-- Based on 'Bulk Bulldozer' by square17 (mod.io 6434884).
-- Global names are prefixed Rub. Globals are shared by all loaded mods.
-- Entities are plain integers.

--- Angles in radians, counter-clockwise from +x; heights in metres (world z).
global record RubRingArc
	startAngle : number
	angle : number
	length : number     -- arc length in metres (radius * angle)
	h0 : number
	h1 : number
end

--- Cubic Hermite curve of BaseEdge position0/1 and tangent0/1 in plan view (z dropped).
global record RubCurve
	p0x : number
	p0y : number
	t0x : number
	t0y : number
	p1x : number
	p1y : number
	t1x : number
	t1y : number
	-- World z of position0/1 and tangent0/1. Optional; nil means the terrain height is used.
	p0z : number
	t0z : number
	p1z : number
	t1z : number
end

--- true = that kind may be selected.
global record RubFilters
	roads : boolean          -- every street that is ours or has no PLAYER_OWNED; never another player's
	tracks : boolean         -- our edges without BASE_EDGE_STREET
	stations : boolean       -- our constructions with stations or depots
	assets : boolean         -- our other constructions (placed assets etc.)
	townBuildings : boolean  -- unowned constructions that are only town buildings
	underground : boolean    -- edges with BaseEdge.type == TUNNEL (any kind)
	surface : boolean        -- edges that are not tunnels; false (not nil) while the underground view is on
end

--- The local player. -1 = unknown or none.
global record RubContext
	player : integer   -- api.engine.util.getPlayer()
	hq : integer       -- PLAYER.headquarters of that player
end

--- Edge fields are set only when isEdge, construction fields only when not.
global record RubDesc
	entity : integer
	isEdge : boolean
	gone : boolean               -- no longer exists, or its main component could not be read
	full : boolean               -- every field read; false = only geometry / origin read
	owner : integer              -- PLAYER_OWNED.player, -1 when the component is missing
	parentConstruction : integer -- edge: getConstructionEntityForEdge; construction: the owner of a
	                             -- subconstruction; -1 when none
	isStreet : boolean           -- has BASE_EDGE_STREET
	isTunnel : boolean           -- BaseEdge.type == TUNNEL
	template : string            -- BaseEdge.roadTemplate
	tramOnly : boolean           -- a street whose lanes carry no car, bus or truck (a stand-alone tram track)
	industryRoad : boolean       -- a segment that goes with an industry (findSegmentsToDelete) or
	                             -- ends on a node frozen in an industry construction
	objects : {integer}          -- BaseEdge.objects entities (signals, stops, waypoints)
	node0 : integer              -- BaseEdge.node0 / node1
	node1 : integer
	curve : RubCurve
	x : number                   -- transf translation (origin)
	y : number
	stations : integer           -- # of Construction.stations
	depots : integer
	industries : integer
	townBuildings : integer
	frozen : integer             -- # frozenEdges + # frozenNodes
end

global enum RubKind
	"road"           -- a street, ours or unowned (town roads included)
	"track"          -- our track
	"station"        -- our station or depot construction
	"asset"          -- our other construction
	"town_building"  -- town building construction
	"industry"       -- industry construction (never kept)
	"other"          -- anything else (unowned track, landmark, mission prop; never kept)
end

global enum RubReason
	"gone"           -- entity vanished / unreadable
	"foreign"        -- PLAYER_OWNED by another player
	"part"           -- belongs to a construction (goes with it)
	"industry"       -- industry construction or industry road
	"hq"             -- our headquarters
	"not_player"     -- unowned and not a town road / town building
	"filtered"       -- its kind's toolbar filter is off
	"underground"    -- tunnel edge with "Underground" off
	"surface"        -- edge on the ground while the underground view is on
	"tram_only"      -- a stand-alone tram track (no lane for cars, buses or trucks)
	"track_type"     -- a track whose template is none of the six base track templates
end

--- reason == nil means keep.
global record RubCandidate
	entity : integer
	kind : RubKind
	reason : RubReason
	objects : integer   -- edge objects that go with an edge (0 for constructions)
end

--- The selection: every sample of every stroke since it was last cleared or upgraded.
global record RubStroke
	keep : {integer : RubCandidate}
	order : {integer}                           -- kept entities in the order they were added
	skipped : {integer : RubReason}   -- entity → reason (unique entities)
	kindCounts : {string : integer}             -- kept per kind
	reasonCounts : {string : integer}           -- skipped per reason
	objects : integer                           -- edge objects riding along with kept edges
	capped : boolean                            -- a keep was refused because of the cap
end

-- Module: ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/bb_brush.tl" as RubBrush
global record RubBrush
	RADII : {number}               -- toolbar slider steps in metres
	DEFAULT_RADIUS : number
	RING_ARCS : integer            -- arcs per ring (one EdgeRenderable edge each)
	SAMPLE_MIN_INTERVAL : number   -- seconds; a sample is due at least this often while the cursor moves
	SAMPLE_MOVE_FRACTION : number  -- or once the cursor moved this fraction of the radius
	EDGE_SAMPLES : integer
	EDGE_MARGIN : number           -- metres added to the edge octree query radius
	SAMPLE_MAX_ENTITIES : integer  -- per octree query; more hits are ignored

	--- Slider labels for RADII, e.g. "20 m".
	radiusLabels : function() : {string}
	--- 1-based index of r in RADII, or nil.
	radiusIndex : function(r : number) : integer
	--- A slider value read back from the menu (metres) as a valid radius, or nil if it is not one.
	radiusFromParam : function(v : number) : number
	--- The ring as n arcs; heightAt(x, y) gives the terrain height.
	ringArcs : function(cx : number, cy : number, r : number, n : integer,
		heightAt : function(number, number) : number) : {RubRingArc}
	--- Ring line width in metres for radius r.
	ringWidth : function(r : number) : number
	--- Sample-throttle policy: true when the cursor moved >= r * SAMPLE_MOVE_FRACTION
	--- or dt >= SAMPLE_MIN_INTERVAL since the last sample.
	sampleDue : function(dx : number, dy : number, dt : number, r : number) : boolean
	--- Radius for the BASE_EDGE octree query: r + EDGE_MARGIN.
	edgeQueryRadius : function(r : number) : number
	--- Point on the curve at t in [0, 1].
	hermite : function(c : RubCurve, t : number) : number, number
	pointSegmentDistance : function(px : number, py : number, ax : number, ay : number,
		bx : number, by : number) : number
	--- true when the curve comes within r of (cx, cy): EDGE_SAMPLES points, polyline distance.
	curveTouchesCircle : function(c : RubCurve, cx : number, cy : number, r : number) : boolean
	--- true when (px, py) is inside or on the circle.
	pointInCircle : function(px : number, py : number, cx : number, cy : number, r : number) : boolean
end

-- Module: ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/bb_select.tl" as RubSelect
global record RubSelect
	STROKE_CAP : integer               -- kept entities per selection
	CONSTRUCTION_ORIGIN_ONLY : boolean -- constructions hit only when their origin is in the circle
	KINDS : {RubKind}        -- display order
	REASONS : {RubReason}    -- display order

	defaultFilters : function() : RubFilters
	--- Filter field names in toolbar order.
	FILTER_KEYS : {string}
	--- CheckBox value (1-based index: 2 = on, 1 = off) → boolean; anything else → dflt.
	checkboxOn : function(v : number, dflt : boolean) : boolean
	--- One menu CheckBox value → true (2) / false (1) / nil (unknown).
	paramValue : function(v : number) : boolean
	--- keys: field → param key. Fields whose value is not 1 or 2 are left out.
	paramFilters : function(params : {string : number}, keys : {string : string}) : {string : boolean}
	--- Filters to use from the last shown toolbar values, the toggles seen per menu category and
	--- the defaults; unknown fields are OFF and returned in the 2nd result.
	resolveFilters : function(shown : {string : boolean}, toggles : {string : {string : boolean}},
		defaults : RubFilters) : RubFilters, {string}
	--- Hard rules first, then filters. reason nil = keep.
	classify : function(d : RubDesc, f : RubFilters, ctx : RubContext) : RubCandidate
	newStroke : function() : RubStroke
	--- Merge one candidate; returns true when it became a new keep. Respects STROKE_CAP.
	add : function(s : RubStroke, c : RubCandidate) : boolean
	--- Removes kept entities; returns how many were removed.
	remove : function(s : RubStroke, entities : {integer}) : integer
	count : function(s : RubStroke) : integer
	--- Kept entities in add order.
	entities : function(s : RubStroke) : {integer}
	--- Log lines (English, also compared for change detection): kept per kind (+ edge objects),
	--- skipped per reason, cap note.
	describe : function(s : RubStroke) : {string}
	--- Translated tooltip lines: the cap note (none when the selection is below the cap).
	limitLines : function(s : RubStroke) : {string}
end

--- Per-stroke cache.
global record RubGatherCache
	descs : {integer : RubDesc}
	industryRoads : {integer : boolean}   -- edge entity → protected
	industryCons : {integer : boolean}    -- industry construction already expanded
	conIsIndustry : {integer : boolean}   -- construction entity → has industries
	createdAt : number                    -- os.clock() at creation
end

global record RubSampleResult
	candidates : {RubCandidate}  -- hits that touch the circle, classified
	edgeHits : integer                      -- octree BASE_EDGE results (before the touch test)
	conHits : integer                       -- octree CONSTRUCTION results
	truncated : boolean                     -- a query returned more than SAMPLE_MAX_ENTITIES
	seconds : number                        -- wall time of the sample (os.clock)
end

-- Module: ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/bb_gather.tl" as RubGather
-- GUI thread only.
global record RubGather
	newCache : function() : RubGatherCache
	--- Our player and HQ (pcall; -1 when unreadable).
	context : function() : RubContext
	describeEdge : function(e : integer, cache : RubGatherCache) : RubDesc
	describeConstruction : function(e : integer, cache : RubGatherCache) : RubDesc
	--- One brush sample at (cx, cy) with radius r: every road whose curve comes within r is a candidate.
	sample : function(cx : number, cy : number, r : number, f : RubFilters,
		ctx : RubContext, cache : RubGatherCache) : RubSampleResult
end

--- Items are entity ids; batches are sent one at a time.
global record RubBatchPlan
	queue : {{integer}}     -- batches still to send, front first
	cap : integer           -- most commands this plan may send
	sent : integer          -- commands reported so far
	done : {integer}        -- items of batches that succeeded
	failed : {integer}      -- single items that failed on their own
	capSkipped : {integer}  -- items never sent because the command cap ran out
end

-- Module: ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/bb_batch.tl" as RubBatch
-- Pure: no api.* calls.
global record RubBatch
	MAX_COMMANDS : integer   -- hard cap of commands per stroke

	--- A plan that starts with all items in one batch.
	newPlan : function(items : {integer}, cap? : integer) : RubBatchPlan
	--- The next batch to send, or nil when the plan is finished. Once `sent` reaches `cap`,
	--- everything still queued moves to capSkipped and nil is returned.
	nextBatch : function(p : RubBatchPlan) : {integer}
	--- Report one sent command. success → items are done; failure → a single goes to failed,
	--- a larger batch is halved and both halves go to the front of the queue (order kept).
	report : function(p : RubBatchPlan, items : {integer}, success : boolean)
	--- The two halves of a list (first half gets the smaller part when odd).
	split : function(items : {integer}) : {integer}, {integer}
	--- Nodes left without any edge once `edgeEnds` ({node0, node1} per removed edge, edges
	--- unique) are gone. degree[n] = incident edges now (missing = unknown → kept);
	--- frozen[n] = owned by a construction → never. Sorted ascending.
	orphanNodes : function(edgeEnds : {{integer}}, degree : {integer : integer},
		frozen : {integer : boolean}) : {integer}
end

global record RubPreview
	ok : boolean          -- every makeProposalData call returned data
	cost : integer        -- sum of ProposalData.costs (sign as the engine reports it); nil if unknown
	critical : boolean    -- any errorState.critical
	errors : {string}     -- unique errorState.messages
	seconds : number      -- wall time (os.clock)
end

global record RubCommitResult
	requested : integer             -- entities handed to commit
	removed : integer               -- entities in successful commands
	unchanged : integer             -- roads that already were the target, left alone
	failed : {integer}              -- roads whose command failed twice (they keep their entity)
	skipped : integer               -- requested - removed - unchanged
	reasons : {string : integer}    -- skip reason → count
	commands : integer              -- commands sent
	refused : string                -- set when nothing was sent (money, nothing left); else nil
	cost : integer                  -- preflight cost (nil if unknown)
	seconds : number                -- wall time from commit() to onDone (os.clock)
	cancelled : boolean             -- stopped by cancel(): the roads not yet reached were left alone
	rail : boolean                  -- the edges were tracks
end

--- The add-ons of Road Upgrade All in One that change the lanes or the lock of the new segments.
global record RubExtras
	busLane : boolean
	tram : boolean
	catenary : boolean
	lock : string   -- "keep": the segments keep their lock; "lock"; "unlock"
end

-- Module: ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/bb_upgrade.tl" as RubCommit
-- GUI thread only.
global record RubCommit
	--- Commands per press: one per road.
	MAX_COMMANDS : integer

	--- Runs the next step of a running commit once the pause between two commands is over. The tool
	--- calls it on every step.
	tick : function()
	--- Stops the running commit after the road in progress; onDone then runs with cancelled set. Does nothing
	--- when no commit runs.
	cancel : function()
	--- Ends the running commit at once and ignores every later callback of it; the game speed is set back. onDone runs
	--- with cancelled set. The tool calls it when a commit has had no answer for too long. Does nothing when no commit runs.
	abort : function()
	--- One log line about a road: kind, template, edge objects, decorations, parcels.
	describeRoad : function(edge : integer) : string
	--- The test the commit uses to leave a road alone: whether a road already is what the upgrade to `template` with
	--- `extras` would make of it (road type, trees, barriers, bus lane, tram track, catenary, lock).
	matcher : function(template : string, extras : RubExtras) : function(edge : integer) : boolean
	--- The bus lane, tram track and catenary that a road with the street template carries (lock: "lock" when the road is
	--- locked, else "keep"). nil when the lanes of the road match none of the combinations, or the road cannot be read.
	extrasOf : function(edge : integer, template : string) : RubExtras
	--- The cost is unknown before the upgrade: makeProposalData rejects the proposal replaceSegment returns.
	preview : function(edges : {integer}, template : string) : RubPreview
	--- Re-checks the hard rules on fresh descriptors right before sending. Returns the roads that
	--- still pass, plus road → reason for the dropped ones. `industryRoads` carries the selection's
	--- industry-road protection over (bb_gather cache).
	assertHardRules : function(edges : {integer}, ctx : RubContext,
		industryRoads : {integer : boolean}, kind? : RubKind) : {integer}, {integer : string}
	--- Upgrades the roads to the street template with one command per road, one after the other. A road
	--- that already is the target is left alone; a road whose command fails is tried again, twice, after the
	--- others.
	--- `extras` are the bus lane, tram track, catenary and lock of Road Upgrade All in One; a road that already has them (and the template) is left alone.
	--- `onRoad` runs each time a road is done in the current pass: ok when it was upgraded, was already the target, or was
	--- dropped by the hard rules; not ok when its command failed. It gets the road, ok, the number of roads done in this
	--- pass, the number of roads in this pass, and the pass (0 = first, 1 and 2 = retries). At the start of a retry pass it
	--- runs once with no road (edge nil) and 0 done.
	--- With `railTarget` the edges are tracks: `template` is nil, and `railTarget` gives per track the template it gets and whether it has that template already (nil when the track gets none; it is then left alone). The hard rules then keep tracks, not roads.
	--- With `removeBuildings` the commands also demolish the buildings that block a road; without it such a road is
	--- skipped. Only one commit runs at a time: while one runs, a new commit sends nothing and onDone runs at once with
	--- `refused` set and every road in `failed`. onDone runs once, possibly from a sendCommand callback. In the result, `removed` counts the upgraded
	--- roads and `cost` is what the game charged for them (nil when it reports none).
	commit : function(edges : {integer}, template : string, extras : RubExtras, removeBuildings : boolean, ctx : RubContext,
		industryRoads : {integer : boolean},
		onDone : function(RubCommitResult), logFn : function(string),
		onRoad : function(edge : integer, ok : boolean, finished : integer, total : integer, attempt : integer),
		railTarget? : RubRailTarget)
	--- How many times the roads that failed are tried again.
	RETRY_PASSES : integer
end

--- A headline and a detail line for the status chip. Both are always set.
global record RubStatusText
	head : string
	detail : string
	severity : string  -- "error" (red), "warning" (yellow), "ok" (green) or nil
	hint : string      -- a third line under the two (the chip shows it only when set)
	running : boolean   -- the text is the progress of a running upgrade (the Clear button then reads Cancel)
	tail : string        -- a second part of the head line with its own colour (the chip shows it right after the head)
	tailSeverity : string
end

global record RubStatusInput
	phase : string                   -- "none" | "idle" (hover preview) | "painting" | "selected" | "committing"
	count : integer                  -- kept entities in the selection (or under the brush when idle)
	kindCounts : {string : integer}  -- kept per RubKind
	objects : integer                -- edge objects riding along
	cost : string                    -- formatted preview cost, nil when unknown
	capped : boolean                 -- the selection hit STROKE_CAP
	cap : integer                    -- STROKE_CAP
	result : RubStatusText -- a recent result / notice (shown instead of "Nothing selected"), or nil
	progressDone : integer           -- roads done in the current pass of the running upgrade
	progressTotal : integer          -- roads in the current pass
	retryAttempt : integer          -- 0 in the first pass, 1 and 2 in the retry passes
	retryPasses : integer           -- how many retry passes there are
end

-- Module: ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/bb_status.tl" as RubStatus
-- Pure: no api.* calls.
global record RubStatus
	MAX_CHARS : integer       -- per line; longer lines are clipped with "..."
	MAX_KIND_PARTS : integer  -- kinds listed on the detail line before "..."

	--- "8 roads · 3 tracks · 1 asset" (+ signals/stops), at most MAX_KIND_PARTS parts.
	kindSummary : function(kindCounts : {string : integer}, objects : integer) : string
	--- Display width of s: 1 per character, 2 per CJK / Hangul / full-width character (U+3000 and up).
	width : function(s : string) : integer
	--- Clip s to at most n display columns (status.width; UTF-8 safe), appending "..." when clipped.
	clip : function(s : string, n : integer) : string
	--- Translated display text of a skip reason / refusal (English text from bb_upgrade); unknown
	--- reasons (the game's own error messages) are returned unchanged.
	reasonLabel : function(reason : string) : string
	idle : function() : RubStatusText
	lines : function(v : RubStatusInput) : RubStatusText
	resultLines : function(r : RubCommitResult) : RubStatusText
	oneLine : function(t : RubStatusText) : string
end

--- Colours of one highlight state as plain rgba {r, g, b, a} in [0, 1].
global record RubHighlightColors
	fill : {number}       -- Selector.selectionColor
	outline : {number}    -- Selector.selectionOutlineColor
	outline1 : {number}   -- Selector.selectionOutlineColor1
	line : {number}       -- overlay lines / construction markers (EdgeRenderable)
	lineWidth : number    -- overlay line width in metres
end

--- World coordinates.
global record RubSegment
	x0 : number
	y0 : number
	z0 : number
	x1 : number
	y1 : number
	z1 : number
end

-- Module: ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/bb_highlight.tl" as RubHighlight
-- Pure: no api.* calls.
global record RubHighlight
	MODE : string                    -- "engine" | "lines" | "both" (default)
	HOVER_ONLY_HIGHLIGHTED : boolean -- Selector filter accepts only highlighted entities
	MAX_SEGMENTS : integer           -- overlay pieces (lines + markers) per render
	SEGMENT_LENGTH : number          -- metres per piece
	MAX_PER_EDGE : integer           -- pieces per edge at most
	LINE_OFFSET_Z : number           -- metres above the edge
	MARKER_RADIUS : number           -- construction marker circle radius in metres

	usesEngine : function(mode : string) : boolean
	usesLines : function(mode : string) : boolean
	--- "idle" (hover preview) → light coral; any other phase (the selection) → red.
	colors : function(phase : string) : RubHighlightColors
	--- The colours of a road that already is what the upgrade would make of it: the same phases, in blue.
	sameColors : function(phase : string) : RubHighlightColors
	--- Upper bound of the curve length in plan view (Bezier control polygon).
	curveLength : function(c : RubCurve) : number
	--- Pieces for an edge of this length: ceil(length / SEGMENT_LENGTH) in [1, MAX_PER_EDGE].
	piecesFor : function(length : number) : integer
	--- Hermite height at t, nil when the curve has no z.
	curveZ : function(c : RubCurve, t : number) : number
	--- Straight pieces along all curves, at most maxSegments: over budget every edge gets fewer
	--- pieces (at least one), then trailing edges are dropped (truncated = true). Heights from the
	--- curve's z, else heightAt(x, y), else 0.
	edgeSegments : function(curves : {RubCurve}, maxSegments : integer,
		heightAt? : function(number, number) : number) : {RubSegment}, boolean
	--- The budget split edgeSegments uses: pieces per curve, how many curves fit, truncated.
	piecePlan : function(curves : {RubCurve}, maxSegments : integer) : {integer}, integer, boolean
	--- One curve cut into n straight pieces (heights as in edgeSegments).
	curveSegments : function(c : RubCurve, n : integer,
		heightAt? : function(number, number) : number) : {RubSegment}
	--- One log line naming the active path.
	describeMode : function(mode : string) : string
end
