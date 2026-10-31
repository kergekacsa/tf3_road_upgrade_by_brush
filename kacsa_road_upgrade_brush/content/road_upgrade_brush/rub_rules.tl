-- Based on 'Road Upgrade All in One' by kurowasiichi (mod.io 6487083). Private build, not for publication.
-- A combination of options with problems is not applied.

local config = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_config.tl" as RubConfig
local templates = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_templates.tl" as RubTemplates

local rules : RubRules = {}

local function decorationSuffix(choices : RubChoices) : string
	if choices.trees then
		return config.TreesSuffix
	end
	if choices.barrier then
		return config.BarriersSuffix
	end
	return ""
end

function rules.targetTemplate(choices : RubChoices, year : integer) : string
	return templates.resolve(config.roadTypes[choices.roadType], decorationSuffix(choices), year)
end

local function outerLanesCarryBuses(resName : string) : boolean
	local id = api.res.streetTemplateRep.find(resName)
	if id < 0 then
		return false
	end
	local modes = api.type["enum"].TransportMode
	local vehicleLanes : {LaneConfig} = {}
	for _, lane in ipairs(api.res.streetTemplateRep.get(id).laneConfigs) do
		if not lane.transportModes[modes.PERSON] and not lane.transportModes[modes.CARGO] then
			vehicleLanes[#vehicleLanes + 1] = lane
		end
	end
	if #vehicleLanes == 0 then
		return false
	end
	for _, lane in ipairs({ vehicleLanes[1], vehicleLanes[#vehicleLanes] }) do
		if not lane.transportModes[modes.BUS] then
			return false
		end
	end
	return true
end

function rules.check(choices : RubChoices, year : integer) : {RubRules.Problem}
	local problems : {RubRules.Problem} = {}
	if choices.trees and choices.barrier then
		problems[#problems + 1] = "treesAndBarrier"
	end
	local roadType = config.roadTypes[choices.roadType]
	if choices.trees and roadType.country then
		problems[#problems + 1] = "treesCountry"
		return problems
	end
	if choices.trees and choices.barrier then
		return problems
	end
	local template = rules.targetTemplate(choices, year)
	if template == nil then
		problems[#problems + 1] = "noTemplate"
		return problems
	end
	if choices.busLane and choices.tram and not outerLanesCarryBuses(template) then
		problems[#problems + 1] = "busTramLanes"
	end
	return problems
end

return rules
