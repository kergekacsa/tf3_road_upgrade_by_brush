-- Based on 'Road Upgrade All in One' by kurowasiichi (mod.io 6487083). Private build, not for publication.
-- The tool sends one combined street modifier, the same action descriptor the vanilla tools use
-- (construction_react_util.tl, getConstructionActionParams): the road type of the street upgrader, the bus lane of the
-- bus lane tool, the tram track of the tram track tool and the lock of the lock tool, filled in together.
--
-- construction.tl calls construction_react_util.getActionParams through the module table, so it is wrapped here.
-- For the tool's definition the vanilla function builds the action of the street upgrader with the template of the
-- chosen road type, then the chosen options are added to its modifier.
-- The definition keeps action ACTION_STREET_BUILDER_UPGRADER, so the one-way arrows layer, the segment flip (hold
-- IA_SECONDARY_MODE) and the single segment mode of the vanilla upgrader stay as they are.

local options = ug_require "/road_upgrade_suite/options.tl" as RusOptions
local rules = ug_require "/road_upgrade_suite/rules.tl" as RusRules
local construction_react_util = ug_require "::/gui/construction/construction_react_util.tl" as ConstructionReactUtil
local probe = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/proposal_probe.tl" as ProposalProbe

local action : RusAction = {}

local toolResNames : {ResName : boolean} = {}

--- an action name getConstructionActionParams does not know: it returns an empty action, nothing can be built
local NoAction <const> = "ACTION_NONE" as ConstructionMenuAction

local reportedErrors : {string : boolean} = {}

local function copy<T>(t : T) : T
	local result : {any : any} = {}
	for k, v in pairs(t as {any : any}) do
		result[k] = v
	end
	return result as T
end

--- Parameters of the vanilla street upgrader: replace mode, lanes and decorations replaced with the ones of the template.
local function upgraderParams(params : {string : number}) : {string : number}
	local baseParams = copy(params)
	baseParams["mode_street"] = 3
	baseParams["overrideLaneConfigs"] = 1
	return baseParams
end

--- Adds the chosen options to the modifier of the vanilla action.
local function addOptions(modifier : Builtin.Type.ConstructionAction.StreetEdgeNodeModifier, choices : RusChoices)
	if choices.busLane then
		modifier.busLane = true
	end
	if choices.tram then
		local trackTypes = api.type["enum"].TramTrackType
		modifier.tramTrackType = choices.catenary and trackTypes.ELECTRIC or trackTypes.YES
		modifier.overrideLaneConfigs = true
	end
	if choices.busLane or choices.tram then
		modifier.symmetricLanes = choices.symmetric
	end
	if choices.trees or choices.barrier then
		modifier.overrideEdgeDecorations = true
	end
	-- without the lock option the field stays unset: a regular upgrade does not unlock a locked road
	if choices.lock then
		modifier.roadDevelopmentLocked = true
		modifier.makePlayerOwnedOnChange = not api.gui.game.isMapEditor()
	end
	modifier.undergroundMode = choices.underground
end

local type GetActionParams = function(definition : ConstructionDefinition, params : {string : number}, repository : ConstructionActionRepository,
	isGamepadMode : boolean, refParams : ReactRefWrapApiT<any, ConstructionMenuParamsAPI>, entity : Engine.Entity,
	accessNotificationCacheFn : (function(Engine.Entity) : {Notification}), sublistParamsApi : ReactRefWrapApiT<any, ConstructionMenuParamsAPI>,
	disableLayersIA : boolean) : ConstructionMenuActionParams

local function wrap(original : GetActionParams) : GetActionParams
	return function(definition : ConstructionDefinition, params : {string : number}, repository : ConstructionActionRepository,
			isGamepadMode : boolean, refParams : ReactRefWrapApiT<any, ConstructionMenuParamsAPI>, entity : Engine.Entity,
			accessNotificationCacheFn : (function(Engine.Entity) : {Notification}), sublistParamsApi : ReactRefWrapApiT<any, ConstructionMenuParamsAPI>,
			disableLayersIA : boolean) : ConstructionMenuActionParams
		if definition == nil or not toolResNames[definition.resName] then
			return original(definition, params, repository, isGamepadMode, refParams, entity, accessNotificationCacheFn, sublistParamsApi, disableLayersIA)
		end

		local ok, result = pcall(function() : ConstructionMenuActionParams
			local choices = options.fromParams(params or {})
			local year = api.engine.util.getYear()
			local baseDefinition = copy(definition)
			local baseParams = params
			if #rules.check(choices, year) > 0 then
				-- the menu shows the problems; nothing is sent, no option is dropped silently
				baseDefinition.action = NoAction
			else
				-- the street upgrader replaces the clicked segments with the template of the road type
				baseDefinition.action = "ACTION_STREET_BUILDER_UPGRADER"
				baseDefinition.resName = rules.targetTemplate(choices, year)
				baseParams = upgraderParams(params or {})
			end
			local actionParams = original(baseDefinition, baseParams, repository, isGamepadMode, refParams, entity, accessNotificationCacheFn, sublistParamsApi, disableLayersIA)
			local constructionActionParams = actionParams.constructionActionParams
			if constructionActionParams ~= nil then probe.install(constructionActionParams) end
			local modifier = constructionActionParams ~= nil and constructionActionParams.streetEdgeNodeModifier or nil
			if modifier ~= nil then
				addOptions(modifier, choices)
				constructionActionParams.streetEdgeNodeModifier = modifier
			end
			return actionParams
		end)
		if ok then
			return result
		end
		local message = tostring(result)
		if not reportedErrors[message] then
			reportedErrors[message] = true
			log.message("[road_upgrade_suite] error building the action: " .. message)
		end
		local fallback = copy(definition)
		fallback.action = NoAction
		return original(fallback, params, repository, isGamepadMode, refParams, entity, accessNotificationCacheFn, sublistParamsApi, disableLayersIA)
	end
end

--- marks the wrapped function, so that it is wrapped only once per Lua state
local wrappedFns : {GetActionParams : boolean} = {}

function action.install(toolResName : ResName)
	toolResNames[toolResName] = true
	local current = construction_react_util.getActionParams as GetActionParams
	if wrappedFns[current] then
		return
	end
	local wrapped = wrap(current)
	wrappedFns[wrapped] = true
	construction_react_util.getActionParams = wrapped
	log.message("[road_upgrade_suite] street upgrade tool installed: " .. tostring(toolResName))
end

return action
