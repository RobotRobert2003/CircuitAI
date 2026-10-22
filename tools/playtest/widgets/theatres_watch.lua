-- Exercise the control panel's own public button paths; no strategic calculations here.
function widget:GetInfo()
    return {name="Theatres playtest checks",desc="Integrated panel and strategic survey",author="CircuitAI",layer=110,enabled=true}
end
local stage=0
local function click(ui,id)
    local r=ui.ButtonRect(id)
    if not r then Spring.Echo("[TheatresCheck] FAIL missing button " .. id); return end
    local x,y=(r[1]+r[3])/2,(r[2]+r[4])/2
    ui.MousePress(x,y,1); ui.MouseRelease(x,y,1)
end
local function check(ok,name) Spring.Echo("[TheatresCheck] " .. (ok and "PASS " or "FAIL ") .. name) end
function widget:GameFrame(f)
    local ui=WG.barblink; if not ui then return end
    if stage==0 and f>=1100 then
        ui.SetOpen(true); stage=0.5
    elseif stage==0.5 and f>=1140 then
        click(ui,"lanesPlayer"); stage=1
    elseif stage==1 and f>=1200 then
        local s=ui.TheatreSnapshot(0)
        check(s and s.visible and s.lanes==5 and s.ponds==2 and s.seas==2,"selected player")
        check(s and s.yards==2 and s.pondYards==0 and s.tidals==1 and s.planes==1,"pond opportunities")
        check(s and s.geos>0 and s.islands>0 and s.beaches>0,"strategic sites")
        stage=2
    elseif stage==2 and f>=1650 then
        ui.SetRole(1,"AIR"); ui.SetTheatres(1); stage=3
    elseif stage==3 and f>=1700 then
        local a,b=ui.TheatreSnapshot(0),ui.TheatreSnapshot(1)
        check(a and b and not a.visible and b.visible,"switch player")
        local roster=ui.Roster()
        check(roster[1] and roster[1].role=="AIR" and b and b.geos==6,"non-TECH survey")
        click(ui,"lanesTeam"); stage=4
    elseif stage==4 and f>=1900 then
        check(ui.TheatreSnapshot(0).visible and ui.TheatreSnapshot(1).visible==Spring.AreTeamsAllied(0,1),"selected team")
        click(ui,"lanesOff")
        check(not ui.TheatreSnapshot(0).visible and not ui.TheatreSnapshot(1).visible,"hide all")
        ui.SetTheatres(0); stage=5
    elseif stage==5 and f>=5500 then
        check(ui.TheatreSnapshot(0).visible and not ui.TheatreSnapshot(1).visible,"visibility persists")
        ui.SetTheatres(nil); stage=6
    elseif stage==6 and f>=6000 then
        Spring.SendSkirmishAIMessage(0,"barb|theatres|0"); stage=7
    elseif stage==7 and f>=6200 then
        check(not ui.TheatreSnapshot(0).visible,"hidden refresh stays hidden"); stage=8
    end
end
