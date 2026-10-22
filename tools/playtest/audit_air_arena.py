"""Audit actual AIR sorties and interception from streaming combat-arena events."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re


def events(lines):
    for line in lines:
        shot = re.search(r'\[f=\s*(\d+)\].*\[CBitmap::Save\] saving "screenshots/([^"/]+)"', line)
        if shot:
            yield {'event': 'screenshot_file', 'frame': shot[1], 'file': shot[2]}
        if '[AirArena] ' in line:
            record = dict(re.findall(r'(\w+)=([^\s]+)', line.split('[AirArena] ', 1)[1]))
            if not line.endswith('\n') or 'frame' not in record or 'event' not in record:
                yield {'event': 'truncated_record', 'frame': record.get('frame', '0')}
            else:
                yield record


def analyze(lines, end_frame=None):
    waves, units, catalog, errors, classes = {}, {}, {}, [], {}
    total = Counter()
    screenshots = []
    overlaps = []
    last_frame = 0
    def unit_stats(team, name):
        key = str(team) + ':' + name
        return classes.setdefault(key, {'team': int(team), 'unit': name, 'spawned': 0, 'deaths': 0,
                                       'metal_lost': 0.0, 'health_damage': 0.0, 'paralysis': 0.0,
                                       'kills': 0, 'kill_value': 0.0})
    for e in events(lines):
        kind, frame = e['event'], int(e['frame'])
        if end_frame is not None and frame > end_frame:
            continue
        last_frame = max(last_frame, frame)
        total[kind] += 1
        if kind == 'damage':
            attacker = units.get(int(e['attacker']), {})
            name = e.get('adef', attacker.get('unit', 'unknown'))
            stats = unit_stats(e['attackerTeam'], name)
            stats['paralysis' if e['emp'] == '1' else 'health_damage'] += float(e['amount'])
        elif kind == 'death' and 'unit' in e:
            stats = unit_stats(e['team'], e['unit'])
            stats['deaths'] += 1
            stats['metal_lost'] += float(e['cost'])
            attacker = units.get(int(e.get('attacker', -1)), {})
            if attacker and attacker.get('team') != e['team']:
                kills = unit_stats(attacker['team'], attacker['unit'])
                kills['kills'] += 1
                kills['kill_value'] += float(e['cost'])
        if kind == 'catalog':
            catalog[e['unit']] = {k: e[k] for k in ('builder', 'transport', 'weapons')}
        elif kind == 'error':
            errors.append(e)
        elif kind == 'screenshot':
            screenshots.append({'frame': frame, 'key': e['key']})
        elif kind == 'screenshot_file' and screenshots and 'file' not in screenshots[-1]:
            screenshots[-1]['file'] = e['file']
        elif kind == 'spawn':
            units[int(e['id'])] = e
            stats = unit_stats(e['team'], e['unit'])
            stats['spawned'] += 1
            stats['kind'] = e['kind']
        elif kind == 'energy' and float(e['current']) < 1000:
            errors.append({'event': 'energy_shortage', **e})
        elif kind == 'launch':
            # A live task alone is not proof of a surviving cohort. Require a
            # recent independent engine aircraft census at the later launch.
            for earlier in waves.values():
                if (not earlier['completed'] and earlier.get('alive', 0) > 0
                        and frame - earlier.get('flight_frame', -100000) <= 150):
                    overlaps.append({'wave': int(e['wave']), 'launch_frame': frame,
                                     'earlier_wave': earlier['wave'], 'earlier_alive': earlier['alive'],
                                     'observed_frame': earlier['flight_frame']})
            ids = [int(s) for s in e['ids'].split(',')]
            waves[int(e['wave'])] = {
                'wave': int(e['wave']), 'launch_frame': frame, 'target': int(e['target']), 'ids': ids,
                'count': len(ids), 'risk_before': float(e['risk']), 'completed': False,
                'detected_frame': None, 'response_frame': None, 'fighter_hit_frame': None,
                'target_hit_frame': None, 'target_dead_frame': None,
                'target_damage': 0.0, 'paralysis': 0.0, 'aircraft_metal_lost': 0.0,
                'target_metal_destroyed': 0.0, 'survivors': None, 'home': None,
            }
        elif kind in ('detected', 'response', 'damage', 'target_dead', 'death', 'end', 'flight'):
            w = waves.get(int(e.get('wave', 0)))
            if not w or w['completed']:
                continue
            if kind == 'flight':
                w.update(alive=int(e['alive']), flight_frame=frame)
            elif kind == 'detected' and w['detected_frame'] is None:
                w['detected_frame'] = frame
            elif kind == 'response' and e['active'] == '1' and w['response_frame'] is None:
                w['response_frame'] = frame
            elif kind == 'damage':
                if e['attackerTeam'] == '1' and e['team'] == '0' and w['fighter_hit_frame'] is None:
                    a = units.get(int(e['attacker']), {})
                    if a.get('kind') == 'aircraft':
                        w['fighter_hit_frame'] = frame
                if e['attackerTeam'] == '0' and int(e['victim']) == w['target']:
                    if w['target_hit_frame'] is None:
                        w['target_hit_frame'] = frame
                    w['paralysis' if e['emp'] == '1' else 'target_damage'] += float(e['amount'])
            elif kind == 'target_dead':
                w['target_dead_frame'] = frame
                w['target_metal_destroyed'] = float(e['cost'])
            elif kind == 'death' and int(e['id']) in w['ids']:
                w['aircraft_metal_lost'] += float(e['cost'])
            elif kind == 'end':
                w.update(completed=True, end_frame=frame, survivors=int(e['survivors']),
                         home=int(e['home']), risk_after=float(e['risk']))
    for w in waves.values():
        def latency(a, b):
            return round((w[b]-w[a])/30, 2) if w[a] is not None and w[b] is not None else None
        w['detection_to_response_seconds'] = latency('detected_frame', 'response_frame')
        w['detection_to_fighter_hit_seconds'] = latency('detected_frame', 'fighter_hit_frame')
        w['intercept_before_target_damage'] = (w['fighter_hit_frame'] < w['target_hit_frame']) if (
            w['fighter_hit_frame'] is not None and w['target_hit_frame'] is not None) else None
    completed = [w for w in waves.values() if w['completed']]
    attackers = [s for s in classes.values() if s.get('kind') == 'aircraft' and s['team'] == 0]
    return {'last_frame': last_frame, 'measurement_end_frame': end_frame, 'events': dict(total), 'fixture_errors': errors, 'waves': list(waves.values()),
            'completed_waves': len(completed), 'censored_waves': len(waves)-len(completed),
            'observed_overlaps': overlaps,
            'screenshots': screenshots, 'loaded_air_catalog': catalog,
            'unit_classes': list(classes.values()),
            'attacker_health_damage': sum(s['health_damage'] for s in attackers),
            'attacker_paralysis': sum(s['paralysis'] for s in attackers),
            'attacker_metal_lost': sum(s['metal_lost'] for s in attackers),
            'attacker_kill_value': sum(s['kill_value'] for s in attackers),
            'note': 'Supplied-force capability measurements. Launches are real AI cohorts. Target kill value excludes collateral; raw damage can include overkill. Class kills use the last observed damaging unit, not strategic credit. Screen response toggles may concern scouts, so fighter-hit latency is the interception measure. Loaded aircraft are a catalog, not behavior coverage.'}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('log', type=Path)
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--end-frame', type=int, help='Exclude shutdown overrun beyond the measurement window')
    a = p.parse_args()
    with a.log.open(encoding='utf-8', errors='replace') as src:
        result = analyze(src, a.end_frame)
    result['log'] = str(a.log)
    result['auditor_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_text(json.dumps(result, indent=2)+'\n')
    rows = ['# AIR arena observations', '', f"Completed sorties: {result['completed_waves']}; censored: {result['censored_waves']}; fixture errors: {len(result['fixture_errors'])}.", '',
            '| Wave | Aircraft | Risk before/after | Target damage | Kill value | Aircraft lost M | Survivors/home | Detection to fighter hit |',
            '| --- | --- | --- | --- | --- | --- | --- | --- |']
    for w in result['waves']:
        rows.append(f"| {w['wave']} | {w['count']} | {w['risk_before']}/{w.get('risk_after','pending')} | {w['target_damage']:.0f} | {w['target_metal_destroyed']:.0f} | {w['aircraft_metal_lost']:.0f} | {w['survivors']}/{w['home']} | {w['detection_to_fighter_hit_seconds']} |")
    rows += ['', '| Team | Unit | Spawned | Lost metal | Health damage | Paralysis | Kill value |',
             '| --- | --- | --- | --- | --- | --- | --- |']
    for s in result['unit_classes']:
        rows.append(f"| {s['team']} | {s['unit']} | {s['spawned']} | {s['metal_lost']:.0f} | {s['health_damage']:.0f} | {s['paralysis']:.0f} | {s['kill_value']:.0f} |")
    rows += ['', result['note'], '', 'This audit supplements the strict playtest report; it does not waive script/invariant failures or establish improvement from a small sample.']
    rows += ['', 'Screenshots:']
    rows += [f"- [{s['key']}]({s['file']}) at frame {s['frame']}" for s in result['screenshots'] if 'file' in s]
    a.output.with_suffix('.md').write_text('\n'.join(rows)+'\n')
    print('\n'.join(rows[:4]), flush=True)


if __name__ == '__main__':
    main()
