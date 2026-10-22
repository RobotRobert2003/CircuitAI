"""Focused physical compact TECH placement on Coastlines Dry; supplied resources/workers."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import playtest
import storage
from run_retirement_regression import inject_entry


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', type=Path, required=True)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--side', choices=playtest.SIDES, default='cortex')
    parser.add_argument('--east', action='store_true')
    parser.add_argument('--economy-first', action='store_true', help='Verify local turret seeding after an economy project opens a bank')
    parser.add_argument('--visual', action='store_true')
    parser.add_argument('--displaced-lab', action='store_true', help='Legion shelf: real rush turret admission with distant home and supplied ground workers')
    parser.add_argument('--profile', default='experimental_balanced')
    args = parser.parse_args()
    if args.displaced_lab and (args.side != 'legion' or not args.east or args.economy_first):
        parser.error('--displaced-lab requires --side legion --east without --economy-first')
    directory = storage.allocate('tech', 'layout', 'compact-'+args.side+('-east' if args.east else '-west'), 'coastlines', 'supplied', seed=3071)
    print('TECH_COMPACT_DIRECTORY='+str(directory), flush=True)
    call = [sys.executable, str(playtest.HERE/'playtest.py')]
    stage = ['stage','--dir',str(directory),'--dll',str(args.dll),'--data',str(args.data),
        '--map','Coastlines_Dry_V2.2.1','--map-file',str(playtest.REPO/'data/script/src/maps/coastlines_dry.as'),
        '--engine','recoil_2026.07.04','--role','TECH','--roles','TECH','--side',args.side,
        '--ai-option','profile='+args.profile,'--ai-option','random_seed=3071','--bonus','0',
        '--mode','visual' if args.visual else 'fast','--speed','20','--minutes','10','--modoption','deathmode=neverend',
        '--modoption','startmetal=1000000','--modoption','startmetalstorage=10000000',
        '--modoption','startenergy=100000000','--modoption','startenergystorage=100000000',
        '--extra-widget',str(playtest.HERE/'widgets/tech_compact_watch.lua')]
    if not args.visual: stage += ['--headless']
    else: stage += ['--shots','2,4']
    if args.east: stage += ['--ally-spots','9,10,11,12,13,14,15,16']
    subprocess.run(call+stage, check=True)
    source = directory/'AI/Skirmish/BARbTest/test/script/src'
    (source/'tech_compact_probe.as').write_bytes((playtest.HERE/'fixtures/tech_compact_probe.as').read_bytes())
    if args.economy_first:
        probe = source/'tech_compact_probe.as'
        probe.write_text(probe.read_text().replace('int phase = 0;', 'int phase = -1;'))
    if args.displaced_lab:
        probe = source/'tech_compact_probe.as'
        probe.write_text(probe.read_text().replace('bool displacedLab = false;', 'bool displacedLab = true;'))
    profile = source.parent/args.profile/'main.as'
    profile.write_text('#include "../src/tech_compact_probe.as"\n'+profile.read_text())
    inject_entry(profile, 'void AiLuaMessage(const string& in data)', 'if (TechCompactProbe::Handle(data)) return;')
    inject_entry(source/'roles/tech/tech.as','void Tech_EconomyUpdate()','if (ai.teamId >= 0) return;')
    inject_entry(source/'manager/builder.as','IUnitTask@ AiMakeTask(CCircuitUnit@ u)','if (ai.teamId >= 0) return TechCompactProbe::Task(u);')
    inject_entry(source/'manager/factory.as','IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
        'if (u.circuitDef.GetName() == UnitHelpers::GetT1NanoNameForSide(Global::AISettings::Side)) return RoleTech::Tech_FactoryAiMakeTask(u); if (ai.teamId >= 0) return aiFactoryMgr.Enqueue(TaskS::Wait(false, SECOND));')
    inject_entry(source/'systems/diagnostics/invariants.as','void Tick()','if (ai.frame >= 0) return;')
    economy = source/'manager/economy.as'
    economy.write_text(economy.read_text().replace('_UpdateSlidingMinima(ai.frame, metal.income, energy.income);',
        '_UpdateSlidingMinima(ai.frame, 40.0f, energy.income);'))
    prefix = {'armada':'arm','cortex':'cor','legion':'leg'}[args.side]
    names = dict(nano=prefix+'nanotc', afus=prefix+'afus',converter=prefix+'mmkr',store=prefix+'estor',t1=prefix+'ca',t2=prefix+'aca')
    if args.side == 'legion': names['converter'] = 'legadveconv'
    if args.displaced_lab: names.update(t1='legck',t2='legack')
    widget = directory/'LuaUI/Widgets/tech_compact_watch.lua'
    widget.write_text(widget.read_text().replace('__NAMES__','{'+','.join(k+'="'+v+'"' for k,v in names.items())+'}'))
    if args.economy_first: widget.write_text(widget.read_text().replace('local phase=0','local phase=-1'))
    if args.displaced_lab:
        widget.write_text(widget.read_text().replace('for i=0,11 do give', 'x=9368;z=2368\n        for i=0,11 do give')
            .replace('(i%4)*70','(i%4)*24').replace('math.floor(i/4)*70','math.floor(i/4)*24'))
    checks=directory/'compact-checks.json'
    checks.write_bytes((playtest.HERE/'checks/tech/layout/compact-eco.json').read_bytes())
    if args.economy_first:
        spec=json.loads(checks.read_text())
        spec['expect'].append(dict(key='local support seeded',pattern=r'\[TechCompactTest\] PASS local_support_seed',scope='any',by_minute=10))
        checks.write_text(json.dumps(spec,indent=2))
    if args.displaced_lab:
        spec=json.loads(checks.read_text())
        spec['expect'].append(dict(key='displaced lab',pattern=r'\[TechCompactTest\] PASS displaced_lab_reserved',scope='any',by_minute=1))
        checks.write_text(json.dumps(spec,indent=2))
    (directory/'compact-inputs.json').write_text(json.dumps({'side':args.side,'east':args.east,'profile':args.profile,'economy_first':args.economy_first,'displaced_lab':args.displaced_lab,
        'overrides':['supplied resource banks; '+('ground constructors, reported home/lab anchors and real nuke turret gate' if args.displaced_lab else 'flying constructors'),'fixed 40 metal sliding income',
            'ordinary economy/factory decisions held; real layout and recovery methods', 'whole-base periodic invariants held; construction admission remains enabled'],
        'scripts':{str(p.relative_to(directory)):storage.file_hash(p) for p in source.parent.rglob('*.as')},
        'widget_sha256':storage.file_hash(widget)},indent=2))
    try:
        subprocess.run(call+['launch','--dir',str(directory),'--engine','recoil_2026.07.04']+([] if args.visual else ['--headless']),check=True)
        return subprocess.call(call+['watch','--dir',str(directory),'--minutes','10','--wall-minutes','8','--checks',str(checks)])
    finally:
        subprocess.run(call+['stop','--dir',str(directory)],check=False)


if __name__ == '__main__': sys.exit(main())
