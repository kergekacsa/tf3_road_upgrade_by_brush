-- Based on 'Bulk Bulldozer' by square17 (mod.io 6434884).
-- The construction menu draws every toolbar param as a ToggleButton. The status chip is a disabled one-value Button
-- param (brush_upgrade.script.tl KEY_STATUS). Its group id becomes a class of the group's R::Component
-- ("param-group,<group>"). Every toolbar rule here is scoped under that class (GROUP_INFO = "sq-tool-info", shared with
-- Smart Lanes). Class names hold only letters, digits and dashes.
local ssu = require "::/gui/main/stylesheetutil.lua"

function data()
	local result = { }

	local a = ssu.makeAdder(result)

	-- This block is identical in every SQ_TOOL_INFO_MODS mod except ME. Only the first active mod of the list adds the
	-- rules (each ships square_tool_info/marker.gres; a disabled mod's resources aren't loaded). The game crashes on
	-- load above about 200 mod stylesheet rules. A new tool goes at the end of the list: each mod only reads the
	-- entries before it.
	do
		local ME = "kacsa_road_upgrade_brush"
		local SQ_TOOL_INFO_MODS = { "square_smart_lanes", "square_bulk_bulldozer" }
		local function markerActive(modId)
			local okFind, id = pcall(api.gui.genericRep.find, modId .. "::/square_tool_info/marker.gres")
			if not okFind or type(id) ~= "number" or id < 0 then return false end
			local okGet, res = pcall(api.gui.genericRep.get, id)
			return okGet and res ~= nil and type(res.data) == "table" and res.data.squareToolInfo == true
		end
		local leader = true
		for __, modId in ipairs(SQ_TOOL_INFO_MODS) do
			if modId == ME then break end
			if markerActive(modId) then
				leader = false
				log.message("[SQ tool info] style: skipped in " .. ME .. " (added by " .. modId .. ")")
				break
			end
		end
		if leader then
			log.message("[SQ tool info] style: added by " .. ME)
			local colorDefault = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/default_colors.gres")).data
			-- Each selector adds our class and the R::Component element to the base one, so it wins by specificity.
			a([[R::Component!sq-tool-info ToggleButton!checked:disabled,
				R::Component!sq-tool-info ToggleButton!unchecked:disabled]], {
				backgroundColor1 = colorDefault.Invisible,
				borderColor = colorDefault.Invisible,
				padding = { 2, 0, 2, 0 },
				transitionPropertyDuration = {},
			})
			a("R::Component!sq-tool-info ToggleButton > FloatingLayout > *", {
				gravity = { 0, 0.5 },
			})
			-- maxSize 280 px is the width of the menu's group separators.
			a("R::Component!sq-tool-info ToggleButton:disabled > FloatingLayout TextView", {
				color = colorDefault.NeutralVeryLight,
				transitionPropertyDuration = {},
				textAutoWrap = true,
				maxSize = { 280, -1 },
			})
		end
	end

	-- The button hints of a controller for the tool recipe (BrushUpgradeAction). The input action handlers of the
	-- recipe give the texts. This rule is not part of the shared block above.
	a("!input-controller R::BrushUpgradeAction", {
		actionPromptList = {
			{ ia = "IA_APPLY", sortKey = "brush-upgrade-1" },
			{ ia = "IA_OPTION2", sortKey = "brush-upgrade-2" },
			{ ia = "constructOpt2", sortKey = "brush-upgrade-3a" },
			{ ia = "constructOpt1", sortKey = "brush-upgrade-3b" },
			{ ia = "IA_MENU_BACK", sortKey = "brush-upgrade-4" },
		},
	})

	return result
end
