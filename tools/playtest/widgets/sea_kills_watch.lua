function widget:GetInfo() return {name="SEA kill tally",layer=130,enabled=true,handler=true} end
-- Read-only: metal value of enemy units destroyed by the team under test
-- (team 0), split naval / land mobile / structure, and team 0's own losses.
-- Uses the real widget:UnitDestroyed callin (widgetHandler hooks are dropped).
local killed={naval=0,land=0,structure=0}
local lost={naval=0,land=0,structure=0}
local lostBy={} -- attacker definition name -> metal of our units it destroyed
local function kind(def)
 local d=UnitDefs[def]
 if not d then return nil end
 if (d.speed or 0)<=0 then return "structure" end
 if (d.minWaterDepth or 0)>0 and not d.canFly then return "naval" end
 if d.canFly then return nil end
 return "land"
end
local function cost(def) local d=UnitDefs[def]; return d and (d.metalCost or 0) or 0 end
function widget:UnitDestroyed(id,def,team,attacker,attackerDef,attackerTeam)
 local k=kind(def); if not k then return end
 if Spring.GetUnitIsBeingBuilt and select(1,Spring.GetUnitIsBeingBuilt(id)) then return end
 if team==0 then
  lost[k]=lost[k]+cost(def)
  local a=attackerDef and UnitDefs[attackerDef] and UnitDefs[attackerDef].name or "unknown"
  lostBy[a]=(lostBy[a] or 0)+cost(def)
  if k=="naval" then
   -- One line per own ship lost: where, to what, from how far.
   local x,_,z=Spring.GetUnitPosition(id)
   local ax,_,az; if attacker then ax,_,az=Spring.GetUnitPosition(attacker) end
   Spring.Echo(string.format("[SeaLoss] frame=%d victim=%s attacker=%s x=%d z=%d range=%d",
    Spring.GetGameFrame(),UnitDefs[def].name,a,math.floor(x or -1),math.floor(z or -1),
    (x and ax) and math.floor(math.sqrt((x-ax)^2+(z-az)^2)) or -1))
  end
  return
 end
 if attackerTeam==0 and not Spring.AreTeamsAllied(team,0) then killed[k]=killed[k]+cost(def) end
end
local function report(frame)
 local top={}
 for name,metal in pairs(lostBy) do top[#top+1]={name,metal} end
 table.sort(top,function(a,b) return a[2]>b[2] end)
 local parts={}
 for i=1,math.min(6,#top) do parts[#parts+1]=top[i][1]..":"..math.floor(top[i][2]) end
 Spring.Echo("[SeaKillers] frame="..frame.." "..table.concat(parts,","))
 Spring.Echo(string.format("[SeaKills] frame=%d killed_naval=%d killed_land=%d killed_structure=%d lost_naval=%d lost_land=%d lost_structure=%d",
  frame,killed.naval,killed.land,killed.structure,lost.naval,lost.land,lost.structure))
end
function widget:GameFrame(frame) if frame%1800==0 then report(frame) end end
function widget:Initialize() Spring.Echo("[SeaKills] loaded") end
