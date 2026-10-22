"""Per-team AI command metrics from a replay, kept after the raw files are pruned.

KI-655: BAR test-31677 refuses widgetHandler.UnitCommand to user widgets, so
the command observer is blind. The replay still records every AI command
packet (Recoil SendAICommand), so this reads it once, streamed, and writes
commands-summary.json next to the run's results:

  per team: packets, per-command counts, MOVE packets, MOVE queues (one queue
  = the MOVEs one unit received in one replay frame), mean/p95/max queue
  length, queues of 10+ waypoints, and the share of those long queues'
  waypoints that are collinear (heading change <= 0.02 rad, so a straight-run
  reduction could drop them); plus packets per game minute.

Cost: O(replay bytes); memory O(MOVE packets in one frame) plus per-team
counters. Lua-issued orders and batched AICOMMANDS are not decoded (see
replay_ai_commands.py). Packets are ordered by replay frame, not decision frame.

  python tools/playtest/replay_command_summary.py <replay.sdfz> <out.json>
"""
import argparse, json, math, sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from replay_ai_commands import commands  # noqa: E402

CMD_MOVE = 10
LONG = 10


def turns(points, tolerance=0.02):
    count = 0
    for i in range(1, len(points) - 1):
        a = math.atan2(points[i][1] - points[i - 1][1], points[i][0] - points[i - 1][0])
        b = math.atan2(points[i + 1][1] - points[i][1], points[i + 1][0] - points[i][0])
        if abs((b - a + math.pi) % (2 * math.pi) - math.pi) > tolerance:
            count += 1
    return count


def summarise(replay):
    packets, moves = Counter(), Counter()
    kinds = defaultdict(Counter)
    minutes = defaultdict(Counter)
    lengths = defaultdict(list)
    long_points, long_needed = Counter(), Counter()
    frame, open_queues = None, {}

    def close():
        for (team, _), points in open_queues.items():
            lengths[team].append(len(points))
            if len(points) >= LONG:
                long_points[team] += len(points)
                long_needed[team] += turns(points) + 2
        open_queues.clear()

    for row in commands(replay):
        if row.get('undecoded') or 'team' not in row:
            continue
        if row['frame'] != frame:
            close(); frame = row['frame']
        team = row['team']
        packets[team] += 1; kinds[team][row['command']] += 1
        minutes[team][row['frame'] // 1800] += 1
        if row['command'] == CMD_MOVE and len(row['parameters']) >= 3:
            moves[team] += 1
            p = row['parameters']
            open_queues.setdefault((team, row['unit']), []).append((p[0], p[2]))
    close()
    last = max((m for c in minutes.values() for m in c), default=0)
    teams = {}
    for team in sorted(packets):
        q = sorted(lengths[team])
        teams[str(team)] = dict(
            packets=packets[team], move=moves[team], move_queues=len(q),
            mean_queue=round(sum(q) / len(q), 2) if q else 0,
            p95_queue=q[int(len(q) * .95)] if q else 0, max_queue=q[-1] if q else 0,
            queues_ge10=sum(1 for n in q if n >= LONG), long_waypoints=long_points[team],
            long_collinear_share=round(1 - long_needed[team] / long_points[team], 3) if long_points[team] else 0,
            commands={str(k): v for k, v in kinds[team].most_common()},
            per_minute=[minutes[team][m] for m in range(last + 1)])
    return {'schema': 1, 'source': 'replay AI command packets (type 14); Lua orders absent',
            'replay': Path(replay).name, 'total_packets': sum(packets.values()), 'teams': teams}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('replay'); ap.add_argument('out')
    a = ap.parse_args()
    value = summarise(a.replay)
    Path(a.out).write_text(json.dumps(value, indent=1) + '\n')
    print(f"{value['total_packets']} AI command packets -> {a.out}")


if __name__ == '__main__':
    main()
