function widget:GetInfo()
 return {name="SEA expansion observer",desc="Read-only mex frontier, defense coverage and constructor survival",layer=127,enabled=true}
end
local function log(s) Spring.Echo("[SeaExpansionWatch] "..s) end
local function worker(d) return d.name=="armcs" or d.name=="corcs" or d.name=="legnavyconship" end
local function record(event,id,def,team,builder)
 local d=UnitDefs[def]
 if not d or not (worker(d) or (d.extractsMetal or 0)>0 or (d.isImmobile and (d.minWaterDepth or 0)>0 and #(d.weapons or {})>0)) then return end
 local x,_,z=Spring.GetUnitPosition(id)
 if x then log(string.format("%s team=%d id=%d def=%s builder=%s x=%.0f z=%.0f",event,team,id,d.name,tostring(builder),x,z)) end
end
function widget:Initialize() log("loaded") end
function widget:UnitCreated(id,def,team,builder) record("created",id,def,team,builder) end
function widget:UnitFinished(id,def,team) record("finished",id,def,team) end
function widget:UnitDestroyed(id,def,team) record("destroyed",id,def,team) end
function widget:GameFrame(f)
 if f%150==0 then
  for _,id in ipairs(Spring.GetAllUnits()) do
   local d=UnitDefs[Spring.GetUnitDefID(id)]
   if d and worker(d) then
    local x,_,z=Spring.GetUnitPosition(id)
    local cmd=Spring.GetUnitCurrentCommand(id)
    log(string.format("worker frame=%d team=%d id=%d x=%.0f z=%.0f cmd=%s",f,Spring.GetUnitTeam(id),id,x,z,tostring(cmd)))
   end
  end
 end
 if f%900~=0 then return end
 for _,team in ipairs(Spring.GetTeamList()) do
  local sx,_,sz=Spring.GetTeamStartPosition(team)
  if sx and sx>0 then
   local mexes,forward,furthest,cons=0,0,0,0
   for _,id in ipairs(Spring.GetTeamUnits(team)) do
    local d=UnitDefs[Spring.GetUnitDefID(id)]
    local _,_,_,_,bp=Spring.GetUnitHealth(id)
    if bp and bp>=1 then
     if worker(d) then cons=cons+1 end
     if (d.extractsMetal or 0)>0 then
      local x,_,z=Spring.GetUnitPosition(id)
      local dist=math.sqrt((x-sx)^2+(z-sz)^2)
      mexes=mexes+1;furthest=math.max(furthest,dist)
      if dist>2400 then forward=forward+1 end
     end
    end
   end
   log(string.format("sample frame=%d team=%d mexes=%d beyond2400=%d furthest=%.0f constructors=%d",f,team,mexes,forward,furthest,cons))
  end
 end
end
