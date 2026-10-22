function widget:GetInfo()
 return {name="Full match performance lifecycle",layer=128,enabled=true}
end
local cfg=VFS.Include("LuaUI/Config/full_match_perf.lua",nil,VFS.RAW_FIRST)
local endedAt=nil
function widget:GameOver(winners)
 Spring.Echo("[FullMatchEnd] frame="..Spring.GetGameFrame().." winners="..table.concat(winners or {},","))
 endedAt=Spring.GetTimer()
 if cfg.screenshots then Spring.SendCommands("screenshot png") end
end
function widget:Update()
 if endedAt and Spring.DiffTimers(Spring.GetTimer(),endedAt)>3 then Spring.SendCommands("quitforce") end
end
function widget:GameFrame(frame)
 if not endedAt and cfg.horizon_frame and frame>=cfg.horizon_frame then
  Spring.Echo("[FullMatchHorizon] frame="..frame)
  endedAt=Spring.GetTimer()
  if cfg.screenshots then Spring.SendCommands("screenshot png") end
 end
 if frame==300 or frame%1800==0 then
  local active=0
  for team=0,(cfg.teams or 16)-1 do
   local _,_,dead,isAI=Spring.GetTeamInfo(team,false)
   local count=Spring.GetTeamUnitCount(team) or 0
   if isAI and not dead and count>0 then active=active+1 end
   Spring.Echo(string.format("[FullMatchTeam] frame=%d team=%d units=%d alive=%d",frame,team,count,not dead and 1 or 0))
  end
  Spring.Echo("[FullMatchRoster] frame="..frame.." active="..active)
 end
 -- Lock only the spectator camera. No player units, resources or AI settings
 -- are changed. Screenshots use this same scene for reproducible FPS context.
 if cfg.screenshots and frame>0 and frame%150==0 and not endedAt then
  Spring.SetCameraState({mode=1,px=cfg.x,py=math.max(0,Spring.GetGroundHeight(cfg.x,cfg.z)),pz=cfg.z,height=cfg.height,angle=.9},0)
 end
end
