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
local EXTRAS_NOT_APPLIED <const> = "bus lane or lock could not be set"

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

-- The edge decorations (alley trees, noise barriers) a template brings when a road is newly built.
-- replaceSegment keeps the decorations of the old road.
local function templateDecorations(template : string) : {{integer, boolean}}
	local result : {{integer, boolean}} = {}
	local templateId = api.res.streetTemplateRep.find(template)
	if templateId < 0 then return result end
	for _, entry in ipairs(api.res.streetTemplateRep.get(templateId).defaultEdgeDecorations or {}) do
		local id = api.res.edgeDecorationRep.find(entry[1])
		if id >= 0 then result[#result + 1] = { id, entry[2] } end
	end
	return result
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

-- The first and the last lane that carries vehicles (neither people nor cargo): the outermost driving lane on each side.
local function outerVehicleLanes(lanes : {LaneConfig}) : {integer}
	local modes = api.type["enum"].TransportMode
	local vehicle : {integer} = {}
	for i, lane in ipairs(lanes or {}) do
		if not lane.transportModes[modes.PERSON] and not lane.transportModes[modes.CARGO] then
			vehicle[#vehicle + 1] = i
		end
	end
	if #vehicle <= 1 then return vehicle end
	return { vehicle[1], vehicle[#vehicle] }
end

local function anyExtras(extras : RubExtras) : boolean
	return extras.busLane or extras.tram or extras.lock ~= "keep"
end

local function extrasText(extras : RubExtras) : string
	local on : {string} = {}
	if extras.busLane then on[#on + 1] = "bus lane" end
	if extras.tram then on[#on + 1] = extras.catenary and "tram with catenary" or "tram" end
	if extras.lock ~= "keep" then on[#on + 1] = extras.lock end
	return #on > 0 and table.concat(on, ", ") or "none"
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

-- The bus lane, tram track and catenary of Road Upgrade All in One, put on the new segments. They differ from the plain
-- proposal in the transport modes of the outer driving lanes (bus lane: no car; tram track: the tram; catenary: the
-- electric tram) and, with the lock, in the lock flag of the segment. The getters may hand out copies: it writes back
-- at every level. The result is false when the lanes read back from the proposal differ from the meant ones, or when a
-- lane that was not edited differs from what it was. Such a proposal MUST NOT be sent: lanes with wrong modes can
-- stop the game in its transport network.
local function applyExtras(p : Proposal, extras : RubExtras) : boolean, string
	local modes = api.type["enum"].TransportMode
	local car = modeNumber(modes.CAR)
	local bus = modeNumber(modes.BUS)
	local tram = modeNumber(modes.TRAM)
	local electricTram = modeNumber(modes.ELECTRIC_TRAM)
	local street = p.proposal
	local segments = street.addedSegments
	local notes : {string} = {}
	-- the lanes meant per segment: segment index -> lane index -> mode numbers
	local meant : {integer : {integer : {integer : boolean}}} = {}
	-- the modes of every lane before the edit: segment index -> lane index -> mode numbers
	local snapshot : {{{integer : boolean}}} = {}
	for s, segment in ipairs(segments) do
		local comp = segment.comp
		if extras.busLane or extras.tram then
			meant[s] = {}
			snapshot[s] = {}
			for i, lane in ipairs(comp.laneConfigs) do snapshot[s][i] = modeSet(lane) end
			local lanes = comp.laneConfigs
			for _, i in ipairs(outerVehicleLanes(lanes)) do
				local lane = lanes[i]
				local want = modeSet(lane)
				local before = modesText(lane)
				if extras.busLane and want[bus] then want[car] = nil end
				if extras.tram then want[tram] = true end
				if extras.catenary then want[electricTram] = true end
				local written : {boolean} = {}
				for mode = 0, MODE_COUNT - 1 do written[mode + 1] = want[mode] == true end
				lane.transportModes = written as any as {TransportMode : boolean}
				lanes[i] = lane
				meant[s][i] = want
				if s == 1 then notes[#notes + 1] = string.format("lane %d %s -> meant %s", i, before, setText(want)) end
			end
			comp.laneConfigs = lanes
		end
		if extras.lock ~= "keep" then comp.roadDevelopmentLocked = extras.lock == "lock" end
		segment.comp = comp
	end
	street.addedSegments = segments
	p.proposal = street

	local verified = true
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
	if extras.lock ~= "keep" then
		local locked = extras.lock == "lock"
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
local ALL_MODE_NAMES : {string} = {
	"PERSON", "CARGO", "CAR", "BUS", "TRUCK", "TRAM", "ELECTRIC_TRAM", "TRAIN", "ELECTRIC_TRAIN", "AIRCRAFT", "SHIP",
	"SMALL_AIRCRAFT", "SMALL_SHIP", "HELICOPTER", "TRAM_TRACK", "ELECTRIC_TRAM_TRACK",
}

-- The mode numbers that are on in a lane, read by asking for every mode. Works for the lanes of a road and of a street template.
local function modeSetOf(lane : LaneConfig) : {integer : boolean}
	local modes = api.type["enum"].TransportMode as any as {string : any}
	local have = lane.transportModes as any as {any : boolean}
	local on : {integer : boolean} = {}
	for _, name in ipairs(ALL_MODE_NAMES) do
		local mode = modes[name]
		if mode ~= nil and have[mode] then on[modeNumber(mode)] = true end
	end
	return on
end

-- The modes the outer driving lanes of a road with the street template and the extras have, per lane index, and the
-- number of lanes. nil when the template is unknown.
local function templateOuterModes(template : string, extras : RubExtras) : {integer : {integer : boolean}}, integer
	local id = api.res.streetTemplateRep.find(template)
	if id < 0 then return nil, 0 end
	local modes = api.type["enum"].TransportMode
	local car, bus = modeNumber(modes.CAR), modeNumber(modes.BUS)
	local tram, electricTram = modeNumber(modes.TRAM), modeNumber(modes.ELECTRIC_TRAM)
	local lanes = api.res.streetTemplateRep.get(id).laneConfigs
	local out : {integer : {integer : boolean}} = {}
	for _, i in ipairs(outerVehicleLanes(lanes)) do
		local want = modeSetOf(lanes[i])
		if extras.busLane and want[bus] then want[car] = nil end
		if extras.tram then want[tram] = true end
		if extras.catenary then want[electricTram] = true end
		out[i] = want
	end
	return out, #lanes
end

-- Whether a road already is what the template and the extras make of it: the outer driving lanes have exactly the
-- modes meant, and the lock is as it is asked for ("keep" asks for nothing).
local function carriesExtras(comp : Engine.Component.BaseEdge, template : string, extras : RubExtras) : boolean
	if extras.lock ~= "keep" and (comp.roadDevelopmentLocked == true) ~= (extras.lock == "lock") then return false end
	local want, count = templateOuterModes(template, extras)
	if want == nil then return true end
	local lanes = comp.laneConfigs or {}
	if #lanes ~= count then return false end
	for i, meant in pairs(want) do
		if not sameSet(modeSetOf(lanes[i]), meant) then return false end
	end
	return true
end
-- The proposal that replaces the road with the template, and one log line about it.
-- `setDecorations`: the list is set even when it is empty (a track whose barrier is removed).
local function proposalOf(edge : integer, template : string, decorations : {{integer, boolean}}, extras : RubExtras, setDecorations? : boolean) : Proposal, string, string
	local ok, p = pcall(api.engine.util.proposal.replaceSegment, edge, template)
	if not ok or p == nil then return nil, "replaceSegment failed: " .. tostring(p), nil end
	local summary = ""
	-- A proposal whose extras are not in place is not sent.
	local unsafe = false
	local okS, errS = pcall(function() : string
		local street = p.proposal
		summary = string.format("+%d/-%d segments, +%d/-%d nodes, %d edge objects, toRemove %d, toAdd %d",
			#street.addedSegments, #street.removedSegments, #street.addedNodes, #street.removedNodes,
			#street.edgeObjectsToAdd, #(p.toRemove or {}), #(p.toAdd or {}))
		pcall(function() : string
			local old = api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
			local oldObjects = #(old.objects or {})
			local newObjects = #(street.addedSegments[1].comp.objects or {})
			summary = summary .. string.format(", edge objects %d -> %d%s", oldObjects, newObjects, newObjects < oldObjects and " (OBJECTS LOST)" or "")
			return nil
		end)
		if #decorations > 0 or setDecorations then
			local before = decorationCount(p)
			applyDecorations(p, decorations)
			summary = summary .. string.format(", decorations %d -> %d (wanted %d per segment)",
				before, decorationCount(p), #decorations)
		end
		if anyExtras(extras) then
			local okE, note = applyExtras(p, extras)
			summary = summary .. ", " .. note
			if not okE then unsafe = true end
		end
		return nil
	end)
	if not okS then
		summary = summary .. ", proposal inspection failed: " .. tostring(errS)
		unsafe = unsafe or anyExtras(extras)
	end
	if unsafe then return nil, summary, EXTRAS_NOT_APPLIED end
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

local function normalized(resName : string) : string
	if resName == nil then return "" end
	return (string.gsub(resName, "^::/", ""))
end

-- Whether the road already is what the upgrade would make it: the template, and the decorations when
-- the template brings its own.
local function isAlreadyTarget(edge : integer, template : string, decorations : {{integer, boolean}}, extras : RubExtras) : boolean
	local ok, same = pcall(function() : boolean
		local comp = api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
		if comp == nil or normalized(comp.roadTemplate) ~= normalized(template) then return false end
		if #decorations == 0 then return carriesExtras(comp, template, extras) end
		local have = comp.edgeDecorations or {}
		if #have ~= #decorations then return false end
		for _, want in ipairs(decorations) do
			local found = false
			for _, h in ipairs(have) do
				if h[1] == want[1] and h[2] == want[2] then found = true; break end
			end
			if not found then return false end
		end
		return carriesExtras(comp, template, extras)
	end)
	return ok and same == true
end

function upgrade.matcher(template : string, extras : RubExtras) : function(edge : integer) : boolean
	local decorations = templateDecorations(template)
	return function(edge : integer) : boolean
		return isAlreadyTarget(edge, template, decorations, extras)
	end
end

local TRAM_STATES : {string} = { "none", "tram", "catenary" }

function upgrade.extrasOf(edge : integer, template : string) : RubExtras
	local ok, found = pcall(function() : RubExtras
		local comp = api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
		if comp == nil then return nil end
		local lock = comp.roadDevelopmentLocked and "lock" or "keep"
		for _, bus in ipairs({ false, true }) do
			for _, tramState in ipairs(TRAM_STATES) do
				local extras : RubExtras = { busLane = bus, tram = tramState ~= "none", catenary = tramState == "catenary", lock = "keep" }
				if carriesExtras(comp, template, extras) then
					extras.lock = lock
					return extras
				end
			end
		end
		return nil
	end)
	if ok then return found end
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

function upgrade.commit(edges : {integer}, template : string, extras : RubExtras, removeBuildings : boolean, ctx : RubContext,
		industryRoads : {integer : boolean}, onDone : function(RubCommitResult), logFn : function(string),
		onRoad : function(integer, boolean, integer, integer, integer), railTarget? : RubRailTarget)
	local t0 = os.clock()
	extras = extras or { busLane = false, tram = false, catenary = false, lock = "keep" }
	local plainLog = logFn or function(_s : string) end
	local function logLine(text : string, category? : string)
		plainLog(probe.tag(category or "upgrade", text))
	end
	edges = edges or {}
	local res : RubCommitResult = {
		requested = #edges, removed = 0, unchanged = 0, failed = {}, skipped = 0, reasons = {}, commands = 0,
		refused = nil, cost = nil, seconds = 0, rail = railTarget ~= nil, lotFailures = 0, buildingsKept = not removeBuildings,
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
		logLine(string.format("upgrade done: %d of %d, %d unchanged, skipped %d%s, %d recovered by the retry, %d commands, cost %s, %.0f ms%s",
			res.removed, res.requested, res.unchanged, res.skipped,
			next(res.reasons) ~= nil and (" (" .. reasonsText(res.reasons) .. ")") or "", recovered,
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

	if template == nil and railTarget == nil then
		res.refused = "no valid road type"
		finish()
		return
	end

	local kind : RubKind = railTarget ~= nil and "track" or "road"
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
	local decorations : {{integer, boolean}} = template ~= nil and templateDecorations(template) or {}
	logLine(string.format("upgrade: %d %s, template %s, extras: %s, %d default decorations, remove buildings %s, %s",
		#queue, railTarget ~= nil and "tracks" or "roads", template or "per track", extrasText(extras), #decorations,
		tostring(removeBuildings), simulationText()))

	-- `probe.press` and `crosswalks:prepare` MUST NOT run in a command callback. They read the roads of the press here, before
	-- the first command. Tracks have no crosswalks.
	local press = probe.press(queue)
	if railTarget == nil then crosswalks:prepare(queue) end

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
	local function tryPair(e : integer, target : string, wanted : {{integer, boolean}}, setWanted : boolean, prepared : Prepared) : integer
		local partner = nextPartner(e, true)
		if partner == nil then return nil end
		pairTried[pairKey(e, partner)] = true
		local ok, err = pcall(function() : string
			if #(upgrade.assertHardRules({ partner }, ctx, industryRoads, kind)) == 0 then error("the neighbour no longer passes the hard rules", 0) end
			local base, baseSummary = proposalOf(e, target, wanted, extras, setWanted)
			local other, otherSummary = proposalOf(partner, target, wanted, extras, setWanted)
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
	local function prepareCommand(e : integer, attempt : integer, target : string, wanted : {{integer, boolean}}, setWanted : boolean) : Prepared
		local prepared : Prepared = { force = false }
		local okP, errP = pcall(function() : string
			prepared.p, prepared.summary, prepared.why = proposalOf(e, target, wanted, extras, setWanted)
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
			if lotHouseRetry and railTarget == nil then
				prepared.partner = tryPair(e, target, wanted, setWanted, prepared)
			end
			if lotHouseRetry and railTarget == nil and prepared.partner == nil then
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
	local sendRoad : function(integer, integer, string, {{integer, boolean}}, boolean, function())

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
			if partner ~= nil then
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
	sendRoad = function(e : integer, attempt : integer, target : string, wanted : {{integer, boolean}}, setWanted : boolean, done : function())
		local prepared = prepareCommand(e, attempt, target, wanted, setWanted)
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
				onCommandResult(e, attempt, prepared, data, success, done, function() sendRoad(e, attempt, target, wanted, setWanted, done) end)
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
		local target = template
		local same : boolean
		local wanted = decorations
		local setWanted = false
		if railTarget ~= nil then
			local railDecorations : {{integer, boolean}} = nil
			target, same, railDecorations = railTarget(e)
			if railDecorations ~= nil then
				wanted = railDecorations
				setWanted = true
			end
			if target == nil then
				skip(REASON_TEXT.track_type)
				logLine(string.format("edge %d: no target template for this track, left alone", e))
				report(e, true)
				done()
				return
			end
		else
			same = isAlreadyTarget(e, target, decorations, extras)
		end
		if same then
			res.unchanged = res.unchanged + 1
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
			sendRoad(e, attempt, target, wanted, setWanted, done)
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
