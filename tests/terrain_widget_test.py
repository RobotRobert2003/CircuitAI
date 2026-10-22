"""Exercise the actual embedded terrain module in Lua 5.1 (requires lupa).

Run with Python after installing lupa into an isolated test environment.
No engine install or user configuration is read or changed.
"""
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]

class TerrainWidgetTest(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute('''
            Game={mapName="Fixture",mapSizeX=128,mapSizeZ=128}
            GL={QUADS=1,LINES=2,TRIANGLES=3}
            local tick=0; local list=0
            Spring={GetTimer=function() tick=tick+0.00001;return tick end,
              DiffTimers=function(a,b) return a-b end,GetGroundHeight=function() return 0 end,
              SetDrawGround=function() end,SetDrawWater=function() end,IsGUIHidden=function() return false end,
              WorldToScreenCoords=function(x,y,z) return x,z,0.5 end, Echo=function() end,
              GetSelectedUnits=function() error("selection query forbidden") end,
              GetActiveCommand=function() error("build command query forbidden") end,
              GetCameraPosition=function() return 0,5000,0 end}
            gl=setmetatable({CreateList=function(fn) fn();list=list+1;return list end,
              BeginEnd=function(_,fn) fn() end,GetViewSizes=function() return 1920,1080 end,
              GetTextWidth=function(s) return #s/2 end}, {__index=function() return function() end end})
            fixture="barbfield|1|Fixture|4|4|32|1|0|123\\n"..
              "experience|2|initial-map\\nclass|0|vehicle|27|-1|20|0\\n"..
              "theatre|0|land|Central Land|16|64|64|0|0,0;128,0;128,128;0,128;0,0\\n"..
              "region|0|0|plain|16|128|128|0|0|64|64|0,0;128,0;128,128;0,128;0,0\\n"..
              "boundary|0|open|0|1|31|128|0|64,0;64,128\\n"..
              "boundary|1|cliff|0|1|16|32|70|0,0;32,0\\n"..
              "site|0|resources|Metal cluster|64|64|31|-1|Resource location|Terrain-derived\\n"..
              "passage|0|1|32|32,32;64,32\\n"..
              "cells|0*16\\nground|3*12;6*4\\naccess|31*12;16*4\\nend|1\\n"
            VFS={RAW=1,FileExists=function() return true end,LoadFile=function() return fixture end}
            io={open=function() return {read=function() return fixture end,close=function() end} end}
        ''')
        source = (ROOT / 'tools/widgets/gui_barb_team_link.lua').read_text(encoding='utf-8')
        self.lua.execute('assert(loadstring(...))', source)
        chunk = source.split('local field = (function()', 1)[1].split('-- Strategic landmarks', 1)[0]
        # The trailing separator is a comment; evaluate the module in isolation.
        self.chunk = 'return (function()' + chunk
        self.api = self.lua.execute(self.chunk)
        self.api.SetMode(True)
        self.ready()

    def ready(self):
        for _ in range(1000):
            self.api.Update()
            if self.api.Snapshot()['ready']:
                break
        self.assertTrue(self.api.Snapshot()['ready'], self.api.Status())
        self.assertNotIn('failed', self.api.Status())

    def ids(self):
        return [v['id'] for _,v in self.api.Snapshot()['features'].items()]

    def configure(self, **values):
        data=self.api.GetConfig()
        for k,v in values.items(): data[k]=v
        self.api.Config(data)
        self.ready()

    def test_no_seam_fallback_and_debug_is_explicit(self):
        self.assertNotIn('boundary:0',self.ids())
        self.assertIn('boundary:1',self.ids())
        self.configure(debug=True)
        self.assertIn('boundary:0',self.ids())
        self.configure(debug=False)
        self.assertNotIn('boundary:0',self.ids())

    def test_views_and_movement(self):
        self.configure(view='approaches')
        self.assertIn('passage:0',self.ids())
        self.configure(primary=5)
        self.assertNotIn('passage:0',self.ids())
        self.configure(view='positions',primary=0)
        self.assertIn('site:0',self.ids())
        self.configure(primary=5)
        self.assertNotIn('site:0',self.ids())

    def test_selection_camera_and_roster_cannot_change_features(self):
        before=self.ids()
        self.api.SetAllyProvider(self.lua.eval('function() error("roster query forbidden") end'))
        self.lua.execute('Spring.GetCameraPosition=function() return 0,50000,0 end')
        for _ in range(3):
            self.api.DrawWorld();self.api.DrawScreen();self.api.Update()
        self.assertEqual(before,self.ids())

    def test_migration_persistence_and_invalid_values(self):
        self.api.Config(self.lua.table_from({'detail':'auto','blueprint':True}))
        self.ready()
        conf=self.api.GetConfig()
        self.assertEqual(conf['detail'],'essential');self.assertFalse(conf['debug'])
        self.assertEqual(conf['background'],'off');self.assertIsNotNone(conf['legacyConfig'])
        self.configure(primary=3,compare=3,side=99)
        conf=self.api.GetConfig();self.assertEqual(conf['compare'],-1);self.assertEqual(conf['side'],-1)
        self.configure(primary=999,opacity=-1)
        self.assertEqual(self.api.GetConfig()['primary'],3)
        self.assertEqual(self.api.GetConfig()['opacity'],0.1)

    def test_input_is_only_captured_in_inspect(self):
        self.assertFalse(self.api.MousePress(1000,800,1))
        self.configure(inspect=True)
        self.assertTrue(self.api.MousePress(1000,800,1))
        self.configure(inspect=False)
        self.assertFalse(self.api.MousePress(1000,800,1))

    def test_never_reads_stale_vfs_fallback(self):
        self.lua.execute('io.open=function() return nil end; VFS.LoadFile=function() error("stale VFS fallback") end')
        self.api=self.lua.execute(self.chunk);self.api.SetMode(True)
        for _ in range(100): self.api.Update()
        self.assertFalse(self.api.Snapshot()['loaded'])

    def test_truncated_grid_is_not_published(self):
        self.lua.execute('fixture=string.gsub(fixture,"access|31%*12;16%*4","access|31*2")')
        self.api=self.lua.execute(self.chunk);self.api.SetMode(True)
        for _ in range(100): self.api.Update()
        self.assertFalse(self.api.Snapshot()['loaded'])

    def test_different_map_version_is_rejected(self):
        self.lua.execute('Game.mapName="Fixture v2"')
        self.api=self.lua.execute(self.chunk);self.api.SetMode(True)
        for _ in range(100): self.api.Update()
        self.assertFalse(self.api.Snapshot()['loaded'])

    def test_essential_coastal_sites_are_spread_and_named(self):
        self.lua.execute('''
          fixture=string.gsub(fixture,"end|1", "theatre|1|pond|North Pond|4|16|16|0|0,0;32,0;32,32;0,32\\n"..
            "site|1|coastal_access|Beach access|16|16|31|-1|Sea 1 to land region 0; initial transition|Terrain-derived\\n"..
            "site|2|coastal_access|Beach access|17|16|31|-1|Sea 1 to land region 0; initial transition|Terrain-derived\\n"..
            "site|3|coastal_access|Beach access|64|64|31|-1|Sea 1 to land region 0; initial transition|Terrain-derived\\nend|1")
        ''')
        self.api=self.lua.execute(self.chunk);self.api.SetMode(True);self.ready()
        self.configure(view='positions')
        self.assertIn('site:1',self.ids());self.assertNotIn('site:2',self.ids())
        self.assertIn('site:3',self.ids())
        f=next(v for _,v in self.api.Snapshot()['features'].items() if v['id']=='site:1')
        self.assertEqual(f['name'],'North Pond access')
        self.assertIn('Central Land',f['reason'])
        self.configure(detail='detailed')
        self.assertIn('site:2',self.ids())

    def test_truncated_ground_is_not_published(self):
        self.lua.execute('fixture=string.gsub(fixture,"ground|3%*12;6%*4","ground|3*2")')
        self.api=self.lua.execute(self.chunk);self.api.SetMode(True)
        for _ in range(100): self.api.Update()
        self.assertFalse(self.api.Snapshot()['loaded'])

    def test_large_rle_records_yield_without_partial_publication(self):
        self.lua.execute('''
          Game.mapSizeX=1024;Game.mapSizeZ=1024
          fixture="barbfield|1|Fixture|32|32|32|1|0|123\\nexperience|2|initial-map\\n"..
            "cells|"..string.rep("0*1;",1024).."\\nground|"..string.rep("3*1;",1024)..
            "\\naccess|"..string.rep("31*1;",1024).."\\nend|1\\n"
        ''')
        self.api=self.lua.execute(self.chunk);self.api.SetMode(True)
        for _ in range(5): self.api.Update()
        self.assertFalse(self.api.Snapshot()['loaded'])
        self.ready()
        self.assertTrue(self.api.Snapshot()['loaded'])

    def test_feature_picker_and_preset_controls(self):
        self.configure(view='positions',inspect=True)
        self.api.DrawScreen()
        r=self.api.ButtonRect('feature')
        x,y=(r[1]+r[3])/2,(r[2]+r[4])/2
        self.api.MousePress(x,y,1);self.api.MouseRelease(x,y,1);self.api.DrawScreen()
        r=self.api.ButtonRect('menu_1')
        self.assertIsNotNone(r)
        x,y=(r[1]+r[3])/2,(r[2]+r[4])/2
        self.api.MousePress(x,y,1);self.api.MouseRelease(x,y,1);self.api.DrawScreen()
        def click(name):
            self.api.DrawScreen()
            r=self.api.ButtonRect(name);self.assertIsNotNone(r,name)
            x,y=(r[1]+r[3])/2,(r[2]+r[4])/2
            self.api.MousePress(x,y,1);self.api.MouseRelease(x,y,1)
        click('savePreset')
        self.assertIsNotNone(self.api.GetConfig()['presets']['Saved 1'])
        click('view_approaches');self.ready()
        click('preset');click('menu_4');self.ready()
        self.assertEqual(self.api.GetConfig()['view'],'positions')
        saved=self.api.GetConfig()
        self.api=self.lua.execute(self.chunk);self.api.Config(saved);self.ready()
        self.assertEqual(self.api.GetConfig()['preset'],'Saved 1')

    def test_resized_panel_keeps_controls_and_reset_reachable(self):
        self.configure(view='positions',inspect=True,advanced=True,debug=True,
                       debugCandidates=True,debugIds=True)
        before=self.ids()
        self.lua.execute('gl.GetViewSizes=function() return 400,360 end')
        self.api.DrawScreen()
        for name in ['view_terrain','movement','feature','resetAll','debugIds']:
            r=self.api.ButtonRect(name);self.assertIsNotNone(r,name)
            self.assertGreaterEqual(r[1],0);self.assertGreaterEqual(r[2],0)
            self.assertLessEqual(r[3],400);self.assertLessEqual(r[4],360)
        self.assertEqual(before,self.ids())
        r=self.api.ButtonRect('resetAll')
        x,y=(r[1]+r[3])/2,(r[2]+r[4])/2
        self.api.MousePress(x,y,1);self.api.MouseRelease(x,y,1);self.ready()
        conf=self.api.GetConfig()
        for key in ['inspect','advanced','debug','debugCandidates','debugIds']:
            self.assertFalse(conf[key],key)
        self.assertEqual(conf['view'],'terrain')

if __name__=='__main__': unittest.main()
