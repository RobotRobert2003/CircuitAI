import tempfile
import unittest
from pathlib import Path

from analyze_sea import analyze


class SeaScorecardTest(unittest.TestCase):
    def score(self, text):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'infolog.txt'
            path.write_text(text, encoding='utf-8')
            return analyze(path)

    def test_eliminated_team_is_not_a_late_economy_checkpoint(self):
        score = self.score('''[SeaWatch] finished frame=900 id=1 def=armsy builder=2
[SeaWatch] egress id=3 yard=1 seconds=9.0 worker=false
[SeaWatch] sample frame=9000 metal=50.0/1000.0 income=40.0 use=39.0 energy=90.0/2000.0 income=800.0 use=700.0 yards=1 busy=1 bp=500.0 idle=0.0 units=armsy:1,armcs:2
[SeaWatch] sample frame=18000 metal=500.0/500.0 income=0.0 use=0.0 energy=500.0/500.0 income=0.0 use=0.0 yards=0 busy=0 bp=0.0 idle=0.0 units=
''')
        self.assertEqual(score['survival']['first_empty_minute'], 10)
        self.assertEqual(score['checkpoints']['10']['status'], 'eliminated_or_no_owned_units')
        self.assertNotIn('metal_income', score['checkpoints']['10'])
        self.assertEqual(score['checkpoints']['5']['metal_income'], 40)
        self.assertEqual(score['milestones_minutes']['t1_yard'], .5)
        self.assertEqual(score['egress']['departures'], 1)

    def test_compile_only_log_cannot_pass_physical_opening(self):
        score = self.score('Loaded script\n')
        self.assertEqual(len(score['failures']), 2)
        self.assertEqual(score['survival']['status'], 'unobserved')

    def test_mex_remnants_do_not_count_as_an_operational_base(self):
        score=self.score('[SeaWatch] sample frame=54000 metal=100.0/500.0 income=0.0 use=0.0 energy=0.0/500.0 income=0.0 use=0.0 yards=0 busy=0 bp=0.0 idle=0.0 units=armmex:13\n')
        self.assertEqual(score['survival']['status'],'remnants_without_build_power')
        self.assertFalse(score['survival']['operational_at_last_sample'])

    def test_runtime_violation_is_not_hidden_by_ship_egress(self):
        score = self.score('[SeaWatch] finished frame=1800 def=corsy\n'
                           '[SeaWatch] egress id=3 yard=1 seconds=10\n'
                           '[INVARIANT] INV-130\n')
        self.assertEqual(score['runtime_violations'], 1)
        self.assertIn('Runtime errors/invariants present', score['failures'])


if __name__ == '__main__':
    unittest.main()
