function widget:GetInfo() return {name="Transport demand verification",layer=126,enabled=true} end
local side="__SIDE__"
local localBuild=__LOCAL__
local names={armada={"armap","armatlas","armhvytrans"},cortex={"corap","corvalk","corhvytrans"},legion={"legap","leglts","legatrans"}}
local def=names[side]
local aircraft=names[localBuild and side or "armada"]
local cargoName=({armada="armfboy",cortex="corsumo",legion="leginc"})[side]
local heavyBuilt,lightBuilt=0,0
local function emit(s) Spring.Echo("[TransportDemandTest] "..s) end
local function has(team,name)
    for _,id in ipairs(Spring.GetTeamUnits(team)) do
        if UnitDefs[Spring.GetUnitDefID(id)].name==name then return true end
    end
    return false
end
function widget:GameFrame(f)
    if f==90 then Spring.SendCommands("cheat 1"); emit("observer_started") end
    if f==300 then
        for team=0,2 do Spring.SendSkirmishAIMessage(team,"transport-demand-init") end
        Spring.SendCommands("give 1 "..aircraft[1].." "..(localBuild and 0 or 1).." @1600,0,4000")
        Spring.SendCommands("give 1 "..cargoName.." 0 @1200,0,4200")
    end
    if f==450 then
        local found=false
        for _,id in ipairs(Spring.GetTeamUnits(0)) do
            if UnitDefs[Spring.GetUnitDefID(id)].name==cargoName then
                Spring.SendSkirmishAIMessage(0,"transport-demand-ledger|"..id)
                found=true
            end
        end
        if not found then emit("FAIL missing ledger cargo") end
    end
    if f==1800 then
        emit((lightBuilt==1 and has(0,aircraft[2]) and heavyBuilt==0 and "PASS " or "FAIL ").."light only before rush")
        Spring.SendSkirmishAIMessage(0,"transport-demand-rush")
    end
    if f==5400 then
        emit((heavyBuilt==1 and lightBuilt==1 and has(0,aircraft[2]) and has(0,aircraft[3]) and "PASS " or "FAIL ").."physical heavy after rush")
        Spring.SendSkirmishAIMessage(0,"transport-demand-stop")
    end
    if f==6000 then emit((heavyBuilt==1 and lightBuilt==1 and "PASS " or "FAIL ").."no extras") end
end
function widget:UnitCreated(id,definition,team,builder)
    local name=UnitDefs[definition].name
    if name==aircraft[2] then
        lightBuilt=lightBuilt+1
        if not builder then emit("FAIL light not factory built") end
    end
    if name==aircraft[3] then
        heavyBuilt=heavyBuilt+1
        if not builder or Spring.GetGameFrame()<1800 then emit("FAIL unplanned heavy") end
    end
end
