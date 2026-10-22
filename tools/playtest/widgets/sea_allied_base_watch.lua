function widget:GetInfo() return {name="SEA allied bases observer",layer=126,enabled=true,handler=true} end
local cfg=VFS.Include("LuaUI/Config/sea_base.lua")
local queue,claims,first,seen,meta={},{},{},{},{}
local prior,hook
for _,t in ipairs(cfg.teams) do meta[t.team]=t end
local yards={armsy=true,armasy=true,corsy=true,corasy=true,legsy=true,legadvshipyard=true}
local function eco(name)
    return name:find("tide") or name:find("uwfus") or name:find("navalfusion") or name:find("fmkr") or name:find("uwmmm")
        or name=="leganavaleconv" or name=="legfeconv"
end
local function log(s) Spring.Echo("[BaseWatch] "..s) end
local function forward(team,x,z)
    local m=meta[team];local dx,dz,n=0,0,0
    for _,t in pairs(meta) do if t.ally~=m.ally then dx=dx+t.x;dz=dz+t.z;n=n+1 end end
    dx,dz=dx/n-m.x,dz/n-m.z
    if math.abs(dx)>math.abs(dz) then return (x-m.x)*(dx>0 and 1 or -1),dx>0 and 1 or 3 end
    return (z-m.z)*(dz>0 and 1 or -1),dz>0 and 0 or 2
end
local function halves(id,d)
    local f=Spring.GetUnitBuildFacing(id) or 0
    return (f%2==0 and d.xsize or d.zsize)*4,(f%2==0 and d.zsize or d.xsize)*4
end
function widget:Initialize()
    local env=getfenv(0);prior=rawget(env,"RecvSkirmishAIMessage")
    hook=function(team,text)
        local name,x,z,n=text:match("^barb|baseprobe|%d+|%d+|give|([^|]+)|([^|]+)|([^|]+)|(%d+)$")
        if cfg.supplied and name then
            x,z=tonumber(x),tonumber(z)
            queue[#queue+1]="give "..n.." "..name.." "..team.." @"..x..","..Spring.GetGroundHeight(x,z)..","..z
        end
        local hx,hz
        x,z,hx,hz=text:match("^barb|baseprobe|%d+|%d+|claim|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
        if x then claims[#claims+1]={team=team,x=tonumber(x),z=tonumber(z),hx=tonumber(hx),hz=tonumber(hz)};log("cluster team="..team) end
        if prior then return prior(team,text) end
    end
    rawset(env,"RecvSkirmishAIMessage",hook);Script.UpdateCallIn("RecvSkirmishAIMessage")
    log("loaded")
end
function widget:UnitCreated(id,def,team)
    if not meta[team] or meta[team].role~="SEA" then return end
    local d=UnitDefs[def]
    if yards[d.name] and not first[team] then first[team]=id end
end
function widget:UnitFinished(id,def,team)
    if not meta[team] or meta[team].role~="SEA" then return end
    local d=UnitDefs[def];if not yards[d.name] or id==first[team] then return end
    local x,_,z=Spring.GetUnitPosition(id);local along,f=forward(team,x,z)
    local hx,hz=halves(id,d);local rear=along-(f%2==0 and hz or hx)
    local front=-1e6
    for _,u in ipairs(Spring.GetTeamUnits(team)) do
        local ud=UnitDefs[Spring.GetUnitDefID(u)]
        if ud.isImmobile and eco(ud.name) then
            local ux,_,uz=Spring.GetUnitPosition(u);local a=forward(team,ux,uz)
            local ex,ez=halves(u,ud);front=math.max(front,a+(f%2==0 and ez or ex))
        end
    end
    for _,c in ipairs(claims) do if c.team==team then
        local a=forward(team,c.x,c.z);front=math.max(front,a+(f%2==0 and c.hz or c.hx))
    end end
    local ok=Spring.GetUnitBuildFacing(id)==f and rear>=front+127
    log((ok and "PASS" or "FAIL").." forward yard team="..team.." unit="..d.name.." rear="..rear.." eco="..front.." facing="..Spring.GetUnitBuildFacing(id).." expected="..f)
end
function widget:GameFrame(frame)
    -- Natural benchmarks must preserve each AI's fog of war. GlobalLOS is a
    -- synced game command that reveals enemies to every allyteam, not a
    -- spectator-only rendering option. Only supplied fixtures may enable it.
    if cfg.supplied and frame==150 then Spring.SendCommands({"cheat 1","globallos"}) end
    if frame%5==0 and #queue>0 then Spring.SendCommands(table.remove(queue,1)) end
    if frame%150~=0 then return end
    for _,c in ipairs(claims) do
        for _,t in pairs(meta) do if t.ally==meta[c.team].ally and t.team~=c.team then
            for _,id in ipairs(Spring.GetTeamUnits(t.team)) do
                local d=UnitDefs[Spring.GetUnitDefID(id)]
                if d.isImmobile and not seen[id] then
                    local x,_,z=Spring.GetUnitPosition(id);local hx,hz=halves(id,d)
                    if math.abs(x-c.x)<c.hx+hx-.1 and math.abs(z-c.z)<c.hz+hz-.1 then
                        seen[id]=true;log("FAIL foreign building in cluster owner="..c.team.." intruder="..t.team.." def="..d.name)
                    end
                end
            end
        end end
    end
    if frame==14*1800 and #claims>0 then log("PASS cluster observation complete count="..#claims) end
end
function widget:Shutdown()
    local env=getfenv(0)
    if rawget(env,"RecvSkirmishAIMessage")==hook then rawset(env,"RecvSkirmishAIMessage",prior);Script.UpdateCallIn("RecvSkirmishAIMessage") end
end
