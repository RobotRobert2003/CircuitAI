"""Supplied SUPPORT factory regression: real recruitment, finite assist power.

Preserves native queues and SUPPORT FactoryTask. Supplies economy and marks the
opening prerequisites complete, so this is not a natural T2 timing benchmark.
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
    parser.add_argument('--side', choices=('armada', 'cortex', 'legion'), default='legion')
    parser.add_argument('--profile', default='experimental_balanced')
    parser.add_argument('--expected-assistants', type=int, default=2,
                        help='Use zero for profiles that defer this unit beyond the five-minute fixture')
    args = parser.parse_args()
    directory = storage.allocate('support', 'economy', 'mobile-assistance-'+args.side, 'supreme', 'supplied')
    print('SUPPORT_ASSIST_DIRECTORY='+str(directory), flush=True)
    call = [sys.executable, str(playtest.HERE/'playtest.py')]
    subprocess.run(call+['stage', '--dir', str(directory), '--dll', str(args.dll),
        '--map', 'Supreme Isthmus v1.7', '--role', 'SUPPORT', '--roles', 'SUPPORT', '--side', args.side,
        '--ai-option', 'profile='+args.profile, '--bonus', '0', '--speed', '10', '--minutes', '5.1',
        '--shots', '', '--lean-render', '--modoption', 'deathmode=neverend',
        '--modoption', 'startmetal=100000', '--modoption', 'startmetalstorage=100000',
        '--modoption', 'startenergy=1000000', '--modoption', 'startenergystorage=1000000',
        '--extra-widget', str(playtest.HERE/'widgets/support_assist_fixture.lua')], check=True)
    source = directory/'AI/Skirmish/BARbTest/test/script/src'
    (source/'support_assist_probe.as').write_bytes((playtest.HERE/'fixtures/support_assist_probe.as').read_bytes())
    profile = source.parent/args.profile/'main.as'
    profile.write_text('#include "../src/support_assist_probe.as"\n'+profile.read_text(encoding='utf8'), encoding='utf8')
    inject_entry(profile, 'void AiLuaMessage(const string& in data)', 'if (SupportAssistProbe::Handle(data)) return;')
    inject_entry(source/'roles/support/support.as', 'void Support_EconomyUpdate()',
                 'if (ai.teamId >= 0) { SupportAssistProbe::Tick(); return; }')
    inject_entry(source/'manager/builder.as', 'IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
                 'if (u.circuitDef.IsMobile()) return aiBuilderMgr.Enqueue(TaskB::Wait(SECOND));')
    widget = directory/'LuaUI/Widgets/support_assist_fixture.lua'
    widget.write_text(widget.read_text(encoding='utf8').replace('__SIDE__', args.side)
                      .replace('__EXPECTED_ASSISTANTS__', str(args.expected_assistants)), encoding='utf8')
    checks = directory/'checks.json'
    checks.write_text(json.dumps({'stop_minute':5.1, 'expect':[
        {'key':key,'pattern':r'\[SupportAssistTest\] PASS '+key,'by_minute':5.1,'scope':'any'}
        for key in ('caps_roster_and_map_limit','physical_production')],
        'forbid':[{'key':'failure','pattern':r'\[INVARIANT\]|\[SupportAssistTest\] FAIL|: ERR\s+:|SCRIPT CRASH|Lib exception','scope':'any'}]}, indent=2))
    subprocess.run(call+['launch','--dir',str(directory)],check=True)
    return subprocess.run(call+['watch','--dir',str(directory),'--role','SUPPORT','--minutes','5.1',
        '--wall-minutes','10','--keep-going','--checks',str(checks)]).returncode


if __name__ == '__main__':
    sys.exit(main())
