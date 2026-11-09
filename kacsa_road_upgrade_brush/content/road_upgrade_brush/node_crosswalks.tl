-- The crosswalks of a node: one command that rewrites the config of the node with a crosswalk on every street segment of the node, and
-- the lookup of a node by its position. The module reads only the node and its streets, keeps no state, and creates no global variable.
-- An error of the engine never reaches the caller: a failing read gives no command and a reason.

local nodeCrosswalks : RubNodeCrosswalks = {}

-- Metres. A node counts as the remembered node when its position lies this close to the remembered one.
local NODE_MATCH_METERS <const> = 1.0
-- The most streets that `readBack` describes.
local MAX_READ_BACK_STREETS <const> = 8

-- Which streets of a node get a crosswalk: the streets of a junction with a town street, every street, or every street with a
-- pedestrian lane.
local MODE_TOWN <const> = "town"
local MODE_ALL <const> = "all"
local MODE_SIDEWALK <const> = "sidewalk"

function nodeCrosswalks.templateOf(street : integer) : StreetTemplate
	local edge = api.engine.getComponent(street, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	return api.res.streetTemplateRep.get(api.res.streetTemplateRep.find(edge.roadTemplate))
end

local function hasSidewalk(street : integer) : boolean
	local edge = api.engine.getComponent(street, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	for _, lane in ipairs(edge.laneConfigs) do
		if lane.transportModes[api.type.enum.TransportMode.PERSON] then return true end
	end
	return false
end

-- A town street is no country road and has a sidewalk (highways and ramps have none).
local function isTownStreet(street : integer) : boolean
	return not nodeCrosswalks.templateOf(street).country and hasSidewalk(street)
end

local function hasTownStreet(streets : {integer}) : boolean
	for _, street in ipairs(streets) do
		if isTownStreet(street) then return true end
	end
	return false
end

local function hasPedestrianStreet(streets : {integer}) : boolean
	for _, street in ipairs(streets) do
		if hasSidewalk(street) then return true end
	end
	return false
end

-- The reason that a node stays as it is when its streets do not fit the mode, else nil.
local function modeRefusal(streets : {integer}, mode : string) : string
	if mode == MODE_ALL then return #streets == 0 and "no_street" or nil end
	if mode == MODE_SIDEWALK then return not hasPedestrianStreet(streets) and "no_pedestrian_street" or nil end
	return not hasTownStreet(streets) and "no_town_street" or nil
end

-- A copy of the node config with a crosswalk on the streets of the node that the mode names, behind the crosswalks it has.
-- Returns nil and a reason when the node stays as it is, else the entry and the text "N added".
local function crosswalkConfig(node : integer, streets : {integer}, mode : string) : Proposal.BaseNodeLaneConnectionAndEntity, string
	local config = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE_CONFIG) as Engine.Component.BaseNodeConfig
	if config == nil then return nil, "no_config" end
	local refusal = modeRefusal(streets, mode)
	if refusal ~= nil then return nil, refusal end
	local crosswalks : {integer} = {}
	local present : {integer : boolean} = {}
	for _, crosswalk in ipairs(config.crosswalks or {}) do
		crosswalks[#crosswalks + 1] = crosswalk
		present[crosswalk] = true
	end
	local added = 0
	for _, street in ipairs(streets) do
		if not present[street] and (mode ~= MODE_SIDEWALK or hasSidewalk(street)) then
			crosswalks[#crosswalks + 1] = street
			added = added + 1
		end
	end
	if added == 0 then return nil, "unchanged" end
	local entry = api.type.BaseNodeLaneConnectionAndEntity.new()
	entry.entity = node
	local message = ""
	local copied = xpcall(function()
		entry.comp = config
		entry.comp.crosswalks = crosswalks
	end, function(problem : any) message = tostring(problem) end)
	if not copied then return nil, "config_copy_failed " .. message end
	return entry, added .. " added"
end

local function commandFor(node : integer, context : Context, mode : string) : Command<WorldBuildProposalCommandData>, string
	local command : Command<WorldBuildProposalCommandData> = nil
	local detail = ""
	local message = ""
	local ok = xpcall(function()
		local entry, reason = crosswalkConfig(node, api.engine.system.streetSystem.getNodeStreetSegments(node) or {}, mode)
		if entry == nil then
			detail = reason
			return
		end
		local proposal = api.type.SimpleProposal.new()
		proposal.streetProposal.nodeConfigsToRemove = { node }
		proposal.streetProposal.nodeConfigsToAdd = { entry }
		command = api.cmd.makeWorldBuildProposalCmd(proposal, context, false, true)
		detail = reason
	end, function(problem : any) message = tostring(problem) end)
	if not ok then return nil, "read_failed " .. message end
	return command, detail
end

function nodeCrosswalks.command(node : integer, context : Context, allStreets : boolean) : Command<WorldBuildProposalCommandData>, string
	return commandFor(node, context, allStreets and MODE_ALL or MODE_TOWN)
end

function nodeCrosswalks.commandSidewalk(node : integer, context : Context) : Command<WorldBuildProposalCommandData>, string
	return commandFor(node, context, MODE_SIDEWALK)
end

local function positionOf(node : integer) : Vec3f
	local comp = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
	return comp ~= nil and comp.position or nil
end

local function isNear(position : Vec3f, spot : RubNodeSpot) : boolean
	return position ~= nil and (position.x - spot.x) ^ 2 + (position.y - spot.y) ^ 2 <= NODE_MATCH_METERS ^ 2
end

function nodeCrosswalks.remember(node : integer) : RubNodeSpot
	local ok, position = pcall(positionOf, node)
	if not ok or position == nil then return nil end
	return { node = node, x = position.x, y = position.y }
end

-- The remembered node when it still lies at its position, else the nearest node within NODE_MATCH_METERS of that position.
local function nodeAt(spot : RubNodeSpot) : integer
	local okOld, position = pcall(positionOf, spot.node)
	if okOld and isNear(position, spot) then return spot.node end
	local okFound, found = pcall(api.engine.util.octree.findEntitiesInCircle, api.type.Vec2f.new(spot.x, spot.y), NODE_MATCH_METERS,
		api.type.ComponentType.BASE_NODE)
	if not okFound or found == nil then return nil end
	local nearest : integer = nil
	local nearestSquared : number = nil
	for _, candidate in ipairs(found as {integer}) do
		local okC, p = pcall(positionOf, candidate)
		if okC and isNear(p, spot) then
			local squared = (p.x - spot.x) ^ 2 + (p.y - spot.y) ^ 2
			if nearestSquared == nil or squared < nearestSquared then nearest, nearestSquared = candidate, squared end
		end
	end
	return nearest
end

function nodeCrosswalks.commandAt(spot : RubNodeSpot, context : Context, allStreets : boolean) : Command<WorldBuildProposalCommandData>, string, integer
	local node = nodeAt(spot)
	if node == nil then return nil, "node_not_found", spot.node end
	local command, detail = nodeCrosswalks.command(node, context, allStreets)
	return command, detail, node
end

function nodeCrosswalks.inspect(spot : RubNodeSpot) : RubNodeView
	local node = nodeAt(spot)
	if node == nil then return { node = spot.node, found = false, readable = false, streets = {}, crosswalks = {} } end
	local view : RubNodeView = { node = node, found = true, readable = false, streets = {}, crosswalks = {} }
	local ok = pcall(function() : string
		local config = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE_CONFIG) as Engine.Component.BaseNodeConfig
		local streets = api.engine.system.streetSystem.getNodeStreetSegments(node)
		if config == nil or streets == nil then return nil end
		for _, crosswalk in ipairs(config.crosswalks or {}) do view.crosswalks[#view.crosswalks + 1] = crosswalk end
		for _, street in ipairs(streets as {integer}) do view.streets[#view.streets + 1] = street end
		view.readable = true
		return nil
	end)
	if not ok then view.readable = false end
	return view
end

function nodeCrosswalks.endSpots(edge : integer) : {RubNodeSpot}
	local spots : {RubNodeSpot} = {}
	local ok, comp = pcall(function() : Engine.Component.BaseEdge
		return api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	end)
	if not ok or comp == nil then return spots end
	for _, node in ipairs({ comp.node0, comp.node1 }) do
		local spot = nodeCrosswalks.remember(node)
		if spot ~= nil then spots[#spots + 1] = spot end
	end
	return spots
end

-- One street of a node as text: its template, the default of the template, and whether the street is in the crosswalk list.
local function streetItem(street : integer, listed : {integer : boolean}) : string
	local ok, text = pcall(function() : string
		local edge = api.engine.getComponent(street, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
		return string.format("street %d template %s defaultWithCrosswalk %s in list %s", street, tostring(edge.roadTemplate),
			tostring(nodeCrosswalks.templateOf(street).defaultWithCrosswalk == true), listed[street] and "yes" or "no")
	end)
	return ok and text or string.format("street %d unreadable", street)
end

-- The crosswalk list of the config of a node, as text.
local function crosswalkSummary(node : integer) : string, {integer : boolean}
	local listed : {integer : boolean} = {}
	local ok, summary = pcall(function() : string
		local config = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE_CONFIG) as Engine.Component.BaseNodeConfig
		if config == nil then return "no config" end
		local ids : {string} = {}
		for i, crosswalk in ipairs(config.crosswalks or {}) do
			ids[i] = tostring(crosswalk)
			listed[crosswalk] = true
		end
		return string.format("%d crosswalks [%s]", #ids, table.concat(ids, ", "))
	end)
	return ok and summary or ("unreadable (" .. tostring(summary) .. ")"), listed
end

-- What the engine holds for the node of `spot` now, for the log: the id of the node, its crosswalk list as text, and one item for
-- each of at most MAX_READ_BACK_STREETS streets. It never raises an error.
function nodeCrosswalks.readBack(spot : RubNodeSpot) : integer, string, {string}
	local items : {string} = {}
	local node = nodeAt(spot)
	if node == nil then return spot.node, "node not found", items end
	local summary, listed = crosswalkSummary(node)
	local okS, streets = pcall(api.engine.system.streetSystem.getNodeStreetSegments, node)
	if not okS or streets == nil then
		items[1] = "streets unreadable"
		return node, summary, items
	end
	for i, street in ipairs(streets as {integer}) do
		if i <= MAX_READ_BACK_STREETS then items[#items + 1] = streetItem(street, listed) end
	end
	return node, summary, items
end

return nodeCrosswalks
