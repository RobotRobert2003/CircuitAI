"""Commander cloak sends in an infolog (owner 2026-10-24).

Reads the AI's [CommanderCloak] lines and D-gun lines and reports, per
commander: cloak on/off sends, the shortest gap between two cloak-off sends
(the limit is one per uncloak_seconds, 3 s by default), and what followed
each D-gun shot (re-cloak kept or turned off, and how soon).

    python tools/playtest/analyze_commander_cloak.py <infolog.txt> [--uncloak-seconds 3]

Exit 1 when two cloak-off sends of one commander are closer than the limit.
"""
import argparse
import collections
import json
import re
import sys

CLOAK = re.compile(r'\[CommanderCloak\] unit=(\d+) cloak=([01])( reassert)? frame=(\d+)')
SHOT = re.compile(r'\[Commander(?:Priority)?\] unit=(\d+) .*?(shot_pending|action=fire )')
FRAME = re.compile(r'frame=(\d+)')
FRAME_PREFIX = re.compile(r'\[f=(\d+)\]')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('log')
    parser.add_argument('--uncloak-seconds', type=float, default=3.0)
    args = parser.parse_args()
    limit = int(args.uncloak_seconds * 30)
    sends = collections.defaultdict(list)  # unit -> [(frame, on, reassert)]
    shots = collections.defaultdict(list)  # unit -> [frame]
    with open(args.log, encoding='utf-8', errors='replace') as log:
        for line in log:
            m = CLOAK.search(line)
            if m:
                sends[m[1]].append((int(m[4]), m[2] == '1', bool(m[3])))
                continue
            m = SHOT.search(line)
            if m:
                f = FRAME.search(line) or FRAME_PREFIX.search(line)
                if f: shots[m[1]].append(int(f[1]))
    report = {'uncloak_limit_frames': limit, 'commanders': {}}
    violations = 0
    for unit in sorted(set(sends) | set(shots), key=int):
        rows = sends[unit]
        offs = [f for f, on, _ in rows if not on]
        gaps = [b - a for a, b in zip(offs, offs[1:])]
        bad = [g for g in gaps if g < limit]
        violations += len(bad)
        after = []
        for shot in sorted(set(shots[unit])):
            nxt = next(((f, on) for f, on, _ in rows if f >= shot), None)
            after.append({'shot_frame': shot,
                          'next_send': None if nxt is None else ('on' if nxt[1] else 'off'),
                          'seconds_after_shot': None if nxt is None else round((nxt[0] - shot) / 30, 1)})
        report['commanders'][unit] = {
            'cloak_on': sum(1 for _, on, r in rows if on and not r),
            'cloak_reassert': sum(1 for _, on, r in rows if on and r),
            'cloak_off': len(offs),
            'min_off_gap_seconds': round(min(gaps) / 30, 2) if gaps else None,
            'off_gaps_under_limit': len(bad),
            'shots': after,
        }
    report['violations'] = violations
    print(json.dumps(report, indent=2))
    return 1 if violations else 0


if __name__ == '__main__':
    sys.exit(main())
