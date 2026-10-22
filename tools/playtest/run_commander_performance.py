"""Serial pinned commander comparisons, full natural games, and separate attribution.

Every run keeps its raw verdict and diagnostics. Fixed-population controls use
AB/BA order; dense battles and natural games retain population/casualty changes.
Run only after correctness, with other simulations and builds stopped.
"""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from analyze_full_match_performance import analyze, summary
from ranged_benchmark import summarize
from run_commander_regression import run_record
import storage

HERE=Path(__file__).resolve().parent


def environment(path, allow_lobby=False):
    script='''$ErrorActionPreference='Stop'
$processes=Get-CimInstance Win32_Process
[ordered]@{
 timeUtc=(Get-Date).ToUniversalTime().ToString('o')
 competing=@($processes | Where-Object { $_.Name -match '^spring(-headless)?\\.exe$' -or ($_.Name -match 'python|bash' -and $_.CommandLine -match 'build_native_snapshot.py|run_native_tests.sh') } | Select-Object ProcessId,Name,CommandLine)
 load=@(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | Where-Object { $_.Name -notin @('_Total','Idle') } | Sort-Object PercentProcessorTime -Descending | Select-Object -First 10 Name,IDProcess,PercentProcessorTime)
} | ConvertTo-Json -Depth 5
'''
    result=subprocess.run(['powershell','-NoProfile','-Command',script],capture_output=True,text=True,timeout=20)
    if result.returncode:raise RuntimeError('Environment inventory failed: '+result.stderr)
    data=json.loads(result.stdout)
    # A human may deliberately keep the menu/lobby open. Record that load and
    # qualify timings; this never permits another match or compiler process.
    allowed=[row for row in data['competing'] if allow_lobby
        and row['Name'].lower()=='spring.exe'
        and re.search(r'(?:^|\s)--menu(?:\s|=)',row.get('CommandLine') or '')]
    data['allowed_lobby']=allowed
    data['competing']=[row for row in data['competing'] if row not in allowed]
    data['uncontended']=not allowed and not data['competing']
    path.write_text(json.dumps(data,indent=2)+'\n')
    if data['competing']:raise RuntimeError('Stop competing simulations/builds before timing: '+str(path))
    return data


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline',required=True,type=Path,help='Pin containing DLL and data/')
    parser.add_argument('--candidate',required=True,type=Path)
    parser.add_argument('--out',required=True,type=Path)
    parser.add_argument('--maps',default='glacial,supreme')
    parser.add_argument('--natural-minutes',type=int,default=90)
    parser.add_argument('--headless',action='store_true')
    parser.add_argument('--attribution',action='store_true',help='Additional candidate dense run with native phases enabled')
    parser.add_argument('--allow-lobby',action='store_true',help='Explicitly permit a Spring --menu lobby; retain load and qualify timings')
    selection=parser.add_mutually_exclusive_group()
    selection.add_argument('--natural-only',action='store_true',help='Run only the natural-map pairs, after supplied controls already completed')
    selection.add_argument('--arenas-only',action='store_true',help='Run supplied controls only; useful after a focused final repair')
    parser.add_argument('--keep-going',action='store_true',help='Natural-only diagnostic continuation; recorded failures remain failures')
    args=parser.parse_args()
    if args.keep_going and not args.natural_only:parser.error('--keep-going requires --natural-only; retain the strict series first')
    if args.out.exists():raise ValueError('Use a fresh output path')
    for name in os.environ:
        if name.startswith('CIRCUIT_VERIFY_') or name in ('CIRCUIT_COMMANDER_TRACE','CIRCUIT_RANGED_TRACE','CIRCUIT_PERF_PHASES'):
            raise ValueError('Timing environment contains '+name)
    pins={'baseline':args.baseline.resolve(),'candidate':args.candidate.resolve()}
    for pin in pins.values():
        if not (pin/'SkirmishAI.dll').is_file() or not (pin/'data/script').is_dir():raise ValueError('Incomplete pin: '+str(pin))
    plan=[]
    for case in (() if args.natural_only else ('commander-population-16','commander-dense-16')):
        for rep,order in ((1,('baseline','candidate')),(2,('candidate','baseline'))):
            for label in order:plan.append(dict(kind='arena',case=case,label=label,rep=rep,minutes=6,native_phases=False))
    for name in (() if args.arenas_only else args.maps.split(',')):
        if name not in ('glacial','supreme','shore','metal-plate','serene','glitters'):raise ValueError('Unknown map: '+name)
        for label in ('baseline','candidate'):plan.append(dict(kind='natural',map=name,label=label,rep=1,minutes=args.natural_minutes,native_phases=False,diagnostic_keep_going=args.keep_going))
    if args.attribution:plan.append(dict(kind='arena',case='commander-dense-16',label='candidate',rep=3,minutes=6,native_phases=True))
    args.out.parent.mkdir(parents=True,exist_ok=True)
    record={'created_utc':dt.datetime.now(dt.timezone.utc).isoformat(),'pins':{
            k:{'directory':str(p),'dll_sha256':storage.file_hash(p/'SkirmishAI.dll')} for k,p in pins.items()},'plan':plan,'results':[],
            'timing_qualification':'BAR lobby permitted; not an uncontended comparison' if args.allow_lobby else 'Other games and builds prohibited'}
    args.out.write_text(json.dumps(record,indent=2)+'\n')
    for i,spec in enumerate(plan,1):
        name=f'{i:02}-{spec["label"]}-{spec.get("case",spec.get("map"))}-r{spec["rep"]}'
        prefix=args.out.with_name(args.out.stem+'-'+name)
        environment(prefix.with_name(prefix.name+'-before.json'),args.allow_lobby)
        pin=pins[spec['label']]
        command=[sys.executable,str(HERE/('ranged_arena.py' if spec['kind']=='arena' else 'run_full_match_performance.py')),
            '--dll',str(pin/'SkirmishAI.dll'),'--data',str(pin/'data'),'--profile','experimental_balanced',
            '--minutes',str(spec['minutes']),'--speed','20','--mode','performance']
        if spec['kind']=='arena':command+=['--case',spec['case']]
        else:
            command+=['--map',spec['map'],'--command-detail']
            if args.keep_going:command.append('--keep-going')
        if args.headless:command+=['--headless']
        print(f'[{i}/{len(plan)}] {name}',flush=True)
        if spec['native_phases']:os.environ['CIRCUIT_PERF_PHASES']='1'
        try:row=run_record(command,prefix.with_suffix('.txt'))
        finally:os.environ.pop('CIRCUIT_PERF_PHASES',None)
        row.update(spec=spec,command=command)
        if row['report']:
            directory=Path(row['report']).parents[2]
            telemetry=analyze(directory)
            prefix.with_name(prefix.name+'-telemetry.json').write_text(json.dumps(telemetry,indent=2)+'\n')
            row['telemetry_summary']=summary(telemetry)
            if spec['kind']=='arena' and 'arena_measurement' not in row:row['arena_measurement']=summarize(directory)
        environment(prefix.with_name(prefix.name+'-after.json'),args.allow_lobby)
        record['results'].append(row)
        record['complete']=len(record['results'])==len(plan)
        record['checks_pass']=record['complete'] and all(r['pass'] for r in record['results'])
        # Passing correctness checks is not a statistical performance verdict.
        record['performance_review']='pending analysis of raw CPU, command and population measurements'
        args.out.write_text(json.dumps(record,indent=2)+'\n')
        print(name+': '+str(row['archive_verdict']),flush=True)
        if row['report'] is None:break # Infrastructure failed; preserve the incomplete series.
    return 0 if record.get('checks_pass') else 1


if __name__=='__main__':raise SystemExit(main())
