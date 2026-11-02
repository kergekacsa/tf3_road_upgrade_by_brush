-- Tests of brush_layer.tl: the state of the world layer of every instance, which instance owns it, which instance may take
-- it on a mouse event, and when a click counts as a stuck ring.
-- Scenario: instance #2 owns the visible layer and its step runs, instance #4 gets the mouse events. The script calls these
-- functions in onStep, onMouse, onMount and onUnmount; the tests prove the rule of the module, not those call sites.

local support = dofile((arg[0]:match("^(.*)[/\\][^/\\]*$") or ".") .. "/support.lua")
local check, contains = support.check, support.contains

support.installRequire({})

-- Every scenario starts with a new module, so the state of one does not reach the next.
local function fresh() return dofile(support.buildDir .. "/brush_layer.lua") end

local noop = function() end
local layer
-- A step of an active tool. Returns whether the unmount counts as closed, and whether the layer is mounted.
local function step(me, now) return layer.step(me, now, true, false) end
local function goneAt(me, now) return (step(me, now)) end

-- No owner
layer = fresh()
local GONE = layer.GONE_SECONDS
check("no owner: owner() is 0", layer.owner() == 0)
check("no owner: no layer is up", layer.isUp(4) == false)
check("no owner: passState does nothing", layer.passState(4, 4, 100, {}) == false)
check("no owner: a mouse event on a layer that never went down claims it", select(1, layer.mouse(4, 100, noop)) == "claimed" and layer.owner() == 4)

-- Instance #2 owns the layer and instance #4 gets a mouse event
layer = fresh()
local passed = nil
local wasUp, downFor, gone = layer.mount(2, 100.0, function(state) passed = state end)
check("mount: a layer that was never marked mounted reports wasUp false, no unmount time, not gone", wasUp == false and downFor == nil and gone == false)
step(2, 100.9)
check("sequence: instance #2 is the owner and its layer is up", layer.owner() == 2 and layer.isUp(2) == true)
local verdict, text = layer.mouse(4, 101.0, noop)
check("sequence: a mouse event of #4 does not take the layer while #2 is alive", verdict == "blocked" and layer.owner() == 2 and layer.isUp(4) == false)
check("sequence: the first blocked event writes a line with the owner and the evidence",
  contains(text, "instance #4: mouse event ignored, instance #2 owns the layer") and contains(text, "seen alive 0.10 s ago")
  and contains(text, "0 mouse events of the owner") and contains(text, "longest gap between its steps 0.90 s"), text)
verdict, text = layer.mouse(4, 101.1, noop)
check("sequence: the next blocked event of the episode writes no line", verdict == "blocked" and text == nil)
verdict = layer.mouse(2, 101.2, noop)
check("sequence: #2 is never blocked by its own ownership", verdict == "up")
check("sequence: the newest instance #4 gives its state to #2", layer.passState(4, 4, 101.3, "state of 4") == true and passed == "state of 4")
check("sequence: an instance that is not the newest gives nothing", layer.passState(3, 4, 101.3, "state of 3") == false and passed == "state of 4")
check("sequence: the owner gives nothing to itself", layer.passState(2, 4, 101.3, "x") == false)
check("sequence: an instance whose layer is up gives nothing", layer.mount(4, 101.4, noop) == false and layer.passState(4, 4, 101.5, "x") == false)

-- An instance whose own layer is up hands nothing to the owner, even when it is the newest
layer = fresh()
local handed = nil
layer.mount(4, 100.0, noop)
layer.mount(2, 100.1, function(state) handed = state end)
check("a second mount without an unmount: the layer of the first owner no longer counts as mounted",
  layer.owner() == 2 and layer.isUp(2) == true and layer.isUp(4) == false)
check("the owner hands nothing to itself", layer.passState(2, 2, 100.2, "x") == false and handed == nil)

-- A new layer of the same instance mounts before the old one unmounts
layer = fresh()
layer.mount(1, 100.0, noop)
layer.mount(1, 100.1, noop)
layer.unmount(1, 100.11)
check("same instance: a second mount and the unmount of the old layer leave it mounted and the owner", layer.isUp(1) == true and layer.owner() == 1)
check("same instance: that layer is not gone, and the step keeps the owner alive", goneAt(1, 100.11 + GONE) == false and select(1, layer.mouse(4, 100.5, noop)) == "blocked")
check("same instance: the mouse event of the layer says up", select(1, layer.mouse(1, 100.6, noop)) == "up")
layer.unmount(1, 105)
check("same instance: the unmount of the last layer takes it down and clears the owner", layer.isUp(1) == false and layer.owner() == 0)
check("same instance: that unmount counts as closed, once", goneAt(1, 105 + GONE) == true and goneAt(1, 105 + GONE) == false)
layer.unmount(1, 106)
layer.mount(1, 110, noop)
layer.unmount(1, 111)
check("an unmount without a mounted layer does not count below zero", layer.isUp(1) == false)
layer = fresh()
layer.mount(1, 100.0, noop)
layer.unmount(1, 100.1)
layer.mount(1, 100.1, noop)
check("unmount, then mount (the other order): the layer is mounted", layer.isUp(1) == true and layer.owner() == 1)

-- An unmount that never came: the count of the next layers must not stay above the layers that exist
layer = fresh()
layer.mount(1, 100.0, noop)
layer.mount(1, 200.0, noop)
layer.unmount(1, 300.0)
check("lost unmount: the next mount and its unmount take the layer down", layer.isUp(1) == false and layer.owner() == 0)
check("lost unmount: that unmount counts as closed, once", goneAt(1, 300.0 + GONE) == true and goneAt(1, 300.0 + GONE) == false)
layer.mount(1, 400.0, noop)
layer.mount(1, 400.1, noop)
layer.unmount(1, 400.1 + GONE - 0.01)
check("re-binding: an unmount less than GONE_SECONDS after the second mount keeps the layer mounted", layer.isUp(1) == true)
layer.unmount(1, 500.0)
check("re-binding: the unmount of the last layer takes it down", layer.isUp(1) == false)

-- A mouse claim marks the layer mounted without a mount event. The mark is replaced by a real mount and cleared by an unmount.
layer = fresh()
check("claim: a mouse event on a layer that never went down claims it", select(1, layer.mouse(4, 100.0, noop)) == "claimed" and layer.isUp(4) == true and layer.owner() == 4)
layer.mount(4, 100.5, noop)
layer.unmount(4, 101.0)
check("claim, mount, unmount: the layer is down and the owner is cleared", layer.isUp(4) == false and layer.owner() == 0)
check("claim, mount, unmount: the unmount counts as closed, once", goneAt(4, 101.0 + GONE) == true and goneAt(4, 101.0 + GONE) == false)

layer = fresh()
layer.mount(2, 100.0, noop)
step(2, 100.5)
check("stale owner, claim: another instance takes the layer once the owner stopped stepping", select(1, layer.mouse(4, 100.5 + layer.OWNER_STALE_SECONDS, noop)) == "claimed" and layer.owner() == 4 and layer.isUp(2) == false)
layer.mount(4, 102.0, noop)
layer.unmount(4, 102.5)
check("stale owner, claim, mount, unmount: the claimed instance is down and the owner is cleared", layer.isUp(4) == false and layer.owner() == 0)

layer = fresh()
layer.mouse(4, 100.0, noop)
layer.unmount(4, 100.5)
check("claim, unmount: the claimed layer unmounts and is down", layer.isUp(4) == false and layer.owner() == 0)
layer.mount(4, 101.0, noop)
layer.unmount(4, 101.1)
check("claim, unmount, then mount and unmount: down again", layer.isUp(4) == false)

-- A mount by another instance replaces the layer of the previous owner: only one world layer is mounted at a time
layer = fresh()
layer.mount(1, 100.0, noop)
layer.mount(2, 100.1, noop)
layer.unmount(2, 100.2)
check("instance 1 mounts, instance 2 mounts and unmounts: no layer is up and nobody owns it", layer.isUp(1) == false and layer.isUp(2) == false and layer.owner() == 0)

-- An instance that is gone is forgotten
layer = fresh()
layer.mount(2, 100.0, noop)
layer.forget(2)
check("forget: the instance is down and the owner is cleared", layer.isUp(2) == false and layer.owner() == 0)
check("forget: nobody receives a state for it", layer.passState(4, 4, 100.1, "x") == false)
layer.mount(3, 101.0, noop)
layer.forget(2)
check("forget: an instance that is not the owner changes nothing", layer.owner() == 3 and layer.isUp(3) == true)
layer.forget(99)
check("forget: an unknown instance is no error", layer.owner() == 3)

-- A layer that counts as not mounted cannot keep the owner alive
layer = fresh()
layer.mount(4, 100.0, noop)
layer.mount(2, 100.1, noop)
step(2, 100.2)
step(4, 101.0)
step(4, 101.5)
check("a step of an instance whose layer is not mounted does not keep the owner alive", select(1, layer.mouse(3, 101.5, noop)) == "claimed")

-- The order of the rules: the block comes before the claim, also for a layer that never went down
layer = fresh()
layer.mount(2, 100.0, noop)
step(2, 100.5)
verdict = layer.mouse(4, 100.6, noop)
check("order: an instance whose layer never went down is blocked, not given the layer", verdict == "blocked" and layer.owner() == 2)

-- The owner stops being alive
layer = fresh()
layer.mount(2, 100.0, noop)
step(2, 100.9)
verdict = layer.mouse(4, 100.9 + layer.OWNER_STALE_SECONDS - 0.01, noop)
check("an owner seen alive just inside the limit still blocks", verdict == "blocked")
verdict = layer.mouse(4, 100.9 + layer.OWNER_STALE_SECONDS, noop)
check("an owner not seen alive for the whole limit stops blocking", verdict == "claimed" and layer.owner() == 4)

layer = fresh()
layer.mount(2, 100.0, noop)
step(2, 105.0)
check("a step of the owner extends the block", select(1, layer.mouse(4, 105.5, noop)) == "blocked")
step(4, 106.0)
check("a step of an instance that is not the owner changes nothing", select(1, layer.mouse(4, 106.2, noop)) == "claimed")

-- An inactive tool does not keep the owner alive
layer = fresh()
layer.mount(2, 100.0, noop)
step(2, 100.5)
layer.step(2, 101.4, false, false)
check("a step of an inactive owner does not keep it alive: another instance takes the layer", select(1, layer.mouse(4, 100.5 + layer.OWNER_STALE_SECONDS, noop)) == "claimed" and layer.owner() == 4)

-- Right after the mount nothing has called alive() yet: the mount counts as seen alive
layer = fresh()
layer.mount(2, 100.0, noop)
check("right after the mount the owner blocks", select(1, layer.mouse(4, 100.01, noop)) == "blocked")

-- The line of a blocked event: mouse events of the owner and the gaps between its steps
layer = fresh()
layer.mount(2, 100.0, noop)
step(2, 100.016)
step(2, 100.25)
step(2, 100.266)
step(4, 100.9)
step(2, 200)
layer.mouse(2, 200.1, noop)
layer.mouse(2, 200.2, noop)
verdict, text = layer.mouse(4, 200.3, noop)
check("evidence: the line holds the mouse events of the owner and the longest gap between its steps",
  verdict == "blocked" and contains(text, "2 mouse events of the owner") and contains(text, "longest gap between its steps 0.23 s"), text)
check("evidence: a step of an instance that is not the owner and a gap of 30 s or more do not count", not contains(text, "0.63 s") and not contains(text, "99."), text)
layer.mount(5, 201, noop)
verdict, text = layer.mouse(4, 201.1, noop)
check("evidence: a new owner starts its event count at 0 and the longest gap stays over the session",
  contains(text, "0 mouse events of the owner") and contains(text, "0.23 s"), text)

-- A lost unmount: the owner keeps stepping with its layer marked mounted, so it keeps blocking the other instances. Only
-- a mount or an unmount of the owner, or the end of its steps, ends the block.
layer = fresh()
layer.mount(2, 100.0, noop)
for i = 1, 60 do step(2, 100 + i * 0.5) end
verdict = layer.mouse(4, 130.4, noop)
check("lost unmount: an owner whose steps go on keeps blocking, however long it lasts", verdict == "blocked" and layer.owner() == 2)
verdict = layer.mouse(4, 130.0 + layer.OWNER_STALE_SECONDS + 0.1, noop)
check("lost unmount: once the steps of the owner stop, another instance takes the layer", verdict == "claimed" and layer.owner() == 4)

-- Unmount
layer = fresh()
layer.mount(2, 100.0, noop)
layer.unmount(4, 100.1)
check("unmount by an instance that is not the owner changes nothing", layer.owner() == 2 and layer.isUp(2) == true)
layer.unmount(2, 100.2)
check("unmount by the owner clears it and takes the layer down", layer.owner() == 0 and layer.isUp(2) == false)
check("after the unmount nobody receives a state", layer.passState(4, 4, 100.3, "x") == false)
verdict = layer.mouse(4, 100.5, noop)
check("after the unmount of the owner another instance takes the layer on a mouse event, once its own unmount is GONE_SECONDS old", verdict == "claimed" and layer.owner() == 4)

-- A new owner replaces the old one
layer = fresh()
layer.mount(2, 100.0, noop)
layer.mount(4, 100.2, noop)
layer.unmount(2, 100.3)
check("mount by #4 makes #4 the owner, and a late unmount by #2 does not clear it", layer.owner() == 4)

-- The rule for a layer that went down
layer = fresh()
layer.mount(2, 90.0, noop)
layer.unmount(2, 99.9)
check("a layer that went down 0.1 s ago is not claimed by a mouse event", select(1, layer.mouse(2, 100, noop)) == "grace" and layer.isUp(2) == false)
check("a layer that went down 0.1 s ago is not gone", goneAt(2, 100) == false)
verdict, text = layer.mouse(2, 99.9 + GONE, noop)
check("a layer that went down GONE_SECONDS ago is claimed by a mouse event", verdict == "claimed" and layer.isUp(2) == true and contains(text, "marked mounted again"), text)
layer.unmount(2, 100)
check("the unmount counts as closed once, GONE_SECONDS after it", goneAt(2, 100 + GONE) == true and goneAt(2, 100 + GONE) == false)
layer.unmount(2, 110)
layer.step(2, 115, false, false)
check("a step of an inactive tool forgets the unmount", goneAt(2, 120) == false)
layer.unmount(2, 125)
layer.step(2, 126, true, true)
check("a step that activates the tool forgets the unmount", goneAt(2, 130) == false)
layer.unmount(2, 131)
check("a step of an inactive tool is never gone and never keeps the owner alive", layer.step(2, 140, false, false) == false)
wasUp, downFor, gone = layer.mount(2, 130, noop)
check("a mount after the unmount was forgotten reports no unmount time", wasUp == false and downFor == nil and gone == false)
layer.unmount(2, 140)
wasUp, downFor, gone = layer.mount(2, 140.1, noop)
check("a mount 0.1 s after the unmount is a re-binding, not a close", wasUp == false and math.abs(downFor - 0.1) < 1e-9 and gone == false)
layer.unmount(2, 150)
wasUp, downFor, gone = layer.mount(2, 155, noop)
check("a mount 5 s after the unmount reports that the layer was closed", gone == true and math.abs(downFor - 5) < 1e-9)

-- The grace period of a passed tool state
layer = fresh()
check("a new instance accepts the params of the menu at once", layer.acceptsParam(2, 1.0) == true)
layer.mount(2, 100.0, noop)
layer.passState(4, 4, 100.0, "x")
check("an instance that got a state does not accept the params of the menu for PUSH_GRACE_SECONDS", layer.acceptsParam(2, 100.0 + layer.PUSH_GRACE_SECONDS) == false)
check("it accepts them again after that", layer.acceptsParam(2, 100.01 + layer.PUSH_GRACE_SECONDS) == true)

-- The blocked line has its own cap
layer = fresh()
local lines = 0
for i = 1, 40 do
  layer.mount(2, 100 + i, noop)
  step(2, 100 + i)
  local _, line = layer.mouse(4, 100 + i + 0.1, noop)
  if line ~= nil then lines = lines + 1 end
end
check("the blocked line is capped per session, one per episode", lines == 20, lines)

-- The stuck ring
layer = fresh()
check("a step that never ran is a stuck ring", layer.ringStuck(nil, 100, nil, nil, nil, nil) == true)
check("a step 0.5 s ago and no ring is not stuck", layer.ringStuck(99.5, 100, nil, nil, nil, nil) == false)
check("a step longer than STUCK_RING_AFTER ago is stuck", layer.ringStuck(100 - layer.STUCK_RING_AFTER - 0.01, 100, nil, nil, nil, nil) == true)
check("a step exactly STUCK_RING_AFTER ago is not stuck", layer.ringStuck(100 - layer.STUCK_RING_AFTER, 100, nil, nil, nil, nil) == false)
check("a ring near the pointer is not stuck", layer.ringStuck(99.9, 100, 10, 10, 15, 12) == false)
check("a ring beyond STUCK_RING_OFFSET in x is stuck", layer.ringStuck(99.9, 100, 10, 10, 10 + layer.STUCK_RING_OFFSET + 0.1, 10) == true)
check("a ring beyond STUCK_RING_OFFSET in y is stuck", layer.ringStuck(99.9, 100, 10, 10, 10, 10 - layer.STUCK_RING_OFFSET - 0.1) == true)
check("a ring exactly STUCK_RING_OFFSET away is not stuck", layer.ringStuck(99.9, 100, 10, 10, 10 + layer.STUCK_RING_OFFSET, 10) == false)
check("a ring without a terrain position under the pointer is stuck", layer.ringStuck(99.9, 100, 10, 10, nil, nil) == true)

support.finish("brush_layer")
