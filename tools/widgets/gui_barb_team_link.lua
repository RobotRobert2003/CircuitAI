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
-- compiles one display list per layer and never reads again. The pattern of a line
-- says who can cross it and the shape of a mark what it is; colour only repeats that,
-- so the map reads the same to colour-blind players. Every line is cased in ink.
-- Grammar: projects/circuitai/battlefield-analysis-implementation.md, 6.4.
local field = (function()
local PATH = "LuaUI/Config/BARb/field/map.txt"
local LAYERS = {"ground","theatres","regions","crossings","barriers","shores","chokes","key","labels"}
local STRATEGIC = {ground=true, theatres=true, key=true}
local options = {legend=false, blueprint=false, dim=false, detail="auto", pick=false, lodHeight=6000, collapsed=false, side=nil}
local layers = {}
for _,k in ipairs(LAYERS) do layers[k]=true end
local on = false                 -- the view is shown
local model = nil                -- parsed records
local lists = {}                 -- layer -> display list id
local labelsAll = {}             -- {x,y,z,text,size,minH,maxH,r,g,b}
local status = "Terrain map hidden"
local parse = nil                -- incremental parse state
local lastExists = nil           -- wall timer of the last VFS.FileExists check
local allyProvider = nil         -- function() -> the panel's selected ally team
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

local function viewerAlly()
    if options.side then return options.side end
    if Spring.GetSpectatingState() and allyProvider then
        local a = allyProvider(); if a then return a end
    end
    return Spring.GetMyAllyTeamID()
end
local function isWaterChar(c) return c=="water" or c=="deep" or c=="coast" or c=="strait" end

-- ---- file discovery and incremental parsing
local function newModel()
    return {classes={}, theatres={}, regions={}, boundaries={}, chokes={}, avenues={}, landings={}, standoff={},
        sides={}, contact={}, keys={}, runs={}, groundRuns={}, rowRun={}, gw=0, gh=0, cell=32, name="", settings={}}
end
local function parseRecord(m, line)
    local f = split(line, "|")
    local k = f[1]
    if k == "theatre" then
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
        local runs, start = m.groundRuns, 0
        for id, count in string.gmatch(f[2] or "", "(%d+)%*(%d+)") do
            runs[#runs+1] = {start, tonumber(id), tonumber(count)}
            start = start + tonumber(count)
        end
    elseif k == "cells" then
        -- Run-length region ids, kept as runs: regionOf(cell) scans the few runs of its row.
        local runs, start = m.runs, 0
        for id, count in string.gmatch(f[2] or "", "(%d+)%*(%d+)") do
            runs[#runs+1] = {start, tonumber(id), tonumber(count)}
            start = start + tonumber(count)
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
    if name ~= "" and Game.mapName and loose(name) ~= loose(Game.mapName)
        and not string.find(loose(Game.mapName), loose(name), 1, true) and not string.find(loose(name), loose(Game.mapName), 1, true) then
        return false, "file is for map '" .. name .. "'"
    end
    local m = newModel()
    m.name, m.gw, m.gh, m.cell = name, tonumber(gw), tonumber(gh), tonumber(cell)
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
        indexRuns(m)
        model, seq = m, parse.seq
        parse = nil
        compileAll()
    else
        status = string.format("Reading terrain analysis %d%%", math.floor(100 * pos / math.max(1, #text)))
    end
end
local function tryLoad()
    if not (VFS and VFS.LoadFile and VFS.FileExists) then status = "VFS unavailable"; return end
    local now = Spring.GetTimer()
    if lastExists and Spring.DiffTimers(now, lastExists) < 2 then return end
    lastExists = now
    if not VFS.FileExists(PATH, VFS.RAW) then
        status = "Terrain analysis not published (needs a locally hosted BARb with field.enabled)"
        return
    end
    local ok, text = pcall(VFS.LoadFile, PATH, VFS.RAW)
    if not ok or type(text) ~= "string" or #text == 0 then status = "Cannot read " .. PATH; return end
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

compileAll = function()
    local m = model
    if not m then return end
    disposeLists()
    -- One line per border. Every theatre and region edge is also a boundary record
    -- (shore kinds between land and water, open/ramp/climb/cliff/pass between land
    -- regions), so the classified boundary IS the border line; outlines are never
    -- drawn on top of it. Smoothed copies are built once here.
    SMOOTH_TOL = 1.0 * (m.cell or 32)
    -- cell -> region id and cell -> ground class, expanded from the runs once, for the fill edges
    m.cellRegion = {}
    for _, r in ipairs(m.runs) do for c = r[1], r[1] + r[3] - 1 do m.cellRegion[c] = r[2] end end
    m.cellGround = {}
    m.groundCount = {}
    for _, r in ipairs(m.groundRuns) do
        m.groundCount[r[2]] = (m.groundCount[r[2]] or 0) + r[3]
        for c = r[1], r[1] + r[3] - 1 do m.cellGround[c] = r[2] end
    end
    for _, t in pairs(m.theatres) do t.sm = smoothLoops(t.outline) end
    for _, r in pairs(m.regions) do r.sm = smoothLoops(r.outline) end
    for _, b in ipairs(m.boundaries) do b.sm = smooth(b.line) end
    findSummits(m)
    -- dim: one flat ink sheet over the map. The view draws with the depth test off, so
    -- the sheet covers the terrain whatever its height and every line above it keeps
    -- its contrast without blueprint mode's bare black.
    compileLayer("dim", function()
        local w, h = Game.mapSizeX, Game.mapSizeZ
        gl.Color(K.ink[1], K.ink[2], K.ink[3], 0.55)
        gl.BeginEnd(GL.QUADS, function()
            gl.Vertex(-512, 0, -512); gl.Vertex(w+512, 0, -512); gl.Vertex(w+512, 0, h+512); gl.Vertex(-512, 0, h+512)
        end)
    end)
    -- ground: the per-cell classes as fills and marks, straight from the file
    compileLayer("ground", function()
        for cls = 0, 7 do
            local gd = GROUND[cls]
            if m.groundCount[cls] and (gd.fill or gd.mark) then
                local want = {[cls] = true}
                if gd.fill then
                    fillWith(gd.fill, gd.alpha)
                    fillRuns(m, m.groundRuns, m.cellGround, want, (cls <= 2) and 2 or nil)
                end
                if gd.mark then
                    gl.LineWidth(1)
                    setColour(MARK_COLOUR[gd.mark], (gd.mark == "hatch") and 0.4 or 0.6)
                    cellMarks(m, m.groundRuns, want, gd.mark, (gd.mark == "hatch" or gd.mark == "wave") and 2 or 1)
                end
            end
        end
    end)
    -- theatres: with the shores layer on, a soft white halo under the classified shore
    -- line (the coastline reads as one line); with shores off, a crisp white line
    compileLayer("theatresHalo", function()
        setColour(K.white, 0.18); gl.LineWidth(8)
        gl.BeginEnd(GL.LINES, function() for _, t in pairs(m.theatres) do if t.kind ~= "land" then solidLoops(t.sm) end end end)
    end)
    lineLayer("theatres", function()
        strokeStyle(STYLE.coast)
        gl.BeginEnd(GL.LINES, function() for _, t in pairs(m.theatres) do if t.kind ~= "land" then solidLoops(t.sm) end end end)
    end)
    -- regions: thin grey border for every land-to-land boundary that no other enabled
    -- layer draws; split by kind so crossings and barriers replace, never overlap, it
    local CROSSING_KINDS = {ramp=true, pass=true, climb=true, ford=true}
    local function thinBorders(filter)
        return function()
            strokeStyle(STYLE.region)
            gl.BeginEnd(GL.LINES, function()
                for _, b in ipairs(m.boundaries) do
                    -- water-to-water borders are not drawn: a sea reads as one surface
                    if filter(b.kind) and not (regionIsWater(m, b.a) and regionIsWater(m, b.b)) then solid(b.sm) end
                end
            end)
        end
    end
    lineLayer("regions", thinBorders(function(k) return k == "open" end))
    lineLayer("regionsCross", thinBorders(function(k) return CROSSING_KINDS[k] end))
    lineLayer("regionsBarrier", thinBorders(function(k) return k == "cliff" end))
    -- crossings: one long-dash line for every border some land class can cross between
    -- land regions (ramp, pass, climb); a ford is a double line. The chokes layer owns
    -- the width bar, so none is drawn here. Which classes cross is in the inspector.
    lineLayer("crossings", function()
        for _, b in ipairs(m.boundaries) do
            local k = b.kind
            if k == "ramp" or k == "pass" or k == "climb" then
                strokeStyle(STYLE.crossing)
                gl.BeginEnd(GL.LINES, function() drawPat(STYLE.crossing, b.sm) end)
            elseif k == "ford" then
                strokeStyle(STYLE.ford)
                gl.BeginEnd(GL.LINES, function() drawPat(STYLE.ford, b.sm) end)
            end
        end
    end)
    -- the side of a line a point lies on, for hachures
    local function leftOf(p, x, z)
        if #p < 4 then return true end
        local ax, az, bx, bz = p[1], p[2], p[3], p[4]
        return ((bx-ax)*(z-az) - (bz-az)*(x-ax)) > 0
    end
    -- barriers: heavy vermilion with ticks pointing downhill (toward the lower region)
    lineLayer("barriers", function()
        strokeStyle(STYLE.blocked)
        for _, b in ipairs(m.boundaries) do
            if b.kind == "cliff" then
                local ra, rb = m.regions[b.a], m.regions[b.b]
                local lowIsA = ra and rb and (ra.minH + ra.maxH) < (rb.minH + rb.maxH)
                local low = lowIsA and ra or rb
                local left = true
                if low then left = leftOf(b.sm, low.lx, low.lz) end
                gl.BeginEnd(GL.LINES, function() drawPat(STYLE.blocked, b.sm, left) end)
            end
        end
    end)
    -- shores: a beach or a steep shore is a crossing out of the water (long dash on the
    -- coast halo); a sheer shore is a barrier with ticks toward the water
    lineLayer("shores", function()
        for _, b in ipairs(m.boundaries) do
            if b.kind == "beach" or b.kind == "steep" then
                strokeStyle(STYLE.crossing)
                gl.BeginEnd(GL.LINES, function() drawPat(STYLE.crossing, b.sm) end)
            elseif b.kind == "sheer" then
                strokeStyle(STYLE.blocked)
                local water = regionIsWater(m, b.a) and m.regions[b.a] or m.regions[b.b]
                local left = true
                if water then left = leftOf(b.sm, water.lx, water.lz) end
                gl.BeginEnd(GL.LINES, function() drawPat(STYLE.blocked, b.sm, left) end)
            end
        end
    end)
    -- chokes: a serifed width bar for land chokes only; narrows between water regions
    -- read as stray strokes across open water
    local function landChoke(c) return not regionIsWater(m, c.a) and not regionIsWater(m, c.b) end
    lineLayer("chokes", function()
        strokeStyle(STYLE.choke)
        gl.BeginEnd(GL.LINES, function()
            for _, c in ipairs(m.chokes) do if landChoke(c) then ibeam(c.x, c.z, c.dx, c.dz, math.max(16, c.width/2)) end end
        end)
    end)
    -- key terrain: yellow symbols, one shape per kind; a summit is a filled triangle
    lineLayer("key", function()
        strokeStyle(STYLE.key)
        local fills = {}
        gl.BeginEnd(GL.LINES, function()
            for _, k in ipairs(m.keys) do
                if k.kind == "high" then
                    local lx, lz, rx, rz, tx, tz = triangle(k.x, k.z, 44)
                    if m.summits[k.region] then fills[#fills+1] = {lx, lz, rx, rz, tx, tz} end
                elseif k.kind == "geo" then ngon(k.x, k.z, 40, 6)
                elseif k.kind == "island" then ngon(k.x, k.z, 60, 4)
                elseif k.kind == "pond" then ngon(k.x, k.z, 30, 8) end
            end
        end)
        if not haloPass and #fills > 0 then
            gl.BeginEnd(GL.TRIANGLES, function() for _, f in ipairs(fills) do tri(f[1], f[2], f[3], f[4], f[5], f[6]) end end)
        end
    end)
    -- minimap: the coastlines in 2D (x, z)
    compileLayer("minimap", function()
        local function flat(p) for i = 3, #p, 2 do gl.Vertex(p[i-2], p[i-1]); gl.Vertex(p[i], p[i+1]) end end
        gl.LineWidth(1.5)
        gl.BeginEnd(GL.LINES, function()
            setColour(K.white, 0.8)
            for _, t in pairs(m.theatres) do if t.kind ~= "land" then for _, p in ipairs(t.sm) do flat(p) end end end
        end)
    end)
    -- labels (screen space): theatres from far, regions and numbers close
    labelsAll = {}
    local mapCells = math.max(1, m.gw * m.gh)
    for _, t in pairs(m.theatres) do
        -- theatres under 1% of the map (islets, ponds) get a small label that the strategic level hides
        local big = t.cells >= mapCells * 0.01
        addLabel(t.x, t.z, big and spaced(t.name ~= "" and t.name or t.kind) or (t.name ~= "" and t.name or t.kind), big and 18 or 11, 0, 1e9, K.white)
    end
    for _, c in ipairs(m.chokes) do
        if not regionIsWater(m, c.a) and not regionIsWater(m, c.b) then addLabel(c.x, c.z, string.format("%d", c.width), 10, 0, options.lodHeight * 0.6, K.white) end
    end
    local summits = 0
    for id in pairs(m.summits) do
        summits = summits + 1
        local r = m.regions[id]
        if r then addLabel(r.lx, r.lz + 70, "summit", 11, 0, options.lodHeight * 1.5, K.yellow) end
    end
    for _, r in pairs(m.regions) do
        if #labelsAll >= 190 then break end
        if not isWaterChar(r.character) and r.cells >= 40 and not m.summits[r.id] then addLabel(r.lx, r.lz, r.character .. " " .. r.id, 10, 0, options.lodHeight, K.grey) end
    end
    local land, seas, ponds = 0, 0, 0
    for _, t in pairs(m.theatres) do if t.kind == "sea" then seas = seas + 1 elseif t.kind == "pond" then ponds = ponds + 1 else land = land + 1 end end
    local nreg = 0; for _ in pairs(m.regions) do nreg = nreg + 1 end
    local lands = 0; for _, c in ipairs(m.chokes) do if landChoke(c) then lands = lands + 1 end end
    status = string.format("Terrain: %d land mass%s, %d sea%s, %d pond%s, %d regions, %d summit%s, %d choke%s",
        land, land == 1 and "" or "es", seas, seas == 1 and "" or "s", ponds, ponds == 1 and "" or "s", nreg,
        summits, summits == 1 and "" or "s", lands, lands == 1 and "" or "s")
end

-- ---- blueprint mode
local function setGround(off)
    if off == groundOff then return end
    groundOff = off
    if Spring.SetDrawGround then Spring.SetDrawGround(not off) end
    if Spring.SetDrawWater then Spring.SetDrawWater(not off) end
end

-- ---- public state changes
local function setMode(value)
    local was = on
    on = value and true or false
    if on then
        if not model and not parse then status = "Looking for the terrain analysis..."; lastExists = nil; tryLoad() end
        setGround(options.blueprint)
    else
        parse = nil
        setGround(false)
        status = "Terrain map hidden"
    end
    return was ~= on
end
local function setBlueprint(v) options.blueprint = v and true or false; if options.blueprint then options.dim = false end; if on then setGround(options.blueprint) end end
local function setLayer(name, v)
    if layers[name] == nil then return false end
    layers[name] = v and true or false
    return true
end
local function detailLevel()
    if options.detail == "strategic" then return "strategic" end
    if options.detail == "tactical" then return "tactical" end
    local _, cy = Spring.GetCameraPosition()
    return (cy or 0) > options.lodHeight and "strategic" or "tactical"
end
local function buildFocus()
    if focusList then gl.DeleteList(focusList); focusList = nil end
    if not focus or not model then return end
    local m = model
    focusList = gl.CreateList(function()
        setColour(K.yellow, 1); gl.LineWidth(4)
        gl.BeginEnd(GL.LINES, function()
            if focus.kind == "region" then local r = m.regions[focus.id]; if r then solidLoops(r.sm or r.outline) end
            elseif focus.kind == "theatre" then local t = m.theatres[focus.id]; if t then solidLoops(t.sm or t.outline) end
            end
        end)
    end)
end
local function setFocus(kind, id)
    if kind == nil then focus = nil else focus = {kind=kind, id=id} end
    buildFocus()
end
local function focusRecords()
    local out = {}
    if not focus or not model then return out end
    local m = model
    if focus.kind == "region" then
        local r = m.regions[focus.id]
        if r then
            local t = m.theatres[r.theatre]
            out[#out+1] = string.format("REGION %d  %s  in %s", r.id, r.character, t and (t.name ~= "" and t.name or t.kind) or "?")
            out[#out+1] = string.format("%d cells  width median %d / low %d  height %d..%d", r.cells, r.medianW, r.lowW, r.minH, r.maxH)
            local n = 0
            for _, b in ipairs(m.boundaries) do
                if (b.a == r.id or b.b == r.id) and b.kind ~= "open" and b.kind ~= "edge" and n < 8 then
                    n = n + 1
                    local who = {}
                    for cls = 0, 4 do if hasBit(b.mask, cls) then who[#who+1] = CLASS_NAMES[cls] end end
                    out[#out+1] = string.format("  %s to region %d  width %d  slope %d deg  crosses: %s", b.kind, b.a == r.id and b.b or b.a, b.width, b.slope, #who > 0 and table.concat(who, ", ") or "nobody")
                end
            end
        end
    elseif focus.kind == "theatre" then
        local t = m.theatres[focus.id]
        if t then out[#out+1] = string.format("THEATRE %d  %s  %s  %d cells  holders mask %d", t.id, t.kind, t.name, t.cells, t.holders) end
    end
    return out
end
local function pickAt(mx, my)
    if not model then return end
    local kind, pos = Spring.TraceScreenRay(mx, my, true)
    if kind ~= "ground" or not pos then return end
    local rid = regionOf(model, pos[1], pos[3])
    if not rid then return end
    setFocus("region", rid)
end
local function inspect()
    if not model or not (options.pick or options.legend) then hover = nil; return end
    local now = Spring.GetTimer()
    if hoverTimer and Spring.DiffTimers(now, hoverTimer) < 0.1 then return end
    hoverTimer = now
    local mx, my = Spring.GetMouseState()
    local kind, pos = Spring.TraceScreenRay(mx, my, true)
    if kind ~= "ground" or not pos then hover = nil; return end
    local rid = regionOf(model, pos[1], pos[3])
    local r = rid and model.regions[rid]
    if not r then hover = nil; return end
    local t = model.theatres[r.theatre]
    local h = Spring.GetGroundHeight(pos[1], pos[3])
    local lines = {
        string.format("cell %d,%d  region %d (%s)  %s", math.floor(pos[1]/model.cell), math.floor(pos[3]/model.cell), rid, r.character, t and (t.name ~= "" and t.name or t.kind) or ""),
        string.format("height %d  region %d..%d", h, r.minH, r.maxH),
    }
    local gnd = model.cellGround and model.cellGround[math.floor(pos[3] / model.cell) * model.gw + math.floor(pos[1] / model.cell)]
    if gnd and GROUND[gnd] then lines[#lines+1] = GROUND[gnd].text end
    local sideName = "no side"
    for _, s in ipairs(model.sides) do
        -- bounding-box test against the side's box: enough for the inspector, the file holds no per-cell side
        local b = s.box
        if #b >= 8 then
            local x1, x2, z1, z2 = math.huge, -math.huge, math.huge, -math.huge
            for i = 1, #b, 2 do x1 = math.min(x1, b[i]); x2 = math.max(x2, b[i]); z1 = math.min(z1, b[i+1]); z2 = math.max(z2, b[i+1]) end
            if pos[1] >= x1 and pos[1] <= x2 and pos[3] >= z1 and pos[3] <= z2 then sideName = s.ally >= 0 and ("start box of ally team " .. s.ally) or "map half (no start boxes)" end
        end
    end
    lines[#lines+1] = sideName
    hover = lines
end

-- ---- drawing
local function lineScale()
    local _, cy = Spring.GetCameraPosition()
    return math.max(0.8, math.min(3, (cy or 3000) / 3000))
end
local function drawWorld()
    if not on or not model or Spring.IsGUIHidden() then return end
    local level = detailLevel()
    local scale = lineScale()
    gl.DepthTest(false)
    if options.dim and not options.blueprint and lists.dim then gl.CallList(lists.dim) end
    local order = {"ground","regions","theatres","shores","crossings","barriers","chokes","key"}
    local tactical = level == "tactical"
    for _, name in ipairs(order) do
        if layers[name] and (tactical or STRATEGIC[name]) then
            local l = lists[name]
            -- the coastline is one line: a halo under the classified shore when shores draw, a crisp line otherwise
            if name == "theatres" and layers.shores and tactical then l = lists.theatresHalo end
            if l then gl.CallList(l) end
            -- borders that crossings or barriers would draw fall back to the thin grey region line
            if name == "regions" then
                if not layers.crossings and lists.regionsCross then gl.CallList(lists.regionsCross) end
                if not layers.barriers and lists.regionsBarrier then gl.CallList(lists.regionsBarrier) end
            end
        end
    end
    if focusList then gl.CallList(focusList) end
    gl.LineWidth(1); gl.Color(1, 1, 1, 1); gl.DepthTest(true)
end
local function drawMiniMap(sx, sy)
    if not on or not model or not lists.minimap or not layers.theatres then return end
    gl.PushMatrix()
    gl.Translate(0, sy, 0)
    gl.Scale(sx / Game.mapSizeX, -sy / Game.mapSizeZ, 1)
    gl.CallList(lists.minimap)
    gl.PopMatrix()
    gl.LineWidth(1); gl.Color(1, 1, 1, 1)
end
local function drawLabels()
    if not layers.labels or not model then return end
    local _, cy = Spring.GetCameraPosition()
    cy = cy or 0
    local vw, vh = gl.GetViewSizes()
    local level = detailLevel()
    -- above the detail height only theatre and avenue names show, shrinking with the camera height
    -- so a full-map view with many theatres does not overlap
    local shrink = cy > options.lodHeight and math.max(0.5, math.min(1, options.lodHeight / cy)) or 1
    for _, l in ipairs(labelsAll) do
        if cy >= l[6] and cy <= l[7] and (level == "tactical" or l[5] >= 13) then
            local sx, sy, sz = Spring.WorldToScreenCoords(l[1], l[2], l[3])
            if sx and sz and sz > 0 and sz < 1 and sx > 0 and sx < vw and sy > 0 and sy < vh then
                local c = l[8]
                local size = math.max(9, l[5] * shrink)
                gl.Color(K.ink[1], K.ink[2], K.ink[3], 0.85)
                gl.Text(l[4], sx+1, sy-1, size, "c"); gl.Text(l[4], sx-1, sy-1, size, "c"); gl.Text(l[4], sx+1, sy+1, size, "c"); gl.Text(l[4], sx-1, sy+1, size, "c")
                gl.Color(c[1], c[2], c[3], 0.95); gl.Text(l[4], sx, sy, size, "co")
            end
        end
    end
    gl.Color(1, 1, 1, 1)
end
local function button(id, x, y, w, title, isOn, action)
    gl.Color(isOn and {0.12,0.30,0.34,0.98} or {0.09,0.13,0.18,0.98}); gl.Rect(x, y, x+w, y+24)
    gl.Color(isOn and mint or {0.83,0.87,0.93,1}); gl.Text(title, x+w/2, y+7, 10, "oc")
    controls[#controls+1] = {x, y, x+w, y+24, id=id, action=action}
end
-- ---- legend: every sample is drawn by the map's own pattern and symbol code, in
-- screen space, so the legend cannot drift from the map. Each row names its pattern
-- or shape in words before its meaning; colour is never the only difference.
local function legendSample(x, y, w, draw)
    emit = function(ax, az, bx, bz) gl.Vertex(ax, az); gl.Vertex(bx, bz) end
    patScale = 0.28
    draw(x, y, w)
    emit = nil; patScale = 1
    gl.LineWidth(1)
end
local function lineRow(st)
    return function(x, y, w) strokeStyle(st); gl.BeginEnd(GL.LINES, function() drawPat(st, {x, y, x+w, y}, false) end) end
end
local function groundRow(cls)
    local gd = GROUND[cls]
    return function(x, y, w)
        if gd.fill then gl.Color(gd.fill[1], gd.fill[2], gd.fill[3], math.min(0.6, gd.alpha * 2)); gl.Rect(x, y-6, x+w, y+6) end
        if gd.mark then
            setColour(MARK_COLOUR[gd.mark], 0.9); gl.LineWidth(1)
            gl.BeginEnd(GL.LINES, function()
                local step = (gd.mark == "hatch" or gd.mark == "wave" or gd.mark == "dash") and 14 or 8
                for t = step/2, w - 3, step do markCell(gd.mark, x + t, y, 3) end
            end)
        end
        if not gd.fill and not gd.mark then
            gl.Color(K.grey[1], K.grey[2], K.grey[3], 0.5); gl.LineWidth(1)
            gl.BeginEnd(GL.LINE_LOOP, function() gl.Vertex(x, y-6); gl.Vertex(x+w, y-6); gl.Vertex(x+w, y+6); gl.Vertex(x, y+6) end)
        end
    end
end
local function chokeRow(x, y, w)
    strokeStyle(STYLE.choke); gl.BeginEnd(GL.LINES, function() ibeam(x+w/2, y, 0, 1, w/3) end)
end
local function markRow(kind)
    return function(x, y, w)
        strokeStyle(STYLE.key)
        local corners
        gl.BeginEnd(GL.LINES, function()
            local cx = x + w/2
            if kind == "high" or kind == "summit" then corners = {triangle(cx, y, 8)}
            elseif kind == "geo" then ngon(cx, y, 7, 6)
            elseif kind == "island" then ngon(cx, y, 7, 4)
            elseif kind == "pond" then ngon(cx, y, 7, 8) end
        end)
        if kind == "summit" and corners then gl.BeginEnd(GL.TRIANGLES, function() tri(corners[1], corners[2], corners[3], corners[4], corners[5], corners[6]) end) end
    end
end
local function legendRows()
    local rows = {}
    local function head(t) rows[#rows+1] = {nil, t} end
    local function add(sample, t) rows[#rows+1] = {sample, t} end
    head("GROUND  /  what each cell is to the unit classes")
    for cls = 0, 7 do
        if cls ~= 7 or (model and model.groundCount and model.groundCount[7]) then
            add(groundRow(cls), GROUND[cls].text)
        end
    end
    head("BORDERS  /  five line types")
    add(lineRow(STYLE.coast), "Solid, heavy: coastline of a sea or pond")
    add(lineRow(STYLE.region), "Solid, thin: open border between regions")
    add(lineRow(STYLE.crossing), "Long dash: a way through for some unit class (Pick shows which)")
    add(lineRow(STYLE.ford), "Double line: ford, wade across")
    add(lineRow(STYLE.blocked), "Solid with ticks: no way through (cliff, sheer shore); ticks point down")
    head("MARKS")
    add(chokeRow, "Bar with serifs: narrowest point, number = width in elmos")
    add(markRow("high"), "Hollow triangle: high ground (plateau)")
    add(markRow("summit"), "Filled triangle: summit, reached only by all-terrain units or aircraft")
    add(markRow("geo"), "Hexagon: geothermal vent")
    add(markRow("island"), "Diamond: island or rock")
    add(markRow("pond"), "Octagon: pond, water with no way to the sea")
    return rows
end
local legendCache, legendCacheModel = nil, nil
local function legendRowsCached()
    if not legendCache or legendCacheModel ~= model then legendCache = legendRows(); legendCacheModel = model end
    return legendCache
end
local ROW_H, HEAD_H = 16, 20
local function drawLegend(panel)
    controls = {}
    legendRect = nil
    if not on or not options.legend or Spring.IsGUIHidden() then return end
    local vw, vh = gl.GetViewSizes()
    local rows = legendRowsCached()
    local rec = focusRecords()
    local layerRows = math.ceil(#LAYERS / 4)
    local w = 500
    local h = 36
    if not options.collapsed then
        h = 52 + 30 + 30 + 26 + layerRows*28 + 6 + 14 + 8 + (#rec > 0 and (16 + #rec*15) or 15) + 30
        for _, row in ipairs(rows) do h = h + (row[1] and ROW_H or HEAD_H) end
    end
    dockX = math.max(8, math.min(vw - w - 8, dockX or (vw - w - 22)))
    dockY = math.max(math.min(h + 8, vh - 65), math.min(vh - 65, dockY or (vh - 80)))
    local x, top = dockX, dockY
    legendRect = {x, top-h, x+w, top}
    gl.Color(inkPanel); gl.Rect(x, top-h, x+w, top)
    gl.Color(K.sky[1], K.sky[2], K.sky[3], 1); gl.Rect(x, top-3, x+w, top)
    gl.Color(0.93, 0.96, 1, 1); gl.Text("TERRAIN MAP", x+14, top-24, 14, "o")
    controls[#controls+1] = {x, top-34, x+w-100, top, id="fieldDrag", action=function() end}
    button("fieldCollapse", x+w-98, top-30, 42, options.collapsed and "+" or "-", false, function() options.collapsed = not options.collapsed end)
    button("fieldLegendClose", x+w-50, top-30, 42, "Hide", false, function() options.legend = false end)
    if options.collapsed then return end
    local y = top - 52
    gl.Color(muted); gl.Text(status, x+14, y, 10, "o")
    y = y - 30
    -- terrain: shown, dimmed under an ink sheet, or off (blueprint: bare black)
    button("fieldContrast", x+12, y, 122, "Terrain: " .. (options.blueprint and "off" or (options.dim and "dim" or "shown")), options.blueprint or options.dim, function()
        if options.blueprint then setBlueprint(false); options.dim = false
        elseif options.dim then setBlueprint(true)
        else options.dim = true end
    end)
    button("fieldDetail", x+140, y, 100, "Detail: " .. options.detail, options.detail ~= "auto", function()
        options.detail = options.detail == "auto" and "strategic" or (options.detail == "strategic" and "tactical" or "auto")
    end)
    button("fieldPick", x+246, y, 78, "Pick " .. (options.pick and "ON" or "OFF"), options.pick, function() options.pick = not options.pick; if not options.pick then setFocus(nil) end end)
    y = y - 30
    gl.Color(muted); gl.Text("LAYERS  /  click to toggle", x+14, y+4, 10, "o")
    y = y - 26
    local col = 0
    for _, name in ipairs(LAYERS) do
        local key = name
        button("fieldLayer_" .. key, x+12+col*116, y, 110, key .. (layers[key] and " +" or " -"), layers[key], function() layers[key] = not layers[key] end)
        col = col + 1
        if col == 4 then col = 0; y = y - 28 end
    end
    if col ~= 0 then y = y - 28 end
    y = y - 6
    gl.Color(muted); gl.Text("LEGEND  /  pattern and shape carry the meaning, colour only repeats it", x+14, y+4, 10, "o")
    y = y - 14
    for _, row in ipairs(rows) do
        if row[1] then
            legendSample(x+16, y, 70, row[1])
            gl.Color(0.9, 0.93, 0.97, 1); gl.Text(row[2], x+96, y-4, 10, "o")
            y = y - ROW_H
        else
            y = y - 4
            gl.Color(mint); gl.Text(row[2], x+14, y-2, 10, "o")
            y = y - (HEAD_H - 4)
        end
    end
    y = y - 8
    if #rec > 0 then
        gl.Color(mint); gl.Text("FOCUS", x+14, y, 11, "o"); y = y - 16
        for _, line in ipairs(rec) do gl.Color(0.91, 0.93, 0.96, 1); gl.Text(line, x+14, y, 10, "o"); y = y - 15 end
    else
        gl.Color(muted); gl.Text(options.pick and "Pick: click the map to focus a region or a land mass" or "Turn Pick on to focus a region; hover shows the cell's ground class", x+14, y, 10, "o")
    end
    gl.Color(muted); gl.Text("Terrain analysis, computed once at game start. Drag header to move.", x+14, top-h+12, 10, "o")
    gl.LineWidth(1); gl.Color(1, 1, 1, 1)
end
local function drawInspector()
    if not on or not hover then return end
    local mx, my = Spring.GetMouseState()
    local vw = gl.GetViewSizes()
    local w = 0
    for _, l in ipairs(hover) do w = math.max(w, gl.GetTextWidth(l) * 10) end
    w = w + 16
    local x = math.min(vw - w - 8, mx + 18)
    local y = my - 10
    gl.Color(inkPanel); gl.Rect(x, y - #hover*14 - 6, x+w, y+6)
    for i, l in ipairs(hover) do gl.Color(0.9, 0.93, 0.97, 1); gl.Text(l, x+8, y - i*14 + 4, 10, "o") end
    gl.Color(1, 1, 1, 1)
end
local function drawScreen(panel)
    if not on then return end
    drawLabels()
    drawLegend(panel)
    inspect()
    drawInspector()
end
local function update()
    if not on then return end
    if parse then stepParse()
    elseif not model then tryLoad() end
end
local function hitAt(x, y)
    for i = #controls, 1, -1 do local r = controls[i]; if x >= r[1] and y >= r[2] and x <= r[3] and y <= r[4] then return r end end
end
local function mousePress(x, y, b)
    if not on or Spring.IsGUIHidden() then return false end
    if options.legend then
        local r = hitAt(x, y)
        if r then
            if b == 1 then pressed = r; if r.id == "fieldDrag" then drag = {x, y, dockX, dockY} end end
            return true
        end
        if legendRect and x >= legendRect[1] and x <= legendRect[3] and y >= legendRect[2] and y <= legendRect[4] then return true end
    end
    if options.pick and b == 1 and model then pickAt(x, y); return true end
    return false
end
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
local function config(data)
    if type(data) ~= "table" then return end
    if type(data.layers) == "table" then for _, k in ipairs(LAYERS) do if type(data.layers[k]) == "boolean" then layers[k] = data.layers[k] end end end
    if type(data.legend) == "boolean" then options.legend = data.legend end
    if type(data.blueprint) == "boolean" then options.blueprint = data.blueprint end
    if type(data.dim) == "boolean" then options.dim = data.dim end
    if data.detail == "auto" or data.detail == "strategic" or data.detail == "tactical" then options.detail = data.detail end
    if type(data.lodHeight) == "number" then options.lodHeight = math.max(1000, data.lodHeight) end
    if type(data.dock) == "table" and type(data.dock.x) == "number" and type(data.dock.y) == "number" then dockX, dockY = data.dock.x, data.dock.y end
end
local function getConfig()
    local l = {}
    for _, k in ipairs(LAYERS) do l[k] = layers[k] end
    return {layers=l, legend=options.legend, blueprint=options.blueprint, dim=options.dim, detail=options.detail, lodHeight=options.lodHeight, dock={x=dockX, y=dockY}}
end
local function textCommand(cmd)
    if cmd == "barbfield" or cmd == "barbterrain" then setMode(not on); return true end
    local sub = string.match(cmd, "^barbfield%s+(.+)$") or string.match(cmd, "^barbterrain%s+(.+)$")
    if not sub then return false end
    if sub == "legend" then options.legend = not options.legend; if options.legend and not on then setMode(true) end
    elseif sub == "blueprint" then setBlueprint(not options.blueprint)
    elseif sub == "dim" then options.dim = not options.dim; if options.dim then setBlueprint(false) end
    elseif sub == "on" or sub == "show" then setMode(true)
    elseif sub == "off" or sub == "hide" then setMode(false)
    elseif sub == "pick" then options.pick = not options.pick
    else
        local name = string.match(sub, "^layer%s+(%w+)$")
        if name then if not setLayer(name, not layers[name]) then Spring.Echo("[BARb link] unknown field layer " .. name) end
        else
            local d = string.match(sub, "^detail%s+(%w+)$")
            if d == "auto" or d == "strategic" or d == "tactical" then options.detail = d
            else
                do Spring.Echo("[BARb link] /barbterrain [legend|blueprint|dim|pick|on|off|layer <name>|detail <auto|strategic|tactical>]") end
            end
        end
    end
    return true
end
local function shutdown()
    setGround(false)
    disposeLists()
    on = false
end
return {SetMode=setMode, Mode=function() return on end, Status=function() return status end, Snapshot=snapshot,
    SetLayer=setLayer, SetFocus=setFocus, SetBlueprint=setBlueprint, SetLegend=function(v) options.legend = v and true or false end,
    SetSide=function(v) options.side = (type(v) == "number" and v >= 0) and v or nil end,   -- the viewer's ally team; negative = own
    Legend=function() return options.legend end, Config=config, GetConfig=getConfig, TextCommand=textCommand,
    Update=update, DrawWorld=drawWorld, DrawScreen=drawScreen, DrawMiniMap=drawMiniMap, Shutdown=shutdown,
    SetAllyProvider=function(fn) allyProvider = fn end,
    ButtonRect=function(id) for _, r in ipairs(controls) do if r.id == id then return {r[1], r[2], r[3], r[4]} end end end,
    MousePress=mousePress, MouseRelease=mouseRelease, MouseMove=mouseMove}
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
local WIN_W, WIN_H = 340, 450   -- unscaled px
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
        -- the terrain map (field module): the same paths as the Terrain row and /barbterrain
        SetField = function(v) return field.SetMode(v) end,
        FieldStatus = field.Status,
        FieldSnapshot = field.Snapshot,
        FieldLayer = field.SetLayer,
        FieldFocus = field.SetFocus,
        FieldBlueprint = field.SetBlueprint,
        FieldLegend = field.SetLegend,
        FieldSide = field.SetSide,
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
    field.Shutdown()
	unhookAIMessages()
	WG.barblink = nil
	if WG.guishader then
		WG.guishader.RemoveRect("barblink")
		WG.guishader.RemoveRect("barblinklauncher")
	end
end

function widget:GetConfigData()
	return { open = open, offX = offX / mathMax(scale, 0.01), offY = offY / mathMax(scale, 0.01),  theatres=theatres.GetConfig(), field=field.GetConfig() }
end

function widget:SetConfigData(data)
	if type(data) ~= "table" then return end
	theatres.Config(data.theatres)
	field.Config(data.field)
	if data.open ~= nil then
		firstRun = false   -- a config of this version: its open state stands
		open = data.open == true
	end
	offX = (tonumber(data.offX) or 0) * scale
	offY = (tonumber(data.offY) or 0) * scale
end

function widget:Update()
    if stateFiles.Poll then stateFiles.Poll() end
    field.Update()
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
function widget:DrawWorld() blueprints.Draw(); field.DrawWorld() end
function widget:DrawInMiniMap(sx, sy) field.DrawMiniMap(sx, sy) end

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
	if theatres.MousePress(mx,my,mb) then return true end
	if field.MousePress(mx,my,mb) then return true end
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
	if field.TextCommand(cmd) then return true end
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
