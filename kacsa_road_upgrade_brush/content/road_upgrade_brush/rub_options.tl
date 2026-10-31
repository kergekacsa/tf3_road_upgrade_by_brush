-- Based on 'Road Upgrade All in One' by kurowasiichi (mod.io 6487083).
-- Check boxes and buttons store the 1-based index of the chosen value (check boxes: 1 = no, 2 = yes).

local config = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_config.tl" as RubConfig
local rules = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_rules.tl" as RubRules
local construction_react_util = ug_require "::/gui/construction/construction_react_util.tl" as ConstructionReactUtil

local options : RubOptions = {}

--- First year with tram catenary; same value as in gui/construction/tools/tram_track_tool.res.lua.
local CatenaryYearFrom <const> = 1910

local Problems <const> : {RubRules.Problem} = { "treesAndBarrier", "treesCountry", "noTemplate", "busTramLanes" }

local DefaultRoadType <const> = "rub_type_town_medium"

local function defaultRoadTypeIndex() : integer
	for i, roadType in ipairs(config.roadTypes) do
		if roadType.name == DefaultRoadType then
			return i
		end
	end
	return 1
end

local function isYes(params : {string : number}, key : string) : boolean
	return params[key] == 2
end

function options.fromParams(params : {string : number}) : RubChoices
	local roadTypeIndex = math.floor(params["rub_roadType"] or defaultRoadTypeIndex())
	if config.roadTypes[roadTypeIndex] == nil then
		roadTypeIndex = defaultRoadTypeIndex()
	end
	local tram = isYes(params, "rub_tram")
	return {
		roadType = roadTypeIndex,
		busLane = isYes(params, "rub_busLane"),
		tram = tram,
		-- the catenary parameter exists only from CatenaryYearFrom on
		catenary = tram and params["rub_catenary"] == 1,
		trees = isYes(params, "rub_trees"),
		barrier = isYes(params, "rub_barrier"),
		lock = isYes(params, "rub_lock"),
		symmetric = true,
		underground = params["undergroundMode"] == 1,
	}
end

local function checkBox(key : string, checkEnabledFn? : function(params : {string : number}) : ConstructionMenuParam.CheckEnabledResult) : ConstructionMenuParam
	return {
		key = key,
		name = _(key .. "_name"),
		tooltip = _(key .. "_tooltip"),
		values = { _("No"), _("Yes") },
		defaultIndex = 1,
		uiType = api.type["enum"].ScriptParamType.CheckBox,
		yearFrom = 0,
		yearTo = 0,
		checkEnabledFn = checkEnabledFn,
		resetOnMenuClose = false,
	}
end

local function isCountry(params : {string : number}) : boolean
	local choices = options.fromParams(params)
	return config.roadTypes[choices.roadType].country
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
	local roadTypeNames : {string} = {}
	for __, roadType in ipairs(config.roadTypes) do
		roadTypeNames[#roadTypeNames + 1] = _(roadType.name)
	end

	local result : {ConstructionMenuParam} = {
		{
			key = "rub_roadType",
			name = _("rub_roadType_name"),
			tooltip = _("rub_roadType_tooltip"),
			values = roadTypeNames,
			defaultIndex = defaultRoadTypeIndex(),
			uiType = api.type["enum"].ScriptParamType.ComboBox,
			yearFrom = 0,
			yearTo = 0,
		},
		checkBox("rub_busLane"),
		checkBox("rub_tram"),
		{
			key = "rub_catenary",
			name = _("Catenary"),
			values = { _("Yes"), _("No") },
			defaultIndex = 1,
			displayMode = api.type["enum"].ScriptParamDisplayMode.Horizontal,
			uiType = api.type["enum"].ScriptParamType.Button,
			yearFrom = CatenaryYearFrom,
			yearTo = 0,
			checkEnabledFn = function(params : {string : number}) : ConstructionMenuParam.CheckEnabledResult
				return isYes(params, "rub_tram") and "Enabled" or "Hidden"
			end,
		},
		checkBox("rub_trees", function(params : {string : number}) : ConstructionMenuParam.CheckEnabledResult
			if isYes(params, "rub_trees") then
				return "Enabled"
			end
			return (isYes(params, "rub_barrier") or isCountry(params)) and "Disabled" or "Enabled"
		end),
		checkBox("rub_barrier", function(params : {string : number}) : ConstructionMenuParam.CheckEnabledResult
			if isYes(params, "rub_barrier") then
				return "Enabled"
			end
			return isYes(params, "rub_trees") and "Disabled" or "Enabled"
		end),
		checkBox("rub_lock"),
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
