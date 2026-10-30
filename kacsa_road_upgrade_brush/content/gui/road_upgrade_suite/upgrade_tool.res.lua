-- Based on 'Road Upgrade All in One' by kurowasiichi (mod.io 6487083). Private build, not for publication.
-- Combined street upgrade tool in the road tools menu, see upgrade_tool.script.tl.
function data()
	return {
		type = "construction_tool",
		data = {
			getDefinitionFn = {
				fileName = "kacsa_road_upgrade_brush::/gui/road_upgrade_suite/upgrade_tool.script@getDefinition",
			}
		}
	}
end
