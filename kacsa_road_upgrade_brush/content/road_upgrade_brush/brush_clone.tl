-- Reads the settings of the street under the cursor, for the middle click. Read-only: issues no commands.

local brush = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/bb_brush.tl" as RubBrush
local commit = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/bb_upgrade.tl" as RubCommit
local config = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_config.tl" as RubConfig
local templates = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_templates.tl" as RubTemplates
local rails = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/brush_rails.tl" as RubRails

local clone : RubBrushClone = {}

-- Metres around the cursor in which the octree is asked for streets. A street is hit only inside its own width.
local QUERY_RADIUS <const> = 40
-- A street counts as at least this wide on each side of its centre line (metres), also when its lanes give no width.
local MIN_HALF_WIDTH <const> = 3

local function readEdge(e : integer) : Engine.Component.BaseEdge
	local ok, c = pcall(function() : Engine.Component.BaseEdge
		return api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	end)
	if ok then return c end
	return nil
end

local function isStreet(e : integer) : boolean
	local ok, c = pcall(function() : any
		local v : any = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE_STREET)
		return v
	end)
	return ok and c ~= nil
end

-- Distance in metres from (x, y) to the curve of the edge, in plan view.
local function distanceTo(be : Engine.Component.BaseEdge, x : number, y : number) : number
	local curve : RubCurve = {
		p0x = be.position0.x, p0y = be.position0.y, t0x = be.tangent0.x, t0y = be.tangent0.y,
		p1x = be.position1.x, p1y = be.position1.y, t1x = be.tangent1.x, t1y = be.tangent1.y,
	}
	local best = math.huge
	local lx, ly = curve.p0x, curve.p0y
	for i = 1, brush.EDGE_SAMPLES - 1 do
		local px, py = brush.hermite(curve, i / (brush.EDGE_SAMPLES - 1))
		best = math.min(best, brush.pointSegmentDistance(x, y, lx, ly, px, py))
		lx, ly = px, py
	end
	return best
end

-- Half the width of the street, from the centre line. The lanes lie side by side (sidewalks included), so the width is
-- the sum of the lane widths; the lane offsets are small shifts, not distances.
local function halfWidth(be : Engine.Component.BaseEdge) : number
	local total : number = 0
	for _, lane in ipairs(be.laneConfigs or {}) do
		local width : number = lane.width or 0
		total = total + width
	end
	return math.max(MIN_HALF_WIDTH, total / 2)
end

-- The lanes of the edge as "width@offset" pairs, for the log.
local function lanesText(be : Engine.Component.BaseEdge) : string
	local parts : {string} = {}
	for _, lane in ipairs(be.laneConfigs or {}) do
		parts[#parts + 1] = string.format("%s@%s", tostring(lane.width), tostring(lane.offset))
	end
	return table.concat(parts, " ")
end

function clone.pick(x : number, y : number, underground : boolean, tracks? : boolean) : integer, string
	local ok, found = pcall(api.engine.util.octree.findEntitiesInCircle, api.type.Vec2f.new(x, y),
		QUERY_RADIUS + brush.EDGE_MARGIN, api.type.ComponentType.BASE_EDGE)
	if not ok or found == nil then return nil, "octree query failed: " .. tostring(found) end
	local best : integer = nil
	local bestDistance : number = math.huge
	local streets = 0
	local nearest : integer = nil
	local nearestDistance : number = math.huge
	local nearestHalf : number = 0
	local nearestLanes = ""
	for _, e in ipairs(found as {integer}) do
		local be = readEdge(e)
		local isTunnel = be ~= nil and be.type == api.type.enum.BaseEdgeType.TUNNEL
		if be ~= nil and be.position0 ~= nil and be.position1 ~= nil and be.tangent0 ~= nil and be.tangent1 ~= nil
				and isTunnel == underground and isStreet(e) ~= (tracks == true) then
			streets = streets + 1
			local d = distanceTo(be, x, y)
			local half = halfWidth(be)
			if d < nearestDistance then
				nearest = e
				nearestDistance = d
				nearestHalf = half
				nearestLanes = lanesText(be)
			end
			if d <= half and d <= bestDistance then
				best = e
				bestDistance = d
			end
		end
	end
	local note = string.format("%d edges in range, %d streets (%s), nearest %s at %.1f m with half width %.1f m (lanes width@offset: %s)",
		#(found as {integer}), streets, underground and "tunnels" or "surface", tostring(nearest), nearestDistance, nearestHalf, nearestLanes)
	return best, note
end

local function stripSuffix(name : string, suffix : string) : string, boolean
	if #name > #suffix and string.sub(name, -#suffix) == suffix then
		return string.sub(name, 1, #name - #suffix), true
	end
	return name, false
end

function clone.read(edge : integer) : RubClone
	local be = readEdge(edge)
	if be == nil or be.roadTemplate == nil then return nil end
	local name, trees = stripSuffix(templates.baseName(be.roadTemplate), config.TreesSuffix)
	local barrier = false
	if not trees then name, barrier = stripSuffix(name, config.BarriersSuffix) end
	for i, roadType in ipairs(config.roadTypes) do
		for _, base in ipairs(roadType.bases) do
			if base == name then
				local extras = commit.extrasOf(edge, be.roadTemplate)
				return {
					roadType = i,
					trees = trees,
					barrier = barrier,
					busLane = extras ~= nil and extras.busLane,
					tram = extras ~= nil and extras.tram,
					catenary = extras ~= nil and extras.catenary,
					lock = be.roadDevelopmentLocked and "lock" or "keep",
					editedLanes = extras == nil,
				}
			end
		end
	end
	return nil
end

function clone.readTrack(edge : integer) : RubTrackClone
	local be = readEdge(edge)
	if be == nil then return nil end
	local trackType, catenary = rails.parse(be.roadTemplate)
	if trackType == nil then return nil end
	local barrier : boolean = nil
	if be.type ~= api.type.enum.BaseEdgeType.TUNNEL and not rails.isQuiet(be.roadTemplate) then
		barrier = rails.hasBarrier(be.edgeDecorations)
	end
	return { trackType = trackType, catenary = catenary, barrier = barrier }
end

return clone
