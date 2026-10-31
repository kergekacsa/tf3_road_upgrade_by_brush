-- Options of the brush tool: the single-click tool's menu params without the one-way road types. The underground button (key undergroundMode) is the single-click tool's own. The rules and templates are
-- the single-click tool's.

local config = ug_require "/road_upgrade_suite/config.tl" as RusConfig
local options = ug_require "/road_upgrade_suite/options.tl" as RusOptions
local rules = ug_require "/road_upgrade_suite/rules.tl" as RusRules
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local brushStyle = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/brush_style.tl" as BrushStyle

local brushOptions : BrushOptions = {}

local ROAD_TYPE_KEY <const> = "rus_roadType"
local PROBLEM_KEY_PREFIX <const> = "rus_problem_"
local ONE_WAY_MARK <const> = "one_way"
local KEPT_KEYS : {string : boolean} = {
	rus_busLane = true, rus_tram = true, rus_catenary = true, rus_trees = true, rus_barrier = true, rus_lock = true, undergroundMode = true,
}
local REMOVE_BUILDINGS_KEY <const> = "brush_upgrade_remove_buildings"
local CHECKBOX_NO <const> = 1
local UNDERGROUND_KEY <const> = "undergroundMode"
local UNDERGROUND_YES <const> = 1

local function isOneWay(roadType : RusRoadType) : boolean
	return string.find(roadType.name, ONE_WAY_MARK, 1, true) ~= nil
end

-- The brush offers the two-way road types. config.lua lists them before the one-way ones, so their
-- index in the combo box is their index in config.roadTypes.
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
		tooltip = _("Buildings that block the new road are demolished, as with the single-click tool. A placed asset that blocks the road is removed on the first retry, and the last retry forces the build. Off: such roads are skipped."),
		values = { _("No"), _("Yes") },
		defaultIndex = 2,
		uiType = api.type["enum"].ScriptParamType.CheckBox,
		yearFrom = 0,
		yearTo = 0,
		resetOnMenuClose = false,
	}
end

-- Tunnels have no alley trees and no noise barriers: with the underground button on, the two boxes are disabled.
local function disabledUnderground(param : ConstructionMenuParam)
	local inner = param.checkEnabledFn
	param.checkEnabledFn = function(params : {string : number}) : ConstructionMenuParam.CheckEnabledResult
		if params[UNDERGROUND_KEY] == UNDERGROUND_YES then return "Disabled" end
		if inner ~= nil then return inner(params) end
		return "Enabled"
	end
end

-- A note about an impossible combination: the text in red, as plain wrapped text like the status chip.
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
			if param.key == "rus_trees" or param.key == "rus_barrier" then disabledUnderground(param) end
			result[#result + 1] = param
		elseif string.sub(param.key, 1, #PROBLEM_KEY_PREFIX) == PROBLEM_KEY_PREFIX then
			errorNote(param, noteGroup)
			result[#result + 1] = param
		end
	end
	result[#result + 1] = removeBuildingsParam()
	return result
end

function brushOptions.extras(params : {string : number}) : BrushExtras
	local choices = options.fromParams(params or {})
	return { busLane = choices.busLane, tram = choices.tram, catenary = choices.catenary, lock = choices.lock }
end

function brushOptions.removeBuildings(params : {string : number}) : boolean
	return params == nil or params[REMOVE_BUILDINGS_KEY] ~= CHECKBOX_NO
end

function brushOptions.template(params : {string : number}) : string, string
	local choices = options.fromParams(params or {})
	-- a tunnel has neither alley trees nor noise barriers, whatever the two boxes show
	if choices.underground then
		choices.trees = false
		choices.barrier = false
	end
	-- the menu remembers values by key, so a one-way type chosen in the single-click tool can arrive here
	if choices.roadType > offeredRoadTypes() then
		return nil, _("Choose a road type")
	end
	local year = api.engine.util.getYear()
	local problems = rules.check(choices, year)
	if #problems > 0 then
		return nil, _("rus_problem_" .. problems[1])
	end
	return rules.targetTemplate(choices, year), nil
end

return brushOptions
