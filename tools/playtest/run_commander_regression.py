"""Serial commander scenarios with durable diagnostics and strict run verdicts.

Uses each check's full horizon unless its explicit completion condition fires.
T3 roster/defence/shore matrices use t3_matrix.py; performance comparisons use
fixed inputs and run_full_match_performance.py after this correctness suite.
"""
import argparse
import datetime as dt
import json
from pathlib import Path
import re
import subprocess
import sys
import time

import playtest
import storage
from ranged_benchmark import summarize

HERE=Path(__file__).resolve().parent


def run_record(command, diagnostic):
    started=time.monotonic()
    with diagnostic.open('w',encoding='utf-8') as output:
        run=subprocess.run(command,stdout=output,stderr=subprocess.STDOUT,check=False)
    report=None
    with diagnostic.open(encoding='utf-8',errors='replace') as output:
        for line in output:
            match=re.search(r'\[playtest\] report: (.*report\.md)',line)
            if match:report=Path(match[1].strip())
    archive=report.parent/'result.json' if report else None
    result=json.loads(archive.read_text()) if archive and archive.exists() else {}
    row={'returncode':run.returncode,'archive_verdict':result.get('verdict'),
            'report':str(report) if report else None,'diagnostic':str(diagnostic),
            'pass':run.returncode==0 and result.get('verdict')=='PASS',
            'wall_seconds':time.monotonic()-started}
    if report and (report.parents[2]/'ranged-arena.json').is_file():
        # Pattern checks alone cannot certify numeric casualty/damage/shot
        # assertions. Preserve both verdicts, including adaptive completion.
        row['arena_measurement']=summarize(report.parents[2])
        row['pass']=row['pass'] and row['arena_measurement']['passed']
    return row


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll',required=True,type=Path)
    parser.add_argument('--data',required=True,type=Path)
    parser.add_argument('--out',required=True,type=Path)
    parser.add_argument('--cases',help='Comma-separated case names; default all commander correctness cases')
    parser.add_argument('--profile',default='experimental_balanced')
    parser.add_argument('--mode',choices=['fast','visual'],default='fast')
    parser.add_argument('--headless',action='store_true')
    parser.add_argument('--stop-on-failure',action='store_true',help='Focused iteration; final regression normally collects all cases')
    args=parser.parse_args()
    cases=args.cases.split(',') if args.cases else [p.stem for p in sorted((HERE/'cases/shared/combat').glob('commander-*.json'))
        if p.stem not in ('commander-population-16','commander-dense-16')]
    # Validate the entire selection before starting any engine.
    selected=[]
    for name in cases:
        case=json.loads(storage.resolve_definition(name,'cases').read_text())
        checks=playtest.validate_checks(case['checks'])
        selected.append((name,checks.get('stop_minute',4)))
    args.out.parent.mkdir(parents=True,exist_ok=True)
    if args.out.exists():raise ValueError('Use a fresh output path; previous results are evidence')
    result={'recorded_at_utc':dt.datetime.now(dt.timezone.utc).isoformat(),
            'dll':str(args.dll),'dll_sha256':storage.file_hash(args.dll),'data':str(args.data),
            'profile':args.profile,'mode':args.mode,'results':[]}
    for index,(name,minutes) in enumerate(selected):
        command=[sys.executable,str(HERE/'ranged_arena.py'),'--case',name,'--dll',str(args.dll),
            '--data',str(args.data),'--profile',args.profile,'--minutes',str(minutes),'--mode',args.mode]
        if args.headless:command.append('--headless')
        print(f'[{index+1}/{len(selected)}] {name}',flush=True)
        row=run_record(command,args.out.with_name(args.out.stem+'-'+name+'.txt'))
        row.update(case=name,command=command);result['results'].append(row)
        result['complete']=len(result['results'])==len(selected)
        result['pass']=result['complete'] and all(r['pass'] for r in result['results'])
        args.out.write_text(json.dumps(result,indent=2)+'\n')
        print(f"{name}: {'PASS' if row['pass'] else 'FAIL'} ({row['wall_seconds']:.1f}s) {row['report'] or row['diagnostic']}",flush=True)
        # Missing archives mean startup/staging infrastructure failed. Repeating
        # the remaining cases cannot establish gameplay coverage (e.g. low disk).
        if row['report'] is None or (args.stop_on_failure and not row['pass']):break
    return 0 if result.get('pass') else 1


if __name__=='__main__':raise SystemExit(main())
