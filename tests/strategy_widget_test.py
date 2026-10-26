"""Run the real strategy renderer in Lua 5.1 with engine-free publication fixtures."""
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]


class StrategyWidgetTest(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute('''
            Game={mapSizeX=128,mapSizeZ=128};GL={LINES=1,QUADS=2}
            permitted=true;frame=300;created=0;deleted=0;orders=0
            local tick=0
            function isPermittedTeam() return permitted end
            Spring={GetGameFrame=function()return frame end,GetTeamColor=function()return .2,.5,.8 end,
                GetGroundHeight=function()return 0 end,IsGUIHidden=function()return false end,
                GetTimer=function()tick=tick+.0001;return tick end,DiffTimers=function(a,b)return a-b end,
                TraceScreenRay=function()return "ground",{40,0,40}end,Echo=function(s)error(s)end}
            gl=setmetatable({CreateList=function(fn)created=created+1;fn();return created end,
                DeleteList=function()deleted=deleted+1 end,BeginEnd=function(_,fn)fn()end,
                GetViewSizes=function()return 1920,1080 end},{__index=function()return function()end end})
            model={gw=4,gh=4,cell=32,corridorRuns={[0]={{0,2,16}}},clearanceRuns={[0]={{0,6,16}}},
                corridors={[2]={id=2,class=0,name="Centre",x=64,z=64,width=96,length=128,spine={{0,64,96},{128,64,96}}}}}
            field={Model=function()return model end,Status=function()return "ready"end}
            territory={Snapshot=function()return {} end}
        ''')
        source = (ROOT/'tools/widgets/include/barb_strategy.lua').read_text()
        self.api = self.lua.execute(source+'\nreturn strategy')
        self.payload = '1;300;1;0;2;0;1;32,64;32;-1,-1,0;-1;123;0,2,-1,0,64,128,64;1,3,-1;0,64,0|64,64,4;290,1,3,80,90,75,0,75,64,0'

    def ready(self):
        self.api.Set(True)
        for _ in range(100):
            self.api.Update()
            if not self.api.Snapshot()['preparing']:
                return
        self.fail('geometry never completed')

    def test_parses_real_snapshot_and_rejects_older_or_foreign(self):
        self.assertTrue(self.api.Receive(1,self.payload))
        self.ready()
        s=self.api.Snapshot()['teams'][1]
        self.assertEqual(s['corridor'],2)
        self.assertEqual(s['native'][5],90)
        self.assertEqual(len(s['route']),2)
        self.assertFalse(self.api.Receive(1,self.payload.replace(';300;',';299;',1)))
        self.lua.execute('permitted=false')
        self.assertFalse(self.api.Receive(1,self.payload))
        self.assertEqual(len(self.api.Snapshot()['teams']),0)
        self.api.DrawWorld()
        self.assertGreater(self.lua.globals().deleted,0)

    def test_mismatched_field_revision_is_not_drawn_as_assignment(self):
        self.api.Receive(1,self.payload)
        self.lua.execute("model.corridorRevision='999'")
        self.ready()
        self.assertEqual(len(self.api.Snapshot()['teams']),0)
        self.assertEqual(self.api.Snapshot()['dynamicLists'],0)

    def test_panel_avoids_top_left_minimap(self):
        self.lua.execute('Spring.GetMiniMapGeometry=function()return 0,735,208,345 end')
        self.api.Receive(1,self.payload);self.ready();self.api.DrawScreen()
        self.assertFalse(self.api.MousePress(30,1000,1,True))
        self.assertTrue(self.api.MousePress(30,590,1,False))
        self.assertTrue(self.api.Snapshot()['frozen'])

    def test_raster_binary_lookup_boundaries(self):
        runs=self.lua.table_from([self.lua.table_from([0,-1,3]),self.lua.table_from([3,7,5])])
        self.assertEqual(self.api.At(runs,2),-1)
        self.assertEqual(self.api.At(runs,3),7)
        self.assertEqual(self.api.At(runs,7),7)
        self.assertIsNone(self.api.At(runs,8))

    def test_identical_state_files_do_not_rebuild_and_command_close_disposes(self):
        self.api.Receive(1,self.payload);self.ready()
        count=self.lua.globals().created
        self.assertFalse(self.api.Receive(1,self.payload))
        self.api.Update();self.assertEqual(self.lua.globals().created,count)
        self.assertTrue(self.api.TextCommand('barbstrategy'))
        self.assertFalse(self.api.Mode())
        self.assertEqual(self.api.Snapshot()['terrainLists'],0)
        self.assertEqual(self.api.Snapshot()['dynamicLists'],0)

    def test_dynamic_updates_reuse_static_geometry(self):
        self.api.Receive(1,self.payload);self.ready()
        before=self.lua.globals().created
        self.api.Receive(1,self.payload.replace(';300;',';600;',1));self.ready()
        self.assertEqual(self.lua.globals().created-before,1)
        self.api.DrawScreen();self.api.DrawWorld()

    def test_freeze_preserves_snapshot_and_resume_refreshes(self):
        self.api.Receive(1,self.payload);self.ready();self.api.DrawScreen()
        self.assertTrue(self.api.MousePress(30,930,1,False))  # Freeze
        self.assertTrue(self.api.Snapshot()['frozen'])
        self.api.Receive(1,self.payload.replace(';300;',';600;',1))
        self.assertEqual(self.api.Snapshot()['teams'][1]['frame'],300)
        self.api.DrawScreen();self.api.MousePress(30,930,1,False)
        self.assertEqual(self.api.Snapshot()['teams'][1]['frame'],600)

    def test_inspection_does_not_capture_normal_game_clicks(self):
        self.api.Receive(1,self.payload);self.ready();self.api.DrawScreen()
        self.assertFalse(self.api.MousePress(1000,500,1,False))
        self.api.MousePress(155,930,1,False)  # Inspect map
        self.assertFalse(self.api.MousePress(1000,500,1,True))
        self.assertTrue(self.api.MousePress(1000,500,1,False))
        self.api.Update();self.api.DrawScreen()


if __name__ == '__main__':
    unittest.main()
