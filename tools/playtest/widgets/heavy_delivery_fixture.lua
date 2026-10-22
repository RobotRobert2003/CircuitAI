function widget:GetInfo()
    return {name="Heavy delivery physical verification", layer=115, enabled=true}
end
local mode = "__MODE__"
local side = "__SIDE__"
local heavy = ({armada="armfboy",cortex="corsumo",legion="leginc"})[side]
if mode=="constructor" then heavy=({armada="armack",cortex="corack",legion="legack"})[side] end
local carrier = ({armada="armhvytrans",cortex="corhvytrans",legion="legatrans"})[side]
local lab = ({armada="armap",cortex="corap",legion="legap"})[side]
local cargo, commanders, firstMex = {}, {}, {}
local loaded, unloaded, given = {}, {}, {}
local maximumConcurrent, commands = 0, 0
local function emit(text) Spring.Echo("[HeavyDeliveryTest] " .. text) end
local function position(id)
    -- Skirmish Unit_getPos returns midPos, not the model's ground origin.
    -- Compare independent Lua observations in the same coordinate convention.
    local _,_,_,x,y,z=Spring.GetUnitPosition(id,true)
    return x,y,z
end
local function spawn(name,team,x,z)
    Spring.SendCommands("give "..name.." "..team.." @"..x..","..Spring.GetGroundHeight(x,z)..","..z)
end
local function message(team,text) Spring.SendSkirmishAIMessage(team,"heavy-logistics|"..text) end
local function scan()
    for _, team in ipairs(Spring.GetTeamList()) do
        for _, id in ipairs(Spring.GetTeamUnits(team) or {}) do
            local definition=UnitDefs[Spring.GetUnitDefID(id)]
            if definition.customParams and definition.customParams.iscommander then commanders[team]=id end
            local _,_,_,_,progress=Spring.GetUnitHealth(id)
            if definition.extractsMetal and definition.extractsMetal>0 and progress==1 and not firstMex[team] then
                local x,_,z=position(id); firstMex[team]={x,z}
            end
        end
    end
end
function widget:UnitFinished(id, definition, team)
    if team==0 and UnitDefs[definition].name==heavy and Spring.GetGameFrame()<600 then cargo[id]=true end
    if UnitDefs[definition].extractsMetal and UnitDefs[definition].extractsMetal>0 and not firstMex[team] then
        local x,_,z=position(id);firstMex[team]={x,z}
    end
end
function widget:UnitLoaded(id, definition, team, transport)
    if cargo[id] and mode=="constructor" then
        local name=UnitDefs[Spring.GetUnitDefID(transport)].name
        emit(((name=="armatlas" or name=="corvalk" or name=="leglts") and "PASS" or "FAIL").." constructor carrier="..name)
    end
    if cargo[id] then loaded[id]=transport; emit("loaded id="..id.." carrier="..transport) end
end
function widget:UnitUnloaded(id, definition, team, transport)
    if cargo[id] then unloaded[id]=true; loaded[id]=nil; emit("unloaded id="..id) end
end
function widget:UnitCommand(id, definition, team, command)
    if cargo[id] and given[id]==nil then commands=commands+1 end
end
function widget:UnitGiven(id, definition, newTeam, oldTeam)
    local name=UnitDefs[definition].name
    if (name=="armhvytrans" or name=="corhvytrans" or name=="legatrans") and newTeam==0 then
        emit("carrier-received id="..id.." from="..oldTeam.." frame="..Spring.GetGameFrame())
    end
    if not cargo[id] or oldTeam~=0 then return end
    local target,kind=nil,"mex"
    local commander=commanders[newTeam]
    if mode~="constructor" and commander and Spring.ValidUnitID(commander) and not Spring.GetUnitIsDead(commander) then
        local x,_,z=position(commander); target={x,z};kind="commander"
    else target=firstMex[newTeam] end
    local x,_,z=position(id)
    local distance=target and math.sqrt((x-target[1])^2+(z-target[2])^2) or -1
    local aboard=Spring.GetUnitTransporter(id)
    local expectedKind=(mode=="mex" or mode=="constructor") and "mex" or "commander"
    -- Constructor drops use Ferry.SafeDropRadius (900); the heavy commander
    -- rendezvous has its separate 240-elmo arrival contract. Keep both exact.
    local arrivalLimit=mode=="constructor" and 901 or 241
    local passed=newTeam==2 and distance>=0 and distance<=arrivalLimit and not aboard and kind==expectedKind
    given[id]=passed
    emit((passed and "PASS" or "FAIL").." given id="..id.." recipient="..newTeam.." anchor="..kind
        .." distance="..math.floor(distance).." loaded="..tostring(aboard))
end
function widget:GameFrame(frame)
    if frame==150 then Spring.SendCommands("cheat 1") end
    if frame==300 then
        scan()
        for _,team in ipairs({0,1,2,3}) do message(team,"setup|"..mode) end
        spawn("armmex",2,4550,7750)
        if mode=="local" then spawn(lab,0,1150,10850) end
        if mode=="local" or mode=="request" then
            for _,team in ipairs({0,1}) do
                local x,_,z=Spring.GetTeamStartPosition(team)
                for index=1,4 do spawn("armfus",team,x+index*120,z+250) end
                for index=1,8 do spawn("armnanotc",team,x+index*50,z+100) end
            end
        end
    end
    -- AIR has no capable lab for three minutes: queued demand and retries must
    -- survive this gap; acknowledgements are not completed transport receipt.
    if frame==5400 and mode=="request" then spawn("armap",1,2150,11400) end
    if frame==450 then
        scan()
        if mode=="mex" then
            if commanders[2] then Spring.SendLuaRulesMsg("$dev$:removeunits "..commanders[2]) end
        end
        for index=1,3 do
            spawn(heavy,0,1250+index*100,10000)
            if mode=="flight" then spawn(carrier,0,1250+index*100,10150) end
        end
        if mode=="constructor" then
            spawn(({armada="armatlas",cortex="corvalk",legion="leglts"})[side],0,1350,10150)
            spawn(carrier,0,1550,10150)
        end
    end
    if frame==600 then
        local ids={};for id in pairs(cargo) do ids[#ids+1]=id end;table.sort(ids)
        for _,id in ipairs(ids) do message(0,"cargo|"..id..(mode=="constructor" and "|constructor" or "")) end
    end
    if frame%300==0 then
        message(0,"sample")
        local active=0;for id in pairs(loaded) do active=active+1 end
        maximumConcurrent=math.max(maximumConcurrent,active)
        emit("progress frame="..frame.." concurrent="..active.." maximum="..maximumConcurrent.." commands="..commands)
    end
    if frame==8700 then
        local passed=0;for id,result in pairs(given) do if result then passed=passed+1 end end
        local owned=0
        for _,id in ipairs(Spring.GetTeamUnits(0) or {}) do
            local name=UnitDefs[Spring.GetUnitDefID(id)].name
            local _,_,_,_,progress=Spring.GetUnitHealth(id)
            if progress==1 and (name=="armhvytrans" or name=="corhvytrans" or name=="legatrans") then owned=owned+1 end
        end
        local poolPassed=(mode~="local" and mode~="request") or owned>=2
        local concurrentPassed=mode~="flight" or maximumConcurrent==3
        emit((passed==3 and poolPassed and concurrentPassed and "PASS" or "FAIL").." final delivered="..passed
            .." max-concurrent="..maximumConcurrent.." commands="..commands.." carriers-owned="..owned)
    end
end
