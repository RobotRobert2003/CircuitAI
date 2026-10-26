"""Summarise the lolcannon program in a playtest infolog (owner 2026-10-26).

Joins the script's [LolCannon] lines (gates, site, REPORT framed / finished /
first_target, crews) with the native CSuperTask TIER lines (TIER: team=N ...)
per AI team:
  - when the gates opened and where the site went;
  - when the cannon was ordered, framed and finished, and its build time;
  - turrets and storages standing beside it at the finish, crew sizes;
  - its first target (def, tier, distance) and when, from finish;
  - the AIR scout sweep the finish asked for.
Prints a table and writes <infolog dir>/lolcannon.json.

    python tools/playtest/analyze_lolcannon.py <infolog.txt> [--label forge+65]
"""
import argparse
import json
import re
from pathlib import Path

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument('infolog', type=Path)
ap.add_argument('--label', default='')
a = ap.parse_args()

AI = r':::AI LOG:S:\d+:T:(\d+):F:(\d+):L::'
re_gates = re.compile(AI + r'\[LolCannon\] gates open: (.*)')
re_site = re.compile(AI + r'\[LolCannon\] site for (\S+) \(range (\d+)\) at \((\d+), (\d+)\), facing (\d), (\d+) from home, ground (\d+)%')
re_nosite = re.compile(AI + r'\[LolCannon\] no site for.*?(?:\((cannon refused \d+, turrets short \d+, best \d+/\d+)\))?; retry')
re_framed = re.compile(AI + r'\[LolCannon\] REPORT framed at=(-?\d+)s ordered=(-?\d+)s')
re_done = re.compile(AI + r'\[LolCannon\] REPORT finished (.*)')
re_first = re.compile(AI + r'\[LolCannon\] REPORT first_target unit=(\d+) enemy=(-?\d+) at=(\d+)s after_finish=(\d+)s(.*)')
re_sweep = re.compile(AI + r'\[LolCannon\] scout sweep asked of AIR=(\d+): (\d+) T1 scouts, (\d+) radar')
re_air = re.compile(AI + r'\[AIR\]\[ScoutSweep\] lolcannon request from (\d+)')
re_tier = re.compile(r'TIER: team=(\d+) frame=(\d+) (\S+)\((\d+)\): tier (\d) (\S+)\((\d+)\) cost=(\d+) at \((-?\d+),(-?\d+)\), (\d+) away(.*)')
re_kv = re.compile(r'(\w+)=(\S+)')

teams = {}
def team(t):
    return teams.setdefault(int(t), {'gates': None, 'site': None, 'no_site': 0, 'no_site_why': None, 'cannons': [], 'framed': [], 'tiers': {},
                                     'first': [], 'sweep': None, 'air_got_sweep': False})

with open(a.infolog, encoding='utf-8', errors='replace') as f:
    for line in f:
        if 'LolCannon' not in line and 'TIER:' not in line and 'ScoutSweep' not in line:
            continue
        if m := re_gates.search(line):
            t = team(m[1]); t['gates'] = t['gates'] or {'second': int(m[2]) // 30, 'why': m[3].strip()}
        elif m := re_site.search(line):
            team(m[1])['site'] = {'def': m[3], 'range': int(m[4]), 'x': int(m[5]), 'z': int(m[6]), 'from_home': int(m[8]), 'ground': int(m[9])}
        elif m := re_nosite.search(line):
            t = team(m[1]); t['no_site'] += 1; t['no_site_why'] = m[3] or t['no_site_why']
        elif m := re_framed.search(line):
            team(m[1])['framed'].append({'framed': int(m[3]), 'ordered': int(m[4])})
        elif m := re_done.search(line):
            team(m[1])['cannons'].append(dict(re_kv.findall(m[3])))
        elif m := re_first.search(line):
            team(m[1])['first'].append({'unit': int(m[3]), 'enemy': int(m[4]), 'at': int(m[5]), 'after_finish': int(m[6]), 'note': m[7].strip()})
        elif m := re_sweep.search(line):
            team(m[1])['sweep'] = {'air': int(m[3]), 't1': int(m[4]), 'radar': int(m[5])}
        elif m := re_air.search(line):
            for t in teams.values():
                if t['sweep'] and t['sweep']['air'] == int(m[1]):
                    t['air_got_sweep'] = True
        elif m := re_tier.search(line):
            t = team(m[1])
            t['tiers'].setdefault(int(m[4]), []).append({'frame': int(m[2]), 'tier': int(m[5]), 'def': m[6], 'enemy': int(m[7]),
                                                         'cost': int(m[8]), 'distance': int(m[11]), 'seen': 'last seen' not in m[12]})

rows = []
for tid, t in sorted(teams.items()):
    if not (t['gates'] or t['site'] or t['cannons'] or t['no_site']):
        continue
    for i, c in enumerate(t['cannons'] or [{}]):
        unit = int(c.get('unit', '-1'))
        first = next((x for x in t['first'] if x['unit'] == unit), None)
        tier = (t['tiers'].get(unit) or [None])[0]
        rows.append({'team': tid, 'cannon': c.get('cannon', '-'), 'def': c.get('def', (t['site'] or {}).get('def', '-')),
                     'gates_s': (t['gates'] or {}).get('second'), 'ordered': c.get('ordered'), 'framed': c.get('framed'),
                     'finished': c.get('finished'), 'build': c.get('build'), 'nanos': c.get('nanos'), 'storages': c.get('storages'),
                     'crews': c.get('crews'), 'site': t['site'], 'no_site_logs': t['no_site'], 'no_site_why': t['no_site_why'],
                     'first_target': tier, 'first_target_report': first, 'sweep': t['sweep'], 'air_got_sweep': t['air_got_sweep']})

print(f"lolcannon {a.label} ({a.infolog})")
print(f"{'team':>4} {'#':>2} {'def':<12} {'gates':>6} {'ordered':>8} {'framed':>7} {'finished':>8} {'build':>6} {'nanos':>6} {'stores':>6}  first target")
for r in rows:
    ft = r['first_target']
    ftxt = f"t{ft['tier']} {ft['def']} {ft['distance']}" if ft else ('none' if r['finished'] else '-')
    if not r['site'] and r['no_site_logs']:
        ftxt = f"no site x{r['no_site_logs']} ({r['no_site_why'] or 'no reason logged'})"
    print(f"{r['team']:>4} {r['cannon']:>2} {r['def']:<12} {str(r['gates_s']):>6} {str(r['ordered']):>8} {str(r['framed']):>7} "
          f"{str(r['finished']):>8} {str(r['build']):>6} {str(r['nanos']):>6} {str(r['storages']):>6}  {ftxt}")
out = a.infolog.parent / 'lolcannon.json'
out.write_text(json.dumps({'label': a.label, 'rows': rows}, indent=1))
print(f"written {out}")
