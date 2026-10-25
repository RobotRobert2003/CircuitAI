-- BARb team link
--
-- A control window for the allied BARb AIs, opened from a small launcher
-- button beside the player list. The window floats over the map to the left
-- of the player list (it never joins the player list's module stack, so it
-- covers none of the game's own panels), can be dragged by its header, keeps
-- its place between games and is always kept on screen.
--
-- Inside: the allied AIs as a list (colour, name, role, side), the selected
-- AI's details, a role grid that switches the AI's role at runtime, actions
-- (query, query all, the layout overlay) and the event log. Every button has
-- an icon from the game's own art.
--
-- Install: copy into <BAR data dir>/LuaUI/Widgets/ and enable it (F11).
-- Open/close: the launcher, /barblink or Ctrl+Alt+B; Escape closes.
-- Blueprint overlay: player/team controls or /barblayout show the selected team's
-- native reservations: cyan footprints, survey ticks, construction states,
-- factory-facing arrows and crossed orange protected resource footprints.
--
-- Both directions only work on the machine that runs the AIs (the host),
-- playing or spectating:
--   AI -> widget   a state file the AI rewrites a short while after changes (D-300):
--                  <writeDir>/LuaUI/Config/BARb/state/team<N>.txt, polled here once
--                  a second. Each record carries the old "barb|<topic>|<team>|<allyTeam>|<payload>"
--                  line. BAR's user-widget sandbox (BAR PRs #9547/#9658/#9660) no longer
--                  lets a user widget receive RecvSkirmishAIMessage (KI-617).
--   widget -> AI   Spring.SendSkirmishAIMessage(teamId, "barb|<command>|<teamId>|...")
-- Lanes still travel only through ai.CallUI -> RecvSkirmishAIMessage, so they
-- work only on a BAR build that delivers that callin to widgets.
-- Commands carry the target team id and the AI ignores any other; the widget
-- never broadcasts, so hosting two ally teams locally cannot cross-steer them.
-- Wire formats: data/script/src/systems/presentation/widget_link.as and commands.as.
-- Topics shown: roster, role, orphan, donation, ferry, spam, seaassist, layout.
-- Terrain map (D-323, D-326): the "Terrain" row (Show / Legend / Hide) or
-- /barbterrain draws the map analysis one BARb computed at game start and wrote
-- once to <writeDir>/LuaUI/Config/BARb/field/map.txt: the ground class of every
-- cell (deep, water, shallows, flat, rough, steep, cliff, lava), land masses,
-- seas and ponds, regions, crossings and cliffs, shores (beach / steep / sheer),
-- chokes, high ground and summits, geos, islands. Read-only; it asks no AI anything.
-- Landmarks (field-landmarks proposal, section 7): the "Landmarks" rows or /barbmarks
-- draw <writeDir>/LuaUI/Config/BARb/field/landmarks.txt, written once right after
-- map.txt: start positions and territories, landmarks by phase window, and the
-- selected position's opening card. Read-only as well.

function widget:GetInfo()
	return {
		name    = "BARb team link",
		desc    = "Allied BARb AIs: roster, events, runtime role switching, layout overlay, terrain map (host only)",
		author  = "s3k-CircuitAI",
		date    = "2026-09-25",
		layer   = 0,
		enabled = true,
	}
end

local theatres = (function()
local surveys, staging = {}, {}
local PREFIX = "barbtheatre|1|"
local mode = nil
local function groupMode() return mode=="team" or mode=="all" end
local activeTeams = {}
local options = {live=true, routes=true, sites=false, shores=false, cues=true, teaching=true, labels=true, context=true, opacity=0.85, collapsed=false}
local classFilter = {[0]=true,true,true,true,true,true,true}
local selectedLane, selectedTeam, controls, badges = nil,nil,{},{}
local refreshRequested, refreshAction = {}, nil
local dockX,dockY,drag,pressed
local lessonTitles = {[0]="RECON / ADVANCE", "CONTAIN THE CHOKE", "SPECIALIST FLANK", "CONTEST THE SEA", "AIR APPROACH", "PASSAGE / CLIFF DESCENT"}
local lessons = {
    [0]={"Scout the approach before committing your army.","Spread out in open ground; preserve a retreat route."},
    {"Cover the narrow approach with overlapping fire.","Scout both flanks. Do not feed units into a bottleneck."},
    {"This route crosses terrain ordinary bots cannot use.","Scout the exit; bring units that can cross the whole route."},
    {"Sea access can open a second front along the coast.","Protect your shipyard exit and scout for torpedoes."},
    {"Aircraft can bypass terrain, but not enemy anti-air.","Scout AA, choose an approach, then concentrate the strike."},
    {"Follow the high passage to the far-side cliff exit.","Descend with crawlers; scout the landing before committing."},
}
local previous, wrapper, globals
local names = {[0]="LAND", "BOT", "AMPHIBIOUS", "HOVER", "ALL-TERRAIN", "NAVAL", "AIR"}
local colours = {
    [0]={1,0.75,0.30,1}, {1,0.85,0.45,1}, {0.3,0.88,0.68,1}, {0.3,0.88,0.68,1},
    {0.75,0.86,0.40,1}, {0.22,0.76,1,1}, {0.78,0.62,1,1},
}
local mint, muted, ink = {0.35,0.9,0.73,1}, {0.65,0.73,0.8,1}, {0.025,0.045,0.07,0.94}
local occupied = {}
local function freeRect(x,y,w,h)
    for _,r in ipairs(occupied) do
        if x < r[3]+6 and x+w > r[1]-6 and y < r[4]+6 and y+h > r[2]-6 then return false end
    end
    return true
end
local function split(s, delimiter)
    local t = {}
    for v in (s .. delimiter):gmatch("(.-)" .. delimiter) do t[#t+1] = v end
    return t
end
local function numbers(s)
    local t = {}
    for v in s:gmatch("[^,]+") do
        local n = tonumber(v)
        if not n or n ~= n or math.abs(n) > 1e12 then return nil end
        t[#t+1] = n
    end
    return t
end
local function permitted(team)
    local spec = Spring.GetSpectatingState()
    return spec or Spring.AreTeamsAllied(team, Spring.GetMyTeamID())
end
local function receive(team, msg)
    if type(msg) ~= "string" or msg:sub(1,#PREFIX) ~= PREFIX then return nil end
    local f = split(msg,"|")
    if #f < 5 or tonumber(f[3]) ~= team or not permitted(team) then return nil end
    local topic = f[4]
    if topic == "remove" then surveys[team],staging[team]=nil,nil; return "theatre-v1" end
    if topic == "begin" then
        local n = numbers(f[5]); if not n or #n ~= 2 then return nil end
        staging[team] = {lanes={}, bodies={}, geos={}, islands={}, beaches={}, seconds=math.max(1,math.min(120,n[1])), tidal=n[2]}
        return "theatre-v1"
    end
    if topic == "hide" then
        if surveys[team] then surveys[team].untilFrame = 0 end
        return "theatre-v1"
    end
    local s = staging[team]
    if not s then return nil end
    if topic == "lane" and f[6] then
        local n = numbers(f[5]); if not n or #n ~= 2 or not names[n[2]] then return nil end
        local pts = {}
        for row in f[6]:gmatch("[^;]+") do
            local p = numbers(row); if p and #p == 2 then pts[#pts+1] = p end
        end
        s.lanes[#s.lanes+1] = {id=n[1], class=n[2], points=pts}
    elseif topic == "body" then
        local n = numbers(f[5]); if not n or #n ~= 14 then return nil end
        s.bodies[n[1]] = {id=n[1], pond=n[2]==1, shared=n[3]==1, friendly=n[4]==1,
            x=n[5], z=n[6], area=n[7], yard={n[8],n[9]}, tidal={n[10],n[11]}, plane={n[12],n[13]}, facing=n[14], shore={}}
    elseif topic == "laneinfo" then
        local n=numbers(f[5])
        if not n or #n~=11 then return nil end
        for _,l in ipairs(s.lanes) do if l.id==n[1] then
            l.length,l.width,l.threat,l.front,l.mask=n[2],n[3],n[4],n[5],n[6]
            l.lesson,l.anchor,l.calcFrame,l.revision=n[7],{n[8],n[9]},n[10],n[11]
        end end
    elseif topic == "cliffinfo" then
        local n=numbers(f[5]); if not n or #n~=5 then return nil end
        for _,l in ipairs(s.lanes) do if l.id==n[1] then l.ascent={n[2],n[3]}; l.cliffQuality={n[4],n[5]} end end
    elseif topic == "shore" and f[6] then
        local b = s.bodies[tonumber(f[5])]; if not b then return nil end
        for row in f[6]:gmatch("[^;]+") do
            local p = numbers(row); if p and #p==4 then b.shore[#b.shore+1]=p end
        end
    elseif topic == "geo" then
        local n=numbers(f[5]); if n and #n==6 then s.geos[#s.geos+1]=n end
    elseif topic == "island" then
        local n=numbers(f[5]); if n and #n==5 then s.islands[#s.islands+1]=n end
    elseif topic == "beach" and f[6] then
        local n=numbers(f[5]); if not n or #n~=2 then return nil end
        local b={use=n[2],edges={}}
        for row in f[6]:gmatch("[^;]+") do local e=numbers(row); if e and #e==6 then b.edges[#b.edges+1]=e end end
        s.beaches[#s.beaches+1]=b
    elseif topic == "show" or topic == "refresh" then
        s.frame = Spring.GetGameFrame()
        s.untilFrame = topic=="show" and (Spring.GetGameFrame()+s.seconds*30) or (surveys[team] and surveys[team].untilFrame or 0)
        if options.live or not surveys[team] or refreshRequested[team] then surveys[team]=s end
        staging[team],refreshRequested[team] = nil,nil
        Spring.Echo("[TheatresUI] received " .. #s.lanes .. " lanes for team " .. team)
    end
    return "theatre-v1"
end

local function setMode(value, teams)
    if value~=mode then selectedLane,selectedTeam=nil,nil end
    mode=value
    activeTeams={}
    if value=="all" or value=="team" then
        for _,id in ipairs(teams or Spring.GetTeamList()) do if permitted(id) then activeTeams[id]=true end end
    elseif type(value)=="number" and permitted(value) then activeTeams[value]=true end
end
local function snapshot(team)
    local s=surveys[team]; if not s or not permitted(team) then return nil end
    local r={lanes=#s.lanes,ponds=0,seas=0,yards=0,pondYards=0,tidals=0,planes=0,
        geos=#s.geos,islands=#s.islands,beaches=#s.beaches,visible=activeTeams[team]==true,frame=s.frame,
        live=options.live,classes={},details={}}
    for _,l in ipairs(s.lanes) do
        r.classes[l.class]=(r.classes[l.class] or 0)+1
        r.details[#r.details+1]={id=l.id,class=l.class,mask=l.mask,lesson=l.lesson,anchor=l.anchor,ascent=l.ascent,cliffQuality=l.cliffQuality,revision=l.revision,calcFrame=l.calcFrame,threat=l.threat,points=l.points}
    end
    for _,l in ipairs(s.lanes) do if l.class==6 and l.points[1] then r.airOrigin={l.points[1][1],l.points[1][2]}; break end end
    for _,b in pairs(s.bodies) do
        if b.pond then r.ponds=r.ponds+1 else r.seas=r.seas+1 end
        if b.yard[1]>=0 then r.yards=r.yards+1; if b.pond then r.pondYards=r.pondYards+1 end end
        if b.tidal[1]>=0 then r.tidals=r.tidals+1 end
        if b.plane[1]>=0 then r.planes=r.planes+1 end
    end
    return r
end

local function project(x,z)
    if x < 0 or z < 0 or x > Game.mapSizeX or z > Game.mapSizeZ then return nil end
    -- Screen-space rendering deliberately floats above the water, never on the seabed.
    local sx,sy,sz = Spring.WorldToScreenCoords(x,math.max(0,Spring.GetGroundHeight(x,z))+12,z)
    if not sx or not sz or sz < 0 or sz > 1 then return nil end
    return sx,sy
end
local function lineVertices(x,y,a,b)
    gl.Vertex(x,y); gl.Vertex(a,b)
end
local function line(x,y,a,b,width,c)
    gl.Color(c[1],c[2],c[3],(c[4] or 1)*options.opacity); gl.LineWidth(width)
    gl.BeginEnd(GL.LINES,lineVertices,x,y,a,b)
end
-- One reusable projection buffer for all lanes, and two batches per
-- route. Per-segment closures/tables can allocate tens of MB each DrawScreen
-- with all players visible; the engine deliberately stops automatic Lua GC.
local routeContextInk = {0.025,0.045,0.07,0.2}
local routeScreen = {}
local function routeVertices(screen,count,cls)
    for i=2,count do
        local a,b=(i-2)*2+1,(i-1)*2+1
        if screen[a] and screen[b] and not (cls==6 and i%6>=3) then
            gl.Vertex(screen[a],screen[a+1]); gl.Vertex(screen[b],screen[b+1])
        end
    end
end
local function path(points,x,y,size,c,width)
    gl.Color(c); gl.LineWidth(width or 1.7)
    gl.BeginEnd(GL.LINE_STRIP,function()
        for i=1,#points,2 do gl.Vertex(x+points[i]*size,y+points[i+1]*size) end
    end)
end
local function disk(x,y,r,c)
    gl.Color(c)
    gl.BeginEnd(GL.TRIANGLE_FAN,function()
        gl.Vertex(x,y)
        for i=0,32 do local a=i*math.pi/16; gl.Vertex(x+math.cos(a)*r,y+math.sin(a)*r) end
    end)
end
local function ring(x,y,r,c)
    gl.Color(c); gl.LineWidth(1.4)
    gl.BeginEnd(GL.LINE_LOOP,function()
        for i=0,31 do local a=i*math.pi/16; gl.Vertex(x+math.cos(a)*r,y+math.sin(a)*r) end
    end)
end
local function icon(kind,x,y,c)
    disk(x,y,17,ink); ring(x,y,17,c)
    if kind=="yard" then
        path({-10,-7,-10,7,-3,7,-3,0,3,0,3,7,10,7,10,-7},x,y,1,c)
        path({-12,-10,12,-10},x,y,1,c)
        path({-4,-5,0,-8,4,-5},x,y,1,c)
    elseif kind=="tidal" then
        path({2,11,-4,2,2,2,-2,-7,6,3,1,3},x,y,1,c)
        path({-10,-10,-5,-8,0,-10,5,-8,10,-10},x,y,1,c)
    elseif kind=="plane" or kind=="air" then
        path({0,-10,0,11,-2,4,-11,-2,-11,-4,-2,-1,-2,-7,-6,-10,0,-8,6,-10,2,-7,2,-1,11,-4,11,-2,2,4,0,11},x,y,1,c)
        if kind=="plane" then path({-11,-13,-6,-11,0,-13,6,-11,11,-13},x,y,1,c) end
    elseif kind=="naval" then
        ring(x,y+8,3,c)
        path({0,5,0,-10,-6,-7,-10,-2,-6,-4},x,y,1,c)
        path({0,-10,6,-7,10,-2,6,-4},x,y,1,c)
        path({-7,2,7,2},x,y,1,c)
    else
        path({-10,-7,10,-7,10,6,-10,6,-10,-7},x,y,1,c)
        path({-5,-3,5,-3,5,3,-5,3,-5,-3},x,y,1,c)
        path({0,3,0,12},x,y,1,c)
    end
end
local function label(x,y,title,subtitle,c)
    local w = math.max(gl.GetTextWidth(title)*13,gl.GetTextWidth(subtitle or "")*10)+20
    local ox,oy=x,y
    local vw,vh=gl.GetViewSizes()
    local choices={{0,0},{0,48},{0,-48},{-w-48,0},{0,96},{-w-48,48},{-w-48,-48},{0,-96},{-w-48,96},{0,144}}
    for _,o in ipairs(choices) do
        local cx=math.max(12,math.min(vw-w-12,ox+o[1]))
        local cy=math.max(44,math.min(vh-145,oy+o[2]))
        if freeRect(cx,cy-30,w,39) then x,y=cx,cy; break end
    end
    occupied[#occupied+1]={x,y-30,x+w,y+9}
    if x~=ox or y~=oy then line(ox-7,oy-8,x+2,y-8,1,c) end
    gl.Color(ink); gl.Rect(x,y-30,x+w,y+9)
    gl.Color(c); gl.Rect(x,y-30,x+2,y+9)
    gl.Text(title,x+10,y-5,13,"o")
    gl.Color(0.82,0.88,0.94,1); gl.Text(subtitle or "",x+10,y-21,10,"o")
end
local function marker(p,kind,title,detail,c,offset)
    if p[1]<0 then return end
    local x,y=project(p[1],p[2]); if not x then return end
    if not options.labels then icon(kind,x,y,c); return end
    local vw,vh=gl.GetViewSizes()
    local w=math.max(gl.GetTextWidth(title)*13,gl.GetTextWidth(detail)*10)+20
    local ox,oy = math.max(25,math.min(vw-w-45,x+38)),math.max(150,math.min(vh-160,y+(offset or 0)))
    local baseY=oy
    for _,dy in ipairs({0,54,-54,108,-108,162,-162}) do
        local cy=math.max(150,math.min(vh-160,baseY+dy))
        if freeRect(ox-18,cy-23,w+43,42) then oy=cy; break end
    end
    line(x,y,ox-18,oy,2,ink); line(x,y,ox-18,oy,1,c)
    ring(x,y,4,c); icon(kind,ox,oy,c); label(ox+23,oy+8,title,detail,c)
    occupied[#occupied+1]={ox-18,oy-18,ox+18,oy+18}
end

local function drawSurvey(team,s,first,index,count)
    local shift=groupMode() and (index-(count+1)/2)*12 or 0
    local tr,tg,tb=Spring.GetTeamColor(team)
    local teamColour={tr,tg,tb,1}
    -- Geometry, classifications and extents arrive from the AI.
    for _,b in pairs(options.shores and s.bodies or {}) do
        local c=b.pond and (b.friendly and mint or muted) or colours[5]
        gl.Color(c[1],c[2],c[3],0.42); gl.LineWidth(1.2)
        gl.BeginEnd(GL.LINES,function()
            for _,e in ipairs(b.shore) do
                local x,y=project(e[1],e[2]); local a,d=project(e[3],e[4])
                if x and a then gl.Vertex(x,y); gl.Vertex(a,d) end
            end
        end)
    end
    local ordered={}
    for _,l in ipairs(s.lanes) do if not (team==selectedTeam and l.id==selectedLane) then ordered[#ordered+1]=l end end
    for _,l in ipairs(s.lanes) do if team==selectedTeam and l.id==selectedLane then ordered[#ordered+1]=l end end
    for _,l in ipairs(options.routes and ordered or {}) do
      if classFilter[l.class] and (options.context or (selectedTeam==team and selectedLane==l.id)) then
        local chosen=selectedTeam==team and selectedLane==l.id
        local base=colours[l.class]
        local c={base[1],base[2],base[3],chosen and 1 or 0.25}
        -- Shared scratch storage is consumed immediately; it never retains
        -- old surveys or grows with the number of teams/frames.
        local screen=routeScreen
        local count=#l.points
        for i,p in ipairs(l.points) do
            local x,y=project(p[1],p[2]); screen[i*2-1],screen[i*2]=x or false,y or false
        end
        local border=chosen and ink or routeContextInk
        gl.Color(border[1],border[2],border[3],border[4]*options.opacity); gl.LineWidth(chosen and 6 or 2)
        gl.BeginEnd(GL.LINES,routeVertices,screen,count,l.class)
        gl.Color(c[1],c[2],c[3],c[4]*options.opacity); gl.LineWidth(chosen and 3 or 1.5)
        gl.BeginEnd(GL.LINES,routeVertices,screen,count,l.class)
        -- Small directional chevrons instead of oversized repeated unit silhouettes.
        for i=14,count-1,24 do
            local a,b=(i-1)*2+1,i*2+1
            if screen[a] and screen[b] then
                local x,y=screen[a],screen[a+1]
                local dx,dy=screen[b]-x,screen[b+1]-y; local d=math.sqrt(dx*dx+dy*dy)
                if d>0.1 then
                    dx,dy=dx/d,dy/d
                    line(x-dx*7-dy*4,y-dy*7+dx*4,x,y,2,c)
                    line(x-dx*7+dy*4,y-dy*7-dx*4,x,y,2,c)
                end
            end
        end
        local p=(math.max(1,math.floor(count*(l.id%2==0 and 0.62 or 0.38)))-1)*2+1
        if count>0 and screen[p] and options.labels then
            local x,y=screen[p],screen[p+1]
            if chosen or freeRect(x-22,y-12,44,24) then
                gl.Color(ink); gl.Rect(x-22,y-12,x+22,y+12)
                gl.Color(base); gl.Text("P"..team.." / "..l.id,x,y-4,11,"oc")
                badges[#badges+1]={x-22,y-12,x+22,y+12,team=team,lane=l.id}
                occupied[#occupied+1]={x-22,y-12,x+22,y+12}
            end
        end
        if chosen and options.cues and l.anchor then
          for cueIndex,cueAnchor in ipairs(l.ascent and {l.anchor,l.ascent} or {l.anchor}) do
            local x,y=project(cueAnchor[1],cueAnchor[2])
            -- Orient the symbol along the published route at its actual anchor.
            -- The route midpoint can face a different direction from a cliff exit.
            local nearest,bestDistance=1,math.huge
            for i,p in ipairs(l.points) do
                local distance=(p[1]-cueAnchor[1])^2+(p[2]-cueAnchor[2])^2
                if distance<bestDistance then nearest,bestDistance=i,distance end
            end
            local before=l.points[math.max(1,nearest-2)]
            local after=l.points[math.min(#l.points,nearest+2)]
            if x and before and after then
                local a,b=project(before[1],before[2]); local d,e=project(after[1],after[2])
                if a and d then
                    local dx,dy=d-a,e-b; local len=math.sqrt(dx*dx+dy*dy)
                    if len>1 then
                        dx,dy=dx/len,dy/len
                        local c=base
                        if l.lesson==1 then
                            -- Battle-position bracket faces the enemy avenue of approach.
                            line(x-dy*27,y+dx*27,x+dy*27,y-dx*27,5,ink)
                            line(x-dy*27,y+dx*27,x+dy*27,y-dx*27,3,mint)
                            for _,side in ipairs({-1,1}) do
                                local px,py=x+dy*27*side,y-dx*27*side
                                line(px,py,px+dx*13,py+dy*13,3,mint)
                            end
                        else
                            -- Open axis-of-advance arrow: an opportunity, not an order.
                            for _,side in ipairs({-1,1}) do
                                line(x-dx*35+dy*7*side,y-dy*35-dx*7*side,x+dy*7*side,y-dx*7*side,3,c)
                                line(x-dx*8+dy*19*side,y-dy*8-dx*19*side,x+dx*20,y+dy*20,3,c)
                            end
                        end
                        if options.teaching then label(x+32,y+32,cueIndex==2 and "STEEP CLIFF / WALKERS" or (lessonTitles[l.lesson] or "SCOUT"),names[l.class].." / terrain opportunity",c) end
                    end
                end
            end
          end
        end
        if chosen and options.cues and l.front and l.front>=0 then
            local p=l.points[math.min(#l.points,1+math.floor(l.front*(#l.points-1)))]
            local x,y=project(p[1],p[2]); if x then
                path({0,13,13,0,0,-13,-13,0,0,13},x,y,1,{1,0.4,0.3,1},2)
                if options.labels then label(x+20,y+12,"OBSERVED THREAT","Scout before crossing",{1,0.4,0.3,1}) end
            end
        end
      end
    end
    for _,b in pairs(options.sites and s.bodies or {}) do
        local x,y=project(b.x,b.z)
        if x and first and options.labels then
            local c=b.pond and (b.friendly and mint or muted) or colours[5]
            local title=(b.pond and "POND " or "SEA ") .. (b.id+1)
            local detail=b.shared and "shared naval theatre" or (groupMode() and "isolated water" or (b.friendly and "friendly rear water" or "enemy / neutral water"))
            if b.pond then detail=detail .. " / no navy" end
            label(x-60,y+35,title,detail,c)
        end
        marker(b.yard,"yard","SHIPYARD","player " .. team .. " / clear exit",colours[5],-38)
        marker(b.tidal,"tidal","TIDAL",s.tidal .. " E/s / candidate",mint,-38)
        marker(b.plane,"plane","SEAPLANES","player " .. team .. " / platform",mint,35)
    end

    for _,g in ipairs(options.sites and s.geos or {}) do
        local x,y=project(g[2],g[3])
        if x and (not groupMode() or first) then
            local c=groupMode() and {1,0.83,0.4,1} or (g[4]==1 and {1,0.62,0.3,1} or mint)
            disk(x,y,12,ink)
            path({0,11,10,0,0,-11,-10,0,0,11},x,y,1,c,2)
            gl.Color(c); gl.Text(mode=="all" and "G" or (g[4]==1 and "+" or "~"),x,y-4,13,"oc")
            if options.labels then gl.Text(groupMode() and "GEO" or (g[5] .. "%"),x,y-24,10,"oc") end
            local mx,my=Spring.GetMouseState()
            if (mx-x)^2+(my-y)^2<500 then
                -- Group duplicate map positions for presentation, preserving every AI's assessment.
                local rows={}
                for id in pairs(activeTeams) do
                    local other=surveys[id]
                    if other and permitted(id) then
                        for _,item in ipairs(other.geos) do
                            if item[2]==g[2] and item[3]==g[3] then
                                rows[#rows+1]={id=id,use=item[4],coverage=item[5],friendly=item[6]}
                            end
                        end
                    end
                end
                table.sort(rows,function(a,b) return a.id<b.id end)
                local vw,vh=gl.GetViewSizes()
                local h=38+#rows*19
                local tx,ty=math.max(12,math.min(vw-350,x+20)),math.max(h+12,math.min(vh-40,y+20))
                gl.Color(ink); gl.Rect(tx,ty-h,tx+335,ty)
                gl.Color(1,0.9,0.65,1); gl.Text("GEOTHERMAL / FORWARD TERRAIN VIEW",tx+10,ty-19,12,"o")
                for n,row in ipairs(rows) do
                    gl.Color(row.use==1 and {1,0.62,0.3,1} or mint)
                    gl.Text("P" .. row.id .. "  " .. (row.use==1 and "BATTERY" or "POWER") .. "  " .. row.coverage .. "%" .. (row.friendly==1 and "  friendly" or "  capture / contested"),tx+10,ty-20-n*19,11,"o")
                end
            end
        end
    end
    if first and options.sites then
        for _,p in ipairs(s.islands) do
            local x,y=project(p[2],p[3]); if x then
                path({0,7,7,0,0,-7,-7,0,0,7},x,y,1,colours[6],1.5)
                local mx,my=Spring.GetMouseState()
                if (mx-x)^2+(my-y)^2<350 then label(x+14,y+8,"ISLAND / AIR FIRST","isolated land / sea landing later",colours[6]) end
            end
        end
    end
    for _,b in ipairs(options.cues and options.shores and s.beaches or {}) do
        local c=groupMode() and teamColour or (b.use==0 and mint or {1,0.48,0.32,1})
        for i,e in ipairs(b.edges) do
            local x,y=project(e[1],e[2]); local a,d=project(e[3],e[4])
            if x and a then
                y,d=y+shift,d+shift
                line(x,y,a,d,5,ink); line(x,y,a,d,2.4,c)
                -- Same continuous shoreline ribbon; bars defend, teeth point inland to assault.
                if i%3==1 then
                    local mx,mz=(e[1]+e[3])/2,(e[2]+e[4])/2
                    local sx,sy=project(mx,mz); local tx,ty=project(mx+e[5]*110,mz+e[6]*110)
                    if sx and tx then
                        sy,ty=sy+shift,ty+shift
                        local dx,dy=tx-sx,ty-sy; local len=math.sqrt(dx*dx+dy*dy)
                        if len>0 then
                            dx,dy=dx/len,dy/len
                            if b.use==0 then line(sx-dx*4,sy-dy*4,sx+dx*7,sy+dy*7,2,c)
                            else
                                line(sx-dy*4,sy+dx*4,sx+dx*8,sy+dy*8,2,c)
                                line(sx+dy*4,sy-dx*4,sx+dx*8,sy+dy*8,2,c)
                            end
                        end
                    end
                end
            end
        end
    end
end
local function button(id,x,y,w,title,on,action)
    gl.Color(on and {0.12,0.30,0.34,0.98} or {0.09,0.13,0.18,0.98}); gl.Rect(x,y,x+w,y+26)
    gl.Color(on and mint or {0.83,0.87,0.93,1}); gl.Text(title,x+w/2,y+8,11,"oc")
    controls[#controls+1]={x,y,x+w,y+26,id=id,action=action}
end
local function config(data)
    if type(data)~="table" then return end
    for k,v in pairs(options) do if type(v)=="boolean" and type(data[k])=="boolean" then options[k]=data[k] end end
    if type(data.opacity)=="number" then options.opacity=math.max(0.25,math.min(1,data.opacity)) end
    if type(data.x)=="number" and type(data.y)=="number" then dockX,dockY=data.x,data.y end
    if type(data.classes)=="table" then for k=0,6 do if type(data.classes[k])=="boolean" then classFilter[k]=data.classes[k] end end end
end
local function getConfig()
    local result={}; for k,v in pairs(options) do result[k]=v end
    result.x,result.y=dockX,dockY; result.classes={}
    for k=0,6 do result.classes[k]=classFilter[k] end
    return result
end
local function draw(panel)
    controls,badges={},{}
    if not mode or Spring.IsGUIHidden() then return end
    local vw,vh=gl.GetViewSizes()
    local w,h=420,options.collapsed and 38 or 550
    dockX=math.max(8,math.min(vw-w-8,dockX or vw-w-22))
    dockY=math.max(h+8,math.min(vh-65,dockY or vh-80))
    local x,top=dockX,dockY
    occupied={{x,top-h,x+w,top},{0,vh-350,350,vh},{vw-440,0,vw,210}}
    if panel then occupied[#occupied+1]={panel.x1,panel.y1,panel.x2,panel.y2} end
    local ids,rows={},{}
    for id in pairs(activeTeams) do if permitted(id) and surveys[id] then ids[#ids+1]=id end end
    table.sort(ids)
    for _,id in ipairs(ids) do for _,l in ipairs(surveys[id].lanes) do
        if classFilter[l.class] then rows[#rows+1]={team=id,lane=l} end
    end end
    local selected,selectedIndex=nil,1
    for i,r in ipairs(rows) do if r.team==selectedTeam and r.lane.id==selectedLane then selected,selectedIndex=r,i end end
    if not selected and rows[1] then selected=rows[1]; selectedTeam,selectedLane=selected.team,selected.lane.id end
    for i,id in ipairs(ids) do if id~=selectedTeam then drawSurvey(id,surveys[id],i==1,i,#ids) end end
    for i,id in ipairs(ids) do if id==selectedTeam then drawSurvey(id,surveys[id],i==1,i,#ids) end end
    gl.Color(0.025,0.04,0.06,0.97); gl.Rect(x,top-h,x+w,top)
    gl.Color(mint); gl.Rect(x,top-3,x+w,top)
    gl.Color(0.93,0.96,1,1); gl.Text("BATTLEFIELD GUIDE",x+14,top-25,15,"o")
    controls[#controls+1]={x,top-36,x+w-100,top,id="guideDrag",action=function() end}
    button("guideCollapse",x+w-98,top-31,42,options.collapsed and "+" or "-",false,function() options.collapsed=not options.collapsed end)
    button("guideHide",x+w-50,top-31,42,"Hide",false,function() setMode(nil) end)
    if options.collapsed then return end
    local y=top-58
    gl.Color(muted); gl.Text((mode=="team" and "TEAM" or (mode=="all" and "ALL PLAYERS" or "PLAYER "..mode)).."  /  "..(options.live and "LIVE" or "FROZEN VIEW"),x+14,y,11,"o")
    y=y-36
    button("guideLive",x+12,y,124,options.live and "Live updates: ON" or "Live updates: OFF",options.live,function() options.live=not options.live end)
    button("guideRefresh",x+144,y,124,"Refresh now",false,function() if refreshAction then refreshAction() end end)
    button("guideTeach",x+276,y,132,"Teaching: "..(options.teaching and "ON" or "OFF"),options.teaching,function() options.teaching=not options.teaching end)
    y=y-33
    for i,k in ipairs({"routes","sites","shores","cues"}) do
        local key=k
        button("guide_"..key,x+12+(i-1)*99,y,93,key:sub(1,1):upper()..key:sub(2)..(options[key] and " +" or " -"),options[key],function() options[key]=not options[key] end)
    end
    y=y-32
    for i,k in ipairs({"labels","context","opacity","reset"}) do
        local key=k
        local title=key=="labels" and (options.labels and "Labels: ON" or "Labels: OFF") or (key=="context" and (options.context and "Context: ON" or "Focus only") or (key=="opacity" and ("Ink: "..math.floor(options.opacity*100).."%") or "Reset view"))
        button("guide_"..key,x+12+(i-1)*99,y,93,title,false,function()
            if key=="labels" then options.labels=not options.labels
            elseif key=="context" then options.context=not options.context
            elseif key=="opacity" then options.opacity=options.opacity>0.8 and 0.55 or (options.opacity>0.5 and 0.3 or 0.85)
            else config({live=true,routes=true,sites=false,shores=false,cues=true,teaching=true,labels=true,context=true,opacity=0.85}); for c=0,6 do classFilter[c]=true end; dockX,dockY=nil,nil end
        end)
    end
    y=y-27
    gl.Color(muted); gl.Text("ROUTE TYPES  /  click to filter",x+14,y,10,"o")
    y=y-31
    local short={[0]="Land","Bot","Amph","Hover","Cliff","Sea","Air"}
    for c=0,6 do local cls=c
        button("guideClass"..c,x+12+c*57,y,53,short[c],classFilter[c],function() classFilter[cls]=not classFilter[cls] end)
    end
    y=y-35
    button("guidePrev",x+12,y,32,"<",false,function()
        local r=rows[(selectedIndex-2)%math.max(1,#rows)+1]; if r then selectedTeam,selectedLane=r.team,r.lane.id end
    end)
    button("guideNext",x+w-44,y,32,">",false,function()
        local r=rows[selectedIndex%math.max(1,#rows)+1]; if r then selectedTeam,selectedLane=r.team,r.lane.id end
    end)
    if selected then
        local l=selected.lane; local c=colours[l.class]
        gl.Color(c); gl.Text(names[l.class].."  /  P"..selected.team.." ROUTE "..l.id,x+54,y+8,13,"o")
        y=y-23
        gl.Color(muted); gl.Text(selectedIndex.." of "..#rows.." routes  /  select a map badge or use arrows",x+14,y,10,"o")
        y=y-24
        gl.Color(0.9,0.94,1,1); gl.Text((l.length or 0).." elmos   /   "..(l.width and l.width>0 and ("narrowest ~"..l.width) or "no ground choke"),x+14,y,12,"o")
        y=y-21
        local age=math.max(0,math.floor((Spring.GetGameFrame()-(l.calcFrame or surveys[selected.team].frame))/30))
        local threat=l.threat and l.threat>1 and ("Reported "..(l.class==6 and "AA" or "surface").." threat: "..string.format("%.1f",l.threat)) or "No reported threat - this does not mean safe"
        gl.Color(l.threat and l.threat>1 and {1,0.55,0.35,1} or muted); gl.Text(threat,x+14,y,11,"o")
        y=y-21
        gl.Color(muted); gl.Text("Survey "..age.."s ago / rev "..(l.revision or "?").." / AI sight + profile weights",x+14,y,11,"o")
        y=y-21
        local capable={}
        for cls=0,6 do if l.mask and math.floor(l.mask/2^cls)%2==1 then capable[#capable+1]=short[cls] end end
        gl.Color(muted); gl.Text("Terrain fits: "..table.concat(capable," / "),x+14,y,10,"o")
        if options.teaching then
            y=y-28
            gl.Color(mint); gl.Text(lessonTitles[l.lesson or 0],x+14,y,13,"o")
            local teaching=l.ascent and {"Use steep walker-only cliffs at both ends of the passage.","Scout both landings before committing walkers."} or (lessons[l.lesson or 0] or lessons[0])
            for _,txt in ipairs(teaching) do y=y-20; gl.Color(0.91,0.93,0.96,1); gl.Text(txt,x+14,y,11,"o") end
        end
    else
        gl.Color(muted); gl.Text(#ids==0 and "Waiting for an AI survey..." or "No routes match these filters",x+56,y+8,12,"o")
    end
    gl.Color(muted); gl.Text("Arrows: approach   Brackets: contain   Diamonds: observed threat",x+14,top-h+30,10,"o")
    gl.Text("Terrain estimate, not orders. Sites are candidates. Drag header to move.",x+14,top-h+13,10,"o")
    gl.LineWidth(1); gl.Color(1,1,1,1)
end
local function hitAt(x,y)
    for i=#controls,1,-1 do local r=controls[i]; if x>=r[1] and y>=r[2] and x<=r[3] and y<=r[4] then return r end end
    for _,r in ipairs(badges) do if x>=r[1] and y>=r[2] and x<=r[3] and y<=r[4] then return r end end
end
local function mousePress(x,y,b)
    if not mode or Spring.IsGUIHidden() then return false end
    local r=hitAt(x,y)
    if r then
        if b==1 then pressed=r; if r.id=="guideDrag" then drag={x,y,dockX,dockY} end end
        return true
    end
    return dockX and x>=dockX and x<=dockX+420 and y<=dockY and y>=dockY-(options.collapsed and 38 or 550) or false
end
local function mouseRelease(x,y,b)
    local was=pressed~=nil
    if drag then drag=nil
    elseif pressed and b==1 then
        local r=hitAt(x,y)
        if r and r.id==pressed.id and r.team==pressed.team and r.lane==pressed.lane then
            if r.action then r.action() else selectedTeam,selectedLane=r.team,r.lane end
        end
    end
    pressed=nil; return was
end
return {Receive=receive,Draw=draw,SetMode=setMode,Mode=function() return mode end,Snapshot=snapshot,
    ShowsTeam=function(team) return activeTeams[team]==true and permitted(team) end,
    Config=config,GetConfig=getConfig,Live=function() return options.live end,
    SetRefresh=function(fn) refreshAction=fn end,Requested=function(id) refreshRequested[id]=true end,
    Select=function(team,lane) selectedTeam,selectedLane=team,lane end,
    ButtonRect=function(id) for _,r in ipairs(controls) do if r.id==id then return {r[1],r[2],r[3],r[4]} end end end,
    MousePress=mousePress,MouseRelease=mouseRelease,
    MouseMove=function(x,y) if drag then dockX=drag[3]+x-drag[1]; dockY=drag[4]+y-drag[2]; return true end end}
end)()

-- ---------------------------------------------------------------- field
-- The battlefield map analysis (D-323): one file per game written once by the
-- BARb AI that ran the analysis, LuaUI/Config/BARb/field/map.txt, drawn here as
-- a terrain map (D-326): ground classes, coastlines, crossings, cliffs, summits.
-- The widget asks no AI for anything: it reads the
-- file when the view is turned on, parses it once (spread over Update calls),
-- compiles bounded display-list batches and never reads again. Explicit widget
-- settings choose Terrain, Approaches or Positions; camera/selection do not.
-- Patterns and shapes supplement colour. Physical lines never fall back to
-- watershed partition lines. Partitions are explicit diagnostic data only.
-- Grammar: projects/circuitai/battlefield-analysis-implementation.md, 6.4.
local field = (function()
local PATH = "LuaUI/Config/BARb/field/map.txt"
local LAYERS = {"ground","theatres","regions","crossings","barriers","shores","chokes","key","labels"}
local options = {legend=false}
local layers = {}
for _,k in ipairs(LAYERS) do layers[k]=true end
local on = false                 -- the view is shown
local model = nil                -- parsed records
local lists = {}                 -- layer -> display list id
local labelsAll = {}             -- {x,y,z,text,size,minH,maxH,r,g,b}
local status = "Terrain map hidden"
local parse = nil                -- incremental parse state
local parseJob = nil             -- permits yielding inside long RLE records
local lastExists = nil           -- wall timer of the last VFS.FileExists check
local groundOff = false          -- Spring.SetDrawGround(false) is in effect
local focus = nil                -- {kind, id} focused record
local focusList = nil
local hover = nil                -- inspector text lines
local hoverTimer = nil
local controls = {}              -- legend panel hit regions {x1,y1,x2,y2,id=,action=}
local legendRect = nil           -- the panel's screen box as last drawn: clicks inside never reach the game
local dockX, dockY, drag, pressed
local seq = nil

-- Okabe-Ito, colour-blind safe. Every colour difference is repeated by a line style.
local K = {
    white  = {1,1,1},
    grey   = {0.72,0.72,0.74},
    orange = {0.90,0.62,0.00},
    sky    = {0.34,0.71,0.91},
    green  = {0.00,0.62,0.45},
    yellow = {0.94,0.89,0.26},
    blue   = {0.00,0.45,0.70},
    verm   = {0.84,0.37,0.00},
    purple = {0.80,0.47,0.65},
    teal   = {0.15,0.65,0.62},
    ink    = {0.025,0.045,0.07},
}
local AVENUE_PALETTE = {K.orange, K.sky, K.green, K.yellow, K.purple, K.blue, K.verm, K.grey}
local CLASS_NAMES = {[0]="vehicle","bot","amphibious","hover","all-terrain","ship","submarine"}
local BIT_VEH, BIT_BOT, BIT_AMPH, BIT_HOVER = 0, 1, 2, 3
local mint, muted = {0.35,0.9,0.73,1}, {0.65,0.73,0.8,1}
local inkPanel = {0.025,0.045,0.07,0.94}

local function split(s, sep)
    local out, from = {}, 1
    while true do
        local a, b = string.find(s, sep, from, true)
        if not a then out[#out+1] = string.sub(s, from); break end
        out[#out+1] = string.sub(s, from, a-1); from = b+1
    end
    return out
end
local function poly(s)
    local p = {}
    if not s then return p end
    for x, z in string.gmatch(s, "(-?%d+),(-?%d+)") do p[#p+1] = tonumber(x); p[#p+1] = tonumber(z) end
    return p
end
local function loops(s)
    -- theatre and region outlines: several closed loops joined by '/'
    local out = {}
    if not s then return out end
    for part in string.gmatch(s, "[^/]+") do
        local p = poly(part)
        if #p >= 4 then out[#out+1] = p end
    end
    return out
end
local function spine(s)
    local p = {}
    if not s then return p end
    for x, z, w in string.gmatch(s, "(-?%d+),(-?%d+),(-?%d+)") do p[#p+1] = {tonumber(x), tonumber(z), tonumber(w)} end
    return p
end
local function ints(s)
    local out = {}
    if not s then return out end
    for v in string.gmatch(s, "-?%d+") do out[#out+1] = tonumber(v) end
    return out
end
local function num(v, d) return tonumber(v) or d or 0 end
local function hasBit(mask, bit) return math.floor((mask or 0) / 2^bit) % 2 == 1 end
local function loose(name) return string.lower((string.gsub(name or "", "[%s%._%-]", ""))) end
local function groundY(x, z) return math.max(0, Spring.GetGroundHeight(x, z)) + 6 end

local function isWaterChar(c) return c=="water" or c=="deep" or c=="coast" or c=="strait" end

-- ---- file discovery and incremental parsing
local function newModel()
    return {classes={}, theatres={}, regions={}, boundaries={}, chokes={}, avenues={}, landings={}, standoff={},
        sides={}, contact={}, keys={}, corridors={}, corridorRuns={}, clearanceRuns={}, runs={}, groundRuns={}, rowRun={}, gw=0, gh=0, cell=32, name="", settings={}}
end
local function parseRecord(m, line)
    local f = split(line, "|")
    local k = f[1]
    if k == "corridor" then
        local id, cls = num(f[2],-1), num(f[3],-1)
        if id<0 or cls<0 or cls>6 then error("invalid corridor identity") end
        m.corridors[id]={id=id,class=cls,name=f[4],length=num(f[5]),width=num(f[6]),
            x=num(f[7]),z=num(f[8]),meanWidth=num(f[9]),specialist=num(f[10])==1,
            routes=num(f[11]),lateral=num(f[12]),lane=num(f[13]),lanes=num(f[14]),extent=num(f[15]),spine=spine(f[16])}
    elseif k == "corridorcells" or k == "clearance" then
        local cls=num(f[2],-1)
        if cls<0 or cls>6 then error("invalid corridor raster class") end
        local runs,start={},0
        for id,count in string.gmatch(f[3] or "", "(-?%d+)%*(%d+)") do
            id,count=tonumber(id),tonumber(count)
            if count<=0 or start+count>m.gw*m.gh or id< -1 or (k=="clearance" and (id<0 or id>255)) then error("invalid corridor raster") end
            runs[#runs+1]={start,id,count};start=start+count
            if #runs%256==0 then coroutine.yield() end
        end
        if start~=m.gw*m.gh then error("incomplete corridor raster") end
        if k=="corridorcells" then m.corridorRuns[cls]=runs else m.clearanceRuns[cls]=runs end
    elseif k == "experience" then
        m.experience = num(f[2])
    elseif k == "access" then
        m.accessRuns = {}; local start, runCount = 0, 0
        for id, count in string.gmatch(f[2] or "", "(%d+)%*(%d+)") do
            local n = tonumber(count)
            if n <= 0 or tonumber(id)>255 or start + n > m.gw * m.gh then error("invalid access run") end
            m.accessRuns[#m.accessRuns+1] = {start, tonumber(id), n}; start = start + n
            runCount=runCount+1;if runCount%256==0 then coroutine.yield() end
        end
        m.accessCount = start
    elseif k == "passage" then
        m.passages = m.passages or {}
        m.passages[#m.passages+1] = {id=num(f[2]), mask=num(f[3]), width=num(f[4]), line=poly(f[5])}
    elseif k == "landingdir" then
        m.landingDirs=m.landingDirs or {};m.landingDirs[num(f[2])]={x=num(f[3]),z=num(f[4]),dx=num(f[5]),dz=num(f[6])}
    elseif k == "site" then
        m.sites = m.sites or {}
        m.sites[#m.sites+1] = {id=num(f[2]), category=f[3], name=f[4], x=num(f[5]), z=num(f[6]), mask=num(f[7]),
            ally=num(f[8], -1), reason=f[9], basis=f[10]}
    elseif k == "theatre" then
        local id = num(f[2])
        m.theatres[id] = {id=id, kind=f[3], name=f[4] or "", cells=num(f[5]), x=num(f[6]), z=num(f[7]), holders=num(f[8]), outline=loops(f[9])}
    elseif k == "region" then
        local id = num(f[2])
        m.regions[id] = {id=id, theatre=num(f[3]), character=f[4] or "plain", cells=num(f[5]), medianW=num(f[6]), lowW=num(f[7]),
            minH=num(f[8]), maxH=num(f[9]), lx=num(f[10]), lz=num(f[11]), outline=loops(f[12])}
    elseif k == "boundary" then
        m.boundaries[#m.boundaries+1] = {id=num(f[2]), kind=f[3], a=num(f[4]), b=num(f[5]), mask=num(f[6]), width=num(f[7]),
            slope=num(f[8]), line=poly(f[9])}
    elseif k == "choke" then
        m.chokes[#m.chokes+1] = {id=num(f[2]), a=num(f[3]), b=num(f[4]), x=num(f[5]), z=num(f[6]), dx=num(f[7]), dz=num(f[8]), width=num(f[9])}
    elseif k == "avenue" then
        m.avenues[#m.avenues+1] = {id=num(f[2]), class=num(f[3]), name=f[4] or "", specialist=num(f[5])==1, length=num(f[6]),
            regions=ints(f[7]), crossings=ints(f[8]), spine=spine(f[9]), outline=poly(f[10])}
    elseif k == "landing" then
        local so = ints(f[12])
        local ov = f[13] and f[13] ~= "-" and ints(f[13]) or nil
        m.landings[#m.landings+1] = {id=num(f[2]), kind=f[3], sea=num(f[4]), region=num(f[5]), side=num(f[6], -1), assault=num(f[7])==1,
            rank=num(f[8]), mask=num(f[9]), width=num(f[10]), inland=num(f[11]), standoff={so[1] or -1, so[2] or -1, so[3] or -1},
            overlook=ov, line=poly(f[14])}
    elseif k == "standoff" then
        m.standoff[#m.standoff+1] = {sea=num(f[2]), depth=num(f[3]), line=poly(f[4])}
    elseif k == "side" then
        m.sides[#m.sides+1] = {ally=num(f[2]), box=poly(f[3]), cells=num(f[4]), lx=num(f[5]), lz=num(f[6])}
    elseif k == "contact" then
        m.contact[#m.contact+1] = poly(f[2])
    elseif k == "key" then
        m.keys[#m.keys+1] = {kind=f[2], x=num(f[3]), z=num(f[4]), value=num(f[5]), region=num(f[6], -1), side=num(f[7], -1), avenue=f[8]}
    elseif k == "class" then
        m.classes[num(f[2])] = {name=f[3] or "", slope=num(f[4]), minDepth=num(f[5]), maxDepth=num(f[6]), flags=num(f[7])}
    elseif k == "settings" then
        for key, v in string.gmatch(f[2] or "", "([%w_]+)=([^;]+)") do m.settings[key] = tonumber(v) or v end
    elseif k == "ground" then
        -- D-326: run-length ground class per cell, same form as the region ids
        local runs, start, runCount = m.groundRuns, 0, 0
        for id, count in string.gmatch(f[2] or "", "(%d+)%*(%d+)") do
            if tonumber(count)<=0 or tonumber(id)>7 or start+tonumber(count)>m.gw*m.gh then error("invalid ground run") end
            runs[#runs+1] = {start, tonumber(id), tonumber(count)}
            start = start + tonumber(count)
            runCount=runCount+1;if runCount%256==0 then coroutine.yield() end
        end
        m.groundCellCount=start
    elseif k == "cells" then
        -- Run-length region ids, kept as runs: regionOf(cell) scans the few runs of its row.
        local runs, start, runCount = m.runs, 0, 0
        for id, count in string.gmatch(f[2] or "", "(%d+)%*(%d+)") do
            runs[#runs+1] = {start, tonumber(id), tonumber(count)}
            start = start + tonumber(count)
            runCount=runCount+1;if runCount%256==0 then coroutine.yield() end
        end
        m.cellCount = start
    end
end
local function indexRuns(m)
    local gw = math.max(1, m.gw)
    m.rowRun = {}
    for i, r in ipairs(m.runs) do
        local row0 = math.floor(r[1] / gw)
        local row1 = math.floor((r[1] + r[3] - 1) / gw)
        for row = row0, row1 do if not m.rowRun[row] then m.rowRun[row] = i end end
    end
end
local function regionOf(m, x, z)
    if not m or m.gw == 0 then return nil end
    local cx, cz = math.floor(x / m.cell), math.floor(z / m.cell)
    if cx < 0 or cz < 0 or cx >= m.gw or cz >= m.gh then return nil end
    local c = cz * m.gw + cx
    local i = m.rowRun[cz]; if not i then return nil end
    while m.runs[i] do
        local r = m.runs[i]
        if c < r[1] then return nil end
        if c < r[1] + r[3] then return r[2] end
        i = i + 1
    end
    return nil
end

local compileAll   -- forward
local function beginParse(text)
    local fmt, name, gw, gh, cell, fseq = string.match(text, "^barbfield|(%d+)|([^|]*)|(%d+)|(%d+)|(%d+)|(%d+)")
    if not fmt then return false, "unexpected header" end
    if tonumber(fmt) ~= 1 then return false, "format " .. tostring(fmt) end
    local trailer = "\nend|" .. fseq
    local tp = string.find(text, trailer, 1, true)
    if not tp then return false, "torn file" end
    local after = string.sub(text, tp + #trailer, tp + #trailer)
    if after ~= "" and after ~= "\n" and after ~= "\r" then return false, "torn file" end
    if name ~= "" and Game.mapName and loose(name) ~= loose(Game.mapName) then
        return false, "file is for map '" .. name .. "'"
    end
    local m = newModel()
    m.name, m.gw, m.gh, m.cell = name, tonumber(gw), tonumber(gh), tonumber(cell)
    if m.gw < 1 or m.gh < 1 or m.gw * m.gh > 4194304 or m.cell < 1 then return false, "invalid grid" end
    -- the header's ninth field: the analysis fingerprint the landmarks file must repeat
    m.fingerprint = string.match(text, "^barbfield|[^|]*|[^|]*|[^|]*|[^|]*|[^|]*|[^|]*|[^|]*|([^|\r\n]+)")
    -- Recoil Lua uses FLOAT numbers: even a 9-digit revision loses precision.
    -- Long division keeps every intermediate digit <= 19, preserving the native
    -- fingerprint % 1000000007 + 1 as an exact decimal string. Once per file.
    local rem,divisor="0","1000000007"
    for digit in string.gmatch(m.fingerprint or "","%d") do
        rem=(rem=="0" and "" or rem)..digit
        while #rem>#divisor or (#rem==#divisor and rem>=divisor) do
            local out,borrow="",0
            for i=#rem,1,-1 do
                local j=i-(#rem-#divisor)
                local d=tonumber(rem:sub(i,i))-(j>0 and tonumber(divisor:sub(j,j)) or 0)-borrow
                borrow=d<0 and 1 or 0;if d<0 then d=d+10 end
                out=tostring(d)..out
            end
            rem=out:gsub("^0+","");if rem=="" then rem="0" end
        end
    end
    local out,carry="",1
    for i=#rem,1,-1 do local d=tonumber(rem:sub(i,i))+carry;carry=d>=10 and 1 or 0;out=tostring(d%10)..out end
    m.corridorRevision=(carry>0 and "1" or "")..out
    parse = {text=text, pos=1, m=m, total=#text, seq=tonumber(fseq)}
    return true
end
local function stepParse()
    if not parse then return end
    local t0 = Spring.GetTimer()
    local text, pos = parse.text, parse.pos
    local lines = 0
    while true do
        local e = string.find(text, "\n", pos, true)
        local line = e and string.sub(text, pos, e-1) or string.sub(text, pos)
        if string.sub(line, -1) == "\r" then line = string.sub(line, 1, -2) end
        if #line > 0 and not string.find(line, "^barbfield") and not string.find(line, "^end|") then parseRecord(parse.m, line) end
        pos = e and e + 1 or #text + 1
        lines = lines + 1
        if pos > #text then break end
        if lines % 64 == 0 and Spring.DiffTimers(Spring.GetTimer(), t0) > 0.002 then break end
    end
    parse.pos = pos
    if pos > #text then
        local m = parse.m
        if m.cellCount ~= m.gw * m.gh or (m.experience == 2 and (m.accessCount ~= m.cellCount or m.groundCellCount ~= m.cellCount)) then
            parse = nil; status = "Incomplete terrain grid"; return
        end
        indexRuns(m)
        model, seq = m, parse.seq
        parse = nil
        if on then compileAll() else status="Terrain analysis ready" end
    else
        status = string.format("Reading terrain analysis %d%%", math.floor(100 * pos / math.max(1, #text)))
    end
end
local function tryLoad()
    -- Recoil changes cwd to the write directory. Direct IO deliberately avoids
    -- VFS's fallback to a stale same-map export in another data directory.
    -- Native clears its previous file during frame-zero initialization.
    if Spring.GetGameFrame and Spring.GetGameFrame()<1 then return end
    if not (io and io.open) then status="Local terrain file access unavailable";return end
    local now = Spring.GetTimer()
    if lastExists and Spring.DiffTimers(now, lastExists) < 2 then return end
    lastExists = now
    local ok, text = pcall(function()
        local f=io.open(PATH,"rb");if not f then return nil end
        local value=f:read(64*1024*1024+1);f:close();return value
    end)
    if ok and not text then
        status = "Terrain analysis not published (needs a locally hosted BARb with field.enabled)"
        return
    end
    if not ok or type(text) ~= "string" or #text == 0 then status = "Cannot read " .. PATH; return end
    if #text>64*1024*1024 then status="Terrain file exceeds size limit";return end
    local good, err = beginParse(text)
    if not good then status = "Terrain file skipped: " .. tostring(err) end
end

-- ---- line generation helpers
-- Every stroke goes through seg(). In world space seg() splits long segments so the
-- line follows the terrain; the legend swaps in a flat screen-space emitter (`emit`)
-- and shrinks the pattern lengths (`patScale`), so a legend row is drawn by exactly
-- the code that draws the map. Every line layer is compiled twice into its display
-- list: an ink under-stroke three pixels wider (`haloPass`) and then the colour, so a
-- line keeps its contrast over bright sand, dark forest or another line.
local SEG_MAX = 128   -- elmos; longer segments are split so the line follows the terrain
local emit = nil      -- nil: world space; else function(ax, az, bx, bz) emitting 2D vertices
local patScale = 1    -- pattern lengths are in elmos; the legend scales them to pixels
local haloPass = false
local function seg(ax, az, bx, bz)
    if emit then emit(ax, az, bx, bz); return end
    local dx, dz = bx - ax, bz - az
    local len = math.sqrt(dx*dx + dz*dz)
    local n = math.max(1, math.ceil(len / SEG_MAX))
    local px, pz = ax, az
    for i = 1, n do
        local f = i / n
        local x, z = ax + dx*f, az + dz*f
        gl.Vertex(px, groundY(px, pz), pz); gl.Vertex(x, groundY(x, z), z)
        px, pz = x, z
    end
end
local function tri(ax, az, bx, bz, cx, cz)
    -- a filled triangle (inside gl.BeginEnd(GL.TRIANGLES)); small enough to sit on the ground
    if emit then gl.Vertex(ax, az); gl.Vertex(bx, bz); gl.Vertex(cx, cz); return end
    gl.Vertex(ax, groundY(ax, az), az); gl.Vertex(bx, groundY(bx, bz), bz); gl.Vertex(cx, groundY(cx, cz), cz)
end
local function solid(p)
    for i = 3, #p, 2 do seg(p[i-2], p[i-1], p[i], p[i+1]) end
end
local function solidLoops(ls) for _, p in ipairs(ls) do solid(p) end end
-- Chaikin corner cutting: the file's lines follow 32-elmo cell edges (a staircase on any
-- diagonal); two passes turn them into readable curves within a quarter cell of the edge.
-- A loop (first point == last point) stays closed; an open chain keeps its end points.
local SMOOTH_PASSES = 2
local SMOOTH_TOL = 32   -- elmos; set from the model's cell size (one cell) when it loads
-- Douglas-Peucker on a flat x,z list between point indices i0 and i1 (1-based point
-- numbers); appends kept points (excluding i0) to out. A 32-elmo staircase on a
-- diagonal deviates about 11 elmos from the straight line and a 2:1 staircase about
-- 28, so one cell collapses both to their diagonal while real bends survive.
local function dpSegment(p, i0, i1, tol, out)
    local ax, az = p[2*i0-1], p[2*i0]
    local bx, bz = p[2*i1-1], p[2*i1]
    local dx, dz = bx-ax, bz-az
    local len = math.sqrt(dx*dx + dz*dz)
    local best, bestI = -1, nil
    for i = i0+1, i1-1 do
        local x, z = p[2*i-1], p[2*i]
        local d
        if len == 0 then d = math.sqrt((x-ax)^2 + (z-az)^2)
        else d = math.abs(dx*(z-az) - dz*(x-ax)) / len end
        if d > best then best, bestI = d, i end
    end
    if bestI and best > tol then
        dpSegment(p, i0, bestI, tol, out)
        dpSegment(p, bestI, i1, tol, out)
    else
        out[#out+1] = bx; out[#out+1] = bz
    end
end
local function simplify(p, tol, closed)
    local n = math.floor(#p / 2)
    if n < 3 then return p end
    local out = {p[1], p[2]}
    if closed then
        -- anchor a loop at its first point and the point farthest from it
        local far, farI = -1, 2
        for i = 2, n-1 do
            local d = (p[2*i-1]-p[1])^2 + (p[2*i]-p[2])^2
            if d > far then far, farI = d, i end
        end
        dpSegment(p, 1, farI, tol, out)
        dpSegment(p, farI, n, tol, out)
    else
        dpSegment(p, 1, n, tol, out)
    end
    return out
end
local function smooth(p)
    if #p < 6 then return p end
    local closed = p[1] == p[#p-1] and p[2] == p[#p]
    local cur = simplify(p, SMOOTH_TOL, closed)
    if #cur < 6 then return cur end
    for _ = 1, SMOOTH_PASSES do
        local out = {}
        local n = #cur - (#cur % 2)   -- flat x,z pairs; ignore a dangling odd value
        if not closed then out[1], out[2] = cur[1], cur[2] end
        for i = 3, n, 2 do
            local ax, az, bx, bz = cur[i-2], cur[i-1], cur[i], cur[i+1]
            out[#out+1] = ax*0.75 + bx*0.25; out[#out+1] = az*0.75 + bz*0.25
            out[#out+1] = ax*0.25 + bx*0.75; out[#out+1] = az*0.25 + bz*0.75
        end
        if closed then out[#out+1] = out[1]; out[#out+1] = out[2]
        else out[#out+1] = cur[n-1]; out[#out+1] = cur[n] end
        cur = out
    end
    return cur
end
local function smoothLoops(ls) local out = {}; for i, p in ipairs(ls) do out[i] = smooth(p) end; return out end
-- Patterns: on/off run lengths in elmos repeated along the line, phase carried across
-- vertices. The pattern, not the colour, is what tells two kinds of line apart.
local PAT = {
    longdash = {64, 24},
}
local function pattern(p, seq)
    local n = #seq
    local k, phase = 1, 0
    for i = 3, #p, 2 do
        local ax, az, bx, bz = p[i-2], p[i-1], p[i], p[i+1]
        local dx, dz = bx-ax, bz-az
        local len = math.sqrt(dx*dx + dz*dz)
        if len > 0 then
            dx, dz = dx/len, dz/len
            local t = 0
            while t < len do
                local run = seq[k] * patScale - phase
                local t2 = math.min(len, t + run)
                if k % 2 == 1 then seg(ax+dx*t, az+dz*t, ax+dx*t2, az+dz*t2) end
                if t2 >= len then phase = phase + (len - t) else phase = 0; k = k % n + 1 end
                t = t2
            end
        end
    end
end
local function hachures(p, every, length, towardLeft)
    -- short ticks on one side of the line, every `every` elmos
    every, length = every * patScale, length * patScale
    local acc = every / 2
    for i = 3, #p, 2 do
        local ax, az, bx, bz = p[i-2], p[i-1], p[i], p[i+1]
        local dx, dz = bx-ax, bz-az
        local len = math.sqrt(dx*dx + dz*dz)
        if len > 0 then
            dx, dz = dx/len, dz/len
            local nx, nz = -dz, dx
            if not towardLeft then nx, nz = dz, -dx end
            local t = acc
            while t < len do
                local x, z = ax+dx*t, az+dz*t
                seg(x, z, x+nx*length, z+nz*length)
                t = t + every
            end
            acc = t - len
        end
    end
end
local function double(p, off)
    -- the line and a parallel copy `off` elmos to its left
    solid(p)
    off = off * patScale
    for i = 3, #p, 2 do
        local ax, az, bx, bz = p[i-2], p[i-1], p[i], p[i+1]
        local dx, dz = bx-ax, bz-az
        local len = math.sqrt(dx*dx+dz*dz)
        if len > 0 then
            local nx, nz = -dz/len*off, dx/len*off
            seg(ax+nx, az+nz, bx+nx, bz+nz)
        end
    end
end
local function polyMid(p)
    -- the point half way along the polyline's length
    if #p < 2 then return 0, 0 end
    if #p < 4 then return p[1], p[2] end
    local total = 0
    for i = 3, #p, 2 do local dx, dz = p[i]-p[i-2], p[i+1]-p[i-1]; total = total + math.sqrt(dx*dx+dz*dz) end
    local half, acc = total / 2, 0
    for i = 3, #p, 2 do
        local dx, dz = p[i]-p[i-2], p[i+1]-p[i-1]
        local len = math.sqrt(dx*dx+dz*dz)
        if acc + len >= half and len > 0 then
            local f = (half - acc) / len
            return p[i-2] + dx*f, p[i-1] + dz*f
        end
        acc = acc + len
    end
    return p[#p-1], p[#p]
end
local function ibeam(x, z, dx, dz, half, serif)
    -- a choke: the width bar perpendicular to (dx,dz) with a serif at each end along the crossing
    local len = math.sqrt(dx*dx+dz*dz); if len == 0 then dx, dz, len = 1, 0, 1 end
    dx, dz = dx/len, dz/len
    local s = (serif or 14) * patScale
    local lx, lz, rx, rz = x - dz*half, z + dx*half, x + dz*half, z - dx*half
    seg(lx, lz, rx, rz)
    seg(lx - dx*s, lz - dz*s, lx + dx*s, lz + dz*s)
    seg(rx - dx*s, rz - dz*s, rx + dx*s, rz + dz*s)
end
local function triangle(x, z, r)
    -- an upright triangle of "radius" r centred on (x, z); returns its corners for a fill
    local lx, lz, rx, rz, tx, tz = x - r, z + r*0.75, x + r, z + r*0.75, x, z - r
    seg(lx, lz, rx, rz); seg(lx, lz, tx, tz); seg(rx, rz, tx, tz)
    return lx, lz, rx, rz, tx, tz
end
local function ngon(x, z, r, n)
    local px, pz
    for i = 0, n do
        local a = i * 2 * math.pi / n
        local cx, cz = x + math.cos(a)*r, z + math.sin(a)*r
        if px then seg(px, pz, cx, cz) end
        px, pz = cx, cz
    end
end
local function stroke(c, a, w)
    -- the current line colour and width; in the halo pass every line is a wider ink stroke
    if haloPass then gl.Color(K.ink[1], K.ink[2], K.ink[3], 0.85); gl.LineWidth((w or 2) + 3)
    else gl.Color(c[1], c[2], c[3], a or 1); gl.LineWidth(w or 2) end
end
local function setColour(c, a) gl.Color(c[1], c[2], c[3], a or 1) end   -- fills and marks only

-- The style of every line. No two differ in colour alone, because the legend is read
-- by colour-blind players too: the pattern carries the meaning and the colour only
-- repeats it. Five line types in all: solid heavy (coast), solid thin (open border),
-- long dash (a crossing some unit class can use; which one, the inspector says),
-- double (ford), solid with ticks (nobody crosses; the ticks point down or to the water).
local STYLE = {
    coast    = {pat="solid",    w=3,   c=K.white,  a=0.9},
    region   = {pat="solid",    w=1,   c=K.grey,   a=0.6},
    crossing = {pat="longdash", w=2.5, c=K.white,  a=0.95},
    ford     = {pat="double",   w=1.5, c=K.white,  a=0.9},
    blocked  = {pat="ticked",   w=3,   c=K.verm,   a=0.95},
    choke    = {pat="solid",    w=2.5, c=K.white,  a=0.95},
    key      = {pat="solid",    w=1.5, c=K.yellow, a=0.95},
}
-- The ground classes the AI writes per cell (D-326), in file order. Each is a fill, a
-- mark, or both; the mark alone tells the class on a monochrome print. The text is
-- the legend row.
local GROUND = {
    [0] = {name="deep",    fill=K.blue,   alpha=0.30, mark=nil,       text="Deep water: ships sail it"},
    [1] = {name="water",   fill=K.sky,    alpha=0.22, mark="wave",    text="Water, no ships: hovers and amphibious only"},
    [2] = {name="shallow", fill=K.teal,   alpha=0.32, mark="dash",    text="Shallows, marsh: land units wade, slowed"},
    [3] = {name="flat",    fill=nil,      alpha=0,    mark=nil,       text="Flat: vehicles drive"},
    [4] = {name="rough",   fill=nil,      alpha=0,    mark="hatch",   text="Rough: vehicles slowed, bots fine"},
    [5] = {name="steep",   fill=K.orange, alpha=0.12, mark="hatch2",  text="Steep: bots and amphibious climb, no vehicles"},
    [6] = {name="cliff",   fill=K.verm,   alpha=0.16, mark="cross",   text="Cliff: all-terrain only, or nobody"},
    [7] = {name="harm",    fill=K.verm,   alpha=0.30, mark="dot",     text="Lava, acid: deadly to everything that is not flying"},
}
local MARK_COLOUR = {wave=K.sky, dash=K.teal, hatch=K.grey, hatch2=K.orange, cross=K.verm, dot=K.verm}
local function drawPat(st, p, left)
    -- polyline p in style st's pattern (inside gl.BeginEnd(GL.LINES)); left: tick side
    local pat = st.pat
    if pat == "solid" then solid(p)
    elseif pat == "double" then double(p, 10)
    elseif pat == "ticked" then solid(p); hachures(p, 40, 18, left)
    elseif PAT[pat] then pattern(p, PAT[pat])
    else solid(p) end
end
local function strokeStyle(st, a) stroke(st.c, a or st.a, st.w) end

local function regionIsWater(m, id) local r = m.regions[id]; return r and isWaterChar(r.character) end
local function regionLabel(m, id) local r = m.regions[id]; if r then return r.lx, r.lz end return nil end
local FILL_MAX_CELLS = 4   -- a fill quad spans at most this many cells so it can follow the ground
local fillColour = {1, 1, 1, 0.2}   -- set by fillWith() before fillRuns(); per-vertex alpha needs it
local function fillWith(c, a) fillColour = {c[1], c[2], c[3], a} end
local function fillRuns(m, runs, table, want, waterY)
    -- quads per run for the ids in `want` (set) over run-length `runs` ({start, id, count})
    -- whose per-cell expansion is `table`: a flat fill with no triangulation.
    -- waterY: a flat surface height for water fills; nil samples the ground at every corner.
    -- Soft edge: a grid node whose four cells are not all in `want` gets alpha 0, so the
    -- fill fades out over the border cell instead of showing a hard cell staircase
    -- beside the smoothed border line. Cells with any faded corner are drawn one by
    -- one; full-alpha runs are merged up to FILL_MAX_CELLS. The map edge counts as inside.
    local gw, gh, cell = m.gw, m.gh, m.cell
    local cr, cg, cb, ca = fillColour[1], fillColour[2], fillColour[3], fillColour[4]
    local function y(x, z) if waterY then return waterY end return math.max(0, Spring.GetGroundHeight(x, z)) + 4 end
    local function inside(col, row)
        if col < 0 or row < 0 or col >= gw or row >= gh then return true end
        local id = table[row * gw + col]
        return id == nil or want[id] == true
    end
    -- node (nx, nz) is full when the four cells around it are inside
    local function nodeFull(nx, nz)
        return inside(nx-1, nz-1) and inside(nx, nz-1) and inside(nx-1, nz) and inside(nx, nz)
    end
    gl.BeginEnd(GL.QUADS, function()
        local function vertex(nx, nz, full)
            gl.Color(cr, cg, cb, full and ca or 0)
            local x, z = nx*cell, nz*cell
            gl.Vertex(x, y(x, z), z)
        end
        local function quad(row, col, take)
            vertex(col, row, nodeFull(col, row)); vertex(col+take, row, nodeFull(col+take, row))
            vertex(col+take, row+1, nodeFull(col+take, row+1)); vertex(col, row+1, nodeFull(col, row+1))
        end
        for _, r in ipairs(runs) do
            if want[r[2]] then
                local startCol, count, row = nil, 0, nil
                for c = r[1], r[1] + r[3] - 1 do
                    local rw, col = math.floor(c / gw), c % gw
                    -- a cell is mergeable only when its four corners are all full
                    local plain = nodeFull(col, rw) and nodeFull(col+1, rw) and nodeFull(col, rw+1) and nodeFull(col+1, rw+1)
                    if plain and startCol and rw == row and count < FILL_MAX_CELLS then
                        count = count + 1
                    else
                        if startCol then quad(row, startCol, count) end
                        if plain then startCol, count, row = col, 1, rw
                        else startCol, count = nil, 0; quad(rw, col, 1) end
                    end
                end
                if startCol then quad(row, startCol, count) end
            end
        end
    end)
    gl.Color(cr, cg, cb, ca)
end
local function markCell(kind, x, z, q)
    -- one cell's mark, centred on (x, z) with half size q (inside gl.BeginEnd(GL.LINES))
    if kind == "hatch" then seg(x-q, z+q, x+q, z-q)
    elseif kind == "hatch2" then seg(x-q, z+q, x+q, z-q); seg(x-q, z, x, z-q)
    elseif kind == "cross" then seg(x-q, z-q, x+q, z+q); seg(x-q, z+q, x+q, z-q)
    elseif kind == "dash" then seg(x-q, z, x+q, z)
    elseif kind == "wave" then seg(x-q, z+q*0.3, x-q*0.3, z-q*0.3); seg(x-q*0.3, z-q*0.3, x+q*0.3, z+q*0.3); seg(x+q*0.3, z+q*0.3, x+q, z-q*0.3)
    elseif kind == "dot" then seg(x-2, z, x+2, z) end
end
local function cellMarks(m, runs, want, kind, every)
    -- a per-cell mark for the ids in `want`: every cell (every = 1) or every other (2)
    local gw, cell = m.gw, m.cell
    gl.BeginEnd(GL.LINES, function()
        for _, r in ipairs(runs) do
            if want[r[2]] then
                for c = r[1], r[1] + r[3] - 1 do
                    local row, col = math.floor(c / gw), c % gw
                    if (row + col) % every == 0 then
                        markCell(kind, col*cell + cell/2, row*cell + cell/2, cell * 0.3)
                    end
                end
            end
        end
    end)
end

local function addLabel(x, z, textValue, size, minH, maxH, c)
    if #labelsAll >= 200 then return end
    labelsAll[#labelsAll+1] = {x, groundY(x, z) + 10, z, textValue, size, minH, maxH, c}
end
local function spaced(s) return (string.gsub(string.upper(s), ".", "%0 ")) end

local function disposeLists()
    for k, l in pairs(lists) do gl.DeleteList(l) end
    lists = {}
    if focusList then gl.DeleteList(focusList); focusList = nil end
    labelsAll = {}
end

local function compileLayer(name, fn)
    if lists[name] then gl.DeleteList(lists[name]) end
    lists[name] = gl.CreateList(fn)
end
local function lineLayer(name, fn)
    -- a line layer is compiled twice into one list: the ink under-stroke, then the colour
    compileLayer(name, function() haloPass = true; fn(); haloPass = false; fn() end)
end
-- A summit is a plateau no land unit reaches: every one of its borders is a cliff, a
-- sheer shore or the map edge, so only all-terrain units and aircraft get there.
local REACHABLE = {open=true, ramp=true, climb=true, pass=true, ford=true, beach=true, steep=true}
local function findSummits(m)
    local reach = {}
    for _, b in ipairs(m.boundaries) do
        if REACHABLE[b.kind] then reach[b.a] = true; reach[b.b] = true end
    end
    m.summits = {}
    for id, r in pairs(m.regions) do
        if r.character == "plateau" and not reach[id] then m.summits[id] = true end
    end
end

-- Geometry is compiled incrementally by the experience controller below.

-- ---- blueprint mode
local function setGround(off)
    if off == groundOff then return end
    groundOff = off
    if Spring.SetDrawGround then Spring.SetDrawGround(not off) end
    if Spring.SetDrawWater then Spring.SetDrawWater(not off) end
end

local setMode, setBlueprint, setLayer, setFocus
local drawWorld, drawMiniMap, drawScreen, update

local function button(id, x, y, w, title, isOn, action)
    gl.Color(isOn and {0.12,0.30,0.34,0.98} or {0.09,0.13,0.18,0.98}); gl.Rect(x, y, x+w, y+24)
    gl.Color(isOn and mint or {0.83,0.87,0.93,1}); gl.Text(title, x+w/2, y+7, 10, "oc")
    controls[#controls+1] = {x, y, x+w, y+24, id=id, action=action}
end
local function hitAt(x, y)
    for i = #controls, 1, -1 do local r = controls[i]; if x >= r[1] and y >= r[2] and x <= r[3] and y <= r[4] then return r end end
end
local mousePress
local function mouseRelease(x, y, b)
    local was = pressed ~= nil or drag ~= nil
    if drag then drag = nil
    elseif pressed and b == 1 then
        local r = hitAt(x, y)
        if r and r.id == pressed.id and r.action then r.action() end
    end
    pressed = nil
    return was
end
local function mouseMove(x, y)
    if drag then dockX = drag[3] + x - drag[1]; dockY = drag[4] + y - drag[2]; return true end
end
local function snapshot()
    local out = {loaded = model ~= nil, seq = seq, theatres = 0, land = 0, seas = 0, ponds = 0, regions = 0, boundaries = 0, chokes = 0,
        summits = 0, keys = 0, avenues = 0, landings = 0, assault = 0, ground = {}, layers = {},
        items = {theatres = {}, chokes = {}, summits = {}, landings = {}, avenues = {}}, on = on, status = status}
    for k, v in pairs(layers) do out.layers[k] = v end
    local m = model
    if not m then return out end
    for _, t in pairs(m.theatres) do
        out.theatres = out.theatres + 1
        if t.kind == "sea" then out.seas = out.seas + 1 elseif t.kind == "pond" then out.ponds = out.ponds + 1 else out.land = out.land + 1 end
        out.items.theatres[#out.items.theatres+1] = {id=t.id, kind=t.kind, name=t.name, x=t.x, z=t.z, cells=t.cells}
    end
    for _ in pairs(m.regions) do out.regions = out.regions + 1 end
    out.boundaries, out.chokes, out.keys = #m.boundaries, #m.chokes, #m.keys
    for cls, n in pairs(m.groundCount or {}) do out.ground[cls] = n end
    for id in pairs(m.summits or {}) do
        local r = m.regions[id]
        out.summits = out.summits + 1
        if r then out.items.summits[#out.items.summits+1] = {region=id, x=r.lx, z=r.lz, cells=r.cells, minH=r.minH, maxH=r.maxH} end
    end
    for _, c in ipairs(m.chokes) do
        local ra, rb = m.regions[c.a], m.regions[c.b]
        local land = ra ~= nil and rb ~= nil and not isWaterChar(ra.character) and not isWaterChar(rb.character)
        out.items.chokes[#out.items.chokes+1] = {id=c.id, x=c.x, z=c.z, width=c.width, a=c.a, b=c.b, land=land}
    end
    return out
end
local config, getConfig, textCommand, shutdown

-- Experience v2. All semantic state belongs to this widget. The immutable
-- model and explicit settings are the only inputs; no selection/roster/time
-- callbacks participate. Preparation yields between bounded geometry batches.
local ux = {schemaVersion=2, view="terrain", primary=0, compare=-1, side=-1,
    detail="essential", labels="names", background="normal", opacity=0.35,
    inspect=false, debug=false, advanced=false, collapsed=false,
    categories={resources=true, coastal_access=true}, preset="Terrain overview"}
local presets, legacyConfig = {}, nil
local uxLists, uxFeatures, uxJob, uxFocus, uxMenu = {}, {}, nil, nil, nil
local uxLabelFeatures = {}
local uxNotice = "Initial-map analysis; temporary obstacles and enemy coverage are not assessed"
local uxMetrics = {prepareMs=0, maxSliceMs=0, batches=0}
local movement = {{0,"Vehicles"},{1,"Bots"},{3,"Hover"},{2,"Amphibious"},{5,"Surface ships"},{7,"Deep-draft ships"},{6,"Submarines"},{4,"All-terrain"}}
local categoryNames = {{"resources","Resources"},{"staging","Staging"},{"defensive","Defensive candidates"},{"coastal_access","Coastal access"},{"starts","Start positions"}}
local function copy(v)
    if type(v) ~= "table" then return v end
    local t = {}; for k,x in pairs(v) do t[k] = copy(x) end; return t
end
local function clearUxLists()
    for _, id in ipairs(uxLists) do gl.DeleteList(id) end
    uxLists = {}; uxJob = nil; uxFeatures = {}; uxLabelFeatures = {}; uxFocus = nil; uxMenu = nil
end
local function accepts(mask)
    return hasBit(mask, ux.primary) or (ux.compare >= 0 and hasBit(mask, ux.compare))
end
local function selectionColour(mask)
    local a, b = hasBit(mask, ux.primary), ux.compare >= 0 and hasBit(mask, ux.compare)
    if a and b then return K.grey, 0 end
    if b then return K.orange, 2 end
    return K.sky, 1
end
local function featureVisible(f)
    if f.debugCandidate then return ux.debugCandidates end
    if f.debug then return ux.debug end
    if ux.view == "terrain" then return f.view == "terrain" end
    if ux.view == "approaches" then return f.view == "approaches" and (not f.mask or accepts(f.mask)) end
    return f.view == "positions" and ux.categories[f.category] and accepts(f.mask or 0)
        and (ux.side < 0 or f.ally == nil or f.ally < 0 or f.ally == ux.side)
end
local function appendFeature(f)
    if not featureVisible(f) then return end
    f.y = groundY(f.x, f.z)
    uxFeatures[#uxFeatures+1] = f
    if ux.detail=="detailed" or f.category or string.find(f.id,"^theatre:") or string.find(f.id,"^passage:") or ux.debugIds then
        uxLabelFeatures[#uxLabelFeatures+1] = f
    end
end
local function uxBatch(fn)
    local id = gl.CreateList(fn)
    if id then uxLists[#uxLists+1] = id end
    uxMetrics.batches = uxMetrics.batches + 1
    coroutine.yield()
end
local function uxPrepare()
    local m = model
    -- RLE cell surfaces are the native mobility mask itself, not a buffered
    -- route. O(G) preparation only; draw calls reuse lists until settings/model
    -- change. Each chunk is <=128 row fragments, limiting height callbacks.
    local runs = ux.view == "approaches" and m.accessRuns or m.groundRuns
    if ux.view ~= "positions" and runs then
        local batch = {}
        local function flush()
            local items = batch; batch = {}
            uxBatch(function()
                gl.BeginEnd(GL.QUADS, function()
                    for _,q in ipairs(items) do
                        gl.Color(q.c[1],q.c[2],q.c[3],ux.opacity * q.alpha)
                        gl.Vertex(q.x,q.y,q.z); gl.Vertex(q.x+q.w,q.y,q.z)
                        gl.Vertex(q.x+q.w,q.y,q.z+m.cell); gl.Vertex(q.x,q.y,q.z+m.cell)
                    end
                end)
                gl.LineWidth(1)
                gl.BeginEnd(GL.LINES, function()
                    for _,q in ipairs(items) do if q.pattern and q.pattern > 0 then
                        gl.Color(q.c[1],q.c[2],q.c[3],ux.opacity)
                        -- Sparse native-cell pattern: slash vs cross remains
                        -- distinguishable in monochrome. No per-frame work.
                        local spacing=ux.detail=="essential" and 8 or 4
                        if math.floor(q.z/m.cell)%spacing == 0 then
                            local first=q.x+((spacing-(q.x/m.cell)%spacing)%spacing)*m.cell
                            for x=first,q.x+q.w-m.cell,spacing*m.cell do
                                gl.Vertex(x,q.y+1,q.z); gl.Vertex(x+m.cell,q.y+1,q.z+m.cell)
                                if q.pattern==2 then gl.Vertex(x+m.cell,q.y+1,q.z); gl.Vertex(x,q.y+1,q.z+m.cell) end
                            end
                        end
                    end end
                end)
            end)
        end
        for _,r in ipairs(runs) do
            local colour, pattern, alpha
            if ux.view == "approaches" then
                if accepts(r[2]) then colour,pattern=selectionColour(r[2]); alpha=0.55 end
            else
                local gd = GROUND[r[2]]
                if gd and r[2] ~= 3 and (ux.detail=="detailed" or r[2]~=4) then
                    colour=gd.fill or K.verm; alpha=0.4; pattern=r[2]>=5 and 2 or nil
                end
            end
            if colour then
                local c, left = r[1],r[3]
                while left>0 do
                    local cx,cz=c%m.gw,math.floor(c/m.gw); local n=math.min(left,m.gw-cx,16)
                    local x,z=cx*m.cell,cz*m.cell
                    batch[#batch+1]={x=x,z=z,w=n*m.cell,y=groundY(x+n*m.cell/2,z+m.cell/2),c=colour,pattern=pattern,alpha=alpha}
                    c=c+n;left=left-n
                    if #batch>=128 then flush() end
                end
            end
        end
        if #batch>0 then flush() end
    end
    local ids = {}; for id in pairs(m.theatres) do ids[#ids+1]=id end; table.sort(ids)
    for _,id in ipairs(ids) do local t=m.theatres[id]
        appendFeature({id="theatre:"..id,view=ux.view=="approaches" and "approaches" or "terrain",name=t.name,x=t.x,z=t.z,loops=t.kind~="land" and t.outline or nil,
            reason="Connected "..t.kind.." area",basis="Terrain-derived",colour=K.white})
    end
    for _,b in ipairs(m.boundaries) do
        local physical=b.kind=="cliff" or b.kind=="sheer" or (m.experience==2 and (b.kind=="ramp" or b.kind=="pass" or b.kind=="climb" or b.kind=="ford"))
        if #b.line>=4 then
            appendFeature({id="boundary:"..b.id,view="terrain",debug=not physical,name=physical and b.kind or "Analysis partition",
                x=b.line[1],z=b.line[2],line=b.line,colour=physical and K.verm or K.grey,
                pattern=physical and ((b.kind=="cliff" or b.kind=="sheer") and "blocked" or "crossing") or nil,
                reason=physical and "Physical terrain transition; movement families have different limits" or "Internal watershed partition; not a terrain restriction",
                basis="Terrain-derived",mask=b.mask})
        end
    end
    for i,k in ipairs(m.keys) do if k.kind=="high" then
        appendFeature({id="height:"..i,view="terrain",category="high",name=m.summits[k.region] and "Isolated high ground" or "High ground",
            x=k.x,z=k.z,colour=K.yellow,basis="Terrain-derived",
            reason="Raised terrain in the initial grid. Access has unit exceptions; height is not a universal weapon range bonus"})
    end end
    for _,p in ipairs(m.passages or {}) do if #p.line>=4 then
        appendFeature({id="passage:"..p.id,view="approaches",name="Local constriction",mask=p.mask,
            x=(p.line[1]+p.line[3])/2,z=(p.line[2]+p.line[4])/2,line=p.line,colour=K.white,
            measurement=string.format("%.0f elmos",p.width),
            reason=string.format("%.0f elmo obstacle cross-section; wider connected approaches on both sides",p.width),basis="Terrain-derived"})
    end end
    for _,c in ipairs(m.chokes) do
        appendFeature({id="candidate:"..c.id,debugCandidate=true,name="Clearance candidate",x=c.x,z=c.z,
            category="debug",colour=K.grey,reason="Unqualified watershed contact; not a measured passage",basis="Analysis diagnostic"})
    end
    for _,l in ipairs(m.landings) do if #l.line>=4 then
        local side=m.sides[l.side+1]
        local ally=side and side.ally or -1
        local water=m.theatres[l.sea]
        local land=m.regions[l.region];land=land and m.theatres[land.theatre]
        appendFeature({id="landing:"..l.id,view="approaches",name=(water and water.name or "Water").." access",mask=l.mask,
            x=l.line[1],z=l.line[2],line=l.line,colour=K.sky,ally=ally,
            arrow=ux.side>=0 and ally==ux.side and m.landingDirs and m.landingDirs[l.id] or nil,
            reason="Connects "..(water and water.name or "water").." and "..(land and land.name or "inland ground").."; initial terrain only",basis="Terrain-derived"})
    end end
    local categoryCount, categorySites = {}, {}
    local separation=math.min(1024,math.max(Game.mapSizeX,Game.mapSizeZ)/10)
    for _,s in ipairs(m.sites or {}) do
        if ux.side<0 or s.ally<0 or s.ally==ux.side then
            local group=s.category=="resources" and s.name or s.category
            local count=categoryCount[group] or 0
            local nearby=false
            if ux.detail=="essential" and s.category~="starts" then
                for _,p in ipairs(categorySites[group] or {}) do
                    if (p.x-s.x)^2+(p.z-s.z)^2<separation^2 then nearby=true;break end
                end
            end
            if accepts(s.mask) and not nearby and (ux.detail=="detailed" or count<(s.category=="resources" and 3 or 6)) then
                categoryCount[group]=count+1
                categorySites[group]=categorySites[group] or {};table.insert(categorySites[group],s)
                local name=s.category=="starts" and ((s.basis=="Tactical candidate" and "Predicted " or "Recorded ")..s.name) or s.name
                local reason=s.reason
                if s.category=="coastal_access" then
                    local sea,region=string.match(reason or "","^Sea (%d+) to land region (%d+)")
                    local water=m.theatres[tonumber(sea)];local land=m.regions[tonumber(region)]
                    land=land and m.theatres[land.theatre]
                    name=(water and water.name or "Water").." access"
                    reason="Connects "..(water and water.name or "water").." and "..(land and land.name or "inland ground").."; initial terrain transition, occupancy unknown"
                end
                appendFeature({id="site:"..s.id,view="positions",category=s.category,name=name,x=s.x,z=s.z,
                    mask=s.mask,ally=s.ally,reason=reason,basis=s.basis,colour=s.category=="resources" and K.yellow or K.sky})
            end
        end
    end
    for first=1,#uxFeatures,32 do
        local last=math.min(#uxFeatures,first+31)
        uxBatch(function()
            gl.LineWidth(2)
            gl.BeginEnd(GL.LINES,function()
                for i=first,last do local f=uxFeatures[i]; local c=f.colour
                    gl.Color(c[1],c[2],c[3],math.min(1,ux.opacity+0.35))
                    if f.line then
                        if f.pattern then drawPat(STYLE[f.pattern],f.line) else solid(f.line) end
                        if f.arrow then
                            local a=f.arrow;local tx,tz=a.x+a.dx*100,a.z+a.dz*100
                            seg(a.x,a.z,tx,tz);seg(tx,tz,tx-a.dx*30-a.dz*20,tz-a.dz*30+a.dx*20)
                            seg(tx,tz,tx-a.dx*30+a.dz*20,tz-a.dz*30-a.dx*20)
                        end
                        if string.find(f.id,"^passage:") then
                            local p=f.line; local dx,dz=p[3]-p[1],p[4]-p[2];local len=math.sqrt(dx*dx+dz*dz)
                            if len>0 then for j=1,3,2 do seg(p[j]-dz/len*24,p[j+1]+dx/len*24,p[j]+dz/len*24,p[j+1]-dx/len*24) end end
                        end
                    elseif f.loops then solidLoops(f.loops)
                    elseif f.category then
                        if f.category=="defensive" or f.category=="high" then triangle(f.x,f.z,48)
                        elseif f.category=="staging" then ngon(f.x,f.z,48,4)
                        elseif f.category=="resources" then ngon(f.x,f.z,40,6)
                        else ngon(f.x,f.z,40,8) end
                    end
                end
            end)
        end)
    end
    status = string.format("%s: %d features · initial-map analysis",ux.view,#uxFeatures)
    if m.experience~=2 then status="Legacy terrain: physical crossings and movement access unavailable" end
end
compileAll = function()
    disposeLists(); clearUxLists()
    if not model then return end
    model.cellGround={};model.groundCount={}
    for _,r in ipairs(model.groundRuns) do model.groundCount[r[2]]=(model.groundCount[r[2]] or 0)+r[3] end
    findSummits(model)
    if ux.side>=0 then
        local found=false;for _,s in ipairs(model.sides) do if s.ally==ux.side then found=true end end
        if not found then ux.side=-1;uxNotice="Saved ally team is absent; perspective reset to Neutral" end
    end
    uxMetrics={prepareMs=0,maxSliceMs=0,batches=0}
    uxJob=coroutine.create(uxPrepare)
    status="Preparing "..ux.view.." geometry"
end
local function uxChange(key,value)
    ux[key]=value;ux.preset="Custom"
    if ux.compare==ux.primary then ux.compare=-1 end
    if key=="background" then setGround(on and value=="off") end
    if key~="inspect" and key~="labels" and key~="advanced" and key~="collapsed" then compileAll() end
    if key=="inspect" and not value then uxFocus=nil end
end
local function uxPreset(name)
    if presets[name] then
        local shown=on; config(copy(presets[name])); on=shown;ux.preset=name;compileAll();return
    end
    ux.categories={resources=true,coastal_access=true};ux.primary=0;ux.compare=-1;ux.side=-1;ux.debug=false;ux.debugCandidates=false;ux.debugIds=false
    ux.detail="essential";ux.labels="names";ux.background="normal";ux.opacity=0.35
    ux.view=name=="Ground approaches" and "approaches" or name=="Coastal access" and "positions" or "terrain"
    if name=="Coastal access" then ux.primary=3;ux.compare=2;ux.categories={coastal_access=true} end
    ux.preset=name;setGround(false);compileAll()
end
local originalSnapshot=snapshot
snapshot=function()
    local out=originalSnapshot();out.settings=copy(ux);out.features={};out.metrics=copy(uxMetrics)
    out.layers={ground=ux.view=="terrain",access=ux.view=="approaches",positions=ux.view=="positions",regions=ux.debug,labels=ux.labels~="off"}
    out.ready=model~=nil and uxJob==nil;out.fingerprint=model and model.fingerprint
    for _,f in ipairs(uxFeatures) do out.features[#out.features+1]={id=f.id,name=f.name,reason=f.reason,basis=f.basis} end
    return out
end
config=function(data)
    if type(data)~="table" then return end
    if data.schemaVersion~=2 then
        legacyConfig=copy(data);ux.detail=data.detail=="tactical" and "detailed" or "essential"
        ux.background=data.blueprint and "off" or data.dim and "dim" or "normal";ux.debug=false
    else
        local enums={view={terrain=true,approaches=true,positions=true},detail={essential=true,detailed=true},labels={off=true,names=true,measurements=true},background={normal=true,dim=true,off=true}}
        for k,values in pairs(enums) do if values[data[k]] then ux[k]=data[k] end end
        for _,k in ipairs({"inspect","debug","debugCandidates","debugIds","advanced","collapsed"}) do if type(data[k])=="boolean" then ux[k]=data[k] end end
        for _,k in ipairs({"primary","compare"}) do if type(data[k])=="number" and data[k]==math.floor(data[k]) and data[k]>= (k=="compare" and -1 or 0) and data[k]<=7 then ux[k]=data[k] end end
        if ux.primary==ux.compare then ux.compare=-1 end
        if type(data.side)=="number" and data.side==math.floor(data.side) and data.side>=-1 then ux.side=data.side end
        if type(data.opacity)=="number" and data.opacity==data.opacity then ux.opacity=math.max(0.1,math.min(0.8,data.opacity)) end
        if type(data.categories)=="table" then ux.categories={};for _,c in ipairs(categoryNames) do ux.categories[c[1]]=data.categories[c[1]]==true end end
        if type(data.presets)=="table" then presets=copy(data.presets) end
        if type(data.preset)=="string" then ux.preset=data.preset end
        legacyConfig=data.legacyConfig
        if type(data.shown)=="boolean" then on=data.shown end
    end
    options.legend=data.legend~=false
    if type(data.dock)=="table" and type(data.dock.x)=="number" and type(data.dock.y)=="number" then dockX,dockY=data.dock.x,data.dock.y end
    if model then compileAll() end
end
getConfig=function()
    local out=copy(ux);out.shown=on;out.legend=options.legend;out.dock={x=dockX,y=dockY};out.presets=copy(presets);out.legacyConfig=legacyConfig
    return out
end
setMode=function(value)
    local was=on;on=value==true;options.legend=on
    setGround(on and ux.background=="off")
    if on and model and #uxLists==0 and not uxJob then compileAll() end
    return was~=on
end
update=function(dataRequested)
    if not on and not dataRequested then return end
    if on then setGround(ux.background=="off") end
    if parse then
        -- A single access/ground record can contain thousands of runs. The
        -- line-count budget alone cannot bound that work. Yield every 256
        -- runs within a record; Lua 5.1 must use resume, not pcall, to yield.
        local started=Spring.GetTimer()
        repeat
            if not parseJob then parseJob=coroutine.create(stepParse) end
            local ok,err=coroutine.resume(parseJob)
            if not ok then parse=nil;parseJob=nil;status="Invalid terrain file: "..tostring(err)
            elseif coroutine.status(parseJob)=="dead" then parseJob=nil end
        until not parse or Spring.DiffTimers(Spring.GetTimer(),started)>=0.002
    elseif not model then tryLoad() end
    if uxJob then
        local t=Spring.GetTimer()
        repeat
            local ok,err=coroutine.resume(uxJob)
            if not ok then uxJob=nil;status="Geometry preparation failed: "..tostring(err);break end
            if coroutine.status(uxJob)=="dead" then uxJob=nil end
        until not uxJob or Spring.DiffTimers(Spring.GetTimer(),t)>=0.002
        local ms=Spring.DiffTimers(Spring.GetTimer(),t)*1000
        uxMetrics.prepareMs=uxMetrics.prepareMs+ms;uxMetrics.maxSliceMs=math.max(uxMetrics.maxSliceMs,ms)
    end
end
drawWorld=function()
    if not on or not model or Spring.IsGUIHidden() then return end
    gl.DepthTest(false)
    if ux.background=="dim" then
        gl.Color(0.02,0.03,0.04,0.5)
        gl.BeginEnd(GL.QUADS,function() gl.Vertex(0,0,0);gl.Vertex(Game.mapSizeX,0,0);gl.Vertex(Game.mapSizeX,0,Game.mapSizeZ);gl.Vertex(0,0,Game.mapSizeZ) end)
    end
    for _,id in ipairs(uxLists) do gl.CallList(id) end
    local f=uxFocus and uxFeatures[uxFocus]
    if f then gl.Color(1,1,1,1);gl.LineWidth(3);gl.BeginEnd(GL.LINES,function() ngon(f.x,f.z,75,12) end) end
    gl.LineWidth(1);gl.Color(1,1,1,1);gl.DepthTest(true)
end
drawMiniMap=function() end -- world view owns the configured feature set; no hidden minimap layers
local function uxChoose(id,x,y,w,title,items,key)
    button(id,x,y,w,title,false,function() uxMenu={x=x,y=y,items=items,key=key,w=w} end)
end
drawScreen=function()
    controls={};legendRect=nil
    if not on or Spring.IsGUIHidden() then return end
    local vw,vh=gl.GetViewSizes()
    if ux.labels~="off" then
        local occupied={};local projected=0
        -- Eligibility is cached with geometry; never scan unnamed borders each frame.
        for _,f in ipairs(uxLabelFeatures) do
            local sx,sy,sz=Spring.WorldToScreenCoords(f.x,f.y,f.z);projected=projected+1
            if sx and sz and sz>0 and sz<1 and sx>0 and sx<vw and sy>0 and sy<vh then
                local bx,by=math.floor(sx/150),math.floor(sy/24);local key=bx..":"..by
                if not occupied[key] then
                    occupied[key]=true;gl.Color(f.colour[1],f.colour[2],f.colour[3],1)
                    local label=f.name
                    if ux.labels=="measurements" and ux.detail=="detailed" and f.measurement then label=label.." "..f.measurement end
                    if ux.debugIds then label=label.." ["..f.id.."]" end
                    gl.Text(label,sx,sy,11,"oc")
                end
            end
            if projected>=200 then break end
        end
    end
    if not options.legend then return end
    local w=480;local h=ux.collapsed and 40 or (440+(ux.advanced and 130 or 0)+(uxFocus and ux.inspect and 90 or 0))
    -- Keep the complete panel reachable on small/resized viewports. Only UI
    -- geometry scales; terrain features and display settings stay unchanged.
    local scale=math.min(1,math.max(1,vw-16)/w,math.max(1,vh-16)/h)
    dockX=math.max(8,math.min(vw-w*scale-8,dockX or vw-w*scale-20))
    dockY=math.max(h*scale+8,math.min(vh-8,dockY or vh-110))
    local x,top=dockX/scale,dockY/scale;legendRect={x,top-h,x+w,top}
    local function finishPanel()
        gl.PopMatrix()
        for _,r in ipairs(controls) do for i=1,4 do r[i]=r[i]*scale end end
        for i=1,4 do legendRect[i]=legendRect[i]*scale end
        gl.Color(1,1,1,1)
    end
    gl.PushMatrix();gl.Scale(scale,scale,1)
    local vw,vh=vw/scale,vh/scale
    gl.Color(inkPanel);gl.Rect(x,top-h,x+w,top)
    gl.Color(mint);gl.Text("MAP ANALYSIS",x+12,top-24,14,"o")
    controls[#controls+1]={x,top-34,x+w-100,top,id="fieldDrag",action=function() end}
    button("fieldCollapse",x+w-94,top-32,40,ux.collapsed and "+" or "-",false,function() ux.collapsed=not ux.collapsed end)
    button("fieldHide",x+w-50,top-32,42,"Hide",false,function() setMode(false) end)
    if ux.collapsed then finishPanel();return end
    local y=top-66
    for i,v in ipairs({"terrain","approaches","positions"}) do
        button("view_"..v,x+12+(i-1)*150,y,144,v,ux.view==v,function() uxChange("view",v) end)
    end
    y=y-34
    local title="Movement: "..(CLASS_NAMES[ux.primary] or "deep-draft")
    if ux.view~="terrain" then
        uxChoose("movement",x+12,y,220,title,movement,"primary")
        local cmp={{-1,"None"}};for _,v in ipairs(movement) do if v[1]~=ux.primary then cmp[#cmp+1]=v end end
        uxChoose("compare",x+240,y,220,"Compare: "..(ux.compare<0 and "None" or CLASS_NAMES[ux.compare] or "deep-draft"),cmp,"compare")
    else gl.Color(muted);gl.Text("Movement filters inactive: Terrain is a physical overview",x+12,y+8,11,"o") end
    y=y-32
    local sides={{-1,"Neutral"}};for _,s in ipairs(model and model.sides or {}) do if s.ally>=0 then sides[#sides+1]={s.ally,"Ally team "..s.ally.." (setup)"} end end
    uxChoose("perspective",x+12,y,220,ux.side<0 and "Perspective: Neutral" or "Setup ally team "..ux.side,sides,"side")
    uxChoose("detail",x+240,y,220,"Detail: "..ux.detail,{{"essential","Essential"},{"detailed","Detailed"}},"detail")
    y=y-32
    uxChoose("labels",x+12,y,220,"Labels: "..ux.labels,{{"off","Off"},{"names","Names"},{"measurements","Measurements"}},"labels")
    uxChoose("background",x+240,y,220,"Background: "..ux.background,{{"normal","Normal"},{"dim","Dim"},{"off","Off"}},"background")
    y=y-32
    local choices={{"Terrain overview","Terrain overview"},{"Ground approaches","Ground approaches"},{"Coastal access","Coastal access"}}
    local names={};for name in pairs(presets) do names[#names+1]=name end;table.sort(names);for _,name in ipairs(names) do choices[#choices+1]={name,name} end
    uxChoose("preset",x+12,y,220,"Preset: "..ux.preset,choices,"preset")
    button("savePreset",x+240,y,106,"Save preset",false,function()
        local name="Saved "..(#names+1);local p=copy(ux);p.schemaVersion=2;presets[name]=p;ux.preset=name
    end)
    button("resetView",x+354,y,106,"Reset view",false,function()
        ux.detail="essential";ux.labels="names";ux.debug=false;ux.debugCandidates=false;ux.debugIds=false;ux.inspect=false
        if ux.view~="terrain" then ux.primary=0;ux.compare=-1;ux.side=-1 end
        if ux.view=="positions" then ux.categories={resources=true,coastal_access=true} end
        compileAll()
    end)
    y=y-32
    button("inspect",x+12,y,144,"Inspect: "..(ux.inspect and "On" or "Off"),ux.inspect,function() uxChange("inspect",not ux.inspect) end)
    button("advanced",x+162,y,144,"Advanced",ux.advanced,function() ux.advanced=not ux.advanced end)
    button("opacity",x+312,y,148,string.format("Opacity: %.0f%%",ux.opacity*100),false,function() uxChange("opacity",ux.opacity>=0.75 and 0.15 or ux.opacity+0.1) end)
    y=y-28
    if ux.view=="positions" then
        for i,c in ipairs(categoryNames) do
            button("category_"..c[1],x+12+((i-1)%3)*150,y-math.floor((i-1)/3)*28,144,c[2],ux.categories[c[1]],function() ux.categories[c[1]]=not ux.categories[c[1]];ux.preset="Custom";compileAll() end)
        end
        y=y-58
    else
        gl.Color(muted);gl.Text(ux.view=="approaches" and "Slash: primary only   Cross: comparison only   Plain: shared" or "Edges: physical transitions   Open ground: no partition lines",x+12,y+6,10,"o");y=y-28
    end
    if ux.inspect then
        local fs={};for i,f in ipairs(uxFeatures) do
            fs[#fs+1]={i,f.name..(ux.debugIds and (" ("..f.id..")") or (" #"..i))}
        end
        uxChoose("feature",x+12,y,350,uxFocus and uxFeatures[uxFocus] and uxFeatures[uxFocus].name or "Choose a visible feature",fs,"focus")
        button("clearFocus",x+370,y,90,"Clear",false,function() uxFocus=nil end);y=y-30
    end
    local f=uxFocus and uxFeatures[uxFocus]
    if f and ux.inspect then
        gl.Color(mint);gl.Text(f.basis or "Terrain-derived",x+12,y+5,11,"o");y=y-16
        local types={};for cls=0,7 do if hasBit(f.mask or 0,cls) then types[#types+1]=CLASS_NAMES[cls] or "deep-draft" end end
        gl.Color(muted);gl.Text(#types>0 and ("Movement: "..table.concat(types,", ")) or "Physical geography; no movement claim",x+12,y,9,"o");y=y-16
        -- Wrapped card text stays inside the panel at small resolutions.
        local line="";for word in string.gmatch(f.reason or "", "%S+") do
            if #line+#word>68 then gl.Color(muted);gl.Text(line,x+12,y,10,"o");y=y-14;line="" end
            line=line..word.." "
        end
        gl.Color(muted);gl.Text(line,x+12,y,10,"o");y=y-18
    end
    if ux.advanced then
        button("debugBoundaries",x+12,y,280,"Debug: analysis boundaries",ux.debug,function() uxChange("debug",not ux.debug) end)
        button("resetAll",x+300,y,160,"Reset all",false,function()
            uxPreset("Terrain overview");ux.inspect=false;ux.advanced=false;ux.collapsed=false;dockX=nil;dockY=nil
        end);y=y-30
        button("debugCandidates",x+12,y,280,"Debug: clearance candidates",ux.debugCandidates,function() uxChange("debugCandidates",not ux.debugCandidates) end)
        button("debugIds",x+300,y,160,"Source IDs",ux.debugIds,function() uxChange("debugIds",not ux.debugIds) end);y=y-30
        local cl=model and model.classes[ux.primary]
        gl.Color(muted);gl.Text(cl and string.format("Representative: slope %.0f deg; depth %.0f..%.0f (-1 unbounded)",cl.slope,cl.minDepth,cl.maxDepth) or "Representative movement assumptions unavailable",x+12,y,10,"o")
        y=y-18;gl.Text("Terrain-derived, not engine-checked for every unit. Initial map only.",x+12,y,10,"o")
    end
    gl.Color(muted);gl.Text(status,x+12,top-h+28,10,"o");gl.Text(uxNotice,x+12,top-h+12,9,"o")
    if uxMenu then
        local menu=uxMenu;local mh=math.min(#menu.items,12)*25
        local mx=math.max(8,math.min(vw-358,menu.x))
        local my=math.min(vh-8,math.max(mh+(#menu.items>12 and 33 or 8),menu.y))
        gl.Color(inkPanel);gl.Rect(mx,my-mh,mx+350,my)
        local offset=menu.offset or 0
        for n=1,math.min(12,#menu.items-offset) do local item=menu.items[n+offset]
            button("menu_"..n,mx,my-n*25,350,item[2],false,function()
                uxMenu=nil
                if menu.key=="focus" then uxFocus=item[1]
                elseif menu.key=="preset" then uxPreset(item[1])
                else uxChange(menu.key,item[1]) end
            end)
        end
        if #menu.items>12 then
            button("menuNext",mx,my-mh-25,350,"Next page",false,function() menu.offset=(offset+12<#menu.items) and offset+12 or 0 end)
        end
    end
    finishPanel()
end
mousePress=function(x,y,b)
    if not on or Spring.IsGUIHidden() then return false end
    local r=hitAt(x,y)
    if r then if b==1 then pressed=r;if r.id=="fieldDrag" then drag={x,y,dockX,dockY} end end;return true end
    if uxMenu then uxMenu=nil;return true end
    if legendRect and x>=legendRect[1] and x<=legendRect[3] and y>=legendRect[2] and y<=legendRect[4] then return true end
    if ux.inspect and b==1 then
        local best,dist=nil,28*28
        for i,f in ipairs(uxFeatures) do local sx,sy,sz=Spring.WorldToScreenCoords(f.x,f.y,f.z)
            if sx and sz and sz>0 and sz<1 then local d=(sx-x)^2+(sy-y)^2;if d<dist then best,dist=i,d end end
        end
        uxFocus=best;return true
    end
    return false
end
setLayer=function(name,value)
    if name=="regions" then uxChange("debug",value==true);return true end
    if name=="labels" then uxChange("labels",value and "names" or "off");return true end
    return false
end
setFocus=function(kind,id)
    uxFocus=nil;if kind then for i,f in ipairs(uxFeatures) do if f.id==kind..":"..tostring(id) then uxFocus=i;break end end end
end
setBlueprint=function(v) uxChange("background",v and "off" or "normal") end
textCommand=function(cmd)
    if cmd=="barbterrain" or cmd=="barbfield" then setMode(not on);return true end
    local sub=string.match(cmd,"^barbterrain%s+(.+)$") or string.match(cmd,"^barbfield%s+(.+)$")
    if not sub then return false end
    if sub=="on" or sub=="show" then setMode(true)
    elseif sub=="off" or sub=="hide" then setMode(false)
    elseif sub=="legend" then options.legend=not options.legend
    elseif sub=="pick" then uxChange("inspect",not ux.inspect)
    elseif sub=="blueprint" then setBlueprint(ux.background~="off")
    elseif sub=="dim" then uxChange("background",ux.background=="dim" and "normal" or "dim")
    elseif sub=="detail strategic" or sub=="detail auto" then uxChange("detail","essential")
    elseif sub=="detail tactical" then uxChange("detail","detailed")
    else Spring.Echo("[BARb] Configure Map Analysis in the widget panel") end
    return true
end
shutdown=function() clearUxLists();disposeLists();setGround(false);on=false end
return {SetMode=setMode, Mode=function() return on end, Status=function() return status end, Snapshot=snapshot,
    View=function() return ux.view end,
    SetLayer=setLayer, SetFocus=setFocus, SetBlueprint=setBlueprint, SetLegend=function(v) options.legend = v and true or false end,
    SetSide=function(v) uxChange("side",(type(v)=="number" and v>=0) and v or -1) end,
    Legend=function() return options.legend end, Config=config, GetConfig=getConfig, TextCommand=textCommand,
    Update=update, DrawWorld=drawWorld, DrawScreen=drawScreen, DrawMiniMap=drawMiniMap, Shutdown=shutdown,
    SetAllyProvider=function() end, -- compatibility only; roster never drives map analysis
    -- read-only access for the landmarks view: the parsed map.txt (grid, fingerprint, chokes)
    -- and the soft-edged run-length fill, so both views fill territory the same way
    Model=function() return model end,
    FillRuns=function(m, runs, cells, want, c, a) fillWith(c, a); fillRuns(m, runs, cells, want, nil) end,
    ButtonRect=function(id) for _, r in ipairs(controls) do if r.id == id then return {r[1], r[2], r[3], r[4]} end end end,
    MousePress=mousePress, MouseRelease=mouseRelease, MouseMove=mouseMove}
end)()

-- ---------------------------------------------------------------- marks
-- Strategic landmarks and the opening per start position (field-landmarks
-- proposal, section 7): a second file written once by the same BARb field
-- service right after map.txt, LuaUI/Config/BARb/field/landmarks.txt. Like the
-- terrain map it is read once when the view is turned on, parsed over Update
-- calls (64 lines per step, 2 ms), and drawn from one display list per layer.
-- Cost: after load nothing is parsed or scanned per frame; drawing is about ten
-- CallList calls plus at most 200 labels. The lists are compiled a few per
-- Update (the incremental compile KI-643 asks of Terrain), and the territory
-- cell expansion and border edges are built in time-boxed steps before that.
-- A new selection recompiles only the selection layers (territory fill,
-- landings, ring, minimap) and the card; a new phase only the mark layers; a
-- roster change (polled every 2 s while shown) only the position layer.
-- D-325: every kind of mark differs by shape first; colour (Okabe-Ito) only
-- repeats it, and every line is cased in ink (the halo pass).
-- Grammar: the landmarks.txt record list (format 1); unknown records are ignored.
local marks = (function()
local PATH = "LuaUI/Config/BARb/field/landmarks.txt"
local FACTIONS = {"armada", "cortex", "legion"}
local FACTION_NAME = {armada="Armada", cortex="Cortex", legion="Legion"}
local PHASES = {
    {key="0-5", lo=0, hi=5}, {key="5-15", lo=5, hi=15}, {key="15-25", lo=15, hi=25}, {key="25+", lo=25, hi=1e9}, {key="all"},
}
local PHASE_KEYS = {}
local PHASE_BY_KEY = {}
for i, p in ipairs(PHASES) do PHASE_KEYS[i] = p.key; PHASE_BY_KEY[p.key] = p end
-- every display list, in compile order; DRAW_ORDER is the world draw order
local LAYER_ORDER = {"dim", "terrOutline", "terrSel", "seazone", "economy", "land", "sea", "late", "landing", "positions", "selRing", "minimap"}
local DRAW_ORDER = {"terrOutline", "terrSel", "seazone", "economy", "land", "sea", "late", "landing", "positions", "selRing"}
-- "late" reads the selection too: only the selected side's anti-nuke coverage circles are drawn
local BY_SELECTION = {"terrSel", "landing", "late", "selRing", "minimap"}
-- above LABEL_HEIGHT (the strategic view) the mark layers switch to a second list in which
-- the labelled marks' glyphs are FAR_SCALE times larger, so they stay readable from far
local FAR_SCALE = 3
local BY_PHASE = {"seazone", "economy", "land", "sea", "late", "landing", "minimap"}
local BY_ROSTER = {"positions"}
local CLASS_WORD = {bot="Bot lab", vehicle="Vehicle plant", hover="Hover plant", ship="Shipyard", air="Aircraft plant"}
local MATCH_RADIUS = 800      -- elmos: a roster start this close to a position is that position's AI
local POS_R = 80              -- position disc radius, elmos
local LABEL_CAP = 200
local LABEL_HEIGHT = 6000     -- above this camera height labels shrink and labelled glyphs draw FAR_SCALE larger
local options = {legend=false, phase="all", faction=nil}
local on = false
local model, parse, prep, seq = nil, nil, nil, nil
local lastExists = nil
local status = "Landmarks hidden"
local lists = {}
local pending, pendingSet = {}, {}
local labelsAll = {}
local selected = nil          -- the selected position index
local inspectLines = nil      -- the clicked mark's record
local fieldApi = nil          -- the terrain module: map.txt grid, fingerprint and chokes, its fill routine
local rosterProvider = nil    -- function() -> {{teamId=, allyTeam=, role=, side=, factory=, x=, z=}, ...}
local mineProvider = nil      -- function() -> x, z of the viewer's start (spectating: the panel's selected AI)
local rosterSig, rosterTimer = "", nil
local panelRects = {}
local card = nil              -- the selected position's opening card

local K = {
    white  = {1,1,1},
    grey   = {0.72,0.72,0.74},
    orange = {0.90,0.62,0.00},
    sky    = {0.34,0.71,0.91},
    green  = {0.00,0.62,0.45},
    yellow = {0.94,0.89,0.26},
    blue   = {0.00,0.45,0.70},
    verm   = {0.84,0.37,0.00},
    purple = {0.80,0.47,0.65},
    teal   = {0.15,0.65,0.62},
    ink    = {0.025,0.045,0.07},
}
local mint, muted = {0.35,0.9,0.73,1}, {0.65,0.73,0.8,1}
local inkPanel = {0.025,0.045,0.07,0.94}

local function split(s, sep)
    local out, from = {}, 1
    while true do
        local a, b = string.find(s, sep, from, true)
        if not a then out[#out+1] = string.sub(s, from); break end
        out[#out+1] = string.sub(s, from, a-1); from = b+1
    end
    return out
end
local function poly(s)
    local p = {}
    if not s then return p end
    for x, z in string.gmatch(s, "(-?%d+%.?%d*),(-?%d+%.?%d*)") do p[#p+1] = tonumber(x); p[#p+1] = tonumber(z) end
    return p
end
local function num(v, d) return tonumber(v) or d or 0 end
local function loose(name) return string.lower((string.gsub(name or "", "[%s%._%-]", ""))) end
local function groundY(x, z) return math.max(0, Spring.GetGroundHeight(x, z)) + 8 end
local function words(s, sep)
    local out = {}
    if not s or s == "" or s == "-" then return out end
    for _, v in ipairs(split(s, sep)) do
        local t = string.match(v, "^%s*(.-)%s*$")
        if t and t ~= "" then out[#out+1] = t end
    end
    return out
end
local function normFaction(side)
    local s = string.lower(side or "")
    if string.find(s, "arm", 1, true) then return "armada" end
    if string.find(s, "cor", 1, true) then return "cortex" end
    if string.find(s, "leg", 1, true) then return "legion" end
    return nil
end
local function fieldModel() return fieldApi and fieldApi.Model and fieldApi.Model() or nil end

-- ---- parsing
local function newModel()
    return {name="", fieldFp="", marksFp="", env={minWind=0, maxWind=0, tidal=0, diag=0}, factories={},
        positions={}, order={}, features={}, openings={}, marks={}, terrRuns={}, terrCount=0, cellPos={}, edges={}, byLayer={},
        gw=0, gh=0, cell=32, terrOk=false}
end
local function parseRecord(m, line)
    local f = split(line, "|")
    local k = f[1]
    if k == "mark" then
        local pl = f[15]
        m.marks[#m.marks+1] = {id=num(f[2]), group=f[3] or "", kind=f[4] or "", x=num(f[5]), z=num(f[6]), value=num(f[7]),
            pos=num(f[8], -1), ally=num(f[9], -1), contested=f[10] == "1", from=num(f[11], 0), to=num(f[12], -1),
            labelled=f[13] == "1", reason=f[14] or "", line=(pl and pl ~= "-" and pl ~= "") and poly(pl) or nil}
    elseif k == "position" then
        local i = tonumber(f[2])
        if i then
            if not m.positions[i] then m.order[#m.order+1] = i end
            m.positions[i] = {index=i, name=f[3] or ("P" .. i), ally=num(f[4], -1), n=num(f[5]), x=num(f[6]), z=num(f[7]),
                source=f[8] or "predicted", label=f[9] or "", sublabel=f[10] or "-", frontShare=num(f[11]), rearRank=num(f[12]), cells=num(f[13])}
        end
    elseif k == "opening" then
        local i = tonumber(f[2])
        if i then m.openings[i] = {class=f[3] or "", fallbacks=words(f[4], ","), energy=f[5] or "", second=f[6] or "", reasons=words(f[7], ";")} end
    elseif k == "feature" then
        local i = tonumber(f[2])
        if i then
            local g = {}
            for v in string.gmatch(f[3] or "", "-?%d+") do g[#g+1] = tonumber(v) end
            local yx, yz = string.match(f[11] or "", "(-?%d+),(-?%d+)")
            m.features[i] = {ground=g, openWidth=num(f[4]), vehShare=num(f[5]), metal=num(f[6]), clusters=num(f[7]), geos=num(f[8]),
                geoDist=num(f[9], -1), sea=num(f[10], -1), yardX=num(yx, -1), yardZ=num(yz, -1), yardDist=num(f[12], -1),
                pondCells=num(f[13]), assaultRank=num(f[14]), island=f[15] == "1"}
        end
    elseif k == "territory" then
        -- run-length position index per cell (-1 = none), the same form as map.txt cells|
        local runs, start = m.terrRuns, m.terrCount
        for id, count in string.gmatch(f[2] or "", "(-?%d+)%*(%d+)") do
            local n = tonumber(count)
            runs[#runs+1] = {start, tonumber(id), n}
            start = start + n
        end
        m.terrCount = start
    elseif k == "env" then
        m.env = {minWind=num(f[2]), maxWind=num(f[3]), tidal=num(f[4]), diag=num(f[5])}
    elseif k == "factory" and f[2] then
        local function id(v) if v == nil or v == "" or v == "-" then return nil end return v end
        m.factories[f[2]] = {armada=id(f[3]), cortex=id(f[4]), legion=id(f[5])}
    end
end

local function beginParse(text)
    local fmt, name, ffp, mfp, fseq = string.match(text, "^barbmarks|(%d+)|([^|]*)|([^|]*)|([^|]*)|(%d+)")
    if not fmt then return false, "unexpected header" end
    if tonumber(fmt) ~= 1 then return false, "format " .. tostring(fmt) end
    local trailer = "\nend|" .. fseq
    local tp = string.find(text, trailer, 1, true)
    if not tp then return false, "torn file" end
    local after = string.sub(text, tp + #trailer, tp + #trailer)
    if after ~= "" and after ~= "\n" and after ~= "\r" then return false, "torn file" end
    if name ~= "" and Game.mapName and loose(name) ~= loose(Game.mapName)
        and not string.find(loose(Game.mapName), loose(name), 1, true) and not string.find(loose(name), loose(Game.mapName), 1, true) then
        return false, "file is for map '" .. name .. "'"
    end
    local fm = fieldModel()
    if fm and fm.fingerprint and ffp ~= fm.fingerprint then return false, "fingerprint differs from map.txt" end
    local m = newModel()
    m.name, m.fieldFp, m.marksFp = name, ffp, mfp
    parse = {text=text, pos=1, m=m, seq=tonumber(fseq)}
    return true
end

local finishModel   -- forward
local function stepParse()
    if not parse then return end
    local t0 = Spring.GetTimer()
    local text, pos = parse.text, parse.pos
    local lines = 0
    while true do
        local e = string.find(text, "\n", pos, true)
        local line = e and string.sub(text, pos, e-1) or string.sub(text, pos)
        if string.sub(line, -1) == "\r" then line = string.sub(line, 1, -2) end
        if #line > 0 and not string.find(line, "^barbmarks") and not string.find(line, "^end|") then parseRecord(parse.m, line) end
        pos = e and e + 1 or #text + 1
        lines = lines + 1
        if pos > #text then break end
        if lines % 64 == 0 and Spring.DiffTimers(Spring.GetTimer(), t0) > 0.002 then break end
    end
    parse.pos = pos
    if pos > #text then
        local m, s = parse.m, parse.seq
        parse = nil
        finishModel(m, s)
    else
        status = string.format("Reading landmarks %d%%", math.floor(100 * pos / math.max(1, #text)))
    end
end
local function tryLoad()
    if not (VFS and VFS.LoadFile and VFS.FileExists) then status = "VFS unavailable"; return end
    local now = Spring.GetTimer()
    if lastExists and Spring.DiffTimers(now, lastExists) < 2 then return end
    lastExists = now
    if not VFS.FileExists(PATH, VFS.RAW) then
        if string.sub(status, 1, 15) ~= "Landmarks file " then status = "Landmarks: waiting for file" end
        return
    end
    local ok, text = pcall(VFS.LoadFile, PATH, VFS.RAW)
    if not ok or type(text) ~= "string" or #text == 0 then status = "Cannot read " .. PATH; return end
    local good, err = beginParse(text)
    if not good then status = "Landmarks file skipped: " .. tostring(err) end
end

-- ---- line generation: the same emitter idea as the terrain map. In world space seg()
-- splits long segments so a line follows the ground; for a legend sample `flatY` is the
-- sample's screen y and a map z is mirrored about it, so north stays up and every
-- legend glyph is drawn by exactly the code that draws the map. Line layers are
-- compiled twice: an ink under-stroke three pixels wider, then the colour.
local SEG_MAX = 128
local flatY = nil
local patScale = 1
local haloPass = false
local function vtx(x, z)
    if flatY then gl.Vertex(x, 2*flatY - z) else gl.Vertex(x, groundY(x, z), z) end
end
local function seg(ax, az, bx, bz)
    if flatY then vtx(ax, az); vtx(bx, bz); return end
    local dx, dz = bx - ax, bz - az
    local n = math.max(1, math.ceil(math.sqrt(dx*dx + dz*dz) / SEG_MAX))
    local px, pz = ax, az
    for i = 1, n do
        local x, z = ax + dx*i/n, az + dz*i/n
        vtx(px, pz); vtx(x, z)
        px, pz = x, z
    end
end
local function solid(p) for i = 3, #p, 2 do seg(p[i-2], p[i-1], p[i], p[i+1]) end end
local function dashed(p, onLen, offLen)
    local runs = {onLen * patScale, offLen * patScale}
    local k, phase = 1, 0
    for i = 3, #p, 2 do
        local ax, az, bx, bz = p[i-2], p[i-1], p[i], p[i+1]
        local dx, dz = bx-ax, bz-az
        local len = math.sqrt(dx*dx + dz*dz)
        if len > 0 then
            dx, dz = dx/len, dz/len
            local t = 0
            while t < len do
                local run = runs[k] - phase
                local t2 = math.min(len, t + run)
                if k == 1 then seg(ax+dx*t, az+dz*t, ax+dx*t2, az+dz*t2) end
                if t2 >= len then phase = phase + (len - t) else phase = 0; k = 3 - k end
                t = t2
            end
        end
    end
end
local function stroke(c, a, w)
    if haloPass then gl.Color(K.ink[1], K.ink[2], K.ink[3], 0.85); gl.LineWidth((w or 2) + 3)
    else gl.Color(c[1], c[2], c[3], a or 1); gl.LineWidth(w or 2) end
end
local function ngon(x, z, r, n, dash)
    local px, pz
    for i = 0, n do
        local a = i * 2 * math.pi / n
        local cx, cz = x + math.cos(a)*r, z + math.sin(a)*r
        if px and (not dash or i % 2 == 0) then seg(px, pz, cx, cz) end
        px, pz = cx, cz
    end
end
local function disc(x, z, r)
    -- a filled disc (inside gl.BeginEnd(GL.TRIANGLES))
    local n = 20
    for i = 0, n - 1 do
        local a1, a2 = i * 2 * math.pi / n, (i + 1) * 2 * math.pi / n
        vtx(x, z); vtx(x + math.cos(a1)*r, z + math.sin(a1)*r); vtx(x + math.cos(a2)*r, z + math.sin(a2)*r)
    end
end
local function polyMid(p)
    if #p < 4 then return p[1] or 0, p[2] or 0 end
    local total = 0
    for i = 3, #p, 2 do local dx, dz = p[i]-p[i-2], p[i+1]-p[i-1]; total = total + math.sqrt(dx*dx+dz*dz) end
    local half, acc = total / 2, 0
    for i = 3, #p, 2 do
        local dx, dz = p[i]-p[i-2], p[i+1]-p[i-1]
        local len = math.sqrt(dx*dx+dz*dz)
        if acc + len >= half and len > 0 then
            local f = (half - acc) / len
            return p[i-2] + dx*f, p[i-1] + dz*f
        end
        acc = acc + len
    end
    return p[#p-1], p[#p]
end
local function hatch(p, step)
    -- 45-degree hatching inside the closed polygon p (lines x + z = c, even-odd rule)
    local n = math.floor(#p / 2)
    if n < 3 then return end
    local umin, umax = math.huge, -math.huge
    for i = 1, n do
        local u = p[2*i-1] + p[2*i]
        if u < umin then umin = u end
        if u > umax then umax = u end
    end
    step = math.max(step, (umax - umin) / 300)
    local xs = {}
    local c = umin + step * 0.5
    while c < umax do
        local cnt = 0
        for i = 1, n do
            local j = (i % n) + 1
            local ax, az, bx, bz = p[2*i-1], p[2*i], p[2*j-1], p[2*j]
            local ua, ub = ax + az, bx + bz
            if (ua <= c and ub > c) or (ub <= c and ua > c) then
                cnt = cnt + 1
                xs[cnt] = ax + (bx - ax) * (c - ua) / (ub - ua)
            end
        end
        for q = #xs, cnt + 1, -1 do xs[q] = nil end
        table.sort(xs)
        for q = 1, cnt - 1, 2 do seg(xs[q], c - xs[q], xs[q+1], c - xs[q+1]) end
        c = c + step
    end
end

-- ---- glyphs: one shape per kind, centred on (x, z), size r (inside gl.BeginEnd(GL.LINES))
local function square(x, z, r) seg(x-r, z-r, x+r, z-r); seg(x+r, z-r, x+r, z+r); seg(x+r, z+r, x-r, z+r); seg(x-r, z+r, x-r, z-r) end
local function ibeam(x, z, dx, dz, half, serif)
    -- the Terrain choke glyph: a width bar perpendicular to (dx, dz), a serif at each end
    local len = math.sqrt(dx*dx + dz*dz); if len == 0 then dx, dz, len = 0, 1, 1 end
    dx, dz = dx/len, dz/len
    local lx, lz, rx, rz = x - dz*half, z + dx*half, x + dz*half, z - dx*half
    seg(lx, lz, rx, rz)
    seg(lx - dx*serif, lz - dz*serif, lx + dx*serif, lz + dz*serif)
    seg(rx - dx*serif, rz - dz*serif, rx + dx*serif, rz + dz*serif)
end
local function star(x, z, r)
    local px, pz
    for i = 0, 10 do
        local a = -math.pi / 2 + i * math.pi / 5
        local rr = (i % 2 == 0) and r or r * 0.42
        local cx, cz = x + math.cos(a)*rr, z + math.sin(a)*rr
        if px then seg(px, pz, cx, cz) end
        px, pz = cx, cz
    end
end
local function arcUp(x, z, r, n)
    -- the upper half circle (north), a dome
    local px, pz
    for i = 0, n do
        local a = math.pi + i * math.pi / n
        local cx, cz = x + math.cos(a)*r, z + math.sin(a)*r
        if px then seg(px, pz, cx, cz) end
        px, pz = cx, cz
    end
end
local function arcDown(x, z, r, n)
    local px, pz
    for i = 0, n do
        local a = i * math.pi / n
        local cx, cz = x + math.cos(a)*r, z + math.sin(a)*r
        if px then seg(px, pz, cx, cz) end
        px, pz = cx, cz
    end
end
local function dot(x, z, d) seg(x - d, z, x + d, z); seg(x, z - d, x, z + d) end
local function glyph(kind, x, z, r, mk)
    if kind == "metal" then square(x, z, r * 0.7)
    elseif kind == "centre" then star(x, z, r)
    elseif kind == "geo" then
        -- a downward triangle (the Terrain view's upright triangle is high ground)
        seg(x - r, z - r*0.7, x + r, z - r*0.7); seg(x + r, z - r*0.7, x, z + r); seg(x, z + r, x - r, z - r*0.7)
    elseif kind == "tidal" then
        for _, oz in ipairs({-0.3, 0.3}) do
            local zz = z + r * oz
            seg(x - r, zz, x - r*0.5, zz - r*0.25); seg(x - r*0.5, zz - r*0.25, x, zz)
            seg(x, zz, x + r*0.5, zz - r*0.25); seg(x + r*0.5, zz - r*0.25, x + r, zz)
        end
    elseif kind == "choke" then ibeam(x, z, mk.dx or 0, mk.dz or 1, mk.half and math.max(mk.half, r) or r, r * 0.35)
    elseif kind == "killzone" then
        ibeam(x, z, mk.dx or 0, mk.dz or 1, r, r * 0.35)
        seg(x - r*0.6, z - r*0.6, x + r*0.6, z + r*0.6); seg(x - r*0.6, z + r*0.6, x + r*0.6, z - r*0.6)
    elseif kind == "radar" then arcUp(x, z + r*0.3, r, 8); arcUp(x, z + r*0.3, r * 0.55, 6); dot(x, z + r*0.3, r * 0.12)
    elseif kind == "perch" then seg(x - r, z + r*0.4, x, z - r*0.5); seg(x, z - r*0.5, x + r, z + r*0.4)
    elseif kind == "lrpc" then
        -- a tall, narrow double chevron
        for _, oz in ipairs({0, 0.5}) do
            local zz = z + r * oz
            seg(x - r*0.55, zz + r*0.6, x, zz - r*1.1); seg(x, zz - r*1.1, x + r*0.55, zz + r*0.6)
        end
    elseif kind == "forward" then square(x, z, r * 0.8); square(x, z, r * 0.15)
    elseif kind == "yard" then
        -- an anchor: ring, stock, shank, the arms as the lower half circle
        ngon(x, z - r*0.9, r*0.16, 8)
        seg(x - r*0.45, z - r*0.5, x + r*0.45, z - r*0.5)
        seg(x, z - r*0.74, x, z + r*0.8)
        arcDown(x, z, r * 0.8, 8)
    elseif kind == "strait" then seg(x - r, z - r*0.28, x + r, z - r*0.28); seg(x - r, z + r*0.28, x + r, z + r*0.28)
    elseif kind == "emergence" then
        for i = -2, 2 do
            for j = -2, 2 do
                if (i + j) % 2 == 0 and math.abs(i) + math.abs(j) <= 2 then dot(x + i*r*0.4, z + j*r*0.4, r * 0.08) end
            end
        end
    elseif kind == "coastfire" then ngon(x, z, r * 0.8, 16); dot(x, z, r * 0.25)
    elseif kind == "seaplane" then
        seg(x, z - r, x, z + r)
        seg(x - r, z + r*0.2, x, z - r*0.2); seg(x, z - r*0.2, x + r, z + r*0.2)
        seg(x - r*0.4, z + r*0.85, x + r*0.4, z + r*0.85)
    elseif kind == "island" then ngon(x, z, r, 6); ngon(x, z, r * 0.55, 6)
    elseif kind == "antinuke" then
        -- a ring with three spokes; the 2000-elmo coverage circle is drawn by the late layer
        -- for the selected side only (drawn for every site it crossed the whole map as dashes)
        ngon(x, z, r * 0.45, 12)
        for _, a in ipairs({-math.pi / 2, math.pi / 6, 5 * math.pi / 6}) do
            seg(x + math.cos(a) * r * 0.45, z + math.sin(a) * r * 0.45, x + math.cos(a) * r, z + math.sin(a) * r)
        end
    end
end
local function landingGlyph(mk, assault, L)
    -- the beach line; an arrow inland for an assault landing, out to sea for a home landing
    if mk.contested then dashed(mk.line, 40, 20) else solid(mk.line) end
    if assault == nil or not mk.mx then return end
    local dx, dz = mk.nx, mk.nz
    if not assault then dx, dz = -dx, -dz end
    local tx, tz = mk.mx + dx*L, mk.mz + dz*L
    seg(mk.mx - dx*L*0.2, mk.mz - dz*L*0.2, tx, tz)
    local px, pz = -dz, dx
    seg(tx, tz, tx - dx*L*0.4 + px*L*0.3, tz - dz*L*0.4 + pz*L*0.3)
    seg(tx, tz, tx - dx*L*0.4 - px*L*0.3, tz - dz*L*0.4 - pz*L*0.3)
end

-- The style of every kind: shape (above) first, colour second; the text is the legend row.
local KIND = {
    metal     = {c=K.white,  w=1.5, r=28, text="Hollow square: metal cluster (number: metal per second)"},
    centre    = {c=K.white,  w=2,   r=70, text="Star: map centre"},
    geo       = {c=K.yellow, w=2,   r=40, text="Downward triangle: geothermal vent"},
    tidal     = {c=K.sky,    w=2,   r=40, text="Two waves: tidal generator site"},
    choke     = {c=K.white,  w=2.5, r=40, text="Bar with serifs: choke (number: width in elmos)"},
    killzone  = {c=K.verm,   w=2.5, r=50, text="Crossed bar: kill zone, hold the approach here"},
    radar     = {c=K.green,  w=2,   r=45, text="Two arcs over a dot: radar hill"},
    perch     = {c=K.orange, w=2.5, r=45, text="Wide chevron: artillery perch"},
    forward   = {c=K.green,  w=2,   r=45, text="Square with a dot: forward base site"},
    emergence = {c=K.purple, w=2,   r=50, text="Dot cluster: emergence band, amphibious units come ashore"},
    island    = {c=K.teal,   w=2,   r=60, text="Double hexagon: island (its class is in the record)"},
    yard      = {c=K.blue,   w=2,   r=50, text="Anchor: shipyard site"},
    seazone   = {c=K.blue,   w=1.5, r=40, text="Hatched area: sea control zone"},
    strait    = {c=K.sky,    w=2.5, r=50, text="Double bar: strait"},
    coastfire = {c=K.orange, w=2,   r=40, text="Circle with a cross: coast-fire station on the standoff line"},
    seaplane  = {c=K.sky,    w=2,   r=45, text="Plane: seaplane platform site"},
    lrpc      = {c=K.verm,   w=2.5, r=50, text="Tall double chevron: long-range cannon perch"},
    antinuke  = {c=K.purple, w=2,   r=40, text="Ring with three spokes: anti-nuke site; thin circle: the selected side's 2000 coverage"},
    landing   = {c=K.white,  w=2.5, r=40, text="Beach line: landing"},
}
local KIND_ORDER = {"metal", "centre", "geo", "tidal", "choke", "killzone", "radar", "perch", "forward", "emergence", "island",
    "yard", "strait", "coastfire", "seaplane", "lrpc", "antinuke"}

local function phaseVisible(mk)
    local ph = PHASE_BY_KEY[options.phase]
    if not ph or not ph.lo then return true end
    local to = (mk.to < 0) and 1e9 or mk.to
    return mk.from < ph.hi and to > ph.lo
end
local function layerOf(mk)
    if mk.kind == "seazone" then return "seazone" end
    if mk.kind == "landing" then return "landing" end
    if mk.group == "economy" or mk.group == "land" or mk.group == "sea" or mk.group == "late" then return mk.group end
    return "land"
end
-- Lua numbers here are single precision floats, so %g printed 65.6 as 65.5999985: round
-- to a whole number when within 0.05 of one, else to one decimal.
local function fmtNum(v)
    v = tonumber(v) or 0
    local r = math.floor(v + 0.5)
    if math.abs(v - r) < 0.05 then return string.format("%d", r) end
    return string.format("%.1f", v)
end
local function markWord(mk)
    local v = mk.value or 0
    if mk.kind == "metal" then return string.format("%.1f m/s", v) end   -- metal per second
    if mk.kind == "choke" then return fmtNum(v) end
    if v ~= 0 then return mk.kind .. " " .. fmtNum(v) end
    return mk.kind
end

-- ---- selection-independent preparation (time-boxed steps before the first compile)
local function prepMarks(m)
    local fm = fieldModel()
    m.byLayer = {}
    for _, mk in ipairs(m.marks) do
        local layer = layerOf(mk)
        local bl = m.byLayer[layer]; if not bl then bl = {}; m.byLayer[layer] = bl end
        local list = bl[mk.kind]; if not list then list = {}; bl[mk.kind] = list end
        list[#list+1] = mk
        if mk.kind == "choke" or mk.kind == "killzone" then
            if mk.kind == "choke" then mk.half = math.max(16, math.min(400, (mk.value or 0) / 2)) end
            -- borrow the crossing direction of the terrain map's choke at the same place
            mk.dx, mk.dz = 0, 1
            if fm and fm.chokes then
                local best = 160 * 160
                for _, c in ipairs(fm.chokes) do
                    local d = (c.x - mk.x)^2 + (c.z - mk.z)^2
                    if d < best then best = d; mk.dx, mk.dz = c.dx, c.dz end
                end
            end
        elseif mk.kind == "landing" and mk.line and #mk.line >= 4 then
            local p = mk.line
            local mx, mz = polyMid(p)
            local tx, tz = p[#p-1] - p[1], p[#p] - p[2]
            local len = math.sqrt(tx*tx + tz*tz); if len == 0 then tx, tz, len = 1, 0, 1 end
            local nx, nz = -tz/len, tx/len
            -- inland is the side of the beach whose ground stands higher
            local ha = Spring.GetGroundHeight(mx + nx*120, mz + nz*120)
            local hb = Spring.GetGroundHeight(mx - nx*120, mz - nz*120)
            if hb > ha then nx, nz = -nx, -nz end
            mk.mx, mk.mz, mk.nx, mk.nz = mx, mz, nx, nz
        end
    end
end
local function verticalEdges(m, col)
    -- borders between columns col-1 and col, merged down the rows
    local gw, gh, cell, c, edges = m.gw, m.gh, m.cell, m.cellPos, m.edges
    local runA, runB, start = nil, nil, nil
    for row = 0, gh do
        local a, b = nil, nil
        if row < gh then a, b = c[row*gw + col - 1], c[row*gw + col] end
        local diff = row < gh and a ~= b
        if not (diff and start and a == runA and b == runB) then
            if start then edges[#edges+1] = {col*cell, start*cell, col*cell, row*cell, runA, runB} end
            if diff then start, runA, runB = row, a, b else start = nil end
        end
    end
end
local function horizontalEdges(m, row)
    local gw, cell, c, edges = m.gw, m.cell, m.cellPos, m.edges
    local runA, runB, start = nil, nil, nil
    for col = 0, gw do
        local a, b = nil, nil
        if col < gw then a, b = c[(row-1)*gw + col], c[row*gw + col] end
        local diff = col < gw and a ~= b
        if not (diff and start and a == runA and b == runB) then
            if start then edges[#edges+1] = {start*cell, row*cell, col*cell, row*cell, runA, runB} end
            if diff then start, runA, runB = col, a, b else start = nil end
        end
    end
end
local function queue(names)
    for _, n in ipairs(names) do
        if not pendingSet[n] then pendingSet[n] = true; pending[#pending+1] = n end
    end
end
local function stepPrep()
    local m = model
    local t0 = Spring.GetTimer()
    local steps = 0
    while prep do
        if prep.stage == 1 then
            prepMarks(m)
            prep.stage, prep.i = (m.terrOk and 2 or 5), 1
        elseif prep.stage == 2 then
            local r = m.terrRuns[prep.i]
            if not r then prep.stage, prep.i = 3, 1
            else
                local cells = m.cellPos
                for c = r[1], r[1] + r[3] - 1 do cells[c] = r[2] end
                prep.i = prep.i + 1
            end
        elseif prep.stage == 3 then
            if prep.i > m.gw - 1 then prep.stage, prep.i = 4, 1 else verticalEdges(m, prep.i); prep.i = prep.i + 1 end
        elseif prep.stage == 4 then
            if prep.i > m.gh - 1 then prep.stage = 5 else horizontalEdges(m, prep.i); prep.i = prep.i + 1 end
        else
            prep = nil
            queue(LAYER_ORDER)
            break
        end
        steps = steps + 1
        if steps % 8 == 0 and Spring.DiffTimers(Spring.GetTimer(), t0) > 0.002 then break end
    end
end

-- ---- labels (screen space, rebuilt on selection and phase changes; never per frame)
local function addLabel(x, z, s, size, maxH, c, centre, dzFar)
    -- dzFar: the label's z offset in the strategic view, below a FAR_SCALE glyph (nil: z as given)
    if #labelsAll >= LABEL_CAP then return end
    labelsAll[#labelsAll+1] = {x, groundY(x, z) + 12, z, s, size, maxH, c, centre, dzFar}
end
local function buildLabels()
    labelsAll = {}
    local m = model
    if not m then return end
    for _, i in ipairs(m.order) do
        local p = m.positions[i]
        local c = (i == selected) and K.yellow or K.white
        -- the rank on the disc: ink on a solid (script) disc, white in a hollow (predicted) one
        addLabel(p.x, p.z, tostring(p.n), 13, 1e9, p.source == "script" and K.ink or K.white, true)
        addLabel(p.x, p.z + POS_R * 1.9 + 40, p.name .. "  " .. p.label, 12, 1e9, c, false)
    end
    for _, mk in ipairs(m.marks) do
        if mk.labelled and KIND[mk.kind] and phaseVisible(mk) then
            local x, z = mk.x, mk.z
            if mk.mx then x, z = mk.mx, mk.mz end
            -- labelled marks keep their text at every height (the strategic view too); the cap is 200
            local r = KIND[mk.kind].r
            addLabel(x, z + r + 30, markWord(mk), 11, 1e9, KIND[mk.kind].c, false, r * FAR_SCALE + 60 - (r + 30))
        end
    end
end

-- ---- the opening card
local function factoryFor(class, faction)
    local f = model and model.factories[class]
    return f and f[faction] or nil
end
local function viewerFaction()
    if options.faction then return options.faction end
    local ok, _, _, _, _, side = pcall(Spring.GetTeamInfo, Spring.GetMyTeamID(), false)
    return (ok and normFaction(side)) or "armada"
end
local function buildCard()
    card = nil
    if not model or not selected then return end
    local p = model.positions[selected]
    if not p then return end
    local o = model.openings[selected]
    local faction = viewerFaction()
    local c = {name=p.name, label=p.label, sublabel=p.sublabel, source=p.source, faction=faction, reasons={}, lines={}}
    local function line(head, body, col) c.lines[#c.lines+1] = {head, body, col or {0.91, 0.93, 0.96}} end
    local sub = (p.sublabel ~= "" and p.sublabel ~= "-") and ("  /  " .. p.sublabel) or ""
    local src = p.source
    if p.actual and p.actualDist then src = string.format("%s, %d from actual", src, math.floor(p.actualDist + 0.5)) end
    line(p.name, string.format("%s%s   (%s)", p.label, sub, src), K.white)
    if o then
        c.class, c.factory, c.next = o.class, factoryFor(o.class, faction) or "-", o.fallbacks[1] or "-"
        c.energy, c.second, c.reasons = o.energy, o.second, o.reasons
        local e = model.env
        c.wind, c.tidal = (e.minWind + e.maxWind) / 2, e.tidal
        line("Ideal factory", string.format("%s  %s   next: %s", CLASS_WORD[o.class] or o.class, c.factory, c.next))
        line("Energy", string.format("%s  (wind %.1f avg, tidal %s)", o.energy ~= "" and o.energy or "-", c.wind, fmtNum(c.tidal)))
        line("Then", o.second ~= "" and o.second or "-")
        if #o.reasons == 0 then line("Why", "-") end
        for k = 1, math.min(3, #o.reasons) do line(k == 1 and "Why" or "", o.reasons[k]) end
    else
        line("Opening", "none in the file", K.verm)
    end
    local r = p.actual
    if r then
        local tf = normFaction(r.side) or faction
        local ideal = o and factoryFor(o.class, tf)
        local verdict = "differs"
        if ideal and r.factory == ideal then verdict = "matches"
        elseif o and o.fallbacks[1] and r.factory == factoryFor(o.fallbacks[1], tf) then verdict = "fallback" end
        c.chosen = {factory=r.factory, team=r.teamId, role=r.role, verdict=verdict}
        line("Chosen", string.format("%s   (team %s, %s)   %s", r.factory or "-", tostring(r.teamId), r.role or "?", verdict),
            verdict == "matches" and K.green or (verdict == "differs" and K.verm or K.yellow))
    else
        c.chosen = {verdict="no AI"}
        line("Chosen", "no AI", K.grey)
    end
    card = c
end

-- ---- display lists
local function compileLayer(name, fn)
    if lists[name] then gl.DeleteList(lists[name]); lists[name] = nil end
    if fn then lists[name] = gl.CreateList(fn) end
end
local function lineLayer(name, fn)
    compileLayer(name, function() haloPass = true; fn(); haloPass = false; fn() end)
end
local function markLayer(name)
    -- two lists per mark layer: `name` (near) and `name .. "Far"` (strategic view), in which
    -- the labelled marks' glyphs are FAR_SCALE larger; drawWorld picks one by camera height
    local byKind = (model and model.byLayer[name]) or {}
    local sel = selected and model and model.positions[selected]
    local function body(far)
        local function size(st, mk) return (far and mk.labelled) and st.r * FAR_SCALE or st.r end
        for _, kind in ipairs(KIND_ORDER) do
            local ms, st = byKind[kind], KIND[kind]
            if ms and st then
                stroke(st.c, 0.95, st.w)
                gl.BeginEnd(GL.LINES, function()
                    for _, mk in ipairs(ms) do if phaseVisible(mk) then glyph(kind, mk.x, mk.z, size(st, mk), mk) end end
                end)
            end
        end
        -- anti-nuke coverage: a thin solid circle, only for the selected position's side
        local nukes = byKind.antinuke
        if nukes and sel then
            stroke(KIND.antinuke.c, 0.8, 1.2)
            gl.BeginEnd(GL.LINES, function()
                for _, mk in ipairs(nukes) do if mk.ally == sel.ally and phaseVisible(mk) then ngon(mk.x, mk.z, 2000, 96) end end
            end)
        end
        -- contested: a dashed (split) vermilion outline around the glyph
        stroke(K.verm, 0.95, 1.5)
        gl.BeginEnd(GL.LINES, function()
            for _, kind in ipairs(KIND_ORDER) do
                local ms, st = byKind[kind], KIND[kind]
                if ms and st then
                    for _, mk in ipairs(ms) do if mk.contested and phaseVisible(mk) then ngon(mk.x, mk.z, size(st, mk) * 1.5, 12, true) end end
                end
            end
        end)
    end
    lineLayer(name, function() body(false) end)
    lineLayer(name .. "Far", function() body(true) end)
end
local BUILD = {}
BUILD.dim = function()
    compileLayer("dim", function()
        local w, h = Game.mapSizeX, Game.mapSizeZ
        gl.Color(K.ink[1], K.ink[2], K.ink[3], 0.45)
        gl.BeginEnd(GL.QUADS, function()
            gl.Vertex(-512, 0, -512); gl.Vertex(w+512, 0, -512); gl.Vertex(w+512, 0, h+512); gl.Vertex(-512, 0, h+512)
        end)
    end)
end
BUILD.terrOutline = function()
    local m = model
    if not m.terrOk then compileLayer("terrOutline", nil); return end
    -- a light boundary between territories; no halo, it sits under everything
    compileLayer("terrOutline", function()
        gl.Color(K.grey[1], K.grey[2], K.grey[3], 0.5); gl.LineWidth(1.2)
        gl.BeginEnd(GL.LINES, function() for _, e in ipairs(m.edges) do seg(e[1], e[2], e[3], e[4]) end end)
    end)
end
BUILD.terrSel = function()
    local m = model
    if not m.terrOk or not selected or not m.positions[selected] then compileLayer("terrSel", nil); return end
    local sel = selected
    compileLayer("terrSel", function()
        if fieldApi and fieldApi.FillRuns then
            fieldApi.FillRuns({gw=m.gw, gh=m.gh, cell=m.cell}, m.terrRuns, m.cellPos, {[sel]=true}, K.yellow, 0.16)
        end
        for pass = 1, 2 do
            haloPass = pass == 1
            stroke(K.yellow, 0.9, 2)
            gl.BeginEnd(GL.LINES, function()
                for _, e in ipairs(m.edges) do if e[5] == sel or e[6] == sel then seg(e[1], e[2], e[3], e[4]) end end
            end)
        end
        haloPass = false
    end)
end
BUILD.seazone = function()
    local list = (model.byLayer.seazone or {}).seazone or {}
    lineLayer("seazone", function()
        local st = KIND.seazone
        stroke(st.c, 0.7, 1.2)
        gl.BeginEnd(GL.LINES, function()
            for _, mk in ipairs(list) do if mk.line and phaseVisible(mk) then hatch(mk.line, 120) end end
        end)
        stroke(st.c, 0.95, 2)
        gl.BeginEnd(GL.LINES, function()
            for _, mk in ipairs(list) do
                if mk.line and phaseVisible(mk) then if mk.contested then dashed(mk.line, 60, 30) else solid(mk.line) end end
            end
        end)
    end)
end
BUILD.economy = function() markLayer("economy") end
BUILD.land = function() markLayer("land") end
BUILD.sea = function() markLayer("sea") end
BUILD.late = function() markLayer("late") end
BUILD.landing = function()
    local list = (model.byLayer.landing or {}).landing or {}
    local sel = selected and model.positions[selected]
    -- the selected position's side reads each landing: an assault landing (arrow inland) when
    -- the landing's defending ally is another team, a home landing (arrow out to sea) when it is its own
    local groups = {{c=K.verm, want=true}, {c=K.green, want=false}, {c=K.white}}
    lineLayer("landing", function()
        for _, g in ipairs(groups) do
            stroke(g.c, 0.95, KIND.landing.w)
            gl.BeginEnd(GL.LINES, function()
                for _, mk in ipairs(list) do
                    if mk.line and phaseVisible(mk) then
                        local assault = nil
                        if sel then assault = mk.ally ~= sel.ally end
                        if assault == g.want then landingGlyph(mk, assault, 110) end
                    end
                end
            end)
        end
    end)
end
BUILD.positions = function()
    local m = model
    lineLayer("positions", function()
        if not haloPass then
            gl.Color(K.white[1], K.white[2], K.white[3], 0.85)
            gl.BeginEnd(GL.TRIANGLES, function()
                for _, i in ipairs(m.order) do local p = m.positions[i]; if p.source == "script" then disc(p.x, p.z, POS_R) end end
            end)
        end
        stroke(K.white, 0.95, 2)
        gl.BeginEnd(GL.LINES, function()
            for _, i in ipairs(m.order) do
                local p = m.positions[i]
                ngon(p.x, p.z, POS_R, 24)
                if p.source ~= "script" then ngon(p.x, p.z, POS_R * 0.7, 24) end
            end
        end)
        -- a thin dashed line from a predicted position to the actual start the roster reports
        stroke(K.sky, 0.9, 1.5)
        gl.BeginEnd(GL.LINES, function()
            for _, i in ipairs(m.order) do
                local p = m.positions[i]
                local r = p.actual
                if r and p.source ~= "script" and p.actualDist and p.actualDist > POS_R then
                    dashed({p.x, p.z, r.x, r.z}, 40, 24)
                    dot(r.x, r.z, 30)
                end
            end
        end)
    end)
end
BUILD.selRing = function()
    local p = selected and model.positions[selected]
    if not p then compileLayer("selRing", nil); return end
    lineLayer("selRing", function()
        stroke(K.yellow, 1, 3)
        gl.BeginEnd(GL.LINES, function() ngon(p.x, p.z, POS_R * 1.5, 32); ngon(p.x, p.z, POS_R * 1.8, 32) end)
    end)
end
BUILD.minimap = function()
    local m = model
    compileLayer("minimap", function()
        local function ring(x, z, r, n)
            for i = 0, n - 1 do
                local a1, a2 = i * 2 * math.pi / n, (i + 1) * 2 * math.pi / n
                gl.Vertex(x + math.cos(a1)*r, z + math.sin(a1)*r); gl.Vertex(x + math.cos(a2)*r, z + math.sin(a2)*r)
            end
        end
        gl.LineWidth(1.5)
        gl.Color(K.white[1], K.white[2], K.white[3], 0.95)
        gl.BeginEnd(GL.LINES, function()
            for _, i in ipairs(m.order) do local p = m.positions[i]; ring(p.x, p.z, 150, 12) end
        end)
        gl.Color(K.yellow[1], K.yellow[2], K.yellow[3], 0.95)
        gl.BeginEnd(GL.LINES, function()
            for _, mk in ipairs(m.marks) do
                if mk.labelled and KIND[mk.kind] and phaseVisible(mk) and mk.kind ~= "landing" and mk.kind ~= "seazone" then
                    local s = 60
                    gl.Vertex(mk.x - s, mk.z - s); gl.Vertex(mk.x + s, mk.z + s); gl.Vertex(mk.x - s, mk.z + s); gl.Vertex(mk.x + s, mk.z - s)
                end
            end
        end)
        local p = selected and m.positions[selected]
        if p then gl.LineWidth(2.5); gl.BeginEnd(GL.LINES, function() ring(p.x, p.z, 260, 16) end) end
    end)
end

local function loadedStatus()
    if not model then return end
    local s = string.format("%d positions, %d marks", #model.order, #model.marks)
    if prep or #pending > 0 then s = s .. "  (drawing)" end
    if model.terrCount > 0 and not model.terrOk then s = s .. "  (territory grid mismatch)" end
    status = s
end
local function compileSome()
    local t0 = Spring.GetTimer()
    local n = 0
    while #pending > 0 do
        local name = table.remove(pending, 1)
        pendingSet[name] = nil
        local b = BUILD[name]
        if b then b() end
        n = n + 1
        if n >= 3 or Spring.DiffTimers(Spring.GetTimer(), t0) > 0.002 then break end
    end
    loadedStatus()
end
local function disposeLists()
    for _, l in pairs(lists) do gl.DeleteList(l) end
    lists = {}
end

-- ---- selection, roster
local function selectIndex(i)
    if not model or not model.positions[i] then return false end
    selected = i
    inspectLines = nil
    queue(BY_SELECTION)
    buildLabels()
    buildCard()
    return true
end
local function nearestPosition(x, z, radius)
    if not model or not x or not z then return nil end
    local best, bd = nil, radius * radius
    for _, i in ipairs(model.order) do
        local p = model.positions[i]
        local d = (p.x - x)^2 + (p.z - z)^2
        if d < bd then best, bd = i, d end
    end
    return best
end
local function selectMine()
    if not model then return false end
    local x, z = nil, nil
    if mineProvider then x, z = mineProvider() end
    local i = nearestPosition(x, z, 1500)
    if not i then i = model.order[1] end
    return i ~= nil and selectIndex(i)
end
local function refreshRoster(force)
    if not model then return end
    local now = Spring.GetTimer()
    if not force and rosterTimer and Spring.DiffTimers(now, rosterTimer) < 2 then return end
    rosterTimer = now
    local rs = rosterProvider and rosterProvider() or {}
    local parts = {}
    for _, r in ipairs(rs) do
        parts[#parts+1] = tostring(r.teamId) .. ":" .. tostring(r.x) .. ":" .. tostring(r.z) .. ":" .. tostring(r.factory) .. ":" .. tostring(r.role) .. ":" .. tostring(r.side)
    end
    local sig = table.concat(parts, ";")
    if sig == rosterSig and not force then return end
    rosterSig = sig
    for _, i in ipairs(model.order) do
        local p = model.positions[i]
        local best, bd = nil, MATCH_RADIUS * MATCH_RADIUS
        for _, r in ipairs(rs) do
            if r.x and r.z then
                local d = (r.x - p.x)^2 + (r.z - p.z)^2
                if d < bd then best, bd = r, d end
            end
        end
        p.actual = best
        p.actualDist = best and math.sqrt(bd) or nil
    end
    queue(BY_ROSTER)
    buildCard()
end
finishModel = function(m, s)
    local fm = fieldModel()
    if fm and fm.gw and fm.gw > 0 then m.gw, m.gh, m.cell = fm.gw, fm.gh, fm.cell or 32
    else m.cell = 32; m.gw = math.max(1, math.floor(Game.mapSizeX / 32)); m.gh = math.max(1, math.floor(Game.mapSizeZ / 32)) end
    m.terrOk = m.terrCount > 0 and m.terrCount == m.gw * m.gh
    m.fpChecked = fm ~= nil and fm.fingerprint ~= nil
    disposeLists()
    pending, pendingSet = {}, {}
    model, seq = m, s
    selected, inspectLines, card = nil, nil, nil
    rosterSig = ""
    prep = {stage=1, i=1}
    refreshRoster(true)
    if not selectMine() then buildLabels() end
    -- what the two calls queued is a subset of the full queue stepPrep adds when it ends
    pending, pendingSet = {}, {}
    loadedStatus()
end
local function checkFingerprint()
    -- the terrain file may load after this one: compare once it has
    if not model or model.fpChecked then return end
    local fm = fieldModel()
    if not (fm and fm.fingerprint) then return end
    model.fpChecked = true
    if fm.fingerprint ~= model.fieldFp then
        disposeLists()
        model, prep, selected, card, inspectLines = nil, nil, nil, nil, nil
        pending, pendingSet, labelsAll = {}, {}, {}
        status = "Landmarks file skipped: fingerprint differs from map.txt"
    end
end

-- ---- public state changes
local function setMode(value)
    local was = on
    on = value and true or false
    if on then
        if not model and not parse then status = "Landmarks: waiting for file"; lastExists = nil end
    else
        parse = nil
        if not model then status = "Landmarks hidden" end
    end
    return was ~= on
end
local function setPhase(p)
    if type(p) == "string" then p = string.lower(p) end
    if p == "0" then p = "0-5" elseif p == "5" then p = "5-15" elseif p == "15" then p = "15-25" elseif p == "25" then p = "25+" end
    if not PHASE_BY_KEY[p] then return false end
    if options.phase ~= p then
        options.phase = p
        if model then queue(BY_PHASE); buildLabels() end
    end
    return true
end
local function setFaction(f)
    f = normFaction(f)
    if not f then return false end
    options.faction = f
    buildCard()
    return true
end
local function selectName(name)
    if not model or not name then return false end
    -- exact name, then any case (P0.3 / p0.3); never a punctuation-blind match (P1.12 vs P11.2)
    local lower = string.lower(tostring(name))
    for _, i in ipairs(model.order) do if model.positions[i].name == name then return selectIndex(i) end end
    for _, i in ipairs(model.order) do if string.lower(model.positions[i].name) == lower then return selectIndex(i) end end
    local n = tonumber(name)
    if n and model.positions[n] then return selectIndex(n) end
    return false
end
local function step(d)
    if not model or #model.order == 0 then return false end
    local at = 0
    for k, i in ipairs(model.order) do if i == selected then at = k end end
    local n = #model.order
    local k = ((at - 1 + d) % n) + 1
    if at == 0 then k = 1 end
    return selectIndex(model.order[k])
end

-- ---- picking
local function markRecord(mk)
    local owner = (mk.pos >= 0 and model.positions[mk.pos]) and model.positions[mk.pos].name or "none"
    local to = mk.to < 0 and "end" or fmtNum(mk.to)
    return {
        string.format("%s  (%s)  value %s%s", string.upper(mk.kind), mk.group, fmtNum(mk.value), mk.contested and "  contested" or ""),
        string.format("owner %s  ally %d  minutes %s-%s", owner, mk.ally, fmtNum(mk.from), to),
        mk.reason ~= "" and mk.reason or "-",
    }
end
local function pickAt(mx, my)
    local kind, pos = Spring.TraceScreenRay(mx, my, true)
    if kind ~= "ground" or not pos then return false end
    local x, z = pos[1], pos[3]
    local i = nearestPosition(x, z, POS_R * 1.6)
    if i then selectIndex(i); return true end
    local best, bd = nil, 80 * 80
    for _, mk in ipairs(model.marks) do
        if (KIND[mk.kind]) and phaseVisible(mk) then
            local px, pz = mk.x, mk.z
            if mk.mx then px, pz = mk.mx, mk.mz end
            local d = (px - x)^2 + (pz - z)^2
            if d < bd then best, bd = mk, d end
        end
    end
    if best then inspectLines = markRecord(best); return true end
    inspectLines = nil
    return false
end

-- ---- drawing
local function drawWorld()
    if not on or not model or Spring.IsGUIHidden() then return end
    gl.DepthTest(false)
    -- with the terrain map off the marks draw over a dim sheet of their own
    if not (fieldApi and fieldApi.Mode and fieldApi.Mode()) and lists.dim then gl.CallList(lists.dim) end
    local _, cy = Spring.GetCameraPosition()
    local far = (cy or 0) > LABEL_HEIGHT
    for _, name in ipairs(DRAW_ORDER) do
        local l = lists[name]
        if far and lists[name .. "Far"] then l = lists[name .. "Far"] end
        if l then gl.CallList(l) end
    end
    gl.LineWidth(1); gl.Color(1, 1, 1, 1); gl.DepthTest(true)
end
local function drawMiniMap(sx, sy)
    if not on or not model or not lists.minimap then return end
    gl.PushMatrix()
    gl.Translate(0, sy, 0)
    gl.Scale(sx / Game.mapSizeX, -sy / Game.mapSizeZ, 1)
    gl.CallList(lists.minimap)
    gl.PopMatrix()
    gl.LineWidth(1); gl.Color(1, 1, 1, 1)
end
local function drawLabels()
    local _, cy = Spring.GetCameraPosition()
    cy = cy or 0
    local vw, vh = gl.GetViewSizes()
    local far = cy > LABEL_HEIGHT
    local shrink = far and math.max(0.55, math.min(1, LABEL_HEIGHT / cy)) or 1
    for _, l in ipairs(labelsAll) do
        if cy <= l[6] then
            local sx, sy, sz = Spring.WorldToScreenCoords(l[1], l[2], l[3] + ((far and l[9]) or 0))
            if sx and sz and sz > 0 and sz < 1 and sx > 0 and sx < vw and sy > 0 and sy < vh then
                local size = math.max(9, l[5] * shrink)
                local opt = l[8] and "cv" or "c"
                gl.Color(K.ink[1], K.ink[2], K.ink[3], 0.85)
                gl.Text(l[4], sx+1, sy-1, size, opt); gl.Text(l[4], sx-1, sy-1, size, opt); gl.Text(l[4], sx+1, sy+1, size, opt); gl.Text(l[4], sx-1, sy+1, size, opt)
                local c = l[7]
                gl.Color(c[1], c[2], c[3], 0.95); gl.Text(l[4], sx, sy, size, opt)
            end
        end
    end
    gl.Color(1, 1, 1, 1)
end
-- legend samples: the map's own glyph code in screen space (flatY), halo pass then colour
local function legendSample(cx, cy, fn)
    flatY, patScale = cy, 0.2
    haloPass = true; fn(cx, cy)
    haloPass = false; fn(cx, cy)
    flatY, patScale = nil, 1
    gl.LineWidth(1)
end
local function kindSample(kind)
    return function(cx, cy)
        local st = KIND[kind]
        stroke(st.c, 0.95, st.w)
        gl.BeginEnd(GL.LINES, function() glyph(kind, cx, cy, 8, {}) end)
    end
end
local function legendRows()
    local rows = {}
    local function head(t) rows[#rows+1] = {nil, t} end
    local function add(sample, t) rows[#rows+1] = {sample, t} end
    head("POSITIONS")
    add(function(cx, cy)
        if not haloPass then gl.Color(1, 1, 1, 0.85); gl.BeginEnd(GL.TRIANGLES, function() disc(cx, cy, 7) end) end
        stroke(K.white, 0.95, 2); gl.BeginEnd(GL.LINES, function() ngon(cx, cy, 7, 16) end)
    end, "Filled disc: a start position from the start script (number: rank from the rear)")
    add(function(cx, cy)
        stroke(K.white, 0.95, 2); gl.BeginEnd(GL.LINES, function() ngon(cx, cy, 7, 16); ngon(cx, cy, 4.5, 12) end)
    end, "Hollow double ring: a predicted start position")
    add(function(cx, cy)
        stroke(K.yellow, 1, 3); gl.BeginEnd(GL.LINES, function() ngon(cx, cy, 6, 16); ngon(cx, cy, 8, 16) end)
    end, "Double yellow ring: the selected position (the opening card describes it)")
    add(function(cx, cy)
        stroke(K.sky, 0.9, 1.5); gl.BeginEnd(GL.LINES, function() dashed({cx - 20, cy, cx + 14, cy}, 40, 24); dot(cx + 18, cy, 3) end)
    end, "Thin dashed line: prediction to the actual start")
    add(function(cx, cy)
        if not haloPass then
            gl.Color(K.yellow[1], K.yellow[2], K.yellow[3], 0.3); gl.Rect(cx - 22, cy - 6, cx, cy + 6)
            gl.Color(K.grey[1], K.grey[2], K.grey[3], 0.6); gl.LineWidth(1.2)
            gl.BeginEnd(GL.LINES, function() seg(cx + 6, cy - 7, cx + 6, cy + 7); seg(cx + 6, cy, cx + 22, cy) end)
        end
    end, "Soft fill: selected territory; thin grey lines: other territories")
    head("ECONOMY")
    for _, k in ipairs({"metal", "geo", "tidal", "centre"}) do add(kindSample(k), KIND[k].text) end
    head("LAND")
    for _, k in ipairs({"choke", "killzone", "radar", "perch", "forward", "emergence", "island"}) do add(kindSample(k), KIND[k].text) end
    head("SEA")
    add(kindSample("yard"), KIND.yard.text)
    add(function(cx, cy)
        local p = {cx - 16, cy - 7, cx + 16, cy - 7, cx + 16, cy + 7, cx - 16, cy + 7, cx - 16, cy - 7}
        stroke(KIND.seazone.c, 0.95, 1.2); gl.BeginEnd(GL.LINES, function() hatch(p, 5); solid(p) end)
    end, KIND.seazone.text)
    add(kindSample("strait"), KIND.strait.text)
    local function landingRow(assault, c)
        return function(cx, cy)
            local mk = {line={cx - 18, cy + 4, cx + 18, cy + 4}, mx=cx, mz=cy + 4, nx=0, nz=-1}
            stroke(c, 0.95, 2.5); gl.BeginEnd(GL.LINES, function() landingGlyph(mk, assault, 11) end)
        end
    end
    add(landingRow(true, K.verm), "Beach line, arrow inland: assault landing for the selected side")
    add(landingRow(false, K.green), "Beach line, arrow out to sea: home landing (the selected side defends it)")
    for _, k in ipairs({"coastfire", "seaplane"}) do add(kindSample(k), KIND[k].text) end
    head("LATE GAME")
    add(kindSample("lrpc"), KIND.lrpc.text)
    add(function(cx, cy)
        kindSample("antinuke")(cx, cy)
        stroke(KIND.antinuke.c, 0.8, 1.2); gl.BeginEnd(GL.LINES, function() ngon(cx, cy, 13, 24) end)
    end, KIND.antinuke.text)
    head("ANY MARK")
    add(function(cx, cy)
        kindSample("metal")(cx, cy)
        stroke(K.verm, 0.95, 1.5); gl.BeginEnd(GL.LINES, function() ngon(cx, cy, 12, 12, true) end)
    end, "Dashed ring around a mark: contested, near the contact line")
    return rows
end
local legendCache = nil
local ROW_H, HEAD_H = 17, 20
local function panel(x, top, w, h)
    gl.Color(inkPanel); gl.Rect(x, top - h, x + w, top)
    gl.Color(K.sky[1], K.sky[2], K.sky[3], 1); gl.Rect(x, top - 3, x + w, top)
    panelRects[#panelRects+1] = {x, top - h, x + w, top}
end
-- The panels dock on the left just below the minimap (BAR draws the minimap over anything
-- placed under it; the first played run hid the card there). The minimap's bottom edge in
-- GL coordinates is the y of Spring.GetMiniMapGeometry (BAR's minimap_utils reads it so);
-- the picture-in-picture minimap reports its own box through WG.minimap.getScreenBounds.
local function dockTop(vh)
    local bottom = nil
    local wm = WG and WG.minimap
    local okPip, pip = pcall(function() return wm and wm.isPipMinimapActive and wm.isPipMinimapActive() end)
    if okPip and pip and wm.getScreenBounds then
        local ok, _, b = pcall(wm.getScreenBounds)
        if ok and type(b) == "number" then bottom = b end
    end
    if not bottom and Spring.GetMiniMapGeometry then
        local ok, _, py, _, sy, minimized = pcall(Spring.GetMiniMapGeometry)
        if ok and type(py) == "number" and type(sy) == "number" and sy > 0 and not minimized then bottom = py end
    end
    if not bottom or bottom <= 0 or bottom > vh then bottom = vh - 60 end
    return bottom - 12
end
local function drawPanels()
    panelRects = {}
    if Spring.IsGUIHidden() then return end
    local vw, vh = gl.GetViewSizes()
    local dock = dockTop(vh)
    local x, top = 12, dock
    local w = 460
    -- the opening card, with the clicked mark's record under it
    local lines = card and card.lines or {}
    local h = 40 + #lines * 15 + (inspectLines and (20 + #inspectLines * 14) or 0) + 8
    if not model then h = 40 + 18 end
    top = math.max(h + 10, math.min(vh - 10, top))
    panel(x, top, w, h)
    gl.Color(0.93, 0.96, 1, 1); gl.Text("LANDMARKS  /  OPENING CARD", x + 14, top - 24, 13, "o")
    local y = top - 44
    if not model then
        gl.Color(muted); gl.Text(status, x + 14, y, 10, "o")
    else
        for _, l in ipairs(lines) do
            gl.Color(mint); gl.Text(l[1], x + 14, y, 10, "o")
            local c = l[3]
            gl.Color(c[1], c[2], c[3], 1); gl.Text(l[2], x + 112, y, 10, "o")
            y = y - 15
        end
        if inspectLines then
            y = y - 6
            gl.Color(mint); gl.Text("MARK", x + 14, y, 10, "o"); y = y - 14
            for _, l in ipairs(inspectLines) do gl.Color(0.91, 0.93, 0.96, 1); gl.Text(l, x + 14, y, 10, "o"); y = y - 14 end
        end
    end
    -- the legend, beside the card
    if options.legend then
        if not legendCache then legendCache = legendRows() end
        local lw = 470
        local lh = 40
        for _, row in ipairs(legendCache) do lh = lh + (row[1] and ROW_H or HEAD_H) end
        local lx = x + w + 8
        if lx + lw > vw - 8 then lx = math.max(8, vw - lw - 8) end
        local ltop = math.max(lh + 10, math.min(vh - 10, dock))
        panel(lx, ltop, lw, lh)
        gl.Color(0.93, 0.96, 1, 1); gl.Text("LANDMARKS LEGEND  /  shape carries the meaning, colour repeats it", lx + 14, ltop - 24, 11, "o")
        local ly = ltop - 40
        for _, row in ipairs(legendCache) do
            if row[1] then
                legendSample(lx + 40, ly, row[1])
                gl.Color(0.9, 0.93, 0.97, 1); gl.Text(row[2], lx + 76, ly - 4, 10, "o")
                ly = ly - ROW_H
            else
                ly = ly - 4
                gl.Color(mint); gl.Text(row[2], lx + 14, ly - 2, 10, "o")
                ly = ly - (HEAD_H - 4)
            end
        end
    end
    gl.LineWidth(1); gl.Color(1, 1, 1, 1)
end
local function drawScreen()
    if not on then panelRects = {}; return end
    if model then drawLabels() end
    drawPanels()
end
local function update()
    if not on then return end
    if parse then stepParse(); return end
    if not model then tryLoad(); return end
    checkFingerprint()
    if not model then return end
    if prep then stepPrep(); loadedStatus(); return end
    refreshRoster(false)
    if #pending > 0 then compileSome() end
end
local function mousePress(x, y, b, overUi)
    if not on or Spring.IsGUIHidden() then return false end
    for _, r in ipairs(panelRects) do
        if x >= r[1] and x <= r[3] and y >= r[2] and y <= r[4] then return true end
    end
    if overUi or b ~= 1 or not model or prep then return false end
    return pickAt(x, y)
end

local function snapshot()
    local out = {loaded = model ~= nil, on = on, status = status, seq = seq, positions = 0, marks = 0, selected = nil,
        phase = options.phase, faction = viewerFaction(), legend = options.legend, compiled = false, pending = #pending,
        kinds = {}, items = {positions = {}}, card = nil, inspect = inspectLines, panels = {}}
    -- the card (and legend) boxes as last drawn, screen coordinates {x1, y1, x2, y2}
    for i, r in ipairs(panelRects) do out.panels[i] = {r[1], r[2], r[3], r[4]} end
    local m = model
    if not m then return out end
    out.compiled = prep == nil and #pending == 0
    out.positions, out.marks = #m.order, #m.marks
    out.territory = m.terrOk
    out.fieldFingerprint = m.fieldFp
    for _, mk in ipairs(m.marks) do out.kinds[mk.kind] = (out.kinds[mk.kind] or 0) + 1 end
    for _, i in ipairs(m.order) do
        local p, o = m.positions[i], m.openings[i]
        out.items.positions[#out.items.positions+1] = {index=i, name=p.name, label=p.label, sublabel=p.sublabel, source=p.source,
            ally=p.ally, n=p.n, x=p.x, z=p.z, opening = o ~= nil, class = o and o.class or nil,
            factory = o and factoryFor(o.class, out.faction) or nil, energy = o and o.energy or nil, next = o and o.fallbacks[1] or nil}
    end
    local sp = selected and m.positions[selected]
    out.selected = sp and sp.name or nil
    if card then
        local text = {}
        for _, l in ipairs(card.lines) do text[#text+1] = (l[1] ~= "" and (l[1] .. ": ") or "") .. l[2] end
        out.card = {name=card.name, label=card.label, sublabel=card.sublabel, source=card.source, faction=card.faction,
            class=card.class, factory=card.factory, next=card.next, energy=card.energy, wind=card.wind, tidal=card.tidal,
            second=card.second, reasons=card.reasons, chosen=card.chosen, lines=text}
    end
    return out
end
local function config(data)
    if type(data) ~= "table" then return end
    if type(data.legend) == "boolean" then options.legend = data.legend end
    if type(data.phase) == "string" and PHASE_BY_KEY[data.phase] then options.phase = data.phase end
    if type(data.faction) == "string" and FACTION_NAME[data.faction] then options.faction = data.faction end
    if data.show == true then setMode(true) end
end
local function getConfig()
    return {show=on, legend=options.legend, phase=options.phase, faction=options.faction}
end
local function textCommand(cmd)
    if cmd == "barbmarks" then setMode(not on); return true end
    local sub = string.match(cmd, "^barbmarks%s+(.+)$")
    if not sub then return false end
    sub = string.match(sub, "^%s*(.-)%s*$")
    if sub == "show" or sub == "on" then setMode(true)
    elseif sub == "hide" or sub == "off" then setMode(false)
    elseif sub == "legend" then options.legend = not options.legend; if options.legend and not on then setMode(true) end
    else
        local ph = string.match(sub, "^phase%s+(%S+)$")
        local pos = string.match(sub, "^pos%s+(%S+)$")
        local fac = string.match(sub, "^faction%s+(%a+)$")
        if ph then
            if not setPhase(ph) then Spring.Echo("[BARb link] /barbmarks phase <0-5|5-15|15-25|25+|all>") end
        elseif pos then
            if not selectName(pos) then Spring.Echo("[BARb link] no landmarks position " .. pos) end
        elseif fac then
            if not setFaction(fac) then Spring.Echo("[BARb link] /barbmarks faction <armada|cortex|legion>") end
        else
            Spring.Echo("[BARb link] /barbmarks [show|hide|legend|phase <0-5|5-15|15-25|25+|all>|pos <name>|faction <armada|cortex|legion>]")
        end
    end
    return true
end
local function shutdown()
    disposeLists()
    on = false
end
return {SetMode=setMode, Mode=function() return on end, Status=function() return status end, Snapshot=snapshot,
    SetLegend=function(v) options.legend = v and true or false end, Legend=function() return options.legend end,
    SetPhase=setPhase, Phase=function() return options.phase end, Phases=function() return PHASE_KEYS end,
    SetFaction=setFaction, Faction=viewerFaction, Factions=function() return FACTIONS end,
    FactionName=function(f) return FACTION_NAME[f] or tostring(f) end,
    Select=selectName, SelectMine=selectMine, Step=step,
    SelectedName=function() local p = model and selected and model.positions[selected]; return p and p.name or nil end,
    SetField=function(api) fieldApi = api end, SetRosterProvider=function(fn) rosterProvider = fn end,
    SetMineProvider=function(fn) mineProvider = fn end,
    Config=config, GetConfig=getConfig, TextCommand=textCommand,
    Update=update, DrawWorld=drawWorld, DrawScreen=drawScreen, DrawMiniMap=drawMiniMap, Shutdown=shutdown,
    MousePress=mousePress}
end)()

-- ---------------------------------------------------------------- constants

local ROLES = { "FRONT", "AIR", "TECH", "SEA", "SUPPORT", "TACTICAL" }
local ROLE_HINT = {
	FRONT = "Land army and forward pressure",
	AIR = "Aircraft plants, bomber waves",
	TECH = "Economy first, T2/T3 race",
	SEA = "Naval production",
	SUPPORT = "Economic support",
	TACTICAL = "Mobile builders, hover opening",
}
-- the game's own art (VFS paths); a missing file falls back to text only
local ICON = {
	FRONT    = "icons/bot_t2.png",
	AIR      = "icons/air.png",
	TECH     = "icons/fusion.png",
	SEA      = "icons/ship.png",
	SUPPORT  = "icons/worker.png",
	TACTICAL = "icons/hover.png",
	ai       = "LuaUI/Images/advplayerslist/cpu.dds",
	team     = "LuaUI/Images/advplayerslist/ally.dds",
	query    = "LuaUI/Images/advplayerslist/ping.dds",
	queryall = "icons/radar_t2.png",
	overlay  = "icons/eye.png",
	close    = "LuaUI/Images/advplayerslist/cross.dds",
	goto     = "LuaUI/Images/advplayerslist/camera.dds",
	lead     = "LuaUI/Images/advplayerslist/indicator.dds",
}
local MAX_EVENTS = 120
local QUERY_INTERVAL_FRAMES = 1800
local WIN_W, WIN_H = 340, 590   -- unscaled px (560: room for the Landmarks rows)
local LAUNCHER = 26             -- unscaled px

local C = {
	onSurface        = { 0.93, 0.93, 0.93, 1 },
	onSurfaceVariant = { 0.66, 0.66, 0.68, 1 },
	outline          = { 1, 1, 1, 0.12 },
	outlineStrong    = { 1, 1, 1, 0.28 },
	primary          = { 1, 0.9, 0.66, 1 },
	primaryContainer = { 1, 0.9, 0.66, 0.2 },
	surface          = { 0.07, 0.07, 0.08, 0.93 },
	surfaceHigh      = { 1, 1, 1, 0.06 },
	surfaceMenu      = { 0.12, 0.12, 0.13, 0.98 },
	hoverLayer       = { 1, 1, 1, 0.08 },
	pressLayer       = { 1, 1, 1, 0.14 },
	ok               = { 0.55, 0.85, 0.55, 1 },
	warn             = { 1, 0.75, 0.4, 1 },
	error            = { 1, 0.5, 0.5, 1 },
}
local SOUND_CLICK = "LuaUI/Sounds/buildbar_click.wav"

-- ---------------------------------------------------------------- engine locals

local glColor, glRect, glText, glTexture, glTexRect = gl.Color, gl.Rect, gl.Text, gl.Texture, gl.TexRect
local spEcho, spGetGameFrame, spGetMouseState = Spring.Echo, Spring.GetGameFrame, Spring.GetMouseState
local spGetTeamList, spGetTeamInfo, spGetAIInfo, spGetTeamColor = Spring.GetTeamList, Spring.GetTeamInfo, Spring.GetAIInfo, Spring.GetTeamColor
local spGetMyTeamID, spAreTeamsAllied, spGetSpectatingState = Spring.GetMyTeamID, Spring.AreTeamsAllied, Spring.GetSpectatingState
local spSendSkirmishAIMessage, spPlaySoundFile = Spring.SendSkirmishAIMessage, Spring.PlaySoundFile
local spGetMyPlayerID, spGetTeamUnits, spGetUnitDefID = Spring.GetMyPlayerID, Spring.GetTeamUnits, Spring.GetUnitDefID
local spGetUnitPosition, spSetCameraTarget, spGetTeamStartPosition = Spring.GetUnitPosition, Spring.SetCameraTarget, Spring.GetTeamStartPosition
local mathFloor, mathMax, mathMin = math.floor, math.max, math.min

-- Only teams allied with the local player are listed, drawn and commanded
-- (CR-008): a host playing in a game must not see the enemy BARb's plan or
-- steer its builders. A spectator sees every AI. Commanding needs the AI to be
-- hosted by this client (it runs here, and only here does the message reach
-- it): a spectating host commands every AI it hosts (an AI-only game, the
-- owner's usual set-up; before this, every role button was greyed out there),
-- a playing host only its allies.
local function isSpectator() return spGetSpectatingState() == true end
local function isPermittedTeam(teamId)
	if isSpectator() then return true end
	return spAreTeamsAllied(teamId, spGetMyTeamID()) == true
end
local function hostedHere(teamId)
	local _, _, host = spGetAIInfo(teamId)
	return host ~= nil and host == spGetMyPlayerID()
end
local function mayCommand(teamId)
	if not hostedHere(teamId) then return false end
	if isSpectator() then return true end
	return spAreTeamsAllied(teamId, spGetMyTeamID()) == true
end

-- ---------------------------------------------------------------- state

local vsx, vsy = Spring.GetViewGeometry()
local scale = 1
local RectRound, RectRoundOutline, UiElement
local font, font2
local hasFlowUI = false

local open = false               -- the window is shown
local firstRun = true            -- no saved config yet (owner: the window starts closed; the launcher shows it is there)
local offX, offY = 0, 0          -- the user's drag, from the default place (scaled px)
local launcher = { x1 = 0, y1 = 0, x2 = 0, y2 = 0 }
local win = { x1 = 0, y1 = 0, x2 = 0, y2 = 0 }
local dragging = nil             -- { mx, my, offX, offY } while the header is dragged

local hit = {}                   -- rebuilt every draw: { x1, y1, x2, y2, id, action, tooltip }
local aggressionDrag
local hoverId, pressedId = nil, nil

local ais = {}                   -- teamId -> { teamId, name, color, allyTeam, roster, lastReply, replyKind }
local aiOrder = {}
local allyTeams = {}
local selectedAlly, selected = nil, nil
local events = {}
local eventScroll, listScroll = 0, 0
local lastQueryFrame = -1
local firstAnnounceFrame = nil
local blueprints = {} -- shared read-only layout observer; initialized below
local stateFiles = {} -- D-300 AI state file reader; initialized with the message code
local hookAIMessages, unhookAIMessages   -- defined with the message code below
local lastRowClick = nil                 -- a row's last click (double-click flies the camera)

-- ---------------------------------------------------------------- helpers

local function split(s, sep)
	local out = {}
	for piece in string.gmatch(s .. sep, "([^" .. sep .. "]*)" .. sep) do out[#out + 1] = piece end
	return out
end

local function frameToClock(f)
	local s = mathFloor((f or 0) / 30)
	return string.format("%d:%02d", mathFloor(s / 60), s % 60)
end

local function addEvent(text, kind)
	events[#events + 1] = { frame = spGetGameFrame(), text = text, kind = kind or "info" }
	if #events > MAX_EVENTS then table.remove(events, 1) end
end

local function aisOfAlly(allyTeam)
	local out = {}
	for _, id in ipairs(aiOrder) do
		if ais[id].allyTeam == allyTeam then out[#out + 1] = id end
	end
	return out
end

local function refreshTeams()
    local live={}
	for _, teamId in ipairs(spGetTeamList() or {}) do
		local _, _, isDead, isAI, _, allyTeam = spGetTeamInfo(teamId)
		if isAI and not isDead and isPermittedTeam(teamId) then
            live[teamId]=true
			local _, name = spGetAIInfo(teamId)
			local r, g, b = spGetTeamColor(teamId)
			local e = ais[teamId] or { teamId = teamId }
			e.name = name or ("AI " .. teamId)
			e.allyTeam = allyTeam or 0
			e.color = { r or 1, g or 1, b or 1, 1 }
			ais[teamId] = e
		end
	end
    for id in pairs(ais) do if not live[id] then ais[id]=nil end end
	aiOrder = {}
	for id in pairs(ais) do aiOrder[#aiOrder + 1] = id end
	table.sort(aiOrder, function(a, b)
		local ea, eb = ais[a], ais[b]
		if ea.allyTeam ~= eb.allyTeam then return ea.allyTeam < eb.allyTeam end
		return a < b
	end)
	allyTeams = {}
	local seen = {}
	for _, id in ipairs(aiOrder) do
		local at = ais[id].allyTeam
		if not seen[at] then seen[at] = true; allyTeams[#allyTeams + 1] = at end
	end
	table.sort(allyTeams)
	if selectedAlly == nil or not seen[selectedAlly] then
		local _, _, _, _, _, myAlly = spGetTeamInfo(spGetMyTeamID())
		selectedAlly = seen[myAlly] and myAlly or allyTeams[1]
	end
	if selected == nil or not ais[selected] or ais[selected].allyTeam ~= selectedAlly then
		selected = aisOfAlly(selectedAlly)[1]
	end
end

local function parseRoster(line)
	local p = split(line, "|")
	if p[1] ~= "roster" then return nil end
	return {
		teamId = tonumber(p[3]), aiId = tonumber(p[4]), role = p[5], side = p[6], factory = p[7],
		x = tonumber(p[8]), z = tonumber(p[9]), landLocked = (p[10] == "1"), spot = tonumber(p[11]), leader = (p[12] == "1"),
	}
end

local function send(teamId, msg)
	local ok = spSendSkirmishAIMessage(teamId, msg)
	if not ok then addEvent(string.format("Team %d: no local AI received the command (not hosted here?)", teamId), "warn") end
	return ok
end

local function queryAll()
	for _, id in ipairs(aiOrder) do send(id, "barb|query|" .. id) end
	lastQueryFrame = spGetGameFrame()
end

local function playClick() spPlaySoundFile(SOUND_CLICK, 0.5, "ui") end

-- a role switch request: the role grid's buttons and WG.barblink.SetRole
local function requestRole(teamId, role)
	if not mayCommand(teamId) then
		addEvent(string.format("Team %d: switch to %s refused here (this AI is not hosted by you)", teamId, role), "warn")
		return false
	end
	addEvent(string.format("Team %d: switch to %s requested", teamId, role), "info")
	return send(teamId, "barb|setrole|" .. teamId .. "|" .. role)
end

local function requestAggression(teamId, value)
    if not mayCommand(teamId) or type(value) ~= "number" or value ~= value
        or value < -1 or value > 1 then return false end
    -- Release-to-send: dragging is local preview, one targeted message at the
    -- end. The AI reply owns the displayed value; there is no polling/relay.
    return send(teamId, string.format("barb|aggression|%d|%.4f", teamId, value))
end

local function dragAggression(mx)
    if aggressionDrag then
        aggressionDrag.value = mathMax(-1, mathMin(1,
            2 * (mx - aggressionDrag.x1) / (aggressionDrag.x2 - aggressionDrag.x1) - 1))
    end
end

-- Fly the camera to an AI: its commander, else its factory nearest its start
-- (the owner's request). Only when asked: the widget never moves the camera
-- by itself.
local commanderDef, factoryDef = {}, {}
for id, ud in pairs(UnitDefs) do
	if ud.customParams and ud.customParams.iscommander then commanderDef[id] = true end
	if ud.isFactory then factoryDef[id] = true end
end
local function focusUnit(teamId)
	local units = spGetTeamUnits(teamId)
	if not units then return nil end
	local e = ais[teamId]
	local bx, bz = e and e.roster and e.roster.x, e and e.roster and e.roster.z
	if not bx then local sx, _, sz = spGetTeamStartPosition(teamId); bx, bz = sx, sz end
	bx, bz = bx or 0, bz or 0
	local best, bestD, bestKind = nil, math.huge, nil
	for _, uid in ipairs(units) do
		local d = spGetUnitDefID(uid)
		local kind = (d and commanderDef[d]) and "commander" or ((d and factoryDef[d]) and "factory" or nil)
		if kind and (bestKind ~= "commander" or kind == "commander") then
			local x, _, z = spGetUnitPosition(uid)
			if x then
				local dist = (x - bx) * (x - bx) + (z - bz) * (z - bz)
				if (kind == "commander" and bestKind ~= "commander") or dist < bestD then
					best, bestD, bestKind = uid, dist, kind
				end
			end
		end
	end
	return best, bestKind
end
local function goTo(teamId)
	local uid, kind = focusUnit(teamId)
	if not uid then
		addEvent(string.format("Team %d: no commander or factory in view", teamId), "warn")
		return false
	end
	local x, y, z = spGetUnitPosition(uid)
	spSetCameraTarget(x, y, z, 0.4)
	local name = UnitDefs[spGetUnitDefID(uid)] and UnitDefs[spGetUnitDefID(uid)].translatedHumanName or kind
	addEvent(string.format("Camera: team %d's %s (%s)", teamId, kind, name or "?"), "info")
	return true, uid, kind
end

local function setOpen(v)
	open = v
	if v then refreshTeams() end
	if not v and WG.guishader then WG.guishader.RemoveRect("barblink") end
end

-- ---------------------------------------------------------------- placement

-- The player list's box: { top, left, bottom, right, scale }, or nil.
local function playerList()
	local api = WG.advplayerlist_api
	if api and api.GetPosition then
		local p = api.GetPosition()
		if p and p[1] then return p end
	end
	return nil
end

-- The launcher sits just left of the player list's top-left corner, the
-- window to its left over the map; without a player list, the bottom-right
-- corner. The user's drag is an offset from that place, clamped on screen.
local function updatePlacement()
	local list = playerList()
	if list then
		scale = list[5] or 1
	else
		scale = (vsy / 1080) * (1 + (Spring.GetConfigFloat("ui_scale", 1) - 1) / 1.25)
	end
	local ls = mathFloor(LAUNCHER * scale)
	local gap = mathFloor(4 * scale)
	local ax, ay   -- the launcher's bottom-right corner
	if list then
		ax, ay = list[2] - gap, list[1] - ls
	else
		ax, ay = vsx - gap, mathFloor(220 * scale)
	end
	launcher.x1, launcher.y1, launcher.x2, launcher.y2 = ax - ls, ay, ax, ay + ls
	local w, h = mathFloor(WIN_W * scale), mathMin(mathFloor(WIN_H * scale), vsy - 2 * gap)
	local x2 = launcher.x1 - gap + offX
	local y2 = launcher.y2 + offY
	x2 = mathMax(w + gap, mathMin(vsx - gap, x2))
	y2 = mathMax(h + gap, mathMin(vsy - gap, y2))
	win.x1, win.y1, win.x2, win.y2 = x2 - w, y2 - h, x2, y2
end

-- ---------------------------------------------------------------- lifecycle

local function initFlowUI()
	hasFlowUI = WG.FlowUI ~= nil and WG.FlowUI.Draw ~= nil
	if hasFlowUI then
		RectRound = WG.FlowUI.Draw.RectRound
		RectRoundOutline = WG.FlowUI.Draw.RectRoundOutline
		UiElement = WG.FlowUI.Draw.Element
	end
	if WG.fonts then
		font = WG.fonts.getFont()
		font2 = WG.fonts.getFont(2)
	end
end

-- D-345: SEA lanes, calculated by each locally hosted SEA AI (AngelScript,
-- data/script/src/systems/sea/sea_lanes.as) and published as the state-file
-- key "sealanes" (D-300), like the layout. Payload:
--   1;<frame>;<factory>,<kind>,<contact index>,x,z,x,z,...;...
-- kind 0 ends in the water by an enemy start box, kind 1 at a landing beach.
-- Drawn in the owning team's colour: a ring at the factory, the line, a dot
-- at the nearest last known enemy, a square (start box) or triangle (beach)
-- at the end. Visualisation only. /barbsealanes [on|off] toggles it.
-- D-349: the same module is the Tactical view: tactical positions placed on
-- the map as waypoints. Repair points ("searepair": 1;<ship>,<x>,<z>,<retreating>;...)
-- are a pin standing out of the water with a diamond head and a "repair"
-- label, in the team colour; one pin per position, however many ships share
-- it, with the count in the label. A retreating ship gets a line from its
-- current position. /barbtactical [on|off] (alias /barbtactics) toggles the
-- view, /barbrepair and /barbsealanes its layers.
-- Cost: parsing only when the file changes; DrawWorld draws a few hundred
-- vertices; no per-frame engine queries beyond ground height per vertex.
local seaLanes = (function()
    local show = true          -- the whole Tactics overlay
    local showLanes, showRepair = true, true
    local byTeam = {}
    local frontByTeam = {}    -- same geometry protocol; independent land/sea publications
    local repairByTeam = {}    -- team -> { {ship, x, y, z, retreating} }
    local function receiveRepair(team, payload)
        local list = {}
        local first = true
        for part in (payload .. ";"):gmatch("(.-);") do
            if first then first = false
            else
                local id, x, z, r = part:match("^(%d+),(%-?%d+),(%-?%d+),(%d)$")
                if id then
                    x, z = tonumber(x), tonumber(z)
                    list[#list + 1] = { ship = tonumber(id), x = x, y = math.max(0, Spring.GetGroundHeight(x, z) or 0) + 10, z = z, retreating = r == "1" }
                end
            end
        end
        repairByTeam[team] = list
    end      -- team -> { frame, lanes = { {factory, kind, contact, pts={{x,y,z}}} } }
    -- Front lanes (D-359): record kind 2 is the seat's fixed lane, whose
    -- contact field is the first vertex of its unsupplied section (-1: all
    -- supplied); record kind 3 is the fork link to the corridor the seat is
    -- assisting. The fixed lane is always drawn; nothing changes colour.
    local function ground(x, z) return math.max(0, Spring.GetGroundHeight(x, z) or 0) + 10 end
    -- D-350: friendly lanes that run together are drawn like a metro map: a
    -- bundle of parallel strands, one per lane in its owner's colour, which
    -- separate again where the lanes branch. Every lane is resampled every
    -- STEP elmos; a sample shares a bundle with other lanes' samples within
    -- NEAR (50) elmos heading the same way (|cos| > 0.7) and owned by the same ally
    -- team. Each lane takes a fixed
    -- slot in a bundle (ordered by team, then factory) and is shifted
    -- sideways by one line width per slot; shifts are smoothed over a few samples so
    -- strands ease in and out. Rebuilt only when a lane file changes:
    -- O(samples x neighbours) with a 128-elmo cell hash, a few thousand
    -- samples at most; drawing then costs only the stored vertices.
    -- Strands sit exactly side by side on screen: a lane's sideways shift is
    -- stored in strand slots and turned into elmos each frame from the
    -- camera's elmos per pixel, so neighbours touch at every zoom. Lines
    -- keep their normal width; only the bundle reads wider.
    local STEP, NEAR, CELL = 64, 50, 128
    local LINE_PX = 2.5        -- strand width in pixels, and the slot pitch
    local strands = {}         -- { team, lane, pts = {{x, y, z, nx, nz, slot}} }
    local function resample(pts)
        local out = {}
        for i = 1, #pts - 1 do
            local a, b = pts[i], pts[i + 1]
            local dx, dz = b[1] - a[1], b[3] - a[3]
            local len = math.sqrt(dx * dx + dz * dz)
            local n = math.max(1, math.floor(len / STEP))
            for k = 0, n - 1 do
                out[#out + 1] = { x = a[1] + dx * k / n, z = a[3] + dz * k / n, dx = dx / math.max(len, 1), dz = dz / math.max(len, 1), v = i - 1 }
            end
        end
        local last, prev = pts[#pts], out[#out]
        out[#out + 1] = { x = last[1], z = last[3], dx = prev and prev.dx or 1, dz = prev and prev.dz or 0, v = #pts - 1 }
        return out
    end
    local function rebuild()
        strands = {}
        local all = {}
        for _, entries in ipairs({byTeam, frontByTeam}) do
        for team, entry in pairs(entries) do
            if isPermittedTeam(team) then
                for _, lane in ipairs(entry.lanes) do
                    if #lane.pts >= 2 then
                        local ally = select(6, Spring.GetTeamInfo(team, false)) or team
                        all[#all + 1] = { team = team, ally = ally, lane = lane, key = team * 100000 + (lane.factory or 0), samples = resample(lane.pts) }
                    end
                end
            end
        end
        end
        table.sort(all, function(a, b) return a.key < b.key end)
        local grid = {}
        for li, l in ipairs(all) do
            for si, p in ipairs(l.samples) do
                local c = math.floor(p.x / CELL) .. ":" .. math.floor(p.z / CELL)
                grid[c] = grid[c] or {}
                local bucket = grid[c]; bucket[#bucket + 1] = { li, si }
            end
        end
        for li, l in ipairs(all) do
            local raw = {}
            for si, p in ipairs(l.samples) do
                local present = { [li] = true }
                local cx, cz = math.floor(p.x / CELL), math.floor(p.z / CELL)
                for ox = -1, 1 do for oz = -1, 1 do
                    local bucket = grid[(cx + ox) .. ":" .. (cz + oz)]
                    if bucket then
                        for _, ref in ipairs(bucket) do
                            local oli = ref[1]
                            -- Only friendly lanes bundle: a spectator sees both
                            -- sides, and opposing lanes in one channel stay apart.
                            if oli ~= li and not present[oli] and all[oli].ally == l.ally then
                                local q = all[oli].samples[ref[2]]
                                local ddx, ddz = q.x - p.x, q.z - p.z
                                if ddx * ddx + ddz * ddz <= NEAR * NEAR and math.abs(q.dx * p.dx + q.dz * p.dz) > 0.7 then present[oli] = true end
                            end
                        end
                    end
                end end
                local ids = {}
                for id in pairs(present) do ids[#ids + 1] = id end
                table.sort(ids)
                local slot = 1
                for k, id in ipairs(ids) do if id == li then slot = k end end
                -- A canonical sideways direction, so every lane in a bundle
                -- agrees which side is which whatever its own heading.
                local nx, nz = -p.dz, p.dx
                if nx < 0 or (nx == 0 and nz < 0) then nx, nz = -nx, -nz end
                raw[si] = { off = slot - (#ids + 1) / 2, nx = nx, nz = nz }
            end
            local pts = {}
            -- D-359: a front lane (kind 2) with contact >= 0 is unsupplied from
            -- that vertex on while its seat assists a neighbour: those samples
            -- are drawn translucent, in the same colour. A fork link (kind 3)
            -- is an ordinary strand of its owner's colour.
            local dimFrom = (l.lane.kind == 2 and l.lane.contact and l.lane.contact >= 0) and l.lane.contact or nil
            for si, p in ipairs(l.samples) do
                local sum, n = 0, 0
                for k = math.max(1, si - 2), math.min(#raw, si + 2) do sum = sum + raw[k].off; n = n + 1 end
                pts[#pts + 1] = { p.x, ground(p.x, p.z), p.z, raw[si].nx, raw[si].nz, sum / n, dimFrom ~= nil and p.v >= dimFrom }
            end
            strands[#strands + 1] = { team = l.team, lane = l.lane, pts = pts }
        end
    end
    local function receive(team, payload, front)
        local parts = {}
        for v in (payload .. ";"):gmatch("(.-);") do parts[#parts + 1] = v end
        if parts[1] ~= "1" then return end
        local entry = { frame = tonumber(parts[2]) or 0, lanes = {} }
        for i = 3, #parts do
            local n = {}
            for v in parts[i]:gmatch("[^,]+") do n[#n + 1] = tonumber(v) end
            if #n >= 7 and n[1] and n[2] and n[3] then
                local lane = { factory = n[1], kind = n[2], contact = n[3], pts = {} }
                for j = 4, #n - 1, 2 do
                    local x, z = n[j], n[j + 1]
                    if x and z then lane.pts[#lane.pts + 1] = { x, ground(x, z), z } end
                end
                entry.lanes[#entry.lanes + 1] = lane
            end
        end
        if front then frontByTeam[team] = entry else byTeam[team] = entry end
        rebuild()
    end
    local function colour(team, alpha)
        local r, g, b = Spring.GetTeamColor(team)
        return r or 1, g or 1, b or 1, alpha
    end
    local PIN = 140            -- waypoint pin height (elmos above the water)
    local MERGE = 160          -- repair points closer than this share one waypoint
    local function waypoints()
        -- One waypoint per (team, position): ships sharing a point share a pin.
        local pins = {}
        for team, list in pairs(repairByTeam) do
            if isPermittedTeam(team) then
                -- Points within MERGE elmos of a pin join it (ships that are
                -- already clear each hold where they are): O(points x pins).
                local own = {}
                for _, p in ipairs(list) do
                    local w
                    for _, q in ipairs(own) do
                        local dx, dz = q.x - p.x, q.z - p.z
                        if dx * dx + dz * dz <= MERGE * MERGE then w = q; break end
                    end
                    if not w then
                        w = { team = team, x = p.x, y = p.y, z = p.z, ships = 0, retreating = 0, kind = "repair" }
                        own[#own + 1] = w; pins[#pins + 1] = w
                    end
                    w.ships = w.ships + 1
                    if p.retreating then w.retreating = w.retreating + 1 end
                end
            end
        end
        return pins
    end
    -- Elmos covered by one screen pixel at the camera's focus (vertical FOV).
    local function elmosPerPixel()
        local _, cy = Spring.GetCameraPosition()
        local _, vsy = Spring.GetViewGeometry()
        local fov = math.rad(Spring.GetCameraFOV() or 45)
        return math.max(0.2, 2 * math.max(200, cy or 2000) * math.tan(fov / 2) / math.max(1, vsy or 1080))
    end
    local DIM = 0.28           -- alpha of an unsupplied lane section (D-359)
    local function strandVertices(st, k, dy, r, g, b, a)
        for _, p in ipairs(st.pts) do
            if r then gl.Color(r, g, b, p[7] and a * DIM or a) end
            gl.Vertex(p[1] + p[4] * p[6] * k, p[2] + (dy or 0), p[3] + p[5] * p[6] * k)
        end
    end
    local function drawRepair()
        -- World part of a repair waypoint: a thin stem and a ground ring; the
        -- wrench badge and label are drawn on screen (drawScreen).
        for _, w in ipairs(waypoints()) do
            local r, g, b = Spring.GetTeamColor(w.team)
            gl.LineWidth(1.5); gl.Color(r or 1, g or 1, b or 1, w.retreating > 0 and 0.9 or 0.5)
            gl.BeginEnd(GL.LINES, function() gl.Vertex(w.x, w.y, w.z); gl.Vertex(w.x, w.y + PIN, w.z) end)
            gl.DrawGroundCircle(w.x, w.y, w.z, 40, 20)
        end
        for team, list in pairs(repairByTeam) do
            if isPermittedTeam(team) then
                local r, g, b = Spring.GetTeamColor(team)
                for _, p in ipairs(list) do
                    if p.retreating then
                        local ux, uy, uz = Spring.GetUnitPosition(p.ship)
                        if ux then
                            gl.LineWidth(1); gl.Color(r or 1, g or 1, b or 1, 0.5)
                            gl.BeginEnd(GL.LINES, function() gl.Vertex(ux, math.max(0, uy) + 10, uz); gl.Vertex(p.x, p.y, p.z) end)
                        end
                    end
                end
            end
        end
        gl.LineWidth(1); gl.Color(1, 1, 1, 1)
    end
    local function drawWorld()
        if not show then return end
        if showRepair then drawRepair() end
        if not showLanes then return end
        local k = LINE_PX * elmosPerPixel()
        gl.LineWidth(LINE_PX + 1.5)
        for _, st in ipairs(strands) do if theatres.ShowsTeam(st.team) then gl.BeginEnd(GL.LINE_STRIP, function() strandVertices(st, k, -1, 0, 0, 0, 0.45) end) end end
        gl.LineWidth(LINE_PX)
        for _, st in ipairs(strands) do
            if theatres.ShowsTeam(st.team) then
            local r, g, b = colour(st.team, 1)
            gl.BeginEnd(GL.LINE_STRIP, function() strandVertices(st, k, nil, r, g, b, 0.95) end)
            end
        end
        gl.LineWidth(1); gl.Color(1, 1, 1, 1)
    end
    -- Screen-space badges: a dark disc with a team-coloured ring and a white
    -- symbol, the same size at every zoom. (x, y) is the badge centre.
    local BADGE = 12
    local function disc(x, y, radius)
        gl.BeginEnd(GL.TRIANGLE_FAN, function()
            gl.Vertex(x, y)
            for a = 0, 24 do local t = a / 24 * 2 * math.pi; gl.Vertex(x + math.cos(t) * radius, y + math.sin(t) * radius) end
        end)
    end
    local function ring(x, y, radius, from, to)
        gl.BeginEnd(GL.LINE_STRIP, function()
            for a = 0, 20 do local t = from + (to - from) * a / 20; gl.Vertex(x + math.cos(t) * radius, y + math.sin(t) * radius) end
        end)
    end
    local function badge(x, y, r, g, b, symbol, angle)
        gl.Color(0.04, 0.06, 0.09, 0.85); disc(x, y, BADGE)
        gl.LineWidth(2); gl.Color(r, g, b, 1); ring(x, y, BADGE, 0, 2 * math.pi)
        gl.Color(1, 1, 1, 1); gl.LineWidth(2)
        if symbol == "wrench" then
            -- Handle from lower left to an open jaw at upper right.
            gl.BeginEnd(GL.LINES, function() gl.Vertex(x - 6, y - 6); gl.Vertex(x + 1, y + 1) end)
            ring(x + 3.5, y + 3.5, 3.5, math.rad(-20), math.rad(250))
        elseif symbol == "anchor" then
            gl.BeginEnd(GL.LINES, function()
                gl.Vertex(x, y + 7); gl.Vertex(x, y - 6)
                gl.Vertex(x - 4, y + 4); gl.Vertex(x + 4, y + 4)
            end)
            ring(x, y - 1, 6, math.rad(200), math.rad(340))
            ring(x, y + 8, 1.5, 0, 2 * math.pi)
        elseif symbol == "target" then
            ring(x, y, 6, 0, 2 * math.pi); ring(x, y, 2, 0, 2 * math.pi)
            gl.BeginEnd(GL.LINES, function()
                gl.Vertex(x - 10, y); gl.Vertex(x - 7, y); gl.Vertex(x + 7, y); gl.Vertex(x + 10, y)
                gl.Vertex(x, y - 10); gl.Vertex(x, y - 7); gl.Vertex(x, y + 7); gl.Vertex(x, y + 10)
            end)
        elseif symbol == "landing" then
            -- Two chevrons pointing along `angle` (towards the shore).
            local dx, dy = math.cos(angle or math.pi / 2), math.sin(angle or math.pi / 2)
            local nx, ny = -dy, dx
            for c = 0, 1 do
                local bx, by = x + dx * (c * 5 - 1), y + dy * (c * 5 - 1)
                gl.BeginEnd(GL.LINE_STRIP, function()
                    gl.Vertex(bx - dx * 4 + nx * 5, by - dy * 4 + ny * 5); gl.Vertex(bx, by); gl.Vertex(bx - dx * 4 - nx * 5, by - dy * 4 - ny * 5)
                end)
            end
        elseif symbol == "enemy" then
            gl.LineWidth(2.5)
            gl.BeginEnd(GL.LINES, function() gl.Vertex(x, y + 7); gl.Vertex(x, y - 1) end)
            disc(x, y - 5, 1.6)
        end
        gl.LineWidth(1)
    end
    local function toScreen(x, y, z)
        local sx, sy, sz = Spring.WorldToScreenCoords(x, y, z)
        if sx and sz and sz < 1 then return sx, sy end
    end
    local function drawScreen()
        if not show then return end
        if showLanes then
            -- One badge per distinct position: lanes sharing a start, contact or
            -- end share its badge. O(lanes).
            local seen = {}
            local function once(key) if seen[key] then return false end seen[key] = true return true end
            for team, entry in pairs(byTeam) do
                if theatres.ShowsTeam(team) then
                    local r, g, b = colour(team, 1)
                    for _, lane in ipairs(entry.lanes) do
                        local pts = lane.pts
                        if #pts >= 2 then
                            local s0, e = pts[1], pts[#pts]
                            local sx, sy = toScreen(s0[1], s0[2], s0[3])
                            if sx and once("s" .. team .. ":" .. math.floor(s0[1] / 64) .. ":" .. math.floor(s0[3] / 64)) then
                                badge(sx, sy, r, g, b, "anchor")
                            end
                            local c = pts[(lane.contact or -1) + 1]
                            if lane.contact and lane.contact >= 0 and c then
                                local cx, cy = toScreen(c[1], c[2], c[3])
                                if cx and once("c" .. math.floor(c[1] / 128) .. ":" .. math.floor(c[3] / 128)) then
                                    badge(cx, cy, 1, 0.25, 0.2, "enemy")
                                end
                            end
                            local ex, ey = toScreen(e[1], e[2], e[3])
                            if ex and once("e" .. math.floor(e[1] / 200) .. ":" .. math.floor(e[3] / 200)) then
                                local angle
                                if lane.kind == 1 then
                                    local p = pts[#pts - 1]
                                    local px, py = toScreen(p[1], p[2], p[3])
                                    if px then angle = math.atan2(ey - py, ex - px) end
                                end
                                badge(ex, ey, r, g, b, lane.kind == 1 and "landing" or "target", angle)
                                gl.Color(1, 1, 1, 0.9)
                                gl.Text(lane.kind == 1 and "landing" or "enemy base", ex, ey + BADGE + 4, 12, "co")
                            end
                        end
                    end
                end
            end
        end
        if not showRepair then return end
        for _, w in ipairs(waypoints()) do
            local sx, sy = toScreen(w.x, w.y + PIN, w.z)
            if sx then
                local r, g, b = Spring.GetTeamColor(w.team)
                badge(sx, sy + BADGE, r or 1, g or 1, b or 1, "wrench")
                gl.Color(r or 1, g or 1, b or 1, w.retreating > 0 and 1 or 0.75)
                gl.Text(w.ships > 1 and string.format("repair x%d", w.ships) or "repair", sx, sy + 2 * BADGE + 4, 12, "co")
            end
        end
        gl.Color(1, 1, 1, 1)
    end
    local function drawMiniMap(sx, sy)
        if not show or not showLanes then return end
        local mx, mz = Game.mapSizeX, Game.mapSizeZ
        gl.PushMatrix()
        gl.Translate(0, sy, 0); gl.Scale(sx / mx, -sy / mz, 1)
        gl.LineWidth(1.5)
        for _, st in ipairs(strands) do
            if theatres.ShowsTeam(st.team) then
            local r, g, b = colour(st.team, 1)
            gl.BeginEnd(GL.LINE_STRIP, function() for _, p in ipairs(st.pts) do gl.Color(r, g, b, p[7] and 0.9 * DIM or 0.9); gl.Vertex(p[1], p[3], 0) end end)
            end
        end
        gl.PopMatrix(); gl.LineWidth(1); gl.Color(1, 1, 1, 1)
    end
    local function textCommand(cmd)
        local what, state = cmd:match("^barb(%a+)%s*(%a*)$")
        if what == "tactics" then what = "tactical" end
        -- barblanes/barblandlanes/barbsealanes are the shared player/team/off
        -- lane selection (widget:TextCommand, D-354); the tactical view's own
        -- lane layer is barbtacticallanes (D-356: the old alias was unreachable).
        if what ~= "tactical" and what ~= "tacticallanes" and what ~= "repair" then return false end
        local function set(current) if state == "on" then return true elseif state == "off" then return false end return not current end
        if what == "tactical" then show = set(show); territory.Set(show)
        elseif what == "tacticallanes" then showLanes = set(showLanes); if showLanes then show = true end
        else showRepair = set(showRepair); if showRepair then show = true end end
        Spring.Echo(string.format("[BARb link] tactical view %s (lanes %s, repair %s)", show and "on" or "off",
            showLanes and "on" or "off", showRepair and "on" or "off"))
        return true
    end
    return {
        Receive = receive, ReceiveRepair = receiveRepair, DrawWorld = drawWorld, DrawScreen = drawScreen, DrawMiniMap = drawMiniMap, TextCommand = textCommand,
        GetConfig = function() return { show = show, lanes = showLanes, repair = showRepair } end,
        EnableLanes = function() show, showLanes = true, true end,
        Config = function(c)
            if type(c) ~= "table" then return end
            if c.show ~= nil then show = c.show == true end
            if c.lanes ~= nil then showLanes = c.lanes == true end
            if c.repair ~= nil then showRepair = c.repair == true end
        end,
    }
end)()

-- D-352: the Territory layer of the Tactical view. Each hosted BARb publishes
-- the state key "territory" (WidgetLink::SetState from Team::MexClaim::Tick):
--   barb|territory|<team>|<allyTeam>|1;<frame>;<landWindow><theatreWindow>;<homeRadius>
--     ;S,<x>,<z>,<mask>,<rule>,<owner>,<lane>    one per metal spot
--     ;L,<id>,<midX>,<midZ>,<chokeX>,<chokeZ>,<width>,<members t+t>,<spine x:z ...>
--     ;H,<team>,<x>,<z>                           one per claim (the home circle)
-- Every ally resolves the same owners, so one sender per ally team is drawn
-- (the lowest hosted team id). A spot is a ring in its owner's colour, its
-- shape by rule: disc = home, ring = walk, diamond = sea, triangle = race
-- (secured, contested, air), square = lane cluster, cross = forward (nobody's,
-- past the midpoint), dotted grey = open / nobody. Lane spines are thin dashed
-- lines in the founding member's colour, with a bar at the midpoint and an X at
-- the choke. Home circles are faint rings. Labels on screen name the rule and
-- owner for spots near the cursor. /barbterritory [on|off] toggles the layer;
-- it is part of /barbtactical. Cost: parsing only when the state changes;
-- a few hundred vertices per frame; no per-frame engine queries beyond ground
-- height at parse time.
local territory = (function()
    local show = true
    local byAlly = {}          -- allyTeam -> { team, frame, windows, home, spots, lanes, homes }
    local RULE = { [0] = "none", "home", "sea", "lane", "walk", "forward", "secured", "contested", "air", "open-land", "open-class" }
    local function ground(x, z) return math.max(0, Spring.GetGroundHeight(x, z) or 0) + 8 end
    local function receive(team, payload)
        local parts = {}
        for v in (payload .. ";"):gmatch("(.-);") do parts[#parts + 1] = v end
        if parts[1] ~= "1" then return end
        local ally = select(6, Spring.GetTeamInfo(team, false)) or team
        local entry = byAlly[ally]
        if entry and entry.team ~= team and entry.team < team then return end   -- one sender per ally team
        entry = { team = team, frame = tonumber(parts[2]) or 0, windows = parts[3] or "00", home = tonumber(parts[4]) or 0, spots = {}, lanes = {}, homes = {} }
        for i = 5, #parts do
            local f = {}
            for v in parts[i]:gmatch("[^,]+") do f[#f + 1] = v end
            if f[1] == "S" and #f >= 7 then
                local x, z = tonumber(f[2]), tonumber(f[3])
                entry.spots[#entry.spots + 1] = { x = x, y = ground(x, z), z = z, mask = tonumber(f[4]) or 8, rule = tonumber(f[5]) or 0, owner = tonumber(f[6]) or -1, lane = tonumber(f[7]) or -1 }
            elseif f[1] == "L" and #f >= 8 then
                local lane = { id = tonumber(f[2]), mid = { tonumber(f[3]), tonumber(f[4]) }, choke = { tonumber(f[5]), tonumber(f[6]) }, width = tonumber(f[7]) or -1, members = {}, pts = {} }
                for m in (f[8] or ""):gmatch("[^+]+") do lane.members[#lane.members + 1] = tonumber(m) end
                for j = 9, #f do
                    local x, z = f[j]:match("^(%-?%d+):(%-?%d+)$")
                    if x then x, z = tonumber(x), tonumber(z); lane.pts[#lane.pts + 1] = { x, ground(x, z), z } end
                end
                entry.lanes[#entry.lanes + 1] = lane
            elseif f[1] == "H" and #f >= 4 then
                entry.homes[#entry.homes + 1] = { team = tonumber(f[2]), x = tonumber(f[3]), z = tonumber(f[4]) }
            end
        end
        byAlly[ally] = entry
    end
    local function colour(team, alpha)
        if team == nil or team < 0 then return 0.75, 0.75, 0.75, alpha end
        local r, g, b = Spring.GetTeamColor(team)
        return r or 1, g or 1, b or 1, alpha
    end
    local function ring(x, y, z, radius, n)
        gl.BeginEnd(GL.LINE_LOOP, function()
            for a = 0, (n or 20) - 1 do local t = a / (n or 20) * 2 * math.pi; gl.Vertex(x + math.cos(t) * radius, y, z + math.sin(t) * radius) end
        end)
    end
    local function disc(x, y, z, radius)
        gl.BeginEnd(GL.TRIANGLE_FAN, function()
            gl.Vertex(x, y, z)
            for a = 0, 20 do local t = a / 20 * 2 * math.pi; gl.Vertex(x + math.cos(t) * radius, y, z + math.sin(t) * radius) end
        end)
    end
    local function poly(x, y, z, radius, sides, turn)
        gl.BeginEnd(GL.LINE_LOOP, function()
            for a = 0, sides - 1 do local t = (turn or 0) + a / sides * 2 * math.pi; gl.Vertex(x + math.cos(t) * radius, y, z + math.sin(t) * radius) end
        end)
    end
    local function cross(x, y, z, r)
        gl.BeginEnd(GL.LINES, function()
            gl.Vertex(x - r, y, z - r); gl.Vertex(x + r, y, z + r); gl.Vertex(x - r, y, z + r); gl.Vertex(x + r, y, z - r)
        end)
    end
    local SPOT = 44
    -- Membership checks reuse the lane selection; no geometry rebuild or
    -- per-frame filtered arrays. Territory spots remain a separate layer.
    local function laneVisible(lane)
        for _, team in ipairs(lane.members) do if theatres.ShowsTeam(team) then return true end end
        return false
    end
    local function drawSpot(s)
        local r, g, b = colour(s.owner, 1)
        local rule = s.rule
        if rule == 1 then gl.Color(r, g, b, 0.35); disc(s.x, s.y, s.z, SPOT); gl.Color(r, g, b, 0.95); ring(s.x, s.y, s.z, SPOT)
        elseif rule == 2 then gl.Color(r, g, b, 0.95); poly(s.x, s.y, s.z, SPOT, 4, 0)
        elseif rule == 3 then gl.Color(r, g, b, 0.95); poly(s.x, s.y, s.z, SPOT, 4, math.pi / 4)
        elseif rule == 4 then gl.Color(r, g, b, 0.9); ring(s.x, s.y, s.z, SPOT)
        elseif rule == 5 then gl.Color(0.9, 0.3, 0.3, 0.9); cross(s.x, s.y, s.z, SPOT * 0.7)
        elseif rule == 6 or rule == 7 or rule == 8 then gl.Color(r, g, b, 0.95); poly(s.x, s.y, s.z, SPOT * 1.1, 3, -math.pi / 2)
        else gl.Color(0.7, 0.7, 0.7, 0.6); ring(s.x, s.y, s.z, SPOT * 0.8, 8) end
    end
    local function drawWorld()
        if not show then return end
        for ally, entry in pairs(byAlly) do
            if isPermittedTeam(entry.team) then
                gl.LineWidth(1.2)
                for _, h in ipairs(entry.homes) do
                    local r, g, b = colour(h.team, 1)
                    gl.Color(r, g, b, 0.25); ring(h.x, ground(h.x, h.z), h.z, entry.home, 48)
                end
                gl.LineWidth(1.6)
                for _, lane in ipairs(entry.lanes) do
                    if laneVisible(lane) then
                    local r, g, b = colour(lane.members[1], 1)
                    gl.Color(r, g, b, 0.55)
                    if #lane.pts >= 2 then
                        gl.BeginEnd(GL.LINES, function()
                            for i = 1, #lane.pts - 1, 2 do
                                local a, c = lane.pts[i], lane.pts[i + 1]
                                gl.Vertex(a[1], a[2], a[3]); gl.Vertex(c[1], c[2], c[3])
                            end
                        end)
                    end
                    local mx, mz = lane.mid[1], lane.mid[2]
                    if mx and mx >= 0 then gl.Color(1, 1, 1, 0.8); ring(mx, ground(mx, mz), mz, 60, 12) end
                    local cx, cz = lane.choke[1], lane.choke[2]
                    if cx and cx >= 0 then gl.Color(1, 0.85, 0.3, 0.9); gl.LineWidth(2.2); cross(cx, ground(cx, cz) + 4, cz, 70); gl.LineWidth(1.6) end
                    end
                end
                gl.LineWidth(2)
                for _, s in ipairs(entry.spots) do drawSpot(s) end
            end
        end
        gl.LineWidth(1); gl.Color(1, 1, 1, 1)
    end
    local function drawMiniMap(sx, sy)
        if not show then return end
        local mx, mz = Game.mapSizeX, Game.mapSizeZ
        gl.PushMatrix()
        gl.Translate(0, sy, 0); gl.Scale(sx / mx, -sy / mz, 1)
        gl.PointSize(4)
        for _, entry in pairs(byAlly) do
            if isPermittedTeam(entry.team) then
                gl.BeginEnd(GL.POINTS, function()
                    for _, s in ipairs(entry.spots) do
                        local r, g, b = colour(s.owner, 1)
                        if s.rule == 0 or s.rule == 5 then r, g, b = 0.6, 0.6, 0.6 end
                        gl.Color(r, g, b, 0.9); gl.Vertex(s.x, s.z, 0)
                    end
                end)
                gl.LineWidth(1)
                for _, lane in ipairs(entry.lanes) do
                    if laneVisible(lane) then
                    local r, g, b = colour(lane.members[1], 1)
                    gl.Color(r, g, b, 0.6)
                    gl.BeginEnd(GL.LINE_STRIP, function() for _, p in ipairs(lane.pts) do gl.Vertex(p[1], p[3], 0) end end)
                    end
                end
            end
        end
        gl.PointSize(1); gl.PopMatrix(); gl.LineWidth(1); gl.Color(1, 1, 1, 1)
    end
    local function toScreen(x, y, z)
        local sx, sy, sz = Spring.WorldToScreenCoords(x, y, z)
        if sx and sz and sz < 1 then return sx, sy end
    end
    local function drawScreen()
        if not show then return end
        local mx, my = Spring.GetMouseState()
        local _, pos = Spring.TraceScreenRay(mx, my, true)
        for _, entry in pairs(byAlly) do
            if isPermittedTeam(entry.team) then
                local n = 0
                for _, s in ipairs(entry.spots) do
                    if pos and (s.x - pos[1]) ^ 2 + (s.z - pos[3]) ^ 2 <= 600 * 600 then
                        local sx, sy = toScreen(s.x, s.y, s.z)
                        if sx then
                            local r, g, b = colour(s.owner, 1)
                            gl.Color(0, 0, 0, 0.6); gl.Text(string.format("%s %s%s", RULE[s.rule] or "?", s.owner >= 0 and ("P" .. s.owner) or "free", s.lane >= 0 and (" L" .. s.lane) or ""), sx + 1, sy + 13, 11, "o")
                            gl.Color(r, g, b, 1); gl.Text(string.format("%s %s%s", RULE[s.rule] or "?", s.owner >= 0 and ("P" .. s.owner) or "free", s.lane >= 0 and (" L" .. s.lane) or ""), sx, sy + 14, 11, "o")
                            n = n + 1
                        end
                    end
                end
                for _, lane in ipairs(entry.lanes) do
                    if laneVisible(lane) then
                    local cx, cz = lane.choke[1], lane.choke[2]
                    if cx and cx >= 0 then
                        local sx, sy = toScreen(cx, ground(cx, cz), cz)
                        if sx then
                            gl.Color(1, 0.85, 0.3, 1)
                            gl.Text(string.format("lane %d choke %s  P%s", lane.id or 0, lane.width >= 0 and (math.floor(lane.width) .. " wide") or "", table.concat(lane.members, "+")), sx, sy + 16, 11, "oc")
                        end
                    end
                    end
                end
                local sx, sy = 12, 12
                gl.Color(0.85, 0.9, 1, 0.9)
                gl.Text(string.format("territory P%d: %d spots, %d lanes, window %s/%s, home %d", entry.team, #entry.spots, #entry.lanes,
                    entry.windows:sub(1, 1) == "1" and "land" or "open", entry.windows:sub(2, 2) == "1" and "sea" or "open", entry.home), sx, sy, 10, "o")
            end
        end
        gl.Color(1, 1, 1, 1)
    end
    local function textCommand(cmd)
        local what, state = cmd:match("^barb(%a+)%s*(%a*)$")
        if what ~= "territory" then return false end
        if state == "on" then show = true elseif state == "off" then show = false else show = not show end
        Spring.Echo(string.format("[BARb link] territory layer %s", show and "on" or "off"))
        return true
    end
    return {
        Receive = receive, DrawWorld = drawWorld, DrawScreen = drawScreen, DrawMiniMap = drawMiniMap, TextCommand = textCommand,
        GetConfig = function() return { show = show } end,
        Config = function(c) if type(c) == "table" and c.show ~= nil then show = c.show == true end end,
        Set = function(on) show = on end,
        Snapshot = function() return byAlly end,
    }
end)()

-- BEGIN STRATEGY MODULE
-- Embedded by tools/widgets/embed_strategy.py into gui_barb_team_link.lua.
-- Pure renderer of AI publications. No unit enumeration, orders or ownership inference.
local strategy = (function()
    local show, frozen, inspect = false, nil, false
    local frozenTerritory=nil
    local live, revision, built, modelSeen = {}, 0, -1, nil
    local lastPayload, lastTerritory = {}, {}
    local mode, cls, team, selectedCorridor = 1, 0, -1, nil
    local side=nil
    local modes = {"Overview", "Territory", "Commander", "Diagnostics"}
    local classes = {[0]="Vehicle", "Bot", "Amphibious", "Hover", "All-terrain", "Ship", "Sub"}
    -- Lane query classes differ from the field's class enum.
    local laneClass = {[0]=0, [1]=1, [2]=2, [3]=3, [4]=4, [5]=5}
    local controls, lists, terrainLists, job, inspection = {}, {}, {}, nil, nil
    local terrainKey=""
    local view, panel, freezeFrame = {}, nil, nil
    local displayTeams={}
    local function split(s, sep)
        local out, at = {}, 1
        while true do
            local a,b=string.find(s or "",sep,at,true)
            if not a then out[#out+1]=string.sub(s or "",at);return out end
            out[#out+1]=string.sub(s,at,a-1);at=b+1
        end
    end
    local function numbers(s)
        local out={}
        for _,v in ipairs(split(s,",")) do
            local n=tonumber(v)
            if not n or n~=n or math.abs(n)>1e12 then return nil end
            out[#out+1]=n
        end
        return out
    end
    local function route(s)
        local n=numbers(s);local out={}
        if not n or #n<3 or (#n-3)%2~=0 or #n>8195 then return out end
        for i=4,#n,2 do
            if n[i]<0 or n[i+1]<0 or n[i]>Game.mapSizeX or n[i+1]>Game.mapSizeZ then return {} end
            out[#out+1]={n[i],n[i+1]}
        end
        return out
    end
    local function receive(id,payload)
        if not isPermittedTeam(id) or #payload>150000 or lastPayload[id]==payload then return false end
        local f=split(payload,";")
        if f[1]~="1" or #f<15 then return false end
        local frame,assignment,class,corridor,rank,count=tonumber(f[2]),tonumber(f[3]),tonumber(f[4]),tonumber(f[5]),tonumber(f[6]),tonumber(f[7])
        local pos,help=numbers(f[8]),numbers(f[10])
        if not frame or frame<0 or not assignment or not class or not corridor or not rank or not count or not pos or #pos~=2 or not help or #help~=3 then return false end
        if live[id] and live[id].frame>frame then return false end
        local samples={}
        for _,v in ipairs(split(f[15],"|")) do
            local n=numbers(v)
            if n and #n==3 and #samples<33 then samples[#samples+1]=n end
        end
        local ally=Spring.GetTeamInfo and select(6,Spring.GetTeamInfo(id,false)) or -1
        if side==nil then side=ally end
        live[id]={team=id,ally=ally,frame=frame,assignment=assignment,class=laneClass[class],corridor=corridor,rank=rank,count=count,
            pos=pos,progress=tonumber(f[9]) or -1,help=help,request=tonumber(f[11]) or -1,fieldRevision=f[12],
            route=route(f[13]),proposal=route(f[14]),samples=samples,native=numbers(f[16] or ""),status=f[17] or "legacy snapshot",proposalStatus=f[18] or "unknown"}
        lastPayload[id]=payload;revision=revision+1
        return true
    end
    local function invalidate() built=-1 end
    local function clearLists()
        for _,id in ipairs(lists) do gl.DeleteList(id) end
        for _,id in ipairs(terrainLists) do gl.DeleteList(id) end
        lists={};terrainLists={};terrainKey="";job=nil
    end
    local function colour(id,alpha)
        if id==nil or id<0 then gl.Color(.52,.56,.61,alpha);return end
        local r,g,b=Spring.GetTeamColor(id);gl.Color(r or 1,g or 1,b or 1,alpha)
    end
    local function vertex(x,z) gl.Vertex(x,math.max(0,Spring.GetGroundHeight(x,z))+9,z) end
    local function line(points,dashed)
        gl.BeginEnd(GL.LINES,function()
            for i=2,#points do
                local a,b=points[i-1],points[i]
                if dashed then
                    local dx,dz=b[1]-a[1],b[2]-a[2];local length=math.sqrt(dx*dx+dz*dz)
                    for d=0,length,128 do
                        local u,v=d/math.max(1,length),math.min(length,d+64)/math.max(1,length)
                        vertex(a[1]+dx*u,a[2]+dz*u);vertex(a[1]+dx*v,a[2]+dz*v)
                    end
                else vertex(a[1],a[2]);vertex(b[1],b[2]) end
            end
        end)
    end
    local function cross(x,z,r)
        gl.BeginEnd(GL.LINES,function() vertex(x-r,z);vertex(x+r,z);vertex(x,z-r);vertex(x,z+r) end)
    end
    local function at(runs,cell)
        local lo,hi=1,#(runs or {})
        while lo<=hi do
            local mid=math.floor((lo+hi)/2);local r=runs[mid]
            if cell<r[1] then hi=mid-1 elseif cell>=r[1]+r[3] then lo=mid+1 else return r[2] end
        end
        return nil
    end
    local function snapshot()
        local out={}
        local m=field.Model()
        for id,s in pairs(frozen or live) do
            if isPermittedTeam(id) and (not m or not m.corridorRevision or s.fieldRevision==m.corridorRevision) and (side==nil or side<0 or side==s.ally) and (team<0 or team==id) and s.class==cls then out[#out+1]=s end
        end
        table.sort(out,function(a,b)return a.team<b.team end)
        return out
    end
    local function prepare(m)
        view=snapshot();built=revision;displayTeams={}
        for _,s in ipairs(view) do displayTeams[s.team]=true end
        local key=tostring(m)..":"..cls..":"..mode..":"..tostring(selectedCorridor)..":"..team..":"..tostring(side)
        for _,s in ipairs(view) do key=key..":"..s.team.."/"..s.assignment.."/"..s.corridor end
        local rebuild=key~=terrainKey
        if rebuild then clearLists() else
            for _,id in ipairs(lists) do gl.DeleteList(id) end
            lists={};job=nil
        end
        modelSeen=m
        local owners={}
        for _,s in ipairs(view) do
            owners[s.corridor]=owners[s.corridor] or {};table.insert(owners[s.corridor],s.team)
        end
        job=coroutine.create(function()
            -- Each list holds at most 128 row spans. Build only in Update, never
            -- DrawWorld; yield between chunks. Revision/filter changes own invalidation.
            if rebuild and (mode==1 or mode==2 or mode==4) then
                local batch={}
                local function flush()
                    if #batch==0 then return end
                    terrainLists[#terrainLists+1]=gl.CreateList(function()
                        gl.BeginEnd(GL.QUADS,function()
                            for _,q in ipairs(batch) do
                                local own=owners[q[5]];local id=own and own[1] or -1
                                if own and #own>1 then gl.Color(1,.62,.12,.25) else colour(id,own and .16 or .045) end
                                vertex(q[1],q[2]);vertex(q[3],q[2]);vertex(q[3],q[4]);vertex(q[1],q[4])
                            end
                        end)
                    end)
                    batch={};coroutine.yield()
                end
                for _,r in ipairs(m.corridorRuns[cls] or {}) do
                    local first,last=r[1],r[1]+r[3]
                    while first<last do
                        local row=math.floor(first/m.gw);local stop=math.min(last,(row+1)*m.gw)
                        if r[2]>=0 and (not selectedCorridor or selectedCorridor==r[2]) then
                            batch[#batch+1]={(first%m.gw)*m.cell,row*m.cell,(stop-row*m.gw)*m.cell,(row+1)*m.cell,r[2]}
                            if #batch==128 then flush() end
                        end
                        first=stop
                    end
                end
                flush()
            end
            if rebuild then
            for id,c in pairs(m.corridors) do
                if c.class==cls and (not selectedCorridor or id==selectedCorridor) then
                    terrainLists[#terrainLists+1]=gl.CreateList(function()
                        local own=owners[id];colour(own and own[1],.65)
                        local points={};for _,p in ipairs(c.spine) do points[#points+1]={p[1],p[2]} end
                        line(points,false);cross(c.x,c.z,40)
                    end)
                    coroutine.yield()
                end
            end
            terrainKey=key
            end
            if mode==2 then
                for _,entry in pairs(frozenTerritory or territory.Snapshot()) do
                    local ally=Spring.GetTeamInfo and select(6,Spring.GetTeamInfo(entry.team,false)) or -1
                    if isPermittedTeam(entry.team) and (side==nil or side<0 or side==ally) then
                        displayTeams[entry.team]=true
                        lists[#lists+1]=gl.CreateList(function()
                            for _,spot in ipairs(entry.spots) do
                                if team<0 or spot.owner==team then
                                    local cell=math.floor(spot.z/m.cell)*m.gw+math.floor(spot.x/m.cell)
                                    local corridor=at(m.corridorRuns[cls],cell)
                                    local assigned=owners[corridor];local mismatch=assigned and spot.owner>=0
                                    for _,id in ipairs(assigned or {}) do if id==spot.owner then mismatch=false end end
                                    if not selectedCorridor or corridor==selectedCorridor then
                                        colour(spot.owner,1);cross(spot.x,spot.z,35)
                                        if mismatch then
                                            gl.Color(1,.4,.8,1)
                                            line({{spot.x-55,spot.z},{spot.x,spot.z+55},{spot.x+55,spot.z},{spot.x,spot.z-55},{spot.x-55,spot.z}},false)
                                        end
                                    end
                                end
                            end
                        end)
                        coroutine.yield()
                    end
                end
            end
            for _,s in ipairs(view) do
                lists[#lists+1]=gl.CreateList(function()
                    colour(s.team,1);gl.LineWidth(3);line(s.route,false)
                    if s.help[1]>=0 then gl.Color(1,.74,.25,.9);gl.LineWidth(2);line(s.proposal,true) end
                    if s.pos[1]>=0 then colour(s.team,1);cross(s.pos[1],s.pos[2],75) end
                    if mode==3 and s.native and #s.native>=10 and s.native[8]>=0 then
                        gl.Color(.4,1,.7,1);cross(s.native[8],s.native[9],105)
                    end
                    if mode==4 then
                        for _,p in ipairs(s.samples) do
                            gl.Color(p[3]>3 and 1 or .4,p[3]>3 and .25 or .85,.2,.85);cross(p[1],p[2],25)
                        end
                    end
                    gl.LineWidth(1)
                end)
                coroutine.yield()
            end
        end)
    end
    local function update()
        if not show then return end
        for id in pairs(displayTeams) do if not isPermittedTeam(id) then invalidate();break end end
        local m=field.Model();if not m then return end
        if built<0 or modelSeen~=m or (not frozen and built~=revision and not job) then prepare(m) end
        if job then
            local t=Spring.GetTimer()
            repeat
                local ok,err=coroutine.resume(job)
                if not ok then Spring.Echo("[BARb strategy] "..tostring(err));job=nil;break end
                if coroutine.status(job)=="dead" then job=nil end
            until not job or Spring.DiffTimers(Spring.GetTimer(),t)>=.002
        end
    end
    local function drawWorld()
        if not show or Spring.IsGUIHidden() then return end
        -- Permission changes also invalidate frozen/display-list state.
        for id in pairs(displayTeams) do if not isPermittedTeam(id) then clearLists();invalidate();return end end
        gl.DepthTest(false)
        for _,id in ipairs(terrainLists) do gl.CallList(id) end
        for _,id in ipairs(lists) do gl.CallList(id) end
        gl.LineWidth(1);gl.Color(1,1,1,1);gl.DepthTest(true)
    end
    local function inside(x,y,r) return r and x>=r[1] and x<=r[3] and y>=r[2] and y<=r[4] end
    local function drawScreen()
        if not show or Spring.IsGUIHidden() then return end
        for id in pairs(displayTeams) do if not isPermittedTeam(id) then invalidate();return end end
        controls={}
        local sx,sy=gl.GetViewSizes();local w=math.min(480,sx-24);local x,y=12,sy-54
        -- Dock below a top-left minimap instead of drawing underneath it.
        if Spring.GetMiniMapGeometry then
            local mx,my,mw,mh=Spring.GetMiniMapGeometry()
            if mx and x<mx+mw and x+w>mx and y+30>my and y-330<my+mh then
                if my>=372 then y=my-42 else x=math.min(sx-w-12,mx+mw+12) end
            end
        end
        panel={x,y-330,x+w,y+30};gl.Color(.025,.04,.06,.95);gl.Rect(unpack(panel));gl.Color(1,1,1,1)
        gl.Text("Strategy inspection",x+12,y+10,16,"o")
        local function button(label,bx,by,bw,action,active)
            local r={bx,by,bx+bw,by+30,action};controls[#controls+1]=r
            gl.Color(active and .16 or .075,active and .32 or .12,.2,1);gl.Rect(bx,by,bx+bw,by+30)
            gl.Color(1,1,1,1);gl.Text(label,bx+7,by+9,11,"o")
        end
        local bw=(w-24)/4
        for i,label in ipairs(modes) do button(label,x+12+(i-1)*bw,y-34,bw-3,function()mode=i;invalidate()end,mode==i) end
        button(classes[cls].." >",x+12,y-70,125,function()cls=(cls+1)%7;selectedCorridor=nil;inspection=nil;invalidate()end)
        button(team<0 and "All FRONT teams >" or "Team "..team.." >",x+143,y-70,125,function()
            local ids={};for id in pairs(frozen or live) do if isPermittedTeam(id) and (side==nil or side<0 or (frozen or live)[id].ally==side) then ids[#ids+1]=id end end;table.sort(ids)
            local nextId=-1;for _,id in ipairs(ids) do if id>team then nextId=id;break end end;team=nextId;invalidate()
        end)
        button((side==nil or side<0) and "All sides >" or "Side "..tostring(side).." >",x+274,y-70,110,function()
            local set,ids={},{}
            for id,s in pairs(frozen or live) do if isPermittedTeam(id) then set[s.ally]=true end end
            for id in pairs(set) do ids[#ids+1]=id end;table.sort(ids)
            local nextId=-1;for _,id in ipairs(ids) do if id>(side or -1) then nextId=id;break end end
            side=nextId;team=-1;invalidate()
        end)
        button("Close",x+w-80,y-70,68,function()show=false;clearLists()end)
        button(frozen and "Resume live" or "Freeze",x+12,y-106,110,function()
            if frozen then frozen=nil;frozenTerritory=nil;freezeFrame=nil else frozen={};for id,s in pairs(live) do frozen[id]=s end;frozenTerritory={};for id,s in pairs(territory.Snapshot()) do frozenTerritory[id]=s end;freezeFrame=Spring.GetGameFrame() end;invalidate()
        end,frozen~=nil)
        button(inspect and "Inspect ON" or "Inspect map",x+128,y-106,120,function()inspect=not inspect end,inspect)
        button("Reset filters",x+254,y-106,115,function()team=-1;cls=0;mode=1;selectedCorridor=nil;inspection=nil;invalidate()end)
        local now=Spring.GetGameFrame();local oldest=now
        for _,s in ipairs(view) do oldest=math.min(oldest,s.frame) end
        local function text(t) y=y-18;gl.Color(.85,.9,.94,1);gl.Text(t,x+12,y,11,"o") end
        y=y-116
        text((frozen and "FROZEN  " or (now-oldest>900 and "STALE  " or "LIVE  "))..(#view==0 and "Waiting for FRONT snapshots" or string.format("%d team(s) | oldest %.0fs old",#view,math.max(0,now-oldest)/30))..(job and " | preparing" or ""))
        text("Fill = assigned responsibility, not physical control. Orange = shared.")
        text(mode==2 and "Mex + = current policy owner. Pink diamond = differs from lane assignment." or "Solid = commander route. Dashed amber = proposal only. + = choke/position.")
        text("Terrain: initial map; physical control unknown. Threat: AI observations only.")
        local m=field.Model()
        if not m then text(field.Status())
        elseif inspection then
            local c=m.corridors[inspection.corridor]
            text(c and string.format("Corridor %d | %s | narrowest %.0f | length %.0f",c.id,classes[c.class],c.width,c.length) or "No corridor at inspected cell")
            text("Conservative clearance: "..(inspection.clearance and string.format("%.0f elmos",inspection.clearance*16/3) or "unavailable"))
        else text("Enable Inspect map, then click terrain to isolate a corridor.") end
        local s=view[1]
        if s then
            text(string.format("Team %d | r%d | seat %d/%d | %.0f elmos | %s",s.team,s.assignment,s.rank+1,s.count,s.progress,s.status))
            if s.native and #s.native>=10 and s.native[1]>=0 then
                local n=s.native
                text(string.format("Screens %d | bound %.0f | %s | decision %.0fs old",n[3],n[5],n[7]==1 and "return-home latch" or (n[10]==1 and "working" or "front active"),math.max(0,now-n[1])/30))
            else text("Commander front decision: not available yet (opening or inactive).") end
            text(s.help[1]>=0 and ("ADVISORY: assist team "..s.help[1]..(s.help[3]==1 and " (income-loss suspect)" or " (pressure)")) or ("Proposal: "..s.proposalStatus..". Other units keep existing behavior."))
        end
        gl.Color(1,1,1,1)
    end
    local function mousePress(x,y,button,blocked)
        if not show then return false end
        for _,r in ipairs(controls) do if inside(x,y,r) then if button==1 then r[5]() end;return true end end
        if inside(x,y,panel) then return true end
        if not inspect or blocked or button~=1 then return false end
        local kind,p=Spring.TraceScreenRay(x,y,true)
        local m=field.Model()
        if kind~="ground" or not p or not m then return false end
        local gx,gz=math.floor(p[1]/m.cell),math.floor(p[3]/m.cell)
        if gx<0 or gz<0 or gx>=m.gw or gz>=m.gh then return false end
        local cell=gz*m.gw+gx;local corridor=at(m.corridorRuns[cls],cell)
        inspection={corridor=corridor,clearance=at(m.clearanceRuns[cls],cell)}
        selectedCorridor=corridor and corridor>=0 and corridor or nil;invalidate();return true
    end
    return {Receive=receive,TerritoryChanged=function(id,payload)if lastTerritory[id]~=payload then lastTerritory[id]=payload;revision=revision+1 end end,Update=update,DrawWorld=drawWorld,DrawScreen=drawScreen,MousePress=mousePress,
        Mode=function()return show end,Set=function(v)show=v==true;invalidate();if not show then clearLists() end end,
        Shutdown=clearLists,Snapshot=function()return {teams=snapshot(),mode=mode,class=cls,side=side,frozen=frozen~=nil,preparing=job~=nil,ready=field.Model()~=nil and built>=0 and job==nil,terrainLists=#terrainLists,dynamicLists=#lists,status=field.Status()}end,
        TextCommand=function(cmd) if cmd=="barbstrategy" then show=not show;invalidate();if not show then clearLists() end;return true end return false end,
        At=at,GetConfig=function()return {show=show,class=cls,mode=mode,side=side}end,
        Config=function(c)if type(c)=="table" then if c.side~=nil then side=math.floor(tonumber(c.side) or -1) end;show=c.show==true;cls=math.floor(math.max(0,math.min(6,tonumber(c.class) or 0)));mode=math.floor(math.max(1,math.min(4,tonumber(c.mode) or 1)));invalidate();if not show then clearLists() end end end}
end)()
-- END STRATEGY MODULE
function widget:ViewResize(newX, newY)
	vsx, vsy = newX, newY
	initFlowUI()
	updatePlacement()
end

local theatrePending = {}
local theatreStatus = ""
local function setTheatres(value)
    theatrePending = {}
    theatreStatus = value and "Requesting lanes..." or ""
    local ids={}
    -- Keep the old all-player API for benchmark fixtures. The visible Team
    -- control requests/draws only the selected ally team, even for spectators.
    for _,id in ipairs(aiOrder) do
        if mayCommand(id) and (value~="team" or ais[id].allyTeam==selectedAlly) then ids[#ids+1]=id end
    end
    theatres.SetMode(value,ids)
    if value~=nil then seaLanes.EnableLanes() end
    local function request(id)
        theatrePending[id]={time=Spring.GetTimer(),frame=spGetGameFrame()}
        theatres.Requested(id)
        spSendSkirmishAIMessage(id,"barb|theatres|" .. id .. "|refresh")
    end
    if value=="all" or value=="team" then
        for _,id in ipairs(ids) do request(id) end
        if #ids==0 then theatreStatus="Lanes require a locally hosted BARb AI." end
    elseif type(value)=="number" and mayCommand(value) then
        request(value)
    elseif value~=nil then theatreStatus="Lanes require a locally hosted BARb AI."
    end
end

function widget:Initialize()
	 theatres.SetRefresh(function() if theatres.Mode() then setTheatres(theatres.Mode()) end end)
    field.SetAllyProvider(function() return selectedAlly end)
    -- the landmarks view reads the terrain module's grid and fingerprint, the roster's
    -- starts and factories (the card's Chosen line), and the viewer's own start (Mine)
    marks.SetField(field)
    marks.SetRosterProvider(function()
        local out = {}
        for _, id in ipairs(aiOrder) do
            local e = ais[id]
            local r = e and e.roster
            if r then out[#out + 1] = {teamId=id, allyTeam=e.allyTeam, role=r.role, side=r.side, factory=r.factory, x=r.x, z=r.z} end
        end
        return out
    end)
    marks.SetMineProvider(function()
        if not Spring.GetSpectatingState() then
            local x, _, z = Spring.GetTeamStartPosition(spGetMyTeamID())
            if x and (x > 0 or z > 0) then return x, z end
        end
        local e = selected and ais[selected]
        if e and e.roster then return e.roster.x, e.roster.z end
        return nil, nil
    end)
	self:ViewResize(Spring.GetViewGeometry())
	refreshTeams()
	hookAIMessages()
	WG.barblink = {
		SetTheatres = setTheatres,
        SetBlueprints = blueprints.SetMode,
        BlueprintSnapshot = blueprints.Snapshot,
        BlueprintStatus = blueprints.Status,
        TheatreSnapshot = theatres.Snapshot,
        TheatreStatus = function() return theatreStatus end,
        TheatreOptions = theatres.Config,
        TheatreConfig = theatres.GetConfig,
        SelectLane = theatres.Select,
        SetStrategy=function(v)strategy.Set(v)end,
        StrategySnapshot=function()return strategy.Snapshot()end,
        StrategyConfig=function(c)strategy.Config(c)end,
        -- the terrain map (field module): the same paths as the Terrain row and /barbterrain
        SetField = function(v) return field.SetMode(v) end,
        FieldStatus = field.Status,
        FieldSnapshot = field.Snapshot,
        FieldOptions = field.Config,
        FieldConfig = field.GetConfig,
        FieldLayer = field.SetLayer,
        FieldFocus = field.SetFocus,
        FieldBlueprint = field.SetBlueprint,
        FieldLegend = field.SetLegend,
        FieldSide = field.SetSide,
        -- the landmarks view (marks module): the same paths as the Landmarks rows and /barbmarks
        MarksShow = function(v) return marks.SetMode(v) end,
        MarksStatus = marks.Status,
        MarksSnapshot = marks.Snapshot,
        MarksPhase = function(p) return marks.SetPhase(p) end,
        MarksSelect = function(name) return marks.Select(name) end,
        MarksFaction = function(f) return marks.SetFaction(f) end,
        MarksLegend = function(v) marks.SetLegend(v) end,
        MousePress = function(x,y,b) return widget:MousePress(x,y,b) end,
        MouseRelease = function(x,y,b) return widget:MouseRelease(x,y,b) end,
        MouseMove = function(x,y,dx,dy,b) return widget:MouseMove(x,y,dx,dy,b) end,
        ButtonRect = function(id)
            local guide=theatres.ButtonRect(id); if guide then return guide end
            local fieldRect=field.ButtonRect(id); if fieldRect then return fieldRect end
            for _,r in ipairs(hit) do if r[5]==id then return {r[1],r[2],r[3],r[4]} end end
        end,
		IsOpen = function() return open end,
		SetOpen = setOpen,
		-- the same paths as the buttons (tools/playtest drives them)
		SetRole = function(teamId, role) return requestRole(teamId, role) end,
        SetAggression = requestAggression,
        GetAggression = function(teamId)
            local e=ais[teamId]
            return e and e.aggression, e and e.automaticAggression
        end,
		GoTo = function(teamId) return goTo(teamId) end,
		MayCommand = function(teamId) return mayCommand(teamId) end,
		-- teamId -> { role, allyTeam, name } of every listed AI that announced itself
		Roster = function()
			local out = {}
			for id, e in pairs(ais) do
				if e.roster then out[id] = { role = e.roster.role, allyTeam = e.allyTeam, name = e.name } end
			end
			return out
		end,
		LastReply = function(teamId) local e = ais[teamId]; return e and e.lastReply end,
		-- D-300 diagnostics for tools/playtest: the event log size and the last
		-- state file sequence read for a team (nil before the first read)
		EventCount = function() return #events end,
		StateSeq = function(teamId) return stateFiles.Seq and stateFiles.Seq(teamId) end,
	}
end

function widget:Shutdown()
    blueprints.SetMode(nil)
    strategy.Shutdown()
    field.Shutdown()
    marks.Shutdown()
	unhookAIMessages()
	WG.barblink = nil
	if WG.guishader then
		WG.guishader.RemoveRect("barblink")
		WG.guishader.RemoveRect("barblinklauncher")
	end
end

function widget:GetConfigData()
	return { open = open, offX = offX / mathMax(scale, 0.01), offY = offY / mathMax(scale, 0.01),  theatres=theatres.GetConfig(), field=field.GetConfig(), marks=marks.GetConfig(), seaLanes=seaLanes.GetConfig(), territory=territory.GetConfig(), strategy=strategy.GetConfig() }
end

function widget:SetConfigData(data)
    if data then strategy.Config(data.strategy) end
	if type(data) ~= "table" then return end
	theatres.Config(data.theatres)
	field.Config(data.field)
	marks.Config(data.marks)
	seaLanes.Config(data.seaLanes)
	territory.Config(data.territory)
	if data.open ~= nil then
		firstRun = false   -- a config of this version: its open state stands
		open = data.open == true
	end
	offX = (tonumber(data.offX) or 0) * scale
	offY = (tonumber(data.offY) or 0) * scale
end

function widget:Update()
    if stateFiles.Poll then stateFiles.Poll() end
    field.Update(strategy.Mode())
    strategy.Update()
    marks.Update()
    local waiting=false
    for id,p in pairs(theatrePending) do
        local result=theatres.Snapshot(id)
        if result and result.frame>=p.frame then theatrePending[id]=nil
        elseif Spring.DiffTimers(Spring.GetTimer(),p.time)>5 then
            theatrePending[id]=nil
            theatreStatus="No lane reply: this BAR build does not pass AI messages to widgets (KI-617)."
            addEvent("Player " .. id .. ": " .. theatreStatus,"warn")
            spEcho("[BARb link] " .. theatreStatus)
        else waiting=true end
    end
    if not waiting and next(theatrePending)==nil and theatreStatus=="Requesting lanes..." then theatreStatus="" end
end

function widget:GameFrame(n)
    if n % 600 == 0 then blueprints.Tick() end
	if n < 90 then return end
	if n % 900 == 0 and theatres.Mode() and theatres.Live() then setTheatres(theatres.Mode()) end
	if lastQueryFrame < 0 or n % QUERY_INTERVAL_FRAMES == 0 then
		local missing = false
		for _, id in ipairs(aiOrder) do
			if not (ais[id] and ais[id].roster) then missing = true end
		end
		if missing then queryAll() end
	end
end

-- ---------------------------------------------------------------- blueprints
-- Keep rendering state inside a closure: Lua 5.1 limits top-level locals. Parsing,
-- ground samples and GL list creation happen only on a CHANGED complete snapshot.
-- No per-frame unit/terrain scans, no orders to units and no synced map drawing.
do
    local mode, wanted, data = nil, {}, {}
    local colours = {zone={0.18,0.55,0.9,0.5}, corridor={0.45,0.8,1,0.6},
        p={0.3,0.8,1,0.9}, h={0.35,0.55,0.75,0.6}, c={1,0.85,0.35,0.95},
        s={0.4,1,0.8,0.95}, b={0.3,0.55,0.7,0.35}, t={1,0.65,0.3,0.8},
        resource={1,0.55,0.25,0.9}}
    local dirs = {[0]={0,1}, {1,0}, {0,-1}, {-1,0}}
    local function dispose(d) if d and d.list then gl.DeleteList(d.list); d.list=nil end end
    local function finite(v) return v and v==v and v~=math.huge and v~=-math.huge end
    local function compile(d)
        dispose(d)
        -- A display list is owned by exactly one committed team snapshot.
        -- Water plans must be drawn at the surface, not hidden on the seabed.
        d.list=gl.CreateList(function()
            for _,e in ipairs(d.entries) do
                local c=colours[e.kind] or colours[e.state:sub(1,1)] or colours.p
                if e.state:sub(2,2)=='t' and e.state:sub(1,1)~='b' then c=colours.t end
                local x1,z1,x2,z2=e.x-e.w/2,e.z-e.d/2,e.x+e.w/2,e.z+e.d/2
                local y=math.max(0,Spring.GetGroundHeight(e.x,e.z),Spring.GetGroundHeight(x1,z1),
                    Spring.GetGroundHeight(x2,z2),Spring.GetGroundHeight(x1,z2),Spring.GetGroundHeight(x2,z1))+5
                gl.Color(c[1],c[2],c[3],c[4]); gl.LineWidth(e.kind=='slot' and 1.5 or 1)
                gl.BeginEnd(GL.LINES,function()
                    local function line(ax,az,bx,bz) gl.Vertex(ax,y,az); gl.Vertex(bx,y,bz) end
                    line(x1,z1,x2,z1); line(x2,z1,x2,z2); line(x2,z2,x1,z2); line(x1,z2,x1,z1)
                    if e.kind=='resource' then line(x1,z1,x2,z2); line(x1,z2,x2,z1)
                    elseif e.kind=='corridor' then
                        -- Corridors export axis-aligned bounds, not a facing.
                        if e.w>e.d then line(x1,e.z,x2,e.z) else line(e.x,z1,e.x,z2) end
                    elseif e.kind=='slot' then
                        local r=math.min(8,e.w/4,e.d/4)
                        line(e.x-r,e.z,e.x+r,e.z); line(e.x,e.z-r,e.x,e.z+r)
                        local ud=UnitDefNames and UnitDefNames[e.name]
                        if ud and ud.isFactory then
                            local dir=dirs[e.facing] or dirs[0]
                            local length=math.min(e.w,e.d)*0.4
                            local tx,tz=e.x+dir[1]*length,e.z+dir[2]*length
                            line(e.x,e.z,tx,tz)
                            line(tx,tz,tx-dir[1]*12+dir[2]*8,tz-dir[2]*12-dir[1]*8)
                            line(tx,tz,tx-dir[1]*12-dir[2]*8,tz-dir[2]*12+dir[1]*8)
                        end
                    else
                        -- Survey ticks give large reserved envelopes a blueprint outline.
                        for x=x1+64,x2-1,64 do line(x,z1,x,z1+8); line(x,z2,x,z2-8) end
                        for z=z1+64,z2-1,64 do line(x1,z,x1+8,z); line(x2,z,x2-8,z) end
                    end
                end)
            end
        end)
    end
    local function commit(id,payload)
        local d=data[id] or {}; data[id]=d; d.parts=nil
        if d.text==payload then return end
        local entries,slots,built,zones,resources={},0,0,0,0
        for item in payload:gmatch('[^;]+') do
            local f=split(item,':')
            local x,z,w,h=tonumber(f[3]),tonumber(f[4]),tonumber(f[6]),tonumber(f[7])
            local kind=f[1]
            if (kind=='slot' or kind=='zone' or kind=='corridor' or kind=='resource') and
                finite(x) and finite(z) and finite(w) and finite(h) and w>0 and h>0 and
                x-w/2>=0 and z-h/2>=0 and x+w/2<=Game.mapSizeX and z+h/2<=Game.mapSizeZ then
                entries[#entries+1]={kind=kind,name=f[2],x=x,z=z,w=w,d=h,facing=tonumber(f[5]) or 0,state=f[8] or 'p'}
                if kind=='slot' then slots=slots+1; if (f[8] or ''):sub(1,1)=='b' then built=built+1 end
                elseif kind=='resource' then resources=resources+1 else zones=zones+1 end
            end
        end
        d.text=payload; d.entries=entries; d.slots=slots; d.built=built; d.zones=zones; d.resources=resources
        d.frame=spGetGameFrame()
        d.label=nil
        for _,e in ipairs(entries) do if e.kind=='slot' then
            d.label={e.x,math.max(0,Spring.GetGroundHeight(e.x,e.z))+65,e.z}; break
        end end
        compile(d)
    end
    function blueprints.Receive(id,idx,total,payload)
        if not wanted[id] or not mayCommand(id) or not isPermittedTeam(id) then return end
        -- CallUI sends a whole snapshot synchronously, ordered on the AI thread.
        -- Ignore gaps/duplicates, cap memory, and keep the old list until complete.
        if total==0 and idx==0 then commit(id,''); return end
        if total<1 or total>1024 or total~=math.floor(total) or idx~=math.floor(idx) or idx<1 or idx>total or #payload>3000 then return end
        local d=data[id] or {}; data[id]=d
        if idx==1 then d.parts={}; d.total=total; d.next=1 end
        if not d.parts or d.total~=total or d.next~=idx then d.parts=nil; return end
        d.parts[idx]=payload; d.next=idx+1
        if idx==total then commit(id,table.concat(d.parts)) end
    end
    -- D-300: the state file carries the whole snapshot ("none" = no plan); the
    -- reader only calls this when the stored value changed.
    function blueprints.Whole(id,payload)
        if not wanted[id] or not mayCommand(id) or not isPermittedTeam(id) then return end
        commit(id,payload=='none' and '' or payload)
    end
    function blueprints.Wanted(id) return wanted[id]==true end
    function blueprints.SetMode(value)
        if value~=nil and value~='team' and type(value)~='number' then return end
        mode=value; refreshTeams()
        if type(value)=='number' and ais[value] and mayCommand(value) then
            selected=value; selectedAlly=ais[value].allyTeam
        end
        local nextWanted={}
        for _,id in ipairs(aiOrder) do
            if mayCommand(id) and isPermittedTeam(id) and (id==value or (value=='team' and ais[id].allyTeam==selectedAlly)) then nextWanted[id]=true end
        end
        for id in pairs(wanted) do
            if not nextWanted[id] then
                spSendSkirmishAIMessage(id,'barb|layout|'..id..'|off'); dispose(data[id]); data[id]=nil
            end
        end
        local previous=wanted; wanted=nextWanted -- receive can re-enter while sending
        for id in pairs(wanted) do
            if not previous[id] then spSendSkirmishAIMessage(id,'barb|layout|'..id..'|on') end
        end
    end
    function blueprints.Tick()
        blueprints.SetMode(mode) -- prune permission loss, dead teams, changed team selection
        for id in pairs(wanted) do spSendSkirmishAIMessage(id,'barb|layout|'..id..'|renew') end
    end
    function blueprints.Mode() return mode end
    function blueprints.Snapshot(id)
        local d=data[id]
        return {visible=wanted[id] and true or false,slots=d and d.slots or 0,built=d and d.built or 0,
            zones=d and d.zones or 0,resources=d and d.resources or 0,x=d and d.label and d.label[1],z=d and d.label and d.label[3],frame=d and d.frame,ready=d and d.entries~=nil or false}
    end
    function blueprints.Status()
        if mode==nil then return 'Blueprints hidden' end
        local n,slots,built,pending=0,0,0,0
        for id in pairs(wanted) do
            n=n+1; local d=data[id]
            if d and d.entries then slots=slots+d.slots; built=built+d.built else pending=pending+1 end
        end
        if n==0 then return 'No permitted locally hosted AI selected' end
        return string.format('%d AI | %d slots | %d built%s',n,slots,built,pending>0 and ' | awaiting plans' or '')
    end
    function blueprints.Draw()
        if mode==nil or Spring.IsGUIHidden() then return end
        gl.DepthTest(false)
        for id,d in pairs(data) do
            if wanted[id] and isPermittedTeam(id) and mayCommand(id) then
                if d.list then gl.CallList(d.list) end
                -- One cached label anchor per team; no entry traversal or terrain callback per draw.
                if d.label then
                    local a=ais[id]; local c=a and a.color or colours.p
                    gl.Color(c[1],c[2],c[3],1); gl.PushMatrix()
                    gl.Translate(d.label[1],d.label[2],d.label[3]); gl.Billboard()
                    gl.Text((a and a.name or ('AI '..id))..' / '..(a and a.roster and a.roster.role or 'layout'),0,0,14,'oc')
                    gl.PopMatrix()
                end
            end
        end
        gl.LineWidth(1); gl.Color(1,1,1,1); gl.DepthTest(true)
    end
end
function widget:DrawWorld() blueprints.Draw(); field.DrawWorld(); if not field.Mode() then marks.DrawWorld() end; if not strategy.Mode() then seaLanes.DrawWorld(); territory.DrawWorld() end; strategy.DrawWorld() end
function widget:DrawInMiniMap(sx, sy) field.DrawMiniMap(sx, sy); marks.DrawMiniMap(sx, sy); seaLanes.DrawMiniMap(sx, sy); territory.DrawMiniMap(sx, sy) end

-- ---------------------------------------------------------------- messages

local function onAIMessage(aiTeam, dataStr)
	local ack=theatres.Receive(aiTeam,dataStr); if ack then return ack end
	if type(dataStr) ~= "string" or string.sub(dataStr, 1, 5) ~= "barb|" then return end
	local p = split(dataStr, "|")
	local topic, sender, senderAlly = p[2], tonumber(p[3]), tonumber(p[4])
	if sender and not isPermittedTeam(sender) then return end   -- CR-008
	if sender and not ais[sender] then refreshTeams() end
	local e = sender and ais[sender]
	if e and senderAlly then e.allyTeam = senderAlly end
	local rest = table.concat(p, " ", 5)
	if topic == "roster" then
		local r = parseRoster(table.concat(p, "|", 6))
		if r and ais[r.teamId] then
			local target = ais[r.teamId]
			firstAnnounceFrame = firstAnnounceFrame or spGetGameFrame()
			if not target.roster then
				addEvent(string.format("Team %d announced: %s, %s%s", r.teamId, r.role, r.side, r.leader and ", lead" or ""), "info")
			elseif target.roster.role ~= r.role then
				addEvent(string.format("Team %d role changed: %s to %s", r.teamId, target.roster.role, r.role), "ok")
			end
			target.roster = r
			if target.lastReply and string.sub(target.lastReply, 1, 2) == "?:" then target.lastReply = nil; target.replyKind = nil end   -- "not ready" is answered
		end
    elseif topic == "aggression" and e then
        local delta, automatic=tonumber(p[5]),tonumber(p[6])
        if delta and delta>=-1 and delta<=1 and automatic and automatic>=-1 and automatic<=1 then
            e.aggression, e.automaticAggression=delta,automatic
        end
	elseif topic == "role" and e then
		local role, status = p[5] or "?", p[6] or ""
		e.lastReply = string.format("%s: %s", role, status)
		e.replyKind = (status == "ok") and "ok" or ((string.sub(status, 1, 7) == "already") and "info" or "warn")
		if status == "ok" and e.roster then e.roster.role = role end
		addEvent(string.format("Team %d replied: %s (%s)", sender, status, role), e.replyKind)
	elseif topic == "orphan" and e then
		addEvent(string.format("Team %d orphan rescue: %s", sender, rest), "warn")
	elseif topic == "donation" and e then
		addEvent(string.format("Team %d gave %s to team %s (%s of %s)", sender, p[5] or "?", p[6] or "?", p[7] or "?", p[8] or "?"), "ok")
	elseif topic == "ferry" and e then
		addEvent(string.format("Team %d ferry: %s", sender, rest), (p[5] == "done" or p[5] == "gave") and "ok" or ((p[5] == "fallback") and "warn" or "info"))
	elseif topic == "spam" and e then
		local what = p[5] or "?"
		if what == "on" then addEvent(string.format("Team %d spam on (+%s metal, +%s energy)", sender, p[6] or "?", p[7] or "?"), "ok")
		elseif what == "off" then addEvent(string.format("Team %d spam off (+%s metal, +%s energy)", sender, p[6] or "?", p[7] or "?"), "warn")
		else addEvent(string.format("Team %d spam %s (%s, %s)", sender, what, p[6] or "?", p[7] or "?"), "info") end
	elseif topic == "seaassist" and e then
		addEvent(string.format("Team %d sea assist: %s", sender, rest), "info")
	elseif topic == "sealanes" and sender == aiTeam then
		seaLanes.Receive(sender, table.concat(p, "|", 5))
	elseif topic == "strategy" and sender == aiTeam then
        strategy.Receive(sender, table.concat(p, "|", 5))
	elseif topic == "frontlanes" and sender == aiTeam then
		seaLanes.Receive(sender, table.concat(p, "|", 5), true)
	elseif topic == "territory" and sender == aiTeam then
		territory.Receive(sender, table.concat(p, "|", 5))
        strategy.TerritoryChanged(sender, table.concat(p, "|", 5))
	elseif topic == "searepair" and sender == aiTeam then
		seaLanes.ReceiveRepair(sender, table.concat(p, "|", 5))
	elseif topic == "layout" and sender == aiTeam then
		blueprints.Receive(sender, tonumber(p[5]) or 0, tonumber(p[6]) or 0, table.concat(p, "|", 7))
	end
end

-- D-300: the AI state files. Each locally hosted BARb rewrites
-- LuaUI/Config/BARb/state/team<N>.txt a short while after its widget state
-- changes (src/circuit/util/WidgetState.h):
--   barbstate|<format>|<team>|<allyTeam>|<seq>|<frame>
--   s|<key>|<barb line>      latest value per key (roster, aggression, layout)
--   e|<id>|<barb line>       the latest 64 events, ids increasing
--   end|<seq>                trailer: a torn or half-written file is skipped
-- Cost: one VFS read per hosted AI per POLL_SECONDS of wall time; the header
-- sequence skips parsing an unchanged file, and only changed values or new
-- event ids reach onAIMessage. No per-frame work.
do
    local FORMAT, POLL_SECONDS = 1, 1.0
    local files = {}           -- teamId -> { seq, event, states = {key -> line}, layoutShown }
    local lastPoll = nil
    local readError = nil
    local function path(id) return "LuaUI/Config/BARb/state/team" .. id .. ".txt" end
    local function load(id)
        if not (VFS and VFS.LoadFile) then return nil, "VFS.LoadFile is unavailable" end
        local ok, text = pcall(VFS.LoadFile, path(id), VFS.RAW)
        if not ok then return nil, tostring(text) end
        return text
    end
    local function apply(id, text)
        local f = files[id] or { seq = -1, event = 0, states = {} }
        files[id] = f
        local format, team, _, seq, frame = text:match("^barbstate|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)")
        format, team, seq, frame = tonumber(format), tonumber(team), tonumber(seq), tonumber(frame)
        if format ~= FORMAT or team ~= id or not seq then return end
        if seq == f.seq then return end
        -- A file from a longer earlier game: the AI deletes it on start, so this
        -- is only a leftover when the AI is not running here.
        if frame and frame > spGetGameFrame() + 900 then return end
        if not text:find("\nend|" .. seq .. "\n", 1, true) then return end   -- torn: next poll
        if seq < f.seq then f.event = 0; f.states = {}; f.layoutShown = nil end   -- the AI restarted
        f.seq = seq
        local seen = {}
        for line in text:gmatch("[^\n]+") do
            local kind = line:sub(1, 2)
            if kind == "s|" then
                local key, value = line:match("^s|([^|]+)|(.*)$")
                if key then
                    seen[key] = true
                    if key == "layout" then
                        local payload = value:match("^barb|layout|%d+|%d+|(.*)$")
                        if payload and blueprints.Wanted(id) and (f.states.layout ~= value or not f.layoutShown) then
                            blueprints.Whole(id, payload); f.layoutShown = true
                        end
                        f.states.layout = value
                    elseif f.states[key] ~= value then
                        f.states[key] = value
                        onAIMessage(id, value)
                    end
                end
            elseif kind == "e|" then
                local eid, value = line:match("^e|(%d+)|(.*)$")
                eid = tonumber(eid)
                if eid and eid > f.event then
                    f.event = eid
                    onAIMessage(id, value)
                end
            end
        end
        for key in pairs(f.states) do if not seen[key] then f.states[key] = nil end end
        if not seen.layout then f.layoutShown = nil end
    end
    function stateFiles.Poll()
        local now = Spring.GetTimer()
        if lastPoll and Spring.DiffTimers(now, lastPoll) < POLL_SECONDS then return end
        lastPoll = now
        for _, id in ipairs(aiOrder) do
            if hostedHere(id) and isPermittedTeam(id) then
                -- A newly wanted overlay must show the stored plan even when the
                -- file itself has not changed since the last read.
                local f = files[id]
                if f and not blueprints.Wanted(id) then f.layoutShown = nil end
                if f and blueprints.Wanted(id) and not f.layoutShown and f.states.layout then
                    local payload = f.states.layout:match("^barb|layout|%d+|%d+|(.*)$")
                    if payload then blueprints.Whole(id, payload); f.layoutShown = true end
                end
                local text, err = load(id)
                if err and readError ~= err then
                    readError = err
                    spEcho("[BARb link] cannot read AI state file " .. path(id) .. ": " .. err)
                elseif type(text) == "string" and #text > 0 then
                    local ok, perr = pcall(apply, id, text)
                    if not ok then spEcho("[BARb link] state file error team " .. id .. ": " .. tostring(perr)) end
                end
            end
        end
    end
    function stateFiles.Seq(id) return files[id] and files[id].seq or nil end
end

-- BAR's widget handler (luaui/barwidgets.lua) does not forward the engine's
-- RecvSkirmishAIMessage callin to widgets: it is not in its callInLists, and
-- RegisterGlobal refuses engine callin names. So the widget installs the LuaUI
-- global itself (getfenv(0) is LuaUI's global table; Script.UpdateCallIn makes
-- the engine call it), chaining to any handler already there, and restores it
-- on shutdown. Should the handler ever forward the callin, widget:Recv... is
-- used instead and the global is left alone.
local AI_CALLIN = "RecvSkirmishAIMessage"
local hooked, previousGlobal = false, nil

function widget:RecvSkirmishAIMessage(aiTeam, dataStr)
	if hooked then return end
	return onAIMessage(aiTeam, dataStr)
end

hookAIMessages = function()
	local G = getfenv and getfenv(0)
	if type(G) ~= "table" or not (Script and Script.UpdateCallIn) then return end
	previousGlobal = rawget(G, AI_CALLIN)
	if previousGlobal ~= nil then return end   -- the handler (or another widget) delivers it: widget:Recv... gets it
	rawset(G, AI_CALLIN, function(aiTeam, dataStr)
		local ok, err = pcall(onAIMessage, aiTeam, dataStr)
		if not ok then spEcho("[BARb link] message error: " .. tostring(err)) end
		return ok and err or nil
	end)
	Script.UpdateCallIn(AI_CALLIN)
	hooked = true
end

unhookAIMessages = function()
	if not hooked then return end
	local G = getfenv and getfenv(0)
	if type(G) == "table" then
		rawset(G, AI_CALLIN, previousGlobal)
		Script.UpdateCallIn(AI_CALLIN)
	end
	hooked = false
end

-- ---------------------------------------------------------------- drawing primitives

local function px(v) return mathFloor(v * scale + 0.5) end
local function inside(x, y, x1, y1, x2, y2) return x >= x1 and x <= x2 and y >= y1 and y <= y2 end

local function roundRect(x1, y1, x2, y2, cs, color)
	if hasFlowUI then
		RectRound(x1, y1, x2, y2, cs, 1, 1, 1, 1, color, color)
	else
		glColor(color); glRect(x1, y1, x2, y2)
	end
end

local function outlineRect(x1, y1, x2, y2, cs, color)
	if hasFlowUI then
		RectRoundOutline(x1, y1, x2, y2, cs, mathMax(1, px(1)), 1, 1, 1, 1, color, color)
	else
		glColor(color)
		glRect(x1, y1, x2, y1 + 1); glRect(x1, y2 - 1, x2, y2); glRect(x1, y1, x1 + 1, y2); glRect(x2 - 1, y1, x2, y2)
	end
end

local function text(f, s, x, y, size, opts, color)
	if f then
		f:Begin()
		f:SetTextColor(color[1], color[2], color[3], color[4] or 1)
		f:SetOutlineColor(0, 0, 0, 0.6)
		f:Print(s, x, y, size, opts or "o")
		f:End()
	else
		glColor(color); glText(s, x, y, size, opts or "o")
	end
end

local function textWidth(f, s, size)
	if f then return f:GetTextWidth(s) * size end
	return gl.GetTextWidth(s) * size
end

local function fitText(f, s, size, maxW)
	local out = s
	while textWidth(f, out, size) > maxW and #out > 3 do out = string.sub(out, 1, #out - 2) .. "." end
	return out
end

local iconOk = {}
local function icon(path, x1, y1, x2, y2, color)
	if not path then return false end
	if iconOk[path] == nil then iconOk[path] = VFS.FileExists(path) == true end
	if not iconOk[path] then return false end
	glColor(color or { 1, 1, 1, 1 })
	glTexture(path)
	glTexRect(x1, y1, x2, y2)
	glTexture(false)
	return true
end

local function stateLayer(x1, y1, x2, y2, cs, id)
	if pressedId == id then roundRect(x1, y1, x2, y2, cs, C.pressLayer)
	elseif hoverId == id then roundRect(x1, y1, x2, y2, cs, C.hoverLayer) end
end

local function register(x1, y1, x2, y2, id, action, tooltip)
	hit[#hit + 1] = { x1, y1, x2, y2, id, action, tooltip }
end

local function divider(x1, x2, y)
	glColor(C.outline)
	glRect(x1, y, x2, y + mathMax(1, px(1)))
end

-- a square icon button; `on` shows it pressed in (a toggle)
local function iconButton(x1, y1, size, path, id, action, tooltip, on, fallback)
	local x2, y2 = x1 + size, y1 + size
	if on then roundRect(x1, y1, x2, y2, px(4), C.primaryContainer) end
	stateLayer(x1, y1, x2, y2, px(4), id)
	local m = px(4)
	if not icon(path, x1 + m, y1 + m, x2 - m, y2 - m, on and C.primary or C.onSurface) then
		text(font2, fallback or "?", (x1 + x2) / 2, y1 + size * 0.5 - px(3.5), px(10), "oc", C.onSurface)
	end
	register(x1, y1, x2, y2, id, action, tooltip)
	return x1 - size - px(2)
end

-- a button with a leading icon and a label
local function labelButton(x1, y1, x2, y2, path, label, id, action, tooltip, active, enabled)
	local cs = px(4)
	if active then roundRect(x1, y1, x2, y2, cs, C.primaryContainer)
	else outlineRect(x1, y1, x2, y2, cs, C.outlineStrong) end
	if enabled ~= false then stateLayer(x1, y1, x2, y2, cs, id) end
	local h = y2 - y1
	local isz = h - px(6)
	local col = (enabled == false) and C.onSurfaceVariant or (active and C.primary or C.onSurface)
	local tx = x1 + px(5)
	if icon(path, tx, y1 + px(3), tx + isz, y1 + px(3) + isz, col) then tx = tx + isz + px(4) end
	text(font2, fitText(font2, label, px(9), x2 - tx - px(3)), tx, y1 + h * 0.5 - px(3.4), px(9), "o", col)
	if enabled ~= false then register(x1, y1, x2, y2, id, action, tooltip) end
end

-- ---------------------------------------------------------------- draw

local function drawLauncher()
	local x1, y1, x2, y2 = launcher.x1, launcher.y1, launcher.x2, launcher.y2
	if hasFlowUI then
		UiElement(x1, y1, x2, y2, 1, 1, 1, 1, 1, 1, 1, 1, WG.FlowUI.clampedOpacity)
	else
		roundRect(x1, y1, x2, y2, px(4), C.surface)
	end
	if WG.guishader then WG.guishader.InsertRect(x1, y1, x2, y2, "barblinklauncher", widget) end
	if open then roundRect(x1 + px(2), y1 + px(2), x2 - px(2), y2 - px(2), px(3), C.primaryContainer) end
	stateLayer(x1, y1, x2, y2, px(4), "launcher")
	local m = px(5)
	if not icon(ICON.ai, x1 + m, y1 + m, x2 - m, y2 - m, open and C.primary or C.onSurface) then
		text(font2, "AI", (x1 + x2) / 2, y1 + (y2 - y1) * 0.5 - px(4), px(10), "oc", C.onSurface)
	end
	register(x1, y1, x2, y2, "launcher", function() playClick(); setOpen(not open) end,
		open and "Close the BARb AI window (Ctrl+Alt+B)" or "Allied BARb AIs: roster, roles, events (Ctrl+Alt+B)")
end

local function drawWindow()
	local x1, y1, x2, y2 = win.x1, win.y1, win.x2, win.y2
	if hasFlowUI then
		UiElement(x1, y1, x2, y2, 1, 1, 1, 1, 1, 1, 1, 1, WG.FlowUI.clampedOpacity)
	else
		roundRect(x1, y1, x2, y2, px(6), C.surface)
	end
	if WG.guishader then WG.guishader.InsertRect(x1, y1, x2, y2, "barblink", widget) end
	local pad = px(7)
	local left, right = x1 + pad, x2 - pad
	local w = right - left

	-- header: title (drag handle), actions on the right
	local hh = px(24)
	local hy1 = y2 - hh
	roundRect(x1 + px(1), hy1, x2 - px(1), y2 - px(1), px(5), C.surfaceHigh)
	icon(ICON.ai, left, hy1 + px(5), left + px(14), hy1 + px(19), C.primary)
	text(font2, "BARb AIs", left + px(18), hy1 + hh * 0.5 - px(4), px(11), "o", C.onSurface)
	text(font, string.format("%d allied", #aiOrder), left + px(18) + textWidth(font2, "BARb AIs", px(11)) + px(6), hy1 + hh * 0.5 - px(3.5), px(8.5), "o", C.onSurfaceVariant)
	register(x1, hy1, x2, y2, "header", function() end, "Drag to move")
	local bs = px(20)
	local bx = right - bs
	local by = hy1 + (hh - bs) / 2
	bx = iconButton(bx, by, bs, ICON.close, "close", function() playClick(); setOpen(false) end, "Close (Escape)", false, "x")
	bx = iconButton(bx, by, bs, ICON.overlay, "overlay", function() playClick(); if blueprints.Mode() then blueprints.SetMode(nil) else blueprints.SetMode("team") end end,
        "Toggle selected team's blueprints (/barblayout)", blueprints.Mode()~=nil, "o")
	bx = iconButton(bx, by, bs, ICON.queryall, "queryall", function() playClick(); queryAll() end, "Ask every AI for its details", false, "*")
    local cy = hy1 - px(5)
    local buttonsLeft=left+px(52)
    local bw=(w-px(60))/3
    text(font2,"Lanes",left,cy-px(14),px(9),"o",C.onSurfaceVariant)
    labelButton(buttonsLeft,cy-px(22),buttonsLeft+bw,cy,ICON.overlay,"Player","lanesPlayer",function()
        playClick(); if theatres.Mode()==selected then setTheatres(nil) else setTheatres(selected) end
    end,"Toggle lanes and strategic sites for the selected player",theatres.Mode()~=nil and theatres.Mode()==selected)
    labelButton(buttonsLeft+bw+px(4),cy-px(22),buttonsLeft+2*bw+px(4),cy,ICON.team,"Team","lanesTeam",function()
        playClick(); if theatres.Mode()=="team" then setTheatres(nil) else setTheatres("team") end
    end,"Lanes and strategic sites for locally hosted AIs on the selected ally team",theatres.Mode()=="team")
    labelButton(buttonsLeft+2*bw+px(8),cy-px(22),right,cy,ICON.close,"Hide","lanesOff",function()
        playClick(); setTheatres(nil)
    end,"Hide lanes and strategic sites immediately",theatres.Mode()==nil)
    cy=cy-px(28)
    if theatreStatus~="" then
        text(font,fitText(font,theatreStatus,px(8),w),left,cy-px(9),px(8),"o",C.warn)
        register(left,cy-px(15),right,cy,"laneStatus",function() end,theatreStatus)
    end
    cy=cy-px(16)

    text(font2,"Layouts",left,cy-px(14),px(9),"o",C.onSurfaceVariant)
    labelButton(buttonsLeft,cy-px(22),buttonsLeft+bw,cy,ICON.overlay,"Player","plansPlayer",function()
        playClick(); if blueprints.Mode()==selected then blueprints.SetMode(nil) else blueprints.SetMode(selected) end
    end,"Follow selected AI's live blueprint",type(blueprints.Mode())=="number")
    labelButton(buttonsLeft+bw+px(4),cy-px(22),buttonsLeft+2*bw+px(4),cy,ICON.team,"Team","plansTeam",function()
        playClick(); if blueprints.Mode()=="team" then blueprints.SetMode(nil) else blueprints.SetMode("team") end
    end,"Blueprints of every locally hosted AI on the selected ally team",blueprints.Mode()=="team")
    labelButton(buttonsLeft+2*bw+px(8),cy-px(22),right,cy,ICON.close,"Hide","plansOff",function()
        playClick(); blueprints.SetMode(nil)
    end,"Hide blueprints and stop requesting snapshots",blueprints.Mode()==nil)
    cy=cy-px(25)
    text(font,fitText(font,blueprints.Status(),px(8),w),left,cy-px(9),px(8),"o",C.onSurfaceVariant)
    cy=cy-px(17)
    register(left,cy,right,cy+px(15),"planLegend",function() end,
        "Blueprint: cyan=planned, grey=held/built, yellow=claimed, mint=under construction. Orange X=protected metal/geo. Arrows=factory exit direction. Updates within 4 game seconds.")
    cy=cy-px(16)

    -- D-323 / D-326: the terrain map, read from the field file the AI wrote once
    text(font2,"Terrain",left,cy-px(14),px(9),"o",C.onSurfaceVariant)
    labelButton(buttonsLeft,cy-px(22),buttonsLeft+bw,cy,ICON.overlay,"Show","fieldShow",function()
        playClick(); field.SetMode(true)
    end,"Show the terrain map: ground classes, land masses, seas, ponds, crossings, cliffs, summits (/barbterrain)",field.Mode())
    labelButton(buttonsLeft+bw+px(4),cy-px(22),buttonsLeft+2*bw+px(4),cy,ICON.team,"Legend","fieldLegend",function()
        playClick(); field.SetLegend(not field.Legend()); if field.Legend() and not field.Mode() then field.SetMode(true) end
    end,"Open or close the legend panel: layers, terrain shown / dim / off, detail, focus",field.Legend())
    labelButton(buttonsLeft+2*bw+px(8),cy-px(22),right,cy,ICON.close,"Hide","fieldOff",function()
        playClick(); field.SetMode(false)
    end,"Hide the terrain map and restore the view",not field.Mode())
    cy=cy-px(25)
    text(font,fitText(font,field.Status(),px(8),w),left,cy-px(9),px(8),"o",C.onSurfaceVariant)
    register(left,cy-px(12),right,cy,"fieldStatus",function() end,field.Status())
    cy=cy-px(14)

    text(font2,"Strategy",left,cy-px(14),px(9),"o",C.onSurfaceVariant)
    labelButton(buttonsLeft,cy-px(24),right,cy,ICON.overlay,"Inspect lanes / territory","strategyShow",function()
        playClick();strategy.Set(not strategy.Mode())
    end,"Inspect corridor assignments, commander decisions and advisory assistance (/barbstrategy)",strategy.Mode())
    cy=cy-px(30)
    -- All map-analysis views use the same persisted widget configuration.
    text(font,"Views",left,cy-px(12),px(8.5),"o",C.onSurfaceVariant)
    for i,view in ipairs({"terrain","approaches","positions"}) do
        local vx=buttonsLeft+(i-1)*(bw+px(4))
        labelButton(vx,cy-px(22),vx+bw,cy,nil,view,"analysis_"..view,function()
            playClick(); marks.SetMode(false)
            local cfg=field.GetConfig();cfg.view=view;cfg.preset="Custom";field.Config(cfg);field.SetMode(true)
        end,"Configure "..view.." in Map Analysis",field.Mode() and field.View()==view)
    end
    cy=cy-px(30)
	-- ally-team chips (only when more than one ally team has an AI)
	if #allyTeams > 1 then
		local chH = px(18)
		local cx = left
		for _, at in ipairs(allyTeams) do
			local label = "Team " .. (at + 1)
			local cw = textWidth(font2, label, px(9)) + px(28)
			labelButton(cx, cy - chH, cx + cw, cy, ICON.team, label, "ally" .. at, function()
				playClick(); selectedAlly = at; selected = aisOfAlly(at)[1]; listScroll = 0
                if type(theatres.Mode())=="number" then setTheatres(selected)
                elseif theatres.Mode()=="team" then setTheatres("team") end
                if type(blueprints.Mode())=="number" then blueprints.SetMode(selected)
                elseif blueprints.Mode()=="team" then blueprints.SetMode("team") end
			end, string.format("Show team %d's AIs (%d)", at + 1, #aisOfAlly(at)), at == selectedAlly)
			cx = cx + cw + px(4)
			if cx > right - px(40) then break end
		end
		cy = cy - chH - px(5)
	end

	-- the AI list
	local ids = aisOfAlly(selectedAlly)
	local rowH = px(19)
	local maxRows = mathMin(5, mathMax(1, #ids))
	local listH = maxRows * rowH
	listScroll = mathMax(0, mathMin(listScroll, mathMax(0, #ids - maxRows)))
	if #ids == 0 then
		text(font, #aiOrder == 0 and "No allied BARb AI in this game." or "No AI on this team.", left, cy - px(12), px(9.5), "o", C.onSurfaceVariant)
		cy = cy - px(18)
	else
		roundRect(left, cy - listH, right, cy, px(4), C.surfaceHigh)
		for i = 1, maxRows do
			local id = ids[i + listScroll]
			if not id then break end
			local a = ais[id]
			local ry2 = cy - (i - 1) * rowH
			local ry1 = ry2 - rowH
			local sel = (id == selected)
			if sel then roundRect(left + px(1), ry1 + px(1), right - px(1), ry2 - px(1), px(3), C.primaryContainer) end
			stateLayer(left + px(1), ry1 + px(1), right - px(1), ry2 - px(1), px(3), "row" .. id)
			roundRect(left + px(6), ry1 + rowH / 2 - px(4), left + px(14), ry1 + rowH / 2 + px(4), px(4), a.color)
			local role = a.roster and a.roster.role or nil
			local rx = right - px(4)
			if role then
				local rw = textWidth(font, role, px(8.5))
				text(font, role, rx, ry1 + rowH * 0.5 - px(3.2), px(8.5), "or", sel and C.primary or C.onSurfaceVariant)
				rx = rx - rw - px(3)
				icon(ICON[role], rx - px(13), ry1 + px(3), rx, ry1 + rowH - px(3), sel and C.primary or C.onSurfaceVariant)
				rx = rx - px(16)
			end
			if a.roster and a.roster.leader then
				icon(ICON.lead, rx - px(11), ry1 + px(4), rx, ry1 + rowH - px(4), C.primary)
				rx = rx - px(14)
			end
			text(font, fitText(font, a.name, px(9.5), rx - left - px(22)), left + px(19), ry1 + rowH * 0.5 - px(3.4), px(9.5), "o", sel and C.onSurface or C.onSurfaceVariant)
			register(left, ry1, right, ry2, "row" .. id, function()
				playClick()
				local now = Spring.GetTimer()
				if selected == id and lastRowClick and Spring.DiffTimers(now, lastRowClick) < 0.4 then goTo(id) end
				local follow=type(theatres.Mode())=="number"
				selected = id
				if follow then setTheatres(id) end
                if type(blueprints.Mode())=="number" then blueprints.SetMode(id) end
				lastRowClick = now
			end,
				string.format("Team %d: %s%s", id, a.name, a.roster and (", " .. a.roster.role .. ", " .. (a.roster.side or "?")) or ""))
		end
		if #ids > maxRows then
			text(font, string.format("%d-%d of %d, scroll", listScroll + 1, listScroll + maxRows, #ids), right, cy - listH - px(9), px(7.5), "or", C.onSurfaceVariant)
		end
		cy = cy - listH - px(12)
	end

	-- the selected AI: details, role grid, query
	local e = selected and ais[selected]
	if e then
		local r = e.roster
		local cmd = mayCommand(e.teamId)
		local line
		if r then
			line = string.format("team %d · %s · start %d, %d · %s%s", e.teamId, r.side or "?", r.x or 0, r.z or 0, r.factory or "-", r.landLocked and " · landlocked" or "")
		else
			line = (firstAnnounceFrame == nil and spGetGameFrame() > 60 * 30) and "no announcement: is this AI hosted here?" or "waiting for the AI's announcement"
		end
		local qs = px(18)
		local qx = iconButton(right - qs, cy - qs + px(3), qs, ICON.query, "query", function() playClick(); send(e.teamId, "barb|query|" .. e.teamId) end,
			"Ask this AI for its details", false, "?")
		iconButton(qx, cy - qs + px(3), qs, ICON.goto, "goto", function() playClick(); goTo(e.teamId) end,
			"Fly the camera to this AI's commander (else its factory nearest its start); double-click a row does the same", false, ">")
		text(font, fitText(font, line, px(8.5), w - 2 * qs - px(6)), left, cy - px(10), px(8.5), "o", C.onSurfaceVariant)
		cy = cy - px(18)

		local segH = px(22)
		local sgap = px(3)
		local segW = (w - 2 * sgap) / 3
		for i, role in ipairs(ROLES) do
			local row = mathFloor((i - 1) / 3)
			local col = (i - 1) % 3
			local sx1 = left + col * (segW + sgap)
			local sy2 = cy - row * (segH + sgap)
			local active = r and r.role == role
			labelButton(sx1, sy2 - segH, sx1 + segW, sy2, ICON[role], role, "role" .. role, function()
				if active then return end
				playClick()
				requestRole(e.teamId, role)
			end, role .. ": " .. (ROLE_HINT[role] or "") .. (cmd and "" or " (only this AI's host can switch its role)"), active, cmd)
		end
		cy = cy - 2 * segH - sgap - px(4)
        local value=(aggressionDrag and aggressionDrag.team==e.teamId) and aggressionDrag.value or (e.aggression or 0)
        text(font, string.format("Aggression %+.2f",value),left,cy-px(11),px(9),"o",C.onSurfaceVariant)
        local ax1,ax2,ay=left+px(105),right-px(35),cy-px(8)
        roundRect(ax1,ay-px(2),ax2,ay+px(2),px(2),C.onSurfaceVariant)
        glColor(C.onSurfaceVariant); glRect((ax1+ax2)/2,ay-px(5),(ax1+ax2)/2+px(1),ay+px(5))
        local knob=ax1+(value+1)*.5*(ax2-ax1)
        roundRect(knob-px(4),ay-px(6),knob+px(4),ay+px(6),px(3),cmd and C.ok or C.onSurfaceVariant)
        hit[#hit+1]={ax1,ay-px(10),ax2,ay+px(10),"aggression",function() end,
            "Aggression offset: -1 defensive, 0 automatic, +1 aggressive. Drag, then release to apply to this AI.",cmd and e.teamId or nil}
        labelButton(right-px(31),cy-px(18),right,cy, nil,"0","aggressionReset",function()
            requestAggression(e.teamId,0)
        end,"Reset this AI's aggression offset to zero",false,cmd)
        cy=cy-px(25)
		local replyColor = C.onSurfaceVariant
		if e.replyKind == "ok" then replyColor = C.ok elseif e.replyKind == "warn" then replyColor = C.warn end
		text(font, fitText(font, e.lastReply and ("reply: " .. e.lastReply) or (cmd and "pick a role to switch this AI" or "read-only: this AI is not hosted by you"), px(8.5), w),
			left, cy - px(9), px(8.5), "o", replyColor)
		cy = cy - px(14)
	end
	divider(x1 + px(4), x2 - px(4), cy)
	cy = cy - px(4)

	-- events
	local bottom = y1 + pad
	local lineH = px(12)
	local rows = mathFloor((cy - bottom) / lineH)
	if rows >= 1 then
		local total = #events
		eventScroll = mathMax(0, mathMin(eventScroll, mathMax(0, total - rows)))
		local shown = 0
		for i = total - eventScroll, 1, -1 do
			if shown >= rows then break end
			local ev = events[i]
			local ey = cy - shown * lineH
			local col = C.onSurfaceVariant
			if ev.kind == "ok" then col = C.ok elseif ev.kind == "warn" then col = C.warn elseif ev.kind == "error" then col = C.error end
			text(font, frameToClock(ev.frame), left, ey - px(9.5), px(8), "o", C.onSurfaceVariant)
			text(font, fitText(font, ev.text, px(8), w - px(30)), left + px(30), ey - px(9.5), px(8), "o", col)
			shown = shown + 1
		end
		if total == 0 then text(font, "No events yet.", left, cy - px(9.5), px(8.5), "o", C.onSurfaceVariant) end
	end
end

function widget:DrawScreen()
	hit = {}
	if not hasFlowUI or not font then initFlowUI() end
	updatePlacement()
	theatres.Draw(open and win or nil)
	field.DrawScreen(open and win or nil)
	if not field.Mode() then marks.DrawScreen() end
	if not strategy.Mode() then seaLanes.DrawScreen();territory.DrawScreen() end
    strategy.DrawScreen()
	drawLauncher()
	if open then drawWindow() end

	local mx, my = spGetMouseState()
	local newHover = nil
	for _, r in ipairs(hit) do
		if inside(mx, my, r[1], r[2], r[3], r[4]) and r[5] ~= "header" then newHover = r[5] end
	end
	hoverId = newHover
	glColor(1, 1, 1, 1)
end

-- ---------------------------------------------------------------- input

local function overLauncher(mx, my) return inside(mx, my, launcher.x1, launcher.y1, launcher.x2, launcher.y2) end
local function overWindow(mx, my) return open and inside(mx, my, win.x1, win.y1, win.x2, win.y2) end

function widget:IsAbove(mx, my)
	return overLauncher(mx, my) or overWindow(mx, my)
end

function widget:GetTooltip(mx, my)
	local tip = nil
	for _, r in ipairs(hit) do
		if inside(mx, my, r[1], r[2], r[3], r[4]) and r[7] then tip = r[7] end
	end
	return tip
end

function widget:MousePress(mx, my, mb)
    if strategy.MousePress(mx,my,mb,overLauncher(mx,my) or overWindow(mx,my)) then return true end
	if theatres.MousePress(mx,my,mb) then return true end
	if field.MousePress(mx,my,mb) then return true end
	-- landmarks: clicks on its panels are kept from the game; a left click on a position
	-- disc or a mark (never under the window) selects or inspects it
	if marks.MousePress(mx,my,mb,overLauncher(mx, my) or overWindow(mx, my)) then return true end
	if not (overLauncher(mx, my) or overWindow(mx, my)) then return false end
	if mb ~= 1 then return true end
	local top = nil
	for _, r in ipairs(hit) do
		if inside(mx, my, r[1], r[2], r[3], r[4]) then top = r end
	end
	if top and top[5] == "header" then
		dragging = { mx, my, offX, offY }
		return true
	end
    if top and top[5]=="aggression" then
        if top[8] then
            aggressionDrag={team=top[8],x1=top[1],x2=top[3],value=0}
            dragAggression(mx)
        end
        return true
    end
	if top then pressedId = top[5] end
	return true
end

function widget:MouseMove(mx, my, dx, dy, mb)
    if aggressionDrag then dragAggression(mx); return end
	if theatres.MouseMove(mx,my) then return end
	if field.MouseMove(mx,my) then return end
	if dragging then
		offX = dragging[3] + (mx - dragging[1])
		offY = dragging[4] + (my - dragging[2])
		updatePlacement()
	end
end

function widget:MouseRelease(mx, my, mb)
    if aggressionDrag then
        dragAggression(mx)
        requestAggression(aggressionDrag.team,aggressionDrag.value)
        aggressionDrag=nil
        return false
    end
	if theatres.MouseRelease(mx,my,mb) then return false end
	if field.MouseRelease(mx,my,mb) then return false end
	if dragging then
		dragging = nil
		return false
	end
	if pressedId then
		for _, r in ipairs(hit) do
			if r[5] == pressedId and inside(mx, my, r[1], r[2], r[3], r[4]) then
				pressedId = nil
				r[6]()
				return false
			end
		end
		pressedId = nil
	end
	return false
end

function widget:MouseWheel(up, value)
	local mx, my = spGetMouseState()
	if not overWindow(mx, my) then return false end
	-- over the AI list: scroll the list; elsewhere: the events
	for _, r in ipairs(hit) do
		if string.sub(r[5], 1, 3) == "row" and inside(mx, my, r[1], r[2], r[3], r[4]) then
			listScroll = listScroll + (up and -1 or 1)
			return true
		end
	end
	eventScroll = eventScroll + (up and 1 or -1)
	return true
end

function widget:TextCommand(cmd)
    if strategy.TextCommand(cmd) then return true end
	local laneCommand, laneMode = cmd:match("^barb(%a+)%s*(%a*)$")
	if laneCommand=="lanes" or laneCommand=="landlanes" or laneCommand=="sealanes" then
		-- D-356: with no player selected, "on"/"player" show the member team's
		-- lanes rather than nothing (the older barbtheatres fell back the same way).
		if laneMode=="off" or laneMode=="hide" then setTheatres(nil)
		elseif laneMode=="team" then setTheatres("team")
		elseif laneMode=="player" or laneMode=="on" then setTheatres(selected or "team")
		elseif laneMode=="" then if theatres.Mode() then setTheatres(nil) else setTheatres(selected or "team") end
		else return false end
		return true
	end
	if field.TextCommand(cmd) then return true end
	if marks.TextCommand(cmd) then return true end
	if seaLanes.TextCommand(cmd) then return true end
	if territory.TextCommand(cmd) then return true end
	if cmd=="barbtheatres" then if theatres.Mode() then setTheatres(nil) else setTheatres(selected or "all") end; return true end
	if cmd == "barblink" then setOpen(not open); return true end
	if cmd == "barblayout" then
        if blueprints.Mode() then blueprints.SetMode(nil) else blueprints.SetMode("team") end
        return true
    end
    if cmd == "barblayout player" then blueprints.SetMode(selected); return true end
    if cmd == "barblayout team" then blueprints.SetMode("team"); return true end
    if cmd == "barblayout off" then blueprints.SetMode(nil); return true end
	return false
end

function widget:KeyPress(key, mods, isRepeat)
	if key == 98 and mods.ctrl and mods.alt and not isRepeat then   -- b
		setOpen(not open)
		return true
	end
	if key == 27 and open then   -- escape
		setOpen(false)
		return true
	end
	return false
end
