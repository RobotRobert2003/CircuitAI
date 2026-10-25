-- Playtest watcher (owner, 2026-10-25): every AI team's first land gantry.
-- When its frame is placed: the game time, the team's metal income (now and the
-- mean of the last 10 s) and the construction turrets around it. While it goes
-- up, every 10 s, and when it finishes: its build progress and the turrets
-- around it (standing and still frames). 60 s after it finishes: the turrets
-- again. One summary line per gantry. Every line is "[T3Watch] ...".
--
-- Staged by: playtest.py run --extra-widget tools/playtest/widgets/t3rush_gantry_watch.lua

function widget:GetInfo()
	return {
		name    = "BARb t3rush gantry watch",
		desc    = "tools/playtest: first gantry per team: placement time and metal income, turrets near it while it is built and 60 s after",
		author  = "s3k-CircuitAI",
		date    = "2026-10-25",
		layer   = 10,
		enabled = true,
	}
end

local FPS = 30
local GANTRIES = { armshltx = true, corgant = true, leggant = true }
local BUILD_REPORT_FRAMES = 10 * FPS
local AFTER_FRAMES = 60 * FPS
local WINDOW = 10   -- seconds of metal income averaged

local nanoDefs = {}
for id, ud in pairs(UnitDefs) do
	if ud.isBuilder and not ud.canMove and not ud.isFactory and (ud.buildSpeed or 0) > 0 then nanoDefs[id] = ud end
end

local income = {}     -- team -> ring of the last WINDOW 1 s samples
local watched = {}    -- team -> { id, name, x, z, placed, placedIncome, placedMean, finished, lastReport, afterDone, ... }
local byUnit = {}     -- gantry unitID -> team

local function echo(s) Spring.Echo("[T3Watch] " .. s) end
local function minutes(n) return n / (60 * FPS) end
local function clock(n)
	local s = math.floor(n / FPS)
	return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

local function roleOf(team)
	local roster = WG.barblink and WG.barblink.Roster and WG.barblink.Roster() or nil
	return roster and roster[team] and roster[team].role or "?"
end

local function teamIncome(team)
	local _, _, _, mi = Spring.GetTeamResources(team, "metal")
	return mi or 0
end

local function meanIncome(team)
	local ring = income[team]
	if not ring or #ring == 0 then return teamIncome(team) end
	local sum = 0
	for i = 1, #ring do sum = sum + ring[i] end
	return sum / #ring
end

-- Construction turrets of the gantry's team that can reach it: standing ones,
-- frames still going up, and the build power of the standing ones
local function turretsNear(w)
	local standing, frames, power = 0, 0, 0
	for _, u in ipairs(Spring.GetTeamUnits(w.team) or {}) do
		local d = Spring.GetUnitDefID(u)
		local ud = d and nanoDefs[d]
		if ud then
			local x, _, z = Spring.GetUnitPosition(u)
			local reach = (ud.buildDistance or 0) + 120   -- plus the gantry's half size, roughly
			if x and (x - w.x) ^ 2 + (z - w.z) ^ 2 <= reach * reach then
				local _, _, _, _, progress = Spring.GetUnitHealth(u)
				if progress and progress < 1 then frames = frames + 1 else standing = standing + 1; power = power + (ud.buildSpeed or 0) end
			end
		end
	end
	return standing, frames, power
end

local function progressOf(w)
	if not Spring.ValidUnitID(w.id) then return 0 end
	local _, _, _, _, progress = Spring.GetUnitHealth(w.id)
	return progress or 0
end

local function report(w, n, what)
	local standing, frames, power = turretsNear(w)
	echo(string.format("team %d %s %s %d %s at %s (%.2f min): gantry %.0f%%, turrets near it %d standing (%d BP) + %d frames; metal +%.1f",
		w.team, w.role, w.name, w.id, what, clock(n), minutes(n), progressOf(w) * 100, standing, power, frames, teamIncome(w.team)))
	return standing, frames
end

function widget:UnitCreated(unitID, unitDefID, unitTeam)
	local ud = UnitDefs[unitDefID]
	if not ud or not GANTRIES[ud.name] or watched[unitTeam] then return end
	local n = Spring.GetGameFrame()
	local x, _, z = Spring.GetUnitPosition(unitID)
	local w = { team = unitTeam, role = roleOf(unitTeam), id = unitID, name = ud.name, x = x or 0, z = z or 0, placed = n,
		placedIncome = teamIncome(unitTeam), placedMean = meanIncome(unitTeam), lastReport = n }
	watched[unitTeam] = w
	byUnit[unitID] = unitTeam
	local standing, frames = turretsNear(w)
	w.placedTurrets = standing
	echo(string.format("team %d %s placed %s %d at %s (%.2f min) at (%d, %d): metal +%.1f now, +%.1f mean of the last %d s; turrets near it %d standing + %d frames",
		unitTeam, w.role, ud.name, unitID, clock(n), minutes(n), w.x, w.z, w.placedIncome, w.placedMean, WINDOW, standing, frames))
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	local team = byUnit[unitID]
	if not team then return end
	local w = watched[team]
	local n = Spring.GetGameFrame()
	w.finished = n
	w.finishedTurrets = report(w, n, "finished after " .. string.format("%.0f s", (n - w.placed) / FPS))
end

function widget:UnitDestroyed(unitID)
	local team = byUnit[unitID]
	if not team then return end
	local w = watched[team]
	if w and not w.afterDone then
		echo(string.format("team %d %s %s %d destroyed at %s (%s)", team, w.role, w.name, unitID, clock(Spring.GetGameFrame()),
			w.finished and "after it finished" or "before it finished"))
		w.afterDone = true
	end
	byUnit[unitID] = nil
end

function widget:GameFrame(n)
	if n % FPS == 0 then
		for _, team in ipairs(Spring.GetTeamList() or {}) do
			local ring = income[team] or {}
			ring[#ring + 1] = teamIncome(team)
			if #ring > WINDOW then table.remove(ring, 1) end
			income[team] = ring
		end
	end
	for team, w in pairs(watched) do
		if not w.afterDone then
			if not w.finished and n - w.lastReport >= BUILD_REPORT_FRAMES then
				w.lastReport = n
				report(w, n, "going up")
			elseif w.finished and n - w.finished >= AFTER_FRAMES then
				w.afterDone = true
				local standing, frames = report(w, n, "60 s after it finished")
				echo(string.format("SUMMARY team %d %s %s: placed %s at metal +%.1f (10 s mean +%.1f) with %d turrets; finished %s with %d; %d (+%d frames) 60 s later",
					team, w.role, w.name, clock(w.placed), w.placedIncome, w.placedMean, w.placedTurrets or 0, clock(w.finished),
					w.finishedTurrets or 0, standing, frames))
			end
		end
	end
end

function widget:GameOver()
	for team, w in pairs(watched) do
		if not w.afterDone then
			echo(string.format("SUMMARY team %d %s %s: placed %s at metal +%.1f (10 s mean +%.1f) with %d turrets; %s at game end",
				team, w.role, w.name, clock(w.placed), w.placedIncome, w.placedMean, w.placedTurrets or 0,
				w.finished and ("finished " .. clock(w.finished) .. ", under 60 s before the end") or "not finished"))
		end
	end
end

function widget:Shutdown()
	widget:GameOver()
end
