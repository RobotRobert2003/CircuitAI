"""Supplied gantry admission/recovery. Does not measure natural T3 timing."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import playtest
import storage
from run_retirement_regression import inject_entry


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', type=Path, required=True)
    parser.add_argument('--mode', choices=('supported', 'no-t1', 'starved', 'policy', 'recovery', 'integration'), default='supported')
    parser.add_argument('--side', choices=('armada', 'cortex', 'legion'), default='cortex')
    parser.add_argument('--profile', default='experimental_balanced')
    parser.add_argument('--stage-only', action='store_true')
    args = parser.parse_args()
    minutes = 15.1 if args.mode == "integration" else (2.0 if args.mode == "policy" else 7.1)
    scenario_mode = 'integ' if args.mode == 'integration' else args.mode
    directory = storage.allocate('tech', 'layout', 'gantry-'+scenario_mode+'-'+args.side, 'supreme', 'supplied')
    print('GANTRY_DIRECTORY='+str(directory), flush=True)
    call = [sys.executable, str(playtest.HERE/'playtest.py')]
    subprocess.run(call+['stage', '--dir', str(directory), '--dll', str(args.dll),
        '--map', 'Supreme Isthmus v1.7', '--role', 'TECH', '--roles', 'TECH', '--side', args.side,
        '--ai-option', 'profile='+args.profile, '--bonus', '0', '--speed', '10', '--minutes', str(minutes),
        '--shots', '', '--lean-render',
        '--modoption', 'deathmode=neverend', '--modoption', 'startmetal=100000',
        '--modoption', 'startmetalstorage=100000', '--modoption', 'startenergy=1000000',
        '--modoption', 'startenergystorage=1000000', '--extra-widget', str(playtest.HERE/'widgets/gantry_fixture.lua')], check=True)
    source = directory/'AI/Skirmish/BARbTest/test/script/src'
    (source/'gantry_probe.as').write_bytes((playtest.HERE/'fixtures/gantry_probe.as').read_bytes())
    profile = source.parent/args.profile/'main.as'
    profile.write_text('#include "../src/gantry_probe.as"\n'+profile.read_text())
    inject_entry(profile, 'void AiLuaMessage(const string& in data)', 'if (GantryProbe::Handle(data)) return;')
    inject_entry(source/'roles/tech/tech.as', 'void Tech_EconomyUpdate()', 'if (ai.teamId >= 0) { GantryProbe::Tick(); return; }')
    if args.mode != 'integration':
        inject_entry(source/'manager/builder.as', 'IUnitTask@ AiMakeTask(CCircuitUnit@ u)', 'if (ai.teamId >= 0) return GantryProbe::Task(u);')
        inject_entry(source/'manager/factory.as', 'IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
                     'if (ai.teamId >= 0) return aiFactoryMgr.Enqueue(TaskS::Wait(false, SECOND));')
    widget = directory/'LuaUI/Widgets/gantry_fixture.lua'
    widget.write_text(widget.read_text().replace('__MODE__', args.mode).replace('__SIDE__', args.side))
    checks = directory/'gantry-checks.json'
    checks.write_text(json.dumps({'stop_minute':minutes, 'expect':[
        {'key':'physical gantry', 'pattern':r'\[GantryTest\] PASS admission_and_profile_sequence' if args.mode == 'policy' else r'\[GantryTest\] PASS final', 'by_minute':minutes, 'scope':'any'}],
        'forbid':[{'key':'fixture failure','pattern':r'\[INVARIANT\]|\[GantryTest\] FAIL|: ERR\s+:|SCRIPT CRASH|Lib exception', 'scope':'any'}]}, indent=2))
    if args.mode == 'recovery':
        content=json.loads(checks.read_text())
        content['expect'] += [
            {'key':'dropped support order', 'pattern':r'\[GantryTest\] dropped_support_order', 'by_minute':minutes, 'scope':'any'},
            {'key':'late frame adopted', 'pattern':r'\[GantryTest\] PASS late_frame_adopted', 'by_minute':minutes, 'scope':'any'}]
        checks.write_text(json.dumps(content, indent=2))
    if args.mode == 'policy':
        content=json.loads(checks.read_text()); content['stop_minute']=2
        checks.write_text(json.dumps(content, indent=2))
    if args.stage_only:
        return 0
    subprocess.run(call+['launch', '--dir', str(directory)], check=True, env={**os.environ,'CIRCUIT_PERF_PHASES':'1'})
    return subprocess.run(call+['watch', '--dir', str(directory), '--role', 'TECH', '--minutes', str(minutes),
        '--wall-minutes', '10', '--keep-going', '--checks', str(checks)]).returncode


if __name__ == '__main__':
    sys.exit(main())
