-- Types of the brush tool's own modules (the library files use bb_types.d.tl).

-- Module: ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/brush_options.tl" as BrushOptions
global record BrushOptions
	--- Toolbar params of the brush: the two-way road types, bus lane, tram track, catenary, lock, alley trees, noise barriers, the notes about
	--- impossible combinations (red text in the toolbar group `noteGroup`), and the choice to remove
	--- buildings in the way (on by default).
	params : function(noteGroup : string) : {ConstructionMenuParam}
	--- The street template for the options in a toolbar params map, or nil and the text of the
	--- problem that prevents an upgrade.
	template : function(params : {string : number}) : string, string
	--- The bus lane, tram track, catenary and lock chosen in a toolbar params map.
	extras : function(params : {string : number}) : BrushExtras
	--- Whether the toolbar choice "Remove buildings in the way" is on (also when the map has no value yet).
	removeBuildings : function(params : {string : number}) : boolean
end

-- Module: ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/brush_style.tl" as BrushStyle
global record BrushStyle
	--- The meta of a text: the font class, and the theme colour of the severity ("error" red, "warning"
	--- yellow, "ok" green, anything else leaves the colour as the style sheet sets it).
	meta : function(fontClass : string, severity : string) : Meta
end
-- Module: ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/proposal_probe.tl" as ProposalProbe
global record ProposalProbe
	--- Logs the proposal of a construction action while the cursor is over a road (diagnostic).
	install : function(params : Builtin.ConstructionActionParam)
	--- One line about a segment of a proposal: edge type, road development lock, decorations, lanes.
	segmentText : function(seg : Proposal.SegmentAndEntity) : string
end