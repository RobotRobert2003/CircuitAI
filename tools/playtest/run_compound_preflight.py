"""Compare read-only compound placement with real reserve/rollback in a test game."""
import argparse
import os
from pathlib import Path
import subprocess
import sys

import playtest
import storage


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pin', type=Path, required=True)
    parser.add_argument('--profile', default='experimental_balanced')
    parser.add_argument('--map', choices=('Supreme Isthmus v1.7', 'Glacial Gap v1.1'), default='Supreme Isthmus v1.7')
    args = parser.parse_args()
    map_key = 'glacial' if args.map == 'Glacial Gap v1.1' else 'supreme'
    directory = storage.allocate('shared', 'reliability', 'compound-preflight', map_key, 'regression')
    print('COMPOUND_PREFLIGHT=' + str(directory), flush=True)
    cli = [sys.executable, str(playtest.HERE / 'playtest.py')]
    subprocess.run(cli + ['stage', '--dir', str(directory), '--dll', str(args.pin / 'SkirmishAI.dll'),
        '--data', str(args.pin / 'data'), '--map', args.map, '--roles', 'TECH',
        '--role', 'TECH', '--side', 'cortex', '--bonus', '0', '--game', 'Beyond All Reason test-31536-188afa8',
        '--engine', 'recoil_2026.07.04', '--ai-option', 'profile=' + args.profile,
        '--ai-option', 'random_seed=26001', '--modoption', 'deathmode=neverend',
        '--speed', '10', '--minutes', '2', '--shots', '1', '--lean-render'], check=True)
    staged = directory / 'AI/Skirmish/BARbTest/test'
    probe = playtest.HERE / 'fixtures/compound_preflight_probe.as'
    target = staged / 'script' / args.profile / 'main.as'
    source = target.read_text()
    opening = source.index('{', source.index('void AiUpdate()'))
    target.write_text(probe.read_text() + '\n' + source[:opening+1]
                      + '\n CompoundPreflightProbe::Tick();\n' + source[opening+1:])
    checks = {'stop_minute': 2, 'expect': [{'key': 'oracle', 'pattern': r'\[CompoundProbe\] PASS',
               'scope': 'any', 'by_minute': 2}], 'forbid': [
               {'key': 'script', 'pattern': r': ERR\s+:|SCRIPT CRASH|Lib exception', 'scope': 'any'},
               {'key': 'invariant', 'pattern': r'\[INVARIANT\]|\[CompoundProbe\] FAIL', 'scope': 'any'}]}
    storage.write_json(directory / 'checks.json', checks)
    storage.write_json(directory / 'preflight-pins.json', {
        'dll_sha256': storage.file_hash(args.pin / 'SkirmishAI.dll'),
        'profile': args.profile, 'fixture_sha256': storage.file_hash(probe),
        'overrides': ['read-only prediction followed by reserve/rollback mutation oracle'],
        'timing_valid': False})
    environment = dict(os.environ, CIRCUIT_VERIFY_EMPTY_PACK='1', CIRCUIT_VERIFY_SEA_STATIC_INDEX='1')
    subprocess.run(cli + ['launch', '--dir', str(directory), '--engine', 'recoil_2026.07.04'],
                   check=True, env=environment)
    return subprocess.run(cli + ['watch', '--dir', str(directory), '--checks', str(directory / 'checks.json'),
        '--role', 'TECH', '--minutes', '2', '--wall-minutes', '10', '--keep-going'], env=environment).returncode


if __name__ == '__main__':
    sys.exit(main())
