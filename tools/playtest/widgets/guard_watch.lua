function widget:GetInfo()
 return {name="Guard regression observer",layer=130,enabled=true,handler=true}
end
local cfg=VFS.Include("LuaUI/Config/guard_test.lua")
local previous,hook
local total,guards,repeats,finished=0,0,0,0
local last,byUnit={},{}
local workers,yards={},{}
local passed={}
local stopFrame
local movingStart
local function log(s) Spring.Echo("[GuardTest] "..s) end
local function pass(key) if not passed[key] then passed[key]=true;log("PASS "..key) end end
local function guardTarget(id)
 for _,c in ipairs(Spring.GetUnitCommands(id,8) or {}) do
  if c.id==CMD.GUARD and #c.params==1 then return c.params[1] end
 end
end
local function probe(id,target)
 Spring.SendSkirmishAIMessage(0,"guard-probe|"..id.."|"..target)
end
function widget:Initialize()
 previous=widgetHandler.UnitCommand
 hook=function(self,id,def,team,cmd,params,options,tag,player,fromSynced,fromLua,...)
  local frame=Spring.GetGameFrame()
  -- LuaUI sends synchronized player/network commands; fromLua identifies
  -- synced gadget orders, not the UI that requested this STOP.
  if cfg.fixture and not stopFrame and id==workers[1] and cmd==CMD.STOP and frame>=2100 and frame<2700 then
   stopFrame=frame;log("STOP applied frame="..frame)
  end
  if team==0 and fromLua==false then
   total=total+1
   if cmd==CMD.GUARD and params and #params==1 then
    guards=guards+1;byUnit[id]=(byUnit[id] or 0)+1
    if last[id]==params[1] then repeats=repeats+1 end
    last[id]=params[1]
   end
  end
  if previous then return previous(self,id,def,team,cmd,params,options,tag,player,fromSynced,fromLua,...) end
 end
 widgetHandler.UnitCommand=hook;widgetHandler:UpdateCallIn("UnitCommand")
 log("loaded fixture="..tostring(cfg.fixture))
end
function widget:UnitFinished(id,def,team)
 if team~=0 then return end
 local d=UnitDefs[def]
 if d.name=="armsy" then yards[#yards+1]=id end
 if d.name=="armcs" then workers[#workers+1]=id end
 if not d.isImmobile then finished=finished+1 end
end
function widget:GameFrame(f)
 if f%900==0 then
  if widgetHandler.UnitCommand~=hook then log("FAIL observer_replaced") end
  log(string.format("frame=%d commands=%d guards=%d repeated_targets=%d finished_mobile=%d",f,total,guards,repeats,finished))
  for id,n in pairs(byUnit) do log("unit="..id.." guards="..n) end
 end
 if not cfg.fixture then return end
 if f>=600 and f%30==0 and workers[1] then
  local q={}
  for _,c in ipairs(Spring.GetUnitCommands(workers[1],8) or {}) do
   q[#q+1]=c.id..":"..table.concat(c.params or {},",")
  end
  log("queue frame="..f.." worker="..workers[1].." commands="..table.concat(q,";"))
 end
 if f==150 then Spring.SendCommands("cheat 1") end
 if f==300 then
  for _,p in ipairs({{"armsy",5824,10736},{"armsy",6528,10736},{"armcs",5632,10736},{"armcs",5760,11000},{"armuwfus",6300,11400}}) do
   Spring.SendCommands("give "..p[1].." 0 @"..p[2]..","..Spring.GetGroundHeight(p[2],p[3])..","..p[3])
  end
 end
 -- Real task re-admission intentionally repeats: this isolates native Execute
 -- queue idempotence. Natural games separately measure unmodified role policy.
 if f>=600 and f<8100 and f%60==0 and #workers>=2 and #yards>=2 then
  local target=f<3600 and yards[1] or f<5400 and yards[2] or workers[2]
  if Spring.ValidUnitID(target) then probe(workers[1],target) end
 end
 if f==2100 and workers[1] then
  -- The host is a spectator: send through the test-only existing AI API,
  -- rather than silently rejected spectator GiveOrderToUnit calls.
  Spring.SendSkirmishAIMessage(0,"guard-stop|"..workers[1].."|0");log("interruption STOP frame="..f)
 end
 if stopFrame and not passed.stop_recovery and f>stopFrame and guardTarget(workers[1])==yards[1] then
  if f-stopFrame<=90 then pass("stop_recovery");log("STOP recovery frames="..(f-stopFrame))
  else log("FAIL delayed_stop_recovery frames="..(f-stopFrame));stopFrame=nil end
 end
 if f==4200 and guardTarget(workers[1])==yards[2] then pass("target_change") end
 if f==5520 and workers[2] then
  local x,_,z=Spring.GetUnitPosition(workers[2]);movingStart={x,z}
  Spring.SendSkirmishAIMessage(0,"guard-move|"..workers[2].."|0")
 end
 if f==6300 and movingStart and guardTarget(workers[1])==workers[2] then
  local x,_,z=Spring.GetUnitPosition(workers[2])
  if (x-movingStart[1])^2+(z-movingStart[2])^2>100^2 then pass("moving_target")
  else log("FAIL target_did_not_move") end
 end
 if f==6600 and workers[2] then
  Spring.SendLuaRulesMsg("$dev$:removeunits "..workers[2]);log("removed guard target")
 end
 if f==7200 and workers[1] and yards[2] then probe(workers[1],yards[2]) end
 if f==7800 and guardTarget(workers[1])==yards[2] then pass("target_loss_recovery") end
 if f%60==0 and workers[1] then
  local cmd=Spring.GetUnitCurrentCommand(workers[1])
  if cmd==CMD.REPAIR and guardTarget(workers[1]) then pass("production_assist") end
 end
 if f==8100 then
  if #workers<2 or #yards<2 then log("FAIL fixture_not_established") end
  if finished>=5 then pass("production_continues") else log("FAIL production_stalled") end
  if cfg.expect_suppression and workers[1] and (byUnit[workers[1]] or 0)>35 then log("FAIL duplicate_guard_budget") end
  log("fixture_end")
 end
end
function widget:Shutdown()
 if widgetHandler.UnitCommand==hook then widgetHandler.UnitCommand=previous;widgetHandler:UpdateCallIn("UnitCommand") end
end
