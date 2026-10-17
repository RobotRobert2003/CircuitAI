-- D-323 playtest: the battlefield blueprint in the BARb team link. Drives the
-- panel through its own button paths (WG.barblink.ButtonRect + MousePress /
-- MouseRelease, SetField, FieldSnapshot, FieldLayer, FieldBlueprint), waits in
-- wall-clock seconds for the field file the AI writes once, then takes a series
-- of screenshots: the full map, blueprint mode, each sea, the best assault
-- landings of each side, two chokes, and the avenues alone.
--
-- Stage: --extra-widget tools/widgets/gui_barb_team_link.lua
--        --extra-widget tools/playtest/widgets/field_watch.lua
-- Check: tools/playtest/checks/shared/terrain/field_supreme.json
-- Every check line starts "[FieldCheck]"; each screenshot is announced with a
-- "[Playtest] screenshot field <label>" line just before the capture.
-- Pass --shots "" so the runner's camera does not fight this one.

function widget:GetInfo()
    return {name = "BARb field blueprint check", desc = "tools/playtest: D-323 battlefield blueprint screenshots",
        author = "s3k-CircuitAI", date = "2026-10-17", layer = 110, enabled = true}
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

-- The invasion series (modoption field_series=invasion): for each side as the
-- viewer, the map with only theatres, shores, landings and sides on (every
-- filled chevron is a landing into the enemy side, numbered by rank), each sea
-- at 6500, then the three best assault landings focused at 2400.
local function planInvasion(ui, snap)
    local cx, cz = Game.mapSizeX / 2, Game.mapSizeZ / 2
    local full = math.max(Game.mapSizeX, Game.mapSizeZ) * 1.1
    local quiet = {"regions", "fills", "crossings", "barriers", "chokes", "standoff", "key", "avenues"}
    local allies, seen = {}, {}
    for _, l in ipairs(snap.items.landings) do
        if l.side and l.side >= 0 and not seen[l.side] then seen[l.side] = true; allies[#allies + 1] = l.side end
    end
    table.sort(allies)
    local seas = {}
    for _, t in ipairs(snap.items.theatres) do if t.kind == "sea" then seas[#seas + 1] = t end end
    table.sort(seas, function(a, b) return a.id < b.id end)
    for _, viewer in ipairs(allies) do
        local tag = "invade_v" .. viewer
        queue(tag .. "_map", cx, cz, full, function()
            for _, name in ipairs(quiet) do ui.FieldLayer(name, false) end
            if ui.FieldSide then ui.FieldSide(viewer) else Spring.SendCommands("barbfield side " .. viewer) end
        end, nil, true)
        -- 5500: below the strategic detail switch, so the rank numbers are drawn
        for _, t in ipairs(seas) do queue(tag .. "_sea" .. t.id, t.x, t.z, 5500) end
        -- assault landings for this viewer: they lead into another side; best rank first
        local targets = {}
        for _, l in ipairs(snap.items.landings) do
            if (l.rank or 0) >= 1 and l.side ~= viewer then targets[#targets + 1] = l end
        end
        table.sort(targets, function(a, b) if a.rank ~= b.rank then return a.rank < b.rank end return a.id < b.id end)
        for i = 1, math.min(3, #targets) do
            local l = targets[i]
            queue(string.format("%s_rank%d", tag, l.rank), l.x, l.z, 2400,
                function() ui.FieldFocus("landing", l.id) end, function() ui.FieldFocus(nil) end)
        end
    end
    queue("invade_end", cx, cz, full, nil, function()
        for _, name in ipairs(quiet) do ui.FieldLayer(name, true) end
        if ui.FieldSide then ui.FieldSide(-1) else Spring.SendCommands("barbfield side -1") end
    end, true)
end

local function planShots(ui, snap)
    local series = (Spring.GetModOptions() or {}).field_series
    if series == "invasion" then return planInvasion(ui, snap) end
    local cx, cz = Game.mapSizeX / 2, Game.mapSizeZ / 2
    local full = math.max(Game.mapSizeX, Game.mapSizeZ) * 1.1   -- the free camera is not clamped; the map fills the frame
    queue("full", cx, cz, full, nil, nil, true)
    queue("blueprint", cx, cz, full, function() ui.FieldBlueprint(true) end, function() ui.FieldBlueprint(false) end, true)
    local seas = {}
    for _, t in ipairs(snap.items.theatres) do if t.kind == "sea" then seas[#seas + 1] = t end end
    table.sort(seas, function(a, b) return a.id < b.id end)
    for _, t in ipairs(seas) do queue("sea" .. t.id, t.x, t.z, 5000) end
    -- the two best landings into each side (lowest rank first)
    local bySide = {}
    for _, l in ipairs(snap.items.landings) do
        if (l.rank or 0) >= 1 then   -- rank 0 = a pond shore, not a way in from the water
            bySide[l.side] = bySide[l.side] or {}
            local list = bySide[l.side]; list[#list + 1] = l
        end
    end
    local sides = {}
    for side in pairs(bySide) do sides[#sides + 1] = side end
    table.sort(sides)
    for _, side in ipairs(sides) do
        local list = bySide[side]
        table.sort(list, function(a, b) if a.rank ~= b.rank then return a.rank < b.rank end return a.id < b.id end)
        for i = 1, math.min(2, #list) do
            local l = list[i]
            queue(string.format("landing%d_side%d", l.rank, side), l.x, l.z, 1800)
        end
    end
    local chokes = {}
    for _, c in ipairs(snap.items.chokes) do chokes[#chokes + 1] = c end
    table.sort(chokes, function(a, b) return a.width < b.width end)
    for i = 1, math.min(2, #chokes) do queue("choke" .. chokes[i].id, chokes[i].x, chokes[i].z, 2200) end
    -- the isthmus: the widest choke whose two regions are both land
    local widest = nil
    for _, c in ipairs(snap.items.chokes) do
        if c.land and (not widest or c.width > widest.width) then widest = c end
    end
    if widest then queue("isthmus", widest.x, widest.z, 2600) end
    queue("avenues", cx, cz, full, function()
        for _, name in ipairs({"regions", "fills", "crossings", "barriers", "shores", "standoff", "chokes", "landings", "key"}) do ui.FieldLayer(name, false) end
    end, function()
        for _, name in ipairs({"regions", "fills", "crossings", "barriers", "shores", "standoff", "chokes", "landings", "key"}) do ui.FieldLayer(name, true) end
    end, true)
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
            echo(string.format("PASS loaded theatres=%d seas=%d ponds=%d regions=%d boundaries=%d chokes=%d avenues=%d landings=%d assault=%d",
                snap.theatres, snap.seas, snap.ponds, snap.regions, snap.boundaries, snap.chokes, snap.avenues, snap.landings, snap.assault))
            check(snap.seas >= 1, "at least one sea")
            check(snap.regions >= 3, "regions found")
            check(snap.boundaries >= 1, "boundaries classified")
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
