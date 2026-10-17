"""Focused physical fog-front delivery, central spam lane and known-AA avoidance."""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
import playtest
import storage
from run_retirement_regression import inject_entry

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll',type=Path,required=True)
    p.add_argument('--data',type=Path,required=True)
    p.add_argument('--side',choices=('armada','cortex','legion'),default='cortex')
    p.add_argument('--mode',choices=('aa','clear','fallback','turns','blocked'),default='aa')
    p.add_argument('--deliveries',type=int,choices=(1,2),default=1)
    p.add_argument('--profile',default='experimental_balanced')
    p.add_argument('--visual',action='store_true')
    a=p.parse_args()
    directory=storage.allocate('tech','cooperation','heavy-front-'+a.mode,'comet','supplied',seed=3121)
    print('HEAVY_FRONT_DIRECTORY='+str(directory),flush=True)
    starts=directory/'starts.as'
    starts.write_text('StartSpot(AIFloat3(1000,0,4000),AiRole::TECH,false),\n'
        'StartSpot(AIFloat3(1500,0,6000),AiRole::FRONT,false),\n'
        'StartSpot(AIFloat3(7000,0,4000),AiRole::FRONT,false),\n')
    call=[sys.executable,str(playtest.HERE/'playtest.py')]
    subprocess.run(call+['stage','--dir',str(directory),'--dll',str(a.dll),'--data',str(a.data),
        '--map','Comet Catcher Remake 1.8','--map-file',str(starts),'--ally-spots','1,2',
        '--engine','recoil_2026.07.04','--role','TECH','--roles','all','--side',a.side,
        '--ai-option','profile='+a.profile,'--ai-option','random_seed=3121','--bonus','0',
        '--mode','visual' if a.visual else 'fast','--speed','20','--minutes','5',
        '--shots','1.3@5000@3300:4000,3@3000@4600:4000' if a.visual else '',
        '--lean-render',*([] if a.visual else ['--headless']),'--modoption','deathmode=neverend',
        '--extra-widget',str(playtest.HERE/'widgets/heavy_front_fixture.lua')],check=True)
    source=directory/'AI/Skirmish/BARbTest/test/script/src'
    (source/'heavy_front_probe.as').write_bytes((playtest.HERE/'fixtures/heavy_front_probe.as').read_bytes())
    profile=source.parent/a.profile/'main.as'
    profile.write_text('#include "../src/heavy_front_probe.as"\n'+profile.read_text())
    inject_entry(profile,'void AiLuaMessage(const string& in data)','if (HeavyFrontProbe::Handle(data)) return;')
    inject_entry(source/'roles/tech/tech.as','void Tech_EconomyUpdate()',
        'if (HeavyFrontProbe::active) { TechHeavyRush::Tick(); return; }')
    inject_entry(source/'manager/builder.as','IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
        'if (ai.teamId>=0) return aiBuilderMgr.Enqueue(TaskB::Wait(15*MINUTE));')
    inject_entry(source/'manager/factory.as','IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
        'if (ai.teamId>=0) return aiFactoryMgr.Enqueue(TaskS::Wait(false,SECOND));')
    inject_entry(source/'systems/construction/commander_front.as','void Update()',
        'if (ai.teamId>=0) { aiBuilderMgr.SetCommanderCombatOption("front_duty",0); return; }')
    inject_entry(source/'systems/diagnostics/invariants.as','void Tick()','if (ai.frame>=0) return;')
    widget=directory/'LuaUI/Widgets/heavy_front_fixture.lua'
    widget.write_text(widget.read_text().replace('__SIDE__',a.side).replace('__MODE__',a.mode)
        .replace('__FORWARD__','true' if a.profile=='experimental_balanced' else 'false')
        .replace('__DELIVERIES__',str(a.deliveries)))
    checks=directory/'heavy-front-checks.json'
    checks.write_text(json.dumps({'stop_minute':5,'expect':[
        {'key':label,'pattern':r'\[HeavyFrontTest\] PASS '+label,'scope':'any','by_minute':5}
        for label in ('geometry','admission','central lane','arrival','final delivery')],
        'forbid':[{'key':'failure','scope':'any','pattern':
        r'\[HeavyFrontTest\] FAIL|\[INVARIANT\]|: ERR\s+:|\.as \(\d+,\s*\d+\)\s*:\s*WARN\s*:|SCRIPT CRASH|Lib exception|Access violation|has crashed|Fatal:|Error in.*heavy_front'}]},indent=2))
    if a.mode=='blocked':
        check_data=json.loads(checks.read_text())
        check_data['expect'].extend([
            {'key':'blocked route recovery','pattern':r'FERRY: routed run failed \(blocked flight corridor\)',
             'scope':'any','by_minute':2},
            {'key':'blocked fixture','pattern':r'\[HeavyFrontTest\] blocked goal observed',
             'scope':'any','by_minute':2},
            {'key':'AA removed after unload','pattern':r'\[HeavyFrontTest\] PASS blocking AA removed',
             'scope':'any','by_minute':2}])
        checks.write_text(json.dumps(check_data,indent=2))
    storage.write_json(directory/'heavy-front-inputs.json',dict(side=a.side,mode=a.mode,profile=a.profile,deliveries=a.deliveries,
        overrides=['supplied cargo, aircraft, factory lanes, allied ground sight and enemy AA',
            'ordinary builder/production/commander deployment and periodic base invariants suspended',
            'real heavy ledger, selection, ferry, load/unload/transfer; event invariant retained'],
        scripts={str(q.relative_to(source.parent)):storage.file_hash(q) for q in source.parent.rglob('*.as')},
        widget_sha256=storage.file_hash(widget)))
    try:
        subprocess.run(call+['launch','--dir',str(directory),'--engine','recoil_2026.07.04'],check=True)
        code=subprocess.call(call+['watch','--dir',str(directory),'--role','TECH','--minutes','5',
            '--wall-minutes','8','--checks',str(checks)])
        # A Lua callback exception may not be a role-tagged timeline event.
        # Validate the raw observer too, including the full survival/return tail.
        log=(directory/'infolog.txt').read_text(errors='replace')
        errors=re.findall(r'^.*(?:\[HeavyFrontTest\] FAIL|Error in.*heavy_front|SCRIPT CRASH|Lib exception|Access violation).*$',log,re.M)
        passed=code==0 and not errors and '[HeavyFrontTest] PASS final delivery safe=true' in log
        storage.write_json(directory/'heavy-front-result.json',dict(passed=passed,watch_exit=code,errors=errors))
        return 0 if passed else 1
    finally:
        subprocess.run(call+['stop','--dir',str(directory)],check=False)

if __name__=='__main__':sys.exit(main())
