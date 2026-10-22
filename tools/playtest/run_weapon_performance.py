"""Same-input old/new weapon work inside the pinned engine, plus profile loading.

The isolated fixture temporarily swaps synthetic cluster observations, restores
them before normal play resumes, and cannot reach a site/order operation.
It does not change production data or claim full-match equivalence.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

import playtest
import storage


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', type=Path, required=True)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--profile', choices=['experimental_hard', 'experimental_balanced', 'experimental_terrible'], required=True)
    args = parser.parse_args()
    d = storage.allocate('shared', 'performance', 'weapon-work-' + args.profile.split('_')[1], 'supreme', 'supplied', seed=1991)
    print('WEAPON_PERFORMANCE_DIRECTORY=' + str(d), flush=True)
    call = [sys.executable, str(playtest.HERE / 'playtest.py')]
    subprocess.run(call + ['stage', '--dir', str(d), '--dll', str(args.dll), '--data', str(args.data),
        '--map', 'Supreme Isthmus v1.7', '--game', 'Beyond All Reason test-31479-433a460', '--engine', 'recoil_2026.07.04',
        '--role', 'TECH', '--roles', 'TECH', '--side', 'armada', '--bonus', '0',
        '--ai-option', 'profile=' + args.profile, '--ai-option', 'random_seed=1991',
        '--minutes', '4', '--speed', '15', '--shots', '1.8,3.8', '--width', '1280', '--height', '720', '--lean-render'], check=True)
    sys.path.insert(0, str(playtest.REPO / 'tools/knowledge'))
    from check_performance_policy import function
    before = (playtest.REPO / 'tests/fixtures/performance/weapon_work_before.as').read_text(encoding='utf-8')
    old = function(before, 'int OutstandingOrders()').replace('OutstandingOrders()', 'FixtureOldOutstandingOrders()')
    old += '\n' + function(before, 'IUnitTask@ Work(').replace('IUnitTask@ Work(', 'IUnitTask@ FixtureOldWork(').replace('OutstandingOrders()', 'FixtureOldOutstandingOrders()')
    scripts = d / 'AI/Skirmish/BARbTest/test/script'
    main_file = scripts / args.profile / 'main.as'
    source = main_file.read_text(encoding='utf-8')
    assert source.count('ArtilleryPolicy::Check();') == 1
    source = source.replace('ArtilleryPolicy::Check();', 'ArtilleryPolicy::Check();\n        WeaponPerformanceProbe::Tick();')
    probe = (playtest.HERE / 'weapon_performance_probe.as').read_text(encoding='utf-8')
    main_file.write_text(source + '\nnamespace TechWeapons {\n' + old + '\n}\n' + probe, encoding='utf-8')
    (d / 'weapon-fixture-source.json').write_text(json.dumps({str(p.relative_to(scripts.parent)): storage.file_hash(p)
        for p in scripts.parent.rglob('*') if p.is_file()}, indent=2) + '\n', encoding='utf-8')
    subprocess.run([sys.executable, str(playtest.REPO / 'tools/knowledge/check_script_api.py'), '--dll', str(args.dll), '--scripts', str(scripts)], check=True)
    subprocess.run(call + ['launch', '--dir', str(d), '--engine', 'recoil_2026.07.04'],
        env={**os.environ, 'CIRCUIT_PERF_PHASES': '1'}, check=True)
    return subprocess.run(call + ['watch', '--dir', str(d), '--role', 'TECH', '--checks', 'shared/performance/weapon_work',
        '--minutes', '4', '--wall-minutes', '12', '--keep-going']).returncode


if __name__ == '__main__':
    sys.exit(main())
