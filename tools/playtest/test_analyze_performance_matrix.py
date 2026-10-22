import unittest

from analyze_performance_matrix import ranked_scopes, summarize, route_diagnostics


class MatrixTests(unittest.TestCase):
    def test_raw_routes_keep_unknown_flags_and_do_not_claim_dispatched_commands(self):
        rows = route_diagnostics([
            '[PerfSeaRoute] frame=30 points=0\n',
            '[PerfSeaRoute] frame=60 points=40 transit=1 hold=0 cautious=0 withdrawing=0\n',
            '[PerfSeaRoute] frame=90 points=60 transit=1 hold=0 cautious=0 withdrawing=0\n',
        ])
        self.assertEqual(rows[0]['calls'], 2)
        self.assertEqual(rows[0]['raw_points'], 100)
        self.assertEqual(rows[0]['maximum_raw_points'], 60)
        self.assertIsNone(rows[1]['transit'])
        self.assertEqual(rows[1]['fewer_than_two_points'], 1)
        self.assertNotIn('commands', rows[0])

    def test_exclusive_ranking_does_not_double_count_parent(self):
        rows = [dict(frame=1800, phase='parent', calls=1, exclusive_ms=2, inclusive_ms=12, max_ms=12),
                dict(frame=1800, phase='child', calls=4, exclusive_ms=10, inclusive_ms=10, max_ms=5),
                dict(frame=0, phase='startup', calls=1, exclusive_ms=99, inclusive_ms=99, max_ms=99)]
        ranked = ranked_scopes(rows, 'phase')
        self.assertEqual([row['name'] for row in ranked], ['child', 'parent'])
        self.assertEqual(sum(row['exclusive_ms'] for row in ranked), 12)

    def test_origins_off_profiler_and_no_traffic_are_not_invented(self):
        data = {key: [] for key in ('orders', 'minutes', 'phases', 'labels', 'game_over', 'roster', 'errors')}
        data.update(last_frame=3600, invariants={}, reservation_lines={}, failed_placement_lines={})
        data['orders'] = [{}, dict(frame=1800, team=0, all_apm=100), dict(frame=1800, team=1, all_apm=200)]
        data['minutes'] = [dict(frame=3600, profiling=0, units=900, ai_mean_ms=0, speed_actual=1, speed_wanted=1)]
        data['command_units'] = [dict(frame=1800, nonlua=60, lua=40, unknown=0),
                                 dict(frame=1800, nonlua=90, lua=0, unknown=110)]
        result = summarize(data)
        self.assertIsNone(result['peak_ai_frame_mean'])
        self.assertEqual(result['aggregate_commands'], [dict(frame=1800, orders=300, nonlua=150, lua=40, unknown=110)])
        self.assertEqual(result['application_traffic'], [])

    def test_payload_and_wait_samples_keep_their_own_units(self):
        data = {key: [] for key in ('orders', 'minutes', 'phases', 'labels', 'game_over', 'roster', 'errors')}
        data.update(last_frame=3600, invariants={}, reservation_lines={}, failed_placement_lines={})
        data['command_traffic'] = [dict(frame=1800, packet=14, interval_bytes=210),
                                   dict(frame=1800, packet=15, interval_bytes=40),
                                   dict(frame=1800, packet=50, interval_bytes=10),
                                   dict(frame=1800, packet=-1, interval_bytes=999)]
        data['wait_removals'] = [dict(orders=128, sampled=2, absent=1, unavailable=1)]
        result = summarize(data)
        self.assertEqual(result['application_traffic'],
                         [dict(frame=1800, ai_application_bytes=250, lua_message_bytes=10)])
        self.assertEqual(result['wait_removal_samples'],
                         dict(orders=128, sampled=2, absent=1, unavailable=1))

    def test_requested_real_time_window_retains_simulation_slowdown(self):
        data = {key: [] for key in ('orders', 'minutes', 'phases', 'labels', 'game_over', 'roster', 'errors')}
        data.update(last_frame=3600, invariants={}, reservation_lines={}, failed_placement_lines={})
        slow = dict(frame=3600, profiling=1, units=3700, ai_mean_ms=6,
                    speed_actual=.65, speed_wanted=1)
        data['minutes'] = [slow]
        result = summarize(data)
        self.assertEqual(result['one_times_windows'], [slow])


if __name__ == '__main__':
    unittest.main()
