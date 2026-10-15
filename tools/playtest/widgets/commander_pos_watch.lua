-- D-302 playtest diagnostic: logs "[CommPos] frame team id x z cmd queue speed" for every
-- commander every 150 frames. cmd=nil means an empty queue (idle). Used with
-- tools/playtest/checks/shared/combat/commander-front-scylla.json.
function widget:GetInfo()
	return {name = "Commander position watch", desc = "D-302: every commander's position, current command and queue every 5 s", author = "s3k-CircuitAI", layer = 0, enabled = true}
end
local comms = {}
function widget:Initialize()
	for _, id in ipairs(Spring.GetAllUnits()) do
		local def = UnitDefs[Spring.GetUnitDefID(id)]
		if def and def.customParams and def.customParams.iscommander then comms[id] = true end
	end
end
function widget:UnitCreated(id, defID)
	local def = UnitDefs[defID]
	if def and def.customParams and def.customParams.iscommander then comms[id] = true end
end
function widget:GameFrame(f)
	if f % 150 ~= 0 then return end
	for id in pairs(comms) do
		if Spring.ValidUnitID(id) then
			local x, _, z = Spring.GetUnitPosition(id)
			local cmd = Spring.GetUnitCurrentCommand(id)
			local q = Spring.GetUnitCommandCount and Spring.GetUnitCommandCount(id) or -1
			local vx, _, vz = Spring.GetUnitVelocity(id)
			local team = Spring.GetUnitTeam(id)
			Spring.Echo(string.format("[CommPos] frame=%d team=%d id=%d x=%.0f z=%.0f cmd=%s queue=%s speed=%.1f",
				f, team, id, x or -1, z or -1, tostring(cmd), tostring(q), math.sqrt((vx or 0)^2 + (vz or 0)^2) * 30))
		else
			comms[id] = nil
		end
	end
end
