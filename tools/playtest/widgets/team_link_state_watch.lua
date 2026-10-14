-- D-300 playtest: the BARb team link reads AI state from the state files
-- (LuaUI/Config/BARb/state/team<N>.txt) instead of RecvSkirmishAIMessage,
-- which BAR's user-widget sandbox no longer delivers. Drives WG.barblink the
-- way its buttons do and checks every synced surface except lanes:
--   roster (every hosted AI's role), aggression reply, runtime role switch and
--   its reply event, the event log, the base-layout overlay (show and hide).
-- Waits are in wall-clock seconds as well as frames: the state file is
-- eventually consistent in wall time (0.5-3 s write, 1 s poll), so a fast game
-- must not be judged before the files could have changed.
--
-- Stage: --extra-widget tools/widgets/gui_barb_team_link.lua
--        --extra-widget tools/playtest/widgets/team_link_state_watch.lua
-- Check: tools/playtest/checks/shared/reliability/team_link_state.json
-- Every line starts "[LinkCheck]".

function widget:GetInfo()
	return {name = "BARb team link state check", desc = "tools/playtest: D-300 widget state sync",
		author = "s3k-CircuitAI", date = "2026-10-14", layer = 110, enabled = true}
end

local WAIT_SECONDS = 8      -- worst case 3 s write + 1 s poll, with margin
local stage, stageTimer, stageFrame = 0, nil, 0
local aggressionTeam, roleTeam, roleTarget, techTeam = nil, nil, nil, nil
local shot = nil

local function echo(s) Spring.Echo("[LinkCheck] " .. s) end
local function check(ok, label) echo((ok and "PASS " or "FAIL ") .. label) end
local function advance(n) stage, stageTimer, stageFrame = n, Spring.GetTimer(), Spring.GetGameFrame() end
local function waited(frames)
	return stageTimer and Spring.DiffTimers(Spring.GetTimer(), stageTimer) >= WAIT_SECONDS
		and Spring.GetGameFrame() - stageFrame >= frames
end

local function hostedAIs()
	local out = {}
	for _, teamId in ipairs(Spring.GetTeamList() or {}) do
		local _, _, isDead, isAI = Spring.GetTeamInfo(teamId)
		local _, _, host = Spring.GetAIInfo(teamId)
		if isAI and not isDead and host == Spring.GetMyPlayerID() then out[#out + 1] = teamId end
	end
	return out
end

function widget:DrawScreen()
	if shot then shot.draws = shot.draws + 1 end
end

function widget:Update()
	local ui = WG.barblink
	if not ui then return end
	if shot then
		Spring.SetCameraState({mode = 1, px = shot.x, py = math.max(0, Spring.GetGroundHeight(shot.x, shot.z)),
			pz = shot.z, height = 1800, angle = 0.8}, 0)
		if shot.draws >= 3 and Spring.DiffTimers(Spring.GetTimer(), shot.started) >= 1 then
			Spring.SendCommands("screenshot png"); echo("screenshot " .. shot.label); shot = nil
		end
	end
	local f = Spring.GetGameFrame()
	if stage == 0 and f >= 450 then
		ui.SetOpen(true)
		ui.SetBlueprints("team")
		advance(1)
	elseif stage == 1 and waited(300) then
		-- Roster: every hosted AI announced its role through the file.
		local roster, hosted = ui.Roster(), hostedAIs()
		local n = 0
		for _, id in ipairs(hosted) do
			local r = roster[id]
			check(r ~= nil and r.role ~= nil, "roster team " .. id .. " role=" .. tostring(r and r.role)
				.. " seq=" .. tostring(ui.StateSeq(id)))
			if r then
				n = n + 1
				if r.allyTeam == 0 then
					if r.role == "TECH" then techTeam = techTeam or id
					elseif not roleTeam then roleTeam = id end
				end
				aggressionTeam = aggressionTeam or id
			end
		end
		check(#hosted > 0 and n == #hosted, "roster complete " .. n .. "/" .. #hosted)
		-- Commands go out on the unchanged widget -> AI channel; the replies
		-- must come back through the state file.
		if aggressionTeam then ui.SetAggression(aggressionTeam, 0.5) end
		if roleTeam then
			roleTarget = roster[roleTeam].role == "FRONT" and "AIR" or "FRONT"
			ui.SetRole(roleTeam, roleTarget)
		end
		advance(2)
	elseif stage == 2 and waited(300) then
		local delta = aggressionTeam and ui.GetAggression(aggressionTeam)
		check(delta ~= nil and math.abs(delta - 0.5) < 0.01, "aggression reply team " .. tostring(aggressionTeam)
			.. " delta=" .. tostring(delta))
		if roleTeam then
			local r = ui.Roster()[roleTeam]
			check(r ~= nil and r.role == roleTarget, "role switch team " .. roleTeam .. " now " .. tostring(r and r.role))
			local reply = ui.LastReply(roleTeam)
			check(reply ~= nil and reply:find("ok", 1, true) ~= nil, "role reply event team " .. roleTeam
				.. " '" .. tostring(reply) .. "'")
		else
			check(false, "no second ally-team AI to switch")
		end
		check(ui.EventCount() > 0, "event log entries=" .. ui.EventCount())
		local best, slots = nil, 0
		for _, id in ipairs(hostedAIs()) do
			local s = ui.BlueprintSnapshot(id)
			if s.visible and s.ready and s.slots > slots then best, slots = id, s.slots end
		end
		check(best ~= nil and slots > 0, "layout overlay team " .. tostring(best) .. " slots=" .. slots)
		if best then
			local s = ui.BlueprintSnapshot(best)
			local x, _, z = Spring.GetTeamStartPosition(best)
			shot = {x = s.x or x, z = s.z or z, draws = 0, started = Spring.GetTimer(), label = "layout team " .. best}
		end
		advance(3)
	elseif stage == 3 and waited(150) then
		ui.SetBlueprints(nil)
		advance(4)
	elseif stage == 4 and waited(60) then
		local hidden = true
		for _, id in ipairs(hostedAIs()) do if ui.BlueprintSnapshot(id).visible then hidden = false end end
		check(hidden, "layout overlay hidden")
		ui.SetBlueprints("team")
		advance(5)
	elseif stage == 5 and waited(150) then
		local ready = false
		for _, id in ipairs(hostedAIs()) do
			local s = ui.BlueprintSnapshot(id)
			if s.visible and s.ready and s.slots > 0 then ready = true end
		end
		check(ready, "layout overlay shown again")
		check(true, "completed")
		advance(6)
	end
end
