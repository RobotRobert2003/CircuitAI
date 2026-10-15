-- Playtest diagnostic: logs every radar structure started, finished and destroyed,
-- with its team and builder, and a per-team count of live radar structures every
-- 60 s. "[RadarWatch] created frame team id def x z builder=<def> builderId=<id>".
-- Used to measure how many radars each team (and its commander) places.
function widget:GetInfo()
	return {name = "Radar watch", desc = "Every radar structure per team, with its builder", author = "s3k-CircuitAI", layer = 0, enabled = true}
end
local radarDefs, live = {}, {}
local function isRadar(def)
	return def and not def.canMove and (def.radarDistance or 0) > 0 and not (def.weapons and #def.weapons > 0)
		and not (def.customParams and def.customParams.iscommander)
end
function widget:Initialize()
	for id, def in pairs(UnitDefs) do
		if isRadar(def) then radarDefs[id] = def.name end
	end
end
function widget:UnitCreated(id, defID, team, builderID)
	if not radarDefs[defID] then return end
	local x, _, z = Spring.GetUnitPosition(id)
	local bdef = builderID and Spring.GetUnitDefID(builderID)
	local bname = bdef and UnitDefs[bdef] and UnitDefs[bdef].name or "none"
	live[id] = team
	Spring.Echo(string.format("[RadarWatch] created frame=%d team=%d id=%d def=%s x=%.0f z=%.0f builder=%s builderId=%s",
		Spring.GetGameFrame(), team, id, radarDefs[defID], x or -1, z or -1, bname, tostring(builderID)))
end
function widget:UnitFinished(id, defID, team)
	if not radarDefs[defID] then return end
	Spring.Echo(string.format("[RadarWatch] finished frame=%d team=%d id=%d def=%s", Spring.GetGameFrame(), team, id, radarDefs[defID]))
end
function widget:UnitDestroyed(id, defID, team)
	if not radarDefs[defID] then return end
	live[id] = nil
	Spring.Echo(string.format("[RadarWatch] destroyed frame=%d team=%d id=%d def=%s", Spring.GetGameFrame(), team, id, radarDefs[defID]))
end
function widget:GameFrame(f)
	if f % 1800 ~= 0 then return end
	local counts = {}
	for id, team in pairs(live) do
		if Spring.ValidUnitID(id) then counts[team] = (counts[team] or 0) + 1 else live[id] = nil end
	end
	local parts = {}
	for team, n in pairs(counts) do parts[#parts + 1] = team .. ":" .. n end
	table.sort(parts)
	Spring.Echo(string.format("[RadarWatch] count frame=%d %s", f, table.concat(parts, " ")))
end
