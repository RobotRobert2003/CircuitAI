"""Run the actual Lua 5.1 relay against allied/human command observations."""
import unittest
from test_lane_ui_memory import ROOT, LuaRuntime

class ResurrectionRelayTests(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime()
        self.lua.execute('''
            widget={}; CMD={RESURRECT=125}; UnitDefs={[1]={canResurrect=true}};
            messages={}; current={id=125,params={32775}}; owner=1
            Spring={GetAllUnits=function() return {10} end, GetUnitDefID=function() return 1 end,
              GetTeamList=function() return {0,1,2,3} end,
              GetTeamInfo=function(t) return t,0,false,t~=1 end,
              GetAIInfo=function(t) return t,'AI',t==3 and 2 or 0 end,
              GetMyPlayerID=function() return 0 end, GetUnitTeam=function() return owner end,
              AreTeamsAllied=function(a,b) return a<2 and b<2 or a==b end,
              GetUnitCommands=function() return current and {current} or {} end,
              SendSkirmishAIMessage=function(team,msg) messages[#messages+1]={team,msg} end}
        ''')
        self.lua.execute((ROOT/'tools/widgets/gui_barb_resurrection_claims.lua').read_text())
        self.lua.execute('widget:Initialize()')

    def test_human_ally_only_and_stop_release(self):
        self.lua.execute('widget:GameFrame(30)')
        self.assertEqual(self.lua.eval('#messages'),1)
        self.assertEqual(self.lua.eval('messages[1][1]'),0)
        self.assertEqual(self.lua.eval('messages[1][2]'),'barb-resurrection 10 1 32775')
        self.lua.execute('current=nil;widget:GameFrame(60)')
        self.assertEqual(self.lua.eval('messages[2][2]'),'barb-resurrection 10 0')
        self.lua.execute('widget:GameFrame(90)')
        self.assertEqual(self.lua.eval('#messages'),2)

    def test_converted_area_and_destroy(self):
        self.lua.execute('current.params={32775,100,0,100,500};widget:GameFrame(30)')
        self.assertEqual(self.lua.eval('messages[1][2]'),'barb-resurrection 10 5 32775 100 0 100 500')
        self.lua.execute('widget:UnitDestroyed(10);widget:GameFrame(60)')
        self.assertEqual(self.lua.eval('messages[2][2]'),'barb-resurrection 10 0')

if __name__=='__main__':unittest.main()
