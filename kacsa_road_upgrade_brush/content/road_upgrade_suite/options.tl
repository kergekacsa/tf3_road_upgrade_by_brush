-- Based on 'Road Upgrade All in One' by kurowasiichi (mod.io 6487083). Private build, not for publication.
-- Menu parameters of the tool and reading the chosen options from them.
-- Check boxes and buttons store the 1-based index of the chosen value (check boxes: 1 = no, 2 = yes).

local config = ug_require "/road_upgrade_suite/config.tl" as RusConfig
local rules = ug_require "/road_upgrade_suite/rules.tl" as RusRules
local construction_react_util = ug_require "::/gui/construction/construction_react_util.tl" as ConstructionReactUtil

local options : RusOptions = {}

--- first year with tram catenary, as the vanilla tram track tool (gui/construction/tools/tram_track_tool.res.lua)
local CatenaryYearFrom <const> = 1910

local Problems <const> : {RusRules.Problem} = { "treesAndBarrier", "treesCountry", "noTemplate", "busTramLanes" }

--- road type preselected in the menu
local DefaultRoadType <const> = "rus_type_town_medium"

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

function options.fromParams(params : {string : number}) : RusChoices
	local roadTypeIndex = math.floor(params["rus_roadType"] or defaultRoadTypeIndex())
	if config.roadTypes[roadTypeIndex] == nil then
		roadTypeIndex = defaultRoadTypeIndex()
	end
	local tram = isYes(params, "rus_tram")
	return {
		roadType = roadTypeIndex,
		busLane = isYes(params, "rus_busLane"),
		tram = tram,
		-- the catenary parameter only exists from CatenaryYearFrom on
		catenary = tram and params["rus_catenary"] == 1,
		trees = isYes(params, "rus_trees"),
		barrier = isYes(params, "rus_barrier"),
		lock = isYes(params, "rus_lock"),
		-- bus lanes and tram tracks always go on both sides
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

--- A parameter that only shows the explanation of a problem while the problem exists.
local function problemParam(problem : RusRules.Problem) : ConstructionMenuParam
	return {
		key = "rus_problem_" .. problem,
		name = _("rus_problem_name"),
		values = { _("rus_problem_" .. problem) },
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
			key = "rus_roadType",
			name = _("rus_roadType_name"),
			tooltip = _("rus_roadType_tooltip"),
			values = roadTypeNames,
			defaultIndex = defaultRoadTypeIndex(),
			uiType = api.type["enum"].ScriptParamType.ComboBox,
			yearFrom = 0,
			yearTo = 0,
		},
		checkBox("rus_busLane"),
		checkBox("rus_tram"),
		{
			key = "rus_catenary",
			name = _("Catenary"),
			values = { _("Yes"), _("No") },
			defaultIndex = 1,
			displayMode = api.type["enum"].ScriptParamDisplayMode.Horizontal,
			uiType = api.type["enum"].ScriptParamType.Button,
			yearFrom = CatenaryYearFrom,
			yearTo = 0,
			checkEnabledFn = function(params : {string : number}) : ConstructionMenuParam.CheckEnabledResult
				return isYes(params, "rus_tram") and "Enabled" or "Hidden"
			end,
		},
		checkBox("rus_trees", function(params : {string : number}) : ConstructionMenuParam.CheckEnabledResult
			-- keep it enabled while checked, so that a conflicting choice can be unchecked again
			if isYes(params, "rus_trees") then
				return "Enabled"
			end
			return (isYes(params, "rus_barrier") or isCountry(params)) and "Disabled" or "Enabled"
		end),
		checkBox("rus_barrier", function(params : {string : number}) : ConstructionMenuParam.CheckEnabledResult
			if isYes(params, "rus_barrier") then
				return "Enabled"
			end
			return isYes(params, "rus_trees") and "Disabled" or "Enabled"
		end),
		checkBox("rus_lock"),
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
