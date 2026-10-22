"""Seeded natural Forge economy: no resource or unit gifts; completed GEO evidence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import playtest
import storage


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll',type=Path,required=True)
    p.add_argument('--data',type=Path,default=playtest.REPO/'data')
    p.add_argument('--profile',default='experimental_balanced')
    p.add_argument('--side',default='cortex',choices=('armada','cortex','legion'))
    p.add_argument('--minutes',type=int,default=16)
    p.add_argument('--stage-only',action='store_true')
    p.add_argument('--cost',action='store_true',help='Measure inclusive FRONT builder policy; comparisons run serially')
    a=p.parse_args()
    directory=storage.allocate('front','economy','geothermal','forge','natural',seed=28701)
    print('FRONT_GEO_DIRECTORY='+str(directory),flush=True)
    call=[sys.executable,str(playtest.HERE/'playtest.py')]
    subprocess.run(call+['stage','--dir',str(directory),'--dll',str(a.dll),'--data',str(a.data),
        '--map','Forge v2.3','--role','FRONT','--roles','all','--side',a.side,
        '--game','Beyond All Reason test-31578-8247b61','--engine','recoil_2026.07.04',
        '--ai-option','profile='+a.profile,'--ai-option','random_seed=28701','--bonus','0',
        '--minutes',str(a.minutes),'--speed','12','--lean-render','--shots','3,6,10,15',
        '--extra-widget',str(playtest.HERE/'widgets/front_geothermal_watch.lua')],check=True)
    script=directory/'script.txt'
    script.write_text(script.read_text().replace('[GAME]\n{','[GAME]\n{\n FixedRNGSeed=28701;',1))
    if a.cost:
        from run_full_match_performance import wrap
        wrap(directory/'AI/Skirmish/BARbTest/test/script/src/roles/front/front.as',
             'Front_BuilderAiMakeTask','IUnitTask@','CCircuitUnit@ builder','builder','front.builder')
    checks={'stop_minute':a.minutes,'expect':[
        {'key':'front geo finished','pattern':r'\[FrontGeoEvidence\] finished=(?:arm|cor|leg)geo team=0',
         'scope':'any','by_minute':12}], 'forbid':[
        {'key':'script','pattern':r': ERR\s+:|SCRIPT CRASH|Lib exception','scope':'any'},
        {'key':'invariant','pattern':r'\[INVARIANT\]','scope':'any'}]}
    (directory/'checks.json').write_text(json.dumps(checks,indent=2))
    staged=directory/'AI/Skirmish/BARbTest/test'
    (directory/'front-geo-pins.json').write_text(json.dumps({
        'seed':28701,'profile':a.profile,'cost_profiling':a.cost,
        'dll_sha256':hashlib.sha256(a.dll.read_bytes()).hexdigest(),
        'files':{str(f.relative_to(staged)):hashlib.sha256(f.read_bytes()).hexdigest()
                 for f in staged.rglob('*') if f.is_file() and f.suffix in ('.as','.json')},
        'observer_sha256':hashlib.sha256((playtest.HERE/'widgets/front_geothermal_watch.lua').read_bytes()).hexdigest(),
        'overrides':['fixed seed','read-only geo event observer']},indent=2))
    if a.stage_only:return 0
    subprocess.run(call+['launch','--dir',str(directory),'--engine','recoil_2026.07.04'],check=True,
                   env={**os.environ,**({'CIRCUIT_PERF_PHASES':'1'} if a.cost else {})})
    return subprocess.run(call+['watch','--dir',str(directory),'--role','FRONT','--checks',str(directory/'checks.json'),
        '--minutes',str(a.minutes),'--wall-minutes','20','--keep-going']).returncode


if __name__=='__main__':sys.exit(main())
