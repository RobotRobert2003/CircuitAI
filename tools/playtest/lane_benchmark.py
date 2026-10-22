"""Prepare/record isolated, map-and-settings-specific lane worker benchmarks.

Uses the existing staging and scorecard machinery. The only treatment change
is lanes/background; the observer requests surveys, never gameplay orders.
"""
import argparse
import datetime as dt
import json
import math
import re
import statistics
import subprocess
import sys
from pathlib import Path
from benchmark_store import RAW_ROOT

import scorecard
from benchmark_store import EVIDENCE_ROOT, require_checkout

ROOT = scorecard.ROOT
MAPS = {'supreme': 'Supreme Isthmus v1.7', 'glacial': 'Glacial Gap v1.1', 'ascendancy': 'Ascendancy v2.2'}


def prepare(args):
    directory = Path(args.directory).resolve()
    if not directory.is_relative_to(RAW_ROOT):
        raise ValueError('Benchmark output must stay inside build-theatres')
    command = [sys.executable, str(ROOT/'tools/playtest/playtest.py'), 'stage', '--dir', str(directory),
               '--dll', args.dll, '--map', MAPS[args.map], '--game', args.game,
               '--engine', 'recoil_2026.07.04', '--roles', args.roles, '--side', 'legion',
               '--headless', '--shots', '', '--speed', '8', '--minutes', '6',
               '--ai-option', 'profile='+args.profile, '--modoption', 'experimentallegionfaction=1',
               '--modoption', 'experimentalextraunits=0', '--modoption', 'scavunitsforplayers=0',
               '--extra-widget', str(ROOT/'tools/playtest/widgets/lane_benchmark_watch.lua'),
               '--extra-widget', str(ROOT/'tools/playtest/widgets/scorecard_metrics.lua')]
    if args.map == 'ascendancy':
        command += ['--map-file', str(ROOT/'tools/playtest/fixtures/ascendancy.as')]
    subprocess.run(command, cwd=ROOT, check=True)
    config = directory/'AI/Skirmish/BARbTest/test/config/lanes.json'
    text = config.read_text(encoding='utf-8')
    text, count = re.subn(r'("background"\s*:\s*)(true|false)',
                         lambda m: m[1]+('true' if args.mode=='worker' else 'false'), text)
    if count != 1:
        raise ValueError('Expected exactly one background setting')
    config.write_text(text, encoding='utf-8', newline='\n')
    overrides = []
    if args.map == 'ascendancy':
        setup = directory/'AI/Skirmish/BARbTest/test/script/src/setup.as'
        text = setup.read_text(encoding='utf-8')
        old = 'AiRole defaultRole = RoleHelpers::DefaultRoleForFactory(defaultFactoryName);'
        if text.count(old) != 1:
            raise ValueError('Ascendancy role fixture changed')
        setup.write_text(text.replace(old, 'AiRole defaultRole = AiRole::TECH;'), encoding='utf-8', newline='\n')
        overrides.append('Ascendancy unknown-map fallback TECH role, in staged scripts only')
    scorecard.capture(directory, {'benchmark':'lane-worker', 'treatment':args.mode,
        'minutes_limit':6, 'headless':True, 'speed':8, 'income_fixture':False, 'role_overrides':overrides})
    print(directory)


def summary(values):
    if not values:
        return {'n':0}
    ordered=sorted(values)
    return {'n':len(values), 'median':statistics.median(values),
            'p95':ordered[max(0,math.ceil(len(values)*0.95)-1)], 'max':max(values)}


def record(args):
    directory=Path(args.directory)
    run=Path(args.run)
    rows=[]; post={}; errors=[]
    for line in (run/'infolog.txt').read_text(encoding='utf-8',errors='replace').splitlines():
        if 'LANE_PERF ' in line:
            row=dict(re.findall(r'(\w+)=([\w.]+)',line.split('LANE_PERF ',1)[1]))
            for key in row.keys()-{'mode','fingerprint'}:
                row[key]=float(row[key]) if key.endswith('_ms') else int(row[key])
            rows.append(row)
        if 'LANE_POST ' in line:
            data=dict(re.findall(r'(\w+)=([\w.]+)',line.split('LANE_POST ',1)[1]))
            post[(int(data['team']),int(data['revision']))]=float(data['main_ms'])
        if '[INVARIANT]' in line or re.search(r': ERR\s+:|SCRIPT CRASH|LANES: .*failed:',line):
            errors.append(line)
    for row in rows:
        row['post_ms']=post.get((row['team'],row['revision']))
        if row['post_ms'] is not None:
            row['main_ms']=row['snapshot_ms']+row['publish_ms']+row['post_ms']
            if row['mode']=='sync': row['main_ms']+=row['solve_ms']
    manifest=scorecard.read_json(directory/'scorecard-manifest.json')
    teams={t['team'] for t in manifest['teams']}
    completed={r['team'] for r in rows}
    result={'recorded_at_utc':dt.datetime.now(dt.timezone.utc).isoformat(),
            'manifest':manifest, 'run':str(run.resolve()), 'calculations':rows,
            'missing_teams':sorted(teams-completed), 'errors':errors,
            'timings':{key:summary([r[key] for r in rows if r.get(key) is not None])
                       for key in ['snapshot_ms','queue_ms','solve_ms','publish_ms','post_ms','main_ms']}}
    require_checkout()
    out=EVIDENCE_ROOT/'lane-workers'/manifest['started_at_utc'][:10]
    out.mkdir(parents=True,exist_ok=True)
    target=out/(manifest['run_id']+'.json')
    scorecard.write_json(target,result)
    print(json.dumps({'file':str(target),'timings':result['timings'],
                     'missing_teams':result['missing_teams'],'errors':len(errors)},indent=2))
    # Keep the existing map/settings scorecards updated as well. Censored six
    # minute runs are telemetry, not evidence of a win or an OpenSkill update.
    print(scorecard.record(directory,run))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='command',required=True)
    p=sub.add_parser('prepare');p.add_argument('directory');p.add_argument('--dll',required=True)
    p.add_argument('--map',choices=MAPS,default='supreme');p.add_argument('--game',required=True)
    p.add_argument('--mode',choices=('sync','worker'),required=True)
    p.add_argument('--roles',default='all');p.add_argument('--profile',default='experimental_hard')
    p=sub.add_parser('record');p.add_argument('directory');p.add_argument('--run',required=True)
    args=parser.parse_args()
    prepare(args) if args.command=='prepare' else record(args)


if __name__=='__main__':
    main()
