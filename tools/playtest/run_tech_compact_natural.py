"""Unmodified balanced TECH opening on either Coastlines Dry start."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import playtest
import storage


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pin', type=Path, required=True)
    parser.add_argument('--east', action='store_true')
    parser.add_argument('--side', choices=playtest.SIDES)
    parser.add_argument('--position', type=float, nargs=2, metavar=('X', 'Z'))
    parser.add_argument('--bonus', type=int, default=0)
    parser.add_argument('--objective', choices=('auto','nuke','afus'), default='auto')
    parser.add_argument('--visual', action='store_true')
    parser.add_argument('--keep-going', action='store_true', help='Bounded diagnosis after retaining a strict failure; never clears invariant failures')
    args = parser.parse_args()
    side = args.side or ('armada' if args.east else 'cortex')
    directory = storage.allocate('tech', 'layout', 'compact-natural-'+side, 'coastlines', 'regression', seed=3071)
    print('NATURAL_DIRECTORY='+str(directory), flush=True)
    map_file = playtest.REPO/'data/script/src/maps/coastlines_dry.as'
    if args.position:
        text = map_file.read_text()
        spot = 12 if args.east else 4
        text, replacements = re.subn(r'StartSpot\(AIFloat3\([^\n]+(?= // P'+str(spot)+r'\s)',
            f'StartSpot(AIFloat3({args.position[0]}, 0, {args.position[1]}), AiRole::TECH, false),', text)
        if replacements != 1: raise ValueError('Expected one selected TECH start')
        map_file = directory/'start-map.as'
        map_file.write_text(text)
    (directory/'natural-inputs.json').write_text(json.dumps(dict(side=side, east=args.east,
        position=args.position, bonus=args.bonus, visual=args.visual, objective=args.objective,
        policy='pinned scripts; optional opening setting only'),indent=2))
    call = [sys.executable, str(playtest.HERE/'playtest.py')]
    run = ['run', '--dir', str(directory), '--dll', str(args.pin/'SkirmishAI.dll'), '--data', str(args.pin/'data'),
        '--map', 'Coastlines_Dry_V2.2.1', '--map-file', str(map_file),
        '--engine', 'recoil_2026.07.04', '--role', 'TECH', '--roles', 'TECH', '--side', side,
        '--ai-option', 'profile=experimental_balanced', '--ai-option', 'random_seed=3071', '--bonus', str(args.bonus),
        '--mode', 'visual' if args.visual else 'fast', '--speed', '20', '--minutes', '12', '--wall-minutes', '8',
        '--checks', 'tech/layout/compact-natural']
    if not args.visual: run += ['--headless']
    else: run += ['--shots', '5,10']
    if args.objective != 'auto': run += ['--set', f'RushObjective="{args.objective}"']
    if args.east: run += ['--ally-spots', '9,10,11,12,13,14,15,16']
    if args.keep_going: run += ['--keep-going']
    try:
        return subprocess.call(call+run)
    finally:
        subprocess.run(call+['stop', '--dir', str(directory)], check=False)


if __name__ == '__main__': sys.exit(main())
