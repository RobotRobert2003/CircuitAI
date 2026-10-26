-- D-387: observer for capture-for-owner. Logs every extractor that changes
-- team, so a capture is confirmed by the engine and not only by the giver's
-- log, and the extractor count of each ally team once a minute, so a capture
-- game can be compared with a capture-off game on the same seed.
function widget:GetInfo() return {name="Mex capture watch",layer=126,enabled=true} end
local given=0
local seen={}  -- unitID -> frame: the engine can report one transfer twice
local function emit(s) Spring.Echo("[MexCaptureWatch] "..s) end
local function isMex(defID)
    local def=UnitDefs[defID]
    return def and def.extractsMetal and def.extractsMetal>0, def
end
local function census(f)
    local parts={}
    for _,ally in ipairs(Spring.GetAllyTeamList()) do
        local count=0
        for _,team in ipairs(Spring.GetTeamList(ally)) do
            for _,id in ipairs(Spring.GetTeamUnits(team)) do
                local _,_,_,_,progress=Spring.GetUnitHealth(id)
                if progress and progress>=1 and isMex(Spring.GetUnitDefID(id)) then count=count+1 end
            end
        end
        parts[#parts+1]="ally"..ally.."="..count
    end
    emit(string.format("census minute=%d %s",math.floor(f/1800),table.concat(parts," ")))
end
function widget:GameFrame(f)
    if f==90 then emit("observer_started") end
    if f>0 and f%1800==0 then census(f) end
end
function widget:UnitGiven(unitID,unitDefID,newTeam,oldTeam)
    local mex,def=isMex(unitDefID)
    if not mex then return end
    local f=Spring.GetGameFrame()
    if seen[unitID]==f then return end
    seen[unitID]=f
    given=given+1
    local x,_,z=Spring.GetUnitPosition(unitID)
    local allied=Spring.AreTeamsAllied(newTeam,oldTeam)
    emit(string.format("mex-given unit=%d def=%s from=%d to=%d allied=%s x=%.0f z=%.0f count=%d",
        unitID,def.name,oldTeam,newTeam,tostring(allied),x or -1,z or -1,given))
end
