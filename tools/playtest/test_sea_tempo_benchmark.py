import unittest
from sea_tempo_benchmark import summarize, audit


class EvidenceTests(unittest.TestCase):
    def test_truncated_failed_fixture_record_is_preserved(self):
        s=summarize('[f=0000987] [SeaArena] frame=987 damage victim')
        self.assertEqual(len(s['failures']),1)
        self.assertFalse(s['reported_damage'])
    def test_enemy_friendly_fire_is_not_friendly_objective_damage(self):
        s=summarize('''[f=0000300] [SeaArena] frame=300 spawn id=2 team=1 unit=corsy
[f=0000600] [SeaArena] frame=600 damage victim=2 attacker=3 team=1 amount=100
[f=0000900] [SeaArena] frame=900 death id=2 team=1 cost=450''')
        self.assertIsNone(s['objectives']['2']['first_hit'])
        self.assertEqual(len(audit(s,dict(destroyed_units={'corsy':1}))),1)
    def test_smoke_damage_does_not_satisfy_a_destroyed_objective(self):
        summary=dict(survivors={'0':{'armroy':8}}, objectives={'2':dict(unit='corsy',destroyed=None)})
        self.assertEqual(len(audit(summary,dict(minimum_survivors={'armroy':8},destroyed_units={'corsy':1}))),1)

    def test_kill_does_not_hide_unacceptable_friendly_losses(self):
        summary=dict(survivors={'0':{'armpship':1}}, objectives={'2':dict(unit='corroy',first_hit=20,destroyed=30)})
        self.assertEqual(len(audit(summary,dict(minimum_survivors={'armpship':2},destroyed_units={'corroy':1}))),1)

    def test_fixture_or_game_rule_removal_is_not_an_attack_kill(self):
        summary=dict(survivors={'0':{}},objectives={'2':dict(unit='armmex',first_hit=None,destroyed=16)})
        self.assertEqual(len(audit(summary,dict(destroyed_units={'armmex':1}))),1)

    def test_engine_timestamp_is_not_a_performance_value(self):
        s = summarize('[t=00:00:47.936541][f=0001800] [WorkforcePerf] frame=1800 samples=1799 ai_all_p95_ms=0.125')
        self.assertEqual(s['ai_all_teams_timing_windows'][0]['ai_all_p95_ms'], .125)

    def test_loss_is_not_inferred_from_lost_sight_or_damage(self):
        s = summarize('''[f=0000300] [SeaArena] frame=300 spawn id=1 team=0 unit=armroy
[f=0000301] [SeaArena] frame=301 spawn id=2 team=1 unit=corsy
[f=0000600] [SeaArena] frame=600 damage victim=2 attacker=1 team=0 amount=100
[f=0000700] [SeaArena] frame=700 objective id=2 los=false health=200''')
        self.assertEqual(s['survivors']['1']['corsy'], 1)
        self.assertIsNone(s['objectives']['2']['destroyed'])
        self.assertEqual(s['objectives']['2']['first_hit'], 20)

    def test_observed_death_and_failure_are_retained(self):
        s = summarize('''[f=0000300] [SeaArena] frame=300 spawn id=1 team=0 unit=armroy
[f=0000600] [SeaArena] frame=600 death id=1 team=0 cost=960
[f=0001800] [SeaArena] frame=1800 orders team=0 apm=100 repeated=2
[f=0001801] [INVARIANT] INV-171''')
        self.assertEqual(s['losses_metal']['0'], 960)
        self.assertFalse(s['survivors']['0'])
        self.assertEqual(s['engine_commands_full_minute_windows']['0'], 100)
        self.assertEqual(len(s['failures']), 1)


if __name__ == '__main__':
    unittest.main()
