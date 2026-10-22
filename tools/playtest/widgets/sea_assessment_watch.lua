function widget:GetInfo() return {name="SEA unit assessment",layer=129,enabled=true,handler=true} end
-- Read-only natural-game coverage. Counts raw damage (includes overkill), not
-- kill efficiency. No unit orders, resources, visibility or production changes.
local rows,tracked={},{}
local priorDamage,damageHook
local damageEvents=0
local function naval(def)
 local d=UnitDefs[def]
 return d and (d.minWaterDepth or 0)>0 and (d.speed or 0)>0 and not d.canFly
end
local function row(team,def)
 local key=team..":"..def
 if not rows[key] then rows[key]={team=team,def=def,finished=0,lost=0,damage=0} end
 return rows[key]
end
local function damage(id,def,team,amount,paralyzer,weapon,projectile,attacker,attackerDef,attackerTeam)
 damageEvents=damageEvents+1
 if attackerDef and attackerTeam and naval(attackerDef) and not Spring.AreTeamsAllied(team,attackerTeam) then
  row(attackerTeam,attackerDef).damage=row(attackerTeam,attackerDef).damage+amount
 end
end
-- The BAR widget sandbox drops widgetHandler.X= hooks; only a real callin
-- is delivered (that is why damageEvents read 0 for whole games, KI-604).
function widget:UnitDamaged(id,def,team,amount,paralyzer,weapon,projectile,attacker,attackerDef,attackerTeam)
 damage(id,def,team,amount,paralyzer,weapon,projectile,attacker,attackerDef,attackerTeam)
end
function widget:Initialize()
 for _,name in ipairs({"armsy","armasy","corsy","corasy","legsy","legadvshipyard"}) do
  local factory=UnitDefNames[name]
  if factory then for _,definition in ipairs(UnitDefs[factory.id].buildOptions or {}) do
   Spring.Echo("[SeaAssessment] roster factory="..name.." unit="..UnitDefs[definition].name)
  end end
 end
 Spring.Echo("[SeaAssessment] loaded")
end
function widget:UnitFinished(id,def,team)
 if naval(def) and not tracked[id] then tracked[id]=true;row(team,def).finished=row(team,def).finished+1 end
end
function widget:UnitDestroyed(id,def,team)
 if tracked[id] then row(team,def).lost=row(team,def).lost+1;tracked[id]=nil end
end
function widget:GameFrame(frame)
 if frame%1800~=0 then return end
 Spring.Echo("[SeaAssessment] observer frame="..frame.." damageEvents="..damageEvents.." attached="..tostring(widgetHandler.UnitDamaged==damageHook))
 for _,r in pairs(rows) do
  local d=UnitDefs[r.def]
  Spring.Echo(string.format("[SeaAssessment] frame=%d team=%d unit=%s tier=%s finished=%d lost=%d rawDamage=%.1f cost=%.1f",frame,r.team,d.name,tostring((d.customParams or {}).techlevel or 1),r.finished,r.lost,r.damage,d.metalCost))
 end
end
function widget:Shutdown()
 if widgetHandler.UnitDamaged==damageHook then widgetHandler.UnitDamaged=priorDamage;widgetHandler:UpdateCallIn("UnitDamaged") end
end
