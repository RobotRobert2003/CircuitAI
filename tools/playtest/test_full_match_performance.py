"""Protect the distinctions used to rank costs, not the runtime AI policy."""
import tempfile
import unittest
from pathlib import Path

from analyze_full_match_performance import analyze, summary
from summarize_full_match_performance import reduce
from analyze_sea_route_performance import analyze as analyze_routes


class FullMatchEvidenceTests(unittest.TestCase):
    def test_nested_costs_multiple_ais_and_orders_stay_separate(self):
        lines = [
            '[f=3600] [SkirmishPerf] frame=3600 units=100 wall_s=120 speed_actual=0.4 ai_mean_ms=4',
            '[f=3600] [SkirmishScope] frame=3600 name=Sim total_ms=180000 interval_ms=90000',
            '[f=3600] [SkirmishScope] frame=3600 name=Sim::Script total_ms=54000 interval_ms=18000',
            '[f=3600] [PerfPhase] team=0 frame=3600 phase=script inclusive_ms=5000 exclusive_ms=900',
            '[f=3600] [PerfPhase] team=1 frame=3600 phase=script inclusive_ms=4000 exclusive_ms=450',
            '[f=3600] [PerfLabel] team=0 frame=3600 label=builder-dispatch inclusive_ms=3000 exclusive_ms=1800',
            '[f=3600] [AirOrders] observer initialized',
            '[f=3600] [AirOrders] frame=3600 team=0 all_apm=120 air_apm=40',
            '[f=3600] [AirOrders] frame=3600 team=1 all_apm=80 air_apm=20',
            '[f=3600] [CommandOrigin] frame=3600 team_source=0:nonlua count=100',
            '[f=3600] [CommandOrigin] frame=3600 team_source=0:lua count=20',
            '[f=3600] [FullMatchRoster] frame=3600 active=16',
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'infolog.txt').write_text('\n'.join(lines))
            result = reduce(analyze(path))
        window = result['windows'][0]
        self.assertEqual(window['engine_scope_ms_per_frame']['Sim'], 50)
        self.assertEqual(window['engine_scope_ms_per_frame']['Sim::Script'], 10)
        self.assertEqual(window['native_exclusive_ms_per_frame']['script'], .75)
        self.assertEqual(window['native_inclusive_ms_per_frame']['script'], 5)
        self.assertEqual(window['label_exclusive_ms_per_frame']['builder-dispatch'], 1)
        self.assertEqual(window['all_team_orders'], 200)
        self.assertEqual(window['air_unit_orders'], 60)
        self.assertEqual(window['nonlua_orders'], 100)
        self.assertEqual(window['average_sim_speed'], .5)
        self.assertEqual(window['active_ais'], 16)
        self.assertEqual(result['game_over'], [])

    def test_partial_last_minute_and_invariant_do_not_become_victory(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'infolog.txt').write_text(
                '[f=54432] [INVARIANT] INV-025 failed\n'
                '[f=54435] RESERVE: no room\n')
            result = analyze(path)
        self.assertEqual(result['last_frame'], 54435)
        self.assertEqual(result['minutes'], [])
        self.assertEqual(result['game_over'], [])
        self.assertEqual(result['invariants'], {'INV-025': 1})
        self.assertEqual(result['failed_placement_lines'], {30: 1})

    def test_profiler_off_keeps_progress_but_has_no_measured_ai_peak(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'infolog.txt').write_text(
                '[f=3600] [SkirmishPerf] frame=3600 units=200 wall_s=60 '
                'speed_actual=1 ai_mean_ms=0 ai_p99_ms=0 profiling=0\n')
            data = analyze(path)
        window = reduce(data)['windows'][0]
        self.assertFalse(window['engine_measurement_valid'])
        self.assertEqual(window['average_sim_speed'], 1)
        self.assertIsNone(summary(data)['worst_ai'])

    def test_route_joint_counts_exclude_gaia_and_keep_calls_distinct(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'infolog.txt'
            log.write_text('\n'.join([
                '[PerfSeaRoute] frame=1799 team=0 cohort=1 members=2 points=100',
                '[PerfSeaRoute] frame=1801 team=0 cohort=1 members=2 points=90',
                '[CommandJoint] frame=1800 team=0 def=armroy cmd=10 origin=nonlua orders=198 max_unit_frame_moves=99',
                '[CommandJoint] frame=1800 team=0 def=armroy cmd=20 origin=nonlua orders=2 max_unit_frame_moves=0',
                '[CommandJoint] frame=1800 team=17 def=bird cmd=10 origin=lua orders=900 max_unit_frame_moves=1',
                '[AirOrders] frame=1800 team=0 all_apm=200 air_apm=0',
                '[AirOrders] frame=1800 team=17 all_apm=900 air_apm=900',
                '[PerfLabel] frame=1800 team=0 label=sea.route calls=1 inclusive_ms=1900 exclusive_ms=1800 max_ms=1900',
            ]))
            result = analyze_routes(log, {0})
        self.assertEqual(result['reconciled_intervals'], 1)
        self.assertEqual(result['mismatches'], [])
        row = result['windows'][0]
        self.assertEqual(row['route_requests'], 1)
        self.assertEqual(row['route_points_max'], 100)
        self.assertEqual(row['unit_orders'], 200)
        self.assertEqual(row['move_orders'], 198)
        self.assertEqual(row['max_unit_frame_moves'], 99)
        self.assertEqual(row['label_exclusive_ms_per_frame']['sea.route'], 1)

    def test_missing_joint_observations_fail_reconciliation(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'infolog.txt'
            log.write_text('[AirOrders] frame=1800 team=0 all_apm=4 air_apm=0\n')
            result = analyze_routes(log, {0})
        self.assertEqual(result['mismatches'], [dict(frame=1800, team=0, expected=4, joint=0)])


if __name__ == '__main__':
    unittest.main()
