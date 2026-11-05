-- Tests rub_grid_builder.tl (loaded by the debug console with ug_require) against a stub of the game's `api`.
-- The stub queues every command, applies it like the game (new nodes get real ids) and then calls the callback.
local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path
local support = require("support")

local ALONG = 6
local LEFT = 8
local ALONG_M = 144
local LEFT_M = 88
local GRID_NODES = (ALONG + 1) * (LEFT + 1)
local ALONG_EDGES = ALONG * (LEFT + 1)
local LEFT_EDGES = LEFT * (ALONG + 1)
local GRID_EDGES = ALONG_EDGES + LEFT_EDGES
local FIRST_NEW_ID = 1000
local REPLACED_CORNER_ID = 900
local FIRST_EDGE_ID = 5000

-- A street of 'perSide' vehicle lanes in each direction between two sidewalk lanes, in the order of the build direction.
local function laneLayout(tag, perSide)
  local list = {}
  local function lane(forward, modes) list[#list + 1] = { tag = tag, forward = forward, transportModes = modes } end
  lane(false, { [0] = true })
  for _ = 1, perSide do lane(false, { [2] = true, [3] = true, [4] = true }) end
  for _ = 1, perSide do lane(true, { [2] = true, [3] = true, [4] = true }) end
  lane(true, { [0] = true })
  return list
end
local OWNER_PLAYER = 42
local LARGE_NEW = "street/town_new_large.street_template"
local LARGE_OLD = "street/town_old_large.street_template"
local TEMPLATE_NAMES = { "town_medium", LARGE_OLD, "street/country_new_large.lua", LARGE_NEW }
local LARGE_DECORATION_ID = 77
local STRIP_DECORATION = { 5, false }
local EVERY_ALONG = 4
local EVERY_LEFT = 3

support.installRequire(nil)
local globalsBefore = {}
for key in pairs(_G) do globalsBefore[key] = true end
local gridBuilder = ug_require("kacsa_road_upgrade_brush::/road_upgrade_brush/rub_grid_builder.tl")
local loadedWithoutApi = _G.api == nil and type(gridBuilder.build) == "function"

local function vec(x, y, z) return { x = x, y = y, z = z } end
local function near(a, b) return math.abs(a - b) < 1e-6 end

-- A world with one street strip (edge 7, nodes 10 and 11) from p0 to p1, a far street (edge 3) and a track (edge 5).
-- `failAt` makes that command fail with the message "Collision".
-- `invalidateStripAfter`: after that many commands the stub wipes every view of the strip, as the engine can do with the data behind a component.
-- The number of ticks (wait commands) after a street is added before a node with three streets shows its lane connections, as another mod writes them a moment later.
local connectionDelayTicks = 0
-- While true, a node config refuses a list of lane connections.
local refuseLaneLists = false
-- While true, a node with three or more streets has no crosswalk in its config.
local nodesWithoutCrosswalks = false
local function runWorld(p0, p1, options, failAt, year, invalidateStripAfter, replaceCornerAfter)
  local ownerView = { player = OWNER_PLAYER }
  local world = { nodes = { [10] = { position = p0 }, [11] = { position = p1 } }, edges = {}, applied = {}, queue = {}, next = FIRST_NEW_ID }
  local edges = {
    [5] = { roadType = "TRACK", position0 = p0, position1 = p1 },
    [7] = { roadType = "STREET", node0 = 10, node1 = 11, position0 = p0, position1 = p1, roadTemplate = "town_medium", typeIndex = -1, distance = 0, edgeDecorations = { STRIP_DECORATION }, laneConfigs = laneLayout("strip", 1) },
    [3] = { roadType = "STREET", node0 = 12, node1 = 13, position0 = vec(p0.x + 90, p0.y + 90, 0), position1 = vec(p1.x + 90, p1.y + 90, 0), roadTemplate = "country_small", typeIndex = -1, distance = 0 },
  }
  local record = function() return { new = function() return { comp = {} } end } end
  local octreeCalls = {}
  local nextEdgeId = FIRST_EDGE_ID
  local writtenConfigs = {}
  local explicitConfigNodes = {}
  local ticksDone = 0
  local api = {
    type = {
      ComponentType = { BASE_EDGE = "BASE_EDGE", BASE_NODE = "BASE_NODE", BASE_NODE_CONFIG = "BASE_NODE_CONFIG", PLAYER_OWNED = "PLAYER_OWNED" },
      enum = { RoadType = { STREET = "STREET", TRACK = "TRACK" }, BaseEdgeType = { NORMAL = "NORMAL" }, TransportMode = { PERSON = 0, CARGO = 1, CAR = 2, BUS = 3, TRUCK = 4 } },
      Vec2f = { new = function(x, y) return { x = x, y = y } end },
      Vec3f = { new = vec },
      PlayerOwned = record(),
      LaneConnection = { new = function() return {} end },
      BaseNodeLaneConnectionAndEntity = { new = function()
        -- Like the game: userModifiedLaneConnections is not writable.
        local comp = setmetatable({}, { __newindex = function(table, key, value)
          if key == "userModifiedLaneConnections" then error("no writable member '" .. key .. "'") end
          if refuseLaneLists and key == "laneConnections" and #value > 0 then error("bad argument #4 to '?' (const LaneConnection expected, got no value)") end
          rawset(table, key, value)
        end })
        return { comp = comp }
      end },
      NodeAndEntity = record(),
      SegmentAndEntity = record(),
      SimpleProposal = { new = function() return { streetProposal = {} } end },
      Context = { new = function() return {} end },
    },
    res = { streetTemplateRep = {
      find = function(name)
        for id, known in ipairs(TEMPLATE_NAMES) do if known == name then return id end end
        return -1
      end,
      get = function(id)
        local name = TEMPLATE_NAMES[id]
        local template = { defaultWithCrosswalk = not name:find("country", 1, true), streetStyle = "style_of_" .. name, laneConfigs = laneLayout("lanes_of_" .. name, (name == LARGE_NEW or name == LARGE_OLD) and 3 or 1), defaultEdgeDecorations = { { "deco_of_" .. name, true } } }
        if name == LARGE_NEW then template.availability = { yearFrom = 1950, yearTo = 0 } end
        if name == LARGE_OLD then template.availability = { yearFrom = 0, yearTo = 1950 } end
        return template
      end,
      getAll = function() return TEMPLATE_NAMES end,
    },
    edgeDecorationRep = { find = function(name) return name == "deco_of_" .. LARGE_NEW and LARGE_DECORATION_ID or -1 end } },
    gui = { camera = { getCameraData = function()
      return { x = (p0.x + p1.x) / 2 + 5, y = (p0.y + p1.y) / 2 - 3, z = 300, w = 0, q = 1 }
    end } },
    cmd = {
      makeWorldBuildProposalCmd = function(proposal, context, ignoreErrors, playerInitiated)
        return { proposal = proposal, context = context, ignoreErrors = ignoreErrors, playerInitiated = playerInitiated }
      end,
      makeScriptingSendEventCmd = function() return { tick = true } end,
      sendCommand = function(cmd, callback) world.queue[#world.queue + 1] = { cmd = cmd, callback = callback } end,
    },
    engine = {
      util = {
        getPlayer = function() return 42 end,
        getYear = function() return year or 1990 end,
        octree = { findEntitiesInCircle = function(centre, radius, component)
          octreeCalls[#octreeCalls + 1] = { centre = centre, radius = radius, component = component }
          if component == "BASE_EDGE" then return { 3, 5, 7 } end
          local found = {}
          for id, node in pairs(world.nodes) do
            if (node.position.x - centre.x) ^ 2 + (node.position.y - centre.y) ^ 2 <= radius ^ 2 then found[#found + 1] = id end
          end
          return found
        end },
      },
      getComponent = function(entity, component)
        if component == "BASE_EDGE" then return edges[entity] end
        if component == "PLAYER_OWNED" then return entity == 7 and ownerView or nil end
        if component == "BASE_NODE_CONFIG" then
          if writtenConfigs[entity] then return { laneConnections = writtenConfigs[entity].lanes, crosswalks = nodesWithoutCrosswalks and {} or { 501 } } end
          local streets = {}
          for id, edge in pairs(edges) do
            if edge.node0 == entity or edge.node1 == entity then streets[#streets + 1] = id end
          end
          table.sort(streets)
          if #streets < 3 then
            if explicitConfigNodes[entity] then return { laneConnections = {}, crosswalks = {}, userModifiedLaneConnections = false } end
            return nil
          end
          if ticksDone < connectionDelayTicks then return { laneConnections = {}, crosswalks = {}, userModifiedLaneConnections = false } end
          local lanes = {}
          for _, from in ipairs(streets) do
            for _, to in ipairs(streets) do
              if from ~= to then lanes[#lanes + 1] = { segment0 = from, lane0 = 0, segment1 = to, lane1 = 0, withRoad = true, withTram = false } end
            end
          end
          return { laneConnections = lanes, crosswalks = nodesWithoutCrosswalks and {} or { 501 } }
        end
        return world.nodes[entity]
      end,
      system = { streetSystem = { getNodeStreetSegments = function(node)
        local found = {}
        for id, edge in pairs(edges) do
          if edge.node0 == node or edge.node1 == node then found[#found + 1] = id end
        end
        table.sort(found)
        return found
      end } },
      terrain = {
        getHeightAt = function(v) return v.x * 0.01 end,
        isValidCoordinate = function(v) return math.abs(v.x) < 5000 and math.abs(v.y) < 5000 end,
      },
    },
  }
  _G.api = api
  local out = {}
  local realPrint = print
  _G.print = function(...) out[#out + 1] = table.concat({ ... }, " ") end
  local effective = {}
  for key, value in pairs(options or {}) do effective[key] = value end
  if not effective.defaultBend and effective.laneConnections == nil then effective.laneConnections = "off" end
  local ok, err = pcall(gridBuilder.build, effective)
  local sequential = true
  local guard = 0
  while ok and #world.queue > 0 and guard < 1000 do
    guard = guard + 1
    sequential = sequential and #world.queue == 1
    local item = table.remove(world.queue, 1)
    if item.cmd.tick then
      ticksDone = ticksDone + 1
      item.callback({}, true)
      goto continue
    end
    local sp = item.cmd.proposal.streetProposal
    local record = { newNodes = 0, edges = {}, configs = {}, removedConfigs = sp.nodeConfigsToRemove, rewrittenConfigs = {}, removedEdges = sp.edgesToRemove, removedNodes = sp.nodesToRemove, removes = sp.edgesToRemove ~= nil or sp.nodesToRemove ~= nil, context = item.cmd.context, playerInitiated = item.cmd.playerInitiated, ignoreErrors = item.cmd.ignoreErrors }
    local failFirst = type(failAt) == "table" and failAt.first or failAt
    local failCount = type(failAt) == "table" and failAt.count or 1
    if failFirst and guard >= failFirst and guard < failFirst + failCount then
      item.callback({ resultProposalData = { errorState = { messages = { "Collision" } } } }, false)
    else
      local mapping = {}
      local created = {}
      for _, node in ipairs(sp.nodesToAdd or {}) do
        mapping[node.entity] = world.next
        created[#created + 1] = { world.next, 1 }
        world.nodes[world.next] = { position = node.comp.position }
        world.next = world.next + 1
        record.newNodes = record.newNodes + 1
      end
      for _, config in ipairs(sp.nodeConfigsToAdd or {}) do
        if mapping[config.entity] then
          explicitConfigNodes[mapping[config.entity]] = true
          record.configs[#record.configs + 1] = { node = mapping[config.entity], lanes = config.comp.laneConnections, crosswalks = config.comp.crosswalks }
        else
          assert(world.nodes[config.entity], "a rewritten node config refers to a node that does not exist")
          record.rewrittenConfigs[#record.rewrittenConfigs + 1] = { node = config.entity, lanes = config.comp.laneConnections, crosswalks = config.comp.crosswalks, userModified = config.comp.userModifiedLaneConnections }
          writtenConfigs[config.entity] = { lanes = config.comp.laneConnections }
        end
      end
      for _, edge in ipairs(sp.edgesToAdd or {}) do
        local n0, n1 = mapping[edge.comp.node0] or edge.comp.node0, mapping[edge.comp.node1] or edge.comp.node1
        assert(world.nodes[n0] and world.nodes[n1], "edge refers to an unknown node")
        local id = nextEdgeId
        nextEdgeId = nextEdgeId + 1
        edges[id] = { roadType = "STREET", node0 = n0, node1 = n1, position0 = world.nodes[n0].position, position1 = world.nodes[n1].position, roadTemplate = edge.comp.roadTemplate, laneConfigs = edge.comp.laneConfigs }
        record.edges[#record.edges + 1] = { n0 = n0, n1 = n1, edge = edge, id = id }
        ticksDone = 0
      end
      for _, id in ipairs(sp.edgesToRemove or {}) do
        assert(edges[id], "a removed edge does not exist")
        edges[id] = nil
      end
      for _, id in ipairs(sp.nodesToRemove or {}) do
        assert(world.nodes[id], "a removed node does not exist")
        world.nodes[id] = nil
      end
      world.applied[#world.applied + 1] = record
      if replaceCornerAfter and #world.applied == replaceCornerAfter then
        local corner = world.nodes[11]
        world.nodes[11] = nil
        world.nodes[REPLACED_CORNER_ID] = { position = corner.position }
      end
      if invalidateStripAfter and #world.applied == invalidateStripAfter then
        local strip = edges[7]
        strip.roadTemplate, strip.typeIndex, strip.distance, strip.edgeDecorations, strip.node0, strip.node1 = "", nil, nil, nil, nil, nil
        ownerView.player = nil
      end
      item.callback({ resultProposalData = { errorState = { messages = {} } }, resultEntities = created }, true)
    end
    ::continue::
  end
  _G.print = realPrint
  return { ok = ok, err = err, world = world, edges = edges, out = out, octreeCalls = octreeCalls, sequential = sequential, commands = guard }
end

local function bounds(world)
  local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
  for id, node in pairs(world.nodes) do
    if id >= FIRST_NEW_ID then
      minX = math.min(minX, node.position.x); maxX = math.max(maxX, node.position.x)
      minY = math.min(minY, node.position.y); maxY = math.max(maxY, node.position.y)
    end
  end
  return minX, maxX, minY, maxY
end

-- East-heading strip from (100,200) to (180,200): the grid starts at the strip end (180,200) and runs east and north.
local east = runWorld(vec(100, 200, 0), vec(180, 200, 0))
support.check("script runs", east.ok, east.err)
support.check("one command per segment: 110 commands", east.commands == GRID_EDGES, east.commands)
support.check("a command is sent only after the previous one finished", east.sequential)
support.check("the search is a circle of 150 m around the camera centre over edges",
  east.octreeCalls[1].centre.x == 145 and east.octreeCalls[1].centre.y == 197 and east.octreeCalls[1].radius == 150 and east.octreeCalls[1].component == "BASE_EDGE")
support.check("the first log line ends with the build mark of the module", east.out[1]:find("build 2026-11-03 stemorder", 1, true) ~= nil, east.out[1])
support.check("the log names the strip nearest to the camera", east.out[1]:find("strip 7 ", 1, true) ~= nil and east.out[1]:find("corner 180", 1, true) ~= nil, east.out[1])
support.check("a finished command logs its segment numbers and how many of them are large", east.out[3]:find("built 1 1 large 1", 1, true) ~= nil and east.out[4]:find("built 2 2 large 1", 1, true) ~= nil, east.out[3] .. " | " .. east.out[4])
support.check("the log names both templates with their lot flags", east.out[2]:find("templates", 1, true) ~= nil and east.out[2]:find("town_medium simBuildable=", 1, true) ~= nil and east.out[2]:find(LARGE_NEW .. " simBuildable=", 1, true) ~= nil, east.out[2])
support.check("the run ends with done", east.out[#east.out]:find("done 110", 1, true) ~= nil, east.out[#east.out])

local created, edgeCount, noRemove, oneEdge, lengthsOk, ownedOk, templateOk, decorationsOk = 0, 0, true, true, true, true, true, true
local pairsSeen, duplicates = {}, false
local alongEdges, leftEdges, largeEdges = 0, 0, 0
for _, record in ipairs(east.world.applied) do
  created = created + record.newNodes
  noRemove = noRemove and not record.removes
  oneEdge = oneEdge and #record.edges == 1 and record.newNodes <= 1
  for _, item in ipairs(record.edges) do
    edgeCount = edgeCount + 1
    local p, q = east.world.nodes[item.n0].position, east.world.nodes[item.n1].position
    local length = math.sqrt((q.x - p.x) ^ 2 + (q.y - p.y) ^ 2)
    if near(length, ALONG_M) then alongEdges = alongEdges + 1 elseif near(length, LEFT_M) then leftEdges = leftEdges + 1 else lengthsOk = false end
    ownedOk = ownedOk and item.edge.playerOwned ~= nil and item.edge.playerOwned.player == OWNER_PLAYER
    local runsAlong = near(p.y, q.y)
    local lineIndex = runsAlong and (p.y - 200) / LEFT_M or (p.x - 180) / ALONG_M
    local every = runsAlong and EVERY_ALONG or EVERY_LEFT
    local expected = every > 0 and lineIndex % every == 0 and LARGE_NEW or "town_medium"
    if expected == LARGE_NEW then largeEdges = largeEdges + 1 end
    templateOk = templateOk and item.edge.comp.roadTemplate == expected and item.edge.comp.roadStyle == "style_of_" .. expected
      and item.edge.comp.laneConfigs[1].tag == "lanes_of_" .. expected and item.edge.type == 0 and item.edge.comp.roadType == "STREET"
    local decorations = item.edge.comp.edgeDecorations
    if expected == LARGE_NEW then
      decorationsOk = decorationsOk and #decorations == 1 and decorations[1][1] == LARGE_DECORATION_ID and decorations[1][2] == true
    else
      decorationsOk = decorationsOk and #decorations == 1 and decorations[1][1] == STRIP_DECORATION[1] and decorations[1][2] == STRIP_DECORATION[2]
    end
    local key = math.min(item.n0, item.n1) .. ":" .. math.max(item.n0, item.n1)
    duplicates = duplicates or pairsSeen[key] ~= nil
    pairsSeen[key] = true
  end
end
support.check("62 new nodes: the corner is the strip end node", created == GRID_NODES - 1, created)
support.check("110 edges", edgeCount == GRID_EDGES, edgeCount)
support.check("each command adds one edge and at most one node", oneEdge)
support.check("no command removes anything", noRemove)
support.check("54 edges run along the heading and are 144 m long, 56 run to the left and are 88 m long", lengthsOk and alongEdges == ALONG_EDGES and leftEdges == LEFT_EDGES, alongEdges .. " " .. leftEdges)
support.check("every edge takes the owner of the strip", ownedOk)
support.check("lines 0, 4 and 8 get the large template, style, lanes and default decorations, the other lines keep those of the strip", templateOk and decorationsOk)
support.check("42 edges are large: 3 large rows of 6 segments and 3 large columns of 8 segments", largeEdges == 3 * ALONG + 3 * LEFT, largeEdges)
support.check("no edge is built twice", not duplicates)

local first = east.world.applied[1].edges[1]
support.check("the first edge starts at the strip end node", first.n0 == 11 and east.world.applied[1].newNodes == 1)
local minX, maxX, minY, maxY = bounds(east.world)
support.check("east heading: new nodes span x 180 to 1044 and y 200 to 904", near(minX, 180) and near(maxX, 180 + ALONG * ALONG_M) and near(minY, 200) and near(maxY, 200 + LEFT * LEFT_M), string.format("%g %g %g %g", minX, maxX, minY, maxY))
support.check("tangent equals the chord", near(first.edge.comp.tangent0.x, ALONG_M) and near(first.edge.comp.tangent1.x, ALONG_M))
local firstRecord = east.world.applied[1]
support.check("context asks for terrain alignment for the player", firstRecord.context.checkTerrainAlignment == true and firstRecord.context.player == 42)
support.check("commands are player initiated and do not ignore errors", firstRecord.playerInitiated == true and firstRecord.ignoreErrors == false)

-- North-heading strip: the grid starts at (0,80), runs north, and its left side is west (-x).
local north = runWorld(vec(0, 0, 0), vec(0, 80, 0))
local minXN, maxXN, minYN, maxYN = bounds(north.world)
support.check("north heading: new nodes span x -704 to 0 and y 80 to 944", north.ok and near(minXN, -LEFT * LEFT_M) and near(maxXN, 0) and near(minYN, 80) and near(maxYN, 80 + ALONG * ALONG_M),
  string.format("%g %g %g %g", minXN, maxXN, minYN, maxYN))

-- FLIP starts at the first node and heads from the second node to the first.
local flipped = runWorld(vec(100, 200, 0), vec(180, 200, 0), { flipStripDirection = true })
local minXF, maxXF, minYF, maxYF = bounds(flipped.world)
support.check("FLIP: the first edge starts at the first strip node", flipped.world.applied[1].edges[1].n0 == 10)
support.check("FLIP: new nodes run west and south from (100,200)", near(maxXF, 100) and near(minXF, 100 - ALONG * ALONG_M) and near(maxYF, 200) and near(minYF, 200 - LEFT * LEFT_M),
  string.format("%g %g %g %g", minXF, maxXF, minYF, maxYF))

-- buildToRight puts the side of the grid to the right of the heading.
local toRight = runWorld(vec(100, 200, 0), vec(180, 200, 0), { buildToRight = true })
local minXR, maxXR, minYR, maxYR = bounds(toRight.world)
support.check("buildToRight: the east heading grid spans y 200 down to -504 and keeps x 180 to 1044", toRight.ok and toRight.commands == GRID_EDGES and near(minXR, 180) and near(maxXR, 180 + ALONG * ALONG_M)
  and near(maxYR, 200) and near(minYR, 200 - LEFT * LEFT_M), string.format("%g %g %g %g", minXR, maxXR, minYR, maxYR))
support.check("buildToRight: the log names the side", toRight.out[1]:find("side right", 1, true) ~= nil and east.out[1]:find("side left", 1, true) ~= nil, toRight.out[1])
local rightLarge, leftLarge = 0, 0
for _, record in ipairs(toRight.world.applied) do
  for _, item in ipairs(record.edges) do
    if item.edge.comp.roadTemplate == LARGE_NEW then rightLarge = rightLarge + 1 end
  end
end
for _, record in ipairs(east.world.applied) do
  for _, item in ipairs(record.edges) do
    if item.edge.comp.roadTemplate == LARGE_NEW then leftLarge = leftLarge + 1 end
  end
end
support.check("buildToRight: the same streets are large as on the left side", rightLarge == leftLarge and rightLarge == 3 * ALONG + 3 * LEFT, rightLarge .. " " .. leftLarge)

-- maxLengthAlongM and maxLengthLeftM give the most blocks that fit under the length.
local fitted = runWorld(vec(100, 200, 0), vec(180, 200, 0), { maxLengthAlongM = 600, maxLengthLeftM = 500 })
support.check("max lengths: 600 m along fit 4 blocks of 144 m, 500 m to the side fit 5 blocks of 88 m", fitted.ok and fitted.commands == 4 * (5 + 1) + 5 * (4 + 1)
  and fitted.out[1]:find("blocks 4 5", 1, true) ~= nil, fitted.commands .. " " .. fitted.out[1])
local fitsExactly = runWorld(vec(100, 200, 0), vec(180, 200, 0), { maxLengthAlongM = 6 * ALONG_M, maxLengthLeftM = 8 * LEFT_M })
support.check("max lengths: a length equal to whole blocks keeps all of them", fitsExactly.ok and fitsExactly.out[1]:find("blocks 6 8", 1, true) ~= nil, fitsExactly.out[1])
local lengthWins = runWorld(vec(100, 200, 0), vec(180, 200, 0), { blocksAlong = 2, maxLengthAlongM = 600 })
support.check("max lengths: the length replaces the block count", lengthWins.ok and lengthWins.out[1]:find("blocks 4 8", 1, true) ~= nil, lengthWins.out[1])
local tooShort = runWorld(vec(100, 200, 0), vec(180, 200, 0), { maxLengthAlongM = 100 })
support.check("max lengths: a length under one block is an error and nothing is built", not tooShort.ok and tostring(tooShort.err):find("length_shorter_than_one_block", 1, true) ~= nil and tooShort.commands == 0, tostring(tooShort.err))

-- A failed command stops the run and reports where.
local failing = runWorld(vec(100, 200, 0), vec(180, 200, 0), nil, { first = 5, count = 3 })
support.check("a command that fails on every attempt stops the run", failing.commands == 7 and #failing.world.applied == 4)
support.check("the failure line names the command and the message", failing.out[#failing.out]:find("failed_at 5 5 of 110 Collision", 1, true) ~= nil, failing.out[#failing.out])
local retried = runWorld(vec(100, 200, 0), vec(180, 200, 0), nil, 5)
support.check("a command that fails once is sent again and the run completes", retried.ok and retried.commands == GRID_EDGES + 1 and #retried.world.applied == GRID_EDGES
  and table.concat(retried.out, "\n"):find("retry 5 5 attempt 1 Collision", 1, true) ~= nil and retried.out[#retried.out]:find("done 110", 1, true) ~= nil)

-- The two settings are independent: LARGE_EVERY_ALONG picks rows (streets that run along the heading, numbered to the left),
-- LARGE_EVERY_LEFT picks columns (streets that run to the left, numbered along the heading). 0 turns a kind off.
local function largeCounts(everyAlong, everyLeft)
  local result = runWorld(vec(100, 200, 0), vec(180, 200, 0), { largeEveryAlong = everyAlong, largeEveryLeft = everyLeft })
  local rows, columns, wrong = 0, 0, 0
  for _, record in ipairs(result.world.applied) do
    for _, item in ipairs(record.edges) do
      local p, q = result.world.nodes[item.n0].position, result.world.nodes[item.n1].position
      local runsAlong = near(p.y, q.y)
      local lineIndex = runsAlong and (p.y - 200) / LEFT_M or (p.x - 180) / ALONG_M
      local every = runsAlong and everyAlong or everyLeft
      local shouldBeLarge = every > 0 and lineIndex % every == 0
      local isLarge = item.edge.comp.roadTemplate == LARGE_NEW
      if isLarge ~= shouldBeLarge then wrong = wrong + 1 end
      if isLarge and runsAlong then rows = rows + 1 elseif isLarge then columns = columns + 1 end
    end
  end
  return result.ok, rows, columns, wrong
end

local okA, rowsA, columnsA, wrongA = largeCounts(2, 0)
support.check("along 2, left 0: rows 0, 2, 4, 6, 8 are large (40 segments), no column is", okA and rowsA == 5 * ALONG and columnsA == 0 and wrongA == 0, rowsA .. " " .. columnsA .. " " .. wrongA)
local okL, rowsL, columnsL, wrongL = largeCounts(0, 3)
support.check("along 0, left 3: columns 0, 3, 6 are large (24 segments), no row is", okL and rowsL == 0 and columnsL == 3 * LEFT and wrongL == 0, rowsL .. " " .. columnsL .. " " .. wrongL)
local okZ, rowsZ, columnsZ, wrongZ = largeCounts(0, 0)
support.check("along 0, left 0: no large street and no error", okZ and rowsZ == 0 and columnsZ == 0 and wrongZ == 0)

-- Before 1950 the new large template is not available and the old one is used.
local oldYear = runWorld(vec(100, 200, 0), vec(180, 200, 0), nil, nil, 1930)
local usedOld = false
for _, record in ipairs(oldYear.world.applied) do
  for _, item in ipairs(record.edges) do usedOld = usedOld or item.edge.comp.roadTemplate == LARGE_OLD end
end
support.check("in 1930 the large streets take the old large template", oldYear.ok and usedOld)

-- Without any large template the script stops before it sends anything.
local noLarge = runWorld(vec(100, 200, 0), vec(180, 200, 0), { largeStreetBaseNames = { "no_such_template" } })
support.check("no large template: the script stops and sends nothing", not noLarge.ok and noLarge.commands == 0)

-- Loading the module reads no api, and nothing in it creates a global variable: the game logs an error for each one a mod creates.
support.check("the module loads without the game api", loadedWithoutApi)
local leaked = {}
for key in pairs(_G) do
  if not globalsBefore[key] and key ~= "api" then leaked[#leaked + 1] = tostring(key) end
end
support.check("loading and running the module creates no global variable", #leaked == 0, table.concat(leaked, ","))

-- The strip, its owner and its decorations are copied when the plan is made: wiping them after the first command changes nothing.
local stale = runWorld(vec(100, 200, 0), vec(180, 200, 0), nil, nil, nil, 1)
local staleBad, staleEdges = 0, 0
for _, record in ipairs(stale.world.applied) do
  for _, item in ipairs(record.edges) do
    staleEdges = staleEdges + 1
    local comp = item.edge.comp
    local named = comp.roadTemplate == "town_medium" or comp.roadTemplate == LARGE_NEW
    if not named or comp.typeIndex ~= -1 or comp.distance ~= 0 or comp.edgeDecorations == nil or item.edge.playerOwned == nil or item.edge.playerOwned.player ~= OWNER_PLAYER then
      staleBad = staleBad + 1
    end
  end
end
support.check("views of the strip that the engine wipes after command 1 change no later edge", stale.ok and staleEdges == GRID_EDGES and staleBad == 0, staleEdges .. " " .. staleBad)

-- Another mod can replace a node after a command (Smart Lanes does at a lane-count change): the next command finds the new node by position.
local replaced = runWorld(vec(100, 200, 0), vec(180, 200, 0), nil, nil, nil, nil, 1)
local staleCornerEdges, newCornerEdges = 0, 0
for index, record in ipairs(replaced.world.applied) do
  for _, item in ipairs(record.edges) do
    if index > 1 and (item.n0 == 11 or item.n1 == 11) then staleCornerEdges = staleCornerEdges + 1 end
    if item.n0 == REPLACED_CORNER_ID or item.n1 == REPLACED_CORNER_ID then newCornerEdges = newCornerEdges + 1 end
  end
end
support.check("a node that another mod replaced after command 1 is found again by position", replaced.ok and staleCornerEdges == 0 and newCornerEdges >= 1 and #replaced.world.applied == GRID_EDGES, staleCornerEdges .. " " .. newCornerEdges)

-- edgesPerCommand 0 builds the whole grid in one command. Every node is made once, with all its edges.
local whole = runWorld(vec(100, 200, 0), vec(180, 200, 0), { edgesPerCommand = 0 })
local wholeRecord = whole.world.applied[1]
local nodeUses = {}
for _, item in ipairs(wholeRecord and wholeRecord.edges or {}) do
  nodeUses[item.n0] = (nodeUses[item.n0] or 0) + 1
  nodeUses[item.n1] = (nodeUses[item.n1] or 0) + 1
end
local newNodeIds, junctions4 = 0, 0
for id, uses in pairs(nodeUses) do
  if id >= FIRST_NEW_ID then
    newNodeIds = newNodeIds + 1
    if uses == 4 then junctions4 = junctions4 + 1 end
  end
end
support.check("edgesPerCommand 0: one command with all 110 edges and the 62 new nodes", whole.ok and whole.commands == 1 and #wholeRecord.edges == GRID_EDGES and wholeRecord.newNodes == GRID_NODES - 1, whole.commands .. " " .. (wholeRecord and #wholeRecord.edges or "-"))
support.check("edgesPerCommand 0: the inner nodes have all four edges", newNodeIds == GRID_NODES - 1 and junctions4 == (ALONG - 1) * (LEFT - 1), junctions4)
support.check("edgesPerCommand 0: the log shows one built line for all segments", whole.out[3]:find("built 1 110 large 42", 1, true) ~= nil and whole.out[#whole.out]:find("done 110", 1, true) ~= nil, whole.out[3])

-- edgesPerCommand 5: 29 commands of at most 5 edges, in order.
local batches = runWorld(vec(100, 200, 0), vec(180, 200, 0), { edgesPerCommand = 5 })
local maxEdges, totalEdges = 0, 0
for _, record in ipairs(batches.world.applied) do
  maxEdges = math.max(maxEdges, #record.edges)
  totalEdges = totalEdges + #record.edges
end
support.check("edgesPerCommand 5: 22 commands, at most 5 edges each, 110 edges", batches.ok and batches.commands == 22 and maxEdges == 5 and totalEdges == GRID_EDGES, batches.commands .. " " .. maxEdges .. " " .. totalEdges)
support.check("edgesPerCommand 5: the log names the segment ranges", batches.out[3]:find("built 1 5 ", 1, true) ~= nil and batches.out[#batches.out - 1]:find("built 106 110 ", 1, true) ~= nil, batches.out[3] .. " | " .. batches.out[#batches.out - 1])

-- explicitNodeConfigs adds one empty node config for each new node, and the default adds none.
local function configCount(result)
  local count, mismatched = 0, 0
  for _, record in ipairs(result.world.applied) do
    count = count + #record.configs
    if #record.configs ~= 0 and #record.configs ~= record.newNodes then mismatched = mismatched + 1 end
  end
  return count, mismatched
end
local defaultConfigs = configCount(east)
local plainGrid = runWorld(vec(100, 200, 0), vec(180, 200, 0), { largeEveryAlong = 0, largeEveryLeft = 0 })
local plainConfigs = configCount(plainGrid)
local oneKindLarge = runWorld(vec(100, 200, 0), vec(180, 200, 0), { largeEveryAlong = 0 })
local oneKindConfigs = configCount(oneKindLarge)
local switchedOff = runWorld(vec(100, 200, 0), vec(180, 200, 0), { explicitNodeConfigs = false })
local switchedOffConfigs = configCount(switchedOff)
local withConfigs = runWorld(vec(100, 200, 0), vec(180, 200, 0), { explicitNodeConfigs = true })
local withCount, withMismatch = configCount(withConfigs)
local firstConfig = withConfigs.world.applied[1].configs[1]
support.check("default with large streets: a node config for each of the 62 new nodes", defaultConfigs == GRID_NODES - 1, defaultConfigs)
support.check("default without large streets: no node config", plainGrid.ok and plainConfigs == 0, plainConfigs)
support.check("default with one kind of large street: node configs are on", oneKindLarge.ok and oneKindConfigs == GRID_NODES - 1, oneKindConfigs)
support.check("explicitNodeConfigs=false switches the configs off with large streets", switchedOff.ok and switchedOffConfigs == 0, switchedOffConfigs)
support.check("explicitNodeConfigs: one empty config for each of the 62 new nodes", withConfigs.ok and withCount == GRID_NODES - 1 and withMismatch == 0, withCount .. " " .. withMismatch)
support.check("explicitNodeConfigs: the config has no lane connections and no crosswalks", firstConfig ~= nil and #firstConfig.lanes == 0 and #firstConfig.crosswalks == 0)
local wholeConfigs = runWorld(vec(100, 200, 0), vec(180, 200, 0), { explicitNodeConfigs = true, edgesPerCommand = 0 })
local wholeCount, wholeMismatch = configCount(wholeConfigs)
support.check("explicitNodeConfigs with one command: all 62 configs are in that command", wholeConfigs.commands == 1 and wholeCount == GRID_NODES - 1 and wholeMismatch == 0, wholeCount)

-- Bend stubs: a corner that keeps two streets gets a short plain street out of it, and the street is removed again.
local function countEdges(result)
  local count = 0
  for id in pairs(result.edges) do
    if id >= FIRST_EDGE_ID then count = count + 1 end
  end
  return count
end
local function countNewNodes(result)
  local count = 0
  for id in pairs(result.world.nodes) do
    if id >= FIRST_NEW_ID then count = count + 1 end
  end
  return count
end
local function logText(result) return table.concat(result.out, "\n") end
local STUB_END = 30 / math.sqrt(2)
local stubbed = runWorld(vec(100, 200, 0), vec(180, 200, 0), { laneConnections = "stub_remove" })
support.check("stub_remove: 110 segment commands, then a build and a removal for each of the 3 corners", stubbed.ok and stubbed.commands == GRID_EDGES + 6, stubbed.commands)
local expectedStarts = { { 180 + ALONG * ALONG_M, 200 }, { 180, 200 + LEFT * LEFT_M }, { 180 + ALONG * ALONG_M, 200 + LEFT * LEFT_M } }
local expectedEnds = {
  { expectedStarts[1][1] + STUB_END, expectedStarts[1][2] - STUB_END },
  { expectedStarts[2][1] - STUB_END, expectedStarts[2][2] + STUB_END },
  { expectedStarts[3][1] + STUB_END, expectedStarts[3][2] + STUB_END },
}
local stubsOk, removalsOk = true, true
for corner = 1, 3 do
  local buildRecord = stubbed.world.applied[GRID_EDGES + corner * 2 - 1]
  local removeRecord = stubbed.world.applied[GRID_EDGES + corner * 2]
  local stub = buildRecord and buildRecord.edges[1]
  local startNode = stub and stubbed.world.nodes[stub.n0]
  if not (stub and startNode and #buildRecord.edges == 1 and buildRecord.newNodes == 1 and not buildRecord.removes
      and near(startNode.position.x, expectedStarts[corner][1]) and near(startNode.position.y, expectedStarts[corner][2])
      and stub.edge.comp.roadTemplate == "town_medium"
      and near(stub.edge.comp.position1.x, expectedEnds[corner][1]) and near(stub.edge.comp.position1.y, expectedEnds[corner][2])) then
    stubsOk = false
  end
  if not (removeRecord and removeRecord.removedEdges and stub and #removeRecord.removedEdges == 1 and removeRecord.removedEdges[1] == stub.id
      and #removeRecord.removedNodes == 1 and removeRecord.removedNodes[1] == stub.n1 and #removeRecord.edges == 0) then
    removalsOk = false
  end
end
support.check("each stub is one plain street of 30 m out of the corner, away from the grid", stubsOk)
support.check("each removal takes out that stub street and its end node and nothing else", removalsOk)
support.check("after the removals only the 110 grid streets and 62 new nodes are left", countEdges(stubbed) == GRID_EDGES and countNewNodes(stubbed) == GRID_NODES - 1, countEdges(stubbed) .. " " .. countNewNodes(stubbed))
support.check("the log names each corner and ends with done",
  stubbed.out[#stubbed.out]:find("done 110", 1, true) ~= nil and logText(stubbed):find("bend_stub 6:0 built", 1, true) ~= nil
  and logText(stubbed):find("bend_stub 0:8 removed", 1, true) ~= nil and logText(stubbed):find("bend_stub 6:8 removed", 1, true) ~= nil)
local kept = runWorld(vec(100, 200, 0), vec(180, 200, 0), { laneConnections = "stub_keep" })
support.check("stub_keep: the 3 stubs are built and stay", kept.ok and kept.commands == GRID_EDGES + 3 and countEdges(kept) == GRID_EDGES + 3 and countNewNodes(kept) == GRID_NODES - 1 + 3, kept.commands .. " " .. countEdges(kept))
local noStubs = runWorld(vec(100, 200, 0), vec(180, 200, 0), { laneConnections = "off" })
support.check("laneConnections off: no stub and no write", noStubs.commands == GRID_EDGES and countEdges(noStubs) == GRID_EDGES)
local byDefault = runWorld(vec(100, 200, 0), vec(180, 200, 0), { defaultBend = true })
support.check("default with large streets: the lane connections of all 63 grid nodes are written, one command each", byDefault.commands == GRID_EDGES + GRID_NODES and countEdges(byDefault) == GRID_EDGES, byDefault.commands)
local byDefaultPlain = runWorld(vec(100, 200, 0), vec(180, 200, 0), { defaultBend = true, largeEveryAlong = 0, largeEveryLeft = 0 })
support.check("default without large streets: no write and no stub", byDefaultPlain.commands == GRID_EDGES)
local byDefaultNoConfigs = runWorld(vec(100, 200, 0), vec(180, 200, 0), { defaultBend = true, explicitNodeConfigs = false })
support.check("default with explicitNodeConfigs=false: no write and no stub", byDefaultNoConfigs.commands == GRID_EDGES)
local rightStubs = runWorld(vec(100, 200, 0), vec(180, 200, 0), { laneConnections = "stub_remove", buildToRight = true })
local rightEnds = {}
for corner = 1, 3 do
  local buildRecord = rightStubs.world.applied[GRID_EDGES + corner * 2 - 1]
  local stub = buildRecord and buildRecord.edges[1]
  if stub then rightEnds[corner] = stub.edge.comp.position1 end
end
support.check("buildToRight: a stub is built and removed at each corner, pointing away from the grid", rightStubs.commands == GRID_EDGES + 6 and countEdges(rightStubs) == GRID_EDGES
  and #rightEnds == 3 and rightEnds[1].x > 1044 and rightEnds[2].y < 200 - LEFT * LEFT_M + 1 and rightEnds[2].x < 180 and rightEnds[3].x > 1044 and rightEnds[3].y < 200 - LEFT * LEFT_M + 1, rightStubs.commands)
local stubFails = runWorld(vec(100, 200, 0), vec(180, 200, 0), { laneConnections = "stub_remove" }, GRID_EDGES + 1)
support.check("a stub that the game refuses is logged and the next corner still runs", stubFails.ok and stubFails.commands == GRID_EDGES + 5
  and logText(stubFails):find("bend_stub 6:0 failed Collision", 1, true) ~= nil and stubFails.out[#stubFails.out]:find("done 110", 1, true) ~= nil, stubFails.commands)
local oneBlock = runWorld(vec(100, 200, 0), vec(180, 200, 0), { laneConnections = "stub_remove", blocksAlong = 1, blocksLeft = 1 })
support.check("a 1 by 1 grid has 3 bend corners and gets 3 stubs", oneBlock.ok and oneBlock.commands == 4 + 6 and countEdges(oneBlock) == 4, oneBlock.commands)
local oneRow = runWorld(vec(100, 200, 0), vec(180, 200, 0), { laneConnections = "stub_remove", blocksLeft = 0 })
support.check("a grid without blocks to the left has no bend corner and ends with done", oneRow.ok and oneRow.out[#oneRow.out]:find("done", 1, true) ~= nil and oneRow.commands == ALONG, oneRow.commands)

-- The removal of a stub writes the node config of the corner again without the connections that touch the stub and without crosswalks.
local configStubbed = runWorld(vec(100, 200, 0), vec(180, 200, 0), { laneConnections = "stub_remove" })
local configsOk, configsDetail = true, ""
for corner = 1, 3 do
  local buildRecord = configStubbed.world.applied[GRID_EDGES + corner * 2 - 1]
  local removeRecord = configStubbed.world.applied[GRID_EDGES + corner * 2]
  local stub = buildRecord and buildRecord.edges[1]
  local rewritten = removeRecord and removeRecord.rewrittenConfigs[1]
  if not (stub and rewritten and removeRecord.removedConfigs and #removeRecord.removedConfigs == 1 and removeRecord.removedConfigs[1] == stub.n0
      and rewritten.node == stub.n0 and #rewritten.lanes == 2 and #rewritten.crosswalks == 0) then
    configsOk = false
    configsDetail = configsDetail .. corner .. ":" .. tostring(rewritten and #rewritten.lanes) .. " "
  else
    for _, lane in ipairs(rewritten.lanes) do
      if lane.segment0 == stub.id or lane.segment1 == stub.id or lane.segment0 == lane.segment1 then configsOk = false end
    end
  end
end
support.check("the removal of a stub rewrites the node config with the 2 connections between the grid streets and no crosswalk", configsOk, configsDetail)
local diagText = table.concat(configStubbed.out, "\n")
support.check("the log gives the connections kept", diagText:find("bend_stub 6:0 config_kept 2 of 6", 1, true) ~= nil, diagText:match("bend_stub 6:0 config_kept[^\n]*") or "no line")
support.check("the log gives the connections before the removal and after it for each corner", diagText:find("bend_stub 6:0 connections_ready polls 0 streets 3 connections 6", 1, true) ~= nil
  and diagText:find("bend_stub 6:0 after streets 2", 1, true) ~= nil and diagText:find("bend_stub 6:8 after streets 2", 1, true) ~= nil, diagText:match("bend_stub 6:0 connections_ready[^\n]*") or "no line")

-- The stub stays until another mod has written the lane connections of the node.
connectionDelayTicks = 3
local delayed = runWorld(vec(100, 200, 0), vec(180, 200, 0), { laneConnections = "stub_remove" })
support.check("the removal waits for the connections: 3 wait commands for each corner, then the removal", delayed.ok and delayed.commands == GRID_EDGES + 3 * (1 + 3 + 1) and countEdges(delayed) == GRID_EDGES, delayed.commands)
support.check("the log gives the number of polls", table.concat(delayed.out, "\n"):find("bend_stub 6:0 connections_ready polls 3 streets 3 connections 6", 1, true) ~= nil)
connectionDelayTicks = math.huge
local neverReady = runWorld(vec(100, 200, 0), vec(180, 200, 0), { laneConnections = "stub_remove" })
support.check("connections that never appear leave the stubs in place and are logged", neverReady.ok and countEdges(neverReady) == GRID_EDGES + 3
  and table.concat(neverReady.out, "\n"):find("bend_stub 6:0 wait_timeout polls 150 streets 3 connections 0", 1, true) ~= nil and neverReady.out[#neverReady.out]:find("done 110", 1, true) ~= nil)
connectionDelayTicks = 0
local keptNoRewrite = runWorld(vec(100, 200, 0), vec(180, 200, 0), { laneConnections = "stub_keep" })
local rewrites = 0
for _, record in ipairs(keptNoRewrite.world.applied) do rewrites = rewrites + #record.rewrittenConfigs end
support.check("stub_keep: no node config is rewritten", rewrites == 0)


-- laneConnections "own": the function writes the lane connections of every grid node, every street into every other street.
local own = runWorld(vec(100, 200, 0), vec(180, 200, 0), { laneConnections = "own" })
support.check("own: one write command for each of the 63 grid nodes after the 110 segments", own.ok and own.commands == GRID_EDGES + GRID_NODES and countEdges(own) == GRID_EDGES, own.commands)
local function writeOf(result, alongIndex, leftIndex) return result.world.applied[GRID_EDGES + alongIndex * (LEFT + 1) + leftIndex + 1] end
local cornersOk, cornersDetail = true, ""
for _, corner in ipairs({ { 6, 0 }, { 0, 8 }, { 6, 8 } }) do
  local record = writeOf(own, corner[1], corner[2])
  local written = record and record.rewrittenConfigs[1]
  if not (written and #record.edges == 0 and record.newNodes == 0 and record.removedConfigs and #record.removedConfigs == 1 and record.removedConfigs[1] == written.node
      and #written.lanes == 6 and #written.crosswalks == 0) then
    cornersOk = false
    cornersDetail = cornersDetail .. corner[1] .. ":" .. corner[2] .. " shape "
  else
    for _, lane in ipairs(written.lanes) do
      if not (lane.segment0 ~= lane.segment1 and lane.lane0 >= 1 and lane.lane0 <= 3 and lane.lane1 >= 4 and lane.lane1 <= 6 and lane.lane0 + lane.lane1 == 7 and lane.withRoad == true and lane.withTram == false) then
        cornersOk = false
        cornersDetail = cornersDetail .. corner[1] .. ":" .. corner[2] .. " lane " .. lane.lane0 .. ">" .. lane.lane1 .. " "
      end
    end
  end
end
support.check("own: a corner of two large streets gets the 6 mirrored lane pairs 3 to 4, 2 to 5, 1 to 6, in both directions", cornersOk, cornersDetail)
local inner = writeOf(own, 1, 1).rewrittenConfigs[1]
support.check("own: a crossing of four one-lane streets gets 12 connections, each street into the 3 others", #inner.lanes == 12, #inner.lanes)
support.check("own: a node that already has a crosswalk keeps it", #inner.crosswalks == 1 and inner.crosswalks[1] == 501, #inner.crosswalks)
nodesWithoutCrosswalks = true
local ownBare = runWorld(vec(100, 200, 0), vec(180, 200, 0), { laneConnections = "own" })
nodesWithoutCrosswalks = false
local bareInner = writeOf(ownBare, 1, 1).rewrittenConfigs[1]
local bareCorner = writeOf(ownBare, 6, 8).rewrittenConfigs[1]
local crosswalkSegments = true
for _, segment in ipairs(bareInner.crosswalks) do crosswalkSegments = crosswalkSegments and segment >= FIRST_EDGE_ID end
support.check("own: a crossing of four streets without crosswalks gets one on each street, a bend of two streets gets none",
  #bareInner.crosswalks == 4 and crosswalkSegments and #bareCorner.crosswalks == 0, #bareInner.crosswalks .. "/" .. #bareCorner.crosswalks)
local ownText = table.concat(own.out, "\n")
support.check("own: the log gives the counts and the run ends with done", ownText:find("lane_connections written 63 failed 0 refused 0 skipped 0", 1, true) ~= nil and own.out[#own.out]:find("done 110", 1, true) ~= nil)
local ownFails = runWorld(vec(100, 200, 0), vec(180, 200, 0), { laneConnections = "own" }, GRID_EDGES + 1)
support.check("own: a write that the game refuses is logged and the next node still runs", ownFails.ok and ownFails.commands == GRID_EDGES + GRID_NODES
  and table.concat(ownFails.out, "\n"):find("lane_connections 0:0 failed Collision", 1, true) ~= nil and table.concat(ownFails.out, "\n"):find("written 62 failed 1", 1, true) ~= nil)
refuseLaneLists = true
local ownRefused = runWorld(vec(100, 200, 0), vec(180, 200, 0), { laneConnections = "own" })
refuseLaneLists = false
support.check("own: a game that takes no connection list sends nothing and logs the refusal", ownRefused.ok and ownRefused.commands == GRID_EDGES
  and table.concat(ownRefused.out, "\n"):find("lane_connections 0:0 refused", 1, true) ~= nil and table.concat(ownRefused.out, "\n"):find("written 0 failed 0 refused 63", 1, true) ~= nil and ownRefused.out[#ownRefused.out]:find("done 110", 1, true) ~= nil)

do
-- The lane rules at a node. The large streets have lanes 1 to 3 into the node and 4 to 6 out of it, the one-lane streets have lane 1 in and lane 2 out.
local function bySource(lanes)
  local groups = {}
  for _, lane in ipairs(lanes) do
    groups[lane.segment0] = groups[lane.segment0] or {}
    table.insert(groups[lane.segment0], lane)
  end
  return groups
end
local function groupSizes(groups)
  local sizes = {}
  for _, group in pairs(groups) do sizes[#sizes + 1] = #group end
  table.sort(sizes)
  return table.concat(sizes, ",")
end
local function laneSet(group)
  local seen = {}
  for _, lane in ipairs(group) do seen[lane.lane0] = true end
  return seen
end

-- A crossing of two large streets: straight ahead lane to lane from the lanes 3 and 2, a right turn only from the curb lane 1, which does not go straight, into the curb lane 6, a left turn only from the lane next to the centre line 3 into the lane next to the centre line 4.
local crossing = writeOf(own, 3, 4).rewrittenConfigs[1]
local crossingGroups = bySource(crossing.lanes)
support.check("crossing of large streets: 16 connections, 4 from each of the 4 streets", #crossing.lanes == 16 and groupSizes(crossingGroups) == "4,4,4,4", #crossing.lanes .. " " .. groupSizes(crossingGroups))
local crossingOk, crossingDetail = true, ""
for source, group in pairs(crossingGroups) do
  local perTarget = {}
  for _, lane in ipairs(group) do
    perTarget[lane.segment1] = perTarget[lane.segment1] or {}
    table.insert(perTarget[lane.segment1], lane)
  end
  local straightTargets, turnLanes = 0, {}
  for target, lanes in pairs(perTarget) do
    if #lanes == 2 then
      straightTargets = straightTargets + 1
      for _, lane in ipairs(lanes) do if lane.lane0 + lane.lane1 ~= 7 then crossingOk = false; crossingDetail = crossingDetail .. source .. " straight " end end
    elseif #lanes == 1 then
      turnLanes[#turnLanes + 1] = lanes[1]
    else
      crossingOk = false
      crossingDetail = crossingDetail .. source .. " count " .. #lanes .. " "
    end
  end
  table.sort(turnLanes, function(first, second) return first.lane0 < second.lane0 end)
  if not (straightTargets == 1 and #turnLanes == 2 and turnLanes[1].lane0 == 1 and turnLanes[1].lane1 == 6 and turnLanes[2].lane0 == 3 and turnLanes[2].lane1 == 4) then
    crossingOk = false
    crossingDetail = crossingDetail .. source .. " turns "
  end
end
support.check("crossing of large streets: straight on from the lanes 3 and 2 only, right turn 1 to 6 only from the curb lane, left turn 3 to 4", crossingOk, crossingDetail)

-- The stem of a T has no street straight ahead: its inner lane goes left and its two outer lanes go right, the curb lane into the curb lane and the next lane into the next lane, so every lane has a connection.
local stemNode = writeOf(own, 0, 4).rewrittenConfigs[1]
local stemGroups = bySource(stemNode.lanes)
local stemSource
for source, group in pairs(stemGroups) do
  local distinctTargets, count = {}, 0
  for _, lane in ipairs(group) do
    if not distinctTargets[lane.lane1] then distinctTargets[lane.lane1] = true; count = count + 1 end
  end
  local edge = own.edges[source]
  if #group == 3 and math.abs(edge.position0.y - edge.position1.y) < 1e-6 then stemSource = source end
end
local stemTargets = {}
for _, lane in ipairs(stemSource and stemGroups[stemSource] or {}) do stemTargets[lane.lane0] = lane.lane1 end
support.check("stem of a T: 10 connections, every lane of the stem has one, the inner lane 3 goes left into lane 4, the lane 2 goes right into lane 5, the curb lane 1 goes right into lane 6",
  #stemNode.lanes == 10 and groupSizes(stemGroups) == "3,3,4" and stemTargets[3] == 4 and stemTargets[2] == 5 and stemTargets[1] == 6, #stemNode.lanes .. " " .. groupSizes(stemGroups))

-- A large street crossing a one-lane street: every lane of every street has a connection.
local mixed = writeOf(own, 1, 4).rewrittenConfigs[1]
local mixedGroups = bySource(mixed.lanes)
local mixedCovered = true
for _, group in pairs(mixedGroups) do
  local seen = laneSet(group)
  local large = seen[3] ~= nil or seen[2] ~= nil
  if large and not (seen[1] and seen[2] and seen[3]) then mixedCovered = false end
  if not large and not seen[1] then mixedCovered = false end
end
support.check("large street crossing a one-lane street: 14 connections and every incoming lane has one", #mixed.lanes == 14 and mixedCovered, #mixed.lanes .. " " .. groupSizes(mixedGroups))

-- A corner where a large street meets a one-lane street: the 3 lanes merge into the single lane, and the single lane goes into all 3 lanes.
local narrow = runWorld(vec(100, 200, 0), vec(180, 200, 0), { laneConnections = "own", largeEveryAlong = 1, largeEveryLeft = 0 })
local narrowCorner = narrow.world.applied[GRID_EDGES + 6 * (LEFT + 1) + 1].rewrittenConfigs[1]
local merged, widened = 0, 0
for _, lane in ipairs(narrowCorner.lanes) do
  if lane.lane0 >= 1 and lane.lane0 <= 3 and lane.lane1 == 2 then merged = merged + 1 end
  if lane.lane0 == 1 and lane.lane1 >= 4 and lane.lane1 <= 6 then widened = widened + 1 end
end
support.check("corner of a large and a one-lane street: 3 lanes merge into the one lane, the one lane fans out into all 3 lanes of the large street", #narrowCorner.lanes == 6 and merged == 3 and widened == 3, #narrowCorner.lanes .. " " .. merged .. " " .. widened)
end

-- Every option replaces its default: a 2 by 3 block grid with blocks of 100 m along and 50 m to the left.
local small = runWorld(vec(100, 200, 0), vec(180, 200, 0), { blocksAlong = 2, blocksLeft = 3, blockLengthAlongM = 100, blockLengthLeftM = 50, largeEveryAlong = 0, largeEveryLeft = 0, cameraSearchRadiusM = 90, nodeSnapRadiusM = 2 })
local alongCount, leftCount, otherCount = 0, 0, 0
for _, record in ipairs(small.world.applied) do
  for _, item in ipairs(record.edges) do
    local p, q = small.world.nodes[item.n0].position, small.world.nodes[item.n1].position
    local length = math.sqrt((q.x - p.x) ^ 2 + (q.y - p.y) ^ 2)
    if near(length, 100) then alongCount = alongCount + 1 elseif near(length, 50) then leftCount = leftCount + 1 else otherCount = otherCount + 1 end
  end
end
support.check("options: 8 streets of 100 m and 9 streets of 50 m", small.ok and alongCount == 2 * 4 and leftCount == 3 * 3 and otherCount == 0, alongCount .. " " .. leftCount .. " " .. otherCount)
support.check("options: the search radius reaches the octree", small.octreeCalls[1].radius == 90)
support.check("options: the snap radius reaches the octree", small.octreeCalls[2].radius == 2)

-- A grid that leaves the map sends nothing.
local offMap = runWorld(vec(4900, 0, 0), vec(4980, 0, 0))
support.check("a grid that leaves the map sends nothing", offMap.ok and offMap.commands == 0 and offMap.out[1]:find("fits_map false", 1, true) ~= nil)

-- Traffic lights: a world of junctions, each with a reason to be skipped except nodes 1 and 7.
local OTHER_PLAYER = 99
local CUSTOM_LIGHT_CONFIG = { custom = true }
local function runLights(entry, failCommand)
  local major, minor = { laneConfigs = laneLayout("major", 2) }, { laneConfigs = laneLayout("minor", 1) }
  local edges = { [101] = major, [102] = major, [103] = minor, [104] = minor, [105] = minor, [106] = major }
  local streetsOf = { [1] = { 101, 102, 103 }, [2] = { 101, 102, 103, 104 }, [3] = { 103, 104, 105 }, [4] = { 106, 102, 103 },
    [5] = { 101, 102, 103 }, [6] = { 101, 103 }, [7] = { 101, 102, 103 } }
  local lightNodes = { [1] = true, [2] = true, [3] = true, [4] = true, [6] = true, [7] = true }
  local configs = { [2] = { trafficLightPreference = "NO" }, [7] = { trafficLightPreference = "AUTO", trafficLightConfig = CUSTOM_LIGHT_CONFIG } }
  local queue, sent, out = {}, {}, {}
  _G.api = {
    type = {
      ComponentType = { BASE_EDGE = "BASE_EDGE", PLAYER_OWNED = "PLAYER_OWNED", BASE_NODE_CONFIG = "BASE_NODE_CONFIG", BASE_NODE_TRAFFIC_LIGHT = "BASE_NODE_TRAFFIC_LIGHT" },
      enum = { TransportMode = { PERSON = 0 }, TrafficLightPreference = { NO = "NO", AUTO = "AUTO" } },
      TrafficLightConfig = { new = function() return { fresh = true } end },
    },
    engine = {
      util = { getPlayer = function() return 42 end,
        proposal = { createTrafficLightProposal = function(node, config, preference) return { node = node, config = config, preference = preference } end } },
      system = { streetSystem = { getNode2StreetEdgeMap = function() return streetsOf end } },
      getComponent = function(entity, component)
        if component == "BASE_EDGE" then return edges[entity] end
        if component == "PLAYER_OWNED" then return { player = entity == 106 and OTHER_PLAYER or 42 } end
        if component == "BASE_NODE_CONFIG" then return configs[entity] end
        if component == "BASE_NODE_TRAFFIC_LIGHT" then return lightNodes[entity] and {} or nil end
      end,
    },
    cmd = {
      makeWorldBuildProposalCmd = function(proposal, context, ignoreErrors, playerInitiated) return { proposal = proposal, context = context, ignoreErrors = ignoreErrors, playerInitiated = playerInitiated } end,
      sendCommand = function(cmd, callback) queue[#queue + 1] = { cmd = cmd, callback = callback } end,
    },
  }
  local realPrint = print
  _G.print = function(...) out[#out + 1] = table.concat({ ... }, " ") end
  local ok, err = pcall(entry)
  local sequential = true
  while ok and #queue > 0 do
    sequential = sequential and #queue == 1
    local item = table.remove(queue, 1)
    sent[#sent + 1] = item.cmd
    if #sent == failCommand then
      item.callback({ resultProposalData = { errorState = { messages = { "Collision" } } } }, false)
    else
      item.callback({}, true)
    end
  end
  _G.print = realPrint
  return { ok = ok, err = err, sent = sent, out = out, sequential = sequential }
end

local lights = runLights(gridBuilder.removeLights)
support.check("remove lights: one command per qualifying node, each sent after the previous one finished", lights.ok and #lights.sent == 2 and lights.sequential, lights.err or #lights.sent)
support.check("remove lights: the proposal sets the preference NO on the node, without context and not player initiated",
  lights.sent[1].proposal.node == 1 and lights.sent[2].proposal.node == 7 and lights.sent[1].proposal.preference == "NO" and lights.sent[2].proposal.preference == "NO"
  and lights.sent[1].context == nil and lights.sent[1].playerInitiated == false and lights.sent[1].ignoreErrors == false)
support.check("remove lights: a node without a config gets a new light config, a node with one keeps its own",
  lights.sent[1].proposal.config.fresh == true and lights.sent[2].proposal.config == CUSTOM_LIGHT_CONFIG)
support.check("remove lights: the run ends with the counts", lights.out[#lights.out]:find("lights_done nodes 2 changed 2 skipped 0 failed 0", 1, true) ~= nil, lights.out[#lights.out])
local lightsFail = runLights(gridBuilder.removeLights, 2)
support.check("remove lights: a refused command is logged with the game message and the run goes on",
  lightsFail.ok and lightsFail.out[1]:find("lights_failed 7 Collision", 1, true) ~= nil and lightsFail.out[#lightsFail.out]:find("lights_done nodes 2 changed 1 skipped 0 failed 1", 1, true) ~= nil,
  table.concat(lightsFail.out, " | "))

-- Left turns. Node 1 is a T junction whose two major streets form an L: S1 leaves to the west, S2 arrives from the north, the minor S3 leaves to the east.
-- Major street lanes in build order: pedestrian, outer bus (back), inner normal (back), inner normal (forward), outer bus (forward), pedestrian.
-- Seen from a node the positions of a major street are: incoming bus 1, incoming normal 2, outgoing normal 3, outgoing bus 4. The minor street has incoming normal 1 and outgoing normal 2.
local function lane(forward, ...)
  local modes = {}
  for _, mode in ipairs({ ... }) do modes[mode] = true end
  return { forward = forward, transportModes = modes }
end
local PERSON, CAR, BUS = 0, 2, 3
local function majorLanes() return { lane(false, PERSON), lane(false, BUS), lane(false, CAR, BUS), lane(true, CAR, BUS), lane(true, BUS), lane(true, PERSON) } end
local function minorLanes() return { lane(false, PERSON), lane(false, CAR, BUS), lane(true, CAR, BUS), lane(true, PERSON) } end
local function connection(s0, l0, s1, l1, withRoad)
  return { segment0 = s0, lane0 = l0, segment1 = s1, lane1 = l1, withRoad = withRoad ~= false, withTram = false }
end

-- Every incoming vehicle lane of a street to every outgoing vehicle lane of every other street, and one U-turn on the minor street.
local function defaultConnections(s1, s2, s3)
  local incoming = { [s1] = { 1, 2 }, [s2] = { 1, 2 }, [s3] = { 1 } }
  local outgoing = { [s1] = { 3, 4 }, [s2] = { 3, 4 }, [s3] = { 2 } }
  local list = {}
  for _, from in ipairs({ s1, s2, s3 }) do
    for _, to in ipairs({ s1, s2, s3 }) do
      if from ~= to then
        for _, l0 in ipairs(incoming[from]) do
          for _, l1 in ipairs(outgoing[to]) do list[#list + 1] = connection(from, l0, to, l1) end
        end
      end
    end
  end
  list[#list + 1] = connection(s3, 1, s3, 2)
  list[#list + 1] = connection(s1, 0, s2, 0, false)
  return list
end

local function runTurns(failCommand, entryPoint)
  local edges, streetsOf, configs, lights = {}, {}, {}, {}
  -- Junction n has the streets 10n+1 (west, starts at n), 10n+2 (from the north, ends at n), 10n+3 (east, starts at n).
  for node = 1, 4 do
    local s1, s2, s3 = node * 10 + 1, node * 10 + 2, node * 10 + 3
    edges[s1] = { node0 = node, node1 = 900 + node, tangent0 = vec(-1, 0, 0), tangent1 = vec(-1, 0, 0), laneConfigs = majorLanes() }
    edges[s2] = { node0 = 800 + node, node1 = node, tangent0 = vec(0, -1, 0), tangent1 = vec(0, -1, 0), laneConfigs = majorLanes() }
    edges[s3] = { node0 = node, node1 = 700 + node, tangent0 = vec(1, 0, 0), tangent1 = vec(1, 0, 0), laneConfigs = minorLanes() }
    streetsOf[node] = { s1, s2, s3 }
  end
  local function setConfig(node, connections) configs[node] = connections end
  setConfig(1, defaultConnections(11, 12, 13))
  setConfig(2, defaultConnections(21, 22, 23))
  lights[2] = true
  setConfig(3, { connection(31, 1, 32, 3), connection(31, 0, 32, 3) })
  setConfig(4, { connection(41, 1, 42, 4), connection(41, 2, 42, 3), connection(43, 1, 43, 2) })
  local queue, sent, out = {}, {}, {}
  _G.api = {
    type = {
      ComponentType = { BASE_EDGE = "BASE_EDGE", PLAYER_OWNED = "PLAYER_OWNED", BASE_NODE_CONFIG = "BASE_NODE_CONFIG", BASE_NODE_TRAFFIC_LIGHT = "BASE_NODE_TRAFFIC_LIGHT" },
      enum = { TransportMode = { PERSON = PERSON, CAR = CAR, BUS = BUS }, TrafficLightPreference = { NO = "NO" } },
      TrafficLightConfig = { new = function() return { fresh = true } end },
      BaseNodeLaneConnectionAndEntity = { new = function() return { comp = {} } end },
      SimpleProposal = { new = function() return { streetProposal = {} } end },
      Context = { new = function() return {} end },
    },
    engine = {
      util = { getPlayer = function() return 42 end,
        proposal = { createTrafficLightProposal = function(node, config, preference) return { node = node, config = config, preference = preference } end } },
      system = { streetSystem = { getNode2StreetEdgeMap = function() return streetsOf end, getNodeStreetSegments = function(node) return streetsOf[node] end } },
      getComponent = function(entity, component)
        if component == "BASE_EDGE" then return edges[entity] end
        if component == "PLAYER_OWNED" then return { player = 42 } end
        if component == "BASE_NODE_TRAFFIC_LIGHT" then return lights[entity] and {} or nil end
        if component == "BASE_NODE_CONFIG" then
          local copy = {}
          for index, item in ipairs(configs[entity]) do copy[index] = item end
          return { laneConnections = copy, crosswalks = { 501 } }
        end
      end,
    },
    cmd = {
      makeWorldBuildProposalCmd = function(proposal, context, ignoreErrors, playerInitiated) return { proposal = proposal, context = context, ignoreErrors = ignoreErrors, playerInitiated = playerInitiated } end,
      sendCommand = function(cmd, callback) queue[#queue + 1] = { cmd = cmd, callback = callback } end,
    },
  }
  local realPrint = print
  _G.print = function(...) out[#out + 1] = table.concat({ ... }, " ") end
  local ok, err = pcall(entryPoint or gridBuilder.removeLeftTurns)
  local sequential = true
  while ok and #queue > 0 do
    sequential = sequential and #queue == 1
    local item = table.remove(queue, 1)
    sent[#sent + 1] = item.cmd
    if item.cmd.proposal.preference ~= nil then lights[item.cmd.proposal.node] = nil end
    if #sent == failCommand then
      item.callback({ resultProposalData = { errorState = { messages = { "Collision" } } } }, false)
    else
      item.callback({}, true)
    end
  end
  _G.print = realPrint
  return { ok = ok, err = err, sent = sent, out = out, sequential = sequential }
end

local turns = runTurns()
support.check("left turns: only node 1 gets a command, the others are skipped with a reason",
  turns.ok and #turns.sent == 1 and turns.sequential and turns.sent[1].proposal.streetProposal.nodeConfigsToRemove[1] == 1
  and table.concat(turns.out, "\n"):find("turns_skipped 2 has_traffic_light", 1, true) ~= nil
  and table.concat(turns.out, "\n"):find("turns_skipped 3 lane_mismatch", 1, true) ~= nil
  and table.concat(turns.out, "\n"):find("turns_skipped 4 unchanged", 1, true) ~= nil, turns.err or table.concat(turns.out, " | "))
local function keptList(command)
  local entry = command.proposal.streetProposal.nodeConfigsToAdd[1]
  local list = {}
  for _, c in ipairs(entry.comp.laneConnections) do list[#list + 1] = string.format("%d:%d>%d:%d", c.segment0, c.lane0, c.segment1, c.lane1) end
  table.sort(list)
  return table.concat(list, " "), entry
end
local keptText, keptEntry = keptList(turns.sent[1])
-- S1>S2 and S2>S1 are the two major streets of the L: straight, bus to bus and normal to normal. S1>S3 and S3>S1 are straight by angle. S3>S2 is a right turn from the outer normal lane. S2>S3 is a left turn. The U-turn stays. The road-less connection stays.
local expectedKept = { "11:0>12:0", "11:1>12:4", "11:2>12:3", "12:1>11:4", "12:2>11:3", "13:1>11:3", "13:1>12:3", "13:1>13:2", "11:2>13:2" }
table.sort(expectedKept)
support.check("left turns: the kept connections are the straight ones of the L, the straight ones by angle, the outer right turn, the U-turn and the connection without road",
  keptText == table.concat(expectedKept, " "), keptText)
support.check("left turns: the new config keeps the crosswalks and writes no flag, and the command is player initiated with the player in its context",
  keptEntry.entity == 1 and #keptEntry.comp.crosswalks == 1 and keptEntry.comp.userModifiedLaneConnections == nil
  and turns.sent[1].playerInitiated == true and turns.sent[1].ignoreErrors == false and turns.sent[1].context.player == 42)
support.check("left turns: the log names the kept count and the run ends with the counts",
  table.concat(turns.out, "\n"):find("turns_node 1 kept 9 of 18", 1, true) ~= nil and turns.out[#turns.out]:find("turns_done nodes 4 changed 1 skipped 3 failed 0", 1, true) ~= nil, table.concat(turns.out, " | "))
-- Node 2 has the only light. The combined call removes it first, so the left turns of node 2 are removed in the same run, one command after the other.
local both = runTurns(nil, gridBuilder.removeLightsAndLeftTurns)
local bothText = table.concat(both.out, "\n")
support.check("lights and left turns: the light of node 2 goes first, then nodes 1 and 2 lose their left turns, each command after the previous one",
  both.ok and #both.sent == 3 and both.sequential and both.sent[1].proposal.preference == "NO" and both.sent[1].proposal.node == 2
  and both.sent[2].proposal.streetProposal.nodeConfigsToRemove[1] == 1 and both.sent[3].proposal.streetProposal.nodeConfigsToRemove[1] == 2, both.err or #both.sent)
support.check("lights and left turns: lights_done comes before the first turns line, and the run ends with turns_done",
  bothText:find("lights_done nodes 1 changed 1 skipped 0 failed 0", 1, true) ~= nil
  and bothText:find("lights_done", 1, true) < bothText:find("turns_node", 1, true)
  and both.out[#both.out]:find("turns_done nodes 4 changed 2 skipped 2 failed 0", 1, true) ~= nil, bothText)
local turnsFail = runTurns(1)
support.check("left turns: a refused command is logged and counted", turnsFail.ok and turnsFail.out[#turnsFail.out]:find("turns_done nodes 4 changed 0 skipped 3 failed 1", 1, true) ~= nil
  and table.concat(turnsFail.out, "\n"):find("turns_failed 1 Collision", 1, true) ~= nil, table.concat(turnsFail.out, " | "))

-- Add crosswalks. Node 1: two town streets and a country road. Node 2: two town streets and a highway without a sidewalk. Node 3: every crosswalk exists.
-- Node 4: one of three crosswalks exists. Node 5: no node config. Node 6: a street of another player. Node 7: a bend of two streets.
-- Node 8: two country roads and a highway.
local function runCrosswalks(failCommand)
  local walk = { transportModes = { [PERSON] = true } }
  local road = { transportModes = { [CAR] = true }, forward = true }
  local function edge(template, sidewalk) return { roadTemplate = template, laneConfigs = sidewalk and { walk, road } or { road } } end
  local edges = {}
  local streetsOf = {}
  for node = 1, 8 do
    streetsOf[node] = { node * 10 + 1, node * 10 + 2, node * 10 + 3 }
    for _, street in ipairs(streetsOf[node]) do edges[street] = edge("town_new_small", true) end
  end
  streetsOf[7] = { 71, 72 }
  edges[13] = edge("country_new_small", true)
  edges[22] = edge("highway", false)
  edges[81] = edge("country_new_small", false)
  edges[82] = edge("highway", false)
  edges[83] = edge("country_new_small", false)
  local configs = { [1] = {}, [2] = {}, [3] = { 31, 32, 33 }, [4] = { 41 }, [6] = {}, [7] = {}, [8] = {} }
  local queue, sent, out = {}, {}, {}
  _G.api = {
    type = {
      ComponentType = { BASE_EDGE = "BASE_EDGE", PLAYER_OWNED = "PLAYER_OWNED", BASE_NODE_CONFIG = "BASE_NODE_CONFIG" },
      enum = { TransportMode = { PERSON = PERSON, CAR = CAR } },
      BaseNodeLaneConnectionAndEntity = { new = function() return { comp = {} } end },
      SimpleProposal = { new = function() return { streetProposal = {} } end },
      Context = { new = function() return {} end },
    },
    res = { streetTemplateRep = {
      find = function(name) return name end,
      get = function(name) return { country = name:find("country", 1, true) ~= nil } end,
    } },
    engine = {
      util = { getPlayer = function() return 42 end },
      system = { streetSystem = { getNode2StreetEdgeMap = function() return streetsOf end, getNodeStreetSegments = function(node) return streetsOf[node] end } },
      getComponent = function(entity, component)
        if component == "BASE_EDGE" then return edges[entity] end
        if component == "PLAYER_OWNED" then return { player = entity == 61 and 99 or 42 } end
        if component == "BASE_NODE_CONFIG" then
          if configs[entity] == nil then return nil end
          return { laneConnections = {}, crosswalks = configs[entity] }
        end
      end,
    },
    cmd = {
      makeWorldBuildProposalCmd = function(proposal, context, ignoreErrors, playerInitiated) return { proposal = proposal, context = context, ignoreErrors = ignoreErrors, playerInitiated = playerInitiated } end,
      sendCommand = function(cmd, callback) queue[#queue + 1] = { cmd = cmd, callback = callback } end,
    },
  }
  local realPrint = print
  _G.print = function(...) out[#out + 1] = table.concat({ ... }, " ") end
  local ok, err = pcall(gridBuilder.addCrosswalks)
  local sequential = true
  while ok and #queue > 0 do
    sequential = sequential and #queue == 1
    local item = table.remove(queue, 1)
    sent[#sent + 1] = item.cmd
    if #sent == failCommand then
      item.callback({ resultProposalData = { errorState = { messages = { "Collision" } } } }, false)
    else
      item.callback({}, true)
    end
  end
  _G.print = realPrint
  return { ok = ok, err = err, sent = sent, out = out, sequential = sequential }
end

do
local walks = runCrosswalks()
local function crosswalksOf(command)
  local entry = command.proposal.streetProposal.nodeConfigsToAdd[1]
  return entry.entity, table.concat(entry.comp.crosswalks, ",")
end
local walksText = table.concat(walks.out, "\n")
local firstNode, firstList = crosswalksOf(walks.sent[1])
local secondNode, secondList = crosswalksOf(walks.sent[2])
local thirdNode, thirdList = crosswalksOf(walks.sent[3])
support.check("crosswalks: a junction with a town street gets a crosswalk on every street, also on the country road and the highway, and a crosswalk that exists stays",
  walks.ok and #walks.sent == 3 and walks.sequential and firstNode == 1 and firstList == "11,12,13" and secondNode == 2 and secondList == "21,22,23"
  and thirdNode == 4 and thirdList == "41,42,43", walks.err or (firstList .. " | " .. secondList .. " | " .. thirdList))
support.check("crosswalks: a junction with every crosswalk, a node without config, a junction of country roads and highways, a foreign junction and a bend get no command",
  walksText:find("crosswalks_skipped 3 unchanged", 1, true) ~= nil and walksText:find("crosswalks_skipped 5 no_config", 1, true) ~= nil
  and walksText:find("crosswalks_skipped 8 no_town_street", 1, true) ~= nil
  and walksText:find("crosswalks_node 6", 1, true) == nil and walksText:find("crosswalks_node 7", 1, true) == nil, walksText)
support.check("crosswalks: the command rewrites the node config as the player and the run ends with the counts",
  walks.sent[1].proposal.streetProposal.nodeConfigsToRemove[1] == 1 and walks.sent[1].playerInitiated == true and walks.sent[1].ignoreErrors == false and walks.sent[1].context.player == 42
  and walks.out[#walks.out]:find("crosswalks_done nodes 6 changed 3 skipped 3 failed 0", 1, true) ~= nil, walks.out[#walks.out])
local walksFail = runCrosswalks(1)
support.check("crosswalks: a refused command is logged and counted", walksFail.ok and walksFail.out[#walksFail.out]:find("crosswalks_done nodes 6 changed 2 skipped 3 failed 1", 1, true) ~= nil
  and table.concat(walksFail.out, "\n"):find("crosswalks_failed 1 Collision", 1, true) ~= nil, table.concat(walksFail.out, " | "))
end

-- Small road speed. Edge 201/202 change (202 is unowned, a variant of country_old_small), 203 already has the speed, 204 and 207 are no small road,
-- 205 belongs to another player, 206 is part of a construction, 208 would lose its edge object, 209 is a tram variant. Node 1 and node 2 share edge 201.
local KMH_30_MS = 30 / 3.6
local function speedLanes(ms) return { { speed = ms, forward = true }, { speed = ms, forward = false } } end
local function runSpeed(keepSpeed, failCommand, entry)
  local roads = {
    [201] = { roadTemplate = "street/town/town_new_small.street_template.lua", laneConfigs = speedLanes(13.89), objects = {} },
    [202] = { roadTemplate = "country_old_small_trees", laneConfigs = speedLanes(16.67), objects = {} },
    [203] = { roadTemplate = "town_old_small", laneConfigs = speedLanes(KMH_30_MS), objects = {} },
    [204] = { roadTemplate = "town_new_medium", laneConfigs = speedLanes(13.89), objects = {} },
    [205] = { roadTemplate = "town_new_small", laneConfigs = speedLanes(13.89), objects = {} },
    [206] = { roadTemplate = "town_new_small", laneConfigs = speedLanes(13.89), objects = {} },
    [207] = { roadTemplate = "town_new_xsmall", laneConfigs = speedLanes(8.33), objects = {} },
    [208] = { roadTemplate = "town_new_small", laneConfigs = speedLanes(13.89), objects = { { 900, 0 } } },
    [209] = { roadTemplate = "town_new_small_tram_electrified", laneConfigs = speedLanes(13.89), objects = {} },
  }
  local streetsOf = { [1] = { 201, 202, 203, 204, 205 }, [2] = { 201, 206, 207, 208, 209 } }
  local owners = { [205] = 99, [202] = -1 }
  local queue, sent, out, replaced = {}, {}, {}, {}
  local replaceFor = {}
  _G.api = {
    type = {
      ComponentType = { BASE_EDGE = "BASE_EDGE", PLAYER_OWNED = "PLAYER_OWNED" },
      Context = { new = function() return {} end },
    },
    engine = {
      util = { getPlayer = function() return 42 end,
        proposal = { replaceSegment = function(edge, template)
          replaced[#replaced + 1] = edge .. "=" .. template
          local lanes = {}
          for i, lane in ipairs(roads[edge].laneConfigs) do lanes[i] = { speed = 13.89, forward = lane.forward } end
          local proposal = { proposal = { addedSegments = { { comp = { laneConfigs = lanes, objects = edge == 208 and {} or roads[edge].objects } } } } }
          replaceFor[proposal] = edge
          return proposal
        end } },
      system = { streetSystem = { getNode2StreetEdgeMap = function() return streetsOf end },
        streetConnectorSystem = { getConstructionEntityForEdge = function(edge) return edge == 206 and 500 or -1 end } },
      getComponent = function(entity, component)
        if component == "BASE_EDGE" then return roads[entity] end
        if component == "PLAYER_OWNED" then
          if owners[entity] == nil then return { player = 42 } end
          return owners[entity] >= 0 and { player = owners[entity] } or nil
        end
      end,
    },
    cmd = {
      makeWorldBuildProposalCmd = function(proposal, context, ignoreErrors, playerInitiated) return { proposal = proposal, context = context, ignoreErrors = ignoreErrors, playerInitiated = playerInitiated } end,
      sendCommand = function(cmd, callback) queue[#queue + 1] = { cmd = cmd, callback = callback } end,
    },
  }
  local realPrint = print
  _G.print = function(...) out[#out + 1] = table.concat({ ... }, " ") end
  local ok, err = pcall(entry or gridBuilder.setSmallRoadSpeed)
  local sequential = true
  while ok and #queue > 0 do
    sequential = sequential and #queue == 1
    local item = table.remove(queue, 1)
    sent[#sent + 1] = item.cmd
    if #sent == failCommand then
      item.callback({ resultProposalData = { errorState = { messages = { "Collision" } } } }, false)
    else
      if keepSpeed then
        local edge = replaceFor[item.cmd.proposal]
        roads[edge].laneConfigs = item.cmd.proposal.proposal.addedSegments[1].comp.laneConfigs
      end
      item.callback({}, true)
    end
  end
  _G.print = realPrint
  return { ok = ok, err = err, sent = sent, out = out, sequential = sequential, replaced = replaced, replaceFor = replaceFor }
end

local speed = runSpeed(true)
support.check("small road speed: one command per road that needs it, each sent after the previous one finished",
  speed.ok and #speed.sent == 3 and speed.sequential and table.concat(speed.replaced, " ") == "201=street/town/town_new_small.street_template.lua 202=country_old_small_trees 208=town_new_small 209=town_new_small_tram_electrified",
  speed.err or table.concat(speed.replaced, " "))
local firstLanes = speed.sent[1] and speed.sent[1].proposal.proposal.addedSegments[1].comp.laneConfigs or {}
support.check("small road speed: every lane of the new segment gets 30 km/h in m/s, the command is player initiated with the player in its context",
  #firstLanes == 2 and near(firstLanes[1].speed, KMH_30_MS) and near(firstLanes[2].speed, KMH_30_MS)
  and speed.sent[1].playerInitiated == true and speed.sent[1].ignoreErrors == false and speed.sent[1].context.player == 42)
support.check("small road speed: the start line counts the small roads and the roads to change",
  speed.out[1]:find("speed_start kmh 30 ms 8.33 small_roads 5 to_change 4", 1, true) ~= nil, speed.out[1])
support.check("small road speed: a road whose new segment loses its edge object is skipped and logged",
  table.concat(speed.out, "\n"):find("speed_skipped 208 objects_lost", 1, true) ~= nil, table.concat(speed.out, " | "))
support.check("small road speed: the run ends with the counts and a check that finds only the skipped road at another speed",
  speed.out[#speed.out - 1]:find("speed_done roads 4 changed 3 skipped 1 failed 0", 1, true) ~= nil
  and speed.out[#speed.out]:find("speed_check small_roads 5 other_speed 1", 1, true) ~= nil, table.concat(speed.out, " | "))
local dropped = runSpeed(false)
support.check("small road speed: a game that does not keep the speed shows in the check line",
  dropped.out[#dropped.out]:find("speed_check small_roads 5 other_speed 4", 1, true) ~= nil, dropped.out[#dropped.out])
local speedFail = runSpeed(true, 2)
support.check("small road speed: a refused command is logged with the game message and the run goes on",
  speedFail.ok and table.concat(speedFail.out, "\n"):find("speed_failed 202 Collision", 1, true) ~= nil
  and speedFail.out[#speedFail.out - 1]:find("speed_done roads 4 changed 2 skipped 1 failed 1", 1, true) ~= nil, table.concat(speedFail.out, " | "))
local fastRoad = runSpeed(true, nil, function() gridBuilder.setSmallRoadSpeed(50) end)
support.check("small road speed: the kmh argument sets the speed",
  fastRoad.out[1]:find("speed_start kmh 50 ms 13.89 small_roads 5 to_change 5", 1, true) ~= nil, fastRoad.out[1])
local badSpeed = runSpeed(true, nil, function() gridBuilder.setSmallRoadSpeed(0) end)
support.check("small road speed: a speed of 0 raises an error and sends nothing", not badSpeed.ok and #badSpeed.sent == 0 and tostring(badSpeed.err):find("kmh_must_be_positive", 1, true) ~= nil, badSpeed.err)

support.finish("grid_builder_test")
