function widget:GetInfo() return {name="SEA amphibious transition observer",layer=126,enabled=true,handler=true} end
local cfg=VFS.Include("LuaUI/Config/sea_invasion.lua")
local claimed,owned,products,targets={}, {}, {}, {}
local seen,enemySub={},nil
local shotAt=-1
local rosters={
 armada={"armsy","armasy","armplat","armuwfus","armuwmmm","armcs","armacsub","armcrus","armsubk","armamsub","armshltxuw","armcroc","armmar"},
 cortex={"corsy","corasy","corplat","coruwfus","coruwmmm","corcs","coracsub","corcrus","corshark","coramsub","corgantuw","corsala","corshiva"},
 legion={"legsy","legadvshipyard","legsplab","leganavalfusion","leganavaleconv","legnavyconship","leganavyconsub","leganavycruiser","leganavybattlesub","legamphlab","leggantuw","legamphtank","legjav"},
}
local r=rosters[cfg.side]
local function log(s) Spring.Echo("[SeaInvasionTest] "..s) end
local function pass(s) if not seen[s] then seen[s]=true;log("PASS "..s) end end
local function shot(id,label)
 local x,y,z=Spring.GetUnitPosition(id);if not x then return end
 Spring.SetCameraState({name="ta",mode=1,px=x,py=y,pz=z,height=2600,angle=0.65,flipped=-1},0)
 shotAt=Spring.GetGameFrame()+15;log("camera "..label.." at="..math.floor(x)..","..math.floor(z))
end
local function nearbySupport(id)
 local x,_,z=Spring.GetUnitPosition(id);local cover,nanos=0,0
 for u,n in pairs(owned) do
  local ux,_,uz=Spring.GetUnitPosition(u);local _,_,_,_,bp=Spring.GetUnitHealth(u)
  if ux and bp==1 then
   local d=UnitDefs[Spring.GetUnitDefID(u)];local dist=(ux-x)^2+(uz-z)^2
   if (n==r[8] or n==r[9]) and dist<=900^2 then cover=cover+d.metalCost end
   if not d.canMove and d.buildSpeed>0 and not d.isFactory and dist<=(d.buildDistance or 0)^2 then nanos=nanos+1 end
  end
 end
 return cover,nanos
end
local function protection(id)
 local cover,nanos=nearbySupport(id)
 log(string.format("protection factory=%d escortMetal=%.0f completedTurrets=%d",id,cover,nanos))
 if cover>=1500 then pass("factory-escorted") else log("FAIL missing factory escort") end
end
local function spawn(name,team,ax,az,dry)
 local d=UnitDefNames[name];if not d then log("FAIL missing "..name);return end
 for radius=0,1600,80 do for dx=-radius,radius,80 do for dz=-radius,radius,80 do
  if radius==0 or math.abs(dx)==radius or math.abs(dz)==radius then
   local x,z=ax+dx,az+dz
   if x>100 and z>100 and x<Game.mapSizeX-100 and z<Game.mapSizeZ-100 then
    local y=Spring.GetGroundHeight(x,z);local ok=(dry and y>0) or (not dry and y<-40)
    for _,p in ipairs(claimed) do if math.abs(x-p.x)<(d.xsize+p.sx)*4+32 and math.abs(z-p.z)<(d.zsize+p.sz)*4+32 then ok=false;break end end
    if ok and (not d.isBuilding or Spring.TestBuildOrder(d.id,x,y,z,0)>0) then
     claimed[#claimed+1]={x=x,z=z,sx=d.xsize,sz=d.zsize}
     Spring.SendCommands("give 1 "..name.." "..team.." @"..x..","..y..","..z);return
    end
   end
  end
 end end end
 log("FAIL placement "..name)
end
function widget:Initialize()
 log("loaded side="..cfg.side.." blocked="..tostring(cfg.blocked))
 for _,i in ipairs({6,7,10,11,12,13}) do
  local d=UnitDefNames[r[i]];local opts={}
  for _,def in ipairs(d.buildOptions or {}) do opts[#opts+1]=UnitDefs[def].name end
  log("roster "..r[i].." move="..tostring(d.moveDef and d.moveDef.name).." builds="..table.concat(opts,","))
 end
end
function widget:UnitCreated(id,def,team,builder)
 local n=UnitDefs[def].name
 if team==0 then owned[id]=n end
 if team==1 and n=="corsub" then enemySub=id end
 if team==1 and (n=="armfus" or n=="armmakr" or n=="armlab") then targets[id]=true end
 if builder and team==0 then
  if n==r[10] then
   log("factory frame complex="..id.." builder="..builder);pass("complex-started");protection(id);shot(id,"complex")
   local x,_,z=Spring.GetUnitPosition(id)
   for _,dx in ipairs({-640,-384,384,640}) do for _,dz in ipairs({0,128,256}) do
    local y=Spring.GetGroundHeight(x+dx,z+dz)
    log(string.format("gantry terrain x=%.0f z=%.0f height=%.0f build=%d",x+dx,z+dz,y,Spring.TestBuildOrder(UnitDefNames[r[11]].id,x+dx,y,z+dz,2)))
   end end
  end
  if n==r[11] then log("factory frame gantry="..id.." builder="..builder);pass("gantry-started");protection(id);shot(id,"gantry") end
  if n==r[12] or n==r[13] then products[id]=n end
 end
end
function widget:UnitFinished(id,def,team)
 local n=UnitDefs[def].name
 if team==0 and (n==r[10] or n==r[11]) then pass(n==r[10] and "complex-finished" or "gantry-finished") end
 if products[id] then pass(n==r[12] and "complex-produced" or "gantry-produced") end
end
function widget:UnitDamaged(id,def,team,damage,paralyzer)
 -- BAR's widget handler forwards only these five arguments. The engine's
 -- longer gadget signature is not the widget contract.
 local attacker=Spring.GetUnitLastAttacker(id)
 if targets[id] and products[attacker] and damage>0 and not paralyzer then pass("amphibian-damaged-economy") end
end
function widget:UnitDestroyed(id,def,team,attacker)
 if targets[id] and products[attacker] then pass("amphibian-damaged-economy") end
 if targets[id] then pass("enemy-economy-destroyed"); targets[id]=nil end
 owned[id]=nil;products[id]=nil
end
function widget:GameFrame(f)
 if f==shotAt then Spring.SendCommands("screenshot");shotAt=-1 end
 if f==150 then Spring.SendCommands("cheat 1") end
 if f==300 then
  for i=1,3 do spawn(r[i],0,6100+i*450,10800,false) end
  for i=1,24 do spawn(r[4],0,8200,11600,false) end
  for i=1,45 do spawn(r[5],0,9600,11600,false) end
  for i=1,8 do spawn(r[6],0,6400,10300,false) end
  for i=1,4 do spawn(r[7],0,6800,10300,false) end
  for i=1,16 do spawn(r[8],0,7600,10000,false) end
  for i=1,6 do spawn(r[9],0,7800,10300,false) end
  spawn("armfus",1,11200,2500,true);spawn("armmakr",1,11300,2300,true);spawn("armlab",1,11000,2200,true)
  if cfg.blocked then spawn("corsub",1,11600,6000,false) end
 end
 -- Observe a deliberately incomplete survey first, then supply genuine
 -- aircraft with LOS+sonar. Spectator data is used only for test measurements.
 if f==3600 then
  for x=400,Game.mapSizeX-100,800 do for z=400,Game.mapSizeZ-100,800 do
   Spring.SendCommands("give 1 armsehak 0 @"..x..","..(math.max(0,Spring.GetGroundHeight(x,z))+160)..","..z)
  end end
  log("sensor coverage supplied")
 end
 if f==3300 then
  local count=0;for _,n in pairs(owned) do if n==r[10] or n==r[11] then count=count+1 end end
  if count==0 then pass("partial-survey-blocked") else log("FAIL invasion before survey") end
 end
 if f%300==0 then
  for id,n in pairs(owned) do
   if n==r[10] or n==r[11] then
    local _,nanos=nearbySupport(id)
    if n==r[10] and nanos>=6 then pass("complex-support-six") end
    if n==r[11] and nanos>=12 then pass("gantry-support-twelve") end
   end
  end
  local count=0;for id,n in pairs(products) do
   local x,y,z=Spring.GetUnitPosition(id)
   if x then
    count=count+1
    if Spring.GetGroundHeight(x,z)>0 then if not seen.landfall then shot(id,"landfall") end;pass("landfall") end
    -- The coast at z~4900 is a landing, not the backline. Require entry into
    -- the supplied enemy economic-base region well inland and to the east.
    if x>9500 and z<3500 and Spring.GetGroundHeight(x,z)>0 then
     if not seen["backline-reached"] then log(string.format("backline position unit=%s x=%.0f z=%.0f",n,x,z)) end
     pass("backline-reached")
    end
    if n==r[13] and Spring.GetGroundHeight(x,z)>0 then pass("gantry-landfall") end
    if n==r[13] and x>9500 and z<3500 and Spring.GetGroundHeight(x,z)>0 then
     if not seen["gantry-backline"] then
      log(string.format("gantry backline position unit=%s x=%.0f z=%.0f",n,x,z));shot(id,"gantry-backline")
     end;pass("gantry-backline")
    end
   end
  end
  local m,_,_,mi=Spring.GetTeamResources(0,"metal");local e,_,_,ei=Spring.GetTeamResources(0,"energy")
  log(string.format("sample frame=%d amphibians=%d bankM=%.1f incomeM=%.1f incomeE=%.1f",f,count,m,mi,ei))
 end
 if cfg.blocked and f>=(cfg.minutes*60-10)*30 and not seen["blocked-check"] then
  seen["blocked-check"]=true
  if not enemySub or Spring.GetUnitTeam(enemySub)~=1 or Spring.GetUnitIsDead(enemySub) then log("FAIL blocked fixture lost submarine")
  elseif not seen["complex-started"] then pass("enemy-blocked") else log("FAIL invasion while occupied") end
 end
end
