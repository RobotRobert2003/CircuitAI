-- Wall-clock supervision keeps working after GameOver or paused simulation.
function widget:GetInfo()
    return {name="Playtest lifecycle", layer=100000, enabled=true}
end
local lastPoll = Spring.GetTimer()
local quitting = nil
local function finish()
    if not quitting then
        quitting = Spring.GetTimer()
        Spring.Echo("[PlaytestLifecycle] stopping")
    end
end
function widget:GameOver() finish() end
function widget:Update()
    local now = Spring.GetTimer()
    if quitting then
        -- The watcher already observed the scenario's simulated survival tail.
        -- Only allow buffered logging one Update interval before quitting.
        if Spring.DiffTimers(now, quitting) >= .25 then Spring.SendCommands("quitforce") end
        return
    end
    if Spring.DiffTimers(now, lastPoll) < 1 then return end
    lastPoll = now
    Spring.Echo(string.format("[PlaytestHeartbeat] [f=%07d]", Spring.GetGameFrame()))
    if VFS.LoadFile("playtest-stop.txt", VFS.RAW) then finish() end
end
