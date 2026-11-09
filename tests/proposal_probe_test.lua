-- Tests of proposal_probe.tl: the option gate, the tags, the caps, the per-road probe and the hook of the base game tools.

local support = dofile((arg[0]:match("^(.*)[/\\][^/\\]*$") or ".") .. "/support.lua")
local check, contains = support.check, support.contains

local calls, logged = {}, {}
local optionValue = 1
local logThrows = false

local function lane(forward, modes)
  local transportModes = {}
  for _, m in ipairs(modes) do transportModes[m] = true end
  return { forward = forward, transportModes = transportModes }
end

local STREET, TRACK = {}, {}
local streetEdges = { [1] = true, [2] = true, [3] = true }
local oldRoad = {
  roadTemplate = "town_medium", type = 0, typeIndex = 0, roadDevelopmentLocked = true, roadType = STREET, distance = 10,
  edgeDecorations = { { 5, false }, { 5, true } },
  laneConfigs = { lane(false, { 0, 1 }), lane(true, { 2, 3, 4, 5 }) },
  position0 = { x = 0, y = 0, z = 0 }, position1 = { x = 10, y = 0, z = 0 },
}
local newRoad = {
  roadTemplate = "town_medium", type = 0, typeIndex = 0, roadDevelopmentLocked = false, roadType = STREET,
  edgeDecorations = {}, laneConfigs = { lane(true, { 2, 3 }) },
  position0 = { x = 0, y = 0.4, z = 0 }, position1 = { x = 10, y = 0, z = 0.2 },
}
local otherRoad = { roadTemplate = "other", type = 0, typeIndex = 0, edgeDecorations = {}, laneConfigs = {}, roadType = STREET,
  position0 = { x = 50, y = 0, z = 0 }, position1 = { x = 60, y = 0, z = 0 } }
local track = { roadTemplate = "standard", type = 0, typeIndex = 0, roadDevelopmentLocked = false, roadType = TRACK, distance = 30,
  edgeDecorations = {}, laneConfigs = {}, position0 = { x = 0, y = 0, z = 0 }, position1 = { x = 30, y = 0, z = 0 } }
local comps = { [1] = oldRoad, [2] = newRoad, [3] = otherRoad, [4] = track }
local found = { 1, 2, 3 }
local constructions = {}
local foundConstructions = {}
local octreeThrows, constructionReadThrows = false, false

support.installRequire({ bb_brush = { EDGE_MARGIN = 100 } })
_G.log = { message = function(m) if logThrows then error("log broke") end logged[#logged + 1] = m end }
_G.api = {
  type = {
    enum = { RoadType = { STREET = STREET, TRACK = TRACK } },
    ComponentType = { BASE_EDGE = "BASE_EDGE", BASE_EDGE_STREET = "BASE_EDGE_STREET", PLAYER_OWNED = "PLAYER_OWNED", CONSTRUCTION = "CONSTRUCTION" },
    Vec2f = { new = function(x, y) return { x = x, y = y } end },
  },
  engine = {
    config = { getModParams = function() calls.params = (calls.params or 0) + 1; return { kacsa_road_upgrade_brush = { rub_log = optionValue } } end },
    getComponent = function(e, componentType)
      calls.getComponent = (calls.getComponent or 0) + 1
      if componentType == "BASE_EDGE_STREET" then return streetEdges[e] and {} or nil end
      if componentType == "PLAYER_OWNED" then return e ~= 3 and { player = 5 } or nil end
      if componentType == "CONSTRUCTION" then
        if constructionReadThrows then error("construction read refused", 0) end
        return constructions[e]
      end
      return comps[e]
    end,
    system = {
      parcelSystem = {
        getParcelData = function() calls.parcels = (calls.parcels or 0) + 1; return { leftEntities = { 11, 12 }, rightParcels = {} } end,
        getSegment2ParcelData = function() calls.parcels = (calls.parcels or 0) + 1; return {} end,
      },
    },
    util = { octree = { findEntitiesInCircle = function(center, radius, componentType)
      calls.octree = (calls.octree or 0) + 1
      if componentType == "CONSTRUCTION" then
        if octreeThrows then error("octree refused", 0) end
        calls.constructionQueries = (calls.constructionQueries or 0) + 1
        calls.constructionCenter, calls.constructionRadius = center, radius
        return foundConstructions
      end
      calls.radius = radius
      return found
    end } },
  },
}

local probe = dofile(support.buildDir .. "/proposal_probe.lua")
local proposal = { proposal = { addedSegments = { { comp = {
  roadTemplate = "town_medium", type = 0, typeIndex = 0, roadDevelopmentLocked = true,
  edgeDecorations = {}, laneConfigs = { lane(true, { 2, 3 }) } } } } } }

local function reset() calls = {}; logged = {} end

-- The option is Off
optionValue = 1
probe.beginPress()
check("off: enabled is false", probe.enabled() == false)
check("off: tag returns the text unchanged", probe.tag("upgrade", "edge 1") == "edge 1")
reset()
local offOriginal = function() return {} end
local offParams = { getProposalStringsFn = offOriginal }
local offStateRead = false
local offHandle = probe.press({ 1, 4 })
offHandle.road(1, 0)
offHandle.proposal(1, proposal, 0)
offHandle.after(1, function() offStateRead = true; return "speed 0" end)
probe.install(offParams, "ACTION_TEST")
check("off: no game read", next(calls) == nil, calls.getComponent)
check("off: the state function is never run", offStateRead == false)
check("off: nothing logged", #logged == 0)
check("off: install left the function of the tool as it was", offParams.getProposalStringsFn == offOriginal)
reset()
foundConstructions = { 101 }
constructions[101] = { townBuildings = { 1001 }, stations = {}, depots = {}, industries = {} }
local offHouses, offHouseText = probe.lotHouses(1)
local offHouseCalls = calls
check("off: lotHouses returns the lot houses and the text, as with the option On",
  #offHouses == 1 and offHouses[1] == 101 and offHouseText == "1 lot houses within 30 m of the road: [101]", offHouseText)
check("off: lotHouses reads the road, the octree and the constructions but not the option and no parcel",
  offHouseCalls.params == nil and offHouseCalls.parcels == nil and offHouseCalls.constructionQueries == 1 and offHouseCalls.getComponent == 2,
  tostring(offHouseCalls.params) .. "/" .. tostring(offHouseCalls.getComponent))
check("off: lotHouses logs nothing", #logged == 0)
foundConstructions, constructions = {}, {}

-- The option is On: the press reads the roads, the handle writes the lines
optionValue = 2
probe.beginPress()
check("on: enabled is true", probe.enabled() == true)
check("on: tag adds the category", probe.tag("failure", "edge 1") == "[failure] edge 1")
reset()
local handle = probe.press({ 1, 4 })
check("on: the press reads each road and its owner once", calls.getComponent == 4, calls.getComponent)
check("on: the press writes nothing and never reads parcels", #logged == 0 and calls.parcels == nil)
reset()
handle.proposal(1, proposal, 3)
check("on: one line before the command", #logged == 1)
check("on: the line says when the road was read", contains(logged[1], "old road read at press start, 3 commands sent since"))
check("on: the line has lock, decorations and lanes of the old road",
  contains(logged[1], "locked true") and contains(logged[1], "decorations [5:false 5:true]") and contains(logged[1], "lanes [<0+1 >2+3+4+5]"))
check("on: the line has no parcels", not contains(logged[1], "parcel"))
check("on: the line shows the owner of the old road", contains(logged[1], "owner 5"))
check("on: the line has the added segment", contains(logged[1], "added segment (1 in the proposal)") and contains(logged[1], "lanes [>2+3]"))

reset()
comps[1] = nil
handle.after(1, function() return "speed 0, updates 5" end)
comps[1] = oldRoad
check("on: after finds the new road by its end points",
  #logged == 1 and contains(logged[1], "1 roads at the end points") and contains(logged[1], "edge 2:") and not contains(logged[1], "edge 3:"))
check("on: after appends the simulation state", contains(logged[1], "speed 0, updates 5"))
check("on: the query radius is the road length plus 1 m", calls.radius == 11)
reset()
found = { 3 }
handle.after(1, function() return "speed 0" end)
check("on: a miss reads as not found, not as removed", #logged == 1 and contains(logged[1], "no road found") and contains(logged[1], "not proof"))
found = { 1, 2, 3 }

reset()
handle.proposal(1, nil, 0)
check("on: no proposal gives a line and no error", #logged == 1 and contains(logged[1], "no proposal was built"))

reset()
handle.proposal(4, nil, 0)
check("on: a track gets a watch", #logged == 1 and contains(logged[1], "edge 4 attempt 0 before"))

-- Read errors never reach the caller
comps[1] = nil
reset()
local missingHandle = probe.press({ 1 })
missingHandle.proposal(1, proposal, 0)
check("on: a missing road gives one line and no watch", #logged == 1 and contains(logged[1], "no road component"))
comps[1] = oldRoad
reset()
handle.proposal(1, { proposal = {} }, 0)
check("on: a broken proposal gives a line and no error", #logged == 1 and contains(logged[1], "unreadable"))
logThrows = true
local survived = pcall(function() handle.proposal(1, proposal, 0); handle.after(1, function() return "s" end) end)
logThrows = false
check("a failing log write does not throw out of the probe", survived)

-- The handle of a press
reset()
handle.road(1, 2)
handle.proposal(1, proposal, 3)
check("press: road sets the attempt that proposal names", #logged == 1 and contains(logged[1], "edge 1 attempt 2 before"))
reset()
handle.after(1, function() return "speed 0" end)
check("press: after logs the road found and appends the state", #logged == 1 and contains(logged[1], "edge 1 attempt 2 after") and contains(logged[1], "speed 0"))
reset()
local unwatchedStateRead = false
handle.road(9, 1)
handle.proposal(9, proposal, 0)
handle.after(9, function() unwatchedStateRead = true; return "x" end)
check("press: an edge without a watch gets no read and no line", next(calls) == nil and #logged == 0)
check("press: the state of an edge without a watch is never read", unwatchedStateRead == false)
reset()
local stateSurvived = pcall(handle.after, 1, function() error("state broke") end)
check("press: an error in the state function does not reach the caller", stateSurvived and #logged == 0)

-- The hook of the base game tools
reset()
local hookParams = { getProposalStringsFn = function() return { "original" } end }
probe.install(hookParams, "ACTION_BUS_LANE_TOOL")
check("hook: one install line that names the tool", #logged == 1 and contains(logged[1], "hooked the action params of ACTION_BUS_LANE_TOOL"))
local result = hookParams.getProposalStringsFn({
  proposal = { removedSegments = {}, addedSegments = {}, addedNodes = {}, removedNodes = {}, edgeObjectsToAdd = {} },
  toRemove = {}, toAdd = {},
}, nil)
check("hook: the original result is returned", result[1] == "original")
check("hook: the proposal line names the tool", contains(logged[#logged], "ACTION_BUS_LANE_TOOL:"))
check("hook: the proposal line has no chain text", not contains(logged[#logged], "chain:"), logged[#logged])
reset()
local bareParams = {}
probe.install(bareParams, "ACTION_TRAM_TRACK_TOOL")
check("hook: a tool without getProposalStringsFn stays unchanged and logs one line",
  bareParams.getProposalStringsFn == nil and #logged == 1 and contains(logged[1], "ACTION_TRAM_TRACK_TOOL") and contains(logged[1], "no getProposalStringsFn"))
reset()
probe.install({}, "ACTION_TRAM_TRACK_TOOL")
probe.install({}, "ACTION_TRAM_TRACK_TOOL")
check("hook: the missing-function line comes once per tool", #logged == 0)
probe.install({}, "ACTION_STREET_BUILDER_UPGRADER")
check("hook: another tool gets its own missing-function line", #logged == 1 and contains(logged[1], "ACTION_STREET_BUILDER_UPGRADER"))

reset()
local sameParams = { getProposalStringsFn = function() return { "original" } end }
probe.install(sameParams, "ACTION_BUS_LANE_TOOL")
local wrapped = sameParams.getProposalStringsFn
probe.install(sameParams, "ACTION_BUS_LANE_TOOL")
check("hook: params that carry the hook are not wrapped again", #logged == 1 and sameParams.getProposalStringsFn == wrapped)

reset()
for _ = 1, 8 do probe.install({ getProposalStringsFn = function() return {} end }, "ACTION_TEST_A") end
local hookLinesA = #logged
probe.install({ getProposalStringsFn = function() return {} end }, "ACTION_TEST_B")
check("hook: at most five install lines per tool", hookLinesA == 5)
check("hook: the install lines of one tool do not use up those of another", #logged == hookLinesA + 1 and contains(logged[#logged], "ACTION_TEST_B"))

-- The read cap of the hook: describe runs at most 200 times per session, whether or not a call gives a new line
reset()
local capParams = { getProposalStringsFn = function() return { "original" } end }
probe.install(capParams, "ACTION_CAP_TEST")
local capProposal = {
  proposal = { removedSegments = {}, addedSegments = {}, addedNodes = {}, removedNodes = {}, edgeObjectsToAdd = {} },
  toRemove = {}, toAdd = {},
}
local realClock = os.clock
local fakeNow = 1000
os.clock = function() return fakeNow end
for _ = 1, 250 do
  fakeNow = fakeNow + 2
  capParams.getProposalStringsFn(capProposal, nil)
end
capProposal.toRemove = { 5 }
fakeNow = fakeNow + 2
local readsAtCap = calls.getComponent or 0
capParams.getProposalStringsFn(capProposal, nil)
check("hook cap: no component read after the cap", (calls.getComponent or 0) == readsAtCap, calls.getComponent)
os.clock = realClock
local capNotices = 0
for _, m in ipairs(logged) do if contains(m, "hook read cap of 200") then capNotices = capNotices + 1 end end
check("hook cap: the original result still comes back after the cap", capParams.getProposalStringsFn(capProposal, nil)[1] == "original")
check("hook cap: one notice when the cap is reached", capNotices == 1, capNotices)

-- The lot houses around a road, with the option On
local function house(id) constructions[id] = { townBuildings = { id + 5000 }, stations = {}, depots = {}, industries = {} } end
local function ids(list) return table.concat(list, ", ") end
constructions = {
  [101] = { townBuildings = { 1 }, stations = {}, depots = {}, industries = {} },
  [102] = { townBuildings = { 2 }, stations = {}, depots = {}, industries = {} },
  [103] = { townBuildings = {}, stations = { 9 }, depots = {}, industries = {} },
  [104] = { townBuildings = { 1, 2 }, stations = {}, depots = {}, industries = {} },
  [105] = { townBuildings = { 1 }, stations = {}, depots = { 7 }, industries = {} },
  [106] = { townBuildings = { 1 }, stations = {}, depots = {}, industries = { 8 } },
  [107] = { townBuildings = {}, stations = {}, depots = {}, industries = {} },
  [108] = { townBuildings = { 3 } },
}
foundConstructions = { 101, 103, 104, 105, 106, 107, 108, 109, 102 }
reset()
local houses, houseText = probe.lotHouses(1)
check("lot houses: only constructions with exactly one town building and nothing else are kept, in the order found",
  ids(houses) == "101, 108, 102", ids(houses))
check("lot houses: the text names the count, the reach and the ids",
  houseText == "3 lot houses within 30 m of the road: [101, 108, 102]", houseText)
check("lot houses: one query of the constructions, centred between the end points",
  calls.constructionQueries == 1 and calls.constructionCenter.x == 5 and calls.constructionCenter.y == 0)
check("lot houses: the radius is half the road length plus 30 m", calls.constructionRadius == 35, calls.constructionRadius)
check("lot houses: nothing is logged and no parcel is read", #logged == 0 and calls.parcels == nil)

reset()
local noDistanceHouses = probe.lotHouses(2)
check("lot houses: a road without a length uses the distance of its end points",
  #noDistanceHouses == 3 and math.abs(calls.constructionRadius - (math.sqrt(100.2) / 2 + 30)) < 1e-9, calls.constructionRadius)
check("lot houses: the centre of such a road is the middle of its end points",
  calls.constructionCenter.x == 5 and math.abs(calls.constructionCenter.y - 0.2) < 1e-9)

reset()
foundConstructions = {}
local noHouses, noHouseText = probe.lotHouses(1)
check("lot houses: no construction near the road gives an empty list and a text with count 0",
  #noHouses == 0 and noHouseText == "0 lot houses within 30 m of the road: []", noHouseText)

foundConstructions = {}
for id = 200, 223 do house(id); foundConstructions[#foundConstructions + 1] = id end
reset()
local atCapHouses = probe.lotHouses(1)
check("lot houses: exactly 24 qualifying constructions are all returned", #atCapHouses == 24 and atCapHouses[1] == 200 and atCapHouses[24] == 223, #atCapHouses)
house(224); foundConstructions[#foundConstructions + 1] = 224
for id = 225, 229 do house(id); foundConstructions[#foundConstructions + 1] = id end
reset()
local cappedHouses, cappedText = probe.lotHouses(1)
check("lot houses: more than 24 qualifying constructions give an empty list, never a partial one", #cappedHouses == 0, #cappedHouses)
check("lot houses: the text names the count found, the cap, and that none were put in toRemove",
  cappedText == "30 lot houses found within 30 m of the road, more than the cap of 24, none put in toRemove", cappedText)

foundConstructions = { 101, 102 }
reset()
octreeThrows = true
local octreeHouses, octreeText = probe.lotHouses(1)
octreeThrows = false
check("lot houses: a failing octree query gives an empty list and a text that says the read failed",
  #octreeHouses == 0 and contains(octreeText, "read failed"), octreeText)
reset()
constructionReadThrows = true
local constructionHouses, constructionText = probe.lotHouses(1)
constructionReadThrows = false
check("lot houses: a failing construction read gives an empty list and a text that says the read failed",
  #constructionHouses == 0 and contains(constructionText, "read failed"), constructionText)
reset()
local missingHouses, missingText = probe.lotHouses(99)
check("lot houses: a road without a component gives an empty list, a text that says the read failed, and no query",
  #missingHouses == 0 and contains(missingText, "read failed") and calls.constructionQueries == nil, missingText)
check("lot houses: the probe never calls a function of the parcel system", calls.parcels == nil)

foundConstructions = { 101, 103, 104, 105, 106, 107, 108, 109, 102 }
constructions[109] = nil
optionValue = 1
probe.beginPress()
reset()
local offList, offListText = probe.lotHouses(1)
check("lot houses: with the option Off the list and the text equal those with the option On",
  ids(offList) == "101, 108, 102" and offListText == "3 lot houses within 30 m of the road: [101, 108, 102]", offListText)
check("lot houses: with the option Off the query, the centre and the radius equal those with the option On",
  calls.constructionQueries == 1 and calls.constructionCenter.x == 5 and calls.constructionCenter.y == 0 and calls.constructionRadius == 35)
reset()
foundConstructions = { 101, 102 }
octreeThrows = true
local offOctreeHouses, offOctreeText = probe.lotHouses(1)
octreeThrows = false
check("lot houses: with the option Off a failing read gives an empty list and a text that says the read failed",
  #offOctreeHouses == 0 and contains(offOctreeText, "read failed") and #logged == 0, offOctreeText)
optionValue = 2
probe.beginPress()

-- The caps
probe.beginPress()
reset()
for i = 1, 805 do handle.proposal(1, nil, i) end
check("cap: 800 lines in a press plus one notice", #logged == 801 and contains(logged[801], "press cap of 800"))
probe.beginPress()
reset()
handle.proposal(1, nil, 0)
check("cap: a new press logs again", #logged == 1 and contains(logged[1], "edge 1"))
reset()
for _ = 1, 6 do probe.beginPress(); for _ = 1, 800 do handle.proposal(1, nil, 0) end end
local notices = 0
for _, m in ipairs(logged) do if contains(m, "session cap of 4000") then notices = notices + 1 end end
check("cap: the session notice appears once", notices == 1)

support.finish("proposal_probe")
