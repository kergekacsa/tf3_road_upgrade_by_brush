-- Spike C of the lot-road failure: two neighbouring roads that fail together are replaced in ONE proposal.
-- `partners` finds the neighbours of a road through a shared node. `merge` puts the street data of one `replaceSegment`
-- proposal into another. This module reads only the BASE_EDGE of the roads that it is asked about and changes only the
-- proposals that it is given. It does not know the option "Debug: upgrade log": the caller decides when to use it.

local pairSpike : RubPairSpike = {}

-- The most neighbours of a road that `partners` returns.
local MAX_PARTNERS <const> = 3

local record IdMap
	ids : {integer : integer}
	order : {integer}
end

local function edgeNodes(edge : integer) : integer, integer
	local ok, comp = pcall(function() : Engine.Component.BaseEdge
		return api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	end)
	if not ok or comp == nil then return nil, nil end
	return comp.node0, comp.node1
end

function pairSpike.partners(edge : integer, candidates : {integer}) : {integer}
	local found : {integer} = {}
	if #candidates == 0 then return found end
	local n0, n1 = edgeNodes(edge)
	if n0 == nil or n1 == nil then return found end
	for _, candidate in ipairs(candidates) do
		if candidate ~= edge and #found < MAX_PARTNERS then
			local m0, m1 = edgeNodes(candidate)
			if m0 ~= nil and m1 ~= nil and (n0 == m0 or n0 == m1 or n1 == m0 or n1 == m1) then found[#found + 1] = candidate end
		end
	end
	return found
end

local function isTemporary(id : integer) : boolean
	return id ~= nil and id < 0
end

-- The temporary ids that the added segments, nodes, and edge objects define.
local function definedIds(segments : {Proposal.SegmentAndEntity}, nodes : {Proposal.NodeAndEntity}, objects : {Proposal.EdgeObject}) : {integer : boolean}
	local ids : {integer : boolean} = {}
	for _, s in ipairs(segments) do if isTemporary(s.entity) then ids[s.entity] = true end end
	for _, n in ipairs(nodes) do if isTemporary(n.entity) then ids[n.entity] = true end end
	for _, o in ipairs(objects) do if isTemporary(o.resultEntity) then ids[o.resultEntity] = true end end
	return ids
end

-- Maps each id of `extraIds` that `baseIds` also defines to an unused negative id. `order` lists the renumbered ids.
local function collisions(baseIds : {integer : boolean}, extraIds : {integer : boolean}) : IdMap
	local lowest = 0
	local extraList : {integer} = {}
	for id in pairs(baseIds) do lowest = math.min(lowest, id) end
	for id in pairs(extraIds) do
		lowest = math.min(lowest, id)
		extraList[#extraList + 1] = id
	end
	table.sort(extraList, function(a : integer, b : integer) : boolean return a > b end)
	local map : IdMap = { ids = {}, order = {} }
	for _, id in ipairs(extraList) do
		if baseIds[id] then
			lowest = lowest - 1
			map.ids[id] = lowest
			map.order[#map.order + 1] = id
		end
	end
	return map
end

local function renumbered(map : IdMap, id : integer) : integer
	if id == nil then return nil end
	return map.ids[id] or id
end

local function renumberObjectPairs(map : IdMap, objects : {{Engine.Entity, EdgeObjectType}}) : {{Engine.Entity, EdgeObjectType}}
	local out : {{Engine.Entity, EdgeObjectType}} = {}
	for i, pair in ipairs(objects or {}) do out[i] = { renumbered(map, pair[1]), pair[2] } end
	return out
end

local function renumberSegments(map : IdMap, segments : {Proposal.SegmentAndEntity}) : {Proposal.SegmentAndEntity}
	for _, s in ipairs(segments) do
		s.entity = renumbered(map, s.entity)
		local comp = s.comp
		comp.node0 = renumbered(map, comp.node0)
		comp.node1 = renumbered(map, comp.node1)
		comp.objects = renumberObjectPairs(map, comp.objects)
		s.comp = comp
	end
	return segments
end

local function renumberNodes(map : IdMap, nodes : {Proposal.NodeAndEntity}) : {Proposal.NodeAndEntity}
	for _, n in ipairs(nodes) do n.entity = renumbered(map, n.entity) end
	return nodes
end

-- The segment that an edge object belongs to is a field of the engine that the type definition does not list.
local function renumberObjects(map : IdMap, objects : {Proposal.EdgeObject}) : {Proposal.EdgeObject}
	for _, o in ipairs(objects) do
		o.resultEntity = renumbered(map, o.resultEntity)
		local fields = o as {string : any}
		if fields["segmentEntity"] ~= nil then fields["segmentEntity"] = renumbered(map, fields["segmentEntity"] as integer) end
	end
	return objects
end

local function renumberList(map : IdMap, list : {integer}) : {integer}
	local out : {integer} = {}
	for i, id in ipairs(list or {}) do out[i] = renumbered(map, id) end
	return out
end

local function renumberConfigs(map : IdMap, configs : {Proposal.BaseNodeLaneConnectionAndEntity}) : {Proposal.BaseNodeLaneConnectionAndEntity}
	for _, c in ipairs(configs) do
		c.entity = renumbered(map, c.entity)
		local comp = c.comp
		local connections = comp.laneConnections
		for _, lc in ipairs(connections or {}) do
			lc.segment0 = renumbered(map, lc.segment0)
			lc.segment1 = renumbered(map, lc.segment1)
		end
		comp.laneConnections = connections
		comp.crosswalks = renumberList(map, comp.crosswalks)
		c.comp = comp
	end
	return configs
end

-- The entries of `extra` whose key is not yet in `base`, appended to a copy of `base`.
local function appendNew(base : {any}, extra : {any}, keyOf : function(any) : integer) : {any}
	local seen : {integer : boolean} = {}
	local out : {any} = {}
	for _, item in ipairs(base) do
		seen[keyOf(item)] = true
		out[#out + 1] = item
	end
	for _, item in ipairs(extra) do
		if not seen[keyOf(item)] then out[#out + 1] = item end
	end
	return out
end

local function appendAll(base : {any}, extra : {any}) : {any}
	local out : {any} = {}
	for _, item in ipairs(base) do out[#out + 1] = item end
	for _, item in ipairs(extra) do out[#out + 1] = item end
	return out
end

local function entityOf(item : any) : integer
	return (item as {string : integer}).entity
end

local function configNodes(configs : {Proposal.BaseNodeLaneConnectionAndEntity}) : {integer : boolean}
	local nodes : {integer : boolean} = {}
	for _, c in ipairs(configs) do nodes[c.entity] = true end
	return nodes
end

-- The lists of ids that a map of edge objects holds, with the extra map's ids renumbered and its entries added.
local function mergedObjectMap(base : {integer : {integer}}, extra : {integer : {integer}}, map : IdMap) : {integer : {integer}}
	local out : {integer : {integer}} = {}
	for key, list in pairs(base or {}) do out[key] = renumberList(map, list) end
	for key, list in pairs(extra or {}) do
		local target = renumbered(map, key)
		local joined = out[target] or {}
		for _, id in ipairs(renumberList(map, list)) do joined[#joined + 1] = id end
		out[target] = joined
	end
	return out
end

local function hasEntries(map : {integer : {integer}}) : boolean
	return map ~= nil and next(map) ~= nil
end

local function renumberedText(map : IdMap) : string
	if #map.order == 0 then return "renumbered none" end
	local parts : {string} = {}
	for i, id in ipairs(map.order) do parts[i] = string.format("%d -> %d", id, map.ids[id]) end
	return "renumbered [" .. table.concat(parts, ", ") .. "]"
end

local COUNT_LABELS <const> = { "added segments", "removed segments", "added nodes", "removed nodes", "edge objects", "node configs" }

-- The sizes of the six lists that are merged, in the order of COUNT_LABELS.
local function sizesOf(street : Proposal.StreetProposal) : {integer}
	return { #street.addedSegments, #street.removedSegments, #street.addedNodes, #street.removedNodes,
		#(street.edgeObjectsToAdd or {}), #(street.nodeConfigsToAdd or {}) }
end

local function countsText(before : {integer}, extra : {integer}, after : {integer}) : string
	local parts : {string} = {}
	for i, label in ipairs(COUNT_LABELS) do parts[i] = string.format("%s %d+%d=%d", label, before[i], extra[i], after[i]) end
	return table.concat(parts, ", ")
end

-- The existing nodes (not the new ones with a temporary id) that both lists hold a config for, in ascending order.
local function sharedNodes(base : {Proposal.BaseNodeLaneConnectionAndEntity}, extra : {Proposal.BaseNodeLaneConnectionAndEntity}) : {integer}
	local taken = configNodes(base)
	local shared : {integer} = {}
	for _, c in ipairs(extra) do
		if not isTemporary(c.entity) and taken[c.entity] then shared[#shared + 1] = c.entity end
	end
	table.sort(shared)
	return shared
end

local function isIn(ids : {integer}, id : integer) : boolean
	for _, other in ipairs(ids) do
		if other == id then return true end
	end
	return false
end

-- The configs without those of the nodes in `skip`.
local function configsWithout(configs : {Proposal.BaseNodeLaneConnectionAndEntity}, skip : {integer}) : {Proposal.BaseNodeLaneConnectionAndEntity}
	local out : {Proposal.BaseNodeLaneConnectionAndEntity} = {}
	for _, c in ipairs(configs) do
		if not isIn(skip, c.entity) then out[#out + 1] = c end
	end
	return out
end

-- The configs of a shared node name segments of both proposals, and a config that names a segment which the merged proposal
-- removes crashes the game. The shared node therefore keeps ONE entry (the one of `configs`, the base) with new empty lane
-- connections and crosswalks: the game makes the routes, and a follow-up command adds the crosswalks.
local function resetConfigs(configs : {Proposal.BaseNodeLaneConnectionAndEntity}, shared : {integer}) : {Proposal.BaseNodeLaneConnectionAndEntity}
	for _, c in ipairs(configs) do
		if isIn(shared, c.entity) then
			local comp = c.comp
			comp.laneConnections = {}
			comp.crosswalks = {}
			c.comp = comp
		end
	end
	return configs
end

local function mergeAdded(into : Proposal.StreetProposal, from : Proposal.StreetProposal, map : IdMap)
	into.addedSegments = appendAll(into.addedSegments, renumberSegments(map, from.addedSegments)) as {Proposal.SegmentAndEntity}
	into.addedNodes = appendAll(into.addedNodes, renumberNodes(map, from.addedNodes)) as {Proposal.NodeAndEntity}
	into.edgeObjectsToAdd = appendAll(into.edgeObjectsToAdd or {}, renumberObjects(map, from.edgeObjectsToAdd or {})) as {Proposal.EdgeObject}
end

local function mergeRemoved(into : Proposal.StreetProposal, from : Proposal.StreetProposal)
	into.removedSegments = appendNew(into.removedSegments, from.removedSegments, entityOf) as {Proposal.SegmentAndEntity}
	into.removedNodes = appendNew(into.removedNodes, from.removedNodes, entityOf) as {Proposal.NodeAndEntity}
end

-- A list or map that `from` does not have is not assigned, so that `into` keeps what it has. Returns the nodes whose config was reset.
local function mergeConfigsAndMaps(into : Proposal.StreetProposal, from : Proposal.StreetProposal, map : IdMap) : {integer}
	local configs = from.nodeConfigsToAdd or {}
	local shared : {integer} = {}
	if #configs > 0 then
		shared = sharedNodes(into.nodeConfigsToAdd or {}, configs)
		local kept = resetConfigs(into.nodeConfigsToAdd or {}, shared)
		into.nodeConfigsToAdd = appendAll(kept, renumberConfigs(map, configsWithout(configs, shared))) as {Proposal.BaseNodeLaneConnectionAndEntity}
	end
	local removing = from.nodeConfigsToRemove or {}
	if #removing > 0 then
		into.nodeConfigsToRemove = appendNew(into.nodeConfigsToRemove or {}, removing, function(id : any) : integer return id as integer end) as {Engine.Entity}
	end
	if hasEntries(from.new2oldEdgeObjects) then into.new2oldEdgeObjects = mergedObjectMap(into.new2oldEdgeObjects, from.new2oldEdgeObjects, map) end
	if hasEntries(from.old2newEdgeObjects) then into.old2newEdgeObjects = mergedObjectMap(into.old2newEdgeObjects, from.old2newEdgeObjects, map) end
	return shared
end

local function resetText(shared : {integer}) : string
	local parts : {string} = {}
	for i, node in ipairs(shared) do
		parts[i] = string.format("node config of node %d reset to the default routes; crosswalks are added by a follow-up command", node)
	end
	return table.concat(parts, ", ")
end

function pairSpike.merge(base : Proposal, extra : Proposal) : string, {integer}
	local into, from = base.proposal, extra.proposal
	if into == nil or from == nil then error("a proposal has no street data", 0) end
	local before, added = sizesOf(into), sizesOf(from)
	local map = collisions(definedIds(into.addedSegments, into.addedNodes, into.edgeObjectsToAdd or {}),
		definedIds(from.addedSegments, from.addedNodes, from.edgeObjectsToAdd or {}))
	mergeAdded(into, from, map)
	mergeRemoved(into, from)
	local shared = mergeConfigsAndMaps(into, from, map)
	base.proposal = into
	local text = countsText(before, added, sizesOf(into)) .. ", " .. renumberedText(map)
	return #shared > 0 and (text .. ", " .. resetText(shared)) or text, shared
end

return pairSpike
