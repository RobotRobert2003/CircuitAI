"""Focused actual-VM request policy and physical AIR/local transport production."""
import argparse
import json
import subprocess
import sys
from pathlib import Path
import playtest
import storage
from run_retirement_regression import inject_entry


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pin', type=Path, required=True)
    parser.add_argument('--side', choices=('armada','cortex','legion'), default='cortex')
    parser.add_argument('--profile', default='experimental_balanced')
    parser.add_argument('--local', action='store_true')
    parser.add_argument('--visual', action='store_true')
    args = parser.parse_args()
    directory = storage.allocate('tech','cooperation','transport-demand-'+('local' if args.local else 'air'),'comet','supplied',seed=3151)
    print('TRANSPORT_DEMAND_DIRECTORY='+str(directory),flush=True)
    starts=directory/'starts.as'
    starts.write_text('StartSpot(AIFloat3(1000,0,4000),AiRole::TECH,false),\n'
                      'StartSpot(AIFloat3(2000,0,4000),AiRole::AIR,false),\n'
                      'StartSpot(AIFloat3(7000,0,4000),AiRole::FRONT,false),\n')
    call=[sys.executable,str(playtest.HERE/'playtest.py')]
    subprocess.run(call+['stage','--dir',str(directory),'--dll',str(args.pin/'SkirmishAI.dll'),
        '--data',str(args.pin/'data'),'--map','Comet Catcher Remake 1.8','--map-file',str(starts),
        '--ally-spots','1,2','--engine','recoil_2026.07.04','--role','TECH','--roles','all','--side',args.side,
        '--ai-option','profile='+args.profile,'--ai-option','random_seed=3151','--bonus','0',
        '--mode','visual' if args.visual else 'fast','--speed','20','--minutes','4',
        '--shots','3.2@2400@1300:4000' if args.visual else '', '--lean-render',
        *([] if args.visual else ['--headless']), '--modoption','deathmode=neverend',
        '--modoption','startmetal=100000','--modoption','startmetalstorage=1000000',
        '--modoption','startenergy=1000000','--modoption','startenergystorage=1000000',
        '--extra-widget',str(playtest.HERE/'widgets/transport_demand_watch.lua')],check=True)
    source=directory/'AI/Skirmish/BARbTest/test/script/src'
    (source/'transport_demand_probe.as').write_bytes((playtest.HERE/'fixtures/transport_demand_probe.as').read_bytes())
    profile=source.parent/args.profile/'main.as'
    profile.write_text('#include "../src/transport_demand_probe.as"\n'+profile.read_text())
    inject_entry(profile,'void AiLuaMessage(const string& in data)','if (TransportDemandProbe::Handle(data)) return;')
    for role in ('tech','air','front'):
        inject_entry(source/f'roles/{role}/{role}.as',f'void {role.title()}_EconomyUpdate()', 'if (ai.teamId>=0) return;')
    inject_entry(source/'manager/builder.as','IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
                 'if (ai.teamId>=0) return aiBuilderMgr.Enqueue(TaskB::Wait(10*MINUTE));')
    inject_entry(source/'manager/factory.as','IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
                 'if (ai.teamId>=0) return TransportDemandProbe::FactoryTask(u);')
    inject_entry(source/'systems/team/ferry.as','void Update()', 'if (!TransportDemandProbe::active) return;')
    inject_entry(source/'systems/construction/commander_front.as','void Update()',
                 'if (ai.teamId>=0) { aiBuilderMgr.SetCommanderCombatOption("front_duty",0); return; }')
    inject_entry(source/'systems/diagnostics/invariants.as','void Tick()','if (ai.frame>=0) return;')
    widget=directory/'LuaUI/Widgets/transport_demand_watch.lua'
    widget.write_text(widget.read_text().replace('__SIDE__',args.side).replace('__LOCAL__','true' if args.local else 'false'))
    labels=['strategy matrix','uncarryable T2 override','restricted cargo','finished rush','stale target cleared',
            'cancel keeps light','cancel closes heavy slot','delivery ledger','light only before rush','rush target','physical heavy after rush','rush target released','no extras']
    checks=directory/'transport-demand-checks.json'
    checks.write_text(json.dumps({'stop_minute':4,
        'complete_on':{'key':'done','pattern':r'\[TransportDemandTest\] PASS no extras','scope':'any'},
        'completion_grace_seconds':10,
        'expect':[{'key':label,'pattern':r'\[TransportDemandTest\] PASS '+label+r'\s*$','scope':'any','by_minute':4} for label in labels],
        'forbid':[{'key':'failure','scope':'any','pattern':r'\[TransportDemandTest\] FAIL|: ERR\s+:|\.as \(\d+,\s*\d+\)\s*:\s*WARN\s*:|SCRIPT CRASH|Lib exception|Access violation|has crashed|Fatal:|Error in.*transport_demand'}]},indent=2))
    storage.write_json(directory/'transport-demand-inputs.json',dict(side=args.side,profile=args.profile,local_build=args.local,
        overrides=['supplied air factory, one heavy cargo for ledger checks and resource banks; transport income gate zero, additional threshold 100000',
                   'ordinary role economy/building, commander deployment and periodic base invariants suspended',
                   'actual VM policy matrix, directed request, native production and donation; no supplied transports'],
        scripts={str(p.relative_to(source.parent)):storage.file_hash(p) for p in source.parent.rglob('*.as')},
        widget_sha256=storage.file_hash(widget)))
    try:
        subprocess.run(call+['launch','--dir',str(directory),'--engine','recoil_2026.07.04',
                            *([] if args.visual else ['--headless'])],check=True)
        return subprocess.call(call+['watch','--dir',str(directory),'--role','TECH','--minutes','4',
                                    '--wall-minutes','6','--checks',str(checks)])
    finally:
        subprocess.run(call+['stop','--dir',str(directory)],check=False)


if __name__=='__main__':
    sys.exit(main())
