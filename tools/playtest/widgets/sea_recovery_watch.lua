function widget:GetInfo() return {name="SEA recovery and production observer",layer=126,enabled=true} end
local cfg=VFS.Include("LuaUI/Config/sea_recovery.lua")
local born, yards, subs, empty, last, passed={}, {}, {}, {}, {}, {}
local flag, ordinary, wreck, expensiveWreck
local claimed = {}
local roster={
 armada={"armsy","armasy","armplat","armuwfus","armuwmmm","armnanotcplat","armepoch"},
 cortex={"corsy","corasy","corplat","coruwfus","coruwmmm","cornanotcplat","corblackhy"},
 legion={"legsy","legadvshipyard","legsplab","leganavalfusion","leganavaleconv","legnanotcplat","leganavyflagship"},
}
local function log(s) Spring.Echo("[SeaRecoveryTest] "..s) end
local function pass(k) if not passed[k] then passed[k]=true;log("PASS "..k) end end
local function rez(d) return d.name=="armrecl" or d.name=="correcl" or d.name=="legnavyrezsub" end
local function give(n,x,z)
 local y=Spring.GetGroundHeight(x,z)
 if y>=-20 then log("FAIL dry fixture "..n);return end
 Spring.SendCommands("give 1 "..n.." 0 @"..x..","..y..","..z)
end
-- Supplied capacity is test setup, never an AI command. Search actual water
-- and exclude placements already requested this frame before engine sync.
local function supply(n,t)
 local d=UnitDefNames[n]
 local direction=t.ally==0 and 1 or -1
 -- Put injected capacity in deep water, not the cramped coastal start cells.
 -- Every original team still plays normally. These are explicitly supplied
 -- assets, so this run measures production/recovery rather than layout choice.
 local inner=(t.team%8)>=4
 local x0=t.ally==0 and (inner and 5600 or 3500) or (inner and Game.mapSizeX-5600 or Game.mapSizeX-3500)
 if d.isFactory then x0=x0+direction*650 end
 if not d.isBuilding and not d.isFactory then x0=x0+direction*1000 end
 for radius=0,1024,64 do
  for dx=-radius,radius,64 do for dz=-radius,radius,64 do
   if radius==0 or math.abs(dx)==radius or math.abs(dz)==radius then
    local x,z=x0+dx,t.z+dz
    if x>100 and x<Game.mapSizeX-100 and z>100 and z<Game.mapSizeZ-100 then
     local y=Spring.GetGroundHeight(x,z)
     local clear=y<-35
     for _,p in ipairs(claimed) do
      if math.abs(x-p.x)<(d.xsize+p.sx)*4+16 and math.abs(z-p.z)<(d.zsize+p.sz)*4+16 then clear=false;break end
     end
     if clear and Spring.TestBuildOrder(d.id,x,y,z,direction==1 and 1 or 3)>0 then
      claimed[#claimed+1]={x=x,z=z,sx=d.xsize,sz=d.zsize}
      Spring.SendCommands("give 1 "..n.." "..t.team.." @"..x..","..y..","..z)
      return
     end
    end
   end
  end end
 end
 log("FAIL no capacity site team="..t.team.." unit="..n)
end
function widget:Initialize() log("loaded teams="..#cfg.teams.." fixture="..tostring(cfg.fixture)) end
function widget:UnitCreated(id,def,team,builder) born[id]={builder=builder,frame=Spring.GetGameFrame()} end
function widget:UnitFinished(id,def,team)
 local d=UnitDefs[def]
 if d.isFactory then yards[id]={team=team,name=d.name,tier=tonumber((d.customParams or {}).techlevel) or 1,produced=0} end
 if rez(d) then subs[id]=team;log("sub finished team="..team.." id="..id.." name="..d.name) end
 local b=born[id]
 if b and b.builder and yards[b.builder] then
  yards[b.builder].produced=yards[b.builder].produced+1
  log("product team="..team.." factory="..b.builder.." lab="..yards[b.builder].name.." unit="..d.name)
  local r=roster[(cfg.teams[team+1] or {}).side]
  if r then for i=1,3 do if yards[b.builder].name==r[i] then pass("team-"..team.."-factory-"..i) end end end
  if d.name=="armrecl" and cfg.fixture then pass("sub-produced") end
  if yards[b.builder].name=="armsy" then pass("t1-producing") end
  if yards[b.builder].name=="armasy" then pass("t2-producing") end
  if yards[b.builder].name=="armplat" then pass("platform-producing") end
 end
 if cfg.fixture and team==0 then
  if d.name=="armepoch" then flag=id end
  if d.name=="armcrus" and not ordinary then ordinary=id end
  if d.name=="armroy" then wreck=id end
  if d.name=="corblackhy" then expensiveWreck=id end
 end
end
function widget:UnitDestroyed(id)
 yards[id]=nil;subs[id]=nil;empty[id]=nil;born[id]=nil;last[id]=nil
end
function widget:GameFrame(f)
 if f==150 then Spring.SendCommands({"cheat 1","globallos"}) end
 if cfg.capacity and f>=900 and f<=2700 and f%30==0 then
  -- Stagger injection: sync occupancy and AI ownership between gifts. Give
  -- enough real energy/conversion for support scaling, then each yard tier.
  local step=(f-900)/30+1
  for _,t in ipairs(cfg.teams) do
   local r=roster[t.side]
   if step<=8 then supply(r[4],t)
   elseif step<=26 then supply(r[5],t)
   elseif step<=29 then supply(r[step-26],t)
   elseif step<=33 then supply(r[6],t)
   elseif step==34 then supply(r[7],t) end
  end
 end
 if cfg.fixture then
  if f==300 then
   for i=0,3 do give("armrecl",6200+i*64,10700) end;give("armepoch",6450,10700);give("armcrus",6000,10550)
   give("armroy",6150,10900)
  end
  if f==450 then
   if flag then Spring.SendLuaRulesMsg("$dev$:sethealth "..flag..":95") end
   if ordinary then Spring.SendLuaRulesMsg("$dev$:sethealth "..ordinary..":10") end
   if wreck then Spring.SendLuaRulesMsg("$dev$:wreckunits "..wreck) end
   log("fixture low-metal reclaim with damaged flagship and ordinary ship")
  end
  if f==3600 then
   for i=0,11 do give("armuwmmm",8000+(i%4)*150,11000+math.floor(i/4)*150) end
   for i=0,5 do give("armuwfus",7700+i*200,11600) end
  end
  if f==4200 then give("armroy",6300,10900);give("corblackhy",6600,10900) end
  if f==5400 and ordinary then Spring.SendLuaRulesMsg("$dev$:sethealth "..ordinary..":10") end
  if f==4260 and wreck then
   Spring.SendLuaRulesMsg("$dev$:wreckunits "..wreck)
   if expensiveWreck then Spring.SendLuaRulesMsg("$dev$:wreckunits "..expensiveWreck) end
  end
  if f==7200 then
   give("armsy",5800,10700);give("armasy",6800,11100);give("armplat",7150,10600)
   give("armcs",6500,11000);give("armcs",6500,11150);give("armacsub",6850,11400);give("armacsub",7000,11400)
   for i=0,3 do give("armnanotcplat",6550+i*64,11300) end
   log("fixture production release T1 T2 platform")
  end
 end
 if f%30~=0 then return end
 local resurrectionGroups={}
 for id,team in pairs(subs) do
  local cmd,_,_,target=Spring.GetUnitCurrentCommand(id)
  if cfg.fixture and cmd==CMD.RESURRECT then
   local orders=Spring.GetUnitCommands(id,1) or {}
   local parameters=orders[1] and orders[1].params or {}
   local key=table.concat(parameters,",")
   resurrectionGroups[key]=(resurrectionGroups[key] or 0)+1
   if resurrectionGroups[key]>=3 then pass("grouped-resurrection") end
   if #parameters>=1 and parameters[1]>=Game.maxUnits then
    local name=Spring.GetFeatureResurrect(parameters[1]-Game.maxUnits)
    local feature=parameters[1]-Game.maxUnits
    local x,_,z=Spring.GetFeaturePosition(feature)
    if not passed["high-value-resurrection"] then log("rez-target params="..key.." feature="..feature.." name="..tostring(name).." x="..tostring(x).." z="..tostring(z)) end
    if name=="corblackhy" or (x and math.abs(x-6600)<32 and math.abs(z-10900)<32) then pass("high-value-resurrection") end
   elseif #parameters>=3 and math.abs(parameters[1]-6600)<32 and math.abs(parameters[3]-10900)<32 then
    pass("high-value-resurrection")
   end
  end
  local sig=tostring(cmd)..":"..tostring(target)
  if last[id]~=sig then
   last[id]=sig
   local m,ms=Spring.GetTeamResources(team,"metal")
   log("order frame="..f.." sub="..id.." team="..team.." cmd="..tostring(cmd).." target="..tostring(target).." metal="..m.." storage="..ms)
   if cmd==CMD.REPAIR and target and Spring.GetUnitTeam(target)~=team and Spring.GetUnitAllyTeam(target)==Spring.GetTeamAllyTeamID(team) then pass("allied-repair") end
   if cfg.fixture then
    if cmd==CMD.RECLAIM then pass("reclaim") end
    if cmd==CMD.REPAIR and target==flag then pass("flagship-repair") end
    if cmd==CMD.REPAIR and f<1800 and m<ms*.2 then pass("repair-before-reclaim") end
    if cmd==CMD.RESURRECT then pass("resurrect") end
    if cmd==CMD.REPAIR and target==ordinary then pass("ordinary-repair") end
   end
  end
 end
 for id,y in pairs(yards) do
  local product=Spring.GetUnitIsBuilding(id)
  local q=Spring.GetFactoryCommands(id,1) or {}
  local queued=#q>0 and q[1].id and q[1].id<0
  local busy=product~=nil or queued
  if busy then
   if empty[id] then log("idle-end factory="..id.." seconds="..(f-empty[id])/30) end
   empty[id]=nil
  elseif not empty[id] then empty[id]=f end
  if f%300==0 then
   local m,ms,_,mi,mu=Spring.GetTeamResources(y.team,"metal")
   local e,es,_,ei,eu=Spring.GetTeamResources(y.team,"energy")
   local progress=product and select(5,Spring.GetUnitHealth(product)) or 0
   log(string.format("yard frame=%d team=%d id=%d name=%s tier=%d queue=%d product=%s progress=%.4f emptySeconds=%.0f metal=%.1f/%.1f mi=%.1f mu=%.1f energy=%.1f/%.1f ei=%.1f eu=%.1f produced=%d",
    f,y.team,id,y.name,y.tier,#q,tostring(product),progress or 0,empty[id] and (f-empty[id])/30 or 0,m,ms,mi,mu,e,es,ei,eu,y.produced))
  end
 end
 if f%900==0 then
  if cfg.fixture then
   for _,id in ipairs({flag,ordinary}) do
    local hp,mhp=Spring.GetUnitHealth(id)
    if hp then log("repair-health frame="..f.." id="..id.." hp="..hp.." max="..mhp) end
   end
  end
  for _,t in ipairs(cfg.teams) do
   local n=0;for _,team in pairs(subs) do if team==t.team then n=n+1 end end
   log("census frame="..f.." team="..t.team.." subs="..n)
   if n>=2 then pass("sub-scaling") end
  end
 end
end
