import json
import tempfile
import unittest
from pathlib import Path
from ranged_benchmark import summarize


class MeasurementsTest(unittest.TestCase):
    def test_early_completion_requires_archived_survival_and_keeps_casualties(self):
        for mode,tail,expected in [('fast','',True),('performance','',False),
                ('fast','[RangedArena] frame=1210 death id=1 team=0 unit=armcom cost=2700\n',False)]:
            with self.subTest(mode=mode,tail=tail), tempfile.TemporaryDirectory() as tmp:
                path=Path(tmp);archive=path/'runs/test';archive.mkdir(parents=True)
                (path/'ranged-arena.json').write_text(json.dumps(dict(name='early',unit='armcom',
                    variant='ranged',seed=1,minutes=4,mode=mode,assertions=dict(min_kills=0,min_shooters=0))))
                (path/'infolog.txt').write_text('[RangedArena] frame=1230 orders team=0 nonlua=12 lua=0\n'+tail)
                (archive/'result.json').write_text(json.dumps(dict(verdict='PASS',reason='scenario complete with survival grace')))
                (archive/'checks.json').write_text(json.dumps(dict(complete_on={'pattern':'complete'},completion_grace_seconds=10)))
                (archive/'runner-timing.json').write_text('{"complete_frame":900}')
                result=summarize(path)
                self.assertEqual(result['passed'],expected)

    def test_completion_marker_without_survival_tail_does_not_shorten_window(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp);archive=path/'runs/test';archive.mkdir(parents=True)
            (path/'ranged-arena.json').write_text(json.dumps(dict(name='early',unit='armcom',variant='ranged',seed=1,
                minutes=4,assertions=dict(min_kills=0,min_shooters=0))))
            (path/'infolog.txt').write_text('[RangedArena] frame=950 orders team=0 nonlua=12 lua=0\n')
            (archive/'result.json').write_text(json.dumps(dict(verdict='PASS',reason='scenario complete with survival grace')))
            (archive/'checks.json').write_text('{"complete_on":{"pattern":"complete"}}')
            (archive/'runner-timing.json').write_text('{"complete_frame":900}')
            self.assertIn('incomplete observation window',summarize(path)['failures'])

    def test_explicit_enemy_team_excludes_allied_casualties(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)
            (path/'ranged-arena.json').write_text(json.dumps(dict(name='energy',unit='armcom',
                variant='ranged',seed=1,minutes=1,enemy_team=2,
                assertions=dict(min_kills=1,min_shooters=0,min_damage=0))))
            (path/'infolog.txt').write_text('''[RangedArena] frame=700 death id=2 team=2 unit=corak cost=43
[RangedArena] frame=710 death id=3 team=1 unit=armwar cost=280
[RangedArena] frame=1800 orders team=0 nonlua=12 lua=0
''')
            result=summarize(path)
            self.assertEqual(result['enemy_kills'],1)
            self.assertEqual(result['enemy_metal_destroyed'],43)

    def test_first_actual_shot_and_forward_progress_exclude_shutdown(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path/'ranged-arena.json').write_text(json.dumps(dict(
                name='thug', unit='corthud', variant='ranged', seed=1, minutes=3,
                starts=[[0,0],[0,1000]], assertions=dict(min_kills=0,
                    min_shooters=1, min_damage=100, max_first_shot_seconds=30))))
            (path/'infolog.txt').write_text('''[RangedArena] frame=300 spawn id=1 team=0 unit=corthud x=0 z=0
[RangedArena] frame=600 unit id=1 unit=corthud x=0 z=-100 hp=900 host=-1
[RangedArena] frame=900 shot id=1 unit=corthud weapon=1 target=2 distance=300 intent=2
[RangedArena] frame=900 damage id=2 team=1 amount=104 attacker=1 attackerTeam=0 weapon=8
[RangedArena] frame=900 unit id=1 unit=corthud x=0 z=500 hp=900 host=-1
[RangedArena] frame=5400 orders team=0 nonlua=30 lua=0
[RangedArena] frame=5500 unit id=1 unit=corthud x=0 z=9000 hp=900 host=-1
''')
            result = summarize(path)
            self.assertTrue(result['passed'])
            self.assertEqual(result['first_shot_seconds'],30)
            self.assertEqual(result['minimum_forward_projection'],-100)
            self.assertEqual(result['maximum_forward_projection'],500)
            self.assertEqual(result['firing_sample_fraction_20_to_120'],.5)

    def response_result(self, events):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path/'ranged-arena.json').write_text(json.dumps(dict(
                name='turn', unit='legmed', variant='ranged', seed=1, minutes=4,
                assertions=dict(min_kills=0, min_shooters=0, max_target_response_seconds=30))))
            (path/'infolog.txt').write_text('''[RangedArena] frame=300 spawn id=1 team=0 unit=legmed x=0 z=0
[RangedArena] frame=300 spawn id=2 team=0 unit=armpw x=0 z=0
[RangedArena] frame=300 spawn id=3 team=1 unit=armestor x=0 z=900
[RangedArena] frame=300 spawn id=4 team=1 unit=armestor x=0 z=-900
[RangedArena] frame=330 detected id=3 unit=armestor
[RangedArena] frame=340 damage id=3 team=1 amount=500 attacker=1 attackerTeam=0 weapon=8
[RangedArena] frame=1800 detected id=4 unit=armestor
''' + events + '\n[RangedArena] frame=7200 orders team=0 nonlua=20 lua=0\n')
            return summarize(path)

    def test_each_visible_target_requires_real_damage_from_tested_hulls(self):
        result = self.response_result('''[RangedArena] frame=1810 shot id=1 unit=legmed weapon=1 target=4 distance=900 intent=4
[RangedArena] frame=1811 damage id=4 team=1 amount=0 attacker=1 attackerTeam=0 weapon=7
[RangedArena] frame=1812 damage id=4 team=1 amount=100 attacker=2 attackerTeam=0 weapon=6''')
        self.assertFalse(result['passed'])
        self.assertIsNone(result['target_response_seconds']['4'])

    def test_facing_recovery_must_finish_before_response_deadline(self):
        on_time = self.response_result('[RangedArena] frame=2700 damage id=4 team=1 amount=500 attacker=1 attackerTeam=0 weapon=8')
        late = self.response_result('[RangedArena] frame=2701 damage id=4 team=1 amount=500 attacker=1 attackerTeam=0 weapon=8')
        self.assertTrue(on_time['passed'])
        self.assertEqual(on_time['target_response_seconds']['4'], 30)
        self.assertFalse(late['passed'])

    def test_shutdown_damage_does_not_repair_a_firing_stall(self):
        result = self.response_result('[RangedArena] frame=7500 damage id=4 team=1 amount=500 attacker=1 attackerTeam=0 weapon=8')
        self.assertFalse(result['passed'])
        self.assertIsNone(result['target_response_seconds']['4'])

    def test_logs_and_overkill_are_not_confused_with_fixture_events(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)
            (path/'ranged-arena.json').write_text(json.dumps(dict(name='test',unit='armsnipe',variant='ranged',seed=1,minutes=4)))
            (path/'infolog.txt').write_text('''[Playtest] expect [RangedArena] unit damaged
[RangedArena] frame=300 spawn id=1 team=0 unit=armsnipe x=0 z=0
[RangedArena] frame=310 spawn id=2 team=1 unit=armllt x=0 z=800
[RangedArena] frame=600 shot id=1 unit=armsnipe weapon=1 target=2 distance=880 intent=2
[RangedArena] frame=610 damage id=2 team=1 amount=2500 attacker=1 attackerTeam=0 weapon=283
[RangedArena] frame=610 death id=2 team=1 unit=armllt cost=85
[RangedArena] frame=7200 orders team=0 total=50 nonlua=40 lua=10
''')
            result=summarize(path)
            self.assertTrue(result['passed'])
            self.assertEqual(result['enemy_metal_destroyed'],85)
            self.assertEqual(result['commands_per_game_minute'],10)
            self.assertEqual(result['raw_damage_including_overkill'],2500)
            self.assertEqual(result,summarize(path))
            (path/'infolog.txt').write_text('[RangedArena] frame=700 ERROR test\n')
            with self.assertRaises(RuntimeError): summarize(path)

    def test_early_failure_uses_observed_command_window_and_fails_acceptance(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)
            (path/'ranged-arena.json').write_text(json.dumps(dict(name='test',unit='armsnipe',variant='ranged',seed=1,minutes=4,
                assertions=dict(min_kills=0,min_shooters=0))))
            (path/'infolog.txt').write_text('[RangedArena] frame=1800 orders team=0 nonlua=120 lua=0\n')
            result=summarize(path)
            self.assertFalse(result['passed'])
            self.assertEqual(result['commands_per_game_minute'],120)
            self.assertIn('incomplete observation window',result['failures'])

    def test_failed_watch_verdict_and_missing_sensor_movement_remain_failures(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)
            (path/'ranged-arena.json').write_text(json.dumps(dict(name='test',unit='armsnipe',variant='ranged',seed=1,minutes=4,
                sensor_units=['armseer'],assertions=dict(min_kills=0,min_shooters=0,min_sensor_advance=600))))
            (path/'infolog.txt').write_text('[RangedArena] frame=7200 orders team=0 nonlua=120 lua=0\n')
            archive=path/'runs/test';archive.mkdir(parents=True)
            (archive/'result.json').write_text('{"verdict":"FAIL"}')
            result=summarize(path)
            self.assertFalse(result['passed'])
            self.assertIn('original watch verdict: FAIL',result['failures'])
            self.assertIn('sensor did not advance: armseer',result['failures'])

    def test_shutdown_grace_and_partial_events_do_not_extend_measurements(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)
            (path/'ranged-arena.json').write_text(json.dumps(dict(name='test',unit='armsnipe',variant='ranged',seed=1,minutes=4,
                assertions=dict(min_kills=0,min_shooters=0))))
            (path/'infolog.txt').write_text('''[RangedArena] frame=7200 orders team=0 nonlua=120 lua=0
[WorkforcePerf] frame=7200 ai_all_p95_ms=0.2
[RangedArena] frame=7500 orders team=0 nonlua=999 lua=0
[WorkforcePerf] frame=7500 ai_all_p95_ms=9
[RangedArena] frame=7501 damage id=2 team=1 amount=25
[RangedArena] frame=
''')
            result=summarize(path)
            self.assertTrue(result['passed'])
            self.assertEqual(result['commands_per_game_minute'],30)
            self.assertEqual(result['last_observed_frame'],7500)
            self.assertEqual(len(result['engine_ai_windows']),1)


if __name__=='__main__': unittest.main()
