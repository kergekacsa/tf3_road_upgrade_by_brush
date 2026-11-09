-- Options of the brush tool: the menu params of the rub_options module without the one-way road types.
-- The underground button (key undergroundMode) is the base game's.

local config = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_config.tl" as RubConfig
local options = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_options.tl" as RubOptions
local rules = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_rules.tl" as RubRules
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local brushStyle = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/brush_style.tl" as RubStyle
local rails = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/brush_rails.tl" as RubRails

local brushOptions : RubBrushOptions = {}

local MODE_KEY <const> = "rub_mode"
local MODE_ROADS <const> = 1
local MODE_RAILS <const> = 2
local TRACK_TYPE_KEY <const> = "rub_trackType"
local TRACK_STATE_KEY <const> = "rub_trackCatenary"
local TRACK_BARRIER_KEY <const> = "rub_trackBarrier"
local DEFAULT_TRACK_TYPE <const> = 2
local RAIL_STATES : {string} = { "keep", "add", "remove" }
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
		tooltip = _("Buildings that block the new road are demolished. A road with plots is upgraded by demolishing the buildings on the plots, or together with its neighbour road. A placed asset that blocks the road is removed on the first retry, and the last retry forces the build. Off: such roads are skipped."),
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

local function isRailMode(params : {string : number}) : boolean
	return params ~= nil and params[MODE_KEY] == MODE_RAILS
end

function brushOptions.mode(params : {string : number}) : string
	return isRailMode(params) and "rail" or "road"
end

-- The toolbar shows the options of one mode: the other mode's params are hidden.
local function onlyInMode(param : ConstructionMenuParam, rail : boolean)
	local inner = param.checkEnabledFn
	param.checkEnabledFn = function(params : {string : number}) : ConstructionMenuParam.CheckEnabledResult
		if isRailMode(params) ~= rail then return "Hidden" end
		if inner ~= nil then return inner(params) end
		return "Enabled"
	end
end

local function defaultTrackType(offered : integer) : integer
	return math.min(DEFAULT_TRACK_TYPE, offered)
end

-- The toolbar is built once, before the game year is known to it, so the track type list cannot be cut to the year.
-- Instead each list length has its own combo box, and only the one that matches the number of offered types shows;
-- with one offered type there is no combo box. The key of the full list is TRACK_TYPE_KEY.
local function trackTypeKey(offered : integer) : string
	if offered == #rails.TYPES then return TRACK_TYPE_KEY end
	return TRACK_TYPE_KEY .. offered
end

-- The menu remembers values by key: a remembered position can lie outside the choices offered in the game year.
-- A type without catenary in the game year has no catenary choice in the toolbar: its tracks get no catenary.
local function trackChoices(params : {string : number}) : integer, string, string
	local year = api.engine.util.getYear()
	local offered = rails.offeredTypes(year)
	local trackType = 1
	if offered > 1 then
		trackType = math.floor((params or {})[trackTypeKey(offered)] or defaultTrackType(offered))
		if trackType < 1 or trackType > offered then trackType = defaultTrackType(offered) end
	end
	local barrier = RAIL_STATES[math.floor((params or {})[TRACK_BARRIER_KEY] or 1)] or "keep"
	if not rails.hasCatenary(trackType, year) then return trackType, "remove", barrier end
	return trackType, RAIL_STATES[math.floor((params or {})[TRACK_STATE_KEY] or 1)] or "keep", barrier
end

local function modeParam(railEntry : boolean) : ConstructionMenuParam
	return {
		key = MODE_KEY,
		name = _("rub_mode_name"),
		tooltip = _("rub_mode_tooltip"),
		values = { _("rub_mode_roads"), _("rub_mode_rails") },
		defaultIndex = railEntry and MODE_RAILS or MODE_ROADS,
		displayMode = api.type["enum"].ScriptParamDisplayMode.Horizontal,
		uiType = api.type["enum"].ScriptParamType.Button,
		yearFrom = 0,
		yearTo = 0,
	}
end

local function railParams() : {ConstructionMenuParam}
	local result : {ConstructionMenuParam} = {}
	local names : {string} = {}
	for offered = 1, #rails.TYPES do
		names[offered] = rails.typeName(offered)
		if offered > 1 then
			local values : {string} = {}
			for i = 1, offered do values[i] = names[i] end
			result[#result + 1] = {
				key = trackTypeKey(offered),
				name = _("rub_trackType_name"),
				tooltip = _("rub_trackType_tooltip"),
				values = values,
				defaultIndex = defaultTrackType(offered),
				uiType = api.type["enum"].ScriptParamType.ComboBox,
				yearFrom = 0,
				yearTo = 0,
				checkEnabledFn = function(_params : {string : number}) : ConstructionMenuParam.CheckEnabledResult
					return rails.offeredTypes(api.engine.util.getYear()) == offered and "Enabled" or "Hidden"
				end,
			}
		end
	end
	result[#result + 1] = {
		key = TRACK_STATE_KEY,
		name = _("Catenary"),
		tooltip = _("rub_trackCatenary_tooltip"),
		values = { _("rub_lock_keep"), _("rub_state_add"), _("rub_state_remove") },
		defaultIndex = 1,
		uiType = api.type["enum"].ScriptParamType.ComboBox,
		yearFrom = 0,
		yearTo = 0,
		resetOnMenuClose = false,
		checkEnabledFn = function(params : {string : number}) : ConstructionMenuParam.CheckEnabledResult
			local trackType = trackChoices(params)
			return rails.hasCatenary(trackType, api.engine.util.getYear()) and "Enabled" or "Hidden"
		end,
	}
	local barrierParam : ConstructionMenuParam = {
		key = TRACK_BARRIER_KEY,
		name = _("rub_barrier_name"),
		tooltip = _("rub_trackBarrier_tooltip"),
		values = { _("rub_lock_keep"), _("rub_state_add"), _("rub_state_remove") },
		defaultIndex = 1,
		uiType = api.type["enum"].ScriptParamType.ComboBox,
		yearFrom = 0,
		yearTo = 0,
		resetOnMenuClose = false,
	}
	disabledUnderground(barrierParam)
	result[#result + 1] = barrierParam
	for _, param in ipairs(result) do onlyInMode(param, true) end
	return result
end

function brushOptions.params(noteGroup : string, railEntry? : boolean) : {ConstructionMenuParam}
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
	for _, param in ipairs(result) do
		if param.key ~= UNDERGROUND_KEY then onlyInMode(param, false) end
	end
	for _, param in ipairs(railParams()) do result[#result + 1] = param end
	result[#result + 1] = modeParam(railEntry == true)
	return result
end

function brushOptions.extras(params : {string : number}) : RubExtras
	local choices = options.fromParams(params or {})
	return { busLane = choices.busLane, tram = choices.tram, catenary = choices.catenary, lock = choices.lock }
end

function brushOptions.removeBuildings(params : {string : number}) : boolean
	return params == nil or params[REMOVE_BUILDINGS_KEY] ~= CHECKBOX_NO
end

function brushOptions.offers(clone : RubClone) : boolean
	return clone.roadType <= offeredRoadTypes()
end

function brushOptions.roadTypeName(clone : RubClone) : string
	return _(config.roadTypes[clone.roadType].name)
end

local CHECKBOX_YES <const> = 2
local CATENARY_YES <const> = 1
local CATENARY_NO <const> = 2
local LOCK_KEEP <const> = 1
local LOCK_LOCK <const> = 2
local CATENARY_KEY <const> = "rub_catenary"

local function setParam(menu : ConstructionMenuParamsAPI, key : string, value : integer) : boolean
	local set = false
	pcall(function()
		local info = menu.getParamByKey(key)
		if info ~= nil then
			menu.changeParam(info.index, value)
			set = true
		end
	end)
	return set
end

local function checkBoxValue(on : boolean) : integer
	return on and CHECKBOX_YES or CHECKBOX_NO
end

local record ParamStep
	key : string
	value : integer
end

-- Alley trees and noise barriers go off first and on last: the menu disables each of them while the other is on.
function brushOptions.apply(menu : ConstructionMenuParamsAPI, clone : RubClone) : boolean
	local steps : {ParamStep} = {
		{ key = "rub_trees", value = CHECKBOX_NO },
		{ key = "rub_barrier", value = CHECKBOX_NO },
		{ key = ROAD_TYPE_KEY, value = clone.roadType },
		{ key = "rub_tram", value = checkBoxValue(clone.tram) },
		{ key = "rub_busLane", value = checkBoxValue(clone.busLane) },
		{ key = "rub_trees", value = checkBoxValue(clone.trees) },
		{ key = "rub_barrier", value = checkBoxValue(clone.barrier) },
		{ key = "rub_lock", value = clone.lock == "lock" and LOCK_LOCK or LOCK_KEEP },
	}
	local allSet = true
	for _, step in ipairs(steps) do
		if not setParam(menu, step.key, step.value) then allSet = false end
	end
	-- The catenary param exists only from 1910 on, and only while the tram track is on.
	if clone.tram then setParam(menu, CATENARY_KEY, clone.catenary and CATENARY_YES or CATENARY_NO) end
	return allSet
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

-- The rail choice as one text, for the caches that depend on it.
function brushOptions.railKey(params : {string : number}) : string
	local trackType, state, barrier = trackChoices(params)
	return "rail/" .. trackType .. "/" .. state .. "/" .. barrier
end

function brushOptions.railTargeter(params : {string : number}) : RubRailTarget
	local trackType, state, barrier = trackChoices(params)
	return rails.targeter(trackType, state, api.engine.util.getYear(), barrier)
end

function brushOptions.trackName(clone : RubTrackClone) : string
	return rails.typeName(clone.trackType)
end

-- The catenary and the noise barrier of a track are copied as Add or Remove: the copy sets exactly what the track has.
-- A track that cannot show a barrier (tunnel, quiet copy) leaves the barrier choice as it is.
function brushOptions.applyTrack(menu : ConstructionMenuParamsAPI, clone : RubTrackClone) : boolean
	local offered = rails.offeredTypes(api.engine.util.getYear())
	local typeSet = clone.trackType <= offered and (offered == 1 or setParam(menu, trackTypeKey(offered), clone.trackType))
	local stateSet = setParam(menu, TRACK_STATE_KEY, clone.catenary and 2 or 3)
	local barrierSet = clone.barrier == nil or setParam(menu, TRACK_BARRIER_KEY, clone.barrier and 2 or 3)
	return typeSet and stateSet and barrierSet
end

return brushOptions
