import unittest
from sea_station_audit import audit, audit_production, audit_visibility, audit_coast, audit_handoff


class StationAuditTest(unittest.TestCase):
    def test_handoff_requires_every_guard_and_real_damage(self):
        spec = dict(wave_seconds=240, maximum_response_seconds=3, submarines=['armsub'], enemy='corroy')
        guards = '[f=100] :T:0: [SEA][SubPerimeter] cohort=1\n[f=100] :T:0: [SEA][SubPerimeter] cohort=2\n'
        damage = '[f=7300] [SeaArena] damage attacker=12 team=0 attackerUnit=armsub victimUnit=corroy\n'
        release = '[f=7230] :T:0: [SEA][GuardReleased] cohort=1\n'
        complete = guards + release + release.replace('cohort=1', 'cohort=2')
        self.assertTrue(audit_handoff(guards+release+damage, spec)[0])
        self.assertTrue(audit_handoff(complete, spec)[0])
        self.assertTrue(audit_handoff(complete.replace('7230', '7400')+damage, spec)[0])
        self.assertEqual(audit_handoff(complete+damage, spec)[0], [])

    def test_coast_requires_stationary_physical_range(self):
        spec = dict(minimum_observed=1, minimum_aligned=1, range_fraction=.95, maximum_error=128)
        self.assertTrue(audit_coast('', spec)[0])
        prefix = '[SeaArena] frame=900 boat id=1 queue=0\n'
        self.assertTrue(audit_coast(prefix+'[SeaArena] frame=900 coast id=1 range=500 distance=700', spec)[0])
        self.assertEqual(audit_coast(prefix+'[SeaArena] frame=900 coast id=1 range=500 distance=480', spec)[0], [])
        self.assertTrue(audit_coast(prefix.replace('queue=0', 'queue=1')+'[SeaArena] frame=900 coast id=1 range=500 distance=480', spec)[0])

    def test_discovery_alone_does_not_clear_visibility(self):
        text = '\n'.join(f'[SeaArena] frame={frame} objective id=1 los={visible}' for frame, visible in [(150, 'true'), (300, 'false'), (1800, 'false')])
        failures, _ = audit_visibility(text, dict(minimum_objectives=1, maximum_blackout_seconds=45))
        self.assertTrue(failures)

    def test_continuous_samples_and_missing_observations(self):
        spec = dict(minimum_objectives=1, maximum_blackout_seconds=45)
        self.assertTrue(audit_visibility('', spec)[0])
        self.assertEqual(audit_visibility('[SeaArena] frame=150 objective id=1 los=true\n[SeaArena] frame=300 objective id=1 los=true', spec)[0], [])

    spec = dict(units=['armsub'], minimum_stationed=1, minimum_stations=1)
    goal = '[f=0000100] [SEA][SubPerimeter] cohort=1 goal=1000,2000\n'

    def test_assignment_without_arrival_fails(self):
        failures, _ = audit(self.goal+'[f=0000200] [SeaArena] boat id=4 unit=armsub x=0 z=0', self.spec)
        self.assertTrue(failures)

    def test_arrival_passes(self):
        failures, measured = audit(self.goal+'[f=0000200] [SeaArena] boat id=4 unit=armsub x=1000 z=2000', self.spec)
        self.assertEqual(failures, [])
        self.assertEqual(measured['stationed'], 1)

    def test_stale_or_dead_boat_does_not_count(self):
        failures, _ = audit(self.goal+'[f=0000200] [SeaArena] boat id=4 unit=armsub x=1000 z=2000\n[f=0000600] end', self.spec)
        self.assertTrue(failures)

    def test_supplied_units_do_not_prove_production(self):
        text = '[SeaArena] frame=10 finished id=1 team=0 unit=armpt\n[SeaArena] frame=20 finished id=2 team=0 unit=armsub'
        failures, _ = audit_production(text, dict(scout='armpt', submarine='armsub', minimum_submarines=1))
        self.assertTrue(failures)

    def test_created_and_completed_scout_precedes_sub(self):
        text = '\n'.join(f'[SeaArena] frame={frame} {event} id={unit_id} team=0 unit={unit}' for frame, event, unit_id, unit in [
            (10, 'produced', 1, 'armpt'), (20, 'finished', 1, 'armpt'),
            (30, 'produced', 2, 'armsub'), (40, 'finished', 2, 'armsub')])
        failures, _ = audit_production(text, dict(scout='armpt', submarine='armsub', minimum_submarines=1))
        self.assertEqual(failures, [])
