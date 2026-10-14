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

function widget:GetInfo()
	return {
		name    = "BARb team link",
		desc    = "Allied BARb AIs: roster, events, runtime role switching, layout overlay (host only)",
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
local WIN_W, WIN_H = 340, 390   -- unscaled px
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
        MousePress = function(x,y,b) return widget:MousePress(x,y,b) end,
        MouseRelease = function(x,y,b) return widget:MouseRelease(x,y,b) end,
        MouseMove = function(x,y,dx,dy,b) return widget:MouseMove(x,y,dx,dy,b) end,
        ButtonRect = function(id)
            local guide=theatres.ButtonRect(id); if guide then return guide end
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
	unhookAIMessages()
	WG.barblink = nil
	if WG.guishader then
		WG.guishader.RemoveRect("barblink")
		WG.guishader.RemoveRect("barblinklauncher")
	end
end

function widget:GetConfigData()
	return { open = open, offX = offX / mathMax(scale, 0.01), offY = offY / mathMax(scale, 0.01),  theatres=theatres.GetConfig() }
end

function widget:SetConfigData(data)
	if type(data) ~= "table" then return end
	theatres.Config(data.theatres)
	if data.open ~= nil then
		firstRun = false   -- a config of this version: its open state stands
		open = data.open == true
	end
	offX = (tonumber(data.offX) or 0) * scale
	offY = (tonumber(data.offY) or 0) * scale
end

function widget:Update()
    if stateFiles.Poll then stateFiles.Poll() end
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
function widget:DrawWorld() blueprints.Draw() end

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
