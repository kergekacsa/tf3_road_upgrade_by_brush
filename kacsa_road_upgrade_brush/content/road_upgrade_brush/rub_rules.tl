-- Based on 'Road Upgrade All in One' by kurowasiichi (mod.io 6487083).
-- A combination of choices with problems is not applied. These are the problems that hold for every road.

local config = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_config.tl" as RubConfig
local templates = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_templates.tl" as RubTemplates
local roads = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/brush_roads.tl" as RubRoads

local rules : RubRules = {}

local ADD <const> = "add"

function rules.check(choices : RubChoices, year : integer) : {RubRules.Problem}
	local problems : {RubRules.Problem} = {}
	-- Tunnels have no alley trees and no noise barriers: the two choices do not count while the underground view is on.
	local trees = not choices.underground and choices.trees == ADD
	local barrier = not choices.underground and choices.barrier == ADD
	if trees and barrier then
		problems[#problems + 1] = "treesAndBarrier"
	end
	local roadType = config.roadTypes[choices.roadType]
	if roadType == nil then
		return problems
	end
	if trees and roadType.country then
		problems[#problems + 1] = "treesCountry"
		return problems
	end
	if trees and barrier then
		return problems
	end
	local suffix = trees and config.TreesSuffix or (barrier and config.BarriersSuffix or "")
	local template = templates.resolve(roadType, suffix, year)
	if template == nil then
		problems[#problems + 1] = "noTemplate"
		return problems
	end
	if choices.busLane == ADD and choices.tram == ADD and not roads.outerLanesCarryBuses(template) then
		problems[#problems + 1] = "busTramLanes"
	end
	return problems
end

return rules
