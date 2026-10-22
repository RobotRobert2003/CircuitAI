"""Metal-map and unchanged TECH sequence controls for the AIR workforce change."""
import argparse
from pathlib import Path
from benchmark_store import RAW_ROOT
import subprocess
import sys
import playtest
import storage
from prepare_metal_check import MAPS


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll', type=Path, required=True)
    p.add_argument('--data', type=Path, default=playtest.REPO/'data')
    p.add_argument('--subset', choices=['all', 'metal', 'tech'], default='all')
    a = p.parse_args()
    call = [sys.executable, str(playtest.HERE/'playtest.py')]
    records = []
    scenarios = [(name, key, 'metal_field', 30) for name, key in zip(MAPS, ['full-metal', 'speed-metal', 'nine-metal'])]
    scenarios += [('Supreme Isthmus v1.7', 'tech-opening', 'tech_opening', 14),
                  ('Supreme Isthmus v1.7', 'tech-rush', 'rush_t2', 16)]
    for name, key, checks, minutes in scenarios:
        metal = name in MAPS
        if a.subset == 'metal' and not metal or a.subset == 'tech' and metal: continue
        base = storage.allocate('shared' if metal else 'tech', 'economy', 'workforce-control', key, 'natural')
        stage = call+['stage', '--dir', str(base), '--dll', str(a.dll), '--data', str(a.data), '--map', name,
            '--game', 'Beyond All Reason test-31479-433a460', '--engine', 'recoil_2026.07.04',
            '--role', 'TECH', '--side', 'armada', '--minutes', str(minutes), '--speed', '30',
            '--shots', '5,15,25', '--lean-render', '--width', '1280', '--height', '720',
            '--ai-option', 'profile=experimental_hard', '--ai-option', 'random_seed=1813001']
        prep = [sys.executable, str(playtest.HERE/'prepare_metal_check.py'), '--map', name, '--output', str(base/'starts.as')]
        if metal:
            subprocess.run(prep, check=True)
            stage += ['--map-file', str(base/'starts.as'), '--roles', 'all', '--ally-spots', '1,2',
                '--extra-widget', str(playtest.HERE/'widgets/metal_watch.lua'),
                '--extra-widget', str(playtest.HERE/'widgets/air_workforce_watch.lua')]
        else:
            stage += ['--roles', 'TECH']
            stage += ['--set', 'RushObjective="t2"' if key == 'tech-rush' else 'RushObjective="eco"']
        subprocess.run(stage, check=True)
        if metal: subprocess.run(prep+['--dir', str(base)], check=True)
        subprocess.run([sys.executable, str(playtest.HERE/'prepare_air_check.py'), '--dir', str(base),
            '--scenario', 'natural', '--seed', '1813001'], check=True)
        subprocess.run([sys.executable, str(playtest.REPO/'tools/knowledge/check_script_api.py'), '--dll', str(a.dll)], check=True)
        subprocess.run(call+['launch', '--dir', str(base), '--engine', 'recoil_2026.07.04'], check=True)
        code = subprocess.call(call+['watch', '--dir', str(base), '--role', 'TECH', '--checks', checks,
            '--minutes', str(minutes), '--wall-minutes', '40', '--keep-going'])
        if metal:
            subprocess.call([sys.executable, str(playtest.HERE/'audit_metal_check.py'), str(base/'infolog.txt'),
                '--metal', '--output', str(base/'metal-audit.json')])
        records.append(dict(directory=str(base), exit=code))
        storage.write_json(RAW_ROOT / 'workforce-regressions.json', records)
    return any(row['exit'] for row in records)


if __name__ == '__main__':
    raise SystemExit(main())
