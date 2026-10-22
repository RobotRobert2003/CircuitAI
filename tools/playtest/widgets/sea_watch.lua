function widget:GetInfo()
    return {name="SEA economy and egress observer",desc="Read-only naval benchmark census",author="CircuitAI",layer=114,enabled=true}
end
local born, pendingExit = {}, {}
local function log(s) Spring.Echo("[SeaWatch] "..s) end
local function yard(d) return d.isFactory and (d.minWaterDepth or 0)>0 and not d.canFly end
local function advanced(d) return d.name=="armasy" or d.name=="corasy" or d.name=="legadvshipyard" end
function widget:Initialize() log("loaded") end
function widget:UnitCreated(id,def,team,builder)
    if team~=0 then return end
    born[id]={frame=Spring.GetGameFrame(),builder=builder}
    if advanced(UnitDefs[def]) and builder then
        local x,_,z=Spring.GetUnitPosition(id)
        if not x then return end
        local count=0
        -- Test-only event census, not a recurring gameplay poll.
        for _,unit in ipairs(Spring.GetTeamUnits(team)) do
            local d=UnitDefs[Spring.GetUnitDefID(unit)]
            if d and d.isBuilder and d.isImmobile and not d.isFactory and (d.buildSpeed or 0)>0 then
                local _,_,_,_,progress=Spring.GetUnitHealth(unit)
                local nx,_,nz=Spring.GetUnitPosition(unit)
                if progress and progress>=1 and nx and (nx-x)^2+(nz-z)^2<=(d.buildDistance or 0)^2 then count=count+1 end
            end
        end
        log(string.format("t2-start frame=%d id=%d support=%d",Spring.GetGameFrame(),id,count))
    end
end
function widget:UnitFinished(id,def,team)
    if team~=0 then return end
    local d=UnitDefs[def]
    local b=born[id]
    log(string.format("finished frame=%d id=%d def=%s builder=%s",Spring.GetGameFrame(),id,d.name,tostring(b and b.builder)))
    if advanced(d) and b and b.builder then
        log(string.format("t2-complete id=%d seconds=%.1f",id,(Spring.GetGameFrame()-b.frame)/30))
    end
    if b and b.builder then
        local bd=Spring.GetUnitDefID(b.builder)
        if bd and yard(UnitDefs[bd]) and not d.canFly and not d.isImmobile then
            local x,_,z=Spring.GetUnitPosition(b.builder)
            pendingExit[id]={frame=Spring.GetGameFrame(),yard=b.builder,x=x,z=z,worker=d.isBuilder}
        end
    end
end
function widget:UnitDestroyed(id) born[id]=nil; pendingExit[id]=nil end
function widget:GameFrame(f)
    if f%30~=0 then return end
    for id,p in pairs(pendingExit) do
        local x,_,z=Spring.GetUnitPosition(id)
        if not x then pendingExit[id]=nil
        elseif (x-p.x)^2+(z-p.z)^2>320^2 then
            log(string.format("egress id=%d yard=%d seconds=%.1f worker=%s",id,p.yard,(f-p.frame)/30,tostring(p.worker)))
            pendingExit[id]=nil
        elseif f-p.frame>=1800 and not p.warned then
            p.warned=true
            log("exit-delay id="..id.." yard="..p.yard.." seconds=60 worker="..tostring(p.worker))
        end
    end
    if f%900~=0 then return end
    local counts,fac,busy,bp,idle= {},0,0,0,0
    for _,id in ipairs(Spring.GetTeamUnits(0)) do
        local d=UnitDefs[Spring.GetUnitDefID(id)]
        local _,_,_,_,progress=Spring.GetUnitHealth(id)
        if progress and progress>=1 then
            counts[d.name]=(counts[d.name] or 0)+1
            local cmds=Spring.GetUnitCommands(id,1) or {}
            if yard(d) then fac=fac+1; if Spring.GetUnitIsBuilding(id) then busy=busy+1 end end
            if d.isBuilder then bp=bp+(d.buildSpeed or 0); if #cmds==0 then idle=idle+(d.buildSpeed or 0) end end
        end
    end
    local m,ms,_,mi,mu=Spring.GetTeamResources(0,"metal")
    local e,es,_,ei,eu=Spring.GetTeamResources(0,"energy")
    local list={}; for n,c in pairs(counts) do list[#list+1]=n..":"..c end; table.sort(list)
    log(string.format("sample frame=%d metal=%.1f/%.1f income=%.1f use=%.1f energy=%.1f/%.1f income=%.1f use=%.1f yards=%d busy=%d bp=%.1f idle=%.1f units=%s",f,m,ms,mi,mu,e,es,ei,eu,fac,busy,bp,idle,table.concat(list,",")))
end
