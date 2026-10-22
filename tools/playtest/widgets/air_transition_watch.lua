function widget:GetInfo() return {name="AIR first lab funding verification",layer=126,enabled=true} end
local side="__SIDE__"
local funded=__FUNDED__
local legacy=__LEGACY__
local growth=__GROWTH__
local names={armada={"armap","armca","armfus","armmmkr","armaap"},
 cortex={"corap","corca","corfus","cormmkr","coraap"},
 legion={"legap","legca","legfus","legadveconv","legaap"}}
local def=names[side]
local labs=0
local started=false
local progressChecked=false
local function emit(s) Spring.Echo("[AirTransitionTest] "..s) end
function widget:GameFrame(f)
    if f==90 then Spring.SendCommands("cheat 1"); emit("observer_started") end
    if f==300 then
        Spring.SendCommands("give 1 "..def[1].." 0 @1300,0,4000")
        Spring.SendCommands("give 3 "..def[2].." 0 @1100,0,4000")
        Spring.SendCommands("give 1 "..def[3].." 0 @700,0,4300")
        Spring.SendCommands("give 1 "..def[3].." 0 @700,0,4700")
        Spring.SendCommands("give 1 "..def[4].." 0 @700,0,4500")
    end
    if f==900 then Spring.SendSkirmishAIMessage(0,"air-transition-init") end
    if f>=1800 and started and not progressChecked and funded and not legacy then
        progressChecked=true; Spring.SendSkirmishAIMessage(0,"air-transition-progress")
    end
    if f==(growth and 7200 or 2400) and funded and not started then emit("FAIL first lab start deadline") end
end
function widget:UnitCreated(id,definition,team,builder)
    if team~=0 or UnitDefs[definition].name~=def[5] then return end
    labs=labs+1; started=true
    local bank=Spring.GetTeamResources(0,"metal")
    local cost=UnitDefs[definition].metalCost
    emit((builder and labs==1 and (not funded or bank<cost) and "PASS " or "FAIL ").."physical lab start")
    emit("physical_start frame="..Spring.GetGameFrame().." bank="..bank.." cost="..cost)
end
function widget:UnitFinished(id,definition,team)
    if growth and team==0 and UnitDefs[definition].name==({armada="armmex",cortex="cormex",legion="legmex"})[side] then
        local x,_,z=Spring.GetUnitPosition(id)
        emit(((x-1000)^2+(z-4000)^2<=1400^2 and "PASS " or "FAIL ").."physical local mex growth")
    end
    if team==0 and funded and UnitDefs[definition].name==({armada="armfig",cortex="corveng",legion="legfig"})[side] then
        emit("PASS physical defence completion")
    end
    if team==0 and UnitDefs[definition].name==def[5] then
        emit((labs==1 and "PASS " or "FAIL ").."physical completion")
        Spring.SendSkirmishAIMessage(0,"air-transition-finished")
    end
end
