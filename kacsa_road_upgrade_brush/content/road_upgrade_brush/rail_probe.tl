-- Probe for upgrading rails. It sends ONE real command per middle click on a track: the track changes to the next
-- base track type (simple, standard, high speed, simple, ...) and keeps its catenary. Use a test save.

local gather = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/bb_gather.tl" as RubGather
local sel = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/bb_select.tl" as RubSelect
local brushClone = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/brush_clone.tl" as RubBrushClone

local rail : RubRailProbe = {}

-- Seconds between the answer of the game and the second reading of the track.
local CHECK_DELAY <const> = 1.5
local TRACK_PATH <const> = "/track/"

local ALL_FILTERS : RubFilters = {
	roads = true, tracks = true, stations = true, assets = true, townBuildings = true, underground = true, surface = true,
}

local TRACK : RubKind = "track"

local TYPES : {string} = { "simple", "standard", "high_speed" }
local TEMPLATE_PREFIX <const> = "::/infrastructure/track/"
local CATENARY_SUFFIX <const> = "_catenary"
local TEMPLATE_ENDING <const> = ".street_template"

local MODE_NAMES : {string} = { "TRAIN", "ELECTRIC_TRAIN", "TRAM_TRACK", "ELECTRIC_TRAM_TRACK", "CAR", "PERSON", "CARGO" }

local function templateName(trackType : string, catenary : boolean) : string
	return TEMPLATE_PREFIX .. trackType .. "/" .. trackType .. (catenary and CATENARY_SUFFIX or "") .. TEMPLATE_ENDING
end

-- The transport modes of the first lane that are on, by name.
local function laneModesText(be : Engine.Component.BaseEdge) : string
	local lane = (be.laneConfigs or {})[1]
	if lane == nil then return "no lane" end
	local modes = api.type["enum"].TransportMode as any as {string : any}
	local have = lane.transportModes as any as {any : boolean}
	local on : {string} = {}
	for _, name in ipairs(MODE_NAMES) do
		local mode = modes[name]
		if mode ~= nil and have[mode] then on[#on + 1] = name end
	end
	return table.concat(on, "+")
end

-- The kinds of the objects on the edge (signal, stop), by name.
local function objectKindsText(be : Engine.Component.BaseEdge) : string
	local kinds = api.type["enum"].EdgeObjectType as any as {string : any}
	local out : {string} = {}
	for _, o in ipairs(be.objects or {}) do
		local kind = tostring(o[2])
		for _, name in ipairs({ "SIGNAL", "STOP_LEFT", "STOP_RIGHT" }) do
			if kinds[name] == o[2] then kind = name end
		end
		out[#out + 1] = kind
	end
	return table.concat(out, ",")
end

-- State between the command and the second reading.
local running = false
local check : {string : any} = nil

local function edgeText(e : integer) : string
	local ok, text = pcall(function() : string
		local be = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
		if be == nil then return "no BASE_EDGE" end
		local kinds = api.type.enum.BaseEdgeType
		local kind = "normal"
		if be.type == kinds.BRIDGE then kind = "bridge" elseif be.type == kinds.TUNNEL then kind = "tunnel" end
		return string.format("template %s, %s, nodes %s-%s, %d edge objects (%s), %d decorations, %d lanes, lane modes %s",
			tostring(be.roadTemplate), kind, tostring(be.node0), tostring(be.node1), #(be.objects or {}), objectKindsText(be),
			#(be.edgeDecorations or {}), #(be.laneConfigs or {}), laneModesText(be))
	end)
	if ok then return text end
	return "unreadable: " .. tostring(text)
end

local function objectCount(e : integer) : integer
	local ok, n = pcall(function() : integer
		local be = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
		return #(be.objects or {})
	end)
	if ok then return n end
	return -1
end

local templatesLogged = false

local function logTrackTemplates(logFn : function(string))
	if templatesLogged then return end
	templatesLogged = true
	local rep = api.res.streetTemplateRep
	for _, resName in pairs(rep.getAll(true)) do
		if string.find(resName, TRACK_PATH, 1, true) ~= nil then
			local id = rep.find(resName)
			if id >= 0 then
				local t = rep.get(id)
				logFn(string.format("rail probe: template %s, id %d, roadType %s, catenaryAdd %s, catenaryRemove %s",
					resName, id, tostring(t.roadType), tostring(t.catenaryAdd), tostring(t.catenaryRemove)))
			end
		end
	end
end

-- The template of the next base track type with the same catenary. nil when the template is none of the six base templates.
local function nextTypeOf(template : string) : string
	for i, trackType in ipairs(TYPES) do
		for _, catenary in ipairs({ false, true }) do
			if template == templateName(trackType, catenary) then
				local target = templateName(TYPES[i % #TYPES + 1], catenary)
				if api.res.streetTemplateRep.find(target) >= 0 then return target end
				return nil
			end
		end
	end
	return nil
end

local function gameSpeed() : integer
	local ok, speed = pcall(function() : integer
		local gs = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_SPEED) as Engine.Component.GameSpeed
		return gs.speedup
	end)
	if ok then return speed end
	return nil
end

local function setSpeed(speed : integer, done : function())
	local ok = pcall(function() : string
		api.cmd.sendCommand(api.cmd.makeGameSetSpeedCmd(speed), function(_data : GameSetSpeedCommandData, _success : boolean)
			done()
		end)
		return nil
	end)
	if not ok then done() end
end

local function messagesOf(data : WorldBuildProposalCommandData) : string
	local ok, text = pcall(function() : string
		local out : {string} = {}
		local msgs = (data.resultProposalData.errorState.messages or {}) as {string}
		for i = 1, #msgs do out[#out + 1] = tostring(msgs[i]) end
		return table.concat(out, "; ")
	end)
	if ok then return text end
	return "messages unreadable"
end

local function send(p : Proposal, edge : integer, x : number, y : number, underground : boolean, logFn : function(string))
	local before = gameSpeed()
	if before == nil then
		logFn("rail probe: game speed unreadable, no command is sent")
		running = false
		return
	end
	local function sendCommand()
		local objectsBefore = objectCount(edge)
		local ok, err = pcall(function() : string
			local context = api.type.Context.new()
			pcall(function() context.player = api.engine.util.getPlayer() end)
			api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(p, context, false, true, true),
				function(data : WorldBuildProposalCommandData, success : boolean)
					logFn(string.format("rail probe: command answered, success %s, messages: %s", tostring(success), messagesOf(data)))
					local function after()
						check = { dueAt = os.clock() + CHECK_DELAY, x = x, y = y, underground = underground, edge = edge,
							objectsBefore = objectsBefore, logFn = logFn }
						running = false
					end
					if before ~= 0 then setSpeed(before, after) else after() end
				end)
			return nil
		end)
		if not ok then
			logFn("rail probe: send failed: " .. tostring(err))
			running = false
		end
	end
	if before == 0 then
		sendCommand()
	else
		setSpeed(0, sendCommand)
	end
end

function rail.run(x : number, y : number, underground : boolean, logFn : function(string)) : boolean
	if running or check ~= nil then
		logFn("rail probe: the previous probe is not finished")
		return false
	end
	local edge, note = brushClone.pick(x, y, underground, true)
	if edge == nil then
		logFn(string.format("rail probe: no track at %.1f/%.1f; %s", x, y, tostring(note)))
		return false
	end
	logFn(string.format("rail probe: edge %d; %s; %s", edge, edgeText(edge), tostring(note)))
	logTrackTemplates(logFn)
	local d = gather.describeEdge(edge, gather.newCache())
	local c = sel.classify(d, ALL_FILTERS, { player = api.engine.util.getPlayer(), hq = -1 })
	logFn(string.format("rail probe: kind %s, reason %s, owner %s, street %s, part of construction %s, tunnel %s",
		tostring(c.kind), tostring(c.reason), tostring(d.owner), tostring(d.isStreet), tostring(d.parentConstruction), tostring(d.isTunnel)))
	if c.kind ~= TRACK or c.reason ~= nil then
		logFn("rail probe: the edge is not a track the tool may change, no command is sent")
		return false
	end
	local be = api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	local template = be.roadTemplate
	local twin = nextTypeOf(template)
	if twin == nil then
		logFn("rail probe: " .. tostring(template) .. " is none of the six base track templates, no command is sent")
		return false
	end
	local okP, p = pcall(api.engine.util.proposal.replaceSegment, edge, twin)
	if not okP or p == nil then
		logFn("rail probe: replaceSegment failed: " .. tostring(p))
		return false
	end
	local okS, errS = pcall(function() : string
		local street = p.proposal
		local added = street.addedSegments
		local mapped = 0
		for _ in pairs(street.old2newEdgeObjects or {}) do mapped = mapped + 1 end
		logFn(string.format("rail probe: proposal %s -> %s: +%d/-%d segments, +%d/-%d nodes, %d edge objects to add, %d old objects mapped to new ones, toRemove %d, toAdd %d, added template %s with %d objects",
			tostring(template), tostring(twin), #added, #street.removedSegments, #street.addedNodes, #street.removedNodes,
			#street.edgeObjectsToAdd, mapped, #(p.toRemove or {}), #(p.toAdd or {}),
			#added > 0 and tostring(added[1].comp.roadTemplate) or "none", #added > 0 and #(added[1].comp.objects or {}) or 0))
		return nil
	end)
	if not okS then logFn("rail probe: proposal inspection failed: " .. tostring(errS)) end
	running = true
	send(p, edge, x, y, underground, logFn)
	return true
end

function rail.tick()
	if check == nil or os.clock() < (check.dueAt as number) then return end
	local c = check
	check = nil
	local logFn = c.logFn as function(string)
	local before = c.edge as integer
	local objectsBefore = c.objectsBefore as integer
	local edge = brushClone.pick(c.x as number, c.y as number, c.underground as boolean, true)
	logFn(string.format("rail probe: old edge %d still exists: %s", before, tostring(api.engine.entityExists(before))))
	if edge == nil then
		logFn("rail probe: no track under the pointer after the command")
		return
	end
	local after = objectCount(edge)
	logFn(string.format("rail probe: after the command edge %d; %s; edge objects before %d, after %d%s", edge, edgeText(edge),
		objectsBefore, after, after < objectsBefore and " (LOST)" or ""))
end

return rail
