-- Tests of node_crosswalks.tl: the command that adds the crosswalks of a node, and the lookup of a node by its position.

local support = dofile((arg[0]:match("^(.*)[/\\][^/\\]*$") or ".") .. "/support.lua")
local check, contains = support.check, support.contains

local PERSON, CAR = 0, 2
local world = { configs = {}, streets = {}, edges = {}, templates = {}, positions = {}, readThrows = false, copyFails = false }

local function lanes(withPedestrians)
  local out = { { transportModes = { [CAR] = true } } }
  if withPedestrians then out[#out + 1] = { transportModes = { [PERSON] = true } } end
  return out
end

local function deep(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deep(x) end
  return out
end

-- An entry whose "comp" is a copy, and can be refused, as the game refuses a copy of a config
local function newEntry()
  local store = {}
  return setmetatable({}, {
    __index = function(_, k) return store[k] end,
    __newindex = function(_, k, v)
      if k == "comp" and world.copyFails then error("copy refused", 0) end
      store[k] = k == "comp" and deep(v) or v
    end,
  })
end

support.installRequire({})
_G.api = {
  type = {
    ComponentType = { BASE_EDGE = "BASE_EDGE", BASE_NODE = "BASE_NODE", BASE_NODE_CONFIG = "BASE_NODE_CONFIG" },
    enum = { TransportMode = { PERSON = PERSON } },
    Vec2f = { new = function(x, y) return { x = x, y = y } end },
    SimpleProposal = { new = function() return { streetProposal = {} } end },
    BaseNodeLaneConnectionAndEntity = { new = newEntry },
  },
  res = { streetTemplateRep = { find = function(name) return name end, get = function(name) return world.templates[name] end } },
  cmd = { makeWorldBuildProposalCmd = function(proposal, context, ignoreErrors, playerInitiated)
    return { proposal = proposal, context = context, ignoreErrors = ignoreErrors, playerInitiated = playerInitiated }
  end },
  engine = {
    getComponent = function(e, componentType)
      if world.readThrows then error("read refused", 0) end
      if componentType == "BASE_NODE_CONFIG" and world.configThrows then error("config refused", 0) end
      if componentType == "BASE_NODE_CONFIG" then return world.configs[e] end
      if componentType == "BASE_NODE" then return world.positions[e] and { position = world.positions[e] } or nil end
      return world.edges[e]
    end,
    system = { streetSystem = { getNodeStreetSegments = function(node) return world.streets[node] end } },
    util = { octree = { findEntitiesInCircle = function(center, radius)
      local found = {}
      for id, p in pairs(world.positions) do
        if (p.x - center.x) ^ 2 + (p.y - center.y) ^ 2 <= radius ^ 2 then found[#found + 1] = id end
      end
      table.sort(found)
      return found
    end } },
  },
}
local crosswalks = dofile(support.buildDir .. "/node_crosswalks.lua")

world.templates = { town = { country = false }, country = { country = true } }
local function street(template, withPedestrians) return { roadTemplate = template, laneConfigs = lanes(withPedestrians) } end
local function copy(list) local out = {}; for i, v in ipairs(list) do out[i] = v end; return out end
local function walks(cmd) return cmd.proposal.streetProposal.nodeConfigsToAdd[1].comp.crosswalks end
local function reset(overrides)
  world.readThrows, world.copyFails, world.configThrows = false, false, false
  world.edges = { [10] = street("town", true), [11] = street("town", true), [12] = street("country", true), [13] = street("town", false) }
  world.streets = { [5] = { 10, 11, 12 } }
  world.configs = { [5] = { crosswalks = { 10 }, laneConnections = { "kept" } } }
  world.positions = {}
  for key, value in pairs(overrides or {}) do world[key] = value end
end
local context = { player = 1 }

-- The command for a node
reset()
local cmd, detail = crosswalks.command(5, context, false)
check("command: a node with a town street gets a command", cmd ~= nil, detail)
check("command: it adds the missing crosswalk segments and keeps the existing ones in front", cmd ~= nil and table.concat(walks(cmd), ",") == "10,11,12", cmd and table.concat(walks(cmd), ","))
check("command: the detail says how many were added", detail == "2 added", detail)
check("command: it replaces the config of the node, as a player action without ignoring errors",
  cmd ~= nil and cmd.proposal.streetProposal.nodeConfigsToRemove[1] == 5 and cmd.proposal.streetProposal.nodeConfigsToAdd[1].entity == 5
  and cmd.context == context and cmd.ignoreErrors == false and cmd.playerInitiated == true)
check("command: the config entry keeps the lane connections of the copy", cmd ~= nil and cmd.proposal.streetProposal.nodeConfigsToAdd[1].comp.laneConnections[1] == "kept")

reset({ streets = { [5] = { 12 } } })
local countryCmd, countryReason = crosswalks.command(5, context, false)
check("command: only country roads give no command and the reason no_town_street", countryCmd == nil and countryReason == "no_town_street", countryReason)
reset({ streets = { [5] = { 13, 12 } } })
local noSidewalkCmd, noSidewalkReason = crosswalks.command(5, context, false)
check("command: a town road without a pedestrian lane is no town street", noSidewalkCmd == nil and noSidewalkReason == "no_town_street", noSidewalkReason)
reset()
world.configs[5] = nil
local noConfigCmd, noConfigReason = crosswalks.command(5, context, false)
check("command: a node without a config gives no command and the reason no_config", noConfigCmd == nil and noConfigReason == "no_config", noConfigReason)
reset()
world.configs[5].crosswalks = { 10, 11, 12 }
local unchangedCmd, unchangedReason = crosswalks.command(5, context, false)
check("command: nothing missing gives no command and the reason unchanged", unchangedCmd == nil and unchangedReason == "unchanged", unchangedReason)
reset({ copyFails = true })
local copyCmd, copyReason = crosswalks.command(5, context, false)
check("command: a refused copy gives no command and a reason that starts with config_copy_failed", copyCmd == nil and contains(copyReason, "config_copy_failed"), copyReason)
reset({ readThrows = true })
local readOk, readCmd, readReason = pcall(crosswalks.command, 5, context, false)
check("command: a failing read does not raise an error, it gives no command and a reason", readOk and readCmd == nil and contains(readReason, "read_failed"), readReason)
reset()
check("command: the config of the engine is not changed", (function() crosswalks.command(5, context, false); return #world.configs[5].crosswalks == 1 end)())
check("templateOf: gives the street template of a road", crosswalks.templateOf(10).country == false and crosswalks.templateOf(12).country == true)

-- The follow-up of a merged pair: a crosswalk on EVERY street segment of the node, with no filter
reset({ streets = { [5] = { 12, 14 } } })
world.edges[14] = street("country", true)
local allCmd, allDetail = crosswalks.command(5, context, true)
check("all streets: a node with only country streets gets a crosswalk on every one, the existing one stays in front",
  allCmd ~= nil and table.concat(walks(allCmd), ",") == "10,12,14" and allDetail == "2 added", allCmd and table.concat(walks(allCmd), ","))
local sameCmd2, sameReason2 = crosswalks.command(5, context, false)
check("all streets: the default mode still gives no_town_street for the same node", sameCmd2 == nil and sameReason2 == "no_town_street", sameReason2)
reset({ streets = { [5] = { 10, 11, 12, 13 } } })
local everyCmd = crosswalks.command(5, context, true)
check("all streets: a street without a pedestrian lane gets a crosswalk too", everyCmd ~= nil and table.concat(walks(everyCmd), ",") == "10,11,12,13", everyCmd and table.concat(walks(everyCmd), ","))
local defaultMixedCmd = crosswalks.command(5, context, false)
check("all streets: the default mode still adds every street of the junction when one is a town street", defaultMixedCmd ~= nil and table.concat(walks(defaultMixedCmd), ",") == "10,11,12,13")
reset({ streets = { [5] = { 13 } } })
local onlyNoPedCmd = crosswalks.command(5, context, true)
check("all streets: a node whose only street has no pedestrian lane still gets its crosswalk", onlyNoPedCmd ~= nil and table.concat(walks(onlyNoPedCmd), ",") == "10,13")
reset({ streets = { [5] = {} } })
local noStreetCmd, noStreetReason = crosswalks.command(5, context, true)
check("all streets: a node without any street segment gives no command and the reason no_street", noStreetCmd == nil and noStreetReason == "no_street", noStreetReason)
reset({ streets = { [5] = { 12 } } })
world.configs[5].crosswalks = { 10, 12 }
local allThereCmd, allThereReason = crosswalks.command(5, context, true)
check("all streets: nothing missing gives no command and the reason unchanged", allThereCmd == nil and allThereReason == "unchanged", allThereReason)
reset({ streets = { [5] = { 12 } } })
world.configs[5] = nil
local noConfigCmd2, noConfigReason2 = crosswalks.command(5, context, true)
check("all streets: a node without a config gives the reason no_config", noConfigCmd2 == nil and noConfigReason2 == "no_config", noConfigReason2)
reset({ copyFails = true, streets = { [5] = { 12 } } })
local copyCmd2, copyReason2 = crosswalks.command(5, context, true)
check("all streets: a refused copy gives config_copy_failed", copyCmd2 == nil and contains(copyReason2, "config_copy_failed"), copyReason2)

-- The fallback when the game refuses the all-streets command: only the streets with a pedestrian lane
reset({ streets = { [5] = { 10, 11, 12, 13 } } })
local sideCmd, sideDetail = crosswalks.commandSidewalk(5, context)
check("sidewalk streets: only the streets with a pedestrian lane are added, the existing one stays in front, country roads included",
  sideCmd ~= nil and table.concat(walks(sideCmd), ",") == "10,11,12" and sideDetail == "2 added", sideCmd and table.concat(walks(sideCmd), ","))
check("sidewalk streets: the command replaces the config of the node as a player action",
  sideCmd ~= nil and sideCmd.proposal.streetProposal.nodeConfigsToRemove[1] == 5 and sideCmd.proposal.streetProposal.nodeConfigsToAdd[1].entity == 5
  and sideCmd.context == context and sideCmd.ignoreErrors == false and sideCmd.playerInitiated == true)
reset({ streets = { [5] = { 13 } } })
local sideNoneCmd, sideNoneReason = crosswalks.commandSidewalk(5, context)
check("sidewalk streets: no street with a pedestrian lane gives no command and the reason no_pedestrian_street", sideNoneCmd == nil and sideNoneReason == "no_pedestrian_street", sideNoneReason)
reset({ streets = { [5] = { 10 } } })
local sideSameCmd, sideSameReason = crosswalks.commandSidewalk(5, context)
check("sidewalk streets: nothing missing gives no command and the reason unchanged", sideSameCmd == nil and sideSameReason == "unchanged", sideSameReason)
reset({ readThrows = true })
local sideOk, sideRead, sideReadReason = pcall(crosswalks.commandSidewalk, 5, context)
check("sidewalk streets: a failing read does not raise an error", sideOk and sideRead == nil and contains(sideReadReason, "read_failed"), sideReadReason)

-- The node by its position
reset({ positions = { [5] = { x = 100.04, y = 200.0, z = 3 } } })
local spot = crosswalks.remember(5)
check("remember: it keeps the id and the position of the node", spot ~= nil and spot.node == 5 and spot.x == 100.04 and spot.y == 200.0)
reset()
check("remember: a node that cannot be read gives nil", crosswalks.remember(5) == nil)
reset({ positions = { [5] = { x = 1, y = 2, z = 0 } } })
local sameSpot = { node = 5, x = 1, y = 2 }
local sameCmd, sameDetail, sameNode = crosswalks.commandAt(sameSpot, context, false)
check("commandAt: the old node is used while it exists at the same position", sameCmd ~= nil and sameNode == 5 and sameDetail == "2 added")
reset({ positions = { [77] = { x = 1.3, y = 2.0, z = 0 }, [78] = { x = 50, y = 50, z = 0 } }, streets = { [77] = { 10, 11 } },
  configs = { [77] = { crosswalks = {}, laneConnections = {} } } })
local movedCmd, movedDetail, movedNode = crosswalks.commandAt({ node = 5, x = 1, y = 2 }, context, false)
check("commandAt: a node that was replaced is found by its position", movedCmd ~= nil and movedNode == 77 and movedCmd.proposal.streetProposal.nodeConfigsToAdd[1].entity == 77
  and movedDetail == "2 added", tostring(movedNode))
reset({ positions = { [5] = { x = 90, y = 90, z = 0 }, [77] = { x = 1.5, y = 2, z = 0 } }, streets = { [77] = { 10 } }, configs = { [77] = { crosswalks = {}, laneConnections = {} } } })
local otherCmd, _, otherNode = crosswalks.commandAt({ node = 5, x = 1, y = 2 }, context, false)
check("commandAt: an old id at another position is not used, the node at the position is", otherCmd ~= nil and otherNode == 77, tostring(otherNode))
reset({ positions = { [78] = { x = 50, y = 50, z = 0 } } })
local lostCmd, lostReason, lostNode = crosswalks.commandAt({ node = 5, x = 1, y = 2 }, context, false)
check("commandAt: no node at the position gives no command, the reason node_not_found and the old id", lostCmd == nil and lostReason == "node_not_found" and lostNode == 5, tostring(lostReason))
reset({ positions = { [5] = { x = 1, y = 2, z = 0 } }, streets = { [5] = { 12 } } })
local skipCmd, skipReason, skipNode = crosswalks.commandAt({ node = 5, x = 1, y = 2 }, context, false)
check("commandAt: the reason of the command is passed on", skipCmd == nil and skipReason == "no_town_street" and skipNode == 5, tostring(skipReason))

reset({ positions = { [5] = { x = 1, y = 2, z = 0 } }, streets = { [5] = { 12 } } })
local passCmd, _, passNode = crosswalks.commandAt({ node = 5, x = 1, y = 2 }, context, true)
check("commandAt: the mode is passed on, a node with only country streets gets a command", passCmd ~= nil and passNode == 5 and table.concat(walks(passCmd), ",") == "10,12")
local passOffCmd, passOffReason = crosswalks.commandAt({ node = 5, x = 1, y = 2 }, context, false)
check("commandAt: the default mode gives no_town_street for the same node", passOffCmd == nil and passOffReason == "no_town_street", passOffReason)

-- The read back of a node, for the log
world.templates = { town = { country = false, defaultWithCrosswalk = true }, country = { country = true } }
reset({ positions = { [5] = { x = 1, y = 2, z = 0 } }, streets = { [5] = { 10, 11, 12 } } })
world.configs[5].crosswalks = { 10, 12 }
local readNode, readSummary, readItems = crosswalks.readBack({ node = 5, x = 1, y = 2 })
check("readBack: the node, the number and the ids of its crosswalks", readNode == 5 and readSummary == "2 crosswalks [10, 12]", readSummary)
check("readBack: one item per street with its template, the default of the template and whether it is in the list",
  #readItems == 3 and readItems[1] == "street 10 template town defaultWithCrosswalk true in list yes" and readItems[2] == "street 11 template town defaultWithCrosswalk true in list no"
  and readItems[3] == "street 12 template country defaultWithCrosswalk false in list yes", readItems[1])
local manyStreets = {}
for i = 1, 10 do manyStreets[i] = 20 + i; world.edges[20 + i] = street("town", true) end
world.streets[5] = manyStreets
check("readBack: at most 8 streets are listed", #select(3, crosswalks.readBack({ node = 5, x = 1, y = 2 })) == 8)
reset({ positions = { [77] = { x = 1.2, y = 2, z = 0 } }, configs = { [77] = { crosswalks = { 1 }, laneConnections = {} } }, streets = { [77] = {} } })
local movedNode, movedSummary = crosswalks.readBack({ node = 5, x = 1, y = 2 })
check("readBack: a node that was replaced is read at its position", movedNode == 77 and movedSummary == "1 crosswalks [1]", tostring(movedNode))
reset({ positions = { [5] = { x = 1, y = 2, z = 0 } }, streets = { [5] = { 10 } } })
world.configs[5] = nil
check("readBack: a node without a config is reported as such, with its streets", select(2, crosswalks.readBack({ node = 5, x = 1, y = 2 })) == "no config")
reset({ positions = { [5] = { x = 1, y = 2, z = 0 } } })
world.edges[10] = nil
local missingItems = select(3, crosswalks.readBack({ node = 5, x = 1, y = 2 }))
check("readBack: an unreadable street is reported as unreadable, the others are listed", contains(missingItems[1], "street 10 unreadable") and #missingItems == 3, missingItems[1])
reset({ positions = { [5] = { x = 1, y = 2, z = 0 } }, configThrows = true })
local throwNode, throwSummary = crosswalks.readBack({ node = 5, x = 1, y = 2 })
check("readBack: a failing read of the config is reported as unreadable and does not raise an error", throwNode == 5 and contains(throwSummary, "unreadable"), throwSummary)
reset({ positions = { [78] = { x = 50, y = 50, z = 0 } } })
local lostNode, lostSummary = crosswalks.readBack({ node = 5, x = 1, y = 2 })
check("readBack: no node at the position gives the remembered id and the text node not found", lostNode == 5 and lostSummary == "node not found")

-- The view of a node for the pass: its streets and its crosswalk list
reset({ positions = { [5] = { x = 1, y = 2, z = 0 } }, streets = { [5] = { 10, 11, 12 } } })
local view = crosswalks.inspect({ node = 5, x = 1, y = 2 })
check("inspect: the node, its streets and its crosswalk list", view.found == true and view.readable == true and view.node == 5
  and table.concat(view.streets, ",") == "10,11,12" and table.concat(view.crosswalks, ",") == "10")
reset({ positions = { [77] = { x = 1.2, y = 2, z = 0 } }, configs = { [77] = { crosswalks = { 1, 2 }, laneConnections = {} } }, streets = { [77] = { 10 } } })
local movedView = crosswalks.inspect({ node = 5, x = 1, y = 2 })
check("inspect: a node that was replaced is read at its position", movedView.found and movedView.node == 77 and table.concat(movedView.crosswalks, ",") == "1,2")
reset({ positions = { [5] = { x = 1, y = 2, z = 0 } } })
world.configs[5] = nil
check("inspect: a node without a config is found but not readable", crosswalks.inspect({ node = 5, x = 1, y = 2 }).found == true and crosswalks.inspect({ node = 5, x = 1, y = 2 }).readable == false)
reset({ positions = { [5] = { x = 1, y = 2, z = 0 } }, configThrows = true })
local throwView = crosswalks.inspect({ node = 5, x = 1, y = 2 })
check("inspect: a failing read is not readable and raises no error", throwView.found == true and throwView.readable == false)
reset({ positions = { [78] = { x = 50, y = 50, z = 0 } } })
local lostView = crosswalks.inspect({ node = 5, x = 1, y = 2 })
check("inspect: no node at the position is not found, with the remembered id", lostView.found == false and lostView.node == 5 and #lostView.streets == 0)

-- The end nodes of a road, as spots
reset({ positions = { [5] = { x = 1, y = 2, z = 0 }, [6] = { x = 3, y = 4, z = 0 } } })
world.edges[40] = { node0 = 5, node1 = 6 }
local ends = crosswalks.endSpots(40)
check("endSpots: both end nodes of a road with their positions", #ends == 2 and ends[1].node == 5 and ends[1].x == 1 and ends[2].node == 6 and ends[2].y == 4)
world.edges[41] = { node0 = 5, node1 = 9 }
check("endSpots: an end node without a position is left out", #crosswalks.endSpots(41) == 1)
check("endSpots: a road that cannot be read gives an empty list", #crosswalks.endSpots(99) == 0)
reset({ readThrows = true })
check("endSpots: a failing read raises no error", select("#", crosswalks.endSpots(40)) == 1 and #crosswalks.endSpots(40) == 0)

support.finish("node_crosswalks")
