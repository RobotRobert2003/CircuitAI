import unittest
import tempfile
from pathlib import Path
from nuke_benchmark import analyze, prepare_trial


class NukeBenchmarkTests(unittest.TestCase):
    def test_storage_dispatch_is_not_completed_reclaim(self):
        log = 'S:0:T:0:F:21000:L::[TECH][NukeRush] refund storage 42 using surplus assistant 2'
        self.assertEqual(analyze(log)['storage_refund_started_seconds'], 700)
        self.assertIsNone(analyze(log)['storage_removed_seconds'])
        self.assertIsNone(analyze(log+'\n[NukeRush] storage-removed team=0 id=43 frame=22200')['storage_removed_seconds'])
        self.assertEqual(analyze(log+'\n[NukeRush] storage-removed team=0 id=42 frame=22200')['storage_removed_seconds'], 740)

    def test_silo_is_not_a_launch(self):
        r = analyze('[NukeRush] silo-finished team=0 id=1 frame=18000')
        self.assertEqual(r['silo_seconds'], 600)
        self.assertFalse(r['timing_pass'])

    def test_enemy_missile_does_not_pass(self):
        self.assertIsNone(analyze('[NukeRush] launch team=1 silo=1 projectile=2 frame=100')['launch_seconds'])

    def test_launch_deadline_and_recovery(self):
        log = '[NukeRush] launch team=0 silo=1 projectile=2 frame=27000\nS:0:T:0:F:1:L::[TECH][NukeRush] silo complete; normal economy resumes'
        self.assertTrue(analyze(log)['pass'])
        self.assertFalse(analyze(log.replace('27000', '27001'))['pass'])
        self.assertFalse(analyze(log.split('\n')[0])['pass'])
        self.assertFalse(analyze(log.replace('S:0:T:0:', 'S:1:T:1:'))['pass'])

    def test_invariant_is_not_hidden_by_fast_launch(self):
        log = '[NukeRush] launch team=0 silo=1 projectile=2 frame=20000\nS:0:T:0:F:1:L::[TECH][NukeRush] silo complete; normal economy resumes\nS:0:T:0:F:123:L::[INVARIANT] INV-004 test'
        self.assertTrue(analyze(log)['timing_pass'])
        self.assertFalse(analyze(log)['pass'])

    def test_stockpile_is_separate_and_first_event_wins(self):
        log = '[f=0024000] [NukeRush] stock team=0 id=1 count=1 queued=9\n[NukeRush] launch team=0 silo=1 projectile=2 frame=25000\n[NukeRush] launch team=0 silo=1 projectile=3 frame=30000'
        self.assertEqual(analyze(log)['ready_seconds'],800)
        self.assertAlmostEqual(analyze(log)['launch_seconds'],25000/30)

    def test_recovery_failures_remain_failures_but_are_attributed(self):
        log = ('[NukeRush] launch team=0 silo=1 projectile=2 frame=25000\n'
               'S:0:T:0:F:20000:L::[TECH][NukeRush] silo complete; normal economy resumes\n'
               'S:0:T:0:F:19000:L::[INVARIANT] INV-008 reclaim\n'
               'S:0:T:0:F:23000:L::[INVARIANT] INV-011 income')
        result = analyze(log)
        self.assertTrue(result['timing_pass'])
        self.assertFalse(result['pass'])
        self.assertEqual(result['opening_invariants'], ['INV-008'])
        self.assertEqual(result['recovery_invariants'], ['INV-011'])

    def test_seed_and_opponent_override_are_staged_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            script = directory / 'script.txt'
            script.write_text('[GAME]\n{\n [AI0] { [OPTIONS] { random_seed=22901; } }\n}', encoding='utf-8')
            chain = directory / 'AI/Skirmish/BARbTest/test/script/src/roles/tech/tech_chain.as'
            chain.parent.mkdir(parents=True)
            chain.write_text('objective = Global::RoleSettings::Tech::RushObjective;', encoding='utf-8')
            prepare_trial(directory, 22901, 'auto')
            self.assertIn('FixedRNGSeed=22901;', script.read_text())
            self.assertIn('random_seed=22901;', script.read_text())
            self.assertIn('if (ai.teamId != 0) objective = "auto";', chain.read_text())


if __name__ == '__main__':
    unittest.main()
