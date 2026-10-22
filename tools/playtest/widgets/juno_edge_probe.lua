function widget:GetInfo()
    return {name="Juno edge projectile probe",desc="D196 supplied weapon mechanics; no AI policy changes",layer=115,enabled=true}
end
local launchers,tracked,seen={},{},{}
local totals={launches=0,projectiles=0,explosions=0,outsideFlights=0,outsideImpacts=0}
local width,height=Game.mapSizeX,Game.mapSizeZ
local cases={{"north-edge",1857,1},{"south-edge",2088,height-2},{"north-inset",1857,128},{"east-edge",width-2,height/2}}
local function echo(s) Spring.Echo("[JunoEdge] "..s) end
local function inside(x,z) return x>=0 and z>=0 and x<width and z<height end
function widget:VisibleExplosion(x,y,z,def,owner)
    if not launchers[owner] or not WeaponDefs[def].name:find("juno_pulse") then return end
    totals.explosions=totals.explosions+1
    if not inside(x,z) then totals.outsideImpacts=totals.outsideImpacts+1 end
    echo(string.format("impact owner=%d case=%s x=%.3f y=%.3f z=%.3f inside=%s",owner,launchers[owner].case[1],x,y,z,tostring(inside(x,z))))
end
function widget:UnitCreated(id,def,team)
    local name=UnitDefs[def].name
    if team==2 and (name=="armjuno" or name=="corjuno" or name=="legjuno") then
        local x,_,z=Spring.GetUnitPosition(id)
        local index=math.max(1,math.min(4,math.floor((x-320)/240+.5)+1))
        launchers[id]={name=name,case=cases[index],stock=nil,issued=false}
        echo("launcher id="..id.." name="..name.." case="..cases[index][1].." x="..x.." z="..z)
    end
end
function widget:GameFrame(frame)
    if frame==300 then Spring.SendCommands({"cheat 1","globallos","godmode 3"});echo("map width="..width.." height="..height) end
    if frame==600 then
        for faction,name in ipairs({"armjuno","corjuno","legjuno"}) do
            for i=1,4 do
                local x,z=320+(i-1)*240,360+(faction-1)*400
                Spring.SendCommands("give "..name.." 2 @"..x..","..Spring.GetGroundHeight(x,z)..","..z)
            end
        end
    end
    if frame==750 then Spring.SendLuaRulesMsg("$dev$:loadmissiles") end
    for id,entry in pairs(launchers) do
        local stock=Spring.GetUnitStockpile(id)
        if frame>=900 and not entry.issued and stock and stock>0 then
            local c=entry.case
            local ok=Spring.GiveOrderToUnit(id,CMD.ATTACK,{c[2],Spring.GetGroundHeight(c[2],c[3]),c[3]},0)
            entry.issued=true
            echo("order id="..id.." case="..c[1].." accepted="..tostring(ok).." x="..c[2].." z="..c[3])
        end
        if stock and entry.stock and stock<entry.stock then
            totals.launches=totals.launches+1
            Spring.GiveOrderToUnit(id,CMD.STOP,{},0)
            echo("launch id="..id.." case="..entry.case[1])
        end
        entry.stock=stock
    end
    if frame%3==0 then
        for _,id in ipairs(Spring.GetProjectilesInRectangle(-10000,-10000,width+10000,height+10000,false,false) or {}) do
            local def=Spring.GetProjectileDefID(id)
            local name=def and WeaponDefs[def] and WeaponDefs[def].name or ""
            if name:find("juno_pulse") and not seen[id] then
                seen[id]=true
                local owner=Spring.GetProjectileOwnerID(id)
                if launchers[owner] then totals.projectiles=totals.projectiles+1 end
                local kind,target=Spring.GetProjectileTarget(id)
                tracked[id]={owner=owner,name=name,outside=false}
                echo("projectile id="..id.." owner="..tostring(owner).." targetType="..tostring(kind).." target="..(type(target)=="table" and table.concat(target,",") or tostring(target)))
            end
        end
    end
    for id,p in pairs(tracked) do
        local x,y,z=Spring.GetProjectilePosition(id)
        if x then
            p.x,p.y,p.z=x,y,z
            if not inside(x,z) and not p.outside then
                p.outside=true
                if launchers[p.owner] then totals.outsideFlights=totals.outsideFlights+1 end
                echo(string.format("outside id=%d owner=%s x=%.3f y=%.3f z=%.3f",id,tostring(p.owner),x,y,z))
            end
        else
            echo(string.format("gone id=%d owner=%s last_x=%.3f last_y=%.3f last_z=%.3f ever_outside=%s",id,tostring(p.owner),p.x or -1,p.y or -1,p.z or -1,tostring(p.outside)))
            tracked[id]=nil
        end
    end
    if frame==3600 then
        echo(string.format("summary launches=%d projectiles=%d impacts=%d outsideFlights=%d outsideImpacts=%d",totals.launches,totals.projectiles,totals.explosions,totals.outsideFlights,totals.outsideImpacts))
    end
end
