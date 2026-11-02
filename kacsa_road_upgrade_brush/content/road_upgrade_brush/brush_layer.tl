-- The state of the world layer of every instance of the tool recipe, and the rules that follow from it: which instance owns
-- the mounted layer, which instance may take it on a mouse event, and when a click counts as a stuck ring.
-- Pure: no api.* calls. The owner is the instance that mounted the layer last and that has not unmounted it.

local layer : RubLayer = {}

-- Seconds. An owner whose layer was not seen alive for this long counts as gone.
layer.OWNER_STALE_SECONDS = 1.0
-- Seconds. An unmounted layer counts as closed once it stays unmounted this long. An unmount followed by a mount in the same
-- frame (re-binding) is not a close.
layer.GONE_SECONDS = 0.25
-- Seconds. A tool state passed in by the newest instance stays this long.
layer.PUSH_GRACE_SECONDS = 0.5
-- A click is a stuck ring when the step did not update the ring for this long (seconds), or when the ring is more than
-- STUCK_RING_OFFSET metres from the terrain position under the pointer.
layer.STUCK_RING_AFTER = 1.0
layer.STUCK_RING_OFFSET = 20.0

-- Seconds. A longer gap between two steps of the owner means its tool was inactive. It does not count as a gap of the steps.
local STEP_GAP_MAX_SECONDS <const> = 30
-- Lines of "mouse event ignored" per session.
local BLOCKED_LINES_MAX <const> = 20

local record Instance
	-- Mounted world-layer components of the instance. A new layer mounts before the old one unmounts, so it can be 2.
	mounted : integer
	-- true when a mouse event marked the layer mounted again and no mount event has come since. The next mount replaces
	-- this mark, the next unmount clears it.
	claimed : boolean
	-- os.clock() of the last mount; nil when there was none.
	mountedAt : number
	-- os.clock() the layer went down; nil when it never did.
	downAt : number
	-- os.clock() a newer instance passed its tool state in.
	pushedAt : number
	setParam : function(any)
end

local instances : {integer : Instance} = {}
local ownerId = 0
local ownerAliveAt : number = 0
local ownerEvents = 0
local longestStepGap : number = 0
-- true after the first blocked mouse event of an episode; false after the next mount.
local blockedNoted = false
local blockedLines = 0

local function instanceOf(me : integer) : Instance
	local inst = instances[me]
	if inst == nil then
		inst = { mounted = 0, claimed = false, mountedAt = nil, downAt = nil, pushedAt = -layer.PUSH_GRACE_SECONDS, setParam = nil }
		instances[me] = inst
	end
	return inst
end

local function goneFor(downAt : number, now : number) : boolean
	return downAt ~= nil and now - downAt >= layer.GONE_SECONDS
end

-- true when another instance owns a layer that was seen alive less than OWNER_STALE_SECONDS ago.
local function blocksClaim(me : integer, now : number) : boolean
	return ownerId ~= 0 and ownerId ~= me and now - ownerAliveAt < layer.OWNER_STALE_SECONDS
end

function layer.owner() : integer
	return ownerId
end

local function isMounted(inst : Instance) : boolean
	return inst.mounted > 0 or inst.claimed
end

function layer.isUp(me : integer) : boolean
	return isMounted(instanceOf(me))
end

-- `me` takes the layer: it becomes the owner and its layer counts as seen alive.
local function takeLayer(me : integer, inst : Instance, now : number, setParam : function(any))
	-- Only one world layer is mounted at a time, so a mount by another instance replaces the layer of the previous owner.
	if ownerId ~= 0 and ownerId ~= me then
		local previous = instanceOf(ownerId)
		previous.mounted = 0
		previous.claimed = false
	end
	inst.downAt = nil
	inst.setParam = setParam
	blockedNoted = false
	ownerId = me
	ownerAliveAt = now
	ownerEvents = 0
end

function layer.mount(me : integer, now : number, setParam : function(any)) : boolean, number, boolean
	local inst = instanceOf(me)
	local wasUp = isMounted(inst)
	local downFor = inst.downAt ~= nil and now - inst.downAt or nil
	local gone = goneFor(inst.downAt, now)
	takeLayer(me, inst, now, setParam)
	inst.claimed = false
	inst.mounted = inst.mounted + 1
	inst.mountedAt = now
	return wasUp, downFor, gone
end

function layer.unmount(me : integer, now : number)
	local inst = instanceOf(me)
	-- A count of 2 that stays for GONE_SECONDS after the last mount counts as 1.
	if inst.mounted > 1 and now - inst.mountedAt >= layer.GONE_SECONDS then inst.mounted = 1 end
	if inst.mounted > 0 then inst.mounted = inst.mounted - 1 else inst.claimed = false end
	if inst.mounted > 0 then return end
	inst.downAt = now
	if ownerId == me then ownerId = 0 end
end

function layer.forget(me : integer)
	instances[me] = nil
	if ownerId == me then ownerId = 0 end
end

function layer.step(me : integer, now : number, active : boolean, activated : boolean) : boolean, boolean
	local inst = instanceOf(me)
	if activated or not active then inst.downAt = nil end
	local up = isMounted(inst)
	if not active then return false, up end
	local gone = goneFor(inst.downAt, now)
	if gone then inst.downAt = nil end
	if up then
		local gap = now - ownerAliveAt
		if gap > longestStepGap and gap < STEP_GAP_MAX_SECONDS then longestStepGap = gap end
		ownerAliveAt = now
	end
	return gone, up
end

function layer.passState(me : integer, newest : integer, now : number, state : any) : boolean
	if ownerId == 0 or ownerId == me or me ~= newest then return false end
	local owner = instanceOf(ownerId)
	if owner.setParam == nil then return false end
	owner.setParam(state)
	owner.pushedAt = now
	return true
end

function layer.acceptsParam(me : integer, now : number) : boolean
	return now - instanceOf(me).pushedAt > layer.PUSH_GRACE_SECONDS
end

function layer.mouse(me : integer, now : number, setParam : function(any)) : string, string
	local inst = instanceOf(me)
	if ownerId == me then ownerEvents = ownerEvents + 1 end
	if isMounted(inst) then return "up", nil end
	if blocksClaim(me, now) then
		if blockedNoted or blockedLines >= BLOCKED_LINES_MAX then return "blocked", nil end
		blockedNoted = true
		blockedLines = blockedLines + 1
		return "blocked", string.format("instance #%d: mouse event ignored, instance #%d owns the layer (seen alive %.2f s ago, %d mouse events of the owner since it claimed the layer, longest gap between its steps %.2f s)",
			me, ownerId, now - ownerAliveAt, ownerEvents, longestStepGap)
	end
	if inst.downAt == nil or goneFor(inst.downAt, now) then
		takeLayer(me, inst, now, setParam)
		inst.claimed = true
		return "claimed", string.format("instance #%d: mouse event on a layer marked unmounted, marked mounted again", me)
	end
	return "grace", nil
end

function layer.ringStuck(stepAt : number, now : number, ringX : number, ringY : number, liveX : number, liveY : number) : boolean
	if stepAt == nil or now - stepAt > layer.STUCK_RING_AFTER then return true end
	if ringX == nil then return false end
	return liveX == nil or math.abs(liveX - ringX) > layer.STUCK_RING_OFFSET or math.abs(liveY - ringY) > layer.STUCK_RING_OFFSET
end

return layer
