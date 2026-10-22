"""Actual Lua callback dispatch across legacy handlers and BAR widget proxies."""
import unittest
from test_lane_ui_memory import ROOT, LuaRuntime


class ArenaObserverTests(unittest.TestCase):
    def observer(self, legacy=False):
        lua=LuaRuntime()
        lua.execute('''
            widget={}; lines={}; priorCalls=0; updates=0
            cfg={name="smoke",variant="ranged",natural=true,unit="armcom"}
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

    def test_shutdown_does_not_replace_a_new_handler_owner(self):
        lua=self.observer(True)
        lua.execute('''
            newer=function() end
            widgetHandler.UnitDamaged=newer
            widget:Shutdown()
            assert(widgetHandler.UnitDamaged==newer and updates==1)
        ''')


if __name__=='__main__':unittest.main()
