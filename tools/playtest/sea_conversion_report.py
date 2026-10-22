"""Summarize read-only SEA economy observations; never infer waste from tidal count.

Run against an isolated run directory containing teams.json and infolog.txt.
--output writes JSON evidence in a caller-selected benchmark location.
"""
import argparse
import json
from pathlib import Path
import re

SAMPLE = re.compile(r'\[SeaConversion\] sample (.*)')
NAVAL_FUSIONS = {'armuwfus', 'coruwfus', 'leganavalfusion'}
ADVANCED_CONVERTERS = {'armuwmmm', 'coruwmmm', 'leganavaleconv'}


def parse_sample(line):
    match = SAMPLE.search(line)
    if not match:
        return None
    fields = dict(piece.split('=', 1) for piece in match[1].split() if '=' in piece)
    result = {}
    for key, value in fields.items():
        if key in ('units', 'frames'):
            result[key] = {name: int(n) for name, n in (part.split(':') for part in value.split(',') if part)}
        elif key in ('team', 'frame'):
            result[key] = int(value)
        else:
            result[key] = float(value)
    return result


def summarize(directory):
    directory = Path(directory)
    teams = {t['team']: t for t in json.loads((directory / 'teams.json').read_text())['teams'] if t['role'] == 'SEA'}
    samples = {team: [] for team in teams}
    violations = set()
    with (directory / 'infolog.txt').open(encoding='utf-8', errors='replace') as stream:
        for line in stream:
            row = parse_sample(line)
            if row and row['team'] in samples:
                samples[row['team']].append(row)
            if '[INVARIANT]' in line:
                violations.add(line.split('[INVARIANT]', 1)[1].strip())
    result = {'directory': str(directory), 'teams': [], 'invariants': sorted(violations)}
    for team, rows in samples.items():
        if not rows:
            continue
        last = rows[-1]
        mature = [s for s in rows if s['frame'] >= 20 * 1800]
        # At a full bank, surplus above non-conversion usage AND installed
        # capacity is unserved. Frame-capacity may still be arriving; retain
        # complete samples so this descriptive metric cannot imply idle work.
        surplus = [max(0, s['ei'] - max(0, s['eu'] - s['converted']) - s['capacity'])
                   if s['es'] > 0 and s['e'] >= s['es'] * .95 else 0 for s in mature]
        first = lambda names: next((s['frame'] / 1800 for s in rows if any(s['units'].get(n, 0) for n in names)), None)
        result['teams'].append({'team': team, 'side': teams[team]['side'], 'last': last,
                               'first_fusion_minute': first(NAVAL_FUSIONS),
                               'first_advanced_converter_minute': first(ADVANCED_CONVERTERS),
                               'late_full_bank_unserved_mean': sum(surplus) / len(surplus) if surplus else None,
                               'late_full_bank_unserved_peak': max(surplus) if surplus else None})
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = summarize(args.directory)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    for team in result['teams']:
        last = team['last']
        print(f"team {team['team']} {team['side']} at {last['frame']/1800:.1f}m: "
              f"M={last['mi']:.1f} E={last['ei']:.0f} capacity={last['capacity']:.0f} "
              f"fusion={team['first_fusion_minute']} advanced={team['first_advanced_converter_minute']} "
              f"unserved={team['late_full_bank_unserved_mean']} units=" +
              ','.join(f'{n}:{v}' for n, v in last['units'].items() if n in NAVAL_FUSIONS | ADVANCED_CONVERTERS))
    print(f"Preserved {len(result['invariants'])} distinct invariant failures.")


if __name__ == '__main__':
    main()
