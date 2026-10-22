-- Playtest camera (tools/playtest): staged into the playtest write dir's
-- LuaUI/Widgets by playtest.py with CFG filled in. It never ships with the AI.
--
-- What it does, all logged as "[Playtest] ..." lines in the infolog so the
-- watcher can pair them with the AI's own lines:
--   * forcestart in the pregame and the game speed at frame 1,
--   * finds the AI under test from the BARb roster message (role + team) or
--     the team's start position, points the overhead camera at it and takes a
--     screenshot at each configured minute (screenshots/screen_<UTC time>.png),
--   * quits the engine at end_minute.
local CFG = __CFG__

function widget:GetInfo()
	return {
		name    = "Playtest camera",
		desc    = "Screenshots of the AI under test and a timed quit (tools/playtest)",
		author  = "s3k-CircuitAI",
		date    = "2026-09-21",
		layer   = 0,
		enabled = true,
	}
end

local FPS = 30
local target = { team = CFG.team, x = nil, z = nil, found = false }
local shots = {}
local pending = nil
local ended = false

local function echo(s)
	Spring.Echo(CFG.log_prefix .. " " .. s)
end

local function split(s, sep)
	local out = {}
	for piece in string.gmatch(s .. sep, "([^" .. sep .. "]*)" .. sep) do
		out[#out + 1] = piece
	end
	return out
end

function widget:Initialize()
	for i, s in ipairs(CFG.shots or {}) do
		shots[i] = { minute = s.minute, frame = math.floor(s.minute * 60 * FPS), height = s.height or 2200, x = s.x, z = s.z, done = false }
	end
	echo(string.format("widget loaded: role %s, team %s, speed %s, %d shots, end at %s min",
		tostring(CFG.role), tostring(CFG.team), tostring(CFG.speed), #shots, tostring(CFG.end_minute)))
	Spring.SendCommands("specfullview 3")
	-- BAR's Autoquit widget exits the game when the mouse has not moved; nobody moves it here
	Spring.SendCommands("luaui disablewidget Autoquit")
	if widgetHandler and widgetHandler.DisableWidget then
		widgetHandler:DisableWidget("Autoquit")
	end
	echo("Autoquit widget disabled")
	if CFG.forcestart and Spring.GetGameFrame() <= 0 then
		Spring.SendCommands("forcestart")
	end
end

function widget:GameStart()
	if CFG.forcestart then
		Spring.SendCommands("forcestart")
	end
end

-- roster line: "barb|roster|<team>|<ally>|roster|?|teamId|aiId|role|side|factory|x|z|landLocked|spot|leader"
function widget:RecvSkirmishAIMessage(aiTeam, dataStr)
	if type(dataStr) ~= "string" or string.sub(dataStr, 1, 5) ~= "barb|" then return end
	local p = split(dataStr, "|")
	if p[2] ~= "roster" then return end
	local teamId, role, x, z = tonumber(p[7]), p[9], tonumber(p[12]), tonumber(p[13])
	if target.found then return end
	if role == CFG.role and (CFG.team == nil or teamId == CFG.team) then
		target.found, target.team, target.x, target.z = true, teamId, x, z
		echo(string.format("target team %d (%s) at (%d, %d) from the roster", teamId, role, x or -1, z or -1))
	end
end

local function resolveTarget()
	if target.found then return true end
	local team = CFG.team or 0
	local x, y, z = Spring.GetTeamStartPosition(team)
	if x and z then
		target.found, target.team, target.x, target.z = true, team, x, z
		echo(string.format("target team %d at (%d, %d) from its start position", team, x, z))
		return true
	end
	return false
end

local function lookAt(x, z, height)
	local y = Spring.GetGroundHeight(x, z) or 0
	Spring.SetCameraState({mode=1, px=x, py=math.max(0,y), pz=z, height=height, angle=0.8}, 0)
	echo(string.format("camera requested (%d,%d) height=%d", x, z, height))
end

local function prepareShot(x,z,height,minute)
	-- Keep camera/render settling independent of fast-forward simulation.
	local speed=Spring.GetGameSpeed()
	Spring.SendCommands({"setminspeed 0.25", "setmaxspeed 0.25"})
	lookAt(x,z,height)
	pending={started=Spring.GetTimer(),draws=0,minute=minute,x=x,z=z,height=height,speed=speed}
end

local function dumpTeams(n)
	for _, t in ipairs(Spring.GetTeamList()) do
		local _, leader, isDead, isAI, side, ally = Spring.GetTeamInfo(t, false)
		local x, y, z = Spring.GetTeamStartPosition(t)
		echo(string.format("frame %d team %d ally %s side %s ai %s dead %s start (%d, %d) units %d",
			n, t, tostring(ally), tostring(side), tostring(isAI), tostring(isDead), x or -1, z or -1, Spring.GetTeamUnitCount(t) or -1))
	end
end

-- every structure the team under test finishes, and any unit costing 2,000+ metal
-- (T3), as "[Playtest] finished <def> team <t> at <min>" for the benchmark tracker
function widget:UnitFinished(unitID, unitDefID, unitTeam)
	local ud = UnitDefs[unitDefID]
	if not ud then return end
	local team = CFG.team or 0
	if unitTeam ~= team then return end
	-- every immobile unit: isBuilding needs a yardmap, which BAR's construction
	-- turrets lack, so they were never reported (found 2026-09-22)
	if ud.isImmobile or (ud.metalCost or 0) >= 2000 then
		local n = Spring.GetGameFrame()
		echo(string.format("finished %s team %d at %.2f min", ud.name, unitTeam, n / (60 * FPS)))
	end
end

local function dumpEco(n)
	local team = CFG.team or 0
	local m, ms, _, mi = Spring.GetTeamResources(team, "metal")
	local e, es, _, ei = Spring.GetTeamResources(team, "energy")
	echo(string.format("eco team %d at %.1f min: metal +%.1f bank %d/%d, energy +%.1f bank %d/%d, units %d",
		team, n / (60 * FPS), mi or 0, m or 0, ms or 0, ei or 0, e or 0, es or 0, Spring.GetTeamUnitCount(team) or 0))
end

function widget:DrawScreen()
	if pending then pending.draws = pending.draws + 1 end
end

function widget:Shutdown()
	if pending then
		Spring.SendCommands({"setmaxspeed "..pending.speed,"setminspeed "..pending.speed})
		pending=nil
	end
end

function widget:Update()
	if not pending then return end
	-- Other spectator camera widgets can restore their own state after a jump.
	-- Hold this explicit test camera only during the screenshot settling window.
	Spring.SetCameraState({mode=1,px=pending.x,py=math.max(0,Spring.GetGroundHeight(pending.x,pending.z)),
		pz=pending.z,height=pending.height,angle=0.8},0)
	local elapsed = Spring.DiffTimers(Spring.GetTimer(),pending.started)
	if elapsed >= 5 and pending.draws < 3 then
		echo("screenshot timeout: restoring speed")
		Spring.SendCommands({"setmaxspeed "..pending.speed,"setminspeed "..pending.speed})
		pending=nil
		return
	end
	if pending.draws>=3 and elapsed>=1 then
		local state=Spring.GetCameraState()
		echo(string.format("camera captured name=%s position=(%.0f,%.0f) height=%.0f",
			tostring(state.name),state.px or -1,state.pz or -1,state.height or -1))
		Spring.SendCommands("screenshot png")
		echo(string.format("screenshot at %.1f min of team %d at (%d, %d)",pending.minute,target.team or -1,pending.x,pending.z))
		Spring.SendCommands({"setmaxspeed "..pending.speed,"setminspeed "..pending.speed})
		pending=nil
	end
end

-- "[Playtest] decided: ..." once, when a single AI alliance still has living
-- units; playtest.py stops the run there unless --play-decided is given, so a
-- won game does not run on to stop_minute. Humans/spectator teams are ignored:
-- the host sits in its own ally team with a commander on every playtest.
local decidedEchoed = false
local function checkDecided(n)
	if decidedEchoed then return end
	local aiAllies, aliveAllies, aliveTeams = {}, {}, {}
	for _, t in ipairs(Spring.GetTeamList()) do
		local _, _, isDead, isAI, _, ally = Spring.GetTeamInfo(t, false)
		if isAI then
			aiAllies[ally] = true
			if not isDead and (Spring.GetTeamUnitCount(t) or 0) > 0 then
				aliveAllies[ally] = true
				aliveTeams[#aliveTeams + 1] = t
			end
		end
	end
	local total, alive, last = 0, 0, nil
	for a in pairs(aiAllies) do total = total + 1 end
	for a in pairs(aliveAllies) do alive = alive + 1; last = a end
	if total > 1 and alive <= 1 then
		decidedEchoed = true
		echo(string.format("decided: ally %s alone with teams %s at %.1f min", tostring(last), table.concat(aliveTeams, ","), n / (60 * FPS)))
	end
end

function widget:GameFrame(n)
	-- owner: the BARb AI window stays closed in tests, so screenshots are clear
	-- (the installed copy may be an older one that opens itself on a fresh config;
	-- a test that needs it opens it with WG.barblink.SetOpen(true) after this)
	if n <= 300 and n % 30 == 0 and WG.barblink and WG.barblink.IsOpen and WG.barblink.IsOpen() then
		WG.barblink.SetOpen(false)
		echo("BARb AI window closed for the screenshots")
	end
	if n % 1800 == 0 then dumpEco(n); checkDecided(n) end
	if n == 1 then
		Spring.SendCommands("luaui disablewidget Autoquit")
		-- The spectator TV can replace the requested camera during its render
		-- settling interval. Disable it only in this isolated test UI.
		Spring.SendCommands("luaui disablewidget Player-TV")
		if widgetHandler and widgetHandler.DisableWidget then widgetHandler:DisableWidget("Player-TV") end
	end
	if n == 1 or n == 90 then dumpTeams(n) end
	if n == 1 and CFG.speed and CFG.speed > 1 then
		Spring.SendCommands({ "setmaxspeed " .. CFG.speed, "setminspeed " .. CFG.speed })
		echo("speed " .. CFG.speed)
	end
	-- the speed plan: fast between the moments a test watches, 1 at them
	for _, sp in ipairs(CFG.speed_plan or {}) do
		if not sp.done and n >= math.max(2, math.floor(sp.minute * 1800)) then
			sp.done = true
			-- the engine keeps max >= min: lowering sets min first, raising max first
			local cur = Spring.GetGameSpeed()   -- the user speed factor
			if sp.speed < (cur or 1) then
				Spring.SendCommands({ "setminspeed " .. sp.speed, "setmaxspeed " .. sp.speed })
			else
				Spring.SendCommands({ "setmaxspeed " .. sp.speed, "setminspeed " .. sp.speed })
			end
			echo(string.format("speed %s at %.2f min", sp.speed, n / 1800))
		end
	end
	for _, s in ipairs(shots) do
		if not s.done and n >= s.frame then
			s.done = true
			if s.x and s.z then
				prepareShot(s.x,s.z,s.height,s.minute)
			elseif resolveTarget() then
				local x,z=target.x,target.z
				-- A terrain-constrained AIR opening can establish its factory away
				-- from the nominal start (including a water start). Follow the
				-- actual base for automatic AIR shots; explicit shot coordinates
				-- and every other role keep their original meaning.
				if CFG.role=="AIR" then
					local nearest=math.huge
					for _,id in ipairs(Spring.GetTeamUnits(target.team or 0)) do
						local def=UnitDefs[Spring.GetUnitDefID(id)]
						if def and def.isFactory then
							local px,_,pz=Spring.GetUnitPosition(id)
							local distance=px and (px-target.x)^2+(pz-target.z)^2 or math.huge
							if distance<nearest then x,z,nearest=px,pz,distance end
						end
					end
				end
				prepareShot(x,z,s.height,s.minute)
			else
				echo(string.format("no target for the %.1f min screenshot", s.minute))
			end
		end
	end
	if not ended and CFG.end_minute and n >= math.floor(CFG.end_minute * 60 * FPS) then
		ended = true
		echo(string.format("end at %.1f min: quitting", n / (60 * FPS)))
		Spring.SendCommands("quitforce")
	end
end
