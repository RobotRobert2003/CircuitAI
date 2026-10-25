-- Playtest observer for "the bank is full and the labs stand idle": once a
-- minute, for every AI team, the metal and energy banks, incomes and usage, and
-- every finished factory with its engine state (building, repeat, build-queue
-- length, idle seconds since its queue last emptied), plus the number of
-- finished mobile builders and how many of them are idle (no command). Read
-- only: no orders, no cheats. Every line is "[FactoryIdle] ...".
--
-- Staged by: playtest.py run --extra-widget tools/playtest/widgets/factory_idle_watch.lua

function widget:GetInfo()
    return {
        name    = "BARb factory idle watch",
        desc    = "tools/playtest: per-team banks, factory states and idle builders",
        author  = "s3k-CircuitAI",
        date    = "2026-10-25",
        layer   = 10,
        enabled = true,
    }
end

local FPS = 30
local EVERY = 60 * FPS
local idleSince = {}   -- factory id -> frame its queue was first seen empty

local function echo(s) Spring.Echo("[FactoryIdle] " .. s) end

local function sample(f)
    for _, team in ipairs(Spring.GetTeamList() or {}) do
        local _, _, dead, isAI = Spring.GetTeamInfo(team, false)
        if isAI and not dead then
            local mc, ms, _, mi, me = Spring.GetTeamResources(team, "metal")
            local ec, es, _, ei, ee = Spring.GetTeamResources(team, "energy")
            local labs, builders, idleBuilders = {}, 0, 0
            for _, u in ipairs(Spring.GetTeamUnits(team) or {}) do
                local d = UnitDefs[Spring.GetUnitDefID(u) or -1]
                local _, _, _, _, bp = Spring.GetUnitHealth(u)
                if d and (bp or 1) >= 1 then
                    if d.isFactory then
                        local st = Spring.GetUnitStates(u) or {}
                        local builds = Spring.GetFactoryCommands(u, 0) or 0
                        local building = Spring.GetUnitIsBuilding(u) ~= nil
                        if builds == 0 and not building then
                            idleSince[u] = idleSince[u] or f
                        else
                            idleSince[u] = nil
                        end
                        local idle = idleSince[u] and math.floor((f - idleSince[u]) / FPS) or 0
                        labs[#labs + 1] = string.format("%s#%d building=%s repeat=%s builds=%d idle=%ds",
                            d.name, u, tostring(building), tostring(st["repeat"]), builds, idle)
                    elseif d.isBuilder and d.canMove then
                        builders = builders + 1
                        if (Spring.GetUnitCommands(u, 0) or 0) == 0 then idleBuilders = idleBuilders + 1 end
                    end
                end
            end
            echo(string.format("%.0f min team %d metal=%.0f/%.0f +%.1f -%.1f energy=%.0f/%.0f +%.0f -%.0f builders=%d idle=%d",
                f / (60 * FPS), team, mc or 0, ms or 0, mi or 0, me or 0, ec or 0, es or 0, ei or 0, ee or 0, builders, idleBuilders))
            echo(string.format("%.0f min team %d factories: %s", f / (60 * FPS), team, #labs > 0 and table.concat(labs, " | ") or "none"))
        end
    end
end

function widget:GameFrame(f)
    if f > 0 and f % EVERY == 0 then sample(f) end
end
