function widget:GetInfo()
    return {name="Skirmish performance observer",desc="Read-only CPU/FPS scopes for D195",layer=127,enabled=true}
end
local previousAI,previousFrame,lastWall=nil,0,nil
local samples,fpsSamples={},{}
local previousScopes={}
local fpsTimer=0
local config=VFS.FileExists("LuaUI/Config/skirmish_perf.lua",VFS.RAW_FIRST) and VFS.Include("LuaUI/Config/skirmish_perf.lua",nil,VFS.RAW_FIRST) or {}
local profiling=config.profiling~=false
local changeIndex=1
local function percentile(values,p)
    return #values>0 and values[math.max(1,math.ceil(#values*p))] or 0
end
function widget:Initialize()
    Spring.SendCommands(profiling and "debug 1 0" or "debug 0 0")
    Spring.Echo("[SkirmishPerfMode] frame="..Spring.GetGameFrame().." enabled="..tostring(profiling))
    lastWall=Spring.GetTimer()
end
function widget:GameOver(winners)
    Spring.Echo("[SkirmishPerfEnd] frame="..Spring.GetGameFrame().." winners="..table.concat(winners or {},","))
end
function widget:TeamDied(team)
    Spring.Echo("[SkirmishPerfTeamDied] frame="..Spring.GetGameFrame().." team="..team)
end
function widget:Update(dt)
    fpsTimer=fpsTimer+dt
    if fpsTimer>=1 then
        fpsTimer=0
        fpsSamples[#fpsSamples+1]=Spring.GetFPS()
    end
end
function widget:GameFrame(frame)
    local total=Spring.GetProfilerTimeRecord("AI",false)
    if previousAI and total>=previousAI and frame>previousFrame then
        samples[#samples+1]=(total-previousAI)/(frame-previousFrame)
    end
    previousAI=total;previousFrame=frame
    if frame>0 and frame%1800==0 then
        local now=Spring.GetTimer()
        local seconds=Spring.DiffTimers(now,lastWall)
        lastWall=now
        table.sort(samples);table.sort(fpsSamples)
        local sum=0
        for _,value in ipairs(samples) do sum=sum+value end
        local wanted,actual,paused=Spring.GetGameSpeed()
        local unitCount=0
        for _,team in ipairs(Spring.GetTeamList()) do unitCount=unitCount+(Spring.GetTeamUnitCount(team) or 0) end
        Spring.Echo(string.format("[SkirmishPerf] frame=%d units=%d wall_s=%.6f speed_wanted=%.3f speed_actual=%.3f ai_n=%d ai_mean_ms=%.6f ai_p50_ms=%.6f ai_p95_ms=%.6f ai_p99_ms=%.6f ai_max_ms=%.6f fps_n=%d fps_p10=%.3f fps_p50=%.3f fps_p90=%.3f profiling=%d",
            frame,unitCount,seconds,wanted,actual,#samples,#samples>0 and sum/#samples or 0,percentile(samples,.5),percentile(samples,.95),percentile(samples,.99),percentile(samples,1),#fpsSamples,percentile(fpsSamples,.1),percentile(fpsSamples,.5),percentile(fpsSamples,.9),profiling and 1 or 0))
        local names=Spring.GetProfilerRecordNames()
        table.sort(names)
        for _,name in ipairs(names) do
            local cumulative=Spring.GetProfilerTimeRecord(name,false)
            local delta=cumulative-(previousScopes[name] or 0)
            Spring.Echo(string.format("[SkirmishScope] frame=%d name=%s total_ms=%.6f interval_ms=%.6f",frame,name,cumulative,delta))
            previousScopes[name]=cumulative
        end
        samples={};fpsSamples={}
    end
    local change=config.changes and config.changes[changeIndex]
    if change and frame>=change.minute*1800 then
        profiling=change.enabled
        Spring.SendCommands(profiling and "debug 1 0" or "debug 0 0")
        Spring.Echo("[SkirmishPerfMode] frame="..frame.." enabled="..tostring(profiling))
        changeIndex=changeIndex+1
    end
end
