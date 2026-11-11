-- Upgrade step of the brush tool (API layer, GUI thread only). It builds one street template proposal per
-- road with replaceSegment and sends the proposals one after the other. It sends ignoreErrors = true only for the last
-- retry of a road that nothing but asset groups blocks.
-- Every road is checked against the hard rules on fresh engine reads right before its command.
-- A road that already is the target is left alone. A road whose command fails is tried again, twice, after all the others.

local gather = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/bb_gather.tl" as RubGather
local sel = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/bb_select.tl" as RubSelect
local probe = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/proposal_probe.tl" as RubProposalProbe
local pairSpike = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/pair_spike.tl" as RubPairSpike
local crosswalkPass = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/crosswalk_pass.tl" as RubCrosswalkPass

local upgrade : RubCommit = {}

-- One command per road: a press sends at most as many commands as the selection cap.
upgrade.MAX_COMMANDS = sel.STROKE_CAP

local REFUSED_BY_GAME <const> = "refused by the game"
local STILL_RUNNING <const> = "previous upgrade still running"
local LANES_NOT_APPLIED <const> = "bus lane or lock could not be set"

-- Pause in seconds after each command: the game still works on the world change of a command when its callback runs.
local COMMAND_GAP <const> = 0.1

local RETRY_PASSES <const> = 2
-- The pass number that the progress callback reports while the crosswalk pass runs.
local CROSSWALK_PASS <const> = -1
-- The retry pass in which a failed road gets its lot houses in the removal list.
local LOT_HOUSE_ATTEMPT <const> = 1

local pendingStep : function() = nil
local pendingDueAt : number = 0

-- The commit that runs; nil when none runs. At most one commit runs at a time.
-- cancel() ends it after the command in progress. abort() ends it at once and ignores every later callback of it.
local record Running
	cancel : function()
	abort : function()
end
local running : Running = nil

function upgrade.cancel()
	if running ~= nil then running.cancel() end
end

function upgrade.abort()
	if running ~= nil then running.abort() end
end

local REASON_TEXT : {string : string} = {
	gone = "gone",
	foreign = "other player",
	part = "part of a construction",
	industry = "industry",
	hq = "HQ",
	not_player = "not yours",
	filtered = "filtered",
	underground = "underground",
	surface = "on the ground",
	tram_only = "tram track",
	track_type = "other track type",
}

-- Hard rules only: the toolbar filters do not apply here.
local ALL_FILTERS : RubFilters = {
	roads = true, tracks = true, stations = true, assets = true, townBuildings = true, underground = true, surface = true,
}

-- Runs the next step once the pause is over. The tool recipe calls it on every step.
function upgrade.tick()
	if pendingStep ~= nil and os.clock() >= pendingDueAt then
		local step = pendingStep
		pendingStep = nil
		step()
	end
end

local function afterSeconds(seconds : number, step : function())
	pendingStep = step
	pendingDueAt = os.clock() + seconds
end

local function afterGap(step : function())
	afterSeconds(COMMAND_GAP, step)
end

-- gatherBuildings and gatherFields let the proposal demolish the buildings and fields that block the new road.
local function makeContext(removeBuildings : boolean) : Context
	local c = api.type.Context.new()
	c.gatherBuildings = removeBuildings
	c.gatherFields = removeBuildings
	pcall(function() c.player = api.engine.util.getPlayer() end)
	pcall(function()
		local r = api.gui.construction.getRefundableEntities()
		if r ~= nil then c.refundableEntities = r end
	end)
	return c
end

function upgrade.assertHardRules(edges : {integer}, ctx : RubContext,
		industryRoads : {integer : boolean}, kind? : RubKind) : {integer}, {integer : string}
	local wanted : RubKind = kind or "road"
	local cache = gather.newCache()
	for k, v in pairs(industryRoads or {}) do if v then cache.industryRoads[k] = true end end
	local passed : {integer} = {}
	local dropped : {integer : string} = {}
	local seen : {integer : boolean} = {}
	for _, e in ipairs(edges or {}) do
		if not seen[e] then
			seen[e] = true
			local d = gather.describeEdge(e, cache)
			if cache.industryRoads[e] then d.industryRoad = true end
			local c = sel.classify(d, ALL_FILTERS, ctx)
			if c.reason == nil and c.kind == wanted then
				passed[#passed + 1] = e
			else
				dropped[e] = c.reason or "filtered"
			end
		end
	end
	return passed, dropped
end

local function decorationCount(p : Proposal) : integer
	local n = 0
	for _, segment in ipairs(p.proposal.addedSegments) do
		n = n + #(segment.comp.edgeDecorations or {})
	end
	return n
end

-- The getters may hand out copies: it writes back at every level.
local function applyDecorations(p : Proposal, decorations : {{integer, boolean}})
	local street = p.proposal
	local segments = street.addedSegments
	for _, segment in ipairs(segments) do
		local comp = segment.comp
		comp.edgeDecorations = decorations
		segment.comp = comp
	end
	street.addedSegments = segments
	p.proposal = street
end

-- The lane's transport modes that are on, as "2+3" (TransportMode numbers).
local function modesText(lane : LaneConfig) : string
	local on : {string} = {}
	for mode, enabled in pairs(lane.transportModes or {}) do
		if enabled then on[#on + 1] = tostring(mode) end
	end
	table.sort(on)
	return table.concat(on, "+")
end

-- The game gives out the transport modes of a lane as a table with the mode numbers 0 to 15 as keys, but it takes
-- them in as a list of 16 booleans, one per mode, counted from 1: the mode number plus one is the index. The list
-- must be complete: a table with only some indexes gives the lane the modes 0 and 1, and a lane written back with
-- the keys it was read with comes out with every mode one number lower.
local MODE_COUNT <const> = 16

local function modeNumber(mode : any) : integer
	return math.floor(tonumber(tostring(mode)) or -1)
end

local function modeSet(lane : LaneConfig) : {integer : boolean}
	local on : {integer : boolean} = {}
	for mode, enabled in pairs(lane.transportModes or {}) do
		if enabled then on[modeNumber(mode)] = true end
	end
	return on
end

local function setText(set : {integer : boolean}) : string
	local on : {string} = {}
	for k in pairs(set) do on[#on + 1] = tostring(k) end
	table.sort(on)
	return table.concat(on, "+")
end

local function sameSet(a : {integer : boolean}, b : {integer : boolean}) : boolean
	for k in pairs(a) do if not b[k] then return false end end
	for k in pairs(b) do if not a[k] then return false end end
	return true
end

-- The bus lane, tram track, catenary and lock of a plan, put on the new segments. A lane that carries buses gets or
-- loses the car, and every lane of the plan gets or loses the tram and the electric tram. A lane that already has the
-- meant modes is not written. The getters may hand out copies: it writes back at every level. The result is false when
-- the lanes read back from the proposal differ from the meant ones, when a lane that was not edited differs from what
-- it was, or when a segment has another number of lanes than the plan. Such a proposal MUST NOT be sent: lanes with
-- wrong modes can stop the game in its transport network.
local function applyLanes(p : Proposal, plan : RubPlan) : boolean, string
	local modes = api.type["enum"].TransportMode
	local car = modeNumber(modes.CAR)
	local bus = modeNumber(modes.BUS)
	local tram = modeNumber(modes.TRAM)
	local electricTram = modeNumber(modes.ELECTRIC_TRAM)
	local street = p.proposal
	local segments = street.addedSegments
	local notes : {string} = {}
	local verified = true
	-- the lanes meant per segment: segment index -> lane index -> mode numbers
	local meant : {integer : {integer : {integer : boolean}}} = {}
	-- the modes of every lane before the edit: segment index -> lane index -> mode numbers
	local snapshot : {{{integer : boolean}}} = {}
	for s, segment in ipairs(segments) do
		local comp = segment.comp
		if plan.lanes ~= nil then
			meant[s] = {}
			snapshot[s] = {}
			local lanes = comp.laneConfigs
			for i, lane in ipairs(lanes) do snapshot[s][i] = modeSet(lane) end
			if #lanes ~= plan.laneCount then
				verified = false
				notes[#notes + 1] = string.format("segment %d has %d lanes, the template has %d", s, #lanes, plan.laneCount)
			else
				local written = false
				for i = 1, #lanes do
					local flags = plan.lanes[i]
					if flags ~= nil then
						local want = modeSet(lanes[i])
						if want[bus] then want[car] = (not flags.carFree) or nil end
						want[tram] = flags.tram or nil
						want[electricTram] = flags.electric or nil
						if not sameSet(want, snapshot[s][i]) then
							local lane = lanes[i]
							local list : {boolean} = {}
							for mode = 0, MODE_COUNT - 1 do list[mode + 1] = want[mode] == true end
							lane.transportModes = list as any as {TransportMode : boolean}
							lanes[i] = lane
							meant[s][i] = want
							written = true
							if s == 1 then notes[#notes + 1] = string.format("lane %d %s -> meant %s", i, setText(snapshot[s][i]), setText(want)) end
						end
					end
				end
				if written then comp.laneConfigs = lanes end
			end
		end
		if plan.lock ~= "keep" then comp.roadDevelopmentLocked = plan.lock == "lock" end
		segment.comp = comp
	end
	street.addedSegments = segments
	p.proposal = street

	local readBack = p.proposal.addedSegments
	for s, perLane in pairs(meant) do
		local lanes = readBack[s].comp.laneConfigs
		if #lanes ~= #snapshot[s] then
			verified = false
			notes[#notes + 1] = string.format("segment %d has %d lanes, had %d", s, #lanes, #snapshot[s])
		else
			-- Every lane: the edited ones read back as meant, the others as they were.
			for i = 1, #lanes do
				local want = perLane[i] or snapshot[s][i]
				if not sameSet(modeSet(lanes[i]), want) then
					verified = false
					notes[#notes + 1] = string.format("segment %d lane %d reads back %s", s, i, modesText(lanes[i]))
				end
			end
		end
	end
	if plan.lock ~= "keep" then
		local locked = plan.lock == "lock"
		for s = 1, #readBack do
			if (readBack[s].comp.roadDevelopmentLocked == true) ~= locked then
				verified = false
				notes[#notes + 1] = string.format("segment %d lock reads back %s", s, tostring(not locked))
			end
		end
	end
	notes[#notes + 1] = verified and "edit verified" or "EDIT NOT VERIFIED, not sent"
	return verified, "edit: " .. table.concat(notes, ", ")
end

-- The positions of the tram lanes of a street at one of its end nodes, counted as the lanes of a LaneConnection: zero-based,
-- from left to right when looking from the node along the street.
local record TramLanes
	incoming : {integer}
	outgoing : {integer}
end

-- A lane connection for the tram at a node: from a lane of one street into a lane of another street.
local record TramRoute
	node : integer
	from : integer
	fromLane : integer
	to : integer
	toLane : integer
end

local function tramLanesAt(comp : Engine.Component.BaseEdge, node : integer) : TramLanes
	local tram = modeNumber(api.type["enum"].TransportMode.TRAM)
	local startsAtNode = comp.node0 == node
	local lanes = comp.laneConfigs or {}
	local found : TramLanes = { incoming = {}, outgoing = {} }
	for position = 1, #lanes do
		local lane = lanes[startsAtNode and position or #lanes + 1 - position]
		if modeSet(lane)[tram] then
			local side = (lane.forward == true) == startsAtNode and found.outgoing or found.incoming
			side[#side + 1] = position - 1
		end
	end
	return found
end

-- api.type.LaneConnection exists in the game but not in its Teal definitions. The game takes only its own objects in the list
-- of a node config.
local function newTramConnection(route : TramRoute) : LaneConnection
	local factory = (api.type as {string : any})["LaneConnection"] as {string : function() : LaneConnection}
	local connection = factory["new"]()
	connection.segment0 = route.from
	connection.lane0 = route.fromLane
	connection.segment1 = route.to
	connection.lane1 = route.toLane
	connection.withRoad = false
	connection.withTram = true
	return connection
end

local function connectionOf(connections : {LaneConnection}, route : TramRoute) : LaneConnection
	for _, c in ipairs(connections) do
		if c.segment0 == route.from and c.lane0 == route.fromLane and c.segment1 == route.to and c.lane1 == route.toLane then return c end
	end
	return nil
end

-- The tram routes between an added segment and every other street of the node, in both directions: from the incoming tram
-- lane of the one into the outgoing tram lane of the other. The second value counts the pairs left out because a street has
-- several tram lanes in that direction. It reads the BASE_EDGE of the streets that the connections name.
local function tramRoutesAt(node : integer, connections : {LaneConnection}, addedSegments : {Proposal.SegmentAndEntity}) : {TramRoute}, integer
	local isAdded : {integer : boolean} = {}
	local lanes : {integer : TramLanes} = {}
	local streets : {integer} = {}
	for _, segment in ipairs(addedSegments) do
		isAdded[segment.entity] = true
		local comp = segment.comp
		if comp.node0 == node or comp.node1 == node then
			lanes[segment.entity] = tramLanesAt(comp, node)
			streets[#streets + 1] = segment.entity
		end
	end
	for _, connection in ipairs(connections) do
		for _, street in ipairs({ connection.segment0, connection.segment1 }) do
			if lanes[street] == nil then
				lanes[street] = tramLanesAt(api.engine.getComponent(street, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge, node)
				streets[#streets + 1] = street
			end
		end
	end
	local routes : {TramRoute} = {}
	local leftOut = 0
	for _, from in ipairs(streets) do
		for _, to in ipairs(streets) do
			local incoming, outgoing = lanes[from].incoming, lanes[to].outgoing
			if from ~= to and (isAdded[from] or isAdded[to]) and #incoming > 0 and #outgoing > 0 then
				if #incoming > 1 or #outgoing > 1 then
					leftOut = leftOut + 1
				else
					routes[#routes + 1] = { node = node, from = from, fromLane = incoming[1], to = to, toLane = outgoing[1] }
				end
			end
		end
	end
	return routes, leftOut
end

-- The tram routes of the added segments in the node configs of the proposal. replaceSegment makes these configs from the lanes
-- of the template, so the connections of an added segment carry no tram. Every route of tramRoutesAt gets the tram flag on
-- its connection, or a connection for the tram alone when the config has none. The result is false when a route does not
-- read back from the proposal. Such a proposal MUST NOT be sent.
local function applyTramConnections(p : Proposal) : boolean, string
	local street = p.proposal
	local configs = street.nodeConfigsToAdd or {}
	local meant : {TramRoute} = {}
	local set, added, leftOut = 0, 0, 0
	for _, config in ipairs(configs) do
		local comp = config.comp
		local connections : {LaneConnection} = {}
		for i, connection in ipairs(comp.laneConnections or {}) do connections[i] = connection end
		local routes, skipped = tramRoutesAt(config.entity, connections, street.addedSegments)
		leftOut = leftOut + skipped
		for _, route in ipairs(routes) do
			local connection = connectionOf(connections, route)
			if connection == nil then
				connections[#connections + 1] = newTramConnection(route)
				added = added + 1
			elseif not connection.withTram then
				connection.withTram = true
				set = set + 1
			end
			meant[#meant + 1] = route
		end
		if #routes > 0 then
			comp.laneConnections = connections
			config.comp = comp
		end
	end
	if #meant > 0 then
		street.nodeConfigsToAdd = configs
		p.proposal = street
	end

	local verified = true
	local notes : {string} = { string.format("%d set, %d added, %d left out", set, added, leftOut) }
	local readBack = p.proposal.nodeConfigsToAdd or {}
	for _, route in ipairs(meant) do
		local found = false
		for _, config in ipairs(readBack) do
			if config.entity == route.node then
				local connection = connectionOf(config.comp.laneConnections or {}, route)
				found = found or (connection ~= nil and connection.withTram == true)
			end
		end
		if not found then
			verified = false
			notes[#notes + 1] = string.format("node %d: %d lane %d -> %d lane %d reads back without the tram", route.node, route.from,
				route.fromLane, route.to, route.toLane)
		end
	end
	notes[#notes + 1] = verified and "verified" or "TRAM CONNECTIONS NOT VERIFIED, not sent"
	return verified, "tram connections: " .. table.concat(notes, ", ")
end

local function hasTram(lanes : {integer : RubLaneFlags}) : boolean
	for _, flags in pairs(lanes or {}) do
		if flags.tram then return true end
	end
	return false
end

-- The proposal that replaces the edge by the plan, and one log line about it.
local function proposalOf(edge : integer, plan : RubPlan) : Proposal, string, string
	local ok, p = pcall(api.engine.util.proposal.replaceSegment, edge, plan.template)
	if not ok or p == nil then return nil, "replaceSegment failed: " .. tostring(p), nil end
	local summary = ""
	local editsLanes = plan.lanes ~= nil or plan.lock ~= "keep"
	-- A proposal whose lanes or lock are not in place is not sent.
	local unsafe = false
	local okS, errS = pcall(function() : string
		local street = p.proposal
		summary = string.format("template %s, +%d/-%d segments, +%d/-%d nodes, %d edge objects, toRemove %d, toAdd %d",
			tostring(plan.template), #street.addedSegments, #street.removedSegments, #street.addedNodes, #street.removedNodes,
			#street.edgeObjectsToAdd, #(p.toRemove or {}), #(p.toAdd or {}))
		pcall(function() : string
			local old = api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
			local oldObjects = #(old.objects or {})
			local newObjects = #(street.addedSegments[1].comp.objects or {})
			summary = summary .. string.format(", edge objects %d -> %d%s", oldObjects, newObjects, newObjects < oldObjects and " (OBJECTS LOST)" or "")
			return nil
		end)
		if plan.decorations ~= nil then
			local before = decorationCount(p)
			applyDecorations(p, plan.decorations)
			summary = summary .. string.format(", decorations %d -> %d (wanted %d per segment)",
				before, decorationCount(p), #plan.decorations)
		end
		if editsLanes then
			local okE, note = applyLanes(p, plan)
			summary = summary .. ", " .. note
			if not okE then unsafe = true end
			if okE and hasTram(plan.lanes) then
				local okT, tramNote = applyTramConnections(p)
				summary = summary .. ", " .. tramNote
				if not okT then unsafe = true end
			end
		end
		return nil
	end)
	if not okS then
		summary = summary .. ", proposal inspection failed: " .. tostring(errS)
		unsafe = unsafe or editsLanes
	end
	if unsafe then return nil, summary, LANES_NOT_APPLIED end
	return p, summary, nil
end

local function addUnique(list : {string}, s : string)
	if s == nil or s == "" then return end
	for _, x in ipairs(list) do if x == s then return end end
	list[#list + 1] = s
end

local function messagesOf(data : WorldBuildProposalCommandData) : {string}
	local out : {string} = {}
	pcall(function()
		local es = data.resultProposalData.errorState
		local msgs = (es.messages or {}) as {string}
		for i = 1, #msgs do addUnique(out, tostring(msgs[i])) end
	end)
	return out
end

-- What the game says the proposal collides with, as entity ids only.
local function collisionText(data : WorldBuildProposalCommandData, own : integer) : string
	local parts : {string} = {}
	pcall(function()
		local info = data.resultProposalData.collisionInfo
		for _, c in ipairs(info.collisionEntities or {}) do
			parts[#parts + 1] = c.entity == own and "the road itself" or tostring(c.entity)
		end
		parts[#parts + 1] = string.format("%d buildings", #(info.buildingEntities or {}))
	end)
	return table.concat(parts, ", ")
end
-- Number of buildings the game demolished with the command.
local function buildingCount(data : WorldBuildProposalCommandData) : integer
	local ok, n = pcall(function() : integer return #data.resultProposalData.collisionInfo.buildingEntities end)
	if ok then return n end
	return 0
end

-- The asset groups (placed trees, rocks and decoration assets) that a failed command collides with, and whether they are
-- the only thing in the way besides the road itself. The game does not remove an asset group on its own, so a road
-- that one of them blocks fails with the message "Collision".
local function assetGroupsOf(data : WorldBuildProposalCommandData, own : integer) : {integer}, boolean
	local found : {integer} = {}
	local seen : {integer : boolean} = {}
	local onlyAssets = true
	pcall(function()
		for _, c in ipairs(data.resultProposalData.collisionInfo.collisionEntities or {}) do
			local e = c.entity
			if e ~= own and not seen[e] then
				seen[e] = true
				if api.engine.getComponent(e, api.type.ComponentType.ASSET_GROUP) ~= nil then
					found[#found + 1] = e
				else
					onlyAssets = false
				end
			end
		end
	end)
	return found, onlyAssets and #found > 0
end

local function addToRemove(p : Proposal, ids : {integer})
	local list : {integer} = {}
	local seen : {integer : boolean} = {}
	for _, e in ipairs(p.toRemove or {}) do
		if not seen[e] then seen[e] = true; list[#list + 1] = e end
	end
	for _, e in ipairs(ids) do
		if not seen[e] then seen[e] = true; list[#list + 1] = e end
	end
	p.toRemove = list
end

-- The entities of `ids` that still exist, in order. The game refuses a removal list with an entity that is gone ("Unknown
-- exception" in PreprocessProposal).
local function existing(ids : {integer}) : {integer}
	local remaining : {integer} = {}
	for _, id in ipairs(ids) do
		if api.engine.entityExists(id) then remaining[#remaining + 1] = id end
	end
	return remaining
end

-- The game names a building lot in this English text; in another game language the text does not match and the hint for the
-- player stays away.
local PARCEL_MESSAGE <const> = "Unexpected parcel"

local function mentionsParcel(messages : {string}) : boolean
	for _, message in ipairs(messages) do
		if string.find(message, PARCEL_MESSAGE, 1, true) ~= nil then return true end
	end
	return false
end

-- Cost of the roads the game did upgrade; nil when the game reports none.
local function costOf(data : WorldBuildProposalCommandData) : integer
	local ok, c = pcall(function() : integer return data.resultProposalData.costs end)
	if ok then return c end
	return nil
end

-- Simulation speed (0 = paused) and number of simulation updates, for the log. The game works on the world
-- changes of a command during its simulation updates, which do not run while the game is paused.
local function simulationText() : string
	local ok, text = pcall(function() : string
		local world = api.engine.util.getWorld()
		local speed = api.engine.getComponent(world, api.type.ComponentType.GAME_SPEED) as Engine.Component.GameSpeed
		local time = api.engine.getComponent(world, api.type.ComponentType.GAME_TIME) as Engine.Component.GameTime
		return string.format("speed %s, updates %s", tostring(speed.speedup), tostring(time.updateCount))
	end)
	if ok then return text end
	return "simulation unknown"
end

-- The game MUST be paused while the commands run. The commit pauses the game (speed 0) and sets the old speed back when it
-- is done.
local PAUSE_NOTE <const> = "Pause the game first"

-- Speed the game ran at before this module paused it; nil when it did not pause the game.
local speedBeforePause : integer = nil

local function gameSpeed() : integer
	local ok, speed = pcall(function() : integer
		local gs = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_SPEED) as Engine.Component.GameSpeed
		return gs.speedup
	end)
	if ok then return speed end
	return nil
end

local function sendSpeed(speed : integer, done : function(boolean))
	local ok = pcall(function() : string
		local cmd = api.cmd.makeGameSetSpeedCmd(speed)
		api.cmd.sendCommand(cmd, function(_data : GameSetSpeedCommandData, success : boolean)
			done(success == true)
		end)
		return nil
	end)
	if not ok then done(false) end
end

-- Calls proceed(true) when the game is paused, after pausing it if it ran; proceed(false) when it stays running or its
-- speed cannot be read.
local function ensurePaused(logLine : function(string), proceed : function(boolean))
	local speed = gameSpeed()
	if speed == nil then
		logLine("game speed unreadable, no command is sent")
		proceed(false)
		return
	end
	if speed == 0 then
		proceed(true)
		return
	end
	if speedBeforePause == nil then speedBeforePause = speed end
	sendSpeed(0, function(success : boolean)
		local now = gameSpeed()
		logLine(string.format("pause command %s, game speed was %d, is now %s",
			success and "accepted" or "refused", speed, tostring(now)))
		proceed(now == 0)
	end)
end

-- One log line about the road: what it is now. It reads only the road's own component.
local function describeRoad(edge : integer) : string
	local parts : {string} = {}
	pcall(function()
		local comp = api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
		local kinds = api.type.enum.BaseEdgeType
		local kind = "normal"
		if comp.type == kinds.BRIDGE then kind = "bridge" elseif comp.type == kinds.TUNNEL then kind = "tunnel" end
		parts[#parts + 1] = string.format("%s, template %s, %d edge objects, %d decorations",
			kind, tostring(comp.roadTemplate), #(comp.objects or {}), #(comp.edgeDecorations or {}))
	end)
	return table.concat(parts, "; ")
end
upgrade.describeRoad = describeRoad

-- makeProposalData rejects the proposal replaceSegment returns: the cost is known only from the commit's result.
function upgrade.preview(_edges : {integer}, _template : string) : RubPreview
	return { ok = false, cost = nil, critical = false, errors = {}, seconds = 0 }
end

local function reasonsText(r : {string : integer}) : string
	local keys : {string} = {}
	for k in pairs(r) do keys[#keys + 1] = k end
	table.sort(keys)
	local parts : {string} = {}
	for _, k in ipairs(keys) do parts[#parts + 1] = k .. ": " .. tostring(r[k]) end
	return table.concat(parts, ", ")
end

-- The proposal of one road and the context of its command. `p` is nil when the road fails: `why` or `errText` tell why.
local record Prepared
	p : Proposal
	summary : string
	why : string
	context : Context
	force : boolean
	errText : string
	partner : integer
end

function upgrade.commit(edges : {integer}, target : RubTarget, kind : RubKind, removeBuildings : boolean, ctx : RubContext,
		industryRoads : {integer : boolean}, onDone : function(RubCommitResult), logFn : function(string),
		onRoad : function(integer, boolean, integer, integer, integer))
	local t0 = os.clock()
	local isRail = kind == "track"
	local plainLog = logFn or function(_s : string) end
	local function logLine(text : string, category? : string)
		plainLog(probe.tag(category or "upgrade", text))
	end
	edges = edges or {}
	local res : RubCommitResult = {
		requested = #edges, removed = 0, unchanged = 0, failed = {}, skipped = 0, reasons = {}, commands = 0,
		refused = nil, cost = nil, seconds = 0, rail = isRail, lotFailures = 0, buildingsKept = not removeBuildings, notes = {},
	}
	if running ~= nil then
		-- The roads stay selected: a refusal reports them as failed.
		logLine("upgrade refused: the previous upgrade is still running", "failure")
		res.refused = STILL_RUNNING
		res.skipped = res.requested
		for i, e in ipairs(edges) do res.failed[i] = e end
		if onDone ~= nil then
			local okD, errD = pcall(function() : string onDone(res); return nil end)
			if not okD then logLine("upgrade onDone failed: " .. tostring(errD), "failure") end
		end
		return
	end
	probe.beginPress()
	pendingStep = nil
	local finished = false
	local cancelled = false
	-- A pause or a command is on its way: its callback ends a cancelled commit.
	local busy = false
	local recovered = 0
	-- Progress of the current pass. The first pass counts every road requested; a retry pass counts the roads that failed
	-- before. A road counts once in a pass: upgraded, already the target, dropped by the hard rules (ok), or failed.
	local passFinished = 0
	local passTotal = #edges
	local passAttempt = 0
	local function report(e : integer, ok : boolean)
		if e ~= nil then passFinished = passFinished + 1 end
		if onRoad ~= nil then
			local okC, err = pcall(function() : string onRoad(e, ok, passFinished, passTotal, passAttempt); return nil end)
			if not okC then logLine("progress callback failed: " .. tostring(err), "failure") end
		end
	end
	local function startPass(attempt : integer, total : integer)
		passAttempt = attempt
		passTotal = total
		passFinished = 0
		report(nil, true)
	end
	local function skip(reason : string, n? : integer)
		res.reasons[reason] = (res.reasons[reason] or 0) + (n or 1)
	end
	-- The notes of the plan each road had last: road -> notes. They count once the road is upgraded or is found unchanged.
	local planNotes : {integer : {string}} = {}
	local function addNotes(e : integer)
		for _, note in ipairs(planNotes[e] or {}) do res.notes[note] = (res.notes[note] or 0) + 1 end
		planNotes[e] = nil
	end
	-- The plan of an edge, read now.
	local function planOf(e : integer) : RubPlan
		local plan = target(e)
		plan.lock = plan.lock or "keep"
		planNotes[e] = plan.notes
		return plan
	end
	local mine : Running = {}
	local crosswalks = crosswalkPass.new()
	local function finish()
		if finished then return end
		finished = true
		if running == mine then running = nil end
		res.cancelled = cancelled
		if speedBeforePause ~= nil then
			local speed = speedBeforePause
			speedBeforePause = nil
			sendSpeed(speed, function(success : boolean)
				logLine(string.format("game speed set back to %d: %s", speed, success and "accepted" or "refused"))
			end)
		end
		res.skipped = res.requested - res.removed - res.unchanged
		res.seconds = os.clock() - t0
		logLine(string.format("upgrade done: %d of %d, %d unchanged, skipped %d%s%s, %d recovered by the retry, %d commands, cost %s, %.0f ms%s",
			res.removed, res.requested, res.unchanged, res.skipped,
			next(res.reasons) ~= nil and (" (" .. reasonsText(res.reasons) .. ")") or "",
			next(res.notes) ~= nil and (", notes (" .. reasonsText(res.notes) .. ")") or "", recovered,
			res.commands, tostring(res.cost), res.seconds * 1000,
			res.refused ~= nil and (", refused: " .. res.refused) or ""))
		if onDone ~= nil then
			local ok, err = pcall(function() : string onDone(res); return nil end)
			if not ok then logLine("upgrade onDone failed: " .. tostring(err), "failure") end
		end
	end
	mine.cancel = function()
		if finished or cancelled then return end
		cancelled = true
		pendingStep = nil
		logLine("upgrade cancelled by the user")
		local left = crosswalks:unfinished()
		if left > 0 then logLine(string.format("crosswalks: pass cut off by the cancel, %d touched nodes not done", left), "failure") end
		if not busy then finish() end
	end
	mine.abort = function()
		if finished then return end
		cancelled = true
		pendingStep = nil
		logLine("upgrade aborted: no answer from the game")
		finish()
	end
	running = mine
	local function skipDropped(dropped : {integer : string}, where : string)
		local n = 0
		for e, r in pairs(dropped) do
			skip(REASON_TEXT[r] or r)
			n = n + 1
			report(e, true)
		end
		if n > 0 then logLine(string.format("hard-rule recheck (%s) dropped %d", where, n)) end
	end

	if target == nil then
		res.refused = "no valid road type"
		finish()
		return
	end

	local queue, dropped = upgrade.assertHardRules(edges, ctx, industryRoads, kind)
	skipDropped(dropped, "before send")
	if #queue == 0 then
		res.refused = "nothing left to upgrade"
		finish()
		return
	end
	if #queue > upgrade.MAX_COMMANDS then
		skip("command limit reached", #queue - upgrade.MAX_COMMANDS)
		local limited : {integer} = {}
		for i = 1, upgrade.MAX_COMMANDS do limited[i] = queue[i] end
		queue = limited
	end
	logLine(string.format("upgrade: %d %s, remove buildings %s, %s", #queue, isRail and "tracks" or "roads", tostring(removeBuildings),
		simulationText()))

	-- `probe.press` and `crosswalks:prepare` MUST NOT run in a command callback. They read the roads of the press here, before
	-- the first command. Tracks have no crosswalks.
	local press = probe.press(queue)
	if not isRail then crosswalks:prepare(queue) end

	local failed : {integer} = {}
	local failedReason : {integer : string} = {}
	local lotFailed : {integer : boolean} = {}
	local function fail(e : integer, reason : string)
		failed[#failed + 1] = e
		failedReason[e] = reason
		report(e, false)
	end

	-- Set when the game could not be paused: no further command is sent.
	local pauseFailed = false

	-- Roads whose command failed with one message and where only asset groups are in the way (the message is the game's
	-- translated "Collision"): road -> asset groups.
	-- The first retry puts them in the removal list of the proposal; the second retry also sends it with ignoreErrors.
	-- Both need the option "Remove buildings in the way".
	local assetBlockers : {integer : {integer}} = {}

	-- Pair spike: the roads of the current retry pass, the neighbours of each road that are still to be tried, the pairs that were
	-- tried (key "small:large"), and the neighbours that a successful pair command upgraded, so that their own turn does nothing.
	local record PairQueue
		list : {integer}
		next : integer
	end
	local retryList : {integer} = {}
	local pairQueues : {integer : PairQueue} = {}
	local pairTried : {string : boolean} = {}
	local pairHandled : {integer : boolean} = {}

	local function pairKey(a : integer, b : integer) : string
		return math.min(a, b) .. ":" .. math.max(a, b)
	end

	local function pairable(e : integer, c : integer) : boolean
		return c ~= e and not pairHandled[c] and assetBlockers[c] == nil and not pairTried[pairKey(e, c)]
	end

	-- The neighbours of the road, found once per road: the roads of the retry pass that can still be paired with it.
	local function queueOf(e : integer) : PairQueue
		local known = pairQueues[e]
		if known ~= nil then return known end
		local candidates : {integer} = {}
		for _, c in ipairs(retryList) do
			if pairable(e, c) then candidates[#candidates + 1] = c end
		end
		local created : PairQueue = { list = #candidates > 0 and pairSpike.partners(e, candidates) or {}, next = 1 }
		pairQueues[e] = created
		return created
	end

	-- The first neighbour of the queue that can still be paired. With `take` the queue moves past it.
	local function nextPartner(e : integer, take : boolean) : integer
		local pending = queueOf(e)
		for i = pending.next, #pending.list do
			local c = pending.list[i]
			if pairable(e, c) then
				if take then pending.next = i + 1 end
				return c
			end
		end
		return nil
	end

	-- The road and its next neighbour in ONE proposal. Returns the neighbour after it set `prepared`, or nil with `prepared`
	-- unchanged: the road is then retried alone. An error while the pair is built is logged, drops the other neighbours of the
	-- road, and has the same result.
	local function tryPair(e : integer, plan : RubPlan, prepared : Prepared) : integer
		local partner = nextPartner(e, true)
		if partner == nil then return nil end
		pairTried[pairKey(e, partner)] = true
		local ok, err = pcall(function() : string
			if #(upgrade.assertHardRules({ partner }, ctx, industryRoads, kind)) == 0 then error("the neighbour no longer passes the hard rules", 0) end
			local partnerPlan = planOf(partner)
			if partnerPlan.reason ~= nil or partnerPlan.template == nil or partnerPlan.unchanged then error("the neighbour has nothing to upgrade", 0) end
			local base, baseSummary = proposalOf(e, plan)
			local other, otherSummary = proposalOf(partner, partnerPlan)
			if base == nil or other == nil then error("no proposal for one of the roads", 0) end
			local mergeText = pairSpike.merge(base, other)
			prepared.p = base
			prepared.summary = string.format("%s; pair spike: edge %d merged with edge %d (%s; proposal of the neighbour: %s); no lot houses put in toRemove (the game gathers the buildings)",
				baseSummary, e, partner, mergeText, otherSummary)
			return nil
		end)
		if ok then return partner end
		pairQueues[e].next = #pairQueues[e].list + 1
		logLine(string.format("pair spike: building the pair for edges %d and %d failed, the road is retried alone: %s", e, partner, tostring(err)), "failure")
		return nil
	end

	-- Builds the proposal of one road and the context of its command. The game calls this from its own thread: an error in
	-- the preparation fails the road, not the whole run.
	local function prepareCommand(e : integer, attempt : integer, plan : RubPlan) : Prepared
		local prepared : Prepared = { force = false }
		local okP, errP = pcall(function() : string
			prepared.p, prepared.summary, prepared.why = proposalOf(e, plan)
			if prepared.p == nil then return nil end
			prepared.context = makeContext(removeBuildings)
			local blockers = removeBuildings and attempt > 0 and assetBlockers[e] or nil
			if blockers ~= nil then
				-- An earlier road of this press may have removed a shared asset group.
				local remaining = existing(blockers)
				blockers = #remaining > 0 and remaining or nil
			end
			prepared.force = blockers ~= nil and attempt >= RETRY_PASSES
			if blockers ~= nil then
				addToRemove(prepared.p, blockers)
				prepared.summary = prepared.summary .. string.format("; %d asset groups in the way put in toRemove%s", #blockers,
					prepared.force and ", sent with ignoreErrors" or "")
			end
			local lotHouseRetry = removeBuildings and attempt == LOT_HOUSE_ATTEMPT and assetBlockers[e] == nil
			if lotHouseRetry and not isRail then
				prepared.partner = tryPair(e, plan, prepared)
			end
			if lotHouseRetry and not isRail and prepared.partner == nil then
				local found, houseText = probe.lotHouses(e)
				if houseText ~= "" then prepared.summary = prepared.summary .. "; " .. houseText end
				-- An earlier road of this press may have removed a shared house.
				local houses = existing(found)
				if #houses > 0 then
					addToRemove(prepared.p, houses)
					prepared.summary = prepared.summary .. string.format("; %d lot houses put in toRemove", #houses)
				end
			end
			return nil
		end)
		if not okP then
			prepared.p = nil
			prepared.errText = tostring(errP)
		end
		return prepared
	end

	-- Forward declaration: sendRoad builds and sends the command of one road.
	local sendRoad : function(integer, integer, RubPlan, function())

	-- The answer of the game to the command of one road. `done` runs after the command gap. `again` sends the next pair
	-- command of the road.
	local function onCommandResult(e : integer, attempt : integer, prepared : Prepared, data : WorldBuildProposalCommandData,
			success : boolean, done : function(), again : function())
		local partner = prepared.partner
		local summary = prepared.summary
		local pairAgain = false
		res.commands = res.commands + 1
		local msgs = messagesOf(data)
		local cost = costOf(data)
		local outcome = "ok"
		if success == true then
			res.removed = res.removed + 1
			report(e, true)
			if cost ~= nil then res.cost = (res.cost or 0) + cost end
			if attempt > 0 then recovered = recovered + 1 end
			crosswalks:touchRoad(e)
			addNotes(e)
			if partner ~= nil then
				addNotes(partner)
				res.removed = res.removed + 1
				pairHandled[partner] = true
				report(partner, true)
				if attempt > 0 then recovered = recovered + 1 end
				crosswalks:touchRoad(partner)
			end
		elseif partner ~= nil and nextPartner(e, false) ~= nil then
			outcome = "FAILED"
			pairAgain = true
		else
			lotFailed[e] = mentionsParcel(msgs)
			fail(e, msgs[1] or REFUSED_BY_GAME)
			outcome = "FAILED"
			local assets, onlyAssets = assetGroupsOf(data, e)
			assetBlockers[e] = (onlyAssets and #msgs == 1) and assets or nil
		end
		logLine(string.format("cmd %d%s: edge %d -> %s%s; %s; %s; %s", res.commands, attempt > 0 and string.format(" (retry %d)", attempt) or "", e,
			outcome, #msgs > 0 and (": " .. table.concat(msgs, "; ")) or "", simulationText(), summary,
			success == true and string.format("cost %s, %d buildings gathered", tostring(cost), buildingCount(data))
				or ("collides with: " .. collisionText(data, e) .. "; road: " .. describeRoad(e))),
			success == true and "upgrade" or "failure")
		if cancelled then
			finish()
			return
		end
		afterGap(function()
			press.after(e, simulationText)
			if partner ~= nil and success == true then
				press.road(partner, attempt)
				press.after(partner, simulationText)
			end
			if pairAgain then
				local okA, errA = pcall(function() : string again(); return nil end)
				if not okA then
					logLine("pair spike: the next pair command failed: " .. tostring(errA), "failure")
					finish()
				end
				return
			end
			local okC, errC = pcall(function() : string done(); return nil end)
			if not okC then
				logLine("upgrade callback failed: " .. tostring(errC), "failure")
				finish()
			end
		end)
	end

	-- The proposal of one road and its command, sent while the game is paused. `done` runs when the road is finished.
	sendRoad = function(e : integer, attempt : integer, plan : RubPlan, done : function())
		local prepared = prepareCommand(e, attempt, plan)
		press.proposal(e, prepared.p, res.commands)
		if prepared.errText ~= nil then
			logLine(string.format("edge %d: preparing the command failed: %s", e, prepared.errText), "failure")
			fail(e, "script error")
			done()
			return
		end
		if prepared.p == nil then
			fail(e, prepared.why or REFUSED_BY_GAME)
			logLine(string.format("edge %d: %s", e, prepared.summary), "failure")
			done()
			return
		end
		if prepared.partner ~= nil then
			logLine(string.format("pair spike: sending ONE proposal for edges %d and %d (a merged proposal can crash the game)", e, prepared.partner))
		end
		local called = false
		busy = true
		local okS, errS = pcall(function() : string
			local cmd = api.cmd.makeWorldBuildProposalCmd(prepared.p, prepared.context, prepared.force, true, true)
			api.cmd.sendCommand(cmd, function(data : WorldBuildProposalCommandData, success : boolean)
				if called or finished then return end
				called = true
				busy = false
				onCommandResult(e, attempt, prepared, data, success, done, function() sendRoad(e, attempt, plan, done) end)
			end)
			return nil
		end)
		if not okS and not called then
			called = true
			busy = false
			logLine("send failed: " .. tostring(errS), "failure")
			fail(e, "script error")
			done()
		end
	end

	-- One road: nothing for a road that already is the target; else its command, sent while the game is paused.
	-- `done` runs when the road is finished, from the command callback when a command was sent.
	local function upgradeRoad(e : integer, attempt : integer, done : function())
		if pairHandled[e] then
			done()
			return
		end
		local plan = planOf(e)
		if #(plan.notes or {}) > 0 then logLine(string.format("edge %d: notes of its plan: %s", e, table.concat(plan.notes, ", "))) end
		if plan.reason ~= nil or plan.template == nil then
			skip(plan.reason or REFUSED_BY_GAME)
			logLine(string.format("edge %d: left alone: %s", e, tostring(plan.reason)))
			report(e, true)
			done()
			return
		end
		if plan.unchanged then
			res.unchanged = res.unchanged + 1
			addNotes(e)
			logLine(string.format("edge %d: already the target, left alone", e))
			report(e, true)
			done()
			return
		end
		local passed, dr = upgrade.assertHardRules({ e }, ctx, industryRoads, kind)
		if #passed == 0 then
			skipDropped(dr, "before send")
			done()
			return
		end
		press.road(e, attempt)
		busy = true
		ensurePaused(logLine, function(paused : boolean)
			busy = false
			if finished then return end
			if cancelled then
				finish()
				return
			end
			if not paused then
				pauseFailed = true
				fail(e, PAUSE_NOTE)
				done()
				return
			end
			sendRoad(e, attempt, plan, done)
		end)
	end

	-- The roads of one pass, one after the other. When the game cannot be paused, the roads left in the pass
	-- count as failed with that reason.
	local function runPass(list : {integer}, attempt : integer, passDone : function())
		local step : function(integer)
		step = function(i : integer)
			if finished or cancelled then return end
			if pauseFailed then
				for j = i, #list do fail(list[j], PAUSE_NOTE) end
				passDone()
				return
			end
			if i > #list then
				passDone()
				return
			end
			upgradeRoad(list[i], attempt, function() step(i + 1) end)
		end
		step(1)
	end

	local function skipFailed()
		for _, e in ipairs(failed) do
			skip(failedReason[e])
			res.failed[#res.failed + 1] = e
			if lotFailed[e] then res.lotFailures = res.lotFailures + 1 end
		end
	end

	-- What the crosswalk pass may use: one command at a time with its answer delivered after the command gap, a wait that goes through
	-- the same pending step as the gap, the log, a fresh context, and the cancel flag.
	local function crosswalkEnv() : RubCrosswalkEnv
		return {
			send = function(command : Command<WorldBuildProposalCommandData>, callback : function(boolean, string))
				local called = false
				busy = true
				local okS, errS = pcall(function() : string
					api.cmd.sendCommand(command, function(data : WorldBuildProposalCommandData, success : boolean)
						if called or finished then return end
						called = true
						busy = false
						if cancelled then
							finish()
							return
						end
						local text = table.concat(messagesOf(data), "; ")
						afterGap(function() callback(success == true, text) end)
					end)
					return nil
				end)
				if not okS and not called then
					called = true
					busy = false
					callback(false, "send failed: " .. tostring(errS))
				end
			end,
			wait = function(seconds : number, step : function()) afterSeconds(seconds, step) end,
			-- A line of the pass is progress for the tool: it gives up waiting for a commit that shows none for a long time.
			log = function(text : string, tag : string)
				logLine(text, tag)
				report(nil, true)
			end,
			context = function() : Context return makeContext(removeBuildings) end,
			cancelled = function() : boolean return cancelled or finished end,
			progress = function(done : integer, total : integer)
				passAttempt = CROSSWALK_PASS
				passTotal = total
				passFinished = done
				report(nil, true)
			end,
		}
	end

	-- The failed roads go through the queue again, up to RETRY_PASSES times, each time after all the others.
	local function afterPass(attempt : integer)
		if pauseFailed then
			-- a retry cannot work without a paused game
			skipFailed()
			if res.commands == 0 then res.refused = PAUSE_NOTE end
			finish()
			return
		end
		if #failed == 0 or attempt >= RETRY_PASSES then
			skipFailed()
			crosswalks:run(crosswalkEnv(), finish)
			return
		end
		local again = failed
		failed = {}
		startPass(attempt + 1, #again)
		retryList = again
		logLine(string.format("retry %d of %d: %d roads whose command failed", attempt + 1, RETRY_PASSES, #again))
		runPass(again, attempt + 1, function() afterPass(attempt + 1) end)
	end

	runPass(queue, 0, function() afterPass(0) end)
end
upgrade.RETRY_PASSES = RETRY_PASSES

return upgrade
