import unittest
from sea_arena import audit_retreat


class RetreatEvidenceTest(unittest.TestCase):
    def test_correlates_same_ship_fresh_hint_and_native_endpoint(self):
        text='''[f=000100] [RetreatProbe] waypoint ship=7 anchor=2 x=1000 z=500
[f=000115] [SeaArena] frame=115 move id=7 x=1100 z=500
[f=000120] [RetreatProbe] state ship=7 retreat=true'''
        failures,evidence=audit_retreat(text)
        self.assertEqual([],failures)
        self.assertEqual(100,evidence[0]['endpoint_error'])

    def test_rejects_expired_hint(self):
        text='''[f=000100] [RetreatProbe] waypoint ship=7 anchor=2 x=1000 z=500
[f=001500] [SeaArena] frame=1500 move id=7 x=1000 z=500
[f=001510] [RetreatProbe] state ship=7 retreat=true'''
        self.assertTrue(audit_retreat(text)[0])

    def test_rejects_other_ship_or_unrelated_destination(self):
        for ship,x in ((8,1000),(7,1500)):
            text=f'''[f=000100] [RetreatProbe] waypoint ship=7 anchor=2 x=1000 z=500
[f=000115] [SeaArena] frame=115 move id={ship} x={x} z=500
[f=000120] [RetreatProbe] state ship=7 retreat=true'''
            self.assertTrue(audit_retreat(text)[0])


if __name__=='__main__':unittest.main()
