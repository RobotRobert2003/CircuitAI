"""Summarize physical SEA patrol/AA evidence without rewriting a run verdict.

Usage: python tools/playtest/analyze_sea_patrol.py <archived-run>
Positions and queues come from the engine observer. Formation log lines prove
assignment only; they do not prove physical separation or a successful kill.
"""
import argparse
import json
import math
import re
from collections import defaultdict
from pathlib import Path


def analyze(lines):
    samples = defaultdict(dict)
    spawned, deaths, attacks, formations, patrols, orders = {}, [], [], [], [], []
    for line in lines:
        m = re.search(r'\[SeaArena\] frame=(\d+) boat id=(\d+) x=(-?\d+) z=(-?\d+) patrol=(true|false) target=(-?\d+)', line)
        if m:
            frame, uid, x, z, patrol, target = m.groups()
            samples[int(frame)][int(uid)] = (int(x), int(z), patrol == 'true', int(target))
        m = re.search(r'\[SeaArena\] frame=(\d+) spawn id=(\d+) team=(\d+) unit=(\w+)', line)
        if m:
            frame, uid, team, unit = m.groups()
            spawned[int(uid)] = dict(frame=int(frame), team=int(team), unit=unit)
        m = re.search(r'\[SeaArena\] frame=(\d+) death id=(\d+) team=(\d+).*attackerTeam=(\w+)', line)
        if m:
            deaths.append(dict(zip(('frame', 'id', 'team', 'attacker'), m.groups())))
        m = re.search(r'\[SeaArena\] frame=(\d+) damage.*team=0 amount=([\d.]+) attackerUnit=(\w+) victimUnit=(\w+)', line)
        if m:
            attacks.append(dict(frame=int(m[1]), amount=float(m[2]), attacker=m[3], victim=m[4]))
        m = re.search(r':F:(\d+):L::\[SEA\]\[AAFormation\] id=(\d+).*slot=(\d+).*goal=(-?\d+),(-?\d+)', line)
        if m:
            formations.append(dict(frame=int(m[1]), id=int(m[2]), slot=int(m[3]), x=int(m[4]), z=int(m[5])))
        m = re.search(r'\[SeaArena\] frame=(\d+) orders team=0 apm=(\d+) repeated=(\d+)', line)
        if m:
            orders.append(dict(frame=int(m[1]), orders=int(m[2]), repeated=int(m[3])))
    def physical_sample(frame, units):
        points = list(units.values())
        if not points:
            return dict(frame=frame, live=0, patrol=0, priority_fire=0, width=0, depth=0, mean_nearest=0, min_nearest=0)
        nearest = [min((math.hypot(p[0]-q[0], p[1]-q[1]) for j, q in enumerate(points) if i != j), default=0)
                   for i, p in enumerate(points)]
        return dict(frame=frame, live=len(points), patrol=sum(p[2] for p in points),
                            priority_fire=sum(p[3] >= 0 for p in points),
                            width=max(p[0] for p in points)-min(p[0] for p in points),
                            depth=max(p[1] for p in points)-min(p[1] for p in points),
                            mean_nearest=round(sum(nearest)/len(nearest), 1),
                            min_nearest=round(min(nearest), 1))
    responders = set(f['id'] for f in formations)
    aa_samples = []
    for frame, units in sorted(samples.items()):
        patrols.append(physical_sample(frame, units))
        aa_samples.append(physical_sample(frame, {uid: p for uid, p in units.items() if uid in responders}))
    # These are the explicit aircraft in this fixture family, not a guess that
    # every enemy death is an air kill. Ignore administrative removal at 210s.
    aircraft = {'armbrawl', 'armthund', 'corvalk'}
    first_air = min((u['frame'] for u in spawned.values() if u['team'] == 1 and u['unit'] in aircraft), default=None)
    kills = [d for d in deaths if d['team'] == '1' and d['attacker'] == '0' and int(d['frame']) < 6300
             and spawned.get(int(d['id']), {}).get('unit') in aircraft]
    return dict(schema=1, spawned=spawned, aircraft_kills_before_fixture_removal=len(kills),
                friendly_deaths=sum(d['team'] == '0' for d in deaths),
                physical_air_damage=round(sum(a['amount'] for a in attacks if a['victim'] in aircraft), 1),
                first_air_spawn_frame=first_air,
                first_formation_frame=formations[0]['frame'] if formations else None,
                responders=sorted(responders),
                responder_types=sorted(set(spawned.get(f['id'], {}).get('unit', 'unknown') for f in formations)),
                orders_per_game_minute=orders, physical_samples=patrols, aa_physical_samples=aa_samples,
                limitations=['Orders are engine commands, not network packets or FPS measurements.',
                             'Distinct destinations do not guarantee minimum spacing while ships cross paths.',
                             'Supplied forces do not test economic affordability or victory.'])


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('archive', type=Path)
    a = p.parse_args()
    with (a.archive/'infolog.txt').open(encoding='utf-8', errors='replace') as lines:
        result = analyze(lines)
    output = a.archive/'sea-patrol-analysis.json'
    if output.exists():
        raise SystemExit('Analysis already exists; retain immutable evidence and use another run/revision.')
    output.write_text(json.dumps(result, indent=2, sort_keys=True)+'\n', encoding='utf-8')
    print(output)


if __name__ == '__main__':
    main()
