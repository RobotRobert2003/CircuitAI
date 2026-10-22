-- Read-only observer: no resource gifts, reveal, orders or stockpile cheats.
function widget:GetInfo()
    return {name="Nuke rush benchmark observer",desc="First silo, stockpile and real projectile timing",layer=115,enabled=true}
end
local silos, seen = {}, {}
local function echo(s) Spring.Echo("[NukeRush] "..s) end
local function isSilo(d) return d and (d.name=="armsilo" or d.name=="corsilo" or d.name=="legsilo") end
function widget:UnitCreated(id,def,team)
    if isSilo(UnitDefs[def]) then silos[id]={team=team,name=UnitDefs[def].name}; echo("silo-frame team="..team.." id="..id) end
end
function widget:UnitFinished(id,def,team)
    if isSilo(UnitDefs[def]) then echo("silo-finished team="..team.." id="..id.." frame="..Spring.GetGameFrame()) end
end
function widget:UnitDestroyed(id,def,team)
    local d=UnitDefs[def]
    if d and (d.name=="armmstor" or d.name=="cormstor" or d.name=="legmstor") then
        echo("storage-removed team="..team.." id="..id.." frame="..Spring.GetGameFrame())
    end
end
function widget:GameFrame(frame)
    if frame%30~=0 then return end
    for id,s in pairs(silos) do
        if Spring.ValidUnitID(id) and not Spring.GetUnitIsDead(id) then
            local stock,queued,progress=Spring.GetUnitStockpile(id)
            if stock and (stock~=s.stock or frame%300==0) then
                echo(string.format("stock team=%d id=%d count=%d queued=%d progress=%.4f",s.team,id,stock,queued or 0,progress or 0))
            end
            s.stock=stock
        end
    end
    -- Only scan after a silo exists; one read-only sample per simulated second.
    if next(silos) then
        for _,id in ipairs(Spring.GetProjectilesInRectangle(0,0,Game.mapSizeX,Game.mapSizeZ,false,false) or {}) do
            local owner=Spring.GetProjectileOwnerID(id)
            local s=silos[owner]
            local wd=WeaponDefs[Spring.GetProjectileDefID(id) or -1]
            if s and wd and wd.customParams and wd.customParams.nuclear and not seen[id] then
                seen[id]=true
                echo("launch team="..s.team.." silo="..owner.." projectile="..id.." frame="..frame)
            end
        end
    end
    if frame%900==0 then
        local m,ms,_,mi,mp=Spring.GetTeamResources(0,"metal")
        local e,es,_,ei,ep=Spring.GetTeamResources(0,"energy")
        echo(string.format("economy frame=%d metal=%.1f/%.1f income=%.1f expense=%.1f energy=%.1f/%.1f income=%.1f expense=%.1f",frame,m or 0,ms or 0,mi or 0,mp or 0,e or 0,es or 0,ei or 0,ep or 0))
        local _,_,_,wind = Spring.GetWind()
        echo(string.format("wind frame=%d strength=%.2f",frame,wind or 0))
        -- Observer-only command snapshots separate travel, idle build power,
        -- reclaim and resource starvation without changing any AI decisions.
        for _,id in ipairs(Spring.GetTeamUnits(0) or {}) do
            local ud=UnitDefs[Spring.GetUnitDefID(id)]
            local _,_,_,_,progress=Spring.GetUnitHealth(id)
            if ud and (ud.buildSpeed or 0)>0 then
                local commands=Spring.GetUnitCommands(id,1) or {}
                local c=commands[1]
                local x,_,z=Spring.GetUnitPosition(id)
                echo(string.format("worker id=%d def=%s progress=%.4f x=%.0f z=%.0f cmd=%d target=%s priority=%d",id,ud.name,progress or 0,x or 0,z or 0,c and c.id or 0,c and table.concat(c.params,",") or "",Spring.GetUnitRulesParam(id,"builderPriority") or -1))
            elseif ud and (ud.metalCost or 0)>=400 and progress and progress<1 then
                echo(string.format("project id=%d def=%s progress=%.4f",id,ud.name,progress))
            end
        end
    end
end
