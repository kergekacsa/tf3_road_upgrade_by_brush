-- Tests of brush_rails.tl and rub_templates.tl: which track types the game offers in a year, the target template of a
-- track, and the decoration list that gives a track its noise barrier state. The game's template and decoration
-- repositories and the edges are stubs.

local support = dofile((arg[0]:match("^(.*)[/\\][^/\\]*$") or ".") .. "/support.lua")
local check = support.check

local TUNNEL = 2
local TEMPLATE_ROOT = "::/infrastructure/track/"
local function templateName(trackType, catenary)
  return TEMPLATE_ROOT .. trackType .. "/" .. trackType .. (catenary and "_catenary" or "") .. ".street_template"
end
local WOODEN_BARRIER, CONCRETE_BARRIER = "::/infrastructure/edge_addons/barrier_track_a.edge", "::/infrastructure/edge_addons/barrier_track_b.edge"
local WOODEN, CONCRETE, OTHER_DECORATION = 10, 11, 55

-- name -> availability (nil: always available). A template that is not in the table does not exist.
local templateCatalog = {}
-- id -> availability, for the two barriers
local barrierCatalog = {}
local edges = {}
local streetTemplates = {}

local function reset()
  templateCatalog = {
    [templateName("simple", false)] = { yearFrom = 0, yearTo = 0 },
    [templateName("simple", true)] = { yearFrom = 1900, yearTo = 0 },
    [templateName("standard", false)] = { yearFrom = 1930, yearTo = 0 },
    [templateName("standard", true)] = { yearFrom = 1930, yearTo = 0 },
    [templateName("high_speed", false)] = { yearFrom = 1960, yearTo = 0 },
    [templateName("high_speed", true)] = { yearFrom = 1960, yearTo = 0 },
  }
  barrierCatalog = { [WOODEN] = { yearFrom = 0, yearTo = 1940 }, [CONCRETE] = { yearFrom = 1940, yearTo = 0 } }
  edges = {}
end

local templateIds, templateNames = {}, {}
local function rebuildTemplateIds()
  templateIds, templateNames = {}, {}
  local n = 0
  for name in pairs(templateCatalog) do
    n = n + 1
    templateIds[name] = n
    templateNames[n] = name
  end
end

_G.log = { message = function() end }
_G.api = {
  type = {
    ComponentType = { BASE_EDGE = "BASE_EDGE" },
    enum = { BaseEdgeType = { NORMAL = 0, BRIDGE = 1, TUNNEL = TUNNEL } },
  },
  res = {
    streetTemplateRep = {
      find = function(name)
        rebuildTemplateIds()
        return templateIds[name] or streetTemplates[name] or -1
      end,
      get = function(id) return { availability = templateCatalog[templateNames[id]] } end,
      getAll = function() return streetTemplates.all or {} end,
    },
    edgeDecorationRep = {
      find = function(name)
        if name == WOODEN_BARRIER and barrierCatalog[WOODEN] then return WOODEN end
        if name == CONCRETE_BARRIER and barrierCatalog[CONCRETE] then return CONCRETE end
        return -1
      end,
      get = function(id) return { availability = barrierCatalog[id] } end,
    },
  },
  engine = { getComponent = function(e) return edges[e] end },
}

support.installRequire({})
local rails = dofile(support.buildDir .. "/brush_rails.lua")
local templates = ug_require("kacsa_road_upgrade_brush::/road_upgrade_brush/rub_templates.tl")

local function sameDecorations(a, b)
  if a == nil or b == nil then return a == b end
  if #a ~= #b then return false end
  for i = 1, #a do if a[i][1] ~= b[i][1] or a[i][2] ~= b[i][2] then return false end end
  return true
end

local function decorationsText(list)
  if list == nil then return "nil" end
  local parts = {}
  for _, d in ipairs(list) do parts[#parts + 1] = d[1] .. (d[2] and "+" or "-") end
  return "{" .. table.concat(parts, " ") .. "}"
end

-- Which track types and catenary versions the game offers in a year
reset()
check("types: only the simple track exists before the standard track", rails.offeredTypes(1920) == 1)
check("types: the standard track is offered in its first year", rails.offeredTypes(1930) == 2 and rails.offeredTypes(1929) == 1)
check("types: the high speed track is offered in its first year", rails.offeredTypes(1960) == 3 and rails.offeredTypes(1959) == 2)
templateCatalog[templateName("standard", false)] = { yearFrom = 1930, yearTo = 1950 }
check("types: the end year is exclusive and the count stops at the first type that is not offered",
  rails.offeredTypes(1949) == 2 and rails.offeredTypes(1950) == 1 and rails.offeredTypes(1960) == 1)
reset()
templateCatalog[templateName("simple", false)] = nil
check("types: a missing first template offers nothing", rails.offeredTypes(2000) == 0)
reset()
check("catenary: a catenary version is offered in its first year", rails.hasCatenary(1, 1900) == true and rails.hasCatenary(1, 1899) == false)
check("catenary: a type without a catenary template has none", (function()
  templateCatalog[templateName("high_speed", true)] = nil
  return rails.hasCatenary(3, 2000) == false
end)())

-- The noise barrier of the game
reset()
check("barrier id: the wooden barrier until 1939", rails.barrierId(1939) == WOODEN)
check("barrier id: the concrete barrier from 1940", rails.barrierId(1940) == CONCRETE)
barrierCatalog[CONCRETE] = nil
check("barrier id: none when the game offers none in that year", rails.barrierId(1950) == nil)
reset()
check("has barrier: a list with a barrier", rails.hasBarrier({ { OTHER_DECORATION, true }, { WOODEN, false } }) == true)
check("has barrier: a list without one, an empty list and nil", rails.hasBarrier({ { OTHER_DECORATION, true } }) == false
  and rails.hasBarrier({}) == false and rails.hasBarrier(nil) == false)

-- The target of a track
local function edge(id, template, decorations, edgeType)
  edges[id] = { roadTemplate = template, edgeDecorations = decorations or {}, type = edgeType or 0 }
  return id
end

local function target(e, typeIndex, state, year, barrier)
  local template, same, decorations = rails.targeter(typeIndex, state, year, barrier)(e)
  return template, same, decorations
end

local STANDARD, STANDARD_CATENARY = templateName("standard", false), templateName("standard", true)
local SIMPLE_CATENARY, HIGH_SPEED = templateName("simple", true), templateName("high_speed", false)

reset()
local t, same, decorations = target(edge(1, STANDARD), 2, "keep", 1950, "keep")
check("target: a track that has the target template is already the target", t == STANDARD and same == true and decorations == nil, tostring(t))
t, same = target(edge(1, SIMPLE_CATENARY), 2, "keep", 1950, "keep")
check("target: the catenary of the track is kept", t == STANDARD_CATENARY and same == false, tostring(t))
t = target(edge(1, STANDARD), 2, "add", 1950, "keep")
check("target: Add gives the track a catenary", t == STANDARD_CATENARY, tostring(t))
t, same = target(edge(1, STANDARD_CATENARY), 2, "remove", 1950, "keep")
check("target: Remove takes the catenary off", t == STANDARD and same == false, tostring(t))
t = target(edge(1, STANDARD), 3, "keep", 1950, "keep")
check("target: a type that the game does not offer in the year gives no target", t == nil)
t = target(edge(1, "::/infrastructure/street/town/town_new_medium.street_template"), 2, "keep", 1950, "keep")
check("target: a template that is no track template gives no target", t == nil)
edges[2] = nil
t = target(2, 2, "keep", 1950, "keep")
check("target: an edge that cannot be read gives no target", t == nil)
t, same = target(edge(1, "station_noise_walls_1::/quiet_tracks/infrastructure/track/standard/standard.street_template"), 2, "keep", 1950, "keep")
check("target: a quiet track is swapped to the base template", t == STANDARD and same == false, tostring(t))

-- The noise barrier choice
reset()
t, same, decorations = target(edge(1, STANDARD, {}), 2, "keep", 1939, "add")
check("barrier add: a track without a barrier gets both sides, template unchanged but not the target yet",
  sameDecorations(decorations, { { WOODEN, false }, { WOODEN, true } }) and same == false, decorationsText(decorations))
t, same, decorations = target(edge(1, STANDARD, { { WOODEN, false } }), 2, "keep", 1939, "add")
check("barrier add: one side is completed", sameDecorations(decorations, { { WOODEN, false }, { WOODEN, true } }), decorationsText(decorations))
t, same, decorations = target(edge(1, STANDARD, { { CONCRETE, true } }), 2, "keep", 1939, "add")
check("barrier add: the barrier already on the track is the one that completes it",
  sameDecorations(decorations, { { CONCRETE, true }, { CONCRETE, false } }), decorationsText(decorations))
t, same, decorations = target(edge(1, STANDARD, { { OTHER_DECORATION, false } }), 2, "keep", 1939, "add")
check("barrier add: other decorations are kept",
  sameDecorations(decorations, { { OTHER_DECORATION, false }, { WOODEN, false }, { WOODEN, true } }), decorationsText(decorations))
t, same, decorations = target(edge(1, STANDARD, { { WOODEN, false }, { WOODEN, true } }), 2, "keep", 1939, "add")
check("barrier add: a track with both sides is already the target", decorations == nil and same == true)
t, same, decorations = target(edge(1, STANDARD, {}), 2, "keep", 1950, "add")
check("barrier add: the barrier of the year is the concrete one", sameDecorations(decorations, { { CONCRETE, false }, { CONCRETE, true } }), decorationsText(decorations))
barrierCatalog = {}
t, same, decorations = target(edge(1, STANDARD, {}), 2, "keep", 1950, "add")
check("barrier add: without a barrier in the game the decorations stay as they are", decorations == nil and same == true)
reset()
t, same, decorations = target(edge(1, STANDARD, { { WOODEN, false }, { WOODEN, true }, { OTHER_DECORATION, true } }), 2, "keep", 1939, "remove")
check("barrier remove: the barriers go and the other decorations stay", sameDecorations(decorations, { { OTHER_DECORATION, true } }) and same == false, decorationsText(decorations))
t, same, decorations = target(edge(1, STANDARD, { { WOODEN, true } }), 2, "keep", 1939, "remove")
check("barrier remove: a track with one side is cleared", sameDecorations(decorations, {}), decorationsText(decorations))
t, same, decorations = target(edge(1, STANDARD, { { OTHER_DECORATION, true } }), 2, "keep", 1939, "remove")
check("barrier remove: a track without a barrier is already the target", decorations == nil and same == true)
t, same, decorations = target(edge(1, STANDARD, {}, TUNNEL), 2, "keep", 1939, "add")
check("barrier add: a tunnel gets none", decorations == nil and same == true)
t, same, decorations = target(edge(1, STANDARD, { { WOODEN, true } }, TUNNEL), 2, "keep", 1939, "remove")
check("barrier remove: a tunnel is left alone", decorations == nil and same == true)
t, same, decorations = target(edge(1, SIMPLE_CATENARY, { { WOODEN, true } }), 2, "keep", 1939, "keep")
check("barrier keep: the decorations are left alone", decorations == nil and t == STANDARD_CATENARY and same == false)

-- Resolving a road type to a template of the game
reset()
local ROAD = "::/infrastructure/street/town/"
streetTemplates["all"] = {
  ROAD .. "town_new_large_trees.street_template",
  ROAD .. "town_old_large_trees.street_template",
}
streetTemplates[ROAD .. "town_new_large_trees.street_template"] = 100
streetTemplates[ROAD .. "town_old_large_trees.street_template"] = 101
templateCatalog = {}
local resolveCatalog = {
  [100] = { yearFrom = 1950, yearTo = 0 },
  [101] = { yearFrom = 0, yearTo = 1950 },
}
api.res.streetTemplateRep.get = function(id) return { availability = resolveCatalog[id] } end
local roadType = { bases = { "town_new_large", "town_old_large" } }
check("resolve: the first base that exists and is available wins", templates.resolve(roadType, "_trees", 1950) == ROAD .. "town_new_large_trees.street_template")
check("resolve: a base that is not available yet is skipped", templates.resolve(roadType, "_trees", 1949) == ROAD .. "town_old_large_trees.street_template")
check("resolve: nothing when no base is available", templates.resolve({ bases = { "town_new_large" } }, "_trees", 1949) == nil)
check("resolve: nothing for a suffix that no template has", templates.resolve(roadType, "_none", 1950) == nil)

support.finish("brush_rails")
