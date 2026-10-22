"""Evidence must distinguish an empty queue, a stalled product and a new hull."""
import tempfile
import unittest
from pathlib import Path
from analyze_sea_recovery import analyze


class RecoveryEvidenceTests(unittest.TestCase):
    def test_progress_and_partial_logs_are_not_empty_queue_failures(self):
        prefix = '[SeaRecoveryTest] yard team=0 id=3 name=armsy tier=1 produced=1 '
        lines = [
            prefix+'frame=300 product=7 progress=0.4 emptySeconds=0',
            prefix+'frame=600 product=7 progress=0.4 emptySeconds=0',
            prefix+'frame=900 product=8 progress=0.1 emptySeconds=0',
            prefix+'frame=1200 product=nil progress=0 emptySeconds=19',
            '[SeaRecoveryTest] idle-end factory=3 seconds=22',
            '[SeaRecoveryTest] yard frame=1300 team=0',
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'infolog.txt'
            path.write_text('\n'.join(lines))
            result = analyze(path)
        self.assertEqual(result['factory_samples'], 4)
        self.assertEqual(len(result['no_progress_samples']), 1)
        self.assertEqual(len(result['empty_at_least_15_seconds']), 1)
        self.assertEqual(result['longest_completed_empty_interval'], 22)
        self.assertEqual(len(result['incomplete_factory_records']), 1)


if __name__ == '__main__': unittest.main()
