-- Tests of pair_spike.tl: the neighbour of a road through a shared node, and the merge of the street data of two proposals.
-- The proposals of the stub hand out copies of their data, as the game may do: an edit that is not assigned back is lost.

local support = dofile((arg[0]:match("^(.*)[/\\][^/\\]*$") or ".") .. "/support.lua")
local check, contains = support.check, support.contains

local edges, readThrowsFor, reads = {}, {}, 0
support.installRequire({})
_G.api = {
  type = { ComponentType = { BASE_EDGE = "BASE_EDGE" } },
  engine = {
    getComponent = function(e, componentType)
      reads = reads + 1
      if readThrowsFor[e] then error("read refused", 0) end
      return componentType == "BASE_EDGE" and edges[e] or nil
    end,
  },
}
local pair = dofile(support.buildDir .. "/pair_spike.lua")

-- Finding the neighbours
local function list(ids) return table.concat(ids, ",") end
edges = { [1] = { node0 = 10, node1 = 11 }, [2] = { node0 = 11, node1 = 12 }, [3] = { node0 = 20, node1 = 21 }, [4] = { node0 = 12, node1 = 13 },
  [5] = { node0 = 30, node1 = 10 }, [6] = {}, [7] = { node0 = 10, node1 = 41 }, [8] = { node0 = 10, node1 = 42 }, [9] = { node0 = 10, node1 = 43 },
  [10] = { node0 = 10, node1 = 44 } }
check("partners: every road of the list that shares a node, in the order of the list, the road itself is skipped", list(pair.partners(1, { 1, 3, 2, 4, 5 })) == "2,5")
check("partners: the order of the list decides", list(pair.partners(2, { 4, 1 })) == "4,1")
check("partners: no road shares a node", #pair.partners(1, { 3, 4 }) == 0)
check("partners: at most three roads are returned, the first ones", list(pair.partners(1, { 7, 8, 9, 10, 2, 5 })) == "7,8,9")
check("partners: an empty list gives an empty list and reads nothing", (function() reads = 0; return #pair.partners(1, {}) == 0 and reads == 0 end)())
readThrowsFor[2] = true
check("partners: an unreadable road of the list is skipped", list(pair.partners(1, { 2, 3, 5 })) == "5")
check("partners: an unreadable road alone gives an empty list", #pair.partners(1, { 2 }) == 0)
readThrowsFor[2] = nil
readThrowsFor[1] = true
check("partners: an unreadable road gives an empty list", #pair.partners(1, { 2 }) == 0)
readThrowsFor[1] = nil
check("partners: a road without node ids gives an empty list, and so does a candidate without them", #pair.partners(6, { 1 }) == 0 and #pair.partners(1, { 6 }) == 0)
check("partners: a road that is gone gives an empty list", #pair.partners(99, { 1 }) == 0)

-- The proposals: every read gives a copy, every write stores a copy
local function deep(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deep(x) end
  return out
end
local registry = setmetatable({}, { __mode = "k" })
local function streetView(data)
  local copy = deep(data)
  local view = setmetatable({}, {
    __index = function(_, k) return deep(copy[k]) end,
    __newindex = function(_, k, v) copy[k] = deep(v) end,
  })
  registry[view] = copy
  return view
end
local function proposalOf(streetData)
  local stored = deep(streetData)
  local proposal = setmetatable({}, {
    __index = function(_, k) if k == "proposal" then return streetView(stored) end end,
    __newindex = function(_, k, v) if k == "proposal" then stored = deep(registry[v] or v) end end,
  })
  return proposal, function() return stored end
end

local function ids(list, field)
  local out = {}
  for i, item in ipairs(list or {}) do out[i] = tostring(item[field or "entity"]) end
  return table.concat(out, ",")
end

local function baseStreet()
  return {
    addedSegments = { { entity = -1, comp = { node0 = 10, node1 = 11, objects = {} } } },
    removedSegments = { { entity = 1 } },
    addedNodes = { { entity = -2, comp = { position = { x = 0, y = 0, z = 0 } } } },
    removedNodes = { { entity = 9 } },
    edgeObjectsToAdd = {},
  }
end
local function extraStreet()
  return {
    addedSegments = { { entity = -1, comp = { node0 = 11, node1 = -2, objects = { { -3, 2 } } } } },
    removedSegments = { { entity = 2 } },
    addedNodes = { { entity = -2, comp = { position = { x = 5, y = 5, z = 0 } } } },
    removedNodes = { { entity = 9 }, { entity = 8 } },
    edgeObjectsToAdd = { { resultEntity = -3, segmentEntity = -1 } },
    new2oldEdgeObjects = { [-3] = { 77 } },
    old2newEdgeObjects = { [77] = { -3 } },
    nodeConfigsToAdd = { { entity = -2, comp = { laneConnections = { { segment0 = -1, lane0 = 0, segment1 = 5, lane1 = 0 } }, crosswalks = { -1 } } } },
    nodeConfigsToRemove = { 11 },
  }
end

local base, baseData = proposalOf(baseStreet())
local extra = proposalOf(extraStreet())
local text = pair.merge(base, extra)
local merged = baseData()
check("merge: the added segments are appended and assigned back", ids(merged.addedSegments) == "-1,-4", ids(merged.addedSegments))
check("merge: the removed segments are appended", ids(merged.removedSegments) == "1,2", ids(merged.removedSegments))
check("merge: the added nodes are appended", ids(merged.addedNodes) == "-2,-5", ids(merged.addedNodes))
check("merge: a removed node that both proposals name is listed once", ids(merged.removedNodes) == "9,8", ids(merged.removedNodes))
check("merge: a colliding id of a segment is renumbered to an unused negative id", merged.addedSegments[2].entity == -4)
check("merge: a node id that an added segment refers to follows the renumbering", merged.addedSegments[2].comp.node1 == -5 and merged.addedSegments[2].comp.node0 == 11)
check("merge: an id in the objects of an added segment that does not collide stays", merged.addedSegments[2].comp.objects[1][1] == -3)
check("merge: the edge objects follow the renumbering of their segment", ids(merged.edgeObjectsToAdd, "resultEntity") == "-3" and merged.edgeObjectsToAdd[1].segmentEntity == -4)
check("merge: the maps of the edge objects are merged", merged.new2oldEdgeObjects[-3][1] == 77 and merged.old2newEdgeObjects[77][1] == -3)
local config = merged.nodeConfigsToAdd[1]
check("merge: a node config follows the renumbering of its node, its lane connections and its crosswalks",
  config ~= nil and config.entity == -5 and config.comp.laneConnections[1].segment0 == -4 and config.comp.laneConnections[1].segment1 == 5
  and config.comp.crosswalks[1] == -4)
check("merge: the node configs to remove are appended", merged.nodeConfigsToRemove[1] == 11)
check("merge: the text names the counts before and after", contains(text, "added segments 1+1=2") and contains(text, "removed segments 1+1=2")
  and contains(text, "added nodes 1+1=2") and contains(text, "removed nodes 1+2=2") and contains(text, "edge objects 0+1=1"), text)
check("merge: the text names the renumbered ids", contains(text, "renumbered [-1 -> -4, -2 -> -5]"), text)
check("merge: the extra proposal is not changed", ids(extra.proposal.addedSegments) == "-1")

local free, freeData = proposalOf(baseStreet())
local other = extraStreet()
other.addedSegments[1].entity = -7
other.addedSegments[1].comp.node1 = -8
other.addedNodes[1].entity = -8
other.edgeObjectsToAdd[1] = { resultEntity = -9, segmentEntity = -7 }
other.nodeConfigsToAdd = nil
other.new2oldEdgeObjects = nil
other.old2newEdgeObjects = nil
local freeText = pair.merge(free, proposalOf(other))
check("merge: ids that do not collide stay as they are", ids(freeData().addedSegments) == "-1,-7" and ids(freeData().addedNodes) == "-2,-8", ids(freeData().addedSegments))
check("merge: without a collision the text says so", contains(freeText, "renumbered none"), freeText)

local plain, plainData = proposalOf({ addedSegments = {}, removedSegments = { { entity = 1 } }, addedNodes = {}, removedNodes = {} })
local plainText = pair.merge(plain, proposalOf({ addedSegments = {}, removedSegments = { { entity = 2 } }, addedNodes = {}, removedNodes = {} }))
check("merge: proposals without edge objects and node configs merge", ids(plainData().removedSegments) == "1,2" and contains(plainText, "edge objects 0+0=0"), plainText)

-- Malformed input is raised to the caller
check("merge: an extra proposal without street data raises an error", pcall(pair.merge, proposalOf(baseStreet()), setmetatable({}, { __index = function() return nil end })) == false)
local broken = extraStreet()
broken.addedSegments[1].comp = nil
check("merge: an added segment without data raises an error", pcall(pair.merge, proposalOf(baseStreet()), proposalOf(broken)) == false)
-- Two adjacent roads share node 11, and both proposals hold a config for it: one entry remains, with empty lane connections and
-- empty crosswalks. A follow-up command adds the crosswalks.
local function lane(segment0, segment1) return { segment0 = segment0, lane0 = 0, segment1 = segment1, lane1 = 0 } end
local sharedBase = baseStreet()
sharedBase.nodeConfigsToAdd = {
  { entity = 11, comp = { laneConnections = { lane(1, 2) }, crosswalks = { 1, 30 } } },
  { entity = 12, comp = { laneConnections = { lane(3, -1) }, crosswalks = { 3 } } },
}
sharedBase.nodeConfigsToRemove = { 11, 7 }
local sharedExtra = extraStreet()
sharedExtra.nodeConfigsToAdd = {
  { entity = 11, comp = { laneConnections = { lane(2, 1) }, crosswalks = { 2, 33 } } },
  { entity = 13, comp = { laneConnections = { lane(-1, 4) }, crosswalks = { -1 } } },
}
sharedExtra.nodeConfigsToRemove = { 11, 8 }
local shared, sharedData = proposalOf(sharedBase)
local sharedText, sharedNodes = pair.merge(shared, proposalOf(sharedExtra))
local sharedConfigs = sharedData().nodeConfigsToAdd
local byNode = {}
for _, c in ipairs(sharedConfigs) do byNode[c.entity] = (byNode[c.entity] or 0) + 1 end
check("shared node config: one entry remains for the shared node, the other nodes keep theirs", #sharedConfigs == 3 and byNode[11] == 1 and byNode[12] == 1 and byNode[13] == 1, ids(sharedConfigs))
local resetConfig
for _, c in ipairs(sharedConfigs) do if c.entity == 11 then resetConfig = c end end
check("shared node config: its lane connections and its crosswalks are empty new lists and the reset is assigned back",
  resetConfig ~= nil and next(resetConfig.comp.laneConnections) == nil and next(resetConfig.comp.crosswalks) == nil)
check("shared node config: merge returns the ids of the nodes whose config was reset", type(sharedNodes) == "table" and #sharedNodes == 1 and sharedNodes[1] == 11)
local ownConfig
for _, c in ipairs(sharedConfigs) do if c.entity == 12 then ownConfig = c end end
check("shared node config: a config that only the base proposal holds is untouched", ownConfig ~= nil and ownConfig.comp.laneConnections[1].segment0 == 3
  and ownConfig.comp.laneConnections[1].segment1 == -1 and ownConfig.comp.crosswalks[1] == 3)
local extraConfig
for _, c in ipairs(sharedConfigs) do if c.entity == 13 then extraConfig = c end end
check("shared node config: a config that only the extra proposal holds is kept, its colliding ids renumbered",
  extraConfig ~= nil and extraConfig.comp.laneConnections[1].segment0 == -4 and extraConfig.comp.laneConnections[1].segment1 == 4 and extraConfig.comp.crosswalks[1] == -4,
  extraConfig and extraConfig.comp.laneConnections[1].segment0)
local removing = sharedData().nodeConfigsToRemove
check("shared node config: the configs to remove are merged without duplicates", #removing == 3 and removing[1] == 11 and removing[2] == 7 and removing[3] == 8,
  table.concat(removing, ","))
check("shared node config: the text names the node and says that the crosswalks are added by a follow-up command",
  contains(sharedText, "node config of node 11 reset to the default routes; crosswalks are added by a follow-up command") and contains(sharedText, "node configs 2+2=3"), sharedText)

local tempBase, tempData = baseStreet(), nil
tempBase.nodeConfigsToAdd = { { entity = -2, comp = { laneConnections = { lane(-1, 5) }, crosswalks = {} } } }
local tempExtra = extraStreet()
tempExtra.nodeConfigsToAdd = { { entity = -2, comp = { laneConnections = { lane(-1, 6) }, crosswalks = {} } } }
local temp
temp, tempData = proposalOf(tempBase)
local tempText = pair.merge(temp, proposalOf(tempExtra))
check("shared node config: two new nodes with the same temporary id are two nodes, not a shared one",
  #tempData().nodeConfigsToAdd == 2 and tempData().nodeConfigsToAdd[1].entity == -2 and tempData().nodeConfigsToAdd[2].entity == -5
  and #tempData().nodeConfigsToAdd[1].comp.laneConnections == 1 and not contains(tempText, "reset to the default routes"), tempText)

local noShared = proposalOf(baseStreet())
local noSharedText, noSharedNodes = pair.merge(noShared, proposalOf(extraStreet()))
check("shared node config: a merge without a shared node does not mention a reset and returns no node", not contains(noSharedText, "reset to the default routes") and #noSharedNodes == 0)

check("merge: a base proposal without street data raises an error", pcall(pair.merge, setmetatable({}, { __index = function() return nil end }), proposalOf(extraStreet())) == false)

support.finish("pair_spike")
