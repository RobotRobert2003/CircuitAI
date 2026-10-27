-- Anti-spam arena (owner, 2026-10-27): the viewer plays the spam team. It
-- spawns waves of spam units (cheat give) at a spawn point and fight-moves
-- them down a lane toward the AIs, and keeps score of the AIs' anti-spam
-- defence: kills before death of every parked unit, gun and construction
-- turret, and nano heals (repair sessions and hit points restored).
-- Config: LuaUI/Config/anti_spam_arena.lua (see README.md), returning
--   { spam_team = 0, end_minute = 40, ai_starts = {{x,z},...}, breach_radius = 1500,
--     waves = { {minute = 8, unit = "corak", count = 30, spawn = {x,z}, route = {{x,z},...}}, ... } }
-- Lines:
--   [AntiSpamArena] wave minute=.. unit=.. count=.. spawned=..
--   [AntiSpamArena] breach id=.. def=.. frame=..              (a spam unit inside breach_radius of an AI start)
--   [AntiSpamStats] died id=.. team=.. def=.. kind=parked|gun|nano|other kills=.. life=..s healed=..hp heals=..
--   [AntiSpamStats] summary ... (every 60 s and at the end), then [AntiSpamArena] END
-- Cost: O(watched units) health reads every 15 frames, O(nanos) build-target reads; orders only to the spam team.
function widget:GetInfo()
    return {name = "Anti-spam arena", layer = 118, enabled = true}
end

local cfg = VFS.Include("LuaUI/Config/anti_spam_arena.lua")
local SPAM_TEAM = cfg.spam_team or 0
local END_FRAME = math.floor((cfg.end_minute or 40) * 60 * 30)
local BREACH = cfg.breach_radius or 1500
local PARKED = {armraz = true, leginc = true, corsumo = true, cordemon = true, legaheattank = true,
    legshot = true, legstr = true, armzeus = true, armmav = true, armlatnk = true, armwar = true}
local GUN = {armbeamer = true, corhllt = true, legmg = true, armclaw = true, cormaw = true, legdtr = true}
local NANO = {armnanotc = true, cornanotc = true, legnanotc = true}

local waves, pendingWave = {}, nil
local watched = {}       -- AI unit id -> {def, team, kind, born, kills, lastHp, healed, heals, healing}
local nanos = {}         -- AI nano id -> {healed, heals, target}
local spam = {}          -- spam unit id -> {def, born, breached}
local tally = {spawned = 0, spam_killed = 0, breached = 0, ai_lost = 0, ai_lost_metal = 0}
local byDef = {}         -- def -> {n, died, kills, healed, heals}
local ended = false

local function log(tag, s) Spring.Echo("[" .. tag .. "] " .. s) end
local function defName(udid) local d = UnitDefs[udid or -1]; return d and d.name or "?" end
local function kindOf(name)
    if PARKED[name] then return "parked" end
    if GUN[name] then return "gun" end
    if NANO[name] then return "nano" end
    return "other"
end
local function stat(name)
    byDef[name] = byDef[name] or {n = 0, died = 0, kills = 0, healed = 0, heals = 0}
    return byDef[name]
end

function widget:Initialize()
    Spring.SendCommands("cheat 1")
    Spring.SendCommands("globallos")
    for i, w in ipairs(cfg.waves or {}) do waves[i] = w end
    table.sort(waves, function(a, b) return a.minute < b.minute end)
    for _, id in ipairs(Spring.GetAllUnits()) do
        widget:UnitFinished(id, Spring.GetUnitDefID(id), Spring.GetUnitTeam(id))
    end
end

local function spawnWave(w)
    local x, z = w.spawn[1], w.spawn[2]
    local y = Spring.GetGroundHeight(x, z)
    pendingWave = {w = w, ids = {}, frame = Spring.GetGameFrame()}
    Spring.SendCommands(string.format("give %d %s %d @%d,%d,%d", w.count, w.unit, SPAM_TEAM, x, y, z))
end

local function orderWave()
    local p = pendingWave
    pendingWave = nil
    if #p.ids == 0 then return end
    local first = true
    for _, pt in ipairs(p.w.route or {}) do
        local opts = first and {} or {"shift"}
        Spring.GiveOrderToUnitArray(p.ids, CMD.FIGHT, {pt[1], Spring.GetGroundHeight(pt[1], pt[2]), pt[2]}, opts)
        first = false
    end
    log("AntiSpamArena", string.format("wave minute=%s unit=%s count=%d spawned=%d", tostring(p.w.minute), p.w.unit, p.w.count, #p.ids))
end

function widget:UnitCreated(id, udid, team)
    if team == SPAM_TEAM then
        local name = defName(udid)
        spam[id] = {def = name, born = Spring.GetGameFrame(), breached = false}
        if pendingWave and name == pendingWave.w.unit then
            local ids = pendingWave.ids
            ids[#ids + 1] = id
            tally.spawned = tally.spawned + 1
        end
    end
end

function widget:UnitFinished(id, udid, team)
    if not udid or team == SPAM_TEAM or watched[id] then return end
    local name = defName(udid)
    local kind = kindOf(name)
    local hp = Spring.GetUnitHealth(id)
    watched[id] = {def = name, team = team, kind = kind, born = Spring.GetGameFrame(), kills = 0,
        lastHp = hp or 0, healed = 0, heals = 0}
    if kind ~= "other" then stat(name).n = stat(name).n + 1 end
    if kind == "nano" then nanos[id] = {healed = 0, heals = 0, target = nil} end
end

function widget:UnitDestroyed(id, udid, team, attacker, attackerDef, attackerTeam)
    if attacker == nil then
        attacker = Spring.GetUnitLastAttacker(id)
        if attacker and attacker < 0 then attacker = nil end
    end
    local a = attacker and watched[attacker]
    if a and team == SPAM_TEAM then a.kills = a.kills + 1 end
    if spam[id] then
        tally.spam_killed = tally.spam_killed + 1
        spam[id] = nil
    end
    local w = watched[id]
    if w then
        tally.ai_lost = tally.ai_lost + 1
        tally.ai_lost_metal = tally.ai_lost_metal + (UnitDefs[udid] and UnitDefs[udid].metalCost or 0)
        if w.kind ~= "other" then
            local s = stat(w.def)
            s.died = s.died + 1
            log("AntiSpamStats", string.format("died id=%d team=%d def=%s kind=%s kills=%d life=%ds healed=%dhp heals=%d by=%s",
                id, w.team, w.def, w.kind, w.kills, math.floor((Spring.GetGameFrame() - w.born) / 30), math.floor(w.healed), w.heals,
                attackerDef and defName(attackerDef) or "?"))
        end
        local s = w.kind ~= "other" and stat(w.def) or nil
        if s then s.kills = s.kills + w.kills; s.healed = s.healed + w.healed; s.heals = s.heals + w.heals end
        w.counted = true
        watched[id] = nil
        nanos[id] = nil
    end
end

local function summary(final)
    local live = {}
    for _, w in pairs(watched) do
        if w.kind ~= "other" then
            local l = live[w.def] or {n = 0, kills = 0, healed = 0, heals = 0}
            l.n = l.n + 1; l.kills = l.kills + w.kills; l.healed = l.healed + w.healed; l.heals = l.heals + w.heals
            live[w.def] = l
        end
    end
    local parts = {}
    for name, s in pairs(byDef) do
        local l = live[name] or {n = 0, kills = 0, healed = 0, heals = 0}
        local kills = s.kills + l.kills
        parts[#parts + 1] = string.format("%s:n=%d,died=%d,alive=%d,kills=%d,kills_per_death=%.1f,healed=%d,heals=%d",
            name, s.n, s.died, l.n, kills, s.died > 0 and s.kills / s.died or 0, math.floor(s.healed + l.healed), s.heals + l.heals)
    end
    local nh, nhp = 0, 0
    for _, n in pairs(nanos) do nh = nh + n.heals; nhp = nhp + n.healed end
    log("AntiSpamStats", string.format("summary%s frame=%d spawned=%d spam_killed=%d breached=%d ai_lost=%d ai_lost_metal=%d live_nano_heals=%d live_nano_healed=%dhp units=%s",
        final and " final" or "", Spring.GetGameFrame(), tally.spawned, tally.spam_killed, tally.breached, tally.ai_lost,
        math.floor(tally.ai_lost_metal), nh, math.floor(nhp), table.concat(parts, " ")))
end

function widget:GameFrame(f)
    if ended then return end
    -- the give lands a few to ~30 frames after the command: order once the whole wave stands (or after 3 s)
    if pendingWave and (#pendingWave.ids >= pendingWave.w.count or f - pendingWave.frame >= 90) then orderWave() end
    if not pendingWave and #waves > 0 and f >= waves[1].minute * 60 * 30 then
        spawnWave(table.remove(waves, 1))
    end
    if f % 15 == 0 then
        -- heals: a nano working on a damaged, finished unit; hit points it gained meanwhile
        local repairing = {}
        for nid, n in pairs(nanos) do
            local t = Spring.GetUnitIsBuilding(nid)
            local tw = t and watched[t]
            if tw and select(5, Spring.GetUnitHealth(t)) == 1 then
                repairing[t] = nid
                if n.target ~= t then n.heals = n.heals + 1; tw.heals = tw.heals + 1; n.target = t end
            else
                n.target = nil
            end
        end
        for id, w in pairs(watched) do
            local hp = Spring.GetUnitHealth(id)
            if hp then
                local nid = repairing[id]
                if nid and hp > w.lastHp then
                    w.healed = w.healed + (hp - w.lastHp)
                    nanos[nid].healed = nanos[nid].healed + (hp - w.lastHp)
                end
                w.lastHp = hp
            end
        end
    end
    if f % 30 == 0 and cfg.ai_starts then
        for id, s in pairs(spam) do
            if not s.breached then
                local x, _, z = Spring.GetUnitPosition(id)
                if x then
                    for _, p in ipairs(cfg.ai_starts) do
                        if (x - p[1]) ^ 2 + (z - p[2]) ^ 2 < BREACH * BREACH then
                            s.breached = true
                            tally.breached = tally.breached + 1
                            log("AntiSpamArena", string.format("breach id=%d def=%s frame=%d", id, s.def, f))
                            break
                        end
                    end
                end
            end
        end
    end
    if f % 1800 == 0 then summary(false) end
    if f >= END_FRAME then
        ended = true
        summary(true)
        log("AntiSpamArena", "END")
        Spring.SendCommands("quitforce")
    end
end

function widget:GameOver()
    if ended then return end
    ended = true
    summary(true)
    log("AntiSpamArena", "END")
end
