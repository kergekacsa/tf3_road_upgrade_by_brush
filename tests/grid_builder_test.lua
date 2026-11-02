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
local function runWorld(p0, p1, options, failAt, year, invalidateStripAfter, replaceCornerAfter)
  local ownerView = { player = OWNER_PLAYER }
  local world = { nodes = { [10] = { position = p0 }, [11] = { position = p1 } }, edges = {}, applied = {}, queue = {}, next = FIRST_NEW_ID }
  local edges = {
    [5] = { roadType = "TRACK", position0 = p0, position1 = p1 },
    [7] = { roadType = "STREET", node0 = 10, node1 = 11, position0 = p0, position1 = p1, roadTemplate = "town_medium", typeIndex = -1, distance = 0, edgeDecorations = { STRIP_DECORATION } },
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
      BaseNodeLaneConnectionAndEntity = record(),
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
        local template = { streetStyle = "style_of_" .. name, laneConfigs = laneLayout("lanes_of_" .. name, (name == LARGE_NEW or name == LARGE_OLD) and 3 or 1), defaultEdgeDecorations = { { "deco_of_" .. name, true } } }
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
          if writtenConfigs[entity] then return { laneConnections = writtenConfigs[entity].lanes, crosswalks = { 501 } } end
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
          return { laneConnections = lanes, crosswalks = { 501 } }
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
  if not effective.defaultBend and effective.bendStubs == nil then effective.bendStubs = "off" end
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
support.check("the first log line ends with the build mark of the module", east.out[1]:find("build 2026-11-02 sixblocks", 1, true) ~= nil, east.out[1])
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
local stubbed = runWorld(vec(100, 200, 0), vec(180, 200, 0), { bendStubs = "remove" })
support.check("bendStubs remove: 110 segment commands, then a build and a removal for each of the 3 corners", stubbed.ok and stubbed.commands == GRID_EDGES + 6, stubbed.commands)
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
local kept = runWorld(vec(100, 200, 0), vec(180, 200, 0), { bendStubs = "keep" })
support.check("bendStubs keep: the 3 stubs are built and stay", kept.ok and kept.commands == GRID_EDGES + 3 and countEdges(kept) == GRID_EDGES + 3 and countNewNodes(kept) == GRID_NODES - 1 + 3, kept.commands .. " " .. countEdges(kept))
local noStubs = runWorld(vec(100, 200, 0), vec(180, 200, 0), { bendStubs = "off" })
support.check("bendStubs off: no stub", noStubs.commands == GRID_EDGES and countEdges(noStubs) == GRID_EDGES)
local byDefault = runWorld(vec(100, 200, 0), vec(180, 200, 0), { defaultBend = true })
support.check("default with large streets: a stub is built and removed at each of the 3 corners", byDefault.commands == GRID_EDGES + 6 and countEdges(byDefault) == GRID_EDGES, byDefault.commands)
local byDefaultPlain = runWorld(vec(100, 200, 0), vec(180, 200, 0), { defaultBend = true, largeEveryAlong = 0, largeEveryLeft = 0 })
support.check("default without large streets: no stub", byDefaultPlain.commands == GRID_EDGES)
local byDefaultNoConfigs = runWorld(vec(100, 200, 0), vec(180, 200, 0), { defaultBend = true, explicitNodeConfigs = false })
support.check("default with explicitNodeConfigs=false: no stub", byDefaultNoConfigs.commands == GRID_EDGES)
local stubFails = runWorld(vec(100, 200, 0), vec(180, 200, 0), { bendStubs = "remove" }, GRID_EDGES + 1)
support.check("a stub that the game refuses is logged and the next corner still runs", stubFails.ok and stubFails.commands == GRID_EDGES + 5
  and logText(stubFails):find("bend_stub 6:0 failed Collision", 1, true) ~= nil and stubFails.out[#stubFails.out]:find("done 110", 1, true) ~= nil, stubFails.commands)
local oneBlock = runWorld(vec(100, 200, 0), vec(180, 200, 0), { bendStubs = "remove", blocksAlong = 1, blocksLeft = 1 })
support.check("a 1 by 1 grid has 3 bend corners and gets 3 stubs", oneBlock.ok and oneBlock.commands == 4 + 6 and countEdges(oneBlock) == 4, oneBlock.commands)
local oneRow = runWorld(vec(100, 200, 0), vec(180, 200, 0), { bendStubs = "remove", blocksLeft = 0 })
support.check("a grid without blocks to the left has no bend corner and ends with done", oneRow.ok and oneRow.out[#oneRow.out]:find("done", 1, true) ~= nil and oneRow.commands == ALONG, oneRow.commands)

-- The removal of a stub writes the node config of the corner again without the connections that touch the stub and without crosswalks.
local configStubbed = runWorld(vec(100, 200, 0), vec(180, 200, 0), { bendStubs = "remove" })
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
local delayed = runWorld(vec(100, 200, 0), vec(180, 200, 0), { bendStubs = "remove" })
support.check("the removal waits for the connections: 3 wait commands for each corner, then the removal", delayed.ok and delayed.commands == GRID_EDGES + 3 * (1 + 3 + 1) and countEdges(delayed) == GRID_EDGES, delayed.commands)
support.check("the log gives the number of polls", table.concat(delayed.out, "\n"):find("bend_stub 6:0 connections_ready polls 3 streets 3 connections 6", 1, true) ~= nil)
connectionDelayTicks = math.huge
local neverReady = runWorld(vec(100, 200, 0), vec(180, 200, 0), { bendStubs = "remove" })
support.check("connections that never appear leave the stubs in place and are logged", neverReady.ok and countEdges(neverReady) == GRID_EDGES + 3
  and table.concat(neverReady.out, "\n"):find("bend_stub 6:0 wait_timeout polls 150 streets 3 connections 0", 1, true) ~= nil and neverReady.out[#neverReady.out]:find("done 110", 1, true) ~= nil)
connectionDelayTicks = 0
local keptNoRewrite = runWorld(vec(100, 200, 0), vec(180, 200, 0), { bendStubs = "keep" })
local rewrites = 0
for _, record in ipairs(keptNoRewrite.world.applied) do rewrites = rewrites + #record.rewrittenConfigs end
support.check("bendStubs keep: no node config is rewritten", rewrites == 0)


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

support.finish("grid_builder_test")
