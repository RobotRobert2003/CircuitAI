-- Playtest observer for the shared spam pumps (D-111 / D-216): once a minute,
-- for every team, each T1 land lab's engine repeat flag, its build queue
-- length, its rally (unit) command queue, and a census of the spam products
-- (Global::Spam::UnitByFactory) by first command. Optionally injects a
-- fusion-era economy into team 0 so spam activates inside a short game.
-- Every line is "[SpamPump] ...". Injected runs are fixture evidence, not
-- natural-game evidence.
--
-- Staged by: playtest.py run --extra-widget tools/playtest/widgets/spam_pump_watch.lua
-- Injection is on by default; set INJECT=false below for a natural watch.

function widget:GetInfo()
    return {
        name    = "BARb spam pump watch",
        desc    = "tools/playtest: T1 lab repeat flags, factory routes and spam unit commands per team",
        author  = "s3k-CircuitAI",
        date    = "2026-10-25",
        layer   = 10,
        enabled = true,
    }
end

local FPS = 30
local EVERY = 60 * FPS
local INJECT = true
local INJECT_FALLBACK = 9 * 60 * FPS   -- inject at the first T1 lab + 6 min, else at 9 min
local INJECT_DELAY = 6 * 60 * FPS
-- 3 advanced fusions clear the energy gate; CONVERTERS adds ~10.4 M/s each. 0 keeps the
-- metal income near the activation gate, so LabsWanted stays at one pump while the
-- role may own two labs (the D-366 case); 12 lifts it to two or three pumps.
local CONVERTERS = 0

local LABS = { armlab = true, corlab = true, leglab = true, armvp = true, corvp = true, legvp = true }
local SPAM = { armpw = true, corak = true, leggob = true, armflash = true, corgator = true, leghades = true }
local NAMES = {
    arm = { afus = "armafus", conv = "armmmkr", estor = "armestor", mstor = "armmstor" },
    cor = { afus = "corafus", conv = "cormmkr", estor = "corestor", mstor = "cormstor" },
    leg = { afus = "legafus", conv = "legadveconv", estor = "legestor", mstor = "legmstor" },
}
local labDef, spamDef = {}, {}
for name in pairs(LABS) do local ud = UnitDefNames[name]; if ud then labDef[ud.id] = name end end
for name in pairs(SPAM) do local ud = UnitDefNames[name]; if ud then spamDef[ud.id] = name end end

local CMDNAME = { [CMD.MOVE] = "move", [CMD.FIGHT] = "fight", [CMD.ATTACK] = "attack", [CMD.PATROL] = "patrol", [CMD.GUARD] = "guard" }
local queue = {}
local injectAt = nil
local injected = false
local firstLabFrame = nil

local function echo(s) Spring.Echo("[SpamPump] " .. s) end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function spot(dx, dz)
    local x, _, z = Spring.GetTeamStartPosition(0)
    local sx = (x < Game.mapSizeX / 2) and -1 or 1
    local sz = (z < Game.mapSizeZ / 2) and -1 or 1
    x = clamp(x + sx * dx, 256, Game.mapSizeX - 256); z = clamp(z + sz * dz, 256, Game.mapSizeZ - 256)
    return x, z
end
local function give(name, count, dx, dz)
    local x, z = spot(dx, dz)
    queue[#queue + 1] = "give " .. count .. " " .. name .. " 0 @" .. math.floor(x) .. "," .. math.floor(Spring.GetGroundHeight(x, z)) .. "," .. math.floor(z)
end
local function detectSide()
    for _, u in ipairs(Spring.GetTeamUnits(0) or {}) do
        local def = UnitDefs[Spring.GetUnitDefID(u) or -1]
        if def and NAMES[string.sub(def.name, 1, 3)] then return string.sub(def.name, 1, 3) end
    end
    return "cor"
end
local function inject()
    local side = detectSide()
    local n = NAMES[side]
    give(n.afus, 3, 1400, 300)
    if CONVERTERS > 0 then give(n.conv, CONVERTERS, 1400, 900) end
    give(n.estor, 4, 900, 300)
    give(n.mstor, 2, 900, 700)
    echo("inject: team 0 side=" .. side .. " 3 " .. n.afus .. " + " .. CONVERTERS .. " " .. n.conv .. " (+9000 E/s, ~+" .. (CONVERTERS * 10) .. " M/s); injected economy, not natural evidence")
end

function widget:UnitFinished(id, defID, team)
    if team == 0 and labDef[defID] and not firstLabFrame then
        firstLabFrame = Spring.GetGameFrame()
        if INJECT then injectAt = firstLabFrame + INJECT_DELAY end
    end
end

local function report(f)
    for _, team in ipairs(Spring.GetTeamList() or {}) do
        local units = Spring.GetTeamUnits(team) or {}
        local labs = {}
        local census, byCmd = {}, {}
        local total = 0
        for _, u in ipairs(units) do
            local d = Spring.GetUnitDefID(u) or -1
            local _, _, _, _, bp = Spring.GetUnitHealth(u)
            if (bp or 1) >= 1 then
                if labDef[d] then
                    local st = Spring.GetUnitStates(u) or {}
                    local builds = Spring.GetFactoryCommands(u, 0) or 0
                    local rally = Spring.GetUnitCommands(u, 0) or 0
                    local firstRally = Spring.GetUnitCommands(u, 1)
                    local rc = (firstRally and firstRally[1]) and (CMDNAME[firstRally[1].id] or tostring(firstRally[1].id)) or "none"
                    labs[#labs + 1] = string.format("%s#%d repeat=%s builds=%d building=%s rally=%d/%s",
                        labDef[d], u, tostring(st["repeat"]), builds, tostring(Spring.GetUnitIsBuilding(u) ~= nil), rally, rc)
                elseif spamDef[d] then
                    total = total + 1
                    census[spamDef[d]] = (census[spamDef[d]] or 0) + 1
                    local c = Spring.GetUnitCommands(u, 1)
                    local k = (c and c[1]) and (CMDNAME[c[1].id] or tostring(c[1].id)) or "idle"
                    byCmd[k] = (byCmd[k] or 0) + 1
                end
            end
        end
        if #labs > 0 or total > 0 then
            local parts = {}
            for k, v in pairs(census) do parts[#parts + 1] = k .. "=" .. v end
            local cmds = {}
            for k, v in pairs(byCmd) do cmds[#cmds + 1] = k .. "=" .. v end
            table.sort(parts); table.sort(cmds)
            echo(string.format("%.0f min team %d labs: %s", f / (60 * FPS), team, #labs > 0 and table.concat(labs, " | ") or "none"))
            echo(string.format("%.0f min team %d spam units=%d [%s] by first command [%s]", f / (60 * FPS), team, total,
                table.concat(parts, " "), table.concat(cmds, " ")))
        end
    end
end

function widget:GameFrame(f)
    -- cheats take a network round trip: enable them long before the first give
    if INJECT and f == 300 then Spring.SendCommands("cheat 1") end
    if INJECT and not injected then
        if not injectAt and f >= INJECT_FALLBACK then injectAt = f + 1; echo("inject trigger: fallback at 9 min (no T1 lab seen)") end
        if injectAt and f >= injectAt then injected = true; inject() end
    end
    if #queue > 0 and f % 30 == 0 then Spring.SendCommands(table.remove(queue, 1)) end
    if f > 0 and f % EVERY == 0 then report(f) end
end
