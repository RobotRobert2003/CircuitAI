function widget:GetInfo() return {name="AIR naval support fixture",layer=126,enabled=true,handler=true} end
local cfg=VFS.Include("LuaUI/Config/air_naval_support.lua")
local roster={armada={"armawac","armlance","armaap","armca","armaca","armhawk"},cortex={"corawac","cortitan","coraap","corca","coraca","corvamp"},legion={"legwhisper","legatorpbomber","legaap","legca","legaca","legvenator"}}
local r=roster[cfg.side];local queue,shots,seen={},{},{}
local camera,priorDamage,damageHook;local damage=0;local dead=0;local threatened,aaX,aaZ,escaped
local function log(s)Spring.Echo("[AirNavalWatch] "..s)end
local function give(name,n,team,x,z)
    if cfg.map=="glacial" then
        if x<4000 and z>10000 then x,z=490+x-2155,1140+z-11747
        elseif x==6500 and z==11400 then x,z=2300,4600
        elseif x==6500 and z==10800 then x,z=2600,4400
        elseif x==7500 and z==9500 then x,z=3500,4650
        elseif x==7500 and z==9000 then x,z=3900,4400
        elseif x==7600 and z==9100 then x,z=4000,4300 end
    end
    log("spawn def="..name.." n="..n.." team="..team.." x="..x.." z="..z.." ground="..Spring.GetGroundHeight(x,z))
    queue[#queue+1]="give "..n.." "..name.." "..team.." @"..x..","..math.max(0,Spring.GetGroundHeight(x,z))..","..z
end
local function photo(key,x,z,h)
    if camera or shots[key] or cfg.headless then return end
    shots[key]=true;Spring.SendCommands({"setminspeed 0.25","setmaxspeed 0.25"})
    camera={key=key,at=Spring.GetTimer(),draws=0,state={mode=1,px=x,py=0,pz=z,height=h or 4000,angle=.8}}
end
function widget:Initialize()
    priorDamage=widgetHandler.UnitDamaged
    damageHook=function(self,id,def,team,amount,emp,weapon,projectile,attacker,attackerDef,attackerTeam,...)
        if team==2 and attackerTeam==0 and UnitDefs[attackerDef or -1] and UnitDefs[attackerDef].name==r[2] then
            damage=damage+amount
            if not seen[id] then seen[id]=true;log("torpedo_damage frame="..Spring.GetGameFrame().." victim="..UnitDefs[def].name.." amount="..amount)
                local x,_,z=Spring.GetUnitPosition(id);if x then photo("torpedo-hit",x,z,3000)end
            end
        end
        if priorDamage then return priorDamage(self,id,def,team,amount,emp,weapon,projectile,attacker,attackerDef,attackerTeam,...)end
    end
    widgetHandler.UnitDamaged=damageHook;widgetHandler:UpdateCallIn("UnitDamaged");log("loaded case="..cfg.case)
end
function widget:UnitFinished(id,def,team)
    if team==0 and UnitDefs[def].name==r[2] then log("torpedo_finished frame="..Spring.GetGameFrame().." id="..id)end
end
function widget:UnitDestroyed(id,def,team)
    if id==threatened and not escaped then log("AA_escape_failed frame="..Spring.GetGameFrame())end
    if team==2 and (UnitDefs[def].name=="armroy" or UnitDefs[def].name=="corsub") then dead=dead+1;log("naval_kill frame="..Spring.GetGameFrame().." def="..UnitDefs[def].name)end
end
function widget:GameFrame(f)
    if f==150 then Spring.SendCommands("cheat 1")end
    if f==300 and not cfg.recon then
        give(r[4],3,0,2250,11700);give(r[5],2,0,2350,11700)
        give(r[3],1,0,2600,11200);give("armnanotc",12,0,2750,11200);give("armafus",3,0,2700,11800)
        give(r[6],16,0,2300,11800)
        if cfg.case~="remote" then
            give("armsy",1,1,6500,11400)
            if cfg.case~="factory" then give(cfg.case=="sub" and "armpt" or "armroy",cfg.case=="parity" and 8 or cfg.case=="sub" and 30 or 1,1,6500,10800)end
        end
        give("armfrad",1,0,7500,9500);give("armason",1,0,7500,9500)
    end
    if f==1800 then
        if cfg.recon then give(r[1],cfg.case=="full" and 20 or (cfg.case=="patrol" or cfg.case=="zero") and 8 or 3,0,2155,11747)
        else
            give(cfg.case=="hover" and "armsh" or cfg.case=="sub" and "corsub" or "armroy",6,2,cfg.case=="basin" and 3000 or 7500,cfg.case=="basin" and 3000 or 9000)
            if cfg.case=="basin" then give("armfrad",1,0,3000,3500)end
            if cfg.case=="danger" then give("armaas",8,2,7500,9000)end
            if cfg.case=="aa" then give("armpt",2,2,7600,9100)end
            if cfg.case~="naval" then give(r[2],cfg.case=="stall" and 2 or 20,0,2155,11747)end
        end
    end
    if f==3300 and (cfg.case=="patrol" or cfg.case=="zero") then
        local planes=Spring.GetTeamUnitsByDefs(0,UnitDefNames[r[1]].id);table.sort(planes)
        local chosen=planes[1]
        if cfg.case=="zero" then
            for _,id in ipairs(planes)do local x,_,z=Spring.GetUnitPosition(id);if Spring.GetGroundHeight(x,z)<-30 then chosen=id;break end end
        end
        if chosen then
            local x,_,z=Spring.GetUnitPosition(chosen);threatened=chosen;aaX=x;aaZ=z;
            give(cfg.case=="zero" and "corcrus" or Spring.GetGroundHeight(x,z)<0 and "corfship" or "corflak",1,2,x,z)
            give("armpeep",1,1,x,z);log("new_AA frame="..f.." at="..x..","..z)
        end
    end
    if f%5==0 and #queue>0 then Spring.SendCommands(table.remove(queue,1))end
    if threatened and not escaped and f%30==0 then
        local x,_,z=Spring.GetUnitPosition(threatened)
        if x and (x-aaX)^2+(z-aaZ)^2>1500^2 then escaped=true;log("AA_escape frame="..f.." plane="..threatened) end
    end
    if f%300==0 then
        local planes=Spring.GetTeamUnitsByDefs(0,UnitDefNames[cfg.recon and r[1] or r[2]].id)
        local airborne,patrol,attacking=0,0,0;local minx,maxx,minz,maxz=1e9,-1e9,1e9,-1e9
        for _,id in ipairs(planes)do
            local x,_,z=Spring.GetUnitPosition(id);minx=math.min(minx,x);maxx=math.max(maxx,x);minz=math.min(minz,z);maxz=math.max(maxz,z)
            local move=Spring.GetUnitMoveTypeData(id);if move and move.aircraftState~="landed" then airborne=airborne+1 end
            for _,cmd in ipairs(Spring.GetUnitCommands(id,6) or {})do if cmd.id==CMD.PATROL then patrol=patrol+1;break end end
            local commands=Spring.GetUnitCommands(id,1);if commands and commands[1] and commands[1].id==CMD.ATTACK then attacking=attacking+1 end
        end
        log("census frame="..f.." planes="..#planes.." airborne="..airborne.." patrol="..patrol.." attacking="..attacking.." span="..math.floor(maxx-minx)..","..math.floor(maxz-minz).." damage="..math.floor(damage).." dead="..dead)
        if cfg.recon and #planes>0 and f==3000 then photo("safe-patrols",6000,7200,14000)end
        if cfg.recon and #planes>0 and f==4200 then photo("after-AA",6000,7200,14000)end
        if not cfg.recon and f==3000 then photo("naval-relief",7000,9600,6500)end
    end
end
function widget:Update()
    if not camera then return end
    Spring.SetCameraState(camera.state,0);camera.draws=camera.draws+1
    if camera.draws>=5 and Spring.DiffTimers(Spring.GetTimer(),camera.at)>=1 then
        Spring.SendCommands("screenshot png");log("screenshot="..camera.key)
        Spring.SendCommands({"setmaxspeed "..cfg.speed,"setminspeed "..cfg.speed});camera=nil
    end
end
function widget:Shutdown()
    if widgetHandler.UnitDamaged==damageHook then widgetHandler.UnitDamaged=priorDamage;widgetHandler:UpdateCallIn("UnitDamaged")end
end
