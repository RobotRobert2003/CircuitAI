function widget:GetInfo() return {name="AIR response fixture",layer=126,enabled=true,handler=true} end
local cfg=VFS.Include("LuaUI/Config/air_response.lua")
local queue,seen,shots={},{},{}
local camera,priorDamage,damageHook
local roster={armada={"armawac","armpnix","armaap","armbrawl","armca","armaca","armap","armkam"},
    cortex={"corawac","corhurc","coraap","corape","corca","coraca","corap","corshad"},
    legion={"legwhisper","legphoenix","legaap","legstronghold","legca","legaca","legap","legmos"}}
local r=roster[cfg.side]
local function log(s) Spring.Echo("[AirResponseWatch] "..s) end
local function give(name,n,team,x,z) queue[#queue+1]="give "..n.." "..name.." "..team.." @"..x..","..math.max(0,Spring.GetGroundHeight(x,z))..","..z end
local function photo(key,x,z,h)
    if camera or shots[key] then return end
    shots[key]=true;Spring.SendCommands({"setminspeed 0.25","setmaxspeed 0.25"})
    camera={key=key,at=Spring.GetTimer(),draws=0,state={mode=1,px=x,py=math.max(0,Spring.GetGroundHeight(x,z)),pz=z,height=h or 2700,angle=.8}}
end
function widget:Initialize()
    priorDamage=widgetHandler.UnitDamaged
    damageHook=function(self,id,def,team,damage,emp,weapon,projectile,attacker,attackerDef,attackerTeam,...)
        if team==2 and attackerTeam==0 and UnitDefs[attackerDef or -1] then
            local name=UnitDefs[attackerDef].name
            if not seen[name] then
                seen[name]=true;log("damage frame="..Spring.GetGameFrame().." attacker="..name.." victim="..UnitDefs[def].name.." amount="..damage.." emp="..tostring(emp))
                local x,_,z=Spring.GetUnitPosition(id);if x then photo("hit-"..name,x,z) end
            end
        end
        if priorDamage then return priorDamage(self,id,def,team,damage,emp,weapon,projectile,attacker,attackerDef,attackerTeam,...) end
    end
    widgetHandler.UnitDamaged=damageHook;widgetHandler:UpdateCallIn("UnitDamaged")
    log("loaded case="..cfg.case)
end
function widget:UnitFinished(id,def,team)
    local name=UnitDefs[def].name
    if team==0 and (name==r[4] or name==r[8] or name=="corbw") then log("finished frame="..Spring.GetGameFrame().." def="..name.." id="..id) end
end
function widget:UnitDestroyed(id,def,team)
    if team==2 and UnitDefs[def].name=="armmar" then log("marauder_destroyed frame="..Spring.GetGameFrame().." id="..id) end
end
function widget:GameFrame(f)
    if f==150 then Spring.SendCommands("cheat 1") end
    if f==300 and not cfg.recon then
        give(r[5],3,0,2250,11700);give(r[6],2,0,2350,11700)
        give(cfg.case=="t1" and r[7] or r[3],1,0,2600,11200)
        give("armnanotc",12,0,2750,11200)
        give("armafus",3,0,2700,11800)
        give("armeyes",2,0,1000,9750);give("armarad",1,0,1300,10100)
        if cfg.case~="t1" then give(r[2],cfg.case=="small" and 2 or 18,0,2300,11750) end
        log("supplied factory economy and idle bombers; defender policy unchanged")
    end
    if f==1800 and cfg.recon then give(r[1],cfg.case=="full" and 20 or 3,0,2155,11747) end
    if f==2400 and not cfg.recon then photo("ready-idle-aircraft",2300,11400,3200) end
    if not cfg.recon and (f==2700 or f==6300) then
        local x,z=1000,9400
        if cfg.case=="outside" then x,z=4400,7400 end
        if f==6300 then give("armeyes",2,0,x,z+350) end
        give("armmar",cfg.case=="small" and 1 or 12,2,x,z);log("intrusion frame="..f.." x="..x.." z="..z)
    end
    if f%5==0 and #queue>0 then Spring.SendCommands(table.remove(queue,1)) end
    if f%300==0 then
        if cfg.recon then
            local n,xsum,zsum=0,0,0
            for _,id in ipairs(Spring.GetTeamUnitsByDefs(0,UnitDefNames[r[1]].id)) do
                local x,_,z=Spring.GetUnitPosition(id);if x then n=n+1;xsum=xsum+x;zsum=zsum+z end
            end
            if n>0 and f>=5400 then photo("recon-crossing",xsum/n,zsum/n,10000) end
        else
            local attack,landed=0,0
            for _,id in ipairs(Spring.GetTeamUnits(0)) do
                local d=UnitDefs[Spring.GetUnitDefID(id)]
                if d.name==r[2] then
                    local cs=Spring.GetUnitCommands(id,1)
                    if cs and cs[1] and cs[1].id==CMD.ATTACK then attack=attack+1 end
                    local state=Spring.GetUnitMoveTypeData(id)
                    if state and state.aircraftState=="landed" then landed=landed+1 end
                end
            end
            log("census frame="..f.." bomber_attack="..attack.." bomber_landed="..landed)
        end
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
    if widgetHandler.UnitDamaged==damageHook then widgetHandler.UnitDamaged=priorDamage;widgetHandler:UpdateCallIn("UnitDamaged") end
end
