function widget:GetInfo()
    return {name="Reclaim overflow fixture", desc="D-290: fills team 0's metal bank to 96% the moment its advanced lab is being reclaimed; reports a lab refund that overflowed", author="CircuitAI", layer=122, enabled=true}
end
-- Controlled input, not natural-game evidence. Once a second it looks for a
-- team-0 builder whose first command reclaims a team-0 advanced bot lab
-- (armalab, coralab, legalab). The first time, it cheats team 0's bank up to
-- 96% of storage (cheat, team 0, atm, spectator). Lines:
--   [ReclaimFixture] bank filled to C/S at lab L reclaim
--   [ReclaimFixture] lab L gone bank C/S cost M      (the refund landed)
--   [ReclaimFixture] OVERFLOW lab L gone bank C/S cost M  (bank + cost > storage
--     in the last sample before the lab went: its refund was partly lost)
-- Cost: team 0's units once a second until the fill, then the lab id only.
local tag = "[ReclaimFixture] "
local labs = {armalab = true, coralab = true, legalab = true}
local filled = false
local watched = {}       -- lab id -> metal cost
local lastBank, lastStor = 0, 0
local queue = {}
local function findReclaim()
    for _, id in ipairs(Spring.GetTeamUnits(0)) do
        local cmds = Spring.GetUnitCommands(id, 1)
        local c = cmds and cmds[1]
        if c and c.id == CMD.RECLAIM and c.params and #c.params == 1 then
            local target = c.params[1]
            if Spring.ValidUnitID(target) and Spring.GetUnitTeam(target) == 0 then
                local d = UnitDefs[Spring.GetUnitDefID(target)]
                if d and labs[d.name] then return target, d end
            end
        end
    end
end
function widget:Initialize()
    Spring.Echo(tag .. "controlled bank fill on the advanced lab's reclaim; not natural-game evidence")
end
function widget:GameFrame(f)
    if f == 60 then Spring.SendCommands("cheat 1") end
    if #queue > 0 and f % 3 == 0 then Spring.SendCommands(table.remove(queue, 1)) end
    if f % 30 ~= 0 then return end
    local cur, stor = Spring.GetTeamResources(0, "metal")
    if not filled then
        local lab, d = findReclaim()
        if lab then
            filled = true
            watched[lab] = d.metalCost
            local add = math.max(0, math.floor(stor * 0.96 - cur))
            queue[#queue + 1] = "team 0"
            queue[#queue + 1] = "atm " .. add
            queue[#queue + 1] = "spectator"
            Spring.Echo(tag .. string.format("bank filled to %d/%d at lab %d reclaim (added %d)", math.floor(cur + add), math.floor(stor), lab, add))
        end
    end
    lastBank, lastStor = cur, stor
end
function widget:UnitDestroyed(id, defID, team)
    local cost = watched[id]
    if not cost then return end
    watched[id] = nil
    local over = lastBank + cost > lastStor
    Spring.Echo(tag .. string.format("%slab %d gone bank %d/%d cost %d", over and "OVERFLOW " or "", id, math.floor(lastBank), math.floor(lastStor), cost))
end
