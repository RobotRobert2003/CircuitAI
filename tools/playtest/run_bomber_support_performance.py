"""Serial AB/BA bomber-support selector controls, then separate attribution.

Fixed supplied populations isolate the location selector. This is not a full
late-game FPS guarantee: normal bomber support correctness is checked separately.
Only staged copies disable other AIR policy and weapon fire, identically in A/B.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

import playtest
import ranged_arena
from run_commander_regression import run_record
from run_commander_performance import environment
from run_full_match_performance import wrap
from analyze_full_match_performance import analyze, summary
import storage

HERE = Path(__file__).resolve().parent


def prepare(pin, enabled, attribution):
    args = argparse.Namespace(case='bomber-support-population-16', dll=pin/'SkirmishAI.dll',
        data=pin/'data', profile='experimental_balanced', variant='ranged', seed=2071,
        minutes=4, speed=20, mode='performance', headless=True, game=None)
    directory, command = ranged_arena.prepare(args)
    # Resolve the actual staged AI identity rather than depending on casing.
    matches = list(directory.glob('AI/Skirmish/*/*/script/src/roles/air/air.as'))
    if len(matches) != 1:
        raise ValueError('Ambiguous staged AIR policy')
    staged = matches[0].parents[4]
    role = matches[0]
    source = role.read_text()
    marker = 'void Air_MainUpdate() {'
    assert source.count(marker) == 1
    source = source.replace(marker, marker + '\n if (ai.frame>=0) { AirBaseResponse::Tick(); return; } // fixed selector fixture\n')
    role.write_text(source)
    military = staged/'script/src/manager/military.as'
    source = military.read_text()
    marker = 'array<AIFloat3> points={u.GetPos(ai.frame)};'
    assert marker in source
    # The fixture route owns these units; set hold fire in its admission hook.
    source = source.replace('route.SetTraversal(true,48,false); route.SetRoute(points); return route;',
        'route.SetTraversal(true,48,false); route.SetRoute(points); u.SetFireState(0); return route;')
    military.write_text(source)
    settings = staged/'script/src/settings/roles/air.as'
    source = settings.read_text()
    import re
    source, count = re.subn(r'(bool BomberSupportEnabled\s*=\s*)(true|false)',
        lambda m: m[1] + ('true' if enabled else 'false'), source)
    assert count == 1
    settings.write_text(source)
    if attribution:
        wrap(staged/'script/src/systems/air/air_base_response.as', 'Tick', 'void', '', '', 'bomber_support_tick')
        wrap(staged/'script/src/systems/air/air_operations.as', 'InitHeavyRoster', 'void', '', '', 'air_heavy_roster')
        wrap(staged/'script/src/helpers/spatial/air_home.as', 'Refresh', 'void', '', '', 'air_home_refresh')
    # Read-only fixture proof; all sixteen AIs must actually see contacts.
    response = staged/'script/src/systems/air/air_base_response.as'
    source = response.read_text().replace("namespace AirBaseResponse {", "namespace AirBaseResponse { int fixtureNextProof=0;")
    if attribution:
        candidate = '''(inBase || aiBattle.InAirSpotterSight(p))
                && aiBattle.AirThreatAlong(Global::Map::StartPos, p, Global::RoleSettings::Air::StrikeCorridorPadding)
                    <= Global::RoleSettings::Air::BomberSupportMaxThreat'''
        assert source.count(candidate) == 1
        source = source.replace(candidate, 'FixtureSupportCandidate(p,inBase)')
        source = source.replace('namespace AirBaseResponse {', '''namespace AirBaseResponse {
    bool FixtureSupportCandidate(const AIFloat3 &in p, bool inBase) {
        if (AiPerfEnabled) AiPerfBeginLabel("bomber_support_candidate");
        const bool result = ''' + candidate + ''';
        if (AiPerfEnabled) AiPerfEndLabel();
        return result;
    }
''', 1)
    marker = 'const bool previous = contact;'
    assert source.count(marker) == 1
    source = source.replace(marker, 'if (ai.frame>=fixtureNextProof) { fixtureNextProof=ai.frame+30*SECOND; AiLog("[BomberPerf] team="+ai.teamId+" contacts="+contacts+" target="+selected[1]); }\n        '+marker)
    response.write_text(source)
    pins = json.loads((directory/'ranged-arena-pins.json').read_text())
    pins['bomber_performance'] = {'enabled':enabled, 'attribution':attribution,
        'overrides':['AIR main update runs base response only', 'fixture routes hold fire', 'no supplied bombers; selector cost only'],
        'staged_files':{str(p.relative_to(staged)):storage.file_hash(p) for p in staged.rglob('*') if p.suffix in ('.as','.json')}}
    (directory/'ranged-arena-pins.json').write_text(json.dumps(pins,indent=2)+'\n')
    return directory, command


def run_one(args):
    directory, command = prepare(args.pin, args.enabled, args.attribution)
    checks = json.loads(storage.resolve_definition('bomber-support-population-16','checks').read_text())
    for team in range(16):
        checks['expect'].append({'key':f'team {team} selector input',
            'pattern':r'\[BomberPerf\] team='+str(team)+r' contacts=[1-9]\d* target='+
                (r'\d+' if args.enabled else r'-?\d+'), 'scope':'any','by_minute':2})
    check_path = directory/'performance-checks.json'
    check_path.write_text(json.dumps(checks,indent=2)+'\n')
    playtest.validate_checks(str(check_path))
    env = dict(os.environ)
    if args.attribution:
        env['CIRCUIT_PERF_PHASES'] = '1'
    try:
        subprocess.run(command+['launch','--dir',str(directory),'--engine','recoil_2026.07.04','--headless'],check=True,env=env)
        return subprocess.run(command+['watch','--dir',str(directory),'--role','AIR',
            '--checks',str(check_path),'--play-decided','--minutes','4','--wall-minutes','8'],check=False).returncode
    finally:
        subprocess.run(command+['stop','--dir',str(directory)],check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pin',type=Path,required=True)
    parser.add_argument('--out',type=Path)
    parser.add_argument('--allow-lobby',action='store_true')
    parser.add_argument('--run-one',action='store_true')
    parser.add_argument('--enabled',action='store_true')
    parser.add_argument('--attribution',action='store_true')
    args = parser.parse_args()
    if args.run_one:
        return run_one(args)
    if args.out is None or args.out.exists():
        parser.error('A new --out path is required')
    if any(k.startswith('CIRCUIT_VERIFY_') or k in ('CIRCUIT_PERF_PHASES','CIRCUIT_RANGED_TRACE','CIRCUIT_COMMANDER_TRACE') for k in os.environ):
        parser.error('Unset verification/profiling/trace environment variables')
    args.out.parent.mkdir(parents=True,exist_ok=True)
    record = {'dll_sha256':storage.file_hash(args.pin/'SkirmishAI.dll'), 'results':[],
        'qualification':'Lobby allowed; contended measurements' if args.allow_lobby else 'No competing engines/builds allowed',
        'scope':'Fixed-population selector cost; no full-match FPS claim'}
    for i,(enabled,attribution) in enumerate(((False,False),(True,False),(True,False),(False,False),(True,True)),1):
        prefix = args.out.with_name(args.out.stem+f'-{i:02}')
        environment(prefix.with_suffix('.before.json'),args.allow_lobby)
        command = [sys.executable,__file__,'--pin',str(args.pin),'--run-one']
        if enabled: command.append('--enabled')
        if attribution: command.append('--attribution')
        print(f'[{i}/5] support={enabled} attribution={attribution}',flush=True)
        row = run_record(command,prefix.with_suffix('.log'))
        row.update(enabled=enabled,attribution=attribution)
        if row['report']:
            directory = Path(row['report']).parents[2]
            telemetry = analyze(directory)
            prefix.with_suffix('.telemetry.json').write_text(json.dumps(telemetry,indent=2)+'\n')
            row['summary'] = summary(telemetry)
            if not row['pass']:
                # Preserve stack frames and launcher context before raw pruning.
                prefix.with_suffix('.failure.md').write_text(
                    '```text\n'+(directory/'infolog.txt').read_text(errors='replace')+'\n```\n')
            subprocess.run([sys.executable,str(HERE/'prune_benchmarks.py'),'--apply','--path',str(directory)],check=True,stdout=subprocess.DEVNULL)
        environment(prefix.with_suffix('.after.json'),args.allow_lobby)
        record['results'].append(row)
        record['complete'] = i == 5
        args.out.write_text(json.dumps(record,indent=2)+'\n')
        print(f"result={row['pass']} report={row['report']}",flush=True)
        if not row['pass']: return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
