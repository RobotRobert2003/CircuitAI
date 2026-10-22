-- Optional host-local transport for constructor recovery requests. BARb falls
-- back to AiSendMessage when this widget is absent (headless hosts included).
function widget:GetInfo()
    return {name="BARb constructor recovery relay", desc="Allied AI recovery messaging",
        author="CircuitAI", layer=0, enabled=true}
end
local previous, hook, queue
local function receive(sender, message)
    if type(message) ~= "string" then return end
    local from, target, verb, epoch = message:match("^barbrescue%-relay|(%d+)|(%d+)|(%a+)|(%d+)$")
    from, target = tonumber(from), tonumber(target)
    if not from or from ~= sender or target == from
        or not Spring.AreTeamsAllied(from, target)
        or (verb ~= "request" and verb ~= "cancel" and verb ~= "unavailable") then return end
    -- Constant work per event, bounded by allied teams' 20-second heartbeats.
    -- Flush next GameFrame: SendSkirmishAIMessage must not synchronously enter
    -- an AngelScript context already executing ai.CallUI.
    queue[#queue+1] = {target, "barbrescue-lua|"..from.."|"..target.."|"..verb.."|"..epoch}
    return "barbrescue-queued"
end
function widget:Initialize()
    queue = {}
    local env = getfenv(0)
    previous = rawget(env, "RecvSkirmishAIMessage")
    hook = function(sender, message)
        local reply = receive(sender, message)
        if reply then return reply end
        if previous then return previous(sender, message) end
    end
    rawset(env, "RecvSkirmishAIMessage", hook)
    Script.UpdateCallIn("RecvSkirmishAIMessage")
end
function widget:GameFrame()
    local outgoing = queue
    queue = {}
    for _, message in ipairs(outgoing) do
        Spring.SendSkirmishAIMessage(message[1], message[2])
    end
end
function widget:Shutdown()
    if rawget(getfenv(0), "RecvSkirmishAIMessage") == hook then
        rawset(getfenv(0), "RecvSkirmishAIMessage", previous)
        Script.UpdateCallIn("RecvSkirmishAIMessage")
    end
end
