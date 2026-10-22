function widget:GetInfo() return {name="SEA supplied harbor fixture",layer=125,enabled=true,handler=true} end
local queue,prior,hook={},nil,nil
local oldYard,oldDef,reclaimObserved=nil,nil,false
local products,departed={},{}
function widget:Initialize()
    local env=getfenv(0);prior=rawget(env,"RecvSkirmishAIMessage")
    hook=function(team,text)
        if team==0 then
            local old=text:match("^barb|seaprobe|%d+|%d+|watchold|(%d+)$")
            if old then oldYard=tonumber(old); oldDef=Spring.GetUnitDefID(oldYard) end
            local unit,x,z,n=text:match("^barb|seaprobe|%d+|%d+|give|([^|]+)|([^|]+)|([^|]+)|(%d+)$")
            if unit then queue[#queue+1]="give "..n.." "..unit.." 0 @"..x..","..Spring.GetGroundHeight(tonumber(x),tonumber(z))..","..z end
        end
        if prior then return prior(team,text) end
    end
    rawset(env,"RecvSkirmishAIMessage",hook);Script.UpdateCallIn("RecvSkirmishAIMessage")
    Spring.Echo("[SeaFixture] supplied naval economy and stationary friendly cover; no factory or production orders supplied")
end
function widget:GameFrame(f)
    if f%30==0 then
        for id,p in pairs(products) do
            local x,_,z=Spring.GetUnitPosition(id)
            local _,_,_,_,progress=Spring.GetUnitHealth(id)
            if not x then products[id]=nil
            elseif progress and progress>=1 and (x-p.x)^2+(z-p.z)^2>480^2 then
                departed[p.yard]=true; products[id]=nil
            end
        end
    end
    if f==150 then Spring.SendCommands({"cheat 1","globallos"}) end
    if f%15==0 and #queue>0 then Spring.SendCommands(table.remove(queue,1)) end
    -- Only startup liquidity is supplied. Natural production pays subsequent costs.
    if f==4500 then Spring.SendCommands({"team 0","atm 5000","spectator"}) end
end
function widget:UnitCreated(id,def,team,builder)
    if team~=0 or not builder or builder==oldYard then return end
    if oldDef and Spring.GetUnitDefID(builder)==oldDef and not UnitDefs[def].isImmobile then
        local x,_,z=Spring.GetUnitPosition(builder)
        products[id]={yard=builder,x=x,z=z}
    end
end
function widget:UnitCommand(id,def,team,cmd,params)
    if team~=0 or cmd~=CMD.RECLAIM or not params or params[1]~=oldYard or reclaimObserved then return end
    reclaimObserved=true
    local replacement=nil
    for yard in pairs(departed) do
        local _,_,_,_,progress=Spring.GetUnitHealth(yard)
        if progress and progress>=1 and Spring.GetUnitTeam(yard)==0 then replacement=yard; break end
    end
    local verdict=replacement and not Spring.GetUnitIsBuilding(oldYard) and "PASS" or "FAIL"
    Spring.Echo("[SeaFixture] "..verdict.." replacement exit precedes old reclaim old="..oldYard.." new="..tostring(replacement))
end
function widget:UnitDestroyed(id)
    products[id]=nil; departed[id]=nil
    if id==oldYard then Spring.Echo("[SeaFixture] "..(reclaimObserved and "PASS" or "FAIL").." observed old yard removal after reclaim") end
end
function widget:Shutdown()
    local env=getfenv(0)
    if rawget(env,"RecvSkirmishAIMessage")==hook then rawset(env,"RecvSkirmishAIMessage",prior);Script.UpdateCallIn("RecvSkirmishAIMessage") end
end
