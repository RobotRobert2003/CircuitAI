-- Playtest watcher: every land gantry of every team, and the construction turrets around it.
-- For each gantry: the team's metal income when it was placed (now and the 10 s minimum), the
-- finished turrets in reach when it was placed and when it finished, each change of that count
-- (so the time the planned complement was reached can be read afterwards), and the time each unit
-- it produces takes. Every line is "[GantryNano] ...". Roles come from the run's teams.json.
--
-- Staged by: playtest.py run --extra-widget tools/playtest/widgets/gantry_nano_watch.lua
-- Cost: one GetUnitsInCylinder per tracked gantry per second, one GetTeamResources per team per second.

function widget:GetInfo()
	return {
		name    = "BARb gantry nano watch",
		desc    = "tools/playtest: every gantry's turrets at placement and finish, and its T3 production times",
		author  = "s3k-CircuitAI",
		date    = "2026-10-26",
		layer   = 10,
		enabled = true,
	}
end

local FPS = 30
local GANTRIES = { armshltx = true, corgant = true, leggant = true }
local REACH_PAD = 110          -- a gantry's footprint radius, roughly, added to each turret's build distance
local TRACK_AFTER = 600 * FPS  -- keep counting turrets this long after a gantry finishes
local WINDOW = 10              -- seconds of income kept per team

local nanoDefs = {}            -- static builders: T1 and T2 construction turrets
local maxReach = 0
for id, ud in pairs(UnitDefs) do
	if ud.isBuilder and not ud.canMove and not ud.isFactory and (ud.buildSpeed or 0) > 0 then
		nanoDefs[id] = ud
		maxReach = math.max(maxReach, (ud.buildDistance or 0) + REACH_PAD)
	end
end

local gantries = {}            -- unitID -> record
local products = {}            -- unitID -> { gantry, frame, name }
local income = {}              -- teamID -> ring of the last WINDOW per-second incomes

local function echo(s) Spring.Echo("[GantryNano] " .. s) end
local function clock(n) return string.format("%d:%02d", math.floor(n / (60 * FPS)), math.floor(n / FPS) % 60) end

local function minIncome(team)
	local ring = income[team]
	if not ring or #ring == 0 then return 0 end
	local m = math.huge
	for i = 1, #ring do m = math.min(m, ring[i]) end
	return m
end

-- finished turrets and turret frames of the gantry's team within reach of it
local function count(g)
	local done, frames, bp = 0, 0, 0
	for _, u in ipairs(Spring.GetUnitsInCylinder(g.x, g.z, maxReach, g.team) or {}) do
		local ud = nanoDefs[Spring.GetUnitDefID(u) or -1]
		if ud then
			local x, _, z = Spring.GetUnitPosition(u)
			local reach = (ud.buildDistance or 0) + REACH_PAD
			if x and (x - g.x) ^ 2 + (z - g.z) ^ 2 <= reach * reach then
				local _, _, _, _, progress = Spring.GetUnitHealth(u)
				if (progress or 0) >= 1 then done = done + 1; bp = bp + (ud.buildSpeed or 0) else frames = frames + 1 end
			end
		end
	end
	return done, frames, bp
end

local function progressOf(id)
	local _, _, _, _, p = Spring.GetUnitHealth(id)
	return p or 0
end

function widget:UnitCreated(unitID, unitDefID, unitTeam, builderID)
	local ud = UnitDefs[unitDefID]
	if not ud then return end
	local n = Spring.GetGameFrame()
	if GANTRIES[ud.name] then
		local x, _, z = Spring.GetUnitPosition(unitID)
		local g = { team = unitTeam, name = ud.name, x = x, z = z, placed = n, last = -1, finished = nil }
		local _, _, _, mi = Spring.GetTeamResources(unitTeam, "metal")
		g.last, g.frames = count(g)
		gantries[unitID] = g
		echo(string.format("placed team=%d id=%d def=%s at=%s frame=%d income=%.0f min10=%.0f nanos=%d frames=%d pos=%d,%d",
			unitTeam, unitID, ud.name, clock(n), n, mi or 0, minIncome(unitTeam), g.last, g.frames, x, z))
		return
	end
	local g = builderID and gantries[builderID]
	if g and g.finished then
		products[unitID] = { gantry = builderID, frame = n, name = ud.name }
	end
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	local n = Spring.GetGameFrame()
	local g = gantries[unitID]
	if g and not g.finished then
		g.finished = n
		local done, frames, bp = count(g)
		g.last = done
		echo(string.format("finished team=%d id=%d def=%s at=%s frame=%d took=%.0f nanos=%d frames=%d nanobp=%d",
			g.team, unitID, g.name, clock(n), n, (n - g.placed) / FPS, done, frames, bp))
		return
	end
	local p = products[unitID]
	if p then
		products[unitID] = nil
		local pg = gantries[p.gantry]
		echo(string.format("product team=%d gantry=%d unit=%s at=%s took=%.0f nanos=%d",
			unitTeam, p.gantry, p.name, clock(n), (n - p.frame) / FPS, pg and pg.last or -1))
	end
end

function widget:UnitDestroyed(unitID)
	local g = gantries[unitID]
	if g then
		echo(string.format("destroyed team=%d id=%d at=%s frame=%d progress=%.2f", g.team, unitID, clock(Spring.GetGameFrame()),
			Spring.GetGameFrame(), g.finished and 1 or g.progress or 0))
		gantries[unitID] = nil
	end
	products[unitID] = nil
end

-- every minute: each allyteam's standing value (metal cost of every unit, frames at their progress), for
-- the win effect of a game the time limit ends undecided
local function standing(n)
	local value, count = {}, {}
	for _, team in ipairs(Spring.GetTeamList() or {}) do
		local _, _, _, _, _, ally = Spring.GetTeamInfo(team, false)
		if ally then
			for _, u in ipairs(Spring.GetTeamUnits(team) or {}) do
				local ud = UnitDefs[Spring.GetUnitDefID(u) or -1]
				if ud then
					local _, _, _, _, progress = Spring.GetUnitHealth(u)
					value[ally] = (value[ally] or 0) + (ud.metalCost or 0) * (progress or 1)
					count[ally] = (count[ally] or 0) + 1
				end
			end
		end
	end
	local parts = {}
	for ally, v in pairs(value) do parts[#parts + 1] = string.format("ally%d=%d/%d", ally, v, count[ally]) end
	table.sort(parts)
	echo(string.format("standing at=%s frame=%d %s", clock(n), n, table.concat(parts, " ")))
end

function widget:GameFrame(n)
	if n % (60 * FPS) == 0 and n > 0 then standing(n) end
	if n % FPS ~= 0 then return end
	for _, team in ipairs(Spring.GetTeamList() or {}) do
		local _, _, _, mi = Spring.GetTeamResources(team, "metal")
		local ring = income[team] or {}
		ring[#ring + 1] = mi or 0
		if #ring > WINDOW then table.remove(ring, 1) end
		income[team] = ring
	end
	for id, g in pairs(gantries) do
		if not g.finished or n - g.finished <= TRACK_AFTER then
			if not g.finished then g.progress = progressOf(id) end
			local done, frames = count(g)
			if done ~= g.last then
				g.last = done
				echo(string.format("nanos team=%d id=%d at=%s frame=%d nanos=%d frames=%d gantry=%.2f",
					g.team, id, clock(n), n, done, frames, g.finished and 1 or g.progress or 0))
			end
		end
	end
end
