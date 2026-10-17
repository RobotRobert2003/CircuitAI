function widget:GetInfo() return {name="FRONT opener verification",layer=126,enabled=true} end
local mode,side,kind="__MODE__","__SIDE__","__KIND__"
local prefix=({armada="arm",cortex="cor",legion="leg"})[side]
local factoryName=prefix..(kind=="bot" and "lab" or "vp")
local scout=kind=="bot" and ({armada="armflea",cortex="corak",legion="leggob"})[side]
    or ({armada="armflash",cortex="corfav",legion="legscout"})[side]
local tank=({armada="armflash",cortex="corgator",legion="leghades"})[side]
local wantsTank=mode~="ordinary" and mode~="unavailable" and mode~="profile" and kind=="vehicle" and side~="armada"
local batch=wantsTank and tank or scout
local factory,products,finished,live=nil,{},0,{}
local lost,ended=false,false
local function emit(s) Spring.Echo("[FrontOpenerTest] "..s) end
local function give(name,x,z,team)
    Spring.SendCommands("give 1 "..name.." "..(team or 0).." @"..x..","..Spring.GetGroundHeight(x,z)..","..z)
end
local function destroy(id)
    Spring.SelectUnitArray({id},false); Spring.SendCommands("destroy"); Spring.SelectUnitArray({},false)
end
function widget:UnitCreated(id,def,team,builder)
    if team~=0 then return end
    if UnitDefs[def].name==factoryName then factory=id end
    if factory and builder==factory then products[id]=true end
end
function widget:UnitFinished(id,def,team)
    if team~=0 or not products[id] then return end
    if UnitDefs[def].isBuilder then emit("constructor_finished"); return end
    finished=finished+1
    local name=UnitDefs[def].name
    emit("finished index="..finished.." unit="..name.." frame="..Spring.GetGameFrame())
    if mode=="spam" and finished>11 then emit("post_opener_production"); return end
    if name~=(finished==1 and scout or batch) then emit("FAIL production sequence") end
    if finished>1 then live[id]=true end
    if finished>11 then emit("FAIL extra opener production") end
end
function widget:UnitDestroyed(id) live[id]=nil end
function widget:GameFrame(f)
    if f==90 then Spring.SendCommands("cheat 1"); emit("observer_started") end
    if f==150 then Spring.SendSkirmishAIMessage(0,"front-opener|setup|"..mode.."|"..side) end
    if f==210 then give(prefix..(kind=="bot" and "ck" or "cv"),1600,10300) end
    if f==240 then
        give(factoryName,1400,10100)
        -- Add radar and several targets for post-release movement; the sparse
        -- version could leave ordinary RAID idle (retained as KI-629).
        give(prefix.."rad",1400,9500)
        give("armmex",1100,8300,3)
        give("armmex",1400,8300,3)
        give("armmex",1700,8300,3)
        if wantsTank then give(tank,1600,9800); give(tank,1700,9800) end
        -- One caretaker accelerates production without skipping partial cohorts.
        give(prefix.."nanotc",1600,10100)
    end
    if ended or f%15~=0 then return end
    if mode=="casualty" and not lost and finished>=5 then
        for id in pairs(live) do destroy(id); lost=true; emit("casualty_injected"); break end
    elseif mode=="factory-loss" and not lost and finished>=5 then
        destroy(factory); factory=nil; lost=true; emit("factory_loss_injected")
    end
    local target=(mode=="cancel" and 10 or 11)
    if mode=="factory-loss" then target=5 end
    local distant,alive=0,0
    for id in pairs(live) do
        local x,_,z=Spring.GetUnitPosition(id)
        if x then
            alive=alive+1
            local d=(x-1400)^2+(z-10100)^2
            if d>800^2 then distant=distant+1 end
            if mode=="factory-loss" and lost and f%1800==0 then
                local health,maxHealth=Spring.GetUnitHealth(id)
                local commands=Spring.GetUnitCommands(id,2) or {}
                local first=commands[1] or {}
                emit("loss_survivor id="..id.." x="..math.floor(x).." z="..math.floor(z).." health="..tostring(health).."/"..tostring(maxHealth).." command="..tostring(first.id).." params="..table.concat(first.params or {},","))
                Spring.SendSkirmishAIMessage(0,"front-opener|state|"..id)
            end
            if wantsTank and mode~="timeout" and mode~="factory-loss" and finished<target and d>800^2 then
                emit("FAIL tank left before batch gathered")
            end
        end
    end
    local departuresNeeded=mode=="factory-loss" and alive or math.max(1,alive-1)
    if finished>=target and (not wantsTank or distant>=departuresNeeded) then
        ended=true; emit("PASS sequence_and_departure finished="..finished.." alive="..alive.." departed="..distant)
    end
end
