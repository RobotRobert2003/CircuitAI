function widget:GetInfo() return {name="SEA coastal fallback fixture",layer=125,enabled=true,handler=true} end
local cfg=VFS.Include("LuaUI/Config/sea_coast.lua")
local home=cfg.teams[1]
local dry,wet,base,beaches=nil,nil,nil,{}
local prior,hook=nil,nil
local camera=nil
local transfer,finished={},{}
local invaders,damaged={},false
local enemy=1
for _,t in ipairs(cfg.teams) do if t.ally~=home.ally then enemy=t.team;break end end
local function log(s) Spring.Echo("[CoastFixture] frame="..Spring.GetGameFrame().." "..s) end
local function give(name,team,p)
 Spring.SendCommands("give "..name.." "..team.." @"..p.x..","..Spring.GetGroundHeight(p.x,p.z)..","..p.z)
end
local prefix=cfg.side=="armada" and "arm" or cfg.side=="cortex" and "cor" or "leg"
local ctor=prefix.."ck"
local yard=cfg.side=="legion" and "legsy" or prefix.."sy"
local ship=cfg.side=="legion" and "legnavyconship" or prefix.."cs"
local function site(name,water)
 local d=UnitDefNames[name]
 for r=0,3000,128 do for k=0,15 do
  local a=k*math.pi/8
  local x,z=home.x+math.cos(a)*r,home.z+math.sin(a)*r
  if x>64 and z>64 and x<Game.mapSizeX-64 and z<Game.mapSizeZ-64
    and (Spring.GetGroundHeight(x,z)<-16)==water and Spring.TestBuildOrder(d.id,x,Spring.GetGroundHeight(x,z),z,0)>0 then return {x=x,z=z} end
 end end
end
function widget:Initialize()
 local env=getfenv(0);prior=rawget(env,"RecvSkirmishAIMessage")
 hook=function(team,text)
  if team==0 then
   local x,z,n=text:match("^coastprobe|state|([^|]+)|([^|]+)|(%d+)$")
   if x and tonumber(x)>=0 then base={x=tonumber(x),z=tonumber(z)} end
   local id,bx,bz,nx,nz=text:match("^coastprobe|beach|(%d+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)$")
   if id then beaches[tonumber(id)+1]={x=tonumber(bx),z=tonumber(bz),nx=tonumber(nx),nz=tonumber(nz)} end
  end
  if prior then return prior(team,text) end
 end
 rawset(env,"RecvSkirmishAIMessage",hook);Script.UpdateCallIn("RecvSkirmishAIMessage")
 log("loaded; supplied resources, real constructor ownership transfer, real AI placement")
end
function widget:GameFrame(f)
 if f==150 then Spring.SendCommands({"cheat 1","globallos"}) end
 if f==600 then
  wet=site(yard,true);dry=site(prefix.."lab",false)
  if not wet or not dry then log("FAIL fixture sites missing");return end
  give(yard,0,wet)
  give(ship,0,{x=wet.x+240,z=wet.z})
  log("seeded naval foothold")
 end
 if f==3600 then
  for _,id in ipairs(Spring.GetTeamUnits(0) or {}) do
   local d=UnitDefs[Spring.GetUnitDefID(id)]
   if cfg.mode~="held" or (d.name~=yard and d.name~=ship) then Spring.SendLuaRulesMsg("$dev$:removeunits "..id) end
  end
  give(ctor,1,dry)
  log(cfg.mode=="held" and "yard retained" or "naval foothold removed")
 end
 if f==3630 then
  for _,id in ipairs(Spring.GetTeamUnits(1) or {}) do
   if UnitDefs[Spring.GetUnitDefID(id)].name==ctor then Spring.SendLuaRulesMsg("$dev$:transferunits "..id..":0") end
  end
 end
 -- Supplied liquidity isolates build sequencing/placement. This is not a
 -- natural-economy benchmark or a claim that the recovery is always affordable.
 if f>=3600 and f%150==0 then Spring.SendCommands({"team 0","atm 5000","spectator"}) end
 if f==21600 and cfg.mode=="retake" then give(yard,0,wet);give(ship,0,{x=wet.x+240,z=wet.z});log("naval foothold restored") end
 if f==9000 and base and cfg.mode~="held" then
  for i=1,4 do give(prefix.."ack",1,{x=base.x+400,z=base.z+i*72}) end
  log("advanced donor supplied")
 end
 if f==9030 then
  for _,id in ipairs(Spring.GetTeamUnits(1) or {}) do
   if UnitDefs[Spring.GetUnitDefID(id)].name==prefix.."ack" then Spring.SendLuaRulesMsg("$dev$:transferunits "..id..":0") end
  end
 end
 if f==27000 and cfg.mode=="lost" and beaches[1] then
  local b=beaches[1]
  for i=1,6 do give("armcroc",enemy,{x=b.x+b.nx*600-b.nz*(i-3)*80,z=b.z+b.nz*600+b.nx*(i-3)*80}) end
  give("armmar",enemy,{x=b.x+b.nx*800,z=b.z+b.nz*800})
  give(prefix.."mlv",0,{x=base.x+250,z=base.z})
  log("amphibious wave and capable minelayer supplied")
 end
 if f==27060 and beaches[1] then
  local b=beaches[1]
  for _,id in ipairs(Spring.GetTeamUnits(enemy) or {}) do
   local d=UnitDefs[Spring.GetUnitDefID(id)]
   if d.name=="armcroc" or d.name=="armmar" then
    invaders[id]=Spring.GetUnitHealth(id)
    Spring.GiveOrderToUnit(id,CMD.MOVE,{b.x-b.nx*500,Spring.GetGroundHeight(b.x-b.nx*500,b.z-b.nz*500),b.z-b.nz*500},0)
   end
  end
 end
 if f>27060 and f%150==0 then
  for id,hp in pairs(invaders) do
   local health=Spring.GetUnitHealth(id)
   if health and health<hp and not damaged then damaged=true;log("invader damaged by live defense") end
  end
 end
 if f%1800==0 and f>3600 then
  local target=(f%7200==0 and beaches[1]) or base or dry
  if target and not camera then
   camera={state={mode=1,px=target.x,py=math.max(0,Spring.GetGroundHeight(target.x,target.z)),pz=target.z,height=2800,angle=.9},at=Spring.GetTimer(),draws=0}
   Spring.SendCommands({"setminspeed 1","setmaxspeed 1"})
  end
  log("census sectors="..#beaches.." completed="..(finished[prefix.."lab"] or 0).." labs")
 end
 if f==24000 and cfg.mode=="held" then log("held control complete") end
end
function widget:DrawWorld()
 if not camera then return end
 Spring.SetCameraState(camera.state,0);camera.draws=camera.draws+1
 if camera.draws>=5 and Spring.DiffTimers(Spring.GetTimer(),camera.at)>=1 then
  Spring.SendCommands("screenshot png")
  Spring.SendCommands({"setmaxspeed 15","setminspeed 15","setmaxspeed 15"})
  camera=nil
 end
end
function widget:UnitGiven(id,def,newTeam,oldTeam)
 if newTeam==0 then log("donated "..UnitDefs[def].name.." id="..id) end
end
function widget:UnitFinished(id,def,team)
 if team~=0 then return end
 local d=UnitDefs[def];local x,_,z=Spring.GetUnitPosition(id)
 finished[d.name]=(finished[d.name] or 0)+1
 log("finished "..d.name.." x="..math.floor(x).." z="..math.floor(z))
end
function widget:Shutdown()
 local env=getfenv(0)
 if rawget(env,"RecvSkirmishAIMessage")==hook then rawset(env,"RecvSkirmishAIMessage",prior);Script.UpdateCallIn("RecvSkirmishAIMessage") end
end
