"""Attribute opt-in SEA route diagnostics without treating orders as packets.

This is a separate artifact from the established full-match schema. Route
lengths are requests, not actual submitted orders; only CommandJoint counts
measure the latter. Partial trailing minutes are excluded from reconciliation.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import re
import statistics

from analyze_full_match_performance import fields


def analyze(log, teams):
    routes, joint, labels, orders = [], [], [], {}
    tag = re.compile(r'\[(PerfSeaRoute|CommandJoint|PerfLabel|AirOrders)\] (.*)')
    with log.open(encoding='utf-8', errors='replace') as stream:
        for line in stream:
            match = tag.search(line)
            if not match:
                continue
            row = fields(match[2])
            if row.get('team') not in teams or 'frame' not in row:
                continue
            if match[1] == 'PerfSeaRoute':
                routes.append(row)
            elif match[1] == 'CommandJoint':
                joint.append(row)
            elif match[1] == 'PerfLabel':
                labels.append(row)
            elif 'all_apm' in row:
                orders[row['frame'], row['team']] = row['all_apm']
    sums = Counter()
    for row in joint:
        sums[row['frame'], row['team']] += row['orders']
    mismatches = [dict(frame=f, team=t, expected=n, joint=sums[f, t])
                  for (f, t), n in orders.items() if sums[f, t] != n]
    missing = [dict(frame=f, team=t) for f, t in sums if (f, t) not in orders]
    by_frame = defaultdict(list)
    for row in labels:
        by_frame[row['frame']].append(row)
    windows = []
    for frame, values in sorted(by_frame.items()):
        route_rows = [r for r in routes if frame - 1800 < r['frame'] <= frame]
        lengths = sorted(r['points'] for r in route_rows)
        costs, calls, maxima = Counter(), Counter(), Counter()
        for row in values:
            costs[row['label']] += row['exclusive_ms']
            calls[row['label']] += row['calls']
            maxima[row['label']] = max(maxima[row['label']], row['max_ms'])
        window_joint = [r for r in joint if r['frame'] == frame]
        windows.append(dict(
            frame=frame,
            label_exclusive_ms_per_frame={k: v / 1800 for k, v in costs.most_common()},
            label_calls=dict(calls), label_max_ms=dict(maxima),
            route_requests=len(lengths),
            route_points_median=statistics.median(lengths) if lengths else None,
            route_points_max=max(lengths, default=None),
            unit_orders=sum(orders.get((frame, t), 0) for t in teams),
            move_orders=sum(r['orders'] for r in window_joint if r['cmd'] == 10),
            nonlua_move_orders=sum(r['orders'] for r in window_joint if r['cmd'] == 10 and r['origin'] == 'nonlua'),
            max_unit_frame_moves=max((r['max_unit_frame_moves'] for r in window_joint), default=0),
            busiest_joint_rows=sorted(window_joint, key=lambda r: -r['orders'])[:5],
        ))
    return dict(schema=1, teams=sorted(teams), reconciled_intervals=len(orders),
                mismatches=mismatches, joint_without_total=missing,
                windows=windows,
                limits=['unit-command events, not network packets or human APM',
                        'route lengths measure requests, not redundant orders',
                        'timings are exclusive except single-call max_ms',
                        'extra instrumentation: not an old/new performance pair'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--teams', type=int, nargs='+', required=True,
                        help='Competing AI team IDs; exclude spectator and Gaia')
    parser.add_argument('--live', action='store_true')
    args = parser.parse_args()
    log = args.directory / 'infolog.txt'
    result = analyze(log, set(args.teams))
    if not args.live:
        with log.open('rb') as stream:
            result['log_sha256'] = hashlib.file_digest(stream, 'sha256').hexdigest()
        target = args.directory / 'sea-route-performance-v1.json'
        if target.exists() and json.loads(target.read_text()) != result:
            raise ValueError('Conflicting immutable analysis')
        if not target.exists():
            target.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({**result, 'windows': result['windows'][-2:]}, indent=2))
    if result['mismatches'] or result['joint_without_total']:
        raise SystemExit('Joint counts do not reconcile')


if __name__ == '__main__':
    main()
