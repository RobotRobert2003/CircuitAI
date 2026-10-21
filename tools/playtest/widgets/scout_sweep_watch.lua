function widget:GetInfo() return {name="Scout sweep supplied observer",layer=126,enabled=true,handler=true} end
local cfg=VFS.Include("LuaUI/Config/scout_sweep.lua")
local pending,planes={},{}
local prior,hook,lastEvent=nil,nil,0
local basic=({armada="armap",cortex="corap",legion="legap"})[cfg.side]
local advanced=({armada="armaap",cortex="coraap",legion="legaap"})[cfg.side]
local function give(name,team,x,z)
    pending[#pending+1]="give "..name.." "..team.." @"..x..","..Spring.GetGroundHeight(x,z)..","..z
end
function widget:Initialize()
    local env=getfenv(0); prior=rawget(env,"RecvSkirmishAIMessage")
    hook=function(team,text)
        local id,x,z=text:match("^barb|scoutsweep|%d+|%d+|cross|([^|]+)|([^|]+)|([^|]+)$")
        if team==0 and id then planes[tonumber(id)]={tonumber(x),tonumber(z)} end
        if prior then return prior(team,text) end
    end
    rawset(env,"RecvSkirmishAIMessage",hook); Script.UpdateCallIn("RecvSkirmishAIMessage")
end
function widget:GameFrame(f)
    if f==300 then Spring.SendCommands("cheat 1") end
    -- Cheat acknowledgement is asynchronous. Queue supplied units afterwards.
    if f==600 then
        for i=0,1 do give(basic,0,cfg.home[1]+(i-0.5)*320,cfg.home[2]) end
        for i=0,3 do give(advanced,0,cfg.home[1]+(i-1.5)*320,cfg.home[2]+500) end
        if cfg.mixed then
            give(cfg.side=="armada" and "corap" or "armap",0,cfg.home[1]+640,cfg.home[2]-320)
            give(cfg.side=="armada" and "coraap" or "armaap",0,cfg.home[1]+640,cfg.home[2]+500)
        end
        give(cfg.silo or "armsilo",1,cfg.tech[1],cfg.tech[2])
        Spring.Echo("[ScoutSweepWatch] supplied plants and TECH silo; real factory production")
    end
    if f%15==0 and #pending>0 then Spring.SendCommands(table.remove(pending,1)) end
    if f>=600 and f%30==0 then
        -- BAR's sandbox no longer forwards AI messages to user widget hooks.
        -- Read the existing local event ring, retaining monotonic event IDs.
        local state=VFS.LoadFile("LuaUI/Config/BARb/state/team0.txt",VFS.RAW)
        if state then for line in state:gmatch("[^\r\n]+") do
            local serial,text=line:match("^e|(%d+)|(.+)$")
            if serial and tonumber(serial)>lastEvent then
                lastEvent=tonumber(serial)
                local id,x,z=text:match("^barb|scoutsweep|%d+|%d+|cross|([^|]+)|([^|]+)|([^|]+)$")
                if id then planes[tonumber(id)]={tonumber(x),tonumber(z)} end
            end
        end end
        -- Supply the local AI's banks, not its measured income.
        for i=1,30 do Spring.SendCommands("atm") end
        for id,p in pairs(planes) do
            local x,_,z=Spring.GetUnitPosition(id)
            if x and (x-p[1])^2+(z-p[2])^2<512^2 then
                Spring.Echo("[ScoutSweepWatch] arrival unit="..id)
                planes[id]=nil
            end
        end
    end
end
function widget:Shutdown()
    local env=getfenv(0)
    if rawget(env,"RecvSkirmishAIMessage")==hook then rawset(env,"RecvSkirmishAIMessage",prior); Script.UpdateCallIn("RecvSkirmishAIMessage") end
end
