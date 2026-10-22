function widget:GetInfo()
    return {name="Support mobile build power verification", layer=115, enabled=true}
end
local side="__SIDE__"
local expectedAssistants=__EXPECTED_ASSISTANTS__
local prefix=({armada="arm",cortex="cor",legion="leg"})[side]
local assistant=({armada="armfark",cortex="corfast",legion="legaceb"})[side]
local assistants, combat, decoys, peak = 0,0,0,0
local position, camera
local function emit(text) Spring.Echo("[SupportAssistTest] "..text) end
local function photo()
    Spring.SendCommands({"setmaxspeed 0.25","setminspeed 0.25","setmaxspeed 0.25"})
    camera={at=Spring.GetTimer(),draws=0}
end
function widget:DrawScreen()
    if not camera or not position then return end
    Spring.SetCameraState({mode=1,px=position[1],py=math.max(0,position[2]),pz=position[3],height=2000,angle=0.8},0)
    camera.draws=camera.draws+1
    if camera.draws>=5 and Spring.DiffTimers(Spring.GetTimer(),camera.at)>=1 then
        Spring.SendCommands("screenshot png")
        Spring.SendCommands({"setmaxspeed 10","setminspeed 10","setmaxspeed 10"})
        camera=nil
    end
end
local function spawn(name,x,z)
    Spring.SendCommands("give "..name.." 0 @"..x..","..Spring.GetGroundHeight(x,z)..","..z)
end
function widget:UnitCreated(id,definition,team,builder)
    if team~=0 or not builder then return end
    local name=UnitDefs[definition].name
    if name==assistant then
        if combat<3 then emit("FAIL assistant_preempted_opening") end
        -- Separate labs can start their already-admitted queues in a different
        -- order. Check physical opening/caps here, not global frame alternation.
        peak=peak+1
        if peak>expectedAssistants then emit("FAIL cap_or_profile_gate_exceeded") end
        emit("assistant_frame="..id.." combat_before="..combat)
    elseif name==prefix.."decom" then
        decoys=decoys+1; emit("FAIL decoy_produced")
    elseif not UnitDefs[definition].isBuilder then
        combat=combat+1
    end
end
function widget:UnitFinished(id,definition,team)
    if team==0 and UnitDefs[definition].name==assistant then
        assistants=assistants+1
        emit("completed_assistant="..id.." count="..assistants.." combat="..combat)
        photo()
    end
end
function widget:GameFrame(frame)
    if frame==90 then Spring.SendCommands("cheat 1") end
    if frame==210 then Spring.SendSkirmishAIMessage(0,"support-assist-probe|setup") end
    if frame==300 then
        for _,id in ipairs(Spring.GetTeamUnits(0)) do
            local definition=UnitDefs[Spring.GetUnitDefID(id)]
            if definition.customParams and definition.customParams.iscommander then position={Spring.GetUnitPosition(id)}; break end
        end
        if not position then position={Spring.GetTeamStartPosition(0)} end
        local x,z=position[1],position[3]
        spawn(prefix.."alab",x-320,z-160)
        spawn(prefix.."alab",x+320,z-160)
        spawn(prefix.."ack",x,z+200)
        spawn(prefix.."afus",x,z+420)
        for index=1,10 do spawn(prefix.."nanotc",x-450+index*80,z-400) end
        photo()
    end
    if frame==5*1800 then
        emit((assistants==expectedAssistants and decoys==0 and combat>=6 and peak<=expectedAssistants and "PASS" or "FAIL")..
            " physical_production assistants="..assistants.." combat="..combat.." decoys="..decoys)
        photo()
    end
end
