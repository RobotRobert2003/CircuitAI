function widget:GetInfo()
    return {name='Blueprint checks', desc='Real host UI and native layout snapshots', author='CircuitAI', layer=110, enabled=true}
end
local stage, roles, pendingShot = 0, {}, nil
local function check(ok,label) Spring.Echo('[BlueprintCheck] '..(ok and 'PASS ' or 'FAIL ')..label) end
local function click(ui,id)
    local r=ui.ButtonRect(id)
    if not r then check(false,'missing control '..id); return end
    local x,y=(r[1]+r[3])/2,(r[2]+r[4])/2
    ui.MousePress(x,y,1); ui.MouseRelease(x,y,1)
end
local function focus(id)
    local snapshot=WG.barblink.BlueprintSnapshot(id)
    local x,y,z=Spring.GetTeamStartPosition(id)
    x,z=snapshot.x or x,snapshot.z or z
    pendingShot={x=x,z=z,draws=0,started=Spring.GetTimer()}
end
function widget:DrawScreen() if pendingShot then pendingShot.draws=pendingShot.draws+1 end end
function widget:Update()
    if pendingShot then
        local p=pendingShot
        Spring.SetCameraState({mode=1,px=p.x,py=math.max(0,Spring.GetGroundHeight(p.x,p.z)),pz=p.z,height=2000,angle=0.8},0)
        if p.draws>=3 and Spring.DiffTimers(Spring.GetTimer(),p.started)>=1 then
            Spring.SendCommands('screenshot png'); pendingShot=nil
        end
    end
end
function widget:GameFrame(f)
    local ui=WG.barblink; if not ui then return end
    if stage==0 and f>=450 then
        ui.SetOpen(true); stage=0.5
    elseif stage==0.5 and f>=480 then
        click(ui,'plansTeam'); click(ui,'lanesTeam'); stage=1
    elseif stage==1 and f>=2700 then
        local roster=ui.Roster()
        local count=0
        for id,r in pairs(roster) do if r.allyTeam==0 then
            count=count+1
            local s=ui.BlueprintSnapshot(id)
            check(s.visible and s.ready and s.slots>0,'team snapshot '..r.role..' slots='..s.slots)
            local lanes=ui.TheatreSnapshot(id)
            check(lanes and lanes.visible,'team lanes '..r.role)
            roles[r.role]=id
        end end
        check(count>0,'at least one live plan')
        for id,r in pairs(roster) do if r.allyTeam~=0 then
            check(not ui.BlueprintSnapshot(id).visible,'other ally team hidden')
            local lanes=ui.TheatreSnapshot(id)
            check(not lanes or not lanes.visible,'other ally team lanes hidden')
        end end
        if roles.SEA then ui.SetBlueprints(roles.SEA); focus(roles.SEA)
        elseif roles.TECH then ui.SetBlueprints(roles.TECH) end
        stage=2
    elseif stage==2 and f>=3900 then
        if roles.SEA then check(ui.BlueprintSnapshot(roles.SEA).visible,'SEA blueprint') end
        click(ui,'lanesPlayer')
        for role,id in pairs(roles) do
            local lanes=ui.TheatreSnapshot(id)
            check(lanes and lanes.visible==(id==(roles.SEA or roles.TECH)),'player lanes '..role)
        end
        click(ui,'lanesOff')
        for _,id in pairs(roles) do check(not ui.TheatreSnapshot(id).visible,'hide lanes') end
        if roles.AIR then ui.SetBlueprints(roles.AIR); focus(roles.AIR) end
        stage=3
    elseif stage==3 and f>=5100 then
        if roles.AIR then check(ui.BlueprintSnapshot(roles.AIR).visible,'AIR blueprint') end
        if roles.TECH then ui.SetBlueprints(roles.TECH); focus(roles.TECH) end
        stage=4
    elseif stage==4 and f>=6300 then
        if roles.TECH then check(ui.BlueprintSnapshot(roles.TECH).visible,'TECH blueprint') end
        ui.SetBlueprints(nil)
        for _,id in pairs(roles) do check(not ui.BlueprintSnapshot(id).visible,'hidden subscription') end
        stage=5
    elseif stage==5 and f>=6600 then
        ui.SetBlueprints('team'); stage=6
    elseif stage==6 and f>=6900 then
        for role,id in pairs(roles) do check(ui.BlueprintSnapshot(id).ready,'resubscribe '..role) end
        check(true,'completed'); stage=7
    end
end
