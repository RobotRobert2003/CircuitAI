"""Actual-host factory retirement: repeat queues for all three factions.

The isolated profile disables normal building/combat production. It retains
native recruitment, script Lifecycle::Retire and the real engine command queues.
This is a supplied-resource mechanism test, not an economy benchmark.
"""
import argparse
from pathlib import Path
import subprocess
import sys

import playtest
import storage


def inject_entry(path, signature, statement):
    text = path.read_text()
    at = text.index('{', text.index(signature))
    path.write_text(text[:at + 1] + '\n' + statement + '\n' + text[at + 1:])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', type=Path, required=True)
    parser.add_argument('--data', type=Path, required=True)
    args = parser.parse_args()
    directory = storage.allocate('shared', 'reliability', 'factory-retirement', 'supreme', 'supplied')
    print('RETIREMENT_DIRECTORY=' + str(directory), flush=True)
    call = [sys.executable, str(playtest.HERE / 'playtest.py')]
    subprocess.run(call + ['stage', '--dir', str(directory), '--dll', str(args.dll), '--data', str(args.data),
        '--map', 'Supreme Isthmus v1.7', '--role', 'TECH', '--roles', 'TECH', '--side', 'armada',
        '--ai-option', 'profile=experimental_balanced', '--bonus', '0', '--speed', '10', '--minutes', '3',
        '--shots', '1,2', '--lean-render', '--modoption', 'deathmode=neverend',
        '--modoption', 'startmetal=100000', '--modoption', 'startmetalstorage=100000',
        '--modoption', 'startenergy=1000000', '--modoption', 'startenergystorage=1000000',
        '--extra-widget', str(playtest.HERE / 'widgets/retirement_fixture.lua')], check=True)
    source = directory / 'AI/Skirmish/BARbTest/test/script/src'
    (source / 'retirement_probe.as').write_bytes((playtest.HERE / 'fixtures/retirement_probe.as').read_bytes())
    profile = source.parent / 'experimental_balanced/main.as'
    profile.write_text('#include "../src/retirement_probe.as"\n' + profile.read_text())
    inject_entry(profile, 'void AiLuaMessage(const string& in data)', 'if (RetirementProbe::Handle(data)) return;')
    inject_entry(source / 'manager/factory.as', 'IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
                 'if (ai.teamId >= 0) return RetirementProbe::MakeTask(u);')
    inject_entry(source / 'manager/builder.as', 'IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
                 'if (ai.teamId >= 0) return aiBuilderMgr.Enqueue(TaskB::Wait(SECOND));')
    subprocess.run(call + ['launch', '--dir', str(directory)], check=True)
    return subprocess.run(call + ['watch', '--dir', str(directory), '--role', 'TECH', '--minutes', '3',
        '--wall-minutes', '8', '--keep-going', '--checks', 'shared/reliability/factory_retirement']).returncode


if __name__ == '__main__':
    sys.exit(main())
