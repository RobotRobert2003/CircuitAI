function widget:GetInfo()
    return {name="Turret census", desc="D-289: every 30 s, what team 0's construction turrets are doing (read-only)", author="CircuitAI", layer=112, enabled=true}
end
-- One line per 30 s: [TurretWatch] team 0 turrets N busy B idle I factory F labs L
--   factory = guarding a factory, or repairing a mobile unit still being built
--   (a factory-side assist of what a lab produces); busy = any other command.
-- Cost: team 0's units once per 30 s, one GetUnitCommands per turret.
local tag = "[TurretWatch] "
local nano = {}
for id, d in pairs(UnitDefs) do
    if d.name:find("nanotc", 1, true) then nano[id] = true end
end
local function census(frame)
    local n, busy, idle, factory, labs = 0, 0, 0, 0, 0
    for _, id in ipairs(Spring.GetTeamUnits(0)) do
        local def = Spring.GetUnitDefID(id)
        local d = def and UnitDefs[def]
        local _, _, _, _, progress = Spring.GetUnitHealth(id)
        if d and d.isFactory and (progress or 0) >= 1 then labs = labs + 1 end
        if nano[def] and (progress or 0) >= 1 then
            n = n + 1
            -- native static repair inserts WAIT ahead of its REPAIR while energy
            -- is empty: classify by the command behind a leading WAIT
            local cmds = Spring.GetUnitCommands(id, 2)
            local c = cmds and cmds[1]
            if c and c.id == CMD.WAIT and cmds[2] then c = cmds[2] end
            if not c then
                idle = idle + 1
            else
                local target = c.params and #c.params == 1 and c.params[1]
                local td = target and Spring.ValidUnitID(target) and UnitDefs[Spring.GetUnitDefID(target)]
                if c.id == CMD.GUARD and td and td.isFactory then
                    factory = factory + 1
                elseif c.id == CMD.REPAIR and td and not td.isImmobile and select(5, Spring.GetUnitHealth(target)) < 1 then
                    factory = factory + 1
                elseif c.id == CMD.WAIT then
                    idle = idle + 1
                else
                    busy = busy + 1
                end
            end
        end
    end
    Spring.Echo(tag .. string.format("frame=%d team 0 turrets %d busy %d idle %d factory %d labs %d", frame, n, busy, idle, factory, labs))
end
function widget:GameFrame(frame)
    if frame > 0 and frame % 900 == 0 then census(frame) end
end
