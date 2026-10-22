"""Damage/priority evidence from supplied fortress combat; never rewrite a verdict.

The fixture's two expensive tanks and cheap bots are identical old/new inputs.
Weapon-level damage distinguishes AA and surface guns; a zero damage result is
not a success just because the game reached its cutoff.
"""
import argparse
import json
import re
from collections import defaultdict
from pathlib import Path


def measure(directory):
    directory = Path(directory).resolve()
    case = json.loads((directory/'ranged-arena.json').read_text())
    text = (directory/'infolog.txt').read_text(errors='replace')
    names = {}
    damages = defaultdict(float)
    first = {}
    priorities = defaultdict(int)
    priority_samples = defaultdict(int)
    shot_targets = defaultdict(int)
    early_damage = defaultdict(float)
    first_priority = None
    defense_ids = []
    defense_target = None
    first_defense_target = None
    hostile_damage = 0.0
    deaths = []
    for line in text.splitlines():
        engine_frame = re.search(r'\[f=(\d+)\]', line)
        if engine_frame and int(engine_frame[1]) > case['minutes']*1800:
            continue
        if '[AIR][BaseResponse]' in line and case.get('role') == 'AIR':
            selected = re.search(r'group=3 target=(-?\d+)', line)
            if selected:
                defense_target = selected[1]
                defense_ids.append(defense_target)
            if 'dispatched=' in line and first_defense_target is None:
                first_defense_target = defense_target
        if '[RangedArena]' not in line:
            continue
        row = dict(re.findall(r'(\w+)=([^ ]+)', line))
        frame = int(row.get('frame', 0))
        if frame > case['minutes']*1800:
            continue
        if ' spawn ' in line:
            names[row['id']] = row['unit']
        if ' damage ' in line and names.get(row.get('attacker')) == case['unit']:
            target = names.get(row.get('id'), 'untracked')
            key = target + ':weapon=' + row.get('weapon', '?')
            damages[key] += float(row['amount'])
            if row.get('team') == '1':
                hostile_damage += float(row['amount'])
            if frame <= 30*30:
                early_damage[key] += float(row['amount'])
            first.setdefault(target, frame/30)
        if ' priority ' in line and row.get('unit') == case['unit']:
            priorities[names.get(row.get('target'), 'untracked')] += 1
        # BAR consumes priority-fire commands in AllowCommand, before the
        # observer's UnitCommand call-in. The replicated rules parameter is
        # the independent evidence of active intent; command count can be zero.
        if ' unit id=' in line and row.get('unit') == case['unit']:
            active = names.get(row.get('target'), 'none')
            priority_samples[active] += 1
            if active != 'none' and first_priority is None:
                first_priority = active
        if ' shot ' in line and row.get('unit') == case['unit']:
            shot_targets[row.get('weapon', '?')+':'+names.get(row.get('target'), 'none')] += 1
        if ' death ' in line:
            deaths.append({'seconds':frame/30, 'unit':row['unit'], 'team':int(row['team'])})
    totals = defaultdict(float)
    for key,value in damages.items():
        totals[key.split(':')[0]] += value
    heavy = any(g['team']==1 and g['unit']=='corgol' for g in case['groups'])
    anti_air = any(g['team']==1 and g['unit']=='armfig' for g in case['groups'])
    criteria = {'enemy_damage':hostile_damage>0,
                'survival':not any(d['team']==0 and d['unit']==case['unit'] for d in deaths)}
    if heavy:
        criteria['heavy_damage'] = totals['corgol'] >= 1000
        if case['variant'] != 'baseline' and case.get('role') == 'AIR':
            # A direct ATTACK has precedence over BAR priority fire. Its
            # unitTargetID can be nil despite correct task/weapon targeting.
            criteria['defense_heavy_assignment'] = names.get(first_defense_target) == 'corgol'
        elif case['variant'] != 'baseline':
            criteria['active_heavy_priority'] = priority_samples['corgol'] > 0
            # AA has its own target opportunities; the ground-only supplied
            # cases should acquire the valuable tank as their first priority.
            if not anti_air:
                criteria['first_priority_heavy'] = first_priority == 'corgol'
    if anti_air:
        criteria['anti_air_damage'] = totals['armfig'] > 0
    return {'case':case['name'], 'variant':case['variant'], 'directory':str(directory),
            'window_seconds':case['minutes']*60, 'damage_by_target_and_weapon':dict(damages),
            'first_damage_seconds':first, 'priority_commands':dict(priorities),
            'active_priority_samples':dict(priority_samples), 'sampled_shot_targets':dict(shot_targets),
            'damage_first_30_seconds':dict(early_damage), 'deaths':deaths,
            'first_active_priority':first_priority, 'criteria':criteria,
            'defense_group_targets':[names.get(i, 'none') for i in defense_ids],
            'first_defense_assignment':names.get(first_defense_target, 'none'),
            'enemy_damage':hostile_damage,
            'passed':all(criteria.values())}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    result = measure(args.directory)
    output = args.directory/'fortress-measurements-v5.json'
    serialized = json.dumps(result, indent=2)+'\n'
    if output.exists() and output.read_text() != serialized:
        raise SystemExit('Refusing to replace different evidence: '+str(output))
    output.write_text(serialized)
    print(serialized)
    raise SystemExit(0 if result['passed'] else 1)
