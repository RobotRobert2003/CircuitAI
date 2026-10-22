function widget:GetInfo() return {name="Construction recovery observer",layer=115,enabled=true} end
local products={}
function widget:UnitCreated(id,def,team,builder)
    local yard=builder and UnitDefs[Spring.GetUnitDefID(builder) or -1]
    if yard and (yard.name=="armsy" or yard.name=="corsy" or yard.name=="legsy"
        or yard.name=="armasy" or yard.name=="corasy" or yard.name=="legadvshipyard") then
        local x,_,z=Spring.GetUnitPosition(builder)
        products[id]={yard=builder,team=team,x=x,z=z,facing=Spring.GetUnitBuildFacing(builder),
            half=math.max(yard.xsize or 1,yard.zsize or 1)*4,created=Spring.GetGameFrame()}
    end
end
function widget:UnitDestroyed(id) products[id]=nil end
local function sample(id,team,event)
    local d=UnitDefs[Spring.GetUnitDefID(id) or -1]
    if not d then return end
    local x,_,z=Spring.GetUnitPosition(id)
    local _,_,_,_,progress=Spring.GetUnitHealth(id)
    local cmd=Spring.GetUnitCurrentCommand(id) or -1
    Spring.Echo(string.format("[ConstructionWatch] frame=%d event=%s team=%d id=%d def=%s x=%.0f z=%.0f progress=%.3f facing=%s command=%d building=%s",
        Spring.GetGameFrame(),event,team,id,d.name,x or 0,z or 0,progress or 0,tostring(Spring.GetUnitBuildFacing(id) or -1),cmd,tostring(Spring.GetUnitIsBuilding(id) or -1)))
end
function widget:UnitFinished(id,def,team)
    local d=UnitDefs[def]
    if d and (d.isFactory or d.isBuilding or (d.buildSpeed or 0)>0 or (d.energyMake or 0)>0) then sample(id,team,"finished") end
end
function widget:GameFrame(frame)
    if frame%30==0 then
        for id,p in pairs(products) do
            local x,_,z=Spring.GetUnitPosition(id)
            local _,_,_,_,progress=Spring.GetUnitHealth(id)
            if x and progress and progress>=1 then
                local forward=p.facing==1 and x-p.x or p.facing==2 and p.z-z or p.facing==3 and p.x-x or z-p.z
                -- A completed ship inside the yard is not proof of an exit.
                -- Require its centre beyond the mouth by its collision radius.
                local radius=Spring.GetUnitRadius(id) or 16
                if forward>p.half+radius then
                    Spring.Echo(string.format("[ConstructionWatch] event=yard-exit frame=%d team=%d id=%d def=%s yard=%d facing=%d forward=%.0f seconds=%.1f",
                        frame,p.team,id,UnitDefs[Spring.GetUnitDefID(id)].name,p.yard,p.facing,forward,(frame-p.created)/30))
                    products[id]=nil
                elseif frame-p.created>5400 then
                    Spring.Echo(string.format("[ConstructionWatch] event=exit-unverified frame=%d team=%d id=%d yard=%d",frame,p.team,id,p.yard))
                    products[id]=nil
                end
            end
        end
    end
    if frame%900~=0 then return end
    for _,team in ipairs(Spring.GetTeamList()) do
        for _,id in ipairs(Spring.GetTeamUnits(team)) do
            local d=UnitDefs[Spring.GetUnitDefID(id) or -1]
            if d and (d.buildSpeed or 0)>0 then sample(id,team,"sample") end
        end
    end
end
