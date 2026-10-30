-- Brush upgrade tool in the road tools menu, see brush_upgrade.script.tl.
function data()
	return {
		type = "construction_tool",
		data = {
			getDefinitionFn = {
				fileName = "kacsa_road_upgrade_brush::/road_upgrade_brush/brush_upgrade.script@getDefinition",
			}
		}
	}
end