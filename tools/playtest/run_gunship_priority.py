"""Supplied AIR defense: light/mobile AA must preempt a heavy incumbent.

Only economy and enemy movement are frozen. AIR selection, wave assembly,
native target dispatch and weapon damage use the production implementation.
"""
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
    parser.add_argument('--data', type=Path, default=playtest.REPO/'data')
    parser.add_argument('--side', choices=('armada', 'cortex', 'legion'), default='armada')
    parser.add_argument('--profile', default='experimental_balanced')
    parser.add_argument('--label', default='candidate')
    args = parser.parse_args()
    directory = storage.allocate('air', 'combat', 'aa-'+args.label+'-'+args.side, 'supreme', 'supplied', seed=283)
    print('GUNSHIP_PRIORITY_DIRECTORY='+str(directory), flush=True)
    call = [sys.executable, str(playtest.HERE/'playtest.py')]
    subprocess.run(call+['stage', '--dir', str(directory), '--dll', str(args.dll), '--data', str(args.data),
        '--map', 'Supreme Isthmus v1.7', '--role', 'AIR', '--roles', 'AIR', '--side', args.side,
        '--ai-option', 'profile='+args.profile, '--ai-option', 'random_seed=283',
        '--bonus', '0', '--speed', '10', '--minutes', '3', '--shots', '', '--lean-render',
        '--modoption', 'deathmode=neverend',
        '--extra-widget', str(playtest.HERE/'widgets/gunship_priority_fixture.lua')], check=True)
    source = directory/'AI/Skirmish/BARbTest/test/script/src'
    inject_entry(source/'manager/builder.as', 'IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
                 'if (ai.frame >= 0) return aiBuilderMgr.Enqueue(TaskB::Wait(60*SECOND));')
    inject_entry(source/'manager/factory.as', 'IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
                 'if (ai.frame >= 0) return aiFactoryMgr.Enqueue(TaskS::Wait(false,60*SECOND));')
    inject_entry(source/'manager/military.as', 'IUnitTask@ AiMakeTask(CCircuitUnit@ u)', '''
        if (ai.teamId != 0) {
            CRouteTask@ task = cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
            array<AIFloat3> position = {u.GetPos(ai.frame)};
            task.SetAirControl(true); task.SetHoldPosition(true); task.SetRoute(position);
            return task;
        }''')
    widget = directory/'LuaUI/Widgets/gunship_priority_fixture.lua'
    widget.write_text(widget.read_text(encoding='utf8').replace('__SIDE__', args.side), encoding='utf8')
    checks = directory/'checks.json'
    checks.write_text(json.dumps({'stop_minute':3, 'expect':[
        {'key':key, 'pattern':r'\[GunshipPriority\] PASS '+key, 'scope':'any', 'by_minute':3}
        for key in ('heavy_incumbent', 'aa_preempts', 'aa_damage', 'aa_destroyed', 'heavy_fallback')],
        'forbid':[{'key':'failure', 'pattern':r'\[INVARIANT\]|\[GunshipPriority\] FAIL|: ERR\s+:|SCRIPT CRASH|Lib exception', 'scope':'any'}]}, indent=2), encoding='utf8')
    (directory/'fixture-manifest.json').write_text(json.dumps({
        'side':args.side, 'profile':args.profile, 'data':str(args.data), 'dll':str(args.dll),
        'fixture':'economy and enemy movement frozen; observed real orders and weapon damage; ordinary LOS'}, indent=2), encoding='utf8')
    subprocess.run(call+['launch', '--dir', str(directory)], check=True)
    return subprocess.run(call+['watch', '--dir', str(directory), '--role', 'AIR', '--minutes', '3',
        '--wall-minutes', '8', '--keep-going', '--checks', str(checks)]).returncode


if __name__ == '__main__':
    sys.exit(main())
