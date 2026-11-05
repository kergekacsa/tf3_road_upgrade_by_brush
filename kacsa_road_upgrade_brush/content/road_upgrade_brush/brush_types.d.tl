-- Types of the brush tool's own modules.

-- Module: ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/brush_options.tl" as RubBrushOptions
global record RubBrushOptions
	--- Toolbar params of the brush: the mode switch (Roads or Rails; Rails when `railEntry`, else Roads, is the default), the two-way road types, bus lane, tram track, catenary, lock, alley trees, noise barriers, the notes about
	--- impossible combinations (red text in the toolbar group `noteGroup`), and the choice to remove
	--- buildings in the way (on by default), and for the Rails mode the track type, the catenary state and their notes. Each mode's params are hidden in the other mode.
	params : function(noteGroup : string, railEntry? : boolean) : {ConstructionMenuParam}
	--- "road" or "rail": the mode chosen in a toolbar params map.
	mode : function(params : {string : number}) : string
	--- The rail choices of a toolbar params map as one text.
	railKey : function(params : {string : number}) : string
	--- The per-track target of the rail choices.
	railTargeter : function(params : {string : number}) : RubRailTarget
	--- The name the game gives the track type of a clone.
	trackName : function(clone : RubTrackClone) : string
	--- Sets the track type and the catenary state of the menu to a track's. The result is false when a param could not be set.
	applyTrack : function(menu : ConstructionMenuParamsAPI, clone : RubTrackClone) : boolean
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

--- The settings of one track, as the toolbar shows them.
global record RubTrackClone
	trackType : integer     -- index in `rails.TYPES`
	catenary : boolean
	barrier : boolean      -- the track has a noise barrier of the game on a side; nil for a tunnel or a quiet copy, which cannot show it
end

-- Module: ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/brush_clone.tl" as RubBrushClone
global record RubBrushClone
	--- The street at (x, y): the one whose lanes cover the point (the nearest centre line when several do); tunnels only with `underground`, other streets only without it. nil when there is none. The second result is a text for the log: how many streets were in range and the nearest one.
	pick : function(x : number, y : number, underground : boolean, tracks? : boolean) : integer, string
	--- The settings of a street. nil when its street template is none of the road types of the tool, or it cannot be read.
	read : function(edge : integer) : RubClone
	--- The settings of a track. nil when its template is none of the six base track templates.
	readTrack : function(edge : integer) : RubTrackClone
end

-- Module: ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/brush_rails.tl" as RubRails
global record RubRails
	--- The base track types in the order of the toolbar: "simple", "standard", "high_speed".
	TYPES : {string}
	--- The street template of a base track type, with or without catenary.
	template : function(typeIndex : integer, catenary : boolean) : string
	--- The type (an index in TYPES) and the catenary of a track template, also of the quiet copy of Station Noise Barriers. nil when the template is none of the twelve.
	parse : function(resName : string) : integer, boolean
	--- The number of track types offered in the year, counted from the first.
	offeredTypes : function(year : integer) : integer
	--- Whether the game offers the catenary twin of a track type in the year.
	hasCatenary : function(typeIndex : integer, year : integer) : boolean
	--- Per track: the template the upgrade gives it, whether the track is the target already, and the decoration list to set (nil: leave it). The template is nil when the track has no base template or the target is not available. The barrier is "keep", "add" or "remove".
	targeter : function(typeIndex : integer, state : string, year : integer, barrier : string) : RubRailTarget
	--- Whether a track template is a quiet copy of another track template (Station Noise Barriers).
	isQuiet : function(resName : string) : boolean
	--- Whether a decoration list holds a noise barrier of the game for tracks on a side.
	hasBarrier : function(decorations : {{integer, boolean}}) : boolean
	--- The id of the track noise barrier that the game offers in the year. nil when it offers none.
	barrierId : function(year : integer) : integer
	--- The name the game gives the plain template of a type.
	typeName : function(typeIndex : integer) : string
end

-- Module: ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/brush_style.tl" as RubStyle
global record RubStyle
	--- The meta of a text: the font class, and the theme colour of the severity ("error" red, "warning"
	--- yellow, "ok" green, anything else leaves the colour as the style sheet sets it).
	meta : function(fontClass : string, severity : string) : Meta
end
--- What `before` reads of a road, to find the same road again after its command.
global record RubProbeWatch
	edge : integer
	attempt : integer
	--- The two end points of the old road, as x, y, z, x, y, z.
	ends : {number}
	oldText : string
	--- Metres: the radius of the octree query that finds the road again.
	radius : number
end
-- Module: ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/brush_layer.tl" as RubLayer
global record RubLayer
	--- Seconds. An owner whose layer was not seen alive for this long counts as gone.
	OWNER_STALE_SECONDS : number
	--- Seconds. An unmounted layer counts as closed once it stays unmounted this long.
	GONE_SECONDS : number
	--- Seconds. A tool state passed in by the newest instance stays this long.
	PUSH_GRACE_SECONDS : number
	--- Seconds. A click is a stuck ring when the step did not update the ring for this long.
	STUCK_RING_AFTER : number
	--- Metres. A click is a stuck ring when the ring is farther than this from the terrain position under the pointer.
	STUCK_RING_OFFSET : number
	--- The instance number of the owner of the mounted world layer; 0 = none.
	owner : function() : integer
	--- true while the world layer of instance `me` is mounted.
	isUp : function(me : integer) : boolean
	--- The layer of `me` is mounted: `me` becomes the owner. `setParam` hands a tool state to `me`. Returns whether the layer was marked mounted before, the seconds it had been unmounted (nil when it never was, or when the tool forgot the unmount), and whether that counts as closed. A mount replaces the mark of a mouse claim.
	mount : function(me : integer, now : number, setParam : function(any)) : boolean, number, boolean
	--- One layer of `me` is unmounted. When none is left mounted, `me` stops being the owner. Two layers that stay mounted for GONE_SECONDS after the last mount count as one.
	unmount : function(me : integer, now : number)
	--- `me` is gone (its recipe unmounted): drops its state, and `me` stops being the owner.
	forget : function(me : integer)
	--- The step of `me`. `active`: the tool is active. `activated`: it became active in this step. An inactive or just activated tool forgets that its layer went down. Returns whether the layer has stayed unmounted for GONE_SECONDS (the tool was switched; true once, the unmount is forgotten) and whether the layer of `me` is mounted. An inactive tool does not count as alive. A mounted layer of an active tool keeps the owner alive.
	step : function(me : integer, now : number, active : boolean, activated : boolean) : boolean, boolean
	--- The newest instance `me` hands `state` to the owner when its own layer is not mounted. Returns true when it did. It does not check when the owner stepped last; a mouse event of another instance takes the layer from an owner that stopped stepping.
	passState : function(me : integer, newest : integer, now : number, state : any) : boolean
	--- true when the params of the menu reach `me` again, which is after PUSH_GRACE_SECONDS since a newer instance passed its state in.
	acceptsParam : function(me : integer, now : number) : boolean
	--- A mouse event reached `me`. Returns "up" (its layer is mounted), "blocked" (another owner was seen alive less than OWNER_STALE_SECONDS ago: ignore the event), "claimed" (the layer was marked mounted again) or "grace" (the layer went down less than GONE_SECONDS ago). The second value is a log line, for the first blocked event of an episode (at most 20 per session) and for a claim; else nil.
	mouse : function(me : integer, now : number, setParam : function(any)) : string, string
	--- true when a click is a stuck ring: the step did not update the ring (`stepAt` nil: never) for STUCK_RING_AFTER, or the ring (nil: none) is farther than STUCK_RING_OFFSET from the terrain position under the pointer (nil: none).
	ringStuck : function(stepAt : number, now : number, ringX : number, ringY : number, liveX : number, liveY : number) : boolean
end
--- The probe of one press. Every function does nothing for an edge that has no watch (option Off, road unreadable).
global record RubProbePress
	--- The road `edge` starts attempt number `attempt` (0 = first pass).
	road : function(edge : integer, attempt : integer)
	--- Logs the line of the road before its command. `p` is nil when no proposal was built. `commands` is the number of commands sent so far.
	proposal : function(edge : integer, p : Proposal, commands : integer)
	--- Logs the road found at the end points of `edge`, with the text that `state` returns appended. `state` runs only when the edge has a watch.
	after : function(edge : integer, state : function() : string)
end
-- Module: ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/proposal_probe.tl" as RubProposalProbe
global record RubProposalProbe
	--- Reads the option "Debug: upgrade log" and keeps the answer. true = On.
	refresh : function() : boolean
	--- The answer of the last refresh (reads the option once when there was none). Does no other work.
	enabled : function() : boolean
	--- Starts the line count of a press and refreshes the option.
	beginPress : function()
	--- The text with a "[category]" tag in front while the option is On, else the text unchanged.
	tag : function(category : string, text : string) : string
	--- Logs the proposal of the base game tool named `tool` (an action id) while the cursor is over a road (does nothing while the option is Off). Params that already carry the hook are skipped.
	install : function(params : Builtin.ConstructionActionParam, tool : string)
	--- Reads every road of `edges` now (option On only) and returns the handle of the press. It MUST NOT run in a command callback. Every call of the handle is protected: an error in it never reaches the caller.
	press : function(edges : {integer}) : RubProbePress
end

--- Options of `RubGridBuilderModule.build`. A field that is missing keeps its default.
global record RubGridOptions
	--- Blocks along the heading of the strip (6).
	blocksAlong : integer
	--- Blocks to the left of the heading (8).
	blocksLeft : integer
	--- Length of a block along the heading, in metres (144).
	blockLengthAlongM : number
	--- Length of a block to the left, in metres (88).
	blockLengthLeftM : number
	--- Longest total length along the heading, in metres, measured between the centre lines of the outer streets. The grid gets the most blocks that fit, at least 1, and the value replaces blocksAlong. Not set by default.
	maxLengthAlongM : number
	--- Longest total length to the side, in metres, counted like maxLengthAlongM. It replaces blocksLeft. Not set by default.
	maxLengthLeftM : number
	--- true builds the grid to the right of the heading instead of the left (false). Every "left" in the other options then means the right.
	buildToRight : boolean
	--- true starts the grid at the first node of the strip and runs it the other way (false).
	flipStripDirection : boolean
	--- Radius around the camera centre in which the strip is searched, in metres (150).
	cameraSearchRadiusM : number
	--- Radius in which a grid point joins an existing node, in metres (3).
	nodeSnapRadiusM : number
	--- Every Nth street that runs along the heading is large, 0 for none (4).
	largeEveryAlong : integer
	--- Every Nth street that runs to the left is large, 0 for none (3).
	largeEveryLeft : integer
	--- Short template names of the large street. The first one available in the game year is used ({"town_new_large", "town_old_large"}).
	largeStreetBaseNames : {string}
	--- Street segments in one command, 0 for all of them in one command (1). A node that segments of one command share is made once, with all its edges.
	edgesPerCommand : integer
	--- true adds an empty node config (no lane connections, no crosswalks) for every new node of a command. The default is true when a large street is in the grid, else false. Streets with several lanes per direction need it.
	explicitNodeConfigs : boolean
	--- How the nodes get lane connections, which an empty node config lacks. "own" writes them for every grid node after the last segment: straight on lane to lane (extra lanes merge into the curb lane, the lanes of a narrower street share the lanes of a wider one, and the curb lane of a street with several lanes only turns right), turns only from the curb lane to the right and from the lane next to the centre line to the left, each turn ending in the closest lane of the new street; a corner of two streets keeps parallel curves. "stub_remove" builds a short plain street out of each corner that keeps two streets, waits until another mod (Smart Lanes) has written the connections, and removes the street. "stub_keep" builds the street and leaves it. "off" does nothing. The default is "own" when explicitNodeConfigs is true, else "off".
	laneConnections : string
end
-- Module: ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_grid_builder.tl" as RubGridBuilderModule
global record RubGridBuilderModule
	--- Builds the grid from the street nearest to the camera, one command per segment. Raises an error when no street is near or no large template exists for the year.
	build : function(options : RubGridOptions)
	--- Sets the traffic light preference "no" on every node of the player where a street with several lanes per direction meets a street with one lane, one command per node. Logs the counts of removed and failed nodes at the end.
	removeLights : function()
	--- Rewrites the lane connections of every major-minor junction of the player that has no traffic light: no left turns, straight only between lanes of one kind (bus or normal), right turns only from the outer lane to the outer lane of one kind. U-turns stay. Logs the counts of changed, skipped and failed nodes at the end.
	removeLeftTurns : function()
	--- Adds a crosswalk on every street of every junction of the player (3 or more streets) where at least one street is a town street, which is no country road and has a sidewalk. A junction of only country roads and highways gets none. A crosswalk that exists stays. One command per junction. Logs the counts of changed, skipped and failed nodes at the end.
	addCrosswalks : function()
	--- Runs removeLights, then removeLeftTurns after the last light command finished.
	removeLightsAndLeftTurns : function()
	--- Replaces every small road (town or country, new or old, with its variants) that belongs to the player or to nobody, outside constructions, with its own template and sets every lane to `kmh` (default 30), one command per road. A road that already has the speed, or whose new segment would lose edge objects, is not replaced. Logs speed_start, the counts at the end, and speed_check with the number of small roads that still have another speed.
	setSmallRoadSpeed : function(kmh : number)
end
