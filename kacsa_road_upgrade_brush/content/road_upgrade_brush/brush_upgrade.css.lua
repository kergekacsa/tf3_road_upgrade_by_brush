-- Based on 'Bulk Bulldozer' by square17 (mod.io 6434884). Private build, not for publication.
-- Road upgrade brush tool styles: the status chip under the Upgrade / Clear row reads as plain text, not as a grey
-- button, the same look as Smart Lanes' info block (docs/ui-guide.md "Construction toolbar").
-- The construction menu draws every toolbar param as a ToggleButton (script_param_util.tl:396-466), so the chip
-- is a disabled one-value Button param (brush_upgrade.script.tl KEY_STATUS). Its group id becomes a class of the
-- group's R::Component (construction.tl:1344-1352, "param-group,<group>"): every rule here is scoped under that
-- class (GROUP_INFO = "sq-tool-info", shared with Smart Lanes), so nothing touches base UI or other mods.
-- Class names hold only letters, digits and dashes (docs/findings/gui.md "CSS class names").
local ssu = require "::/gui/main/stylesheetutil.lua"

function data()
	local result = { }

	local a = ssu.makeAdder(result)

	-- TOOL INFO STYLE (shared by our construction-menu tools; docs/ui-guide.md "Construction toolbar"; keep
	-- this block identical in every SQ_TOOL_INFO_MODS mod except ME). The status / description param of each
	-- tool sits in a group with the class "sq-tool-info"; these rules turn that disabled button into plain
	-- wrapped text. Only the first ACTIVE mod of the list adds them (each ships square_tool_info/marker.gres;
	-- a disabled mod's resources aren't loaded), so they cost 4 rules however many of the tools are on
	-- (docs/findings.md "Load crash above ~200 mod stylesheet rules": a separate copy per mod crashed a new
	-- game, 2026-10-14). A new tool goes at the end of the list: each mod only reads the entries before it.
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
			-- Base rules overridden (builtin.css.lua): the fill and contour of a disabled toggle (:243-252),
			-- centred content (:178-182) and the grey text of a disabled button (:268-275). Each selector adds
			-- our class and the R::Component element to the base one, so it wins by specificity. Colours
			-- other than the text default (Smart Lanes' green / amber badge) go inline in the script, and
			-- wrapping / gravity can't (api.gui.StyleSheet has no textAutoWrap, maxSize or gravity).
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
			-- long lines wrap at the width of the menu's group separators (construction.css.lua:772-775,
			-- 280 px), as the base info callout (construction.css.lua:534-539)
			a("R::Component!sq-tool-info ToggleButton:disabled > FloatingLayout TextView", {
				color = colorDefault.NeutralVeryLight,
				transitionPropertyDuration = {},
				textAutoWrap = true,
				maxSize = { 280, -1 },
			})
		end
	end

	return result
end
