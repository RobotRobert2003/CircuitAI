"""Rank measured CPU scopes and command traffic without inferring network FPS.

Accept completed archives or live game directories. No writes unless --output
is specified; retained output must be in the external benchmark repository.
"""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path

from analyze_full_match_performance import analyze, fields


def route_diagnostics(lines):
    """Aggregate raw query modes, not emitted waypoint/command counts.

    Older runs do not log all mode flags. Keep that distinction explicit;
    absence of a field must not turn into evidence that compaction was off.
    Memory is bounded by observed mode combinations, not route count.
    """
    groups = {}
    flags = ('transit', 'hold', 'cautious', 'withdrawing')
    for line in lines:
        if '[PerfSeaRoute]' not in line:
            continue
        row = fields(line.split('[PerfSeaRoute]', 1)[1])
        key = tuple(row.get(flag) for flag in flags)
        item = groups.setdefault(key, dict(zip(flags, key), calls=0, raw_points=0,
                                          maximum_raw_points=0, fewer_than_two_points=0))
        item['calls'] += 1
        item['raw_points'] += row['points']
        item['maximum_raw_points'] = max(item['maximum_raw_points'], row['points'])
        item['fewer_than_two_points'] += row['points'] < 2
    return sorted(groups.values(), key=lambda row: -row['calls'])


def ranked_scopes(rows, name):
    totals = {}
    for row in rows:
        if row.get('frame', 0) <= 0:
            continue  # initialization is not recurring simulation cost
        key = row[name]
        item = totals.setdefault(key, dict(name=key, calls=0, exclusive_ms=0.0,
                                          inclusive_ms=0.0, max_ms=0.0))
        item['calls'] += row['calls']
        item['exclusive_ms'] += row['exclusive_ms']
        item['inclusive_ms'] += row['inclusive_ms']
        item['max_ms'] = max(item['max_ms'], row['max_ms'])
    return sorted(totals.values(), key=lambda row: (-row['exclusive_ms'], row['name']))


def summarize(data, teams=()):
    roles = {team['team']: team['role'] for team in teams}
    per_minute = defaultdict(Counter)
    for row in data['orders']:
        if 'frame' not in row or 'all_apm' not in row:
            continue  # installation/error markers share the AirOrders tag
        per_minute[row['frame']]['orders'] += row['all_apm']
    for row in data.get('command_units', []):
        for field in ('nonlua', 'lua', 'unknown'):
            per_minute[row['frame']][field] += row[field]
    command_groups = Counter()
    for row in data.get('command_joint', []):
        command_groups[(roles.get(row['team'], 'UNKNOWN'), row['def'],
                        row['cmd'], row['origin'])] += row['orders']
    classified = [dict(role=role, definition=definition, command=command,
                       origin=origin, orders=count)
                  for (role, definition, command, origin), count in command_groups.most_common()]
    valid = [row for row in data['minutes']
             if row['frame'] > 1800 and row.get('profiling', 1) == 1]
    # Retain requested 1x windows even when the simulation cannot keep up.
    # Filtering on achieved speed would hide the most important slowdown.
    real_time = [row for row in data['minutes'] if row.get('speed_wanted') == 1]
    commands = [dict(row, role=roles.get(row['team'], 'UNKNOWN'))
                for row in data.get('command_unit', [])]
    traffic = defaultdict(Counter)
    for row in data.get('command_traffic', []):
        if row['packet'] in (14, 15, 76):
            traffic[row['frame']]['ai_application_bytes'] += row['interval_bytes']
        if row['packet'] == 50:
            traffic[row['frame']]['lua_message_bytes'] += row['interval_bytes']
    wait = Counter()
    for row in data.get('wait_removals', []):
        for field in ('orders', 'sampled', 'absent', 'unavailable'):
            wait[field] += row[field]
    return dict(
        minutes=data['last_frame']/1800, end_events=data['game_over'],
        maximum_units=max((row['units'] for row in data['minutes']), default=0),
        final_roster=data['roster'][-1:] or None,
        peak_ai_frame_mean=max(valid, key=lambda row: row['ai_mean_ms'], default=None),
        one_times_windows=real_time,
        phases=ranked_scopes(data['phases'], 'phase'),
        labels=ranked_scopes(data['labels'], 'label'),
        aggregate_commands=[dict(frame=frame, **counts) for frame, counts in sorted(per_minute.items())],
        peak_team=max((row for row in data['orders'] if 'all_apm' in row), key=lambda row: row['all_apm'], default=None),
        top_units=sorted(commands, key=lambda row: (-row['orders'], row['frame'], row['unit']))[:30],
        top_native_units=sorted(commands, key=lambda row: (-row['nonlua'], row['frame'], row['unit']))[:30],
        command_groups=classified,
        application_traffic=[dict(frame=frame, **counts) for frame, counts in sorted(traffic.items())],
        wait_removal_samples=dict(wait),
        invariants=data['invariants'], errors=data['errors'],
        reservation_lines=sum(data['reservation_lines'].values()),
        failed_placement_lines=sum(data['failed_placement_lines'].values()),
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directories', nargs='+', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    runs = []
    for directory in args.directories:
        teams = json.loads((directory/'teams.json').read_text())['teams']
        row = summarize(analyze(directory), teams)
        row['directory'] = str(directory.resolve())
        row['input_pin'] = json.loads((directory/'run-inputs.json').read_text())
        with (directory/'infolog.txt').open(encoding='utf-8', errors='replace') as stream:
            row['raw_route_modes'] = route_diagnostics(stream)
        runs.append(row)
    result = dict(schema=1, runs=runs, limitations=[
        'Exclusive and inclusive times are separate; never add a parent to its children.',
        'Top unit rows cover at most ten units per team/minute; aggregate totals cover all orders.',
        'nonlua is an engine event origin, not an exclusive CircuitAI attribution.',
        'Application traffic is host-received protocol payload, not UDP overhead, loss, latency or server fan-out.',
        'No network performance or before/after causal claim from these different natural games.',
        'Wait queue absence is sampled every 64 matching removals; do not extrapolate as an exact count.',
    ])
    if args.output:
        # Immutable reports must not replace an earlier observation.
        with args.output.open('x', encoding='utf-8') as stream:
            json.dump(result, stream, indent=2)
            stream.write('\n')
    for row in runs:
        peak = max(row['aggregate_commands'], key=lambda item: item['orders'], default=None)
        print(json.dumps(dict(directory=row['directory'], minutes=row['minutes'], units=row['maximum_units'],
            peak_ai=row['peak_ai_frame_mean'], peak_aggregate_commands=peak, peak_team=row['peak_team'],
            top_units=row['top_units'][:3], top_phases=row['phases'][:5], top_labels=row['labels'][:8],
            wait_removals=row['wait_removal_samples'], invariants=row['invariants'], errors=row['errors'][:3]), indent=2))


if __name__ == '__main__':
    main()
