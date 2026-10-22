"""Reproduce the D-222 trial index without changing any original verdict."""
import argparse
import hashlib
import json
import re
from pathlib import Path
from benchmark_store import RAW_ROOT

from benchmark_store import BENCHMARK_REPO, EVIDENCE_ROOT

ROOT = Path(__file__).resolve().parents[2]


def analyze(archive):
    result = json.loads((archive / 'result.json').read_text())
    log = archive / 'infolog.txt'
    samples, passes, failures, slow = [], [], [], []
    reservations = 0
    global_los = False
    # Stream large logs; retain diagnostic samples rather than the entire log.
    for line in log.open(errors='replace'):
        match = re.search(r'\[SeaWatch\] sample frame=(\d+) (.*)', line)
        if match:
            samples.append({'frame': int(match[1]), 'detail': match[2].strip()})
        if '[SeaCapacity] PASS' in line:
            passes.append(line.strip())
        if re.search(r'\[INVARIANT\]|Error in GameFrame|(?:SeaBase|BaseWatch|BaseProbe)\] FAIL', line):
            failures.append(line.strip())
        reservations += 'RESERVE:' in line
        global_los |= 'global LOS toggled' in line
        if 'SLOW:' in line or 'SLOWCALL' in line:
            slow.append(line.strip())
    with log.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    return {'archive': archive.resolve().relative_to(BENCHMARK_REPO).as_posix(),
            'verdict': result['verdict'], 'reason': result['reason'],
            'map': result['map'], 'category': result.get('category'),
            'log_sha256': digest, 'global_los_enabled': global_los,
            'samples': samples, 'capacity_passes': passes, 'failures': failures,
            'reservation_trace_lines': reservations, 'slow_calls': slow}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=EVIDENCE_ROOT / 'sea-production-capacity.json')
    args = parser.parse_args()
    root = RAW_ROOT / 'games/sea/economy'
    paths = list(root.glob('d222-*/*/*/runs/*/result.json'))
    paths += list(root.glob('capacity-*/*/20261007*/runs/*/result.json'))
    rows = [analyze(p.parent) for p in sorted(paths)]
    output = {'scope': 'D-222 trial evidence. Smoke PASS is not economic acceptance. '
              'Global-LOS games cannot establish normal scouting or fog-buffer behavior. '
              'Natural games diverge and do not establish FPS gains.', 'runs': rows}
    args.output.write_text(json.dumps(output, indent=2) + '\n')
    print('Recorded', len(rows), 'completed observations')


if __name__ == '__main__':
    main()
