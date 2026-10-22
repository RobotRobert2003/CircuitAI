function widget:GetInfo() return {name="SEA production capacity observer",layer=127,enabled=true} end
-- Read-only: do not issue commands, grant resources or change visibility.
-- Production's own builder IDs distinguish constructed turrets from fixtures.
local born,once={},{}
local yards={armsy=true,corsy=true,legsy=true,armasy=true,corasy=true,legadvshipyard=true}
local advanced={armasy=true,corasy=true,legadvshipyard=true}
local function log(s) Spring.Echo("[SeaCapacity] "..s) end
local function pass(k,s) if not once[k] then once[k]=true;log("PASS "..s) end end
local function nano(d) return d.isBuilder and d.isImmobile and not d.isFactory and (d.buildSpeed or 0)>0 end
function widget:UnitCreated(id,def,team,builder) if team==0 then born[id]=builder end end
function widget:UnitDestroyed(id) born[id]=nil end
function widget:UnitFinished(id,def,team)
 if team==0 and nano(UnitDefs[def]) and born[id] then pass("grown","constructed support turret") end
 if team==0 and UnitDefs[def].isFactory and born[id] then
  pass("factory","constructed overflow factory "..UnitDefs[def].name)
  log("factory_completed "..UnitDefs[def].name.." id="..id.." builder="..born[id])
 end
end
function widget:GameFrame(f)
 if f%150~=0 then return end
 local units=Spring.GetTeamUnits(0);local factories,turrets,commanders={},{},{}
 local mexes,tidals=0,0
 for _,id in ipairs(units) do
  local d=UnitDefs[Spring.GetUnitDefID(id)];local _,_,_,_,p=Spring.GetUnitHealth(id)
  if f%900==0 and d.isBuilder then
   local x,_,z=Spring.GetUnitPosition(id)
   local commands=Spring.GetUnitCommands(id,2) or {};local list={}
   for _,c in ipairs(commands) do list[#list+1]=c.id..":"..table.concat(c.params or {},",") end
   local target=Spring.GetUnitIsBuilding(id);local td=target and Spring.GetUnitDefID(target)
   local _,_,_,_,tp=Spring.GetUnitHealth(target or id)
   log(string.format("worker=%d def=%s x=%.0f z=%.0f priority=%s target=%s progress=%.3f commands=%s",
    id,d.name,x,z,tostring(Spring.GetUnitRulesParam(id,"builderPriority") or "default"),td and UnitDefs[td].name or "none",tp or -1,table.concat(list,";")))
  end
  if p and p>=1 then
   if (d.extractsMetal or 0)>0 then mexes=mexes+1 end
   if (d.tidalGenerator or 0)>0 then tidals=tidals+1 end
   if yards[d.name] then factories[#factories+1]=id end
   if nano(d) then turrets[#turrets+1]=id end
   if (d.customParams or {}).iscommander then commanders[#commanders+1]=id end
  end
 end
 if mexes>=6 then pass("mexes","six completed mexes") end
 if tidals>=6 then pass("tidals","six completed tidals") end
 local ready=false
 for _,id in ipairs(factories) do
  local x,_,z=Spring.GetUnitPosition(id);local count=0
  for _,n in ipairs(turrets) do
   local nx,_,nz=Spring.GetUnitPosition(n);local d=UnitDefs[Spring.GetUnitDefID(n)]
   if (nx-x)^2+(nz-z)^2<=d.buildDistance^2 then count=count+1 end
  end
  if advanced[UnitDefs[Spring.GetUnitDefID(id)].name] and count>=4 then ready=true;pass("four","T2 with four completed in-range turrets") end
  if f%900==0 then log("yard="..id.." nanos="..count.." producing="..tostring(Spring.GetUnitIsBuilding(id) or false)) end
 end
 for _,id in ipairs(commanders) do
  local cmd,_,_,target=Spring.GetUnitCurrentCommand(id)
  local def=target and Spring.GetUnitDefID(target);local d=def and UnitDefs[def]
  if (cmd==CMD.GUARD or cmd==CMD.REPAIR) and d then
   if yards[d.name] or (Spring.GetUnitRulesParam(target,"parentFactory") or -1)>=0 then pass("guard","commander assists shipyard") end
   local _,_,_,_,progress=Spring.GetUnitHealth(target)
   if ready and progress and progress<1 and not d.isFactory and d.isImmobile
    and ((d.energyMake or 0)>0 or (d.extractsMetal or 0)>0 or nano(d)
       or d.name:find("uwfus") or d.name:find("navalfusion") or d.name:find("conv") or d.name:find("fmkr")) then
    pass("handoff","commander assists economic construction after four-turret handoff")
   end
  end
 end
end
