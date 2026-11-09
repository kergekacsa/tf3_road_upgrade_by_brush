-- The crosswalk pass of a press: the junctions that upgraded roads touched get a crosswalk on every street, after the press, once
-- the jobs of other mods (Smart Lanes rewrites the config of a changed junction some time after a build) have finished. A round
-- sends the command of every junction that still lacks crosswalks, then waits once and reads all of them back; the junctions that
-- are incomplete go into the next round. The pass reaches the game only through `env` and `node_crosswalks`. It keeps no state
-- outside the state object that `new` returns, and it creates no global variable.

local nodeCrosswalks = ug_require "kacsa_road_upgrade_brush::/road_upgrade_brush/node_crosswalks.tl" as RubNodeCrosswalks

local crosswalkPass : RubCrosswalkPass = {}

-- Seconds. Smart Lanes handles its queued junctions within this time, so the first command and every new round wait for it.
local CROSSWALK_SETTLE_SECONDS <const> = 2.0
-- Seconds between the last command of a round and the read back of its junctions.
local CROSSWALK_VERIFY_SECONDS <const> = 1.0
local CROSSWALK_ATTEMPTS <const> = 3
-- Same meaning as in rub_grid_builder.tl: fewer street segments are no junction.
local MIN_STREETS_FOR_CROSSWALKS <const> = 3
-- Metres to one decimal: touched nodes at the same rounded position are one node.
local POSITION_KEY_FORMAT <const> = "%.1f,%.1f"

crosswalkPass.CROSSWALK_SETTLE_SECONDS = CROSSWALK_SETTLE_SECONDS
crosswalkPass.CROSSWALK_VERIFY_SECONDS = CROSSWALK_VERIFY_SECONDS
crosswalkPass.CROSSWALK_ATTEMPTS = CROSSWALK_ATTEMPTS
crosswalkPass.MIN_STREETS_FOR_CROSSWALKS = MIN_STREETS_FOR_CROSSWALKS

local record Tally
	touched : integer
	complete : integer
	incomplete : integer
	skipped : integer
end

-- A junction that is waiting for its crosswalks: the commands sent so far.
local record Junction
	spot : RubNodeSpot
	node : integer
	sends : integer
end

local function prepareRoads(self : RubCrosswalkPassState, edges : {integer})
	for _, edge in ipairs(edges) do self.ends[edge] = nodeCrosswalks.endSpots(edge) end
end

local function touchSpot(self : RubCrosswalkPassState, spot : RubNodeSpot)
	local key = string.format(POSITION_KEY_FORMAT, spot.x, spot.y)
	if self.seen[key] then return end
	self.seen[key] = true
	self.spots[#self.spots + 1] = spot
end

local function touchRoad(self : RubCrosswalkPassState, edge : integer)
	for _, spot in ipairs(self.ends[edge] or {}) do touchSpot(self, spot) end
end

local function unfinished(self : RubCrosswalkPassState) : integer
	if not self.running then return 0 end
	return #self.spots - self.settled
end

local function missingStreets(view : RubNodeView) : {integer}
	local present : {integer : boolean} = {}
	for _, crosswalk in ipairs(view.crosswalks) do present[crosswalk] = true end
	local missing : {integer} = {}
	for _, street in ipairs(view.streets) do
		if not present[street] then missing[#missing + 1] = street end
	end
	return missing
end

local function idsText(ids : {integer}) : string
	local parts : {string} = {}
	for i, id in ipairs(ids) do parts[i] = tostring(id) end
	return table.concat(parts, ", ")
end

local function answerLine(env : RubCrosswalkEnv, node : integer, success : boolean, text : string)
	env.log(string.format("crosswalks: node %d: game answer %s%s", node, success and "ok" or "failed", text ~= "" and (": " .. text) or ""),
		success and "upgrade" or "failure")
end

-- One round of commands for the node: the command for every street and, when the game refuses it, ONE command for the streets with
-- a pedestrian lane. `afterRound` runs after the last answer.
local function sendRound(env : RubCrosswalkEnv, command : Command<WorldBuildProposalCommandData>, node : integer, afterRound : function())
	env.send(command, function(accepted : boolean, text : string)
		answerLine(env, node, accepted, text)
		if accepted then
			afterRound()
			return
		end
		local second, detail = nodeCrosswalks.commandSidewalk(node, env.context())
		env.log(string.format("crosswalks: node %d: sidewalk streets only: %s", node, detail), "upgrade")
		if second == nil then
			afterRound()
			return
		end
		env.send(second, function(acceptedSecond : boolean, textSecond : string)
			answerLine(env, node, acceptedSecond, textSecond)
			afterRound()
		end)
	end)
end

local function runPass(self : RubCrosswalkPassState, env : RubCrosswalkEnv, onDone : function())
	local tally : Tally = { touched = #self.spots, complete = 0, incomplete = 0, skipped = 0 }
	local finished = false
	self.settled = 0
	local function markSettled()
		self.settled = self.settled + 1
		env.progress(self.settled, tally.touched)
	end
	local function skipped(node : integer, why : string)
		env.log(string.format("crosswalks: node %d: %s", node, why), "upgrade")
		tally.skipped = tally.skipped + 1
		markSettled()
	end
	local function complete(node : integer, sends : integer, streets : integer)
		env.log(string.format("crosswalks: node %d: complete after %d sends (%d streets)", node, sends, streets), "upgrade")
		tally.complete = tally.complete + 1
		markSettled()
	end
	local function incomplete(node : integer, sends : integer, missing : {integer})
		env.log(string.format("crosswalks: node %d: INCOMPLETE after %d sends, missing streets [%s]", node, sends, idsText(missing)), "failure")
		tally.incomplete = tally.incomplete + 1
		markSettled()
	end
	local function done()
		if finished then return end
		finished = true
		self.running = false
		local left = tally.touched - self.settled
		env.log(string.format("crosswalks: pass done: %d junctions touched, %d complete, %d incomplete, %d skipped%s",
			tally.touched, tally.complete, tally.incomplete, tally.skipped, left > 0 and string.format(", %d not reached", left) or ""), "upgrade")
		onDone()
	end

	-- The read back of the junctions that got a command: the complete ones are settled, the others return for the next round.
	local round : function({Junction})
	local function verify(sent : {Junction})
		env.wait(CROSSWALK_VERIFY_SECONDS, function()
			local again : {Junction} = {}
			for _, junction in ipairs(sent) do
				local node, summary, items = nodeCrosswalks.readBack(junction.spot)
				env.log(string.format("crosswalks: node %d: read back%s %s", node, junction.sends > 1 and " again" or "", summary), "upgrade")
				local now = nodeCrosswalks.inspect(junction.spot)
				local missing = missingStreets(now)
				if #missing == 0 and now.readable then
					complete(junction.node, junction.sends, #now.streets)
				else
					for _, item in ipairs(items) do env.log(string.format("crosswalks: node %d: %s", node, item), "upgrade") end
					if junction.sends >= CROSSWALK_ATTEMPTS then
						incomplete(junction.node, junction.sends, missing)
					else
						again[#again + 1] = junction
					end
				end
			end
			if #again == 0 then
				done()
				return
			end
			env.wait(CROSSWALK_SETTLE_SECONDS, function() round(again) end)
		end)
	end

	round = function(list : {Junction})
		local sent : {Junction} = {}
		local function step(i : integer)
			while i <= #list do
				if env.cancelled() then
					done()
					return
				end
				local junction = list[i]
				local command, detail, node = nodeCrosswalks.commandAt(junction.spot, env.context(), true)
				if command == nil and detail == "unchanged" then
					complete(node, junction.sends, #nodeCrosswalks.inspect(junction.spot).streets)
				elseif command == nil then
					skipped(node, detail)
				else
					env.log(string.format("crosswalks: node %d: %s", node, detail), "upgrade")
					junction.node = node
					sent[#sent + 1] = junction
					sendRound(env, command, node, function()
						junction.sends = junction.sends + 1
						step(i + 1)
					end)
					return
				end
				i = i + 1
			end
			if #sent == 0 then
				done()
				return
			end
			verify(sent)
		end
		step(1)
	end

	local anyJunction = false
	for _, spot in ipairs(self.spots) do
		local view = nodeCrosswalks.inspect(spot)
		if view.found and #view.streets >= MIN_STREETS_FOR_CROSSWALKS then
			anyJunction = true
			break
		end
	end
	if not anyJunction then
		finished = true
		if #self.spots > 0 then env.log(string.format("crosswalks: pass skipped, none of the %d touched nodes is a junction", #self.spots), "upgrade") end
		onDone()
		return
	end
	self.running = true
	env.log(string.format("crosswalks: pass start: %d touched nodes", tally.touched), "upgrade")
	env.progress(0, tally.touched)
	env.wait(CROSSWALK_SETTLE_SECONDS, function()
		local junctions : {Junction} = {}
		for _, spot in ipairs(self.spots) do
			local view = nodeCrosswalks.inspect(spot)
			if not view.found then
				skipped(spot.node, "node_not_found")
			elseif #view.streets < MIN_STREETS_FOR_CROSSWALKS then
				skipped(view.node, string.format("not_a_junction (%d streets)", #view.streets))
			else
				junctions[#junctions + 1] = { spot = spot, node = view.node, sends = 0 }
			end
		end
		round(junctions)
	end)
end

function crosswalkPass.new() : RubCrosswalkPassState
	return {
		spots = {}, seen = {}, ends = {}, settled = 0, running = false,
		prepare = prepareRoads, touch = touchSpot, touchRoad = touchRoad, run = runPass, unfinished = unfinished,
	}
end

return crosswalkPass
