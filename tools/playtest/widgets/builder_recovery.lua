function widget:GetInfo() return {name="Constructor recovery fixture",layer=100,enabled=true} end
local cfg=VFS.Include("LuaUI/Config/builder_recovery.lua")
local roles={"FRONT","AIR","SUPPORT","SEA","TACTICAL","TECH"}
local received={}
local function log(s) Spring.Echo("[RecoveryFixture] frame="..Spring.GetGameFrame().." "..s) end
local function give(name,team,x,z)
    Spring.SendCommands("give "..name.." "..team.." @"..x..","..Spring.GetGroundHeight(x,z)..","..z)
end
local function constructors(team)
    local ids={}
    for _,id in ipairs(Spring.GetTeamUnits(team) or {}) do
        local d=UnitDefs[Spring.GetUnitDefID(id)]
        if d and (d.speed or 0)>0 and d.buildOptions and #d.buildOptions>0 and not (d.customParams or {}).iscommander then
            ids[#ids+1]=id
        end
    end
    return ids
end
function widget:GameFrame(f)
    if f==150 then
        Spring.SendCommands({"cheat 1","globallos"})
    end
    if f==300 then
        -- Every requester first owns a real constructor: no synthetic request.
        -- Team 7 keeps its constructor throughout (negative control).
        for team=0,7 do
            local p=cfg.teams[team+1]
            give(Spring.GetGroundHeight(p.x,p.z)<0 and "armcs" or "armck",team,p.x+150,p.z)
        end
        give("armafus",0,800,900);give("armmmkr",0,1020,900)
        give("armmstor",0,1200,900);give("armestor",0,1400,900)
        if cfg.ferry then give("armatlas",0,700,1100) end
        give("leglab",9,14000,1400) -- frozen enemy TECH still needs a valid base
        log("seeded constructors; commanders survive")
    end
    if f==600 then
        for team=1,6 do Spring.SendSkirmishAIMessage(team,"barb|setrole|"..team.."|"..roles[team]) end
    end
    if f==900 then
        for team=1,6 do
            local ids=constructors(team)
            for _,id in ipairs(ids) do Spring.SendLuaRulesMsg("$dev$:removeunits "..id) end
            log("lost constructors team="..team.." role="..roles[team].." count="..#ids)
        end
    end
    if f==2400 and cfg.independent then
        local p=cfg.teams[4] -- SUPPORT independently recovers before the lab exists
        give("armck",3,p.x+150,p.z)
        log("independent recovery team=3")
    end
    if f==2700 then
        give(cfg.lab,0,900,1140)
        Spring.SendCommands({"team 0","atm 5000","spectator"})
        log("delayed TECH lab supplied")
    end
    if f==2880 and cfg.destroy_lab then
        for _,id in ipairs(Spring.GetTeamUnits(0) or {}) do
            if UnitDefs[Spring.GetUnitDefID(id)].name==cfg.lab then
                Spring.SendLuaRulesMsg("$dev$:removeunits "..id)
                log("TECH lab destroyed during recruit id="..id)
            end
        end
    end
    if f==4500 and cfg.destroy_lab then
        give(cfg.lab,0,900,1500)
        log("replacement TECH lab supplied")
    end
    if f%300==0 and f>900 then
        for team=1,6 do
            local ids=constructors(team)
            if #ids>0 and not received[team] then
                received[team]=true
                local x,_,z=Spring.GetUnitPosition(ids[1])
                log("recovered team="..team.." role="..roles[team].." id="..ids[1].." x="..math.floor(x).." z="..math.floor(z))
            end
        end
    end
    if f==14400 then
        for team=1,6 do if not received[team] then log("FAIL missing team="..team) end end
        log("completed")
    end
end
function widget:UnitGiven(id,def,newTeam,oldTeam)
    if oldTeam==0 and newTeam>=1 and newTeam<=6 then
        local x,_,z=Spring.GetUnitPosition(id)
        log("given team="..newTeam.." id="..id.." def="..UnitDefs[def].name.." x="..math.floor(x).." z="..math.floor(z))
    end
end
