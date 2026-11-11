-- Based on 'Road Upgrade All in One' by kurowasiichi (mod.io 6487083).
-- Combo boxes and buttons store the 1-based index of the chosen value.

local config = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_config.tl" as RubConfig
local rules = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_rules.tl" as RubRules
local construction_react_util = ug_require "::/gui/construction/construction_react_util.tl" as ConstructionReactUtil

local options : RubOptions = {}

--- First year with tram catenary; same value as in gui/construction/tools/tram_track_tool.res.lua.
local CatenaryYearFrom <const> = 1910

local Problems <const> : {RubRules.Problem} = { "treesAndBarrier", "treesCountry", "noTemplate", "busTramLanes" }

-- The values of an add-on state param, in the order of the combo box.
local ADDON_STATES <const> : {string} = { "keep", "add", "remove" }

-- The values of the lock param, in the order of the combo box.
local LOCK_STATES <const> : {string} = { "keep", "lock", "unlock" }

-- The road type combo box lists Keep before the road types: its value is an index in config.roadTypes plus one.
local KEEP_ROAD_TYPE <const> = 1

local function stateOf(params : {string : number}, key : string) : string
	return ADDON_STATES[math.floor(params[key] or 1)] or ADDON_STATES[1]
end

function options.fromParams(params : {string : number}) : RubChoices
	local roadType = math.floor(params["rub_roadType"] or KEEP_ROAD_TYPE) - 1
	if config.roadTypes[roadType] == nil then
		roadType = 0
	end
	local tram = stateOf(params, "rub_tram")
	return {
		roadType = roadType,
		busLane = stateOf(params, "rub_busLane"),
		tram = tram,
		-- the catenary parameter exists only from CatenaryYearFrom on, and it is hidden while the tram track is removed
		catenary = tram == "remove" and "keep" or stateOf(params, "rub_catenary"),
		trees = stateOf(params, "rub_trees"),
		barrier = stateOf(params, "rub_barrier"),
		lock = LOCK_STATES[math.floor(params["rub_lock"] or 1)] or LOCK_STATES[1],
		underground = params["undergroundMode"] == 1,
	}
end

local function stateParam(key : string, name? : string) : ConstructionMenuParam
	return {
		key = key,
		name = name or _(key .. "_name"),
		tooltip = _(key .. "_tooltip"),
		values = { _("rub_lock_keep"), _("rub_state_add"), _("rub_state_remove") },
		defaultIndex = 1,
		uiType = api.type["enum"].ScriptParamType.ComboBox,
		yearFrom = 0,
		yearTo = 0,
		resetOnMenuClose = false,
	}
end

local function catenaryParam() : ConstructionMenuParam
	local param = stateParam("rub_catenary", _("Catenary"))
	param.yearFrom = CatenaryYearFrom
	param.checkEnabledFn = function(params : {string : number}) : ConstructionMenuParam.CheckEnabledResult
		return stateOf(params, "rub_tram") == "remove" and "Hidden" or "Enabled"
	end
	return param
end

local function problemParam(problem : RubRules.Problem) : ConstructionMenuParam
	return {
		key = "rub_problem_" .. problem,
		name = _("rub_problem_name"),
		values = { _("rub_problem_" .. problem) },
		defaultIndex = 1,
		uiType = api.type["enum"].ScriptParamType.Button,
		yearFrom = 0,
		yearTo = 0,
		checkEnabledFn = function(params : {string : number}) : ConstructionMenuParam.CheckEnabledResult
			for __, p in ipairs(rules.check(options.fromParams(params), api.engine.util.getYear())) do
				if p == problem then
					return "Disabled"
				end
			end
			return "Hidden"
		end,
	}
end

function options.params() : {ConstructionMenuParam}
	local roadTypeNames : {string} = { _("rub_lock_keep") }
	for __, roadType in ipairs(config.roadTypes) do
		roadTypeNames[#roadTypeNames + 1] = _(roadType.name)
	end

	local result : {ConstructionMenuParam} = {
		{
			key = "rub_roadType",
			name = _("rub_roadType_name"),
			tooltip = _("rub_roadType_tooltip"),
			values = roadTypeNames,
			defaultIndex = KEEP_ROAD_TYPE,
			uiType = api.type["enum"].ScriptParamType.ComboBox,
			yearFrom = 0,
			yearTo = 0,
		},
		stateParam("rub_busLane"),
		stateParam("rub_tram"),
		catenaryParam(),
		stateParam("rub_trees"),
		stateParam("rub_barrier"),
		{
			key = "rub_lock",
			name = _("rub_lock_name"),
			tooltip = _("rub_lock_tooltip"),
			values = { _("rub_lock_keep"), _("rub_lock_lock"), _("rub_lock_unlock") },
			defaultIndex = 1,
			uiType = api.type["enum"].ScriptParamType.ComboBox,
			yearFrom = 0,
			yearTo = 0,
			resetOnMenuClose = false,
		},
	}
	for __, problem in ipairs(Problems) do
		result[#result + 1] = problemParam(problem)
	end
	result[#result + 1] = construction_react_util.makeUndergroundParam(function(value : integer, __ : integer, ___ : boolean) : integer
		return (value % 2) + 1
	end)
	return result
end

return options
