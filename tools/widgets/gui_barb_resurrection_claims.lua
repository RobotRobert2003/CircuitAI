-- Install in LuaUI/Widgets on the AI host. Same-DLL AI allies work without
-- this bridge; human, remote-host and other AI implementations require it.
function widget:GetInfo()
    return {name="BARb allied resurrection protection", desc="Report allied resurrection intents to local AIs",
        author="CircuitAI", layer=0, enabled=true}
end
local workers, previous = {}, {}
local function track(id, definition)
    if UnitDefs[definition] and UnitDefs[definition].canResurrect then workers[id]=true end
end
function widget:Initialize()
    for _,id in ipairs(Spring.GetAllUnits()) do track(id,Spring.GetUnitDefID(id)) end
end
function widget:UnitCreated(id,definition) track(id,definition) end
function widget:UnitGiven(id,definition) track(id,definition) end
function widget:UnitTaken(id,definition) track(id,definition) end
function widget:UnitDestroyed(id) workers[id]=nil end
function widget:GameFrame(frame)
    if frame%30~=0 then return end
    local targets={}
    for _,team in ipairs(Spring.GetTeamList()) do
        local _,_,dead,isAI=Spring.GetTeamInfo(team)
        local _,_,host=Spring.GetAIInfo(team)
        if isAI and not dead and host==Spring.GetMyPlayerID() then targets[#targets+1]=team end
    end
    local active={}
    -- Only resurrection-capable units are polled. Read one command per worker,
    -- never a full queue or a worker-by-wreck scan. Heartbeats expire natively
    -- after three seconds if the bridge disappears; STOP also sends a clear.
    for id in pairs(workers) do
        local team=Spring.GetUnitTeam(id)
        local permitted=false
        for _,target in ipairs(targets) do
            if team and Spring.AreTeamsAllied(team,target) then permitted=true;break end
        end
        if permitted then
            local commands=Spring.GetUnitCommands(id,1) or {}
            local command=commands[1]
            if command and command.id==CMD.RESURRECT and (#command.params==1 or #command.params==4 or #command.params==5) then
                active[id]=team
                local message="barb-resurrection "..id.." "..#command.params.." "..table.concat(command.params," ")
                for _,target in ipairs(targets) do
                    if Spring.AreTeamsAllied(team,target) then Spring.SendSkirmishAIMessage(target,message) end
                end
            end
        end
    end
    for id,team in pairs(previous) do
        if not active[id] then
            for _,target in ipairs(targets) do
                if Spring.AreTeamsAllied(team,target) then Spring.SendSkirmishAIMessage(target,"barb-resurrection "..id.." 0") end
            end
        end
    end
    previous=active
end
