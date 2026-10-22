function widget:GetInfo()
    return {name="Gunship defensive AA priority fixture", layer=126, enabled=true, handler=true}
end
local side="__SIDE__"
local gunship=({armada="armbrawl",cortex="corape",legion="legstronghold"})[side]
local targets=({armada={"armjeth","armaak","armrl"},cortex={"corcrash","coraak","corrl"},legion={"legaabot","legadvaabot","armrl"}})[side]
local targetNames={}
for _,name in ipairs(targets) do targetNames[name]=true end
local position,camera,spawnAt,spawnFrame
local expected,dead,damageSeen,orderSeen={},{},{},{}
local passes,orders,duplicates,last={},{},{},{}
local priorCommand,commandHook,priorDamage,damageHook
local function emit(text) Spring.Echo("[GunshipPriority] "..text) end
local function pass(key)
    if not passes[key] then passes[key]=true;emit("PASS "..key.." frame="..Spring.GetGameFrame()) end
end
local function photo()
    if camera then return end
    Spring.SendCommands({"setmaxspeed 0.25","setminspeed 0.25","setmaxspeed 0.25"})
    camera={at=Spring.GetTimer(),draws=0}
end
local function allDead()
    for _,name in ipairs(targets) do if not dead[name] then return false end end
    return true
end
function widget:Initialize()
    priorCommand=widgetHandler.UnitCommand
    commandHook=function(self,id,definition,team,command,parameters,...)
        if team==0 and UnitDefs[definition].name==gunship and command==CMD.ATTACK and parameters and #parameters==1 then
            local target=UnitDefs[Spring.GetUnitDefID(parameters[1]) or -1]
            orders[id]=(orders[id] or 0)+1
            if last[id]==parameters[1] then duplicates[id]=(duplicates[id] or 0)+1 end
            last[id]=parameters[1]
            if target and target.name=="corjugg" then
                pass("heavy_incumbent")
                if not spawnAt then spawnAt=Spring.GetGameFrame()+30 end
                if allDead() then pass("heavy_fallback");photo() end
            elseif target and targetNames[target.name] then
                if not orderSeen[target.name] then
                    orderSeen[target.name]=true
                    emit("aa_order target="..target.name.." delay_frames="..(Spring.GetGameFrame()-(spawnFrame or 0)))
                    photo()
                end
                if not passes.aa_preempts then
                    if spawnFrame and Spring.GetGameFrame()-spawnFrame<=150 then pass("aa_preempts")
                    else emit("FAIL late_aa_preemption") end
                end
            end
        end
        if priorCommand then return priorCommand(self,id,definition,team,command,parameters,...) end
    end
    widgetHandler.UnitCommand=commandHook;widgetHandler:UpdateCallIn("UnitCommand")
    priorDamage=widgetHandler.UnitDamaged
    damageHook=function(self,id,definition,team,damage,paralyze,weapon,projectile,attacker,attackerDefinition,attackerTeam,...)
        local target=UnitDefs[definition]
        local source=UnitDefs[attackerDefinition or -1]
        if target and targetNames[target.name] and attackerTeam==0 and source and source.name==gunship and not paralyze then
            damageSeen[target.name]=true
            local complete=true
            for _,name in ipairs(targets) do if not damageSeen[name] then complete=false end end
            if complete then pass("aa_damage") end
        end
        if priorDamage then return priorDamage(self,id,definition,team,damage,paralyze,weapon,projectile,attacker,attackerDefinition,attackerTeam,...) end
    end
    widgetHandler.UnitDamaged=damageHook;widgetHandler:UpdateCallIn("UnitDamaged")
end
function widget:UnitCreated(id,definition,team)
    local name=UnitDefs[definition].name
    if team==1 and targetNames[name] then expected[id]=name end
end
function widget:UnitDestroyed(id)
    if expected[id] then
        dead[expected[id]]=true;emit("destroyed="..expected[id].." frame="..Spring.GetGameFrame())
        if allDead() then pass("aa_destroyed") end
    end
end
local function spawn(name,count,team,x,z)
    Spring.SendCommands("give "..count.." "..name.." "..team.." @"..x..","..math.max(0,Spring.GetGroundHeight(x,z))..","..z)
end
function widget:GameFrame(frame)
    if frame==90 then Spring.SendCommands("cheat 1") end
    if frame==300 then
        position={Spring.GetTeamStartPosition(0)}
        local x,z=position[1],position[3]
        spawn("armeyes",1,0,x+350,z-550)
        spawn("armarad",1,0,x+300,z-250)
        spawn("corjugg",1,1,x+500,z-600)
        spawn(gunship,12,0,x+50,z-50)
        photo()
    end
    if spawnAt and frame>=spawnAt and not spawnFrame then
        spawnFrame=frame
        for index,name in ipairs(targets) do spawn(name,1,1,position[1]+380+index*70,position[3]-530) end
        emit("aa_spawn frame="..frame)
    end
    if frame==5300 then
        local count,repeated=0,0
        for id,value in pairs(orders) do count=count+value;repeated=repeated+(duplicates[id] or 0) end
        emit("commands attacks="..count.." repeated_target="..repeated)
    end
end
function widget:DrawScreen()
    if not camera or not position then return end
    Spring.SetCameraState({mode=1,px=position[1]+400,py=math.max(0,position[2]),pz=position[3]-400,height=1700,angle=0.8},0)
    camera.draws=camera.draws+1
    if camera.draws>=5 and Spring.DiffTimers(Spring.GetTimer(),camera.at)>=1 then
        Spring.SendCommands("screenshot png")
        Spring.SendCommands({"setmaxspeed 10","setminspeed 10","setmaxspeed 10"})
        camera=nil
    end
end
function widget:Shutdown()
    if widgetHandler.UnitCommand==commandHook then widgetHandler.UnitCommand=priorCommand;widgetHandler:UpdateCallIn("UnitCommand") end
    if widgetHandler.UnitDamaged==damageHook then widgetHandler.UnitDamaged=priorDamage;widgetHandler:UpdateCallIn("UnitDamaged") end
end
