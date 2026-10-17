"""Focused supplied FRONT opener checks; no timing or broad regression claims."""
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
    parser.add_argument('--side', choices=('armada', 'cortex', 'legion'), default='cortex')
    parser.add_argument('--scenario', choices=('tank', 'spam', 'ordinary', 'unavailable', 'casualty', 'factory-loss', 'cancel', 'timeout', 'profile'), default='tank')
    parser.add_argument('--kind', choices=('bot', 'vehicle'), default='vehicle')
    parser.add_argument('--profile', default='experimental_balanced')
    parser.add_argument('--visual', action='store_true')
    args = parser.parse_args()
    directory = storage.allocate('front', 'combat', 'opener-'+args.scenario, 'supreme', 'supplied', seed=3091)
    print('FRONT_OPENER_DIRECTORY='+str(directory), flush=True)
    call = [sys.executable, str(playtest.HERE/'playtest.py')]
    subprocess.run(call+['stage', '--dir', str(directory), '--dll', str(args.dll), '--data', str(args.data),
        '--map', 'Supreme Isthmus v1.7', '--engine', 'recoil_2026.07.04', '--role', 'FRONT', '--roles', 'FRONT',
        '--side', args.side, '--ai-option', 'profile='+args.profile, '--ai-option', 'random_seed=3091',
        '--bonus', '0', '--mode', 'visual' if args.visual else 'fast', '--speed', '20', '--minutes', '8',
        '--shots', '0.6@2200@1400:9800,1.2@2800@1400:9400' if args.visual else '', '--lean-render',
        *([] if args.visual else ['--headless']), '--modoption', 'deathmode=neverend',
        '--modoption', 'startmetal=100000', '--modoption', 'startmetalstorage=1000000',
        '--modoption', 'startenergy=1000000', '--modoption', 'startenergystorage=1000000',
        '--extra-widget', str(playtest.HERE/'widgets/front_opener_watch.lua')], check=True)
    source = directory/'AI/Skirmish/BARbTest/test/script/src'
    (source/'front_opener_probe.as').write_bytes((playtest.HERE/'fixtures/front_opener_probe.as').read_bytes())
    profile = source.parent/args.profile/'main.as'
    profile.write_text('#include "../src/front_opener_probe.as"\n'+profile.read_text())
    inject_entry(profile, 'void AiLuaMessage(const string& in data)', 'if (FrontOpenerProbe::Handle(data)) return;')
    inject_entry(source/'roles/front/front.as', 'void Front_EconomyUpdate()', 'if (ai.teamId >= 0) return;')
    inject_entry(source/'roles/front/front.as', 'void Front_MainUpdate()', 'FrontOpenerProbe::Tick();')
    inject_entry(source/'manager/builder.as', 'IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
                 'if (ai.teamId >= 0) return FrontOpenerProbe::BuilderTask(u);')
    inject_entry(source/'manager/factory.as', 'IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
                 'if (ai.teamId >= 0 && !(FrontOpenerProbe::active && FrontOpenerProbe::mode == "spam" && RoleFront::g_frontRaiderOpenerDone)) return FrontOpenerProbe::FactoryTask(u);')
    inject_entry(source/'manager/military.as', 'IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
                 'IUnitTask@ gift = FrontOpenerProbe::GiftTask(u); if (gift !is null) return gift;')
    inject_entry(source/'systems/diagnostics/invariants.as', 'void Tick()', 'if (ai.frame >= 0) return;')
    widget = directory/'LuaUI/Widgets/front_opener_watch.lua'
    widget.write_text(widget.read_text().replace('__MODE__',args.scenario).replace('__SIDE__',args.side).replace('__KIND__',args.kind))
    checks = directory/'front-opener-checks.json'
    pattern = r'\[FrontOpenerTest\] PASS sequence_and_departure'
    expected = [{'key':'physical sequence and departure','pattern':pattern,'by_minute':8,'scope':'any'},
        {'key':'effective build edges','pattern':r'\[FrontOpenerTest\] build_edges_checked=5','by_minute':1,'scope':'any'},
        {'key':'observer','pattern':r'\[FrontOpenerTest\] observer_started','by_minute':1,'scope':'any'}]
    tank = args.scenario not in ('ordinary','unavailable','profile') and args.side != 'armada' and args.kind == 'vehicle'
    if tank:
        count = 9 if args.scenario in ('casualty','cancel') else (4 if args.scenario=='factory-loss' else 10)
        launch = r'\[Gather\] launch units='+str(count)+r' .*expired=0'
        if args.scenario == 'factory-loss': launch = r'\[Gather\] launch units=[1-4] .*threshold=0\.00000 expired=0'
        if args.scenario == 'timeout': launch = r'\[Gather\] launch units=[1-9] .*expired=1'
        expected.append({'key':'native cohort launch','pattern':launch,'by_minute':8,'scope':'any'})
        if args.scenario == 'spam': expected.append({'key':'competing spam route active','pattern':'competing_spam_route_ready','by_minute':2,'scope':'any'})
    forbidden = [{'key':'failure','pattern':r'\[FrontOpenerTest\] FAIL|\[INVARIANT\]|: ERR\s+:|\.as \(\d+,\s*\d+\)\s*:\s*WARN\s*:|SCRIPT CRASH|Lib exception|Access violation|has crashed|Fatal:|Error in.*front_opener','scope':'any'}]
    if not tank:
        forbidden.append({'key':'no tank cohort in control','pattern':r'\[FrontOpener\] tank=|\[Gather\] launch','scope':'any'})
    if args.scenario == 'profile' and args.profile != 'experimental_balanced':
        expected.append({'key':'profile remains disabled','pattern':r'configured chance=0$','by_minute':1,'scope':'any'})
    checks.write_text(json.dumps({'stop_minute':8,'complete_on':{'key':'complete','pattern':pattern,'scope':'any'},
        'completion_grace_seconds':5,'expect':expected,
        'forbid':forbidden},indent=2))
    (directory/'front-opener-inputs.json').write_text(json.dumps({'side':args.side,'scenario':args.scenario,'profile':args.profile,'kind':args.kind,
        'overrides':['supplied factory, constructor, caretaker and resources','forced chance except profile controls',
            'normal economy/builders suspended','real FRONT recruitment, no subsequent ordinary production',
            'unrelated gift raid/defend tasks','periodic whole-base invariants suspended; admissions remain active'],
        'files':{str(p.relative_to(directory)):storage.file_hash(p) for p in source.parent.rglob('*.as')},
        'widget_sha256':storage.file_hash(widget)},indent=2))
    try:
        subprocess.run(call+['launch','--dir',str(directory),'--engine','recoil_2026.07.04'],check=True)
        return subprocess.call(call+['watch','--dir',str(directory),'--role','FRONT','--minutes','8',
            '--wall-minutes','10','--checks',str(checks)])
    finally:
        subprocess.run(call+['stop','--dir',str(directory)],check=False)


if __name__ == '__main__':
    sys.exit(main())
