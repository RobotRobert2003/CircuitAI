function widget:GetInfo() return {name="SEA conversion supplied fixture",layer=126,enabled=true,handler=true} end
-- Isolate economy policy from combat variance. Supply a mature tidal field
-- and builders once; no free recurring resources and no build orders.
local injected=false
function widget:GameFrame(f)
    if f==150 then Spring.SendCommands({"cheat 1","globallos"}) end
    if f~=3600 or injected then return end
    injected=true
    local side="arm"
    for _,id in ipairs(Spring.GetTeamUnits(0)) do
        local d=UnitDefs[Spring.GetUnitDefID(id)]
        if d and d.name:sub(1,3)=="cor" then side="cor";break end
        if d and d.name:sub(1,3)=="leg" then side="leg";break end
    end
    local units=side=="leg" and {"legtide","legnavyconship","leganavyconsub","leguwmstore","leguwestore"}
        or {side.."tide",side.."cs",side.."acsub",side.."uwms",side.."uwes"}
    for _,name in ipairs(units) do
        if not UnitDefNames[name] then Spring.Echo("[SeaConversionFixture] FAIL missing unit "..name); return end
    end
    Spring.SendCommands({"give 120 "..units[1].." 0 @600,0,4700",
        "give 4 "..units[2].." 0 @1450,0,4250","give 2 "..units[3].." 0 @1550,0,4250",
        "give 1 "..units[4].." 0 @700,0,5100","give 1 "..units[5].." 0 @850,0,5100"})
    Spring.Echo("[SeaConversionFixture] supplied 120 tidals and six builders; zero supplied converters or fusions")
end
function widget:UnitFinished(id,def,team)
    if team~=0 or not injected then return end
    local name=UnitDefs[def].name
    if name=="armuwfus" or name=="coruwfus" or name=="leganavalfusion" then
        Spring.Echo("[SeaConversionFixture] completed fusion "..name)
    elseif name=="armuwmmm" or name=="coruwmmm" or name=="leganavaleconv" then
        Spring.Echo("[SeaConversionFixture] completed advanced converter "..name)
    end
end
