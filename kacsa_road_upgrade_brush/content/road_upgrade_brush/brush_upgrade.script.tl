-- Based on 'Bulk Bulldozer' by square17 (mod.io 6434884).
-- Road upgrade brush: paint over roads, then press Upgrade (Road tools). Selection, brush, highlight and toolbar come
-- from the Bulk Bulldozer tool; bb_upgrade.tl upgrades the roads.
--
-- Wiring: brush_upgrade.res.lua → getDefinition below → ACTION_CUSTOM with the BrushUpgradeAction recipe. The
-- construction menu mounts the recipe while the entry is selected and the recipe hands the world-layer body to
-- params.setActionFn. getDefinition may run in a different Lua VM than the recipe. Toolbar values reach the
-- recipe through onChangeFn → api.gui.fireReactEvent → react.onEvent, and getCurrentParams() on activation.

local sqperf = ug_require "kacsa_road_upgrade_brush::/sqperf/kacsa_road_upgrade_brush.lua" as RubSqPerf
local perf = sqperf.new({ mod = "kacsa_road_upgrade_brush", ctx = "gui", paramKey = "sqperf_log", first = { "action_render" } })
local perfInit = perf:start()

local react =ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local constructionUi = ug_require "::/gui/construction/construction_react_util.tl" as ConstructionReactUtil
local brush = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/bb_brush.tl" as RubBrush
local sel = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/bb_select.tl" as RubSelect
local gather = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/bb_gather.tl" as RubGather
local commit = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/bb_upgrade.tl" as RubCommit
local status = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/bb_status.tl" as RubStatus
local hl = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/bb_highlight.tl" as RubHighlight
local brushOptions = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/brush_options.tl" as RubBrushOptions
local brushStyle = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/brush_style.tl" as RubStyle
local probe = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/proposal_probe.tl" as RubProposalProbe

local PREFIX <const> = "[BrushUpgrade] "
local EV_RADIUS <const> = "BrushUpgrade.radius"
local EV_UPGRADE <const> = "BrushUpgrade.upgrade"
local EV_SHOWN <const> = "BrushUpgrade.shown"
local EV_CLEAR <const> = "BrushUpgrade.clear"
local EV_STATUS <const> = "BrushUpgrade.status"
local KEY_RADIUS <const> = "brush_upgrade_radius"
local KEY_UPGRADE <const> = "brush_upgrade_upgrade"
local KEY_CLEAR <const> = "brush_upgrade_clear"
local KEY_STATUS <const> = "brush_upgrade_status"
-- Input actions of the game: the rotation keys of its construction tools (default keys M and N, rebindable in the game).
local IA_RADIUS_GROW <const> = "constructOpt1"
local IA_RADIUS_SHRINK <const> = "constructOpt2"
-- Toolbar groups: consecutive params with the same `group` and hideLabel share one horizontal row; a named group
-- gets a separator line before it.
local GROUP_ACTIONS <const> = "brush_upgrade_actions"
-- The status chip's group id is the class that brush_upgrade.css.lua scopes its rules under.
-- The stylesheet parser reads class names as [%a%d-]+ only.
local GROUP_INFO <const> = "sq-tool-info"

-- What the selection shows: the hover preview (nothing selected), a stroke being painted (LMB held, adding), the
-- selection waiting for Upgrade (LMB released), or the selection being upgraded.
local PHASE_IDLE <const> = "idle"
local PHASE_PAINTING <const> = "painting"
local PHASE_SELECTED <const> = "selected"
local PHASE_COMMITTING <const> = "committing"

-- A result / notice stays in the status chip this long (seconds).
local RESULT_SECONDS <const> = 3.0
-- A commit with no progress (no road finished, no retry pass started) for this long is given up on screen (seconds).
-- The time counts from the last progress.
local COMMIT_TIMEOUT <const> = 120.0

-- The ring follows the cursor once it moved this far (metres); smaller moves don't re-render.
local CURSOR_EPS <const> = 0.25
-- Moved events are summarised in one log line at most this often (seconds).
local MOVED_LOG_INTERVAL <const> = 0.5
-- The hover preview drops its descriptor cache this often (seconds).
local HOVER_CACHE_TTL <const> = 2.0
-- A sample slower than this is logged (seconds), at most once a second.
local SLOW_SAMPLE <const> = 0.004
-- Debug aid: the hover tooltip also shows the raw octree counts for exactly radius r. Two extra native queries per
-- hover sample.
local DEBUG_OCTREE <const> = false
-- Right click: only PressedOutside and Clicked of button 2 reach the Selector. A Clicked this far (screen px, either
-- axis) from its press is a camera drag, not a click: the selection stays.
local RMB_CLICK_MAX_PX <const> = 16
-- The world layer (actionFn) counts as closed once it stays unmounted this long (os.clock s). An
-- unmount followed by a mount in the same frame (re-binding) is not a close.
local LAYER_GONE_SECONDS <const> = 0.25
-- Held at the LMB press: the stroke removes from the selection (base hold modifier, Shift by default).

local IA_ERASE <const> = "IA_PRECISION_MODE"

-- The toolbar params map the menu last passed to the status chip's checkEnabledFn (EV_SHOWN carries it
-- across Lua states). The upgrade reads the road type, trees and barrier choice from it.
local g_toolParams : {string : number} = {}

-- The brush radius (m) the player chose last. Like g_toolParams it lives until the GUI is rebuilt.

local g_radius : number = nil

-- The menu's params API from the last toolbar callback that got it. nil until one toolbar control was used.

local g_menuApi : ConstructionMenuParamsAPI = nil

local function rememberApi(menuApi : ConstructionMenuParamsAPI)
	if menuApi ~= nil then g_menuApi = menuApi end
end

-- The view the shortcut asked for, while the toolbar button still shows the value it had then. It holds until the
-- button changes (the player clicked it, or the shortcut reached it).
local record ViewOverride
	on : boolean
	buttonWas : boolean
end
local g_viewOverride : ViewOverride = nil

-- The menu hands a reference to the params API of its bottom bar, where the toolbar params live, to getActionParams
-- whenever it builds the action of the selected tool (its eighth argument).

local type GetActionParams = function(definition : ConstructionDefinition, params : {string : number}, repository : ConstructionActionRepository,
	isGamepadMode : boolean, refParams : ReactRefWrapApiT<any, ConstructionMenuParamsAPI>, entity : Engine.Entity,
	accessNotificationCacheFn : (function(Engine.Entity) : {Notification}), sublistParamsApi : ReactRefWrapApiT<any, ConstructionMenuParamsAPI>,
	disableLayersIA : boolean) : ConstructionMenuActionParams

local g_paramsRef : ReactRefWrapApiT<any, ConstructionMenuParamsAPI> = nil
local g_captureInstalled = false

local function installApiCapture()
	if g_captureInstalled then return end
	g_captureInstalled = true
	local current = constructionUi.getActionParams as GetActionParams
	constructionUi.getActionParams = function(definition : ConstructionDefinition, params : {string : number}, repository : ConstructionActionRepository,
			isGamepadMode : boolean, refParams : ReactRefWrapApiT<any, ConstructionMenuParamsAPI>, entity : Engine.Entity,
			accessNotificationCacheFn : (function(Engine.Entity) : {Notification}), sublistParamsApi : ReactRefWrapApiT<any, ConstructionMenuParamsAPI>,
			disableLayersIA : boolean) : ConstructionMenuActionParams
		if sublistParamsApi ~= nil then g_paramsRef = sublistParamsApi end
		return current(definition, params, repository, isGamepadMode, refParams, entity, accessNotificationCacheFn, sublistParamsApi, disableLayersIA)
	end
end

local function menuParamsApi() : ConstructionMenuParamsAPI
	if g_paramsRef ~= nil then
		local ok, got = pcall(function() : ConstructionMenuParamsAPI
			if g_paramsRef:hasExpired() or g_paramsRef:get() == nil or g_paramsRef:get():getIdentity() == nil then return nil end
			return g_paramsRef:get():getApi()
		end)
		if ok and got ~= nil then return got end
	end
	return g_menuApi
end

-- The shortcut reaches every instance of the tool recipe at once, and a key held down repeats. Instances that get the
-- same press share its decision; a press right after another is ignored.
local SHORTCUT_SAME_PRESS <const> = 0.05
local SHORTCUT_MIN_GAP <const> = 0.3
local record ShortcutPress
	at : number
	want : boolean
end
local g_lastShortcut : ShortcutPress = nil

-- Switches the Underground button of the toolbar; false when the menu's API is not at hand.
local function setUndergroundButton(on : boolean) : boolean
	local menu = menuParamsApi()
	if menu == nil then return false end
	local changed = false
	local ok = pcall(function()
		local info = menu.getParamByKey("undergroundMode")
		if info ~= nil then
			menu.changeParam(info.index, on and 1 or 2)
			changed = true
		end
	end)
	return ok and changed
end

local function logMsg(msg : string)
	pcall(function() log.message(PREFIX .. msg) end)
end

local function diagMsg(msg : string)
	if probe.ENABLED then logMsg(msg) end
end

-- Changes with every edit of the mod.
local BUILD <const> = "2026-10-31 ba"
logMsg("script loaded, build " .. BUILD)

-- Chatty diagnostics (every mouse event, Moved summaries): only with "Debug: performance log" On
-- (SQPERF level 3, re-read every 30 s).
local function debugLog() : boolean
	return perf.on
end

local record RadiusEvent
	meters : number
end
local record ShownEvent
	params : {string : number}
end
local record RubActionParam end
local record MovedLog
	count : integer       -- Moved events since the last summary
	withLmb : integer     -- of those, while LMB was held
	handled : integer     -- of those, with evt.handled already set
	lastAt : number       -- os.clock() of the last summary
end
local record Sample
	x : number
	y : number
	r : number
	at : number
end
-- Everything about the current selection; mutated in place, re-rendered via versionState.
local record Selection
	phase : string
	stroke : RubStroke
	cache : RubGatherCache
	ctx : RubContext
	samples : integer
	worst : number          -- slowest sample in seconds
	truncated : boolean     -- an octree query hit SAMPLE_MAX_ENTITIES
	slowLoggedAt : number
	rawEdges : integer      -- DEBUG_OCTREE: octree BASE_EDGE hits at exactly r (-1 = query failed)
	rawCons : integer       -- DEBUG_OCTREE: octree CONSTRUCTION hits at exactly r
	preview : RubPreview  -- last makeProposalData summary of the stroke (nil = none yet)
	previewAt : number      -- os.clock() of that preview
	previewCount : integer  -- stroke size it was computed for
	previewTemplate : string  -- street template it was computed for
	commitAt : number       -- os.clock() when the commit started
	progressDone : integer   -- roads the running upgrade has finished (and taken out of the selection)
	progressTotal : integer  -- roads in the current pass
	retryAttempt : integer  -- 0 in the first pass of the upgrade, 1 and 2 in the retry passes
	erasing : boolean       -- the stroke being painted removes instead of adds (Shift)
end
local record RmbPress
	x : integer
	y : integer
end
local record ResultLine
	text : RubStatusText
	untilAt : number        -- os.clock() deadline
	sticky : boolean        -- shown until the next stroke, upgrade or clear, whatever is selected (the end of a run)
end

-- Status chip text shared between the action recipe (writer) and the RubStatus recipe in the toolbar
-- (reader). The construction menu loads this file once. The EV_STATUS event carries the same text across Lua states.

local record StatusEvent
	head : string
	detail : string
	severity : string
	hint : string
	running : boolean
	tail : string
	tailSeverity : string
	version : integer
end
-- File-scope state outlives the recipe (the module stays loaded across unmounts). The action recipe resets it on
-- mount and unmount (resetStatus).
local g_status : StatusEvent = { head = status.idle().head, detail = status.idle().detail, severity = nil, hint = nil, running = false, tail = nil, tailSeverity = nil, version = 0 }

local function publishStatus(t : RubStatusText)
	g_status = { head = t.head, detail = t.detail, severity = t.severity, hint = t.hint, running = t.running, tail = t.tail, tailSeverity = t.tailSeverity, version = g_status.version + 1 }
	pcall(api.gui.fireReactEvent, EV_STATUS, g_status)
end

local function resetStatus()
	publishStatus(status.idle())
end

local function newSelection(phase : string) : Selection
	return {
		phase = phase,
		stroke = sel.newStroke(),
		cache = gather.newCache(),
		ctx = gather.context(),
		samples = 0,
		progressDone = 0,
		progressTotal = 0,
		retryAttempt = 0,
		worst = 0,
		truncated = false,
		slowLoggedAt = 0,
	}
end

local function eventTypeName(t : Gui.Mouse.Event.Type) : string
	local T = api.gui.mouse.Event.Type
	if t == T.Pressed then return "Pressed"
	elseif t == T.Released then return "Released"
	elseif t == T.Moved then return "Moved"
	elseif t == T.Wheel then return "Wheel"
	elseif t == T.Clicked then return "Clicked"
	elseif t == T.DoubleClicked then return "DoubleClicked"
	elseif t == T.Entered then return "Entered"
	elseif t == T.Exited then return "Exited"
	elseif t == T.PressedOutside then return "PressedOutside"
	end
	return tostring(t)
end

local function paramsToString(p : {string : number}) : string
	if p == nil then return "nil" end
	local keys : {string} = {}
	for k in pairs(p) do keys[#keys + 1] = k end
	table.sort(keys)
	local parts : {string} = {}
	for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(p[k]) end
	return "{" .. table.concat(parts, ", ") .. "}"
end

local function filtersToString(f : RubFilters) : string
	local on : {string} = {}
	local ff = f as {string : boolean}
	for _, k in ipairs(sel.FILTER_KEYS) do
		if ff[k] then on[#on + 1] = k end
	end
	return "{" .. table.concat(on, ", ") .. "}"
end

local function rawCount(x : number, y : number, r : number, t : Engine.ComponentType) : integer
	local ok, res = pcall(api.engine.util.octree.findEntitiesInCircle, api.type.Vec2f.new(x, y), r, t)
	return (ok and res ~= nil) and #res or -1
end

local function terrainHeight(x : number, y : number) : number
	return api.engine.terrain.getHeightAt(api.type.Vec2f.new(x, y))
end

local function ringEdges(cx : number, cy : number, r : number, color : Vec4f) : {Builtin.Type.EdgeRenderable.Edge}
	local edges : {Builtin.Type.EdgeRenderable.Edge} = {}
	local width = brush.ringWidth(r)
	for _, a in ipairs(brush.ringArcs(cx, cy, r, brush.RING_ARCS, terrainHeight)) do
		local arc = api.type.EdgeGeometry.Arc.new()
		arc.center = api.type.Vec2f.new(cx, cy)
		arc.radius = r
		arc.startAngle = a.startAngle
		arc.angle = a.angle
		local g = api.type.EdgeGeometry.new()
		g.arc = arc
		g.height = api.type.Vec2f.new(a.h0, a.h1)
		g.width = width
		g.length = a.length
		local viz = builtin.type.EdgeRenderable.Edge.new(g)
		viz.colors = { color, color, color }
		viz.stepSize = 1
		viz.width = width
		viz.offsetZ = 1.0
		edges[#edges + 1] = viz
	end
	return edges
end

local function safeHeight(x : number, y : number) : number
	local ok, h = pcall(terrainHeight, x, y)
	if ok and h ~= nil then return h end
	return 0
end

local function vec4(c : {number}) : Vec4f
	return api.type.Vec4f.new(c[1], c[2], c[3], c[4])
end

local function segmentEdge(sg : RubSegment, color : Vec4f, width : number) : Builtin.Type.EdgeRenderable.Edge
	local dx, dy = sg.x1 - sg.x0, sg.y1 - sg.y0
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 0.05 then return nil end
	local st = api.type.EdgeGeometry.Straight.new()
	st.pos = { api.type.Vec2f.new(sg.x0, sg.y0), api.type.Vec2f.new(sg.x1, sg.y1) }
	local g = api.type.EdgeGeometry.new()
	g.straight = st
	g.height = api.type.Vec2f.new(sg.z0, sg.z1)
	g.width = width
	g.length = len
	local viz = builtin.type.EdgeRenderable.Edge.new(g)
	viz.colors = { color, color, color }
	viz.stepSize = 1
	viz.width = width
	viz.offsetZ = hl.LINE_OFFSET_Z
	return viz
end

local function markerEdge(x : number, y : number, color : Vec4f, width : number) : Builtin.Type.EdgeRenderable.Edge
	local z = safeHeight(x, y)
	local r = hl.MARKER_RADIUS
	local arc = api.type.EdgeGeometry.Arc.new()
	arc.center = api.type.Vec2f.new(x, y)
	arc.radius = r
	arc.startAngle = 0
	arc.angle = 2 * math.pi
	local g = api.type.EdgeGeometry.new()
	g.arc = arc
	g.height = api.type.Vec2f.new(z, z)
	g.width = width
	g.length = 2 * math.pi * r
	local viz = builtin.type.EdgeRenderable.Edge.new(g)
	viz.colors = { color, color, color }
	viz.stepSize = 1
	viz.width = width
	viz.offsetZ = hl.LINE_OFFSET_Z
	return viz
end

-- Returns true when the stroke changed.
local function takeSample(s : Selection, x : number, y : number, r : number, f : RubFilters) : boolean
	local tPerf = perf:start()
	local ok, res = pcall(gather.sample, x, y, r, f, s.ctx, s.cache)
	-- Wall milliseconds (SQPERF's Clock). res.seconds is os.clock and reads 3-6x high under load.
	local ms = perf:stop("sample", tPerf)
	if not ok then
		logMsg("sample failed: " .. tostring(res))
		return false
	end
	s.samples = s.samples + 1
	if res.seconds > s.worst then s.worst = res.seconds end
	if res.truncated then s.truncated = true end
	if ms > SLOW_SAMPLE * 1000 and os.clock() - s.slowLoggedAt >= 1.0 then
		s.slowLoggedAt = os.clock()
		logMsg(string.format("slow sample: %.1f ms (r = %d m, %d edges, %d constructions in query)",
			ms, math.floor(r), res.edgeHits, res.conHits))
	end
	local before = sel.count(s.stroke)
	local skippedBefore = 0
	for _, n in pairs(s.stroke.reasonCounts) do skippedBefore = skippedBefore + n end
	for _, c in ipairs(res.candidates) do sel.add(s.stroke, c) end
	local skippedAfter = 0
	for _, n in pairs(s.stroke.reasonCounts) do skippedAfter = skippedAfter + n end
	return sel.count(s.stroke) ~= before or skippedAfter ~= skippedBefore
end

-- One Shift-stroke sample: every selected entity the brush touches leaves the selection, whatever
-- the filters say. Returns true when the selection changed.
local function eraseSample(s : Selection, x : number, y : number, r : number, f : RubFilters) : boolean
	local tPerf = perf:start()
	local ok, res = pcall(gather.sample, x, y, r, f, s.ctx, s.cache)
	perf:stop("erase_sample", tPerf)
	if not ok then
		logMsg("erase sample failed: " .. tostring(res))
		return false
	end
	s.samples = s.samples + 1
	if res.seconds > s.worst then s.worst = res.seconds end
	local hit : {integer} = {}
	for _, c in ipairs(res.candidates) do hit[#hit + 1] = c.entity end
	return sel.remove(s.stroke, hit) > 0
end

local function shiftHeld() : boolean
	local ok, on = pcall(function() : boolean
		return api.gui.inputAction.modifierOnlyActionIsActive(IA_ERASE)
	end)
	return ok and on == true
end

local EDGE_KINDS : {string : boolean} = { road = true, track = true }

-- The stroke's kept entities split into edges and constructions (add order).
local function strokeLists(st : RubStroke) : {integer}, {integer}
	local edges : {integer} = {}
	local cons : {integer} = {}
	for _, e in ipairs(st.order) do
		local c = st.keep[e]
		if c ~= nil and EDGE_KINDS[c.kind as string] then edges[#edges + 1] = e else cons[#cons + 1] = e end
	end
	return edges, cons
end

-- The highlight overlay of one selection state, cached until the selection or phase changes.

local record Overlay
	key : string
	edges : {Builtin.Type.EdgeRenderable.Edge}
	pieces : integer      -- straight pieces along edges
	markers : integer     -- construction circles
	truncated : boolean   -- MAX_SEGMENTS reached; some pieces / edges left out
end

-- Overlay pieces per entity, reused across rebuilds. An entity's pieces depend only on its descriptor (same gather
-- cache), the phase colours and its piece count.

local record PieceEntry
	n : integer                                  -- piece count it was cut into (markers: 0)
	edges : {Builtin.Type.EdgeRenderable.Edge}
end
local record PieceCache
	owner : RubGatherCache             -- the descriptors these pieces were made from
	byPhase : {string : {integer : PieceEntry}}
end

local function pieceTable(pc : PieceCache, phase : string) : {integer : PieceEntry}
	local t = pc.byPhase[phase]
	if t == nil then
		t = {}
		pc.byPhase[phase] = t
	end
	return t
end

local function buildOverlay(s : Selection, phase : string, key : string, pc : PieceCache, budget : integer) : Overlay
	local c = hl.colors(phase)
	local color = vec4(c.line)
	local cached = pieceTable(pc, phase)
	local curves : {RubCurve} = {}
	local curveOf : {integer} = {}
	local points : {RubDesc} = {}
	for _, e in ipairs(s.stroke.order) do
		local cand = s.stroke.keep[e]
		local d = s.cache.descs[e]
		if cand ~= nil and d ~= nil and not d.gone then
			if EDGE_KINDS[cand.kind as string] then
				if d.curve ~= nil then
					curves[#curves + 1] = d.curve
					curveOf[#curves] = e
				end
			elseif d.x ~= nil and d.y ~= nil then
				points[#points + 1] = d
			end
		end
	end
	local out : Overlay = { key = key, edges = {}, pieces = 0, markers = 0, truncated = false }
	local markerBudget = math.min(#points, math.floor(budget / 4))
	if markerBudget < #points then out.truncated = true end
	for i = 1, markerBudget do
		local d = points[i]
		local pe = cached[d.entity]
		if pe == nil or pe.n ~= 0 then
			pe = { n = 0, edges = { markerEdge(d.x, d.y, color, c.lineWidth) } }
			cached[d.entity] = pe
		end
		out.edges[#out.edges + 1] = pe.edges[1]
		out.markers = out.markers + 1
	end
	local plan, fit, trunc = hl.piecePlan(curves, budget - out.markers)
	if trunc then out.truncated = true end
	for i = 1, fit do
		local e = curveOf[i]
		local pe = cached[e]
		if pe == nil or pe.n ~= plan[i] then
			pe = { n = plan[i], edges = {} }
			for _, sg in ipairs(hl.curveSegments(curves[i], plan[i], safeHeight)) do
				local v = segmentEdge(sg, color, c.lineWidth)
				if v ~= nil then pe.edges[#pe.edges + 1] = v end
			end
			cached[e] = pe
		end
		for _, v in ipairs(pe.edges) do
			out.edges[#out.edges + 1] = v
			out.pieces = out.pieces + 1
		end
	end
	return out
end

local function moneyText(c : integer) : string
	if c == nil then return "cost unknown" end
	local ok, t = pcall(api.util.formatMoney, c)
	if ok and t ~= nil then return t end
	return tostring(c)
end

local function previewCost(s : Selection) : integer
	if s.preview == nil then return nil end
	return s.preview.cost
end

-- makeProposalData summary of the whole stroke.
local function updatePreview(s : Selection)
	local tPerf = perf:start()
	local edges = strokeLists(s.stroke)
	local template = brushOptions.template(g_toolParams)
	local ok, pv = pcall(commit.preview, edges, template)
	perf:stop("preview", tPerf)
	if not ok then
		logMsg("preview failed: " .. tostring(pv))
		pv = { ok = false, cost = nil, critical = false, errors = {}, seconds = 0 }
	end
	if pv.seconds > 0.02 then
		logMsg(string.format("slow preview: %.1f ms for %d objects", pv.seconds * 1000, sel.count(s.stroke)))
	end
	s.preview = pv
	s.previewAt = os.clock()
	s.previewCount = sel.count(s.stroke)
	s.previewTemplate = template
end

local function logStroke(what : string, s : Selection)
	logMsg(string.format("%s: %d selected, cost %s, %d samples, worst %.1f ms%s — %s",
		what, sel.count(s.stroke), moneyText(previewCost(s)),
		s.samples, s.worst * 1000, s.stroke.capped and ", capped" or "",
		table.concat(sel.describe(s.stroke), " / ")))
end

-- Underground view: with "Underground" on, the world layer shows what the base bulldozer's Underground button shows:
-- LayerConfig.undergroundMode plus the white screen. The menu's own LayerConfig never applies to this entry
-- (setActionFn replaces the menu's actionFn that renders it). The layer is a child of our ActionDescriptor.
-- Built once per Lua state; nil where the platform lacks a piece (then no underground view, the filter still
-- selects tunnels).
local g_undergroundLayer : LayerConfig = nil
local g_undergroundTried = false

local function undergroundLayerConfig() : LayerConfig
	if g_undergroundTried then return g_undergroundLayer end
	g_undergroundTried = true
	local ok, err : boolean, any = pcall(function()
		local cfg = api.type.LayerConfig.new()
		cfg.undergroundMode = true
		local cu = constructionUi as {string : any}
		if type(cu.makeWhiteScreen) == "function" then
			local layerColors = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/layers/layer_colors.gres")).data as LayerColors
			constructionUi.makeWhiteScreen(cfg, layerColors)
		end
		g_undergroundLayer = cfg
	end)
	if not ok then logMsg("underground view unavailable: " .. tostring(err)) end
	return g_undergroundLayer
end

-- The same layer with the underground view explicitly off. It replaces the underground layer when the view is
-- switched off.
local g_surfaceLayer : LayerConfig = nil

local function surfaceLayerConfig() : LayerConfig
	if g_surfaceLayer == nil then
		local cfg = api.type.LayerConfig.new()
		cfg.undergroundMode = false
		g_surfaceLayer = cfg
	end
	return g_surfaceLayer
end

local function undergroundLayer(on : boolean) : TreeNodeId
	local recipe = (builtin as {string : any}).LayerConfig as function(p : table) : TreeNodeId
	if recipe == nil then return nil end
	local cfg = on and undergroundLayerConfig() or surfaceLayerConfig()
	if cfg == nil then return nil end
	return recipe({ config = cfg })
end

-- When the game gives no terrain position under the cursor for a while, the log says so (at most
-- NO_TERRAIN_MAX_LINES lines per session).
local NO_TERRAIN_AFTER <const> = 1.5
local NO_TERRAIN_MAX_LINES <const> = 12
local g_noTerrainSince : number = nil
local g_noTerrainLines = 0

-- Cursor diagnostic (only with probe.ENABLED): after the tool is activated or its world layer is mounted again, the
-- step logs the terrain position under the cursor and the ring position every DIAG_INTERVAL seconds, at most
-- DIAG_EPISODE_LINES lines per session. The first step after the world layer is gone also logs once.

local DIAG_INTERVAL <const> = 1.5
local DIAG_EPISODE_LINES <const> = 12
local g_diagArmed = false
local g_diagLines = 0
local g_diagNextAt : number = 0
local g_noLayerLogged = false
-- Number of tool instances created in this session.
local g_instances = 0

-- The instance whose world layer is mounted (the one the game draws and sends the mouse events to), and the way to
-- give it the tool state of the newest instance (see the step). The state passed in stays for PUSH_GRACE_SECONDS.
local PUSH_GRACE_SECONDS <const> = 0.5
local g_layerOwnerId = 0
local g_layerOwnerSetParam : function(ConstructionCustomActionParams<RubActionParam>) = nil
local g_passLogged = false

local function armDiagnostic()
	g_diagArmed = probe.ENABLED
	g_diagLines = 0
end

local function logNoTerrain(lmbDown : boolean)
	local now = os.clock()
	if g_noTerrainSince == nil then g_noTerrainSince = now end
	if now - g_noTerrainSince >= NO_TERRAIN_AFTER and g_noTerrainLines < NO_TERRAIN_MAX_LINES then
		g_noTerrainLines = g_noTerrainLines + 1
		g_noTerrainSince = now
		logMsg(string.format("no terrain position under the cursor for %.1f s (left button %s, underground button %s)",
			NO_TERRAIN_AFTER, lmbDown and "down" or "up", tostring(g_toolParams["undergroundMode"])))
	end
end

local RubAction = react.RegisterRecipe("BrushUpgradeAction",
	perf:wrap("action_render", function(param : ConstructionCustomActionParams<RubActionParam>) : TreeNodeId

	-- All hooks first, in a fixed order; the isActive gate comes after them.
	local radiusState = react.useState(g_radius or brush.DEFAULT_RADIUS) as ReactStateT<number>
	local filtersState = react.useState(sel.defaultFilters()) as ReactStateT<RubFilters>
	local cursorState = react.useState(nil) as ReactStateT<Vec3f>
	local versionState = react.useState(0) as ReactStateT<integer>
	local refLmbDown = react.useRef(false) as ReactRefT<boolean>
	local refShift = react.useRef(false) as ReactRefT<boolean>      -- Shift held at the last step
	local refRmbPress = react.useRef(nil) as ReactRefT<RmbPress>
	local refRenderActive = react.useRef(false) as ReactRefT<boolean> -- isActive at the last render
	local refLayerDownAt = react.useRef(nil) as ReactRefT<number>     -- os.clock() the world layer unmounted
	local refLayerUp = react.useRef(false) as ReactRefT<boolean>      -- world layer mounted: this entry is the selected tool
	local refInstance = react.useRef(0) as ReactRefT<integer>         -- number of this instance
	if refInstance:get() == 0 then
		g_instances = g_instances + 1
		refInstance:set(g_instances)
		diagMsg(string.format("instance #%d created", g_instances))
	end

	local refSkipRelease = react.useRef(false) as ReactRefT<boolean>
	local refSample = react.useRef(nil) as ReactRefT<Sample>
	-- Hover preview while a selection waits: the roads under the ring that are not selected yet.
	local refHover = react.useRef(nil) as ReactRefT<Selection>
	local refHoverSample = react.useRef(nil) as ReactRefT<Sample>
	local refHoverOverlay = react.useRef(nil) as ReactRefT<Overlay>
	local refHoverPieces = react.useRef(nil) as ReactRefT<PieceCache>
	local refSel = react.useRef(nil) as ReactRefT<Selection>
	local refVersion = react.useRef(0) as ReactRefT<integer>
	local refMoved = react.useRef({ count = 0, withLmb = 0, handled = 0, lastAt = 0 }) as ReactRefT<MovedLog>
	local refWasActive = react.useRef(false) as ReactRefT<boolean>
	local refJob = react.useRef(0) as ReactRefT<integer>            -- id of the latest commit
	local refResult = react.useRef(nil) as ReactRefT<ResultLine>    -- status chip result
	local refStatusKey = react.useRef("") as ReactRefT<string>      -- last published status text
	local refOverlay = react.useRef(nil) as ReactRefT<Overlay>
	local refPieces = react.useRef(nil) as ReactRefT<PieceCache>
	local refHlSet = react.useRef({}) as ReactRefT<{integer : boolean}>  -- read by the Selector filter
	local refTruncLogged = react.useRef(nil) as ReactRefT<Selection> -- selection whose overlay cap was logged
	local refUndergroundShown = react.useRef(false) as ReactRefT<boolean> -- the underground layer was added since the tool opened
	-- The latest params for the step/event callbacks (they may outlive this render's closure).
	local refParam = react.useRef(param) as ReactRefT<ConstructionCustomActionParams<RubActionParam>>
	local refPushedAt = react.useRef(-PUSH_GRACE_SECONDS) as ReactRefT<number>   -- os.clock() a newer instance passed its state in
	-- A render of an instance that the menu no longer updates carries old params; while a newer instance passes the
	-- current ones in, they stay.
	if os.clock() - refPushedAt:get() > PUSH_GRACE_SECONDS then refParam:set(param) end
	-- The game's shortcut for the underground view (G). The game registers it only for its own builder tools.
	-- The view switches at once; the toolbar button follows when the menu's API is at hand.
	local syncFilters : function(string)
	react.useInputAction("IA_UNDERGOUND_MODE_TOGGLE", react.iaHandler(function()
		if not refParam:get().isActive then return end
		local now = os.clock()
		local last = g_lastShortcut
		local want : boolean
		local firstOfPress = false
		if last ~= nil and now - last.at < SHORTCUT_SAME_PRESS then
			want = last.want
		elseif last ~= nil and now - last.at < SHORTCUT_MIN_GAP then
			return
		else
			want = not filtersState:old().underground
			g_lastShortcut = { at = now, want = want }
			firstOfPress = true
		end
		g_viewOverride = { on = want, buttonWas = g_toolParams["undergroundMode"] == 1 }
		if firstOfPress then
			local viaMenu = setUndergroundButton(want)
			logMsg(string.format("underground shortcut: view %s, toolbar button %s", want and "on" or "off",
				viaMenu and "changed" or "not reachable"))
		end
		syncFilters("shortcut")
	end))

	-- One step along brush.RADII. Only the instance whose world layer is mounted acts; a held key repeats.
	local function stepRadius(direction : integer)
		if not refLayerUp:get() or not refParam:get().isActive then return end
		local current = brush.radiusIndex(radiusState:old()) or brush.radiusIndex(brush.DEFAULT_RADIUS)
		local target = math.max(1, math.min(#brush.RADII, current + direction))
		if target == current then return end
		local r = brush.RADII[target]
		g_radius = r
		radiusState:set(r)
		local menu = menuParamsApi()
		local toolbar = false
		if menu ~= nil then
			toolbar = pcall(function()
				local info = menu.getParamByKey(KEY_RADIUS)
				if info ~= nil then menu.changeParam(info.index, r) end
			end)
		end
		if debugLog() then logMsg(string.format("radius key: %d m, toolbar slider %s", math.floor(r), toolbar and "set" or "not reachable")) end
	end
	react.useInputAction(IA_RADIUS_GROW, react.iaHandler(function() stepRadius(1) end, nil, nil, true))
	react.useInputAction(IA_RADIUS_SHRINK, react.iaHandler(function() stepRadius(-1) end, nil, nil, true))

	local function bump()
		refVersion:set(refVersion:get() + 1)
		versionState:set(refVersion:get())
	end
	-- Back to the hover preview; the next step re-samples under the cursor.
	local function resetToIdle()
		refSel:set(nil)
		refSample:set(nil)
		bump()
	end
	-- Samples the roads under the ring into refHover; roads that are already selected are left out.
	local function updateHover(cur : Vec3f, r : number, now : number, s : Selection)
		local last = refHoverSample:get()
		local due = last == nil or last.r ~= r or brush.sampleDue(cur.x - last.x, cur.y - last.y, now - last.at, r)
		if due and last ~= nil and last.r == r and cur.x == last.x and cur.y == last.y and now - last.at < HOVER_CACHE_TTL then
			due = false
		end
		if not due then return end
		refHoverSample:set({ x = cur.x, y = cur.y, r = r, at = now })
		local old = refHover:get()
		local hs = newSelection(PHASE_IDLE)
		if old ~= nil and now - old.cache.createdAt < HOVER_CACHE_TTL then
			hs.cache = old.cache
			hs.ctx = old.ctx
		end
		takeSample(hs, cur.x, cur.y, r, filtersState:old())
		local already : {integer} = {}
		for _, e in ipairs(hs.stroke.order) do
			if s.stroke.keep[e] ~= nil then already[#already + 1] = e end
		end
		sel.remove(hs.stroke, already)
		local changed = old == nil or table.concat(sel.entities(old.stroke), ",") ~= table.concat(sel.entities(hs.stroke), ",")
		refHover:set(hs)
		if changed then bump() end
	end
	-- After a press only the roads that failed stay selected and highlighted.

	local function keepOnly(s : Selection, kept : {integer})
		local isKept : {integer : boolean} = {}
		for _, e in ipairs(kept) do isKept[e] = true end
		local dropped : {integer} = {}
		for _, e in ipairs(s.stroke.order) do
			if not isKept[e] then dropped[#dropped + 1] = e end
		end
		sel.remove(s.stroke, dropped)
		s.phase = PHASE_SELECTED
		s.erasing = false
		updatePreview(s)
		refSel:set(s)
		refOverlay:set(nil)
	end
	-- A stroke being painted or a selection waiting for Upgrade: RMB / ESC clear it.
	local function hasPending() : boolean
		local s = refSel:get()
		return s ~= nil and (s.phase == PHASE_PAINTING or s.phase == PHASE_SELECTED)
	end
	-- One log line for every Esc that reaches the tool, from either path.
	local function logEsc(path : string)
		local s = refSel:get()
		logMsg(string.format("Esc received (%s): phase %s, %d selected", path, s ~= nil and s.phase or "none", s ~= nil and sel.count(s.stroke) or 0))
	end
	local function isCommitting() : boolean
		local s = refSel:get()
		return s ~= nil and s.phase == PHASE_COMMITTING
	end
	-- Esc while roads are being upgraded stops the upgrade after the road in progress, as the Clear button does; the
	-- tool stays open.
	local function cancelUpgrade()
		logMsg("upgrade cancelled (Esc)")
		commit.cancel()
	end
	local function cancelPending(why : string)
		refResult:set(nil)
		local s = refSel:get()
		if s == nil then return end
		logMsg(string.format("selection cleared (%s): %d selected, nothing removed", why, sel.count(s.stroke)))
		-- The LMB release that ends a cleared press must not start a new selection.
		if refLmbDown:get() then refSkipRelease:set(true) end
		refLmbDown:set(false)
		resetToIdle()
	end
	-- The tool was closed, switched or hidden: drop the selection, the hover preview, the result line and the status
	-- chip. A running commit is cancelled and ends after the road in progress; its result is no longer shown.
	-- rerender = false when called during a render or an unmount (no state updates there).
	local function resetAll(why : string, rerender : boolean)
		local s = refSel:get()
		if s ~= nil and (s.phase == PHASE_PAINTING or s.phase == PHASE_SELECTED) then
			logMsg(string.format("selection cleared (%s): %d selected, nothing removed", why, sel.count(s.stroke)))
		elseif s ~= nil and s.phase == PHASE_COMMITTING then
			-- The commit is driven by the steps of this recipe. Cancelling lets it end after the road in progress and set the
			-- game speed back.
			logMsg("tool closed while upgrading (" .. why .. "); cancelling the upgrade after the road in progress")
			refJob:set(refJob:get() + 1)
			pcall(commit.cancel)
		end
		refSel:set(nil)
		refSample:set(nil)
		refLmbDown:set(false)
		refSkipRelease:set(false)
		refRmbPress:set(nil)
		refResult:set(nil)
		refOverlay:set(nil)
		refPieces:set(nil)
		refHlSet:set({})
		refStatusKey:set("")
		refUndergroundShown:set(false)
		resetStatus()
		if rerender then bump() end
	end

	react.onMount(function()
		resetStatus()
		diagMsg(string.format("instance #%d mounted", refInstance:get()))
	end)
	react.onUnmount(function()
		resetStatus()
		pcall(function() diagMsg(string.format("instance #%d unmounted", refInstance:get())) end)
		pcall(resetAll, "tool closed", false)
	end)
	-- isActive dropped since the last render. onStep may not run any more when the menu is hidden.
	if refRenderActive:get() and not param.isActive then
		pcall(resetAll, "tool closed", false)
	end
	refRenderActive:set(param.isActive == true)

	local function startCommit(s : Selection, template : string, extras : RubExtras, removeBuildings : boolean)
		local edges = strokeLists(s.stroke)
		refResult:set(nil)
		s.phase = PHASE_COMMITTING
		s.commitAt = os.clock()
		s.progressDone = 0
		s.progressTotal = #edges
		s.retryAttempt = 0
		local job = refJob:get() + 1
		refJob:set(job)
		logStroke("commit", s)
		bump()
		local onDone = function(res : RubCommitResult)
			-- pcall: the tool may have been closed (recipe unmounted) before the last callback.
			pcall(function()
				if refJob:get() ~= job then return end   -- given up on (timeout), tool closed or superseded
				refJob:set(job + 1)
				local text = status.resultLines(res)
				if res.removed > 0 and res.cost ~= nil then
					local cost = moneyText(res.cost)
					text.detail = status.clip(text.detail ~= "" and (text.detail .. " · " .. cost) or cost, status.MAX_CHARS)
				end
				-- The end status stays in the chip until the next stroke, upgrade or clear.
				refResult:set({ text = text, untilAt = math.huge, sticky = true })
				if res.cancelled then
					-- Cancel only stops the upgrade: the roads that are not done stay selected.
					keepOnly(s, sel.entities(s.stroke))
				elseif #res.failed > 0 then
					keepOnly(s, res.failed)
				else
					refSel:set(nil)
				end
				refSample:set(nil)
				bump()
			end)
		end
		-- A road that is done (upgraded, already the target, or dropped by the rules) leaves the selection at once.
		-- A road whose command failed stays and counts for the progress. The commit also calls this with no road when a
		-- retry pass starts.
		local onRoad = function(e : integer, ok : boolean, finishedCount : integer, total : integer, attempt : integer)
			-- pcall: the tool may have been closed (recipe unmounted) before the last callback.
			pcall(function()
				if refJob:get() ~= job then return end
				s.commitAt = os.clock()
				if e ~= nil and ok then
					sel.remove(s.stroke, { e })
					refOverlay:set(nil)
				end
				s.progressDone = finishedCount
				s.progressTotal = total
				s.retryAttempt = attempt
				bump()
			end)
		end
		local tPerf = perf:start()
		local ok, err = pcall(function() : string
			commit.commit(edges, template, extras, removeBuildings, s.ctx, s.cache.industryRoads, onDone, logMsg, onRoad)
			return nil
		end)
		perf:stop("commit", tPerf)
		if not ok then
			logMsg("commit failed: " .. tostring(err))
			refResult:set({ text = { head = _("Upgrade failed"), detail = _("See the game log"), severity = "error" }, untilAt = os.clock() + RESULT_SECONDS })
			refJob:set(job + 1)
			resetToIdle()
		end
	end

	-- LMB released: the selection stays (highlighted) and waits for Upgrade; the next stroke adds to it.

	local function finishStroke(s : Selection)
		local what = s.erasing and "erase stroke" or "stroke"
		s.erasing = false
		if sel.count(s.stroke) == 0 then
			logStroke(what .. " (nothing selected)", s)
			resetToIdle()
			return
		end
		updatePreview(s)
		s.phase = PHASE_SELECTED
		refSel:set(s)
		logStroke(what .. " (waiting for Upgrade)", s)
		local ov = refOverlay:get()
		if hl.usesLines(hl.MODE) and ov ~= nil then
			logMsg(string.format("highlight: %d entities, overlay %d line pieces + %d construction circles%s (last render)",
				sel.count(s.stroke), ov.pieces, ov.markers, ov.truncated and ", capped" or ""))
		end
		bump()
	end

	-- The toolbar button "Upgrade" (onChangeFn → EV_UPGRADE).
	local function upgradeSelection()
		local s = refSel:get()
		if s == nil or s.phase == PHASE_IDLE or sel.count(s.stroke) == 0 then
			logMsg("upgrade button: nothing selected")
			refResult:set({ text = { head = _("Nothing selected"), detail = _("Paint over roads first"), severity = "warning" }, untilAt = os.clock() + RESULT_SECONDS })
			bump()
			return
		end
		if s.phase == PHASE_COMMITTING then
			logMsg("upgrade button: a commit is already running")
			return
		end
		-- PAINTING only if LMB still counts as held (it can't be while the toolbar is clicked):
		-- the release that follows must not touch the selection being removed.
		if refLmbDown:get() then
			refSkipRelease:set(true)
			refLmbDown:set(false)
		end
		local template, problem = brushOptions.template(g_toolParams)
		if template == nil then
			logMsg("upgrade button: no street template (" .. tostring(problem) .. ")")
			refResult:set({ text = { head = _("Cannot upgrade"), detail = problem, severity = "error" }, untilAt = os.clock() + RESULT_SECONDS })
			bump()
			return
		end
		logMsg("upgrade button: " .. tostring(sel.count(s.stroke)) .. " selected, template " .. template)
		startCommit(s, template, brushOptions.extras(g_toolParams), brushOptions.removeBuildings(g_toolParams))
	end

	react.onEvent(EV_RADIUS, function(_name : string, payload : any)
		local m = (payload as RadiusEvent).meters
		local r = brush.radiusFromParam(m)
		logMsg("radius event: " .. tostring(m) .. " -> r = " .. tostring(r)
			.. " (getCurrentParams " .. paramsToString(refParam:get().getCurrentParams()) .. ")")
		if r ~= nil then g_radius = r; radiusState:set(r) end
	end)
	react.onEvent(EV_UPGRADE, function(_name : string, _payload : any)
		if not refParam:get().isActive then return end
		upgradeSelection()
	end)
	-- The toolbar button "Clear" (onChangeFn → EV_CLEAR): same as a right click. While roads are being upgraded it
	-- cancels the upgrade.
	react.onEvent(EV_CLEAR, function(_name : string, _payload : any)
		if not refParam:get().isActive then return end
		local s = refSel:get()
		if s ~= nil and s.phase == PHASE_COMMITTING then
			-- the upgrade stops after the road in progress; its onDone then clears the selection
			logMsg("clear button: cancelling the upgrade")
			commit.cancel()
		elseif hasPending() then
			cancelPending("clear button")
		else
			logMsg("clear button: nothing selected")
		end
	end)
	-- The filters the selection uses: roads always, tunnels or the ground by the Underground button.
	syncFilters = function(why : string)
		local f = sel.defaultFilters()
		-- The underground view and the tunnels follow the Underground button of the toolbar (key undergroundMode, 1 = Yes),
		-- or the shortcut, until the button changes.
		local button = g_toolParams["undergroundMode"] == 1
		if g_viewOverride ~= nil and button ~= g_viewOverride.buttonWas then g_viewOverride = nil end
		f.underground = g_viewOverride ~= nil and g_viewOverride.on or button
		-- the underground view takes tunnels only; the ground is not selected then
		f.surface = not f.underground
		local old = filtersState:old()
		if filtersToString(f) ~= filtersToString(old) then
			logMsg("filters (" .. why .. ") " .. filtersToString(f))
		end
		local changed = filtersToString(f) ~= filtersToString(old)
		filtersState:set(f)
		-- The hover preview is redone with the new filters; a selection keeps what it has.
		local s = refSel:get()
		if changed and (s == nil or s.phase == PHASE_IDLE) then resetToIdle() end
	end
	react.onEvent(EV_SHOWN, function(_name : string, payload : any)
		local ev = payload as ShownEvent
		if ev == nil then return end
		if ev.params ~= nil then g_toolParams = ev.params end
		syncFilters("toolbar shown")
		-- A selection waiting for Upgrade shows the cost of the street template chosen now.
		local s = refSel:get()
		if s ~= nil and s.phase == PHASE_SELECTED and s.previewTemplate ~= (brushOptions.template(g_toolParams)) then
			updatePreview(s)
			bump()
		end
	end)

	local function statusNow() : RubStatusText
		local s = refSel:get()
		local rl = refResult:get()
		local v : RubStatusInput = {
			phase = s ~= nil and s.phase or "none",
			count = s ~= nil and sel.count(s.stroke) or 0,
			kindCounts = s ~= nil and s.stroke.kindCounts or {},
			objects = s ~= nil and s.stroke.objects or 0,
			cost = (s ~= nil and s.preview ~= nil and s.preview.cost ~= nil) and moneyText(s.preview.cost) or nil,
			capped = s ~= nil and s.stroke.capped or false,
			cap = sel.STROKE_CAP,
			result = (rl ~= nil and os.clock() < rl.untilAt) and rl.text or nil,
			progressDone = s ~= nil and s.progressDone or 0,
			progressTotal = s ~= nil and s.progressTotal or 0,
			retryAttempt = s ~= nil and s.retryAttempt or 0,
			retryPasses = commit.RETRY_PASSES,
		}
		if rl ~= nil and rl.sticky and (s == nil or s.phase ~= PHASE_COMMITTING) then return rl.text end
		return status.lines(v)
	end

	local function publishIfChanged()
		local t = statusNow()
		local key = t.head .. "\n" .. t.detail .. "\n" .. tostring(t.severity) .. "\n" .. tostring(t.hint) .. "\n" .. tostring(t.running) .. "\n" .. tostring(t.tail)
		if key ~= refStatusKey:get() then
			refStatusKey:set(key)
			publishStatus(t)
		end
	end

	react.onStep(function()
		commit.tick()
		local tStep = perf:start()
		local prm = refParam:get()
		-- The newest instance is the one the menu keeps up to date, but after other tools were used the menu may keep
		-- drawing the world layer of an older instance. Then the newest instance passes its state to the instance
		-- that owns the layer, which follows the pointer and handles the clicks; it does nothing else.
		if not refLayerUp:get() and g_layerOwnerSetParam ~= nil and g_layerOwnerId ~= refInstance:get()
				and refInstance:get() == g_instances then
			g_layerOwnerSetParam(prm)
			if not g_passLogged then
				g_passLogged = true
				diagMsg(string.format("instance #%d passes the tool state to instance #%d, which owns the world layer",
					refInstance:get(), g_layerOwnerId))
			end
			perf:stop("step", tStep)
			return
		end
		g_passLogged = false
		local active = prm.isActive == true
		-- Activation edge: read back the toolbar (onChangeFn does not fire at mount).
		if active ~= refWasActive:get() then
			refWasActive:set(active)
			if active then
				local p = prm.getCurrentParams()
				logMsg(string.format("tool activated (instance #%d); getCurrentParams ", refInstance:get()) .. paramsToString(p))
				logMsg("highlight mode " .. hl.describeMode(hl.MODE)
					.. (hl.HOVER_ONLY_HIGHLIGHTED and "; hover effect only on highlighted objects" or ""))
				local r = p ~= nil and brush.radiusFromParam(p[KEY_RADIUS]) or nil
				if r ~= nil and r ~= radiusState:old() then g_radius = r; radiusState:set(r) end
				if p ~= nil and next(p) ~= nil then g_toolParams = p end
				syncFilters("activated")
				logMsg("filters " .. filtersToString(filtersState:old()))
				armDiagnostic()
			else
				logMsg("tool deactivated")
				resetAll("tool closed", true)
				cursorState:set(nil)
			end
		end
		if not active then
			refLayerDownAt:set(nil)
			publishIfChanged()
			perf:stop("step", tStep)
			return
		end
		-- World layer unmounted and not back (another tool took the world): the tool was switched.
		local downAt = refLayerDownAt:get()
		if downAt ~= nil and os.clock() - downAt >= LAYER_GONE_SECONDS then
			refLayerDownAt:set(nil)
			logMsg("world layer unmounted")
			resetAll("tool switched", true)
		end
		-- isActive stays true for every entry of the shown tab in mouse mode (the menu mounts each entry's recipe).
		-- Only the selected entry's world layer is mounted.

		if not refLayerUp:get() then
			if not g_noLayerLogged and g_diagLines < DIAG_EPISODE_LINES then
				g_noLayerLogged = true
				g_diagLines = g_diagLines + 1
				diagMsg(string.format("cursor diagnostic: instance #%d is active but its world layer is not mounted, the ring does not follow the pointer", refInstance:get()))
			end
			publishIfChanged()
			perf:stop("step", tStep)
			return
		end
		g_noLayerLogged = false

		local hasTerrain = api.gui.mouse.hasTerrainPosition()
		if not hasTerrain then
			logNoTerrain(refLmbDown:get())
		else
			g_noTerrainSince = nil
			local c = api.gui.mouse.getTerrainPosition()
			local old = cursorState:old()
			if old == nil or math.abs(old.x - c.x) > CURSOR_EPS or math.abs(old.y - c.y) > CURSOR_EPS then
				cursorState:set(api.type.Vec3f.new(c.x, c.y, c.z))
			end
		end
		if g_diagArmed and g_diagLines < DIAG_EPISODE_LINES and os.clock() >= g_diagNextAt then
			g_diagNextAt = os.clock() + DIAG_INTERVAL
			g_diagLines = g_diagLines + 1
			local ring = cursorState:old()
			local t = hasTerrain and api.gui.mouse.getTerrainPosition() or nil
			diagMsg(string.format("cursor diagnostic: instance #%d, terrain position %s, ring %s, radius %s", refInstance:get(),
				t ~= nil and string.format("%.1f/%.1f", t.x, t.y) or "none",
				ring ~= nil and string.format("%.1f/%.1f", ring.x, ring.y) or "none", tostring(radiusState:old())))
		end

		-- Shift changes the ring colour over a selection: re-render on the edge.
		local shift = shiftHeld()
		if shift ~= refShift:get() then
			refShift:set(shift)
			bump()
		end

		local cur = cursorState:old()
		local r = radiusState:old()
		local now = os.clock()
		local s = refSel:get()
		if cur ~= nil and (s == nil or s.phase == PHASE_IDLE or s.phase == PHASE_PAINTING) then
			local last = refSample:get()
			local due = last == nil or last.r ~= r or brush.sampleDue(cur.x - last.x, cur.y - last.y, now - last.at, r)
			-- A cursor that hasn't moved adds nothing while painting; the hover preview refreshes the
			-- same spot only when its cache expires.
			if due and s ~= nil and last ~= nil and last.r == r and cur.x == last.x and cur.y == last.y
					and (s.phase == PHASE_PAINTING or now - last.at < HOVER_CACHE_TTL) then
				due = false
			end
			if due and s ~= nil and s.phase == PHASE_PAINTING and s.stroke.capped and not s.erasing then due = false end
			if due then
				refSample:set({ x = cur.x, y = cur.y, r = r, at = now })
				if s ~= nil and s.phase == PHASE_PAINTING and s.erasing then
					if eraseSample(s, cur.x, cur.y, r, filtersState:old()) then bump() end
				elseif s ~= nil and s.phase == PHASE_PAINTING then
					if takeSample(s, cur.x, cur.y, r, filtersState:old()) then bump() end
				else
					-- Hover preview: a fresh single-sample stroke, cache reused for HOVER_CACHE_TTL.
					local cache = s ~= nil and s.cache or nil
					local ctx = s ~= nil and s.ctx or nil
					local hs = newSelection(PHASE_IDLE)
					if cache ~= nil and now - cache.createdAt < HOVER_CACHE_TTL then
						hs.cache = cache
						hs.ctx = ctx
					end
					takeSample(hs, cur.x, cur.y, r, filtersState:old())
					local changed = s == nil or sel.count(s.stroke) ~= sel.count(hs.stroke)
						or table.concat(sel.describe(s.stroke), "|") ~= table.concat(sel.describe(hs.stroke), "|")
					if DEBUG_OCTREE then
						hs.rawEdges = rawCount(cur.x, cur.y, r, api.type.ComponentType.BASE_EDGE)
						hs.rawCons = rawCount(cur.x, cur.y, r, api.type.ComponentType.CONSTRUCTION)
						if s == nil or s.rawEdges ~= hs.rawEdges or s.rawCons ~= hs.rawCons then changed = true end
					end
					if not changed then
						for i, e in ipairs(hs.stroke.order) do
							if s.stroke.order[i] ~= e then changed = true; break end
						end
					end
					refSel:set(hs)
					if changed then bump() end
				end
			end
		end

		if cur ~= nil and s ~= nil and s.phase == PHASE_SELECTED and not refShift:get() then
			updateHover(cur, r, now, s)
		elseif refHover:get() ~= nil then
			refHover:set(nil)
			refHoverSample:set(nil)
			bump()
		end

		-- The cost preview is made when a stroke ends (finishStroke), not while painting. It builds one proposal per road.

		s = refSel:get()
		-- A commit whose last callback never came: stop waiting on screen.
		if s ~= nil and s.phase == PHASE_COMMITTING and now - (s.commitAt or now) > COMMIT_TIMEOUT then
			logMsg(string.format("commit: no final callback after %d s, giving up waiting", math.floor(COMMIT_TIMEOUT)))
			refJob:set(refJob:get() + 1)
			-- The new job number makes the commit's onDone a no-op; abort sets the game speed back and frees the commit.
			pcall(commit.abort)
			refResult:set({ text = { head = _("No answer from the game"), detail = _("Check what was upgraded"), severity = "error" }, untilAt = now + RESULT_SECONDS })
			resetToIdle()
		end

		local rl = refResult:get()
		if rl ~= nil and now >= rl.untilAt then
			refResult:set(nil)
			bump()
		end

		local ml = refMoved:get()
		if ml.count > 0 and now - ml.lastAt >= MOVED_LOG_INTERVAL then
			if debugLog() then logMsg("mouse Moved x" .. tostring(ml.count) .. " (with LMB held: " .. tostring(ml.withLmb)
				.. ", handled: " .. tostring(ml.handled) .. ")") end
			refMoved:set({ count = 0, withLmb = 0, handled = 0, lastAt = now })
		end

		publishIfChanged()
		perf:stop("step", tStep)
	end)

	local onMouse = function(e : Gui.Mouse.Event) : boolean
		local tMouse = perf:start()
		local T = api.gui.mouse.Event.Type
		local isLmb = e.button == 0
		local isRmb = e.button == 2
		if e.type == T.Moved then
			local ml = refMoved:get()
			ml.count = ml.count + 1
			if refLmbDown:get() then ml.withLmb = ml.withLmb + 1 end
			if e.handled then ml.handled = ml.handled + 1 end
			perf:stop("mouse", tMouse)
			return false
		end
		local s = refSel:get()
		local consume = isLmb and (e.type == T.Pressed or e.type == T.Released)

		if isLmb and e.type == T.Pressed then
			if s ~= nil and s.phase == PHASE_COMMITTING then
				-- Nothing new starts while a commit runs.
				refLmbDown:set(false)
				refSkipRelease:set(true)
			else
				refSkipRelease:set(false)
				refLmbDown:set(true)
				refResult:set(nil)
				local erase = shiftHeld()
				if s ~= nil and s.phase == PHASE_SELECTED then
					-- Another stroke adds to the selection (or, with Shift, removes from it).
					s.phase = PHASE_PAINTING
					s.erasing = erase
				else
					-- New selection (the hover preview is dropped). A Shift stroke with nothing
					-- selected has nothing to remove and ends empty.
					local ns = newSelection(PHASE_PAINTING)
					ns.erasing = erase
					refSel:set(ns)
				end
				if erase then logMsg("erase stroke (Shift held)") end
				-- The next step takes the stroke's first sample at the cursor.
				refSample:set(nil)
				bump()
			end
		elseif isLmb and e.type == T.Released then
			local skipThis = refSkipRelease:get()
			refSkipRelease:set(false)
			refLmbDown:set(false)
			if skipThis then
				-- ignore: its press was cleared with RMB or came while a commit ran
			elseif s ~= nil and s.phase == PHASE_PAINTING then
				-- A plain click (released before a step sampled) still adds what is under the circle.
				local cur = cursorState:old()
				if refSample:get() == nil and cur ~= nil and s.erasing then
					eraseSample(s, cur.x, cur.y, radiusState:old(), filtersState:old())
				elseif refSample:get() == nil and cur ~= nil and not s.stroke.capped then
					takeSample(s, cur.x, cur.y, radiusState:old(), filtersState:old())
				end
				finishStroke(s)
			end
		elseif isRmb and (e.type == T.Pressed or e.type == T.PressedOutside) then
			-- RMB press: only remember where. RMB Pressed / Released never arrive here, only PressedOutside (press) and
			-- Clicked (release): RMB is bound to the menu's back and cancel actions, which take the press before the Selector.

			refRmbPress:set({ x = e.x, y = e.y })
		elseif isRmb and (e.type == T.Clicked or e.type == T.Released) then
			-- RMB release: clears the selection, painted or waiting (nothing is removed), unless the
			-- mouse moved like a camera drag since the press. Released and Clicked may both come;
			-- the second finds nothing pending.
			local p = refRmbPress:get()
			refRmbPress:set(nil)
			local moved = 0
			if p ~= nil and e.x ~= nil and e.y ~= nil then
				moved = math.max(math.abs(e.x - p.x), math.abs(e.y - p.y))
			end
			if not hasPending() then
				logMsg(string.format("right click (%s): nothing selected", eventTypeName(e.type)))
			elseif moved > RMB_CLICK_MAX_PX then
				logMsg(string.format("right click (%s): moved %d px > %d (camera drag), selection kept",
					eventTypeName(e.type), moved, RMB_CLICK_MAX_PX))
			else
				logMsg(string.format("right click (%s): moved %d px%s -> clear",
					eventTypeName(e.type), moved, p == nil and " (no press seen)" or ""))
				cancelPending("right click")
				consume = true
			end
		end
		if debugLog() then
			logMsg("mouse " .. eventTypeName(e.type) .. " button=" .. tostring(e.button)
				.. " handled=" .. tostring(e.handled) .. " -> return " .. tostring(consume)
				.. " (phase " .. (s ~= nil and s.phase or "none") .. ")")
		end
		perf:stop("mouse", tMouse)
		return consume
	end

	local function tooltipText(s : Selection) : string
		local lines : {string} = {}
		if s ~= nil and s.phase == PHASE_PAINTING and s.erasing then
			lines[#lines + 1] = _("Removing from the selection")
		elseif s ~= nil and (s.phase == PHASE_PAINTING or s.phase == PHASE_SELECTED) then
			lines[#lines + 1] = _("Shift + paint removes from the selection")
			lines[#lines + 1] = _("Right-click clears the selection")
		end
		if s ~= nil and s.phase == PHASE_COMMITTING then
			lines[#lines + 1] = _("Cancel button stops the progress")
		end
		if s ~= nil and s.phase ~= PHASE_COMMITTING then
			-- The kept counts show in the toolbar chip.
			for _i, l in ipairs(sel.limitLines(s.stroke)) do lines[#lines + 1] = l end
			if s.truncated then lines[#lines + 1] = _("Too many objects here, some were ignored") end
			if DEBUG_OCTREE and s.phase == PHASE_IDLE and s.rawEdges ~= nil then
				lines[#lines + 1] = string.format("octree at r: %d edges · %d constructions", s.rawEdges, s.rawCons)
			end
			if s.preview ~= nil and #s.preview.errors > 0 and s.phase ~= PHASE_IDLE then
				lines[#lines + 1] = string.format(_("Game says: %s"), s.preview.errors[1])
			end
		end
		return table.concat(lines, "\n")
	end

	local actionFn = function() : TreeNodeId
		local tWorld = perf:start()
		local _ = versionState:old()   -- re-render on selection changes
		-- World-layer lifecycle. The menu swaps the action to another entry's (or its "default") when the tool is
		-- left, which unmounts this layer. An unmount not followed by a mount within LAYER_GONE_SECONDS clears the
		-- selection (here or in onStep).
		react.onMount(function()
			pcall(function()
				refLayerUp:set(true)
				g_layerOwnerId = refInstance:get()
				g_layerOwnerSetParam = function(p : ConstructionCustomActionParams<RubActionParam>)
					refParam:set(p)
					refPushedAt:set(os.clock())
				end
				local downAt = refLayerDownAt:get()
				refLayerDownAt:set(nil)
				diagMsg(string.format("instance #%d: world layer mounted (unmounted %s s before)", refInstance:get(),
					downAt ~= nil and string.format("%.2f", os.clock() - downAt) or "no"))
				if downAt ~= nil and os.clock() - downAt >= LAYER_GONE_SECONDS then
					logMsg("world layer mounted again")
					armDiagnostic()
					resetAll("tool switched", true)
				end
			end)
		end)
		react.onUnmount(function()
			pcall(function()
				refLayerUp:set(false)
				refLayerDownAt:set(os.clock())
				if g_layerOwnerId == refInstance:get() then
					g_layerOwnerId = 0
					g_layerOwnerSetParam = nil
				end
				diagMsg(string.format("instance #%d: world layer unmounted", refInstance:get()))
			end)
		end)
		local cur = cursorState:old()
		local r = radiusState:old()
		local s = refSel:get()
		local phase = s ~= nil and s.phase or PHASE_IDLE
		local highlighted : {Engine.Entity} = {}
		if s ~= nil then highlighted = sel.entities(s.stroke) end
		local hlSet : {integer : boolean} = {}
		for _, e in ipairs(highlighted) do hlSet[e] = true end
		refHlSet:set(hlSet)

		-- Selection highlight (bb_highlight). The engine colours highlightedEntities (and the hovered entity) with the
		-- Selector selection colours; transparent ones hide it.
		local hc = hl.colors(phase)
		local selFill = api.type.Vec4f.new(0, 0, 0, 0)
		local selOutline = api.type.Vec4f.new(0, 0, 0, 0)
		local selOutline1 = api.type.Vec4f.new(0, 0, 0, 0)
		if hl.usesEngine(hl.MODE) then
			selFill = vec4(hc.fill)
			selOutline = vec4(hc.outline)
			selOutline1 = vec4(hc.outline1)
		end

		local children : {TreeNodeId} = {
			builtin.Selector{
				filter = function(entity : Engine.Entity) : boolean
					if entity == nil or entity < 0 then return false end
					-- Hover effect only where the highlight is (same colours).

					if hl.HOVER_ONLY_HIGHLIGHTED then return refHlSet:get()[entity] == true end
					return api.engine.entityExists(entity)
				end,
				-- Consume the click so no entity window opens.
				onSelect = function(_e : Engine.Entity, _i : {integer}, _d : Gui.SelectionDetails) : boolean
					return true
				end,
				onProcessMouseEvent = onMouse,
				-- Not transparent: transparent colours hide highlightedEntities.
				selectionColor = selFill,
				selectionOutlineColor = selOutline,
				selectionOutlineColor1 = selOutline1,
			},
		}

		-- Overlay lines / circles for the selection (cached per selection version + phase).
		local overlayEdges : {Builtin.Type.EdgeRenderable.Edge} = {}
		if hl.usesLines(hl.MODE) and s ~= nil and #highlighted > 0 then
			local key = tostring(versionState:old()) .. "/" .. phase .. "/" .. tostring(#highlighted)
			local ov = refOverlay:get()
			if ov == nil or ov.key ~= key then
				local pc = refPieces:get()
				if pc == nil or pc.owner ~= s.cache then
					pc = { owner = s.cache, byPhase = {} }
					refPieces:set(pc)
				end
				local tOverlay = perf:start()
				local ok, built = pcall(buildOverlay, s, phase, key, pc, hl.MAX_SEGMENTS)
				perf:stop("overlay", tOverlay)
				if ok then
					ov = built
				else
					logMsg("highlight overlay failed: " .. tostring(built))
					ov = { key = key, edges = {}, pieces = 0, markers = 0, truncated = false }
				end
				refOverlay:set(ov)
				if ov.truncated and phase ~= PHASE_IDLE and refTruncLogged:get() ~= s then
					refTruncLogged:set(s)
					logMsg(string.format("highlight overlay capped at %d pieces (%d line pieces, %d circles for %d objects)",
						hl.MAX_SEGMENTS, ov.pieces, ov.markers, #highlighted))
				end
			end
			overlayEdges = ov.edges
		end
		-- The hover preview shares the piece budget of the selection overlay.
		local hover = refHover:get()
		if hl.usesLines(hl.MODE) and hover ~= nil and s ~= nil and s.phase == PHASE_SELECTED and sel.count(hover.stroke) > 0 then
			local budget = hl.MAX_SEGMENTS - #overlayEdges
			if budget > 0 then
				local key = tostring(versionState:old()) .. "/hover/" .. tostring(budget)
				local hov = refHoverOverlay:get()
				if hov == nil or hov.key ~= key then
					local pc = refHoverPieces:get()
					if pc == nil or pc.owner ~= hover.cache then
						pc = { owner = hover.cache, byPhase = {} }
						refHoverPieces:set(pc)
					end
					local ok, built = pcall(buildOverlay, hover, PHASE_IDLE, key, pc, budget)
					if ok then
						hov = built
					else
						logMsg("hover overlay failed: " .. tostring(built))
						hov = { key = key, edges = {}, pieces = 0, markers = 0, truncated = false }
					end
					refHoverOverlay:set(hov)
				end
				local combined : {Builtin.Type.EdgeRenderable.Edge} = {}
				for _, v in ipairs(overlayEdges) do combined[#combined + 1] = v end
				for _, v in ipairs(hov.edges) do combined[#combined + 1] = v end
				overlayEdges = combined
			end
		end

		local bag : {Builtin.Type.EdgeRenderable.Edge} = {}
		for _, v in ipairs(overlayEdges) do bag[#bag + 1] = v end
		if cur ~= nil then
			-- White hover, red while painting, amber while the selection waits / is removed, blue
			-- while a Shift stroke removes (or Shift is held over a waiting selection).
			local color = api.type.Vec4f.new(1, 1, 1, 0.7)
			if s ~= nil and ((s.phase == PHASE_PAINTING and s.erasing)
					or (s.phase == PHASE_SELECTED and refShift:get())) then
				color = api.type.Vec4f.new(0.35, 0.7, 1, 0.85)
			elseif s ~= nil and s.phase == PHASE_PAINTING then
				color = api.type.Vec4f.new(1, 0.25, 0.2, 0.8)
			elseif s ~= nil and (s.phase == PHASE_SELECTED or s.phase == PHASE_COMMITTING) then
				color = api.type.Vec4f.new(1, 0.7, 0.1, 0.8)
			end
			for _, v in ipairs(ringEdges(cur.x, cur.y, r, color)) do bag[#bag + 1] = v end
			-- the base tooltip recipe, where this platform has it; else no tooltip

			local tooltip = tooltipText(s)
			if tooltip ~= "" and type((constructionUi as {string : any}).SimpleTooltipRecipe) == "function" then
				children[#children + 1] = builtin.ActionTooltip{
					recipe = constructionUi.SimpleTooltipRecipe,
					param = { message = { message = tooltip } },
				}
			end
		end
		local undergroundOn = filtersState:old().underground == true
		if undergroundOn then refUndergroundShown:set(true) end
		if undergroundOn or refUndergroundShown:get() then
			local layer = undergroundLayer(undergroundOn)
			if layer ~= nil then children[#children + 1] = layer end
		end
		-- Only ONE EdgeRenderable per recipe: the engine asserts on more. The ring and the selection overlay share it.

		if #bag > 0 then
			children[#children + 1] = builtin.EdgeRenderable{
				edges = bag,
				ignoreDepth = true,
			}
		end

		local descriptor = builtin.ActionDescriptor{
			tool = "brush-upgrade-tool",
			crosshair = false,
			terrainCirclePolicy = "Never",
			highlightedEntities = highlighted,
			-- Back (ESC) clears the selection first; otherwise it leaves the tool.
			onBack = function()
				logEsc("back")
				if isCommitting() then cancelUpgrade() elseif hasPending() then cancelPending("back") else param.abort() end
			end,
			children = children,
		}
		perf:stop("world_render", tWorld)
		return descriptor
	end

	-- These and the ESC hooks below only where this platform's react has them. A platform check is constant, so the
	-- hooks are the same every render.
	local reactAny = react as {string : any}
	if type(reactAny.setForceFocusable) == "function" then react.setForceFocusable(true) end
	if type(reactAny.setRestrictMouseFocus) == "function" then react.setRestrictMouseFocus(true) end

	if not param.isActive then return nil end
	param.setActionFn(actionFn, "BrushUpgradeAction")
	-- ESC: while something is selected it clears the selection. Otherwise, in mouse mode, it falls through and closes
	-- the construction window. useInputAction may be conditional here.
	if (hasPending() or isCommitting()) and type(reactAny.useInputAction) == "function" and type(reactAny.iaHandler) == "function" then
		react.useInputAction("IA_MENU_BACK", react.iaHandler(function()
			logEsc("IA_MENU_BACK")
			if isCommitting() then cancelUpgrade() else cancelPending("Esc") end
		end))
	end
	return nil
end))

-- Toolbar status chip: the content of a disabled one-value Button (makeCompactButtonFn below). It returns a
-- BoxLayout (a recipe child must be a layout) and re-renders itself: the menu re-renders a param only when its value
-- or definition changes. The bar fixes a direct TextView child of the button to 50 x 24 px.

local record StatusParam end
local StatusChip = react.RegisterRecipe("BrushUpgradeStatus", perf:wrap("status_render", function(_param : StatusParam) : TreeNodeId
	local textState = react.useState({ head = g_status.head, detail = g_status.detail, severity = g_status.severity, hint = g_status.hint, tail = g_status.tail, tailSeverity = g_status.tailSeverity }) as ReactStateT<RubStatusText>
	local refSeen = react.useRef(g_status.version) as ReactRefT<integer>
	local function take(ev : StatusEvent)
		local old = textState:old()
		if ev.head == nil or ev.detail == nil then return end
		if old == nil or old.head ~= ev.head or old.detail ~= ev.detail or old.severity ~= ev.severity or old.hint ~= ev.hint
				or old.tail ~= ev.tail or old.tailSeverity ~= ev.tailSeverity then
			textState:set({ head = ev.head, detail = ev.detail, severity = ev.severity, hint = ev.hint, tail = ev.tail, tailSeverity = ev.tailSeverity })
		end
	end
	react.onEvent(EV_STATUS, function(_name : string, payload : any)
		local ev = payload as StatusEvent
		if ev ~= nil then take(ev) end
	end)
	react.onStep(function()
		if g_status.version ~= refSeen:get() then
			refSeen:set(g_status.version)
			take(g_status)
		end
	end)
	local t = textState:old()
	local head : TreeNodeId = builtin.TextView{ meta = brushStyle.meta("font-scale-body", t.severity), text = t.head }
	if t.tail ~= nil and t.tail ~= "" then
		-- two parts of one line, each in its own colour
		head = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = {
				head,
				builtin.TextView{ meta = brushStyle.meta("font-scale-body", t.tailSeverity), text = t.tail },
			},
		}
	end
	local lines : {TreeNodeId} = {
		head,
		builtin.TextView{ meta = brushStyle.meta("font-scale-annotation", t.severity), text = t.detail },
	}
	if t.hint ~= nil and t.hint ~= "" then
		lines[#lines + 1] = builtin.TextView{ meta = brushStyle.meta("font-scale-annotation", "warning"), text = t.hint }
	end
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Vertical,
		children = lines,
	}
end))
-- Button label in a BoxLayout; the bar's 50 px TextView rule clips a direct TextView. The base style centres the
-- BoxLayout.
local function buttonLabel(label : string) : TreeNodeId
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = { builtin.TextView{ meta = { class = "font-scale-body" }, text = label } },
	}
end

-- The label of the Clear button, in the warning colour of the theme (yellow): "Cancel" while an upgrade runs,
-- "Clear" otherwise. It follows the status event like the chip does.
local ClearLabel = react.RegisterRecipe("BrushUpgradeClearLabel", function(_param : StatusParam) : TreeNodeId
	local runState = react.useState(g_status.running == true) as ReactStateT<boolean>
	local refSeen = react.useRef(g_status.version) as ReactRefT<integer>
	local function take(running : boolean)
		if runState:old() ~= running then runState:set(running) end
	end
	react.onEvent(EV_STATUS, function(_name : string, payload : any)
		local ev = payload as StatusEvent
		if ev ~= nil then take(ev.running == true) end
	end)
	react.onStep(function()
		if g_status.version ~= refSeen:get() then
			refSeen:set(g_status.version)
			take(g_status.running == true)
		end
	end)
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = { builtin.TextView{ meta = brushStyle.meta("font-scale-body", "warning"), text = runState:old() and _("Cancel") or _("Clear") } },
	}
end)
-- The game erases the generic type at this boundary.
local makeCustomAction = function<P>(recipe : Recipe<ConstructionCustomActionParams<P>>, customParam? : P) : ConstructionCustomAction<any>
	return { recipe = recipe as Recipe<ConstructionCustomActionParams<any>>, customParam = customParam }
end

local function alwaysEnabled(_params : {string : number}) : ConstructionMenuParam.CheckEnabledResult
	return "Enabled"
end

-- checkEnabledFn of the status chip: the menu calls it with the params map of the toolbar it shows, on every
-- activation and change. It keeps the map and fires EV_SHOWN for the recipe (the recipe may run in another Lua state).
local function noteShown(params : {string : number})
	pcall(function()
		local all : {string : number} = {}
		for k, v in pairs(params) do all[k] = v end
		g_toolParams = all
		api.gui.fireReactEvent(EV_SHOWN, { params = all })
	end)
end
local Ret = {
	getDefinition = perf:wrap("get_definition", function(constructionDefinition : ResName, _repository : ConstructionActionRepository, _params : {string : number}) : ConstructionDefinition
		installApiCapture()
		local defaultRadiusIndex = brush.radiusIndex(g_radius or brush.DEFAULT_RADIUS) or brush.radiusIndex(brush.DEFAULT_RADIUS)
		local params : {ConstructionMenuParam} = {
			{
				key = KEY_RADIUS,
				name = _("Brush radius"),
				tooltip = _("Size of the brush. The keys M (larger) and N (smaller) change it too."),
				values = brush.radiusLabels(),
				numbers = brush.RADII,
				defaultIndex = defaultRadiusIndex,
				uiType = api.type.enum.ScriptParamType.Slider,
				yearFrom = 0,
				yearTo = 0,
				location = api.type.enum.ScriptParamLocation.Toolbar,
				-- Slider with numbers: onChangeFn gets the number.
				onChangeFn = function(newValue : number, _api : ConstructionMenuParamsAPI, oldValue? : number)
					if oldValue ~= nil and newValue == oldValue then return end
					rememberApi(_api)
					logMsg(string.format("radius slider: %s -> %s", tostring(oldValue), tostring(newValue)))
					g_radius = brush.radiusFromParam(newValue) or g_radius
				api.gui.fireReactEvent(EV_RADIUS, { meters = newValue })
				end,
				checkEnabledFn = alwaysEnabled,
			},
			{
				-- [Upgrade] [Clear]: two one-value Buttons with hideLabel in one `group` render side by side. Every click
				-- runs onChangeFn, even when the value is unchanged.
				key = KEY_UPGRADE,
				name = _("Upgrade"),
				tooltip = _("Upgrade every selected (highlighted) road. There is no undo."),
				values = { _("Upgrade") },
				defaultIndex = 1,
				hideLabel = true,
				group = GROUP_ACTIONS,
				uiType = api.type.enum.ScriptParamType.Button,
				yearFrom = 0,
				yearTo = 0,
				location = api.type.enum.ScriptParamLocation.Toolbar,

				makeCompactButtonFn = function(_value : number) : TreeNodeId
					return buttonLabel(_("Upgrade"))
				end,
				onChangeFn = function(_newValue : number, _api : ConstructionMenuParamsAPI, _oldValue? : number)
					rememberApi(_api)
					api.gui.fireReactEvent(EV_UPGRADE, {})
				end,
				checkEnabledFn = alwaysEnabled,
			},
			{
				key = KEY_CLEAR,
				name = _("Clear"),
				tooltip = _("Clear the selection (same as a right click). While roads are being upgraded the button reads Cancel: it stops the upgrade and keeps the roads that are not done selected."),
				values = { _("Clear") },
				defaultIndex = 1,
				hideLabel = true,
				group = GROUP_ACTIONS,
				uiType = api.type.enum.ScriptParamType.Button,
				yearFrom = 0,
				yearTo = 0,
				location = api.type.enum.ScriptParamLocation.Toolbar,
				makeCompactButtonFn = function(_value : number) : TreeNodeId
					return ClearLabel{}
				end,
				onChangeFn = function(_newValue : number, _api : ConstructionMenuParamsAPI, _oldValue? : number)
					rememberApi(_api)
					api.gui.fireReactEvent(EV_CLEAR, {})
				end,
				checkEnabledFn = alwaysEnabled,
			},
			{
				-- Status chip under the buttons: a one-value Button kept "Disabled" (not clickable) whose content is the
				-- self-updating BrushUpgradeStatus recipe. Its own group (GROUP_INFO): brush_upgrade.css.lua turns the
				-- grey button into plain left-aligned text.
				key = KEY_STATUS,
				name = _("Selection"),
				tooltip = _("What is selected. Right-click or Clear empties the selection."),
				values = { _("Selection") },
				defaultIndex = 1,
				hideLabel = true,
				group = GROUP_INFO,
				uiType = api.type.enum.ScriptParamType.Button,
				yearFrom = 0,
				yearTo = 0,
				location = api.type.enum.ScriptParamLocation.Toolbar,
				makeCompactButtonFn = function(_value : number) : TreeNodeId
					return StatusChip{}
				end,
				onChangeFn = function(_newValue : number, _api : ConstructionMenuParamsAPI, _oldValue? : number)
				end,
				checkEnabledFn = function(params : {string : number}) : ConstructionMenuParam.CheckEnabledResult
					noteShown(params)
					return "Disabled"
				end,
			},
		}
		-- Road type, trees and barrier come right after the radius.
		for i, p in ipairs(brushOptions.params(GROUP_INFO)) do
			table.insert(params, 1 + i, p)
		end
		for _, prm in ipairs(params) do
		if prm.key == "undergroundMode" then
			prm.onChangeFn = function(_newValue : number, menuApi : ConstructionMenuParamsAPI, _oldValue? : number)
				rememberApi(menuApi)
			end
		end
	end
		-- The choices of the last use in this session become the defaults of the toolbar (the radius slider is
		-- handled where it is built).
		for _, prm in ipairs(params) do
			local last = g_toolParams[prm.key]
			if last ~= nil and prm.key ~= KEY_RADIUS and #prm.values > 1 then
				prm.defaultIndex = math.max(1, math.min(#prm.values, math.floor(last)))
			end
		end
		logMsg(string.format("toolbar built; remembered radius %s, options %s", tostring(g_radius), paramsToString(g_toolParams)))
		-- Every param is placed in the toolbar, in this order: radius, underground, the road options, the status chip,
		-- the Upgrade and Clear buttons. The menu shows the params of the default location in a second window.

		local function rank(key : string) : integer
			if key == KEY_RADIUS then return 1 end
			if key == "undergroundMode" then return 2 end
			if key == KEY_STATUS then return 5 end
			if key == KEY_UPGRADE then return 6 end
			if key == KEY_CLEAR then return 7 end
			return 4
		end
		local order : {integer} = {}
		for i = 1, #params do order[i] = i end
		table.sort(order, function(a : integer, b : integer) : boolean
			local ra, rb = rank(params[a].key), rank(params[b].key)
			if ra ~= rb then return ra < rb end
			return a < b
		end)
		local ordered : {ConstructionMenuParam} = {}
		for _, i in ipairs(order) do
			params[i].location = api.type.enum.ScriptParamLocation.Toolbar
			ordered[#ordered + 1] = params[i]
		end
		params = ordered		return {
			resName = constructionDefinition,
			name = _("Road Upgrade Brush"),
			description = _("Upgrade roads with a brush: paint over the roads to select them, then press \"Upgrade\". \"Clear\", right-click or Esc clears the selection. One-way road types are not offered."),
			icon = { icon = "kacsa_road_upgrade_brush::/gui/road_upgrade_brush/brush_tool.tga" },
			previewIcon = { icon = "kacsa_road_upgrade_brush::/gui/road_upgrade_brush/brush_tool_preview.tga" },
			availability = { yearFrom = 0, yearTo = 0 },
			action = "ACTION_CUSTOM",
			customAction = makeCustomAction(RubAction),
			constructions = {},
			categories = {},
			params = params,
			-- The order must stay below the first year-gated entry for isActionActive(listIndex) to match.
			menuCategory = {
				categories = {
					{ category = "roads_tools", order = 5 },
				},
			},
		}
	end),
}

perf:phase("init", perfInit)

return Ret
