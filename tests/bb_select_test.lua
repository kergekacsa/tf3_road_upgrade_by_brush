-- Tests of the selection rules (bb_select.tl): which roads and tracks the brush may take, and the reason for each skip.

local support = dofile((arg[0]:match("^(.*)[/\\][^/\\]*$") or ".") .. "/support.lua")
local check = support.check

support.installRequire({})
local sel = dofile(support.buildDir .. "/bb_select.lua")
local rails = dofile(support.buildDir .. "/brush_rails.lua")

local PLAYER, OTHER_PLAYER = 7, 8
local ctx = { player = PLAYER, hq = -1 }
local filters = sel.defaultFilters()
filters.tracks = true

local trackTemplate = rails.template(2, false)

-- A description of an edge as bb_gather makes it.
local function edge(fields)
  local d = {
    entity = 1, isEdge = true, isStreet = false, owner = PLAYER, parentConstruction = -1, template = trackTemplate,
    objects = {}, isTunnel = false, tramOnly = false, industryRoad = false, gone = false,
  }
  for key, value in pairs(fields or {}) do d[key] = value end
  return d
end

local function classify(fields)
  local c = sel.classify(edge(fields), filters, ctx)
  return c.kind, c.reason
end

local kind, reason = classify({})
check("a track of the player is selectable", kind == "track" and reason == nil, tostring(reason))

kind, reason = classify({ owner = -1 })
check("a track without an owner is selectable", kind == "track" and reason == nil, tostring(reason))

kind, reason = classify({ owner = OTHER_PLAYER })
check("a track of another player is skipped as foreign", kind == "track" and reason == "foreign", tostring(reason))

kind, reason = classify({ owner = -1, parentConstruction = 12 })
check("a track without an owner that belongs to a construction is skipped as part of it", reason == "part", tostring(reason))

kind, reason = classify({ owner = -1, industryRoad = true })
check("a track without an owner at an industry is skipped", reason == "industry", tostring(reason))

kind, reason = classify({ owner = -1, template = "::/infrastructure/track/no_such_track.street_template" })
check("a track without an owner whose template is none of the six is skipped as another track type", reason == "track_type", tostring(reason))

kind, reason = classify({ owner = -1, isTunnel = true })
check("a tunnel track without an owner follows the underground filter", reason == "underground", tostring(reason))

filters.tracks = false
kind, reason = classify({ owner = -1 })
check("a track without an owner follows the track filter", reason == "filtered", tostring(reason))
filters.tracks = true

kind, reason = classify({ isStreet = true, owner = -1, template = "::/infrastructure/street/town/town_new_medium.street_template" })
check("a road without an owner is selectable", kind == "road" and reason == nil, tostring(reason))

kind, reason = classify({ isEdge = false, owner = -1, stations = 0, depots = 0, townBuildings = 0, industries = 0, frozen = 0 })
check("a construction without an owner is still not yours", reason == "not_player", tostring(reason))

-- The other hard rules and the filters of roads and tracks
kind, reason = classify({ gone = true })
check("an edge that is gone is skipped as gone", reason == "gone", tostring(reason))

kind, reason = classify({ isStreet = true, tramOnly = true, template = "::/infrastructure/street/town/town_new_medium.street_template" })
check("a tram-only road is skipped as a tram track", kind == "road" and reason == "tram_only", tostring(reason))

filters.surface = false
kind, reason = classify({})
check("with the underground view on, a track on the ground is skipped as on the ground", reason == "surface", tostring(reason))
filters.underground = true
kind, reason = classify({ isTunnel = true })
check("with the underground view on, a tunnel track is selectable", reason == nil, tostring(reason))
filters.surface, filters.underground = true, false

-- Constructions
local function construction(fields)
  local d = {
    entity = 60, isEdge = false, owner = PLAYER, parentConstruction = -1, stations = 0, depots = 0, industries = 0,
    townBuildings = 0, frozen = 0, gone = false,
  }
  for key, value in pairs(fields or {}) do d[key] = value end
  return d
end

local function classifyConstruction(fields, filterFields, context)
  local f = sel.defaultFilters()
  for key, value in pairs(filterFields or {}) do f[key] = value end
  local c = sel.classify(construction(fields), f, context or ctx)
  return c.kind, c.reason
end

kind, reason = classifyConstruction({ stations = 1 })
check("a station of the player is skipped by the station filter", kind == "station" and reason == "filtered", tostring(reason))
kind, reason = classifyConstruction({ stations = 1 }, { stations = true })
check("a station of the player is selectable when the station filter is on", kind == "station" and reason == nil, tostring(reason))
kind, reason = classifyConstruction({ depots = 1 })
check("a depot counts as a station", kind == "station" and reason == "filtered", tostring(reason))
kind, reason = classifyConstruction({})
check("another construction of the player is an asset, skipped by the asset filter", kind == "asset" and reason == "filtered", tostring(reason))
kind, reason = classifyConstruction({}, { assets = true })
check("an asset is selectable when the asset filter is on", kind == "asset" and reason == nil, tostring(reason))
kind, reason = classifyConstruction({ owner = -1, townBuildings = 1 })
check("a town building without an owner is skipped by the town building filter", kind == "town_building" and reason == "filtered", tostring(reason))
kind, reason = classifyConstruction({ owner = -1, townBuildings = 1 }, { townBuildings = true })
check("a town building is selectable when its filter is on", kind == "town_building" and reason == nil, tostring(reason))
kind, reason = classifyConstruction({ owner = -1, townBuildings = 1, stations = 1 }, { townBuildings = true })
check("a construction with a station and no owner is not a town building", reason == "not_player", tostring(reason))
kind, reason = classifyConstruction({ industries = 1 }, { assets = true })
check("an industry is skipped as industry", kind == "industry" and reason == "industry", tostring(reason))
kind, reason = classifyConstruction({ owner = OTHER_PLAYER, stations = 1 }, { stations = true })
check("a construction of another player is skipped as foreign", reason == "foreign", tostring(reason))
kind, reason = classifyConstruction({ entity = 50 }, { assets = true }, { player = PLAYER, hq = 50 })
check("the headquarters is skipped as HQ", reason == "hq", tostring(reason))
kind, reason = classifyConstruction({ entity = 51 }, { assets = true }, { player = PLAYER, hq = 50 })
check("another construction is not the headquarters", reason == nil, tostring(reason))

-- The stroke
local function candidate(entity, kindName, reasonName, objects)
  return { entity = entity, kind = kindName or "road", reason = reasonName, objects = objects or 0 }
end

local stroke = sel.newStroke()
check("stroke: a skip is recorded and counted", sel.add(stroke, candidate(1, "road", "filtered")) == false and stroke.reasonCounts.filtered == 1 and stroke.skipped[1] == "filtered")
check("stroke: the same skip is counted once", sel.add(stroke, candidate(1, "road", "filtered")) == false and stroke.reasonCounts.filtered == 1)
check("stroke: a keep replaces an earlier skip of the same entity",
  sel.add(stroke, candidate(1, "road", nil, 2)) == true and stroke.reasonCounts.filtered == 0 and stroke.skipped[1] == nil and sel.count(stroke) == 1)
check("stroke: a kept entity is not added again, and a later skip does not touch it",
  sel.add(stroke, candidate(1, "road", nil, 2)) == false and sel.add(stroke, candidate(1, "road", "filtered")) == false and sel.count(stroke) == 1 and stroke.reasonCounts.filtered == 0)
sel.add(stroke, candidate(2, "road", nil, 1))
sel.add(stroke, candidate(3, "track", nil, 0))
sel.add(stroke, candidate(4, "track", "part"))
sel.add(stroke, candidate(5, "road", "filtered"))
sel.add(stroke, candidate(6, "road", "filtered"))
check("stroke: the kinds and the objects are counted", stroke.kindCounts.road == 2 and stroke.kindCounts.track == 1 and stroke.objects == 3)
local lines = sel.describe(stroke)
check("describe: the kept kinds and the skip reasons, in the order of the toolbar",
  lines[1] == "Selected: 2 roads, 1 tracks (+3 signals/stops)" and lines[2] == "Skipped: 2 filtered, 1 part of a construction" and #lines == 2,
  table.concat(lines, " / "))
check("describe: an empty stroke says nothing is selected", sel.describe(sel.newStroke())[1] == "Nothing selected")
check("stroke: add ignores a candidate without an entity", sel.add(stroke, nil) == false and sel.add(stroke, { kind = "road" }) == false)
check("stroke: remove drops kept entities, counts each once and ignores unknown ones",
  sel.remove(stroke, { 1, 1, 3, 99 }) == 2 and sel.count(stroke) == 1 and stroke.kindCounts.road == 1 and stroke.kindCounts.track == 0 and stroke.objects == 1)
check("stroke: the entities that stay are listed in order", #sel.entities(stroke) == 1 and sel.entities(stroke)[1] == 2)
check("stroke: remove of nothing returns 0", sel.remove(stroke, {}) == 0 and sel.remove(stroke, nil) == 0)

local full = sel.newStroke()
for i = 1, sel.STROKE_CAP do sel.add(full, candidate(i, "road")) end
check("stroke: up to STROKE_CAP entities are kept and the stroke is not capped yet", sel.count(full) == sel.STROKE_CAP and full.capped == false)
check("stroke: the entity after the cap is refused and the stroke is capped", sel.add(full, candidate(sel.STROKE_CAP + 1, "road")) == false and full.capped == true and sel.count(full) == sel.STROKE_CAP)
check("stroke: a skip is still recorded after the cap", sel.add(full, candidate(sel.STROKE_CAP + 2, "road", "filtered")) == false and full.reasonCounts.filtered == 1)
check("describe: a capped stroke names the limit", sel.describe(full)[#sel.describe(full)] == "Limit of " .. sel.STROKE_CAP .. " reached")
_G._ = function(text) return text end
check("limit lines: a capped stroke has one line and another has none", #sel.limitLines(full) == 1 and #sel.limitLines(stroke) == 0)
sel.remove(full, { 1 })
check("stroke: removing one entity below the cap clears the capped flag", full.capped == false and sel.count(full) == sel.STROKE_CAP - 1)

-- The filters of the toolbar and the menu
local fromMenu = sel.paramFilters({ r = 2, t = 1, x = 3 }, { roads = "r", tracks = "t", assets = "x", stations = "missing" })
check("param filters: 2 is on, 1 is off, any other value or a missing key is left out",
  fromMenu.roads == true and fromMenu.tracks == false and fromMenu.assets == nil and fromMenu.stations == nil)
check("param filters: nil params give nothing", next(sel.paramFilters(nil, { roads = "r" })) == nil)
check("checkbox: 2 is on, 1 is off, anything else is the default", sel.checkboxOn(2, false) == true and sel.checkboxOn(1, true) == false and sel.checkboxOn(0, true) == true and sel.checkboxOn(0, false) == false)

local defaults = sel.defaultFilters()
local resolved, unknown = sel.resolveFilters({ roads = false, tracks = true }, {}, defaults)
check("resolve filters: the value the toolbar showed wins over the default", resolved.roads == false and resolved.tracks == true and #unknown == 0)
resolved, unknown = sel.resolveFilters(nil, { menuA = { roads = true }, menuB = { roads = true } }, defaults)
check("resolve filters: toggles that agree with the default keep it", resolved.roads == true and #unknown == 0)
resolved, unknown = sel.resolveFilters(nil, { menuA = { roads = true }, menuB = { roads = false } }, defaults)
check("resolve filters: toggles that disagree turn the field off and list it", resolved.roads == false and #unknown == 1 and unknown[1] == "roads", tostring(unknown[1]))
resolved = sel.resolveFilters(nil, {}, defaults)
check("resolve filters: without a shown value or a toggle every field has its default", resolved.roads == true and resolved.tracks == false and resolved.underground == false)

local quietTemplate ="station_noise_walls_1::/quiet_tracks/" .. trackTemplate:gsub("^::/", "")

kind, reason = classify({ template = quietTemplate, parentConstruction = 12 })
check("a quiet track of a station is skipped as part of it", kind == "track" and reason == "part", tostring(reason))

kind, reason = classify({ template = quietTemplate })
check("a quiet track outside any construction counts as its base track type and is selectable", kind == "track" and reason == nil, tostring(reason))

support.finish("bb_select")
