"""Reproducible SUPPORT geothermal / no-geo TECH controls, without resource gifts.

Pins both engine and AI seeds, stages only in the external benchmark store,
and retains original PASS/FAIL reports. Use separate --pin directories for
baseline/candidate comparisons. No writes to the player's installed AI.
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
    parser.add_argument('--pin', type=Path, required=True)
    parser.add_argument('--case', choices=('transition', 'no-front', 'tech-t2', 'tech-nuke'), default='transition')
    parser.add_argument('--side', choices=('armada', 'cortex', 'legion'), default='cortex')
    parser.add_argument('--north', action='store_true')
    parser.add_argument('--full', action='store_true')
    parser.add_argument('--seed', type=int, default=25701)
    parser.add_argument('--profile', default='experimental_balanced')
    parser.add_argument('--minutes', type=int, default=20)
    parser.add_argument('--verify-membership', action='store_true',
                        help='Compare cached membership to the original ordered scans on every read; not for timing')
    args = parser.parse_args()
    tech = args.case.startswith('tech-')
    role = 'TECH' if tech else 'SUPPORT'
    folder = storage.allocate(role.lower(), 'economy', 'local-geothermal', 'supreme', 'regression',
                              seed=args.seed, bonus=0, case=args.case, side=args.side, north=args.north)
    print('SUPPORT_GEO=' + str(folder), flush=True)
    cli = [sys.executable, str(playtest.HERE / 'playtest.py')]
    stage = cli + ['stage', '--dir', str(folder), '--dll', str(args.pin / 'SkirmishAI.dll'),
        '--data', str(args.pin / 'data'), '--map', 'Supreme Isthmus v1.7', '--role', role,
        '--roles', 'all' if args.full else ('TECH' if tech else ('SUPPORT' if args.case == 'no-front' else 'SUPPORT,FRONT')),
        '--side', args.side, '--bonus', '0', '--game', 'Beyond All Reason test-31536-188afa8',
        '--engine', 'recoil_2026.07.04', '--ai-option', 'profile=' + args.profile,
        '--ai-option', 'random_seed=' + str(args.seed), '--modoption', 'deathmode=neverend',
        '--speed', '20', '--minutes', str(args.minutes), '--shots', '8,14,19',
        '--extra-widget', str(playtest.HERE / 'widgets/support_progress.lua')]
    if args.north:
        stage += ['--ally-spots', '9,10,11,12,13,14,15,16']
    if tech:
        stage += ['--set', 'RushObjective="' + args.case.removeprefix('tech-') + '"']
    subprocess.run(stage, check=True)
    script = folder / 'script.txt'
    source = script.read_text()
    source = source.replace('[GAME]\n{', '[GAME]\n{\n FixedRNGSeed=' + str(args.seed) + ';', 1)
    script.write_text(source)
    check = playtest.HERE / ('checks/tech/economy/rush_' + args.case.removeprefix('tech-') + '.json'
                             if tech else 'checks/support/geothermal.json')
    checks = json.loads(check.read_text())
    if args.case == 'no-front':
        for item in checks['expect']:
            if item['key'] == 'constructor-gift':
                item['pattern'] = 'SUPPORT\\]\\[Gift\\] skipped: no unsupplied living FRONT recipient'
    storage.write_json(folder / 'checks.json', checks)
    staged = folder / 'AI/Skirmish/BARbTest/test'
    if args.verify_membership:
        helper = staged / 'script/src/helpers/construction/owned_economy_helpers.as'
        source = helper.read_text()
        source = source.replace('Refresh(); return workers;', 'Refresh(); Verify(workers, 0); return workers;')
        source = source.replace('Refresh(); return extractors;', 'Refresh(); Verify(extractors, 1); return extractors;')
        source = source.replace('Refresh(); return geothermal;', 'Refresh(); Verify(geothermal, 2); return geothermal;')
        source += '''
namespace OwnedEconomy {
    void Verify(array<Id>@ actual, int category) {
        array<Id> expected;
        array<Id>@ owned = ai.GetOwnedUnitIds();
        CCircuitDef@ target = workerTargetName.length() == 0 ? null : ai.GetCircuitDef(workerTargetName);
        for (uint index = 0; index < owned.length(); ++index) {
            CCircuitUnit@ unit = ai.GetTeamUnit(owned[index]);
            if (unit is null || unit.circuitDef is null) continue;
            const CCircuitDef@ definition = unit.circuitDef;
            const string name = definition.GetName();
            const bool wanted = category == 0
                ? target !is null && definition.IsMobile() && definition.CanBuild(target)
                : category == 1 ? definition.GetExtractsMetal() > 0
                : name == "armgeo" || name == "armageo" || name == "corgeo"
                    || name == "corageo" || name == "leggeo" || name == "legageo";
            if (wanted) expected.insertLast(unit.id);
        }
        bool equal = expected.length() == actual.length();
        if (equal) for (uint index = 0; index < expected.length(); ++index)
            if (expected[index] != actual[index]) equal = false;
        if (!equal) GenericHelpers::LogUtil("[INVARIANT] OwnedEconomy membership differs from ordered scan", 1);
    }
}
'''
        helper.write_text(source)
    storage.write_json(folder / 'review-pins.json', dict(stage=stage,
        membership_oracle=args.verify_membership,
        dll_sha256=storage.file_hash(args.pin / 'SkirmishAI.dll'),
        files={str(path.relative_to(staged)): storage.file_hash(path)
               for path in staged.rglob('*') if path.suffix in ('.as', '.json', '.lua')}))
    subprocess.run(cli + ['launch', '--dir', str(folder), '--engine', 'recoil_2026.07.04'], check=True)
    return subprocess.run(cli + ['watch', '--dir', str(folder), '--role', role,
        '--checks', str(folder / 'checks.json'), '--minutes', str(args.minutes),
        '--wall-minutes', '20', '--keep-going']).returncode


if __name__ == '__main__':
    sys.exit(main())
