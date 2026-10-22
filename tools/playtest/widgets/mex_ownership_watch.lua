function widget:GetInfo() return {name="Mex ownership verification",layer=126,enabled=true} end
local cutoff=__CUTOFF__
local high,low,foreign,airHill,airForeign,allyMex
local highDone,foreignDone=false,false
local function emit(s) Spring.Echo("[MexOwnershipTest] "..s) end
local function give(name,team,p)
    Spring.SendCommands("give 1 "..name.." "..team.." @"..p.x..","..Spring.GetGroundHeight(p.x,p.z)..","..p.z)
end
local function nearest(name,p)
    local best,d=nil,1e9
    for _,id in ipairs(Spring.GetTeamUnits(0)) do
        if UnitDefs[Spring.GetUnitDefID(id)].name==name then
            local x,_,z=Spring.GetUnitPosition(id);local s=(x-p.x)^2+(z-p.z)^2
            if s<d then best,d=id,s end
        end
    end
    return best
end
function widget:GameFrame(f)
    if f==90 then Spring.SendCommands("cheat 1");emit("observer_started") end
    if f==150 then
        local finder=WG.resource_spot_finder
        if not finder or not finder.metalSpotsList then emit("FAIL missing metal survey");return end
        local distance=1e9
        for _,p in ipairs(finder.metalSpotsList) do
            local y=Spring.GetGroundHeight(p.x,p.z)
            local d=(p.x-4578)^2+(p.z-2485)^2
            if y>0 and d<distance then foreign={x=p.x,z=p.z};distance=d end
            if not high and y>160 then
                for radius=120,720,120 do for angle=0,31 do
                    local x=p.x+radius*math.cos(angle*math.pi/16)
                    local z=p.z+radius*math.sin(angle*math.pi/16)
                    local ground=Spring.GetGroundHeight(x,z)
                    if ground>0 and y-ground>150 and Spring.TestBuildOrder(UnitDefNames.armllt.id,x,ground,z,0)>0 then
                        high={x=p.x,z=p.z};low={x=x,z=z};break
                    end
                end if high then break end end
            end
        end
        if not high or not foreign then emit("FAIL no physical cliff/foreign fixture");return end
        emit(string.format("geometry hill=%.0f,%.0f,%.0f valley=%.0f,%.0f,%.0f foreign=%.0f,%.0f",high.x,Spring.GetGroundHeight(high.x,high.z),high.z,low.x,Spring.GetGroundHeight(low.x,low.z),low.z,foreign.x,foreign.z))
        give("armck",0,low);give("armck",0,high);give("armca",0,low)
        give("armca",0,{x=foreign.x+64,z=foreign.z})
    end
    if f==300 and high then
        airHill=nearest("armca",low);airForeign=nearest("armca",foreign)
        local bottom=nearest("armck",low);local top=nearest("armck",high)
        if not airHill or not airForeign or not bottom or not top then emit("FAIL supplied actors");return end
        Spring.SendSkirmishAIMessage(0,table.concat({"mex-test","hill",bottom,top,airHill,high.x,high.z,low.x,low.z},"|"))
        Spring.SendSkirmishAIMessage(0,table.concat({"mex-test","foreign",airForeign,foreign.x,foreign.z},"|"))
    end
    if f==450 and foreign then give("armmex",1,foreign) end
    if f==(cutoff-8)*30 then
        for _,id in ipairs(Spring.GetTeamUnits(1)) do
            if UnitDefs[Spring.GetUnitDefID(id)].name=="armmex" then
                allyMex=id;Spring.SelectUnitArray({id},false);Spring.SendCommands("destroy");Spring.SelectUnitArray({},false)
                emit("ally mex destroyed")
            end
        end
    end
    if f==(cutoff-1)*30 then Spring.SendSkirmishAIMessage(0,"mex-test|before") end
    if f==cutoff*30 then Spring.SendSkirmishAIMessage(0,"mex-test|after") end
    if highDone and foreignDone then emit("PASS all physical checks");highDone=false;foreignDone=false end
end
function widget:UnitCreated(id,def,team,builder)
    if team==0 and UnitDefs[def].name=="armmex" then
        if builder==airForeign and Spring.GetGameFrame()<cutoff*30 then emit("FAIL foreign mex before cutoff") end
    end
end
function widget:UnitFinished(id,def,team)
    if team~=0 or UnitDefs[def].name~="armmex" or not high then return end
    local x,_,z=Spring.GetUnitPosition(id)
    if (x-high.x)^2+(z-high.z)^2<4096 then highDone=true;emit("PASS physical mountain mex") end
    if (x-foreign.x)^2+(z-foreign.z)^2<4096 then foreignDone=true;emit("PASS physical late recovery") end
end
