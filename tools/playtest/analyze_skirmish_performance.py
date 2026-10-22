"""Summarize observer evidence; no FPS/CPU attribution is inferred from APM."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re


def analyze(text):
    minutes, scopes, orders, origins, lanes, post = [], [], [], [], [], []
    game_over_frames, team_deaths = [], []
    log_counts = Counter()
    invariant_counts = Counter()
    errors = []
    for line in text.splitlines():
        ended = re.search(r'\[SkirmishPerfEnd\] frame=(\d+)', line)
        if ended:
            game_over_frames.append(int(ended[1]))
        died = re.search(r'\[SkirmishPerfTeamDied\] frame=(\d+) team=(\d+)', line)
        if died:
            team_deaths.append(dict(frame=int(died[1]), team=int(died[2])))
        frame = re.search(r'\[f=(\d+)\]', line)
        minute = int(frame[1]) // 1800 if frame else -1
        if 'RESERVE:' in line:
            log_counts[minute] += 1
        invariant = re.search(r'\[INVARIANT\]\s+(INV-\d+)', line)
        if invariant:
            invariant_counts[invariant[1]] += 1
        if re.search(r': ERR\s+:|SCRIPT CRASH|Error in GameFrame\(\)|Access violation|Fatal:', line):
            errors.append(line)
        timer = re.search(r'\[SkirmishPerf\] (.*)', line)
        if timer:
            row = {k: float(v) for k, v in re.findall(r'(\w+)=([\d.]+)', timer[1])}
            row['profiling'] = row.get('profiling', 1)
            minutes.append(row)
        scope = re.search(r'\[SkirmishScope\] frame=(\d+) name=(.*?) total_ms=([\d.]+) interval_ms=([\d.]+)', line)
        if scope:
            scopes.append(dict(frame=int(scope[1]), name=scope[2], total_ms=float(scope[3]), interval_ms=float(scope[4])))
        command = re.search(r'\[AirOrders\] frame=(\d+) team=(\d+) all_apm=(\d+) air_apm=(\d+) repeated=(\d+)', line)
        if command:
            orders.append(dict(zip(('frame', 'team', 'all', 'air', 'repeated_air_signature'), map(int, command.groups()))))
        origin = re.search(r'\[CommandOrigin\] frame=(\d+) team_source=(\d+):(\w+) count=(\d+)', line)
        if origin:
            origins.append(dict(frame=int(origin[1]), team=int(origin[2]), source=origin[3], count=int(origin[4])))
        lane = re.search(r'LANE_PERF (.*)', line)
        if lane:
            lanes.append({k: float(v) for k, v in re.findall(r'(\w+)=([\d.]+)', lane[1])})
        lp = re.search(r'LANE_POST team=(\d+) revision=(\d+) main_ms=([\d.]+)', line)
        if lp:
            post.append(dict(team=int(lp[1]), revision=int(lp[2]), main_ms=float(lp[3])))
    peak = max(orders, key=lambda r: r['all'], default=None)
    frames = sorted({r['frame'] for r in orders})
    totals = [dict(frame=f, all=sum(r['all'] for r in orders if r['frame'] == f)) for f in frames]
    return dict(minutes=minutes, scopes=scopes, orders=orders, origins=origins,
                game_over_frames=game_over_frames, team_deaths=team_deaths,
                lane_solve=lanes, lane_post=post, reservation_logs_by_minute=dict(log_counts),
                invariants=dict(invariant_counts), errors=errors, peak_team_apm=peak,
                peak_all_teams_apm=max(totals, key=lambda r: r['all'], default=None),
                measurement_notes=['AI timer covers all local AI callbacks, excludes asynchronous worker duration.',
                                   'Scopes overlap; do not add them or interpret AddTime as main-thread CPU.',
                                   'FPS windows include brief scheduled screenshot settling unless explicitly excluded.',
                                   'UnitCommand events include game/Lua orders; nonlua is not an exact network-packet count.',
                                   'Profiling-disabled AI deltas are unavailable, not zero AI work.'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    result = analyze((args.directory / 'infolog.txt').read_text(errors='replace'))
    (args.directory / 'skirmish-performance.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(normal_speed=[r for r in result['minutes'] if r['speed_wanted'] == 1],
                          peak_team_apm=result['peak_team_apm'], peak_all_teams_apm=result['peak_all_teams_apm'],
                          reservation_logs=sum(result['reservation_logs_by_minute'].values()),
                          invariants=result['invariants'], errors=len(result['errors'])), indent=2))


if __name__ == '__main__':
    main()
