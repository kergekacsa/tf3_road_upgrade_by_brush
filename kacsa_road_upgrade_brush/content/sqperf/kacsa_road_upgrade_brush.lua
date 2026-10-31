-- Based on 'Bulk Bulldozer' by square17 (mod.io 6434884).
-- SQPERF: performance instrumentation for square_* mods.
-- Every mod ships its own copy at content/sqperf/<modId>.lua.
--
-- Plain Lua that runs in the game: pre-5.3 only (no //, bit ops, utf8, math.tointeger, goto).
-- Counters live in this module's locals, one copy per Lua state. Nothing is saved, no command is
-- sent, no game script state is touched.
--
-- Three levels, all lines go to <userdata>/crash_dump/stdout.txt via log.message:
--   1. init (always on, above a threshold): one line per instrument when its setup is done
--      (inst:phase), and one line when every section named in opts.first finished its first call:
--        [SQPERF] mod=square_x ctx=gs vm=3f2a phase=init ms=212.4 timer=clock
--        [SQPERF] mod=square_x ctx=gs vm=3f2a phase=first ms=48.0 scan_a=40.1 scan_b=7.9
--      Each is logged only when its ms is at least INIT_LOG_MS (opts.initMs); with level 3 on, always.
--   2. slow-call watchdog (always on): a call longer than the threshold (16 ms GUI-thread contexts,
--      50 ms simulation / game-script contexts) logs at most one line per section per 60 s,
--      covering every call since that section's previous line:
--        [SQPERF] mod=square_x ctx=gui vm=3f2a slow=window_render max=41.2 over=3/1200
--   3. window summary (opt-in, the mod's "Debug: performance log" param): one line per 30 s:
--        [SQPERF] mod=square_x ctx=gs vm=3f2a win_ms=30004.1 timer=clock mem_kb=5120 | scan_a n=12 ms=4.210 max=1.020 | toasts c=3
--      Off: no output, and counters / window sums are not even accumulated. The gate (debugOn) is
--      the mod's own param == 2 OR the DEV master switch mod square_sqperf_all is active.
--
-- Timer: api.type.Clock (wall clock, microseconds; api/tealdef/api/type.d.tl "record Clock"),
-- created inside pcall; fallback os.clock (process CPU time, overstates on macOS while other
-- threads are busy). Clock is safe in every GUI context, including the worker threads ("Main Pool
-- N") that run react onStepTimer callbacks and hudIconScript functions/recipes, and getTime costs
-- ~0.07 us.
-- Instruments created with timed = false never read any clock (counts only).
-- This module only calls api.type.Clock, log.message, collectgarbage and
-- api.engine.config.getModParams (gate), never a GUI-only API.
--
-- Hot path (start/stop/hit/wrap) allocates nothing once a section exists: no tables, closures or
-- strings. Strings are only built when a line is logged.

local M = {}

M.VERSION = 4
-- Slow-call thresholds (ms per single call).
M.GUI_SLOW_MS = 16
M.SIM_SLOW_MS = 50
-- At most one slow line per section per this many ms of real time.
M.RATE_MS = 60000
-- Level 3 window length (ms).
M.WINDOW_MS = 30000
-- Level 1: phase / phase=first lines below this many ms are dropped unless level 3 is on.
M.INIT_LOG_MS = 5
M.GUI_CONTEXTS = { gui = true, hud = true, step = true }

local NEG_INF = -math.huge

-- Short id of this Lua state: the module table's address.
local vm = string.match(tostring(M), "0x0*(%x+)$") or string.sub(tostring(M), -6)
vm = string.sub(vm, -6)
M.vm = vm

local function emit(msg)
	if log ~= nil and log.message ~= nil then
		log.message(msg)
	elseif print ~= nil then
		print(msg)
	end
end
M.emit = emit

local clock, clockTried = nil, false

local function clockNow()
	return clock:getTime() / 1000
end

local function osNow()
	return os.clock() * 1000
end

local function defaultTimer()
	if not clockTried then
		clockTried = true
		local ok, c = pcall(function() return api.type.Clock.new() end)
		if ok and c ~= nil then
			local ok2 = pcall(function() return c:getTime() end)
			if ok2 then clock = c end
		end
	end
	if clock ~= nil then return clockNow, "clock" end
	return osNow, "os.clock"
end

-- DEV master switch: while the mod with this id is active (mods/square_sqperf_all, never uploaded),
-- every SQPERF mod logs as if its own "Debug: performance log" were On. The engine's mod params table
-- (getModParams(), runFn's allModParams) has an entry for every active mod, even one without params.
M.MASTER_MOD = "square_sqperf_all"
-- The debug param every SQPERF mod declares (values {"Off", "On"}).
M.PARAM_KEY = "sqperf_log"

--- True when all[mod][key] is the 2nd value (params reach scripts as 1-based value indices) or when
--- the master switch mod is active (all[MASTER_MOD] present). all is getModParams() or runFn's allModParams.
--- key defaults to PARAM_KEY. Anything that is not a table: false. Never errors, allocates nothing.
local function debugOn(all, mod, key)
	if type(all) ~= "table" then return false end
	if all[M.MASTER_MOD] ~= nil then return true end
	local mine = all[mod]
	return type(mine) == "table" and mine[key or M.PARAM_KEY] == 2
end
M.debugOn = debugOn

--- debugOn on api.engine.config.getModParams(), in pcall: any error (e.g. a Lua state without
--- api.engine) is false.
local function readParam(mod, key)
	local ok, all = pcall(function() return api.engine.config.getModParams() end)
	return ok and debugOn(all, mod, key)
end
M.readParam = readParam

local Inst = {}
Inst.__index = Inst

local function fmt(ms)
	return string.format("%.1f", ms)
end

--- New instrument. opts:
---   mod      (string, required)  modId, logged as mod=
---   ctx      (string)            "gs", "gui", "hud", "step", "run", ... logged as ctx=
---   timed    (boolean)           false: never read a clock (counts only). Default true.
---   slowMs   (number)            slow-call threshold; default GUI_SLOW_MS for GUI_CONTEXTS, else SIM_SLOW_MS
---   paramKey (string)            mod.json param (values {"Off", "On"}) that enables level 3; read with
---                                getModParams at each window boundary (timed instruments only)
---   enabled  (boolean)           level 3 on/off fixed by the caller (overrides paramKey)
---   gate     (function)          returns level 3 on/off; called at each window boundary (overrides both)
---   first    ({string})          sections whose first calls make up the phase=first line
---   initMs   (number)            level 1 threshold: phase / phase=first lines below it are only
---                                logged while level 3 is on. Default INIT_LOG_MS
---   now      (function)          ms timer override
function M.new(opts)
	opts = opts or {}
	local self = setmetatable({}, Inst)
	self.mod = tostring(opts.mod or "?")
	self.ctx = tostring(opts.ctx or "?")
	self.timed = opts.timed ~= false
	self.slowMs = opts.slowMs or (M.GUI_CONTEXTS[self.ctx] and M.GUI_SLOW_MS or M.SIM_SLOW_MS)
	self.initMs = opts.initMs or M.INIT_LOG_MS
	self.prefix = "[SQPERF] mod=" .. self.mod .. " ctx=" .. self.ctx .. " vm=" .. vm
	if opts.gate ~= nil then
		self.gate = opts.gate
	elseif opts.enabled ~= nil then
		local fixed = opts.enabled == true
		self.gate = function() return fixed end
	elseif opts.paramKey ~= nil and self.timed then
		local mod, key = self.mod, opts.paramKey
		self.gate = function() return readParam(mod, key) end
	end
	if self.timed then
		if opts.now ~= nil then
			self.now, self.timer = opts.now, "custom"
		else
			self.now, self.timer = defaultTimer()
		end
	else
		self.timer = "none"
		-- Untimed: windows run on os.time; the gate is read once here.
		self.now = function() return os.time() * 1000 end
	end
	self.sec = {}
	self.cnt = {}
	self.names = {} -- section names in creation order
	self.on = false
	-- -inf: the first timed stop opens the first window (and reads the gate) at once.
	self.winStart = NEG_INF
	if not self.timed then
		self.on = self.gate ~= nil and self.gate() == true
		self.winStart = self.now()
	end
	self.firstLeft = 0
	self.firstMs = nil
	self.firstSet = {}
	if opts.first ~= nil then
		for _, name in ipairs(opts.first) do
			if not self.firstSet[name] then
				self.firstSet[name] = true
				self.firstLeft = self.firstLeft + 1
			end
		end
	end
	return self
end

function Inst:_section(name)
	local s = {
		n = 0, slowN = 0, slowMax = 0, lastLog = NEG_INF, -- level 2, since the last slow line
		wn = 0, wms = 0, wmax = 0,                        -- level 3, this window
		firstPending = self.firstSet[name] == true,
	}
	self.sec[name] = s
	self.names[#self.names + 1] = name
	return s
end

--- Start time for stop() (0 for an untimed instrument).
function Inst:start()
	if not self.timed then return 0 end
	return self.now()
end

function Inst:_logSlow(name, s, now)
	emit(self.prefix .. " slow=" .. name .. " max=" .. fmt(s.slowMax) .. " over=" .. s.slowN .. "/" .. s.n)
	s.n, s.slowN, s.slowMax, s.lastLog = 0, 0, 0, now
end

--- True while level 3 is on, for a level 1 line below initMs. A timed instrument reads its gate first
--- at its first window boundary (first stop), so this reads the gate once more, in pcall (an error is off).
function Inst:_debugOn()
	if self.on then return true end
	if self.gate == nil then return false end
	local ok, v = pcall(self.gate)
	return ok and v == true
end

--- True when a level 1 line of ms should be logged.
function Inst:_logPhase(ms)
	return ms >= self.initMs or self:_debugOn()
end

function Inst:_first(name, s, ms)
	s.firstPending = false
	self.firstMs = self.firstMs or {}
	self.firstMs[#self.firstMs + 1] = { name, ms }
	self.firstLeft = self.firstLeft - 1
	if self.firstLeft > 0 then return end
	local parts, total = {}, 0
	for i, e in ipairs(self.firstMs) do
		total = total + e[2]
		parts[i] = e[1] .. "=" .. fmt(e[2])
	end
	self.firstMs = nil
	if not self:_logPhase(total) then return end
	emit(self.prefix .. " phase=first ms=" .. fmt(total) .. " " .. table.concat(parts, " "))
end

function Inst:_window(now)
	for _, name in ipairs(self.names) do
		local s = self.sec[name]
		if s.slowN > 0 and now - s.lastLog >= M.RATE_MS then self:_logSlow(name, s, now) end
	end
	if self.on and self.winStart > NEG_INF then self:_summary(now) end
	local wasOn = self.on
	if self.gate ~= nil then
		local ok, v = pcall(self.gate)
		self.on = ok and v == true
	end
	if self.on and not wasOn then self:_resetWindow() end
	self.winStart = now
end

function Inst:_resetWindow()
	for _, name in ipairs(self.names) do
		local s = self.sec[name]
		s.wn, s.wms, s.wmax = 0, 0, 0
	end
	self.cnt = {}
end

function Inst:_summary(now)
	local parts = { self.prefix .. " win_ms=" .. fmt(now - self.winStart) .. " timer=" .. self.timer }
	local okMem, kb = pcall(collectgarbage, "count")
	if okMem and type(kb) == "number" then
		parts[1] = parts[1] .. " mem_kb=" .. string.format("%d", math.floor(kb))
	end
	local names = {}
	for _, name in ipairs(self.names) do
		if self.sec[name].wn > 0 then names[#names + 1] = name end
	end
	table.sort(names)
	for _, name in ipairs(names) do
		local s = self.sec[name]
		if self.timed and not s.untimed then
			parts[#parts + 1] = string.format("%s n=%d ms=%.3f max=%.3f", name, s.wn, s.wms, s.wmax)
		else
			parts[#parts + 1] = string.format("%s n=%d", name, s.wn)
		end
	end
	names = {}
	for name in pairs(self.cnt) do names[#names + 1] = name end
	table.sort(names)
	for _, name in ipairs(names) do
		parts[#parts + 1] = string.format("%s c=%d", name, self.cnt[name])
	end
	emit(table.concat(parts, " | "))
	self:_resetWindow()
end

--- Ends one timed call of section `name` started at t0 (from start()). Returns its ms (0 untimed).
function Inst:stop(name, t0)
	local s = self.sec[name]
	if s == nil then s = self:_section(name) end
	if not self.timed then
		self:hit(name)
		return 0
	end
	local now = self.now()
	local ms = now - t0
	s.n = s.n + 1
	if ms > self.slowMs then
		s.slowN = s.slowN + 1
		if ms > s.slowMax then s.slowMax = ms end
	end
	if s.slowN > 0 and now - s.lastLog >= M.RATE_MS then self:_logSlow(name, s, now) end
	if self.on then
		s.wn = s.wn + 1
		s.wms = s.wms + ms
		if ms > s.wmax then s.wmax = ms end
	end
	if s.firstPending then self:_first(name, s, ms) end
	if now - self.winStart >= M.WINDOW_MS then self:_window(now) end
	return ms
end

--- Counts one call of section `name` without reading a clock.
--- Shows as `name n=…` in the window summary; never slow-logged. Untimed instruments open their
--- windows here (os.time), timed ones on their next stop().
function Inst:hit(name)
	local s = self.sec[name]
	if s == nil then
		s = self:_section(name)
		s.untimed = true
	end
	s.n = s.n + 1
	if not self.on then return end
	s.wn = s.wn + 1
	if not self.timed then
		local now = self.now()
		if now - self.winStart >= M.WINDOW_MS then self:_window(now) end
	end
end

--- Adds n (default 1) to counter `name`. Only while level 3 is on.
function Inst:count(name, n)
	if not self.on then return end
	local c = self.cnt
	c[name] = (c[name] or 0) + (n or 1)
end

--- Logs `phase=<name> ms=<since t0> timer=<timer>` (level 1) when ms >= initMs or level 3 is on.
--- Call once per phase. Returns ms either way.
--- Optional detail, appended after one space: a string, or a string.format pattern plus its
--- arguments (`perf:phase("towns", t, "towns=%d num=%s", #res, tostring(num))`). Nothing is built or allocated
--- when the line is dropped; formatting happens only when the line is logged, in pcall.
--- A bad pattern logs the raw pattern.
function Inst:phase(name, t0, detail, ...)
	local ms = 0
	if self.timed then ms = self.now() - t0 end
	if not self:_logPhase(ms) then return ms end
	local line = self.prefix .. " phase=" .. name .. " ms=" .. fmt(ms) .. " timer=" .. self.timer
	if detail ~= nil then
		if select("#", ...) > 0 then
			local ok, s = pcall(string.format, detail, ...)
			if ok then detail = s end
		end
		line = line .. " " .. tostring(detail)
	end
	emit(line)
	return ms
end

local function finish(self, name, t0, ...)
	self:stop(name, t0)
	return ...
end

--- fn wrapped as section `name`: same arguments, same return values. An error raised by fn passes
--- through unchanged (no pcall here); that call is then simply not recorded.
function Inst:wrap(name, fn)
	local inst = self
	if not self.timed then
		return function(...)
			inst:hit(name)
			return fn(...)
		end
	end
	local now = self.now
	return function(...)
		local t0 = now()
		return finish(inst, name, t0, fn(...))
	end
end

return M
