-- Field-landmarks playtest: the Landmarks view in the BARb team link. Drives the
-- panel through its own button paths (WG.barblink.ButtonRect + MousePress /
-- MouseRelease for "marksShow", then MarksShow, MarksSnapshot, MarksPhase,
-- MarksSelect, MarksLegend), waits in wall-clock seconds for the landmarks file
-- the AI writes once right after map.txt, checks it, logs one opening card per
-- position, then takes a series of screenshots: the full map in each phase
-- window, one card per distinct position label, and the legend.
--
-- The terrain map is loaded too (SetField) so the view can check the landmarks
-- file's fingerprint against map.txt; it is hidden again before the series, so
-- the shots show the landmarks over their own dim sheet.
--
-- Pacing: a fast-forwarded game runs many simulation frames per rendered frame
-- (the first run showed fps 0-8), and "screenshot" captures the next RENDERED
-- frame. Paced by game frames, the camera had already moved to the next target
-- when the capture happened, so every card shot showed the previous position and
-- the last shots were lost. Everything here therefore runs from widget:Update and
-- waits for rendered frames (counted in DrawScreen): the window is drawn before its
-- button is pressed, the layers are compiled and the camera has rendered before the
-- capture, and the capture has rendered before the camera moves again.
--
-- Stage: --extra-widget tools/widgets/gui_barb_team_link.lua
--        --extra-widget tools/playtest/widgets/marks_watch.lua
-- Check: tools/playtest/checks/shared/terrain/field_landmarks.json
-- Check lines start "[MarksCheck]", card lines "[MarksCard]"; each screenshot is
-- announced with a "[Playtest] screenshot marks <label>" line just before the capture.
-- Pass --shots "" so the runner's camera does not fight this one.

function widget:GetInfo()
    return {name = "BARb landmarks check", desc = "tools/playtest: field-landmarks view, opening cards and screenshots",
        author = "s3k-CircuitAI", date = "2026-10-18", layer = 110, enabled = true}
end

local LOAD_SECONDS = 60
local FIELD_SECONDS = 30     -- the terrain file is only needed for the fingerprint check
local BUTTON_SECONDS = 15    -- wall time to wait for the window to lay out the Landmarks row
local START_FRAME = 150
local DRAWS_BEFORE = 4       -- rendered frames between a camera/view change and the capture
local DRAWS_AFTER = 4        -- rendered frames after the capture before the next change
local SETTLE_SECONDS = 0.25  -- and at least this much wall time each way
local COMPILE_SECONDS = 5    -- wait at most this long for the view's layers to compile

local stage = 0              -- 0 wait, 1 laying out the window, 2 loading, 3 shooting, 4 done
local stageTimer = nil
local loadTimer = nil
local draws = 0              -- rendered frames seen (DrawScreen calls)
local shots = {}             -- queued shots: {label=, x=, z=, height=, before=fn, after=fn}
local shotIndex = 0
local shotState = 0          -- 0 start shot, 2 camera attempts, 1 settle then capture, 3 captured
local shotDraw, shotTimer = 0, nil
local taken = 0

local function echo(s) Spring.Echo("[MarksCheck] " .. s) end
local function check(ok, label) echo((ok and "PASS " or "FAIL ") .. label) end
local function safe(s) return (string.gsub(tostring(s or "-"), "[^%w%-%.]", "_")) end
local function since(t) return t and Spring.DiffTimers(Spring.GetTimer(), t) or 1e9 end

local function click(ui, id)
    local r = ui.ButtonRect(id)
    if not r then return false end
    local x, y = (r[1] + r[3]) / 2, (r[2] + r[4]) / 2
    ui.MousePress(x, y, 1); ui.MouseRelease(x, y, 1)
    return true
end

-- The camera: the same free-camera sequence as field_watch.lua (fps, free,
-- viewfree-then-free, "ov"; one attempt per rendered frame, each verified by
-- readback within 20% of the requested height; later shots reuse the free state).
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
local function cameraStep(x, z, H)
    if cam.done then return true end
    cam.attempt = cam.attempt + 1
    local a = cam.attempt
    if cam.switched then
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
        return false
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

-- The height at which a straight-down camera shows the whole map: the free camera's
-- vertical field of view is 45 degrees (measured on the first run: 13516 elmos high
-- showed 11130 elmos of a 12288 map), so the height must cover the map's depth and,
-- through the aspect ratio, its width; 8% margin.
local function fullMapHeight()
    local vw, vh = gl.GetViewSizes()
    local aspect = (vw and vh and vh > 0) and (vw / vh) or (16 / 9)
    local t = math.tan(math.rad(45) / 2)
    local need = math.max(Game.mapSizeZ, Game.mapSizeX / aspect)
    return math.floor(need / (2 * t) * 1.08)
end

local function queue(label, x, z, height, before, after)
    shots[#shots + 1] = {label = label, x = x, z = z, height = height, before = before, after = after}
end

-- The file checks: at least one position, and an opening for every position.
local function checkFile(snap)
    if (snap.positions or 0) < 1 then check(false, "loaded: no positions in the landmarks file"); return false end
    local missing = {}
    for _, p in ipairs(snap.items.positions) do
        if not p.opening then missing[#missing + 1] = p.name end
    end
    if #missing > 0 then check(false, "loaded: no opening for " .. table.concat(missing, ",")); return false end
    echo(string.format("PASS loaded positions=%d marks=%d territory=%s", snap.positions, snap.marks, tostring(snap.territory)))
    local kinds = {}
    for k, n in pairs(snap.kinds or {}) do kinds[#kinds + 1] = k .. "=" .. n end
    table.sort(kinds)
    echo("kinds " .. table.concat(kinds, " "))
    return true
end
local function logCards(snap)
    for _, p in ipairs(snap.items.positions) do
        Spring.Echo(string.format("[MarksCard] %s %s %s %s %s", p.name, p.label ~= "" and p.label or "-", p.class or "-",
            p.factory or "-", p.energy ~= "" and p.energy or "-"))
    end
end
-- The card must be on screen and clear of the minimap (the first run drew it under the minimap).
local function checkPanel(ui, what)
    local s = ui.MarksSnapshot()
    local r = s and s.panels and s.panels[1]
    if not r then check(false, what .. " panel drawn"); return end
    local vw, vh = gl.GetViewSizes()
    local onScreen = r[1] >= 0 and r[2] >= 0 and r[3] <= vw and r[4] <= vh
    local clear = true
    local ok, px, py, sx, sy, minimized = pcall(Spring.GetMiniMapGeometry)
    if ok and type(px) == "number" and type(sy) == "number" and sy > 0 and not minimized then
        -- GL rectangles: the minimap spans px..px+sx, py..py+sy
        clear = r[3] <= px or r[1] >= px + sx or r[4] <= py or r[2] >= py + sy
    end
    check(onScreen and clear, string.format("%s panel on screen, clear of the minimap (%d,%d %d,%d)", what,
        math.floor(r[1]), math.floor(r[2]), math.floor(r[3]), math.floor(r[4])))
end

local function planShots(ui, snap)
    local cx, cz = Game.mapSizeX / 2, Game.mapSizeZ / 2
    local full = fullMapHeight()
    echo("full map camera height " .. full)
    -- every phase window over the full map, then back to all
    for _, ph in ipairs({"0-5", "5-15", "15-25", "25+", "all"}) do
        local key = ph
        queue("phase-" .. safe(key), cx, cz, full, function() ui.MarksPhase(key) end, nil)
    end
    -- one position per distinct label, its card on screen, the camera over that position
    local seen = {}
    for _, p in ipairs(snap.items.positions) do
        local label = (p.label ~= "" and p.label) or "-"
        if not seen[label] then
            seen[label] = true
            local name, px, pz = p.name, p.x, p.z
            queue("card-" .. safe(label) .. "-" .. safe(name), px, pz, 4500, function()
                if not ui.MarksSelect(name) then echo("WARN MarksSelect " .. name .. " refused") end
            end, function()
                local s = ui.MarksSnapshot()
                local c = s and s.card
                check(c ~= nil and c.name == name and s.selected == name, "card shown for " .. name)
                echo(string.format("camera target for %s: %d,%d", name, px, pz))
                if c then
                    Spring.Echo(string.format("[MarksCard] selected %s %s %s %s next=%s chosen=%s", tostring(c.name), tostring(c.label),
                        tostring(c.class), tostring(c.factory), tostring(c.next), tostring(c.chosen and c.chosen.verdict)))
                end
                checkPanel(ui, "card")
            end)
        end
    end
    -- the legend beside the card, over the map centre
    queue("legend", cx, cz, full, function() ui.MarksLegend(true) end, function()
        local s = ui.MarksSnapshot()
        check(s and s.panels and #s.panels >= 2, "legend panel drawn")
        ui.MarksLegend(false)
    end)
end

function widget:DrawScreen() draws = draws + 1 end

local function shoot(ui)
    local s = shots[shotIndex]
    if not s then
        echo("PASS series screenshots=" .. taken); stage = 4
        return
    end
    if shotState == 0 then
        if s.before then s.before() end
        cameraReset()
        shotState = cameraStep(s.x, s.z, s.height) and 1 or 2
        shotDraw, shotTimer = draws, Spring.GetTimer()
    elseif shotState == 2 then
        -- one camera attempt per rendered frame until one is accepted or all are tried
        if draws > shotDraw then
            shotDraw = draws
            if cameraStep(s.x, s.z, s.height) then shotState = 1; shotDraw, shotTimer = draws, Spring.GetTimer() end
        end
    elseif shotState == 1 then
        -- the view's layers recompiled (a phase or selection change) and the new camera rendered
        local snap = ui.MarksSnapshot()
        local compiled = snap and snap.compiled
        if not compiled and since(shotTimer) > COMPILE_SECONDS then echo("WARN " .. s.label .. ": layers still compiling"); compiled = true end
        if compiled and draws - shotDraw >= DRAWS_BEFORE and since(shotTimer) >= SETTLE_SECONDS then
            echo("camera for " .. s.label .. ": " .. tostring(cam.used))
            Spring.Echo("[Playtest] screenshot marks " .. s.label)
            Spring.SendCommands("screenshot png")
            taken = taken + 1
            shotState, shotDraw, shotTimer = 3, draws, Spring.GetTimer()
        end
    elseif shotState == 3 then
        -- the capture is taken on a rendered frame: keep the view until it has been
        if draws - shotDraw >= DRAWS_AFTER and since(shotTimer) >= SETTLE_SECONDS then
            if s.after then s.after() end
            shotIndex = shotIndex + 1; shotState = 0
        end
    end
end

function widget:Update()
    local ui = WG.barblink
    if not ui then return end
    if stage == 0 then
        if Spring.GetGameFrame() >= START_FRAME then
            ui.SetOpen(true); stage = 1; stageTimer = Spring.GetTimer(); shotDraw = draws
        end
    elseif stage == 1 then
        -- the Landmarks row exists only once the open window has been drawn; another widget
        -- may close the window for its own screenshots, so keep it open until the press
        if ui.IsOpen and not ui.IsOpen() then ui.SetOpen(true); shotDraw = draws end
        local laidOut = draws - shotDraw >= 2 and ui.ButtonRect("marksShow") ~= nil
        local snap
        if laidOut then
            click(ui, "marksShow")
            snap = ui.MarksSnapshot()
            if snap and snap.on then echo("PASS marksShow button showed the view")
            else ui.MarksShow(true); echo("WARN marksShow press did not show the view, used MarksShow") end
        elseif since(stageTimer) > BUTTON_SECONDS then
            echo("WARN marksShow button not laid out after " .. BUTTON_SECONDS .. " s, used MarksShow")
            ui.MarksShow(true); laidOut = true
        end
        if laidOut then
            if ui.SetField then ui.SetField(true) end
            loadTimer = Spring.GetTimer(); stage = 2
        end
    elseif stage == 2 then
        local snap = ui.MarksSnapshot()
        local fsnap = ui.FieldSnapshot and ui.FieldSnapshot()
        local fieldReady = (fsnap and fsnap.loaded) or since(loadTimer) > FIELD_SECONDS
        if snap and string.find(snap.status or "", "Landmarks file skipped", 1, true) then
            check(false, "loaded (" .. tostring(snap.status) .. ")")
            stage = 4
        elseif snap and snap.loaded and snap.compiled and fieldReady then
            if not (fsnap and fsnap.loaded) then echo("WARN terrain file not loaded: fingerprint not compared") end
            if ui.SetField then ui.SetField(false) end
            if checkFile(snap) then
                logCards(snap)
                planShots(ui, snap)
                stage = 3; shotIndex = 1; shotState = 0
            else
                stage = 4
            end
        elseif since(loadTimer) > LOAD_SECONDS then
            check(false, "loaded (" .. tostring(snap and snap.status or "no snapshot") .. ")")
            stage = 4
        end
    elseif stage == 3 then
        shoot(ui)
    end
end
