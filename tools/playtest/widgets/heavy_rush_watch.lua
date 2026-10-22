function widget:GetInfo()
    return {name="Heavy rush observer", layer=115, enabled=true}
end
local supplied = false
local heavy = {armfboy=true, corsumo=true, leginc=true}
local carriers = {armhvytrans=true, corhvytrans=true, legatrans=true}
local cargoCommands, carrierCommands = 0, 0
local function name(definition) return UnitDefs[definition] and UnitDefs[definition].name end
function widget:UnitCommand(id, definition, team, command)
    if team ~= 0 then return end
    local unitName = name(definition)
    if heavy[unitName] then cargoCommands = cargoCommands + 1 end
    if carriers[unitName] then carrierCommands = carrierCommands + 1 end
end
function widget:UnitFinished(id, definition, team)
    if heavy[name(definition)] then
        Spring.Echo("[HeavyRushTest] finished team="..team.." id="..id.." def="..name(definition).." frame="..Spring.GetGameFrame())
    end
end
function widget:UnitLoaded(id, definition, team, transport)
    if heavy[name(definition)] then Spring.Echo("[HeavyRushTest] loaded id="..id.." carrier="..transport) end
end
function widget:UnitUnloaded(id, definition, team, transport)
    if heavy[name(definition)] then Spring.Echo("[HeavyRushTest] unloaded id="..id.." carrier="..transport) end
end
function widget:UnitGiven(id, definition, newTeam, oldTeam)
    if heavy[name(definition)] then Spring.Echo("[HeavyRushTest] given id="..id.." from="..oldTeam.." to="..newTeam) end
end
function widget:GameFrame(frame)
    if supplied and frame == 150 then Spring.SendCommands("cheat 1") end
    if supplied and frame == 300 then
        local x, _, z = Spring.GetTeamStartPosition(0)
        local commander = (Spring.GetTeamUnits(0) or {})[1]
        local definition = commander and UnitDefs[Spring.GetUnitDefID(commander)]
        local side = definition and definition.name:sub(1,3) or "cor"
        local fusion = ({arm="armfus",cor="corfus",leg="legfus"})[side] or "corfus"
        for i=1,4 do
            local px,pz=x+160*i,z+220
            Spring.SendCommands("give "..fusion.." 0 @"..px..","..Spring.GetGroundHeight(px,pz)..","..pz)
        end
    end
    if frame % 1800 == 0 then
        -- Events while TECH owns the units, not network packets or recipient
        -- combat commands. Identical observer in old/new starting scenarios.
        Spring.Echo(string.format("[HeavyRushTest] commands frame=%d cargo=%d carriers=%d",
            frame, cargoCommands, carrierCommands))
        cargoCommands, carrierCommands = 0, 0
        local metal, _, _, income = Spring.GetTeamResources(0,"metal")
        local energy, _, _, energyIncome = Spring.GetTeamResources(0,"energy")
        Spring.Echo(string.format("[HeavyRushTest] economy frame=%d metal=%.0f income=%.1f energy=%.0f income=%.1f",
            frame,metal or 0,income or 0,energy or 0,energyIncome or 0))
    end
end
