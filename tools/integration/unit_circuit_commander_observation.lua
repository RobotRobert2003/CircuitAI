-- Optional BAR game-side adapter. Install as LuaRules/Gadgets/ in a game
-- development checkout. No spectator widget, global projectile sweep, hidden
-- enemy identity, or hidden firing direction is required by CircuitAI.
function gadget:GetInfo()
    return {name="Circuit commander observation",desc="Ally-LOS projectile volumes for local commander evasion",
        author="CircuitAI",date="2026-10-12",license="GPLv2 or later",layer=0,enabled=true}
end
local action="circuit_commander_observation"
if not gadgetHandler:IsSyncedCode() then
    local function receive(_,team,message)
        -- Engine dispatch reaches only the AI instances hosted on this client.
        Spring.SendSkirmishAIMessage(team,message)
    end
    function gadget:Initialize() gadgetHandler:AddSyncAction(action,receive) end
    function gadget:Shutdown() gadgetHandler:RemoveSyncAction(action) end
    return
end

local commanders,definitions,teams={},{},{}
local interval,radius,maximum=3,1000,128
for id,def in pairs(UnitDefs) do
    if def.customParams and def.customParams.iscommander and not def.customParams.decoyfor then definitions[id]=true end
end
local function add(id,def,team)
    if not definitions[def] then return end
    local _,_,_,isAI,_,ally=Spring.GetTeamInfo(team,false)
    if not isAI then return end
    commanders[id]={team=team,ally=ally}
    Spring.SetUnitRulesParam(id,"circuit_comm_transported",Spring.GetUnitTransporter(id) and 1 or 0,{allied=true})
end
function gadget:Initialize()
    for _,id in ipairs(Spring.GetAllUnits()) do add(id,Spring.GetUnitDefID(id),Spring.GetUnitTeam(id)) end
end
function gadget:UnitCreated(id,def,team) add(id,def,team) end
function gadget:UnitDestroyed(id) commanders[id]=nil end
function gadget:UnitTaken(id) commanders[id]=nil end
function gadget:UnitGiven(id,def,team) add(id,def,team) end
function gadget:UnitLoaded(id) if commanders[id] then Spring.SetUnitRulesParam(id,"circuit_comm_transported",1,{allied=true}) end end
function gadget:UnitUnloaded(id) if commanders[id] then Spring.SetUnitRulesParam(id,"circuit_comm_transported",0,{allied=true}) end end
function gadget:GameFrame(frame)
    if frame%interval~=0 then return end
    -- Spatial engine queries, per owned commander. No scan of the complete
    -- late-game projectile population. Team buffers are retained and deduped.
    for _,buffer in pairs(teams) do buffer.count=0; for key in pairs(buffer.seen) do buffer.seen[key]=nil end end
    for id,owner in pairs(commanders) do
        local x,y,z=Spring.GetUnitPosition(id)
        if x then
            local buffer=teams[owner.team]
            if not buffer then buffer={count=0,rows={},seen={}};teams[owner.team]=buffer end
            local ids=Spring.GetProjectilesInRectangle(x-radius,z-radius,x+radius,z+radius) or {}
            table.sort(ids) -- deterministic truncation; omitted threats remain covered by native weapon risk
            for _,projectile in ipairs(ids) do
                if buffer.count>=maximum then break end
                if not buffer.seen[projectile] then
                    buffer.seen[projectile]=true
                    local px,py,pz=Spring.GetProjectilePosition(projectile)
                    local team=Spring.GetProjectileTeamID(projectile)
                    local weapon=Spring.GetProjectileDefID(projectile)
                    local def=weapon and WeaponDefs[weapon]
                    if px and def and team and not Spring.AreTeamsAllied(owner.team,team)
                        and Spring.IsPosInLos(px,py,pz,owner.ally) and math.abs(py-y)<300 then
                        local vx,vy,vz=Spring.GetProjectileVelocity(projectile)
                        if vx then
                            buffer.count=buffer.count+1
                            buffer.rows[buffer.count]=string.format("|%.2f %.2f %.2f %.2f %.2f",px,pz,vx*30,vz*30,
                                math.min(1000,def.damageAreaOfEffect or 16))
                        end
                    end
                end
            end
        end
    end
    for team,buffer in pairs(teams) do
        SendToUnsynced(action,team,"comm_projectiles|"..frame.."|"..buffer.count..table.concat(buffer.rows,"",1,buffer.count))
    end
end
