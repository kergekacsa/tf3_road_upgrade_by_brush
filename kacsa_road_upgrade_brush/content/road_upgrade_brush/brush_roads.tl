-- The per-road target of the Roads mode: what an upgrade with the toolbar choices makes of one road, and what a road
-- carries now. Read-only: issues no commands.

local config = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_config.tl" as RubConfig
local templates = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_templates.tl" as RubTemplates

local roads : RubRoads = {}

roads.REASON_GONE = "gone"
roads.REASON_NO_TEMPLATE = "no valid road type"
roads.REASON_LANES = "lanes cannot be kept"
roads.REASON_BUS_TRAM = "no bus lane plus tram track here"
roads.NOTE_UNLISTED = "unlisted"
roads.NOTE_COUNTRY = "country"
roads.NOTE_LOST_TREES = "lostTrees"
roads.NOTE_LOST_BARRIER = "lostBarrier"

local KEEP <const> = "keep"
local ADD <const> = "add"
local REMOVE <const> = "remove"
local NONE <const> = "none"
local TREES <const> = "trees"
local BARRIER <const> = "barrier"
local ONE_WAY_MARK <const> = "one_way"
-- The variants of a road template of the game that differ from their base only in the transport modes of the lanes.
local LANE_VARIANTS : {string} = { "_tram_electrified", "_tram", "_bus" }

-- config.roadTypes lists the two-way road types before the one-way ones.
function roads.offeredTypes() : integer
	local count = 0
	for _, roadType in ipairs(config.roadTypes) do
		if string.find(roadType.name, ONE_WAY_MARK, 1, true) ~= nil then break end
		count = count + 1
	end
	return count
end

-- An error inside a read hides behind the result "gone" or "no road type". The log names the first few.
local MAX_ERROR_LINES <const> = 5
local errorLines = 0

local function logError(what : string, edge : integer, err : any)
	if errorLines >= MAX_ERROR_LINES then return end
	errorLines = errorLines + 1
	pcall(function() log.message(string.format("[BrushUpgrade] %s of edge %s failed: %s", what, tostring(edge), tostring(err))) end)
end

local function normalized(resName : string) : string
	return (string.gsub(resName or "", "^::/", ""))
end

local function withoutSuffix(name : string, suffix : string) : string
	if #name > #suffix and string.sub(name, -#suffix) == suffix then return string.sub(name, 1, #name - #suffix) end
	return nil
end

-- The road type (an index in config.roadTypes), the base name and the kind that the name of a street template states.
-- The road type and the base name are nil when it is no template of a road type.
local function parse(resName : string) : integer, string, string
	local name = templates.baseName(resName or "")
	local kind = NONE
	local stripped = withoutSuffix(name, config.TreesSuffix)
	if stripped ~= nil then
		name, kind = stripped, TREES
	else
		stripped = withoutSuffix(name, config.BarriersSuffix)
		if stripped ~= nil then
			name, kind = stripped, BARRIER
		else
			for _, suffix in ipairs(LANE_VARIANTS) do
				stripped = withoutSuffix(name, suffix)
				if stripped ~= nil then
					name = stripped
					break
				end
			end
		end
	end
	for i, roadType in ipairs(config.roadTypes) do
		for _, base in ipairs(roadType.bases) do
			if base == name then return i, base, kind end
		end
	end
	return nil, nil, kind
end

local function suffixOf(kind : string) : string
	if kind == TREES then return config.TreesSuffix end
	if kind == BARRIER then return config.BarriersSuffix end
	return ""
end

-- The edge decorations (alley trees, noise barriers) that a template brings when a road is newly built.
local function decorationsOf(template : string) : {{integer, boolean}}
	local result : {{integer, boolean}} = {}
	local templateId = template ~= nil and api.res.streetTemplateRep.find(template) or -1
	if templateId < 0 then return result end
	for _, entry in ipairs(api.res.streetTemplateRep.get(templateId).defaultEdgeDecorations or {}) do
		local id = api.res.edgeDecorationRep.find(entry[1])
		if id >= 0 then result[#result + 1] = { id, entry[2] } end
	end
	return result
end

local function sameDecorations(have : {{integer, boolean}}, want : {{integer, boolean}}) : boolean
	if #have ~= #want then return false end
	for _, w in ipairs(want) do
		local found = false
		for _, h in ipairs(have) do
			if h[1] == w[1] and h[2] == w[2] then
				found = true
				break
			end
		end
		if not found then return false end
	end
	return true
end

-- The decoration ids that make the alley trees and the noise barriers of a road type.
local record KindIds
	trees : {integer : boolean}
	barrier : {integer : boolean}
end

local function kindIdsOf(roadType : RubRoadType) : KindIds
	local ids : KindIds = { trees = {}, barrier = {} }
	for _, base in ipairs(roadType.bases) do
		for _, d in ipairs(decorationsOf(templates.find(base .. config.TreesSuffix))) do ids.trees[d[1]] = true end
		for _, d in ipairs(decorationsOf(templates.find(base .. config.BarriersSuffix))) do ids.barrier[d[1]] = true end
	end
	return ids
end

local function holdsAny(have : {{integer, boolean}}, ids : {integer : boolean}) : boolean
	for _, d in ipairs(have) do
		if ids[d[1]] then return true end
	end
	return false
end

-- The kind of a road: the one its template name states, else the one its decorations show.
local function kindOf(be : Engine.Component.BaseEdge, named : string, ids : KindIds) : string
	if named ~= NONE then return named end
	local have = be.edgeDecorations or {}
	if holdsAny(have, ids.trees) then return TREES end
	if holdsAny(have, ids.barrier) then return BARRIER end
	return NONE
end

-- One lane of a road or of a street template, as plain data. `driving`: the lane carries vehicles (a sidewalk and a
-- lane without any transport mode do not). `bus`: the lane carries buses, so it can be a bus lane.
local record Lane
	driving : boolean
	forward : boolean
	bus : boolean
	flags : RubLaneFlags
end

local function readLanes(laneConfigs : {LaneConfig}) : {Lane}
	local modes = api.type["enum"].TransportMode
	local lanes : {Lane} = {}
	for i, lane in ipairs(laneConfigs or {}) do
		local on = lane.transportModes or {}
		local function has(mode : TransportMode) : boolean
			return on[mode] and true or false
		end
		local bus, tram = has(modes.BUS), has(modes.TRAM)
		lanes[i] = {
			driving = has(modes.CAR) or bus or has(modes.TRUCK) or tram or has(modes.ELECTRIC_TRAM),
			forward = lane.forward == true,
			bus = bus,
			flags = { carFree = bus and not has(modes.CAR), tram = tram, electric = tram and has(modes.ELECTRIC_TRAM) },
		}
	end
	return lanes
end

local function templateLanes(template : string) : {Lane}
	local id = api.res.streetTemplateRep.find(template)
	if id < 0 then return nil end
	return readLanes(api.res.streetTemplateRep.get(id).laneConfigs)
end

local function anyFlag(flags : RubLaneFlags) : boolean
	return flags.carFree or flags.tram or flags.electric
end

local function sameShape(a : {Lane}, b : {Lane}) : boolean
	if #a ~= #b then return false end
	for i = 1, #a do
		if a[i].driving ~= b[i].driving or (a[i].driving and a[i].forward ~= b[i].forward) then return false end
	end
	return true
end

-- Driving lanes in both directions, the backward ones before the forward ones: the layout of the six road types.
local function isTwoWay(lanes : {Lane}) : boolean
	local lastBackward, firstForward = 0, #lanes + 1
	for i, lane in ipairs(lanes) do
		if lane.driving and lane.forward then
			firstForward = math.min(firstForward, i)
		elseif lane.driving then
			lastBackward = i
		end
	end
	return lastBackward > 0 and firstForward <= #lanes and lastBackward < firstForward
end

-- The positions of the driving lanes of one direction, the outermost first: a backward lane lies the more outside the
-- lower its position, a forward lane the higher.
local function ranked(lanes : {Lane}, forward : boolean) : {integer}
	local found : {integer} = {}
	for i, lane in ipairs(lanes) do
		if lane.driving and lane.forward == forward then
			if forward then table.insert(found, 1, i) else found[#found + 1] = i end
		end
	end
	return found
end

-- The outermost driving lane of each direction. A one-way road has one.
local function outerPositions(lanes : {Lane}) : {integer}
	local outer : {integer} = {}
	for _, forward in ipairs({ false, true }) do
		local first = ranked(lanes, forward)[1]
		if first ~= nil then outer[#outer + 1] = first end
	end
	return outer
end

function roads.outerLanesCarryBuses(template : string) : boolean
	local lanes = templateLanes(template)
	if lanes == nil then return false end
	local outer = outerPositions(lanes)
	for _, i in ipairs(outer) do
		if not lanes[i].bus then return false end
	end
	return #outer > 0
end

-- What the lanes of a road carry, put on the lanes of the target template, per position of a driving lane of the target.
-- Lanes of the same layout map by position. Else each direction maps by rank: with the same number of lanes every lane
-- keeps its rank, with another number the outermost lane maps to the outermost and the innermost to the innermost.
-- Lanes that land on one lane merge. nil when a lane that carries something has no lane to map to.
local function mapped(source : {Lane}, target : {Lane}) : {integer : RubLaneFlags}
	local flags : {integer : RubLaneFlags} = {}
	if sameShape(source, target) then
		for i, lane in ipairs(target) do
			if lane.driving then
				local have = source[i].flags
				flags[i] = { carFree = have.carFree, tram = have.tram, electric = have.electric }
			end
		end
		return flags
	end
	for i, lane in ipairs(target) do
		if lane.driving then flags[i] = { carFree = false, tram = false, electric = false } end
	end
	if not (isTwoWay(source) and isTwoWay(target)) then
		for _, lane in ipairs(source) do
			if lane.driving and anyFlag(lane.flags) then return nil end
		end
		return flags
	end
	for _, forward in ipairs({ false, true }) do
		local from, to = ranked(source, forward), ranked(target, forward)
		local landing : {integer : {RubLaneFlags}} = {}
		for rank, position in ipairs(from) do
			local toRank : integer = nil
			if #from == #to then toRank = rank elseif rank == 1 then toRank = 1 elseif rank == #from then toRank = #to end
			if toRank == nil then
				if anyFlag(source[position].flags) then return nil end
			else
				local at = to[toRank]
				landing[at] = landing[at] or {}
				table.insert(landing[at], source[position].flags)
			end
		end
		for at, landed in pairs(landing) do
			local merged : RubLaneFlags = { carFree = true, tram = false, electric = false }
			for _, have in ipairs(landed) do
				merged.carFree = merged.carFree and have.carFree
				merged.tram = merged.tram or have.tram
				merged.electric = merged.electric or have.electric
			end
			flags[at] = merged
		end
	end
	return flags
end

-- The lanes without what a Remove state of the toolbar takes off, so that a lane that carries only such things needs no
-- lane to map to.
local function withoutRemoved(lanes : {Lane}, choices : RubChoices) : {Lane}
	local result : {Lane} = {}
	for i, lane in ipairs(lanes) do
		local have = lane.flags
		local tram = have.tram and choices.tram ~= REMOVE
		result[i] = {
			driving = lane.driving, forward = lane.forward, bus = lane.bus,
			flags = {
				carFree = have.carFree and choices.busLane ~= REMOVE, tram = tram,
				electric = tram and have.electric and choices.catenary ~= REMOVE,
			},
		}
	end
	return result
end

-- Changes the flags by the Add states of the toolbar. Returns the reason when the road cannot take them.
local function applyStates(flags : {integer : RubLaneFlags}, target : {Lane}, choices : RubChoices) : string
	local outer = outerPositions(target)
	if choices.busLane == ADD then
		for _, i in ipairs(outer) do flags[i].carFree = true end
	end
	if choices.tram == ADD then
		local hasTram = false
		for _, f in pairs(flags) do hasTram = hasTram or f.tram end
		if not hasTram then
			for _, i in ipairs(outer) do flags[i].tram = true end
		end
	end
	for i, f in pairs(flags) do
		if choices.catenary == ADD then f.electric = f.tram end
		f.carFree = f.carFree and target[i].bus
	end
	if choices.busLane == ADD then
		for _, i in ipairs(outer) do
			if flags[i].tram and not target[i].bus then return roads.REASON_BUS_TRAM end
		end
	end
	return nil
end

local function carries(source : {Lane}, flags : {integer : RubLaneFlags}) : boolean
	for i, want in pairs(flags) do
		local lane = source[i]
		if lane == nil or not lane.driving then return false end
		local have = lane.flags
		if have.carFree ~= want.carFree or have.tram ~= want.tram or have.electric ~= want.electric then return false end
	end
	return true
end

local function readEdge(edge : integer) : Engine.Component.BaseEdge
	return api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
end

function roads.isAllKeep(choices : RubChoices) : boolean
	local decorations = choices.underground or (choices.trees == KEEP and choices.barrier == KEEP)
	return choices.roadType == 0 and decorations and choices.busLane == KEEP and choices.tram == KEEP and choices.catenary == KEEP
		and choices.lock == KEEP
end

function roads.key(choices : RubChoices) : string
	return table.concat({ "road", tostring(choices.roadType), choices.busLane, choices.tram, choices.catenary, choices.trees,
		choices.barrier, choices.lock, tostring(choices.underground) }, "/")
end

function roads.targeter(choices : RubChoices, year : integer) : RubTarget
	local offered = roads.offeredTypes()
	local trees = choices.underground and KEEP or choices.trees
	local barrier = choices.underground and KEEP or choices.barrier
	local kindIds : {integer : KindIds} = {}
	-- The lanes of the templates met so far, per resource name.
	local lanesOfTemplate : {string : {Lane}} = {}

	local function planOf(edge : integer) : RubPlan
		local be = readEdge(edge)
		if be == nil or be.roadTemplate == nil or be.roadTemplate == "" then return nil end
		local current = be.roadTemplate
		local typeIndex, base, named = parse(current)
		local listed = typeIndex ~= nil and typeIndex <= offered
		local targetType : RubRoadType = nil
		if choices.roadType > 0 then targetType = config.roadTypes[choices.roadType] elseif listed then targetType = config.roadTypes[typeIndex] end
		local notes : {string} = {}
		local kindNow, kind = NONE, NONE
		if targetType == nil then
			if trees ~= KEEP or barrier ~= KEEP then notes[#notes + 1] = roads.NOTE_UNLISTED end
		else
			-- A listed road shows its kind by the decorations of its own road type, any other road by those of the target.
			local idsOf = listed and typeIndex or choices.roadType
			kindIds[idsOf] = kindIds[idsOf] or kindIdsOf(config.roadTypes[idsOf])
			kindNow = kindOf(be, named, kindIds[idsOf])
			kind = kindNow
			if barrier == ADD then
				kind = BARRIER
			elseif trees == ADD then
				if targetType.country then notes[#notes + 1] = roads.NOTE_COUNTRY else kind = TREES end
			end
			if (trees == REMOVE or targetType.country) and kind == TREES then kind = NONE end
			if barrier == REMOVE and kind == BARRIER then kind = NONE end
			if kindNow == TREES and kind ~= TREES and trees ~= REMOVE then notes[#notes + 1] = roads.NOTE_LOST_TREES end
			if kindNow == BARRIER and kind ~= BARRIER and barrier ~= REMOVE then notes[#notes + 1] = roads.NOTE_LOST_BARRIER end
		end

		local template : string = nil
		if choices.roadType > 0 then
			template = templates.resolve(targetType, suffixOf(kind), year)
			-- A base game variant with a bus lane or a tram of the template that the road type gives is that template.
			if template ~= nil and listed and kind == named then
				local plain = templates.find(base .. suffixOf(named))
				if plain ~= nil and normalized(plain) == normalized(template) then template = current end
			end
		elseif not listed or kind == kindNow then
			template = current
		else
			template = templates.find(base .. suffixOf(kind))
		end
		if template == nil then return { reason = roads.REASON_NO_TEMPLATE, unchanged = false, notes = notes } end
		local sameTemplate = normalized(template) == normalized(current)

		local source = readLanes(be.laneConfigs)
		local target = lanesOfTemplate[template] or templateLanes(template)
		lanesOfTemplate[template] = target
		if target == nil then return { reason = roads.REASON_NO_TEMPLATE, unchanged = false, notes = notes } end
		local flags = mapped(withoutRemoved(source, choices), target)
		if flags == nil then return { reason = roads.REASON_LANES, unchanged = false, notes = notes } end
		local reason = applyStates(flags, target, choices)
		if reason ~= nil then return { reason = reason, unchanged = false, notes = notes } end

		local setDecorations = kind ~= kindNow or (kind ~= NONE and not sameTemplate)
		local decorations : {{integer, boolean}} = nil
		if setDecorations then decorations = decorationsOf(template) end

		local lockIsSet = choices.lock == KEEP or (be.roadDevelopmentLocked == true) == (choices.lock == "lock")
		local unchanged = sameTemplate and lockIsSet and carries(source, flags)
			and (decorations == nil or sameDecorations(be.edgeDecorations or {}, decorations))
		return {
			template = template, unchanged = unchanged, lanes = flags, laneCount = #target, decorations = decorations, lock = choices.lock,
			notes = notes,
		}
	end

	return function(edge : integer) : RubPlan
		local ok, plan = pcall(planOf, edge)
		if ok and plan ~= nil then return plan end
		if not ok then logError("the plan", edge, plan) end
		return { reason = roads.REASON_GONE, unchanged = false, notes = {} }
	end
end

function roads.read(edge : integer) : RubClone
	local ok, found = pcall(function() : RubClone
		local be = readEdge(edge)
		if be == nil or be.roadTemplate == nil then return nil end
		local typeIndex, _base, named = parse(be.roadTemplate)
		if typeIndex == nil then return nil end
		local kind = kindOf(be, named, kindIdsOf(config.roadTypes[typeIndex]))
		local lanes = readLanes(be.laneConfigs)
		local outer = outerPositions(lanes)
		local isOuter : {integer : boolean} = {}
		for _, i in ipairs(outer) do isOuter[i] = true end
		local first : RubLaneFlags = #outer > 0 and lanes[outer[1]].flags or { carFree = false, tram = false, electric = false }
		-- The toolbar can state only what the outer lanes carry alike and no other lane carries.
		local edited = false
		for i, lane in ipairs(lanes) do
			if lane.driving then
				local have = lane.flags
				if isOuter[i] then
					edited = edited or have.carFree ~= first.carFree or have.tram ~= first.tram or have.electric ~= first.electric
				else
					edited = edited or anyFlag(have)
				end
			end
		end
		return {
			roadType = typeIndex, trees = kind == TREES, barrier = kind == BARRIER,
			busLane = not edited and first.carFree, tram = not edited and first.tram, catenary = not edited and first.electric,
			lock = be.roadDevelopmentLocked and "lock" or KEEP, editedLanes = edited,
		}
	end)
	if ok then return found end
	logError("the read", edge, found)
	return nil
end

return roads
