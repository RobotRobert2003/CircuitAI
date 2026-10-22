function widget:GetInfo() return {name="SEA economy block observer",layer=126,enabled=true,handler=true} end
local plan,prior,hook
local seen,completed={},{}
local function log(s) Spring.Echo("[SeaBlock] "..s) end
local function distance(x,z,bx,bz) return (x-bx)^2+(z-bz)^2 end
local function along(x,z)
    if plan.f==0 then return z-plan.hz elseif plan.f==1 then return x-plan.hx
    elseif plan.f==2 then return plan.hz-z else return plan.hx-x end
end
function widget:Initialize()
    local env=getfenv(0);prior=rawget(env,"RecvSkirmishAIMessage")
    hook=function(team,text)
        local x,z,hx,hz,fx,fz,f=text:match("^barb|seablock|%d+|%d+|plan|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|(%d+)$")
        if team==0 and x then
            plan={x=tonumber(x),z=tonumber(z),hx=tonumber(hx),hz=tonumber(hz),fx=tonumber(fx),fz=tonumber(fz),f=tonumber(f)}
            log("plan received")
        end
        if prior then return prior(team,text) end
    end
    rawset(env,"RecvSkirmishAIMessage",hook);Script.UpdateCallIn("RecvSkirmishAIMessage")
end
function widget:GameFrame(frame)
    if not plan or frame%30~=0 then return end
    local groups,nanos,factories,fusion={},{},{},nil
    for _,id in ipairs(Spring.GetTeamUnits(0)) do
        local d=UnitDefs[Spring.GetUnitDefID(id)]
        local _,_,_,_,progress=Spring.GetUnitHealth(id)
        if d.name=="armuwfus" then fusion=id end
        if progress and progress>=1 then
            if d.name=="armnanotcplat" then nanos[#nanos+1]=id end
            if d.name=="armsy" or d.name=="armamsub" then factories[#factories+1]=id end
            groups[d.name]=groups[d.name] or {};table.insert(groups[d.name],id)
        end
    end
    for name,want in pairs({armfmkr=12,armuwmmm=8}) do
        local ids=groups[name] or {}
        if #ids>=want and not seen[name] then
            local edges=0
            for i,id in ipairs(ids) do
                local x,_,z=Spring.GetUnitPosition(id)
                if math.abs(x-plan.x)>320 or math.abs(z-plan.z)>320 then log("FAIL converter outside block "..name) end
                local d=UnitDefNames[name];local rotate=(Spring.GetUnitBuildFacing(id) or 0)%2==1
                local w,h=(rotate and d.zsize or d.xsize)*8,(rotate and d.xsize or d.zsize)*8
                for j=i+1,#ids do
                    local bx,_,bz=Spring.GetUnitPosition(ids[j]);local dx,dz=math.abs(x-bx),math.abs(z-bz)
                    if (math.abs(dx-w)<1 and dz<1) or (math.abs(dz-h)<1 and dx<1) then edges=edges+1 end
                end
            end
            log((edges>=(name=="armfmkr" and 9 or 4) and "PASS" or "FAIL").." packed "..name.." count="..#ids.." edges="..edges)
            seen[name]=true
        end
    end
    for _,nano in ipairs(nanos) do
        local x,_,z=Spring.GetUnitPosition(nano)
        local useful=distance(x,z,plan.fx,plan.fz)<=400^2
        local cmd,_,_,target=Spring.GetUnitCurrentCommand(nano)
        for _,factory in ipairs(factories) do
            local bx,_,bz=Spring.GetUnitPosition(factory)
            if distance(x,z,bx,bz)<=400^2 then
                useful=true
                local product=Spring.GetUnitIsBuilding(factory)
                local name=UnitDefs[Spring.GetUnitDefID(factory)].name
                if not seen[name] and product and (cmd==CMD.REPAIR or cmd==CMD.GUARD) and (target==factory or target==product) then
                    log("PASS factory assist "..name);seen[name]=true
                end
            end
        end
        if not useful and not seen[nano] then log("FAIL orphan turret "..nano);seen[nano]=true end
        if fusion and target==fusion and (cmd==CMD.REPAIR or cmd==CMD.GUARD) and not seen.assist then
            log("PASS fusion assist");seen.assist=true
        end
    end
    if not seen.square then
        local xs,zs={},{};local n=0
        for _,id in ipairs(nanos) do
            local x,_,z=Spring.GetUnitPosition(id)
            if math.abs(x-plan.x)<120 and math.abs(z-plan.z)<120 then
                xs[x]=true;zs[z]=true;n=n+1
            end
        end
        local function lattice(coords)
            local values={};for p in pairs(coords) do values[#values+1]=p end;table.sort(values)
            for i=2,#values do if (values[i]-values[1])%48~=0 then return false,#values end end
            return #values<=4,#values
        end
        local gx,nx=lattice(xs);local gz,nz=lattice(zs)
        if n>=4 and nx>=2 and nz>=2 then
            log((gx and gz and "PASS" or "FAIL").." square turret grid count="..n.." columns="..nx.." rows="..nz)
            seen.square=true
        end
    end
    if fusion and not seen.fusion then
        local _,_,_,_,progress=Spring.GetUnitHealth(fusion)
        if progress and progress>=1 then
            local x,_,z=Spring.GetUnitPosition(fusion)
            local d=UnitDefNames.armuwfus
            local half=((plan.f%2==0) and d.zsize or d.xsize)*4
            log((along(x,z)+half<=-64 and "PASS" or "FAIL").." rear fusion completed");seen.fusion=true
            Spring.SetCameraState({name="ta",px=6200,pz=11000,height=2200},0)
            Spring.SendCommands("screenshot png")
        end
    end
end
function widget:UnitFinished(id,def,team)
    if team==0 and UnitDefs[def].name=="armfmkr" then completed[id]=true end
end
function widget:UnitDestroyed(id,def,team)
    if team==0 and UnitDefs[def].name=="armfmkr" then
        log(completed[id] and "FAIL completed T1 converter removed in uncontested block" or "frame-loss T1 converter before completion")
    end
    completed[id]=nil
end
function widget:Shutdown()
    local env=getfenv(0)
    if rawget(env,"RecvSkirmishAIMessage")==hook then rawset(env,"RecvSkirmishAIMessage",prior);Script.UpdateCallIn("RecvSkirmishAIMessage") end
end
