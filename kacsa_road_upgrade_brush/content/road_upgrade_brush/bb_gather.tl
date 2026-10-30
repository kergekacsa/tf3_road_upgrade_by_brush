-- Based on 'Bulk Bulldozer' by square17 (mod.io 6434884). Private build, not for publication.
-- Bulk Bulldozer gather layer (PLAN "Architecture": bb_gather.tl). API side of the selection:
-- octree queries → plain BulkBulldozerDesc tables → bb_select.classify. Runs only in the GUI
-- custom-action recipe (GUI thread, research §6). Every engine read is wrapped in pcall so a
-- vanished or odd entity becomes a "gone" skip instead of a Lua error. Read-only: no commands.
--
-- API used (verified against .cache/game/api/tealdef, research §4 / §8):
--   api.engine.util.octree.findEntitiesInCircle   engine/util.d.tl:329
--   api.engine.getComponent / entityExists         engine.d.tl:1690, 1723
--   Engine.Component.BaseEdge (type, objects, node0/1, position0/1, tangent0/1)  engine.d.tl:99-130
--   Engine.Component.Construction (transf, stations, depots, industries, townBuildings,
--     frozenNodes, frozenEdges)                    engine.d.tl:295-335; Mat4f:getTransl type.d.tl:783
--   Engine.Component.PlayerOwned.player / Player.headquarters   engine.d.tl:847-860
--   streetConnectorSystem.getConstructionEntityForEdge/Node/Subconstruction  engine/system.d.tl:240-250
--   api.engine.util.construction.findSegmentsToDelete(con, false)  engine/util.d.tl:827
--   api.engine.util.getPlayer                      engine/util.d.tl:1023

local brush = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/bb_brush.tl" as BulkBulldozerBrush
local sel = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/bb_select.tl" as BulkBulldozerSelect

local gather : BulkBulldozerGather = {}

function gather.newCache() : BulkBulldozerGatherCache
	return {
		descs = {},
		industryRoads = {},
		industryCons = {},
		conIsIndustry = {},
		createdAt = os.clock(),
	}
end

local function comp(e : integer, t : Engine.ComponentType) : any
	local ok, c = pcall(function() : any
		local v : any = api.engine.getComponent(e, t)
		return v
	end)
	if ok then return c end
	return nil
end

local function exists(e : integer) : boolean
	if e == nil or e < 0 then return false end
	local ok, r = pcall(api.engine.entityExists, e)
	return ok and r == true
end

local function ownerOf(e : integer) : integer
	local po = comp(e, api.type.ComponentType.PLAYER_OWNED) as Engine.Component.PlayerOwned
	if po == nil or po.player == nil then return -1 end
	return po.player
end

function gather.context() : BulkBulldozerContext
	local ctx : BulkBulldozerContext = { player = -1, hq = -1 }
	local okP, p = pcall(api.engine.util.getPlayer)
	if okP and p ~= nil then ctx.player = p end
	if ctx.player >= 0 then
		local pc = comp(ctx.player, api.type.ComponentType.PLAYER) as Engine.Component.Player
		if pc ~= nil and pc.headquarters ~= nil then ctx.hq = pc.headquarters end
	end
	return ctx
end

-- true when the construction has industries (cached per stroke).
local function conIsIndustry(con : integer, cache : BulkBulldozerGatherCache) : boolean
	if con == nil or con < 0 then return false end
	local v = cache.conIsIndustry[con]
	if v == nil then
		local c = comp(con, api.type.ComponentType.CONSTRUCTION) as Engine.Component.Construction
		v = c ~= nil and c.industries ~= nil and #c.industries > 0
		cache.conIsIndustry[con] = v
	end
	return v
end

-- Marks every street segment that goes with an industry construction (the same set the base
-- removes with it, industry_util.tl:563-570), so town-style industry roads are never selected.
local function protectIndustryRoads(con : integer, cache : BulkBulldozerGatherCache)
	if cache.industryCons[con] then return end
	cache.industryCons[con] = true
	local ok, segs = pcall(api.engine.util.construction.findSegmentsToDelete, con, false)
	if ok and segs ~= nil then
		for _, s in ipairs(segs) do cache.industryRoads[s] = true end
	end
end

local function nodeConstruction(n : integer) : integer
	if n == nil or n < 0 then return -1 end
	local ok, c = pcall(api.engine.system.streetConnectorSystem.getConstructionEntityForNode, n)
	if ok and c ~= nil then return c end
	return -1
end

-- Descriptors are read in two steps (PERF_REVIEW.md): the octree query is r + EDGE_MARGIN wide, so
-- most entities it returns are not under the brush. The light step reads only what the touch /
-- origin test needs (BASE_EDGE geometry; CONSTRUCTION origin and counts, which also mark
-- industries); the full step (owner, street, connector lookups, station owner, subconstruction)
-- runs once the entity is hit, so sel.classify only ever sees complete descriptors (d.full).
local function edgeLight(e : integer, cache : BulkBulldozerGatherCache) : BulkBulldozerDesc
	local d : BulkBulldozerDesc = cache.descs[e]
	if d ~= nil then return d end
	d = { entity = e, isEdge = true, gone = true, full = true, owner = -1, parentConstruction = -1, objects = {} }
	cache.descs[e] = d
	if not exists(e) then return d end
	local be = comp(e, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	if be == nil or be.position0 == nil or be.position1 == nil or be.tangent0 == nil or be.tangent1 == nil then
		return d
	end
	d.gone = false
	d.full = false
	d.node0, d.node1 = be.node0, be.node1
	d.isTunnel = be.type == api.type.enum.BaseEdgeType.TUNNEL
	if be.objects ~= nil then
		for _, o in ipairs(be.objects) do
			if o ~= nil and o[1] ~= nil then d.objects[#d.objects + 1] = o[1] end
		end
	end
	d.curve = {
		p0x = be.position0.x, p0y = be.position0.y,
		t0x = be.tangent0.x, t0y = be.tangent0.y,
		p1x = be.position1.x, p1y = be.position1.y,
		t1x = be.tangent1.x, t1y = be.tangent1.y,
		-- heights for the highlight lines (bb_highlight.curveZ); bridges keep their deck height
		p0z = be.position0.z, t0z = be.tangent0.z,
		p1z = be.position1.z, t1z = be.tangent1.z,
	}
	return d
end

-- A street with lanes, none of which carries a car, a bus or a truck: a stand-alone tram track. A road with tram tracks
-- on top of its lanes still has the lanes of its vehicles.
local function isTramOnly(e : integer) : boolean
	local be = comp(e, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	if be == nil or be.laneConfigs == nil or #be.laneConfigs == 0 then return false end
	local modes = api.type.enum.TransportMode
	for _, lane in ipairs(be.laneConfigs) do
		local m = lane.transportModes
		if m ~= nil and (m[modes.CAR] or m[modes.BUS] or m[modes.TRUCK]) then return false end
	end
	return true
end

local function edgeFull(d : BulkBulldozerDesc, cache : BulkBulldozerGatherCache) : BulkBulldozerDesc
	if d.full then return d end
	d.full = true
	local e = d.entity
	d.owner = ownerOf(e)
	local okC, con = pcall(api.engine.system.streetConnectorSystem.getConstructionEntityForEdge, e)
	d.parentConstruction = (okC and con ~= nil) and con or -1
	d.isStreet = comp(e, api.type.ComponentType.BASE_EDGE_STREET) ~= nil
	if d.isStreet then d.tramOnly = isTramOnly(e) end
	-- An unowned street that ends on a node frozen in an industry is an industry access road
	-- even when findSegmentsToDelete of that industry was not run (industry origin far away).
	if d.owner < 0 and d.parentConstruction < 0 then
		d.industryRoad = conIsIndustry(nodeConstruction(d.node0), cache)
			or conIsIndustry(nodeConstruction(d.node1), cache)
	end
	return d
end

function gather.describeEdge(e : integer, cache : BulkBulldozerGatherCache) : BulkBulldozerDesc
	return edgeFull(edgeLight(e, cache), cache)
end

-- Owner of a station/depot construction whose construction entity has no PLAYER_OWNED
-- (Phase 2 flag; research §9). The base reads station ownership from the station group
-- (station_group.tl:855 useOwnershipStepState(stationGroupEntityId); manager_window.tl:295) and
-- depot ownership from the construction (maintenance_station.tl:31). Here: PLAYER_OWNED of every
-- station, its station group and every depot. Fail-safe: no owner found → -1 (unowned, never
-- selected as a station); owners that disagree → OWNER_CONFLICT (also unowned).
local OWNER_CONFLICT <const> = -2
local function stationOwner(c : Engine.Component.Construction) : integer
	local found = -1
	local function see(o : integer) : boolean
		if o < 0 then return true end
		if found >= 0 and found ~= o then found = OWNER_CONFLICT; return false end
		found = o
		return true
	end
	for _, st in ipairs(c.stations or {}) do
		if not see(ownerOf(st)) then return found end
		local okG, g = pcall(api.engine.system.stationGroupSystem.getStationGroup, st)
		if okG and g ~= nil and g >= 0 then
			if not see(ownerOf(g)) then return found end
		end
	end
	for _, dp in ipairs(c.depots or {}) do
		if not see(ownerOf(dp)) then return found end
	end
	return found
end

local function constructionLight(e : integer, cache : BulkBulldozerGatherCache) : BulkBulldozerDesc
	local d : BulkBulldozerDesc = cache.descs[e]
	if d ~= nil then return d end
	d = { entity = e, isEdge = false, gone = true, full = true, owner = -1, parentConstruction = -1,
		stations = 0, depots = 0, industries = 0, townBuildings = 0, frozen = 0 }
	cache.descs[e] = d
	if not exists(e) then return d end
	local c = comp(e, api.type.ComponentType.CONSTRUCTION) as Engine.Component.Construction
	if c == nil then return d end
	local okT, t = pcall(function() : Vec3f return c.transf:getTransl() end)
	if not okT or t == nil then return d end
	d.gone = false
	d.full = false
	d.x, d.y = t.x, t.y
	d.stations = c.stations ~= nil and #c.stations or 0
	d.depots = c.depots ~= nil and #c.depots or 0
	d.industries = c.industries ~= nil and #c.industries or 0
	d.townBuildings = c.townBuildings ~= nil and #c.townBuildings or 0
	d.frozen = (c.frozenEdges ~= nil and #c.frozenEdges or 0) + (c.frozenNodes ~= nil and #c.frozenNodes or 0)
	cache.conIsIndustry[e] = d.industries > 0
	return d
end

local function constructionFull(d : BulkBulldozerDesc) : BulkBulldozerDesc
	if d.full then return d end
	d.full = true
	local e = d.entity
	d.owner = ownerOf(e)
	if d.owner < 0 and d.industries == 0 and (d.stations > 0 or d.depots > 0) then
		-- Rare (a station without PLAYER_OWNED on its construction): read the lists again.
		local c = comp(e, api.type.ComponentType.CONSTRUCTION) as Engine.Component.Construction
		if c ~= nil then d.owner = stationOwner(c) end
	end
	-- A subconstruction goes with its parent construction (overpass_probe.script.tl:339-341).
	if comp(e, api.type.ComponentType.SUBCONSTRUCTION) ~= nil then
		local okS, parent = pcall(api.engine.system.streetConnectorSystem.getConstructionEntityForSubconstruction, e)
		if okS and parent ~= nil and parent >= 0 and parent ~= e then d.parentConstruction = parent end
	end
	return d
end

function gather.describeConstruction(e : integer, cache : BulkBulldozerGatherCache) : BulkBulldozerDesc
	return constructionFull(constructionLight(e, cache))
end

local function query(cx : number, cy : number, r : number, t : Engine.ComponentType) : {integer}, boolean
	local ok, res = pcall(api.engine.util.octree.findEntitiesInCircle, api.type.Vec2f.new(cx, cy), r, t)
	if not ok or res == nil then return {}, false end
	return res as {integer}, #res > brush.SAMPLE_MAX_ENTITIES
end

function gather.sample(cx : number, cy : number, r : number, f : BulkBulldozerFilters,
		ctx : BulkBulldozerContext, cache : BulkBulldozerGatherCache) : BulkBulldozerSampleResult
	local t0 = os.clock()
	local out : BulkBulldozerSampleResult = { candidates = {}, edgeHits = 0, conHits = 0, truncated = false, seconds = 0 }
	local qr = brush.edgeQueryRadius(r)
	local max = brush.SAMPLE_MAX_ENTITIES

	-- Constructions first: industries found within the wide radius protect their roads below.
	local cons, truncC = query(cx, cy, qr, api.type.ComponentType.CONSTRUCTION)
	out.conHits = #cons
	local direct : {integer : boolean} = nil
	if not sel.CONSTRUCTION_ORIGIN_ONLY then
		direct = {}
		for _, e in ipairs((query(cx, cy, r, api.type.ComponentType.CONSTRUCTION))) do direct[e] = true end
	end
	for i, e in ipairs(cons) do
		if i > max then break end
		local d = constructionLight(e, cache)
		if not d.gone and d.industries > 0 then protectIndustryRoads(e, cache) end
		local hit : boolean
		if direct ~= nil then
			hit = direct[e] == true
		else
			hit = not d.gone and brush.pointInCircle(d.x, d.y, cx, cy, r)
		end
		-- A gone construction has no position; it is simply not under the brush any more.
		if hit and not d.gone then
			out.candidates[#out.candidates + 1] = sel.classify(constructionFull(d), f, ctx)
		end
	end

	local edges, truncE = query(cx, cy, qr, api.type.ComponentType.BASE_EDGE)
	out.edgeHits = #edges
	for i, e in ipairs(edges) do
		if i > max then break end
		local d = edgeLight(e, cache)
		if not d.gone and brush.curveTouchesCircle(d.curve, cx, cy, r) then
			edgeFull(d, cache)
			if cache.industryRoads[e] then d.industryRoad = true end
			out.candidates[#out.candidates + 1] = sel.classify(d, f, ctx)
		end
	end

	out.truncated = truncC or truncE
	out.seconds = os.clock() - t0
	return out
end

return gather
