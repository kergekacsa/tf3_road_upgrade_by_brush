-- Debug console only: the console loads this module with ug_require and calls `build(options)`. Nothing else loads it, and it sets no global variable.
-- The grid is built one street segment per command. A command starts in the callback of the previous one.
-- Lengths are in metres. The positions of a grid are counted in blocks from the end of the strip.

local templates = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/rub_templates.tl" as RubTemplates

local gridBuilder : RubGridBuilderModule = {}

local LOG_TAG <const> = "[BrushUpgrade] [grid]"
local BUILD_MARK <const> = "2026-11-02 sixblocks"
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
local STUB_REMOVE <const> = "remove"
local STUB_KEEP <const> = "keep"
local STUB_OFF <const> = "off"

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

local function withDefaults(options : RubGridOptions) : RubGridOptions
	local given : RubGridOptions = options or {}
	local largeEveryAlong = given.largeEveryAlong or DEFAULT_LARGE_EVERY_ALONG
	local largeEveryLeft = given.largeEveryLeft or DEFAULT_LARGE_EVERY_LEFT
	local explicitNodeConfigs = given.explicitNodeConfigs
	if explicitNodeConfigs == nil then explicitNodeConfigs = largeEveryAlong > 0 or largeEveryLeft > 0 end
	return {
		blocksAlong = given.blocksAlong or DEFAULT_BLOCKS_ALONG,
		blocksLeft = given.blocksLeft or DEFAULT_BLOCKS_LEFT,
		blockLengthAlongM = given.blockLengthAlongM or DEFAULT_BLOCK_LENGTH_ALONG_M,
		blockLengthLeftM = given.blockLengthLeftM or DEFAULT_BLOCK_LENGTH_LEFT_M,
		flipStripDirection = given.flipStripDirection or false,
		cameraSearchRadiusM = given.cameraSearchRadiusM or DEFAULT_CAMERA_SEARCH_RADIUS_M,
		nodeSnapRadiusM = given.nodeSnapRadiusM or DEFAULT_NODE_SNAP_RADIUS_M,
		largeEveryAlong = largeEveryAlong,
		largeEveryLeft = largeEveryLeft,
		largeStreetBaseNames = given.largeStreetBaseNames or DEFAULT_LARGE_BASE_NAMES,
		edgesPerCommand = given.edgesPerCommand or DEFAULT_EDGES_PER_COMMAND,
		explicitNodeConfigs = explicitNodeConfigs,
		bendStubs = given.bendStubs or (explicitNodeConfigs and STUB_REMOVE or STUB_OFF),
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
local function stripFrame(strip : Engine.Component.BaseEdge, flip : boolean) : Frame
	local first, last = nodePosition(strip.node0), nodePosition(strip.node1)
	if flip then first, last = last, first end
	local dx, dy = last.x - first.x, last.y - first.y
	local length = math.sqrt(dx * dx + dy * dy)
	local forwardX, forwardY = dx / length, dy / length
	return { originX = last.x, originY = last.y, forwardX = forwardX, forwardY = forwardY, leftX = -forwardY, leftY = forwardX }
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

-- A node that gets its third street has its connections made again by another mod (Smart Lanes) a moment later. Corners that keep two streets are given a short plain street for that. With bendStubs "remove" the street is removed once the node has its connections. The removal writes the node config again without the connections that touch the street.
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
		if plan.options.bendStubs ~= STUB_REMOVE then
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

local function finishBends(plan : Plan)
	local stubs = plan.options.bendStubs == STUB_REMOVE or plan.options.bendStubs == STUB_KEEP
	local corners : {{integer}} = {}
	if stubs then corners = bendCorners(plan) end
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
		finishBends(plan)
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
	local frame = stripFrame(strip, options.flipStripDirection)
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
		"heading", rounded(plan.frame.forwardX), rounded(plan.frame.forwardY), "segments", #plan.segments, "fits_map", tostring(fits), "build", BUILD_MARK)
	print(LOG_TAG, "templates", describeTemplate(plan.stripTemplateName), describeTemplate(plan.largeTemplateName))
	if fits then buildBatch(plan, 1, 1) end
end

return gridBuilder
