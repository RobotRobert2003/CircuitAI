"""Lua 5.1 tests of the actual host widget; uses the existing lane UI dependency."""
import unittest
from test_lane_ui_memory import ROOT, LuaRuntime


class BlueprintTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime()
        self.lua.execute((ROOT / 'tools/playtest/fixtures/lane_ui_mock.lua').read_text())
        self.lua.execute('''
            spectating=true; Spring.GetSpectatingState=function() return spectating end
            Spring.AreTeamsAllied=function(a,b) return math.floor(a/8)==math.floor(b/8) end
            messages={}; builds=0; deletes=0; vertices=0; minY=math.huge
            gl.CreateList=function(f) builds=builds+1; f(); return builds end
            gl.DeleteList=function() deletes=deletes+1 end
            gl.Vertex=function(x,y,z) vertices=vertices+1; minY=math.min(minY,y) end
            Spring.GetGroundHeight=function() return -300 end
            Spring.SendSkirmishAIMessage=function(id,text) messages[#messages+1]=text; return true end
            function plan(id,idx,total,text,sender)
                widget:RecvSkirmishAIMessage(id,'barb|layout|'..(sender or id)..'|'..math.floor(id/8)..'|'..idx..'|'..total..'|'..text)
            end
            footprint='zone:1:1000:1000:0:320:320:z;slot:armap:1000:1000:0:64:96:p;'
        ''')
        self.lua.execute((ROOT / 'tools/widgets/gui_barb_team_link.lua').read_text(encoding='utf-8'))
        self.lua.execute('widget:Initialize(); WG.barblink.SetOpen(true)')

    def test_team_player_selection_and_lease(self):
        self.lua.execute('''
            WG.barblink.SetBlueprints('team')
            for id=0,15 do assert(WG.barblink.BlueprintSnapshot(id).visible==(id<8)) end
            widget:DrawScreen(); click('row3')
            assert(WG.barblink.BlueprintSnapshot(0).visible)
            click('plansPlayer'); assert(not WG.barblink.BlueprintSnapshot(0).visible)
            plan(3,1,1,footprint); assert(WG.barblink.BlueprintSnapshot(3).slots==1)
            widget:DrawScreen(); click('row2')
            assert(WG.barblink.BlueprintSnapshot(2).visible and not WG.barblink.BlueprintSnapshot(3).visible)
            assert(deletes==1)
            widget:GameFrame(600); local renewed=false
            for _,m in ipairs(messages) do if m=='barb|layout|2|renew' then renewed=true end end
            assert(renewed)
            widget:DrawScreen(); click('plansTeam'); click('ally1')
            for id=0,15 do assert(WG.barblink.BlueprintSnapshot(id).visible==(id>=8)) end
            widget:DrawScreen(); click('plansOff'); local count=#messages
            widget:GameFrame(1200); assert(#messages==count)
        ''')

    def test_atomic_bounded_messages_unchanged_cache_and_water_surface(self):
        self.lua.execute('''
            WG.barblink.SetBlueprints(0); plan(0,1,1,footprint)
            assert(builds==1 and minY>=5 and vertices>0)
            plan(0,1,1,footprint); assert(builds==1)
            plan(0,1,2,'slot:armap:1000:1000:0:64:96:b;')
            assert(WG.barblink.BlueprintSnapshot(0).built==0)
            plan(0,2,2,'slot:armap:1200:1000:0:64:96:p;')
            assert(WG.barblink.BlueprintSnapshot(0).built==1 and WG.barblink.BlueprintSnapshot(0).slots==2)
            assert(builds==2 and deletes==1)
            plan(0,2,2,'broken'); plan(0,1,2000,'broken'); plan(0,1.5,2,'broken')
            assert(builds==2)
            plan(0,1,1,'slot:a:nan:100:0:10:10:p;slot:a:-100:100:0:10:10:p;')
            assert(WG.barblink.BlueprintSnapshot(0).slots==0)
            plan(0,0,0,'none'); assert(WG.barblink.BlueprintSnapshot(0).ready)
            local left,right=false,false
            gl.Vertex=function(x,y,z)
                if x==880 and z==1000 then left=true end
                if x==1120 and z==1000 then right=true end
            end
            plan(0,1,1,'corridor:2:1000:1000:0:240:80:z;')
            assert(left and right, 'horizontal corridor centerline follows its long axis')
            widget:Shutdown(); assert(deletes==builds)
        ''')

    def test_privacy_sender_and_hidden_late_messages(self):
        self.lua.execute('''
            WG.barblink.SetBlueprints(0)
            plan(1,1,1,footprint,0); assert(builds==0)
            plan(0,1,1,footprint); assert(builds==1)
            WG.barblink.SetBlueprints(nil); plan(0,1,1,footprint); assert(builds==1)
            spectating=false
            WG.barblink.SetBlueprints(8); plan(8,1,1,footprint)
            assert(not WG.barblink.BlueprintSnapshot(8).visible and builds==1)
        ''')

    def test_render_steady_state_allocations(self):
        allocated = self.lua.execute('''
            WG.barblink.SetBlueprints('team')
            local many={} for i=1,1000 do many[i]=footprint end
            local text=table.concat(many); local total=math.ceil(#text/3000)
            for id=0,7 do for i=1,total do plan(id,i,total,text:sub((i-1)*3000+1,i*3000)) end end
            collectgarbage('collect'); collectgarbage('stop'); local before=collectgarbage('count')
            for i=1,120 do widget:DrawWorld() end
            return (collectgarbage('count')-before)/120
        ''')
        self.assertLess(allocated, 16, f'{allocated:.2f} KiB/frame')
        print(f'8-team / 16000-entry blueprint draw: {allocated:.2f} KiB/frame')


if __name__ == '__main__':
    unittest.main()
