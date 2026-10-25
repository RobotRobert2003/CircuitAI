"""Report the [SupWatch] lines of tools/playtest/widgets/support_factory_watch.lua.

    python tools/playtest/support_factory_report.py <run dir> [--profile experimental_balanced] [--role SUPPORT]

Per team of the role: the construction turrets within reach of each T2 factory
at chosen minutes, and every factory's output against the profile's
factory.json / factory_leg.json weights (each unit's share of what the factory
built beside its normalized weight per income tier, land rows).
"""
import argparse
import collections
import json
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
LINE = re.compile(r'\[SupWatch\] t=(\d+):(\d+) (.*)')


def fields(text):
    return dict(kv.split('=', 1) for kv in text.split() if '=' in kv)


def load_weights(profile):
    config = HERE.parent.parent/'data'/'config'
    weights = {}
    for name in ('factory.json', 'factory_leg.json'):
        path = config/profile/name
        if not path.exists():
            path = config/name
        if not path.exists():
            continue
        text = re.sub(r'//.*', '', path.read_text(encoding='utf8'))
        weights.update(json.loads(text).get('factory', {}))
    return weights


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('run', type=Path)
    parser.add_argument('--profile', default='experimental_balanced')
    parser.add_argument('--role', default='SUPPORT')
    parser.add_argument('--minutes', default='10,15,20,25')
    args = parser.parse_args()
    minutes = [int(m) for m in args.minutes.split(',')]
    turrets = collections.defaultdict(dict)      # (team, role, factory, id) -> minute -> turrets
    built = collections.defaultdict(collections.Counter)   # (team, role, factory) -> unit -> n
    log = args.run/'infolog.txt'
    for line in log.read_text(encoding='utf8', errors='replace').splitlines():
        m = LINE.search(line)
        if not m:
            continue
        minute = int(m.group(1))
        f = fields(m.group(3))
        if m.group(3).startswith('built'):
            built[(int(f['team']), f['role'], f['factory'])][f['unit']] += 1
        elif 'turrets' in f:
            turrets[(int(f['team']), f['role'], f['factory'], f['id'])][minute] = (int(f['turrets']), int(f['frames']), int(f['team_turrets']))
    weights = load_weights(args.profile)

    print('## Turrets within reach of each T2 factory (standing+frames, team total)\n')
    print('| team | role | factory | ' + ' | '.join(f'{m} min' for m in minutes) + ' |')
    print('|---|---|---|' + '---|' * len(minutes))
    for key in sorted(turrets):
        team, role, factory, _ = key
        cells = []
        for m in minutes:
            v = turrets[key].get(m)
            cells.append('-' if v is None else f'{v[0]}+{v[1]} ({v[2]})')
        print(f'| {team} | {role} | {factory} | ' + ' | '.join(cells) + ' |')

    print(f'\n## {args.role} factory output against {args.profile} weights (land rows)\n')
    for (team, role, factory), counter in sorted(built.items()):
        if role != args.role:
            continue
        total = sum(counter.values())
        entry = weights.get(factory)
        print(f'### team {team} {factory}: {total} units\n')
        if not entry:
            for unit, n in counter.most_common():
                print(f'- {unit}: {n}')
            print()
            continue
        units = entry['unit']
        tiers = sorted(entry.get('land', {}))
        normalized = {}
        for tier in tiers:
            row = entry['land'][tier]
            s = sum(row) or 1.0
            normalized[tier] = {u: w / s for u, w in zip(units, row)}
        print('| unit | built | share | ' + ' | '.join(f'json {t}' for t in tiers) + ' |')
        print('|---|---|---|' + '---|' * len(tiers))
        for unit in sorted(set(units) | set(counter), key=lambda u: -counter[u]):
            n = counter[unit]
            if n == 0 and all(normalized[t].get(unit, 0) == 0 for t in tiers):
                continue
            note = '' if unit in units else ' (not in json)'
            print(f'| {unit}{note} | {n} | {n / total:.0%} | ' + ' | '.join(f'{normalized[t].get(unit, 0):.0%}' for t in tiers) + ' |')
        print()


if __name__ == '__main__':
    main()
