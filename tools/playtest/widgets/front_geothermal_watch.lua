-- Engine completion events only: no gameplay commands or AI information feed.
function widget:GetInfo() return {name="FRONT geothermal evidence",layer=10,enabled=true} end
function widget:GameFrame(frame)
    if frame%150==0 then
        for _,id in ipairs(Spring.GetAllUnits()) do
            local def=UnitDefs[Spring.GetUnitDefID(id)]
            if def.customParams and def.customParams.iscommander then
                local x,_,z=Spring.GetUnitPosition(id)
                local hp=Spring.GetUnitHealth(id)
                Spring.Echo("[CommanderFrontEvidence] id="..id.." team="..Spring.GetUnitTeam(id)
                    .." x="..math.floor(x).." z="..math.floor(z).." hp="..math.floor(hp)
                    .." building="..tostring(Spring.GetUnitIsBuilding(id) or -1))
            end
        end
    end
    if frame~=30 then return end
    for _,id in ipairs(Spring.GetAllFeatures()) do
        local definition=FeatureDefs[Spring.GetFeatureDefID(id)]
        if definition and definition.geoThermal then
            local x,_,z=Spring.GetFeaturePosition(id)
            Spring.Echo("[FrontGeoEvidence] vent="..math.floor(x)..","..math.floor(z))
        end
    end
end
function widget:UnitDestroyed(id,definition,team)
    local name=UnitDefs[definition].name
    if name:match("geo$") then Spring.Echo("[FrontGeoEvidence] destroyed="..name.." team="..team.." frame="..Spring.GetGameFrame()) end
end
function widget:UnitCreated(id,definition,team,builder)
    local name=UnitDefs[definition].name
    if name:match("geo$") then
        local x,_,z=Spring.GetUnitPosition(id)
        Spring.Echo("[FrontGeoEvidence] created="..name.." team="..team.." frame="..Spring.GetGameFrame()
            .." builder="..tostring(builder).." site="..math.floor(x)..","..math.floor(z))
    end
end
function widget:UnitFinished(id,definition,team)
    local name=UnitDefs[definition].name
    if name:match("geo$") then
        Spring.Echo("[FrontGeoEvidence] finished="..name.." team="..team.." frame="..Spring.GetGameFrame())
    end
    if name:match("nanotc$") then
        Spring.Echo("[CommanderFrontEvidence] nano_finished="..name.." team="..team.." frame="..Spring.GetGameFrame())
    end
end
