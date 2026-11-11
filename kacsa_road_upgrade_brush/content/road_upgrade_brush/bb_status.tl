-- Based on 'Bulk Bulldozer' by square17 (mod.io 6434884).
-- Pure: no api.* calls (money is formatted by the caller).

local status : RubStatus = {}

-- About 280 px of text fit the bar: 36 body-font columns. status.width counts CJK, Hangul and full-width glyphs as 2.
status.MAX_CHARS = 36
status.MAX_KIND_PARTS = 3

-- _() translates when called (GUI script).
local KIND_ORDER : {string} = { "road", "track", "station", "asset", "town_building" }
local function kindFormats() : {string : {string}}
	return {
		road = { _("%d road"), _("%d roads") },
		track = { _("%d track"), _("%d tracks") },
		station = { _("%d station"), _("%d stations") },
		asset = { _("%d asset"), _("%d assets") },
		town_building = { _("%d building"), _("%d buildings") },
	}
end

local function counted(n : integer, formats : {string}) : string
	return string.format(n == 1 and formats[1] or formats[2], n)
end

-- Display width and byte length of the UTF-8 character that starts with byte b.
-- U+0000-U+2FFF (ASCII, Latin, Cyrillic, general punctuation) count 1. From U+3000 (CJK, kana, Hangul, full-width
-- forms) count 2.
local function charInfo(b : integer) : integer, integer
	if b < 0x80 then return 1, 1 end
	if b < 0xE0 then return 2, 1 end
	if b < 0xE3 then return 3, 1 end
	if b < 0xF0 then return 3, 2 end
	return 4, 2
end

function status.width(s : string) : integer
	if s == nil then return 0 end
	local w, i = 0, 1
	while i <= #s do
		local len, cw = charInfo(string.byte(s, i))
		w = w + cw
		i = i + len
	end
	return w
end

function status.clip(s : string, n : integer) : string
	if s == nil then return "" end
	if status.width(s) <= n then return s end
	local budget = n - 3
	local w, i = 0, 1
	while i <= #s do
		local len, cw = charInfo(string.byte(s, i))
		if w + cw > budget then break end
		w = w + cw
		i = i + len
	end
	return string.sub(s, 1, i - 1) .. "..."
end

-- The commit stores reasons as English text or as the game's already translated error message. Known ones are
-- translated here.
local function reasonLabels() : {string : string}
	return {
		["gone"] = _("gone"),
		["other player"] = _("other player"),
		["part of a construction"] = _("part of a construction"),
		["industry"] = _("industry"),
		["HQ"] = _("HQ"),
		["not yours"] = _("not yours"),
		["filtered"] = _("filtered"),
		["underground"] = _("underground"),
		["on the ground"] = _("on the ground"),
		["tram track"] = _("tram track"),
		["other track type"] = _("other track type"),
		["not enough money"] = _("not enough money"),
		["nothing left to upgrade"] = _("nothing left to upgrade"),
		["bus lane or lock could not be set"] = _("bus lane or lock could not be set"),
		["no valid road type"] = _("no valid road type"),
		["lanes cannot be kept"] = _("lanes cannot be kept"),
		["no bus lane plus tram track here"] = _("no bus lane plus tram track here"),
		["script error"] = _("script error"),
		["command limit reached"] = _("command limit reached"),
		["previous upgrade still running"] = _("previous upgrade still running"),
		["refused by the game"] = _("refused by the game"),
		["Pause the game first"] = _("Pause the game first"),
	}
end

function status.reasonLabel(reason : string) : string
	if reason == nil then return "" end
	return reasonLabels()[reason] or reason
end

-- The notes of the plans (the NOTE_ values of brush_roads), as a text with the number of roads.
local function noteFormats() : {string : string}
	return {
		lostTrees = _("%d lost their alley trees"),
		lostBarrier = _("%d lost their noise barrier"),
		country = _("%d country roads: no alley trees"),
		unlisted = _("%d other types: no trees/barrier"),
	}
end

-- The most frequent note of a result as a text. "" when there is none.
local function topNote(notes : {string : integer}) : string
	local formats = noteFormats()
	local top : string = nil
	for k, n in pairs(notes or {}) do
		if n > 0 and formats[k] ~= nil and (top == nil or n > notes[top] or (n == notes[top] and k < top)) then top = k end
	end
	if top == nil then return "" end
	return string.format(formats[top], notes[top])
end

function status.kindSummary(kindCounts : {string : integer}, objects : integer) : string
	local parts : {string} = {}
	local formats = kindFormats()
	for _i, k in ipairs(KIND_ORDER) do
		local n = kindCounts ~= nil and kindCounts[k] or nil
		if n ~= nil and n > 0 then parts[#parts + 1] = counted(n, formats[k]) end
	end
	if objects ~= nil and objects > 0 then
		parts[#parts + 1] = counted(objects, { _("%d signal/stop"), _("%d signals/stops") })
	end
	if #parts > status.MAX_KIND_PARTS then
		local shown : {string} = {}
		for i = 1, status.MAX_KIND_PARTS do shown[i] = parts[i] end
		return table.concat(shown, " · ") .. " ..."
	end
	return table.concat(parts, " · ")
end

local function text(head : string, detail : string, severity? : string, hint? : string) : RubStatusText
	return {
		head = status.clip(head, status.MAX_CHARS), detail = status.clip(detail, status.MAX_CHARS), severity = severity,
		hint = hint ~= nil and status.clip(hint, status.MAX_CHARS) or nil,
	}
end

local function hintPaint() : string
	return _("Paint with the left mouse button")
end

function status.idle() : RubStatusText
	return text(_("Nothing selected"), hintPaint())
end

-- In characters.
local PROGRESS_BAR_WIDTH <const> = 10

local function stopHint() : string
	return _("Cancel button stops the progress")
end

function status.lines(v : RubStatusInput) : RubStatusText
	local n = v.count or 0
	local kinds = status.kindSummary(v.kindCounts, v.objects)
	if v.phase == "committing" then
		local total = v.progressTotal or 0
		if total > 0 then
			local done = math.min(v.progressDone or 0, total)
			local percent = math.floor(done * 100 / total)
			local filled = math.floor(done * PROGRESS_BAR_WIDTH / total)
			local bar = "[" .. string.rep("#", filled) .. string.rep(".", PROGRESS_BAR_WIDTH - filled) .. "]"
			if (v.retryAttempt or 0) < 0 then
				local t = text(_("Placing crosswalks"), string.format(_("%s %d of %d"), bar, done, total), nil, stopHint())
				t.running = true
				return t
			end
			if (v.retryAttempt or 0) > 0 then
				local t = text(string.format(_("Retrying failed ones %d/%d"), v.retryAttempt, v.retryPasses or 0), string.format(_("%s %d of %d"), bar, done, total), nil, stopHint())
				t.running = true
				return t
			end
			local t = text(string.format(_("Upgrading %d of %d"), done, total), string.format("%s %d%%", bar, percent), nil, stopHint())
			t.running = true
			return t
		end
		local t = text(string.format(_("Upgrading %d..."), n), kinds, nil, stopHint())
		t.running = true
		return t
	end
	if n > 0 and (v.phase == "painting" or v.phase == "selected") then
		local atCap = v.capped or (v.cap ~= nil and n >= v.cap)
		local head = string.format(atCap and _("%d selected (max)") or _("%d selected"), n)
		if v.cost ~= nil then head = head .. " · " .. v.cost end
		return text(head, kinds, atCap and "warning" or nil, v.allKeep and _("All on Keep: nothing will change") or nil)
	end
	if v.result ~= nil then
		return text(v.result.head, v.result.detail, v.result.severity)
	end
	if v.phase == "idle" and n > 0 then
		return text(_("Nothing selected"), string.format(_("Brush: %s"), kinds))
	end
	return status.idle()
end

-- The tool adds the cost.
function status.resultLines(r : RubCommitResult) : RubStatusText
	if r.removed == 0 and r.refused ~= nil then
		return text(_("Nothing upgraded"), status.reasonLabel(r.refused), "error")
	end
	local unchanged = r.unchanged or 0
	local failed = #(r.failed or {})
	if r.cancelled then
		local left = math.max(0, r.requested - r.removed - unchanged)
		return text(string.format(_("Cancelled · %d updated"), r.removed), string.format(r.rail and _("%d tracks not done") or _("%d roads not done"), left), "warning")
	end
	local notes = topNote(r.notes)
	if r.removed == 0 and failed == 0 and r.skipped <= 0 and unchanged > 0 then
		return text(_("Nothing to upgrade"), r.rail and _("The tracks are already like this") or _("The roads are already like this"), nil,
			notes ~= "" and notes or nil)
	end
	local head = string.format(_("%d updated, %d failed"), r.removed, failed)
	local parts : {string} = {}
	if unchanged > 0 then parts[#parts + 1] = string.format(_("%d unchanged"), unchanged) end
	local other = r.skipped - failed
	if other > 0 then parts[#parts + 1] = string.format(_("%d skipped"), other) end
	local keys : {string} = {}
	for k in pairs(r.reasons or {}) do keys[#keys + 1] = k end
	table.sort(keys, function(a : string, b : string) : boolean
		if r.reasons[a] ~= r.reasons[b] then return r.reasons[a] > r.reasons[b] end
		return a < b
	end)
	if failed > 0 then
		local top : {string} = {}
		for i = 1, math.min(2, #keys) do top[#top + 1] = status.reasonLabel(keys[i]) end
		if #top > 0 then parts[#parts + 1] = table.concat(top, ", ") end
	end
	local severity : string = nil
	if r.removed > 0 then severity = "ok" elseif failed > 0 then severity = "error" elseif other > 0 then severity = "warning" end
	-- The third line: why roads were skipped when no road failed (the reasons of failed roads are in the detail), else the
	-- most frequent note.
	local third : string = nil
	if failed == 0 and other > 0 and #keys > 0 then
		third = status.reasonLabel(keys[1])
	elseif notes ~= "" then
		third = notes
	end
	local result = text(head, table.concat(parts, " · "), severity, third)
	if r.removed > 0 and failed > 0 then
		result.head = string.format(_("%d updated,"), r.removed)
		result.tail = string.format(_(" %d failed"), failed)
		result.tailSeverity = "warning"
	end
	if failed > 0 and (r.lotFailures or 0) > 0 and r.buildingsKept and not r.rail then
		result.hint = status.clip(_("Turn on removing buildings"), status.MAX_CHARS)
	end
	return result
end
function status.oneLine(t : RubStatusText) : string
	if t == nil then return "" end
	return t.head .. " / " .. t.detail
end

return status
