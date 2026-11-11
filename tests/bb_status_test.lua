-- Tests of bb_status.tl: the lines of the status chip for a waiting selection and for the result of a press. The module
-- is pure. The translation function returns its text.

local support = dofile((arg[0]:match("^(.*)[/\\][^/\\]*$") or ".") .. "/support.lua")
local check = support.check

_G._ = function(text) return text end
support.installRequire({})
local status = dofile(support.buildDir .. "/bb_status.lua")

local function result(fields)
  local r = { requested = 0, removed = 0, unchanged = 0, failed = {}, skipped = 0, reasons = {}, commands = 0, rail = false, lotFailures = 0, buildingsKept = false, notes = {} }
  for key, value in pairs(fields) do r[key] = value end
  return r
end
local function describe(t) return string.format("%s / %s / %s / %s", tostring(t.head), tostring(t.detail), tostring(t.hint), tostring(t.severity)) end

-- A waiting selection
do
  local waiting = status.lines({ phase = "selected", count = 4, kindCounts = { road = 4 }, objects = 0, allKeep = true })
  check("selection with every choice on Keep: the chip says that nothing will change",
    waiting.head == "4 selected" and waiting.hint == "All on Keep: nothing will change", describe(waiting))
  local changing = status.lines({ phase = "selected", count = 4, kindCounts = { road = 4 }, objects = 0, allKeep = false })
  check("selection with a choice set: no hint", changing.head == "4 selected" and changing.hint == nil, describe(changing))
  check("the Keep hint fits the chip", status.width("All on Keep: nothing will change") <= status.MAX_CHARS)
end

-- The result of a press
do
  local updated = status.resultLines(result({ requested = 5, removed = 3, unchanged = 1, skipped = 1, reasons = { ["lanes cannot be kept"] = 1 } }))
  check("result: the counts of updated, unchanged and skipped roads, and the reason of a skipped road in the third line when no road failed",
    updated.head == "3 updated, 0 failed" and updated.detail == "1 unchanged · 1 skipped" and updated.hint == "lanes cannot be kept" and updated.severity == "ok",
    describe(updated))
  local busTram = status.resultLines(result({ requested = 1, skipped = 1, reasons = { ["no bus lane plus tram track here"] = 1 } }))
  check("result: the bus lane and tram reason shows its short text", busTram.hint == "no bus lane plus tram track here" and busTram.severity == "warning", describe(busTram))
  local noted = status.resultLines(result({ requested = 6, removed = 6, notes = { lostTrees = 2, lostBarrier = 0 } }))
  check("result: the roads that lost their trees are named in the third line", noted.hint == "2 lost their alley trees", describe(noted))
  local several = status.resultLines(result({ requested = 9, removed = 9, notes = { unlisted = 1, country = 3 } }))
  check("result: of several notes the most frequent shows", several.hint == "3 country roads: no alley trees", describe(several))
  local unchanged = status.resultLines(result({ requested = 2, unchanged = 2, notes = { unlisted = 2 } }))
  check("result: nothing to upgrade still names the part that was left out", unchanged.head == "Nothing to upgrade"
    and unchanged.hint == "2 other types: no trees/barrier", describe(unchanged))
  local reasonAndNote = status.resultLines(result({ requested = 3, removed = 2, skipped = 1, reasons = { gone = 1 }, notes = { lostTrees = 1 } }))
  check("result: a skip reason takes the third line before a note", reasonAndNote.hint == "gone", describe(reasonAndNote))
  local failedRoad = status.resultLines(result({ requested = 2, removed = 1, failed = { 7 }, skipped = 1, reasons = { Collision = 1 } }))
  check("result: the reason of a failed road stays in the second line", failedRoad.detail == "Collision" and failedRoad.hint == nil, describe(failedRoad))
  local plain = status.resultLines(result({ requested = 2, removed = 2 }))
  check("result: no notes, no third line", plain.hint == nil and plain.head == "2 updated, 0 failed", describe(plain))
  local lots = status.resultLines(result({ requested = 2, removed = 1, failed = { 7 }, skipped = 1, reasons = { ["Unexpected parcel"] = 1 }, lotFailures = 1,
    buildingsKept = true, notes = { lostTrees = 1 } }))
  check("result: the hint to remove buildings takes the third line before the notes", lots.hint == "Turn on removing buildings", describe(lots))
  for _, note in ipairs({ "%d lost their alley trees", "%d lost their noise barrier", "%d country roads: no alley trees", "%d other types: no trees/barrier" }) do
    check("note text fits the chip with a count of three digits: " .. note, status.width(string.format(note, 200)) <= status.MAX_CHARS)
  end
  check("reason texts fit the chip", status.width("lanes cannot be kept") <= status.MAX_CHARS)
end

support.finish("bb_status")
