-- Based on 'Bulk Bulldozer' by square17 (mod.io 6434884). Private build, not for publication.
-- Brush geometry: the ring, the sample points, and the edge-touches-circle test (Hermite sampling), point-in-circle,
-- and the query margin. PURE: no api.* calls; the terrain lookup is passed in.

local brush : BulkBulldozerBrush = {}

-- Twelve radius steps (metres), default 20, at most 200 to bound the query cost.
brush.RADII = { 5, 10, 15, 20, 25, 30, 40, 50, 75, 100, 150, 200 }
brush.DEFAULT_RADIUS = 20
-- One EdgeRenderable edge per arc; an arc has one height pair (start/end), so 48 arcs let the ring follow hills.
brush.RING_ARCS = 48
-- The brush samples when the cursor moved at least radius/4 or 100 ms passed.
brush.SAMPLE_MIN_INTERVAL = 0.1
brush.SAMPLE_MOVE_FRACTION = 0.25
-- An edge is hit when its curve, sampled at 9 points, comes within the radius of a brush sample (polyline distance,
-- so a straight edge passing through is exact).
brush.EDGE_SAMPLES = 9
-- The octree may test an edge's position instead of its geometry, so an edge is only returned when that point is in
-- the query circle. Querying r + EDGE_MARGIN finds every edge up to 2 * EDGE_MARGIN long either way; the exact touch
-- test then drops the extra hits.
brush.EDGE_MARGIN = 100
-- Cost bound per octree query (a 300 m query over a dense city stays well under this).
brush.SAMPLE_MAX_ENTITIES = 4000

function brush.radiusLabels() : {string}
	local out : {string} = {}
	for i, r in ipairs(brush.RADII) do
		out[i] = string.format("%d m", math.floor(r))
	end
	return out
end

function brush.radiusIndex(r : number) : integer
	if r == nil then return nil end
	for i, v in ipairs(brush.RADII) do
		if v == r then return i end
	end
	return nil
end

function brush.radiusFromParam(v : number) : number
	if v == nil then return nil end
	local i = brush.radiusIndex(v)
	return i and brush.RADII[i] or nil
end

function brush.ringArcs(cx : number, cy : number, r : number, n : integer,
		heightAt : function(number, number) : number) : {BulkBulldozerRingArc}
	local out : {BulkBulldozerRingArc} = {}
	if r == nil or r <= 0 or n == nil or n < 1 then return out end
	local step = 2 * math.pi / n
	-- n + 1 shared end points; the last one closes the ring at angle 2π (= the first point).
	local heights : {number} = {}
	for i = 0, n - 1 do
		local a = i * step
		heights[i + 1] = heightAt(cx + r * math.cos(a), cy + r * math.sin(a))
	end
	heights[n + 1] = heights[1]
	for i = 1, n do
		out[i] = {
			startAngle = (i - 1) * step,
			angle = step,
			length = r * step,
			h0 = heights[i],
			h1 = heights[i + 1],
		}
	end
	return out
end

function brush.ringWidth(r : number) : number
	return math.max(1.5, math.min(6.0, r / 25))
end

function brush.sampleDue(dx : number, dy : number, dt : number, r : number) : boolean
	if dt >= brush.SAMPLE_MIN_INTERVAL then return true end
	local d = r * brush.SAMPLE_MOVE_FRACTION
	return dx * dx + dy * dy >= d * d
end

function brush.edgeQueryRadius(r : number) : number
	return r + brush.EDGE_MARGIN
end

-- Cubic Hermite basis (the engine's edge curve: positions and tangents of both ends).
function brush.hermite(c : BulkBulldozerCurve, t : number) : number, number
	local t2 = t * t
	local t3 = t2 * t
	local h00 = 2 * t3 - 3 * t2 + 1
	local h10 = t3 - 2 * t2 + t
	local h01 = -2 * t3 + 3 * t2
	local h11 = t3 - t2
	return h00 * c.p0x + h10 * c.t0x + h01 * c.p1x + h11 * c.t1x,
		h00 * c.p0y + h10 * c.t0y + h01 * c.p1y + h11 * c.t1y
end

function brush.pointSegmentDistance(px : number, py : number, ax : number, ay : number,
		bx : number, by : number) : number
	local dx, dy = bx - ax, by - ay
	local len2 = dx * dx + dy * dy
	local t = 0.0
	if len2 > 0 then
		t = ((px - ax) * dx + (py - ay) * dy) / len2
		if t < 0 then t = 0 elseif t > 1 then t = 1 end
	end
	local qx, qy = ax + t * dx - px, ay + t * dy - py
	return math.sqrt(qx * qx + qy * qy)
end

function brush.curveTouchesCircle(c : BulkBulldozerCurve, cx : number, cy : number, r : number) : boolean
	if c == nil or r == nil or r < 0 then return false end
	-- Cheap reject: the curve lies inside the hull of its Bezier control points
	-- p0, p0 + t0/3, p1 - t1/3, p1, so a circle clear of their bounding box can't touch it.
	local ax, ay = c.p0x + c.t0x / 3, c.p0y + c.t0y / 3
	local bx, by = c.p1x - c.t1x / 3, c.p1y - c.t1y / 3
	local minX = math.min(c.p0x, ax, bx, c.p1x)
	local maxX = math.max(c.p0x, ax, bx, c.p1x)
	local minY = math.min(c.p0y, ay, by, c.p1y)
	local maxY = math.max(c.p0y, ay, by, c.p1y)
	if cx < minX - r or cx > maxX + r or cy < minY - r or cy > maxY + r then return false end
	local n = brush.EDGE_SAMPLES
	local lx, ly = c.p0x, c.p0y
	for i = 1, n - 1 do
		local x, y = brush.hermite(c, i / (n - 1))
		if brush.pointSegmentDistance(cx, cy, lx, ly, x, y) <= r then return true end
		lx, ly = x, y
	end
	return false
end

function brush.pointInCircle(px : number, py : number, cx : number, cy : number, r : number) : boolean
	local dx, dy = px - cx, py - cy
	return dx * dx + dy * dy <= r * r
end

return brush
