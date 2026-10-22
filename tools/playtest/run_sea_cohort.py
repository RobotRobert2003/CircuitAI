"""Paired, immutable SEA layout smoke benchmarks; not a win-rate experiment."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import analyze_sea
import playtest
import storage


def run(job):
    folder, variant, map_name, args = job
    dll=args.baseline_dll if variant=='baseline' and args.baseline_dll else args.dll
    command = [sys.executable, str(playtest.HERE/'run_sea.py'), '--dll', str(dll),
               '--data', str(folder/variant), '--scenario', 'cohort-'+variant,
               '--map', map_name, '--minutes', str(args.minutes), '--seed', str(args.seed)]
    if variant == 'baseline' and not args.baseline_migrated:
        command += ['--legacy']
    output = folder/(variant+'-'+map_name+'.txt')
    with output.open('w') as stream:
        result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT)
    text = output.read_text(errors='replace')
    paths = [line.split('=', 1)[1] for line in text.splitlines() if line.startswith('SEA_DIRECTORY=')]
    record = {'variant': variant, 'map': map_name, 'returncode': result.returncode, 'output': str(output)}
    if paths:
        game = Path(paths[0]); record['directory'] = str(game)
        archives = sorted((game/'runs').glob('*'))
        if archives:
            score = analyze_sea.analyze(archives[-1]/'infolog.txt')
            storage.write_json(archives[-1]/'sea-score.json', score)
            record['archive'] = str(archives[-1])
            record['milestones'] = score['milestones_minutes']
            record['failures'] = score['failures']
    print(json.dumps(record), flush=True)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--baseline-dll', type=Path)
    parser.add_argument('--baseline-migrated', action='store_true',help='Compare the preceding migrated SEA implementation instead of legacy SEA')
    parser.add_argument('--maps', default='supreme,tundra,caldera,erebos')
    parser.add_argument('--minutes', type=float, default=30)
    parser.add_argument('--seed', type=int, default=1881001)
    parser.add_argument('--workers', type=int, choices=(1, 2), default=2)
    args = parser.parse_args()
    folder = storage.allocate('sea', 'economy', 'migration-cohort', 'multi', 'benchmark', seed=args.seed)
    for label, source in [('baseline', args.baseline), ('candidate', playtest.REPO/'data')]:
        shutil.copytree(source, folder/label)
    storage.write_json(folder/'pins.json', {str(p.relative_to(folder)): hashlib.sha256(p.read_bytes()).hexdigest()
        for label in ('baseline', 'candidate') for p in (folder/label).rglob('*') if p.is_file()})
    print('SEA_COHORT='+str(folder), flush=True)
    jobs = [(folder, variant, name, args) for name in args.maps.split(',') for variant in ('baseline', 'candidate')]
    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        records = list(executor.map(run, jobs))
    storage.write_json(folder/'cohort.json', {'seed': args.seed, 'minutes': args.minutes,
        'concurrency': args.workers, 'limitation': 'Concurrent runs cannot measure CPU performance.', 'runs': records})
    return int(any(r['returncode'] or r.get('failures') or 'archive' not in r for r in records))


if __name__ == '__main__':
    sys.exit(main())
