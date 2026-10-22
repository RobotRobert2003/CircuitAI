import unittest
from performance_fixture_report import analyze


class FixtureAcceptanceTests(unittest.TestCase):
    def test_arrival_does_not_hide_idle_command_storm(self):
        case = dict(unit='armpw', minutes=3, native_route=dict(points=[[0,0],[0,100]], lanes=3, spacing=20, radius=4))
        text = '\n'.join(f'[RangedArena] frame=300 unit id={i} unit=armpw x={x} z=100 hp=370'
                         for i,x in enumerate([0,-20,20]))
        self.assertTrue(analyze(text+'\n[RangedArena] frame=300 unit_command key=armpw:10 count=7',case)['passed'])
        self.assertFalse(analyze(text+'\n[RangedArena] frame=300 unit_command key=armpw:10 count=500',case)['passed'])

    def test_drone_ownership_uses_command_instant_not_final_state(self):
        case = dict(unit='legvcarry', minutes=3, drone_ownership=True)
        text = '\n'.join(['[RangedArena] frame=300 child id=1 host=5',
            '[RangedArena] frame=301 drone_order id=1 host=5 command=10 source=lua',
            '[RangedArena] frame=302 drone_order id=2 host=-1 command=20 source=nonlua'])
        self.assertTrue(analyze(text,case)['passed'])
        self.assertFalse(analyze(text+'\n[RangedArena] frame=305 drone_order id=1 host=5 command=10 source=nonlua',case)['passed'])

    def test_missing_units_or_unobserved_drone_control_fails(self):
        self.assertFalse(analyze('',dict(unit='legvcarry', minutes=3, drone_ownership=True))['passed'])
        case = dict(unit='armpw', minutes=3, native_route=dict(points=[[0,0],[0,100]], lanes=3, spacing=20, radius=4))
        self.assertFalse(analyze('',case)['passed'])


if __name__ == '__main__': unittest.main()
