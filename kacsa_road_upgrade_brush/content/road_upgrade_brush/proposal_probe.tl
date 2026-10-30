-- Diagnostic probe: logs what the proposal of the single-click tool contains while the cursor is over a road,
-- so it can be compared with the replaceSegment proposal of the brush tool (same road, same template).
-- The game calls the hook many times a second, so the probe reads the proposal at most once per
-- MIN_INTERVAL seconds and logs only a changed line, at most MAX_LINES per session.

local probe : ProposalProbe = {}

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
		string.format("toAdd %d", #(proposal.toAdd or {})),
	}
	if data ~= nil then
		local es = data.errorState
		parts[#parts + 1] = string.format("costs %s", tostring(data.costs))
		if es ~= nil then
			parts[#parts + 1] = string.format("messages [%s], warnings [%s]",
				table.concat((es.messages or {}) as {string}, "; "), table.concat((es.warnings or {}) as {string}, "; "))
		end
	end
	return table.concat(parts, "; ")
end

-- Wraps getProposalStringsFn of the action, which the game calls with the proposal under the cursor.
function probe.install(params : Builtin.ConstructionActionParam)
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
