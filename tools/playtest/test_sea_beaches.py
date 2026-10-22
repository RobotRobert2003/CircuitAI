import unittest

from run_sea_beaches import summarize, assess_focus


class BeachCoverageTests(unittest.TestCase):
    def test_unseen_tail_is_included(self):
        text='[SeaBeach] frame=30 site id=1 ally=0 x=64 z=320\n'
        for frame,los in [(150,False),(300,True),(450,False),(600,False),(750,False)]:
            text+=f'[SeaBeach] frame={frame} sample id=1 los={str(los).lower()} scout=false\n'
        site=summarize(text)['1']
        self.assertEqual(site['los_first_seconds'],10)
        self.assertEqual(site['los_max_gap_seconds'],15)
        self.assertIsNone(site['scout_near_first_seconds'])
        self.assertEqual(site['scout_near_max_gap_seconds'],20)

    def test_proximity_is_not_visibility(self):
        text='[SeaBeach] frame=30 site id=1 ally=1 x=64 z=320\n'
        text+='[SeaBeach] frame=150 sample id=1 los=false scout=true\n'
        site=summarize(text)['1']
        self.assertIsNone(site['los_first_seconds'])
        self.assertEqual(site['scout_near_first_seconds'],5)

    def test_no_samples_is_not_zero_gap_success(self):
        site=summarize('[SeaBeach] frame=30 site id=1 ally=0 x=64 z=320')['1']
        self.assertEqual(site['sample_count'],0)
        self.assertIsNone(site['last_seconds'])
        self.assertIsNone(site['los_visible_fraction'])

    def test_missing_or_stale_focus_fails(self):
        self.assertTrue(assess_focus({}))
        site=dict(label='edge',los_first_seconds=120,los_max_gap_after_first_seconds=300,sample_count=100)
        self.assertTrue(assess_focus({'1':site},expected=1))
        site['los_max_gap_after_first_seconds']=90
        self.assertFalse(assess_focus({'1':site},expected=1))


if __name__=='__main__':
    unittest.main()
