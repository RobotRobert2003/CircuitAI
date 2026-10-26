-- t3rush gantry test watcher (spectator, full view). Logs every gantry of the
-- TECH teams: placement (time, team metal income), finish, finished nanos
-- within RADIUS at finish, time after finish to 14 and 20 nanos, first unit
-- the gantry finishes. Emits [GTest] ALL_T3_DONE once every TECH team has its
-- first T3 unit out (or is dead).
function widget:GetInfo()
    return {name="t3rush gantry test watch", layer=116, enabled=true}
end

local TECH = {__TECH_TEAMS__}   -- team ids that start as TECH (from teams.json)
local RADIUS = 600
local GANTRY = {corgant=true, armshltx=true, leggant=true}
local isTech, techDone = {}, {}
for _, t in ipairs(TECH) do isTech[t] = true end
local gantries = {}   -- id -> record
local builtBy = {}    -- unit id -> gantry id
local doneSent = false

local function emit(s) Spring.Echo("[GTest] " .. s) end
local function clock(f) local s = math.floor(f / 30); return string.format("%d:%02d", math.floor(s / 60), s % 60) end

local function nanoCount(g)
    local n = 0
    for _, u in ipairs(Spring.GetUnitsInCylinder(g.x, g.z, RADIUS, g.team) or {}) do
        local d = UnitDefs[Spring.GetUnitDefID(u) or -1]
        if d and d.name:find("nanotc") then
            local _, _, _, _, bp = Spring.GetUnitHealth(u)
            if bp and bp >= 1 then n = n + 1 end
        end
    end
    return n
end

function widget:Initialize()
    local spec, full = Spring.GetSpectatingState()
    if spec and not full then Spring.SendCommands("specfullview 1") end
    emit("init tech_teams=" .. table.concat(TECH, ",") .. " spectating=" .. tostring(spec) .. " fullview=" .. tostring(full))
    for t = 0, 15 do
        local _, _, _, isAI, side, ally, inc = Spring.GetTeamInfo(t)
        if side then emit(string.format("team=%d ally=%s side=%s incomeMultiplier=%s", t, tostring(ally), tostring(side), tostring(inc))) end
    end
end

function widget:UnitCreated(id, defID, team, builder)
    local name = UnitDefs[defID].name
    if builder and gantries[builder] then builtBy[id] = builder end
    if not GANTRY[name] then return end
    local x, _, z = Spring.GetUnitPosition(id)
    local _, _, _, income, expense = Spring.GetTeamResources(team, "metal")
    local f = Spring.GetGameFrame()
    local g = {id=id, team=team, name=name, x=x, z=z, placed=f, income=income}
    gantries[id] = g
    emit(string.format("PLACED team=%d tech=%s gantry=%s id=%d t=%s frame=%d metal_income=%.1f metal_expense=%.1f x=%d z=%d nanos=%d",
        team, tostring(isTech[team] or false), name, id, clock(f), f, income or -1, expense or -1, x, z, nanoCount(g)))
end

function widget:UnitFinished(id, defID, team)
    local f = Spring.GetGameFrame()
    local g = gantries[id]
    if g then
        g.finished = f
        g.nanosAtFinish = nanoCount(g)
        emit(string.format("FINISHED team=%d gantry=%s id=%d t=%s frame=%d build_s=%.0f nanos=%d",
            team, g.name, id, clock(f), f, (f - g.placed) / 30, g.nanosAtFinish))
        return
    end
    local gid = builtBy[id]
    if gid and gantries[gid] and not gantries[gid].first then
        local gg = gantries[gid]
        gg.first = f
        emit(string.format("FIRST_T3 team=%d gantry_id=%d unit=%s t=%s frame=%d after_finish_s=%.0f",
            team, gid, UnitDefs[defID].name, clock(f), f, (f - (gg.finished or f)) / 30))
        techDone[team] = true
    end
end

function widget:UnitDestroyed(id)
    local g = gantries[id]
    if g and not g.dead then g.dead = true; emit(string.format("DESTROYED team=%d gantry_id=%d t=%s", g.team, id, clock(Spring.GetGameFrame()))) end
end

function widget:GameFrame(f)
    if f % 30 ~= 0 then return end
    for id, g in pairs(gantries) do
        if g.finished and not g.dead and (not g.t14 or not g.t20) then
            local n = nanoCount(g)
            if not g.t14 and n >= 14 then g.t14 = f; emit(string.format("NANOS14 team=%d gantry_id=%d t=%s after_finish_s=%.0f", g.team, id, clock(f), (f - g.finished) / 30)) end
            if not g.t20 and n >= 20 then g.t20 = f; emit(string.format("NANOS20 team=%d gantry_id=%d t=%s after_finish_s=%.0f", g.team, id, clock(f), (f - g.finished) / 30)) end
        end
    end
    if f % 1800 == 0 then
        local parts = {}
        for _, t in ipairs(TECH) do
            local _, _, _, income = Spring.GetTeamResources(t, "metal")
            local _, _, dead = Spring.GetTeamInfo(t)
            if dead then techDone[t] = true end
            parts[#parts + 1] = string.format("%d:%.0f", t, income or -1)
        end
        emit("minute=" .. math.floor(f / 1800) .. " tech_metal_income " .. table.concat(parts, " "))
        for id, g in pairs(gantries) do
            if g.finished and not g.dead then emit(string.format("nanos team=%d gantry_id=%d n=%d", g.team, id, nanoCount(g))) end
        end
    end
    if not doneSent then
        local all = #TECH > 0
        for _, t in ipairs(TECH) do if not techDone[t] then all = false end end
        if all then doneSent = true; emit("ALL_T3_DONE t=" .. clock(f)) end
    end
end
