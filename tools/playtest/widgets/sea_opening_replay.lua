-- Read-only replay evidence. No unit orders, cheats or production changes.
function widget:GetInfo()
    return {name='BARb sea opening replay',desc='Record opening naval factories',author='CircuitAI',layer=10,enabled=true}
end
local first = {}
local function observe(unit, definition, team)
    local d = UnitDefs[definition]
    if not d or not d.isFactory or not (d.minWaterDepth and d.minWaterDepth > 0) then return end
    local x, y, z = Spring.GetUnitPosition(unit)
    if not x then return end
    local _, _, _, isAI = Spring.GetTeamInfo(team, false)
    Spring.Echo(string.format('[SeaOpeningReplay] frame=%d team=%d ai=%s first=%s unit=%s x=%.0f z=%.0f facing=%d',
        Spring.GetGameFrame(),team,tostring(isAI),tostring(not first[team]),d.name,x,z,Spring.GetUnitBuildFacing(unit) or -1))
    first[team]=true
end
function widget:Initialize()
    if not Spring.IsReplay() then widgetHandler:RemoveWidget(self); return end
    Spring.SendCommands('specfullview 3','setmaxspeed 20','setminspeed 20')
    Spring.Echo('[SeaOpeningReplay] loaded')
end
function widget:UnitCreated(unit,definition,team) observe(unit,definition,team) end
local startupElapsed = 0
function widget:Update(seconds)
    startupElapsed = startupElapsed + seconds
    if startupElapsed > 2 and Spring.GetGameFrame() <= 0 then
        startupElapsed = 0
        Spring.SendCommands('forcestart')
    end
end
function widget:GameFrame(frame)
    if frame >= 10800 then
        Spring.Echo('[SeaOpeningReplay] complete')
        Spring.SendCommands('quitforce')
    end
end
