"""Actual-host shared/TECH arbitration of queued land and air ferry gifts."""
import argparse
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
    args = parser.parse_args()
    directory = storage.allocate('shared', 'reliability', 'ferry-ownership', 'supreme', 'supplied')
    print('FERRY_DIRECTORY=' + str(directory), flush=True)
    call = [sys.executable, str(playtest.HERE / 'playtest.py')]
    subprocess.run(call + ['stage', '--dir', str(directory), '--dll', str(args.dll), '--data', str(args.data),
        '--map', 'Supreme Isthmus v1.7', '--role', 'TECH', '--roles', 'TECH', '--side', 'armada',
        '--ai-option', 'profile=experimental_balanced', '--bonus', '0', '--speed', '10', '--minutes', '2',
        '--shots', '1', '--lean-render', '--extra-widget', str(playtest.HERE / 'widgets/ferry_ownership_fixture.lua')], check=True)
    source = directory / 'AI/Skirmish/BARbTest/test/script/src'
    (source / 'ferry_ownership_probe.as').write_bytes((playtest.HERE / 'fixtures/ferry_ownership_probe.as').read_bytes())
    profile = source.parent / 'experimental_balanced/main.as'
    profile.write_text('#include "../src/ferry_ownership_probe.as"\n' + profile.read_text())
    inject_entry(profile, 'void AiLuaMessage(const string& in data)', 'if (FerryOwnershipProbe::Handle(data)) return;')
    subprocess.run(call + ['launch', '--dir', str(directory)], check=True)
    return subprocess.run(call + ['watch', '--dir', str(directory), '--role', 'TECH', '--minutes', '2',
        '--wall-minutes', '8', '--keep-going', '--checks', 'shared/reliability/ferry_ownership']).returncode


if __name__ == '__main__':
    sys.exit(main())
