"""Serial fixed-population before/after test; refuses concurrent BAR processes.

Run only after compilation and correctness simulations finish. The baseline
is measured first, then its observed spread defines candidate tolerances.
No query/snapshot oracle or detailed per-unit trace may be enabled.
"""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys

import storage

HERE=Path(__file__).resolve().parent


def idle(background_pids=()):
    # PowerShell/CIM is a read-only local process query. Do not stop the user's
    # game or attempt to claim timings from a concurrently running renderer.
    query="@(Get-CimInstance Win32_Process | Where-Object { $_.Name -in @('spring.exe','spring-headless.exe','cc1plus.exe','ninja.exe') } | Select-Object ProcessId,Name) | ConvertTo-Json -Compress"
    output=subprocess.check_output(['powershell','-NoProfile','-Command',query],text=True).strip()
    observed=json.loads(output) if output else []
    if isinstance(observed,dict): observed=[observed]
    other=[row for row in observed if row['ProcessId'] not in background_pids]
    if other:raise RuntimeError('Other game/compiler still running: '+json.dumps(other))
    containers=subprocess.check_output(['docker','ps','--format','{{.ID}} {{.Image}}'],text=True).splitlines()
    builds=[line for line in containers if 'recoil-build-' in line]
    if builds:raise RuntimeError('Finish build containers before timing: '+', '.join(builds))


def metrics(result):
    if result['friendly_losses'] or result['enemy_kills']:
        raise RuntimeError('Fixed-population fixture changed population: '+result['directory'])
    rows=[r for r in result['engine_ai_windows'] if 1800<r['frame']<=5400]
    if len(rows)!=2:raise RuntimeError('Missing steady observation windows')
    return dict(p95_ms=statistics.median(r['ai_all_p95_ms'] for r in rows),
        p99_ms=statistics.median(r['ai_all_p99_ms'] for r in rows),
        mean_ms=statistics.mean(r['ai_all_mean_ms'] for r in rows),
        commands_per_minute=result['commands_per_game_minute'])


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--baseline',type=Path,required=True,help='Pin directory containing DLL and data/')
    p.add_argument('--candidate',type=Path,required=True)
    p.add_argument('--game',default='Beyond All Reason test-31479-433a460')
    p.add_argument('--case', default='thug-fixed-population',
        choices=['thug-fixed-population','t1-formation-fixed-population','armada-formation-fixed-population'])
    p.add_argument('--background-pid',type=int,action='append',default=[],
        help='Explicit existing user game: measure command/population controls only; CPU acceptance remains pending. Never stops that process.')
    a=p.parse_args()
    for name in ('CIRCUIT_VERIFY_RANGED_QUERIES','CIRCUIT_VERIFY_RANGED_SNAPSHOT','CIRCUIT_RANGED_TRACE'):
        if name in os.environ:p.error('Unset diagnostic variable '+name)
    idle(a.background_pid)
    fixture=json.loads((HERE/'cases/shared/combat'/f'{a.case}.json').read_text())
    expected={}
    for group in fixture['groups']:
        key=(group['team'],group['unit'])
        expected[key]=expected.get(key,0)+group['count']
    directory=storage.allocate('shared','performance',
        'thug-comparison' if a.case=='thug-fixed-population' else
        ('armada-form-comparison' if a.case=='armada-formation-fixed-population' else 'formation-comparison'),
        fixture['map_key'],'benchmark')
    print('THUG_PERFORMANCE='+str(directory),flush=True)
    runs={}
    for label,pin in [('baseline',a.baseline),('candidate',a.candidate)]:
        runs[label]=[]
        for seed in (2071,2072,2073):
            idle(a.background_pid)
            cmd=[sys.executable,str(HERE/'ranged_benchmark.py'),'--cases',a.case,
                '--dll',str(pin/'SkirmishAI.dll'),'--data',str(pin/'data'),
                '--variant','baseline' if label=='baseline' else 'ranged',
                '--seed',str(seed),'--speed','16','--minutes','3','--game',a.game]
            log=directory/f'{label}-{seed}.log'
            with log.open('w') as stream:
                code=subprocess.run(cmd,stdout=stream,stderr=subprocess.STDOUT).returncode
            lines=log.read_text().splitlines()
            result=json.loads(next(s[len('MEASUREMENTS='):] for s in lines if s.startswith('MEASUREMENTS=')))
            if code or not result['passed']:raise RuntimeError('Fixture failure retained in '+str(log))
            # Successful staging is not enough: prove the exact watched inputs.
            raw=Path(result['directory'])/'infolog.txt'
            import re
            text=raw.read_text(errors='replace')
            for (team,unit),count in expected.items():
                pattern=rf'\[RangedArena\] frame=\d+ spawn .*team={team} unit={re.escape(unit)} '
                if len(re.findall(pattern,text))!=count:
                    raise RuntimeError(f'Incorrect supplied population: team {team}, {unit}, expected {count}')
            runs[label].append(dict(seed=seed,directory=result['directory'],metrics=metrics(result)))
            print(label,seed,runs[label][-1]['metrics'],flush=True)
        if label=='baseline':
            limits={}
            for key in runs[label][0]['metrics']:
                values=[r['metrics'][key] for r in runs[label]]
                center=statistics.median(values)
                allowance=max(max(values)-min(values),center*.1,0 if key=='commands_per_minute' else .05)
                limits[key]=dict(baseline_median=center,allowance=allowance,ceiling=center+allowance)
            (directory/'baseline-tolerances.json').write_text(json.dumps(limits,indent=2)+'\n')
    comparison={}
    for key,limit in limits.items():
        value=statistics.median(r['metrics'][key] for r in runs['candidate'])
        comparison[key]={**limit,'candidate_median':value,'ratio':value/limit['baseline_median'] if limit['baseline_median'] else None,
            'within_allowance':value<=limit['ceiling']}
    report=dict(schema=1,runs=runs,comparison=comparison,background_pids=a.background_pid,
        cpu_acceptance='pending: other user game active' if a.background_pid else 'measured serially without another game/compiler',
        definition='Median across three games of the median one-minute p95/p99 windows at minutes 2 and 3; command rate covers minutes 0-3. Not a pooled percentile or network packet measurement.')
    (directory/'comparison.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(comparison,indent=2),flush=True)
    assessed=([comparison['commands_per_minute']] if a.background_pid else comparison.values())
    return 0 if all(v['within_allowance'] for v in assessed) else 1


if __name__=='__main__':sys.exit(main())
