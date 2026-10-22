"""Rendered fixed unit-route workload; run old/new serially for component timing.

--oracle deliberately adds reference computations: never use it for cost claims.
Only staged data is modified. Ten bounded samples include three 60-second
refresh boundaries and a supplied obstacle's creation/destruction.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import playtest
import storage
from run_retirement_regression import inject_entry


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', type=Path, required=True)
    parser.add_argument('--oracle', action='store_true')
    args = parser.parse_args()
    directory = storage.allocate('shared', 'performance', 'unit-terrain-routes', 'supreme', 'supplied')
    print('ROUTE_DIRECTORY=' + str(directory), flush=True)
    call = [sys.executable, str(playtest.HERE / 'playtest.py')]
    subprocess.run(call + ['stage', '--dir', str(directory), '--dll', str(args.dll),
        '--map', 'Supreme Isthmus v1.7', '--role', 'TECH', '--roles', 'TECH', '--side', 'armada',
        '--ai-option', 'profile=experimental_balanced', '--bonus', '0', '--speed', '3', '--minutes', '3.6',
        '--shots', '0.6@4500@2400:10400,1.6@4500@2400:10400', '--lean-render',
        '--modoption', 'deathmode=neverend', '--extra-widget', str(playtest.HERE / 'widgets/unit_route_fixture.lua')], check=True)
    source = directory / 'AI/Skirmish/BARbTest/test/script/src'
    (source / 'unit_route_probe.as').write_bytes((playtest.HERE / 'fixtures/unit_route_probe.as').read_bytes())
    profile = source.parent / 'experimental_balanced/main.as'
    profile.write_text('#include "../src/unit_route_probe.as"\n' + profile.read_text())
    inject_entry(profile, 'void AiLuaMessage(const string& in data)', 'if (UnitRouteProbe::Handle(data)) return;')
    inject_entry(source / 'manager/builder.as', 'IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
                 'if (ai.teamId >= 0) return aiBuilderMgr.Enqueue(TaskB::Wait(SECOND));')
    inject_entry(source / 'manager/factory.as', 'IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
                 'if (ai.teamId >= 0) return aiFactoryMgr.Enqueue(TaskS::Wait(false, SECOND));')
    checks = directory / 'route-checks.json'
    checks.write_text(json.dumps({'stop_minute': 3.6, 'expect': [
        {'key': 'queries', 'pattern': r'\[UnitRouteTest\] PASS', 'by_minute': 3.6, 'scope': 'any'}],
        'forbid': [{'key': 'errors', 'pattern': r'\[INVARIANT\]|: ERR\s+:|SCRIPT CRASH|Lib exception', 'scope': 'any'}]}, indent=2))
    environment = {**os.environ, 'CIRCUIT_PERF_PHASES': '1'}
    environment.pop('CIRCUIT_VERIFY_UNIT_ROUTES', None)
    if args.oracle:
        environment['CIRCUIT_VERIFY_UNIT_ROUTES'] = '1'
    subprocess.run(call + ['launch', '--dir', str(directory)], check=True, env=environment)
    result = subprocess.run(call + ['watch', '--dir', str(directory), '--role', 'TECH', '--minutes', '3.6',
        '--wall-minutes', '6', '--keep-going', '--checks', str(checks)])
    routes, costs = [], []
    with (directory / 'infolog.txt').open(errors='replace') as log:
        for line in log:
            if '[UnitRouteTest] sample=' in line:
                routes.append(line.split('[UnitRouteTest] ', 1)[1].strip())
            if '[PerfLabel]' in line and 'label=route-fixture-' in line:
                costs.append(line.split('[PerfLabel] ', 1)[1].strip())
    # Platypus uses an unsupported movement class: its empty result is also a
    # contract to preserve. Beaver exercises the supported amphibious caller.
    complete = len(routes) == 40 and all(('count=0 ' in line) == ('def=armamph ' in line) for line in routes)
    (directory / 'unit-route-result.json').write_text(json.dumps(
        dict(oracle=args.oracle, complete=complete, routes=routes, costs=costs, watch_exit=result.returncode), indent=2))
    print('ROUTE_RESULT=' + str(directory / 'unit-route-result.json'), flush=True)
    return 0 if complete and result.returncode == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
