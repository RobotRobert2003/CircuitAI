-- Rez bot census (owner 2026-10-26, rez bot replenishment experiment). Read-only:
-- per team every 60 s the rez bots alive, the alive mobile army (finished
-- mobile units that are not builders: no constructors, rez bots or
-- commanders) and running totals of army engagements - army units / metal
-- lost, enemy army units / metal killed, all metal lost and killed (with
-- structures), units resurrected by rez bots and rez bots given between teams.
--   [RezWatch] min=<m> team=<t> ally=<a> rez=.. army=.. armyUnits=.. lostU=.. lostM=.. killU=.. killM=..
--              lostAllM=.. killAllM=.. rezzed=.. rezzedM=.. rezGivenOut=.. rezGivenIn=.. rezLost=..
--   [RezWatch] given unit=.. def=.. from=.. to=.. frame=..
-- Staged by: playtest.py run --extra-widget tools/playtest/widgets/rezbot_watch.lua
function widget:GetInfo()
    return {name = "Rez bot watch", desc = "Read-only rez bot and engagement census", author = "CircuitAI", layer = 121, enabled = true}
end

local FPS = 30
local rezDef, armyCost, allCost = {}, {}, {}
for id, ud in pairs(UnitDefs) do
    allCost[id] = ud.metalCost or 0
    if ud.canResurrect then rezDef[id] = true end
    if ud.canMove and not ud.isBuilder then armyCost[id] = ud.metalCost or 0 end
end

local S = {}
local rezzed = {}
local function st(team)
    local s = S[team]
    if not s then
        s = {lostU = 0, lostM = 0, killU = 0, killM = 0, lostAllM = 0, killAllM = 0, rezzed = 0, rezzedM = 0,
             givenOut = 0, givenIn = 0, rezLost = 0}
        S[team] = s
    end
    return s
end
local function ally(team)
    local _, _, _, _, _, a = Spring.GetTeamInfo(team, false)
    return a or -1
end

function widget:Initialize()
    if Spring.GetSpectatingState() then Spring.SendCommands("specfullview 1") end
end

local function markRezzed(id, def, team)
    if rezzed[id] then return end
    rezzed[id] = true
    local s = st(team)
    s.rezzed = s.rezzed + 1
    s.rezzedM = s.rezzedM + (allCost[def] or 0)
    Spring.Echo(string.format("[RezWatch] rezzed unit=%d def=%s team=%d metal=%.0f frame=%d", id,
        UnitDefs[def] and UnitDefs[def].name or "?", team, allCost[def] or 0, Spring.GetGameFrame()))
end

function widget:UnitCreated(id, def, team, builderID)
    if builderID then
        local bdef = Spring.GetUnitDefID(builderID)
        if bdef and rezDef[bdef] then markRezzed(id, def, team) end
    end
end

function widget:UnitFinished(id, def, team)
    local r = Spring.GetUnitRulesParam(id, "resurrected")
    if r and r ~= 0 then markRezzed(id, def, team) end
end

function widget:UnitDestroyed(id, def, team, attackerID, attackerDefID, attackerTeam)
    rezzed[id] = nil
    local _, _, _, _, bp = Spring.GetUnitHealth(id)
    if bp and bp < 1 then return end   -- unfinished frames and cancelled builds are not losses
    local s = st(team)
    local m = allCost[def] or 0
    s.lostAllM = s.lostAllM + m
    if rezDef[def] then s.rezLost = s.rezLost + 1 end
    if armyCost[def] then
        s.lostU = s.lostU + 1
        s.lostM = s.lostM + m
    end
    if attackerTeam and attackerTeam >= 0 and ally(attackerTeam) ~= ally(team) then
        local k = st(attackerTeam)
        k.killAllM = k.killAllM + m
        if armyCost[def] then
            k.killU = k.killU + 1
            k.killM = k.killM + m
        end
    end
end

function widget:UnitGiven(id, def, newTeam, oldTeam)
    if not rezDef[def] then return end
    st(oldTeam).givenOut = st(oldTeam).givenOut + 1
    st(newTeam).givenIn = st(newTeam).givenIn + 1
    Spring.Echo(string.format("[RezWatch] given unit=%d def=%s from=%d to=%d frame=%d", id,
        UnitDefs[def] and UnitDefs[def].name or "?", oldTeam, newTeam, Spring.GetGameFrame()))
end

local function census(tag)
    local f = Spring.GetGameFrame()
    for _, team in ipairs(Spring.GetTeamList() or {}) do
        local a = ally(team)
        if a <= 1 then
            local rez, army, armyN = 0, 0, 0
            for _, u in ipairs(Spring.GetTeamUnits(team) or {}) do
                local def = Spring.GetUnitDefID(u)
                local _, _, _, _, bp = Spring.GetUnitHealth(u)
                if def and (bp or 1) >= 1 then
                    if rezDef[def] then rez = rez + 1
                    elseif armyCost[def] then army = army + armyCost[def]; armyN = armyN + 1 end
                end
            end
            local s = st(team)
            Spring.Echo(string.format("[RezWatch] min=%.1f team=%d ally=%d rez=%d army=%.0f armyUnits=%d lostU=%d lostM=%.0f killU=%d killM=%.0f lostAllM=%.0f killAllM=%.0f rezzed=%d rezzedM=%.0f rezGivenOut=%d rezGivenIn=%d rezLost=%d%s",
                f / (60 * FPS), team, a, rez, army, armyN, s.lostU, s.lostM, s.killU, s.killM, s.lostAllM, s.killAllM,
                s.rezzed, s.rezzedM, s.givenOut, s.givenIn, s.rezLost, tag or ""))
        end
    end
end

function widget:GameFrame(f)
    if f > 0 and f % (60 * FPS) == 0 then census() end
end

function widget:GameOver() census(" final") end
