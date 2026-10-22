function widget:GetInfo() return {name="Heavy front delivery verification",layer=115,enabled=true} end
local side, mode, forward="__SIDE__","__MODE__",__FORWARD__
local heavy=({armada="armfboy",cortex="corsumo",legion="leginc"})[side]
local carrier=({armada="armhvytrans",cortex="corhvytrans",legion="legatrans"})[side]
local cargo,plane,aa,edge,range,loaded,unloaded,given,health,startHealth
local closest=1e9
local moves=0
local required,completed=__DELIVERIES__,0
local loads=0
local idleLimit=mode=="blocked" and 300 or 180
local nextCargo,submitCargo,lastX,lastZ,stillSince,maxStill
maxStill=0
local factories={}
local function emit(s) Spring.Echo("[HeavyFrontTest] "..s) end
local function spawn(name,team,x,z) Spring.SendCommands("give "..name.." "..team.." @"..x..","..Spring.GetGroundHeight(x,z)..","..z) end
local function message(team,s) Spring.SendSkirmishAIMessage(team,"heavy-front|"..s) end
function widget:UnitCommand(id,def,team,command)
    if id==plane and command==CMD.MOVE then moves=moves+1 end
end
function widget:UnitFinished(id,def,team)
    local name=UnitDefs[def].name
    if team==0 and name==heavy then cargo=id;loaded=false;unloaded=false;given=false;lastX=nil;stillSince=nil;loads=0 end
    if team==0 and name==carrier then plane=id;startHealth=Spring.GetUnitHealth(id) end
    if team==0 and name=="corlab" then factories[#factories+1]=id end
    if team==2 and name=="armrl" then
        aa=id
        if mode=="blocked" then emit("blocked goal observed aa="..id) end
    end
end
function widget:UnitLoaded(id,def,team,transport)
    if id==cargo then
        loaded=true;loads=loads+1;emit("loaded cargo="..id.." carrier="..transport)
        if loads>1 then emit("FAIL repeated lift cargo="..id) end
        if mode=="blocked" and loads==1 then
            spawn("armrl",2,edge-range,4000)
        end
    end
end
function widget:UnitUnloaded(id)
    if id==cargo then
        unloaded=true;emit("unloaded cargo="..id)
        if mode=="blocked" and aa then
            -- Recoil's destroy action uses selection; text IDs are ignored.
            Spring.SelectUnitArray({aa},false);Spring.SendCommands("destroy");Spring.SelectUnitArray({},false)
        end
    end
end
function widget:UnitDestroyed(id)
    if mode=="blocked" and id==aa then emit("PASS blocking AA removed") end
end
function widget:UnitGiven(id,def,newTeam,oldTeam)
    if id~=cargo or oldTeam~=0 then return end
    local x,y,z=Spring.GetUnitPosition(id)
    local standoff=edge and edge-x or -1
    local dx,dz=x-1500,z-6000
    local location=forward and (math.abs(z-4000)<180 and math.abs(standoff-range)<200 and x>3500)
        or (not forward and dx*dx+dz*dz<241*241)
    given=newTeam==1 and loaded and unloaded and not Spring.GetUnitTransporter(id) and location
    if given then
        completed=completed+1
        if completed<required then nextCargo=Spring.GetGameFrame()+300 end
    end
    emit((given and "PASS" or "FAIL").." arrival x="..math.floor(x).." z="..math.floor(z)
        .." fog="..tostring(edge).." range="..tostring(range).." standoff="..math.floor(standoff).." recipient="..newTeam)
end
function widget:GameFrame(frame)
    if frame==150 then Spring.SendCommands("cheat 1") end
    if frame==300 then
        for _,team in ipairs({0,1,2}) do message(team,"setup") end
        -- Known ground LOS along the centre lane, independent of aircraft sight.
        for x=1000,4600,400 do spawn("armeyes",0,x,4000) end
        if mode~="fallback" then
            for _,z in ipairs({3200,4000,4800}) do spawn("corlab",0,1600,z) end
        end
        if mode=="aa" or mode=="turns" then spawn("armrl",2,3000,4000) end
    end
    if frame==450 then
        for _,id in ipairs(factories) do
            local _,_,z=Spring.GetUnitPosition(id)
            message(0,"lane|"..id.."|"..math.floor(z-4000))
        end
        spawn(heavy,0,1250,4000);spawn(carrier,0,1100,4100)
    end
    if frame==600 then
        if not cargo or not plane then emit("FAIL missing supplied units");return end
        local ally=Spring.GetTeamAllyTeamID(0)
        local previous=Spring.IsPosInLos(1000,Spring.GetGroundHeight(1000,4000),4000,ally)
        for x=1008,7000,8 do
            local visible=Spring.IsPosInLos(x,Spring.GetGroundHeight(x,4000),4000,ally)
            if previous and not visible then edge=x end
            previous=visible
        end
        range=0
        for _,weapon in ipairs(UnitDefs[Spring.GetUnitDefID(cargo)].weapons) do
            range=math.max(range,WeaponDefs[weapon.weaponDef].range or 0)
        end
        emit("fixture fog="..tostring(edge).." range="..range.." aa="..tostring(aa).." factories="..#factories)
        message(0,"cargo|"..cargo.."|"..mode)
    end
    if nextCargo and frame>=nextCargo then
        spawn(heavy,0,1250,4000);nextCargo=nil;submitCargo=frame+150
    end
    if submitCargo and frame>=submitCargo then
        message(0,"cargo|"..cargo.."|"..mode);submitCargo=nil
    end
    -- Observe actual loaded transit, excluding loading/descent and home hold.
    -- A ship parked on a completed intermediate MOVE must not pass merely
    -- because the 90-second fallback eventually unloads it elsewhere.
    if plane and cargo and loaded and not unloaded and frame%15==0 then
        local x,_,z=Spring.GetUnitPosition(plane)
        local command=Spring.GetUnitCurrentCommand(plane)
        local transit=command==CMD.MOVE or command==CMD.STOP or not command
        local far=edge and ((x-(edge-range))^2+(z-4000)^2>180^2)
        if transit and far and lastX and (x-lastX)^2+(z-lastZ)^2<16^2 then
            stillSince=stillSince or frame-15
            maxStill=math.max(maxStill,frame-stillSince)
            if frame-stillSince==idleLimit then emit("FAIL transit idle cargo="..cargo.." x="..x.." z="..z.." command="..tostring(command)) end
        else stillSince=nil;lastX,lastZ=x,z end
    end
    if plane and Spring.ValidUnitID(plane) and aa and Spring.ValidUnitID(aa) then
        local x,_,z=Spring.GetUnitPosition(plane); local ax,_,az=Spring.GetUnitPosition(aa)
        closest=math.min(closest,math.sqrt((x-ax)^2+(z-az)^2))
    end
    if frame==8700 then
        health=plane and Spring.GetUnitHealth(plane)
        local x,y,z
        if plane then x,y,z=Spring.GetUnitPosition(plane) end
        local home=x and (x-1000)^2+(z-4000)^2<350^2
        local safe=health and health>=startHealth-1 and (not aa or closest>765) and home
        emit((given and completed==required and safe and maxStill<idleLimit and "PASS" or "FAIL").." final delivery safe="..tostring(safe)
            .." closest-aa="..math.floor(closest).." carrier-health="..tostring(health).." moves="..moves
            .." deliveries="..completed.." max-transit-idle-frames="..maxStill)
    end
end
