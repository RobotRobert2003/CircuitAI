-- D-323 / D-326 playtest: the terrain map in the BARb team link. Drives the
-- panel through its own button paths (WG.barblink.ButtonRect + MousePress /
-- MouseRelease, SetField, FieldSnapshot, FieldLayer, FieldBlueprint), waits in
-- wall-clock seconds for the field file the AI writes once, then takes a series
-- of screenshots: the full map, the dim sheet, blueprint mode, the ground
-- classes alone, each sea and pond, each summit, and the narrowest land choke.
--
-- Stage: --extra-widget tools/widgets/gui_barb_team_link.lua
--        --extra-widget tools/playtest/widgets/field_watch.lua
-- Check: tools/playtest/checks/shared/terrain/field_terrain.json (any map) or
--        field_supreme.json (Supreme Isthmus counts)
-- Every check line starts "[FieldCheck]"; each screenshot is announced with a
-- "[Playtest] screenshot field <label>" line just before the capture.
-- Pass --shots "" so the runner's camera does not fight this one.

function widget:GetInfo()
    return {name = "BARb terrain map check", desc = "tools/playtest: D-323/D-326 terrain map screenshots",
        author = "s3k-CircuitAI", date = "2026-10-18", layer = 110, enabled = true}
end

local LOAD_SECONDS = 60
local SHOT_GAP = 12          -- frames between camera set and capture, and between shots
local START_FRAME = 150

local stage = 0              -- 0 wait, 1 open, 2 loading, 3 shooting, 4 done
local stageFrame = 0
local loadTimer = nil
local shots = {}             -- queued shots: {label=, x=, z=, height=, before=fn, after=fn}
local shotIndex = 0
local shotState = 0          -- 0 set camera, 1 capture pending
local shotFrame = 0
local taken = 0

local function echo(s) Spring.Echo("[FieldCheck] " .. s) end
local function check(ok, label) echo((ok and "PASS " or "FAIL ") .. label) end

local function click(ui, id)
    local r = ui.ButtonRect(id)
    if not r then echo("FAIL missing button " .. id); return false end
    local x, y = (r[1] + r[3]) / 2, (r[2] + r[4]) / 2
    ui.MousePress(x, y, 1); ui.MouseRelease(x, y, 1)
    return true
end

-- Every shot, overview and close-up alike, uses the free camera pointed
-- straight down at an explicit height: the overhead ("ta") camera caps its
-- height, and once the free camera is active a "ta" state no longer takes
-- effect (the close-ups rendered the sky). The first switch tries fps, free,
-- viewfree-then-free and "ov" in that order, one attempt per frame (viewfree
-- needs a frame), each read back through Spring.GetCameraState and accepted
-- when its height is within 20% of the request; later shots reuse the free
-- state directly, still verified by readback.
local function freeState(x, z, height)
    return {name = "free", px = x, py = height, pz = z, rx = -math.pi / 2, ry = math.pi, rz = 0}
end
local cam = {attempt = 0, done = false, used = nil, switched = false}
local function cameraHeight()
    local s = Spring.GetCameraState()
    if not s then return nil, "?" end
    return s.py or s.height, s.name or "?"
end
local function cameraAccepted(H)
    local h, name = cameraHeight()
    if h and math.abs(h - H) <= 0.2 * H then cam.used = string.format("%s py=%d", tostring(name), h); return true end
    return false
end
-- Returns true when the camera is settled for this shot (accepted, or every attempt tried).
local function cameraStep(x, z, H)
    if cam.done then return true end
    cam.attempt = cam.attempt + 1
    local a = cam.attempt
    if cam.switched then
        -- the free camera is already active: one state, verified
        if a == 1 then pcall(Spring.SetCameraState, freeState(x, z, H), 0)
        else
            local h, name = cameraHeight()
            echo(string.format("WARN camera height %s (camera %s, wanted %d)", tostring(h and math.floor(h) or "?"), tostring(name), H))
            cam.used = string.format("%s py=%s (off)", tostring(name), tostring(h and math.floor(h) or "?"))
            cam.done = true
            return true
        end
    elseif a == 1 then
        pcall(Spring.SetCameraState, {name = "fps", px = x, py = H, pz = z, rx = -math.pi / 2, ry = math.pi, rz = 0, fov = 45}, 0)
    elseif a == 2 then
        pcall(Spring.SetCameraState, freeState(x, z, H), 0)
    elseif a == 3 then
        pcall(Spring.SendCommands, "viewfree")
        return false   -- the free camera is active next frame
    elseif a == 4 then
        pcall(Spring.SetCameraState, freeState(x, z, H), 0)
    elseif a == 5 then
        pcall(Spring.SetCameraState, {name = "ov"}, 0)
    else
        local h, name = cameraHeight()
        echo(string.format("WARN full map height clamped to %s (camera %s, wanted %d)", tostring(h and math.floor(h) or "?"), tostring(name), H))
        cam.used = string.format("%s py=%s (clamped)", tostring(name), tostring(h and math.floor(h) or "?"))
        cam.done = true
        return true
    end
    if cameraAccepted(H) then cam.done = true; cam.switched = true; return true end
    return false
end
local function cameraReset() cam.attempt, cam.done, cam.used = 0, false, nil end

local function queue(label, x, z, height, before, after, overview)
    shots[#shots + 1] = {label = label, x = x, z = z, height = height, before = before, after = after, overview = overview}
end

local ALL_BUT_GROUND = {"regions", "crossings", "barriers", "shores", "chokes", "key", "labels"}

-- Ground truth for summits: the engine's own pathfinder. A summit is a plateau the
-- analysis says no bot or vehicle reaches; if Spring.RequestPath finds a bot (BOT3)
-- or vehicle (TANK3) path from any start position that ends within 160 elmos of the
-- summit's label point, the detection is wrong and the check fails. The pathfinder
-- answers an unreachable goal with no path or a path that stops short.
-- the movedefs by example unit (Pawn: bot, Stumpy: vehicle), as path types the engine accepts
local function moveTypeOf(unitName, fallback)
    local ud = UnitDefNames and UnitDefNames[unitName]
    local md = ud and ud.moveDef
    if md and md.id then return md.id end
    return fallback
end
local SUMMIT_CLASSES = {moveTypeOf("armpw", "bot3"), moveTypeOf("armstump", "tank3")}
local CLASS_LABEL = {[SUMMIT_CLASSES[1]] = "BOT3", [SUMMIT_CLASSES[2]] = "TANK3"}
local function pathEnd(cls, o, x, z, verbose)
    local gy = Spring.GetGroundHeight(x, z)
    local oy = Spring.GetGroundHeight(o[1], o[3])
    local ok, path = pcall(Spring.RequestPath, cls, o[1], oy, o[3], x, gy, z, 8)
    if not ok or not path then
        if verbose then echo(string.format("path %s from (%d,%d) to (%d,%d): %s", tostring(cls), o[1], o[3], x, z, ok and "no path" or ("error " .. tostring(path)))) end
        return nil
    end
    -- the detailed waypoints when the path has them; otherwise walk it with Next()
    -- the nearest the path comes to the goal, horizontally, and the ground height there:
    -- a path that stops at the foot of the cliff is close on the map but far below
    local okw, wps = pcall(function() return path:GetPathWayPoints() end)
    local best, bestH = nil, nil
    local function consider(px, pz)
        local d = math.sqrt((px - x)^2 + (pz - z)^2)
        if not best or d < best then best, bestH = d, Spring.GetGroundHeight(px, pz) end
    end
    if okw and type(wps) == "table" and #wps > 0 then
        for _, p in ipairs(wps) do consider(p[1], p[3]) end
    end
    local cx, cy, cz, steps = o[1], oy, o[3], 0
    while steps < 400 do
        local okn, nx, ny, nz = pcall(function() return path:Next(cx, cy, cz, 16) end)
        if not okn or not nx then break end
        consider(nx, nz)
        if (nx - cx)^2 + (nz - cz)^2 < 1 then break end
        cx, cy, cz, steps = nx, ny, nz, steps + 1
    end
    if verbose then echo(string.format("path %s from (%d,%d) to (%d,%d): waypoints %d, walked %d steps, nearest %s elmos", tostring(cls), o[1], o[3], x, z,
        (okw and type(wps) == "table") and #wps or -1, steps, best and string.format("%d", best) or "none")) end
    return best, bestH
end
local function checkSummits(snap)
    local summits = snap.items.summits or {}
    if #summits == 0 then echo("no summits on this map"); return end
    local origins = {}
    for _, teamID in ipairs(Spring.GetTeamList()) do
        -- AI teams only: the spectator's dummy team starts at the map corner (64, 64)
        local _, _, isDead, hasAI = Spring.GetTeamInfo(teamID, false)
        local alive = (isDead == false or isDead == 0)
        local ai = (hasAI == true or (type(hasAI) == "number" and hasAI > 0))
        local x, y, z = Spring.GetTeamStartPosition(teamID)
        if ai and alive and x and (x > 0 or z > 0) then origins[#origins + 1] = {x, y, z, teamID} end
    end
    if #origins < 2 then echo("WARN summit check skipped: fewer than two start positions"); return end
    -- self-test: a start must reach another start by bot, else the pathfinder answer is not usable
    local d = pathEnd(SUMMIT_CLASSES[1], origins[1], origins[2][1], origins[2][3], true)
    if not d or d > 160 then echo("WARN summit check skipped: pathfinder gives no bot path between start positions"); return end
    for _, s in ipairs(summits) do
        local reached = nil
        for _, cls in ipairs(SUMMIT_CLASSES) do
            for _, o in ipairs(origins) do
                local dist, h = pathEnd(cls, o, s.x, s.z)
                -- on the plateau: within 160 elmos of its label and no lower than its lowest cell
                if dist and dist < 160 and h and h >= (s.minH or -1e9) - 8 and h <= (s.maxH or 1e9) + 8 then
                    reached = string.format("%s from team %d ends %d elmos from it at height %d (plateau %d..%d)", CLASS_LABEL[cls] or tostring(cls), o[4], dist, h, s.minH or 0, s.maxH or 0); break
                end
            end
            if reached then break end
        end
        check(reached == nil, string.format("summit region %d unreachable by bots and vehicles%s", s.region, reached and (": " .. reached) or ""))
    end
end

local function planShots(ui, snap)
    local cx, cz = Game.mapSizeX / 2, Game.mapSizeZ / 2
    local full = math.max(Game.mapSizeX, Game.mapSizeZ) * 1.1   -- the free camera is not clamped; the map fills the frame
    queue("full", cx, cz, full, nil, nil, true)
    -- the dim terrain sheet (the middle contrast setting) over the full map
    queue("dim", cx, cz, full, function() Spring.SendCommands("barbfield dim") end, function() Spring.SendCommands("barbfield dim") end, true)
    queue("blueprint", cx, cz, full, function() ui.FieldBlueprint(true) end, function() ui.FieldBlueprint(false) end, true)
    -- the ground classes alone over the coastlines: the terrain detection by itself
    queue("ground", cx, cz, full, function()
        for _, name in ipairs(ALL_BUT_GROUND) do ui.FieldLayer(name, false) end
    end, function()
        for _, name in ipairs(ALL_BUT_GROUND) do ui.FieldLayer(name, true) end
    end, true)
    -- each sea and pond at 5000, by id
    local waters = {}
    for _, t in ipairs(snap.items.theatres) do if t.kind ~= "land" then waters[#waters + 1] = t end end
    table.sort(waters, function(a, b) return a.id < b.id end)
    for i = 1, math.min(4, #waters) do queue(waters[i].kind .. waters[i].id, waters[i].x, waters[i].z, 5000) end
    -- each summit at 2500, largest first
    local summits = {}
    for _, s in ipairs(snap.items.summits or {}) do summits[#summits + 1] = s end
    table.sort(summits, function(a, b) if a.cells ~= b.cells then return a.cells > b.cells end return a.region < b.region end)
    for i = 1, math.min(3, #summits) do queue("summit" .. summits[i].region, summits[i].x, summits[i].z, 2500) end
    -- the narrowest land choke
    local narrowest = nil
    for _, c in ipairs(snap.items.chokes) do
        if c.land and (not narrowest or c.width < narrowest.width) then narrowest = c end
    end
    if narrowest then queue("choke" .. narrowest.id, narrowest.x, narrowest.z, 2200) end
    -- the legend panel open over the map centre, so its samples can be read against the map
    queue("legend", cx, cz, 3200, function() ui.FieldLegend(true) end, function() ui.FieldLegend(false) end)
end

function widget:GameFrame(f)
    local ui = WG.barblink
    if not ui then return end
    if stage == 0 and f >= START_FRAME then
        ui.SetOpen(true); stage = 1; stageFrame = f
    elseif stage == 1 and f >= stageFrame + 30 then
        if ui.ButtonRect("fieldShow") then click(ui, "fieldShow") else ui.SetField(true); echo("WARN fieldShow button not laid out, used SetField") end
        -- the lifecycle widget may close the window between our open and the
        -- click (a press on a closed window does nothing): fall back to the API
        local snap = ui.FieldSnapshot()
        if not (snap and snap.on) then ui.SetField(true); echo("WARN fieldShow press did not show the view, used SetField") end
        loadTimer = Spring.GetTimer(); stage = 2
    elseif stage == 2 then
        local snap = ui.FieldSnapshot()
        if snap and snap.loaded then
            local g = snap.ground or {}
            echo(string.format("PASS loaded theatres=%d land=%d seas=%d ponds=%d regions=%d boundaries=%d chokes=%d summits=%d",
                snap.theatres, snap.land or 0, snap.seas, snap.ponds, snap.regions, snap.boundaries, snap.chokes, snap.summits or 0))
            echo(string.format("ground deep=%d water=%d shallow=%d flat=%d rough=%d steep=%d cliff=%d harm=%d",
                g[0] or 0, g[1] or 0, g[2] or 0, g[3] or 0, g[4] or 0, g[5] or 0, g[6] or 0, g[7] or 0))
            check(snap.regions >= 1, "regions found")
            check(snap.boundaries >= 1, "boundaries classified")
            check((g[3] or 0) + (g[4] or 0) + (g[5] or 0) + (g[6] or 0) > 0, "ground classes present")
            checkSummits(snap)
            planShots(ui, snap)
            stage = 3; shotIndex = 1; shotState = 0; shotFrame = f
        elseif Spring.DiffTimers(Spring.GetTimer(), loadTimer) > LOAD_SECONDS then
            check(false, "loaded (" .. tostring(snap and snap.status or "no snapshot") .. ")")
            stage = 4
        end
    elseif stage == 3 then
        local s = shots[shotIndex]
        if not s then
            echo("PASS screenshots " .. taken); stage = 4
            return
        end
        if shotState == 0 and f >= shotFrame then
            if s.before then s.before() end
            cameraReset()
            if not cameraStep(s.x, s.z, s.height) then shotState = 2; return end
            shotState = 1; shotFrame = f + SHOT_GAP   -- 12 frames between the camera change and the capture
        elseif shotState == 2 then
            -- one camera attempt per frame until one is accepted or all are tried
            if cameraStep(s.x, s.z, s.height) then shotState = 1; shotFrame = f + SHOT_GAP end
        elseif shotState == 1 and f >= shotFrame then
            echo("camera for " .. s.label .. ": " .. tostring(cam.used))
            Spring.Echo("[Playtest] screenshot field " .. s.label)
            Spring.SendCommands("screenshot png")
            taken = taken + 1
            if s.after then s.after() end
            shotIndex = shotIndex + 1; shotState = 0; shotFrame = f + SHOT_GAP
        end
    end
end
