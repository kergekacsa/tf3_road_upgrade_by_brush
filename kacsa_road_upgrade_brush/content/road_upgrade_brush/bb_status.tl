-- Based on 'Bulk Bulldozer' by square17 (mod.io 6434884). Private build, not for publication.
-- Toolbar status: the selection is shown in the construction options bar as a status chip instead of the cursor
-- tooltip. PURE: no api.* calls (money is formatted by the caller).

local status : BulkBulldozerStatus = {}

-- The bar is 314 UI px wide with 8 px padding and the button adds 8 px padding per side, so ~280 px for text: about
-- 36 body-font characters. Longer lines are clipped here (with "...") rather than cut by the engine.
-- Width is counted per character, CJK / Hangul / full-width glyphs as 2 (status.width), so
-- translated lines clip at the same pixel width as English ones.
status.MAX_CHARS = 36
status.MAX_KIND_PARTS = 3

-- Display order. Translated at use time (GUI script: _() translates when called).
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

-- Display width of the UTF-8 character that starts with byte b (and its byte length):
-- ASCII, Latin, Cyrillic and general punctuation (U+0000-U+2FFF) count 1, everything from
-- U+3000 (CJK, kana, Hangul, full-width forms) counts 2.
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
	-- Keep whole characters up to n - 3 columns, then "...". Never cut inside a UTF-8 sequence.
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

-- Skip reasons and refusals: the commit stores them as English text (also used in the log), or
-- as the game's own (already translated) error message. Known ones are translated for display.
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
		["not enough money"] = _("not enough money"),
		["nothing left to remove"] = _("nothing left to remove"),
		["script error"] = _("script error"),
		["command limit reached"] = _("command limit reached"),
		["refused by the game"] = _("refused by the game"),
		["Pause the game first"] = _("Pause the game first"),
	}
end

function status.reasonLabel(reason : string) : string
	if reason == nil then return "" end
	return reasonLabels()[reason] or reason
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

local function text(head : string, detail : string, severity? : string, hint? : string) : BulkBulldozerStatusText
	return {
		head = status.clip(head, status.MAX_CHARS), detail = status.clip(detail, status.MAX_CHARS), severity = severity,
		hint = hint ~= nil and status.clip(hint, status.MAX_CHARS) or nil,
	}
end

local function hintPaint() : string
	return _("Paint with the left mouse button")
end

function status.idle() : BulkBulldozerStatusText
	return text(_("Nothing selected"), hintPaint())
end

-- Width of the text progress bar in the chip while roads are upgraded.
local PROGRESS_BAR_WIDTH <const> = 10

-- The third line while roads are upgraded: Esc may close the tool, the Cancel button stops the upgrade and keeps it open.
local function stopHint() : string
	return _("Cancel button stops the progress")
end

function status.lines(v : BulkBulldozerStatusInput) : BulkBulldozerStatusText
	local n = v.count or 0
	local kinds = status.kindSummary(v.kindCounts, v.objects)
	if v.phase == "committing" then
		local total = v.progressTotal or 0
		if total > 0 then
			local done = math.min(v.progressDone or 0, total)
			local percent = math.floor(done * 100 / total)
			local filled = math.floor(done * PROGRESS_BAR_WIDTH / total)
			local bar = "[" .. string.rep("#", filled) .. string.rep(".", PROGRESS_BAR_WIDTH - filled) .. "]"
			if (v.retryAttempt or 0) > 0 then
				local t = text(string.format(_("Retrying failed ones %d/%d"), v.retryAttempt, v.retryPasses or 0), string.format("%s %d of %d", bar, done, total), nil, stopHint())
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
		local head = string.format(v.capped and _("%d selected (max)") or _("%d selected"), n)
		if v.cost ~= nil then head = head .. " · " .. v.cost end
		return text(head, kinds)
	end
	if v.result ~= nil then
		return text(v.result.head, v.result.detail, v.result.severity)
	end
	if v.phase == "idle" and n > 0 then
		return text(_("Nothing selected"), string.format(_("Brush: %s"), kinds))
	end
	return status.idle()
end

-- The end of a run: "X updated, Y failed". Green when something was updated, red when nothing was and some roads
-- failed; with both, the head is green and "Y failed" is yellow, as its own part (tail). The cost is added by the tool.
function status.resultLines(r : BulkBulldozerCommitResult) : BulkBulldozerStatusText
	if r.removed == 0 and r.refused ~= nil then
		return text(_("Nothing upgraded"), status.reasonLabel(r.refused), "error")
	end
	local unchanged = r.unchanged or 0
	local failed = #(r.failed or {})
	if r.cancelled then
		local left = math.max(0, r.requested - r.removed - unchanged)
		return text(string.format(_("Cancelled · %d updated"), r.removed), string.format(_("%d roads not done"), left), "warning")
	end
	if r.removed == 0 and failed == 0 and r.skipped <= 0 and unchanged > 0 then
		return text(_("Nothing to upgrade"), _("The roads are already like this"))
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
	local result = text(head, table.concat(parts, " · "), severity)
	if r.removed > 0 and failed > 0 then
		result.head = string.format(_("%d updated,"), r.removed)
		result.tail = string.format(_(" %d failed"), failed)
		result.tailSeverity = "warning"
	end
	return result
end
function status.oneLine(t : BulkBulldozerStatusText) : string
	if t == nil then return "" end
	return t.head .. " / " .. t.detail
end

return status
