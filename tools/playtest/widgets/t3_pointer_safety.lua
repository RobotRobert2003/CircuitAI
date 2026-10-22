function widget:GetInfo()
    return {name="T3 pointer safety fixture", author="CircuitAI", layer=126, enabled=true}
end
local x,z
local ids={}
local function log(s) Spring.Echo("[T3PointerFixture] "..s) end
local function give(name,team,dx,dz)
    local px,pz=x+dx,z+dz
    Spring.SendCommands("give 1 "..name.." "..team.." @"..px..","..Spring.GetGroundHeight(px,pz)..","..pz)
end
local function message(team,action,actor,target)
    Spring.SendSkirmishAIMessage(team,"t3pointer|"..action.."|"..(actor or -1).."|"..(target or -1))
end
function widget:Initialize() log("loaded") end
function widget:UnitCreated(id,def,team)
    if not x then return end
    local ux,_,uz=Spring.GetUnitPosition(id)
    if not ux or math.abs(ux-x)>600 or math.abs(uz-z)>300 then return end
    local name=UnitDefs[def].name
    if name=="armbanth" and team==0 then ids.hull=id end
    if name=="armnanotc" then ids["nano"..team]=id end
    if name=="armmstor" and team==1 then ids.target=id end
end
function widget:GameFrame(f)
    if f==150 then Spring.SendCommands({"cheat 1","globallos"}) end
    if f==200 then Spring.SendSkirmishAIMessage(0,"barb|setrole|0|FRONT") end
    if f==300 then
        -- Supplied flat, unoccupied ground; no changes to the player's install.
        for pz=1024,Game.mapSizeZ-1024,256 do
            for px=1024,Game.mapSizeX-1024,256 do
                if not x and Spring.TestBuildOrder(UnitDefNames.armnanotc.id,px,Spring.GetGroundHeight(px,pz),pz,0)>0
                    and Spring.TestBuildOrder(UnitDefNames.armmstor.id,px+360,Spring.GetGroundHeight(px+360,pz),pz,0)>0 then x,z=px,pz end
            end
        end
        if not x then log("FAIL no supplied site");return end
        give("armbanth",0,0,0);give("armnanotc",0,-96,0)
        give("armnanotc",1,80,0);give("armmstor",1,360,0)
        give("armnanotc",2,160,0);give("armack",0,0,180)
    end
    if f==420 then
        if not(ids.hull and ids.nano0 and ids.nano1 and ids.nano2 and ids.target) then log("FAIL supplied units missing");return end
        message(1,"donate",ids.nano1,ids.target)
    end
    if f==480 then message(0,"round",ids.hull,ids.nano1) end
    if f==900 then
        message(1,"late",ids.nano1,ids.target)
        if ids.target then Spring.SendLuaRulesMsg("$dev$:removeunits "..ids.target) end
    end
    if f==1500 then
        if not ids.nano2 or Spring.GetUnitTeam(ids.nano2)==2 then log("FAIL ally blocker not transferred")
        else log("PASS ally-clear transferred blocker") end
        log("complete")
    end
end
