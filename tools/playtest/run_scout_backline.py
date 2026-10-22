"""Single-Tick physical raid with an optional exact lost-replan state probe."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

import playtest
import ranged_arena
import ranged_benchmark
import storage


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', type=Path, required=True)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--probe', action='store_true')
    parser.add_argument('--visual', action='store_true')
    args = parser.parse_args()
    arena = argparse.Namespace(case='single-tick-replan' if args.probe else 'single-tick-backline', dll=args.dll, data=args.data,
        variant='ranged', profile='experimental_balanced', game=None, seed=2071,
        minutes=11, speed=20, mode='visual' if args.visual else 'fast', headless=not args.visual)
    directory, call = ranged_arena.prepare(arena)
    checks = json.loads(storage.resolve_definition('single-tick-backline', 'checks').read_text())
    if args.probe:
        source = directory/'AI/Skirmish/BARbTest/test/script'
        fixture = source/'src/scout_replan_probe.as'
        fixture.write_bytes((playtest.HERE/'fixtures/scout_replan_probe.as').read_bytes())
        profile = source/'experimental_balanced/main.as'
        text = profile.read_text()
        entry = text.index('{', text.index('void AiMain()')) + 1
        # Deliberate isolation: both old and new scripts admit the first scout.
        text = text[:entry]+'\n Global::ScoutRaid::KeepNativeScouts = 0;\n'+text[entry:]
        assert text.count('ScoutRaid::Tick();') == 1
        text = text.replace('ScoutRaid::Tick();',
                            'ScoutReplanProbe::Before(); ScoutRaid::Tick(); ScoutReplanProbe::After();')
        profile.write_text('#include "../src/scout_replan_probe.as"\n'+text)
        checks['expect'].append({'key':'live target replan','pattern':r'\[ScoutReplanTest\] PASS live_target_hazard_replanned',
                                 'scope':'any','by_minute':8})
        checks['forbid'].append({'key':'replan failure','pattern':r'\[ScoutReplanTest\] FAIL','scope':'any'})
        (directory/'scout-probe-inputs.json').write_text(json.dumps({
            'overrides':['first scout admitted in both controls',
                         'one observed-target route replaced by a covered waypoint before the real Tick; cooldown remains future'],
            'scripts':{str(p.relative_to(source)):storage.file_hash(p) for p in source.rglob('*.as')}},indent=2))
    check_path = directory/'scout-backline-checks.json'
    check_path.write_text(json.dumps(checks, indent=2))
    playtest.validate_checks(str(check_path))
    result = 1
    try:
        subprocess.run(call+['launch','--dir',str(directory),'--engine','recoil_2026.07.04'],check=True)
        result = subprocess.call(call+['watch','--dir',str(directory),'--role','FRONT',
            '--checks',str(check_path),'--play-decided','--minutes','11','--wall-minutes','8'])
    finally:
        subprocess.run(call+['stop','--dir',str(directory)],check=True)
    summary = ranged_benchmark.summarize(directory)
    (directory/'scout-summary.json').write_text(json.dumps(summary,indent=2))
    print(json.dumps(summary,indent=2))
    return result or (0 if summary['passed'] else 1)


if __name__ == '__main__':
    sys.exit(main())
