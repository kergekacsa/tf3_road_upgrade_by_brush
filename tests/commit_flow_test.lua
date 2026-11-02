-- Tests of the upgrade commit (bb_upgrade.tl) with a stub of the game: the same press with the option "Debug: upgrade log"
-- Off and On must give the same result and the same log lines apart from the tags. The stub records every command and every
-- read of the game api. bb_select is the real module. bb_gather is a stub that describes the edges, so its reads are not
-- recorded.
-- With the option Off the probe adds no read but the read of the option. With the option On it adds no read inside the
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
local function makeLanes(layout, shift)
  local lanes = {}
  for i, modeList in ipairs(layout) do
    local data = { transportModes = {} }
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

local function newComp(template, layout, shift)
  return {
    roadTemplate = template, type = 0, typeIndex = 0, roadDevelopmentLocked = false, roadType = STREET, distance = 10,
    edgeDecorations = {}, objects = {}, laneConfigs = layout ~= nil and makeLanes(layout, shift) or {},
    position0 = { x = 0, y = 0, z = 0 }, position1 = { x = 10, y = 0, z = 0 },
  }
end

local function newProposal(edge)
  local real = newComp("new_template", world.proposalLanes, world.laneShift)
  world.proposalComps[edge] = real
  return {
    proposal = {
      addedSegments = { { comp = tracked(real, "proposal comp") } }, removedSegments = {}, addedNodes = {}, removedNodes = {},
      edgeObjectsToAdd = {},
    },
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

local function runCommand(command, callback)
  world.commands[#world.commands + 1] = command.kind
  local isBuild = command.kind == "build"
  if isBuild then world.builds[#world.builds + 1] = command end
  local nth = #world.builds
  local refused = command.kind == "speed" and command.speed == 0 and world.refusePause
  if command.kind == "speed" and not refused then world.speed = command.speed end
  if command.kind == "speed" and command.speed == 0 and world.cancelBeforePause then upgrade.cancel() end
  if isBuild and world.cancelBeforeBuild == nth then upgrade.cancel() end
  if isBuild and world.abortBeforeBuild == nth then upgrade.abort() end
  world.callbackDepth = world.callbackDepth + 1
  if isBuild and world.failCommandFor[command.edge] then
    callback({ resultProposalData = { errorState = { messages = world.failMessages },
      collisionInfo = { collisionEntities = world.collisionEntities, buildingEntities = {} } } }, false)
  elseif refused then
    callback({}, false)
  else
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
      ASSET_GROUP = "ASSET_GROUP", PLAYER_OWNED = "PLAYER_OWNED",
    },
    Vec2f = { new = function(x, y) return { x = x, y = y } end },
    Context = { new = function() return {} end },
  },
  res = {
    streetTemplateRep = {
      find = recorded("res.streetTemplateRep.find", function() return world.templateLanes ~= nil and 7 or -1 end),
      get = function() return { laneConfigs = makeLanes(world.templateLanes), defaultEdgeDecorations = {} } end,
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
        return newComp("old_template", world.roadLanes)
      end
      if componentType == "ASSET_GROUP" then return world.assetGroups[e] and {} or nil end
      if componentType == "PLAYER_OWNED" then return { player = 7 } end
      return nil
    end,
    system = { parcelSystem = { getParcelData = function(e)
      world.parcelReads[#world.parcelReads + 1] = { edge = e, inCallback = inCallback() }
      return { leftEntities = {}, rightParcels = {} }
    end } },
    util = {
      getWorld = recorded("util.getWorld", function() return 1000 end),
      getPlayer = recorded("util.getPlayer", function() return 1 end),
      octree = { findEntitiesInCircle = recorded("octree", function()
        failIfProbeRead("octree")
        return {}
      end) },
      proposal = { replaceSegment = recorded("util.proposal.replaceSegment", function(e, template)
        if world.failProposalFor[e] then error("replaceSegment refused edge " .. e) end
        world.replacedWith[e] = template
        return newProposal(e)
      end) },
    },
  },
  cmd = {
    makeGameSetSpeedCmd = function(speed) return { kind = "speed", speed = speed } end,
    makeWorldBuildProposalCmd = function(p, _context, force)
      if world.throwOnSendFor[p.edge] then error("stub: the command was refused", 0) end
      return { kind = "build", edge = p.edge, force = force, toRemove = copyList(p.toRemove) }
    end,
    sendCommand = runCommand,
  },
}

-- Notes where the press of the probe runs, and lets a read inside the probe throw on request. With world.inertProbe the
-- commit meets a probe that does nothing at all (tag, beginPress and press): the reads of such a press are the reads of
-- the commit alone.
local probeModule = ug_require("kacsa_road_upgrade_brush::/road_upgrade_brush/proposal_probe.tl")
local originalPress, originalTag, originalBeginPress = probeModule.press, probeModule.tag, probeModule.beginPress
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

-- Runs one press over `options.edges` and returns the commit result, the lines of the commit, the probe lines, and the
-- records of the stub.
local function press(options)
  world.optionValue = options.option
  world.speed = options.speed or 1
  world.failProposalFor = options.failProposalFor or {}
  world.failCommandFor = options.failCommandFor or {}
  world.failMessages = options.failMessages or { "Collision" }
  world.assetGroups = options.assetGroups or { [50] = true }
  world.missingEntities = options.missingEntities or {}
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
  world.inertProbe = options.inertProbe == true
  world.inProbeFunction = nil
  world.descriptions = options.descriptions or {}
  world.describeCalls, world.replacedWith, world.proposalComps = {}, {}, {}
  world.roadLanes, world.proposalLanes, world.templateLanes = options.roadLanes, options.proposalLanes, options.templateLanes
  world.laneShift = options.laneShift
  world.allReads, world.callbackReads, world.parcelReads = {}, {}, {}
  world.pressCalls, world.commands, world.builds, world.probeLines = {}, {}, {}, {}
  world.callbackDepth = 0
  world.clock = 0
  local lines, result, doneCalls, roadCalls = {}, nil, 0, {}
  local template = options.template or "new_template"
  if options.noTemplate then template = nil end
  local function commit(onDone)
    upgrade.commit(options.edges, template, options.extras or DEFAULT_EXTRAS, options.removeBuildings == true, options.ctx or CTX,
      options.industryRoads or {}, onDone, function(text) lines[#lines + 1] = text end,
      function(e, ok, finished, total, attempt) roadCalls[#roadCalls + 1] = { e = e, ok = ok, finished = finished, total = total, attempt = attempt } end,
      options.railTarget)
  end
  commit(function(res) result = res; doneCalls = doneCalls + 1 end)
  -- A second commit while the first one runs
  local second
  if options.secondCommit then
    upgrade.commit(options.edges, template, options.extras or DEFAULT_EXTRAS, false, options.ctx or CTX, {},
      function(res) second = res end, function() end, nil, nil)
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
    proposalComps = world.proposalComps,
  }
end

local function stripTags(lines)
  local out = {}
  for i, line in ipairs(lines) do out[i] = (line:gsub("^%[upgrade%] ", ""):gsub("^%[failure%] ", "")) end
  return out
end

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
  check(name .. ": on: the commit lines equal the Off lines once the tags are removed", sameLines(stripTags(failedOn.lines), failedOff.lines))
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

-- Whether a road already is what the template and the extras make of it, and which extras a road carries
world.templateLanes = PLAIN_LANES
local busMatcher, plainMatcher = upgrade.matcher("old_template", extrasOf({ busLane = true })), upgrade.matcher("old_template", extrasOf({}))
world.roadLanes = BUS_LANES
check("matcher: a road with bus lanes is the target of a bus lane upgrade, not of a plain one", busMatcher(1) == true and plainMatcher(1) == false)
world.roadLanes = PLAIN_LANES
check("matcher: a plain road is the target of a plain upgrade, not of a bus lane one", plainMatcher(1) == true and busMatcher(1) == false)
for _, case in ipairs({
  { "plain", PLAIN_LANES, false, false, false },
  { "bus lane", BUS_LANES, true, false, false },
  { "tram track", TRAM_LANES, false, true, false },
  { "tram track with catenary", CATENARY_LANES, false, true, true },
}) do
  world.roadLanes = case[2]
  local found = upgrade.extrasOf(1, "old_template")
  check("extras of a road: " .. case[1], found ~= nil and found.busLane == case[3] and found.tram == case[4] and found.catenary == case[5] and found.lock == "keep")
end
world.roadLanes = { { MODE.PERSON } }
check("extras of a road: a road whose lanes fit no combination has none", upgrade.extrasOf(1, "old_template") == nil)
world.roadLanes, world.templateLanes = nil, nil

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

-- With the option Off, the probe adds no read of the game next to the commit. The baseline is a probe that does nothing
-- (tag, beginPress and press); the one read left is the read of the option itself. This holds in every scenario.
local READ_OF_THE_OPTION = "config.getModParams -"
local SCENARIOS = {
  { "good roads", {} },
  { "paused game", { speed = 0 } },
  { "chain", { failProposalFor = { [1] = true } } },
  { "speed change", { bumpSpeedAfterBuild = 1 } },
  { "failed command", { failCommandFor = { [1] = true } } },
  { "failed command, buildings removed", { failCommandFor = { [1] = true }, removeBuildings = true } },
  { "error while preparing", { failCommandFor = { [1] = true }, removeBuildings = true, throwInEntityExists = true } },
  { "error while sending", { throwOnSendFor = { [1] = true } } },
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

support.finish("commit_flow")
