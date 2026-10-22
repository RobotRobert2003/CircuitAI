function widget:GetInfo() return {name="Allied resurrection fixture",layer=130,enabled=true} end
local config=VFS.Include("LuaUI/Config/allied_resurrection.lua")
local ally,worker,vessel,feature,protectedFrames=nil,nil,nil,nil,0
local function log(s) Spring.Echo("[AlliedResurrectionTest] "..s) end
local function give(name,team,x,z)
    Spring.SendCommands("give 1 "..name.." "..team.." @"..x..","..Spring.GetGroundHeight(x,z)..","..z)
end
function widget:UnitFinished(id,definition,team)
    local name=UnitDefs[definition].name
    if name=="armepoch" then vessel=id end
    if name=="armrecl" then if team==0 then worker=id else ally=id end end
end
function widget:GameFrame(frame)
    if frame==150 then Spring.SendCommands({"cheat 1","globallos"}) end
    if frame==300 then give("armepoch",0,6150,10900);give("armrecl",config.human and 2 or 1,6100,10700) end
    if frame==450 and vessel then Spring.SendLuaRulesMsg("$dev$:wreckunits "..vessel) end
    if frame==480 then
        for _,id in ipairs(Spring.GetFeaturesInCylinder(6150,10900,100)) do
            if Spring.GetFeatureResurrect(id)=="armepoch" then feature=id end
        end
        if not feature then log("FAIL wreck absent");return end
        if config.human then Spring.GiveOrderToUnit(ally,CMD.RESURRECT,{feature+Game.maxUnits},{}) end
    end
    if frame==900 then give("armrecl",0,6200,10700) end
    if frame>960 and frame<1770 and frame%30==0 and worker and feature and ally then
        local command,_,_,target=Spring.GetUnitCurrentCommand(worker)
        local alliedCommand=Spring.GetUnitCurrentCommand(ally)
        if command==CMD.RECLAIM then log("FAIL [INVARIANT] INV-183 reclaimed while ally resurrecting") end
        if command==CMD.RESURRECT and alliedCommand==CMD.RESURRECT and Spring.ValidFeatureID(feature) then
            protectedFrames=protectedFrames+30
            if protectedFrames==150 then log("PASS protected") end
        else protectedFrames=0 end
    end
    if frame==1800 and ally then
        if config.human then Spring.GiveOrderToUnit(ally,CMD.STOP,{}, {})
        else Spring.SendLuaRulesMsg("$dev$:destroyunits "..ally) end
    end
    if frame>1860 and frame<3000 and frame%30==0 and worker then
        local command=Spring.GetUnitCurrentCommand(worker)
        if command==CMD.RECLAIM then log("PASS released");worker=nil end
    end
end
