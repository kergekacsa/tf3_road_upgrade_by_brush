-- The six base track templates of the game: simple, standard and high speed, each with and without catenary. A track
-- with any other template (for example the quiet copies of Station Noise Barriers) is never changed.

local templates = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_templates.tl" as RubTemplates

local rails : RubRails = {}

rails.TYPES = { "simple", "standard", "high_speed" }

local PATH <const> = "infrastructure/track/"
local CATENARY_SUFFIX <const> = "_catenary"
local ENDING <const> = ".street_template"

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

function rails.parse(resName : string) : integer, boolean
	local path = withoutRoot(resName)
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

-- The target template of a track and whether the track has it already. nil when the track has no base template or the
-- target is not available yet.
function rails.targeter(typeIndex : integer, state : string, year : integer) : RubRailTarget
	return function(edge : integer) : string, boolean
		local ok, current = pcall(function() : string
			local be = api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
			return be.roadTemplate
		end)
		if not ok then return nil, false end
		local currentType, hasCatenary = rails.parse(current)
		if currentType == nil then return nil, false end
		local catenary = hasCatenary
		if state == "add" then catenary = true elseif state == "remove" then catenary = false end
		local target = rails.template(typeIndex, catenary)
		if not templates.isAvailable(target, year) then return nil, false end
		return target, withoutRoot(current) == withoutRoot(target)
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
