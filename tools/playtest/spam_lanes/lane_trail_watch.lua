-- Spam lane trail watcher (spectator, full view). Read-only: records where every
-- spam unit (the T1 spam defs) and every unit a T3 gantry finishes actually
-- walked, one point every 5 game seconds when it moved more than STEP elmos.
-- One line per unit when it dies, and for every live unit at END_FRAME:
--   [LaneTrail] unit=<id> team=<t> def=<name> born=<frame> last=<frame> why=died|end n=<k> pts=x,z;x,z;...
-- then "[LaneTrail] END". parse.py joins the trails with the AI's [SpamJoin]
-- lines (which lane each unit took) and its planned waypoints.
-- Cost: O(watched units) position reads every 150 frames; no orders.
function widget:GetInfo()
    return {name="Spam lane trail watch", layer=117, enabled=true}
end

local END_FRAME = __END_FRAME__
local STEP = 200
local MAXPTS = 120
local SPAM = {armpw=true, corak=true, leggob=true, armflash=true, corgator=true, leghades=true}
local GANTRY = {corgant=true, armshltx=true, leggant=true}
local watched = {}   -- id -> {team, def, born, pts = {x1, z1, x2, z2, ...}}
local ended = false

local function defName(udid) local d = UnitDefs[udid or -1]; return d and d.name end

local function add(id, udid, team, frame)
    local x, _, z = Spring.GetUnitPosition(id)
    if not x then return end
    watched[id] = {team = team, def = defName(udid) or "?", born = frame, pts = {math.floor(x), math.floor(z)}}
end

local function dump(id, w, why)
    local n = #w.pts / 2
    if n < 2 then return end
    local s = {}
    for i = 1, #w.pts, 2 do s[#s + 1] = w.pts[i] .. "," .. w.pts[i + 1] end
    Spring.Echo(string.format("[LaneTrail] unit=%d team=%d def=%s born=%d last=%d why=%s n=%d pts=%s",
        id, w.team, w.def, w.born, Spring.GetGameFrame(), why, n, table.concat(s, ";")))
end

function widget:Initialize()
    local spec, full = Spring.GetSpectatingState()
    if spec and not full then Spring.SendCommands("specfullview 1") end
    Spring.Echo("[LaneTrail] installed end_frame=" .. END_FRAME)
end

function widget:UnitFinished(id, udid, team)
    if ended then return end
    local name = defName(udid)
    if name and SPAM[name] then add(id, udid, team, Spring.GetGameFrame()) end
end

function widget:UnitFromFactory(id, udid, team, factID, factDefID)
    if ended then return end
    if GANTRY[defName(factDefID) or ""] and not watched[id] then add(id, udid, team, Spring.GetGameFrame()) end
end

function widget:UnitDestroyed(id)
    local w = watched[id]
    if w then dump(id, w, "died"); watched[id] = nil end
end

function widget:UnitGiven(id) watched[id] = nil end

local function dumpAll(why)
    if ended then return end
    ended = true
    for id, w in pairs(watched) do dump(id, w, why) end
    watched = {}
    Spring.Echo("[LaneTrail] END f=" .. Spring.GetGameFrame())
end
-- a game that ends early (one ally team left) still dumps the live units
function widget:GameOver() dumpAll("end") end
function widget:Shutdown() dumpAll("end") end

function widget:GameFrame(f)
    if ended or f % 150 ~= 0 then return end
    for id, w in pairs(watched) do
        local x, _, z = Spring.GetUnitPosition(id)
        if x then
            local k = #w.pts
            local dx, dz = x - w.pts[k - 1], z - w.pts[k]
            if dx * dx + dz * dz > STEP * STEP and k < MAXPTS * 2 then
                w.pts[k + 1] = math.floor(x); w.pts[k + 2] = math.floor(z)
            end
        end
    end
    if f >= END_FRAME then dumpAll("end") end
end
