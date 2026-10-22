"""Measure supplied factory runs; queue starvation is not physical launch time."""
import argparse
import json
import re
from collections import Counter
from pathlib import Path


def analyze(path, first=2700, last=5400):
    parents, products, commands, samples, names = {}, Counter(), Counter(), {}, {}
    with Path(path).open(encoding='utf-8', errors='replace') as stream:
        for line in stream:
            match = re.search(r'\[RangedArena\] frame=(\d+) (.*)', line)
            if not match:
                continue
            frame, text = int(match[1]), match[2]
            if frame > last:
                continue
            fields = dict(re.findall(r'(\w+)=([^ ]+)', text))
            if text.startswith('spawn ') and fields.get('team') == '0':
                names[fields['id']] = fields['unit']
            if text.startswith('child ') and 'parent' in fields:
                parents[fields['id']] = fields['parent']
            if frame < first:
                continue
            if text.startswith('finished ') and fields.get('id') in parents:
                products[parents[fields['id']]] += 1
            if text.startswith('factory_order ') and fields.get('source') == 'false':
                commands[fields['id']] += 1
            if text.startswith('throughput '):
                samples[fields['id']] = {k: int(fields[k]) for k in ('samples', 'empty', 'fundedEmpty', 'building')}
    result = {'first_frame': first, 'last_frame': last, 'factories': {}}
    for identity, counts in sorted(samples.items()):
        result['factories'][identity] = dict(counts, unit=names.get(identity), completed=products[identity], build_commands=commands[identity])
    result['completed'] = sum(v['completed'] for v in result['factories'].values())
    result['build_commands'] = sum(v['build_commands'] for v in result['factories'].values())
    total = sum(v['samples'] for v in samples.values())
    result['funded_empty_fraction'] = sum(v['fundedEmpty'] for v in samples.values()) / total if total else None
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    output = json.dumps(analyze(args.log), indent=2)
    print(output)
    if args.output:
        args.output.write_text(output + '\n', encoding='utf-8')
