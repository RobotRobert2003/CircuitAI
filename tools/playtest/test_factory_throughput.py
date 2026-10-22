import tempfile
import unittest
from pathlib import Path
from analyze_factory_throughput import analyze


class ThroughputTests(unittest.TestCase):
    def test_window_and_parent_accounting(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root)/'infolog.txt'
            path.write_text('\n'.join([
                '[RangedArena] frame=2600 child id=21 parent=10 unit=armhawk',
                '[RangedArena] frame=2700 finished id=21 team=0 unit=armhawk cost=150',
                '[RangedArena] frame=2700 factory_order id=10 product=132 source=false',
                '[RangedArena] frame=2700 factory_order id=10 product=132 source=true',
                '[RangedArena] frame=5400 throughput id=10 samples=2701 empty=7 fundedEmpty=3 building=2600 metal=99 energy=999',
                '[RangedArena] frame=5401 finished id=21 team=0 unit=armhawk cost=150',
                '[RangedArena] frame=6300 throughput id=10 samples=3601 empty=9 fundedEmpty=5 building=3300 metal=99 energy=999',
            ]))
            result = analyze(path)
            self.assertEqual(result['completed'], 1)
            self.assertEqual(result['build_commands'], 1)
            self.assertEqual(result['funded_empty_fraction'], 3/2701)
            self.assertEqual(result['factories']['10']['building'], 2600)

    def test_missing_samples_are_not_zero_idle_proof(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root)/'infolog.txt'
            path.write_text('[RangedArena] frame=0 loaded\n')
            self.assertIsNone(analyze(path)['funded_empty_fraction'])


if __name__ == '__main__':
    unittest.main()
