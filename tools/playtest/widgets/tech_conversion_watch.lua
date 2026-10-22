function widget:GetInfo() return {name="TECH conversion fixture",layer=126,enabled=true} end
local initialReactors,reported=0,false
local function give(name,x,z)
 Spring.SendCommands("give 1 "..name.." 0 @"..x..","..Spring.GetGroundHeight(x,z)..","..z)
end
function widget:GameFrame(frame)
 if frame==150 then Spring.SendCommands("cheat 1") end
 -- Adopt the opening factory before supplying late-game turrets. The opening
 -- exception is real policy; giving both on the same frame falsely tests this
 -- arbitrary fixture site as a newly planned, turret-adjacent late factory.
 if frame==210 then
  local x,_,z=Spring.GetTeamStartPosition(0)
  give("leglab",x+600,z-600)
 end
 if frame==300 then
  local x,_,z=Spring.GetTeamStartPosition(0)
  give("legafus",x+320,z)
  give("legnanotc",x+520,z-600)
  for index=0,15 do give("legnanotc",x-120+(index%4)*48,z-520+math.floor(index/4)*48) end
  give("legaca",x,z+160);give("legaca",x,z+240)
  for index=0,19 do give("legadveconv",x+520+(index%5)*64,z+math.floor(index/5)*64) end
  initialReactors=1
 end
 if frame>300 and frame%900==0 then
  local reactors,converters=0,0
  for _,id in ipairs(Spring.GetTeamUnits(0)) do
   local name=UnitDefs[Spring.GetUnitDefID(id)].name
   local _,_,_,_,progress=Spring.GetUnitHealth(id)
   if name=="legafus" and progress==1 then reactors=reactors+1 end
   if name=="legadveconv" then converters=converters+1 end
   if name=="legafus" then Spring.Echo("[TechConversion] reactor="..id.." progress="..tostring(progress)) end
  end
  Spring.Echo("[TechConversion] completed reactors="..reactors.." converters="..converters)
  if reactors>initialReactors and not reported then
   reported=true;Spring.Echo("[TechConversion] PASS additional reactor completed")
  end
 end
end
