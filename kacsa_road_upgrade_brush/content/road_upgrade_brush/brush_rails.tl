-- The six base track templates of the game: simple, standard and high speed, each with and without catenary, and their
-- quiet copies from Station Noise Barriers. A track with any other template is never changed.

local templates = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_templates.tl" as RubTemplates

local rails : RubRails = {}

rails.TYPES = { "simple", "standard", "high_speed" }

local PATH <const> = "infrastructure/track/"
local CATENARY_SUFFIX <const> = "_catenary"
local ENDING <const> = ".street_template"
-- A quiet copy of a track template: "<mod id>::/quiet_tracks/<original path>".
local QUIET_PATTERN <const> = "^[%w_]+::/quiet_tracks/(.+)$"
-- The noise barriers of the game for tracks: wooden before 1940, concrete after.
local BARRIER_NAMES : {string} = {
	"::/infrastructure/edge_addons/barrier_track_a.edge",
	"::/infrastructure/edge_addons/barrier_track_b.edge",
}

local function withoutRoot(resName : string) : string
	return (string.gsub(resName or "", "^::/", ""))
end

local function pathOf(typeIndex : integer, catenary : boolean) : string
	local trackType = rails.TYPES[typeIndex]
	return PATH .. trackType .. "/" .. trackType .. (catenary and CATENARY_SUFFIX or "") .. ENDING
end

function rails.template(typeIndex : integer, catenary : boolean) : string
	return "::/" .. pathOf(typeIndex, catenary)
end

function rails.isQuiet(resName : string) : boolean
	return string.match(resName or "", QUIET_PATTERN) ~= nil
end

function rails.parse(resName : string) : integer, boolean
	local path = string.match(resName or "", QUIET_PATTERN) or withoutRoot(resName)
	for i = 1, #rails.TYPES do
		if path == pathOf(i, false) then return i, false end
		if path == pathOf(i, true) then return i, true end
	end
	return nil, false
end

-- The number of track types the game offers in the year, counted from the first.
function rails.offeredTypes(year : integer) : integer
	local count = 0
	while count < #rails.TYPES and templates.isAvailable(rails.template(count + 1, false), year) do
		count = count + 1
	end
	return count
end

function rails.hasCatenary(typeIndex : integer, year : integer) : boolean
	return templates.isAvailable(rails.template(typeIndex, true), year)
end

local function barrierIds() : {integer}
	local ids : {integer} = {}
	for _, name in ipairs(BARRIER_NAMES) do
		local id = api.res.edgeDecorationRep.find(name)
		if id >= 0 then ids[#ids + 1] = id end
	end
	return ids
end

local function isBarrier(id : integer, ids : {integer}) : boolean
	for _, barrier in ipairs(ids) do
		if id == barrier then return true end
	end
	return false
end

function rails.hasBarrier(decorations : {{integer, boolean}}) : boolean
	local ids = barrierIds()
	for _, d in ipairs(decorations or {}) do
		if isBarrier(d[1], ids) then return true end
	end
	return false
end

-- The id of the track noise barrier that the game offers in the year. nil when it offers none.
function rails.barrierId(year : integer) : integer
	for _, id in ipairs(barrierIds()) do
		local availability = api.res.edgeDecorationRep.get(id).availability
		local from = availability ~= nil and availability.yearFrom or 0
		local to = availability ~= nil and availability.yearTo or 0
		if (from == 0 or year >= from) and (to == 0 or year < to) then return id end
	end
	return nil
end

-- Which sides of a decoration list (false, true) hold a barrier, and the id of a barrier found on a side.
local function barrierSides(decorations : {{integer, boolean}}, ids : {integer}) : boolean, boolean, integer
	local side0, side1 = false, false
	local found : integer = nil
	for _, d in ipairs(decorations) do
		if isBarrier(d[1], ids) then
			found = d[1]
			if d[2] then side1 = true else side0 = true end
		end
	end
	return side0, side1, found
end

local g_missingLogged = false

-- The complete decoration list that gives a track the barrier state, or nil when it has it already or a tunnel cannot
-- carry a barrier. Add completes the sides that lack a barrier, with the barrier already on the other side.
local function barrierChange(be : Engine.Component.BaseEdge, barrier : string, year : integer) : {{integer, boolean}}
	if barrier == "keep" or be.type == api.type.enum.BaseEdgeType.TUNNEL then return nil end
	local have = be.edgeDecorations or {}
	local ids = barrierIds()
	local side0, side1, existing = barrierSides(have, ids)
	local result : {{integer, boolean}} = {}
	if barrier == "add" then
		if side0 and side1 then return nil end
		local id = existing or rails.barrierId(year)
		if id == nil then
			if not g_missingLogged then
				g_missingLogged = true
				pcall(function() log.message("[BrushUpgrade] no track noise barrier found in the game: Add leaves the decorations as they are") end)
			end
			return nil
		end
		for _, d in ipairs(have) do result[#result + 1] = d end
		if not side0 then result[#result + 1] = { id, false } end
		if not side1 then result[#result + 1] = { id, true } end
		return result
	end
	if side0 or side1 then
		for _, d in ipairs(have) do
			if not isBarrier(d[1], ids) then result[#result + 1] = d end
		end
		return result
	end
	return nil
end

-- The target template of a track, whether the track has it already, and the decoration list to set (nil: leave the
-- decorations). The target is always a base template, also for a quiet track. The template is nil when the track has
-- none of the templates or the target is not available.
function rails.targeter(typeIndex : integer, state : string, year : integer, barrier : string) : RubRailTarget
	return function(edge : integer) : string, boolean, {{integer, boolean}}
		local ok, be = pcall(function() : Engine.Component.BaseEdge
			return api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
		end)
		if not ok or be == nil then return nil, false, nil end
		local current = be.roadTemplate
		local currentType, hasCatenary = rails.parse(current)
		if currentType == nil then return nil, false, nil end
		local catenary = hasCatenary
		if state == "add" then catenary = true elseif state == "remove" then catenary = false end
		local target = rails.template(typeIndex, catenary)
		if not templates.isAvailable(target, year) then return nil, false, nil end
		local decorations = barrierChange(be, barrier, year)
		return target, decorations == nil and withoutRoot(current) == withoutRoot(target), decorations
	end
end

function rails.typeName(typeIndex : integer) : string
	local fallback = rails.TYPES[typeIndex]
	local ok, name = pcall(function() : string
		local id = api.res.streetTemplateRep.find(rails.template(typeIndex, false))
		return api.res.streetTemplateRep.get(id).description.name
	end)
	if ok and name ~= nil and name ~= "" then return name end
	return fallback
end

return rails
