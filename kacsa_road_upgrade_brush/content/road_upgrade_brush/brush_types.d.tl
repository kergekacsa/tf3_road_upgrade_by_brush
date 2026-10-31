-- Types of the brush tool's own modules.

-- Module: ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/brush_options.tl" as RubBrushOptions
global record RubBrushOptions
	--- Toolbar params of the brush: the two-way road types, bus lane, tram track, catenary, lock, alley trees, noise barriers, the notes about
	--- impossible combinations (red text in the toolbar group `noteGroup`), and the choice to remove
	--- buildings in the way (on by default).
	params : function(noteGroup : string) : {ConstructionMenuParam}
	--- The street template for the options in a toolbar params map, or nil and the text of the
	--- problem that prevents an upgrade.
	template : function(params : {string : number}) : string, string
	--- The bus lane, tram track, catenary and lock chosen in a toolbar params map.
	extras : function(params : {string : number}) : RubExtras
	--- Whether the toolbar choice "Remove buildings in the way" is on (also when the map has no value yet).
	removeBuildings : function(params : {string : number}) : boolean
	--- Whether the road type of a clone (an index in `config.roadTypes`) is one the toolbar offers (not a one-way type).
	offers : function(clone : RubClone) : boolean
	--- The translated name of the road type of a clone.
	roadTypeName : function(clone : RubClone) : string
	--- Sets the toolbar params of the menu to the settings of a clone. The result is false when a param could not be set.
	apply : function(menu : ConstructionMenuParamsAPI, clone : RubClone) : boolean
end

--- The settings of one street, as the toolbar shows them.
global record RubClone
	roadType : integer      -- index in `config.roadTypes`
	trees : boolean
	barrier : boolean
	busLane : boolean
	tram : boolean
	catenary : boolean
	lock : string           -- "lock" or "keep"
	editedLanes : boolean   -- the lanes match no combination of bus lane and tram track; those three are then off
end

-- Module: ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/brush_clone.tl" as RubBrushClone
global record RubBrushClone
	--- The street at (x, y): the one whose lanes cover the point (the nearest centre line when several do); tunnels only with `underground`, other streets only without it. nil when there is none. The second result is a text for the log: how many streets were in range and the nearest one.
	pick : function(x : number, y : number, underground : boolean) : integer, string
	--- The settings of a street. nil when its street template is none of the road types of the tool, or it cannot be read.
	read : function(edge : integer) : RubClone
end

-- Module: ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/brush_style.tl" as RubStyle
global record RubStyle
	--- The meta of a text: the font class, and the theme colour of the severity ("error" red, "warning"
	--- yellow, "ok" green, anything else leaves the colour as the style sheet sets it).
	meta : function(fontClass : string, severity : string) : Meta
end
-- Module: ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/proposal_probe.tl" as RubProposalProbe
global record RubProposalProbe
	--- Switch for all diagnostics of the mod (this probe and the diagnostic lines of the brush tool); false = off.
	ENABLED : boolean
	--- Logs the proposal of a construction action while the cursor is over a road (does nothing unless ENABLED).
	install : function(params : Builtin.ConstructionActionParam)
	--- One line about a segment of a proposal: edge type, road development lock, decorations, lanes.
	segmentText : function(seg : Proposal.SegmentAndEntity) : string
end