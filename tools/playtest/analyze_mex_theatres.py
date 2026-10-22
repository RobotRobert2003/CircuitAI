"""Mex ownership by theatre from a natural game's [MexTheatre] census.

Joins the staged teams.json (team -> role, ally, start) with the
mex_theatre_watch.lua census lines in the run's infolog and the AI's own
[MexTerritory] classification when present. Prints per-role extractor counts
by theatre at the requested minutes and lists every naval extractor held by a
team whose role is not SEA while a SEA ally shares its side (the reported
symptom), plus spots nobody has taken. Writes <game>/mex-theatres.json.
"""
import argparse
import collections
import json
import re
import sys
from pathlib import Path

CENSUS = re.compile(r'\[MexTheatre\] census minute=(\d+) team=(\d+) ally=(-?\d+) dead=(\w+) land=(\d+) shallow=(\d+) '
                    r'naval=(\d+) unfinished=(\d+) metalIncome=([\d.]+) navalAt=(\S*)(?: allAt=(\S*))?')
SPOT = re.compile(r'\[MexTheatre\] spot (\d+) x=(-?\d+) z=(-?\d+) y=(-?\d+) kind=(\w+)')
# Proposed native dump (mex-theatres-proposal.md section 4.1); the race fields are optional
# so a LAND or sea-rule line without them still parses.
TERRITORY = re.compile(r'\[MexTerritory\] team=(\d+) frame=(\d+) spot=(\d+) x=(-?\d+) z=(-?\d+) (?:theatre|mask)=(\w+)'
                       r'(?: rule=([\w-]+))? owner=(-?\d+)(?: arrive=(-?[\d.]+) secure=(-?[\d.]+) enemy=(-?[\d.]+))?(?: lane=(-?\d+))?')


def latest_run(game):
    """The newest run holding an infolog, or a pruned run's telemetry.jsonl (D-339 keeps it)."""
    runs = sorted(p for p in (game / 'runs').glob('*')
                  if (p / 'infolog.txt').exists() or (p / 'telemetry.jsonl').exists())
    if not runs:
        sys.exit(f'no run with an infolog or telemetry under {game}')
    return runs[-1]


def log_lines(run):
    if (run / 'infolog.txt').exists():
        with open(run / 'infolog.txt', encoding='utf-8', errors='replace') as src:
            yield from src
        return
    with open(run / 'telemetry.jsonl', encoding='utf-8') as src:
        for line in src:
            yield json.loads(line)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('game', type=Path, help='the allocated game directory (holds teams.json and runs/)')
    parser.add_argument('--minutes', default='5,10,15,20')
    args = parser.parse_args()
    game = args.game
    teams = {int(t['team']): t for t in json.loads((game / 'teams.json').read_text(encoding='utf-8'))['teams']}
    run = latest_run(game)
    minutes = [int(m) for m in args.minutes.split(',')]
    census = collections.defaultdict(dict)   # minute -> team -> row
    spots = {}
    territory = {}                            # (team, spot) -> latest classification
    if True:
        for line in log_lines(run):
            m = CENSUS.search(line)
            if m:
                minute, team = int(m.group(1)), int(m.group(2))
                census[minute][team] = {'ally': int(m.group(3)), 'dead': m.group(4) == 'true',
                                        'land': int(m.group(5)), 'shallow': int(m.group(6)), 'naval': int(m.group(7)),
                                        'unfinished': int(m.group(8)), 'metalIncome': float(m.group(9)),
                                        'navalAt': [p for p in m.group(10).split(';') if p],
                                        'allAt': [p for p in (m.group(11) or '').split(';') if p]}
                continue
            m = SPOT.search(line)
            if m:
                spots[int(m.group(1))] = {'x': int(m.group(2)), 'z': int(m.group(3)), 'y': int(m.group(4)), 'kind': m.group(5)}
                continue
            m = TERRITORY.search(line)
            if m:
                territory[(int(m.group(1)), int(m.group(3)))] = {'frame': int(m.group(2)), 'x': int(m.group(4)), 'z': int(m.group(5)),
                                                                 'theatre': m.group(6), 'rule': m.group(7), 'owner': int(m.group(8)),
                                                                 'arrive': m.group(9), 'secure': m.group(10), 'enemy': m.group(11), 'lane': m.group(12)}
    if not census:
        sys.exit('no [MexTheatre] census lines; was mex_theatre_watch.lua staged?')
    sea_allies = {t['ally'] for t in teams.values() if t['role'] == 'SEA'}
    report = {'game': str(game), 'run': run.name, 'map': teams[0].get('map') if teams else None,
              'spots': {'total': len(spots), **collections.Counter(s['kind'] for s in spots.values())},
              'minutes': {}, 'symptoms': [], 'territory_classes': dict(collections.Counter(v['theatre'] for v in territory.values()))}
    lines = []
    for minute in minutes:
        rows = census.get(minute)
        if not rows:
            lines.append(f'minute {minute}: no census')
            continue
        by_role = collections.defaultdict(lambda: {'land': 0, 'shallow': 0, 'naval': 0, 'teams': 0})
        taken = 0
        held_naval = []
        held_all = {}  # position -> role, when the widget logged every extractor
        for team, row in rows.items():
            if team not in teams:
                continue  # Gaia or a spectator team: no AI, no extractors of interest
            role = teams[team]['role']
            held_naval += row['navalAt']
            for p in row['allAt']:
                held_all[tuple(int(v) for v in p.split(':'))] = role
            if role == 'SEA':
                report.setdefault('sea_naval', {}).setdefault(minute, {})[team] = row['naval']
            for kind in ('land', 'shallow', 'naval'):
                by_role[role][kind] += row[kind]
                taken += row[kind]
            by_role[role]['teams'] += 1
            if role != 'SEA' and row['naval'] and teams[team]['ally'] in sea_allies:
                report['symptoms'].append({'minute': minute, 'team': team, 'role': role, 'navalAt': row['navalAt']})
        held = [tuple(int(v) for v in p.split(':')) for p in held_naval]
        untaken = [s for s in spots.values() if s['kind'] == 'naval'
                   and not any((s['x'] - x) ** 2 + (s['z'] - z) ** 2 <= 64 * 64 for x, z in held)]
        report['minutes'][minute] = {'by_role': dict(by_role), 'taken': taken, 'spots': len(spots),
                                     'untaken_naval': [(s['x'], s['z']) for s in untaken]}
        lines.append(f'minute {minute}: {taken}/{len(spots)} spots taken; naval untaken {len(untaken)}'
                     + (': ' + ', '.join(f'{s["x"]}:{s["z"]}' for s in untaken) if untaken else ''))
        for role in sorted(by_role):
            r = by_role[role]
            lines.append(f'  {role:8s} x{r["teams"]}: land={r["land"]:3d} shallow={r["shallow"]:3d} naval={r["naval"]:3d}')
        sea = report.get('sea_naval', {}).get(minute)
        if sea:
            lines.append('  naval per SEA team: ' + ', '.join(f'{t}:{n}' for t, n in sorted(sea.items())))
        if held_all:
            # Elevation tells summits from valleys: list the highest untaken land
            # spots and who holds the high ones (air-only ground in practice).
            def holder(s):
                for (x, z), role in held_all.items():
                    if (s['x'] - x) ** 2 + (s['z'] - z) ** 2 <= 64 * 64:
                        return role
                return None
            land = sorted((s for s in spots.values() if s['kind'] == 'land'), key=lambda s: -s['y'])
            high = land[:max(1, len(land) // 8)]
            by = collections.Counter(holder(s) or 'untaken' for s in high)
            lines.append(f'  highest eighth of land spots (y >= {high[-1]["y"]}): ' + ', '.join(f'{k}={v}' for k, v in sorted(by.items(), key=lambda kv: str(kv[0]))))
            open_land = [s for s in land if holder(s) is None]
            lines.append(f'  untaken land spots {len(open_land)}, highest: ' + ', '.join(f'{s["x"]}:{s["z"]}@{s["y"]}' for s in open_land[:10]))
            report['minutes'][minute]['high_land_holders'] = dict(by)
            report['minutes'][minute]['untaken_land'] = [(s['x'], s['z'], s['y']) for s in open_land]
    lines.append(f'spots: {report["spots"]}')
    if territory:
        # D-352 acceptance: every ally on a side resolves the same owner and rule
        # for every spot (determinism), and the rule histogram per side.
        by_spot = collections.defaultdict(dict)   # (ally, spot) -> team -> (owner, rule)
        for (team, spot), v in territory.items():
            if team in teams:
                by_spot[(teams[team]['ally'], spot)][team] = (v['owner'], v['theatre'], v['rule'])
        disagreements = [(k, vals) for k, vals in by_spot.items() if len({(o, r) for o, _, r in vals.values()}) > 1]
        rules = collections.Counter(v['rule'] for (team, _), v in territory.items() if team in teams)
        owners_by_rule = collections.defaultdict(collections.Counter)
        for (team, spot), v in territory.items():
            if team in teams and v['owner'] >= 0 and v['owner'] in teams:
                owners_by_rule[v['rule']][teams[v['owner']]['role']] += 1
        lines.append(f'territory dumps: {len(territory)} spot records from {len({t for t, _ in territory})} teams; rules {dict(rules)}')
        for rule, roles in sorted(owners_by_rule.items(), key=lambda kv: str(kv[0])):
            lines.append(f'  rule {rule}: owners by role ' + ', '.join(f'{r}={n}' for r, n in roles.most_common()))
        lines.append(f'  ally disagreements (same side, different owner or rule for a spot): {len(disagreements)}')
        for (ally, spot), vals in disagreements[:10]:
            lines.append(f'    ally {ally} spot {spot}: ' + '; '.join(f'team {t} -> owner {o} rule {r}' for t, (o, _, r) in sorted(vals.items())))
        report['territory_rules'] = dict(rules)
        report['territory_disagreements'] = len(disagreements)
        report['territory_owners_by_rule'] = {str(k): dict(v) for k, v in owners_by_rule.items()}
    sym = report['symptoms']
    lines.append(f'naval extractors held by non-SEA roles on a side with SEA: {len(sym)} team-minutes')
    for s in sym:
        lines.append(f'  minute {s["minute"]:2d} team {s["team"]:2d} {s["role"]:8s} at {", ".join(s["navalAt"])}')
    if territory:
        lines.append(f'AI territory classes: {report["territory_classes"]}')
    (game / 'mex-theatres.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print('\n'.join(lines))
    print('written', game / 'mex-theatres.json')


if __name__ == '__main__':
    main()
