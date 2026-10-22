"""Stream integration logs into bounded role/health summaries, without judging wins.

Role log activity proves dispatch occurred, not that every policy succeeded.
Original runner verdicts and invariant categories remain authoritative evidence.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import re


def summarize(path):
    teams, invariants = {}, Counter()
    errors, crash, last_frame = [], False, 0
    census = {}
    census_history = {}
    for line in Path(path).open(encoding='utf-8', errors='replace'):
        frame = re.search(r'\[f=(\d+)\]', line)
        if frame:
            last_frame = max(last_frame, int(frame[1]))
        ai = re.search(r':::AI LOG:S:\d+:T:(\d+):F:(\d+):L::(.*)', line)
        if ai:
            team = teams.setdefault(ai[1], {'role': None, 'last_log_frame': 0, 'messages': 0})
            team['messages'] += 1
            team['last_log_frame'] = int(ai[2])
            role = re.search(r'Captured start position .*role=(\d+)', ai[3])
            if role:
                team['role'] = ['FRONT', 'AIR', 'TECH', 'SEA', 'SUPPORT', 'TACTICAL'][int(role[1])]
            invariant = re.search(r'\[INVARIANT\]\s+(INV-\d+)', ai[3])
            if invariant:
                invariants[invariant[1]] += 1
        if re.search(r'Exception: Access violation|Segmentation fault|SCRIPT CRASH', line):
            crash = True
        if re.search(r'\.as\s*\(\d+,\s*\d+\).*:\s*(?:ERR|WARN)', line) and len(errors) < 20:
            errors.append(line.strip())
        match = re.search(r'\[RoleCensus\] minute=(\d+) team=(\d+) (.*)', line)
        if match:
            census[match[2]] = {'minute': int(match[1]), 'state': match[3].strip()}
            census_history.setdefault(match[2], []).append(census[match[2]])
    return {'last_game_minute': last_frame / 1800, 'teams': teams,
            'invariants': dict(invariants), 'script_diagnostics': errors,
            'crash_marker': crash, 'last_census_by_team': census,
            # Keep intermediate progress: a defeated team's final roster cannot
            # establish whether its opening or technology transition worked.
            'census_history_by_team': census_history,
            'teams_missing_census': sorted(set(teams) - set(census), key=int)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(args.log), indent=2))
