function widget:GetInfo() return {name="TECH recovery verification",layer=126,enabled=true} end
local mode="__MODE__"
local sites={{1400,"armnanotc"},{1464,"armnanotc"},{1584,"armestor"},{1760,"armmmkr"},{1000,"armnanotc"}}
local built,created={},{}
local phase,phaseAt=0,0
local factory,products,lastFinish,refills,maxGap=nil,{},nil,0,0
local function emit(s) Spring.Echo("[TechRecoveryTest] "..s) end
local function give(name,x,z)
    Spring.SendCommands("give 1 "..name.." 0 @"..x..","..Spring.GetGroundHeight(x,z)..","..z)
end
local function destroy(ids)
    Spring.SelectUnitArray(ids,false); Spring.SendCommands("destroy"); Spring.SelectUnitArray({},false)
end
function widget:UnitCreated(id,def,team,builder)
    if team~=0 then return end
    local name=UnitDefs[def].name
    if name=="armshltx" then factory=id end
    if builder==factory and factory then products[id]=true end
    if builder then
        created[id]=true
        if phase==2 and name=="armafus" and not built[4] then emit("FAIL AFUS before lost converter") end
    end
end
function widget:UnitFinished(id,def,team)
    if team~=0 then return end
    if products[id] then lastFinish=Spring.GetGameFrame();emit("product_finished frame="..lastFinish.." id="..id) end
    if not created[id] then return end
    local x,_,z=Spring.GetUnitPosition(id)
    for index,site in ipairs(sites) do
        if UnitDefs[def].name==site[2] and math.abs(x-site[1])<20 and math.abs(z-10100)<20 then
            built[index]=id;emit("site_completed index="..index.." phase="..phase.." id="..id)
        end
    end
end
function widget:UnitCommand(id,def,team,cmd)
    if mode~="gantry" or id~=factory or not lastFinish or cmd>=0 then return end
    local gap=Spring.GetGameFrame()-lastFinish
    maxGap=math.max(gap,maxGap);refills=refills+1;lastFinish=nil
    emit("refill count="..refills.." gap="..gap.." max="..maxGap)
    if gap>12 then emit("FAIL gantry refill gap="..gap) end
    if refills==3 then emit("PASS gantry_three_refills max_gap="..maxGap) end
end
function widget:GameFrame(f)
    if f==90 then Spring.SendCommands("cheat 1") end
    if f==150 then Spring.SendSkirmishAIMessage(0,"tech-recovery|setup|"..mode) end
    if f==240 then
        if mode=="recovery" then
            give("armafus",900,10800)
            for i=0,5 do give(i<3 and "armca" or "armaca",1350+i*80,10300) end
        else
            give("armshltx",1600,10100)
            for i=0,23 do give("armnanotc",1380+(i%8)*48,10400+math.floor(i/8)*48) end
            for i=0,7 do give("armafus",800+i*340,11200) end
        end
    end
    if mode=="recovery" then
        if phase==0 and built[1] and built[2] and built[3] and built[4] and built[5] then
            phase=1;phaseAt=f
            destroy({built[1],built[2],built[3]});built[1]=nil;built[2]=nil;built[3]=nil
            Spring.SendSkirmishAIMessage(0,"tech-recovery|wave1");emit("wave1 frame="..f)
        elseif phase==1 and built[1] and built[2] and built[3] and f>phaseAt+60 then
            emit("PASS nano_and_economy_rebuilt")
            phase=15;phaseAt=f
            Spring.SendSkirmishAIMessage(0,"tech-recovery|wave2")
        elseif phase==15 and f>phaseAt+330 then
            phase=2;phaseAt=f
            destroy({built[4]});built[4]=nil
            emit("wave2 frame="..f)
        elseif phase==2 and built[4] and f>phaseAt+300 then
            phase=3;emit("PASS all_waves converter_rebuilt_low_income")
        end
    elseif lastFinish and factory then
        if f-lastFinish>90 then emit("FAIL gantry stalled");lastFinish=nil end
    end
end
