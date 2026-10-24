"""Run with lupa==2.8 (Lua 5.1); install into build-theatres/widget-test-deps.

The fixture disables automatic GC like Recoil while measuring DrawScreen.
It exercises the actual widget, not a duplicate renderer implementation.
"""
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'build-theatres/widget-test-deps'))
from lupa.lua51 import LuaRuntime


class LaneUIMemoryTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime()
        self.lua.execute((ROOT / 'tools/playtest/fixtures/lane_ui_mock.lua').read_text())
        self.lua.execute((ROOT / 'tools/widgets/gui_barb_team_link.lua').read_text(encoding='utf-8'))
        self.lua.execute("widget:Initialize(); WG.barblink.SetOpen(true); WG.barblink.TheatreOptions({x=8,y=1000})")

    def test_front_publication_does_not_replace_sea_routes(self):
        sea, both, cleared = self.lua.execute('''
            WG.barblink.SetTheatres('all')
            local vertices=0
            gl.Vertex=function() vertices=vertices+1 end
            local function draw()
                vertices=0;widget:DrawWorld();return vertices
            end
            widget:RecvSkirmishAIMessage(0,'barb|sealanes|0|0|1;10;42,0,-1,100,100,500,500')
            local sea=draw()
            widget:RecvSkirmishAIMessage(0,'barb|frontlanes|0|0|1;11;0,2,-1,100,700,500,1100')
            local both=draw()
            widget:RecvSkirmishAIMessage(0,'barb|frontlanes|0|0|1;12')
            return sea,both,draw()
        ''')
        self.assertGreater(sea, 0)
        self.assertGreater(both, sea)
        self.assertEqual(cleared, sea)

    def test_all_players_frame_allocation_and_retained_memory(self):
        allocated, retained = self.lua.execute('''
            for team=0,15 do publish(team,9,400) end
            WG.barblink.SetTheatres('all'); widget:DrawScreen()
            collectgarbage('collect'); local baseline=collectgarbage('count'); local peak=0
            for i=1,120 do
                collectgarbage('stop'); local before=collectgarbage('count')
                widget:DrawScreen(); click('row'..(i%5))
                peak=math.max(peak,collectgarbage('count')-before)
                collectgarbage('collect')
            end
            return peak,collectgarbage('count')-baseline
        ''')
        self.assertLess(allocated, 256, f'per-frame allocation: {allocated:.1f} KiB')
        self.assertLess(retained, 128, f'retained growth: {retained:.1f} KiB')
        print(f'all-player fixture: peak {allocated:.1f} KiB/frame, retained delta {retained:.1f} KiB')

    def test_published_routes_follow_buttons_on_every_surface(self):
        self.lua.execute('''
            for _,team in ipairs({0,1,8}) do
                for _,kind in ipairs({'sealanes','frontlanes'}) do
                    widget:RecvSkirmishAIMessage(team,'barb|'..kind..'|'..team..'|'..math.floor(team/8)..'|1;10;42,0,-1,100,100,500,500')
                end
                if team~=1 then
                    widget:RecvSkirmishAIMessage(team,'barb|territory|'..team..'|'..math.floor(team/8)..'|1;10;11;900;L,1,300,300,400,400,100,'..team..',100:100,500:500')
                end
            end
            local function counts()
                WG.barblink.SetOpen(false)
                local result={}
                for i,draw in ipairs({function() widget:DrawWorld() end,
                    function() widget:DrawInMiniMap(200,100) end,
                    function() widget:DrawScreen() end}) do
                    local n=0;gl.Vertex=function() n=n+1 end;draw();result[i]=n
                end
                WG.barblink.SetOpen(true)
                return result
            end
            local function button(id) widget:DrawScreen();click(id) end
            for _,n in ipairs(counts()) do assert(n==0,'default hidden') end
            button('lanesPlayer');local player=counts()
            button('lanesTeam');local team=counts()
            for i=1,3 do assert(player[i]>0 and team[i]>player[i],'surface filter '..i) end
            button('ally1');local other=counts()
            for i=1,3 do assert(other[i]==player[i],'ally selection '..i) end
            button('lanesOff')
            for _,n in ipairs(counts()) do assert(n==0,'Hide must remove every route surface') end
            widget:TextCommand('barblanes player')
            for i,n in ipairs(counts()) do assert(n==player[i],'command player') end
            widget:TextCommand('barbsealanes off')
            for _,n in ipairs(counts()) do assert(n==0,'alias hide') end
        ''')

    def test_player_selection_preserves_all_mode_and_follows_player_mode(self):
        self.lua.execute('''
            for team=0,15 do publish(team,1,4) end
            WG.barblink.SetTheatres('all'); widget:DrawScreen(); click('row4')
            for team=0,15 do assert(WG.barblink.TheatreSnapshot(team).visible) end
            widget:DrawScreen(); click('lanesTeam')
            for team=0,15 do assert(WG.barblink.TheatreSnapshot(team).visible==(team<8)) end
            widget:DrawScreen(); click('row2')
            for team=0,15 do assert(WG.barblink.TheatreSnapshot(team).visible==(team<8)) end
            widget:DrawScreen(); click('ally1')
            for team=0,15 do assert(WG.barblink.TheatreSnapshot(team).visible==(team>=8)) end
            widget:DrawScreen(); click('ally0'); widget:DrawScreen(); click('row4')
            widget:DrawScreen(); click('lanesPlayer')
            assert(WG.barblink.TheatreSnapshot(4).visible)
            assert(not WG.barblink.TheatreSnapshot(0).visible)
            widget:DrawScreen(); click('row2')
            assert(WG.barblink.TheatreSnapshot(2).visible)
            assert(not WG.barblink.TheatreSnapshot(4).visible)
            widget:DrawScreen(); click('lanesOff')
            for team=0,15 do assert(not WG.barblink.TheatreSnapshot(team).visible) end
        ''')

    def test_batched_vertices_preserve_dashes_clipping_and_shorter_refresh(self):
        self.lua.execute('''
            WG.barblink.SetOpen(false)
            WG.barblink.TheatreOptions({labels=false,cues=false})
            for _,cls in ipairs({4,6}) do
                for _,count in ipairs({12,3,0}) do
                    publish(0,1,count,cls); WG.barblink.SetTheatres(0)
                    Spring.WorldToScreenCoords=function(x,y,z)
                        if x==60 then return nil end
                        return x/10,z/10,0.5
                    end
                    local actual={}
                    gl.Vertex=function(x,y) actual[#actual+1]=x; actual[#actual+1]=y end
                    widget:DrawScreen()
                    local expected={}
                    for pass=1,2 do for i=2,count do
                        if i~=2 and i~=3 and not (cls==6 and i%6>=3) then
                            expected[#expected+1]=(i-1)*3; expected[#expected+1]=100
                            expected[#expected+1]=i*3; expected[#expected+1]=100
                        end
                    end end
                    assert(#actual==#expected,'vertex count')
                    for i,value in ipairs(expected) do assert(actual[i]==value,'vertex coordinate') end
                end
            end
        ''')


if __name__ == '__main__':
    unittest.main()
