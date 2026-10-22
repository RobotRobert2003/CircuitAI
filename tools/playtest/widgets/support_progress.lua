-- Read-only SUPPORT evidence. Engine events record first finished units and
-- actual damage; a sparse census measures forward movement without AI orders.
function widget:GetInfo()
    return {name="SUPPORT progress evidence", desc="T2 timing and combat evidence",
        author="CircuitAI", layer=10, enabled=true}
end
function widget:UnitGiven(unit, definition, newTeam, oldTeam)
    if oldTeam == 0 then
        local value = UnitDefs[definition]
        Spring.Echo(string.format("[SupportEvidence] given=%s unit=%d recipient=%d minute=%.2f",
            value and value.name or "unknown", unit, newTeam, Spring.GetGameFrame()/1800))
    end
end
local firstDamage = {}
function widget:UnitFinished(unit, definition, team)
    local value = UnitDefs[definition]
    if value and (team == 0) then
        Spring.Echo(string.format("[SupportEvidence] finished=%s team=%d minute=%.2f",
            value.name, team, Spring.GetGameFrame()/1800))
    end
end
function widget:UnitDamaged(unit, definition, team, damage, paralyzer, weapon, projectile, attacker, attackerDefinition, attackerTeam)
    -- BAR's widget handler forwards only the first five engine arguments.
    attacker = Spring.GetUnitLastAttacker(unit)
    attackerDefinition = attacker and Spring.GetUnitDefID(attacker)
    attackerTeam = attacker and Spring.GetUnitTeam(attacker)
    if attackerTeam ~= 0 or team == 0 or not attackerDefinition or damage <= 0 then return end
    if Spring.AreTeamsAllied(attackerTeam, team) then return end
    local value = UnitDefs[attackerDefinition]
    if value and not firstDamage[value.name] then
        firstDamage[value.name] = true
        Spring.Echo(string.format("[SupportEvidence] damage=%s minute=%.2f", value.name, Spring.GetGameFrame()/1800))
    end
end
