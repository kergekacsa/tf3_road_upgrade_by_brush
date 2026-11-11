-- Tests of the Roads choices of the toolbar: rub_options.tl (params and choices), rub_rules.tl (the problems that hold for
-- every road) and brush_options.tl (the offered road types, the target, the key, and the values that the copy sets).
-- The game, its GUI modules and brush_style are stand-ins. The other modules are the real ones.

local support = dofile((arg[0]:match("^(.*)[/\\][^/\\]*$") or ".") .. "/support.lua")
local check = support.check

local MODE = { PERSON = 0, CARGO = 1, CAR = 2, BUS = 3, TRUCK = 4, TRAM = 5, ELECTRIC_TRAM = 6 }
local year = 1960

local function lane(forward, ...)
  local modes = {}
  for _, mode in ipairs({ ... }) do modes[mode] = true end
  return { forward = forward, transportModes = modes }
end
local function mediumLanes()
  return {
    lane(false, MODE.PERSON, MODE.CARGO), lane(false, MODE.CAR, MODE.BUS, MODE.TRUCK), lane(false, MODE.CAR, MODE.BUS, MODE.TRUCK),
    lane(true, MODE.CAR, MODE.BUS, MODE.TRUCK), lane(true, MODE.CAR, MODE.BUS, MODE.TRUCK), lane(true, MODE.PERSON, MODE.CARGO),
  }
end

-- short name -> availability. Every template has the lanes of a medium road.
local catalog = {
  town_new_medium = { yearFrom = 1940, yearTo = 0 }, town_new_medium_trees = { yearFrom = 1940, yearTo = 0 },
  town_new_medium_barriers = { yearFrom = 1940, yearTo = 0 },
  town_old_medium = { yearFrom = 0, yearTo = 1940 },
  country_new_medium = { yearFrom = 1940, yearTo = 0 }, country_new_medium_barriers = { yearFrom = 1940, yearTo = 0 },
  town_new_large = { yearFrom = 1980, yearTo = 0 },
}
local names = {}
for short in pairs(catalog) do names[#names + 1] = short end
table.sort(names)
local ids = {}
for id, short in ipairs(names) do ids[short] = id end
local function shortName(resName) return ((resName:match("([^/]+)$") or resName):gsub("%.street_template$", "")) end
local function resName(short) return "::/infrastructure/street/all/" .. short .. ".street_template" end

local edges = {}
_G._ = function(text) return text end
_G.api = {
  type = {
    ComponentType = { BASE_EDGE = "BASE_EDGE" },
    enum = {
      TransportMode = MODE,
      ScriptParamType = { ComboBox = "ComboBox", Button = "Button", CheckBox = "CheckBox" },
      ScriptParamDisplayMode = { Horizontal = "Horizontal" },
      BaseEdgeType = { NORMAL = 0, BRIDGE = 1, TUNNEL = 2 },
    },
  },
  res = {
    streetTemplateRep = {
      find = function(name) return ids[shortName(name)] or -1 end,
      get = function(id) return { laneConfigs = mediumLanes(), defaultEdgeDecorations = {}, availability = catalog[names[id]], description = { name = names[id] } } end,
      getAll = function()
        local all = {}
        for i, short in ipairs(names) do all[i] = resName(short) end
        return all
      end,
    },
    edgeDecorationRep = { find = function() return -1 end, get = function() return {} end },
  },
  engine = {
    util = { getYear = function() return year end },
    getComponent = function(e) return edges[e] end,
  },
}

local stubs = {
  builtin = { BoxLayout = function() return {} end, TextView = function() return {} end, type = { Orientation = { Horizontal = "Horizontal" } } },
  brush_style = { meta = function() return {} end },
  construction_react_util = {
    makeUndergroundParam = function() return { key = "undergroundMode", name = "Underground", values = { "No", "Yes" }, defaultIndex = 2 } end,
  },
}
local loaded = {}
_G.ug_require = function(path)
  local name = path:match("([%w_%.]+)%.tl$") or path:match("([%w_]+)%.lua$")
  assert(name, "unknown module path " .. tostring(path))
  if stubs[name] then return stubs[name] end
  if not loaded[name] then loaded[name] = assert(loadfile(support.buildDir .. "/" .. name .. ".lua"))() end
  return loaded[name]
end

local options = ug_require("kacsa_road_upgrade_brush::/road_upgrade_brush/rub_options.tl")
local rules = ug_require("kacsa_road_upgrade_brush::/road_upgrade_brush/rub_rules.tl")
local brushOptions = ug_require("kacsa_road_upgrade_brush::/road_upgrade_brush/brush_options.tl")

-- Indexes in config.roadTypes, and the values of the combo boxes
local TOWN_MEDIUM, TOWN_LARGE, COUNTRY_MEDIUM = 2, 3, 5
local KEEP, ADD, REMOVE = 1, 2, 3
local UNDERGROUND_ON, MODE_RAILS = 1, 2

local function paramByKey(list, key)
  for _, param in ipairs(list) do
    if param.key == key then return param end
  end
  return nil
end
local function has(list, value)
  for _, v in ipairs(list) do if v == value then return true end end
  return false
end

-- The choices of a params map
do
  local fresh = options.fromParams({})
  check("choices: a fresh toolbar is Keep road type with every add-on state on Keep", fresh.roadType == 0 and fresh.busLane == "keep" and fresh.tram == "keep"
    and fresh.catenary == "keep" and fresh.trees == "keep" and fresh.barrier == "keep" and fresh.lock == "keep" and fresh.underground == false)
  local set = options.fromParams({ rub_roadType = TOWN_MEDIUM + 1, rub_busLane = ADD, rub_tram = ADD, rub_catenary = REMOVE, rub_trees = REMOVE, rub_barrier = ADD,
    rub_lock = 3, undergroundMode = UNDERGROUND_ON })
  check("choices: the road type is the combo box value minus the Keep entry, and each state follows its value",
    set.roadType == TOWN_MEDIUM and set.busLane == "add" and set.tram == "add" and set.catenary == "remove" and set.trees == "remove" and set.barrier == "add"
    and set.lock == "unlock" and set.underground == true)
  local hidden = options.fromParams({ rub_tram = REMOVE, rub_catenary = ADD })
  check("choices: the catenary state does not count while the tram track is on Remove", hidden.tram == "remove" and hidden.catenary == "keep")
  local outside = options.fromParams({ rub_roadType = 40, rub_busLane = 9 })
  check("choices: a value outside the list reads as Keep", outside.roadType == 0 and outside.busLane == "keep")
end

-- The params of the toolbar
do
  local all = options.params()
  local roadType = paramByKey(all, "rub_roadType")
  check("params: Keep is the first entry of the road type list and the default", roadType.values[1] == "rub_lock_keep" and roadType.defaultIndex == 1
    and roadType.values[TOWN_MEDIUM + 1] == "rub_type_town_medium")
  for _, key in ipairs({ "rub_busLane", "rub_tram", "rub_catenary", "rub_trees", "rub_barrier" }) do
    local param = paramByKey(all, key)
    check("params: " .. key .. " is a combo box with Keep, Add and Remove, Keep by default",
      param ~= nil and param.uiType == "ComboBox" and #param.values == 3 and param.values[1] == "rub_lock_keep" and param.values[2] == "rub_state_add"
      and param.values[3] == "rub_state_remove" and param.defaultIndex == 1)
  end
  local catenary = paramByKey(all, "rub_catenary")
  check("params: the catenary choice starts with the first year of the tram catenary", catenary.yearFrom == 1910)
  check("params: the catenary choice is hidden while the tram track is on Remove, and shows for Keep and Add",
    catenary.checkEnabledFn({ rub_tram = REMOVE }) == "Hidden" and catenary.checkEnabledFn({ rub_tram = KEEP }) == "Enabled"
    and catenary.checkEnabledFn({ rub_tram = ADD }) == "Enabled" and catenary.checkEnabledFn({}) == "Enabled")
  local lock = paramByKey(all, "rub_lock")
  check("params: the lock keeps its three ways", #lock.values == 3 and lock.values[2] == "rub_lock_lock" and lock.values[3] == "rub_lock_unlock")

  local brushParams = brushOptions.params("notes")
  local offered = paramByKey(brushParams, "rub_roadType")
  check("brush params: the road type list is Keep and the six two-way road types", #offered.values == 7 and offered.values[1] == "rub_lock_keep"
    and not has(offered.values, "rub_type_one_way_small"))
  local trees = paramByKey(brushParams, "rub_trees")
  check("brush params: alley trees and noise barrier are disabled while the underground view is on",
    trees.checkEnabledFn({ undergroundMode = UNDERGROUND_ON }) == "Disabled" and trees.checkEnabledFn({}) == "Enabled"
    and paramByKey(brushParams, "rub_barrier").checkEnabledFn({ undergroundMode = UNDERGROUND_ON }) == "Disabled")
  check("brush params: the road choices are hidden in Rails mode", trees.checkEnabledFn({ rub_mode = MODE_RAILS }) == "Hidden")
end

-- The problems that hold for every road
do
  local function problems(fields) return rules.check(options.fromParams(fields), year) end
  check("problems: a fresh toolbar has none", #problems({}) == 0)
  local both = problems({ rub_trees = ADD, rub_barrier = ADD })
  check("problems: alley trees Add with noise barrier Add", #both == 1 and both[1] == "treesAndBarrier")
  check("problems: Add with Remove of the other kind is none", #problems({ rub_trees = ADD, rub_barrier = REMOVE }) == 0)
  check("problems: both on Add do not count while the underground view is on", #problems({ rub_trees = ADD, rub_barrier = ADD, undergroundMode = UNDERGROUND_ON }) == 0)
  check("problems: alley trees Add with Keep road type is none, a country road is a matter of each road", #problems({ rub_trees = ADD }) == 0)
  local country = problems({ rub_roadType = COUNTRY_MEDIUM + 1, rub_trees = ADD })
  check("problems: alley trees Add with a country road type", #country == 1 and country[1] == "treesCountry")
  check("problems: alley trees Keep with a country road type is none", #problems({ rub_roadType = COUNTRY_MEDIUM + 1 }) == 0)
  local notYet = problems({ rub_roadType = TOWN_LARGE + 1 })
  check("problems: a road type that the year does not offer", #notYet == 1 and notYet[1] == "noTemplate")
end

-- The target, the key and the Keep test of a params map
do
  local target, problem = brushOptions.targeter({ rub_trees = ADD, rub_barrier = ADD })
  check("target: a problem gives no target and the short text of the problem", target == nil and problem == "rub_chip_treesAndBarrier")
  edges[1] = { roadTemplate = resName("town_new_medium"), laneConfigs = mediumLanes(), edgeDecorations = {}, roadDevelopmentLocked = false }
  local keepTarget = brushOptions.targeter({})
  check("target: a fresh toolbar gives a target that leaves a road as it is", keepTarget ~= nil and keepTarget(1).unchanged == true)
  local barrierTarget = brushOptions.targeter({ rub_barrier = ADD })
  check("target: noise barrier Add gives the barrier template of the road", barrierTarget(1).unchanged == false
    and shortName(barrierTarget(1).template) == "town_new_medium_barriers")
  local railTarget = brushOptions.targeter({ rub_mode = MODE_RAILS })
  local railPlan = railTarget(1)
  check("target: in Rails mode a road has no target, with the reason of another track type", railPlan.template == nil and railPlan.reason == "other track type"
    and railPlan.unchanged == false and railPlan.lock == "keep")
  check("key: another state gives another text, the same params give the same text",
    brushOptions.key({}) == brushOptions.key({}) and brushOptions.key({}) ~= brushOptions.key({ rub_tram = ADD })
    and brushOptions.key({}) ~= brushOptions.key({ rub_mode = MODE_RAILS }))
  year = 1961
  local later = brushOptions.key({})
  year = 1960
  check("key: another year gives another text for roads", later ~= brushOptions.key({}))
  check("all Keep: a fresh toolbar in Roads mode", brushOptions.allKeep({}) == true and brushOptions.allKeep(nil) == true)
  check("all Keep: not with a state set, and never in Rails mode", brushOptions.allKeep({ rub_busLane = REMOVE }) == false
    and brushOptions.allKeep({ rub_mode = MODE_RAILS }) == false)
end

-- The values that the middle-click copy sets
do
  local function applied(clone)
    local set = {}
    local menu = {
      getParamByKey = function(key) return { index = key } end,
      changeParam = function(index, value) set[index] = value end,
    }
    local allSet = brushOptions.apply(menu, clone)
    return set, allSet
  end
  local set, allSet = applied({ roadType = TOWN_MEDIUM, trees = true, barrier = false, busLane = false, tram = true, catenary = true, lock = "lock", editedLanes = false })
  check("copy: a concrete road type, and Add or Remove for each add-on", allSet == true and set.rub_roadType == TOWN_MEDIUM + 1 and set.rub_trees == ADD
    and set.rub_barrier == REMOVE and set.rub_busLane == REMOVE and set.rub_tram == ADD and set.rub_catenary == ADD and set.rub_lock == 2)
  local plain = applied({ roadType = TOWN_MEDIUM, trees = false, barrier = false, busLane = false, tram = false, catenary = false, lock = "keep", editedLanes = false })
  check("copy: a road without a tram sets no catenary state, and an unlocked road sets the lock to Keep", plain.rub_tram == REMOVE and plain.rub_catenary == nil
    and plain.rub_lock == 1)
  local edited = applied({ roadType = TOWN_MEDIUM, trees = false, barrier = true, busLane = false, tram = false, catenary = false, lock = "keep", editedLanes = true })
  check("copy: lanes that the toolbar cannot state set bus lane, tram track and catenary to Keep", edited.rub_busLane == KEEP and edited.rub_tram == KEEP
    and edited.rub_catenary == KEEP and edited.rub_barrier == ADD)
  check("copy: the toolbar offers the six two-way road types", brushOptions.offers({ roadType = 6 }) == true and brushOptions.offers({ roadType = 7 }) == false)
end

support.finish("road_options")
