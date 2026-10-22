import unittest
from spam_report import measure


class SpamEvidence(unittest.TestCase):
    def test_repeat_alone_is_not_production(self):
        r=measure('[RangedArena] frame=30 factory id=1 repeat=true builds=1',900)
        self.assertFalse(r['passed'])

    def test_offspring_must_finish_and_move_inside_window(self):
        rows=['[RangedArena] frame=30 factory id=1 repeat=true builds=1']
        for unit in (2,3):
            rows.extend([f'[RangedArena] frame=40 child id={unit} parent=1',
                         f'[RangedArena] frame=50 finished id={unit}',
                         f'[RangedArena] frame=60 unit id={unit} x=0 z=0 command=10',
                         f'[RangedArena] frame=900 unit id={unit} x=0 z=1000 command=10'])
        self.assertFalse(measure('\n'.join(rows),899)['passed'])
        self.assertTrue(measure('\n'.join(rows),900)['passed'])
        self.assertFalse(measure('\n'.join(rows),900,(0,-1))['passed'])
        rows.append('[RangedArena] frame=80 factory id=1 repeat=true builds=2')
        self.assertFalse(measure('\n'.join(rows),900)['passed'])

if __name__=='__main__':unittest.main()
