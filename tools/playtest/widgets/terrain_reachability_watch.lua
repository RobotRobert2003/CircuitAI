function widget:GetInfo() return {name="Terrain reachability verification",layer=126,enabled=true} end
local commander,created=false,false
local function emit(s) Spring.Echo("[TerrainReachTest] "..s) end
function widget:GameFrame(f)
    if f==90 then Spring.SendCommands("cheat 1"); emit("observer_started") end
    if f==150 then
        Spring.SendCommands("give 1 armca 0 @2100,0,2000")
        Spring.SendCommands("give 1 armnanotc 0 @2200,0,2000")
    end
    if f==300 then
        local air,nano
        for _,id in ipairs(Spring.GetTeamUnits(0)) do
            local name=UnitDefs[Spring.GetUnitDefID(id)].name
            if name=="armcom" then commander=id end
            if name=="armca" then air=id end
            if name=="armnanotc" then nano=id end
        end
        if not commander or not air or not nano then emit("FAIL missing supplied units"); return end
        Spring.SendSkirmishAIMessage(0,"terrain-reach|"..commander.."|"..air.."|"..nano)
    end
end
function widget:UnitCreated(id,def,team,builder)
    if team==0 and UnitDefs[def].name=="armllt" then
        created=builder==commander
        if not created then emit("FAIL wrong turret builder") end
    end
end
function widget:UnitFinished(id,def,team)
    if team==0 and UnitDefs[def].name=="armllt" and created then
        emit("PASS physical_valid_turret")
    end
end
