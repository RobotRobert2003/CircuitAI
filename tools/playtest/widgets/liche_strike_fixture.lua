-- Liche escort strikes (owner 2026-10-24): supplied Phoenix waves with Liches,
-- enemy Liche-roster targets along their path and flak to shoot them down.
-- Counts every Liche born, lost (and to what) and every kill a Liche made.
-- The AI's own ESCORT: lines say which target each Liche chose and whether it
-- fired before it died; tools/playtest/analyze_liche_strikes.py joins both.
function widget:GetInfo()
    return {name="Liche strike fixture",desc="Supplied Liche escort-strike measurements",author="CircuitAI",layer=118,enabled=true}
end
local liches, queue = {}, {}
local stage = 0
local born, lost, kills = 0, 0, 0
local roster = {armgate=true, corgate=true, legdeflector=true, armanni=true, cordoom=true, legbastion=true, corbhmth=true,
    armamd=true, corfmd=true, legabm=true, armsilo=true, corsilo=true, armgeo=true, armageo=true,
    armaap=true, armavp=true, armalab=true, armasy=true, coraap=true, coravp=true, coralab=true}
local function echo(s) Spring.Echo("[LicheStrike] "..s) end
local function dry(x,z)
    for r=0,1200,64 do for dx=-r,r,64 do for dz=-r,r,64 do
        local px,pz=x+dx,z+dz
        if Spring.GetGroundHeight(px,pz)>5 then return px,pz end
    end end end
    return x,z
end
local function give(name,team,x,z,n)
    x,z=dry(x,z)
    queue[#queue+1]="give "..(n or 1).." "..name.." "..team.." @"..x..","..Spring.GetGroundHeight(x,z)..","..z
end
local function defName(def) return def and UnitDefs[def] and UnitDefs[def].name or "?" end
-- One stage: a wave for team 0 and a fresh target district for team 1, shifted
-- east each stage so earlier wreckage does not hide the new targets.
local function supply(s)
    local ox = (s-1)*700
    give("armpnix",0,2600,11200,20); give("armhawk",0,2400,11200,20); give("armliche",0,2800,11400,6)
    -- the wave's economy targets (T2 bomber tiers)
    give("armafus",1,4300+ox,6500,1); give("armfus",1,3700+ox,7000,1)
    -- Liche roster: shield, Pulsar, anti-nuke, T2 plants, on and beside the bombers' path
    give("armgate",1,3900+ox,7600,1); give("armanni",1,4300+ox,7100,1); give("armamd",1,3400+ox,8300,1)
    give("armalab",1,4700+ox,6900,1); give("armavp",1,3000+ox,9100,1)
    -- anti-air: some Liches should die before they strike
    give("armflak",1,4500+ox,6700,1); give("armflak",1,3600+ox,7300,1); give("armflak",1,3200+ox,8700,1)
    echo("stage="..s.." supplied pnix=20 hawk=20 liche=6 targets=gate,anni,amd,alab,avp,afus,fus flak=3")
end
function widget:UnitCreated(id,def,team)
    if team==0 and defName(def)=="armliche" then
        liches[id]=stage; born=born+1
        echo("liche-born id="..id.." stage="..stage)
    end
end
function widget:UnitDestroyed(id,def,team,attackerID,attackerDefID,attackerTeam)
    if liches[id] then
        lost=lost+1
        echo("liche-lost id="..id.." stage="..liches[id].." by="..defName(attackerDefID))
        liches[id]=nil
    end
    if team~=0 and defName(attackerDefID)=="armliche" then
        kills=kills+1
        echo("liche-kill victim="..defName(def).." id="..id.." attacker="..tostring(attackerID).." stage="..stage)
    end
    if team==1 and roster[defName(def)] then
        echo("target-destroyed def="..defName(def).." id="..id.." by="..defName(attackerDefID).." stage="..stage)
    end
end
function widget:GameFrame(f)
    if f==300 then
        Spring.SendCommands({"cheat 1","globallos"})
        give("armafus",0,2000,12500,2) -- explicit economic milestone; still a supplied combat fixture
        echo("loaded; supplied units and global LOS; not a natural economy benchmark")
    end
    if f==600 then stage=1; supply(1) end
    if f==7200 then stage=2; supply(2) end
    if f==14400 then stage=3; supply(3) end
    if #queue>0 and f%15==0 then Spring.SendCommands(table.remove(queue,1)) end
    if f%1800==0 and f>0 then echo("tally born="..born.." lost="..lost.." kills="..kills) end
end
function widget:Shutdown() echo("tally born="..born.." lost="..lost.." kills="..kills.." final") end
