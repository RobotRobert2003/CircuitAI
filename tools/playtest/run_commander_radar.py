"""Supplied commander radar coverage boundaries, queue admission and real construction."""
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
    parser.add_argument('--side', choices=('armada', 'cortex', 'legion'), default='armada')
    parser.add_argument('--profile', default='experimental_balanced')
    parser.add_argument('--visual', action='store_true')
    args = parser.parse_args()
    directory = storage.allocate('front', 'combat', 'commander-radar', 'comet', 'supplied', seed=3101)
    print('COMMANDER_RADAR_DIRECTORY='+str(directory), flush=True)
    starts = directory/'starts.as'
    starts.write_text(''.join(f'StartSpot(AIFloat3({x},0,{z}), AiRole::FRONT, false),\n'
                            for x,z in ((4000,4000),(2000,2000),(7000,7000))))
    call = [sys.executable, str(playtest.HERE/'playtest.py')]
    subprocess.run(call+['stage', '--dir', str(directory), '--dll', str(args.dll), '--data', str(args.data),
        '--map', 'Comet Catcher Remake 1.8', '--map-file', str(starts), '--ally-spots', '1,2',
        '--engine', 'recoil_2026.07.04', '--role', 'FRONT', '--roles', 'all', '--side', args.side,
        '--ai-option', 'profile='+args.profile, '--ai-option', 'random_seed=3101', '--bonus', '0',
        '--mode', 'visual' if args.visual else 'fast', '--speed', '20', '--minutes', '3',
        '--shots', '1.3@2600@4000:4000' if args.visual else '', '--lean-render',
        *([] if args.visual else ['--headless']), '--modoption', 'deathmode=neverend',
        '--modoption', 'startmetal=100000', '--modoption', 'startmetalstorage=1000000',
        '--modoption', 'startenergy=1000000', '--modoption', 'startenergystorage=1000000',
        '--extra-widget', str(playtest.HERE/'widgets/commander_radar_watch.lua')], check=True)
    source = directory/'AI/Skirmish/BARbTest/test/script/src'
    (source/'commander_radar_probe.as').write_bytes((playtest.HERE/'fixtures/commander_radar_probe.as').read_bytes())
    profile = source.parent/args.profile/'main.as'
    profile.write_text('#include "../src/commander_radar_probe.as"\n'+profile.read_text())
    inject_entry(profile, 'void AiLuaMessage(const string& in data)', 'if (CommanderRadarProbe::Handle(data)) return;')
    inject_entry(source/'roles/front/front.as', 'void Front_EconomyUpdate()', 'if (ai.teamId >= 0) return;')
    inject_entry(source/'systems/construction/commander_front.as', 'void Update()',
                 'if (ai.teamId >= 0) { aiBuilderMgr.SetCommanderCombatOption("front_duty",0); return; }')
    inject_entry(source/'manager/builder.as', 'IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
                 'if (ai.teamId >= 0) return CommanderRadarProbe::Task(u);')
    inject_entry(source/'manager/factory.as', 'IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
                 'if (ai.teamId >= 0) return aiFactoryMgr.Enqueue(TaskS::Wait(false, SECOND));')
    inject_entry(source/'systems/diagnostics/invariants.as', 'void Tick()', 'if (ai.frame >= 0) return;')
    widget = directory/'LuaUI/Widgets/commander_radar_watch.lua'
    widget.write_text(widget.read_text().replace('__SIDE__',args.side))
    checks = directory/'commander-radar-checks.json'
    pattern = r'\[CommanderRadarTest\] PASS physical_one_radar'
    labels = ('near','inner79','boundary80','outer81','outside','allied','advanced','destroyed')
    checks.write_text(json.dumps({'stop_minute':3,
        'complete_on':{'key':'complete','pattern':pattern,'scope':'any'}, 'completion_grace_seconds':5,
        'expect':[{'key':label,'pattern':r'\[CommanderRadarTest\] PASS '+label+r' ladder_and_queue',
                   'by_minute':2,'scope':'any'} for label in labels]
                 +[{'key':'physical','pattern':pattern,'by_minute':3,'scope':'any'}],
        'forbid':[{'key':'failure','pattern':r'\[CommanderRadarTest\] FAIL|\[INVARIANT\]|: ERR\s+:|\.as \(\d+,\s*\d+\)\s*:\s*WARN\s*:|SCRIPT CRASH|Lib exception|Access violation|has crashed|Fatal:|Error in.*commander_radar','scope':'any'}]},indent=2))
    (directory/'commander-radar-inputs.json').write_text(json.dumps({'side':args.side,'profile':args.profile,
        'overrides':['supplied radar positions, lab and constructor; resource banks',
                     'ordinary construction/economy and commander deployment suspended',
                     'real ladder and queue admission; final radar built by commander',
                     'periodic whole-base invariants suspended; native admissions remain active'],
        'scripts':{str(p.relative_to(source.parent)):storage.file_hash(p) for p in source.parent.rglob('*.as')},
        'widget_sha256':storage.file_hash(widget)},indent=2))
    try:
        subprocess.run(call+['launch','--dir',str(directory),'--engine','recoil_2026.07.04'],check=True)
        return subprocess.call(call+['watch','--dir',str(directory),'--role','FRONT','--minutes','3',
            '--wall-minutes','8','--checks',str(checks)])
    finally:
        subprocess.run(call+['stop','--dir',str(directory)],check=False)


if __name__ == '__main__':
    sys.exit(main())
