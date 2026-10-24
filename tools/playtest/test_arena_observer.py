"""Actual Lua callback dispatch across legacy handlers and BAR widget proxies."""
import unittest
from test_lane_ui_memory import ROOT, LuaRuntime


class ArenaObserverTests(unittest.TestCase):
    def observer(self, legacy=False):
        lua=LuaRuntime()
        lua.execute('''
            widget={}; lines={}; priorCalls=0; updates=0
            cfg={name="smoke",variant="ranged",natural=true,unit="armcom",headless=true}
            VFS={Include=function() return cfg end}
            Spring={Echo=function(s) lines[#lines+1]=s end,
                GetGameFrame=function() return 600 end,
                GetUnitPosition=function() return 100,0,100 end,
                GetUnitLastAttacker=function() return 1 end,
                GetUnitDefID=function(id) return id end,
                GetUnitTeam=function(id) return id-1 end,
                GetUnitRulesParam=function() return nil end}
            UnitDefs={[1]={name="armcom"},[2]={name="enemy"}}
            WeaponDefs={[7]={name="disintegrator"}}
            widgetHandler={UpdateCallIn=function() error("proxy must not be mutated") end}
        ''')
        if legacy:
            lua.execute('''
                widgetHandler.UnitDamagedList={widget}
                original=function(self,id,def,team,damage,paralyzer)
                    priorCalls=priorCalls+1
                    widget:UnitDamaged(id,def,team,damage,paralyzer)
                end
                widgetHandler.UnitDamaged=original
                widgetHandler.UpdateCallIn=function() updates=updates+1 end
            ''')
        lua.execute((ROOT/'tools/playtest/widgets/ranged_arena.lua').read_text())
        lua.execute('widget:Initialize(); widget:UnitCreated(1,1,0)')
        return lua

    def test_proxy_keeps_public_damage_and_command_callbacks(self):
        lua=self.observer()
        lua.execute('''
            widget:UnitDamaged(2,2,1,100,false)
            widget:UnitCommand(1,1,0,34923,{2},{},0,0,false,false)
            widget:Shutdown()
            assert(widgetHandler.UnitDamaged==nil)
        ''')
        lines=list(lua.globals().lines.values())
        damage=[s for s in lines if 'damage id=' in s]
        self.assertEqual(len(damage),1)
        self.assertIn('attacker=1',damage[0])
        self.assertIn('weaponName=unknown',damage[0])
        self.assertEqual(sum('priority id=' in s for s in lines),1)

    def test_legacy_preserves_full_attribution_once_and_restores_owner(self):
        lua=self.observer(True)
        lua.execute('''
            widgetHandler:UnitDamaged(2,2,1,100,false,7,99,1,1,0)
            widget:Shutdown()
            assert(widgetHandler.UnitDamaged==original)
            assert(priorCalls==1 and updates==2)
        ''')
        damage=[s for s in lua.globals().lines.values() if 'damage id=' in s]
        self.assertEqual(len(damage),1)
        self.assertIn('weaponName=disintegrator',damage[0])

    def test_coverage_deaths_exclude_observer_but_keep_ai_commanders(self):
        lua=self.observer()
        lua.execute('''
            cfg.coverage_probe=true; cfg.starts={{100,100},{900,900}}
            UnitDefs[1].customParams={iscommander=true}
            widget:UnitDestroyed(99,1,2)
            widget:UnitDestroyed(98,1,0)
            widget:UnitDestroyed(97,1,1)
        ''')
        deaths=[s for s in lua.globals().lines.values() if 'coverage_commander_lost' in s]
        self.assertEqual(len(deaths),2)
        self.assertTrue(any('team=0' in s for s in deaths))
        self.assertTrue(any('team=1' in s for s in deaths))

    def test_shutdown_does_not_replace_a_new_handler_owner(self):
        lua=self.observer(True)
        lua.execute('''
            newer=function() end
            widgetHandler.UnitDamaged=newer
            widget:Shutdown()
            assert(widgetHandler.UnitDamaged==newer and updates==1)
        ''')

    def test_relative_wave_uses_current_position_and_requires_wait(self):
        for command in (5, 10):
            with self.subTest(command=command):
                lua=self.observer()
                lua.globals().anchorCommand=command
                lua.execute('''
                    cfg.groups={{unit="enemy",team=1,count=1,position={0,0},after_seconds=450,
                        relative_to={unit="armcom",team=0,offset={-180,0},max_distance=220,require_command=5}}}
                    UnitDefNames={enemy={id=2}}
                    UnitDefs[2].speed=30;UnitDefs[2].canMove=true
                    Spring.GetUnitPosition=function() return 4200,0,2600 end
                    Spring.GetUnitCurrentCommand=function() return anchorCommand end
                    Spring.GetGroundHeight=function() return 0 end
                    Spring.TestMoveOrder=function() return true end
                    sent={};Spring.SendCommands=function(s) sent[#sent+1]=s end
                    widget:GameFrame(13503)
                ''')
                sent=list(lua.globals().sent.values())
                if command==5:
                    self.assertEqual(sent,['give 1 enemy 1 @4020,0,2600'])
                else:
                    self.assertEqual(sent,[])
                    self.assertTrue(any('ERROR spawn_anchor_command' in s for s in lua.globals().lines.values()))

    def test_relative_wave_rejects_terrain_adjustment_outside_shot_range(self):
        lua=self.observer()
        lua.execute('''
            cfg.groups={{unit="enemy",team=1,count=1,position={0,0},after_seconds=450,
                relative_to={unit="armcom",team=0,offset={-180,0},max_distance=220,require_command=5}}}
            UnitDefNames={enemy={id=2}};UnitDefs[2].speed=30;UnitDefs[2].canMove=true
            Spring.GetUnitPosition=function() return 4200,0,2600 end
            Spring.GetUnitCurrentCommand=function() return 5 end
            Spring.GetGroundHeight=function() return 0 end
            Spring.TestMoveOrder=function(_,x,_,z) return (x-4200)^2+(z-2600)^2>220^2 end
            sent={};Spring.SendCommands=function(s) sent[#sent+1]=s end
            widget:GameFrame(13503)
        ''')
        self.assertEqual(list(lua.globals().sent.values()),[])
        self.assertTrue(any('ERROR unbuildable_spawn' in s for s in lua.globals().lines.values()))


if __name__=='__main__':unittest.main()
