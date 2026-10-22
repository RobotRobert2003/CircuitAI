import json
from pathlib import Path
import tempfile
import unittest

from sea_conversion_report import parse_sample, summarize


class ConversionEvidenceTests(unittest.TestCase):
    def test_parses_completed_and_framed_units_separately(self):
        row = parse_sample('[SeaConversion] sample frame=900 team=0 m=100 ms=1000 mi=50 mu=40 '
                           'e=1000 es=1000 ei=2000 eu=1100 capacity=700 converted=700 '
                           'units=armfmkr:10 frames=armuwfus:1')
        self.assertEqual(row['units'], {'armfmkr': 10})
        self.assertEqual(row['frames'], {'armuwfus': 1})
        self.assertIsNone(parse_sample('not an economy sample'))

    def test_frames_and_other_roles_cannot_claim_fusion_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'teams.json').write_text(json.dumps({'teams': [
                {'team': 0, 'role': 'SEA', 'side': 'armada'},
                {'team': 1, 'role': 'TECH', 'side': 'cortex'}]}))
            prefix = '[SeaConversion] sample frame=36000 team={team} m=100 ms=1000 mi=50 mu=40 e=1000 es=1000 ei=2000 eu=1100 capacity=700 converted=700 '
            (root / 'infolog.txt').write_text(prefix.format(team=0) + 'units=armfmkr:10 frames=armuwfus:1\n'
                + prefix.format(team=1) + 'units=coruwfus:1 frames=\n'
                + '[INVARIANT] INV-013 existing failure\n')
            result = summarize(root)
            self.assertEqual(len(result['teams']), 1)
            self.assertIsNone(result['teams'][0]['first_fusion_minute'])
            self.assertEqual(result['teams'][0]['late_full_bank_unserved_mean'], 900)
            self.assertEqual(result['invariants'], ['INV-013 existing failure'])


if __name__ == '__main__':
    unittest.main()
