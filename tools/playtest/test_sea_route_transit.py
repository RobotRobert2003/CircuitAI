import unittest
from sea_arena import audit_transit


class TransitEvidenceTests(unittest.TestCase):
    case={'native_transit':{'unit':'armroy','points':[[0,0],[1000,1000]]},
          'groups':[{'team':0,'unit':'armroy','count':1}]}

    def sample(self,**changes):
        values=dict(frame=3000,id=1,unit='armroy',x=1000,z=1000,health=100,maxhealth=100)
        values.update(changes)
        return '[SeaArena] boat '+' '.join(f'{k}={v}' for k,v in values.items())

    def test_arrival_passes(self):
        self.assertEqual(audit_transit(self.sample(),self.case),[])

    def test_stalled_early_missing_or_damaged_ship_fails(self):
        for text in ('',self.sample(frame=600),self.sample(x=0),self.sample(health=50)):
            with self.subTest(text=text):self.assertTrue(audit_transit(text,self.case))
