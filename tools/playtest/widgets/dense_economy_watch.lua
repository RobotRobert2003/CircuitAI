function widget:GetInfo() return {name="Dense economy fixture",layer=125,enabled=true,handler=true} end
local cfg=VFS.Include("LuaUI/Config/dense_economy.lua")
local queue,prior,hook={},nil,nil
local completed,observed={},{}
local camera
local function log(s) Spring.Echo("[DenseFixture] "..s) end
function widget:Initialize()
    local env=getfenv(0);prior=rawget(env,"RecvSkirmishAIMessage")
    hook=function(team,text)
        if team==0 then
            local unit,x,z,n=text:match("^barb|denseprobe|%d+|%d+|give|([^|]+)|([^|]+)|([^|]+)|(%d+)$")
            if unit then
                local y=Spring.GetGroundHeight(tonumber(x),tonumber(z))
                if not UnitDefNames[unit].canFly and y>=-25 then log("FAIL dry spawn "..unit.." height="..y)
                else queue[#queue+1]="give "..n.." "..unit.." 0 @"..x..","..y..","..z end
            end
            x,z=text:match("^barb|denseprobe|%d+|%d+|camera|([^|]+)|([^|]+)$")
            if x then camera={name="ta",px=tonumber(x),pz=tonumber(z),height=1500};Spring.SetCameraState(camera,0) end
        end
        if prior then return prior(team,text) end
    end
    rawset(env,"RecvSkirmishAIMessage",hook);Script.UpdateCallIn("RecvSkirmishAIMessage")
    log("supplied constructors and resources; physical building and support required")
end
function widget:GameFrame(f)
    if camera and f==10800 then Spring.SetCameraState(camera,0) end
    if camera and f==10830 then Spring.SendCommands("screenshot png") end
    if f==150 then Spring.SendCommands({"cheat 1","globallos"}) end
    if f%15==0 and #queue>0 then Spring.SendCommands(table.remove(queue,1)) end
    if f%300==0 then
        for name,want in pairs(cfg.counts) do
            local ids=completed[name] or {}
            if #ids>=want and not observed[name] then
                local d=UnitDefNames[name]; local touching=0
                for i=1,#ids do for j=i+1,#ids do
                    local x,_,z=Spring.GetUnitPosition(ids[i]);local bx,_,bz=Spring.GetUnitPosition(ids[j])
                    if x and bx then
                        local dx,dz=math.abs(x-bx),math.abs(z-bz)
                        local rotated=(Spring.GetUnitBuildFacing(ids[i]) or 0)%2==1
                        local w,h=(rotated and d.zsize or d.xsize)*8,(rotated and d.xsize or d.zsize)*8
                        if (math.abs(dx-w)<1 and dz<1) or (math.abs(dz-h)<1 and dx<1) then touching=touching+1 end
                    end
                end end
                -- A 3x2 grid has 7 shared edges; a 4x2 bank has 10.
                local expect=want==12 and 16 or want==8 and 10 or 7
                log((touching>=expect and "PASS" or "FAIL").." touching "..name.." count="..#ids.." edges="..touching)
                observed[name]=true
            end
        end
        if cfg.support then
            for _,factory in ipairs(Spring.GetTeamUnits(0)) do
                local d=UnitDefs[Spring.GetUnitDefID(factory)]
                if d.name=="armsy" or d.name=="armamsub" then
                    local x,_,z=Spring.GetUnitPosition(factory);local n,assisting=0,0
                    local product=Spring.GetUnitIsBuilding(factory)
                    for _,id in ipairs(completed.armnanotcplat or {}) do
                        local nx,_,nz=Spring.GetUnitPosition(id)
                        if nx and (nx-x)^2+(nz-z)^2<=400^2 then
                            n=n+1
                            local cmd,_,_,target=Spring.GetUnitCurrentCommand(id)
                            if (cmd==CMD.REPAIR or cmd==CMD.GUARD) and (target==factory or target==product) then assisting=assisting+1 end
                        end
                    end
                    if n>=3 and assisting>0 and product and not observed[d.name] then
                        log("PASS support "..d.name.." turrets="..n.." assisting="..assisting.." product="..product);observed[d.name]=true
                    end
                end
            end
        end
    end
end
function widget:UnitFinished(id,def,team)
    if team~=0 then return end
    local name=UnitDefs[def].name
    local list=completed[name] or {};list[#list+1]=id;completed[name]=list
    local x,_,z=Spring.GetUnitPosition(id)
    log("finished "..name.." id="..id.." x="..x.." z="..z)
end
function widget:Shutdown()
    local env=getfenv(0)
    if rawget(env,"RecvSkirmishAIMessage")==hook then rawset(env,"RecvSkirmishAIMessage",prior);Script.UpdateCallIn("RecvSkirmishAIMessage") end
end
