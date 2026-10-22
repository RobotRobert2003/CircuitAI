"""Physical SEA scouting/protection checks; spectator observations never reach AI."""
import math
import re


def audit(text, case):
    spec = case['progression_audit']
    spawns, detected, boats, ammo, deaths = {}, {}, {}, {}, {}
    for line in text.splitlines():
        if '[SeaArena]' not in line:
            continue
        row = dict(re.findall(r'(\w+)=([^\s]+)', line))
        unit = row.get('id')
        if not unit:
            continue
        if ' spawn ' in line:
            spawns[unit] = row
        elif ' detected ' in line:
            detected.setdefault(unit, int(row['frame']) / 30)
        elif ' boat ' in line:
            boats.setdefault(unit, []).append(row)
        elif ' protection ' in line:
            ammo[unit] = max(ammo.get(unit, 0), int(row['stockpile']))
        elif ' death ' in line:
            deaths[unit] = row
    failures, measurements = [], {}
    if spec['kind'] == 'shores':
        yards = [u for u, r in spawns.items() if r['team'] == '1' and r['unit'] == spec['unit']]
        measurements['first_detection_seconds'] = {u: detected.get(u) for u in yards}
        if len(yards) != spec['count']:
            failures.append('Not all supplied enemy yards spawned')
        for u in yards:
            if detected.get(u, math.inf) > spec['by_seconds']:
                failures.append(f'Yard {u} not discovered before shoreline deadline')
    elif spec['kind'] == 'scout_travel':
        scouts = [u for u, r in spawns.items() if r['team'] == '0' and r['unit'] == spec['unit']]
        if len(scouts) != spec['count']:
            failures.append('Wrong fixed scout population')
        distances = {}
        for unit in scouts:
            samples = boats.get(unit, [])
            positions = [(float(row['x']), float(row['z'])) for row in samples]
            distances[unit] = max((math.dist(positions[0], p) for p in positions), default=0)
            if unit in deaths or distances[unit] < spec['minimum_travel']:
                failures.append(f'Scout {unit} failed surviving-travel acceptance')
        measurements['travel_from_first_sample'] = distances
    elif spec['kind'] == 'scout_release':
        scouts = [u for u, r in spawns.items() if r['team'] == '0' and r['unit'] == spec['unit']]
        kills = [int(r['frame']) for r in deaths.values()
                 if r.get('unit') == spec['target'] and r.get('attackerTeam') == '0']
        if len(scouts) != spec['count'] or not kills:
            return ['Missing supplied scouts or confirmed target kill'], measurements
        release_after = min(kills) + spec['release_seconds'] * 30
        frames = {}
        for u in scouts:
            if u in deaths:
                failures.append(f'Scout {u} died')
            for row in boats.get(u, []):
                if int(row['frame']) >= release_after and row.get('target') == '-1':
                    frames.setdefault(int(row['frame']), {})[u] = (float(row['x']), float(row['z']))
        spans = [max(math.dist(a, b) for a in positions.values() for b in positions.values())
                 for positions in frames.values() if len(positions) == len(scouts)]
        measurements['post_kill_max_spread'] = max(spans, default=0)
        measurements['kill_seconds'] = min(kills) / 30
        if not spans or max(spans) < spec['minimum_spread']:
            failures.append('Scouts did not clear their targets and disperse after the kill')
    else:
        supports = [u for u, r in spawns.items() if r['team'] == '0' and r['unit'] == spec['support']]
        flags = [u for u, r in spawns.items() if r['team'] == '0' and r['unit'] == spec['flagship']]
        if len(supports) != 2 or len(flags) != 1:
            return ['Expected two support ships and one flagship'], measurements
        home, escort = supports
        samples = boats.get(home, [])
        anchor = spec['home']
        distance = lambda r, p: math.hypot(float(r['x']) - p[0], float(r['z']) - p[1])
        home_max = max((distance(r, anchor) for r in samples), default=math.inf)
        measurements['home_max_distance'] = home_max
        if home_max > spec['home_radius']:
            failures.append('First anti-nuke left the home radius')
        positions = {int(r['frame']): (float(r['x']), float(r['z'])) for r in boats.get(flags[0], [])}
        separation = [distance(r, positions[int(r['frame'])]) for r in boats.get(escort, [])
                      if int(r['frame']) in positions and spec['escort_from']*30 <= int(r['frame']) < spec['remove_seconds']*30]
        measurements['escort_max_distance'] = max(separation, default=math.inf)
        if not separation or max(separation) > spec['coverage']:
            failures.append('Second anti-nuke failed flagship coverage')
        first = next(iter(positions.values()), anchor)
        moved = max((math.dist(p, first) for p in positions.values()), default=0)
        measurements['flagship_travel'] = moved
        if moved < spec.get('minimum_travel', 0):
            failures.append('Moving-escort precondition was not exercised')
        returned = [distance(r, anchor) for r in boats.get(escort, []) if int(r['frame']) >= spec['home_by']*30]
        if not returned or max(returned) > spec['home_radius']:
            failures.append('Escort did not return home after flagship removal')
        measurements['stockpiles'] = {u: ammo.get(u, 0) for u in supports}
        if any(ammo.get(u, 0) < 1 for u in supports):
            failures.append('Missing actual interceptor ammunition')
    return failures, measurements
