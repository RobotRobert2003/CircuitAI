function widget:GetInfo()
    return {name="Ferry ownership regression", layer=100, enabled=true}
end
local names = {armck=true, corck=true, legck=true, armca=true, corca=true, legca=true}
local constructors = {}
function widget:UnitFinished(id, definition, team)
    if team == 0 and names[UnitDefs[definition].name] then constructors[id] = true end
end
function widget:GameFrame(frame)
    if frame == 150 then Spring.SendCommands("cheat 1") end
    if frame == 300 then
        for index, name in ipairs({"armck", "corck", "legck", "armca", "corca", "legca"}) do
            local x, z = 500 + index * 100, 10100
            Spring.SendCommands("give " .. name .. " 0 @" .. x .. "," .. Spring.GetGroundHeight(x,z) .. "," .. z)
        end
    end
    if frame == 600 then
        for id in pairs(constructors) do Spring.SendSkirmishAIMessage(0, "ferry-ownership-probe|" .. id) end
    end
end
