"""Focused low-income AIR first-lab admission and physical completion."""
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
    parser.add_argument('--side', choices=('armada', 'cortex', 'legion'), default='armada')
    parser.add_argument('--profile', default='experimental_balanced')
    parser.add_argument('--legacy', action='store_true', help='Retain a failing old-policy control')
    parser.add_argument('--visual', action='store_true')
    parser.add_argument('--small-storage', action='store_true')
    parser.add_argument('--growth', action='store_true', help='Begin below lab funding and require physical local mex growth')
    args = parser.parse_args()
    # Legacy full-bank admission plus an unassisted 640-690 s build exceeds
    # twelve minutes. Keep balanced acceptance fixed; allow legacy completion.
    minutes = 12 if args.profile=='experimental_balanced' else 16
    directory = storage.allocate('air', 'economy', 'funded-first-lab', 'comet', 'supplied', seed=3171)
    print('AIR_TRANSITION_DIRECTORY='+str(directory), flush=True)
    starts = directory/'starts.as'
    starts.write_text('StartSpot(AIFloat3(1000,0,4000),AiRole::AIR,false),\n'
                      'StartSpot(AIFloat3(7000,0,4000),AiRole::FRONT,false),\n')
    call = [sys.executable, str(playtest.HERE/'playtest.py')]
    subprocess.run(call+['stage','--dir',str(directory),'--dll',str(args.pin/'SkirmishAI.dll'),
        '--data',str(args.pin/'data'),'--map','Comet Catcher Remake 1.8','--map-file',str(starts),
        '--ally-spots','1','--engine','recoil_2026.07.04','--role','AIR','--roles','all','--side',args.side,
        '--ai-option','profile='+args.profile,'--ai-option','random_seed=3171','--bonus','0',
        '--mode','visual' if args.visual else 'fast','--speed','20','--minutes',str(minutes),
        '--shots','4@2400@1300:4000' if args.visual else '', '--lean-render',
        *([] if args.visual else ['--headless']), '--modoption','deathmode=neverend',
        '--modoption','startmetal='+('600' if args.growth else '1600'),'--modoption','startmetalstorage='+('1000' if args.small_storage else '3000'),
        '--modoption','startenergy=20000','--modoption','startenergystorage=30000',
        '--extra-widget',str(playtest.HERE/'widgets/air_transition_watch.lua')],check=True)
    source=directory/'AI/Skirmish/BARbTest/test/script/src'
    (source/'air_transition_probe.as').write_bytes((playtest.HERE/'fixtures/air_transition_probe.as').read_bytes())
    probe=source/'air_transition_probe.as'
    probe.write_text(probe.read_text().replace('__INITIAL_FUNDING__','false' if args.growth else 'true'))
    profile=source.parent/args.profile/'main.as'
    profile.write_text('#include "../src/air_transition_probe.as"\n'+profile.read_text())
    inject_entry(profile,'void AiLuaMessage(const string& in data)','if (AirTransitionProbe::Handle(data)) return;')
    if args.legacy:
        inject_entry(source/'air_transition_probe.as','bool Handle(const string& in message)',
                     'Global::RoleSettings::Air::FundFirstLab=false;')
    # The unregistered arena map normally resolves to FRONT. Supply its AIR
    # start role before ordinary setup, so native/script startup agree.
    # Use the default map's actual StartSpots, not a post-start role handoff.
    default_map=source/'maps/default_map_config.as'
    content=default_map.read_text()
    default_map.write_text('StartSpot@[] fixtureSpots = {StartSpot(AIFloat3(1000,0,4000),AiRole::AIR,false), StartSpot(AIFloat3(7000,0,4000),AiRole::FRONT,false)};\n'
        +content.replace('getDefaultMaxUnits()\n','getDefaultMaxUnits(), fixtureSpots\n'))
    for role in ('air','front'):
        inject_entry(source/f'roles/{role}/{role}.as',f'void {role.title()}_EconomyUpdate()',
                     'if (ai.teamId!=0 || !AirTransitionProbe::active) return;')
    inject_entry(source/'manager/builder.as','IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
                 'if (ai.teamId>=0) return AirTransitionProbe::BuilderTask(u);')
    inject_entry(source/'manager/factory.as','IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
                 'if (ai.teamId>=0) return AirTransitionProbe::FactoryTask(u);')
    inject_entry(source/'systems/construction/commander_front.as','void Update()',
                 'if (ai.teamId>=0) { aiBuilderMgr.SetCommanderCombatOption("front_duty",0); return; }')
    inject_entry(source/'systems/diagnostics/invariants.as','void Tick()','if (ai.frame>=0) return;')
    widget=directory/'LuaUI/Widgets/air_transition_watch.lua'
    widget.write_text(widget.read_text().replace('__SIDE__',args.side)
        .replace('__FUNDED__','true' if args.profile=='experimental_balanced' else 'false')
        .replace('__LEGACY__','true' if args.legacy else 'false')
        .replace('__GROWTH__','true' if args.growth else 'false'))
    labels=['fixture loaded','profile admission','legacy gate','recovery gate','wind drop',
            'future gifts excluded','later lab gate','physical lab start','physical completion',
            'completion releases reserve']
    if not args.legacy and args.profile=='experimental_balanced':
        labels += ['started project survives recovery','defence during funded lab','physical defence completion']
        labels += ['physical local mex growth'] if args.growth else ['single funded obligation','cancel releases reserve']
    checks=directory/'air-transition-checks.json'
    checks.write_text(json.dumps({'stop_minute':minutes,
        'complete_on':{'key':'done','pattern':r'\[AirTransitionTest\] PASS physical completion','scope':'any'},
        'completion_grace_seconds':10,
        'expect':[{'key':label,'pattern':r'\[AirTransitionTest\] PASS '+label+r'\s*$','scope':'any','by_minute':minutes} for label in labels],
        'forbid':[{'key':'failure','scope':'any','pattern':r'\[AirTransitionTest\] FAIL|INVARIANT|: ERR\s+:|\.as \(\d+,\s*\d+\)\s*:\s*WARN\s*:|SCRIPT CRASH|Lib exception|Access violation|has crashed|Fatal:|Error in.*air_transition'}]},indent=2))
    storage.write_json(directory/'air-transition-inputs.json',dict(side=args.side,profile=args.profile,legacy=args.legacy,
        growth=args.growth,small_storage=args.small_storage,
        overrides=['supplied T1 factory, three air constructors, two fusions/converter and initial bank; actual income thereafter',
                   'opening milestones/age supplied; commander held; one real defensive fighter order during funded lab, other factory production held; opposite AI held',
                   'periodic natural-base invariants suspended; Record admission invariants retained',
                   'VM gate matrix briefly overrides observed incomes/recovery then restores; physical build uses live economy'],
        scripts={str(p.relative_to(source.parent)):storage.file_hash(p) for p in source.parent.rglob('*.as')},
        widget_sha256=storage.file_hash(widget)))
    try:
        subprocess.run(call+['launch','--dir',str(directory),'--engine','recoil_2026.07.04',
                            *([] if args.visual else ['--headless'])],check=True)
        return subprocess.call(call+['watch','--dir',str(directory),'--role','AIR','--minutes',str(minutes),
                                    '--wall-minutes','6','--checks',str(checks)])
    finally:
        subprocess.run(call+['stop','--dir',str(directory)],check=False)


if __name__=='__main__':
    sys.exit(main())
