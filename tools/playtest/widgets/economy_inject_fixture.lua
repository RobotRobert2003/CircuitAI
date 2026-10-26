-- Playtest fixture: a late-game economy for team 0, injected once so a short
-- game shows what a role does with a surplus. At the first finished factory
-- plus INJECT_DELAY (else at INJECT_FALLBACK) team 0 is given AFUS advanced
-- fusions and CONVERTERS advanced energy converters behind its start, plus
-- storage. Fixture evidence only: a run with this widget is an injected
-- economy, never natural-game evidence. Pair it with factory_idle_watch.lua
-- (read only) to see the banks and factory states. Every line is
-- "[EconomyInject] ...".
--
-- Staged by: playtest.py run --extra-widget tools/playtest/widgets/economy_inject_fixture.lua

function widget:GetInfo()
    return {
        name    = "BARb economy inject fixture",
        desc    = "tools/playtest: give team 0 a fusion-era economy once, for spend probes",
        author  = "s3k-CircuitAI",
        date    = "2026-10-25",
        layer   = 11,
        enabled = true,
    }
end

local FPS = 30
local AFUS = 2            -- 3000 E/s each
local CONVERTERS = 8      -- about 10.4 M/s each from 600 E/s
local INJECT_DELAY = 5 * 60 * FPS
local INJECT_FALLBACK = 12 * 60 * FPS
local NAMES = {
    arm = { afus = "armafus", conv = "armmmkr", estor = "armestor", mstor = "armmstor" },
    cor = { afus = "corafus", conv = "cormmkr", estor = "corestor", mstor = "cormstor" },
    leg = { afus = "legafus", conv = "legadveconv", estor = "legestor", mstor = "legmstor" },
}
local queue, injectAt, injected, firstFactoryFrame = {}, nil, false, nil

local function echo(s) Spring.Echo("[EconomyInject] " .. s) end
local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function spot(dx, dz)
    local x, _, z = Spring.GetTeamStartPosition(0)
    local sx = (x < Game.mapSizeX / 2) and -1 or 1
    local sz = (z < Game.mapSizeZ / 2) and -1 or 1
    x = clamp(x + sx * dx, 256, Game.mapSizeX - 256); z = clamp(z + sz * dz, 256, Game.mapSizeZ - 256)
    return x, z
end
local function give(name, count, dx, dz)
    if count <= 0 then return end
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
    give(n.afus, AFUS, 1400, 300)
    give(n.conv, CONVERTERS, 1400, 900)
    give(n.estor, 4, 900, 300)
    give(n.mstor, 2, 900, 700)
    echo(string.format("inject: team 0 side=%s %d %s + %d %s (+%d E/s, ~+%d M/s); injected economy, not natural evidence",
        side, AFUS, n.afus, CONVERTERS, n.conv, AFUS * 3000, CONVERTERS * 10))
end

function widget:UnitFinished(id, defID, team)
    local d = UnitDefs[defID]
    if team == 0 and d and d.isFactory and not firstFactoryFrame then
        firstFactoryFrame = Spring.GetGameFrame()
        injectAt = firstFactoryFrame + INJECT_DELAY
    end
end

function widget:GameFrame(f)
    -- cheats take a network round trip: enable them long before the first give
    if f == 300 then Spring.SendCommands("cheat 1") end
    if not injected then
        if not injectAt and f >= INJECT_FALLBACK then injectAt = f + 1; echo("inject trigger: fallback at 12 min (no factory seen)") end
        if injectAt and f >= injectAt then injected = true; inject() end
    end
    if #queue > 0 and f % 30 == 0 then Spring.SendCommands(table.remove(queue, 1)) end
end
