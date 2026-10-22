function widget:GetInfo()
    return {name="Factory retirement regression", layer=100, enabled=true}
end
local labs, retired, created = {}, {}, {}
local names = {armalab=true, coralab=true, legalab=true}
local failed = false
local function log(text) Spring.Echo("[RetirementTest] " .. text) end
function widget:UnitFinished(id, definition, team)
    if team == 0 and names[UnitDefs[definition].name] then labs[id] = UnitDefs[definition].name end
end
function widget:UnitCreated(id, definition, team, builder)
    if team ~= 0 or not builder or not labs[builder] then return end
    created[builder] = (created[builder] or 0) + 1
    -- Allow command delivery, then require no new frame from the retired lab.
    if retired[builder] and Spring.GetGameFrame() > retired[builder] + 90 then
        failed = true; log("FAIL post_retirement_frame factory=" .. builder .. " unit=" .. id)
    end
end
function widget:GameFrame(frame)
    if frame == 150 then Spring.SendCommands("cheat 1") end
    if frame == 300 then
        for index, name in ipairs({"armalab", "coralab", "legalab"}) do
            local x, z = 500 + index * 400, 10100
            Spring.SendCommands("give " .. name .. " 0 @" .. x .. "," .. Spring.GetGroundHeight(x,z) .. "," .. z)
        end
    end
    if frame == 1800 then
        local count = 0
        for id, name in pairs(labs) do
            count = count + 1
            if not created[id] then failed = true; log("FAIL no_pre_retirement_production " .. name) end
            retired[id] = frame
            Spring.SendSkirmishAIMessage(0, "retirement-probe|" .. id)
        end
        if count ~= 3 then failed = true; log("FAIL missing_factory count=" .. count) end
    end
    if frame == 3600 then
        for id, name in pairs(labs) do
            for _, command in ipairs(Spring.GetFactoryCommands(id, -1) or {}) do
                if command.id < 0 then failed = true; log("FAIL build_queue_remaining " .. name) end
            end
        end
        if not failed then log("PASS all_factions_queue_cleared_and_no_new_frames") end
    end
end
