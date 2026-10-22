"""Rendered Shore 8v8 regression for the shared reservation index (D-197).

No policy overrides or supplied resources. Full source/observer hashes are
captured by playtest.py; microbenchmarks, not cross-game FPS, establish query cost.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys

import playtest
import storage


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', type=Path, required=True)
    parser.add_argument('--data', type=Path, default=playtest.REPO / 'data')
    parser.add_argument('--minutes', type=int, default=40)
    parser.add_argument('--speed', type=int, default=4)
    parser.add_argument('--speed-plan', default='0:4,3:1,4:4,9:1,10:4,19:1,20:4,29:1,30:4,39:1')
    parser.add_argument('--never-end', action='store_true', help='Soak fixture: disable victory elimination; do not compare as a competitive game.')
    args = parser.parse_args()
    directory = storage.allocate('shared', 'performance', 'reservation-soak' if args.never_end else 'reservation-occupancy',
                                 'shore-to-shore', 'regression', seed=1954001)
    print('RESERVATION_GAME_DIRECTORY=' + str(directory), flush=True)
    starts = []
    for land_x, sea_x in ((550, 2000), (14800, 13250)):
        for z, role in ((730, 'TECH'), (1740, 'AIR'), (2700, 'TACTICAL')):
            starts.append(f'StartSpot(AIFloat3({land_x}, 0, {z}), AiRole::{role}, false),')
        for z in (400, 950, 1500, 2050, 2600):
            starts.append(f'StartSpot(AIFloat3({sea_x}, 0, {z}), AiRole::SEA, false),')
    start_file = directory / 'shore-eight-starts.as'
    start_file.write_text('\n'.join(starts) + '\n')
    call = [sys.executable, str(playtest.HERE / 'playtest.py')]
    command = call + ['stage', '--dir', str(directory), '--dll', str(args.dll),
        '--data', str(args.data), '--map', 'Shore_to_Shore_V3', '--map-file', str(start_file),
        '--game', 'Beyond All Reason test-31479-433a460', '--engine', 'recoil_2026.07.04',
        '--roles', 'all', '--role', 'AIR', '--side', 'armada', '--bonus', '0',
        '--ai-option', 'profile=experimental_hard', '--ai-option', 'random_seed=1954001',
        '--minutes', str(args.minutes), '--speed', str(args.speed),
        '--speed-plan', args.speed_plan,
        '--shots', '3.8@2200@680:2016,19.8@2200@680:2016,29.8@2200@680:2016,39.8@2200@680:2016',
        '--width', '1280', '--height', '720', '--lean-render']
    for name in ('skirmish_perf_watch.lua', 'air_command_watch.lua', 'perf_spectator_cleanup.lua'):
        command += ['--extra-widget', str(playtest.HERE / 'widgets' / name)]
    if args.never_end:
        command += ['--modoption', 'deathmode=neverend']
    subprocess.run(command, check=True)
    (directory / 'reservation-fixture.json').write_text(json.dumps({
        'purpose': 'ordinary economy with exact D195 expanded 8v8 start fixture',
        'profiling': True, 'production_data_unchanged': True,
        'never_end_soak': args.never_end,
        'warning': 'Do not compare FPS after GameOver; retain original invariant failures.'}, indent=2))
    subprocess.run([sys.executable, str(playtest.REPO / 'tools/knowledge/check_script_api.py'),
        '--dll', str(args.dll), '--scripts', str(args.data / 'script')], check=True)
    subprocess.run(call + ['launch', '--dir', str(directory), '--engine', 'recoil_2026.07.04'], check=True)
    return subprocess.run(call + ['watch', '--dir', str(directory), '--role', 'AIR',
        '--checks', 'shared/performance/skirmish_cpu_clean', '--minutes', str(args.minutes),
        '--wall-minutes', '50', '--keep-going']).returncode


if __name__ == '__main__':
    sys.exit(main())
