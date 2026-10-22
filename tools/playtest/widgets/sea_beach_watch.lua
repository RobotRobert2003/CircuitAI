function widget:GetInfo()
    return {name="SEA beach coverage observer", layer=125, enabled=true}
end
-- Read-only test telemetry. Public terrain and declared starts define probes;
-- spectator truth never reaches the AI. Five-second samples measure allied LOS
-- separately from scout proximity (proximity alone is not detection).
local cfg=VFS.Include("LuaUI/Config/sea_beach_watch.lua")
local sites, allies={},{}
local scouts={armpt=true,corpt=true,legnavyscout=true,coresupp=true}
local births,contacts={},{}
local function log(s) Spring.Echo("[SeaBeach] frame="..Spring.GetGameFrame().." "..s) end
local function nearest(x,z,ally,enemy)
    local best=math.huge
    for _,t in ipairs(cfg.teams) do
        if (t.ally~=ally)==enemy then best=math.min(best,(x-t.x)^2+(z-t.z)^2) end
    end
    return best
end
function widget:UnitCreated(id) births[id]=Spring.GetGameFrame() end
function widget:UnitDestroyed(id)
    births[id]=nil
    for ally in pairs(allies) do contacts[ally..":"..id]=nil end
end
function widget:GameFrame(f)
    if f==30 then
        for _,t in ipairs(cfg.teams) do if t.role=="SEA" then allies[t.ally]=true end end
        for _,point in ipairs(cfg.focus or {}) do
            local s={x=point.x,z=point.z,ally=point.ally,id=#sites+1}
            sites[#sites+1]=s
            log("site id="..s.id.." ally="..s.ally.." x="..s.x.." z="..s.z.." label="..point.label)
            local y=Spring.GetGroundHeight(s.x,s.z)
            local buildable=0
            for facing=0,3 do
                buildable=math.max(buildable,Spring.TestBuildOrder(UnitDefNames.armsy.id,s.x,y,s.z,facing) or 0)
            end
            log("focus label="..point.label.." height="..y.." yardBuildable="..buildable)
        end
        -- Include near-edge cells, unlike a grid starting at half a large cell.
        local step=256
        for z=64,Game.mapSizeZ-64,step do for x=64,Game.mapSizeX-64,step do
            local y=Spring.GetGroundHeight(x,z)
            if y < -20 then
                local beach=false
                for direction=0,7 do
                    local a=direction*math.pi/4
                    local px,pz=x+math.cos(a)*step,z+math.sin(a)*step
                    if px>=0 and pz>=0 and px<Game.mapSizeX and pz<Game.mapSizeZ then
                        local h=Spring.GetGroundHeight(px,pz)
                        if h>=0 and h<100 then beach=true;break end
                    end
                end
                if beach then for ally in pairs(allies) do
                    if nearest(x,z,ally,true)<nearest(x,z,ally,false) then
                        local s={x=x,z=z,ally=ally,id=#sites+1}
                        sites[#sites+1]=s
                        log("site id="..s.id.." ally="..ally.." x="..x.." z="..z)
                    end
                end end
            end
        end end
        log("ready sites="..#sites)
    end
    if f<150 or f%150~=0 then return end
    local boats={}
    for ally in pairs(allies) do boats[ally]={} end
    for _,t in ipairs(cfg.teams) do
        if boats[t.ally] then for _,id in ipairs(Spring.GetTeamUnits(t.team) or {}) do
            local def=UnitDefs[Spring.GetUnitDefID(id)]
            if cfg.contacts and def and (def.minWaterDepth or 0)>0 then
                for ally in pairs(allies) do if ally~=t.ally then
                    local state=Spring.GetUnitLosState(id,ally,false) or {}
                    local key=ally..":"..id
                    local visible=state.los==true
                    if contacts[key]==nil or contacts[key]~=visible then
                        local tx,_,tz=Spring.GetUnitPosition(id)
                        log("target ally="..ally.." id="..id.." unit="..def.name.." born="..(births[id] or 0)
                            .." los="..tostring(visible).." x="..math.floor(tx or -1).." z="..math.floor(tz or -1))
                        contacts[key]=visible
                    end
                end end
            end
            if def and scouts[def.name] then
                local x,_,z=Spring.GetUnitPosition(id)
                local _,_,_,_,built=Spring.GetUnitHealth(id)
                if x and built==1 then boats[t.ally][#boats[t.ally]+1]={x=x,z=z,r=def.losRadius or 0} end
            end
        end end
    end
    for _,s in ipairs(sites) do
        local los=Spring.IsPosInLos(s.x,0,s.z,s.ally)==true
        local near=false
        for _,b in ipairs(boats[s.ally]) do
            if (b.x-s.x)^2+(b.z-s.z)^2<=b.r*b.r then near=true;break end
        end
        -- Log every sample: audit must include the final unseen tail and reject
        -- missing observations instead of silently treating them as coverage.
        log("sample id="..s.id.." los="..tostring(los).." scout="..tostring(near))
    end
    if f%1800==0 then for ally,b in pairs(boats) do log("fleet ally="..ally.." scouts="..#b) end end
end
