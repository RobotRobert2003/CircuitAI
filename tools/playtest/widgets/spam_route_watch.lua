function widget:GetInfo()
    return {name="Spam route watch",desc="Read-only: spam units' move queues until they leave their lane",author="CircuitAI",layer=126,enabled=true}
end
-- Owner, 2026-10-24: a spam unit (edge lanes included) keeps its queued MOVE route
-- until it is within 150 elmos of its final move order; only then may the AI hand
-- it to normal attacks. This widget reads every spam unit's command queue twice a
-- game second and logs one line per change of its final move order or queue kind:
--   [SpamWatch] f=<frame> unit=<id> team=<t> def=<name> kind=route|other|empty
--               n=<queue length> pos=(x,z) goal=(x,z) dist=<to goal>
-- "route" is a queue of MOVE orders only, goal its LAST one (the final move order).
-- It also logs a walk-back: a queue re-issued starting at a waypoint the unit had
-- already reached (its route restarted behind it)
-- and a census every game minute. tools/playtest/analyze_spam_routes.py joins these
-- with the AI's [SpamRelease] lines. O(spam units) queue reads per half second; no
-- orders, no callins that BAR withholds from user widgets.
local SPAM={armpw=true,corak=true,leggob=true,armflash=true,corgator=true,leghades=true}
local CMD_MOVE=CMD.MOVE
local watched={}   -- unitID -> {team,def,kind,gx,gz,n,hx,hz (queue head),done (waypoints passed)}
local function defName(id) local d=UnitDefs[Spring.GetUnitDefID(id) or -1];return d and d.name end
local function add(id)
    local name=defName(id)
    if name and SPAM[name] then watched[id]={team=Spring.GetUnitTeam(id),def=name,kind="new",gx=-1,gz=-1,n=0,done={}} end
end
function widget:Initialize()
    for _,id in ipairs(Spring.GetAllUnits()) do add(id) end
    Spring.Echo("[SpamWatch] installed")
end
function widget:UnitFinished(id) add(id) end
function widget:UnitDestroyed(id)
    local w=watched[id]
    if w and w.kind=="route" then
        -- where lane units die, against their final goal: a lane that stalls in a
        -- fight shows deaths at one place; a stuck lane shows none
        local x,_,z=Spring.GetUnitPosition(id)
        if x then Spring.Echo(string.format("[SpamWatch] died f=%d unit=%d team=%d def=%s pos=(%d,%d) goal=(%d,%d) n=%d",
            Spring.GetGameFrame(),id,w.team,w.def,x,z,w.gx,w.gz,w.n)) end
    end
    watched[id]=nil
end
function widget:UnitGiven(id) watched[id]=nil;add(id) end
local function report(f,id,w,kind,n,x,z,gx,gz)
    local dist=(gx>=0) and math.sqrt((x-gx)^2+(z-gz)^2) or -1
    Spring.Echo(string.format("[SpamWatch] f=%d unit=%d team=%d def=%s kind=%s n=%d pos=(%d,%d) goal=(%d,%d) dist=%d",
        f,id,w.team,w.def,kind,n,x,z,gx,gz,dist))
end
function widget:GameFrame(f)
    if f%15~=0 then return end
    local census=(f%1800==0)
    local onRoute,other,empty=0,0,0
    for id,w in pairs(watched) do
        local x,_,z=Spring.GetUnitPosition(id)
        if x then
            local q=Spring.GetUnitCommands(id,16)
            local kind,gx,gz,n="empty",-1,-1,0
            if q and #q>0 then
                n=#q;kind="route"
                for i=1,#q do if q[i].id~=CMD_MOVE then kind="other";break end end
                local last=q[#q]
                if last.params and #last.params>=3 then gx,gz=last.params[1],last.params[3] end
            end
            if kind=="route" then onRoute=onRoute+1 elseif kind=="other" then other=other+1 else empty=empty+1 end
            if census and kind=="route" then   -- once a game minute: every unit on a route queue
                Spring.Echo(string.format("[SpamWatch] at f=%d unit=%d team=%d pos=(%d,%d) n=%d goal=(%d,%d)",f,id,w.team,x,z,n,gx,gz))
            end
            local moved=(gx>=0 and w.gx>=0) and ((gx-w.gx)^2+(gz-w.gz)^2>4*4) or (gx>=0)~=(w.gx>=0)
            local requeued=(kind=="route") and (moved or n>w.n)
            if kind~=w.kind or moved then
                report(f,id,w,kind,n,x,z,gx,gz)
                w.kind=kind
                if gx>=0 then w.gx,w.gz=gx,gz end
            end
            -- walk-back: the new queue starts at a waypoint this unit already passed
            if kind=="route" then
                local hx,hz=q[1].params[1],q[1].params[3]
                if requeued then
                    for _,c in ipairs(w.done) do
                        if (c[1]-hx)^2+(c[2]-hz)^2<48*48 then
                            Spring.Echo(string.format("[SpamWatch] regress f=%d unit=%d team=%d def=%s pos=(%d,%d) goal=(%d,%d) first=(%d,%d)",
                                f,id,w.team,w.def,x,z,gx,gz,hx,hz))
                            break
                        end
                    end
                    if moved then w.done={} end
                elseif n<w.n and w.hx then
                    w.done[#w.done+1]={w.hx,w.hz}   -- the old head was reached and popped
                end
                w.hx,w.hz=hx,hz
            end
            w.n=n
        end
    end
    if census then
        Spring.Echo(string.format("[SpamWatch] census f=%d route=%d other=%d empty=%d",f,onRoute,other,empty))
    end
end
