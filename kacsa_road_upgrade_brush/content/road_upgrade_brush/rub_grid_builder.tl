-- Debug console only: the console loads this module with ug_require and calls `build(options)`. Nothing else loads it, and it sets no global variable.
-- The grid is built one street segment per command. A command starts in the callback of the previous one.
-- Lengths are in metres. The positions of a grid are counted in blocks from the end of the strip.

local templates = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_templates.tl" as RubTemplates

local gridBuilder : RubGridBuilderModule = {}

local LOG_TAG <const> = "[BrushUpgrade] [grid]"
local BUILD_MARK <const> = "2026-11-03 stemorder"
local DEFAULT_BLOCKS_ALONG <const> = 6
local DEFAULT_BLOCKS_LEFT <const> = 8
local DEFAULT_BLOCK_LENGTH_ALONG_M <const> = 144
local DEFAULT_BLOCK_LENGTH_LEFT_M <const> = 88
local DEFAULT_CAMERA_SEARCH_RADIUS_M <const> = 150
local DEFAULT_NODE_SNAP_RADIUS_M <const> = 3
local DEFAULT_LARGE_EVERY_ALONG <const> = 4
local DEFAULT_LARGE_EVERY_LEFT <const> = 3
local DEFAULT_EDGES_PER_COMMAND <const> = 1
local MAX_COMMAND_ATTEMPTS <const> = 3
local MAX_WAIT_POLLS <const> = 150
local WAIT_EVENT_SOURCE <const> = "kacsa_road_upgrade_brush"
local WAIT_EVENT_ID <const> = "rub_grid_wait"
local WAIT_EVENT_NAME <const> = "rub_grid_wait"
local DEFAULT_LARGE_BASE_NAMES : {string} = { "town_new_large", "town_old_large" }
local TEMPORARY_ID_START <const> = 0
local SEGMENT_TYPE_STREET <const> = 0
local ROUNDING_STEPS <const> = 100
local STUB_LENGTH_M <const> = 30
local MIN_DIRECTION_LENGTH <const> = 0.001
local MIN_STREETS_AT_JUNCTION <const> = 3
local STRAIGHT_LIMIT_RAD <const> = math.pi / 4
local TURN_U <const> = "u"
local TURN_STRAIGHT <const> = "straight"
local TURN_LEFT <const> = "left"
local TURN_RIGHT <const> = "right"
local KIND_BUS <const> = "bus"
local KIND_NORMAL <const> = "normal"
local FIT_TOLERANCE <const> = 1e-9
local STRAIGHT_MIN_DOT <const> = 0.866
local MOVE_STRAIGHT <const> = "straight"
local MOVE_LEFT <const> = "left"
local MOVE_RIGHT <const> = "right"
local MOVE_BACK <const> = "back"
local LANES_OWN <const> = "own"
local LANES_STUB_REMOVE <const> = "stub_remove"
local LANES_STUB_KEEP <const> = "stub_keep"
local LANES_OFF <const> = "off"
local KMH_PER_MS <const> = 3.6
local DEFAULT_SMALL_ROAD_KMH <const> = 30
local SPEED_TOLERANCE_MS <const> = 0.001
local SMALL_ROAD_BASES : {string} = { "town_new_small", "town_old_small", "country_new_small", "country_old_small" }

local record Frame
	originX : number
	originY : number
	forwardX : number
	forwardY : number
	leftX : number
	leftY : number
end

local record GridPoint
	nodeId : integer
	x : number
	y : number
	z : number
end

local record Segment
	fromAlong : integer
	fromLeft : integer
	toAlong : integer
	toLeft : integer
end

-- The values of the strip are copied when the plan is made. The strip, its owner and its templates are views of engine data that the engine can move or rewrite while the commands run.
local record Plan
	options : RubGridOptions
	frame : Frame
	stripTemplateName : string
	stripTypeIndex : integer
	stripDistance : number
	stripDecorations : {{integer, boolean}}
	largeTemplateName : string
	largeDecorations : {{integer, boolean}}
	ownerPlayer : integer
	context : Context
	segments : {Segment}
end

local function rounded(value : number) : number
	return math.floor(value * ROUNDING_STEPS + 0.5) / ROUNDING_STEPS
end

-- The most blocks whose total length does not exceed maxLengthM.
local function blocksFitting(maxLengthM : number, blockLengthM : number) : integer
	local blocks = math.floor(maxLengthM / blockLengthM + FIT_TOLERANCE)
	assert(blocks >= 1, LOG_TAG .. " length_shorter_than_one_block")
	return blocks
end

local function withDefaults(options : RubGridOptions) : RubGridOptions
	local given : RubGridOptions = options or {}
	local largeEveryAlong = given.largeEveryAlong or DEFAULT_LARGE_EVERY_ALONG
	local largeEveryLeft = given.largeEveryLeft or DEFAULT_LARGE_EVERY_LEFT
	local explicitNodeConfigs = given.explicitNodeConfigs
	if explicitNodeConfigs == nil then explicitNodeConfigs = largeEveryAlong > 0 or largeEveryLeft > 0 end
	local blockLengthAlongM = given.blockLengthAlongM or DEFAULT_BLOCK_LENGTH_ALONG_M
	local blockLengthLeftM = given.blockLengthLeftM or DEFAULT_BLOCK_LENGTH_LEFT_M
	local blocksAlong = given.blocksAlong or DEFAULT_BLOCKS_ALONG
	local blocksLeft = given.blocksLeft or DEFAULT_BLOCKS_LEFT
	if given.maxLengthAlongM ~= nil then blocksAlong = blocksFitting(given.maxLengthAlongM, blockLengthAlongM) end
	if given.maxLengthLeftM ~= nil then blocksLeft = blocksFitting(given.maxLengthLeftM, blockLengthLeftM) end
	return {
		blocksAlong = blocksAlong,
		blocksLeft = blocksLeft,
		blockLengthAlongM = blockLengthAlongM,
		blockLengthLeftM = blockLengthLeftM,
		buildToRight = given.buildToRight or false,
		flipStripDirection = given.flipStripDirection or false,
		cameraSearchRadiusM = given.cameraSearchRadiusM or DEFAULT_CAMERA_SEARCH_RADIUS_M,
		nodeSnapRadiusM = given.nodeSnapRadiusM or DEFAULT_NODE_SNAP_RADIUS_M,
		largeEveryAlong = largeEveryAlong,
		largeEveryLeft = largeEveryLeft,
		largeStreetBaseNames = given.largeStreetBaseNames or DEFAULT_LARGE_BASE_NAMES,
		edgesPerCommand = given.edgesPerCommand or DEFAULT_EDGES_PER_COMMAND,
		explicitNodeConfigs = explicitNodeConfigs,
		laneConnections = given.laneConnections or (explicitNodeConfigs and LANES_OWN or LANES_OFF),
	}
end

-- The street edge whose midpoint is nearest to the centre of the camera, and that distance.
local function findStrip(radius : number) : integer, number
	local camera = api.gui.camera.getCameraData()
	local edges = api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(camera.x, camera.y), radius, api.type.ComponentType.BASE_EDGE)
	local stripId : integer
	local nearest : number
	for _, edgeId in ipairs(edges) do
		local edge = api.engine.getComponent(edgeId, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
		if edge ~= nil and edge.roadType == api.type.enum.RoadType.STREET then
			local dx = (edge.position0.x + edge.position1.x) / 2 - camera.x
			local dy = (edge.position0.y + edge.position1.y) / 2 - camera.y
			local distance = math.sqrt(dx * dx + dy * dy)
			if nearest == nil or distance < nearest then
				stripId, nearest = edgeId, distance
			end
		end
	end
	assert(stripId ~= nil, LOG_TAG .. " no_street_near_camera")
	return stripId, nearest
end

local function nodePosition(node : integer) : Vec3f
	return (api.engine.getComponent(node, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode).position
end

-- The grid starts at the second node of the strip and runs in the direction from the first node to the second.
-- The side direction ("left" in the rest of this file) points to the right of the heading when toRight is true.
local function stripFrame(strip : Engine.Component.BaseEdge, flip : boolean, toRight : boolean) : Frame
	local first, last = nodePosition(strip.node0), nodePosition(strip.node1)
	if flip then first, last = last, first end
	local dx, dy = last.x - first.x, last.y - first.y
	local length = math.sqrt(dx * dx + dy * dy)
	local forwardX, forwardY = dx / length, dy / length
	local side = toRight and -1 or 1
	return { originX = last.x, originY = last.y, forwardX = forwardX, forwardY = forwardY, leftX = -forwardY * side, leftY = forwardX * side }
end

local function worldXY(plan : Plan, alongIndex : integer, leftIndex : integer) : number, number
	local frame, options = plan.frame, plan.options
	local along = alongIndex * options.blockLengthAlongM
	local left = leftIndex * options.blockLengthLeftM
	return frame.originX + along * frame.forwardX + left * frame.leftX, frame.originY + along * frame.forwardY + left * frame.leftY
end

local function gridFitsMap(plan : Plan) : boolean
	for alongIndex = 0, plan.options.blocksAlong do
		for leftIndex = 0, plan.options.blocksLeft do
			local x, y = worldXY(plan, alongIndex, leftIndex)
			if not api.engine.terrain.isValidCoordinate(api.type.Vec2f.new(x, y)) then return false end
		end
	end
	return true
end

local function largeTemplateOf(baseNames : {string}, year : integer) : string
	return templates.resolve({ name = LOG_TAG, bases = baseNames, country = false }, "", year)
end

local function copyDecorations(list : {{integer, boolean}}) : {{integer, boolean}}
	local copy : {{integer, boolean}} = {}
	for _, entry in ipairs(list or {}) do copy[#copy + 1] = { entry[1], entry[2] } end
	return copy
end

-- The decorations a template puts on a newly built street, as the ids that an edge stores.
local function defaultDecorations(template : StreetTemplate) : {{integer, boolean}}
	local result : {{integer, boolean}} = {}
	for _, entry in ipairs(template.defaultEdgeDecorations or {}) do
		local id = api.res.edgeDecorationRep.find(entry[1])
		if id >= 0 then result[#result + 1] = { id, entry[2] } end
	end
	return result
end

-- Streets along the heading first, then the streets to the left, then the streets along the heading that join existing nodes.
-- Each segment adds at most one node.
local function planSegments(blocksAlong : integer, blocksLeft : integer) : {Segment}
	local segments : {Segment} = {}
	for alongIndex = 0, blocksAlong - 1 do
		segments[#segments + 1] = { fromAlong = alongIndex, fromLeft = 0, toAlong = alongIndex + 1, toLeft = 0 }
	end
	for alongIndex = 0, blocksAlong do
		for leftIndex = 0, blocksLeft - 1 do
			segments[#segments + 1] = { fromAlong = alongIndex, fromLeft = leftIndex, toAlong = alongIndex, toLeft = leftIndex + 1 }
		end
	end
	for leftIndex = 1, blocksLeft do
		for alongIndex = 0, blocksAlong - 1 do
			segments[#segments + 1] = { fromAlong = alongIndex, fromLeft = leftIndex, toAlong = alongIndex + 1, toLeft = leftIndex }
		end
	end
	return segments
end

-- The node within the snap radius of the grid point, found now. Another mod can replace a node after a command, so no node id is kept between commands.
local function gridPoint(plan : Plan, alongIndex : integer, leftIndex : integer) : GridPoint
	local x, y = worldXY(plan, alongIndex, leftIndex)
	local nearest : number
	local nearestNode : integer
	local nodes = api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(x, y), plan.options.nodeSnapRadiusM, api.type.ComponentType.BASE_NODE)
	for _, nodeId in ipairs(nodes) do
		local position = nodePosition(nodeId)
		local squared = (position.x - x) ^ 2 + (position.y - y) ^ 2
		if nearest == nil or squared < nearest then
			nearest, nearestNode = squared, nodeId
		end
	end
	if nearestNode ~= nil then
		local position = nodePosition(nearestNode)
		return { nodeId = nearestNode, x = position.x, y = position.y, z = position.z }
	end
	return { x = x, y = y, z = api.engine.terrain.getHeightAt(api.type.Vec2f.new(x, y)) }
end

local function vec3(point : GridPoint) : Vec3f
	return api.type.Vec3f.new(point.x, point.y, point.z)
end

local function chord(from : GridPoint, to : GridPoint) : Vec3f
	return api.type.Vec3f.new(to.x - from.x, to.y - from.y, to.z - from.z)
end

local function isLarge(plan : Plan, segment : Segment) : boolean
	local runsAlong = segment.fromLeft == segment.toLeft
	local lineIndex = runsAlong and segment.fromLeft or segment.fromAlong
	local every = runsAlong and plan.options.largeEveryAlong or plan.options.largeEveryLeft
	return every > 0 and math.fmod(lineIndex, every) == 0
end

-- api.type.PlayerOwned exists in the game but not in its Teal definitions.
local function newOwner(player : integer) : Engine.Component.PlayerOwned
	local owner = ((api.type as {string : any})["PlayerOwned"] as Engine.Component.PlayerOwned).new()
	owner.player = player
	return owner
end

local function newEdge(plan : Plan, large : boolean, from : GridPoint, to : GridPoint, entity : integer) : Proposal.SegmentAndEntity
	local templateName = large and plan.largeTemplateName or plan.stripTemplateName
	local template = api.res.streetTemplateRep.get(api.res.streetTemplateRep.find(templateName))
	local edge = api.type.SegmentAndEntity.new()
	edge.entity = entity
	edge.type = SEGMENT_TYPE_STREET
	edge.comp.node0 = from.nodeId
	edge.comp.node1 = to.nodeId
	edge.comp.position0 = vec3(from)
	edge.comp.position1 = vec3(to)
	edge.comp.tangent0 = chord(from, to)
	edge.comp.tangent1 = chord(from, to)
	edge.comp.type = api.type.enum.BaseEdgeType.NORMAL
	edge.comp.typeIndex = plan.stripTypeIndex
	edge.comp.roadType = api.type.enum.RoadType.STREET
	edge.comp.roadTemplate = templateName
	edge.comp.roadStyle = template.streetStyle
	edge.comp.laneConfigs = template.laneConfigs
	edge.comp.distance = plan.stripDistance
	edge.comp.edgeDecorations = large and plan.largeDecorations or plan.stripDecorations
	if plan.ownerPlayer ~= nil then edge.playerOwned = newOwner(plan.ownerPlayer) end
	return edge
end

local function errorMessages(data : WorldBuildProposalCommandData) : string
	local messages : {string} = {}
	pcall(function()
		local list = (data.resultProposalData.errorState.messages or {}) as {string}
		for i = 1, #list do messages[#messages + 1] = tostring(list[i]) end
	end)
	return table.concat(messages, ";")
end

local function describeTemplate(name : string) : string
	local template = api.res.streetTemplateRep.get(api.res.streetTemplateRep.find(name))
	return string.format("%s simBuildable=%s crosswalk=%s country=%s", name, tostring(template.simBuildable), tostring(template.defaultWithCrosswalk), tostring(template.country))
end

-- A node config without lane connections and crosswalks: the engine then makes the default routes of the node.
local function emptyNodeConfig(node : integer) : Proposal.BaseNodeLaneConnectionAndEntity
	local config = api.type.BaseNodeLaneConnectionAndEntity.new()
	config.entity = node
	config.comp.laneConnections = {}
	config.comp.crosswalks = {}
	return config
end

local function streetSegmentsAt(node : integer) : {integer}
	return api.engine.system.streetSystem.getNodeStreetSegments(node) or {}
end

-- The grid corners that keep exactly two streets, as block indices: every corner except the one that joins the strip.
local function bendCorners(plan : Plan) : {{integer}}
	local blocksAlong, blocksLeft = plan.options.blocksAlong, plan.options.blocksLeft
	local candidates : {{integer}} = { { blocksAlong, 0 }, { 0, blocksLeft }, { blocksAlong, blocksLeft } }
	local seen : {string : boolean} = {}
	local corners : {{integer}} = {}
	for _, candidate in ipairs(candidates) do
		local key = candidate[1] .. ":" .. candidate[2]
		if (candidate[1] > 0 or candidate[2] > 0) and not seen[key] then
			seen[key] = true
			local point = gridPoint(plan, candidate[1], candidate[2])
			if point.nodeId ~= nil and #streetSegmentsAt(point.nodeId) == 2 then corners[#corners + 1] = candidate end
		end
	end
	return corners
end

-- The unit direction away from the streets of a bend. A node whose streets run straight gets the direction at a right angle to the first street.
local function outwardDirection(node : integer) : number, number
	local origin = nodePosition(node)
	local originX, originY = origin.x, origin.y
	local sumX, sumY, firstX, firstY = 0.0, 0.0, 0.0, 0.0
	for index, edgeId in ipairs(streetSegmentsAt(node)) do
		local edge = api.engine.getComponent(edgeId, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
		local far = edge.node0 == node and edge.position1 or edge.position0
		local dx, dy = far.x - originX, far.y - originY
		local length = math.sqrt(dx * dx + dy * dy)
		if index == 1 then firstX, firstY = dx / length, dy / length end
		sumX, sumY = sumX + dx / length, sumY + dy / length
	end
	local x, y = -sumX, -sumY
	local length = math.sqrt(x * x + y * y)
	if length < MIN_DIRECTION_LENGTH then x, y, length = -firstY, firstX, 1 end
	return x / length, y / length
end

-- The number of lane connections in the config of a node, or -1 when the node has no config.
local function connectionCount(node : integer) : integer
	local config = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE_CONFIG) as Engine.Component.BaseNodeConfig
	if config == nil then return -1 end
	return #(config.laneConnections or {})
end

-- A copy of the config of a node without the lane connections that touch one street, and without crosswalks, to be written in the command that removes that street. A config that still names a removed street crashes the game. Returns nil when the node has no config or the game refuses the copy.
local function nodeConfigWithout(node : integer, street : integer) : Proposal.BaseNodeLaneConnectionAndEntity, string
	local config = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE_CONFIG) as Engine.Component.BaseNodeConfig
	if config == nil then return nil, "no_config" end
	local entry = api.type.BaseNodeLaneConnectionAndEntity.new()
	entry.entity = node
	local message = ""
	local total = #(config.laneConnections or {})
	local copied = xpcall(function()
		entry.comp = config
		local kept : {LaneConnection} = {}
		for _, connection in ipairs(config.laneConnections or {}) do
			if connection.segment0 ~= street and connection.segment1 ~= street then kept[#kept + 1] = connection end
		end
		entry.comp.laneConnections = kept
		entry.comp.crosswalks = {}
	end, function(problem : any) message = tostring(problem) end)
	if not copied then return nil, message end
	return entry, #entry.comp.laneConnections .. " of " .. total
end

-- Calls onDone(true, polls) once the node has lane connections, or onDone(false, polls) after MAX_WAIT_POLLS polls. Each poll is a command with an event that no script handles, so the next check runs after the game has processed it.
local function waitForConnections(node : integer, onDone : function(boolean, integer))
	local polls = 0
	local function check()
		if connectionCount(node) > 0 then
			onDone(true, polls)
		elseif polls >= MAX_WAIT_POLLS then
			onDone(false, polls)
		else
			polls = polls + 1
			api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd(WAIT_EVENT_SOURCE, WAIT_EVENT_ID, WAIT_EVENT_NAME, {}), function() check() end)
		end
	end
	check()
end

-- A node that gets its third street has its connections made again by another mod (Smart Lanes) a moment later. Corners that keep two streets are given a short plain street for that. With laneConnections "stub_remove" the street is removed once the node has its connections. The removal writes the node config again without the connections that touch the street.
local function buildStub(plan : Plan, corner : {integer}, onFinished : function())
	local label = corner[1] .. ":" .. corner[2]
	local node = gridPoint(plan, corner[1], corner[2]).nodeId
	if node == nil then
		print(LOG_TAG, "bend_stub", label, "node_not_found")
		onFinished()
		return
	end
	local origin = nodePosition(node)
	local originX, originY, originZ = origin.x, origin.y, origin.z
	local before : {integer : boolean} = {}
	for _, edgeId in ipairs(streetSegmentsAt(node)) do before[edgeId] = true end
	local outX, outY = outwardDirection(node)
	local endX, endY = originX + outX * STUB_LENGTH_M, originY + outY * STUB_LENGTH_M
	local from : GridPoint = { nodeId = node, x = originX, y = originY, z = originZ }
	local to : GridPoint = { nodeId = TEMPORARY_ID_START - 1, x = endX, y = endY, z = api.engine.terrain.getHeightAt(api.type.Vec2f.new(endX, endY)) }
	local endNode = api.type.NodeAndEntity.new()
	endNode.entity = to.nodeId
	endNode.comp.position = vec3(to)
	local proposal = api.type.SimpleProposal.new()
	proposal.streetProposal.nodesToAdd = { endNode }
	proposal.streetProposal.edgesToAdd = { newEdge(plan, false, from, to, TEMPORARY_ID_START - 2) }
	if plan.options.explicitNodeConfigs then proposal.streetProposal.nodeConfigsToAdd = { emptyNodeConfig(to.nodeId) } end
	api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, plan.context, false, true), function(data : WorldBuildProposalCommandData, built : boolean)
		if not built then
			print(LOG_TAG, "bend_stub", label, "failed", errorMessages(data))
			onFinished()
			return
		end
		print(LOG_TAG, "bend_stub", label, "built")
		if plan.options.laneConnections ~= LANES_STUB_REMOVE then
			onFinished()
			return
		end
		local stubEdge : integer
		for _, edgeId in ipairs(streetSegmentsAt(node)) do
			if not before[edgeId] then stubEdge = edgeId end
		end
		if stubEdge == nil then
			print(LOG_TAG, "bend_stub", label, "stub_not_found")
			onFinished()
			return
		end
		local stub = api.engine.getComponent(stubEdge, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
		local stubEnd = stub.node0 == node and stub.node1 or stub.node0
		waitForConnections(node, function(ready : boolean, polls : integer)
			print(LOG_TAG, "bend_stub", label, ready and "connections_ready" or "wait_timeout", "polls", polls, "streets", #streetSegmentsAt(node), "connections", connectionCount(node))
			if not ready then
				onFinished()
				return
			end
			local keptConfig, keptCount = nodeConfigWithout(node, stubEdge)
			if keptConfig == nil then
				print(LOG_TAG, "bend_stub", label, "config_copy_failed", keptCount)
				onFinished()
				return
			end
			print(LOG_TAG, "bend_stub", label, "config_kept", keptCount)
			local removal = api.type.SimpleProposal.new()
			removal.streetProposal.edgesToRemove = { stubEdge }
			removal.streetProposal.nodesToRemove = { stubEnd }
			removal.streetProposal.nodeConfigsToRemove = { node }
			removal.streetProposal.nodeConfigsToAdd = { keptConfig }
			api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(removal, plan.context, false, true), function(removalData : WorldBuildProposalCommandData, removed : boolean)
				print(LOG_TAG, "bend_stub", label, removed and "removed" or "remove_failed", removed and "" or errorMessages(removalData))
				print(LOG_TAG, "bend_stub", label, "after", "streets", #streetSegmentsAt(node), "connections", connectionCount(node))
				onFinished()
			end)
		end)
	end)
end

local record LaneRoles
	incoming : {integer}
	outgoing : {integer}
end

-- The vehicle lanes of a street as seen from one of its end nodes, with the lane numbers that the game counts from the node: from left to right when looking from the node along the street, so the lanes that lead to the node come first. Each list starts with the lane next to the centre line and ends with the curb lane.
local function laneRoles(street : integer, node : integer) : LaneRoles
	local edge = api.engine.getComponent(street, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	local lanes = edge.laneConfigs
	local count = #lanes
	local centre = (count - 1) / 2
	local startsAtNode = edge.node0 == node
	local modes = api.type["enum"].TransportMode
	local roles : LaneRoles = { incoming = {}, outgoing = {} }
	for position = 1, count do
		local lane = lanes[position]
		if not lane.transportModes[modes.PERSON] and not lane.transportModes[modes.CARGO] then
			local number = startsAtNode and position - 1 or count - position
			local leadsToNode = lane.forward ~= startsAtNode
			local list = leadsToNode and roles.incoming or roles.outgoing
			list[#list + 1] = number
		end
	end
	local function nearerToCentre(first : integer, second : integer) : boolean
		return math.abs(first - centre) < math.abs(second - centre)
	end
	table.sort(roles.incoming, nearerToCentre)
	table.sort(roles.outgoing, nearerToCentre)
	return roles
end

-- The unit direction along a street away from one of its end nodes.
local function directionAway(street : integer, node : integer) : number, number
	local edge = api.engine.getComponent(street, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	local origin = nodePosition(node)
	local far = edge.node0 == node and edge.position1 or edge.position0
	local dx, dy = far.x - origin.x, far.y - origin.y
	local length = math.sqrt(dx * dx + dy * dy)
	return dx / length, dy / length
end

-- How a vehicle that arrives along one street leaves along another: "straight", "left", "right", or "back".
local function movementKind(fromAwayX : number, fromAwayY : number, toAwayX : number, toAwayY : number) : string
	local travelX, travelY = -fromAwayX, -fromAwayY
	local dot = travelX * toAwayX + travelY * toAwayY
	local cross = travelX * toAwayY - travelY * toAwayX
	if dot >= STRAIGHT_MIN_DOT then return MOVE_STRAIGHT end
	if dot <= -STRAIGHT_MIN_DOT then return MOVE_BACK end
	return cross > 0 and MOVE_LEFT or MOVE_RIGHT
end

-- api.type.LaneConnection exists in the game but not in its Teal definitions. The game takes only its own objects in the list of a node config.
local function newLaneConnection(from : integer, fromLane : integer, to : integer, toLane : integer) : LaneConnection
	local factory = (api.type as {string : any})["LaneConnection"] as {string : function() : LaneConnection}
	local connection = factory["new"]()
	connection.segment0 = from
	connection.lane0 = fromLane
	connection.segment1 = to
	connection.lane1 = toLane
	connection.withRoad = true
	connection.withTram = false
	return connection
end

-- The outgoing lanes of a street that the lane at a position (counted from the centre line) of a street with fromCount lanes leads to: the lane at the same position, the curb lane when the other street has fewer lanes, and a share of the lanes when it has more, so that every lane of the wider street is fed.
local function lanesInto(toRoles : LaneRoles, position : integer, fromCount : integer) : {integer}
	local toCount = #toRoles.outgoing
	local lanes : {integer} = {}
	if toCount <= fromCount then
		lanes[1] = toRoles.outgoing[math.min(position, toCount)]
	else
		for index = (position - 1) * toCount // fromCount + 1, position * toCount // fromCount do lanes[#lanes + 1] = toRoles.outgoing[index] end
	end
	return lanes
end

-- The lane connections of a node. At a node of two streets each incoming lane goes to the outgoing lane at the same position, extra lanes merge into the curb lane, and the lanes of a narrower street share the lanes of a wider one. At a crossing of more streets every lane goes straight on in the same way, except the curb lane of a street with several lanes, which only turns right. A right turn starts only in the curb lane and ends in the curb lane of the new street. A left turn starts only in the lane next to the centre line and ends in the lane next to the centre line of the new street. A street with no street straight ahead (the stem of a T) sends its outer lanes right and its inner lanes left, so that every lane has a connection. Lanes that turn the same way enter the lanes of the new street in the same order: from the curb inwards for a right turn, from the centre line outwards for a left turn.
local function nodeConnections(node : integer, streets : {integer}) : {LaneConnection}
	local roles : {LaneRoles} = {}
	local awayX : {number} = {}
	local awayY : {number} = {}
	for index, street in ipairs(streets) do
		roles[index] = laneRoles(street, node)
		awayX[index], awayY[index] = directionAway(street, node)
	end
	local connections : {LaneConnection} = {}
	for fromIndex, from in ipairs(streets) do
		local lanes = roles[fromIndex].incoming
		local laneCount = #lanes
		local kinds : {string} = {}
		local hasStraight, hasLeft, hasRight = false, false, false
		for toIndex = 1, #streets do
			if toIndex ~= fromIndex and #roles[toIndex].outgoing > 0 then
				local kind = #streets == 2 and MOVE_STRAIGHT or movementKind(awayX[fromIndex], awayY[fromIndex], awayX[toIndex], awayY[toIndex])
				kinds[toIndex] = kind
				hasStraight = hasStraight or kind == MOVE_STRAIGHT
				hasLeft = hasLeft or kind == MOVE_LEFT
				hasRight = hasRight or kind == MOVE_RIGHT
			end
		end
		for position, lane in ipairs(lanes) do
			local turnsRight : boolean
			local turnsLeft : boolean
			local rightLaneOnly = false
			if hasStraight then
				turnsRight, turnsLeft = hasRight and position == laneCount, hasLeft and position == 1
				rightLaneOnly = turnsRight and laneCount > 1
			else
				local innerHalf = laneCount == 1 or position <= laneCount // 2
				local outerHalf = laneCount == 1 or position > laneCount // 2
				turnsRight, turnsLeft = hasRight and (not hasLeft or outerHalf), hasLeft and (not hasRight or innerHalf)
			end
			for toIndex = 1, #streets do
				local kind = kinds[toIndex]
				local toRoles = roles[toIndex]
				local toLanes : {integer} = {}
				if kind == MOVE_STRAIGHT and not rightLaneOnly then toLanes = lanesInto(toRoles, position, laneCount)
				elseif kind == MOVE_RIGHT and turnsRight then toLanes = { toRoles.outgoing[math.max(#toRoles.outgoing - (laneCount - position), 1)] }
				elseif kind == MOVE_LEFT and turnsLeft then toLanes = { toRoles.outgoing[math.min(position, #toRoles.outgoing)] } end
				for _, toLane in ipairs(toLanes) do connections[#connections + 1] = newLaneConnection(from, lane, streets[toIndex], toLane) end
			end
		end
	end
	return connections
end

-- Writes the lane connections of one grid node in one command: every street into every other street. Returns "written", "failed", "refused" (the game takes no connection list) or "skipped" (fewer than two streets) to onFinished.
local function writeNodeConnections(plan : Plan, alongIndex : integer, leftIndex : integer, onFinished : function(string))
	local label = alongIndex .. ":" .. leftIndex
	local node = gridPoint(plan, alongIndex, leftIndex).nodeId
	local streets = node ~= nil and streetSegmentsAt(node) or {}
	if #streets < 2 then
		onFinished("skipped")
		return
	end
	local connections = nodeConnections(node, streets)
	local hasConfig = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE_CONFIG) ~= nil
	local entry = api.type.BaseNodeLaneConnectionAndEntity.new()
	entry.entity = node
	local message = ""
	local accepted = xpcall(function()
		entry.comp.laneConnections = connections
		entry.comp.crosswalks = {}
	end, function(problem : any) message = tostring(problem) end)
	if not accepted then
		print(LOG_TAG, "lane_connections", label, "refused", message)
		onFinished("refused")
		return
	end
	local proposal = api.type.SimpleProposal.new()
	if hasConfig then proposal.streetProposal.nodeConfigsToRemove = { node } end
	proposal.streetProposal.nodeConfigsToAdd = { entry }
	api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, plan.context, false, true), function(data : WorldBuildProposalCommandData, written : boolean)
		if not written then print(LOG_TAG, "lane_connections", label, "failed", errorMessages(data)) end
		onFinished(written and "written" or "failed")
	end)
end

-- Writes the lane connections of every grid node, one command each, and logs the counts.
local function writeAllConnections(plan : Plan)
	local nodes : {{integer}} = {}
	for alongIndex = 0, plan.options.blocksAlong do
		for leftIndex = 0, plan.options.blocksLeft do nodes[#nodes + 1] = { alongIndex, leftIndex } end
	end
	local counts : {string : integer} = { written = 0, failed = 0, refused = 0, skipped = 0 }
	local function nodeAt(index : integer)
		if index > #nodes then
			print(LOG_TAG, "lane_connections", "written", counts.written, "failed", counts.failed, "refused", counts.refused, "skipped", counts.skipped)
			print(LOG_TAG, "done", #plan.segments)
			return
		end
		writeNodeConnections(plan, nodes[index][1], nodes[index][2], function(result : string)
			counts[result] = counts[result] + 1
			nodeAt(index + 1)
		end)
	end
	nodeAt(1)
end

local function finishNodes(plan : Plan)
	local mode = plan.options.laneConnections
	if mode == LANES_OWN then
		writeAllConnections(plan)
		return
	end
	local corners : {{integer}} = {}
	if mode == LANES_STUB_REMOVE or mode == LANES_STUB_KEEP then corners = bendCorners(plan) end
	local function cornerAt(index : integer)
		if index > #corners then
			print(LOG_TAG, "done", #plan.segments)
			return
		end
		buildStub(plan, corners[index], function() cornerAt(index + 1) end)
	end
	cornerAt(1)
end

-- One command with the segments firstNumber to the last one of the batch. A node that two segments of the batch share is made once, with all its edges. A refused command is sent again with fresh nodes, up to MAX_COMMAND_ATTEMPTS times.
local function buildBatch(plan : Plan, firstNumber : integer, attempt : integer)
	local total = #plan.segments
	if firstNumber > total then
		finishNodes(plan)
		return
	end
	local perCommand = plan.options.edgesPerCommand
	local lastNumber = total
	if perCommand > 0 then lastNumber = math.min(total, firstNumber + perCommand - 1) end
	local points : {string : GridPoint} = {}
	local newNodes : {Proposal.NodeAndEntity} = {}
	local newEdges : {Proposal.SegmentAndEntity} = {}
	local newConfigs : {Proposal.BaseNodeLaneConnectionAndEntity} = {}
	local temporaryId = TEMPORARY_ID_START
	local function pointOf(alongIndex : integer, leftIndex : integer) : GridPoint
		local key = alongIndex .. ":" .. leftIndex
		local point = points[key]
		if point == nil then
			point = gridPoint(plan, alongIndex, leftIndex)
			if point.nodeId == nil then
				temporaryId = temporaryId - 1
				local node = api.type.NodeAndEntity.new()
				node.entity = temporaryId
				node.comp.position = vec3(point)
				newNodes[#newNodes + 1] = node
				point.nodeId = temporaryId
				if plan.options.explicitNodeConfigs then newConfigs[#newConfigs + 1] = emptyNodeConfig(temporaryId) end
			end
			points[key] = point
		end
		return point
	end
	local largeCount = 0
	for number = firstNumber, lastNumber do
		local segment = plan.segments[number]
		local from = pointOf(segment.fromAlong, segment.fromLeft)
		local to = pointOf(segment.toAlong, segment.toLeft)
		temporaryId = temporaryId - 1
		newEdges[#newEdges + 1] = newEdge(plan, isLarge(plan, segment), from, to, temporaryId)
		if isLarge(plan, segment) then largeCount = largeCount + 1 end
	end
	local proposal = api.type.SimpleProposal.new()
	proposal.streetProposal.nodesToAdd = newNodes
	proposal.streetProposal.edgesToAdd = newEdges
	if #newConfigs > 0 then proposal.streetProposal.nodeConfigsToAdd = newConfigs end
	api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(proposal, plan.context, false, true), function(data : WorldBuildProposalCommandData, success : boolean)
		if success then
			print(LOG_TAG, "built", firstNumber, lastNumber, "large", largeCount)
			buildBatch(plan, lastNumber + 1, 1)
		elseif attempt < MAX_COMMAND_ATTEMPTS then
			print(LOG_TAG, "retry", firstNumber, lastNumber, "attempt", attempt, errorMessages(data))
			buildBatch(plan, firstNumber, attempt + 1)
		else
			print(LOG_TAG, "failed_at", firstNumber, lastNumber, "of", total, errorMessages(data))
		end
	end)
end

local function newPlan(options : RubGridOptions) : Plan, integer, number
	local stripId, cameraDistance = findStrip(options.cameraSearchRadiusM)
	local strip = api.engine.getComponent(stripId, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	local frame = stripFrame(strip, options.flipStripDirection, options.buildToRight)
	local stripTemplateName = strip.roadTemplate
	local stripTypeIndex = strip.typeIndex
	local stripDistance = strip.distance
	local stripDecorations = copyDecorations(strip.edgeDecorations)
	local owned = api.engine.getComponent(stripId, api.type.ComponentType.PLAYER_OWNED) as Engine.Component.PlayerOwned
	local largeName = largeTemplateOf(options.largeStreetBaseNames, api.engine.util.getYear())
	assert(largeName ~= nil, LOG_TAG .. " no_large_template_for_year")
	local largeTemplate = api.res.streetTemplateRep.get(api.res.streetTemplateRep.find(largeName))
	local context = api.type.Context.new()
	context.player = api.engine.util.getPlayer()
	context.checkTerrainAlignment = true
	context.gatherFields = true
	local plan : Plan = {
		options = options,
		frame = frame,
		stripTemplateName = stripTemplateName,
		stripTypeIndex = stripTypeIndex,
		stripDistance = stripDistance,
		stripDecorations = stripDecorations,
		largeTemplateName = largeName,
		largeDecorations = defaultDecorations(largeTemplate),
		ownerPlayer = owned ~= nil and owned.player or nil,
		context = context,
		segments = planSegments(options.blocksAlong, options.blocksLeft),
	}
	return plan, stripId, cameraDistance
end

function gridBuilder.build(options : RubGridOptions)
	local plan, stripId, cameraDistance = newPlan(withDefaults(options))
	local fits = gridFitsMap(plan)
	print(LOG_TAG, "strip", stripId, "camera_distance", rounded(cameraDistance), "corner", rounded(plan.frame.originX), rounded(plan.frame.originY),
		"heading", rounded(plan.frame.forwardX), rounded(plan.frame.forwardY), "segments", #plan.segments, "blocks", plan.options.blocksAlong, plan.options.blocksLeft, "side", plan.options.buildToRight and "right" or "left", "fits_map", tostring(fits), "build", BUILD_MARK)
	print(LOG_TAG, "templates", describeTemplate(plan.stripTemplateName), describeTemplate(plan.largeTemplateName))
	if fits then buildBatch(plan, 1, 1) end
end

-- The most vehicle lanes that the street has in one direction. Pedestrian lanes do not count.
local function lanesPerDirection(street : integer) : integer
	local edge = api.engine.getComponent(street, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	local forward, backward = 0, 0
	for _, lane in ipairs(edge.laneConfigs) do
		if not lane.transportModes[api.type.enum.TransportMode.PERSON] then
			if lane.forward then forward = forward + 1 else backward = backward + 1 end
		end
	end
	return math.max(forward, backward)
end

-- A junction of at least 3 streets that joins a street with several lanes per direction to a street with one, and has no street of another player.
local function isMajorMinorJunction(streets : {integer}, player : integer) : boolean
	if #streets < MIN_STREETS_AT_JUNCTION then return false end
	local hasMajor, hasMinor = false, false
	for _, street in ipairs(streets) do
		local owner = api.engine.getComponent(street, api.type.ComponentType.PLAYER_OWNED) as Engine.Component.PlayerOwned
		if owner ~= nil and owner.player ~= player then return false end
		local lanes = lanesPerDirection(street)
		if lanes > 1 then hasMajor = true elseif lanes == 1 then hasMinor = true end
	end
	return hasMajor and hasMinor
end

-- A major-minor junction that has a traffic light and no preference "no" yet.
local function hasRemovableLight(node : integer, streets : {integer}, player : integer) : boolean
	if not isMajorMinorJunction(streets, player) then return false end
	if api.engine.getComponent(node, api.type.ComponentType.BASE_NODE_TRAFFIC_LIGHT) == nil then return false end
	local config = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE_CONFIG) as Engine.Component.BaseNodeConfig
	return config == nil or config.trafficLightPreference ~= api.type.enum.TrafficLightPreference.NO
end

local function nodesWhere(accepts : function(node : integer, streets : {integer}, player : integer) : boolean) : {integer}
	local player = api.engine.util.getPlayer()
	local nodes : {integer} = {}
	for node, streets in pairs(api.engine.system.streetSystem.getNode2StreetEdgeMap()) do
		if accepts(node, streets, player) then nodes[#nodes + 1] = node end
	end
	table.sort(nodes)
	return nodes
end

-- One command per entity, each sent in the callback of the previous one. makeCommand returns nil and a reason for an entity that needs no command. onDone, when given, runs after the last command finished and the end line is logged. `countName` names the entities in the end line.
local function sendPerNode(tag : string, nodes : {integer}, makeCommand : function(node : integer) : Command<WorldBuildProposalCommandData>, string, onDone : function(), countName? : string)
	local changed, skipped, failed = 0, 0, 0
	local function sendFrom(index : integer)
		while index <= #nodes do
			local node = nodes[index]
			local command, reason = makeCommand(node)
			if command ~= nil then
				api.cmd.sendCommand(command, function(data : WorldBuildProposalCommandData, success : boolean)
					if success then
						changed = changed + 1
					else
						failed = failed + 1
						print(LOG_TAG, tag .. "_failed", node, errorMessages(data))
					end
					sendFrom(index + 1)
				end)
				return
			end
			skipped = skipped + 1
			print(LOG_TAG, tag .. "_skipped", node, reason)
			index = index + 1
		end
		print(LOG_TAG, tag .. "_done", countName or "nodes", #nodes, "changed", changed, "skipped", skipped, "failed", failed)
		if onDone ~= nil then onDone() end
	end
	sendFrom(1)
end

-- Sets the traffic light preference "no" on every node that hasRemovableLight accepts.
local function startRemoveLights(onDone : function())
	sendPerNode("lights", nodesWhere(hasRemovableLight), function(node : integer) : Command<WorldBuildProposalCommandData>, string
		local config = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE_CONFIG) as Engine.Component.BaseNodeConfig
		local lightConfig = config ~= nil and config.trafficLightConfig or api.type.TrafficLightConfig.new()
		local proposal = api.engine.util.proposal.createTrafficLightProposal(node, lightConfig, api.type.enum.TrafficLightPreference.NO)
		return api.cmd.makeWorldBuildProposalCmd(proposal, nil, false, false), nil
	end, onDone)
end

-- A street seen from a node. Lane positions count from 0, from left to right when looking from the node along the street. That is the order of laneConfigs when the street starts at the node, and the reverse order when it ends there. Traffic keeps to the right.
local record Approach
	startsAtNode : boolean
	lanes : {LaneConfig}
	awayX : number
	awayY : number
	incomingOuter : {string : integer}
	outgoingOuter : {string : integer}
end

local function laneKind(lane : LaneConfig) : string
	local modes = lane.transportModes
	if modes[api.type.enum.TransportMode.BUS] and not modes[api.type.enum.TransportMode.CAR] then return KIND_BUS end
	return KIND_NORMAL
end

local function approachOf(street : integer, node : integer) : Approach
	local edge = api.engine.getComponent(street, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
	local startsAtNode = edge.node0 == node
	local tangent = startsAtNode and edge.tangent0 or edge.tangent1
	local sign = startsAtNode and 1 or -1
	local count = #edge.laneConfigs
	local approach : Approach = { startsAtNode = startsAtNode, lanes = {}, awayX = sign * tangent.x, awayY = sign * tangent.y, incomingOuter = {}, outgoingOuter = {} }
	for position = 1, count do
		local lane = edge.laneConfigs[startsAtNode and position or count + 1 - position]
		approach.lanes[position] = lane
		if not lane.transportModes[api.type.enum.TransportMode.PERSON] then
			local kind = laneKind(lane)
			if lane.forward == startsAtNode then
				approach.outgoingOuter[kind] = position - 1
			elseif approach.incomingOuter[kind] == nil then
				approach.incomingOuter[kind] = position - 1
			end
		end
	end
	return approach
end

-- The two lanes of a road connection, or nil when the lane positions of the connection do not fit the lanes of the streets: a lane missing, a pedestrian lane, or a lane in the wrong direction.
local function connectionLanes(connection : LaneConnection, approaches : {integer : Approach}) : LaneConfig, LaneConfig
	local from, to = approaches[connection.segment0], approaches[connection.segment1]
	if from == nil or to == nil then return nil, nil end
	local inLane, outLane = from.lanes[connection.lane0 + 1], to.lanes[connection.lane1 + 1]
	if inLane == nil or outLane == nil then return nil, nil end
	if inLane.transportModes[api.type.enum.TransportMode.PERSON] or outLane.transportModes[api.type.enum.TransportMode.PERSON] then return nil, nil end
	if inLane.forward == from.startsAtNode or outLane.forward ~= to.startsAtNode then return nil, nil end
	return inLane, outLane
end

-- The turn from one street into another. Two streets that are the only major streets of the node count as straight, however sharply they bend at the node.
local function turnBetween(from : integer, to : integer, approaches : {integer : Approach}, bothOnlyMajor : boolean) : string
	if from == to then return TURN_U end
	if bothOnlyMajor then return TURN_STRAIGHT end
	local a, b = approaches[from], approaches[to]
	local inX, inY = -a.awayX, -a.awayY
	local angle = math.atan(inX * b.awayY - inY * b.awayX, inX * b.awayX + inY * b.awayY)
	if math.abs(angle) <= STRAIGHT_LIMIT_RAD then return TURN_STRAIGHT end
	return angle > 0 and TURN_LEFT or TURN_RIGHT
end

-- Left turns go. U-turns stay. A straight connection stays between lanes of one kind. A right turn stays from the outer lane of a kind to the outer lane of the same kind.
local function keepsConnection(connection : LaneConnection, inLane : LaneConfig, outLane : LaneConfig, from : Approach, to : Approach, turn : string) : boolean
	if turn == TURN_U then return true end
	if turn == TURN_LEFT then return false end
	local kind = laneKind(inLane)
	if kind ~= laneKind(outLane) then return false end
	if turn == TURN_STRAIGHT then return true end
	return connection.lane0 == from.incomingOuter[kind] and connection.lane1 == to.outgoingOuter[kind]
end

-- A copy of the node config with the given lane connections. Returns nil and the message when the game refuses the copy.
local function configWithConnections(node : integer, config : Engine.Component.BaseNodeConfig, kept : {LaneConnection}) : Proposal.BaseNodeLaneConnectionAndEntity, string
	local entry = api.type.BaseNodeLaneConnectionAndEntity.new()
	entry.entity = node
	local message = ""
	local copied = xpcall(function()
		entry.comp = config
		entry.comp.laneConnections = kept
	end, function(problem : any) message = tostring(problem) end)
	if not copied then return nil, message end
	return entry, nil
end

-- The node config without the connections that the rules of keepsConnection remove, and the text "kept of total". Returns nil and a reason when the node stays as it is.
local function leftTurnFreeConfig(node : integer) : Proposal.BaseNodeLaneConnectionAndEntity, string
	if api.engine.getComponent(node, api.type.ComponentType.BASE_NODE_TRAFFIC_LIGHT) ~= nil then return nil, "has_traffic_light" end
	local config = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE_CONFIG) as Engine.Component.BaseNodeConfig
	if config == nil then return nil, "no_config" end
	local approaches : {integer : Approach} = {}
	local majors : {integer : boolean} = {}
	local majorCount = 0
	for _, street in ipairs(streetSegmentsAt(node)) do
		approaches[street] = approachOf(street, node)
		if lanesPerDirection(street) > 1 then
			majors[street] = true
			majorCount = majorCount + 1
		end
	end
	local connections = config.laneConnections or {}
	local kept : {LaneConnection} = {}
	for _, connection in ipairs(connections) do
		if connection.withRoad then
			local inLane, outLane = connectionLanes(connection, approaches)
			if inLane == nil then return nil, "lane_mismatch" end
			local bothOnlyMajor = majorCount == 2 and majors[connection.segment0] == true and majors[connection.segment1] == true
			local turn = turnBetween(connection.segment0, connection.segment1, approaches, bothOnlyMajor)
			if keepsConnection(connection, inLane, outLane, approaches[connection.segment0], approaches[connection.segment1], turn) then kept[#kept + 1] = connection end
		else
			kept[#kept + 1] = connection
		end
	end
	if #kept == #connections then return nil, "unchanged" end
	local entry, message = configWithConnections(node, config, kept)
	if entry == nil then return nil, "config_copy_failed " .. message end
	return entry, #kept .. " of " .. #connections
end

-- Rewrites the lane connections of every major-minor junction: no left turns, straight only between lanes of one kind (bus or normal), right turns only from the outer lane to the outer lane of one kind. A junction with a traffic light is skipped, because its light phases refer to the connections by position.
local function startRemoveLeftTurns(onDone : function())
	local context = api.type.Context.new()
	context.player = api.engine.util.getPlayer()
	local nodes = nodesWhere(function(_node : integer, streets : {integer}, player : integer) : boolean return isMajorMinorJunction(streets, player) end)
	sendPerNode("turns", nodes, function(node : integer) : Command<WorldBuildProposalCommandData>, string
		local entry, detail = leftTurnFreeConfig(node)
		if entry == nil then return nil, detail end
		print(LOG_TAG, "turns_node", node, "kept", detail)
		local proposal = api.type.SimpleProposal.new()
		proposal.streetProposal.nodeConfigsToRemove = { node }
		proposal.streetProposal.nodeConfigsToAdd = { entry }
		return api.cmd.makeWorldBuildProposalCmd(proposal, context, false, true), nil
	end, onDone)
end

-- A small road template of the four base names or one of their variants (trees, barriers, bus, tram).
local function isSmallRoadTemplate(template : string) : boolean
	if template == nil then return false end
	local name = templates.baseName(template)
	for _, base in ipairs(SMALL_ROAD_BASES) do
		if name == base or string.sub(name, 1, #base + 1) == base .. "_" then return true end
	end
	return false
end

local function hasOtherLaneSpeed(lanes : {LaneConfig}, speed : number) : boolean
	for _, lane in ipairs(lanes) do
		if math.abs(lane.speed - speed) > SPEED_TOLERANCE_MS then return true end
	end
	return false
end

-- The small roads of the player or of nobody that no construction owns, sorted. Returns the ones with a lane at another speed than `speed` and the number of all of them.
local function smallRoadsNotAt(speed : number) : {integer}, integer
	local player = api.engine.util.getPlayer()
	local seen : {integer : boolean} = {}
	local different : {integer} = {}
	local total = 0
	for _, streets in pairs(api.engine.system.streetSystem.getNode2StreetEdgeMap()) do
		for _, street in ipairs(streets) do
			if not seen[street] then
				seen[street] = true
				local edge = api.engine.getComponent(street, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
				local owner = api.engine.getComponent(street, api.type.ComponentType.PLAYER_OWNED) as Engine.Component.PlayerOwned
				local okC, construction = pcall(api.engine.system.streetConnectorSystem.getConstructionEntityForEdge, street)
				local foreign = owner ~= nil and owner.player ~= nil and owner.player >= 0 and owner.player ~= player
				local inConstruction = not okC or (construction ~= nil and construction >= 0)
				if edge ~= nil and isSmallRoadTemplate(edge.roadTemplate) and not foreign and not inConstruction then
					total = total + 1
					if hasOtherLaneSpeed(edge.laneConfigs, speed) then different[#different + 1] = street end
				end
			end
		end
	end
	table.sort(different)
	return different, total
end

-- The proposal that replaces the road with its own template, every lane of the new segment at `speed`. The getters may hand out copies, so the edit is written back at every level and read back. nil and a reason when the new segment would lose edge objects (signals, stops) or does not keep the speed.
local function speedProposal(road : integer, edge : Engine.Component.BaseEdge, speed : number) : Proposal, string
	local ok, proposal = pcall(api.engine.util.proposal.replaceSegment, road, edge.roadTemplate)
	if not ok or proposal == nil then return nil, "replace_segment_failed " .. tostring(proposal) end
	local street = proposal.proposal
	local segments = street.addedSegments
	for _, segment in ipairs(segments) do
		local comp = segment.comp
		local lanes = comp.laneConfigs
		for i, lane in ipairs(lanes) do
			lane.speed = speed
			lanes[i] = lane
		end
		comp.laneConfigs = lanes
		segment.comp = comp
	end
	street.addedSegments = segments
	proposal.proposal = street
	local readBack = proposal.proposal.addedSegments
	if #readBack == 0 then return nil, "no_new_segment" end
	for _, segment in ipairs(readBack) do
		if hasOtherLaneSpeed(segment.comp.laneConfigs, speed) then return nil, "speed_not_kept" end
	end
	if #(readBack[1].comp.objects or {}) < #(edge.objects or {}) then return nil, "objects_lost" end
	return proposal, nil
end

-- Sets the speed of every lane of every small road, one replacement command per road. The end line `speed_check` counts the small roads that still have another speed: a count above 0 after a run without failed commands means the game did not keep the speed.
local function startSetSmallRoadSpeed(kmh : number, onDone : function())
	local speed = kmh / KMH_PER_MS
	local context = api.type.Context.new()
	context.player = api.engine.util.getPlayer()
	local roads, total = smallRoadsNotAt(speed)
	print(LOG_TAG, "speed_start", "kmh", kmh, "ms", rounded(speed), "small_roads", total, "to_change", #roads)
	sendPerNode("speed", roads, function(road : integer) : Command<WorldBuildProposalCommandData>, string
		local edge = api.engine.getComponent(road, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
		if edge == nil then return nil, "gone" end
		local proposal, reason = speedProposal(road, edge, speed)
		if proposal == nil then return nil, reason end
		return api.cmd.makeWorldBuildProposalCmd(proposal, context, false, true), nil
	end, function()
		local remaining, count = smallRoadsNotAt(speed)
		print(LOG_TAG, "speed_check", "small_roads", count, "other_speed", #remaining)
		if onDone ~= nil then onDone() end
	end, "roads")
end

function gridBuilder.setSmallRoadSpeed(kmh? : number)
	local wanted = kmh or DEFAULT_SMALL_ROAD_KMH
	if wanted <= 0 then error("kmh_must_be_positive") end
	startSetSmallRoadSpeed(wanted, nil)
end

function gridBuilder.removeLights()
	startRemoveLights(nil)
end

function gridBuilder.removeLeftTurns()
	startRemoveLeftTurns(nil)
end

-- Runs removeLights, then removeLeftTurns after the last light command finished.
function gridBuilder.removeLightsAndLeftTurns()
	startRemoveLights(function() startRemoveLeftTurns(nil) end)
end

return gridBuilder
