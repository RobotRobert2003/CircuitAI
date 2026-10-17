"""Pinch Point: protected ally mex, expiry/recovery and physical cliff construction."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import playtest
import storage
from run_retirement_regression import inject_entry

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pin',type=Path,required=True)
    parser.add_argument('--cutoff',type=int,default=600)
    parser.add_argument('--visual',action='store_true')
    args=parser.parse_args()
    directory=storage.allocate('shared','economy','mex-ownership','pinch-point','supplied',seed=3221)
    print('MEX_OWNERSHIP_DIRECTORY='+str(directory),flush=True)
    starts=directory/'starts.as'
    starts.write_text('StartSpot(AIFloat3(1769,0,1928), AiRole::FRONT, false),\n'
                      'StartSpot(AIFloat3(4578,0,2485), AiRole::FRONT, false),\n'
                      'StartSpot(AIFloat3(13851,0,3801), AiRole::FRONT, false),\n')
    minutes=args.cutoff/60+3
    call=[sys.executable,str(playtest.HERE/'playtest.py')]
    stage=call+['stage','--dir',str(directory),'--dll',str(args.pin/'SkirmishAI.dll'),
        '--data',str(args.pin/'data'),'--map','Pinch Point 1.03','--map-file',str(starts),
        '--role','FRONT','--roles','all','--ally-spots','1,2','--side','armada',
        '--engine','recoil_2026.07.04','--ai-option','profile=experimental_balanced',
        '--ai-option','random_seed=3221','--bonus','0','--mode','visual' if args.visual else 'fast',
        '--speed','20','--minutes',str(minutes),'--shots',
        '1.2@2000@14264:136,2@1800@4536:2328' if args.visual else '', '--lean-render',
        '--modoption','deathmode=neverend','--modoption','startmetal=100000',
        '--modoption','startmetalstorage=1000000','--modoption','startenergy=1000000',
        '--modoption','startenergystorage=1000000',
        '--extra-widget',str(playtest.HERE/'widgets/mex_ownership_watch.lua')]
    if not args.visual: stage.append('--headless')
    subprocess.run(stage,check=True)
    source=directory/'AI/Skirmish/BARbTest/test/script/src'
    setup=source/'setup.as'
    setup.write_text(setup.read_text().replace('Global::AISettings::Role = derivedRole;',
        'derivedRole=AiRole::FRONT; Global::AISettings::Role = derivedRole;'))
    (source/'mex_ownership_probe.as').write_text((playtest.HERE/'fixtures/mex_ownership_probe.as').read_text().replace('__CUTOFF__',str(args.cutoff)+'.f'))
    widget=directory/'LuaUI/Widgets/mex_ownership_watch.lua'
    widget.write_text(widget.read_text().replace('__CUTOFF__',str(args.cutoff)))
    profile=source.parent/'experimental_balanced/main.as'
    profile.write_text('#include "../src/mex_ownership_probe.as"\n'+profile.read_text())
    inject_entry(profile,'void AiLuaMessage(const string& in data)','if (MexOwnershipProbe::Handle(data)) return;')
    inject_entry(source/'roles/front/front.as','void Front_EconomyUpdate()','if (ai.frame>=0) return;')
    inject_entry(source/'systems/construction/commander_front.as','void Update()',
        'if (ai.frame>=0) { aiBuilderMgr.SetCommanderCombatOption("front_duty",0); return; }')
    inject_entry(source/'manager/builder.as','IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
        'if (ai.frame>=0) return MexOwnershipProbe::Task(u);')
    inject_entry(source/'manager/factory.as','IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
        'if (ai.frame>=0) return aiFactoryMgr.Enqueue(TaskS::Wait(false,SECOND));')
    inject_entry(source/'systems/diagnostics/invariants.as','void Tick()','if (ai.frame>=0) return;')
    labels=['default configuration','profile enabled','valley cannot build mountain','mountain cannot build valley',
        'air can build mountain','ally protected','opening cannot bypass ownership','zero disables protection',
        'unstarted order supplied','stale order released','protected before deadline','released at deadline',
        'physical mountain mex','physical late recovery','all physical checks']
    checks={'stop_minute':minutes,'completion_grace_seconds':10,
        'complete_on':{'key':'complete','pattern':r'\[MexOwnershipTest\] PASS all physical checks','scope':'any'},
        'expect':[{'key':s,'pattern':r'\[MexOwnershipTest\] PASS '+s,'by_minute':minutes,'scope':'any'} for s in labels],
        'forbid':[{'key':'failure','pattern':r'\[MexOwnershipTest\] FAIL|\[INVARIANT\]|: ERR\s+:|SCRIPT CRASH|Lib exception|Access violation|has crashed|Fatal:|Error in.*mex_ownership','scope':'any'}]}
    check=directory/'mex-ownership-checks.json';check.write_text(json.dumps(checks,indent=2))
    (directory/'mex-ownership-inputs.json').write_text(json.dumps({'cutoff':args.cutoff,
        'overrides':['supplied cliff builders and aircraft; ally mex loss','ordinary work and whole-base invariants held'],
        'scripts':{str(p.relative_to(source.parent)):storage.file_hash(p) for p in source.parent.rglob('*.as')},
        'widget':storage.file_hash(widget)},indent=2))
    try:
        subprocess.run(call+['launch','--dir',str(directory),'--engine','recoil_2026.07.04']+([] if args.visual else ['--headless']),check=True)
        return subprocess.call(call+['watch','--dir',str(directory),'--role','FRONT','--minutes',str(minutes),
            '--wall-minutes','8','--checks',str(check)])
    finally: subprocess.run(call+['stop','--dir',str(directory)],check=False)

if __name__=='__main__': sys.exit(main())
