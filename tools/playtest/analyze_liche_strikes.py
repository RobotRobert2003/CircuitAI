"""Count Liche escort strikes in a playtest infolog (owner 2026-10-24).

Joins the AI's native CEscortStrikeTask lines (ESCORT: team=N ...) with the
liche_strike_fixture.lua widget lines ([LicheStrike] ...):
  - Liches launched with a wave, strikes ordered and the target each chose;
  - Liches that fired (a weapon release on their strike) and the kills a Liche
    made (widget: attacker def armliche);
  - Liches lost before they fired, after they fired, and to what.
Prints a table and writes <infolog dir>/liche-strikes.json.

    python tools/playtest/analyze_liche_strikes.py <infolog.txt> [--team 0]
"""
import argparse
import collections
import json
import re
from pathlib import Path

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument('infolog', type=Path)
ap.add_argument('--team', type=int, default=0)
a = ap.parse_args()
team = a.team

launched = 0
launches = []
strikes = []                      # (unit, target def, target id, distance)
struck_units = set()
fired_units = set()
lost = []                         # (unit, fired, striking)
overs = collections.Counter()
vip_swaps = 0
releases = 0
widget = {'born': 0, 'lost': [], 'kills': [], 'targets': []}
tally = None

re_launch = re.compile(r'T:%d:F:(\d+):L::\[AIR\]\[Liche\] launched liches=(\d+)' % team)
re_strike = re.compile(r'ESCORT: team=%d strike unit=(\d+) target=(\S+)\((\d+)\) priority=([\d.]+) distance=(\d+)' % team)
re_fired = re.compile(r'ESCORT: team=%d fired unit=(\d+) target=(-?\d+)' % team)
re_lost = re.compile(r'ESCORT: team=%d lost unit=(\d+) fired=(\d) striking=(\d) target=(-?\d+)' % team)
re_over = re.compile(r'ESCORT: team=%d strike over unit=(\d+) target=(-?\d+) reason=([a-z ]+) fired=(\d) targetGone=(\d)' % team)
re_vip = re.compile(r'ESCORT: team=%d vip (-?\d+) -> (-?\d+)' % team)
re_release = re.compile(r'ESCORT: team=%d release unit=' % team)
re_w = re.compile(r'\[LicheStrike\] (\S+)(.*)')

with a.infolog.open(encoding='utf-8', errors='replace') as f:
    for line in f:
        if 'ESCORT:' not in line and '[Liche' not in line:
            continue
        m = re_launch.search(line)
        if m:
            launched += int(m[2]); launches.append((int(m[1]), int(m[2]))); continue
        m = re_strike.search(line)
        if m:
            strikes.append((int(m[1]), m[2], int(m[3]), int(m[5]))); struck_units.add(int(m[1])); continue
        m = re_fired.search(line)
        if m:
            fired_units.add(int(m[1])); continue
        m = re_lost.search(line)
        if m:
            lost.append((int(m[1]), m[2] == '1', m[3] == '1')); continue
        m = re_over.search(line)
        if m:
            overs[m[3]] += 1; continue
        m = re_vip.search(line)
        if m:
            if m[1] != '-1': vip_swaps += 1
            continue
        if re_release.search(line):
            releases += 1; continue
        m = re_w.search(line)
        if m:
            kind, rest = m[1], m[2]
            if kind == 'liche-born': widget['born'] += 1
            elif kind == 'liche-lost': widget['lost'].append(rest.strip())
            elif kind == 'liche-kill': widget['kills'].append(rest.strip())
            elif kind == 'target-destroyed': widget['targets'].append(rest.strip())
            elif kind == 'tally': tally = rest.strip()

chosen = collections.Counter(s[1] for s in strikes)
lost_before = [l for l in lost if not l[1]]
lost_after = [l for l in lost if l[1]]
lost_before_striking = [l for l in lost_before if not l[2] and l[0] not in struck_units]
kill_defs = collections.Counter(re.search(r'victim=(\S+)', k)[1] for k in widget['kills'])
lost_to = collections.Counter(re.search(r'by=(\S+)', l)[1] for l in widget['lost'])
summary = {
    'team': team,
    'liches_supplied_widget': widget['born'],
    'liches_launched': launched,
    'launches': len(launches),
    'strike_orders': len(strikes),
    'liches_that_struck': len(struck_units),
    'liches_that_fired': len(fired_units),
    'targets_chosen': dict(chosen),
    'strike_distance_max': max((s[3] for s in strikes), default=0),
    'strike_endings': dict(overs),
    'vip_swaps': vip_swaps,
    'released_no_bomber_left': releases,
    'liches_lost_in_escort': len(lost),
    'lost_before_firing': len(lost_before),
    'lost_before_any_strike_order': len(lost_before_striking),
    'lost_after_firing': len(lost_after),
    'liches_lost_widget': len(widget['lost']),
    'liches_lost_to': dict(lost_to),
    'kills_by_liches_widget': dict(kill_defs),
    'roster_targets_destroyed_widget': len(widget['targets']),
    'widget_tally': tally,
}
for k, v in summary.items():
    print(f'{k:32} {v}')
(a.infolog.parent / 'liche-strikes.json').write_text(json.dumps(summary, indent=2))
