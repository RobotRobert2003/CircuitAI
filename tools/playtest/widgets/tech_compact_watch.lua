function widget:GetInfo() return {name="TECH compact layout verification",layer=126,enabled=true} end
local names=__NAMES__
local built,created={},{}
local phase=0
local lost={}
local function emit(s) Spring.Echo("[TechCompactTest] "..s) end
local function give(name,x,z)
    Spring.SendCommands("give 1 "..name.." 0 @"..x..","..Spring.GetGroundHeight(x,z)..","..z)
end
local function count(name)
    local n=0
    for id,def in pairs(built) do if def==name and Spring.ValidUnitID(id) and not Spring.GetUnitIsDead(id) then n=n+1 end end
    return n
end
local function supported(id)
    local x,_,z=Spring.GetUnitPosition(id)
    for nano,def in pairs(built) do
        if def==names.nano and Spring.ValidUnitID(nano) and not Spring.GetUnitIsDead(nano) then
            local nx,_,nz=Spring.GetUnitPosition(nano)
            local reach=UnitDefs[Spring.GetUnitDefID(nano)].buildDistance
            if (nx-x)^2+(nz-z)^2<=reach^2 then return true end
        end
    end
    return false
end
function widget:UnitCreated(id,def,team,builder)
    if team==0 and builder then created[id]=true end
end
function widget:UnitFinished(id,def,team)
    if team~=0 or not created[id] then return end
    local name=UnitDefs[def].name
    built[id]=name
    local x,_,z=Spring.GetUnitPosition(id)
    emit("completed "..name.." id="..id.." x="..x.." z="..z)
    if phase==3 then
        for index,site in ipairs(lost) do
            if site.name==name and math.abs(x-site.x)<1 and math.abs(z-site.z)<1 then site.rebuilt=true end
        end
    end
end
function widget:GameFrame(f)
    if f==90 then Spring.SendCommands("cheat 1") end
    if f==180 then
        local units=Spring.GetTeamUnits(0)
        local x,_,z=Spring.GetUnitPosition(units[1])
        Spring.SendSkirmishAIMessage(0,"tech-compact|setup|"..x.."|"..z)
        for i=0,11 do give(i<8 and names.t1 or names.t2,x+(i%4)*70,z+math.floor(i/4)*70) end
    end
    if f%30~=0 then return end
    if phase<0 and count(names.store)>=1 and count(names.nano)>=1 then
        for id,name in pairs(built) do
            if name==names.store and supported(id) then
                phase=0;emit("PASS local_support_seed")
                Spring.SendSkirmishAIMessage(0,"tech-compact|turrets")
                break
            end
        end
    elseif phase==0 and count(names.nano)>=16 then
        phase=1;emit("PASS sixteen_turrets")
        Spring.SendSkirmishAIMessage(0,"tech-compact|economy")
    elseif phase==1 and count(names.afus)>=1 and count(names.converter)>=3 and count(names.store)>=1 then
        for id,name in pairs(built) do
            if (name==names.afus or name==names.converter or name==names.store) and not supported(id) then emit("FAIL unsupported economy id="..id);return end
        end
        phase=2;emit("PASS supported_economy")
        -- Adopt the native saved IDs without resetting native ownership.
        Spring.SendSkirmishAIMessage(0,"tech-compact|adopt")
    elseif phase==2 then
        local chosen={}
        local ordered={}
        for id in pairs(built) do ordered[#ordered+1]=id end
        table.sort(ordered)
        local haveNano,haveConverter=false,false
        for _,id in ipairs(ordered) do
            local name=built[id]
            if (name==names.nano and not haveNano) or (name==names.converter and not haveConverter) then
                local x,_,z=Spring.GetUnitPosition(id)
                lost[#lost+1]={name=name,x=x,z=z};chosen[#chosen+1]=id
                if name==names.nano then haveNano=true else haveConverter=true end
            end
        end
        phase=3
        Spring.SelectUnitArray(chosen,false);Spring.SendCommands("destroy");Spring.SelectUnitArray({},false)
        Spring.SendSkirmishAIMessage(0,"tech-compact|recover")
    elseif phase==3 and #lost==2 and lost[1].rebuilt and lost[2].rebuilt then
        phase=4;emit("PASS compact_growth_economy_recovery")
    end
end
