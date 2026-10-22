function widget:GetInfo()
    return {name="Performance spectator cleanup",desc="Remove only the harness spectator commander",layer=129,enabled=true}
end
-- Default retains the established 8v8 fixture. Smaller integration matches
-- declare their roster rather than accidentally probing a nonexistent team.
local cfg=VFS.FileExists("LuaUI/Config/perf_spectator_cleanup.lua") and VFS.Include("LuaUI/Config/perf_spectator_cleanup.lua") or {}
local target=cfg.teams or 16
local requested=false
function widget:GameFrame(frame)
    -- PlayerInfo is unavailable while the spectator is still loading.
    if frame==90 then
        local _,_,_,isAI,_,ally=Spring.GetTeamInfo(target,false)
        local _,_,spectator,playerTeam=Spring.GetPlayerInfo(Spring.GetMyPlayerID(),false)
        -- Spectator widgets change the viewed playerTeam to 0. The pinned
        -- harness team identity is team 16 / ally 2 / no SkirmishAI.
        if isAI or ally~=2 or not spectator then
            Spring.Echo("[PerfFixture] ERROR spectator identity mismatch isAI="..tostring(isAI).." ally="..tostring(ally).." spectator="..tostring(spectator).." playerTeam="..tostring(playerTeam))
            return
        end
        Spring.SendCommands("cheat 1")
        requested=true
    elseif frame==120 and requested then
        local units=Spring.GetTeamUnits(target) or {}
        Spring.SelectUnitArray(units)
        Spring.SendCommands("remove")
        Spring.SelectUnitArray({})
        Spring.Echo("[PerfFixture] requested removal of spectator units count="..#units)
    elseif frame==150 and requested then
        Spring.SendCommands("cheat 0")
    elseif frame==300 then
        local remaining=Spring.GetTeamUnitCount(target) or 0
        local alive=0
        for team=0,target-1 do
            local _,_,dead,isAI=Spring.GetTeamInfo(team,false)
            if isAI and not dead and (Spring.GetTeamUnitCount(team) or 0)>0 then alive=alive+1 end
        end
        Spring.Echo("[PerfFixture] spectator_units="..remaining.." competing_ai_teams="..alive)
        if remaining~=0 or alive~=target then Spring.Echo("[PerfFixture] ERROR invalid competitive roster") end
    end
end
