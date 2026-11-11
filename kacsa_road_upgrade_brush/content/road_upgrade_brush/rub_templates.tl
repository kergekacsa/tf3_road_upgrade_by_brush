-- Based on 'Road Upgrade All in One' by kurowasiichi (mod.io 6487083).

local templates : RubTemplates = {}

--- base name ("town_new_large_trees") -> resource name in streetTemplateRep
local byBaseName : {string : string} = nil

local function baseName(resName : string) : string
	local name = string.match(resName, "([^/]+)$") or resName
	name = string.gsub(name, "%.lua$", "")
	name = string.gsub(name, "%.street_template$", "")
	return name
end

templates.baseName = baseName

local function lookup(name : string) : string
	if byBaseName == nil then
		byBaseName = {}
		for _, resName in pairs(api.res.streetTemplateRep.getAll(true)) do
			byBaseName[baseName(resName)] = resName
		end
	end
	return byBaseName[name]
end

local function isAvailable(resName : string, year : integer) : boolean
	local id = api.res.streetTemplateRep.find(resName)
	if id < 0 then
		return false
	end
	local availability = api.res.streetTemplateRep.get(id).availability
	if availability == nil then
		return true
	end
	local from = availability.yearFrom or 0
	local to = availability.yearTo or 0
	return (from == 0 or year >= from) and (to == 0 or year < to)
end

templates.isAvailable = isAvailable
templates.find = lookup

function templates.resolve(roadType : RubRoadType, suffix : string, year : integer) : string
	for _, base in ipairs(roadType.bases) do
		local resName = lookup(base .. suffix)
		if resName ~= nil and isAvailable(resName, year) then
			return resName
		end
	end
	return nil
end

return templates
