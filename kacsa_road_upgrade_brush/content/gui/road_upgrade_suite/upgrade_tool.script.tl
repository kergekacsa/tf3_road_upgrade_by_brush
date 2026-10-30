-- Based on 'Road Upgrade All in One' by kurowasiichi (mod.io 6487083). Private build, not for publication.
-- Definition of the combined street upgrade tool: choose the road type and the add-ons (bus lane, tram track, alley
-- trees, noise barriers, lock), then click existing roads as with the vanilla upgrader.
-- The action is built in road_upgrade_suite/action.tl.

local action = ug_require "/road_upgrade_suite/action.tl" as RusAction
local options = ug_require "/road_upgrade_suite/options.tl" as RusOptions
local construction_react_util = ug_require "::/gui/construction/construction_react_util.tl" as ConstructionReactUtil

local Ret = {
	getDefinition = function(constructionDefinition : ResName, _repository : ConstructionActionRepository, _params : table) : ConstructionDefinition
		action.install(constructionDefinition)
		return {
			resName = constructionDefinition,
			icon = { icon = "kacsa_road_upgrade_brush::/gui/road_upgrade_suite/upgrade_tool.tga" },
			previewIcon = { icon = "kacsa_road_upgrade_brush::/gui/road_upgrade_suite/upgrade_tool_preview.tga" },
			name = _("rus_tool_name"),
			description = _("rus_tool_description"),
			action = "ACTION_STREET_BUILDER_UPGRADER",
			availability = {
				yearFrom = 0,
				yearTo = 0,
			},
			params = options.params(),
			hudIcons = construction_react_util.getStreetToolsHudIcons("ROAD"),
			menuCategory = {
				categories = {
					{
						category = "roads_tools",
						order = 50,
					},
				},
			},
			builderAudioRes = { "::/gui/construction/sound/tool_upgrade_street.builder_audio" },
		}
	end,
}

return Ret
