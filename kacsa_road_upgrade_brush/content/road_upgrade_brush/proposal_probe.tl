-- Diagnostic probe, on only with the mod option "Debug: upgrade log". With the option Off no function here reads a road,
-- a proposal, or a construction, except `lotHouses`: the commit uses its result with the option On or Off. It returns the
-- list of lot houses that the commit puts in the removal list of a retry. An empty list means that nothing is put in.
-- The probe logs what the proposal of a construction tool contains while the cursor is over a road (at most once per
-- MIN_INTERVAL seconds, only a changed line, at most MAX_LINES per session), and for each road of an upgrade the old
-- road, the added segment, and the road after the command (at most PRESS_LINE_CAP lines per press and
-- SESSION_LINE_CAP per session).

local brush = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/bb_brush.tl" as RubBrush

local probe : RubProposalProbe = {}

local MOD_ID <const> = "kacsa_road_upgrade_brush"
-- The key of the param in mod.json. Params reach scripts as 1-based value indices: OPTION_ON is the second value.
local OPTION_KEY <const> = "rub_log"
local OPTION_ON <const> = 2
local LOG_PREFIX <const> = "[BrushUpgrade] "

local MAX_LINES <const> = 60
-- Calls of `describe` (it reads components of the game) per session, whether or not they give a new line.
local MAX_DESCRIBE_CALLS <const> = 200
local MAX_IDS <const> = 12
local MIN_INTERVAL <const> = 1.0
local MAX_TRACE <const> = 5
local PRESS_LINE_CAP <const> = 800
local SESSION_LINE_CAP <const> = 4000
-- Metres. A road after its command counts as the watched road when both end points lie this close to the old ones.
local END_MATCH_METERS <const> = 1.0
-- Metres. A construction counts as a lot house of a road when it lies within half the road length plus this reach of the
-- middle of the road.
local LOT_REACH_METERS <const> = 30
-- More lot houses than this give an empty list, never a part of the list.
local MAX_LOT_HOUSES <const> = 24

local linesLogged = 0
local describeCalls = 0
local lastLine = ""
local lastReadAt = -MIN_INTERVAL
-- Calls of probe.install per tool (an action id).
local installs : {string : integer} = {}
-- The action params that already carry the hook. Weak keys: params that the game drops are not kept.
local hooked : {any : boolean} = setmetatable({}, { __mode = "k" }) as {any : boolean}
local optionOn : boolean = nil
local pressLines = 0
local sessionLines = 0
local pressCapNoted = false
local sessionCapNoted = false

-- A failing log write never reaches the caller.
local function write(text : string)
	pcall(log.message, LOG_PREFIX .. text)
end

local function readOption() : boolean
	local ok, on = pcall(function() : boolean
		local mine = api.engine.config.getModParams()[MOD_ID] as {string : integer}
		return mine ~= nil and mine[OPTION_KEY] == OPTION_ON
	end)
	return ok and on
end

function probe.refresh() : boolean
	optionOn = readOption()
	return optionOn
end

function probe.enabled() : boolean
	if optionOn == nil then probe.refresh() end
	return optionOn
end

function probe.beginPress()
	probe.refresh()
	pressLines = 0
	pressCapNoted = false
end

function probe.tag(category : string, text : string) : string
	if not probe.enabled() then return text end
	return "[" .. category .. "] " .. text
end

local function line(text : string)
	if not probe.enabled() then return end
	if sessionLines >= SESSION_LINE_CAP then
		if not sessionCapNoted then
			sessionCapNoted = true
			write(string.format("[probe] session cap of %d lines reached, no more probe lines until the game restarts", SESSION_LINE_CAP))
		end
		return
	end
	if pressLines >= PRESS_LINE_CAP then
		if not pressCapNoted then
			pressCapNoted = true
			write(string.format("[probe] press cap of %d lines reached, no more probe lines in this press", PRESS_LINE_CAP))
		end
		return
	end
	pressLines = pressLines + 1
	sessionLines = sessionLines + 1
	write("[probe] " .. text)
end

local function idList(list : {integer}) : string
	local parts : {string} = {}
	for i, e in ipairs(list or {}) do
		if i > MAX_IDS then
			parts[#parts + 1] = "..."
			break
		end
		parts[#parts + 1] = tostring(e)
	end
	return string.format("%d [%s]", #(list or {}), table.concat(parts, ", "))
end

-- The lanes as "<" or ">" for the direction and the transport mode numbers of the lane joined by "+".
local function lanesText(laneConfigs : {LaneConfig}) : string
	local lanes : {string} = {}
	for _, lc in ipairs(laneConfigs or {}) do
		local modes : {string} = {}
		for mode, on in pairs(lc.transportModes or {}) do
			if on then modes[#modes + 1] = tostring(mode) end
		end
		table.sort(modes)
		lanes[#lanes + 1] = (lc.forward and ">" or "<") .. table.concat(modes, "+")
	end
	return table.concat(lanes, " ")
end

-- The decorations as "id:flag" pairs, in the order of the list.
local function decorationsText(decorations : {{integer, boolean}}) : string
	local parts : {string} = {}
	for _, d in ipairs(decorations or {}) do parts[#parts + 1] = string.format("%s:%s", tostring(d[1]), tostring(d[2])) end
	return table.concat(parts, " ")
end

local function valuesText(template : string, kind : string, locked : boolean, decorations : {{integer, boolean}}, laneConfigs : {LaneConfig}) : string
	return string.format("template %s, type %s, locked %s, decorations [%s], lanes [%s]", tostring(template), kind,
		tostring(locked), decorationsText(decorations), lanesText(laneConfigs))
end

local function edgeText(comp : Engine.Component.BaseEdge) : string
	return valuesText(comp.roadTemplate, tostring(comp.type) .. "/" .. tostring(comp.typeIndex), comp.roadDevelopmentLocked,
		comp.edgeDecorations, comp.laneConfigs)
end

local function segmentText(seg : Proposal.SegmentAndEntity) : string
	local comp = seg.comp
	return valuesText(comp.roadTemplate, tostring(comp.type) .. "/" .. tostring(comp.typeIndex), comp.roadDevelopmentLocked,
		comp.edgeDecorations, comp.laneConfigs)
end

-- A construction with town buildings is a house. old2new maps a moved entity to its new entity.
local function removedKinds(proposal : Proposal) : string
	local parts : {string} = {}
	local types = api.type.ComponentType
	for i, e in ipairs(proposal.toRemove or {}) do
		if i > MAX_IDS then break end
		local kinds : {string} = {}
		local okC, c = pcall(function() : Engine.Component.Construction
			return api.engine.getComponent(e, types.CONSTRUCTION) as Engine.Component.Construction
		end)
		if okC and c ~= nil then
			kinds[#kinds + 1] = string.format("construction (%d town buildings, %s)", #(c.townBuildings or {}), tostring(c.fileName))
		end
		local okE, edge = pcall(function() : Engine.Component.BaseEdge
			return api.engine.getComponent(e, types.BASE_EDGE) as Engine.Component.BaseEdge
		end)
		if okE and edge ~= nil then kinds[#kinds + 1] = "edge" end
		local okM, moved = pcall(function() : any return (proposal.old2new as any as {integer : any})[e] end)
		kinds[#kinds + 1] = (okM and moved ~= nil) and "moved" or "removed"
		parts[#parts + 1] = string.format("%d: %s", e, table.concat(kinds, ", "))
	end
	return table.concat(parts, " | ")
end

local function collisionKinds(data : ProposalData, replaced : {integer}) : string
	local info = data.collisionInfo
	if info == nil then return "" end
	local own : {integer : boolean} = {}
	for _, e in ipairs(replaced) do own[e] = true end
	local types = api.type.ComponentType
	local parts : {string} = {}
	for i, c in ipairs(info.collisionEntities or {}) do
		if i > MAX_IDS then break end
		local e = c.entity
		local kind = "other"
		local okE, edge = pcall(function() : Engine.Component.BaseEdge
			return api.engine.getComponent(e, types.BASE_EDGE) as Engine.Component.BaseEdge
		end)
		local okC, con = pcall(function() : Engine.Component.Construction
			return api.engine.getComponent(e, types.CONSTRUCTION) as Engine.Component.Construction
		end)
		local okN, node = pcall(function() : Engine.Component.BaseNode
			return api.engine.getComponent(e, types.BASE_NODE) as Engine.Component.BaseNode
		end)
		if okE and edge ~= nil then
			kind = string.format("road (%s, type %s)", tostring(edge.roadTemplate), tostring(edge.type))
		elseif okC and con ~= nil then
			kind = "construction (" .. tostring(con.fileName) .. ")"
		elseif okN and node ~= nil then
			kind = "node"
		end
		parts[#parts + 1] = string.format("%d: %s%s", e, kind, own[e] and ", replaced by the proposal" or "")
	end
	return string.format("%s; %d buildings", table.concat(parts, " | "), #(info.buildingEntities or {}))
end

local function modifierText(params : Builtin.ConstructionActionParam) : string
	local m = params.streetEdgeNodeModifier
	if m == nil then return "no modifier" end
	return string.format("modifier busLane %s, tram %s, lock %s, underground %s, symmetric %s",
		tostring(m.busLane), tostring(m.tramTrackType), tostring(m.roadDevelopmentLocked), tostring(m.undergroundMode),
		tostring(m.symmetricLanes))
end

local function describe(params : Builtin.ConstructionActionParam, proposal : Proposal, data : ProposalData) : string
	local street = proposal.proposal
	local removed : {integer} = {}
	for _, s in ipairs(street.removedSegments) do removed[#removed + 1] = s.entity end
	local templates : {string} = {}
	for _, s in ipairs(street.addedSegments) do
		templates[#templates + 1] = tostring(s.comp.roadTemplate) .. ": " .. segmentText(s)
	end
	local parts : {string} = {
		modifierText(params),
		"removed segments " .. idList(removed),
		"added segments [" .. table.concat(templates, " | ") .. "]",
		string.format("nodes +%d/-%d, edge objects +%d", #street.addedNodes, #street.removedNodes, #street.edgeObjectsToAdd),
		"toRemove " .. idList(proposal.toRemove),
		"toRemove kinds [" .. removedKinds(proposal) .. "]",
		string.format("toAdd %d", #(proposal.toAdd or {})),
	}
	if data ~= nil then
		local es = data.errorState
		parts[#parts + 1] = string.format("costs %s", tostring(data.costs))
		parts[#parts + 1] = "collides with [" .. collisionKinds(data, removed) .. "]"
		if es ~= nil then
			parts[#parts + 1] = string.format("messages [%s], warnings [%s]",
				table.concat((es.messages or {}) as {string}, "; "), table.concat((es.warnings or {}) as {string}, "; "))
		end
	end
	return table.concat(parts, "; ")
end

-- The game calls getProposalStringsFn with the proposal under the cursor.
function probe.install(params : Builtin.ConstructionActionParam, tool : string)
	if not probe.enabled() or hooked[params] then return end
	local original = params.getProposalStringsFn
	local count = (installs[tool] or 0) + 1
	installs[tool] = count
	if original == nil then
		if count == 1 then write(string.format("[probe] %s: no getProposalStringsFn to hook, nothing changed", tool)) end
		return
	end
	hooked[params] = true
	if count <= MAX_TRACE then
		write(string.format("[probe] hooked the action params of %s (call %d)", tool, count))
	end
	params.getProposalStringsFn = function(proposal : Proposal, data : ProposalData) : {string}
		local now = os.clock()
		if linesLogged < MAX_LINES and describeCalls < MAX_DESCRIBE_CALLS and now - lastReadAt >= MIN_INTERVAL then
			lastReadAt = now
			describeCalls = describeCalls + 1
			local ok, described = pcall(describe, params, proposal, data)
			if not ok then described = "describe failed: " .. tostring(described) end
			if described ~= lastLine then
				lastLine = described
				linesLogged = linesLogged + 1
				write("[probe] " .. tool .. ": " .. described)
			end
			if describeCalls == MAX_DESCRIBE_CALLS then
				write(string.format("[probe] hook read cap of %d reached, no more proposal lines until the game restarts", MAX_DESCRIBE_CALLS))
			end
		end
		return original(proposal, data)
	end
end

-- The owner of an edge as text: "owner <player>" or "no owner".
local function ownerText(edge : integer) : string
	local ok, owner = pcall(function() : Engine.Component.PlayerOwned
		return api.engine.getComponent(edge, api.type.ComponentType.PLAYER_OWNED) as Engine.Component.PlayerOwned
	end)
	if not ok then return "owner unreadable" end
	return (owner ~= nil and owner.player ~= nil) and ("owner " .. tostring(owner.player)) or "no owner"
end

local function endsOf(comp : Engine.Component.BaseEdge) : {number}
	local a, b = comp.position0, comp.position1
	return { a.x, a.y, a.z, b.x, b.y, b.z }
end

-- Metres between the point at index i of one list of ends and the point at index j of the other.
local function pointGap(ends : {number}, i : integer, other : {number}, j : integer) : number
	local dx, dy, dz = ends[i] - other[j], ends[i + 1] - other[j + 1], ends[i + 2] - other[j + 2]
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function sameEnds(ends : {number}, other : {number}) : boolean
	local forward = pointGap(ends, 1, other, 1) <= END_MATCH_METERS and pointGap(ends, 4, other, 4) <= END_MATCH_METERS
	local reverse = pointGap(ends, 1, other, 4) <= END_MATCH_METERS and pointGap(ends, 4, other, 1) <= END_MATCH_METERS
	return forward or reverse
end

-- Reads the old road. It MUST NOT run in a command callback.
local function before(edge : integer, attempt : integer) : RubProbeWatch
	if not probe.enabled() then return nil end
	local ok, watch = pcall(function() : RubProbeWatch
		local old = api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
		if old == nil then
			line(string.format("edge %d attempt %d before: no road component", edge, attempt))
			return nil
		end
		return {
			edge = edge, attempt = attempt, ends = endsOf(old), oldText = edgeText(old) .. ", " .. ownerText(edge),
			radius = old.distance ~= nil and old.distance + END_MATCH_METERS or brush.EDGE_MARGIN,
		}
	end)
	if not ok then
		line(string.format("edge %d attempt %d before: read failed: %s", edge, attempt, tostring(watch)))
		return nil
	end
	return watch
end

-- Writes the one line of the road before its command. `p` is nil when no proposal was built. `commands` is the number of
-- commands sent since the old road was read.
local function proposal(watch : RubProbeWatch, p : Proposal, commands : integer)
	if watch == nil then return end
	local ok, addedText = pcall(function() : string
		if p == nil then return "none, no proposal was built" end
		local added = p.proposal.addedSegments
		return string.format("(%d in the proposal) %s", #added, #added > 0 and segmentText(added[1]) or "none")
	end)
	line(string.format("edge %d attempt %d before (old road read at press start, %d commands sent since): old road: %s; added segment %s",
		watch.edge, watch.attempt, commands, watch.oldText, ok and addedText or ("unreadable: " .. tostring(addedText))))
end

-- `state` is appended to the line, to show the game speed and update count at the read.
local function after(watch : RubProbeWatch, state : string)
	if watch == nil or not probe.enabled() then return end
	local ok, err = pcall(function() : string
		local ends = watch.ends
		local middle = api.type.Vec2f.new((ends[1] + ends[4]) / 2, (ends[2] + ends[5]) / 2)
		local found = api.engine.util.octree.findEntitiesInCircle(middle, watch.radius, api.type.ComponentType.BASE_EDGE) as {integer}
		local texts : {string} = {}
		for _, e in ipairs(found) do
			local comp = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
			if comp ~= nil and comp.position0 ~= nil and comp.position1 ~= nil and sameEnds(ends, endsOf(comp)) then
				texts[#texts + 1] = string.format("edge %d: %s, %s", e, edgeText(comp), ownerText(e))
			end
		end
		if #texts == 0 then
			line(string.format("edge %d attempt %d after: no road found at the end points (a miss of the lookup, not proof that the road is gone); %s", watch.edge, watch.attempt, state))
		else
			line(string.format("edge %d attempt %d after: %d roads at the end points: %s; %s", watch.edge, watch.attempt, #texts, table.concat(texts, " | "), state))
		end
		return nil
	end)
	if not ok then
		line(string.format("edge %d attempt %d after: read failed: %s", watch.edge, watch.attempt, tostring(err)))
	end
end

-- A lot house is a construction with exactly one town building and no station, depot, or industry.
local function isLotHouse(c : Engine.Component.Construction) : boolean
	return c ~= nil and #(c.townBuildings or {}) == 1 and #(c.stations or {}) == 0 and #(c.depots or {}) == 0
		and #(c.industries or {}) == 0
end

-- The lot houses within reach of the road `edge`, in the order the octree gives them. It raises an error when a read fails.
local function housesNear(edge : integer) : {integer}
	local types = api.type.ComponentType
	local old = api.engine.getComponent(edge, types.BASE_EDGE) as Engine.Component.BaseEdge
	if old == nil then error("no road component", 0) end
	local ends = endsOf(old)
	local length = old.distance ~= nil and old.distance or pointGap(ends, 1, ends, 4)
	local middle = api.type.Vec2f.new((ends[1] + ends[4]) / 2, (ends[2] + ends[5]) / 2)
	local found = api.engine.util.octree.findEntitiesInCircle(middle, length / 2 + LOT_REACH_METERS, types.CONSTRUCTION) as {integer}
	local houses : {integer} = {}
	for _, e in ipairs(found) do
		if isLotHouse(api.engine.getComponent(e, types.CONSTRUCTION) as Engine.Component.Construction) then houses[#houses + 1] = e end
	end
	return houses
end

function probe.lotHouses(edge : integer) : {integer}, string
	local ok, houses = pcall(housesNear, edge)
	if not ok then return {}, "lot house read failed: " .. tostring(houses) end
	local found = houses as {integer}
	if #found > MAX_LOT_HOUSES then
		return {}, string.format("%d lot houses found within %d m of the road, more than the cap of %d, none put in toRemove", #found,
			LOT_REACH_METERS, MAX_LOT_HOUSES)
	end
	local ids : {string} = {}
	for i, e in ipairs(found) do ids[i] = tostring(e) end
	return found, string.format("%d lot houses within %d m of the road: [%s]", #found, LOT_REACH_METERS, table.concat(ids, ", "))
end

function probe.press(edges : {integer}) : RubProbePress
	local watches : {integer : RubProbeWatch} = {}
	if probe.enabled() then
		for _, e in ipairs(edges) do watches[e] = before(e, 0) end
	end
	local press : RubProbePress = {}
	press.road = function(edge : integer, attempt : integer)
		local watch = watches[edge]
		if watch ~= nil then watch.attempt = attempt end
	end
	press.proposal = function(edge : integer, p : Proposal, commands : integer)
		local watch = watches[edge]
		if watch ~= nil then pcall(proposal, watch, p, commands) end
	end
	press.after = function(edge : integer, state : function() : string)
		local watch = watches[edge]
		if watch ~= nil then pcall(function() : string after(watch, state()); return nil end) end
	end
	return press
end

return probe
