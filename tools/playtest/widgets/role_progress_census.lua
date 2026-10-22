-- Read-only integration evidence: completed unit types and economy for every
-- team. One O(total units) scan per five game minutes, outside AI policy. No
-- orders, resource grants, target disclosure to AI, or gameplay mutations.
function widget:GetInfo()
    return {name="BARb role progress census", desc="Read-only role regression evidence",
            author="CircuitAI", layer=10, enabled=true}
end

function widget:GameFrame(frame)
    if frame == 0 or frame % (5 * 60 * 30) ~= 0 then return end
    for _, team in ipairs(Spring.GetTeamList() or {}) do
        local counts, completed, unfinished = {}, 0, {}
        for _, unit in ipairs(Spring.GetTeamUnits(team) or {}) do
            local definition = UnitDefs[Spring.GetUnitDefID(unit) or -1]
            local _, _, _, _, progress = Spring.GetUnitHealth(unit)
            if definition and (progress or 0) >= 1 then
                counts[definition.name] = (counts[definition.name] or 0) + 1
                completed = completed + 1
            elseif definition and progress then
                unfinished[#unfinished + 1] = string.format("%s:%d:%.3f", definition.name, unit, progress)
            end
        end
        local names, entries = {}, {}
        for name in pairs(counts) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do entries[#entries + 1] = name .. "=" .. counts[name] end
        local metal, _, _, metalIncome = Spring.GetTeamResources(team, "metal")
        local energy, _, _, energyIncome = Spring.GetTeamResources(team, "energy")
        Spring.Echo(string.format(
            "[RoleCensus] minute=%d team=%d completed=%d metal=%.1f metalIncome=%.1f energy=%.1f energyIncome=%.1f units=%s unfinished=%s",
            frame / 1800, team, completed, metal or 0, metalIncome or 0,
            energy or 0, energyIncome or 0, table.concat(entries, ","), table.concat(unfinished, ",")))
    end
end
