function widget:GetInfo() return {name="SEA transition observer",layer=126,enabled=true} end
local cfg=VFS.Include("LuaUI/Config/sea_transition.lua")
local names={armada={"armsy","armasy","armplat","armcs","armuwfus","armnanotcplat"},
 cortex={"corsy","corasy","corplat","corcs","coruwfus","cornanotcplat"},
 legion={"legsy","legadvshipyard","legsplab","legnavyconship","leganavalfusion","legnanotcplat"}}
local n=names[cfg.side]
local first,t2,platform
local platformCreated=false
local builtBy={}
local passed={}
local function log(s) Spring.Echo("[SeaTransition] "..s) end
local function pass(key,s) if not passed[key] then passed[key]=true;log("PASS "..s) end end
local function give(name,x,z)
 if not UnitDefNames[name] then log("FAIL missing fixture unit "..name);return end
 local y=Spring.GetGroundHeight(x,z)
 if y>=-30 then log("FAIL dry fixture "..name.." height="..y);return end
 Spring.SendCommands("give 1 "..name.." 0 @"..x..","..y..","..z)
end
function widget:UnitDestroyed(id)
 if id==platform then platform=nil end
 builtBy[id]=nil
end
function widget:GameFrame(f)
 if cfg.overflow and f%900==0 then
  log("visibility radar="..tostring(Spring.IsPosInLos(6900,0,9700,0)))
 end
 -- GlobalLOS freezes engine sight-map updates (ILosType::UpdateUnit).
 -- Capacity admission needs the live map, so its overflow fixture uses real
 -- forward radars below. Preserve historical seaplane comparison fixtures.
 if cfg.supplied and f==150 then
  Spring.SendCommands("cheat 1")
  if not cfg.overflow then Spring.SendCommands("globallos") end
 end
 if cfg.supplied~=false then
  if f==300 then give(n[1],5824,10736) end
  if f==330 then give(n[5],6400,11400) end
  if f==3600 then give(n[2],6600,10736) end
  if f==6300 then
   local _,_,_,mi=Spring.GetTeamResources(0,"metal")
   if t2 and not platformCreated and mi<80 then pass("income_hold","low-income T2 holds platform despite supplied bank")
   else log("FAIL low-income hold fixture not established mi="..mi) end
  end
  -- Establish real sustained income, not a one-frame resource injection or
  -- an override of the role's economic thresholds. Naval fixtures are kept
  -- away from the tested home berth and still require water at each site.
  if f==7200 then
   -- This is a capacity-admission test, not a scout benchmark. Give real
   -- allied LOS at prospective forward berths; GlobalLOS disables the
   -- engine's live sight-map updates. Keep the production fog gate.
   if cfg.overflow then
    for i=0,3 do give("armfrad",6450+i*450,9700) end
    log("supplied forward berth vision for overflow-capacity fixture")
   end
   local converter=({armada="armuwmmm",cortex="coruwmmm",legion="leganavaleconv"})[cfg.side]
   for i=0,11 do
    give(n[5],8000+(i%4)*192,10800+math.floor(i/4)*192)
    give(converter,8000+(i%4)*192,11500+math.floor(i/4)*128)
   end
   log("supplied sustained-income economy at 4 minutes")
  end
 end
 if f%150==0 and platform then
  local x,_,z=Spring.GetUnitPosition(platform)
  local count,assist=0,0
  for _,id in ipairs(Spring.GetTeamUnits(0)) do
   local d=UnitDefs[Spring.GetUnitDefID(id)]
   if d.name==n[6] then
    local nx,_,nz=Spring.GetUnitPosition(id)
    local _,_,_,_,bp=Spring.GetUnitHealth(id)
    if bp==1 and (nx-x)^2+(nz-z)^2<=d.buildDistance^2 then
     count=count+1
     local cmd,_,_,target=Spring.GetUnitCurrentCommand(id)
     if (cmd==CMD.REPAIR or cmd==CMD.GUARD) and (target==platform or target==Spring.GetUnitIsBuilding(platform)) then assist=assist+1 end
    end
   end
  end
  if count>=2 and assist>0 then pass("support","platform assistance turrets="..count.." assisting="..assist) end
 end
end
function widget:UnitCreated(id,def,team,builder)
 if team~=0 then return end
 local d=UnitDefs[def]
 builtBy[id]=builder
 if d.name==n[3] then
  platformCreated=true
  if not t2 then log("FAIL platform before T2") end
  log("platform frame at="..Spring.GetGameSeconds())
 end
 if first and builder==first and (d.customParams or {}).unitgroup=="metal" then log("first ship metal structure "..d.name) end
 if first and builder==first and (d.name:find("fmkr") or d.name=="leganavalconv") and not passed.mex then log("FAIL first ship converter before mex") end
end
function widget:UnitFinished(id,def,team)
 if team~=0 then return end
 local d=UnitDefs[def]
 if d.name==n[4] and not first then first=id;log("first construction ship="..id) end
 if d.name==n[2] then t2=id;log("T2 finished at="..Spring.GetGameSeconds()) end
 if d.name==n[3] then platform=id;pass("platform","platform completed "..d.name) end
 if d.extractsMetal and d.extractsMetal>0 and first and builtBy[id]==first then pass("mex","mex completed by first construction ship") end
 if d.canFly and platform and builtBy[id]==platform then pass("aircraft","aircraft produced "..d.name) end
end
