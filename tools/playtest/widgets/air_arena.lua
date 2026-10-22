function widget:GetInfo()
    return {name="AIR combat arena",desc="Continuous supplied-force combat and measurements",author="CircuitAI",layer=125,enabled=true,handler=true}
end
local cfg=VFS.Include("LuaUI/Config/air_arena.lua")
local groups,units,pending,queue={},{},{},{}
local waves,current={},nil
local enabled=false
local camera,shots=nil,{}
local genericAttackShot,genericInterceptShot=false,false
local function event(kind,fields)
    local keys={}; for k in pairs(fields or {}) do keys[#keys+1]=k end;table.sort(keys)
    local line="[AirArena] event="..kind.." frame="..Spring.GetGameFrame()
    for _,k in ipairs(keys) do line=line.." "..k.."="..tostring(fields[k]) end
    Spring.Echo(line)
end
local function valid(id) return id and Spring.ValidUnitID(id) and not Spring.GetUnitIsDead(id) end
local function photograph(key,x,z,height)
    if camera or shots[key] then return end
    shots[key]=true
    Spring.SendCommands({"setmaxspeed 0.25","setminspeed 0.25","setmaxspeed 0.25"})
    local state={mode=1,px=x,py=math.max(0,Spring.GetGroundHeight(x,z)),pz=z,height=height or 2400,angle=0.8}
    Spring.SetCameraState(state,0)
    camera={key=key,at=Spring.GetTimer(),draws=0,state=state}
    event("camera",{key=key,x=math.floor(x),z=math.floor(z)})
end
local function position(g,index)
    local sites=cfg.sites[g.team+1]
    local p=g.position or sites[(index-1)%#sites+1]
    local spread=g.position and index-1 or math.floor((index-1)/#sites)
    local x=p[1]+(spread%4)*128
    local z=p[2]+math.floor(spread/4)*128
    local def=UnitDefNames[g.unit]
    if not def then return end
    if UnitDefs[def.id].canFly then
        -- Start boxes may touch the map edge. Formation/recon offsets are
        -- fixture-generated; keep aircraft inside the map on every refill.
        x=math.max(128,math.min(Game.mapSizeX-128,x))
        z=math.max(128,math.min(Game.mapSizeZ-128,z))
        return x,math.max(0,Spring.GetGroundHeight(x,z))+160,z
    end
    for r=0,960,64 do
        for dx=-r,r,64 do for dz=-r,r,64 do
            if r==0 or math.abs(dx)==r or math.abs(dz)==r then
                local px,pz=x+dx,z+dz
                if px>128 and pz>128 and px<Game.mapSizeX-128 and pz<Game.mapSizeZ-128 then
                    local y=Spring.GetGroundHeight(px,pz)
                    local wet=g.water==true
                    if (wet and y < -40 or not wet and y>5) and Spring.TestBuildOrder(def.id,px,y,pz,0)>0 then
                        return px,y,pz
                    end
                end
            end
        end end
    end
end
local function addGroup(g,kind)
    g.kind=kind;g.team=g.team or (kind=="aircraft" and 0 or 1)
    g.key=kind.."-"..(#groups+1);g.slots={};g.waiting={};g.spawned={}
    if not UnitDefNames[g.unit] then event("error",{reason="missing_unit",unit=g.unit});return end
    if kind=="aircraft" and not UnitDefs[UnitDefNames[g.unit].id].canFly then
        event("error",{reason="not_aircraft",unit=g.unit});return
    end
    groups[#groups+1]=g
end
local function refill(f)
    local count=0
    for _,g in ipairs(groups) do
        if f>=(g.after_seconds or 0)*30 and (g.team~=0 or g.kind~="aircraft" or f>=1350) then
            for i=1,g.count do if not valid(g.slots[i]) and not g.waiting[i] and not (g.once and g.spawned[i]) then
                local x,y,z=position(g,i)
                if x then
                    queue[#queue+1]={g=g,slot=i,x=x,y=y,z=z};g.waiting[i]=true;count=count+1
                else event("error",{reason="no_site",unit=g.unit,group=g.key}) end
            end end
        end
    end
    event("refill",{queued=count,groups=#groups})
end
local function receive(team,text)
    local data=text:match("^barb|arena|%d+|%d+|(.+)$")
    if not data then return end
    local args={};for part in data:gmatch("[^|]+") do args[#args+1]=part end
    if args[1]=="launch" then
        local id=tonumber(args[2]);local ids={}
        for s in args[6]:gmatch("%d+") do ids[#ids+1]=tonumber(s) end
        local w={id=id,target=tonumber(args[4]),members=ids,seen=false,damage=false,firstHit=false,launched=Spring.GetGameFrame(),landed={}}
        waves[id]=w;current=w
        event("launch",{wave=id,target=w.target,risk=args[5],ids=args[6],count=#ids})
        for _,u in ipairs(ids) do if units[u] then units[u].wave=id end end
        local x,_,z=Spring.GetUnitPosition(ids[1])
        if x and id<=3 then photograph("wave"..id.."-launch",x,z,2600) end
    elseif args[1]=="end" then
        local id=tonumber(args[2]);local w=waves[id]
        local living,home=0,0
        if w then
            for _,u in ipairs(w.members) do if valid(u) then
                living=living+1;local x,_,z=Spring.GetUnitPosition(u)
                if x and (x-cfg.homes[1][1])^2+(z-cfg.homes[1][2])^2<1800^2 then home=home+1 end
            end end
        end
        event("end",{wave=id,risk=args[4],survivors=living,home=home})
        -- Completed cohorts no longer accumulate losses on subsequent sorties.
        -- Do not retain every old wave in an indefinitely running arena.
        if w then
            for _,u in ipairs(w.members) do if units[u] and units[u].wave==id then units[u].wave=0 end end
        end
        waves[id]=nil
        if current and current.id==id then current=nil end
    elseif args[1]=="response" then
        event("response",{team=team,active=args[3],wave=current and current.id or 0})
    elseif args[1]=="commitment" then
        local w=waves[tonumber(args[2])]
        if w then w.returning=tonumber(args[6])==5;w.state=tonumber(args[6]) end
        event("commitment",{wave=args[2],escorts=args[3],owned=args[4],homeIntruders=args[5],state=args[6]})
    end
end
local function onDamage(id,def,team,damage,paralyzer,weapon,projectile,attacker,attackerDef,attackerTeam)
    if not enabled or not attacker or damage<=0 or not UnitDefs[def] or not UnitDefs[attackerDef] then return end
    if not team or not attackerTeam or team>1 or attackerTeam>1 or team==attackerTeam then return end
    local a,v=units[attacker],units[id]
    if not a and not v then return end
    local wave=attackerTeam==0 and a and a.wave or v and v.wave or 0
    local w=waves[wave]
    if v then v.lastAttacker=attacker;v.lastAttackerTeam=attackerTeam end
    event("damage",{wave=wave,victim=id,vdef=UnitDefs[def].name,attacker=attacker,adef=UnitDefs[attackerDef].name,
        amount=string.format("%.2f",damage),emp=paralyzer and 1 or 0,team=team,attackerTeam=attackerTeam})
    if w and v and v.team==0 and not w.firstHit then
        w.firstHit=true;local x,_,z=Spring.GetUnitPosition(id)
        event("first_hit",{wave=wave,source=UnitDefs[attackerDef].canFly and "fighter" or "aa",victim=id})
        if x and wave<=3 then photograph("wave"..wave.."-intercept",x,z,2000) end
    end
    if w and a and a.team==0 and id==w.target and not w.damage then
        w.damage=true;local x,_,z=Spring.GetUnitPosition(id)
        event("target_hit",{wave=wave,target=id,emp=paralyzer and 1 or 0})
        if x and wave<=8 then photograph("wave"..wave.."-target",x,z,2200) end
    end
    if w and a and a.team==0 and id~=w.target and not w.cleanupShot and not camera then
        local x,_,z=Spring.GetUnitPosition(id)
        if x then w.cleanupShot=true;photograph("wave"..wave.."-cleanup",x,z,2200) end
    end
    if not w and not camera and a and a.team==0 and a.kind=="aircraft" and not genericAttackShot then
        local x,_,z=Spring.GetUnitPosition(id)
        if x then genericAttackShot=true;photograph("native-aircraft-strike",x,z,2000) end
    elseif not w and not camera and v and v.team==0 and v.kind=="aircraft" and not genericInterceptShot then
        local x,_,z=Spring.GetUnitPosition(id)
        if x then genericInterceptShot=true;photograph("native-aircraft-intercept",x,z,2000) end
    end
end
-- Opt-in, independent engine observer. It never assigns tasks or orders.
local function observePriorityContact(f)
    if not cfg.priority_targets then return end
    for _,w in pairs(waves) do if w.state==3 and not w.returning then
        local cx,cz,alive=0,0,0
        for _,id in ipairs(w.members) do if valid(id) then
            local x,_,z=Spring.GetUnitPosition(id)
            if x then cx=cx+x;cz=cz+z;alive=alive+1 end
        end end
        if alive>0 then
            cx=cx/alive;cz=cz/alive
            w.contacts=w.contacts or {}
            for id,u in pairs(units) do if u.team==1 and cfg.priority_targets[UnitDefs[u.def].name] and valid(id) then
                local x,_,z=Spring.GetUnitPosition(id)
                local los=Spring.GetUnitLosState(id,0,false)
                local distance=x and math.sqrt((x-cx)^2+(z-cz)^2) or math.huge
                if los and los.los and distance<=(cfg.priority_radius or 1800) then
                    local contact=w.contacts[id]
                    if not contact then
                        contact={frame=f};w.contacts[id]=contact
                        event("priority_visible",{wave=w.id,target=id,distance=math.floor(distance),alive=alive})
                        photograph("wave"..w.id.."-priority-visible",x,z,2600)
                    end
                    local attacking=0
                    for _,bomber in ipairs(w.members) do if valid(bomber) then
                        local orders=Spring.GetUnitCommands(bomber,1) or {}
                        if orders[1] and orders[1].id==CMD.ATTACK and orders[1].params[1]==id then attacking=attacking+1 end
                    end end
                    if attacking==alive and not contact.attack then
                        contact.attack=f
                        event("priority_attack",{wave=w.id,target=id,delayFrames=f-contact.frame,alive=alive,distance=math.floor(distance)})
                    elseif not contact.attack and not contact.failed and f-contact.frame>30 then
                        contact.failed=true
                        event("priority_delay",{wave=w.id,target=id,delayFrames=f-contact.frame,attacking=attacking,alive=alive})
                        Spring.Echo("[INVARIANT] INV-121 AIR arena: local visible priority target waiting for bomber ATTACK")
                    end
                end
            end end
        end
    end end
end
-- A route log is only a plan. Record the live cohort crossing the guarded
-- corridor, with a configurable open band on either side (fixture only).
local function observeRoute(f)
    local probe=cfg.route_probe
    if not probe then return end
    for _,w in pairs(waves) do if w.state==3 and not w.returning then
        local cx,cz,alive=0,0,0
        for _,id in ipairs(w.members) do if valid(id) then
            local x,_,z=Spring.GetUnitPosition(id)
            if x then cx=cx+x;cz=cz+z;alive=alive+1 end
        end end
        if alive>0 then
            cx=cx/alive;cz=cz/alive
            local along=probe.axis=="x" and cx or cz
            local across=probe.axis=="x" and cz or cx
            if not w.routeCrossed then
                event("route_position",{wave=w.id,alive=alive,x=math.floor(cx),z=math.floor(cz)})
                if w.routePrevious and (w.routePrevious-probe.crossing)*(along-probe.crossing)<=0 then
                    w.routeCrossed=true
                    local safe=across<=probe.safe_below or across>=probe.safe_above
                    event("route_crossing",{wave=w.id,alive=alive,x=math.floor(cx),z=math.floor(cz),flank=safe and 1 or 0})
                    photograph("wave"..w.id.."-flank-crossing",cx,cz,probe.height or 6500)
                    local original=units[w.target]
                    local requireTarget=not probe.target_units or (original and probe.target_units[UnitDefs[original.def].name])
                    -- A later frontline-cleanup wave is meant to enter the
                    -- defended corridor. Enforce flank geometry only for the
                    -- scenario's declared backline targets, when specified.
                    if not safe and probe.require_flank~=false and requireTarget then
                        event("error",{reason="direct_corridor_crossed",wave=w.id})
                    end
                end
            end
            w.routePrevious=along
        end
    end end
end
function widget:Initialize()
    for _,g in ipairs(cfg.targets) do addGroup(g,"target") end
    for _,g in ipairs(cfg.defenses) do addGroup(g,"defense") end
    for _,g in ipairs(cfg.sensors or {}) do addGroup(g,"sensor") end
    for team=0,1 do
        for _,site in ipairs(cfg.sites[team+1]) do
            local wet=Spring.GetGroundHeight(site[1],site[2]) < -40
            addGroup({unit=wet and "armfrad" or "armrad",team=team,count=1,position=site,water=wet},"radar")
        end
    end
    for _,g in ipairs(cfg.aircraft) do addGroup(g,"aircraft") end
    -- Real scouts at the target region establish identification once; their
    -- subsequent commands, losses and rediscovery remain normal AI behavior.
    for _,g in ipairs(cfg.targets) do
        local p=g.position or cfg.sites[2][1]
        addGroup({unit=cfg.scout or "armpeep",team=0,count=1,position={p[1]-320,p[2]+320}},"recon")
    end
    -- BAR's barwidgets sandbox hands user widgets a proxy widgetHandler
    -- (assigning widgetHandler.UnitDamaged only logs "not available to user
    -- widgets"), refuses getfenv/setfenv, and keeps RecvSkirmishAIMessage out
    -- of its callin lists. The callins are therefore plain widget methods
    -- below (2026-10-14 arena runs had no damage/launch events at all). AI
    -- messages (launch/end/response/commitment) only arrive if the handler
    -- forwards widget:RecvSkirmishAIMessage; checks must not depend on them.
    event("loaded",{case=cfg.name,visibility=cfg.visibility,endless=cfg.endless and 1 or 0})
    for id,d in pairs(UnitDefs) do
        if d.canFly and (d.name:sub(1,3)=="arm" or d.name:sub(1,3)=="cor" or d.name:sub(1,3)=="leg")
            and not d.name:find("_scav") then
            event("catalog",{unit=d.name,cost=d.metalCost or 0,builder=d.isBuilder and 1 or 0,
                transport=(d.transportCapacity or 0)>0 and 1 or 0,weapons=#(d.weapons or {})})
        end
    end
end
function widget:UnitCreated(id,def,team)
    for i,p in ipairs(pending) do
        if team==p.g.team and UnitDefs[def].name==p.g.unit then
            units[id]={team=team,def=def,kind=p.g.kind,group=p.g.key,wave=0}
            p.g.slots[p.slot]=id;p.g.waiting[p.slot]=nil;p.g.spawned[p.slot]=true;table.remove(pending,i)
            event("spawn",{id=id,team=team,unit=p.g.unit,kind=p.g.kind,group=p.g.key,cost=UnitDefs[def].metalCost,x=math.floor(p.x),z=math.floor(p.z)})
            return
        end
    end
end
function widget:UnitDestroyed(id,def,team)
    local u=units[id]
    if not u then return end
    event("death",{id=id,unit=UnitDefs[def].name,team=team,kind=u.kind,wave=u.wave or 0,
        attacker=u.lastAttacker or -1,attackerTeam=u.lastAttackerTeam or -1,cost=UnitDefs[def].metalCost})
    for _,w in pairs(waves) do if not w.ended and w.target==id then event("target_dead",{wave=w.id,target=id,cost=UnitDefs[def].metalCost}) end end
    units[id]=nil
end
function widget:UnitFinished(id,def,team)
    if not cfg.factory_production or team~=0 or units[id] or not UnitDefs[def].canFly then return end
    -- Spawned aircraft already entered through the pending fixture queue.
    -- These are real completed factory outputs, not supplied replacements.
    units[id]={team=team,def=def,kind="aircraft",group="production",wave=0}
    event("spawn",{id=id,team=team,unit=UnitDefs[def].name,kind="aircraft",group="production",cost=UnitDefs[def].metalCost})
    event("produced",{id=id,team=team,unit=UnitDefs[def].name})
end
function widget:GameFrame(f)
    for _,shot in ipairs(cfg.screenshots or {}) do
        if f>=shot.second*30 and f<shot.second*30+60 then
            photograph("perimeter-"..shot.second,shot.x,shot.z,shot.height)
        end
    end
    if f==150 then
        Spring.SendCommands("cheat 1")
        if cfg.visibility=="global" then Spring.SendCommands("globallos") end
        enabled=true;event("ready",{visibility=cfg.visibility})
    end
    if not enabled then return end
    if f%5==0 then observePriorityContact(f) end
    if f%60==0 then observeRoute(f) end
    if f==300 or f%((cfg.refill_seconds or 45)*30)==0 then refill(f) end
    if #queue>0 and f%3==0 then
        local p=table.remove(queue,1);p.sent=f;pending[#pending+1]=p
        Spring.SendCommands(string.format("give 1 %s %d @%d,%d,%d",p.g.unit,p.g.team,p.x,p.y,p.z))
    end
    for i=#pending,1,-1 do
        if f-pending[i].sent>300 then
            event("error",{reason="spawn_timeout",unit=pending[i].g.unit})
            pending[i].g.waiting[pending[i].slot]=nil;table.remove(pending,i)
        end
    end
    if f%300==0 then
        Spring.SendLuaRulesMsg("$dev$:loadmissiles")
        for team=0,1 do
            local e,storage,_,income=Spring.GetTeamResources(team,"energy")
            event("energy",{team=team,current=math.floor(e or 0),storage=math.floor(storage or 0),income=math.floor(income or 0)})
        end
    end
    if f%15==0 and current and not current.seen then
        for _,id in ipairs(current.members) do if valid(id) then
            local state=Spring.GetUnitLosState(id,1,false)
            if state and (state.los or state.radar) then
                current.seen=true;event("detected",{wave=current.id,unit=id,los=state.los and 1 or 0,radar=state.radar and 1 or 0});break
            end
        end end
    end
    if f%900==0 then
        local n0,n1,seen,targets=0,0,0,0
        for id,u in pairs(units) do if valid(id) then
            if u.kind=="aircraft" then if u.team==0 then n0=n0+1 else n1=n1+1 end end
            if u.kind=="target" and u.team==1 then
                targets=targets+1;local state=Spring.GetUnitLosState(id,0,false)
                if state and (state.los or state.radar) then seen=seen+1 end
            end
        end end
        event("sample",{attackers=n0,fighters=n1,wave=current and current.id or 0,targets=targets,seenTargets=seen})
        if f==1800 then photograph("arena-overview",Game.mapSizeX/2,Game.mapSizeZ/2,15000) end
    end
    if f%150==0 then
        for _,w in pairs(waves) do
            local alive,landed,autoLand=0,0,0
            for _,id in ipairs(w.members) do if valid(id) then
                alive=alive+1
                local movement=Spring.GetUnitMoveTypeData(id) or {}
                local state=Spring.GetUnitStates(id) or {}
                if state.autoland then autoLand=autoLand+1 end
                if movement.aircraftState=="landed" or movement.aircraftState=="landing" then
                    landed=landed+1
                    if not w.returning and f>w.launched+150 and not w.landed[id] then
                        w.landed[id]=true
                        event("flight_landing",{wave=w.id,id=id,state=movement.aircraftState,autoland=state.autoland})
                        Spring.Echo("[INVARIANT] INV-116 AIR arena: active bomber landed outside defensive return id="..id)
                        local x,_,z=Spring.GetUnitPosition(id)
                        if x then photograph("wave"..w.id.."-landing",x,z,2200) end
                    end
                end
            end end
            event("flight",{wave=w.id,alive=alive,landed=landed,autoland=autoLand})
        end
    end
end
function widget:DrawScreen()
    if camera then
        Spring.SetCameraState(camera.state,0)
        camera.draws=camera.draws+1
        if camera.draws>=5 and Spring.DiffTimers(Spring.GetTimer(),camera.at)>=1 then
            local state=Spring.GetCameraState()
            Spring.SendCommands("screenshot png");event("screenshot",{key=camera.key,x=math.floor(state.px or 0),z=math.floor(state.pz or 0)})
            Spring.SendCommands({"setmaxspeed "..cfg.speed,"setminspeed "..cfg.speed,"setmaxspeed "..cfg.speed});camera=nil
        end
    end
    gl.Text("AIR COMBAT ARENA: "..cfg.name.." | "..cfg.visibility.." | supplied forces, automatic refill",20,90,16,"o")
end
function widget:UnitDamaged(id,def,team,damage,paralyzer,weapon,projectile,attacker,attackerDef,attackerTeam)
    -- The handler forwards only the first five arguments; recover the attacker.
    if attacker==nil then
        attacker=Spring.GetUnitLastAttacker(id)
        if attacker and attacker>=0 then attackerDef=Spring.GetUnitDefID(attacker);attackerTeam=Spring.GetUnitTeam(attacker) else attacker=nil end
    end
    onDamage(id,def,team,damage,paralyzer,weapon,projectile,attacker,attackerDef,attackerTeam)
end
function widget:RecvSkirmishAIMessage(team,text)
    if type(text)=="string" then receive(team,text) end
end
