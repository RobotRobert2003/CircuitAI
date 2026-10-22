"""Focused regressions for arena measurements and scenario input contracts."""
import io
import json
import tempfile
import unittest
from pathlib import Path

from air_arena import resolve_case, lua
from audit_air_arena import analyze


class ArenaTests(unittest.TestCase):
    def audit(self, *records):
        return analyze(io.StringIO('\n'.join('[AirArena] '+r for r in records)+'\n'))

    def test_truncated_last_log_record_does_not_invent_damage(self):
        result = analyze(io.StringIO('[AirArena] event=damage fra'))
        self.assertEqual(result['events']['truncated_record'], 1)

    def test_screenshot_is_linked_to_actual_engine_file(self):
        result = analyze(io.StringIO('[AirArena] event=screenshot frame=100 key=wave1-target\n'
                                    '[f=0000101] [CBitmap::Save] saving "screenshots/screen.png" to "C:/run/screenshots/screen.png"\n'))
        self.assertEqual(result['screenshots'], [{'frame': 100, 'key': 'wave1-target', 'file': 'screen.png'}])

    def test_unfinished_sortie_is_censored_not_failed_or_returned(self):
        result = self.audit('event=launch frame=30 wave=1 target=9 risk=1 ids=1,2 count=2')
        self.assertEqual((result['completed_waves'], result['censored_waves']), (0, 1))
        self.assertIsNone(result['waves'][0]['survivors'])

    def test_overlap_requires_recent_actual_survivors(self):
        result = self.audit(
            'event=launch frame=30 wave=1 target=9 risk=1 ids=1 count=1',
            'event=flight frame=300 alive=1 wave=1',
            'event=launch frame=330 wave=2 target=10 risk=1 ids=2 count=1')
        self.assertEqual(result['observed_overlaps'], [dict(wave=2, launch_frame=330,
            earlier_wave=1, earlier_alive=1, observed_frame=300)])

    def test_dead_or_stale_cohort_is_not_overlap_evidence(self):
        for census in ('event=flight frame=300 alive=0 wave=1',
                       'event=flight frame=100 alive=1 wave=1'):
            result = self.audit('event=launch frame=30 wave=1 target=9 risk=1 ids=1 count=1',
                census, 'event=launch frame=330 wave=2 target=10 risk=1 ids=2 count=1')
            self.assertEqual(result['observed_overlaps'], [])

    def test_shutdown_overrun_cannot_turn_an_unfinished_sortie_into_success(self):
        result = analyze(io.StringIO('[AirArena] event=launch frame=30 wave=1 target=9 risk=1 ids=1 count=1\n'
                                    '[AirArena] event=target_dead frame=1810 wave=1 cost=3350\n'
                                    '[AirArena] event=end frame=1820 wave=1 risk=1 survivors=1 home=1\n'), 1800)
        self.assertEqual(result['waves'][0]['target_metal_destroyed'], 0)
        self.assertEqual(result['censored_waves'], 1)

    def test_detection_to_actual_fighter_hit_and_target_damage(self):
        result = self.audit(
            'event=spawn frame=0 id=5 kind=aircraft team=1 cost=150 unit=corvamp',
            'event=launch frame=30 wave=1 target=9 risk=1 ids=1,2 count=2',
            'event=detected frame=60 wave=1',
            'event=damage frame=90 wave=1 victim=1 attacker=5 attackerTeam=1 team=0 amount=50 emp=0',
            'event=damage frame=150 wave=1 victim=9 attacker=1 attackerTeam=0 team=1 amount=200 emp=0',
            'event=end frame=300 wave=1 risk=1.5 survivors=1 home=1')
        w = result['waves'][0]
        self.assertEqual(w['detection_to_fighter_hit_seconds'], 1)
        self.assertTrue(w['intercept_before_target_damage'])
        self.assertEqual(w['target_damage'], 200)

    def test_aa_damage_is_not_fighter_interception(self):
        result = self.audit(
            'event=spawn frame=0 id=5 kind=defense team=1 cost=800 unit=armflak',
            'event=launch frame=30 wave=1 target=9 risk=1 ids=1 count=1',
            'event=damage frame=90 wave=1 victim=1 attacker=5 attackerTeam=1 team=0 amount=50 emp=0')
        self.assertIsNone(result['waves'][0]['fighter_hit_frame'])

    def test_paralysis_is_not_health_damage_and_other_target_is_not_credited(self):
        result = self.audit(
            'event=launch frame=30 wave=1 target=9 risk=1 ids=1 count=1',
            'event=damage frame=90 wave=1 victim=9 attacker=1 attackerTeam=0 team=1 amount=6000 emp=1',
            'event=damage frame=120 wave=1 victim=10 attacker=1 attackerTeam=0 team=1 amount=500 emp=0')
        self.assertEqual(result['waves'][0]['paralysis'], 6000)
        self.assertEqual(result['waves'][0]['target_damage'], 0)

    def test_loss_only_counts_actual_launched_cohort(self):
        result = self.audit(
            'event=launch frame=30 wave=1 target=9 risk=1 ids=1 count=1',
            'event=death frame=90 wave=1 id=2 cost=200',
            'event=death frame=120 wave=1 id=1 cost=150')
        self.assertEqual(result['waves'][0]['aircraft_metal_lost'], 150)

    def test_completed_sortie_does_not_count_later_losses_twice(self):
        result = self.audit(
            'event=launch frame=30 wave=1 target=9 risk=1 ids=1 count=1',
            'event=end frame=300 wave=1 risk=1 survivors=1 home=1',
            'event=death frame=330 wave=1 id=1 cost=150')
        self.assertEqual(result['waves'][0]['aircraft_metal_lost'], 0)

    def test_gunship_damage_and_emp_are_measured_without_a_bomber_sortie(self):
        result = self.audit(
            'event=spawn frame=0 id=1 kind=aircraft team=0 cost=150 unit=corbw',
            'event=damage frame=90 wave=0 victim=9 attacker=1 attackerTeam=0 team=1 amount=50 emp=0',
            'event=damage frame=120 wave=0 victim=9 attacker=1 attackerTeam=0 team=1 amount=500 emp=1',
            'event=death frame=150 wave=0 id=9 unit=armmex team=1 cost=50 attacker=1')
        stats = result['unit_classes'][0]
        self.assertEqual((stats['health_damage'], stats['paralysis'], stats['kill_value']), (50, 500, 50))

    def test_legion_early_air_is_a_gunship_not_a_fictitious_bomber(self):
        case = resolve_case(Path(__file__).parent/'cases/air/combat/t1-economy.json', 'legion', 'cortex', 1)
        self.assertEqual(case['aircraft'][0]['unit'], 'legmos')
        self.assertEqual(case['aircraft'][1]['unit'], 'corveng')

    def test_target_alias_defaults_to_defender_faction(self):
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder)/'case.json'
            p.write_text(json.dumps({'name': 'target', 'aircraft': [], 'defenses': [],
                                    'targets': [{'unit': '$fighter1', 'count': 1}]}))
            self.assertEqual(resolve_case(p, 'armada', 'cortex', 1)['targets'][0]['unit'], 'corveng')

    def test_zero_refill_period_is_rejected_before_launch(self):
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder)/'case.json'
            p.write_text(json.dumps({'name': 'bad', 'aircraft': [], 'defenses': [], 'targets': [], 'refill_seconds': 0}))
            with self.assertRaisesRegex(ValueError, 'refill_seconds'):
                resolve_case(p, 'armada', 'cortex', 1)

    def test_unsafe_strings_are_quoted_in_lua_config(self):
        self.assertEqual(lua({'x':'a"b\nc'}), '{["x"]="a\\"b\\nc"}')


if __name__ == '__main__':
    unittest.main()
