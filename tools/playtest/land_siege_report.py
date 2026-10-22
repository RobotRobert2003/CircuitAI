"""Read-only evidence extraction for supplied land-siege/Incinerator cases.

Continuous beams need damage attribution: polling reloadFrame at 1 Hz cannot
reliably count weapons firing every simulation frame. Neither measure implies
network packets. Keep each report in its immutable run directory.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import re

def measure(directory):
    cfg=json.loads((directory/'ranged-arena.json').read_text())
    units, sources, spawned, produced= {}, set(), set(), Counter()
    damage=0; deaths=[]; choices=[]; last=0; errors=[]
    for line in (directory/'infolog.txt').open(errors='replace'):
        if re.search(r'\[INVARIANT\]|\[RangedArena\].*ERROR|Error in.*ranged_arena|\[ERR\]', line):
            errors.append(line.strip())
        if '[LandSiege]' in line: choices.append(line.strip())
        if '[RangedArena]' not in line: continue
        row=dict(re.findall(r'(\w+)=([^\s]+)',line))
        if 'frame' not in row: continue
        f=int(row['frame']); last=max(last,f)
        if f>cfg['minutes']*1800: continue
        if ' spawn ' in line:
            units[row['id']]=row['unit']; spawned.add(row['id'])
        if ' child ' in line and 'unit' in row: units[row['id']]=row['unit']
        if ' finished ' in line and row.get('team')=='0' and row['id'] not in spawned:
            produced[row['unit']]+=1
        if ' damage ' in line and row.get('attackerTeam')=='0' and row.get('team')=='1':
            if units.get(row.get('attacker'))==cfg['unit']:
                sources.add(row['attacker']); damage+=int(row['amount'])
        if ' death ' in line: deaths.append(row)
    failures=[]
    archives = sorted((directory/'runs').glob('*/result.json'))
    verdict = json.loads(archives[-1].read_text()).get('verdict') if archives else None
    if verdict != 'PASS': failures.append('Original watch verdict: '+str(verdict))
    if errors: failures.append('Runtime/fixture error')
    expected=cfg.get('production_assertions',{}) if cfg.get('variant')!='baseline' else {}
    for unit,minimum in expected.get('min_produced',{}).items():
        if produced[unit]<minimum: failures.append('Insufficient completed '+unit)
    if len(choices)<expected.get('min_siege_choices',0): failures.append('Missing siege decisions')
    if expected.get('forbid_siege_choices') and choices: failures.append('Unexpected dedicated siege response')
    if last<cfg['minutes']*1800-150: failures.append('Incomplete observation')
    return {'schema':3,'case':cfg['name'],'directory':str(directory),'minutes':cfg['minutes'],
        'watch_verdict':verdict,'errors':errors,
        'observed_frame':last,'produced':dict(produced),'damaging_primary_units':len(sources),
        'primary_damage_including_overkill':damage,'deaths':deaths,'siege_choices':choices,
        'passed':not failures,'failures':failures}

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('directory',type=Path)
    args=p.parse_args();result=measure(args.directory)
    target=args.directory/'land-siege-measurements-v3.json'
    payload=json.dumps(result,indent=2)+'\n'
    if target.exists() and target.read_text()!=payload: raise SystemExit('Refusing to rewrite original evidence')
    target.write_text(payload);print(payload)
    raise SystemExit(0 if result['passed'] else 1)
