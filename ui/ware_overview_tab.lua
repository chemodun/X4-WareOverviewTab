-- Ware Overview Tab
-- Adds a "Ware Overview" tab to the Property Owned menu (left-panel map menu),
-- placed after the Production Stations Tab (or after "stations" if PST is absent).
-- Lists ALL economy wares (of the four transport types), grouped by transport type
-- (Container, Solid, Liquid, Condensate). For each ware the row shows:
--   station count | total stock | total produced/h | total consumed/h
-- Each ware row is expandable to a per-station breakdown with a Configure Station
-- button, Logical Station Overview button, and Transaction Log button.
--
-- Data collection follows production_stations_tab (station list) and
-- station_storage_allocation (caching approach).
--
-- Compatible with X4 8.00 and 9.00.

local ffi = require("ffi")
local C   = ffi.C

ffi.cdef [[
  typedef uint64_t UniverseID;

  typedef struct {
    int major;
    int minor;
  } GameVersion;

  uint32_t    GetAllFactionStations(UniverseID* result, uint32_t resultlen, const char* factionid);
  const char* GetComponentName(UniverseID componentid);
  double      GetContainerWareConsumption(UniverseID containerid, const char* wareid, bool ignorestate);
  double      GetContainerWareProduction(UniverseID containerid, const char* wareid, bool ignorestate);
  GameVersion GetGameVersion(void);
  uint32_t    GetNumAllFactionStations(const char* factionid);
  UniverseID  GetPlayerID(void);
  uint32_t    GetNumStationModules(UniverseID stationid, bool includeconstructions, bool includewrecks);
  bool        IsComponentClass(UniverseID componentid, const char* classname);
  bool        IsComponentWrecked(UniverseID componentid);
  bool        IsRealComponentClass(UniverseID componentid, const char* classname);
  void        SetFocusMapComponent(UniverseID holomapid, UniverseID componentid, bool resetplayerpan);
  uint32_t    GetNumWares(const char* tags, bool research, const char* licenceownerid, const char* exclusiontags);
  uint32_t    GetWares(const char** result, uint32_t resultlen, const char* tags, bool research, const char* licenceownerid, const char* exclusiontags);
]]

-- *** constants ***

local PAGE_ID  = 1972092420
local MODE     = "wareOverview"
local TAB_ICON = "mapst_fs_trade"

-- Transport type order and display names (ReadText filled in after init).
-- Key matches the transport tag string returned by the game.
local TRANSPORT_ORDER = { "container", "solid", "liquid", "condensate" }
local TRANSPORT_TEXT_IDS = {
  container  = { page = 20109, id = 101  },  -- "Container Storage"
  solid      = { page = 20109, id = 301  },  -- "Solid Storage"
  liquid     = { page = 20109, id = 601  },  -- "Liquid Storage"
  condensate = { page = 20109, id = 9801 },  -- "Condensate Storage"
}

-- PST mode key (to detect if Production Stations Tab is loaded, for positioning).
local PST_MODE = "productionStations"

-- *** module table ***

local wot = {
  menuMap       = nil,
  menuMapConfig = {},
  isV9          = C.GetGameVersion().major >= 9,

  -- Expand state: wot.expandedWares[wareId] = true when that ware row is open.
  expandedWares = {},

  -- *** Ware registry (built once at init, wares don't change after load) ***
  -- wareRegistry[wareId] = { name, icon, transport }
  wareRegistry = nil,

  -- Options config (loaded from player.entity.$wareOverviewTab via MD).
  playerId            = nil,

  -- *** Data cache ***
  -- Rebuilt every dataRefreshInterval renders or when the station list changes.
  dataRefreshInterval = 3,
  dataCache           = nil,  -- { turnCounter, stationListHash, data = { [ware] = wareEntry } }
                              -- wareEntry: { name, icon, transport, stationCount, stock,
                              --              production, consumption, stations = [] }
                              -- stations[]: { id, id64, name, sector, stock,
                              --               production, consumption, hasProduction }
}

-- *** debug helpers ***

local debugLevel = "none"  -- "none" | "debug" | "trace"

local function debug(msg)
  if debugLevel ~= "none" and type(DebugError) == "function" then
    DebugError("WareOverviewTab: " .. msg)
  end
end

local function trace(msg)
  if debugLevel == "trace" then
    debug(msg)
  end
end

-- *** formatting helpers ***

local function fmt(n)
  return ConvertIntegerString(Helper.round(n), true, 0, true, false)
end

local function fmtRate(v)
  if v <= 0 then return "--" end
  return fmt(v)
end

-- *** station list helpers ***

--- Build a sorted list of player station LuaIDs that pass the menu's validity check.
--- Same approach as production_stations_tab.prepareTabData.
local function buildStationList()
  local n = tonumber(C.GetNumAllFactionStations("player"))
  if n == 0 then return {} end
  local buf = ffi.new("UniverseID[?]", n)
  n = tonumber(C.GetAllFactionStations(buf, n, "player"))

  local entries = {}
  for i = 0, n - 1 do
    local object = ConvertStringToLuaID(tostring(buf[i]))
    local object64 = ConvertIDTo64Bit(object)
    local name, hull, purpose, uirelation, sector, classid, realclassid, idcode, fleetname =
      GetComponentData(object, "name", "hullpercent", "primarypurpose", "uirelation",
                       "sector", "classid", "realclassid", "idcode", "fleetname")
    if wot.menuMap.isObjectValid(object64, classid, realclassid) then
      table.insert(entries, {
        id         = object,
        id64       = object64,
        name       = name,
        fleetname  = fleetname,
        objectid   = idcode,
        classid    = classid,
        realclassid = realclassid,
        hull       = hull,
        purpose    = purpose,
        relation   = uirelation,
        sector     = sector,
      })
    end
  end

  table.sort(entries, wot.menuMap.componentSorter(wot.menuMap.propertySorterType))
  return entries
end

--- Build a simple hash string from the sorted station ID list (for change detection).
local function stationListHash(stations)
  local ids = {}
  for _, s in ipairs(stations) do
    ids[#ids + 1] = tostring(s.id)
  end
  return table.concat(ids, ",")
end

-- *** data collection ***

--- Returns true if the station has at least one built production/processing module.
local function hasProductionModule(station64)
  local n = tonumber(C.GetNumStationModules(station64, false, false))
  if n == 0 then return false end
  local buf = ffi.new("UniverseID[?]", n)
  n = tonumber(C.GetStationModules(buf, n, station64, false, false))
  for i = 0, n - 1 do
    local mod = ConvertStringTo64Bit(tostring(buf[i]))
    if IsValidComponent(mod) and not C.IsComponentWrecked(mod) then
      if C.IsRealComponentClass(mod, "production")
          or C.IsRealComponentClass(mod, "processingmodule") then
        return true
      end
    end
  end
  return false
end

--- Build the ware registry once at init: all economy wares grouped by transport type.
--- Called from wot.Init; result stored in wot.wareRegistry.
local function buildWareRegistry()
  local registry = {}
  for _, transportKey in ipairs(TRANSPORT_ORDER) do
    local n = tonumber(C.GetNumWares(transportKey, false, "", ""))
    if n and n > 0 then
      local buf = ffi.new("const char*[?]", n)
      n = tonumber(C.GetWares(buf, n, transportKey, false, "", ""))
      for i = 0, n - 1 do
        local ware = ffi.string(buf[i])
        if not registry[ware] then
          local wareName, wareIcon, wareTags = GetWareData(ware, "name", "icon", "tags")
          if wareTags and wareTags["economy"] then
            registry[ware] = {
              name      = wareName or ware,
              icon      = (wareIcon and wareIcon ~= "") and wareIcon or "solid",
              transport = transportKey,
            }
          end
        end
      end
    end
  end
  trace("buildWareRegistry: " .. (function() local c = 0; for _ in pairs(registry) do c = c + 1 end; return c end)() .. " economy wares")
  return registry
end

--- Collect ware data: use the pre-built registry for the ware list,
--- then accumulate station stock/prod/cons into matching entries.
--- Wares with no player-station activity are still included (zero stats, no sub-rows).
--- wareData[wareId] = {
---   name, icon, transport,
---   stationCount, stock, production, consumption,
---   stations = array of { id, id64, name, sector, stock, production, consumption, hasProduction }
--- }
local function collectAllWareData(stations)
  -- Pre-populate wareData from registry (zero stats).
  local wareData = {}
  for wareId, info in pairs(wot.wareRegistry) do
    wareData[wareId] = {
      name         = info.name,
      icon         = info.icon,
      transport    = info.transport,
      stationCount = 0,
      stock        = 0,
      production   = 0,
      consumption  = 0,
      stations     = {},
    }
  end

  -- Accumulate per-station data into the pre-populated entries.
  for _, st in ipairs(stations) do
    local station   = st.id
    local station64 = st.id64

    local cargo, products, allResources, tradeWares =
      GetComponentData(station, "cargo", "products", "allresources", "tradewares")
    cargo        = cargo        or {}
    products     = products     or {}
    allResources = allResources or {}
    tradeWares   = tradeWares   or {}

    local wareSet = {}
    for ware in pairs(cargo)           do wareSet[ware] = true end
    for _, ware in ipairs(products)    do wareSet[ware] = true end
    for _, ware in ipairs(allResources) do wareSet[ware] = true end
    for _, ware in ipairs(tradeWares)  do wareSet[ware] = true end

    if not next(wareSet) then goto continue end

    local stHasProduction = hasProductionModule(station64)

    for ware in pairs(wareSet) do
      -- Only process wares that are in our transport-type set.
      if not wareData[ware] then goto nextWare end

      local stockAtStation = (cargo[ware] or 0)
      local prodAtStation  = math.max(0, C.GetContainerWareProduction(station64, ware, false))
      local consAtStation  = math.max(0, C.GetContainerWareConsumption(station64, ware, false))

      if stockAtStation > 0 or prodAtStation > 0 or consAtStation > 0 then
        local entry = wareData[ware]
        entry.stationCount = entry.stationCount + 1
        entry.stock        = entry.stock        + stockAtStation
        entry.production   = entry.production   + prodAtStation
        entry.consumption  = entry.consumption  + consAtStation
        table.insert(entry.stations, {
          id            = station,
          id64          = station64,
          name          = st.name,
          sector        = st.sector,
          stock         = stockAtStation,
          production    = Helper.round(prodAtStation),
          consumption   = Helper.round(consAtStation),
          hasProduction = stHasProduction,
        })
      end

      ::nextWare::
    end
    ::continue::
  end

  -- Round aggregated totals and sort per-ware station lists.
  for _, entry in pairs(wareData) do
    entry.production  = Helper.round(entry.production)
    entry.consumption = Helper.round(entry.consumption)
    table.sort(entry.stations, function(a, b) return (a.name or "") < (b.name or "") end)
  end

  return wareData
end

--- Rebuild wot.dataCache from scratch.
local function rebuildCache(stations)
  trace("rebuildCache: building ware data for " .. tostring(#stations) .. " stations")
  local hash = stationListHash(stations)
  local data = collectAllWareData(stations)
  wot.dataCache = {
    turnCounter     = 1,
    stationListHash = hash,
    data            = data,
  }
end

--- Return cached ware data, refreshing if stale.
--- stations: sorted station list (already built by prepareTabData).
local function getWareData(stations)
  local hash = stationListHash(stations)

  if wot.dataCache == nil
      or wot.dataCache.stationListHash ~= hash
      or wot.dataCache.turnCounter >= wot.dataRefreshInterval then
    rebuildCache(stations)
  else
    wot.dataCache.turnCounter = wot.dataCache.turnCounter + 1
  end

  return wot.dataCache.data
end

-- *** tab registration ***

function wot.setupTab()
  local menu = wot.menuMap
  if menu == nil then
    debug("menu map not initialised")
    return
  end
  local cfg = wot.menuMapConfig
  local categories = cfg and cfg.propertyCategories or nil
  if categories == nil then
    debug("propertyCategories not found in menu map config")
    return
  end

  -- Insert after PST tab if present, otherwise after "stations", otherwise after last non-custom_tab.
  local insertAfter = nil
  local fallbackIdx = nil
  for i, cat in ipairs(categories) do
    if cat.category == MODE then
      trace("Tab already registered")
      return
    end
    if cat.category == PST_MODE then
      insertAfter = i
    elseif cat.category == "stations" and insertAfter == nil then
      insertAfter = i
    end
    if string.sub(cat.category, 1, 10) ~= "custom_tab" then
      fallbackIdx = i
    end
  end

  local idx = insertAfter or fallbackIdx
  if idx then
    table.insert(categories, idx + 1, {
      category = MODE,
      name     = ReadText(PAGE_ID, 1),
      icon     = TAB_ICON,
    })
  end
end

-- *** data preparation callbacks ***

function wot.prepareTabData(infoTableData)
  if infoTableData == nil then return end
  if wot.menuMap.propertyMode ~= MODE then return end

  -- Station list is built and stored on infoTableData so displayTabData can use it.
  if infoTableData.wotStations ~= nil then return end

  infoTableData.wotStations = buildStationList()
  trace("prepareTabData: " .. tostring(#infoTableData.wotStations) .. " stations")
end

-- *** station sub-row renderer ***

--- Renders a single per-ware station row inside the ware expansion block.
--- Column layout (keyed on maxIcons):
---   col 1                    : indent spacer
---   col 2                    : name \n sector
---   col 3                    : production/h (green)
---   col 4                    : consumption/h (red)
---   col maxIcons,   span 4   : stock
---   col maxIcons+4, span 2   : Logical Station Overview button
local function createWareStationRow(tblOrGroup, stEntry, maxIcons)
  local comp64 = stEntry.id64
  local name, color, bgColor, font, mouseover =
    wot.menuMap.getContainerNameAndColors(stEntry.id, 0, true, false, true)
  local sectorName = GetComponentData(stEntry.id, "sector") or ""

  local displayText = Helper.convertColorToText(color) .. name .. "\027X"
                   .. "\n" .. sectorName

  local row = tblOrGroup:addRow({"property", stEntry.id, nil, 1}, {
    bgColor       = bgColor,
    multiSelected = wot.menuMap.isSelectedComponent(stEntry.id),
  })

  -- Col 1: empty indent.
  -- Col 2: name / sector (no span).
  row[2]:createText(displayText, { font = font, mouseOverText = mouseover })
  local rowHeight = row[2]:getMinTextHeight(true)

  -- Col 3: production at this station (dark green).
  row[3]:createText(fmtRate(stEntry.production), { halign = "right", color = Color["text_player_lowlight"] })

  -- Col 4: consumption at this station (dark red).
  row[4]:createText(fmtRate(stEntry.consumption), { halign = "right", color = Color["faction_xenon"] })

  -- Col maxIcons, span 4: stock.
  row[maxIcons]:setColSpan(4)
               :createText(stEntry.stock > 0 and fmt(stEntry.stock) or "--",
                 { halign = "right" })

  -- Col maxIcons+4, span 2: Logical Station Overview button.
  local lsoCell = row[maxIcons + 4]
  lsoCell:setColSpan(2)
  local cellWidth = lsoCell:getWidth()
  local iconSize  = math.min(cellWidth, rowHeight or wot.menuMap.getShipIconWidth())
  local iconX     = (cellWidth - iconSize) / 2
  local iconY     = rowHeight and ((rowHeight - iconSize) / 2) or 0
  lsoCell:createButton({ mouseOverText = ReadText(1001, 7903), scaling = false })
         :setIcon("stationbuildst_lsov", { scaling = false, width = iconSize, height = iconSize, x = iconX, y = iconY })
  lsoCell.handlers.onClick = function()
    Helper.closeMenuAndOpenNewMenu(wot.menuMap, "StationOverviewMenu", { 0, 0, comp64 })
    wot.menuMap.cleanup()
  end
  if rowHeight then lsoCell.properties.height = rowHeight end
end

-- *** display callback ***

--- Build the full tab content for one render pass.
function wot.displayTabData(numDisplayed, instance, ftable, infoTableData)
  if wot.menuMap == nil then return { numdisplayed = numDisplayed } end
  if wot.menuMap.propertyMode ~= MODE then return { numdisplayed = numDisplayed } end
  if infoTableData == nil then return { numdisplayed = numDisplayed } end

  local stations = infoTableData.wotStations or {}
  local wareData = getWareData(stations)

  -- Column layout: fixed by vanilla at 5 + maxIcons (default 10).
  -- Ware rows:
  --   col 1                         : expand button
  --   col 2                         : ware icon + name
  --   col 3                         : prod/h  (green)
  --   col 4                         : cons/h  (red)
  --   col maxIcons,   span 4         : total stock
  --   col maxIcons+4, span 2         : station count
  -- Station sub-rows:
  --   col 2                         : name / sector
  --   col 3                         : prod/h  (green)
  --   col 4                         : cons/h  (red)
  --   col maxIcons,   span 4         : stock
  --   col maxIcons+4, span 2         : LSO button
  local maxIcons = infoTableData.maxIcons or 5

  -- Section header
  local headerRow = ftable:addRow(false, Helper.headerRowProperties)
  headerRow[1]:setColSpan(5 + maxIcons)
              :createText(ReadText(PAGE_ID, 1), Helper.headerRowCenteredProperties)
  numDisplayed = numDisplayed + 1

  -- Column headers
  local chRow = ftable:addRow(false, { fixed = true })
  chRow[2]:createText(ReadText(1001, 45), Helper.headerRowCenteredProperties)                              -- Ware
  chRow[3]:createText(ReadText(1001, 1600), Helper.headerRowCenteredProperties)                             -- Production
  chRow[4]:createText(ReadText(1001, 1609), Helper.headerRowCenteredProperties)                             -- Consumption
  chRow[maxIcons]:setColSpan(4):createText(ReadText(1001, 20), Helper.headerRowCenteredProperties)          -- Stock
  chRow[maxIcons + 4]:setColSpan(2):createText(ReadText(1001, 4), Helper.headerRowCenteredProperties)       -- Stations

  numDisplayed = numDisplayed + 1

  -- RowGroup for content (9.00+ only)
  local tblOrGroup = ftable
  if wot.isV9 then
    tblOrGroup = ftable:addRowGroup({})
  end

  local prevDisplayed = numDisplayed
  local wareIconSize  = wot.menuMap.getShipIconWidth()

  -- Render one transport-type section per type.
  for _, transportKey in ipairs(TRANSPORT_ORDER) do
    -- Collect wares for this transport type, sorted alphabetically.
    local typeName = ReadText(TRANSPORT_TEXT_IDS[transportKey].page, TRANSPORT_TEXT_IDS[transportKey].id)
    local typeWares = {}
    for wareId, entry in pairs(wareData) do
      if entry.transport == transportKey then
        table.insert(typeWares, { id = wareId, entry = entry })
      end
    end
    if #typeWares > 0 then

      table.sort(typeWares, function(a, b) return a.entry.name < b.entry.name end)

      -- Transport-type section header
      local typeRow = tblOrGroup:addRow(false, Helper.headerRowProperties)
      typeRow[1]:setColSpan(5 + maxIcons):createText(typeName, Helper.headerRowCenteredProperties)
      numDisplayed = numDisplayed + 1

      for _, item in ipairs(typeWares) do
        local wareId    = item.id
        local entry     = item.entry
        local isExpanded = wot.expandedWares[wareId] or false
        numDisplayed = numDisplayed + 1

        -- Ware header row (expandable only when there are stations)
        local wareRow = tblOrGroup:addRow(wareId, {bgColor = Color["row_background"]})
        if entry.stationCount > 0 then
          wareRow[1]:createButton({ scaling = true, bgColor = Color["row_background"], highlightColor = Color["row_background"] })
                    :setText(isExpanded and "-" or "+", { scaling = true, halign = "center" })
          wareRow[1].handlers.onClick = function()
            wot.expandedWares[wareId] = not (wot.expandedWares[wareId] or false)
            wot.menuMap.noupdate = true
            wot.menuMap.refreshInfoFrame()
          end
        end

        -- Col 2: ware icon + name
        wareRow[2]:createText("\027[" .. entry.icon .. "] " .. entry.name, {
          halign   = "left",
        })

        -- Col 3: total prod/h (dark green)
        wareRow[3]:createText(fmtRate(entry.production), { halign = "right", color = Color["text_player_lowlight"] })

        -- Col 4: total cons/h (dark red)
        wareRow[4]:createText(fmtRate(entry.consumption), { halign = "right", color = Color["faction_xenon"] })

        -- Col maxIcons, span 4: total stock
        wareRow[maxIcons]:setColSpan(4)
                        :createText(entry.stock > 0 and fmt(entry.stock) or "--",
                          { halign = "right" })

        -- Col maxIcons+4, span 2: station count
        wareRow[maxIcons + 4]:setColSpan(2):createText(entry.stationCount > 0 and tostring(entry.stationCount) or "--", { halign = "right" })

        -- *** Expanded: per-station sub-rows ***
        if isExpanded then
          for _, stEntry in ipairs(entry.stations) do
            createWareStationRow(tblOrGroup, stEntry, maxIcons)
            numDisplayed = numDisplayed + 1
          end
        end
      end

    end
  end

  -- Empty placeholder
  if numDisplayed == prevDisplayed then
    local emptyRow = tblOrGroup:addRow(MODE, { interactive = false })
    emptyRow[2]:setColSpan(4 + maxIcons):createText(ReadText(PAGE_ID, 1000))
  end

  return { numdisplayed = numDisplayed }
end

-- *** init ***

-- Read dataRefreshInterval from the MD-side player.entity.$wareOverviewTab blackboard.
-- Called on init and whenever the options slider is changed (WOT.ConfigChanged event).
local function wotOnConfigChanged()
  if wot.playerId == nil then return end
  local cfg = GetNPCBlackboard(wot.playerId, "$wareOverviewTab")
  if cfg and cfg.dataRefreshInterval then
    wot.dataRefreshInterval = math.max(1, math.min(10, tonumber(cfg.dataRefreshInterval) or 3))
    wot.dataCache = nil   -- invalidate so next render uses the new interval
  end
end

function wot.Init(menuMap)
  trace("wot.Init called")
  wot.menuMap       = menuMap
  wot.menuMapConfig = menuMap.uix_getConfig()
  wot.wareRegistry  = buildWareRegistry()

  menuMap.registerCallback(
    "createPropertyOwned_on_add_other_objects_infoTableData",
    wot.prepareTabData)
  menuMap.registerCallback(
    "createPropertyOwned_on_createPropertySection_unassignedships",
    wot.displayTabData)

  wot.setupTab()

  -- Options menu: read initial config and register for live updates.
  wot.playerId = ConvertStringTo64Bit(tostring(C.GetPlayerID()))
  RegisterEvent("WOT.ConfigChanged", wotOnConfigChanged)
  wotOnConfigChanged()
end

local function Init()
  debug("Initialising Ware Overview Tab")

  local menuMap = Helper.getMenu("MapMenu")
  if menuMap == nil or type(menuMap.registerCallback) ~= "function" then
    debug("Failed to get MapMenu - kuertee UI Extensions not loaded?")
    return
  end

  wot.Init(menuMap)
end

Register_OnLoad_Init(Init)
