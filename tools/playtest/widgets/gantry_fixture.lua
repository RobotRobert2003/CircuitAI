function widget:GetInfo()
    return {name="Gantry construction verification", layer=115, enabled=true}
end
local mode, side = "__MODE__", "__SIDE__"
local prefix=({armada="arm",cortex="cor",legion="leg"})[side]
local gantry=({armada="armshltx",cortex="corgant",legion="leggant"})[side]
local turrets, frames, completed = {}, {}, false
local camera
local function emit(text) Spring.Echo("[GantryTest] "..text) end
local function photograph(id)
    local x,y,z=Spring.GetUnitPosition(id)
    Spring.SendCommands({"setmaxspeed 0.25","setminspeed 0.25","setmaxspeed 0.25"})
    camera={state={mode=1,px=x,py=math.max(0,y),pz=z,height=1900,angle=0.8},at=Spring.GetTimer(),draws=0}
end
function widget:DrawScreen()
    if not camera then return end
    Spring.SetCameraState(camera.state,0)
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
function widget:UnitCreated(id, definition, team, builder)
    if team~=0 or not builder then return end
    local name=UnitDefs[definition].name
    if name~=gantry then return end
    local count=0
    for turret in pairs(turrets) do if Spring.ValidUnitID(turret) and not Spring.GetUnitIsDead(turret) then count=count+1 end end
    local frame=Spring.GetGameFrame()
    frames[id]=true
    emit("frame id="..id.." at="..frame.." completed_turrets="..count)
    if (mode=="supported" or mode=="recovery" or mode=="integration") and count<10 then emit("FAIL premature factory") end
    if mode=="no-t1" and frame<300+90*30 then emit("FAIL premature fallback") end
    if mode=="starved" and frame<2*1800 then emit("FAIL unfunded factory") end
    photograph(id)
end
function widget:UnitFinished(id, definition, team)
    if team~=0 then return end
    local name=UnitDefs[definition].name
    if name==prefix.."nanotc" then turrets[id]=true end
    if name==gantry and frames[id] then completed=true; emit("PASS physical gantry completed frame="..Spring.GetGameFrame()); photograph(id) end
end
function widget:GameFrame(frame)
    if mode=="natural" then
        if frame % 1800 == 0 then
            local _,_,_,income,expense=Spring.GetTeamResources(0,"metal")
            emit("natural minute="..(frame/1800).." metal_income="..income.." metal_expense="..expense)
        end
        return
    end
    if frame==90 then Spring.SendCommands("cheat 1") end
    if frame==(mode=="integration" and 210 or 150) then Spring.SendSkirmishAIMessage(0,"gantry-probe|setup|"..mode) end
    if frame==300 then
        -- Supplied banks and plants isolate task recovery from the economy.
        spawn(prefix.."afus",800,10900)
        spawn(prefix.."afus",1400,10900)
        spawn(prefix.."ack",1400,10100)
        spawn(prefix.."ack",1480,10100)
        if mode~="no-t1" then
            for index=1,4 do spawn(prefix.."ck",1400+index*80,10180) end
        end
    end
    if frame==(mode=="integration" and 15 or 7)*1800 then
        emit((completed and "PASS" or "FAIL").." final mode="..mode)
        Spring.SendCommands("screenshot")
    end
end
