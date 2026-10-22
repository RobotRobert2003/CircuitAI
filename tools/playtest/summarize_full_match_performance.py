"""Reduce recorded 8v8 intervals without double-counting nested timers.

Use only completed, hash-pinned analysis for publication. --live is explicitly
ephemeral. Engine scopes are inclusive and worker timers can overlap; native
phase/label exclusive values are reported in separate tables, never summed
with their parent AI scope. Orders are unit-command events, not network packets.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
from analyze_full_match_performance import analyze


def at_frame(rows, frame):
    return (r for r in rows if r.get('frame') == frame)


def totals(rows, name, value):
    result = Counter()
    for row in rows:
        result[row[name]] += row[value]
    return result


def reduce(data):
    windows = []
    for row in data['minutes']:
        frame = row['frame']
        scopes = {r['name']: r['interval_ms'] / 1800 for r in at_frame(data['scopes'], frame)}
        phases = totals(at_frame(data['phases'], frame), 'phase', 'exclusive_ms')
        inclusive = totals(at_frame(data['phases'], frame), 'phase', 'inclusive_ms')
        labels = totals(at_frame(data['labels'], frame), 'label', 'exclusive_ms')
        orders = list(at_frame(data['orders'], frame))
        origins = list(at_frame(data['origins'], frame))
        teams = sorted(((k, v) for k, v in scopes.items() if k.startswith('AI::')), key=lambda kv: -kv[1])
        windows.append(dict(
            **row,
            engine_measurement_valid=row.get('profiling', 1) == 1,
            # This is the average progress over the observed minute. The
            # engine's speed_actual is only its estimate at the final frame.
            average_sim_speed=60 / row['wall_s'] if row['wall_s'] > 0 else None,
            active_ais=next((r['active'] for r in at_frame(data['roster'], frame)), None),
            engine_scope_ms_per_frame=scopes,
            native_exclusive_ms_per_frame={k: v / 1800 for k, v in phases.most_common()},
            # D-221 adds snapshot children. Comparing the old parent to its
            # new exclusive residual would incorrectly count instrumentation
            # boundaries as savings. Keep inclusive parents separately.
            native_inclusive_ms_per_frame={k: v / 1800 for k, v in inclusive.most_common()},
            label_exclusive_ms_per_frame={k: v / 1800 for k, v in labels.most_common()},
            team_ai_ms_per_frame=teams,
            all_team_orders=sum(r.get('all_apm', 0) for r in orders),
            air_unit_orders=sum(r.get('air_apm', 0) for r in orders),
            nonlua_orders=sum(r['count'] for r in origins if r['team_source'].endswith(':nonlua')),
            busiest_team=max(orders, key=lambda r: r.get('all_apm', 0), default=None),
        ))
    return dict(windows=windows, game_over=data['game_over'],
                invariants=data['invariants'], errors=data['errors'],
                log_sha256=data.get('log_sha256'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--live', action='store_true')
    args = parser.parse_args()
    source = args.directory / 'full-match-performance-v1.json'
    data = analyze(args.directory) if args.live else json.loads(source.read_text())
    result = reduce(data)
    if not args.live:
        path = args.directory / 'full-match-summary-v2.json'
        if path.exists() and json.loads(path.read_text()) != result:
            raise ValueError('Refusing to replace immutable summary')
        if not path.exists():
            path.write_text(json.dumps(result, indent=2) + '\n')
    for row in result['windows'][-3:]:
        brief = {k: row[k] for k in (
            'frame', 'units', 'active_ais', 'ai_mean_ms', 'ai_p99_ms', 'speed_actual',
            'engine_measurement_valid', 'average_sim_speed',
            'all_team_orders', 'air_unit_orders', 'busiest_team')}
        for name in ('native_exclusive_ms_per_frame', 'label_exclusive_ms_per_frame'):
            brief[name] = dict(list(row[name].items())[:8])
        print(json.dumps(brief, indent=2))


if __name__ == '__main__':
    main()
