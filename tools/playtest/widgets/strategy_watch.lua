function widget:GetInfo()
    return {name="BARb strategy inspection check",desc="Rendered strategic publication correctness",author="CircuitAI",layer=100000,enabled=true}
end
local stage, due, drawFrames = 0, 0, 0
local started=nil
local function report(s) Spring.Echo("[StrategyCheck] "..s) end
function widget:DrawScreen() drawFrames=drawFrames+1 end
function widget:GameFrame(frame)
    local ui=WG.barblink
    if not ui or not ui.StrategySnapshot then return end
    if started and stage>0 and stage<6 and Spring.DiffTimers(Spring.GetTimer(),started)>40 then
        report("FAIL visual preparation timed out: "..tostring(ui.StrategySnapshot().status))
        Spring.SendCommands({"setmaxspeed 20","setminspeed 20"});stage=6;return
    end
    if stage==0 and frame>=900 then
        ui.SetOpen(false);ui.SetField(false);ui.SetStrategy(true)
        -- Rendered evidence needs draw frames, not a fixed timing window.
        started=Spring.GetTimer();Spring.SendCommands({"setminspeed 1","setmaxspeed 1"})
        Spring.SendCommands("viewfree")
        stage=1
    elseif stage==1 then
        local snap=ui.StrategySnapshot()
        if frame%300==0 then report("pending ready="..tostring(snap.ready).." terrain="..snap.terrainLists.." dynamic="..snap.dynamicLists.." teams="..#snap.teams.." status="..tostring(snap.status)) end
        if frame==2700 then Spring.Echo("[Playtest] screenshot strategy pending");Spring.SendCommands("screenshot png") end
        if #snap.teams==0 and frame%300==0 then ui.StrategyConfig({show=true,class=1,mode=1}) end
        if #snap.teams>0 and snap.ready and snap.terrainLists>0 and snap.dynamicLists>0 then
            local s=snap.teams[1]
            if #s.route<2 or s.corridor<0 then return end
            report("PASS geometry terrain="..snap.terrainLists.." dynamic="..snap.dynamicLists)
            report("PASS loaded team="..s.team.." corridor="..s.corridor.." revision="..s.assignment)
            Spring.SetCameraState({name="free",px=Game.mapSizeX/2,py=math.max(Game.mapSizeX,Game.mapSizeZ)*.85,
                pz=Game.mapSizeZ/2,rx=-math.pi/2,ry=math.pi,rz=0},0)
            stage=2;due=drawFrames+15
        end
    elseif stage>=2 and stage<=5 and drawFrames>=due and ui.StrategySnapshot().ready then
        Spring.Echo("[Playtest] screenshot strategy view "..(stage-1))
        Spring.SendCommands("screenshot png")
        local snap=ui.StrategySnapshot()
        report("PASS view="..snap.mode.." teams="..#snap.teams)
        stage=stage+1;due=drawFrames+15
        if stage<=5 then ui.StrategyConfig({show=true,class=snap.class,mode=stage-1})
        else Spring.SendCommands({"setmaxspeed 20","setminspeed 20"});report("PASS screenshots") end
    end
end
