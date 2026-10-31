-- Based on 'Road Upgrade All in One' by kurowasiichi (mod.io 6487083). Private build, not for publication.
-- Which combinations of the tool options can be applied. A combination with problems is not sent at all.

local config = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_config.tl" as RusConfig
local templates = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_templates.tl" as RusTemplates

local rules : RusRules = {}

local function decorationSuffix(choices : RusChoices) : string
	if choices.trees then
		return config.TreesSuffix
	end
	if choices.barrier then
		return config.BarriersSuffix
	end
	return ""
end

function rules.targetTemplate(choices : RusChoices, year : integer) : string
	return templates.resolve(config.roadTypes[choices.roadType], decorationSuffix(choices), year)
end

--- The outermost vehicle lanes of the template (both sides) must carry buses, so that a bus lane and tram tracks
--- can be put on the same lane.
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

function rules.check(choices : RusChoices, year : integer) : {RusRules.Problem}
	local problems : {RusRules.Problem} = {}
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
