function widget:GetInfo() return {name="Eco flak verification",layer=126,enabled=true} end
local side="__SIDE__"
local enabled=__ENABLED__
local names={armada={"armaca","armafus","armflak","armarad"},cortex={"coraca","corafus","corflak","corarad"},legion={"legaca","legafus","legflak","legarad"}}
local units=names[side]
local built,created={},{}
local completed,total,phase,at=0,0,0,0
local function emit(s) Spring.Echo("[EcoFlakTest] "..s) end
local function give(name,x,z) Spring.SendCommands("give 1 "..name.." 0 @"..x..","..Spring.GetGroundHeight(x,z)..","..z) end
function widget:UnitCreated(id,def,team,builder)
    if team==0 and UnitDefs[def].name==units[3] and builder then
        created[id]=true; total=total+1
        if Spring.GetGameFrame()<600 then emit("FAIL flak before first AFUS") end
    end
end
function widget:UnitFinished(id,def,team)
    if created[id] then built[id]=true;completed=completed+1;emit("finished count="..completed.." id="..id) end
end
function widget:UnitDestroyed(id) built[id]=nil end
function widget:GameFrame(f)
    if f==90 then Spring.SendCommands("cheat 1") end
    if f==150 then Spring.SendSkirmishAIMessage(0,"eco-flak-init") end
    if f==240 then
        for i=0,5 do give(units[1],1500+i*48,10200) end
        give(units[4],1700,10000)
    end
    if f==570 and total==0 then emit("PASS no pre-AFUS construction") end
    if f==600 then give(units[2],1400,10400) end
    if not enabled then
        if f==3600 then emit(total==0 and "PASS disabled profile" or "FAIL disabled profile built flak") end
        return
    end
    if phase==0 and completed==1 then phase=1;at=f;emit("PASS first AFUS minimum") end
    -- Keep observed air pressure present after the first minimum. Supplied
    -- planes can be shot down; their deaths never stand in for completion.
    if phase>=1 and f%30==0 then Spring.SendCommands("give 1 armpeep 1 @1600,"..Spring.GetGroundHeight(1600,10100)..",10100") end
    if phase==1 and completed==3 then phase=2;at=f;emit("PASS air escalation") end
    if phase==2 and f>=at+40*30 then
        if total~=3 then emit("FAIL exceeded configured cap before loss");phase=99;return end
        emit("PASS cap held")
        local target=next(built)
        if target then Spring.SelectUnitArray({target},false);Spring.SendCommands("destroy");Spring.SelectUnitArray({},false);built[target]=nil end
        phase=3;at=f
    end
    if phase==3 and completed==4 then phase=4;at=f;emit("PASS destroyed flak rebuilt") end
    if phase==4 and f>=at+40*30 then
        local alive=0;for _ in pairs(built) do alive=alive+1 end
        emit(total==4 and alive==3 and "PASS all waves" or "FAIL replacement cap")
        phase=5
    end
end
