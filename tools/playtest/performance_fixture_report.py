"""Outcome checks for supplied command-ownership/arrival performance fixtures.

Read immutable archives, not live logs. Keep the original watcher verdict:
these explicit physical checks supplement it and never rewrite it.
"""
import argparse
import collections
import json
import math
from pathlib import Path
import re


def analyze(text, case):
    maximum_frame = case['minutes'] * 1800
    units, initial_health = {}, {}
    moves = 0
    attached = set()
    attached_alive, released = set(), set()
    drone_orders = collections.Counter()
    for line in text.splitlines():
        match = re.search(r'\[RangedArena\] frame=(\d+) (.*)', line)
        if not match or int(match[1]) > maximum_frame:
            continue
        event = match[2]
        values = dict(re.findall(r'(\w+)=([^\s]+)', event))
        if event.startswith('unit ') and values.get('unit') == case['unit']:
            identifier = int(values['id'])
            units[identifier] = values
            initial_health.setdefault(identifier, int(values['hp']))
        if event.startswith('unit_command ') and values.get('key') == case['unit'] + ':10':
            moves = max(moves, int(values['count']))
        if event.startswith('child ') and 'host' in values:
            attached.add(int(values['id']))
            attached_alive.add(int(values['id']))
        if event.startswith('death '):
            attached_alive.discard(int(values['id']))
        if event.startswith('drone_order ') and int(values['command']) in (0, 10, 15, 16, 20, 25):
            ownership = 'attached' if float(values['host']) >= 0 else 'independent_or_released'
            drone_orders[ownership + '_' + values['source']] += 1
            if ownership == 'independent_or_released' and values['source'] == 'nonlua' and int(values['id']) in attached_alive:
                released.add(int(values['id']))
    failures = []
    result = dict(moves=moves, units=units, drone_orders=dict(drone_orders), attached_children=len(attached),
                  surviving_released_children_with_ai_orders=sorted(released))
    if case.get('native_route'):
        spec = case['native_route']
        end = spec['points'][-1]
        before = spec['points'][-2]
        dx, dz = end[0] - before[0], end[1] - before[1]
        length = math.hypot(dx, dz)
        goals = [(end[0] - dz / length * spec['spacing'] * lane,
                  end[1] + dx / length * spec['spacing'] * lane) for lane in (0, 1, -1)]
        if len(units) != 3: failures.append('three observed route members required')
        occupied = set()
        for identifier, unit in units.items():
            distances = [math.hypot(float(unit['x'])-x, float(unit['z'])-z) for x,z in goals]
            nearest = distances.index(min(distances))
            if distances[nearest] > spec['radius']: failures.append('member did not arrive: '+str(identifier))
            if nearest in occupied: failures.append('members collapsed onto one endpoint')
            occupied.add(nearest)
            if int(unit['hp']) != initial_health[identifier]: failures.append('member lost health')
        if moves > 30: failures.append('completed route keeps emitting moves')
    if case.get('drone_ownership'):
        if not attached: failures.append('no attached children observed')
        if not drone_orders['attached_lua']: failures.append('gadget control not exercised')
        if drone_orders['attached_nonlua']: failures.append('attached drones received competing non-Lua movement/combat')
        if not drone_orders['independent_or_released_nonlua']: failures.append('independent AI control not exercised')
        result['release_note'] = 'Release IDs were observed attached, then received non-Lua commands with a cleared host before any recorded death.'
    result.update(passed=not failures, failures=failures)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--case', required=True, type=Path)
    args = parser.parse_args()
    case = json.loads(args.case.read_text())
    result = analyze((args.archive/'infolog.txt').read_text(errors='replace'), case)
    print(json.dumps(result, indent=2))
    return not result['passed']


if __name__ == '__main__':
    raise SystemExit(main())
