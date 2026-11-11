-- Tests of brush_roads.tl: the plan that the Roads choices of the toolbar give one road (template, decorations, lanes,
-- lock, reason, notes), and the settings that the middle click reads from a road. The game's template and decoration
-- repositories and the edges are stubs. rub_config and rub_templates are the real modules.

local support = dofile((arg[0]:match("^(.*)[/\\][^/\\]*$") or ".") .. "/support.lua")
local check = support.check

local MODE = { PERSON = 0, CARGO = 1, CAR = 2, BUS = 3, TRUCK = 4, TRAM = 5, ELECTRIC_TRAM = 6 }
local LETTER = { P = MODE.PERSON, G = MODE.CARGO, c = MODE.CAR, b = MODE.BUS, t = MODE.TRUCK, T = MODE.TRAM, E = MODE.ELECTRIC_TRAM }
local ALLEY, BARRIER_OLD, BARRIER_NEW, OTHER_DECORATION = 1, 2, 3, 99
local DECORATION_NAMES = {
  ["::/infrastructure/edge_addons/alley.edge"] = ALLEY,
  ["::/infrastructure/edge_addons/barrier_a.edge"] = BARRIER_OLD,
  ["::/infrastructure/edge_addons/barrier_b.edge"] = BARRIER_NEW,
}

-- Lanes from a text such as "<PG <cbt >cbtTE >PG": "<" is a backward lane, ">" a forward one, the letters are the modes.
local function lanesOf(text)
  local lanes = {}
  for word in text:gmatch("%S+") do
    local lane = { forward = word:sub(1, 1) == ">", transportModes = {} }
    for letter in word:sub(2):gmatch(".") do lane.transportModes[LETTER[letter]] = true end
    lanes[#lanes + 1] = lane
  end
  return lanes
end

local SIDEWALK = { "<PG", ">PG" }
local function layout(perDirection, outer)
  local words = { SIDEWALK[1] }
  for i = 1, perDirection do words[#words + 1] = "<" .. (i == 1 and outer or "cbt") end
  for i = 1, perDirection do words[#words + 1] = ">" .. (i == perDirection and outer or "cbt") end
  words[#words + 1] = SIDEWALK[2]
  return table.concat(words, " ")
end

-- short name -> { lanes, decorations, availability }
local catalog = {}
local function both(name) return { { name, false }, { name, true } } end
local function addFamily(prefix, perDirection, yearFrom, yearTo, town)
  local barrier = yearTo == 0 and "::/infrastructure/edge_addons/barrier_b.edge" or "::/infrastructure/edge_addons/barrier_a.edge"
  local function add(suffix, outer, decorations)
    catalog[prefix .. suffix] = { lanes = layout(perDirection, outer), decorations = decorations or {}, availability = { yearFrom = yearFrom, yearTo = yearTo } }
  end
  add("", "cbt")
  add("_barriers", "cbt", both(barrier))
  add("_bus", "bt")
  if town then
    add("_trees", "cbt", both("::/infrastructure/edge_addons/alley.edge"))
    add("_tram", "cbtT")
    add("_tram_electrified", "cbtTE")
  end
end
for _, size in ipairs({ { "small", 1 }, { "medium", 2 }, { "large", 3 } }) do
  addFamily("town_new_" .. size[1], size[2], 1940, 0, true)
  addFamily("town_old_" .. size[1], size[2], 0, 1940, true)
  addFamily("country_new_" .. size[1], size[2], 1940, 0, false)
  addFamily("country_old_" .. size[1], size[2], 0, 1940, false)
end
catalog["town_new_one_way_medium"] = { lanes = "<PG >cbt >cbt >cbt >cbt >PG", decorations = {}, availability = { yearFrom = 1940, yearTo = 0 } }
catalog["town_new_one_way_medium_bus"] = { lanes = "<PG >cbt >cbt >cbt >bt >PG", decorations = {}, availability = { yearFrom = 1940, yearTo = 0 } }
-- A street of another mod whose lanes carry cars and a tram, and no buses.
catalog["mod_tram_street"] = { lanes = "<PG <cT >cT >PG", decorations = {}, availability = { yearFrom = 0, yearTo = 0 } }
-- A highway is a one-way road between two lanes without any transport mode.
catalog["highway_new_medium"] = { lanes = "< >cbt >cbt >", decorations = {}, availability = { yearFrom = 1940, yearTo = 0 } }
catalog["highway_new_medium_barriers"] = { lanes = "< >cbt >cbt >", decorations = both("::/infrastructure/edge_addons/barrier_b.edge"),
  availability = { yearFrom = 1940, yearTo = 0 } }

local function shortName(resName)
  return (resName:match("([^/]+)$") or resName):gsub("%.street_template$", "")
end
-- The repository lists a template without the root "::/", an edge names it with the root.
local function listedName(short) return "infrastructure/street/all/" .. short .. ".street_template" end
local function edgeName(short) return "::/" .. listedName(short) end

local ids, names = {}, {}
for short in pairs(catalog) do
  names[#names + 1] = short
end
table.sort(names)
for id, short in ipairs(names) do ids[short] = id end

local edges = {}
local logged = {}
_G.log = { message = function(text) logged[#logged + 1] = text end }
_G.api = {
  type = {
    ComponentType = { BASE_EDGE = "BASE_EDGE" },
    enum = { TransportMode = MODE },
  },
  res = {
    streetTemplateRep = {
      find = function(name) return ids[shortName(name)] or -1 end,
      get = function(id)
        local entry = catalog[names[id]]
        return { laneConfigs = lanesOf(entry.lanes), defaultEdgeDecorations = entry.decorations, availability = entry.availability }
      end,
      getAll = function()
        local all = {}
        for i, short in ipairs(names) do all[i] = listedName(short) end
        return all
      end,
    },
    edgeDecorationRep = { find = function(name) return DECORATION_NAMES[name] or -1 end },
  },
  engine = {
    getComponent = function(e)
      if edges[e] == "throw" then error("stub: the read was refused", 0) end
      return edges[e]
    end,
  },
}

support.installRequire({})
local roads = dofile(support.buildDir .. "/brush_roads.lua")

-- Indexes in config.roadTypes
local TOWN_SMALL, TOWN_MEDIUM, TOWN_LARGE, COUNTRY_LARGE, ONE_WAY_MEDIUM = 1, 2, 3, 6, 8

local nextEdge = 0
-- A road: the short name of its template, its lanes (default: the lanes of the template), its decorations and its lock.
local function road(short, fields)
  fields = fields or {}
  nextEdge = nextEdge + 1
  edges[nextEdge] = {
    roadTemplate = edgeName(short), laneConfigs = lanesOf(fields.lanes or catalog[short].lanes),
    edgeDecorations = fields.decorations or {}, roadDevelopmentLocked = fields.locked == true,
  }
  return nextEdge
end
local function decorated(short)
  local list = {}
  for i, entry in ipairs(catalog[short].decorations) do list[i] = { DECORATION_NAMES[entry[1]], entry[2] } end
  return list
end

local function choices(fields)
  local c = { roadType = 0, busLane = "keep", tram = "keep", catenary = "keep", trees = "keep", barrier = "keep", lock = "keep", underground = false }
  for key, value in pairs(fields or {}) do c[key] = value end
  return c
end
local function planOf(fields, edge, year)
  return roads.targeter(choices(fields), year or 1960)(edge)
end

-- The lanes of a plan as text: per driving lane "b" (bus lane), "T" (tram), "E" (catenary), or "-" for none.
local function lanesText(plan)
  if plan.lanes == nil then return "nil" end
  local parts = {}
  for i = 1, plan.laneCount do
    local f = plan.lanes[i]
    if f ~= nil then
      local text = (f.carFree and "b" or "") .. (f.tram and "T" or "") .. (f.electric and "E" or "")
      parts[#parts + 1] = text == "" and "-" or text
    end
  end
  return table.concat(parts, " ")
end
local function decorationsText(list)
  if list == nil then return "nil" end
  local parts = {}
  for _, d in ipairs(list) do parts[#parts + 1] = d[1] .. (d[2] and "+" or "-") end
  return "{" .. table.concat(parts, " ") .. "}"
end
local function templateOf(plan) return plan.template and shortName(plan.template) or "nil" end
local function notesText(plan) return table.concat(plan.notes or {}, ",") end
local function describe(plan)
  return string.format("%s unchanged=%s lanes=[%s] decorations=%s reason=%s notes=%s", templateOf(plan), tostring(plan.unchanged),
    lanesText(plan), decorationsText(plan.decorations), tostring(plan.reason), notesText(plan))
end
local function hasNote(plan, note)
  for _, n in ipairs(plan.notes or {}) do if n == note then return true end end
  return false
end

check("offered types: the six two-way road types", roads.offeredTypes() == 6)

-- Everything on Keep
do
  local plain = planOf({}, road("town_new_medium"))
  check("all Keep: a plain road is the target already, with its own template", plain.unchanged == true and templateOf(plain) == "town_new_medium", describe(plain))
  local busVariant = planOf({}, road("town_new_medium_bus"))
  check("all Keep: a road with the bus template of the game is the target already", busVariant.unchanged == true and templateOf(busVariant) == "town_new_medium_bus"
    and lanesText(busVariant) == "b - - b", describe(busVariant))
  local innerTram = planOf({}, road("town_new_medium", { lanes = "<PG <cbt <cbtTE >cbtTE >cbt >PG" }))
  check("all Keep: a road with the tram on the inner lanes is the target already", innerTram.unchanged == true and lanesText(innerTram) == "- TE TE -", describe(innerTram))
  local highway = planOf({}, road("highway_new_medium"))
  check("all Keep: an unlisted road is the target already", highway.unchanged == true and templateOf(highway) == "highway_new_medium" and notesText(highway) == "", describe(highway))
  check("all Keep: the choices are all Keep", roads.isAllKeep(choices()) == true)
  check("all Keep: one add-on state makes the choices not all Keep", roads.isAllKeep(choices({ barrier = "add" })) == false
    and roads.isAllKeep(choices({ roadType = TOWN_MEDIUM })) == false and roads.isAllKeep(choices({ lock = "lock" })) == false)
  check("all Keep: trees and barrier do not count while the underground view is on", roads.isAllKeep(choices({ barrier = "add", underground = true })) == true)
end

-- Keep road type: alley trees and noise barrier
do
  local addBarrier = planOf({ barrier = "add" }, road("town_new_medium"))
  check("barrier Add on a plain road: the barrier template of its base, with the decorations of that template",
    addBarrier.unchanged == false and templateOf(addBarrier) == "town_new_medium_barriers" and decorationsText(addBarrier.decorations) == "{3- 3+}"
    and lanesText(addBarrier) == "- - - -" and addBarrier.laneCount == 6 and addBarrier.reason == nil, describe(addBarrier))
  local addTrees = planOf({ trees = "add" }, road("town_old_small"), 1920)
  check("trees Add on a plain road: the trees template of its base", templateOf(addTrees) == "town_old_small_trees"
    and decorationsText(addTrees.decorations) == "{1- 1+}", describe(addTrees))
  local barrierOnTrees = planOf({ barrier = "add" }, road("town_new_large_trees", { decorations = decorated("town_new_large_trees") }))
  check("barrier Add on a road with trees: the barrier replaces the trees and the plan notes the lost trees",
    templateOf(barrierOnTrees) == "town_new_large_barriers" and hasNote(barrierOnTrees, roads.NOTE_LOST_TREES) and #barrierOnTrees.notes == 1, describe(barrierOnTrees))
  local treesOnBarrier = planOf({ trees = "add" }, road("town_new_large_barriers", { decorations = decorated("town_new_large_barriers") }))
  check("trees Add on a road with a barrier: the trees replace the barrier and the plan notes the lost barrier",
    templateOf(treesOnBarrier) == "town_new_large_trees" and hasNote(treesOnBarrier, roads.NOTE_LOST_BARRIER) and #treesOnBarrier.notes == 1, describe(treesOnBarrier))
  local swap = planOf({ trees = "add", barrier = "remove" }, road("town_new_large_barriers", { decorations = decorated("town_new_large_barriers") }))
  check("trees Add with barrier Remove on a road with a barrier: trees, and no note of a lost barrier",
    templateOf(swap) == "town_new_large_trees" and notesText(swap) == "", describe(swap))
  local alreadyBarrier = planOf({ barrier = "add" }, road("town_new_medium_barriers", { decorations = decorated("town_new_medium_barriers") }))
  check("barrier Add on a road with a barrier: the target already", alreadyBarrier.unchanged == true and alreadyBarrier.decorations == nil, describe(alreadyBarrier))
  local removeOther = planOf({ trees = "remove" }, road("town_new_medium_barriers", { decorations = decorated("town_new_medium_barriers") }))
  check("trees Remove on a road with a barrier: nothing changes", removeOther.unchanged == true and templateOf(removeOther) == "town_new_medium_barriers", describe(removeOther))
  local removeBarrier = planOf({ barrier = "remove" }, road("town_new_medium_barriers", { decorations = decorated("town_new_medium_barriers") }))
  check("barrier Remove on a road with a barrier: the plain template and an explicit empty decoration list",
    removeBarrier.unchanged == false and templateOf(removeBarrier) == "town_new_medium" and decorationsText(removeBarrier.decorations) == "{}"
    and notesText(removeBarrier) == "", describe(removeBarrier))
  local stale = planOf({ trees = "remove" }, road("town_new_medium", { decorations = { { ALLEY, false }, { ALLEY, true } } }))
  check("trees Remove on a plain template that still holds tree decorations: the road is replaced with an empty decoration list",
    stale.unchanged == false and templateOf(stale) == "town_new_medium" and decorationsText(stale.decorations) == "{}", describe(stale))
  local otherDecoration = planOf({ trees = "remove" }, road("town_new_medium", { decorations = { { OTHER_DECORATION, false } } }))
  check("trees Remove on a plain road with another decoration: nothing changes and the decorations stay",
    otherDecoration.unchanged == true and otherDecoration.decorations == nil, describe(otherDecoration))
  local underground = planOf({ barrier = "add", trees = "remove", underground = true }, road("town_new_medium_trees", { decorations = decorated("town_new_medium_trees") }))
  check("underground view on: trees and barrier are ignored", underground.unchanged == true and templateOf(underground) == "town_new_medium_trees", describe(underground))
end

-- Keep road type: country roads and unlisted roads
do
  local country = planOf({ trees = "add" }, road("country_new_medium"))
  check("trees Add on a country road: only the tree change is left out, with a note", country.unchanged == true and templateOf(country) == "country_new_medium"
    and hasNote(country, roads.NOTE_COUNTRY) and country.reason == nil, describe(country))
  local countryBus = planOf({ trees = "add", busLane = "add" }, road("country_new_medium"))
  check("trees Add and bus lane Add on a country road: the bus lane is applied, the tree change is noted",
    countryBus.unchanged == false and templateOf(countryBus) == "country_new_medium" and lanesText(countryBus) == "b - - b" and hasNote(countryBus, roads.NOTE_COUNTRY), describe(countryBus))
  local highway = planOf({ barrier = "add" }, road("highway_new_medium"))
  check("barrier Add on an unlisted road: the barrier change is left out, with a note", highway.unchanged == true and templateOf(highway) == "highway_new_medium"
    and hasNote(highway, roads.NOTE_UNLISTED) and highway.decorations == nil, describe(highway))
  local highwayBus = planOf({ barrier = "add", busLane = "add", lock = "lock" }, road("highway_new_medium"))
  check("an unlisted road gets its lane and lock changes on its own template", highwayBus.unchanged == false and templateOf(highwayBus) == "highway_new_medium"
    and lanesText(highwayBus) == "- b" and highwayBus.lock == "lock" and hasNote(highwayBus, roads.NOTE_UNLISTED), describe(highwayBus))
  local oneWay = planOf({ tram = "add", catenary = "add" }, road("town_new_one_way_medium"))
  check("a one-way road is unlisted: tram Add puts the tram on its one outer lane, as the base game variant has it", templateOf(oneWay) == "town_new_one_way_medium"
    and lanesText(oneWay) == "- - - TE", describe(oneWay))
  local highwayTram = planOf({ tram = "add", busLane = "add" }, road("highway_new_medium"))
  check("tram Add and bus lane Add on a highway: only the outer lane that carries vehicles gets them, never a lane without transport modes",
    lanesText(highwayTram) == "- bT" and highwayTram.laneCount == 4 and highwayTram.reason == nil, describe(highwayTram))
  local noBus = planOf({ busLane = "add" }, road("mod_tram_street"))
  check("bus lane Add on a road whose outer lanes carry a tram and no buses: the road is left alone with the bus and tram reason",
    noBus.reason == roads.REASON_BUS_TRAM and noBus.template == nil, describe(noBus))
end

-- Keep road type: an old road after 1940
do
  local old = planOf({ barrier = "add" }, road("town_old_medium"), 1950)
  check("old road after 1940: the road keeps its era and gets the barrier of that era",
    templateOf(old) == "town_old_medium_barriers" and decorationsText(old.decorations) == "{2- 2+}" and old.unchanged == false, describe(old))
  local oldLane = planOf({ busLane = "add" }, road("town_old_medium"), 1950)
  check("old road after 1940, lane change only: its own template",
    templateOf(oldLane) == "town_old_medium" and oldLane.decorations == nil and oldLane.unchanged == false, describe(oldLane))
end

-- Lanes under Keep, with the same lane layout
do
  local inner = planOf({ barrier = "add" }, road("town_new_medium", { lanes = "<PG <cbt <cbtT >cbtT >cbt >PG" }))
  check("barrier Add on a road with the tram on the inner lanes: the tram stays on the inner lanes",
    templateOf(inner) == "town_new_medium_barriers" and lanesText(inner) == "- T T -", describe(inner))
  local variant = planOf({ busLane = "add" }, road("town_new_medium_tram_electrified"))
  check("bus lane Add on a road with the tram template of the game: its own template, the outer lanes carry bus lane, tram and catenary",
    variant.unchanged == false and templateOf(variant) == "town_new_medium_tram_electrified" and lanesText(variant) == "bTE - - bTE", describe(variant))
  local variantBarrier = planOf({ barrier = "add" }, road("town_old_large_tram"), 1900)
  check("barrier Add on a road with the tram template of the game: the barrier template of its base, the tram is kept",
    templateOf(variantBarrier) == "town_old_large_barriers" and lanesText(variantBarrier) == "T - - - - T", describe(variantBarrier))
  local oneSide = planOf({ lock = "lock" }, road("town_new_small", { lanes = "<PG <cbtT >cbt >PG" }))
  check("a tram in one direction only is kept as it is", lanesText(oneSide) == "T -" and oneSide.unchanged == false, describe(oneSide))
end

-- The add-on states of the lanes
do
  local tram = planOf({ tram = "add" }, road("town_new_medium"))
  check("tram Add with catenary Keep: the tram on the outer lanes, without catenary", lanesText(tram) == "T - - T" and tram.unchanged == false, describe(tram))
  local tramCatenary = planOf({ tram = "add", catenary = "add" }, road("town_new_medium"))
  check("tram Add with catenary Add: both in one plan", lanesText(tramCatenary) == "TE - - TE", describe(tramCatenary))
  local hasInner = planOf({ tram = "add" }, road("town_new_medium", { lanes = "<PG <cbt <cbtT >cbtT >cbt >PG" }))
  check("tram Add on a road with a tram on the inner lanes: the road is left as it is", hasInner.unchanged == true and lanesText(hasInner) == "- T T -", describe(hasInner))
  local noTram = planOf({ catenary = "add" }, road("town_new_medium"))
  check("catenary Add on a road without a tram: nothing changes", noTram.unchanged == true and lanesText(noTram) == "- - - -", describe(noTram))
  local electrify = planOf({ catenary = "add" }, road("town_new_medium", { lanes = "<PG <cbt <cbtT >cbtT >cbt >PG" }))
  check("catenary Add on a road with a tram: every tram lane gets the catenary", electrify.unchanged == false and lanesText(electrify) == "- TE TE -", describe(electrify))
  local unwire = planOf({ catenary = "remove" }, road("town_new_medium_tram_electrified"))
  check("catenary Remove: the tram stays, the catenary goes", lanesText(unwire) == "T - - T" and unwire.unchanged == false, describe(unwire))
  local removeTram = planOf({ tram = "remove" }, road("town_new_medium", { lanes = "<PG <bt <cbtTE >cbtTE >bt >PG" }))
  check("tram Remove: no lane keeps the tram or the catenary, the bus lane stays", lanesText(removeTram) == "b - - b" and removeTram.unchanged == false, describe(removeTram))
  local removeBus = planOf({ busLane = "remove" }, road("town_new_medium_bus"))
  check("bus lane Remove on the bus template of the game: the cars come back on its own template",
    templateOf(removeBus) == "town_new_medium_bus" and lanesText(removeBus) == "- - - -" and removeBus.unchanged == false, describe(removeBus))
  local busAdded = planOf({ busLane = "add" }, road("town_new_medium_bus"))
  check("bus lane Add on a road with bus lanes: the target already", busAdded.unchanged == true, describe(busAdded))
  local locked = planOf({ lock = "lock" }, road("town_new_medium", { locked = true }))
  local unlocked = planOf({ lock = "lock" }, road("town_new_medium"))
  check("Lock: a locked road is the target already, an unlocked road is not", locked.unchanged == true and unlocked.unchanged == false and unlocked.lock == "lock")
  local unlock = planOf({ lock = "unlock" }, road("town_new_medium", { locked = true }))
  check("Unlock: a locked road is not the target", unlock.unchanged == false and unlock.lock == "unlock")
end

-- A concrete road type
do
  local plain = planOf({ roadType = TOWN_LARGE }, road("town_new_medium"))
  check("road type: a plain road gets the newest template of the type", templateOf(plain) == "town_new_large" and plain.unchanged == false
    and plain.decorations == nil and lanesText(plain) == "- - - - - -", describe(plain))
  local sameType = planOf({ roadType = TOWN_MEDIUM }, road("town_new_medium"))
  check("road type: a road of that type is the target already", sameType.unchanged == true, describe(sameType))
  local oldSameType = planOf({ roadType = TOWN_MEDIUM }, road("town_old_medium"), 1950)
  check("road type: an old road of that type after 1940 gets the new template", templateOf(oldSameType) == "town_new_medium" and oldSameType.unchanged == false, describe(oldSameType))
  local keepsTrees = planOf({ roadType = TOWN_LARGE }, road("town_new_medium_trees", { decorations = decorated("town_new_medium_trees") }))
  check("road type with trees Keep: a road with trees gets the trees template of the type",
    templateOf(keepsTrees) == "town_new_large_trees" and decorationsText(keepsTrees.decorations) == "{1- 1+}" and notesText(keepsTrees) == "", describe(keepsTrees))
  local toCountry = planOf({ roadType = COUNTRY_LARGE }, road("town_new_medium_trees", { decorations = decorated("town_new_medium_trees") }))
  check("country road type with trees Keep: the road loses its trees, with a note and an empty decoration list",
    templateOf(toCountry) == "country_new_large" and hasNote(toCountry, roads.NOTE_LOST_TREES) and decorationsText(toCountry.decorations) == "{}", describe(toCountry))
  local eraBarrier = planOf({ roadType = TOWN_MEDIUM }, road("town_old_medium_barriers", { decorations = decorated("town_old_medium_barriers") }), 1950)
  check("road type: a kept barrier becomes the barrier of the new template", templateOf(eraBarrier) == "town_new_medium_barriers"
    and decorationsText(eraBarrier.decorations) == "{3- 3+}", describe(eraBarrier))
  local highway = planOf({ roadType = TOWN_MEDIUM, barrier = "add" }, road("highway_new_medium"))
  check("road type on an unlisted road: the road gets the type with the barrier", templateOf(highway) == "town_new_medium_barriers"
    and notesText(highway) == "" and lanesText(highway) == "- - - -", describe(highway))
  local highwayBarrier = planOf({ roadType = TOWN_MEDIUM }, road("highway_new_medium_barriers", { decorations = decorated("highway_new_medium_barriers") }))
  check("road type on an unlisted road with a barrier, barrier Keep: the barrier template of the type in one press",
    templateOf(highwayBarrier) == "town_new_medium_barriers" and decorationsText(highwayBarrier.decorations) == "{3- 3+}" and notesText(highwayBarrier) == "", describe(highwayBarrier))
  local busVariant = planOf({ roadType = TOWN_MEDIUM }, road("town_new_medium_bus"))
  check("road type on the bus template of the game of that type: the target already, the road is not rebuilt",
    busVariant.unchanged == true and templateOf(busVariant) == "town_new_medium_bus", describe(busVariant))
  local oldVariant = planOf({ roadType = TOWN_MEDIUM }, road("town_old_medium_tram"), 1950)
  check("road type on the old tram template of the game after 1940: the new template of the type, the tram is kept",
    templateOf(oldVariant) == "town_new_medium" and lanesText(oldVariant) == "T - - T" and oldVariant.unchanged == false, describe(oldVariant))
  local notYet = planOf({ roadType = TOWN_MEDIUM, trees = "add" }, road("country_old_small"), 1930)
  check("road type: the type is taken in the year of the game", templateOf(notYet) == "town_old_medium_trees", describe(notYet))
end

-- Lanes under Keep, with another lane layout
do
  local widen = planOf({ roadType = TOWN_LARGE }, road("town_new_medium", { lanes = "<PG <cbt <cbtTE >cbtTE >cbt >PG" }))
  check("medium to large: the innermost lane stays the innermost", lanesText(widen) == "- - TE TE - -", describe(widen))
  local widenOuter = planOf({ roadType = TOWN_LARGE }, road("town_new_medium_bus"))
  check("medium to large: the outermost lane stays the outermost", lanesText(widenOuter) == "b - - - - b", describe(widenOuter))
  local fromSmall = planOf({ roadType = TOWN_MEDIUM }, road("town_new_small_tram_electrified"))
  check("small to medium: the single lane maps to the outer lane", lanesText(fromSmall) == "TE - - TE", describe(fromSmall))
  local toSmall = planOf({ roadType = TOWN_SMALL }, road("town_new_medium", { lanes = "<PG <bt <cbtT >cbtT >bt >PG" }))
  check("medium to small: the tram of any lane lands on the single lane, a bus lane only when every lane was one",
    lanesText(toSmall) == "T T", describe(toSmall))
  local middle = planOf({ roadType = TOWN_MEDIUM }, road("town_new_large", { lanes = "<PG <cbt <cbtT <cbt >cbt >cbtT >cbt >PG" }))
  check("large to medium with the tram on the middle lane: the road is left alone with the lanes reason",
    middle.reason == roads.REASON_LANES and middle.template == nil and middle.unchanged == false, describe(middle))
  local middlePlain = planOf({ roadType = TOWN_MEDIUM, tram = "remove" }, road("town_new_large", { lanes = "<PG <cbt <cbtT <cbt >cbt >cbtT >cbt >PG" }))
  check("large to medium with the tram on the middle lane and tram Remove: the road gets the type, the tram needs no lane",
    middlePlain.reason == nil and templateOf(middlePlain) == "town_new_medium" and lanesText(middlePlain) == "- - - -", describe(middlePlain))
  local oneWayBus = planOf({ roadType = TOWN_MEDIUM }, road("town_new_one_way_medium", { lanes = "<PG >cbt >cbt >cbt >bt >PG" }))
  check("one-way road with a bus lane to a two-way type: left alone with the lanes reason", oneWayBus.reason == roads.REASON_LANES, describe(oneWayBus))
  local oneWayPlain = planOf({ roadType = TOWN_MEDIUM }, road("town_new_one_way_medium"))
  check("plain one-way road to a two-way type: it gets the type", templateOf(oneWayPlain) == "town_new_medium" and lanesText(oneWayPlain) == "- - - -", describe(oneWayPlain))
end

-- Roads that cannot be read
do
  nextEdge = nextEdge + 1
  edges[nextEdge] = "throw"
  local refused = planOf({}, nextEdge)
  check("a road whose read fails: the plan has the gone reason", refused.reason == roads.REASON_GONE and refused.unchanged == false)
  check("a road whose read fails: the log names the error", #logged == 1 and support.contains(logged[1], "the read was refused"), logged[1])
  local missing = planOf({}, 9999)
  check("a road that is gone: the plan has the gone reason", missing.reason == roads.REASON_GONE)
end

-- The key of the choices
check("key: the same choices give the same text, another state gives another text",
  roads.key(choices()) == roads.key(choices()) and roads.key(choices()) ~= roads.key(choices({ tram = "add" }))
  and roads.key(choices({ roadType = TOWN_SMALL })) ~= roads.key(choices({ roadType = TOWN_MEDIUM })))

-- What the middle click reads
do
  local plain = roads.read(road("country_old_large"))
  check("read: a plain country road", plain ~= nil and plain.roadType == COUNTRY_LARGE and not plain.trees and not plain.barrier and not plain.busLane
    and not plain.tram and not plain.catenary and plain.lock == "keep" and plain.editedLanes == false)
  local full = roads.read(road("town_new_medium_trees", { lanes = "<PG <btTE <cbt >cbt >btTE >PG", decorations = decorated("town_new_medium_trees"), locked = true }))
  check("read: trees, bus lane, tram, catenary and lock", full ~= nil and full.roadType == TOWN_MEDIUM and full.trees and not full.barrier and full.busLane
    and full.tram and full.catenary and full.lock == "lock" and full.editedLanes == false)
  local variant = roads.read(road("town_old_small_tram"))
  check("read: the tram template of the game reads as its road type with a tram", variant ~= nil and variant.roadType == TOWN_SMALL and variant.tram and not variant.catenary)
  local staleBarrier = roads.read(road("town_new_medium", { decorations = { { BARRIER_NEW, false }, { BARRIER_NEW, true } } }))
  check("read: a plain template with barrier decorations reads as a barrier", staleBarrier ~= nil and staleBarrier.barrier and not staleBarrier.trees)
  local inner = roads.read(road("town_new_medium", { lanes = "<PG <cbt <cbtT >cbtT >cbt >PG" }))
  check("read: a tram on the inner lanes cannot be stated by the toolbar", inner ~= nil and inner.editedLanes == true and not inner.tram and not inner.busLane and not inner.catenary)
  local oneSide = roads.read(road("town_new_small", { lanes = "<PG <cbtT >cbt >PG" }))
  check("read: outer lanes that differ cannot be stated by the toolbar", oneSide ~= nil and oneSide.editedLanes == true)
  local oneWay = roads.read(road("town_new_one_way_medium"))
  check("read: a one-way road reads as its one-way type", oneWay ~= nil and oneWay.roadType == ONE_WAY_MEDIUM)
  local oneWayBus = roads.read(road("town_new_one_way_medium_bus"))
  check("read: the one-way bus template of the game reads as a bus lane", oneWayBus ~= nil and oneWayBus.busLane and oneWayBus.editedLanes == false)
  check("outer lanes: a road type template carries buses on them, a template without buses there and a missing template do not",
    roads.outerLanesCarryBuses(edgeName("town_new_medium")) == true and roads.outerLanesCarryBuses(edgeName("mod_tram_street")) == false
    and roads.outerLanesCarryBuses(edgeName("no_such_template")) == false)
  check("read: an unlisted road gives nothing", roads.read(road("highway_new_medium")) == nil)
  check("read: a road that is gone gives nothing", roads.read(9999) == nil)
end

support.finish("brush_roads")
