-- Text colours of the brush tool: errors red, warnings yellow, success green, in the game's theme colours. The colour is
-- set inline (meta.styleSheet), so the mod's stylesheet needs no extra rules.

local styleutil = ug_require "::/gui/main/styleutil.tl" as StyleUtil

local brushStyle : BrushStyle = {}

local themeColors : {string : {number}} = nil

local function colors() : {string : {number}}
	if themeColors == nil then
		themeColors = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/default_colors.gres")).data as {string : {number}}
	end
	return themeColors
end

function brushStyle.meta(fontClass : string, severity : string) : Meta
	local meta : Meta = { class = fontClass }
	if severity == "error" then
		meta.styleSheet = styleutil.makeStyle{ color = colors().Error }
	elseif severity == "warning" then
		meta.styleSheet = styleutil.makeStyle{ color = colors().Warning }
	elseif severity == "ok" then
		meta.styleSheet = styleutil.makeStyle{ color = colors().Ok }
	end
	return meta
end

return brushStyle