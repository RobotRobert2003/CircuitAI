import json
import tempfile
import unittest
from pathlib import Path
from fortress_report import measure


class FortressEvidenceTests(unittest.TestCase):
    def evidence(self, extra='', role='FRONT', target='corgol', victim_team=1, aa=False):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            groups = [{'team':1, 'unit':target}]
            if aa:
                groups.append({'team':1, 'unit':'armfig'})
            (path/'ranged-arena.json').write_text(json.dumps({'name':'test', 'unit':'legfort',
                'role':role, 'variant':'ranged', 'minutes':2, 'groups':groups}))
            (path/'infolog.txt').write_text(
                '[RangedArena] frame=300 spawn id=1 unit=legfort team=0\n'
                f'[RangedArena] frame=300 spawn id=2 unit={target} team={victim_team}\n'
                '[RangedArena] frame=300 spawn id=3 unit=armflea team=1\n'
                f'[RangedArena] frame=400 damage id=2 team={victim_team} amount=1200 attacker=1 weapon=947\n'+extra)
            return measure(path)

    def test_priority_evidence_must_prefer_heavy(self):
        good = self.evidence('[RangedArena] frame=450 unit id=1 unit=legfort target=2\n')
        bait = self.evidence('[RangedArena] frame=450 unit id=1 unit=legfort target=3\n')
        self.assertTrue(good['passed'])
        self.assertFalse(bait['passed'])

    def test_direct_defense_attack_does_not_need_priority_rules_param(self):
        result = self.evidence('[f=0000350] [AIR][BaseResponse] group=3 target=2\n'
            '[f=0000360] [AIR][BaseResponse] dispatched=1 total=1\n'
            '[RangedArena] frame=450 unit id=1 unit=legfort target=-1\n', role='AIR')
        self.assertTrue(result['passed'])

    def test_friendly_damage_is_not_enemy_engagement(self):
        self.assertFalse(self.evidence(target='legfort', victim_team=0)['passed'])

    def test_air_control_requires_actual_anti_air_damage(self):
        result = self.evidence('[RangedArena] frame=450 unit id=1 unit=legfort target=2\n', aa=True)
        self.assertFalse(result['criteria']['anti_air_damage'])

    def test_post_cutoff_assignment_cannot_rescue_failure(self):
        result = self.evidence('[f=0003601] [AIR][BaseResponse] group=3 target=2\n'
            '[f=0003601] [AIR][BaseResponse] dispatched=1 total=1\n', role='AIR')
        self.assertFalse(result['passed'])


if __name__ == '__main__':
    unittest.main()
