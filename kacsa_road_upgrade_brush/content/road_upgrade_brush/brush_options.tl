-- Options of the brush tool: the menu params of the rub_options module without the one-way road types.
-- The underground button (key undergroundMode) is the base game's.

local config = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_config.tl" as RubConfig
local options = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_options.tl" as RubOptions
local rules = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_rules.tl" as RubRules
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local brushStyle = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/brush_style.tl" as RubStyle

local brushOptions : RubBrushOptions = {}

local ROAD_TYPE_KEY <const> = "rub_roadType"
local PROBLEM_KEY_PREFIX <const> = "rub_problem_"
local ONE_WAY_MARK <const> = "one_way"
local KEPT_KEYS : {string : boolean} = {
	rub_busLane = true, rub_tram = true, rub_catenary = true, rub_trees = true, rub_barrier = true, rub_lock = true, undergroundMode = true,
}
local REMOVE_BUILDINGS_KEY <const> = "brush_upgrade_remove_buildings"
local CHECKBOX_NO <const> = 1
local UNDERGROUND_KEY <const> = "undergroundMode"
local UNDERGROUND_YES <const> = 1

local function isOneWay(roadType : RubRoadType) : boolean
	return string.find(roadType.name, ONE_WAY_MARK, 1, true) ~= nil
end

-- config.roadTypes lists the two-way road types before the one-way ones. A combo box index is an index in config.roadTypes.
local function offeredRoadTypes() : integer
	local count = 0
	for _, roadType in ipairs(config.roadTypes) do
		if isOneWay(roadType) then break end
		count = count + 1
	end
	return count
end

local function removeBuildingsParam() : ConstructionMenuParam
	return {
		key = REMOVE_BUILDINGS_KEY,
		name = _("Remove buildings in the way"),
		tooltip = _("Buildings that block the new road are demolished. A placed asset that blocks the road is removed on the first retry, and the last retry forces the build. Off: such roads are skipped."),
		values = { _("No"), _("Yes") },
		defaultIndex = 2,
		uiType = api.type["enum"].ScriptParamType.CheckBox,
		yearFrom = 0,
		yearTo = 0,
		resetOnMenuClose = false,
	}
end

-- Tunnels have no alley trees and no noise barriers.
local function disabledUnderground(param : ConstructionMenuParam)
	local inner = param.checkEnabledFn
	param.checkEnabledFn = function(params : {string : number}) : ConstructionMenuParam.CheckEnabledResult
		if params[UNDERGROUND_KEY] == UNDERGROUND_YES then return "Disabled" end
		if inner ~= nil then return inner(params) end
		return "Enabled"
	end
end

local function errorNote(param : ConstructionMenuParam, noteGroup : string)
	local message = param.values[1]
	param.group = noteGroup
	param.hideLabel = true
	param.makeCompactButtonFn = function(_value : number) : TreeNodeId
		return builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = { builtin.TextView{ meta = brushStyle.meta("font-scale-body", "error"), text = message } },
		}
	end
end

function brushOptions.params(noteGroup : string) : {ConstructionMenuParam}
	local offered = offeredRoadTypes()
	local result : {ConstructionMenuParam} = {}
	for _, param in ipairs(options.params()) do
		if param.key == ROAD_TYPE_KEY then
			local values : {string} = {}
			for i = 1, offered do
				values[i] = param.values[i]
			end
			param.values = values
			result[#result + 1] = param
		elseif KEPT_KEYS[param.key] then
			if param.key == "rub_trees" or param.key == "rub_barrier" then disabledUnderground(param) end
			result[#result + 1] = param
		elseif string.sub(param.key, 1, #PROBLEM_KEY_PREFIX) == PROBLEM_KEY_PREFIX then
			errorNote(param, noteGroup)
			result[#result + 1] = param
		end
	end
	result[#result + 1] = removeBuildingsParam()
	return result
end

function brushOptions.extras(params : {string : number}) : RubExtras
	local choices = options.fromParams(params or {})
	return { busLane = choices.busLane, tram = choices.tram, catenary = choices.catenary, lock = choices.lock }
end

function brushOptions.removeBuildings(params : {string : number}) : boolean
	return params == nil or params[REMOVE_BUILDINGS_KEY] ~= CHECKBOX_NO
end

function brushOptions.template(params : {string : number}) : string, string
	local choices = options.fromParams(params or {})
	if choices.underground then
		choices.trees = false
		choices.barrier = false
	end
	-- The menu remembers values by key: a remembered road type can lie outside the offered ones.
	if choices.roadType > offeredRoadTypes() then
		return nil, _("Choose a road type")
	end
	local year = api.engine.util.getYear()
	local problems = rules.check(choices, year)
	if #problems > 0 then
		return nil, _("rub_chip_" .. problems[1])
	end
	return rules.targetTemplate(choices, year), nil
end

return brushOptions
