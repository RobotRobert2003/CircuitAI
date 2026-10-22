"""Reproducible TECH heavy-rush games; evidence goes to the benchmark checkout.

--supplied provides resource banks and fusion plants; it is not a timing benchmark.
The normal mode uses zero bonus and no supplied economy. Never edits live data.
"""
import argparse
from pathlib import Path
import re
import subprocess
import sys
import json

import playtest
import storage
from run_retirement_regression import inject_entry


def batch_evidence(log):
    """Require every completion up to the same rolled target, without overshoot."""
    events = [(int(count), int(target)) for count, target in re.findall(
        r'S:0:T:0:.*\[TECH\]\[HeavyRush\] completed (\d+)/(\d+)', log)]
    counts = [count for count, _ in events]
    target = events[0][1] if events else None
    complete = bool(target and all(limit == target for _, limit in events)
                    and len(counts) == target
                    and all(count == index + 1 for index, count in enumerate(counts)))
    return dict(completions=counts, batch_target=target, batch_complete=complete)


def delivery_evidence(log):
    """Count ordered physical events for team 0's products, not allied traffic."""
    finished, loaded, unloaded, delivered = set(), set(), set(), set()
    for line in log.splitlines():
        event = re.search(r'\[HeavyRushTest\] finished team=0 id=(\d+)', line)
        if event:
            finished.add(int(event[1]))
        event = re.search(r'\[HeavyRushTest\] loaded id=(\d+)', line)
        if event and int(event[1]) in finished:
            loaded.add(int(event[1]))
        event = re.search(r'\[HeavyRushTest\] unloaded id=(\d+)', line)
        if event and int(event[1]) in loaded:
            unloaded.add(int(event[1]))
        event = re.search(r'\[HeavyRushTest\] given id=(\d+) from=0 to=(\d+)', line)
        if event and int(event[1]) in unloaded and int(event[2]) != 0:
            delivered.add(int(event[1]))
    return dict(loaded=len(loaded), unloaded=len(unloaded), flown_and_donated=sorted(delivered))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', type=Path, required=True)
    parser.add_argument('--data', type=Path, default=playtest.HERE.parents[1] / 'data')
    parser.add_argument('--side', choices=('armada', 'cortex', 'legion'), default='cortex')
    parser.add_argument('--map', default='Supreme Isthmus v1.7')
    parser.add_argument('--minutes', default='40')
    parser.add_argument('--profile', default='experimental_balanced')
    parser.add_argument('--game', default='Beyond All Reason test-31578-8247b61')
    parser.add_argument('--nuke', action='store_true')
    parser.add_argument('--no-heavy', action='store_true', help='Verify ordinary first-AFUS progression without the heavy overlay')
    parser.add_argument('--require-afus', action='store_true', help='Require physical completion of team 0\'s first AFUS')
    parser.add_argument('--supplied', action='store_true')
    parser.add_argument('--smoke', action='store_true', help='Profile/strategy VM check only; no batch timing claim')
    args = parser.parse_args()
    directory = storage.allocate('tech', 'economy', 'heavy-rush-' + args.side,
                                 args.map, 'supplied' if args.supplied else 'natural')
    print('HEAVY_DIRECTORY=' + str(directory), flush=True)
    command = [sys.executable, str(playtest.HERE / 'playtest.py')]
    options = ['--modoption', 'deathmode=neverend']
    if args.supplied:
        options += ['--modoption', 'startmetal=100000', '--modoption', 'startmetalstorage=100000',
                    '--modoption', 'startenergy=1000000', '--modoption', 'startenergystorage=1000000']
    subprocess.run(command + ['stage', '--dir', str(directory), '--dll', str(args.dll), '--data', str(args.data),
        '--map', args.map, '--game', args.game, '--role', 'TECH', '--roles', 'TECH,FRONT,AIR', '--side', args.side,
        '--ai-option', 'profile=' + args.profile, '--bonus', '0', '--speed', '20', '--minutes', args.minutes,
        '--shots', '0.5@1800@837:10407,1.5@2200@837:10407' if args.smoke else '5,10,15,20,30', '--lean-render', '--extra-widget',
        str(playtest.HERE / 'widgets/heavy_rush_watch.lua')] + options, check=True)
    profile = directory / 'AI/Skirmish/BARbTest/test/script' / args.profile / 'main.as'
    text = profile.read_text()
    for key, value in {'Tech_Spam_Rush': '0.0f', 'Tech_T2_RUSH': '0.0f' if args.no_heavy else '1.0f',
                       'Tech_T3_RUSH': '0.0f', 'Tech_NUKE_RUSH': '1.0f' if args.nuke else '0.0f'}.items():
        text, count = re.subn(r'(float\s+' + key + r'\s*=\s*)[0-9.]+f', r'\g<1>' + value, text)
        if count != 1:
            raise ValueError('Missing unique probability: ' + key)
    profile.write_text(text)
    source = profile.parent.parent / 'src'
    (source / 'heavy_strategy_probe.as').write_bytes((playtest.HERE / 'fixtures/heavy_strategy_probe.as').read_bytes())
    profile.write_text('#include "../src/heavy_strategy_probe.as"\n' + profile.read_text())
    inject_entry(profile, 'void AiMain()', 'HeavyStrategyProbe::Run();')
    if args.supplied:
        widget = directory / 'LuaUI/Widgets/heavy_rush_watch.lua'
        widget.write_text(widget.read_text().replace('local supplied = false', 'local supplied = true'))
    check_name = 'tech/economy/heavy_smoke' if args.smoke else 'tech/economy/heavy_rush'
    if args.no_heavy or args.require_afus:
        checks = json.loads((playtest.HERE / 'checks' / (check_name + '.json')).read_text())
        checks['stop_minute'] = float(args.minutes)
        if args.no_heavy:
            checks['expect'] = [item for item in checks['expect'] if item['key'] != 'heavy batch']
        if args.require_afus:
            checks['expect'].append({'key': 'first AFUS completed', 'pattern': r'\[Playtest\] finished (armafus|corafus|legafus) team 0',
                                     'by_minute': float(args.minutes), 'scope': 'any'})
        check_path = directory / 'heavy-checks.json'
        check_path.write_text(json.dumps(checks, indent=2))
        check_name = str(check_path)
    subprocess.run(command + ['launch', '--dir', str(directory)], check=True)
    result = subprocess.run(command + ['watch', '--dir', str(directory), '--role', 'TECH',
        '--minutes', args.minutes, '--wall-minutes', '20', '--keep-going', '--checks',
        check_name])
    log = (directory / 'infolog.txt').read_text(errors='replace')
    summary = dict(directory=str(directory), supplied=args.supplied, nuke=args.nuke, heavy=not args.no_heavy, side=args.side,
                   errors=re.findall(r'.*(?:: ERR\s+:|SCRIPT CRASH).*', log),
                   strategy_pass='[HeavyStrategyTest] PASS' in log and '[HeavyStrategyTest] FAIL' not in log,
                   watch_exit=result.returncode)
    summary.update(batch_evidence(log))
    summary.update(delivery_evidence(log))
    (directory / 'heavy-rush-result.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    return 0 if (args.smoke or args.no_heavy or summary['batch_complete']) and summary['strategy_pass'] and not summary['errors'] and result.returncode == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
