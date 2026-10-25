-- Read-only natural-game outcome census (owner 2026-10-24): Liches born, lost
-- (and to what) and their kills, plus commander kills and deaths, per team.
-- Pairs with the AI's own ESCORT: and [Commander] shot lines; no orders, gifts
-- or cheats. Liche lines keep the liche_strike_fixture.lua format plus team=.
function widget:GetInfo()
    return {name="Combat outcome watch",desc="Read-only Liche and commander outcome census",author="CircuitAI",layer=119,enabled=true}
end
local liches = {}
local born, lost, kills, comKills, comDeaths = {}, {}, {}, {}, {}
local function echo(s) Spring.Echo("[LicheStrike] "..s) end
local function defName(def) return def and UnitDefs[def] and UnitDefs[def].name or "?" end
local function isCom(def) return def and UnitDefs[def] and UnitDefs[def].customParams and UnitDefs[def].customParams.iscommander ~= nil end
local function add(t, team) t[team] = (t[team] or 0) + 1 end
function widget:Initialize()
    if Spring.GetSpectatingState() then Spring.SendCommands("specfullview 1") end
end
function widget:UnitCreated(id, def, team)
    if defName(def) == "armliche" then
        liches[id] = team; add(born, team)
        echo("liche-born id="..id.." team="..team)
    end
end
function widget:UnitDestroyed(id, def, team, attackerID, attackerDefID, attackerTeam)
    if liches[id] then
        add(lost, team)
        echo("liche-lost id="..id.." team="..team.." by="..defName(attackerDefID))
        liches[id] = nil
    end
    if attackerTeam and attackerTeam ~= team and defName(attackerDefID) == "armliche" then
        add(kills, attackerTeam)
        echo("liche-kill victim="..defName(def).." id="..id.." attacker="..tostring(attackerID).." team="..attackerTeam)
    end
    if attackerTeam and attackerTeam ~= team and isCom(attackerDefID) then
        add(comKills, attackerTeam)
        Spring.Echo("[ComOutcome] kill team="..attackerTeam.." attacker="..defName(attackerDefID).." victim="..defName(def).." frame="..Spring.GetGameFrame())
    end
    if isCom(def) then
        add(comDeaths, team)
        Spring.Echo("[ComOutcome] death team="..team.." def="..defName(def).." by="..defName(attackerDefID).." frame="..Spring.GetGameFrame())
    end
end
local function tally(final)
    for _, team in ipairs(Spring.GetTeamList()) do
        if (born[team] or 0) + (comKills[team] or 0) + (comDeaths[team] or 0) > 0 then
            Spring.Echo(string.format("[ComOutcome] tally team=%d liche_born=%d liche_lost=%d liche_kills=%d com_kills=%d com_deaths=%d%s",
                team, born[team] or 0, lost[team] or 0, kills[team] or 0, comKills[team] or 0, comDeaths[team] or 0, final and " final" or ""))
        end
    end
end
function widget:GameFrame(f)
    if f % 1800 == 0 and f > 0 then tally(false) end
end
function widget:Shutdown() tally(true) end
