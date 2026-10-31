-- Diagnostic probe: logs what the proposal of the single-click tool contains while the cursor is over a road,
-- so it can be compared with the replaceSegment proposal of the brush tool (same road, same template).
-- The game calls the hook many times a second, so the probe reads the proposal at most once per
-- MIN_INTERVAL seconds and logs only a changed line, at most MAX_LINES per session.

local probe : ProposalProbe = {}

-- Switch for all diagnostics of the mod: the hover probe below, the "segment to send" line of the brush commit, and
-- the instance, layer, and cursor lines of the brush tool. true turns them on.
probe.ENABLED = false

local MAX_LINES <const> = 60
local MAX_IDS <const> = 12
local MIN_INTERVAL <const> = 1.0
local MAX_TRACE <const> = 5

local linesLogged = 0
local lastLine = ""
local lastReadAt = -MIN_INTERVAL
local installs = 0

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

-- The lanes (direction and transport modes), the road development lock and the edge type of one segment.
local function segmentText(seg : Proposal.SegmentAndEntity) : string
	local comp = seg.comp
	local lanes : {string} = {}
	for _, lc in ipairs(comp.laneConfigs or {}) do
		local modes : {string} = {}
		for mode, on in pairs(lc.transportModes or {}) do
			if on then modes[#modes + 1] = tostring(mode) end
		end
		table.sort(modes)
		lanes[#lanes + 1] = (lc.forward and ">" or "<") .. table.concat(modes, "+")
	end
	return string.format("type %s/%s, locked %s, %d decorations, lanes [%s]", tostring(comp.type), tostring(comp.typeIndex),
		tostring(comp.roadDevelopmentLocked), #(comp.edgeDecorations or {}), table.concat(lanes, " "))
end

-- What the entities in toRemove are: a construction with town buildings is a house that the proposal removes or moves
-- (old2new maps a moved one to its new entity).
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

-- What the game says the proposal collides with, with the kind of each entity: a road (template, bridge or tunnel), a
-- construction, a node, or other. An entity that the proposal replaces itself is marked.
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

-- The options the single-click tool has switched on.
local function modifierText(params : Builtin.ConstructionActionParam) : string
	local m = params.streetEdgeNodeModifier
	if m == nil then return "no modifier" end
	return string.format("modifier busLane %s, tram %s, lock %s, underground %s, symmetric %s",
		tostring(m.busLane), tostring(m.tramTrackType), tostring(m.roadDevelopmentLocked), tostring(m.undergroundMode),
		tostring(m.symmetricLanes))
end

local function describe(params : Builtin.ConstructionActionParam, proposal : Proposal, data : ProposalData) : string	local street = proposal.proposal
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

-- Wraps getProposalStringsFn of the action, which the game calls with the proposal under the cursor.
function probe.install(params : Builtin.ConstructionActionParam)
	if not probe.ENABLED then return end
	local original = params.getProposalStringsFn
	installs = installs + 1
	if installs <= MAX_TRACE then
		log.message(string.format("[RUS probe] hooked the action params (call %d, the game has its own getProposalStringsFn: %s)",
			installs, tostring(original ~= nil)))
	end
	params.getProposalStringsFn = function(proposal : Proposal, data : ProposalData) : {string}
		local now = os.clock()
		if linesLogged < MAX_LINES and now - lastReadAt >= MIN_INTERVAL then
			lastReadAt = now
			local ok, line = pcall(describe, params, proposal, data)
			if not ok then line = "describe failed: " .. tostring(line) end
			if line ~= lastLine then
				lastLine = line
				linesLogged = linesLogged + 1
				log.message("[RUS probe] " .. line)
			end
		end
		if original ~= nil then return original(proposal, data) end
		return {}
	end
end

probe.segmentText = segmentText

return probe
