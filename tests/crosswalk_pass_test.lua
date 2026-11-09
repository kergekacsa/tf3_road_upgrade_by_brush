-- Tests of crosswalk_pass.tl: the pass over the junctions that a press touched, with a fake env and a fake world. The module
-- may reach the engine only through node_crosswalks, so the global api does not exist here.

local support = dofile((arg[0]:match("^(.*)[/\\][^/\\]*$") or ".") .. "/support.lua")
local check, contains = support.check, support.contains

local world, events, clock, queue, logs, progressCalls
local fakeEnvCancel = false

local function reset(nodes)
  world = { nodes = nodes or {}, drops = {}, refuse = {}, sends = {} }
  events, logs, queue, clock, progressCalls = {}, {}, {}, 0, {}
  fakeEnvCancel = false
end

local function nodeOf(spot)
  if world.nodes[spot.node] then return spot.node end
  for id, n in pairs(world.nodes) do
    if math.abs(n.x - spot.x) <= 1 and math.abs(n.y - spot.y) <= 1 then return id end
  end
  return nil
end

local function listed(node)
  local set = {}
  for _, c in ipairs(world.nodes[node].crosswalks) do set[c] = true end
  return set
end

local function missing(node)
  local out, set = {}, listed(node)
  for _, s in ipairs(world.nodes[node].streets) do if not set[s] then out[#out + 1] = s end end
  return out
end

-- The fake of node_crosswalks: the world is the table above
local fake = {
  inspect = function(spot)
    local id = nodeOf(spot)
    if id == nil then return { node = spot.node, found = false, readable = false, streets = {}, crosswalks = {} } end
    local n = world.nodes[id]
    return { node = id, found = true, readable = n.unreadable ~= true, streets = n.streets, crosswalks = n.crosswalks }
  end,
  commandAt = function(spot, _context, allStreets)
    local id = nodeOf(spot)
    if id == nil then return nil, "node_not_found", spot.node end
    local m = missing(id)
    if #m == 0 then return nil, "unchanged", id end
    return { kind = allStreets and "all" or "town", node = id }, #m .. " added", id
  end,
  commandSidewalk = function(node, _context)
    local m = missing(node)
    if #m == 0 then return nil, "unchanged" end
    return { kind = "sidewalk", node = node }, #m .. " added"
  end,
  readBack = function(spot)
    local id = nodeOf(spot)
    local n = world.nodes[id]
    local ids = {}
    for i, c in ipairs(n.crosswalks) do ids[i] = tostring(c) end
    return id, #ids .. " crosswalks [" .. table.concat(ids, ", ") .. "]", { "street " .. n.streets[1] .. " item" }
  end,
}
support.installRequire({ node_crosswalks = fake })
local passModule = dofile(support.buildDir .. "/crosswalk_pass.lua")

local function makeEnv()
  return {
    send = function(command, callback)
      events[#events + 1] = "send:" .. command.kind .. ":" .. command.node
      world.sends[#world.sends + 1] = { kind = command.kind, node = command.node, clock = clock }
      local refusals = world.refuse[command.node] or 0
      if refusals > 0 then
        world.refuse[command.node] = refusals - 1
        callback(false, "Refused")
        return
      end
      local n = world.nodes[command.node]
      local list = {}
      for _, s in ipairs(world.nodes[command.node].streets) do
        if command.kind ~= "sidewalk" or not n.noPerson or not n.noPerson[s] then list[#list + 1] = s end
      end
      for _, c in ipairs(n.crosswalks) do
        local present = false
        for _, l in ipairs(list) do if l == c then present = true end end
        if not present then table.insert(list, 1, c) end
      end
      n.crosswalks = list
      if (world.drops[command.node] or 0) > 0 then
        world.drops[command.node] = world.drops[command.node] - 1
        n.crosswalks = {}
      end
      callback(true, "")
    end,
    wait = function(seconds, step)
      events[#events + 1] = "wait:" .. string.format("%.1f", seconds)
      queue[#queue + 1] = { due = clock + seconds, step = step, order = #queue }
    end,
    log = function(text, tag) logs[#logs + 1] = text; events[#events + 1] = "log:" .. text end,
    context = function() return {} end,
    cancelled = function() return fakeEnvCancel end,
    progress = function(done, total) progressCalls[#progressCalls + 1] = { done = done, total = total } end,
  }
end

-- Runs the fake clock until nothing is left to do.
local function drain()
  local guard = 0
  while #queue > 0 and guard < 1000 do
    guard = guard + 1
    table.sort(queue, function(a, b) if a.due ~= b.due then return a.due < b.due end return a.order < b.order end)
    local item = table.remove(queue, 1)
    clock = item.due
    item.step()
  end
end

-- Returns the number of onDone calls.
local function run(state, env)
  local doneCalls = 0
  state:run(env or makeEnv(), function() doneCalls = doneCalls + 1 end)
  drain()
  return doneCalls
end

local function town(id, x, y, streets, crosswalks)
  return { x = x, y = y, streets = streets, crosswalks = crosswalks or {} }
end
local function spotOf(id, x, y) return { node = id, x = x, y = y } end
local function count(pattern) local n = 0; for _, l in ipairs(logs) do if contains(l, pattern) then n = n + 1 end end; return n end
local function eventIndex(prefix) for i, e in ipairs(events) do if e:sub(1, #prefix) == prefix then return i end end end

check("the module touches no engine function itself: the global api does not exist", _G.api == nil)
check("the constants of the pass", passModule.CROSSWALK_SETTLE_SECONDS == 2.0 and passModule.CROSSWALK_VERIFY_SECONDS == 1.0 and passModule.CROSSWALK_ATTEMPTS == 3
  and passModule.MIN_STREETS_FOR_CROSSWALKS == 3)

-- touch
reset({})
local state = passModule.new()
state:touch(spotOf(1, 10.04, 20.0))
state:touch(spotOf(2, 10.01, 20.04))
state:touch(spotOf(3, 11.0, 20.0))
check("touch: a node at the same position, rounded to 0.1 m, is kept once, the first spot wins", #state.spots == 2 and state.spots[1].node == 1 and state.spots[2].node == 3)

-- an empty pass
reset({})
local empty = passModule.new()
check("a pass without touched nodes calls onDone at once and waits for nothing", run(empty) == 1 and #events == 0)

-- complete junctions
reset({ [10] = town(10, 1, 1, { 1, 2, 3 }), [11] = town(11, 2, 2, { 4, 5, 6, 7 }), [12] = town(12, 3, 3, { 8, 9, 3 }) })
local pass = passModule.new()
pass:touch(spotOf(10, 1, 1)); pass:touch(spotOf(11, 2, 2)); pass:touch(spotOf(12, 3, 3))
local doneCalls = run(pass)
check("pass: onDone is called once", doneCalls == 1)
check("pass: the settle time is waited BEFORE the first command", eventIndex("wait:2.0") ~= nil and eventIndex("wait:2.0") < eventIndex("send:") and world.sends[1].clock >= 2.0, tostring(world.sends[1] and world.sends[1].clock))
check("pass: one command per junction node, in the order of the touches", #world.sends == 3 and world.sends[1].node == 10 and world.sends[2].node == 11 and world.sends[3].node == 12)
check("pass: every command is the all-streets command", world.sends[1].kind == "all" and world.sends[2].kind == "all")
check("pass: the verify time is waited between a command and the read back", (function()
  local s, w, r = eventIndex("send:all:10"), nil, eventIndex("log:crosswalks: node 10: read back")
  for i = s, r do if events[i] == "wait:1.0" then w = i end end
  return s ~= nil and w ~= nil and r ~= nil and s < w and w < r
end)())
check("pass: a complete junction logs one final line with the number of sends and streets", count("crosswalks: node 10: complete after 1 sends (3 streets)") == 1
  and count("crosswalks: node 11: complete after 1 sends (4 streets)") == 1)
check("pass: the summary line counts the nodes", count("crosswalks: pass done: 3 junctions touched, 3 complete, 0 incomplete, 0 skipped") == 1, logs[#logs])
check("pass: the read back lines are kept", count("crosswalks: node 10: read back 3 crosswalks [1, 2, 3]") == 1)
check("pass: the start line names the number of touched nodes", count("crosswalks: pass start: 3 touched nodes") == 1)
check("pass: every command of the round is sent before the one wait for the read back", (function()
  local verifyWaits, lastSend, firstRead = 0, 0, nil
  for i, e in ipairs(events) do
    if e == "wait:1.0" then verifyWaits = verifyWaits + 1 end
    if e:sub(1, 5) == "send:" then lastSend = i end
    if firstRead == nil and e:find("read back", 1, true) then firstRead = i end
  end
  return verifyWaits == 1 and lastSend < firstRead
end)())
check("pass: the progress starts at 0 and ends with every node settled", progressCalls[1].done == 0 and progressCalls[1].total == 3
  and progressCalls[#progressCalls].done == 3 and progressCalls[#progressCalls].total == 3, #progressCalls)
check("pass: a finished pass has no unfinished node", pass:unfinished() == 0)

-- a node that is no junction
reset({ [20] = town(20, 1, 1, { 1, 2 }), [21] = town(21, 2, 2, { 3, 4, 5 }) })
local bend = passModule.new()
bend:touch(spotOf(20, 1, 1)); bend:touch(spotOf(21, 2, 2))
run(bend)
check("a node with fewer than 3 streets is skipped with the reason, nothing is sent for it",
  count("crosswalks: node 20: not_a_junction") == 1 and #world.sends == 1 and world.sends[1].node == 21)
check("the summary counts the skipped node", count("crosswalks: pass done: 2 junctions touched, 1 complete, 0 incomplete, 1 skipped") == 1)

-- another mod drops the crosswalks: send again, at most three times
reset({ [30] = town(30, 1, 1, { 1, 2, 3 }) })
world.drops[30] = 1
local drop = passModule.new()
drop:touch(spotOf(30, 1, 1))
run(drop)
check("an incomplete read back is followed by a new command after the settle time", #world.sends == 2 and world.sends[2].clock - world.sends[1].clock >= 3.0, #world.sends)
check("the node is complete after the second command", count("crosswalks: node 30: complete after 2 sends (3 streets)") == 1 and count("INCOMPLETE") == 0)
reset({ [31] = town(31, 1, 1, { 1, 2, 3 }) })
world.drops[31] = 9
local never = passModule.new()
never:touch(spotOf(31, 1, 1))
run(never)
check("at most three commands per node", #world.sends == 3)
check("a node that stays incomplete gets the INCOMPLETE line with the missing streets", count("crosswalks: node 31: INCOMPLETE after 3 sends, missing streets [1, 2, 3]") == 1)
check("the summary counts the incomplete node", count("crosswalks: pass done: 1 junctions touched, 0 complete, 1 incomplete, 0 skipped") == 1)

-- a refused command
reset({ [40] = town(40, 1, 1, { 1, 2, 3 }) })
world.refuse[40] = 1
local refused = passModule.new()
refused:touch(spotOf(40, 1, 1))
run(refused)
check("a refused all-streets command falls back to the sidewalk command once", #world.sends == 2 and world.sends[1].kind == "all" and world.sends[2].kind == "sidewalk")
check("the answers are logged", count("crosswalks: node 40: game answer failed: Refused") == 1 and count("crosswalks: node 40: game answer ok") == 1)
check("a refused first command and an accepted fallback count as one send", count("crosswalks: node 40: complete after 1 sends (3 streets)") == 1)
reset({ [41] = town(41, 1, 1, { 1, 2, 3 }) })
world.refuse[41] = 9
local bothRefused = passModule.new()
bothRefused:touch(spotOf(41, 1, 1))
run(bothRefused)
check("when the fallback is refused too no third command of the round is sent", #world.sends >= 2 and world.sends[3] ~= nil and world.sends[3].clock - world.sends[2].clock >= 3.0, #world.sends)
check("a node that stays refused ends as INCOMPLETE after three rounds", count("crosswalks: node 41: INCOMPLETE after 3 sends") == 1 and #world.sends == 6, #world.sends)

-- a node that is not found
reset({ [50] = town(50, 1, 1, { 1, 2, 3 }) })
local lost = passModule.new()
lost:touch(spotOf(50, 1, 1)); lost:touch(spotOf(51, 90, 90))
run(lost)
check("a node that is not found is skipped with the reason, the junction beside it gets its command",
  count("crosswalks: node 51: node_not_found") == 1 and #world.sends == 1 and world.sends[1].node == 50 and count("1 skipped") == 1)

-- no touched node is a junction: the pass ends at once
reset({ [90] = town(90, 1, 1, { 1, 2 }), [91] = town(91, 2, 2, { 3, 4 }) })
local noJunction = passModule.new()
noJunction:touch(spotOf(90, 1, 1)); noJunction:touch(spotOf(91, 2, 2))
check("no junction among the touched nodes: onDone is called once", run(noJunction) == 1)
check("no junction among the touched nodes: no wait event, no command and no progress", #world.sends == 0 and progressCalls[1] == nil
  and eventIndex("wait:") == nil and eventIndex("send:") == nil, table.concat(events, " | "))
check("no junction among the touched nodes: one log line names the number of touched nodes",
  #logs == 1 and logs[1] == "crosswalks: pass skipped, none of the 2 touched nodes is a junction", table.concat(logs, " | "))
check("no junction among the touched nodes: no start line and no summary line", count("pass start") == 0 and count("pass done") == 0)
check("no junction among the touched nodes: the pass has no unfinished node", noJunction:unfinished() == 0 and clock == 0)

reset({ [92] = town(92, 1, 1, { 1, 2, 3 }) })
local onlyLost = passModule.new()
onlyLost:touch(spotOf(93, 90, 90))
check("only a node that is not found: the pass is skipped at once like a pass without a junction", run(onlyLost) == 1 and #events == 1
  and logs[1] == "crosswalks: pass skipped, none of the 1 touched nodes is a junction", table.concat(events, " | "))

-- already complete
reset({ [60] = town(60, 1, 1, { 1, 2, 3 }, { 1, 2, 3 }) })
local already = passModule.new()
already:touch(spotOf(60, 1, 1))
run(already)
check("a node that has every crosswalk already is complete after no command", #world.sends == 0 and count("crosswalks: node 60: complete after 0 sends (3 streets)") == 1)

-- cancel
reset({ [70] = town(70, 1, 1, { 1, 2, 3 }), [71] = town(71, 2, 2, { 4, 5, 6 }) })
local cancelPass = passModule.new()
cancelPass:touch(spotOf(70, 1, 1)); cancelPass:touch(spotOf(71, 2, 2))
local cancelEnv = makeEnv()
local originalSend = cancelEnv.send
cancelEnv.send = function(command, callback) fakeEnvCancel = true; originalSend(command, callback) end
local cancelDone = run(cancelPass, cancelEnv)
check("a cancelled env stops the pass, onDone is called once", cancelDone == 1 and #world.sends == 1)
check("a cancelled pass names the junctions it did not reach", count("crosswalks: pass done: 2 junctions touched, 0 complete, 0 incomplete, 0 skipped, 2 not reached") == 1)

-- a pass that the tool cuts off: no step runs any more
reset({ [80] = town(80, 1, 1, { 1, 2, 3 }), [81] = town(81, 2, 2, { 4, 5, 6 }) })
local cut = passModule.new()
cut:touch(spotOf(80, 1, 1)); cut:touch(spotOf(81, 2, 2))
check("unfinished is 0 before the pass runs", cut:unfinished() == 0)
cut:run(makeEnv(), function() end)
check("a pass that no step finishes reports all its junctions as unfinished", cut:unfinished() == 2)
drain()
check("the same pass has none unfinished after it ran to the end", cut:unfinished() == 0)

-- many junctions need no extra waits
reset((function()
  local nodes = {}
  for i = 1, 30 do nodes[100 + i] = town(100 + i, i, i, { 1, 2, 3 }) end
  return nodes
end)())
local many = passModule.new()
for i = 1, 30 do many:touch(spotOf(100 + i, i, i)) end
run(many)
check("30 junctions are sent in one round and read back after one verify wait: 2.0 + 1.0 seconds", #world.sends == 30 and clock == 3.0, clock)

check("every step ran through the env: waits and sends only, no api", _G.api == nil)

support.finish("crosswalk_pass")
