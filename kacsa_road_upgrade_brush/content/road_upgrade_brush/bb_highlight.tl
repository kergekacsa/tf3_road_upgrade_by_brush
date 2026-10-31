-- Based on 'Bulk Bulldozer' by square17 (mod.io 6434884).
-- Pure: no api.* calls.
--
-- MODE picks how the selection is shown:
--   "engine": ActionDescriptor.highlightedEntities. The Selector's selectionColor and selectionOutlineColor(1) must be
--             set together and must not be transparent.
--   "lines":  red lines along every selected edge and a red circle on every selected construction's origin. They are
--             drawn in the single EdgeRenderable of the ring (the engine asserts on more than one per recipe).
--             Capped at MAX_SEGMENTS pieces.
--   "both":   "engine" and "lines".

local brush = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/bb_brush.tl" as RubBrush

local hl : RubHighlight = {}

hl.MODE = "both"
-- true: the Selector filter accepts only highlighted entities. false: it accepts every existing entity.
hl.HOVER_ONLY_HIGHLIGHTED = true
-- Limit of straight pieces for all overlay lines and construction markers together.
hl.MAX_SEGMENTS = 1600
-- SEGMENT_LENGTH is in metres. MAX_PER_EDGE is pieces per edge.
hl.SEGMENT_LENGTH = 15
hl.MAX_PER_EDGE = 8
-- Both in metres: overlay line lift above the edge, construction marker radius.
hl.LINE_OFFSET_Z = 1.5
hl.MARKER_RADIUS = 8

-- RED is the base palette's Error colour (#CE2029). CORAL is its Negative colour (#F08080).
local RED : {number} = { 206 / 255, 32 / 255, 41 / 255 }
local CORAL : {number} = { 240 / 255, 128 / 255, 128 / 255 }
-- BLUE marks a road that already is the target; SKY is its hover shade.
local BLUE : {number} = { 30 / 255, 110 / 255, 230 / 255 }
local SKY : {number} = { 120 / 255, 170 / 255, 240 / 255 }

local function rgba(c : {number}, a : number) : {number}
	return { c[1], c[2], c[3], a }
end

function hl.usesEngine(mode : string) : boolean
	return mode == "engine" or mode == "both"
end

function hl.usesLines(mode : string) : boolean
	return mode == "lines" or mode == "both"
end

-- "idle" is the hover preview (CORAL). Any other phase is the selection (RED).
function hl.colors(phase : string) : RubHighlightColors
	if phase == "idle" then
		return {
			fill = rgba(CORAL, 0.25),
			outline = rgba(CORAL, 0.6),
			outline1 = rgba(CORAL, 0.85),
			line = rgba(CORAL, 0.6),
			lineWidth = 1.5,
		}
	end
	return {
		fill = rgba(RED, 0.45),
		outline = rgba(RED, 0.75),
		outline1 = rgba(RED, 1.0),
		line = rgba(RED, 0.9),
		lineWidth = 2.5,
	}
end

-- Same phases as colors: "idle" is the hover preview (SKY), any other phase is the selection (BLUE).
function hl.sameColors(phase : string) : RubHighlightColors
	if phase == "idle" then
		return {
			fill = rgba(SKY, 0.25),
			outline = rgba(SKY, 0.6),
			outline1 = rgba(SKY, 0.85),
			line = rgba(SKY, 0.6),
			lineWidth = 1.5,
		}
	end
	return {
		fill = rgba(BLUE, 0.45),
		outline = rgba(BLUE, 0.75),
		outline1 = rgba(BLUE, 1.0),
		line = rgba(BLUE, 0.9),
		lineWidth = 2.5,
	}
end

-- Upper bound of the curve length: the Bezier control polygon p0, p0 + t0/3, p1 - t1/3, p1.
function hl.curveLength(c : RubCurve) : number
	local ax, ay = c.p0x + c.t0x / 3, c.p0y + c.t0y / 3
	local bx, by = c.p1x - c.t1x / 3, c.p1y - c.t1y / 3
	local function d(x0 : number, y0 : number, x1 : number, y1 : number) : number
		return math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0))
	end
	return d(c.p0x, c.p0y, ax, ay) + d(ax, ay, bx, by) + d(bx, by, c.p1x, c.p1y)
end

function hl.piecesFor(length : number) : integer
	if length == nil or length <= 0 then return 1 end
	local n = math.ceil(length / hl.SEGMENT_LENGTH)
	if n < 1 then n = 1 end
	if n > hl.MAX_PER_EDGE then n = hl.MAX_PER_EDGE end
	return math.floor(n)
end

-- Height on the curve (Hermite in z, like x/y), or nil when the curve carries no heights.
function hl.curveZ(c : RubCurve, t : number) : number
	if c.p0z == nil or c.p1z == nil then return nil end
	local t2 = t * t
	local t3 = t2 * t
	return (2 * t3 - 3 * t2 + 1) * c.p0z + (t3 - 2 * t2 + t) * (c.t0z or 0)
		+ (-2 * t3 + 3 * t2) * c.p1z + (t3 - t2) * (c.t1z or 0)
end

-- Pieces per curve within maxSegments. Over budget, every curve gets fewer pieces (at least one), then trailing
-- curves are dropped. Returns the counts, how many curves fit, truncated.
function hl.piecePlan(curves : {RubCurve}, maxSegments : integer) : {integer}, integer, boolean
	if curves == nil or maxSegments == nil or maxSegments < 1 then return {}, 0, curves ~= nil and #curves > 0 end
	local pieces : {integer} = {}
	local total = 0
	for i, c in ipairs(curves) do
		pieces[i] = hl.piecesFor(hl.curveLength(c))
		total = total + pieces[i]
	end
	if total > maxSegments then
		local f = maxSegments / total
		for i = 1, #pieces do
			pieces[i] = math.max(1, math.floor(pieces[i] * f))
		end
	end
	local used = 0
	for i = 1, #pieces do
		if used + pieces[i] > maxSegments then return pieces, i - 1, true end
		used = used + pieces[i]
	end
	return pieces, #pieces, false
end

-- One curve cut into n straight pieces. Heights from the curve's z, else heightAt(x, y), else 0.
function hl.curveSegments(c : RubCurve, n : integer,
		heightAt? : function(number, number) : number) : {RubSegment}
	local out : {RubSegment} = {}
	local function z(t : number, x : number, y : number) : number
		local v = hl.curveZ(c, t)
		if v ~= nil then return v end
		if heightAt ~= nil then return heightAt(x, y) end
		return 0
	end
	local lx, ly = c.p0x, c.p0y
	local lz = z(0, lx, ly)
	for k = 1, n do
		local t = k / n
		local x, y = brush.hermite(c, t)
		local zz = z(t, x, y)
		out[#out + 1] = { x0 = lx, y0 = ly, z0 = lz, x1 = x, y1 = y, z1 = zz }
		lx, ly, lz = x, y, zz
	end
	return out
end

function hl.edgeSegments(curves : {RubCurve}, maxSegments : integer,
		heightAt? : function(number, number) : number) : {RubSegment}, boolean
	local out : {RubSegment} = {}
	local pieces, fit, truncated = hl.piecePlan(curves, maxSegments)
	for i = 1, fit do
		for _, sg in ipairs(hl.curveSegments(curves[i], pieces[i], heightAt)) do out[#out + 1] = sg end
	end
	return out, truncated
end

function hl.describeMode(mode : string) : string
	if mode == "engine" then
		return "engine (highlightedEntities tinted through the Selector selection colours)"
	elseif mode == "lines" then
		return "lines (red lines on selected edges, red circles on selected constructions; Selector colours transparent)"
	elseif mode == "both" then
		return "both (engine tint through the Selector selection colours + red lines on edges / circles on constructions)"
	end
	return "unknown mode " .. tostring(mode)
end

return hl
