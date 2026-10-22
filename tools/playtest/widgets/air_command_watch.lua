function widget:GetInfo()
    return {name="AIR command observer",desc="Read-only synchronized order counts",author="CircuitAI",layer=126,enabled=true,handler=true}
end
local previous,hook
local counts,last,moveBursts={},{},{}
local detailConfig=VFS.FileExists("LuaUI/Config/full_match_perf.lua",VFS.RAW_FIRST) and VFS.Include("LuaUI/Config/full_match_perf.lua",nil,VFS.RAW_FIRST) or {}
local jointDetail=detailConfig.command_detail==true
local unitDetail=detailConfig.unit_command_detail==true
local unitCounts={}
local previousTraffic={}
local waitSamples={}
-- Opt-in attribution only: O(1) bookkeeping per command, O(U log U) sorting
-- once per minute, O(U + distinct unit/command pairs) retained in that minute.
-- No position reads, unit scans, commands or cross-frame policy caches.
-- WAIT-removal diagnosis adds one queue read per 64 matching events below.
-- The top ten are a bounded log, not a sample used to compute team totals.
local function recordUnit(id,name,team,cmd,origin,params)
    local members=unitCounts[team]
    if not members then members={};unitCounts[team]=members end
    local row=members[id]
    if not row then row={id=id,name=name,count=0,native=0,lua=0,unknown=0,parameters=0,removeWait=0,byCommand={},frame=-1,burst=0,maxBurst=0};members[id]=row end
    row.count=row.count+1;row[origin]=row[origin]+1
    if origin=="native" then row.parameters=row.parameters+#(params or {}) end
    row.byCommand[cmd]=(row.byCommand[cmd] or 0)+1
    if cmd==CMD.REMOVE and params and #params==1 and params[1]==CMD.WAIT and origin=="native" then
        row.removeWait=row.removeWait+1
        local sample=waitSamples[team]
        if not sample then sample={orders=0,checked=0,absent=0,unavailable=0};waitSamples[team]=sample end
        sample.orders=sample.orders+1
        -- UnitCommand precedes GiveCommandReal. Inspect only every 64th
        -- matching removal, so the trace can establish needless removals
        -- without turning every command into a queue read. Unknown is not empty.
        if sample.orders%64==0 then
            local queue=Spring.GetUnitCommands(id,-1)
            if not queue then sample.unavailable=sample.unavailable+1
            else
                sample.checked=sample.checked+1;local found=false
                for _,command in ipairs(queue) do if command.id==CMD.WAIT then found=true;break end end
                if not found then sample.absent=sample.absent+1 end
            end
        end
    end
    local frame=Spring.GetGameFrame()
    if row.frame~=frame then row.frame=frame;row.burst=0 end
    row.burst=row.burst+1;row.maxBurst=math.max(row.maxBurst,row.burst)
end
local function count(id,def,team,cmd,params,options,tag,player,fromSynced,fromLua)
    local c=counts[team] or {all=0,air=0,repeated=0,byDef={},byCommand={},byOrigin={},joint={}};counts[team]=c;c.all=c.all+1
    local origin=fromLua==true and "lua" or fromLua==false and "nonlua" or "unknown"
    c.byOrigin[origin]=(c.byOrigin[origin] or 0)+1
    local d=UnitDefs[def]
    local name=d and d.name or "unknown"
    if unitDetail then recordUnit(id,name,team,cmd,origin=="nonlua" and "native" or origin,params) end
    c.byDef[name]=(c.byDef[name] or 0)+1
    c.byCommand[cmd]=(c.byCommand[cmd] or 0)+1
    -- Separate attribution run only: marginal definition/command totals do
    -- not prove which hull issued MOVE. Count their joint distribution with
    -- the engine-provided origin, without inspecting or modifying queues.
    if jointDetail then
        local key=name..":"..cmd..":"..origin
        local row=c.joint[key]
        if not row then row={name=name,cmd=cmd,origin=origin,count=0,maxBurst=0};c.joint[key]=row end
        row.count=row.count+1
        if cmd==CMD.MOVE then
            local frame=Spring.GetGameFrame()
            local burst=moveBursts[id]
            if not burst or burst.frame~=frame or burst.team~=team then burst={frame=frame,team=team,origins={}};moveBursts[id]=burst end
            burst.origins[origin]=(burst.origins[origin] or 0)+1
            row.maxBurst=math.max(row.maxBurst,burst.origins[origin])
        end
    end
    if not d or not d.canFly then return end
    c.air=c.air+1
    local signature=tostring(cmd)
    for _,v in ipairs(params or {}) do signature=signature..":"..tostring(v) end
    if last[id]==signature then c.repeated=c.repeated+1 end
    last[id]=signature
    if (d.name=="armpnix" or d.name=="corhurc" or d.name=="legphoenix") and cmd==CMD.ATTACK and params and #params==1 then
        local target=UnitDefs[Spring.GetUnitDefID(params[1]) or -1]
        if target and (target.speed or 0)>0 and not target.canFly and tonumber((target.customParams or {}).techlevel or 1)<2 then
            Spring.Echo("[AirOrders] ERROR t2_bomber_attacks_t1 unit="..id.." target="..params[1].." name="..target.name)
        end
    end
end
function widget:Initialize()
    previous=widgetHandler.UnitCommand
    hook=function(self,...)
        count(...)
        if previous then return previous(self,...) end
    end
    widgetHandler.UnitCommand=hook;widgetHandler:UpdateCallIn("UnitCommand")
    Spring.Echo("[AirOrders] installed")
end
function widget:GameFrame(frame)
    if frame>0 and frame%1800==0 then
        if widgetHandler.UnitCommand~=hook then Spring.Echo("[AirOrders] ERROR observer_replaced") end
        for team,c in pairs(counts) do
            Spring.Echo(string.format("[AirOrders] frame=%d team=%d all_apm=%d air_apm=%d repeated=%d",frame,team,c.all,c.air,c.repeated))
            for name,n in pairs(c.byDef) do
                Spring.Echo(string.format("[AirOrdersDetail] frame=%d team=%d def=%s orders=%d",frame,team,name,n))
            end
            for cmd,n in pairs(c.byCommand) do
                Spring.Echo(string.format("[AirOrdersDetail] frame=%d team=%d cmd=%d orders=%d",frame,team,cmd,n))
            end
            for origin,n in pairs(c.byOrigin) do
                Spring.Echo("[CommandOrigin] frame="..frame.." team_source="..team..":"..origin.." count="..n)
            end
            for _,row in pairs(c.joint) do
                Spring.Echo(string.format("[CommandJoint] frame=%d team=%d def=%s cmd=%d origin=%s orders=%d max_unit_frame_moves=%d",frame,team,row.name,row.cmd,row.origin,row.count,row.maxBurst))
            end
        end
        for team,members in pairs(unitCounts) do
            local rows={};local total,native,lua,unknown,parameters=0,0,0,0,0
            for _,row in pairs(members) do
                rows[#rows+1]=row;total=total+row.count;native=native+row.native;lua=lua+row.lua;unknown=unknown+row.unknown;parameters=parameters+row.parameters
            end
            table.sort(rows,function(a,b) return a.count>b.count or (a.count==b.count and a.id<b.id) end)
            local count=#rows
            Spring.Echo(string.format("[CommandUnits] frame=%d team=%d commanded_units=%d orders=%d nonlua=%d lua=%d unknown=%d nonlua_parameters=%d p50=%d p95=%d max=%d",
                frame,team,count,total,native,lua,unknown,parameters,rows[count-math.ceil(count*.5)+1].count,rows[count-math.ceil(count*.95)+1].count,rows[1].count))
            for index=1,math.min(10,count) do
                local row=rows[index];local dominant,amount=0,-1
                for cmd,value in pairs(row.byCommand) do if value>amount or (value==amount and cmd<dominant) then dominant,amount=cmd,value end end
                Spring.Echo(string.format("[CommandUnit] frame=%d team=%d unit=%d def=%s orders=%d nonlua=%d lua=%d unknown=%d dominant_cmd=%d dominant_orders=%d max_frame_burst=%d remove_wait=%d",
                    frame,team,row.id,row.name,row.count,row.native,row.lua,row.unknown,dominant,amount,row.maxBurst,row.removeWait))
            end
        end
        for team,sample in pairs(waitSamples) do
            Spring.Echo(string.format("[CommandWaitRemoval] frame=%d team=%d orders=%d sampled=%d absent=%d unavailable=%d",
                frame,team,sample.orders,sample.checked,sample.absent,sample.unavailable))
        end
        waitSamples={}
        counts={};unitCounts={}
        if unitDetail and Spring.GetPlayerTraffic then
            -- Received application payload on this AI host, NOT UDP bytes,
            -- bandwidth saturation, loss, RTT or server fan-out. Five O(1)
            -- counters once per game minute; no polling per unit or order.
            local player=Spring.GetMyPlayerID()
            for _,packet in ipairs({14,15,76,50,-1}) do
                local bytes=Spring.GetPlayerTraffic(player,packet)
                if bytes and bytes>=0 then
                    local before=previousTraffic[packet] or 0
                    Spring.Echo(string.format("[CommandTraffic] frame=%d player=%d packet=%d total_bytes=%d interval_bytes=%d reset=%d",
                        frame,player,packet,bytes,math.max(0,bytes-before),bytes<before and 1 or 0))
                    previousTraffic[packet]=bytes
                end
            end
        end
    end
end
function widget:UnitDestroyed(id) last[id]=nil;moveBursts[id]=nil end
function widget:Shutdown()
    if widgetHandler.UnitCommand==hook then widgetHandler.UnitCommand=previous;widgetHandler:UpdateCallIn("UnitCommand") end
end
