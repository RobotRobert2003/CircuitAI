-- Read-only unit observation for the reported Glacial Gap construction stall.
-- Replay only: never issue unit orders or change the synced game state.
function widget:GetInfo()
    return {name = "BARb builder replay watch", desc = "Observe builder queues and factory facings in a replay",
        author = "CircuitAI", date = "2026-10-07", layer = 10, enabled = true}
end

local watched = {[0]=true, [3]=true, [5]=true, [7]=true, [8]=true, [11]=true, [13]=true}
local function echo(s) Spring.Echo("[BuilderReplay] " .. s) end
local function observe(u, team, event)
    local d = UnitDefs[Spring.GetUnitDefID(u) or -1]
    if not d then return end
    local x,y,z = Spring.GetUnitPosition(u)
    if not x then return end
    local _,_,_,_,progress = Spring.GetUnitHealth(u)
    local commands = Spring.GetUnitCommands(u, 5) or {}
    local parts = {}
    for _,c in ipairs(commands) do
        local params = {}
        for _,v in ipairs(c.params or {}) do params[#params+1] = tostring(v) end
        parts[#parts+1] = tostring(c.id) .. "(" .. table.concat(params, ",") .. ")"
    end
    echo(string.format("event=%s team=%d unit=%d def=%s at=%.0f,%.0f progress=%.3f facing=%s building=%s queue=%s",
        event,team,u,d.name,x,z,progress or 1,tostring(Spring.GetUnitBuildFacing(u) or -1),
        tostring(Spring.GetUnitIsBuilding(u) or -1),table.concat(parts,";")))
end

function widget:Initialize()
    if not Spring.IsReplay() then
        echo("disabled: not a replay")
        widgetHandler:RemoveWidget(self)
        return
    end
    echo("loaded: replay-only, no unit orders")
    local _,fullView = Spring.GetSpectatingState()
    if not fullView then Spring.SendCommands("specfullview") end
    Spring.SendCommands("setmaxspeed 20", "setminspeed 20", "setmaxspeed 20")
end

function widget:UnitCreated(u, defID, team)
    local d = UnitDefs[defID]
    if watched[team] and d and d.isFactory then observe(u,team,"factory-created") end
end

function widget:GameFrame(f)
    if f % 1800 == 0 then
        for _,team in ipairs(Spring.GetTeamList() or {}) do
            if watched[team] then
                for _,u in ipairs(Spring.GetTeamUnits(team) or {}) do
                    local d = UnitDefs[Spring.GetUnitDefID(u) or -1]
                    if d and (d.isFactory or (d.isBuilder and not d.isImmobile)) then observe(u,team,"sample") end
                end
            end
        end
        echo("frame=" .. f)
    end
    if f >= 63000 then
        echo("finished")
        Spring.SendCommands("quitforce")
    end
end
