import unittest
from run_heavy_rush import batch_evidence, delivery_evidence


class HeavyBatchEvidence(unittest.TestCase):
    def events(self, counts, target):
        return '\n'.join(f'S:0:T:0: [TECH][HeavyRush] completed {count}/{target}' for count in counts)

    def test_inclusive_default_targets(self):
        for target in (3, 4, 5):
            result = batch_evidence(self.events(range(1, target + 1), target))
            self.assertTrue(result['batch_complete'])
            self.assertEqual(result['batch_target'], target)

    def test_incomplete_duplicate_and_overshoot_are_not_complete(self):
        for counts in ([], [1, 2], [1, 2, 2, 3], [1, 2, 3, 4], [3]):
            self.assertFalse(batch_evidence(self.events(counts, 3))['batch_complete'])

    def test_changing_target_or_other_team_cannot_complete_batch(self):
        log = self.events([1, 2], 3) + '\n' + self.events([3], 4)
        self.assertFalse(batch_evidence(log)['batch_complete'])
        self.assertFalse(batch_evidence(self.events([1, 2, 3], 3).replace('T:0:', 'T:1:'))['batch_complete'])


class HeavyDeliveryEvidence(unittest.TestCase):
    def test_counts_only_ordered_team_zero_flight_and_gift(self):
        log = '\n'.join([
            '[HeavyRushTest] finished team=0 id=7',
            '[HeavyRushTest] finished team=5 id=8',
            '[HeavyRushTest] loaded id=7 carrier=1',
            '[HeavyRushTest] loaded id=8 carrier=2',
            '[HeavyRushTest] unloaded id=7 carrier=1',
            '[HeavyRushTest] unloaded id=8 carrier=2',
            '[HeavyRushTest] given id=7 from=0 to=2',
            '[HeavyRushTest] given id=8 from=5 to=7',
        ])
        self.assertEqual(delivery_evidence(log), dict(loaded=1, unloaded=1, flown_and_donated=[7]))

    def test_ground_gift_or_missing_unload_is_not_a_completed_flight(self):
        log = '\n'.join([
            '[HeavyRushTest] finished team=0 id=7',
            '[HeavyRushTest] unloaded id=7 carrier=1',
            '[HeavyRushTest] loaded id=7 carrier=1',
            '[HeavyRushTest] given id=7 from=0 to=2',
        ])
        self.assertEqual(delivery_evidence(log)['flown_and_donated'], [])


if __name__ == '__main__':
    unittest.main()
