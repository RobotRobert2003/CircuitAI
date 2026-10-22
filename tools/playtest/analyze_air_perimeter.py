"""Compare supplied fighter-screen observations; command events are not packets."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re


def rows(path, tag):
    with path.open(encoding='utf-8', errors='replace') as source:
        for line in source:
            if tag not in line:
                continue
            result = dict(re.findall(r'(\w+)=([^\s]+)', line.split(tag, 1)[1]))
            yield {key: float(value) if re.fullmatch(r'-?\d+(?:\.\d+)?', value) else value
                   for key, value in result.items()}


def analyze(directory):
    manifest = json.loads((directory/'arena-manifest.json').read_text())
    fighter = next(group['unit'] for group in manifest['case']['aircraft']
                   if 'fig' in group['unit'] or group['unit'] in ('armhawk', 'corvamp', 'legvenator'))
    path = directory/'infolog.txt'
    probes = [row for row in rows(path, '[AirPerimeterProbe]') if row['team'] == 0]
    orders = Counter()
    for row in rows(path, '[CommandJoint]'):
        if row['team'] == 0 and row['def'] == fighter and row['origin'] == 'nonlua':
            orders[int(row['frame']/1800), int(row['cmd'])] += int(row['orders'])
    return dict(directory=str(directory), fighter=fighter,
                maximum_ground_escort=max((row['ground'] for row in probes), default=0),
                maximum_wall=max((row['wall'] for row in probes), default=0),
                maximum_committed=max((row['committed'] for row in probes), default=0),
                commands=[dict(minute=minute, command=command, events=count)
                          for (minute, command), count in sorted(orders.items())],
                probes=probes)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directories', nargs='+', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = [analyze(path) for path in args.directories]
    if args.output:
        with args.output.open('x', encoding='utf-8') as target:
            json.dump(result, target, indent=2)
    for item in result:
        print(json.dumps({key: value for key, value in item.items() if key != 'probes'}, indent=2))
