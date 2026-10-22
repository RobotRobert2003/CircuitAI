function widget:GetInfo()
    return {name="SEA conversion observer", desc="Read-only all-team resource and construction census", layer=115, enabled=true}
end
local function log(s) Spring.Echo("[SeaConversion] "..s) end
function widget:Initialize() log("loaded") end
function widget:GameFrame(f)
    if f%900~=0 then return end
    for _,team in ipairs(Spring.GetTeamList()) do
        if team~=Spring.GetGaiaTeamID() then
            local counts,frames={},{}
            for _,id in ipairs(Spring.GetTeamUnits(team)) do
                local d=UnitDefs[Spring.GetUnitDefID(id)]
                local _,_,_,_,progress=Spring.GetUnitHealth(id)
                if d and progress then
                    local target=progress>=1 and counts or frames
                    target[d.name]=(target[d.name] or 0)+1
                end
            end
            local list,building={},{}
            for name,n in pairs(counts) do list[#list+1]=name..":"..n end
            for name,n in pairs(frames) do building[#building+1]=name..":"..n end
            table.sort(list); table.sort(building)
            local m,ms,_,mi,mu=Spring.GetTeamResources(team,"metal")
            local e,es,_,ei,eu=Spring.GetTeamResources(team,"energy")
            log(string.format("sample frame=%d team=%d m=%.2f ms=%.2f mi=%.2f mu=%.2f e=%.2f es=%.2f ei=%.2f eu=%.2f capacity=%.2f converted=%.2f units=%s frames=%s",
                f,team,m,ms,mi,mu,e,es,ei,eu,
                Spring.GetTeamRulesParam(team,"mmCapacity") or -1,
                Spring.GetTeamRulesParam(team,"mmUse") or -1,
                table.concat(list,","),table.concat(building,",")))
        end
    end
end
