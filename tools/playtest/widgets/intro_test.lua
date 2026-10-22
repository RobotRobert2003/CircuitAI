-- Playtest watcher for the AI's start-of-game intro (systems/presentation/commands.as): the
-- whole-map overview camera, a screenshot while the commander and "Do not spec
-- cheat!" stand, one while the credits stand, one after both are erased. The
-- playtest joins as a spectator, so the shots are what a spectator sees.
-- Every line is "[IntroTest] ...".
function widget:GetInfo()
	return {
		name    = "BARb intro test",
		desc    = "tools/playtest: screenshots of the AI's start-of-game intro",
		author  = "s3k-CircuitAI",
		date    = "2026-09-26",
		layer   = 10,
		enabled = true,
	}
end

-- the AI starts at 3 s and holds each drawing 10 s: "SMRTBARb", the commander
-- and its bold warning (~700 strokes) at a hand's pace (~60 a second, ~12 s),
-- then the erase and the bold credits, top left (~2600 strokes, ~290 a second,
-- ~9 s)
local STEPS = {
	{ frame = 60,   act = "overview" },
	{ frame = 240,  act = "shot", why = "the title and commander part-drawn (a hand's pace)" },
	{ frame = 620,  act = "shot", why = "the title, the commander and its text (held 10 s)" },
	{ frame = 1200, act = "shot", why = "the credits (held 10 s)" },
	{ frame = 1800, act = "shot", why = "after the intro: the map clear" },
	{ frame = 1806, act = "overview" },
}
local nextStep = 1
local received = { line = 0, erase = 0, point = 0 }   -- map draws that reached this client

-- counts only (returns false: the engine still draws them)
function widget:MapDrawCmd(playerID, cmdType)
	received[cmdType] = (received[cmdType] or 0) + 1
	return false
end

local function echo(s) Spring.Echo("[IntroTest] " .. s) end

function widget:GameFrame(n)
	local s = STEPS[nextStep]
	if not s or n < s.frame then return end
	nextStep = nextStep + 1
	if s.act == "overview" then
		Spring.SendCommands("toggleoverview")
		echo("overview toggled; spectating " .. tostring(Spring.GetSpectatingState()))
	elseif s.act == "shot" then
		Spring.SendCommands("screenshot png")
		echo(string.format("screenshot at %.1f s: %s; received so far: %d lines, %d erases, %d points", n / 30, s.why,
			received.line or 0, received.erase or 0, received.point or 0))
	end
end
