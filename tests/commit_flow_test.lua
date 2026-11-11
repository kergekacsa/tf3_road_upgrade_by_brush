-- Tests of the upgrade commit (bb_upgrade.tl) with a stub of the game: the same press with the option "Debug: upgrade log"
-- Off and On must give the same result and the same log lines apart from the tags. The stub records every command and every
-- read of the game api. bb_select is the real module. bb_gather is a stub that describes the edges, so its reads are not
-- recorded.
-- The lot houses, the pair and the crosswalk pass run with the option Off too: only the log lines (tags, probe lines) depend on
-- the option. With the option Off the probe adds no read of its own but the read of the option (`probe.lotHouses` is a read of the
-- commit, not of the probe log). With the option On it adds no read inside the
-- callback of a command, except reads of fields of the proposal that the mod built itself. A callback reads only listed
-- components. This counts the reads of getComponent. The reads of bb_gather (the stub) and the other recorded reads, such
-- as entityExists, are not counted.

local support = dofile((arg[0]:match("^(.*)[/\\][^/\\]*$") or ".") .. "/support.lua")
local check, contains = support.check, support.contains

local STREET = {}
local upgrade
local world = {}

local function inCallback() return world.callbackDepth > 0 end

-- Every read of the game, as "<what> <entity>". All reads go to allReads; the reads inside command callbacks also go to
-- callbackReads.
local function noteRead(what, entity)
  local text = what .. " " .. tostring(entity)
  world.allReads[#world.allReads + 1] = text
  if inCallback() then world.callbackReads[#world.callbackReads + 1] = text end
end

-- A function of the game stub that notes each call.
local function recorded(what, fn)
  return function(...)
    noteRead(what, "-")
    return fn(...)
  end
end

-- A table of the proposal that notes each read of a field.
local function tracked(real, what)
  return setmetatable({}, {
    __index = function(_, key)
      noteRead(what, key)
      return real[key]
    end,
    __newindex = function(_, key, value)
      if key == "roadDevelopmentLocked" and world.dropLockWrite then return end
      real[key] = value
    end,
  })
end

-- A read that the option On adds inside the probe can fail in the game. The stub makes it fail on request.
local function failIfProbeRead(what)
  if world.throwInProbe ~= nil and world.inProbeFunction == world.throwInProbe then error("stub: " .. what .. " refused", 0) end
end

-- The transport modes of the stub, as the enum of the game numbers them
local MODE = { PERSON = 0, CARGO = 1, CAR = 2, BUS = 3, TRUCK = 4, TRAM = 5, ELECTRIC_TRAM = 6 }
local MODE_COUNT = 16

-- The lanes of a road: a list of lanes, each a list of mode numbers. The outer lanes of vehicles are the lanes 2 and 4.
local PLAIN_LANES = {
  { MODE.PERSON }, { MODE.CAR, MODE.BUS, MODE.TRUCK }, { MODE.CAR, MODE.BUS, MODE.TRUCK }, { MODE.CAR, MODE.BUS, MODE.TRUCK }, { MODE.PERSON },
}
local BUS_LANES = {
  { MODE.PERSON }, { MODE.BUS, MODE.TRUCK }, { MODE.CAR, MODE.BUS, MODE.TRUCK }, { MODE.BUS, MODE.TRUCK }, { MODE.PERSON },
}
local TRAM_LANES = {
  { MODE.PERSON }, { MODE.CAR, MODE.BUS, MODE.TRUCK, MODE.TRAM }, { MODE.CAR, MODE.BUS, MODE.TRUCK }, { MODE.CAR, MODE.BUS, MODE.TRUCK, MODE.TRAM }, { MODE.PERSON },
}
local CATENARY_LANES = {
  { MODE.PERSON }, { MODE.CAR, MODE.BUS, MODE.TRUCK, MODE.TRAM, MODE.ELECTRIC_TRAM }, { MODE.CAR, MODE.BUS, MODE.TRUCK },
  { MODE.CAR, MODE.BUS, MODE.TRUCK, MODE.TRAM, MODE.ELECTRIC_TRAM }, { MODE.PERSON },
}

-- Lanes as the game hands them out: the transport modes are read as a table keyed by the mode numbers, and written as a list
-- of 16 booleans counted from 1. `shift` makes the stub store a written list one mode too high, as a game that misreads it.
-- The field `forward` of a mode list is the direction of the lane.
local function makeLanes(layout, shift)
  local lanes = {}
  for i, modeList in ipairs(layout) do
    local data = { transportModes = {}, forward = modeList.forward }
    for _, mode in ipairs(modeList) do data.transportModes[mode] = true end
    lanes[i] = setmetatable({}, {
      __index = data,
      __newindex = function(_, key, value)
        if key ~= "transportModes" then data[key] = value; return end
        local stored = {}
        for index = 1, MODE_COUNT do if value[index] then stored[index - 1 + (shift or 0)] = true end end
        data.transportModes = stored
      end,
    })
  end
  return lanes
end

local function modesOfLane(lane)
  local out = {}
  for mode, on in pairs(lane.transportModes) do if on then out[#out + 1] = mode end end
  table.sort(out)
  return table.concat(out, "+")
end

local function lanesText(lanes)
  local out = {}
  for i, lane in ipairs(lanes) do out[i] = modesOfLane(lane) end
  return table.concat(out, " | ")
end

local function layoutText(layout)
  local out = {}
  for i, modeList in ipairs(layout) do
    local sorted = {}
    for j, mode in ipairs(modeList) do sorted[j] = mode end
    table.sort(sorted)
    out[i] = table.concat(sorted, "+")
  end
  return table.concat(out, " | ")
end

-- The end nodes of a road: world.edgeNodes[edge] = { node0, node1 }, else nodes that no other road shares. world.roadOffsets[edge]
-- moves the road along x, so that the octree stub can tell the roads apart by the centre of the query.
local function newComp(template, layout, shift, edge)
  local nodes = world.edgeNodes[edge] or { 1000 + (edge or 0), 2000 + (edge or 0) }
  local offset = world.roadOffsets[edge] or 0
  return {
    roadTemplate = template, type = 0, typeIndex = 0, roadDevelopmentLocked = false, roadType = STREET, distance = 10,
    edgeDecorations = {}, objects = {}, laneConfigs = layout ~= nil and makeLanes(layout, shift) or {},
    position0 = { x = offset, y = 0, z = 0 }, position1 = { x = offset + 10, y = 0, z = 0 }, node0 = nodes[1], node1 = nodes[2],
  }
end

local function copyConnections(list)
  local out = {}
  for i, c in ipairs(list) do
    out[i] = { segment0 = c.segment0, lane0 = c.lane0, segment1 = c.segment1, lane1 = c.lane1, withRoad = c.withRoad, withTram = c.withTram }
  end
  return out
end

-- With world.nodeConnections[node] (a list of { from, fromLane, to, toLane, withRoad, withTram }) every proposal carries a
-- config for both end nodes with these lane connections. The config hands out copies of its connections and keeps a written
-- list, as the game does. world.dropConnectionWrite makes it ignore a written list.
local function connectionConfigsOf(comp)
  local configs = {}
  for i, node in ipairs({ comp.node0, comp.node1 }) do
    local stored = {}
    for j, c in ipairs(world.nodeConnections[node] or {}) do
      stored[j] = { segment0 = c[1], lane0 = c[2], segment1 = c[3], lane1 = c[4], withRoad = c[5], withTram = c[6] }
    end
    local data = { crosswalks = {} }
    configs[i] = { entity = node, comp = setmetatable({}, {
      __index = function(_, key)
        if key == "laneConnections" then return copyConnections(stored) end
        return data[key]
      end,
      __newindex = function(_, key, value)
        if key ~= "laneConnections" then data[key] = value; return end
        if not world.dropConnectionWrite then stored = copyConnections(value) end
      end,
    }) }
  end
  return configs
end

-- With world.nodeConfigs every proposal of replaceSegment carries a config for both end nodes, naming the new segment -1 and the
-- road that it replaces.
local function nodeConfigsOf(edge, comp)
  if world.nodeConnections then return connectionConfigsOf(comp) end
  if not world.nodeConfigs then return nil end
  local configs = {}
  for i, node in ipairs({ comp.node0, comp.node1 }) do
    configs[i] = { entity = node, comp = { crosswalks = { edge }, laneConnections = { { segment0 = -1, lane0 = 0, segment1 = edge, lane1 = 0 } } } }
  end
  return configs
end

-- Every proposal of replaceSegment defines its new segment as -1 and removes the road itself. world.noStreetOnCall[edge] = N makes
-- the Nth proposal of that road come back without street data.
local function newProposal(edge)
  local real = newComp("new_template", world.proposalLanes, world.laneShift, edge)
  world.proposalComps[edge] = real
  local noStreet = world.noStreetOnCall[edge] == world.proposalCalls[edge]
  return {
    proposal = not noStreet and {
      addedSegments = { { entity = -1, comp = tracked(real, "proposal comp") } }, removedSegments = { { entity = edge } },
      addedNodes = {}, removedNodes = {}, edgeObjectsToAdd = {}, nodeConfigsToAdd = nodeConfigsOf(edge, real),
    } or nil,
    toRemove = {}, toAdd = {}, edge = edge,
  }
end

local function copyList(list)
  local out = {}
  for i, v in ipairs(list or {}) do out[i] = v end
  return out
end

local PLAYER = 7
local CTX = { player = PLAYER, hq = -1 }

-- The description of an edge as bb_gather makes it: a road of the player, outside any construction. A scenario changes
-- fields per edge with world.descriptions[edge], a table of fields or a function of the number of reads of that edge.
local function describeEdge(e)
  world.describeCalls[e] = (world.describeCalls[e] or 0) + 1
  local d = {
    entity = e, isEdge = true, isStreet = true, owner = PLAYER, parentConstruction = -1, template = "old_template", objects = {},
    isTunnel = false, tramOnly = false, industryRoad = false, gone = false,
  }
  local changes = world.descriptions[e]
  if type(changes) == "function" then changes = changes(world.describeCalls[e]) end
  for key, value in pairs(changes or {}) do d[key] = value end
  return d
end

-- bb_gather is a stub, so the reads of the hard rules are not recorded; bb_select is the real module.
support.installRequire({
  bb_brush = { EDGE_MARGIN = 100 },
  bb_gather = {
    newCache = function() return { industryRoads = {} } end,
    describeEdge = describeEdge,
  },
})

-- failCommandFor[edge] is true (every command of the road fails) or a number N (its first N commands fail).
local function commandFails(edge)
  local limit = world.failCommandFor[edge]
  return limit == true or (type(limit) == "number" and world.edgeBuilds[edge] <= limit)
end

local function runCommand(command, callback)
  world.commands[#world.commands + 1] = command.kind
  local isBuild = command.kind == "build"
  if isBuild then
    world.builds[#world.builds + 1] = command
    world.edgeBuilds[command.edge] = (world.edgeBuilds[command.edge] or 0) + 1
  end
  local nth = #world.builds
  local refused = command.kind == "speed" and command.speed == 0 and world.refusePause
  if command.kind == "speed" and not refused then world.speed = command.speed end
  if command.kind == "speed" and command.speed == 0 and world.cancelBeforePause then upgrade.cancel() end
  if isBuild and world.cancelBeforeBuild == nth then upgrade.cancel() end
  if isBuild and world.abortBeforeBuild == nth then upgrade.abort() end
  world.callbackDepth = world.callbackDepth + 1
  if command.kind == "crosswalk" then
    world.crosswalkCommands[#world.crosswalkCommands + 1] = command
    if world.cancelDuringCrosswalk then upgrade.cancel() end
    -- failCrosswalk is true (every crosswalk command is refused) or a number N (the first N are)
    local refused = world.failCrosswalk == true or (type(world.failCrosswalk) == "number" and #world.crosswalkCommands <= world.failCrosswalk)
    if refused then
      callback({ resultProposalData = { errorState = { messages = { "Crosswalk refused" } } } }, false)
    else
      world.nodeCrosswalks[command.node] = copyList(command.crosswalks)
      -- Another mod (Smart Lanes) rewrites the config of the node right after our command
      if (world.dropAfterSend[command.node] or 0) > 0 then
        world.dropAfterSend[command.node] = world.dropAfterSend[command.node] - 1
        world.nodeCrosswalks[command.node] = {}
      end
      world.crosswalkAnswered = true
      callback({ resultProposalData = { errorState = { messages = {} }, costs = 100 } }, true)
    end
  elseif isBuild and commandFails(command.edge) then
    callback({ resultProposalData = { errorState = { messages = world.failMessages },
      collisionInfo = { collisionEntities = world.collisionEntities, buildingEntities = {} } } }, false)
  elseif refused then
    callback({}, false)
  else
    -- A command that succeeds removes its entities from the world.
    for _, e in ipairs(command.toRemove or {}) do world.missingEntities[e] = true end
    -- A node that another mod replaces after the pair command: the same position, a new id
    if isBuild and #command.removedSegments > 1 then
      for old, new in pairs(world.nodeReplaced) do
        world.nodePositions[new], world.nodePositions[old] = world.nodePositions[old], nil
        world.nodeCrosswalks[new], world.nodeCrosswalks[old] = world.nodeCrosswalks[old], nil
        world.nodeSegments[new] = world.nodeSegments[old]
      end
    end
    callback({ resultProposalData = { errorState = { messages = {} }, costs = 100 } }, true)
  end
  world.callbackDepth = world.callbackDepth - 1
  if isBuild and world.bumpSpeedAfterBuild == nth then world.speed = 1 end
end

_G.os.clock = function() return world.clock end
_G.log = { message = function(m) world.probeLines[#world.probeLines + 1] = m end }
_G.api = {
  type = {
    enum = {
      RoadType = { STREET = STREET },
      TransportMode = { PERSON = 0, CARGO = 1, CAR = 2, BUS = 3, TRUCK = 4, TRAM = 5, ELECTRIC_TRAM = 6 },
      BaseEdgeType = { NORMAL = 0, BRIDGE = 1, TUNNEL = 2 },
    },
    ComponentType = {
      BASE_EDGE = "BASE_EDGE", BASE_EDGE_STREET = "BASE_EDGE_STREET", GAME_SPEED = "GAME_SPEED", GAME_TIME = "GAME_TIME",
      ASSET_GROUP = "ASSET_GROUP", PLAYER_OWNED = "PLAYER_OWNED", CONSTRUCTION = "CONSTRUCTION", BASE_NODE = "BASE_NODE",
      BASE_NODE_CONFIG = "BASE_NODE_CONFIG",
    },
    Vec2f = { new = function(x, y) return { x = x, y = y } end },
    Context = { new = function() return {} end },
    SimpleProposal = { new = function() return { streetProposal = {} } end },
    BaseNodeLaneConnectionAndEntity = { new = function() return {} end },
    LaneConnection = { new = function() return {} end },
  },
  res = {
    streetTemplateRep = {
      find = recorded("res.streetTemplateRep.find", function() return world.templateLanes ~= nil and 7 or -1 end),
      get = function() return { laneConfigs = makeLanes(world.templateLanes), defaultEdgeDecorations = {}, country = world.templateCountry, defaultWithCrosswalk = world.templateDefaultWalk } end,
    },
    edgeDecorationRep = { find = recorded("res.edgeDecorationRep.find", function() return -1 end) },
  },
  gui = { construction = { getRefundableEntities = recorded("gui.getRefundableEntities", function() return {} end) } },
  engine = {
    config = { getModParams = recorded("config.getModParams", function() return { kacsa_road_upgrade_brush = { rub_log = world.optionValue } } end) },
    entityExists = recorded("entityExists", function(e)
      if world.throwInEntityExists then error("stub: entityExists refused", 0) end
      return not world.missingEntities[e]
    end),
    getComponent = function(e, componentType)
      noteRead(componentType, e)
      if componentType == "GAME_SPEED" then return { speedup = world.speed } end
      if componentType == "GAME_TIME" then return { updateCount = world.updates } end
      if componentType == "BASE_EDGE_STREET" then return {} end
      if componentType == "BASE_EDGE" then
        failIfProbeRead("getComponent")
        return newComp("old_template", world.roadLanesFor[e] or world.roadLanes, nil, e)
      end
      if componentType == "BASE_NODE" then return world.nodePositions[e] and { position = world.nodePositions[e] } or nil end
      if componentType == "BASE_NODE_CONFIG" and world.crosswalkAnswered and world.hideConfigAfter == "throw" then error("stub: config refused", 0) end
      if componentType == "BASE_NODE_CONFIG" and world.crosswalkAnswered and world.hideConfigAfter == "nil" then return nil end
      if componentType == "BASE_NODE_CONFIG" then
        return world.nodeCrosswalks[e] and { crosswalks = copyList(world.nodeCrosswalks[e]), laneConnections = {} } or nil
      end
      if componentType == "ASSET_GROUP" then return world.assetGroups[e] and {} or nil end
      if componentType == "PLAYER_OWNED" then return { player = 7 } end
      if componentType == "CONSTRUCTION" then
        failIfProbeRead("getComponent")
        return world.constructions[e]
      end
      return nil
    end,
    system = {
      streetSystem = { getNodeStreetSegments = recorded("streetSystem.getNodeStreetSegments", function(node) return world.nodeSegments[node] or {} end) },
      parcelSystem = {
      getParcelData = function(e)
        world.parcelReads[#world.parcelReads + 1] = { edge = e, inCallback = inCallback() }
        return { leftEntities = {}, rightParcels = {} }
      end,
    } },
    util = {
      getWorld = recorded("util.getWorld", function() return 1000 end),
      getPlayer = recorded("util.getPlayer", function() return 1 end),
      octree = { findEntitiesInCircle = recorded("octree", function(center, radius, componentType)
        failIfProbeRead("octree")
        if componentType == "CONSTRUCTION" then
          world.lotQueries[#world.lotQueries + 1] = { center = center, radius = radius }
          if type(world.lotFound) == "function" then return world.lotFound(center) end
          return world.lotFound
        end
        if componentType == "BASE_NODE" then
          local found = {}
          for node, p in pairs(world.nodePositions) do
            if (p.x - center.x) ^ 2 + (p.y - center.y) ^ 2 <= radius ^ 2 then found[#found + 1] = node end
          end
          return found
        end
        return {}
      end) },
      proposal = { replaceSegment = recorded("util.proposal.replaceSegment", function(e, template)
        -- failProposalFor[edge] is true (every proposal fails) or a number N (the first N proposals fail).
        world.proposalCalls[e] = (world.proposalCalls[e] or 0) + 1
        local limit = world.failProposalFor[e]
        if limit == true or (type(limit) == "number" and world.proposalCalls[e] <= limit) then error("replaceSegment refused edge " .. e) end
        world.replacedWith[e] = template
        return newProposal(e)
      end) },
    },
  },
  cmd = {
    makeGameSetSpeedCmd = function(speed) return { kind = "speed", speed = speed } end,
    makeWorldBuildProposalCmd = function(p, _context, force)
      if p.streetProposal ~= nil then
        local entry = p.streetProposal.nodeConfigsToAdd[1]
        world.crosswalkBuilds[#world.crosswalkBuilds + 1] = { node = entry.entity, inCallback = inCallback(), commandsBefore = #world.commands }
        return { kind = "crosswalk", node = entry.entity, crosswalks = copyList(entry.comp.crosswalks), clock = world.clock }
      end
      if world.throwOnSendFor[p.edge] then error("stub: the command was refused", 0) end
      local removedSegments = {}
      for i, segment in ipairs(p.proposal.removedSegments) do removedSegments[i] = segment.entity end
      local configs = {}
      for i, config in ipairs(p.proposal.nodeConfigsToAdd or {}) do
        local first = config.comp.laneConnections[1]
        configs[i] = { entity = config.entity, connections = #config.comp.laneConnections, crosswalks = #config.comp.crosswalks,
          segment0 = first and first.segment0 or nil, crosswalkIds = copyList(config.comp.crosswalks),
          laneConnections = copyConnections(config.comp.laneConnections) }
      end
      return { kind = "build", edge = p.edge, force = force, toRemove = copyList(p.toRemove), removedSegments = removedSegments,
        addedSegments = #p.proposal.addedSegments, linesBefore = #world.lines, configs = configs, clock = world.clock }
    end,
    sendCommand = runCommand,
  },
}

-- Notes where the press of the probe runs, and lets a read inside the probe throw on request. With world.inertProbe the
-- commit meets a probe that does nothing at all (tag, beginPress and press): the reads of such a press are the reads of
-- the commit alone. lotHouses is no part of it: the commit uses its result with the option Off too.
local probeModule = ug_require("kacsa_road_upgrade_brush::/road_upgrade_brush/proposal_probe.tl")
local originalPress, originalTag, originalBeginPress = probeModule.press, probeModule.tag, probeModule.beginPress
local originalLotHouses = probeModule.lotHouses
-- The pair spike module is the real one. These wrappers note each call and where it runs.
local pairModule = ug_require("kacsa_road_upgrade_brush::/road_upgrade_brush/pair_spike.tl")
local originalPartners, originalMerge = pairModule.partners, pairModule.merge
pairModule.partners = function(edge, candidates)
  local found = originalPartners(edge, candidates)
  world.pairCalls[#world.pairCalls + 1] = { what = "partner", edge = edge, partner = found[1], found = #found, candidates = #candidates, inCallback = inCallback() }
  return found
end
pairModule.merge = function(base, extra)
  world.pairCalls[#world.pairCalls + 1] = { what = "merge", inCallback = inCallback() }
  return originalMerge(base, extra)
end
local function inertHandle()
  return { road = function() end, proposal = function() end, after = function() end }
end
probeModule.tag = function(category, text)
  if world.inertProbe then return text end
  return originalTag(category, text)
end
probeModule.beginPress = function()
  if world.inertProbe then return end
  return originalBeginPress()
end
probeModule.lotHouses = function(edge)
  world.lotHouseCalls[#world.lotHouseCalls + 1] = { edge = edge, inCallback = inCallback() }
  world.inProbeFunction = "lotHouses"
  local ok, houses, houseText = pcall(originalLotHouses, edge)
  world.inProbeFunction = nil
  if not ok then error(houses, 0) end
  return houses, houseText
end
probeModule.press = function(edges)
  local call = { inCallback = inCallback(), commandsBefore = #world.commands, readsBefore = #world.allReads }
  world.pressCalls[#world.pressCalls + 1] = call
  if world.inertProbe then
    call.reads = 0
    return inertHandle()
  end
  world.inProbeFunction = "before"
  local ok, handle = pcall(originalPress, edges)
  world.inProbeFunction = nil
  call.reads = #world.allReads - call.readsBefore
  if not ok then error(handle, 0) end
  local originalAfter = handle.after
  handle.after = function(edge, state)
    world.inProbeFunction = "after"
    local okAfter, err = pcall(originalAfter, edge, state)
    world.inProbeFunction = nil
    if not okAfter then error(err, 0) end
  end
  return handle
end

upgrade = dofile(support.buildDir .. "/bb_upgrade.lua")

local DEFAULT_EXTRAS = { busLane = false, tram = false, catenary = false, lock = "keep" }

-- The lanes of a plan that puts the extras on the outer vehicle lanes of a lane layout. nil without bus lane and tram.
local function planLanes(extras, layout)
  if not extras.busLane and not extras.tram then return nil end
  local vehicle = {}
  for i, modeList in ipairs(layout or {}) do
    if modeList[1] ~= MODE.PERSON and modeList[1] ~= MODE.CARGO then vehicle[#vehicle + 1] = i end
  end
  local lanes = {}
  for _, i in ipairs({ vehicle[1], vehicle[#vehicle] }) do
    lanes[i] = { carFree = extras.busLane == true, tram = extras.tram == true, electric = extras.catenary == true }
  end
  return lanes
end

-- The target of a press. With `options.railTarget` (template, same, decorations per track) the plans are those of tracks.
-- Else every road gets `template` with the extras of the scenario, and a road that has the template is the target already.
-- It reads the road as the targets of the tool do. `options.target` replaces all of this with the target of the scenario.
local function targetOf(options, template)
  if options.target ~= nil then return options.target end
  if options.railTarget ~= nil then
    return function(e)
      local railTemplate, same, decorations = options.railTarget(e)
      return { template = railTemplate, unchanged = same, decorations = decorations, lock = "keep",
        reason = railTemplate == nil and "other track type" or nil, notes = {} }
    end
  end
  if template == nil then return nil end
  local extras = options.extras or DEFAULT_EXTRAS
  return function(e)
    local comp = api.engine.getComponent(e, "BASE_EDGE")
    return { template = template, unchanged = comp.roadTemplate == template, lanes = planLanes(extras, options.proposalLanes),
      laneCount = #(options.proposalLanes or {}), lock = extras.lock, notes = {} }
  end
end

-- Runs one press over `options.edges` and returns the commit result, the lines of the commit, the probe lines, and the
-- records of the stub.
local function press(options)
  world.optionValue = options.option
  world.speed = options.speed or 1
  world.failProposalFor = options.failProposalFor or {}
  world.failCommandFor = options.failCommandFor or {}
  world.failMessages = options.failMessages or { "Collision" }
  world.assetGroups = options.assetGroups or { [50] = true }
  world.missingEntities = {}
  for e, gone in pairs(options.missingEntities or {}) do world.missingEntities[e] = gone end
  world.edgeBuilds, world.proposalCalls = {}, {}
  world.refusePause = options.refusePause == true
  world.cancelBeforePause = options.cancelBeforePause == true
  world.throwInEntityExists = options.throwInEntityExists == true
  world.throwOnSendFor = options.throwOnSendFor or {}
  world.collisionEntities = options.collisionEntities or { { entity = 50 } }
  world.dropLockWrite = options.dropLockWrite == true
  world.bumpSpeedAfterBuild = options.bumpSpeedAfterBuild
  world.cancelBeforeBuild = options.cancelBeforeBuild
  world.abortBeforeBuild = options.abortBeforeBuild
  world.throwInProbe = options.throwInProbe
  world.nodeConfigs, world.noStreetOnCall = options.nodeConfigs == true, options.noStreetOnCall or {}
  world.nodeConnections, world.dropConnectionWrite = options.nodeConnections, options.dropConnectionWrite == true
  world.inertProbe = options.inertProbe == true
  world.inProbeFunction = nil
  world.descriptions = options.descriptions or {}
  world.describeCalls, world.replacedWith, world.proposalComps = {}, {}, {}
  world.roadLanes, world.proposalLanes, world.templateLanes = options.roadLanes, options.proposalLanes, options.templateLanes
  world.laneShift = options.laneShift
  world.constructions, world.lotFound = options.constructions or {}, options.lotFound or {}
  world.edgeNodes, world.roadOffsets = options.edgeNodes or {}, options.roadOffsets or {}
  world.nodeSegments = options.nodeSegments or {}
  world.templateCountry = options.templateCountry == true
  world.nodePositions, world.nodeCrosswalks, world.nodeReplaced = options.nodePositions or {}, options.nodeCrosswalks or {}, options.nodeReplaced or {}
  world.failCrosswalk, world.crosswalkBuilds, world.crosswalkCommands = options.failCrosswalk, {}, {}
  world.crosswalkAnswered, world.hideConfigAfter, world.roadLanesFor = false, options.hideConfigAfter, options.roadLanesFor or {}
  world.dropAfterSend, world.cancelDuringCrosswalk = options.dropAfterSend or {}, options.cancelDuringCrosswalk == true
  world.pairCalls = {}
  world.lotQueries, world.lotHouseCalls = {}, {}
  world.allReads, world.callbackReads, world.parcelReads = {}, {}, {}
  world.pressCalls, world.commands, world.builds, world.probeLines = {}, {}, {}, {}
  world.callbackDepth = 0
  world.clock = 0
  local lines, result, doneCalls, roadCalls = {}, nil, 0, {}
  world.lines = lines
  local template = options.template or "new_template"
  if options.noTemplate then template = nil end
  local function commit(onDone)
    upgrade.commit(options.edges, targetOf(options, template), options.railTarget ~= nil and "track" or "road", options.removeBuildings == true,
      options.ctx or CTX, options.industryRoads or {}, onDone, function(text) lines[#lines + 1] = text end,
      function(e, ok, finished, total, attempt) roadCalls[#roadCalls + 1] = { e = e, ok = ok, finished = finished, total = total, attempt = attempt } end)
  end
  commit(function(res) result = res; doneCalls = doneCalls + 1 end)
  -- A second commit while the first one runs
  local second
  if options.secondCommit then
    upgrade.commit(options.edges, targetOf(options, template), "road", false, options.ctx or CTX, {},
      function(res) second = res end, function() end, nil)
  end
  for tick = 1, 400 do
    if result ~= nil then break end
    if options.cancelAtTick == tick then upgrade.cancel() end
    world.clock = world.clock + 0.2
    upgrade.tick()
  end
  for _ = 1, 5 do
    world.clock = world.clock + 0.2
    upgrade.tick()
  end
  return {
    result = result, lines = lines, probeLines = world.probeLines, callbackReads = world.callbackReads, allReads = world.allReads,
    parcelReads = world.parcelReads, pressCalls = world.pressCalls, commands = world.commands, builds = world.builds,
    doneCalls = doneCalls, roadCalls = roadCalls, second = second, replacedWith = world.replacedWith,
    proposalComps = world.proposalComps, lotQueries = world.lotQueries, lotHouseCalls = world.lotHouseCalls, pairCalls = world.pairCalls, crosswalkBuilds = world.crosswalkBuilds, crosswalkCommands = world.crosswalkCommands,
  }
end

local function stripTags(lines)
  local out = {}
  for i, line in ipairs(lines) do out[i] = (line:gsub("^%[upgrade%] ", ""):gsub("^%[failure%] ", "")) end
  return out
end

-- The one read the probe makes with the option Off.
local READ_OF_THE_OPTION = "config.getModParams -"

local function sameLines(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

local function count(list, predicate)
  local n = 0
  for _, item in ipairs(list) do if predicate(item) then n = n + 1 end end
  return n
end

-- The entries of `a` that `b` does not have, counting repeats.
local function onlyIn(a, b)
  local left = {}
  for _, item in ipairs(b) do left[item] = (left[item] or 0) + 1 end
  local out = {}
  for _, item in ipairs(a) do
    if (left[item] or 0) > 0 then left[item] = left[item] - 1 else out[#out + 1] = item end
  end
  return out
end

local function isProposalField(read) return read:sub(1, 13) == "proposal comp" end

local function text(list) return table.concat(list, ", ") end

-- The reads of components inside command callbacks. A callback MAY read only the own base edge of a road of the press, the
-- asset group of a colliding entity, and the speed and the time of the world. Returns the reads that are none of these.
local WORLD_ENTITY = 1000
local function unlistedComponentReads(run, edges, colliding)
  local edgeSet, collidingSet = {}, {}
  for _, e in ipairs(edges) do edgeSet[e] = true end
  for _, e in ipairs(colliding) do collidingSet[e] = true end
  local out = {}
  for _, read in ipairs(run.callbackReads) do
    local component, entity = read:match("^([A-Z_]+) (%d+)$")
    if component ~= nil then
      entity = tonumber(entity)
      local listed = (component == "BASE_EDGE" and edgeSet[entity])
        or (component == "ASSET_GROUP" and collidingSet[entity])
        or ((component == "GAME_SPEED" or component == "GAME_TIME") and entity == WORLD_ENTITY)
      if not listed then out[#out + 1] = read end
    end
  end
  return out
end

-- The reads inside command callbacks with the option On: none is missing, and what the option adds are reads of fields of
-- the proposal that the mod built (the added segment that the line before the command shows).
local function callbackReadsMatch(on, offRun)
  local missing, extra = onlyIn(offRun.callbackReads, on.callbackReads), onlyIn(on.callbackReads, offRun.callbackReads)
  return #missing == 0 and count(extra, function(r) return not isProposalField(r) end) == 0, extra
end

local function sameOutcome(on, offRun)
  return on.result.removed == offRun.result.removed and on.result.unchanged == offRun.result.unchanged
    and on.result.commands == offRun.result.commands and #on.result.failed == #offRun.result.failed
    and sameLines(on.commands, offRun.commands)
end

-- A press of two roads that both work, with the option Off and On
local off = press({ option = 1, edges = { 1, 2 } })
check("press ends", off.result ~= nil)
check("off: the stub sees the reads of the command callbacks", #off.callbackReads > 0)
check("off: both roads upgraded", off.result.removed == 2 and #off.result.failed == 0)
check("off: no parcel read", #off.parcelReads == 0)
check("off: no probe line", #off.probeLines == 0)
check("off: no commit line is tagged", count(off.lines, function(l) return l:sub(1, 1) == "[" end) == 0)

local on = press({ option = 2, edges = { 1, 2 } })
check("on: both roads upgraded", on.result.removed == 2 and #on.result.failed == 0)
check("on: the result equals the result with the option Off", sameOutcome(on, off))
check("on: the commit lines equal the Off lines once the tags are removed", sameLines(stripTags(on.lines), off.lines))
check("on: every commit line carries a tag", count(on.lines, function(l) return l:sub(1, 1) ~= "[" end) == 0)
check("on: the commands are pause, two builds, speed back", text(on.commands) == "speed, build, build, speed", text(on.commands))
check("on: no parcel is ever read", #on.parcelReads == 0)
local matches, extra = callbackReadsMatch(on, off)
check("on: inside command callbacks the option adds reads of proposal fields only", matches, text(extra))
-- The one On-only read inside a command callback: for the first road the proposal is read in the callback of the pause command.
check("on: that read exists, for the first road", #extra > 0)
check("on: the press of the probe reads each road once, before the first command, outside any callback",
  #on.pressCalls == 1 and on.pressCalls[1].commandsBefore == 0 and on.pressCalls[1].inCallback == false and on.pressCalls[1].reads == 4,
  on.pressCalls[1] and on.pressCalls[1].reads)
check("on: a before line and an after line per road",
  count(on.probeLines, function(l) return contains(l, "before (") end) == 2 and count(on.probeLines, function(l) return contains(l, "after:") end) == 2)
check("on: the second road's before line counts the build commands since the read",
  count(on.probeLines, function(l) return contains(l, "edge 2 attempt 0 before (old road read at press start, 1 commands sent since)") end) == 1)

-- A press with the game paused: no pause command
local paused = press({ option = 2, edges = { 1, 2 }, speed = 0 })
check("paused game: both roads upgraded with builds only", paused.result.removed == 2 and text(paused.commands) == "build, build", text(paused.commands))
check("paused game: no parcel is ever read", #paused.parcelReads == 0)
local pausedOff = press({ option = 1, edges = { 1, 2 }, speed = 0 })
check("paused game: the reads inside command callbacks equal the reads with the option Off, proposal fields included",
  sameLines(paused.callbackReads, pausedOff.callbackReads), text(onlyIn(paused.callbackReads, pausedOff.callbackReads)))
check("paused game: the press of the probe reads before the first command, outside any callback",
  #paused.pressCalls == 1 and paused.pressCalls[1].commandsBefore == 0 and paused.pressCalls[1].inCallback == false)
check("paused game: the commit lines equal the Off lines once the tags are removed", sameLines(stripTags(paused.lines), pausedOff.lines))
check("paused game: the result equals the result with the option Off", sameOutcome(paused, pausedOff))

-- A road that fails before its command inside the callback of the pause command starts the next road in that callback
local chain = press({ option = 2, edges = { 1, 2 }, failProposalFor = { [1] = true } })
local chainOff = press({ option = 1, edges = { 1, 2 }, failProposalFor = { [1] = true } })
check("chain: road 2 is upgraded, road 1 fails", chain.result.removed == 1 and #chain.result.failed == 1 and chain.result.failed[1] == 1)
check("chain: the press of the probe never runs in a command callback", #chain.pressCalls == 1 and chain.pressCalls[1].inCallback == false and #chain.parcelReads == 0)
check("chain: the failed road gets a line for each of its three attempts",
  count(chain.probeLines, function(l) return contains(l, "edge 1 attempt 0 before") end) == 1
  and count(chain.probeLines, function(l) return contains(l, "edge 1 attempt 1 before") end) == 1
  and count(chain.probeLines, function(l) return contains(l, "edge 1 attempt 2 before") end) == 1)
check("chain: the failure lines carry the failure tag", count(chain.lines, function(l) return contains(l, "[failure] edge 1:") end) >= 1)
check("chain: the commit lines equal the Off lines once the tags are removed", sameLines(stripTags(chain.lines), chainOff.lines))
matches, extra = callbackReadsMatch(chain, chainOff)
check("chain: inside command callbacks the option adds reads of proposal fields only", matches, text(extra))
check("chain: the result equals the result with the option Off", sameOutcome(chain, chainOff))

-- The game speed changes during a press: the next road starts in the callback of a second pause command
local bumped = press({ option = 2, edges = { 1, 2 }, bumpSpeedAfterBuild = 1 })
local bumpedOff = press({ option = 1, edges = { 1, 2 }, bumpSpeedAfterBuild = 1 })
check("speed change: the second road pauses the game again", text(bumped.commands) == "speed, build, speed, build, speed", text(bumped.commands))
check("speed change: both roads upgraded", bumped.result.removed == 2 and #bumped.result.failed == 0)
matches, extra = callbackReadsMatch(bumped, bumpedOff)
check("speed change: inside command callbacks the option adds reads of proposal fields only", matches, text(extra))
check("speed change: the commit lines equal the Off lines once the tags are removed", sameLines(stripTags(bumped.lines), bumpedOff.lines))
check("speed change: the result equals the result with the option Off", sameOutcome(bumped, bumpedOff))
check("speed change: the second road's before line counts the build command since the read",
  count(bumped.probeLines, function(l) return contains(l, "edge 2 attempt 0 before (old road read at press start, 1 commands sent since)") end) == 1)

-- A command that fails: the branch of the callback that reads the asset groups, and the retry passes that remove them.
-- Road 1 fails in all three attempts; its builds are the ones with edge 1.
local function buildsOf(run, edge)
  local out = {}
  for _, b in ipairs(run.builds) do if b.edge == edge then out[#out + 1] = b end end
  return out
end

for _, removeBuildings in ipairs({ false, true }) do
  local name = removeBuildings and "failed command, buildings removed" or "failed command"
  local failedOff = press({ option = 1, edges = { 1, 2 }, failCommandFor = { [1] = true }, removeBuildings = removeBuildings })
  check(name .. ": off: road 1 fails after all its attempts, road 2 is upgraded",
    failedOff.result.removed == 1 and #failedOff.result.failed == 1 and failedOff.result.failed[1] == 1)
  check(name .. ": off: the failed branch reads in the callback", count(failedOff.callbackReads, function(r) return contains(r, "ASSET_GROUP 50") end) > 0)
  local failedOn = press({ option = 2, edges = { 1, 2 }, failCommandFor = { [1] = true }, removeBuildings = removeBuildings })
  check(name .. ": on: the result equals the result with the option Off", sameOutcome(failedOn, failedOff))
  check(name .. ": on: the commit lines equal the Off lines once the tags are removed",
    sameLines(stripTags(failedOn.lines), failedOff.lines))
  matches, extra = callbackReadsMatch(failedOn, failedOff)
  check(name .. ": on: inside command callbacks the option adds reads of proposal fields only", matches, text(extra))
  check(name .. ": on: the failed command lines carry the failure tag", count(failedOn.lines, function(l) return contains(l, "[failure] cmd") end) >= 1)
  check(name .. ": on: no parcel is ever read", #failedOn.parcelReads == 0)
  check(name .. ": on: the press of the probe never runs in a command callback", count(failedOn.pressCalls, function(r) return r.inCallback end) == 0)
  -- What the commands carry: the first attempt never removes anything. The retries remove the asset group, and only the
  -- last one forces the command.
  local builds = buildsOf(failedOn, 1)
  check(name .. ": road 1 is sent three times", #builds == 3, #builds)
  check(name .. ": the first attempt has no removal list and no force", #builds[1].toRemove == 0 and builds[1].force == false)
  if removeBuildings then
    check(name .. ": retry 1 removes the asset group and does not force", #builds[2].toRemove == 1 and builds[2].toRemove[1] == 50 and builds[2].force == false)
    check(name .. ": retry 2 removes the asset group and forces", #builds[3].toRemove == 1 and builds[3].toRemove[1] == 50 and builds[3].force == true)
  else
    check(name .. ": without the option no retry removes anything or forces",
      #builds[2].toRemove == 0 and #builds[3].toRemove == 0 and builds[2].force == false and builds[3].force == false)
  end
  check(name .. ": road 2 is never given a removal list or forced", count(buildsOf(failedOn, 2), function(b) return #b.toRemove > 0 or b.force end) == 0)
end

-- With the option to remove buildings, an entity that is no asset group, or that is gone, is never put in the removal list
local notAsset = press({ option = 2, edges = { 1, 2 }, failCommandFor = { [1] = true }, removeBuildings = true, assetGroups = {} })
check("collision with something that is no asset group: no retry removes anything or forces",
  #buildsOf(notAsset, 1) == 3 and count(buildsOf(notAsset, 1), function(b) return #b.toRemove > 0 or b.force end) == 0)
local gone = press({ option = 2, edges = { 1, 2 }, failCommandFor = { [1] = true }, removeBuildings = true, missingEntities = { [50] = true } })
check("an asset group that is gone is not put in the removal list and nothing is forced",
  #buildsOf(gone, 1) == 3 and count(buildsOf(gone, 1), function(b) return #b.toRemove > 0 or b.force end) == 0)

local twoMessages = press({ option = 2, edges = { 1, 2 }, failCommandFor = { [1] = true }, removeBuildings = true, failMessages = { "Collision", "Too Much Incline" } })
check("collision with a second message: no retry removes anything or forces",
  #buildsOf(twoMessages, 1) == 3 and count(buildsOf(twoMessages, 1), function(b) return #b.toRemove > 0 or b.force end) == 0)

-- The game refuses to pause: no command is sent
for _, option in ipairs({ 1, 2 }) do
  local refusedRun = press({ option = option, edges = { 1, 2 }, refusePause = true })
  check("pause refused (option " .. option .. "): no build command is sent", #refusedRun.builds == 0, text(refusedRun.commands))
  check("pause refused (option " .. option .. "): the press is refused and both roads count as failed",
    refusedRun.result.refused ~= nil and #refusedRun.result.failed == 2 and refusedRun.result.removed == 0, tostring(refusedRun.result.refused))
  check("pause refused (option " .. option .. "): the speed is set back", refusedRun.commands[#refusedRun.commands] == "speed")
end

-- A cancel while a command is on its way: that command finishes, the next road is not sent
local cancelled = press({ option = 2, edges = { 1, 2 }, cancelBeforeBuild = 1 })
check("cancel: the road in progress finishes and the press stops",
  cancelled.result.cancelled == true and cancelled.result.removed == 1 and #cancelled.builds == 1, text(cancelled.commands))
check("cancel: the speed is set back and the result comes once", cancelled.commands[#cancelled.commands] == "speed" and cancelled.doneCalls == 1)

-- An abort while a command is on its way: the result comes at once and the late answer of the game is ignored
local aborted = press({ option = 2, edges = { 1, 2 }, abortBeforeBuild = 1 })
check("abort: the result comes once and the late answer counts for nothing",
  aborted.doneCalls == 1 and aborted.result.cancelled == true and aborted.result.removed == 0 and #aborted.builds == 1, text(aborted.commands))

-- A collision with an asset group and with something else is never forced
local mixed = press({ option = 2, edges = { 1, 2 }, failCommandFor = { [1] = true }, removeBuildings = true,
  collisionEntities = { { entity = 50 }, { entity = 60 } } })
check("collision with an asset group and with another entity: no retry removes anything or forces",
  #buildsOf(mixed, 1) == 3 and count(buildsOf(mixed, 1), function(b) return #b.toRemove > 0 or b.force end) == 0)

-- The lot houses around a failed road: only the first retry puts them in the removal list. The first attempt and the second
-- retry never do.
local HOUSE = { townBuildings = { 1 }, stations = {}, depots = {}, industries = {} }
local LOT_CONSTRUCTIONS = { [101] = HOUSE, [102] = HOUSE, [103] = { townBuildings = {}, stations = { 9 }, depots = {}, industries = {} } }
local LOT_FOUND = { 101, 102, 103 }
local function lotPress(fields)
  local options = { option = 2, edges = { 1, 2 }, failCommandFor = { [1] = true }, removeBuildings = true, assetGroups = {},
    constructions = LOT_CONSTRUCTIONS, lotFound = LOT_FOUND }
  for key, value in pairs(fields or {}) do options[key] = value end
  return press(options)
end
-- The lines of a run that contain `part`, and (when `tag` is given) also `tag`, such as "(retry 1)".
local function linesWith(run, part, tag)
  return count(run.lines, function(l) return contains(l, part) and (tag == nil or contains(l, tag)) end)
end
local function readsOf(run, part) return count(run.allReads, function(r) return contains(r, part) end) end
local function withRemovalList(run) return count(run.builds, function(b) return #b.toRemove > 0 end) end

local lots = lotPress()
local lotBuilds = buildsOf(lots, 1)
check("lot houses: road 1 is sent three times", #lotBuilds == 3, #lotBuilds)
check("lot houses: the first attempt has no removal list and the houses are looked up once, for the first retry",
  #lotBuilds[1].toRemove == 0 and #lots.lotHouseCalls == 1 and #lots.lotQueries == 1)
check("lot houses: the first retry puts the houses in the removal list, the station is left out", text(lotBuilds[2].toRemove) == "101, 102", text(lotBuilds[2].toRemove))
check("lot houses: the second retry has no removal list", #lotBuilds[3].toRemove == 0)
check("lot houses: nothing is forced because of houses", lotBuilds[1].force == false and lotBuilds[2].force == false and lotBuilds[3].force == false)
check("lot houses: road 2 is never given a removal list", count(buildsOf(lots, 2), function(b) return #b.toRemove > 0 end) == 0)
check("lot houses: only the line of the first retry says that two houses were put in toRemove",
  linesWith(lots, "; 2 lot houses put in toRemove", "(retry 1)") == 1 and linesWith(lots, "lot houses") == 1)
check("lot houses: the line carries the text of the probe with the ids", linesWith(lots, "2 lot houses within 30 m of the road: [101, 102]", "(retry 1)") == 1)
check("lot houses: the octree is asked for constructions around road 1 only, centred on it, with its half length plus 30 m",
  #lots.lotQueries == 1 and lots.lotQueries[1].center.x == 5 and lots.lotQueries[1].center.y == 0 and lots.lotQueries[1].radius == 35)
check("lot houses: no read of the houses runs inside a command callback in a normal press",
  lots.lotHouseCalls[1].inCallback == false and readsOf({ allReads = lots.callbackReads }, "octree") == 0
  and readsOf({ allReads = lots.callbackReads }, "CONSTRUCTION") == 0, text(lots.callbackReads))
check("lot houses: no parcel is ever read", #lots.parcelReads == 0)
check("lot houses: the result is the failure of road 1 and the upgrade of road 2", lots.result.removed == 1 and #lots.result.failed == 1 and lots.result.failed[1] == 1)

-- A road that only asset groups block keeps the recovery of the asset groups: no houses, no lookup.
local lotsWithAssets = lotPress({ assetGroups = { [50] = true } })
local assetBuilds = buildsOf(lotsWithAssets, 1)
check("lot houses with an asset group: both retries remove the asset group only, no house",
  text(assetBuilds[2].toRemove) == "50" and text(assetBuilds[3].toRemove) == "50", text(assetBuilds[2].toRemove) .. " / " .. text(assetBuilds[3].toRemove))
check("lot houses with an asset group: only the last retry forces, as without houses",
  assetBuilds[1].force == false and assetBuilds[2].force == false and assetBuilds[3].force == true)
check("lot houses with an asset group: no house is looked up and no line names a lot house",
  #lotsWithAssets.lotHouseCalls == 0 and #lotsWithAssets.lotQueries == 0 and linesWith(lotsWithAssets, "lot houses") == 0
  and linesWith(lotsWithAssets, "1 asset groups in the way put in toRemove", "(retry 1)") == 1)
local assetsOff = lotPress({ option = 1, assetGroups = { [50] = true } })
local sameBuilds = #assetsOff.builds == #lotsWithAssets.builds
for i = 1, math.min(#assetsOff.builds, #lotsWithAssets.builds) do
  local off, on = assetsOff.builds[i], lotsWithAssets.builds[i]
  sameBuilds = sameBuilds and off.edge == on.edge and off.force == on.force and text(off.toRemove) == text(on.toRemove)
end
check("lot houses with an asset group: the builds with the option On equal the builds with the option Off", sameBuilds)
local assetsGone = lotPress({ assetGroups = { [50] = true }, missingEntities = { [50] = true } })
check("lot houses with an asset group that is gone: a recorded asset-group road still gets no house",
  #assetsGone.lotHouseCalls == 0 and withRemovalList(assetsGone) == 0)

local lotsOff = lotPress({ option = 1 })
do
  local onBuilds, offBuilds = buildsOf(lots, 1), buildsOf(lotsOff, 1)
  local sameRemovals = #onBuilds == #offBuilds
  for i = 1, math.min(#onBuilds, #offBuilds) do
    sameRemovals = sameRemovals and text(onBuilds[i].toRemove) == text(offBuilds[i].toRemove) and onBuilds[i].force == offBuilds[i].force
  end
  check("lot houses, option Off: the first retry puts the houses in the removal list as with the option On, the station is left out",
    #offBuilds == 3 and text(offBuilds[2].toRemove) == "101, 102" and #offBuilds[1].toRemove == 0 and #offBuilds[3].toRemove == 0
    and withRemovalList(lotsOff) == 1 and sameRemovals, text(offBuilds[2] and offBuilds[2].toRemove or {}))
  check("lot houses, option Off: the octree is asked once around road 1 with the query of the option On, the constructions and the houses are read",
    #lotsOff.lotQueries == 1 and lotsOff.lotQueries[1].center.x == 5 and lotsOff.lotQueries[1].center.y == 0 and lotsOff.lotQueries[1].radius == 35
    and #lotsOff.lotHouseCalls == 1 and readsOf(lotsOff, "CONSTRUCTION") == 3 and readsOf(lotsOff, "entityExists") == 2, text(lotsOff.allReads))
  check("lot houses, option Off: the commands equal those of the option On, the lines equal them once the tags are removed, no probe line",
    sameLines(lotsOff.commands, lots.commands) and sameLines(lotsOff.lines, stripTags(lots.lines)) and #lotsOff.probeLines == 0)
  check("lot houses, option Off: the line of the first retry carries the text of the probe and the put-in count, no line is tagged",
    linesWith(lotsOff, "2 lot houses within 30 m of the road: [101, 102]", "(retry 1)") == 1 and linesWith(lotsOff, "; 2 lot houses put in toRemove", "(retry 1)") == 1
    and count(lotsOff.lines, function(l) return l:sub(1, 1) == "[" end) == 0)
  check("lot houses, option Off: no parcel is ever read and the result equals that of the option On",
    #lotsOff.parcelReads == 0 and sameOutcome(lotsOff, lots))
end

local lotsNoRemoval = lotPress({ removeBuildings = false })
check("lot houses, remove buildings off: no retry gets a removal list and nothing is read",
  withRemovalList(lotsNoRemoval) == 0 and #lotsNoRemoval.lotQueries == 0 and #lotsNoRemoval.lotHouseCalls == 0 and linesWith(lotsNoRemoval, "lot houses") == 0)

local lotsNone = lotPress({ lotFound = {} })
check("lot houses: when no house is found no removal list is built and the line of the first retry says so",
  withRemovalList(lotsNone) == 0 and #lotsNone.lotQueries == 1 and linesWith(lotsNone, "put in toRemove") == 0
  and linesWith(lotsNone, "0 lot houses within 30 m", "(retry 1)") == 1)

local lotsBroken = lotPress({ throwInProbe = "lotHouses" })
check("lot houses: a failing read leaves the retries without houses and the commit unharmed",
  withRemovalList(lotsBroken) == 0 and #buildsOf(lotsBroken, 1) == 3 and lotsBroken.result.removed == 1
  and linesWith(lotsBroken, "lot house read failed", "(retry 1)") == 1 and linesWith(lotsBroken, "put in toRemove") == 0)
local lotsBrokenOff = lotPress({ option = 1, throwInProbe = "lotHouses" })
check("lot houses, option Off: a failing read leaves the retries without houses and the commit unharmed, as with the option On",
  withRemovalList(lotsBrokenOff) == 0 and #buildsOf(lotsBrokenOff, 1) == 3 and lotsBrokenOff.result.removed == 1
  and linesWith(lotsBrokenOff, "lot house read failed", "(retry 1)") == 1 and sameLines(lotsBrokenOff.lines, stripTags(lotsBroken.lines)))

-- A house that is gone is never put in the removal list
local lotsOneGone = lotPress({ missingEntities = { [101] = true } })
check("lot houses: a house that no longer exists is dropped from the removal list",
  text(buildsOf(lotsOneGone, 1)[2].toRemove) == "102" and linesWith(lotsOneGone, "1 lot houses put in toRemove", "(retry 1)") == 1)
check("lot houses: the houses are checked with entityExists", readsOf(lots, "entityExists") == 2 and readsOf(lotsOneGone, "entityExists") == 2,
  readsOf(lots, "entityExists"))
local lotsAllGone = lotPress({ missingEntities = { [101] = true, [102] = true } })
check("lot houses: when every house is gone the first retry has no removal list and no put-in text",
  withRemovalList(lotsAllGone) == 0 and linesWith(lotsAllGone, "put in toRemove") == 0)
-- Roads 1 and 2 both fail once. The first retry of road 1 removes the two houses that both roads share.
local shared = lotPress({ failCommandFor = { [1] = 1, [2] = 1 } })
check("lot houses: both roads are upgraded by their first retry", shared.result.removed == 2 and #shared.result.failed == 0 and #buildsOf(shared, 1) == 2 and #buildsOf(shared, 2) == 2)
check("lot houses: the first retry of road 1 removes the shared houses", text(buildsOf(shared, 1)[2].toRemove) == "101, 102", text(buildsOf(shared, 1)[2].toRemove))
check("lot houses: a house that an earlier road of the press removed is not put in the removal list of the next road",
  #buildsOf(shared, 2)[2].toRemove == 0 and linesWith(shared, "lot houses put in toRemove") == 1 and #shared.lotQueries == 2, text(buildsOf(shared, 2)[2].toRemove))

-- Characterization: when every road of the first pass fails before its command, the first retry starts inside the callback
-- of the pause command, and so does the read of the houses.
local inCallback = lotPress({ edges = { 1 }, failCommandFor = {}, failProposalFor = { [1] = 1 } })
check("lot houses in a callback: the first retry runs inside the callback of the pause command and reads the houses there",
  #inCallback.lotHouseCalls == 1 and inCallback.lotHouseCalls[1].inCallback == true
  and readsOf({ allReads = inCallback.callbackReads }, "octree") == 1 and readsOf({ allReads = inCallback.callbackReads }, "CONSTRUCTION 101") == 1,
  text(inCallback.callbackReads))
check("lot houses in a callback: the road is upgraded by that retry with the houses in the removal list",
  inCallback.result.removed == 1 and #inCallback.builds == 1 and text(inCallback.builds[1].toRemove) == "101, 102" and text(inCallback.commands) == "speed, build, speed",
  text(inCallback.commands))
local inCallbackOff = lotPress({ option = 1, edges = { 1 }, failCommandFor = {}, failProposalFor = { [1] = 1 } })
check("lot houses in a callback, option Off: the same retry runs in the same callback with the same houses in the removal list",
  #inCallbackOff.lotHouseCalls == 1 and inCallbackOff.lotHouseCalls[1].inCallback == true and inCallbackOff.result.removed == 1
  and text(inCallbackOff.builds[1].toRemove) == "101, 102" and sameLines(inCallbackOff.commands, inCallback.commands))

-- Spike C: two neighbours that failed together are sent as ONE proposal at the first retry
local PAIR_NODES = { [1] = { 10, 11 }, [2] = { 11, 12 } }
local PAIR_OFFSETS = { [1] = 0, [2] = 100 }
local HOUSES_AT = { [5] = { 101, 102 }, [105] = { 102, 104 } }
local PAIR_CONSTRUCTIONS = { [101] = HOUSE, [102] = HOUSE, [104] = HOUSE }
local MARKER = "pair spike: sending ONE proposal for edges 1 and 2 (a merged proposal can crash the game)"
local function pairPress(fields)
  local options = { option = 2, edges = { 1, 2 }, failCommandFor = { [1] = 1, [2] = 1 }, removeBuildings = true, assetGroups = {},
    constructions = PAIR_CONSTRUCTIONS, lotFound = function(center) return HOUSES_AT[center.x] or {} end,
    edgeNodes = PAIR_NODES, roadOffsets = PAIR_OFFSETS, nodeConfigs = true }
  for key, value in pairs(fields or {}) do options[key] = value end
  return press(options)
end
local function callsOf(run, what) return count(run.pairCalls, function(c) return c.what == what end) end
local function partnersFound(run) return count(run.pairCalls, function(c) return c.what == "partner" and c.partner ~= nil end) end

local pairRun = pairPress()
local pairFailedProbe = pairPress({ failCommandFor = { [1] = true, [2] = 1 } })
local pairBuilds1, pairBuilds2 = buildsOf(pairRun, 1), buildsOf(pairRun, 2)
local pairBuild = pairBuilds1[2]
check("pair: the first retry sends one command for both roads and the partner sends none of its own",
  #pairBuilds1 == 2 and #pairBuilds2 == 1 and #pairRun.builds == 3, #pairRun.builds)
check("pair: that command removes both segments and adds both new ones", pairBuild ~= nil and text(pairBuild.removedSegments) == "1, 2" and pairBuild.addedSegments == 2,
  pairBuild and text(pairBuild.removedSegments))
check("pair: its removal list is empty, the game gathers the buildings", pairBuild ~= nil and #pairBuild.toRemove == 0, pairBuild and text(pairBuild.toRemove))
check("pair: no house lookup at all, no octree query for constructions, no construction read, no entityExists",
  #pairRun.lotHouseCalls == 0 and #pairRun.lotQueries == 0 and readsOf(pairRun, "CONSTRUCTION") == 0 and readsOf(pairRun, "entityExists") == 0)
check("pair: the marker line is the last line before the command", pairBuild ~= nil and contains(pairRun.lines[pairBuild.linesBefore], MARKER),
  pairBuild and pairRun.lines[pairBuild.linesBefore])
check("pair: the line of the command carries the merge text and says that no lot house is put in toRemove, and it names no house",
  linesWith(pairRun, "added segments 1+1=2", "(retry 1)") == 1
  and linesWith(pairRun, "no lot houses put in toRemove (the game gathers the buildings)", "(retry 1)") == 1
  and count(pairRun.lines, function(l) return contains(l, "lot houses within") or l:find("%d lot houses put in toRemove") ~= nil end) == 0)
check("pair: nothing is forced", pairBuild ~= nil and pairBuild.force == false)
local configsOf = {}
for _, c in ipairs(pairBuild and pairBuild.configs or {}) do configsOf[c.entity] = c end
check("pair: both proposals hold a config for the shared node, the command carries one, reset to the default routes",
  pairBuild ~= nil and #pairBuild.configs == 3 and configsOf[11] ~= nil and configsOf[11].connections == 0, pairBuild and #pairBuild.configs)
check("pair: the config of the shared node in the combined command has no crosswalks, a follow-up command adds them",
  configsOf[11] ~= nil and configsOf[11].crosswalks == 0 and #configsOf[11].crosswalkIds == 0)
check("pair: the configs of the other end nodes are kept, the ids of the second road follow the renumbering of its new segment",
  configsOf[10] ~= nil and configsOf[10].connections == 1 and configsOf[10].segment0 == -1 and configsOf[12] ~= nil and configsOf[12].connections == 1
  and configsOf[12].segment0 == -2, configsOf[12] and configsOf[12].segment0)
check("pair: the merge text says that the config of the shared node was reset",
  linesWith(pairRun, "node config of node 11 reset to the default routes; crosswalks are added by a follow-up command", "(retry 1)") == 1)
check("pair: without a remembered node no follow-up command is sent", #pairRun.crosswalkCommands == 0 and linesWith(pairRun, "crosswalks:") == 0)
check("pair: both roads count as upgraded exactly once", pairRun.result.removed == 2 and #pairRun.result.failed == 0 and pairRun.result.commands == 3,
  tostring(pairRun.result.removed) .. "/" .. tostring(pairRun.result.commands))
check("pair: both roads count as recovered by the retry", linesWith(pairRun, "2 recovered by the retry") == 1)
check("pair: the partner is reported as done once, and as failed once before", count(pairRun.roadCalls, function(c) return c.e == 2 and c.ok == true end) == 1
  and count(pairRun.roadCalls, function(c) return c.e == 2 and c.ok == false end) == 1)
check("pair: the first retry reads the neighbour before the command, outside a callback",
  callsOf(pairRun, "partner") == 1 and callsOf(pairRun, "merge") == 1 and pairRun.pairCalls[1].inCallback == false)
check("pair: no parcel is read", #pairRun.parcelReads == 0)
check("pair: the probe logs the road after the command for the neighbour too, at the attempt of the pair",
  count(pairRun.probeLines, function(l) return contains(l, "edge 1 attempt 1 after") end) == 1
  and count(pairRun.probeLines, function(l) return contains(l, "edge 2 attempt 1 after") end) == 1)
check("pair failed: the neighbour gets its after line from its own command only",
  count(pairFailedProbe.probeLines, function(l) return contains(l, "edge 2 attempt 1 after") end) == 1)

local pairFailed = pairPress({ failCommandFor = { [1] = true, [2] = 1 } })
local failedBuilds1, failedBuilds2 = buildsOf(pairFailed, 1), buildsOf(pairFailed, 2)
check("pair failed: road 1 is sent in the pair with an empty removal list and again alone in the second retry", #failedBuilds1 == 3 and text(failedBuilds1[2].removedSegments) == "1, 2"
  and #failedBuilds1[2].toRemove == 0 and text(failedBuilds1[3].removedSegments) == "1" and #failedBuilds1[3].toRemove == 0, #failedBuilds1)
check("pair failed: the partner is tried in its own turn, alone, with its own houses",
  #failedBuilds2 == 2 and text(failedBuilds2[2].removedSegments) == "2" and text(failedBuilds2[2].toRemove) == "102, 104", #failedBuilds2)
check("pair failed: only road 1 fails, the partner is upgraded", pairFailed.result.removed == 1 and #pairFailed.result.failed == 1 and pairFailed.result.failed[1] == 1)
check("pair failed: the pair is tried once, the partner looks for no neighbour", partnersFound(pairFailed) == 1 and callsOf(pairFailed, "merge") == 1 and callsOf(pairFailed, "partner") == 1)
check("pair failed: the failed command is logged with the failure tag", linesWith(pairFailed, "[failure] cmd", "(retry 1)") >= 1)

local pairAlone = pairPress({ edgeNodes = {} })
local aloneBuilds1 = buildsOf(pairAlone, 1)
check("no neighbour: the retry is the single-road retry of today", #aloneBuilds1 == 2 and text(aloneBuilds1[2].removedSegments) == "1" and text(aloneBuilds1[2].toRemove) == "101, 102"
  and callsOf(pairAlone, "merge") == 0 and linesWith(pairAlone, "pair spike") == 0)
check("no neighbour: both roads are upgraded by their own retries", pairAlone.result.removed == 2 and #buildsOf(pairAlone, 2) == 2)

local offPair = pairPress({ option = 1 })
local offPairInert = pairPress({ option = 1, inertProbe = true })
local offBuild = buildsOf(offPair, 1)[2]
check("pair, option Off: the same pair runs: one combined command for both roads, the partner sends none, the same commands as with the option On",
  callsOf(offPair, "partner") == 1 and callsOf(offPair, "merge") == 1 and #offPair.builds == 3 and #buildsOf(offPair, 2) == 1
  and offBuild ~= nil and text(offBuild.removedSegments) == "1, 2" and offBuild.addedSegments == 2 and sameLines(offPair.commands, pairRun.commands),
  #offPair.builds)
check("pair, option Off: the removal list of the combined command is empty and nothing is forced, no house lookup",
  offBuild ~= nil and #offBuild.toRemove == 0 and offBuild.force == false and withRemovalList(offPair) == 0 and #offPair.lotHouseCalls == 0 and #offPair.lotQueries == 0)
check("pair, option Off: both roads count as upgraded once, as with the option On",
  offPair.result.removed == 2 and #offPair.result.failed == 0 and offPair.result.commands == 3 and sameOutcome(offPair, pairRun)
  and count(offPair.roadCalls, function(c) return c.e == 2 and c.ok == true end) == 1)
check("pair, option Off: the lines equal those with the option On once the tags are removed, with the marker and the merge text, no probe line",
  sameLines(offPair.lines, stripTags(pairRun.lines)) and linesWith(offPair, MARKER) == 1 and linesWith(offPair, "added segments 1+1=2", "(retry 1)") == 1
  and linesWith(offPair, "no lot houses put in toRemove (the game gathers the buildings)", "(retry 1)") == 1 and #offPair.probeLines == 0
  and count(offPair.lines, function(l) return l:sub(1, 1) == "[" end) == 0)
check("pair, option Off: the probe adds no read but the read of the option",
  count(onlyIn(offPair.allReads, offPairInert.allReads), function(r) return r ~= READ_OF_THE_OPTION end) == 0 and #onlyIn(offPairInert.allReads, offPair.allReads) == 0
  and sameLines(offPair.lines, offPairInert.lines) and sameLines(offPair.callbackReads, offPairInert.callbackReads))
local offPairFailed = pairPress({ option = 1, failCommandFor = { [1] = true, [2] = 1 } })
check("pair failed, option Off: road 1 is sent in the pair and alone again, the partner is tried alone with its own houses, as with the option On",
  sameLines(offPairFailed.commands, pairFailed.commands) and sameLines(offPairFailed.lines, stripTags(pairFailed.lines))
  and text(buildsOf(offPairFailed, 2)[2].toRemove) == "102, 104" and #buildsOf(offPairFailed, 1)[2].toRemove == 0 and offPairFailed.result.removed == 1)

local pairNoRemoval = pairPress({ removeBuildings = false })
check("pair, remove buildings off: nothing runs", #pairNoRemoval.pairCalls == 0 and withRemovalList(pairNoRemoval) == 0 and linesWith(pairNoRemoval, "pair spike") == 0)

local pairAssets = pairPress({ assetGroups = { [50] = true } })
check("pair, asset groups: a road that only asset groups block never pairs", #pairAssets.pairCalls == 0 and linesWith(pairAssets, "pair spike") == 0
  and text(buildsOf(pairAssets, 1)[2].toRemove) == "50" and #buildsOf(pairAssets, 2)[2].toRemove == 0)
check("pair, asset groups: the builds with the option On equal those with the option Off",
  (function()
    local off = pairPress({ option = 1, assetGroups = { [50] = true } })
    local same = #off.builds == #pairAssets.builds
    for i = 1, math.min(#off.builds, #pairAssets.builds) do
      same = same and off.builds[i].edge == pairAssets.builds[i].edge and off.builds[i].force == pairAssets.builds[i].force
        and text(off.builds[i].toRemove) == text(pairAssets.builds[i].toRemove) and text(off.builds[i].removedSegments) == text(pairAssets.builds[i].removedSegments)
    end
    return same
  end)())

local pairBroken = pairPress({ noStreetOnCall = { [2] = 2 } })
local brokenBuilds1 = buildsOf(pairBroken, 1)
check("pair, error: the merge failure is logged, no marker is written, the road is retried alone with its houses",
  linesWith(pairBroken, "pair spike: building the pair for edges 1 and 2 failed") == 1 and linesWith(pairBroken, "a proposal has no street data") == 1
  and linesWith(pairBroken, MARKER) == 0 and #brokenBuilds1 == 2 and text(brokenBuilds1[2].removedSegments) == "1" and text(brokenBuilds1[2].toRemove) == "101, 102")
check("pair, error: the partner is retried alone in its own turn, both roads are upgraded", pairBroken.result.removed == 2 and #buildsOf(pairBroken, 2) == 2
  and text(buildsOf(pairBroken, 2)[2].toRemove) == "104")

-- Several neighbours: the next candidate is tried at once when a pair command fails
local CHAIN_NODES = { [1] = { 10, 11 }, [2] = { 11, 12 }, [3] = { 10, 13 } }
local CHAIN_OFFSETS = { [1] = 0, [2] = 100, [3] = 200 }
local CHAIN_HOUSES = { [5] = { 101 }, [105] = { 102 }, [205] = { 104 } }
local function chainPress(fields)
  local options = { edges = { 1, 2, 3 }, edgeNodes = CHAIN_NODES, roadOffsets = CHAIN_OFFSETS, failCommandFor = { [1] = 2, [2] = 1, [3] = 1 },
    lotFound = function(center) return CHAIN_HOUSES[center.x] or {} end }
  for key, value in pairs(fields or {}) do options[key] = value end
  return pairPress(options)
end
local function markers(run, text) return linesWith(run, "pair spike: sending ONE proposal for edges " .. text) end

local chain = chainPress()
local chain1 = buildsOf(chain, 1)
check("candidates: the first pair fails, the second neighbour is tried at once for the same road",
  #chain1 == 3 and text(chain1[2].removedSegments) == "1, 2" and text(chain1[3].removedSegments) == "1, 3", #chain1)
check("candidates: each pair gets its marker line, the second one directly before its command",
  markers(chain, "1 and 2 ") == 1 and markers(chain, "1 and 3 ") == 1 and contains(chain.lines[chain1[3].linesBefore], "edges 1 and 3"))
check("candidates: the second pair succeeds, the road and its second neighbour count once, the first neighbour is retried on its own",
  chain.result.removed == 3 and #chain.result.failed == 0 and #buildsOf(chain, 3) == 1 and #buildsOf(chain, 2) == 2 and chain.result.commands == 6, chain.result.commands)
check("candidates: the failed pair command does not count the road as failed for this pass",
  count(chain.roadCalls, function(c) return c.e == 1 and c.ok == false end) == 1 and count(chain.roadCalls, function(c) return c.e == 1 and c.ok == true end) == 1
  and count(chain.roadCalls, function(c) return c.e == 3 and c.ok == true end) == 1)
check("candidates: the first neighbour is not paired again with the road, it takes its own retry",
  text(buildsOf(chain, 2)[2].removedSegments) == "2" and callsOf(chain, "merge") == 2)
check("candidates: the failed pair command is logged with the failure tag", linesWith(chain, "[failure] cmd", "(retry 1): edge 1 -> FAILED") == 1)
check("candidates: the commands are the pass, two pair commands and the own retry of the first neighbour",
  text(chain.commands) == "speed, build, build, build, build, build, build, speed", text(chain.commands))

local chainFails = chainPress({ failCommandFor = { [1] = true, [2] = 1, [3] = 1 } })
local failing1 = buildsOf(chainFails, 1)
check("candidates: when every pair fails the road fails for this pass as today, and takes its single retry in the second retry",
  #failing1 == 4 and text(failing1[2].removedSegments) == "1, 2" and text(failing1[3].removedSegments) == "1, 3" and text(failing1[4].removedSegments) == "1"
  and chainFails.result.removed == 2 and #chainFails.result.failed == 1 and chainFails.result.failed[1] == 1, #failing1)
check("candidates: no pair is tried twice, the neighbours take their own retries",
  callsOf(chainFails, "merge") == 2 and #buildsOf(chainFails, 2) == 2 and #buildsOf(chainFails, 3) == 2 and markers(chainFails, "1 and ") == 2)
check("candidates: only the final failure of the road is reported as failed", count(chainFails.roadCalls, function(c) return c.e == 1 and c.ok == false end) == 3)
local chainOff = chainPress({ option = 1 })
check("candidates, option Off: the same pairs are tried in the same order, the commands and the lines equal those of the option On",
  callsOf(chainOff, "merge") == 2 and markers(chainOff, "1 and 2 ") == 1 and markers(chainOff, "1 and 3 ") == 1 and sameLines(chainOff.commands, chain.commands)
  and sameLines(chainOff.lines, stripTags(chain.lines)) and chainOff.result.removed == 3 and #chainOff.result.failed == 0)

-- The crosswalk pass: every junction that an upgraded road touched gets crosswalks on every street, after the last retry pass
do
  local function junctionPress(fields)
    local options = { roadLanes = PLAIN_LANES, templateLanes = PLAIN_LANES,
      nodeSegments = { [10] = { 1, 30, 31 }, [11] = { 1, 2, 30 }, [12] = { 2, 32, 33 } },
      nodePositions = { [10] = { x = 40, y = 60, z = 0 }, [11] = { x = 50, y = 60, z = 0 }, [12] = { x = 60, y = 60, z = 0 } },
      nodeCrosswalks = { [10] = {}, [11] = {}, [12] = {} } }
    for key, value in pairs(fields or {}) do options[key] = value end
    return pairPress(options)
  end
  local function nodesOf(run) local out = {}; for i, c in ipairs(run.crosswalkCommands) do out[i] = c.node end; return table.concat(out, ",") end
  local function indexOfLine(run, part) for i, l in ipairs(run.lines) do if contains(l, part) then return i end end end

  local pass = junctionPress()
  check("pass: a pair touches its three nodes, one command each, after the last retry pass and before the speed is set back",
    text(pass.commands) == "speed, build, build, build, crosswalk, crosswalk, crosswalk, speed" and nodesOf(pass) == "10,11,12", text(pass.commands))
  check("pass: every command carries a crosswalk on every street of its node",
    text(pass.crosswalkCommands[1].crosswalks) == "1, 30, 31" and text(pass.crosswalkCommands[2].crosswalks) == "1, 2, 30" and text(pass.crosswalkCommands[3].crosswalks) == "2, 32, 33")
  check("pass: the settle time passes between the last road command and the first crosswalk command",
    pass.crosswalkCommands[1].clock - pass.builds[#pass.builds].clock >= 2.0, tostring(pass.crosswalkCommands[1].clock - pass.builds[#pass.builds].clock))
  check("pass: every command is built after the roads, outside a command callback", #pass.crosswalkBuilds == 3 and pass.crosswalkBuilds[1].inCallback == false
    and pass.crosswalkBuilds[1].commandsBefore == 4)
  check("pass: the result and the counts are those of the roads alone", pass.result.removed == 2 and #pass.result.failed == 0 and pass.result.commands == 3 and pass.doneCalls == 1)
  check("pass: the log has the final line of each node and the summary, before the line that ends the press",
    linesWith(pass, "crosswalks: node 10: complete after 1 sends (3 streets)") == 1 and linesWith(pass, "crosswalks: pass done: 3 junctions touched, 3 complete, 0 incomplete, 0 skipped") == 1
    and indexOfLine(pass, "crosswalks: pass done") < indexOfLine(pass, "upgrade done"))
  check("pass: a complete node logs its read back summary and no street lines", linesWith(pass, "crosswalks: node 11: read back 3 crosswalks [1, 2, 30]") == 1
    and linesWith(pass, "crosswalks: node 11: street ") == 0)
  check("pass: nothing is read inside a command callback", count(pass.callbackReads, function(r) return contains(r, "BASE_NODE") end) == 0, text(pass.callbackReads))
  check("pass: the lines of the pass are progress for the tool, so that it does not give up waiting during a long pass",
    count(pass.roadCalls, function(c) return c.e == nil end) >= 3 + 1, count(pass.roadCalls, function(c) return c.e == nil end))

  local single = junctionPress({ edges = { 1 }, failCommandFor = {} })
  check("pass: a single-road upgrade touches both of its end nodes", nodesOf(single) == "10,11" and single.result.removed == 1, nodesOf(single))
  local failedRoad = junctionPress({ edges = { 1 }, failCommandFor = { [1] = true } })
  check("pass: a road that failed touches nothing, no wait and no line", #failedRoad.crosswalkCommands == 0 and linesWith(failedRoad, "crosswalks:") == 0 and #failedRoad.result.failed == 1)
  local mixed = junctionPress({ edges = { 1, 2 }, edgeNodes = { [1] = { 10, 11 }, [2] = { 12, 13 } }, failCommandFor = { [1] = true } })
  check("pass: only the nodes of the roads that were upgraded are touched", nodesOf(mixed) == "12" and mixed.result.removed == 1, nodesOf(mixed) .. " " .. tostring(mixed.result.removed))

  local bend = junctionPress({ nodeSegments = { [10] = { 1, 30 }, [11] = { 1, 2, 30 }, [12] = { 2, 32, 33 } } })
  check("pass: a node with fewer than 3 streets is skipped with the reason, nothing is sent for it",
    nodesOf(bend) == "11,12" and linesWith(bend, "crosswalks: node 10: not_a_junction (2 streets)") == 1
    and linesWith(bend, "crosswalks: pass done: 3 junctions touched, 2 complete, 0 incomplete, 1 skipped") == 1)

  local flat = junctionPress({ nodeSegments = { [10] = { 1, 30 }, [11] = { 1, 2 }, [12] = { 2, 32 } } })
  check("pass: when no touched node has 3 streets nothing is sent, one line says the pass is skipped, and there is no start line and no summary",
    #flat.crosswalkCommands == 0 and linesWith(flat, "crosswalks: pass skipped, none of the 3 touched nodes is a junction") == 1
    and linesWith(flat, "crosswalks:") == 1, linesWith(flat, "crosswalks:"))
  check("pass: when no touched node has 3 streets the press does not wait for the settle time and ends once with the speed set back",
    flat.doneCalls == 1 and flat.result.removed == 2 and flat.commands[#flat.commands] == "speed" and flat.result.seconds + 2.0 <= pass.result.seconds,
    tostring(flat.result.seconds) .. " vs " .. tostring(pass.result.seconds))

  local dropped = junctionPress({ dropAfterSend = { [11] = 1 } })
  check("pass: when another mod drops the crosswalks of a node the node gets a new command in the next round, after the settle time",
    nodesOf(dropped) == "10,11,12,11" and linesWith(dropped, "crosswalks: node 11: complete after 2 sends (3 streets)") == 1
    and dropped.crosswalkCommands[4].clock - dropped.crosswalkCommands[3].clock >= 3.0 and dropped.result.removed == 2)
  local neverDone = junctionPress({ dropAfterSend = { [11] = 9 } })
  check("pass: at most three commands for a node, then the INCOMPLETE line with the missing streets, and the press result is unchanged",
    nodesOf(neverDone) == "10,11,12,11,11" and linesWith(neverDone, "crosswalks: node 11: INCOMPLETE after 3 sends, missing streets [1, 2, 30]") == 1
    and linesWith(neverDone, "crosswalks: node 11: street 30 template old_template defaultWithCrosswalk false in list ") >= 1
    and linesWith(neverDone, "crosswalks: pass done: 3 junctions touched, 2 complete, 1 incomplete, 0 skipped") == 1 and neverDone.result.removed == 2
    and #neverDone.result.failed == 0 and neverDone.doneCalls == 1)

  local refusedFirst = junctionPress({ failCrosswalk = 1 })
  check("pass: a refused all-streets command falls back to one command for the streets with a pedestrian lane",
    #refusedFirst.crosswalkCommands == 4 and refusedFirst.crosswalkCommands[1].node == 10 and refusedFirst.crosswalkCommands[2].node == 10
    and linesWith(refusedFirst, "crosswalks: node 10: sidewalk streets only: 3 added") == 1 and refusedFirst.result.removed == 2)

  local moved = junctionPress({ nodeReplaced = { [11] = 111 } })
  check("pass: a node that another mod replaced after the pair command is found by its position", nodesOf(moved) == "10,111,12", nodesOf(moved))

  local cancelled = junctionPress({ cancelDuringCrosswalk = true })
  check("pass: a cancel during the pass stops it, the press ends once and the speed is set back",
    #cancelled.crosswalkCommands == 1 and cancelled.doneCalls == 1 and cancelled.result.cancelled == true and cancelled.commands[#cancelled.commands] == "speed", #cancelled.crosswalkCommands)

  local hidden = junctionPress({ hideConfigAfter = "nil" })
  check("pass: a config that cannot be read changes nothing in the result and does not stop the press",
    hidden.result.removed == 2 and #hidden.result.failed == 0 and hidden.doneCalls == 1 and hidden.commands[#hidden.commands] == "speed"
    and linesWith(hidden, "crosswalks: pass done:") == 1)

  local offWith = junctionPress({ option = 1 })
  local offInert = junctionPress({ option = 1, inertProbe = true })
  check("pass, option Off: the pass runs as with the option On: one command per node, the same commands, the same result",
    nodesOf(offWith) == "10,11,12" and sameLines(offWith.commands, pass.commands) and sameOutcome(offWith, pass)
    and text(offWith.crosswalkCommands[1].crosswalks) == "1, 30, 31" and text(offWith.crosswalkCommands[3].crosswalks) == "2, 32, 33")
  check("pass, option Off: the lines equal those with the option On once the tags are removed, with the summary before the end of the press, no probe line",
    sameLines(offWith.lines, stripTags(pass.lines)) and linesWith(offWith, "crosswalks: pass done: 3 junctions touched, 3 complete, 0 incomplete, 0 skipped") == 1
    and indexOfLine(offWith, "crosswalks: pass done") < indexOfLine(offWith, "upgrade done") and #offWith.probeLines == 0
    and count(offWith.lines, function(l) return l:sub(1, 1) == "[" end) == 0)
  check("pass, option Off: the probe adds no read but the read of the option, and nothing is read inside a command callback",
    count(onlyIn(offWith.allReads, offInert.allReads), function(r) return r ~= READ_OF_THE_OPTION end) == 0 and #onlyIn(offInert.allReads, offWith.allReads) == 0
    and sameLines(offWith.callbackReads, offInert.callbackReads) and count(offWith.callbackReads, function(r) return contains(r, "BASE_NODE") end) == 0)
  local noPositions = junctionPress({ nodePositions = {} })
  check("pass: nodes without a readable position are not touched, the press runs as before", #noPositions.crosswalkCommands == 0 and noPositions.result.removed == 2
    and linesWith(noPositions, "crosswalks:") == 0)
end

-- Characterization: when both roads fail before their command, the first retry runs inside the callback of the pause command
local pairInCallback = pairPress({ failCommandFor = {}, failProposalFor = { [1] = 1, [2] = 1 } })
check("pair in a callback: the pair is built inside the callback of the pause command", callsOf(pairInCallback, "partner") == 1
  and pairInCallback.pairCalls[1].inCallback == true and callsOf(pairInCallback, "merge") == 1 and pairInCallback.pairCalls[2].inCallback == true,
  #pairInCallback.pairCalls)
check("pair in a callback: one command upgrades both roads", pairInCallback.result.removed == 2 and #pairInCallback.builds == 1
  and text(pairInCallback.builds[1].removedSegments) == "1, 2" and text(pairInCallback.commands) == "speed, build, speed", text(pairInCallback.commands))

-- An error while the command is prepared or sent fails that road and nothing else
local prepFail = press({ option = 2, edges = { 1, 2 }, failCommandFor = { [1] = true }, removeBuildings = true, throwInEntityExists = true })
local prepFailOff = press({ option = 1, edges = { 1, 2 }, failCommandFor = { [1] = true }, removeBuildings = true, throwInEntityExists = true })
check("error while preparing a retry: road 1 fails with the script error, road 2 is upgraded",
  prepFail.result.removed == 1 and #prepFail.result.failed == 1 and (prepFail.result.reasons["script error"] or 0) >= 1 and prepFail.doneCalls == 1,
  tostring(prepFail.result.removed))
check("error while preparing a retry: the lines and the outcome equal the Off ones", sameLines(stripTags(prepFail.lines), prepFailOff.lines) and sameOutcome(prepFail, prepFailOff))
check("error while preparing a retry: the log says so", count(prepFail.lines, function(l) return contains(l, "[failure] edge 1: preparing the command failed") end) >= 1)
check("error while preparing a retry: the probe shows no added segment for that attempt",
  count(prepFail.probeLines, function(l) return contains(l, "edge 1 attempt 1 before") and contains(l, "none, no proposal was built") end) == 1)
local sendFail = press({ option = 2, edges = { 1, 2 }, throwOnSendFor = { [1] = true } })
local sendFailOff = press({ option = 1, edges = { 1, 2 }, throwOnSendFor = { [1] = true } })
check("error while sending: road 1 fails with the script error, road 2 is upgraded",
  sendFail.result.removed == 1 and #sendFail.result.failed == 1 and (sendFail.result.reasons["script error"] or 0) >= 1 and sendFail.doneCalls == 1)
check("error while sending: the lines and the outcome equal the Off ones", sameLines(stripTags(sendFail.lines), sendFailOff.lines) and sameOutcome(sendFail, sendFailOff))
check("error while sending: the log says so", count(sendFail.lines, function(l) return contains(l, "[failure] send failed") end) >= 1)

-- A cancel between two roads, and during the pause command
local gapCancel = press({ option = 2, edges = { 1, 2 }, cancelAtTick = 2 })
check("cancel between two roads: the press ends once, cancelled, with the speed set back",
  gapCancel.doneCalls == 1 and gapCancel.result.cancelled == true and gapCancel.commands[#gapCancel.commands] == "speed", text(gapCancel.commands))
check("cancel between two roads: a new press is not refused", press({ option = 2, edges = { 1, 2 } }).result.removed == 2)
local pauseCancel = press({ option = 2, edges = { 1, 2 }, cancelBeforePause = true })
check("cancel during the pause command: no build command is sent, the press ends once, cancelled",
  #pauseCancel.builds == 0 and pauseCancel.doneCalls == 1 and pauseCancel.result.cancelled == true, text(pauseCancel.commands))
check("cancel during the pause command: a new press is not refused", press({ option = 2, edges = { 1, 2 } }).result.removed == 2)

-- What a good press reports: the cost, and the progress of each road
check("cost: the costs of both commands are summed", on.result.cost == 200, tostring(on.result.cost))
local progress = {}
for _, call in ipairs(on.roadCalls) do if call.e ~= nil then progress[#progress + 1] = call end end
check("progress: each upgraded road is reported once as done",
  #progress == 2 and progress[1].e == 1 and progress[1].ok == true and progress[1].finished == 1 and progress[1].total == 2
  and progress[2].e == 2 and progress[2].ok == true and progress[2].finished == 2 and progress[2].attempt == 0)
local failedProgress = press({ option = 2, edges = { 1, 2 }, failCommandFor = { [1] = true } })
check("progress: a road whose command fails is reported as not done",
  count(failedProgress.roadCalls, function(call) return call.e == 1 and call.ok == false end) >= 1)

-- Extras: a lock that the game does not take is never sent
local LOCK = { busLane = false, tram = false, catenary = false, lock = "lock" }
local locked = press({ option = 2, edges = { 1, 2 }, extras = LOCK })
local lockedOff = press({ option = 1, edges = { 1, 2 }, extras = LOCK })
check("lock set and read back: both roads upgraded", locked.result.removed == 2 and #locked.builds == 2)
check("lock set and read back: the lines and the outcome equal the Off ones", sameLines(stripTags(locked.lines), lockedOff.lines) and sameOutcome(locked, lockedOff))
local notTaken = press({ option = 2, edges = { 1, 2 }, extras = LOCK, dropLockWrite = true })
check("lock not taken: no build command is sent", #notTaken.builds == 0, text(notTaken.commands))
check("lock not taken: both roads fail with the extras reason", #notTaken.result.failed == 2 and notTaken.result.reasons["bus lane or lock could not be set"] == 2)
local notTakenOff = press({ option = 1, edges = { 1, 2 }, extras = LOCK, dropLockWrite = true })
check("lock not taken: the lines and the outcome equal the Off ones", sameLines(stripTags(notTaken.lines), notTakenOff.lines) and sameOutcome(notTaken, notTakenOff))

-- A read of the probe that throws never changes the result or the lines of the commit
for _, where in ipairs({ "before", "after" }) do
  local thrown = press({ option = 2, edges = { 1, 2 }, throwInProbe = where })
  check("throwing read in " .. where .. ": both roads are still upgraded", thrown.result.removed == 2 and #thrown.result.failed == 0 and thrown.result.commands == off.result.commands)
  check("throwing read in " .. where .. ": the commit lines equal the Off lines once the tags are removed", sameLines(stripTags(thrown.lines), off.lines))
  matches, extra = callbackReadsMatch(thrown, off)
  check("throwing read in " .. where .. ": inside command callbacks the option adds reads of proposal fields only", matches, text(extra))
  check("throwing read in " .. where .. ": the probe says that its read failed, once per road",
    count(thrown.probeLines, function(l) return contains(l, where .. ": read failed") end) == 2,
    table.concat(thrown.probeLines, " | "))
end

-- The hard rules of bb_select decide which roads the commit sends. They run before the send and again before each road.
local function reasonTexts(run) return text(run.lines) end
for _, case in ipairs({
  { "a road of another player", { owner = PLAYER + 1 }, "other player" },
  { "a part of a construction", { parentConstruction = 12 }, "part of a construction" },
  { "a road at an industry", { industryRoad = true }, "industry" },
  { "a road that is gone", { gone = true }, "gone" },
  { "a tram track", { tramOnly = true }, "tram track" },
  { "a track", { isStreet = false, template = "::/infrastructure/track/standard/standard.street_template" }, "filtered" },
  { "a track of another type", { isStreet = false }, "other track type" },
}) do
  local name, fields, reason = case[1], case[2], case[3]
  local run = press({ option = 2, edges = { 1, 2 }, descriptions = { [1] = fields } })
  check("hard rules: " .. name .. " is dropped before send, the other road is upgraded",
    run.result.removed == 1 and #buildsOf(run, 1) == 0 and #buildsOf(run, 2) == 1 and run.result.reasons[reason] == 1 and #run.result.failed == 0,
    text(run.commands) .. " / " .. tostring(run.result.reasons[reason]))
end
local atIndustry = press({ option = 2, edges = { 1, 2 }, industryRoads = { [1] = true } })
check("hard rules: a road in the list of industry roads is dropped", #buildsOf(atIndustry, 1) == 0 and atIndustry.result.reasons["industry"] == 1)
local everyone = press({ option = 2, edges = { 1, 2 }, descriptions = { [1] = { owner = PLAYER + 1 }, [2] = { owner = PLAYER + 1 } } })
check("hard rules: when every road is dropped nothing is sent and the press says so",
  #everyone.builds == 0 and #everyone.commands == 0 and everyone.result.refused == "nothing left to upgrade", tostring(everyone.result.refused))
local turnsForeign = press({ option = 2, edges = { 1, 2 }, descriptions = { [2] = function(call) if call >= 2 then return { owner = PLAYER + 1 } end end } })
check("hard rules: a road whose owner changes before its turn is dropped by the recheck",
  turnsForeign.result.removed == 1 and #buildsOf(turnsForeign, 2) == 0 and turnsForeign.result.reasons["other player"] == 1
  and count(turnsForeign.lines, function(l) return contains(l, "hard-rule recheck (before send) dropped 1") end) == 1, reasonTexts(turnsForeign))

local manyEdges = {}
for i = 1, upgrade.MAX_COMMANDS + 1 do manyEdges[i] = i end
local capped = press({ option = 1, edges = manyEdges })
check("command cap: only MAX_COMMANDS roads are sent, the rest is skipped with its reason",
  capped.result ~= nil and #capped.builds == upgrade.MAX_COMMANDS and capped.result.reasons["command limit reached"] == 1,
  capped.result and tostring(capped.result.reasons["command limit reached"]))

local twice = press({ option = 2, edges = { 1, 2 }, secondCommit = true })
check("second commit while one runs: it is refused and all its roads count as failed",
  twice.second ~= nil and twice.second.refused == "previous upgrade still running" and #twice.second.failed == 2 and twice.second.removed == 0)
check("second commit while one runs: the first commit finishes normally", twice.result.removed == 2 and #twice.builds == 2 and twice.doneCalls == 1)

local noTemplate = press({ option = 2, edges = { 1, 2 }, noTemplate = true })
check("no template and no rail target: the press is refused, nothing is sent", noTemplate.result.refused == "no valid road type" and #noTemplate.commands == 0)

local alreadyTarget = press({ option = 2, edges = { 1, 2 }, template = "old_template" })
check("roads that already have the template are counted unchanged and nothing is sent",
  alreadyTarget.result.unchanged == 2 and alreadyTarget.result.removed == 0 and #alreadyTarget.commands == 0, text(alreadyTarget.commands))

-- The bus lane, tram track and catenary edit of the lanes
local function lanesOf(run, edge) return lanesText(run.proposalComps[edge].laneConfigs) end
local function lanePress(extras, more)
  local options = { option = 2, edges = { 1, 2 }, extras = extras, roadLanes = PLAIN_LANES, proposalLanes = PLAIN_LANES, templateLanes = PLAIN_LANES }
  for key, value in pairs(more or {}) do options[key] = value end
  return press(options)
end
local function extrasOf(fields)
  local extras = { busLane = false, tram = false, catenary = false, lock = "keep" }
  for key, value in pairs(fields) do extras[key] = value end
  return extras
end
local BUS_TRAM_LAYOUT = {
  { MODE.PERSON }, { MODE.BUS, MODE.TRUCK, MODE.TRAM }, { MODE.CAR, MODE.BUS, MODE.TRUCK }, { MODE.BUS, MODE.TRUCK, MODE.TRAM }, { MODE.PERSON },
}
for _, case in ipairs({
  { "bus lane", { busLane = true }, BUS_LANES },
  { "tram track", { tram = true }, TRAM_LANES },
  { "tram track with catenary", { tram = true, catenary = true }, CATENARY_LANES },
  { "bus lane and tram track", { busLane = true, tram = true }, BUS_TRAM_LAYOUT },
}) do
  local name, fields, layout = case[1], case[2], case[3]
  local run = lanePress(extrasOf(fields))
  check(name .. ": both roads are upgraded", run.result.removed == 2 and #run.result.failed == 0 and #run.builds == 2)
  check(name .. ": only the outer vehicle lanes change, the inner lane and the sidewalks stay",
    lanesOf(run, 1) == layoutText(layout) and lanesOf(run, 2) == layoutText(layout), lanesOf(run, 1) .. " vs " .. layoutText(layout))
  check(name .. ": the log says the edit is verified", count(run.lines, function(l) return contains(l, "edit verified") end) >= 2)
end
local shifted = lanePress(extrasOf({ busLane = true }), { laneShift = 1 })
check("lanes written one mode off: no command is sent and both roads fail with the extras reason",
  #shifted.builds == 0 and #shifted.result.failed == 2 and shifted.result.reasons["bus lane or lock could not be set"] == 2, text(shifted.commands))
check("lanes written one mode off: the log says the edit is not verified", count(shifted.lines, function(l) return contains(l, "EDIT NOT VERIFIED") end) >= 1)

-- The tram connections of the added segment in the node configs of the proposal. Road 1 runs from node 10 to node 11, where
-- the roads 5 and 6 meet it. In every road the lane at position 1 (seen from node 11) is the incoming tram lane and the lane
-- at position 2 the outgoing one.
do
local VEHICLE = { MODE.CAR, MODE.BUS, MODE.TRUCK }
local VEHICLE_TRAM = { MODE.CAR, MODE.BUS, MODE.TRUCK, MODE.TRAM }
local function directed(modeList, forward)
  local lane = { forward = forward }
  for i, mode in ipairs(modeList) do lane[i] = mode end
  return lane
end
local SMALL_PLAIN = { directed({ MODE.PERSON }, false), directed(VEHICLE, false), directed(VEHICLE, true), directed({ MODE.PERSON }, true) }
local SMALL_TRAM = { directed({ MODE.PERSON }, false), directed(VEHICLE_TRAM, false), directed(VEHICLE_TRAM, true), directed({ MODE.PERSON }, true) }
local WIDE_TRAM = { directed({ MODE.PERSON }, false), directed(VEHICLE_TRAM, false), directed(VEHICLE_TRAM, false),
  directed(VEHICLE_TRAM, true), directed(VEHICLE_TRAM, true), directed({ MODE.PERSON }, true) }
local JUNCTION_NODES = { [1] = { 10, 11 }, [5] = { 11, 12 }, [6] = { 13, 11 } }
local function junctionConnections()
  return { [11] = { { -1, 1, 5, 2, true, false }, { 5, 1, -1, 2, true, false }, { 5, 1, 6, 2, true, true }, { 6, 1, 5, 2, true, true } } }
end
local function tramPress(extras, more)
  local options = { option = 2, edges = { 1 }, extras = extras, roadLanes = SMALL_TRAM, proposalLanes = SMALL_PLAIN, templateLanes = SMALL_PLAIN,
    edgeNodes = JUNCTION_NODES, nodeConnections = junctionConnections() }
  for key, value in pairs(more or {}) do options[key] = value end
  return press(options)
end
local function connectionsAt(run, node)
  for _, config in ipairs(run.builds[1] and run.builds[1].configs or {}) do
    if config.entity == node then return config.laneConnections end
  end
  return {}
end
local function tramRoute(connections, from, fromLane, to, toLane)
  for _, c in ipairs(connections) do
    if c.segment0 == from and c.lane0 == fromLane and c.segment1 == to and c.lane1 == toLane then return c end
  end
  return nil
end
local function isTramOnly(c) return c ~= nil and c.withTram == true and c.withRoad == false end
local function isRoadAndTram(c) return c ~= nil and c.withTram == true and c.withRoad == true end

local tramJunction = tramPress(extrasOf({ tram = true }))
local junction = connectionsAt(tramJunction, 11)
check("tram connections: the road is upgraded", tramJunction.result.removed == 1 and #tramJunction.result.failed == 0 and #tramJunction.builds == 1)
check("tram connections: a connection between the tram lanes of the new road and a neighbour gets the tram flag and keeps the road flag",
  isRoadAndTram(tramRoute(junction, -1, 1, 5, 2)) and isRoadAndTram(tramRoute(junction, 5, 1, -1, 2)))
check("tram connections: a missing connection between the tram lanes is added for the tram alone",
  #junction == 6 and isTramOnly(tramRoute(junction, -1, 1, 6, 2)) and isTramOnly(tramRoute(junction, 6, 1, -1, 2)), #junction)
check("tram connections: the connections between the other roads stay as they were",
  isRoadAndTram(tramRoute(junction, 5, 1, 6, 2)) and isRoadAndTram(tramRoute(junction, 6, 1, 5, 2)))
check("tram connections: a node with no other road gets no connection", #connectionsAt(tramJunction, 10) == 0)
check("tram connections: the log names the counts and that they are verified",
  count(tramJunction.lines, function(l) return contains(l, "tram connections: 2 set, 2 added, 0 left out, verified") end) == 1, text(tramJunction.lines))

local paused = tramPress(extrasOf({ tram = true }), { speed = 0 })
check("tram connections: in a paused game the lanes of the neighbour roads are read outside every command callback",
  count(paused.allReads, function(r) return r == "BASE_EDGE 5" or r == "BASE_EDGE 6" end) == 2
  and count(paused.callbackReads, function(r) return r == "BASE_EDGE 5" or r == "BASE_EDGE 6" end) == 0, text(paused.callbackReads))

local noTram = tramPress(extrasOf({ busLane = true }))
check("tram connections: an upgrade without the tram track leaves the node configs as they are",
  #noTram.builds == 1 and #connectionsAt(noTram, 11) == 4 and not isRoadAndTram(tramRoute(connectionsAt(noTram, 11), -1, 1, 5, 2))
  and count(noTram.lines, function(l) return contains(l, "tram connections") end) == 0)

local wide = tramPress(extrasOf({ tram = true }), { roadLanesFor = { [6] = WIDE_TRAM } })
local wideJunction = connectionsAt(wide, 11)
check("tram connections: a neighbour with several tram lanes per direction is left out, the others are connected",
  #wide.builds == 1 and #wideJunction == 4 and isRoadAndTram(tramRoute(wideJunction, -1, 1, 5, 2))
  and count(wide.lines, function(l) return contains(l, "tram connections: 2 set, 0 added, 2 left out, verified") end) == 1, text(wide.lines))

local dropped = tramPress(extrasOf({ tram = true }), { dropConnectionWrite = true })
check("tram connections not taken by the proposal: no command is sent and the road fails with the extras reason",
  #dropped.builds == 0 and #dropped.result.failed == 1 and dropped.result.reasons["bus lane or lock could not be set"] == 1, text(dropped.commands))
check("tram connections not taken by the proposal: the log says so",
  count(dropped.lines, function(l) return contains(l, "TRAM CONNECTIONS NOT VERIFIED") end) >= 1)
end

-- Rails: the commit builds the target template of each track
local STANDARD_TRACK = "::/infrastructure/track/standard/standard.street_template"
local TRACK = { isStreet = false, template = STANDARD_TRACK }
local function railTarget(e)
  if e == 1 then return STANDARD_TRACK, false, { { 10, false }, { 10, true } } end
  if e == 2 then return STANDARD_TRACK, true, nil end
  return nil, false, nil
end
local rail = press({ option = 2, edges = { 1, 2, 3 }, noTemplate = true, railTarget = railTarget, descriptions = { [1] = TRACK, [2] = TRACK, [3] = TRACK } })
check("rail: one track is built, with the target template", rail.result.rail == true and rail.result.removed == 1 and #rail.builds == 1
  and rail.builds[1].edge == 1 and rail.replacedWith[1] == STANDARD_TRACK, text(rail.commands))
local railDecorations = rail.proposalComps[1] ~= nil and rail.proposalComps[1].edgeDecorations or {}
check("rail: the decoration list of the target is set on the new track",
  #railDecorations == 2 and railDecorations[1][1] == 10 and railDecorations[1][2] == false and railDecorations[2][1] == 10 and railDecorations[2][2] == true)
check("rail: a track that already is the target is counted unchanged and not built", rail.result.unchanged == 1 and #buildsOf(rail, 2) == 0)
check("rail: a track without a target is skipped as another track type", rail.result.reasons["other track type"] == 1 and #buildsOf(rail, 3) == 0)
local railOnRoad = press({ option = 2, edges = { 1, 2 }, noTemplate = true, railTarget = railTarget, descriptions = { [1] = { isStreet = true }, [2] = TRACK } })
check("rail: a road in a press of tracks is dropped by the hard rules", #buildsOf(railOnRoad, 1) == 0 and railOnRoad.result.reasons["filtered"] == 1)

-- Rails: no pair, no lot houses and no crosswalk pass, with the option On and Off
do
  local function sameTrack() return STANDARD_TRACK, false, nil end
  for _, option in ipairs({ 1, 2 }) do
    local name = "rail, option " .. (option == 1 and "Off" or "On")
    local run = press({ option = option, edges = { 1, 2 }, noTemplate = true, railTarget = sameTrack, descriptions = { [1] = TRACK, [2] = TRACK },
      failCommandFor = { [1] = 1, [2] = 1 }, removeBuildings = true, assetGroups = {}, constructions = PAIR_CONSTRUCTIONS,
      lotFound = function(center) return HOUSES_AT[center.x] or {} end, edgeNodes = PAIR_NODES, roadOffsets = PAIR_OFFSETS, nodeConfigs = true,
      nodeSegments = { [10] = { 1, 30, 31 }, [11] = { 1, 2, 30 }, [12] = { 2, 32, 33 } },
      nodePositions = { [10] = { x = 40, y = 60, z = 0 }, [11] = { x = 50, y = 60, z = 0 }, [12] = { x = 60, y = 60, z = 0 } },
      nodeCrosswalks = { [10] = {}, [11] = {}, [12] = {} } })
    check(name .. ": each track takes its own retry, both are upgraded",
      run.result.rail == true and run.result.removed == 2 and #run.result.failed == 0 and #buildsOf(run, 1) == 2 and #buildsOf(run, 2) == 2, text(run.commands))
    check(name .. ": no pair is built and no command removes two segments",
      #run.pairCalls == 0 and linesWith(run, "pair spike") == 0 and count(run.builds, function(b) return #b.removedSegments > 1 end) == 0)
    check(name .. ": no lot house is looked up or put in a removal list",
      #run.lotHouseCalls == 0 and #run.lotQueries == 0 and withRemovalList(run) == 0, #run.lotHouseCalls)
    check(name .. ": no crosswalk pass: no node is read or touched, no command, no line, no progress of the pass",
      #run.crosswalkCommands == 0 and linesWith(run, "crosswalks:") == 0 and readsOf(run, "BASE_NODE") == 0
      and count(run.roadCalls, function(c) return c.attempt == -1 end) == 0 and text(run.commands) == "speed, build, build, build, build, speed", text(run.commands))
  end
end

-- lotFailures and buildingsKept of the result
do
  local PARCEL_MESSAGES = { "Construction Not Possible", "Unexpected parcel on a segment" }
  for _, option in ipairs({ 1, 2 }) do
    for _, removeBuildings in ipairs({ false, true }) do
      local name = "result (option " .. option .. ", remove buildings " .. tostring(removeBuildings) .. ")"
      local parcel = press({ option = option, edges = { 1, 2 }, failCommandFor = { [1] = true }, failMessages = PARCEL_MESSAGES, removeBuildings = removeBuildings })
      check(name .. ": a road that fails on every attempt with the parcel text counts once in lotFailures",
        #parcel.result.failed == 1 and #buildsOf(parcel, 1) == 3 and parcel.result.lotFailures == 1, tostring(parcel.result.lotFailures))
      check(name .. ": buildingsKept is the opposite of removeBuildings", parcel.result.buildingsKept == (not removeBuildings), tostring(parcel.result.buildingsKept))
      local plain = press({ option = option, edges = { 1, 2 }, failCommandFor = { [1] = true }, removeBuildings = removeBuildings })
      check(name .. ": a road that fails without the parcel text gives lotFailures 0", #plain.result.failed == 1 and plain.result.lotFailures == 0, tostring(plain.result.lotFailures))
      check(name .. ": buildingsKept does not depend on the failure", plain.result.buildingsKept == (not removeBuildings))
    end
  end
  local both = press({ option = 1, edges = { 1, 2 }, failCommandFor = { [1] = true, [2] = true }, failMessages = PARCEL_MESSAGES })
  check("lotFailures: every failed road with the parcel text is counted", #both.result.failed == 2 and both.result.lotFailures == 2, tostring(both.result.lotFailures))
  local single = press({ option = 1, edges = { 1, 2 }, failCommandFor = { [1] = true }, failMessages = { "Unexpected parcel" } })
  check("lotFailures: the parcel text as the only message counts too", #single.result.failed == 1 and single.result.lotFailures == 1, tostring(single.result.lotFailures))
  local german = press({ option = 1, edges = { 1, 2 }, failCommandFor = { [1] = true }, failMessages = { "Bau nicht moeglich", "Unerwartete Parzelle" } })
  check("lotFailures: a message in another language does not match the English text", #german.result.failed == 1 and german.result.lotFailures == 0, tostring(german.result.lotFailures))
  local recovered = press({ option = 1, edges = { 1, 2 }, failCommandFor = { [1] = 1 }, failMessages = PARCEL_MESSAGES })
  check("lotFailures: a road that failed with the parcel text and was upgraded by its retry is not counted",
    #recovered.result.failed == 0 and recovered.result.removed == 2 and recovered.result.lotFailures == 0, tostring(recovered.result.lotFailures))
  local good = press({ option = 1, edges = { 1, 2 }, removeBuildings = true })
  check("result: a press without failures has lotFailures 0 and buildingsKept false with removeBuildings", good.result.lotFailures == 0 and good.result.buildingsKept == false)
  check("result: a refused second commit has lotFailures 0 and buildingsKept true (it removes no buildings)",
    twice.second.lotFailures == 0 and twice.second.buildingsKept == true)
  check("result: a press with nothing left to upgrade has lotFailures 0 and buildingsKept true", everyone.result.lotFailures == 0 and everyone.result.buildingsKept == true)
end

-- With the option Off, the probe adds no read of the game next to the commit. The baseline is a probe that does nothing
-- (tag, beginPress and press); the one read left is the read of the option itself. This holds in every scenario. The lot
-- houses, the pair and the crosswalk pass belong to the commit and run in the baseline too.
local SCENARIOS = {
  { "good roads", {} },
  { "paused game", { speed = 0 } },
  { "chain", { failProposalFor = { [1] = true } } },
  { "speed change", { bumpSpeedAfterBuild = 1 } },
  { "failed command", { failCommandFor = { [1] = true } } },
  { "failed command, buildings removed", { failCommandFor = { [1] = true }, removeBuildings = true } },
  { "lot houses", { failCommandFor = { [1] = true }, removeBuildings = true, assetGroups = {}, constructions = LOT_CONSTRUCTIONS, lotFound = LOT_FOUND } },
  { "error while preparing", { failCommandFor = { [1] = true }, removeBuildings = true, throwInEntityExists = true } },
  { "error while sending", { throwOnSendFor = { [1] = true } } },
  { "pair", { failCommandFor = { [1] = 1, [2] = 1 }, removeBuildings = true, assetGroups = {}, constructions = PAIR_CONSTRUCTIONS,
    lotFound = function(center) return HOUSES_AT[center.x] or {} end, edgeNodes = PAIR_NODES, roadOffsets = PAIR_OFFSETS, nodeConfigs = true } },
  { "crosswalk pass", { failCommandFor = { [1] = 1, [2] = 1 }, removeBuildings = true, assetGroups = {}, constructions = PAIR_CONSTRUCTIONS,
    lotFound = function(center) return HOUSES_AT[center.x] or {} end, edgeNodes = PAIR_NODES, roadOffsets = PAIR_OFFSETS, nodeConfigs = true,
    roadLanes = PLAIN_LANES, templateLanes = PLAIN_LANES, nodeSegments = { [10] = { 1, 30, 31 }, [11] = { 1, 2, 30 }, [12] = { 2, 32, 33 } },
    nodePositions = { [10] = { x = 40, y = 60, z = 0 }, [11] = { x = 50, y = 60, z = 0 }, [12] = { x = 60, y = 60, z = 0 } },
    nodeCrosswalks = { [10] = {}, [11] = {}, [12] = {} } } },
  { "lock", { extras = LOCK } },
  { "lock not taken", { extras = LOCK, dropLockWrite = true } },
  { "pause refused", { refusePause = true } },
  { "cancel in flight", { cancelBeforeBuild = 1 } },
  { "cancel during the pause", { cancelBeforePause = true } },
}
for _, scenario in ipairs(SCENARIOS) do
  local name, options = scenario[1], scenario[2]
  local function run(extra)
    local merged = { edges = { 1, 2 }, option = 1 }
    for key, value in pairs(options) do merged[key] = value end
    for key, value in pairs(extra) do merged[key] = value end
    -- A press writes the crosswalks of the world it runs in: each run gets its own copy.
    if merged.nodeCrosswalks ~= nil then
      local fresh = {}
      for node, list in pairs(merged.nodeCrosswalks) do fresh[node] = copyList(list) end
      merged.nodeCrosswalks = fresh
    end
    return press(merged)
  end
  local offRun, inertRun = run({}), run({ inertProbe = true })
  local added = onlyIn(offRun.allReads, inertRun.allReads)
  check(name .. ": off: the probe adds no read but the read of the option", count(added, function(r) return r ~= READ_OF_THE_OPTION end) == 0, text(added))
  check(name .. ": off: the probe adds no read inside a command callback", sameLines(offRun.callbackReads, inertRun.callbackReads),
    text(onlyIn(offRun.callbackReads, inertRun.callbackReads)))
  check(name .. ": off: the probe takes nothing away", #onlyIn(inertRun.allReads, offRun.allReads) == 0)
  check(name .. ": off: the result equals the result with an inert probe", sameOutcome(offRun, inertRun) and sameLines(offRun.lines, inertRun.lines))
  local onRun = run({ option = 2 })
  for label, runToCheck in pairs({ off = offRun, on = onRun }) do
    local unlisted = unlistedComponentReads(runToCheck, { 1, 2 }, { 50 })
    check(name .. ": " .. label .. ": callbacks read only listed components with getComponent", #unlisted == 0, text(unlisted))
  end
end
local mixedReads = unlistedComponentReads(mixed, { 1, 2 }, { 50, 60 })
check("collision with two entities: callbacks read only listed components with getComponent", #mixedReads == 0, text(mixedReads))
check("the check of listed components sees a read that is not listed",
  #unlistedComponentReads({ callbackReads = { "BASE_EDGE 99", "ASSET_GROUP 7", "GAME_SPEED 5", "BASE_NODE 1" } }, { 1, 2 }, { 50 }) == 4)

-- The plan of each road: reason, notes, decorations and lanes
do
  local MEDIUM = {
    { MODE.PERSON }, { MODE.CAR, MODE.BUS, MODE.TRUCK }, { MODE.CAR, MODE.BUS, MODE.TRUCK }, { MODE.CAR, MODE.BUS, MODE.TRUCK },
    { MODE.CAR, MODE.BUS, MODE.TRUCK }, { MODE.PERSON },
  }
  local MEDIUM_TRAM = {
    { MODE.PERSON }, { MODE.CAR, MODE.BUS, MODE.TRUCK, MODE.TRAM, MODE.ELECTRIC_TRAM }, { MODE.CAR, MODE.BUS, MODE.TRUCK },
    { MODE.CAR, MODE.BUS, MODE.TRUCK }, { MODE.CAR, MODE.BUS, MODE.TRUCK, MODE.TRAM, MODE.ELECTRIC_TRAM }, { MODE.PERSON },
  }
  local NONE = { carFree = false, tram = false, electric = false }
  local function planPress(plans, more)
    local options = { option = 2, edges = { 1, 2 }, proposalLanes = MEDIUM, target = function(e)
      local plan = {}
      for key, value in pairs(plans[e]) do plan[key] = value end
      return plan
    end }
    for key, value in pairs(more or {}) do options[key] = value end
    return press(options)
  end

  local reasoned = planPress({ [1] = { reason = "lanes cannot be kept", unchanged = false, notes = { "unlisted" } }, [2] = { template = "new_template", unchanged = false, notes = {} } })
  check("plan with a reason: the road is left alone and counted under its reason, the other road is upgraded",
    reasoned.result.removed == 1 and #buildsOf(reasoned, 1) == 0 and #buildsOf(reasoned, 2) == 1 and reasoned.result.reasons["lanes cannot be kept"] == 1
    and #reasoned.result.failed == 0 and reasoned.result.skipped == 1, text(reasoned.commands))
  check("plan with a reason: the road is reported as done and its notes do not count",
    count(reasoned.roadCalls, function(c) return c.e == 1 and c.ok == true end) == 1 and next(reasoned.result.notes) == nil)
  check("plan with a reason: the log names the reason", count(reasoned.lines, function(l) return contains(l, "edge 1: left alone: lanes cannot be kept") end) == 1)

  local noted = planPress({ [1] = { template = "new_template", unchanged = false, notes = { "lostTrees", "country" } }, [2] = { template = "old_template", unchanged = true, notes = { "unlisted" } } })
  check("notes: the notes of an upgraded road and of an unchanged road are counted",
    noted.result.removed == 1 and noted.result.unchanged == 1 and noted.result.notes.lostTrees == 1 and noted.result.notes.country == 1 and noted.result.notes.unlisted == 1)
  local notedFail = planPress({ [1] = { template = "new_template", unchanged = false, notes = { "lostTrees" } }, [2] = { template = "new_template", unchanged = false, notes = {} } },
    { failCommandFor = { [1] = true } })
  check("notes: the notes of a road that failed are not counted", #notedFail.result.failed == 1 and next(notedFail.result.notes) == nil)
  local notedRetry = planPress({ [1] = { template = "new_template", unchanged = false, notes = { "lostTrees" } }, [2] = { template = "new_template", unchanged = false, notes = {} } },
    { failCommandFor = { [1] = 1 } })
  check("notes: the notes of a road that the retry upgraded are counted once", notedRetry.result.removed == 2 and notedRetry.result.notes.lostTrees == 1)

  local emptied = planPress({ [1] = { template = "new_template", unchanged = false, decorations = {}, notes = {} }, [2] = { template = "new_template", unchanged = false, notes = {} } })
  check("decorations: an empty list of the plan is written, a plan without a list writes none",
    count(emptied.lines, function(l) return contains(l, "edge 1") and contains(l, "decorations 0 -> 0 (wanted 0 per segment)") end) == 1
    and count(emptied.lines, function(l) return contains(l, "edge 2") and contains(l, "decorations") end) == 0, text(emptied.lines))

  local inner = planPress({ [1] = { template = "new_template", unchanged = false, laneCount = 6, notes = {},
    lanes = { [2] = { carFree = true, tram = false, electric = false }, [3] = { carFree = false, tram = true, electric = true }, [4] = { carFree = false, tram = true, electric = false }, [5] = NONE } },
    [2] = { template = "new_template", unchanged = false, laneCount = 6, lanes = { [2] = NONE, [3] = NONE, [4] = NONE, [5] = NONE }, notes = {} } })
  check("lanes: every lane gets what its flags say, also an inner lane",
    lanesText(inner.proposalComps[1].laneConfigs) == "0 | 3+4 | 2+3+4+5+6 | 2+3+4+5 | 2+3+4 | 0" and inner.result.removed == 2, lanesText(inner.proposalComps[1].laneConfigs))
  check("lanes: a road whose lanes need no change is verified without a lane write",
    lanesText(inner.proposalComps[2].laneConfigs) == layoutText(MEDIUM)
    and count(inner.lines, function(l) return contains(l, "edge 2") and contains(l, "edit: edit verified") end) == 1, text(inner.lines))

  local stripped = planPress({ [1] = { template = "new_template", unchanged = false, laneCount = 6, notes = {},
    lanes = { [2] = { carFree = false, tram = true, electric = false }, [3] = NONE, [4] = NONE, [5] = NONE } },
    [2] = { template = "new_template", unchanged = true, notes = {} } }, { proposalLanes = MEDIUM_TRAM })
  check("lanes: a tram or a catenary that the template brings is taken off a lane whose flags lack it",
    lanesText(stripped.proposalComps[1].laneConfigs) == "0 | 2+3+4+5 | 2+3+4 | 2+3+4 | 2+3+4 | 0", lanesText(stripped.proposalComps[1].laneConfigs))

  local miscounted = planPress({ [1] = { template = "new_template", unchanged = false, laneCount = 4, lanes = { [2] = NONE, [3] = NONE }, notes = {} },
    [2] = { template = "new_template", unchanged = true, notes = {} } })
  check("lanes: a proposal with another number of lanes than the plan is not sent",
    #miscounted.builds == 0 and #miscounted.result.failed == 1 and miscounted.result.reasons["bus lane or lock could not be set"] == 1, text(miscounted.commands))
end

support.finish("commit_flow")
