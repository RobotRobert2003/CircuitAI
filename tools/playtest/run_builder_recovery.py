"""Full roster construction integration; optional same-callback pin fixture.

No economy gifts or unit orders. Explicit nuke override applies to TECH only.
The pin probe creates and cancels two unassigned tasks in the same callback.
Actual lost-command recovery is separately identified from native diagnostics.
"""
from script_settings import role_settings_path
import argparse
import json
from pathlib import Path
import subprocess
import sys
import playtest
import storage
from ranged_arena import pool_symbols

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--pin',type=Path,required=True)
    p.add_argument('--map',default='Glacial Gap v1.1')
    p.add_argument('--map-file',type=Path,help='Explicit map-role definition when the map name does not match its script filename')
    p.add_argument('--minutes',type=int,default=25)
    p.add_argument('--bonus',type=int,default=50)
    p.add_argument('--profile',default='experimental_balanced')
    p.add_argument('--side',default='legion')
    p.add_argument('--seed',type=int,default=23901)
    p.add_argument('--probe',action='store_true')
    p.add_argument('--trace-builders',action='store_true',help='Read-only native task census, without synthetic tasks')
    p.add_argument('--fault-probe',action='store_true',help='Separate fault-injection run: drop a build command and lease a worker')
    p.add_argument('--shots',default='5@2400,10@2400,15@2400,20@2400')
    p.add_argument('--experimental-sea',action='store_true')
    a=p.parse_args()
    d=storage.allocate('shared','reliability','builder-recovery',a.map,'regression',seed=a.seed,bonus=a.bonus)
    print('BUILDER_RECOVERY='+str(d),flush=True)
    cli=[sys.executable,str(playtest.HERE/'playtest.py')]
    stage=cli+['stage','--dir',str(d),'--dll',str(a.pin/'SkirmishAI.dll'),'--data',str(a.pin/'data'),
        '--map',a.map,'--role','TECH','--roles','all','--side',a.side,'--bonus',str(a.bonus),
        '--game','Beyond All Reason test-31516-95f3e26','--engine','recoil_2026.07.04',
        '--ai-option','profile='+a.profile,'--ai-option','random_seed='+str(a.seed),
        '--set','RushObjective="nuke"','--set','EndgamePlan="nuke"',
        '--modoption','deathmode=neverend','--speed','20','--minutes',str(a.minutes),
        '--shots',a.shots,'--width','1280','--height','720','--lean-render']
    if a.map_file:
        stage+=['--map-file',str(a.map_file)]
    for widget in ['construction_watch.lua','nuke_rush_watch.lua','workforce_perf_watch.lua']:
        stage+=['--extra-widget',str(playtest.HERE/'widgets'/widget)]
    subprocess.run(stage,check=True)
    start_script=d/'script.txt'
    start_script.write_text(start_script.read_text().replace('[GAME]\n{','[GAME]\n{\n FixedRNGSeed='+str(a.seed)+';',1))
    staged=d/'AI/Skirmish/BARbTest/test';pool_symbols(staged)
    if a.experimental_sea:
        f=role_settings_path(staged/'script/src', 'Sea');s=f.read_text();pos=s.index('namespace Sea {');before=s[:pos];after=s[pos:]
        after=after.replace('bool ExperimentalBuild = false','bool ExperimentalBuild = true',1)
        f.write_text(before+after)
    if a.probe or a.trace_builders:
        f=staged/'script'/a.profile/'main.as';s=f.read_text()
        s=s.replace('ArtilleryPolicy::Check();','ArtilleryPolicy::Check();\n        ConstructionRecoveryProbe::Tick();',1)
        probe=(playtest.HERE/'construction_recovery_probe.as').read_text()
        if not a.probe: probe=probe.replace('bool pinChecked=false;','bool pinChecked=true;',1)
        f.write_text(s+'\n'+probe)
    if a.fault_probe:
        f=staged/'script'/a.profile/'main.as';s=f.read_text()
        s=s.replace('ArtilleryPolicy::Check();','ArtilleryPolicy::Check();\n        ConstructionFaultProbe::Tick();',1)
        f.write_text(s+'\n'+(playtest.HERE/'construction_fault_probe.as').read_text())
    checks={'expect':[{'key':'roles','pattern':'role','scope':'any','by_minute':2}],
        'forbid':[{'key':'script','pattern':': ERR\\s+:','scope':'any'},
                  {'key':'invariant','pattern':'INVARIANT','scope':'any'},
                  {'key':'probe','pattern':'(?:pin|orphan)-transaction=FAIL','scope':'any'},
                  {'key':'crash','pattern':'Access violation|has crashed','scope':'any'}], 'stop_minute':a.minutes}
    if a.probe:
        checks['expect'].append({'key':'pin','pattern':'pin-transaction=PASS','scope':'any','by_minute':5})
        checks['expect'].append({'key':'orphan','pattern':'orphan-transaction=PASS','scope':'any','by_minute':5})
    if a.fault_probe:
        checks['forbid'].append({'key':'fault','pattern':'ConstructionFault.*=FAIL','scope':'any'})
        for kind in ('dropped-command','ownership-lease','transferred-worker'):
            checks['expect'].append({'key':kind,'pattern':kind+'=PASS','scope':'any','by_minute':8})
    (d/'checks.json').write_text(json.dumps(checks,indent=2))
    (d/'review-pins.json').write_text(json.dumps(dict(arguments=vars(a)|{'pin':str(a.pin),'map_file':str(a.map_file) if a.map_file else None},stage=stage,
        dll_sha256=storage.file_hash(a.pin/'SkirmishAI.dll'),files={str(f.relative_to(staged)):storage.file_hash(f)
        for f in staged.rglob('*') if f.suffix in ('.as','.json','.lua')}),indent=2))
    subprocess.run([sys.executable,str(playtest.REPO/'tools/knowledge/check_script_api.py'),'--dll',str(a.pin/'SkirmishAI.dll'),'--scripts',str(staged/'script')],check=True)
    subprocess.run(cli+['launch','--dir',str(d),'--engine','recoil_2026.07.04'],check=True)
    return subprocess.run(cli+['watch','--dir',str(d),'--role','TECH','--checks',str(d/'checks.json'),
        '--minutes',str(a.minutes),'--wall-minutes','35','--keep-going']).returncode

if __name__=='__main__': sys.exit(main())
