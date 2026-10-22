"""Add immutable coastal observations without changing original acceptance verdicts."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re


def measure(archive):
    archive = Path(archive)
    original = json.loads((archive / 'result.json').read_text())
    if not original.get('complete'):
        raise ValueError('Only completed archived runs can be assessed')
    log = archive / 'infolog.txt'
    completed, first, changes, damage, invariants = Counter(), {}, [], None, []
    orders = Counter()
    # Streaming avoids retaining large 8v8 logs. Counts refer to observed
    # completions, not surviving units or a victory inferred from screenshots.
    with log.open(encoding='utf-8', errors='replace') as stream:
        for line in stream:
            match = re.search(r'CoastFixture\] frame=(\d+) finished (\w+)', line)
            if match:
                frame, name = int(match[1]), match[2]
                completed[name] += 1
                first.setdefault(name, frame)
            match = re.search(r'\[f=0*(\d+)\].*\[SEA\]\[Coast\] fallback=(true|false)', line)
            if match:
                changes.append({'frame': int(match[1]), 'active': match[2] == 'true'})
            match = re.search(r'\[SEA\]\[Coast\] build=(\w+)', line)
            if match:
                orders[match[1]] += 1
            match = re.search(r'CoastFixture\] frame=(\d+) invader damaged by live defense', line)
            if match and damage is None:
                damage = int(match[1])
            if '[INVARIANT]' in line:
                invariants.append(line.strip())
    with log.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    return {
        'schema': 1, 'original_id': original['id'],
        'original_verdict': original['verdict'], 'log_sha256': digest,
        'last_frame': original['last_frame'], 'fallback_transitions': changes,
        'completed': dict(sorted(completed.items())),
        'first_completion_frame': dict(sorted(first.items())),
        'coastal_build_orders': dict(sorted(orders.items())),
        'first_observed_invader_damage_frame': damage,
        'invariants': invariants,
        'limits': 'Fixture completion counts include supplied seed assets; damage is not proof of invasion defeat. '
                  'This supplements and never replaces the original check verdict.'
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    args = parser.parse_args()
    result = measure(args.archive)
    output = args.archive / 'coast-observations-v1.json'
    if output.exists():
        if json.loads(output.read_text()) != result:
            raise ValueError('Conflicting immutable coastal observations')
    else:
        output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(output)


if __name__ == '__main__':
    main()
