-- Read-only natural-economy observer. No gifts, reveal, build or fire orders.
function widget:GetInfo()
    return {name="Antinuke timing observer",desc="Silo, interception and nano reach timing",layer=115,enabled=true}
end
local watched, lastStock, missiles, firstIncome = {}, {}, {}, {}
local function echo(s) Spring.Echo("[AntiNukeTest] "..s) end
local function kind(d)
    if not d then return nil end
    if d.name=="armsilo" or d.name=="corsilo" or d.name=="legsilo" then return "silo" end
    if d.name=="armamd" or d.name=="corfmd" or d.name=="legabm" then return "anti" end
end
local function report(event,id,def,team)
    local k=kind(UnitDefs[def]); if not k then return end
    watched[id]={kind=k,team=team}
    local x,_,z=Spring.GetUnitPosition(id)
    local nearest,reach=1e9,0
    for _,n in ipairs(Spring.GetTeamUnits(team) or {}) do
        local nd=UnitDefs[Spring.GetUnitDefID(n)]
        if nd and (nd.name=="armnanotc" or nd.name=="cornanotc" or nd.name=="legnanotc") then
            local nx,_,nz=Spring.GetUnitPosition(n)
            local _,_,_,_,built=Spring.GetUnitHealth(n)
            if built and built>=1 and nx then
                local distance=math.sqrt((x-nx)^2+(z-nz)^2)
                if distance<nearest then nearest=distance; reach=nd.buildDistance or 0 end
            end
        end
    end
    echo(string.format("%s kind=%s team=%d id=%d frame=%d at=%.0f,%.0f nearestNano=%.1f",event,k,team,id,Spring.GetGameFrame(),x or -1,z or -1,nearest))
    if k=="anti" and team==0 then
        if event=="created" and Spring.GetGameFrame()<18000 then echo("FAIL premature antinuke") end
        if event=="finished" then
            echo((nearest<=reach and "PASS" or "FAIL").." nano range distance="..nearest.." reach="..reach)
        end
    end
end
function widget:UnitCreated(id,def,team) report("created",id,def,team) end
function widget:UnitFinished(id,def,team) report("finished",id,def,team) end
function widget:UnitDestroyed(id,def,team)
    if watched[id] then echo("destroyed kind="..watched[id].kind.." team="..team.." id="..id.." frame="..Spring.GetGameFrame()); watched[id]=nil end
end
function widget:GameFrame(frame)
    if frame%30~=0 then return end
    for team=0,1 do
        local m,ms,_,mi,mp=Spring.GetTeamResources(team,"metal")
        local e,es,_,ei,ep=Spring.GetTeamResources(team,"energy")
        if mi and ei and mi>=100 and ei>=2000 and not firstIncome[team] then
            firstIncome[team]=frame; echo("income-ready team="..team.." frame="..frame.." metal="..mi.." energy="..ei)
        end
        if frame%900==0 then
            echo(string.format("economy team=%d frame=%d metal=%.1f/%.1f income=%.1f expense=%.1f energy=%.1f/%.1f income=%.1f expense=%.1f",team,frame,m or 0,ms or 0,mi or 0,mp or 0,e or 0,es or 0,ei or 0,ep or 0))
        end
    end
    for id,s in pairs(watched) do
        local stock,queued,progress=Spring.GetUnitStockpile(id)
        if stock and (stock~=lastStock[id] or frame%300==0) then
            echo(string.format("stock kind=%s team=%d id=%d frame=%d count=%d queued=%d progress=%.4f",s.kind,s.team,id,frame,stock,queued or 0,progress or 0))
        end
        lastStock[id]=stock
    end
    for _,id in ipairs(Spring.GetProjectilesInRectangle(0,0,Game.mapSizeX,Game.mapSizeZ,false,false) or {}) do
        local owner=Spring.GetProjectileOwnerID(id)
        local s=watched[owner]
        if s and not missiles[id] then
            missiles[id]=true
            echo("projectile kind="..s.kind.." team="..s.team.." id="..id.." owner="..owner.." frame="..frame)
        end
    end
end
