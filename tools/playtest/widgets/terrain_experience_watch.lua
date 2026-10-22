-- Drives only the widget's public configuration owner, never gameplay orders.
function widget:GetInfo()
    return {name="BARb terrain experience check",desc="Three views and settings independence",author="CircuitAI",layer=120,enabled=true}
end
local stage, waitFrame, began, before = 0,0,nil,nil
local waitTimer=nil
local readyTimer,readyKey=nil,nil
local function log(ok,s) Spring.Echo("[TerrainUX] "..(ok and "PASS " or "FAIL ")..s) end
local function signature(s)
    local ids={};for _,f in ipairs(s.features or {}) do ids[#ids+1]=f.id..":"..f.reason end
    table.sort(ids);return table.concat(ids,"|")
end
local function configure(ui,view,primary,compare,inspect)
    local c=ui.FieldConfig();c.view=view;c.primary=primary;c.compare=compare;c.inspect=inspect or false
    c.labels="names";c.detail="essential";c.categories={resources=true,staging=true,defensive=true,coastal_access=true,starts=true}
    ui.FieldOptions(c)
end
function widget:Update()
    if stage==99 then return end
    local ui=WG.barblink; if not ui or not ui.FieldConfig then return end
    if not began then began=Spring.GetTimer();ui.SetField(true);ui.FieldLegend(true) end
    if Spring.DiffTimers(Spring.GetTimer(),began)>120 then log(false,"timeout "..ui.FieldStatus());stage=99;return end
    local s=ui.FieldSnapshot();if not s.ready then readyTimer=nil;return end
    local key=s.settings.view..tostring(s.settings.debug)
    if key~=readyKey or not readyTimer then readyKey=key;readyTimer=Spring.GetTimer();return end
    -- The screenshot command can capture the previous rendered frame. Give
    -- completed geometry a rendered settling interval before any capture.
    if Spring.DiffTimers(Spring.GetTimer(),readyTimer)<0.6 then return end
    if waitTimer and Spring.DiffTimers(Spring.GetTimer(),waitTimer)<0.6 then return end
    local frame=Spring.GetGameFrame();if frame<waitFrame then return end
    if stage==0 then
        log(s.loaded and #s.features>0,"loaded")
        Spring.SendCommands("viewfree")
        before=signature(s);stage=0.5;waitTimer=Spring.GetTimer()
    elseif stage==0.5 then
        Spring.SetCameraState({name="free",px=Game.mapSizeX/2,py=14000,pz=Game.mapSizeZ/2,rx=-math.pi/2,ry=math.pi,rz=0},0)
        stage=0.75;waitTimer=Spring.GetTimer()
    elseif stage==0.75 then
        local cam=Spring.GetCameraState();log(cam.py and math.abs(cam.py-14000)<2800,"camera overhead")
        stage=1;waitTimer=Spring.GetTimer()
    elseif stage==1 then
        Spring.Echo("[Playtest] screenshot terrain-ux terrain");Spring.SendCommands("screenshot png")
        local units=Spring.GetAllUnits();Spring.SelectUnitArray(units[1] and {units[1]} or {})
        stage=2;waitFrame=frame+10;waitTimer=Spring.GetTimer()
    elseif stage==2 then
        log(before==signature(s),"selection independent")
        Spring.SelectUnitArray({});configure(ui,"approaches",0,3);stage=3;waitFrame=frame+15
    elseif stage==3 then
        log(s.settings.view=="approaches" and s.settings.compare==3,"approaches comparison")
        Spring.Echo("[Playtest] screenshot terrain-ux approaches");Spring.SendCommands("screenshot png")
        stage=3.5;waitTimer=Spring.GetTimer()
    elseif stage==3.5 then
        configure(ui,"positions",0,3,true);stage=3.75;waitFrame=frame+15;waitTimer=Spring.GetTimer()
    elseif stage==3.75 then
        local f=s.features[1]
        if f then local kind,id=string.match(f.id,"^([^:]+):(%d+)$");ui.FieldFocus(kind,tonumber(id)) end
        stage=4;waitTimer=Spring.GetTimer()
    elseif stage==4 then
        log(#s.features>0 and s.settings.view=="positions","positions")
        Spring.Echo("[Playtest] screenshot terrain-ux positions");Spring.SendCommands("screenshot png")
        stage=4.5;waitTimer=Spring.GetTimer()
    elseif stage==4.5 then
        local c=ui.FieldConfig();c.debug=true;c.view="terrain";ui.FieldOptions(c);stage=5;waitFrame=frame+15;waitTimer=Spring.GetTimer()
    elseif stage==5 then
        log(s.settings.debug,"explicit debug")
        Spring.Echo("[Playtest] screenshot terrain-ux debug");Spring.SendCommands("screenshot png")
        stage=5.5;waitTimer=Spring.GetTimer()
    elseif stage==5.5 then
        local c=ui.FieldConfig();c.debug=false;c.inspect=false;c.view="terrain";ui.FieldOptions(c)
        before=signature(s);stage=5.75;waitFrame=frame+15;waitTimer=Spring.GetTimer()
    elseif stage==5.75 then
        before=signature(s)
        Spring.SetCameraState({name="free",px=Game.mapSizeX/2,py=6500,pz=Game.mapSizeZ/2,rx=-math.pi/2,ry=math.pi,rz=0},0)
        stage=5.9;waitTimer=Spring.GetTimer()
    elseif stage==5.9 then
        log(before==signature(s),"zoom independent")
        Spring.Echo("[Playtest] screenshot terrain-ux close");Spring.SendCommands("screenshot png")
        stage=6;waitTimer=Spring.GetTimer()
    elseif stage==6 then
        log(true,"complete")
        Spring.Echo(string.format("[TerrainUX] preparation_ms=%.3f max_slice_ms=%.3f batches=%d",s.metrics.prepareMs,s.metrics.maxSliceMs,s.metrics.batches))
        stage=99
    end
end
