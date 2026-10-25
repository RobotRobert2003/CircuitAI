-- Playtest watcher (owner, 2026-10-25): construction turrets on T2 factories and
-- what the factories build, for every AI team (SUPPORT compared with AIR and TECH).
-- Every 60 s, one line per T2 factory: the team, its role, the factory and the
-- construction turrets within reach of it (standing, frames). Every unit a
-- factory finishes: one line with the factory and the unit. Every line is
-- "[SupWatch] ..."; tools/playtest/support_factory_report.py reads them.
--
-- Staged by: playtest.py run --extra-widget tools/playtest/widgets/support_factory_watch.lua

function widget:GetInfo()
	return {
		name    = "BARb support factory watch",
		desc    = "tools/playtest: turrets on T2 factories each minute, and every factory-built unit",
		author  = "s3k-CircuitAI",
		date    = "2026-10-25",
		layer   = 10,
		enabled = true,
	}
end

local FPS = 30
local T2 = { armalab = true, coralab = true, legalab = true, armavp = true, coravp = true, legavp = true,
	armaap = true, coraap = true, legaap = true }

local nanoDefs = {}
for id, ud in pairs(UnitDefs) do
	if ud.isBuilder and not ud.canMove and not ud.isFactory and (ud.buildSpeed or 0) > 0 then nanoDefs[id] = ud end
end

local function echo(s) Spring.Echo("[SupWatch] " .. s) end
local function clock(n)
	local s = math.floor(n / FPS)
	return string.format("%d:%02d", math.floor(s / 60), s % 60)
end
local function roleOf(team)
	local roster = WG.barblink and WG.barblink.Roster and WG.barblink.Roster() or nil
	return roster and roster[team] and roster[team].role or "?"
end

local function report(frame)
	for _, team in ipairs(Spring.GetTeamList() or {}) do
		local units = Spring.GetTeamUnits(team) or {}
		local nanos, total = {}, 0
		for _, u in ipairs(units) do
			local d = Spring.GetUnitDefID(u)
			if d and nanoDefs[d] then nanos[#nanos + 1] = u; total = total + 1 end
		end
		for _, f in ipairs(units) do
			local d = Spring.GetUnitDefID(f)
			local name = d and UnitDefs[d].name
			if name and T2[name] then
				local fx, _, fz = Spring.GetUnitPosition(f)
				local _, _, _, _, fp = Spring.GetUnitHealth(f)
				local standing, frames = 0, 0
				for _, u in ipairs(nanos) do
					local ud = nanoDefs[Spring.GetUnitDefID(u)]
					local x, _, z = Spring.GetUnitPosition(u)
					local reach = (ud.buildDistance or 0) + 100
					if x and (x - fx) ^ 2 + (z - fz) ^ 2 <= reach * reach then
						local _, _, _, _, p = Spring.GetUnitHealth(u)
						if p and p < 1 then frames = frames + 1 else standing = standing + 1 end
					end
				end
				echo(string.format("t=%s team=%d role=%s factory=%s id=%d progress=%.2f turrets=%d frames=%d team_turrets=%d",
					clock(frame), team, roleOf(team), name, f, fp or 0, standing, frames, total))
			end
		end
	end
end

function widget:GameFrame(n)
	if n > 0 and n % (60 * FPS) == 0 then report(n) end
end

function widget:UnitFromFactory(unitID, unitDefID, unitTeam, factID, factDefID)
	local fd = UnitDefs[factDefID]
	echo(string.format("t=%s built team=%d role=%s factory=%s unit=%s",
		clock(Spring.GetGameFrame()), unitTeam, roleOf(unitTeam), fd and fd.name or "?", UnitDefs[unitDefID].name))
end
