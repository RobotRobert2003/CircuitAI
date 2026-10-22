function widget:GetInfo()
    return {name="Unit terrain route verification", layer=115, enabled=true}
end
local samples = {[300]=0,[600]=1,[1200]=2,[2130]=3,[2430]=4,[3030]=5,[3960]=6,[4260]=7,[5790]=8,[6090]=9}
local obstacle
function widget:UnitCreated(id, definition, team)
    if team==0 and UnitDefs[definition].name=="armestor" then obstacle=id end
end
function widget:GameFrame(frame)
    if frame==90 then Spring.SendCommands("cheat 1") end
    if frame==900 then
        Spring.SendCommands("give armestor 0 @2400,"..Spring.GetGroundHeight(2400,10400)..",10400")
        Spring.Echo("[UnitRouteTest] obstacle added")
    end
    if frame==2700 and obstacle then
        Spring.SelectUnitArray({obstacle},false)
        Spring.SendCommands("destroy")
        Spring.SelectUnitArray({},false)
        Spring.Echo("[UnitRouteTest] obstacle destroyed")
    end
    if samples[frame] then Spring.SendSkirmishAIMessage(0,"unit-route-probe|"..samples[frame]) end
end
