-- Supplied precondition only. Antinuke construction and stockpile remain AI-owned.
function widget:GetInfo()
    return {name="Antinuke funded defender fixture",desc="Supplied income and physical target scouts",layer=122,enabled=true}
end
local cfg=VFS.Include("LuaUI/Config/antinuke_fixture.lua")
local queue={}
local function give(name,x,z,n)
    queue[#queue+1]="give "..n.." "..name.." 0 @"..x..","..Spring.GetGroundHeight(x,z)..","..z
end
function widget:Initialize()
    Spring.Echo("[AntiNukeFixture] supplied economy and enemy ground scouts; this is not natural opening or scouting evidence")
end
function widget:GameFrame(f)
    if f==300 then Spring.SendCommands("cheat 1") end
    if f==9*60*30 then
        local x,_,z=Spring.GetTeamStartPosition(0)
        local prefix=cfg.side=="cortex" and "cor" or cfg.side=="legion" and "leg" or "arm"
        -- All That Glitters: unused inland ground, outside the reserved campus.
        give(prefix.."fus",x+650,z+1900,12)
        give(prefix.."mmkr",x+650,z+2500,8)
        give(prefix.."mstor",x+1000,z+2100,2)
        give(prefix.."estor",x+1000,z+2400,2)
        Spring.Echo("[AntiNukeFixture] supplying twelve fusions and eight advanced converters at nine minutes")
    end
    if #queue>0 and f%30==0 then Spring.SendCommands(table.remove(queue,1)) end
    if f==12*60*30 or f==14*60*30 then
        -- A physical scout exposes targets through normal LOS. Do not force a
        -- launch or reveal the map; the silo still selects and fires its target.
        local x,_,z=Spring.GetTeamStartPosition(0)
        local sx,sz=x+150,z+150
        Spring.SendCommands("give 1 armfav 1 @"..sx..","..Spring.GetGroundHeight(sx,sz)..","..sz)
        Spring.Echo("[AntiNukeFixture] supplied enemy ground scout at frame="..f)
    end
end
