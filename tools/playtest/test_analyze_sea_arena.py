import tempfile,unittest
from pathlib import Path
from analyze_sea_arena import analyze

class SeaArenaEvidence(unittest.TestCase):
    def test_truncated_log_tail_is_reported_without_inventing_damage(self):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'infolog.txt';p.write_text('[SeaArena] frame=7562 damage victim=1')
            r=analyze(p)
        self.assertEqual(r['raw_weapon_damage_by_team'],[0,0])
        self.assertEqual(len(r['fixture_errors']),1)
        self.assertIn('Incomplete SeaArena damage',r['fixture_errors'][0])

    def test_credit_latency_and_errors_remain_distinct(self):
        text='''[SeaArena] frame=300 spawn id=1 team=0 unit=armroy
[SeaArena] frame=301 spawn id=2 team=1 unit=corsub
[SeaArena] frame=330 detected id=2 unit=corsub
[SeaArena] frame=360 attack id=1 target=2 def=armroy
[SeaArena] frame=370 damage victim=2 attacker=1 team=0 amount=200
[SeaArena] frame=390 death id=2 team=1 cost=600 attackerTeam=0
[SeaArena] frame=1800 orders team=0 apm=40 repeated=3
[SeaArena] frame=1800 sample live0=880 live1=0
[SeaArena] frame=1801 ERROR dry_site=armsy
'''
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'infolog.txt';p.write_text(text);r=analyze(p)
        self.assertEqual(r['metal_lost_by_team'],[0,600])
        self.assertEqual(r['last_hit_kill_metal_by_team'],[600,0])
        self.assertEqual(r['raw_weapon_damage_by_team'],[200,0])
        self.assertEqual(r['median_detection_to_order'],1)
        self.assertEqual(r['peak_apm_by_team'],[40,0])
        self.assertEqual(len(r['fixture_errors']),1)
    def test_production_start_is_not_completion(self):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'infolog.txt';p.write_text('[SeaArena] frame=400 produced id=3 team=0 unit=armsub\n')
            r=analyze(p)
        self.assertEqual(len(r['produced']),1)
        self.assertEqual(r['finished'],[])
        self.assertIsNone(r['median_detection_to_order'])

    def test_gadget_orders_and_child_loss_have_separate_evidence(self):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'infolog.txt';p.write_text('''[SeaArena] frame=300 child id=3 team=0 unit=legdrone host=2
[SeaArena] frame=360 carrier_owner id=3 host=-1
[SeaArena] frame=1800 order_sources team=0 sources=lua:200,nonlua:30,legdrone_lua:200
[SeaArena] frame=1900 death id=3 team=0 cost=15 attackerTeam=1
''')
            r=analyze(p)
        self.assertEqual(r['order_sources'][0]['nonlua'],30)
        self.assertEqual(r['carrier_ownership'][0]['host'],'-1')
        self.assertEqual(r['metal_lost_by_team'],[15,0])

if __name__=='__main__':unittest.main()
