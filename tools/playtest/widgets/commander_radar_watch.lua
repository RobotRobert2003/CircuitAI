function widget:GetInfo() return {name="Commander radar verification",layer=126,enabled=true} end
local prefix=({armada="arm",cortex="cor",legion="leg"})["__SIDE__"]
local commander,constructor,fixtureRadar
local physical,finished,lastFinished=0,0,nil
local building=false
local function emit(s) Spring.Echo("[CommanderRadarTest] "..s) end
local function give(name,x,z,team)
    Spring.SendCommands("give 1 "..name.." "..(team or 0).." @"..x..","..Spring.GetGroundHeight(x,z)..","..z)
end
local function destroy(id)
    if not id then return end
    Spring.SelectUnitArray({id},false); Spring.SendCommands("destroy"); Spring.SelectUnitArray({},false)
end
function widget:UnitCreated(id,def,team,builder)
    local name=UnitDefs[def].name
    if name==prefix.."rad" or name=="armarad" then
        if builder and builder==commander then
            physical=physical+1
            emit("radar_started count="..physical.." builder="..builder)
            if physical>1 then emit("FAIL stacked physical radars") end
        else fixtureRadar=id end
    end
end
function widget:UnitFinished(id,def,team)
    if building and team==0 and UnitDefs[def].name==prefix.."rad" then
        finished=finished+1; lastFinished=Spring.GetGameFrame()
        emit("radar_finished count="..finished)
    end
end
local cases={
    {"near",0.1,false}, {"inner79",0.79,false}, {"boundary80",0.8,true},
    {"outer81",0.81,true}, {"outside",1.05,true}, {"allied",0.2,false,1},
    {"advanced",0.79,false,0,"armarad"}, {"destroyed",nil,true},
}
function widget:GameFrame(f)
    if f==90 then Spring.SendCommands("cheat 1"); emit("observer_started") end
    if f==150 then
        for _,id in ipairs(Spring.GetTeamUnits(0)) do
            if UnitDefs[Spring.GetUnitDefID(id)].name==prefix.."com" then commander=id end
        end
        if not commander then emit("FAIL missing commander"); return end
        give(prefix.."lab",3700,3700)
        give(prefix.."cv",4300,4000)
        Spring.SendSkirmishAIMessage(0,"commander-radar|setup|"..commander.."|"..prefix.."rad")
    end
    if f==240 then
        for _,id in ipairs(Spring.GetTeamUnits(0)) do
            if UnitDefs[Spring.GetUnitDefID(id)].name==prefix.."cv" then constructor=id end
        end
        if not constructor then emit("FAIL missing constructor") end
    end
    for i,case in ipairs(cases) do
        local start=300+(i-1)*180
        if f==start then
            destroy(fixtureRadar); fixtureRadar=nil
            if case[2] then
                local name=case[5] or prefix.."rad"
                local radius=UnitDefNames[name].radarDistance
                local x,_,z=Spring.GetUnitPosition(commander)
                give(name,x+radius*case[2],z,case[4])
            end
        elseif f==start+120 then
            if case[2] and not fixtureRadar then emit("FAIL radar spawn "..case[1]); return end
            if fixtureRadar then
                local x,_,z=Spring.GetUnitPosition(commander)
                local rx,_,rz=Spring.GetUnitPosition(fixtureRadar)
                emit("coverage_input case="..case[1].." distance="..math.sqrt((x-rx)^2+(z-rz)^2))
            end
            Spring.SendSkirmishAIMessage(0,"commander-radar|check|"..case[1].."|"..(case[3] and 1 or 0).."|"..constructor)
        end
    end
    if f==1800 then building=true; Spring.SendSkirmishAIMessage(0,"commander-radar|build") end
    if building and lastFinished and f>=lastFinished+900 then
        building=false
        if physical==1 and finished==1 then emit("PASS physical_one_radar stable_seconds=30")
        else emit("FAIL physical counts started="..physical.." finished="..finished) end
    end
end
