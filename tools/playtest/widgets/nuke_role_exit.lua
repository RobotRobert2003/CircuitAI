-- Integration fixture: natural economy; one explicit host role change after
-- completed silo tests cleanup during the first-stockpile funding window.
function widget:GetInfo()
    return {name="Nuke budget role exit fixture",desc="TECH resource-priority cleanup",layer=115,enabled=true}
end
local switchAt, sent
function widget:UnitFinished(id,def,team)
    local d=UnitDefs[def]
    if team==0 and d and (d.name=="armsilo" or d.name=="corsilo" or d.name=="legsilo") and not switchAt then
        switchAt=Spring.GetGameFrame()+15*30
    end
end
function widget:GameFrame(frame)
    if switchAt and frame>=switchAt and not sent then
        sent=true
        Spring.Echo("[NukeRoleExit] switching after completed silo at frame="..frame)
        Spring.SendSkirmishAIMessage(0,"barb|setrole|0|AIR")
    end
end
