function widget:GetInfo() return {name="Aggression slider test",layer=130,enabled=true} end
local function log(s) Spring.Echo("[AggressionTest] "..s) end
local screenshot=false
local function check(value)
    local a=WG.barblink
    local got=a.GetAggression(0)
    local other=a.GetAggression(1)
    if not got or math.abs(got-value)>.001 or not other or math.abs(other)>.001 then
        log("ERROR value="..tostring(got).." expected="..value.." other="..tostring(other))
    else log("PASS value="..value.." other="..other) end
end
function widget:GameFrame(f)
    if f<600 then return end
    local a=WG.barblink
    if not a then if f==600 then log("ERROR widget missing") end; return end
    if f==600 then
        a.SetOpen(true)
        Spring.SendSkirmishAIMessage(0,"barb|query|0")
        Spring.SendSkirmishAIMessage(1,"barb|query|1")
    elseif f==660 then check(0); a.SetAggression(0,-1)
    elseif f==690 then check(-1); a.SetAggression(0,-.375)
    elseif f==720 then check(-.375); a.SetAggression(0,1)
    elseif f==750 then
        check(1)
        for _,v in ipairs({"NaN","inf","2","0.6bad"}) do Spring.SendSkirmishAIMessage(0,"barb|aggression|0|"..v) end
        Spring.SendSkirmishAIMessage(0,"barb|aggression|1|-0.8")
        Spring.SendSkirmishAIMessage(0,"barb|aggression|0bad|-0.8")
        Spring.SendSkirmishAIMessage(0,"barb|query|0")
    elseif f==780 then
        check(1)
        local r=a.ButtonRect("aggression")
        if not r then log("ERROR slider missing"); return end
        local y=(r[2]+r[4])/2
        a.MousePress(r[1],y,1)
        a.MouseMove(r[1]+(r[3]-r[1])*.6875,y,0,0,1)
        check(1) -- preview must not emit a command before release
        a.MouseRelease(r[1]+(r[3]-r[1])*.6875,y,1)
    elseif f==810 then check(.375); screenshot=true
    elseif f==840 then
        local r=a.ButtonRect("aggressionReset")
        if not r then log("ERROR reset missing"); return end
        local x,y=(r[1]+r[3])/2,(r[2]+r[4])/2
        a.MousePress(x,y,1); a.MouseRelease(x,y,1)
    elseif f==870 then check(0)
    elseif f==960 then Spring.SendSkirmishAIMessage(0,"barb|query|0")
    elseif f==990 then
        local delta,automatic=a.GetAggression(0)
        if delta~=0 or not automatic or automatic<=0 or automatic>.25 then
            log("ERROR automatic aggression="..tostring(automatic).." delta="..tostring(delta))
        else log("PASS automatic="..automatic.." neutral manual offset"); log("complete") end
    end
end
function widget:DrawScreenPost()
    -- Capturing in GameFrame/early DrawScreen reads the world and blur masks
    -- before the actual HUD. Post preserves the visible slider for review.
    if screenshot then screenshot=false; Spring.SendCommands("screenshot png") end
end
