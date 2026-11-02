-- Based on 'Bulk Bulldozer' by square17 (mod.io 6434884).
-- Pure: no api.* calls. Takes the plain descriptors from bb_gather.
--
-- Hard rules always win over the toolbar filters.

local rails = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/brush_rails.tl" as RubRails

local sel : RubSelect = {}

-- Maximum selected entities per stroke. The highlight draws about 6 line pieces per road and MUST stay within
-- bb_highlight MAX_SEGMENTS.
sel.STROKE_CAP = 200
-- true: a construction is hit when its origin (transf translation) is in the circle. false: every construction the
-- octree returns for the circle is hit.
sel.CONSTRUCTION_ORIGIN_ONLY = true

sel.KINDS = { "road", "track", "station", "asset", "town_building", "industry", "other" }
sel.REASONS = { "filtered", "underground", "surface", "tram_only", "track_type", "industry", "hq", "part", "foreign", "not_player", "gone" }

-- Filter CheckBox order in the toolbar; RubFilters field names.
sel.FILTER_KEYS = { "roads", "tracks", "stations", "assets", "townBuildings", "underground" }

local KIND_LABEL : {string : string} = {
	road = "roads",
	track = "tracks",
	station = "stations/depots",
	asset = "assets",
	town_building = "town buildings",
	industry = "industry",
	other = "other",
}

local REASON_LABEL : {string : string} = {
	filtered = "filtered",
	underground = "underground",
	surface = "on the ground",
	tram_only = "tram track",
	track_type = "other track type",
	industry = "industry",
	hq = "HQ",
	part = "part of a construction",
	foreign = "other player",
	not_player = "not yours",
	gone = "gone",
}

function sel.defaultFilters() : RubFilters
	return {
		roads = true,
		tracks = false,
		stations = false,
		assets = false,
		townBuildings = false,
		underground = false,
		surface = true,
	}
end

function sel.checkboxOn(v : number, dflt : boolean) : boolean
	if v == 2 then return true end
	if v == 1 then return false end
	return dflt
end

-- Menu value 2 = ticked (true), 1 = unticked (false), any other value = nil (unknown).
function sel.paramValue(v : number) : boolean
	if v == 2 then return true end
	if v == 1 then return false end
	return nil
end

-- keys maps field to param key. Fields whose value is missing or not 1 or 2 are left out.
function sel.paramFilters(params : {string : number}, keys : {string : string}) : {string : boolean}
	local out : {string : boolean} = {}
	if params == nil then return out end
	for field, key in pairs(keys) do
		local v = sel.paramValue(params[key])
		if v ~= nil then out[field] = v end
	end
	return out
end

-- Per field: the value the toolbar last showed (`shown`). Else the default, when every toggle seen for that field in
-- any menu category (`toggles[category][field]`) agrees with it. Else OFF; those fields are listed in the 2nd result.
function sel.resolveFilters(shown : {string : boolean}, toggles : {string : {string : boolean}},
		defaults : RubFilters) : RubFilters, {string}
	local out = {} as {string : boolean}
	local unknown : {string} = {}
	local dflt = defaults as {string : boolean}
	for _, field in ipairs(sel.FILTER_KEYS) do
		local v : boolean = nil
		if shown ~= nil then v = shown[field] end
		if v == nil then
			local d = dflt[field] == true
			local agree = true
			for _, cat in pairs(toggles or {}) do
				local t = cat[field]
				if t ~= nil and t ~= d then agree = false end
			end
			if agree then
				v = d
			else
				v = false
				unknown[#unknown + 1] = field
			end
		end
		out[field] = v
	end
	return out as RubFilters, unknown
end

local function filterAllows(kind : RubKind, f : RubFilters) : boolean
	if kind == "road" then return f.roads == true
	elseif kind == "track" then return f.tracks == true
	elseif kind == "station" then return f.stations == true
	elseif kind == "asset" then return f.assets == true
	elseif kind == "town_building" then return f.townBuildings == true
	end
	return false
end

local function isOwned(owner : integer) : boolean
	return owner ~= nil and owner >= 0
end

-- A road or a track without PLAYER_OWNED is still a road or a track. An unowned one at an industry is skipped by the
-- industry rule.
local function edgeKind(d : RubDesc) : RubKind
	return d.isStreet and "road" or "track"
end

local function constructionKind(d : RubDesc) : RubKind
	if (d.industries or 0) > 0 then return "industry" end
	if not isOwned(d.owner) then
		if (d.townBuildings or 0) > 0 and (d.stations or 0) == 0 and (d.depots or 0) == 0
				and (d.frozen or 0) == 0 then
			return "town_building"
		end
		return "other"
	end
	if (d.stations or 0) > 0 or (d.depots or 0) > 0 then return "station" end
	return "asset"
end

function sel.classify(d : RubDesc, f : RubFilters, ctx : RubContext) : RubCandidate
	local kind : RubKind = d.isEdge and edgeKind(d) or constructionKind(d)
	local nObjects = d.isEdge and d.objects ~= nil and #d.objects or 0
	local function skip(reason : RubReason) : RubCandidate
		return { entity = d.entity, kind = kind, reason = reason, objects = nObjects }
	end
	local player = ctx ~= nil and ctx.player or -1
	-- Hard rules, most specific first.
	if d.gone then return skip("gone") end
	if isOwned(d.owner) and d.owner ~= player then return skip("foreign") end
	if d.parentConstruction ~= nil and d.parentConstruction >= 0 then return skip("part") end
	if kind == "industry" or (d.isEdge and d.industryRoad) then return skip("industry") end
	if not d.isEdge and ctx ~= nil and ctx.hq ~= nil and ctx.hq >= 0 and d.entity == ctx.hq then
		return skip("hq")
	end
	if kind == "other" then return skip("not_player") end
	if d.isEdge and d.isStreet and d.tramOnly then return skip("tram_only") end
	if d.isEdge and kind == "track" and rails.parse(d.template) == nil then return skip("track_type") end
	if not filterAllows(kind, f) then return skip("filtered") end
	if d.isEdge and d.isTunnel and not f.underground then return skip("underground") end
	-- surface == false (underground view on): only tunnels may be selected.
	if d.isEdge and not d.isTunnel and f.surface == false then return skip("surface") end
	return { entity = d.entity, kind = kind, reason = nil, objects = nObjects }
end

function sel.newStroke() : RubStroke
	return {
		keep = {},
		order = {},
		skipped = {},
		kindCounts = {},
		reasonCounts = {},
		objects = 0,
		capped = false,
	}
end

function sel.count(s : RubStroke) : integer
	return #s.order
end

function sel.add(s : RubStroke, c : RubCandidate) : boolean
	if c == nil or c.entity == nil or s.keep[c.entity] ~= nil then return false end
	if c.reason ~= nil then
		if s.skipped[c.entity] == nil then
			s.skipped[c.entity] = c.reason
			s.reasonCounts[c.reason] = (s.reasonCounts[c.reason] or 0) + 1
		end
		return false
	end
	if #s.order >= sel.STROKE_CAP then
		s.capped = true
		return false
	end
	-- A keep replaces an earlier skip of the same entity.
	local old = s.skipped[c.entity]
	if old ~= nil then
		s.skipped[c.entity] = nil
		s.reasonCounts[old] = s.reasonCounts[old] - 1
	end
	s.keep[c.entity] = c
	s.order[#s.order + 1] = c.entity
	s.kindCounts[c.kind] = (s.kindCounts[c.kind] or 0) + 1
	s.objects = s.objects + (c.objects or 0)
	return true
end

-- Removes every kept entity in `entities` (unknown ones are ignored) and returns how many were removed.
-- Skip records stay. capped resets once the selection is below the cap.
function sel.remove(s : RubStroke, entities : {integer}) : integer
	local gone : {integer : boolean} = {}
	local n = 0
	for _, e in ipairs(entities or {}) do
		local c = s.keep[e]
		if c ~= nil and not gone[e] then
			gone[e] = true
			n = n + 1
			s.keep[e] = nil
			s.kindCounts[c.kind] = s.kindCounts[c.kind] - 1
			s.objects = s.objects - (c.objects or 0)
		end
	end
	if n == 0 then return 0 end
	local order : {integer} = {}
	for _, e in ipairs(s.order) do
		if not gone[e] then order[#order + 1] = e end
	end
	s.order = order
	if #order < sel.STROKE_CAP then s.capped = false end
	return n
end

function sel.entities(s : RubStroke) : {integer}
	local out : {integer} = {}
	for i, e in ipairs(s.order) do out[i] = e end
	return out
end

function sel.describe(s : RubStroke) : {string}
	local lines : {string} = {}
	local kept : {string} = {}
	for _, k in ipairs(sel.KINDS) do
		local n = s.kindCounts[k]
		if n ~= nil and n > 0 then kept[#kept + 1] = string.format("%d %s", n, KIND_LABEL[k]) end
	end
	if #kept == 0 then
		lines[#lines + 1] = "Nothing selected"
	else
		local line = "Selected: " .. table.concat(kept, ", ")
		if s.objects > 0 then line = line .. string.format(" (+%d signals/stops)", s.objects) end
		lines[#lines + 1] = line
	end
	local skipped : {string} = {}
	for _, r in ipairs(sel.REASONS) do
		local n = s.reasonCounts[r]
		if n ~= nil and n > 0 then skipped[#skipped + 1] = string.format("%d %s", n, REASON_LABEL[r]) end
	end
	if #skipped > 0 then lines[#lines + 1] = "Skipped: " .. table.concat(skipped, ", ") end
	if s.capped then
		lines[#lines + 1] = string.format("Limit of %d reached", sel.STROKE_CAP)
	end
	return lines
end

function sel.limitLines(s : RubStroke) : {string}
	local lines : {string} = {}
	if s.capped then
		lines[#lines + 1] = string.format(_("Limit of %d reached"), sel.STROKE_CAP)
	end
	return lines
end

return sel
