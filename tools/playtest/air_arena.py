"""Prepare, run and compare replenishing AIR combat arenas; no economic build-up."""
from script_settings import role_settings_path
import argparse
import copy
import hashlib
import json
import math
from pathlib import Path
from benchmark_store import RAW_ROOT
import re
import shutil
import statistics
import subprocess
import sys
import storage

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
DLL = ROOT.parent / 'bar-RecoilEngine/build-amd64-windows/install/AI/Skirmish/BARb/stable/SkirmishAI.dll'
GAME = None  # the last lobby script's archive, resolved by playtest.py; a pinned name goes stale when BAR updates
ENGINE = 'recoil_2026.07.04'
ROSTERS = {
    'armada': {'t1': 'armthund', 't2': 'armpnix', 'fighter1': 'armfig', 'fighter2': 'armhawk', 'gunship': 'armkam', 'torpedo': 'armlance', 'scout': 'armpeep'},
    'cortex': {'t1': 'corshad', 't2': 'corhurc', 'fighter1': 'corveng', 'fighter2': 'corvamp', 'gunship': 'corbw', 'torpedo': 'cortitan', 'scout': 'corfink'},
    'legion': {'t1': 'legmos', 't2': 'legphoenix', 'fighter1': 'legfig', 'fighter2': 'legvenator', 'gunship': 'legmos', 'torpedo': 'legatorpbomber', 'scout': 'legwhisper'},
}


def lua(value):
    if value is None:
        return 'nil'
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if isinstance(value, (float, int)):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value)
    if isinstance(value, list):
        return '{' + ','.join(lua(v) for v in value) + '}'
    return '{' + ','.join('[' + lua(k) + ']=' + lua(v) for k, v in value.items()) + '}'


def resolve_case(path, side, defender, seed, visibility=None):
    case = json.loads(Path(path).read_text())
    for field in ('name', 'aircraft', 'targets', 'defenses'):
        if field not in case:
            raise ValueError('Missing case field: ' + field)
    case = copy.deepcopy(case)
    if type(case.get('factory_production', False)) is not bool:
        raise ValueError('factory_production must be a boolean')
    # Optional fixture lever: literal replacements of Global::RoleSettings::Air
    # values in the staged copy, e.g. {"FirstBomberWaveMax": "10"} to pin the
    # opening draw. Recorded in the manifest overrides; the pinned data is untouched.
    settings = case.get('air_settings', {})
    if type(settings) is not dict or any(not re.fullmatch(r'[A-Za-z_]\w*', k) or not isinstance(v, str)
                                          or not re.fullmatch(r'-?[\w.]+', v) for k, v in settings.items()):
        raise ValueError('air_settings must map setting names to literal value strings')
    case.update(side=side, defender=defender, seed=seed, scout=ROSTERS[side]['scout'])
    case.setdefault('visibility', 'radar')
    if visibility:
        case['visibility'] = visibility
    if case['visibility'] not in ('radar', 'global') or seed <= 0:
        raise ValueError('Invalid visibility or seed')
    refill = case.get('refill_seconds', 45)
    if type(refill) is not int or not 1 <= refill <= 600:
        raise ValueError('refill_seconds must be an integer in 1..600')
    for field in ('aircraft', 'targets', 'defenses', 'sensors'):
        for group in case.get(field, []):
            delay = group.get('after_seconds', 0)
            if type(delay) is not int or not 0 <= delay <= 3600:
                raise ValueError('after_seconds must be an integer in 0..3600')
            if type(group.get('once', False)) is not bool:
                raise ValueError('once must be a boolean')
            name = group['unit']
            team = group.get('team', 0 if field == 'aircraft' else 1)
            if name.startswith('$'):
                owner = defender if team == 1 else side
                group['unit'] = ROSTERS[owner][name[1:]]
            if not re.fullmatch('[a-z][a-z0-9_]*', group['unit']):
                raise ValueError('Invalid UnitDef name')
            if not isinstance(group['count'], int) or not 1 <= group['count'] <= 256:
                raise ValueError('Group count must be 1..256')
            if team not in (0, 1):
                raise ValueError('Groups must belong to team 0 or 1')
            pos = group.get('position')
            if pos is not None and (not isinstance(pos, list) or len(pos) != 2 or
                                    any(type(v) not in (int, float) or not math.isfinite(v) or v < 0 for v in pos)):
                raise ValueError('Positions must contain two finite, nonnegative coordinates')
    return case


def checked_replace(path, old, new):
    source = path.read_text()
    if source.count(old) != 1:
        raise ValueError(f'{path}: expected one hook: {old}')
    path.write_text(source.replace(old, new))


def override_air_setting(path, name, value):
    """Replace the single `<type> <name> = <literal>;` declaration in the staged Air settings."""
    source = path.read_text()
    pattern = re.compile(r'^([ \t]*(?:const[ \t]+)?\w+[ \t]+' + re.escape(name) + r'[ \t]*=[ \t]*)[^;\n]+;', re.M)
    if len(pattern.findall(source)) != 1:
        raise ValueError(f'{path}: expected one declaration of Air setting {name}')
    path.write_text(pattern.sub(lambda m: m.group(1) + value + ';', source, count=1))


def archive_results(base):
    """Bind measurements to the exact immutable log selected by the watcher."""
    report = (base / 'report.md').read_text(encoding='utf-8')
    match = re.search(r'^- Log: (.+)$', report, re.M)
    if not match:
        raise ValueError('Watcher did not publish an archived log')
    log = Path(match[1].strip()).resolve()
    if not log.resolve().is_relative_to((base / 'runs').resolve()) or not log.is_file():
        raise ValueError('Watcher log is outside this arena archive')
    output = log.parent / 'arena-results.json'
    manifest = json.loads((base / 'arena-manifest.json').read_text())
    if manifest['case']['endless']:
        reached = re.search(r'^- Game time reached:.*\(frame (\d+)\)', report, re.M)
        if not reached:
            raise ValueError('Missing endless observation cutoff')
        end_frame = int(reached[1])
    else:
        end_frame = int(manifest['case']['minutes'] * 1800)
    subprocess.run([sys.executable, str(HERE/'audit_air_arena.py'), str(log), '--output', str(output),
                    '--end-frame', str(end_frame)], check=True)
    shutil.copy2(base / 'arena-manifest.json', log.parent / 'arena-manifest.json')
    for suffix in ('.json', '.md'):
        shutil.copy2(output.with_suffix(suffix), base / ('arena-results' + suffix))
    # The root convenience report must still link to the archived screenshots.
    root_report = base/'arena-results.md'
    prefix = output.parent.relative_to(base).as_posix() + '/'
    root_report.write_text(re.sub(r'\]\((screen_[^)]+)\)', lambda m: '](' + prefix + m[1] + ')',
                                  root_report.read_text()))
    return json.loads(output.read_text())


def summarize(base):
    """Compare one final archive per case, never count root and archive copies twice."""
    records = []
    paths = [base/'arena-results.json'] if (base/'arena-results.json').exists() else sorted(base.glob('*/arena-results.json'))
    if not paths:
        raise ValueError('No completed arena reports in ' + str(base))
    rows = ['# AIR arena comparison', '',
            'PASS refers to fixture integrity. Zero attacker fire is reported explicitly; victory and efficiency are separate.', '',
            '| Case / faction | Integrity | Completed / unfinished | Damage / EMP | Attacker lost M | Credited kill M | Median detection to fighter hit |',
            '| --- | --- | --- | --- | --- | --- | --- |']
    for path in paths:
        r = json.loads(path.read_text())
        case = json.loads((path.parent/'arena-manifest.json').read_text())['case']
        report = (path.parent/'report.md').read_text(encoding='utf-8')
        verdict = 'PASS' if '- Verdict: **PASS**' in report and not r['fixture_errors'] else 'FAIL'
        times = [w['detection_to_fighter_hit_seconds'] for w in r['waves'] if w['detection_to_fighter_hit_seconds'] is not None]
        delay = round(statistics.median(times), 2) if times else None
        record = {'case': case['name'], 'side': case['side'], 'seed': case['seed'], 'integrity': verdict,
                  'directory': str(path.parent), 'completed': r['completed_waves'], 'unfinished': r['censored_waves'],
                  'damage': r['attacker_health_damage'], 'paralysis': r['attacker_paralysis'],
                  'lost_metal': r['attacker_metal_lost'], 'kill_value': r['attacker_kill_value'],
                  'median_detection_to_fighter_hit': delay}
        records.append(record)
        link = (Path(r['log']).parent/'arena-results.md').relative_to(base.resolve()).as_posix()
        rows.append(f"| [{case['name']} / {case['side']}]({link}) | {verdict} | {r['completed_waves']} / {r['censored_waves']} | {record['damage']:.0f} / {record['paralysis']:.0f} | {record['lost_metal']:.0f} | {record['kill_value']:.0f} | {delay} |")
    (base/'comparison.json').write_text(json.dumps(records, indent=2)+'\n')
    (base/'comparison.md').write_text('\n'.join(rows)+'\n')
    print('\n'.join(rows), flush=True)
    return records


def prepare(args):
    base = args.dir.resolve()
    if not base.is_relative_to(RAW_ROOT) or base == RAW_ROOT:
        raise ValueError('Use a child of benchmark-repository build-theatres')
    if (base / 'playtest.pid').exists():
        # Refuse to restage a potentially live game. The ordinary stop command
        # removes the pid; an unused stale directory can simply be given a new name.
        raise ValueError('Run playtest.py stop for this directory before restaging')
    case_path = storage.resolve_definition(args.case, 'cases')
    case = resolve_case(case_path, args.side, args.defender, args.seed, args.visibility)
    args.checks = args.checks or case.get('checks', 'air_arena')
    checks_path = storage.resolve_definition(args.checks, 'checks')
    if args.map != case.get('map', 'Supreme Isthmus v1.7') and case_path.is_relative_to(HERE/'cases'):
        raise ValueError('Built-in target coordinates require their declared map; supply a custom JSON case for another map')
    # Explicit directories (including matrix children) need the same discovery
    # metadata as automatically allocated games. Refresh it on intentional reuse.
    compact = lambda text: re.sub(r'[^a-z0-9]+', '-', text.lower()).strip('-')[:24].rstrip('-')
    storage.write_json(base/'run-plan.json', {'schema':1, 'id':base.name,
        'category':{'domain':'air','area':'combat','scenario':compact(case_path.stem),
                    'map':compact(args.map),'kind':'supplied'},
        'requested':{'case':str(case_path),'side':args.side,'profile':args.profile,'seed':args.seed,'map':args.map}})
    if args.unit:
        if not re.fullmatch('[a-z][a-z0-9_]*', args.unit):
            raise ValueError('Invalid aircraft UnitDef name')
        case['aircraft'][0]['unit'] = args.unit
    if args.fighters is not None:
        if not 0 <= args.fighters <= 256:
            raise ValueError('Fighter pool must be 0..256')
        case['aircraft'] = [g for g in case['aircraft'] if g.get('team', 0) != 1 or args.fighters > 0]
        for group in case['aircraft']:
            if group.get('team', 0) == 1:
                group['count'] = args.fighters
    base.mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, str(ROOT/'tools/knowledge/check_script_api.py'), '--dll', str(args.dll),
        '--scripts', str((args.data or ROOT/'data')/'script')], check=True)
    # All standard start sites, not just the two AI home locations, supply sensors.
    import playtest
    spots = playtest.map_spots(args.map, args.map_file)
    half = len(spots) // 2
    if half < 1 or len(spots) % 2:
        raise ValueError('Arena needs paired standard map start regions')
    case['sites'] = [[[x, z] for x, z, _ in spots[:half]], [[x, z] for x, z, _ in spots[half:]]]
    homes = [next((p for p in region if p[2] == 'AIR'), region[0]) for region in (spots[:half], spots[half:])]
    case['homes'] = [[p[0], p[1]] for p in homes]
    starts = base / 'arena-starts.as'
    starts.write_text('\n'.join(f'StartSpot(AIFloat3({x},0,{z}), AiRole::AIR, false),' for x, z, _ in homes))
    cmd = [sys.executable, str(HERE / 'playtest.py'), 'stage', '--dir', str(base), '--dll', str(args.dll),
           '--map', args.map, '--map-file', str(starts), '--engine', args.engine,
           '--role', 'AIR', '--roles', 'all', '--side', args.side, '--ally-spots', '1', '--bonus', '0',
           '--speed', str(args.speed), '--minutes', str(args.minutes), '--shots', '', '--width', '1280', '--height', '720', '--lean-render',
           '--ai-option', 'profile=' + args.profile, '--ai-option', 'random_seed=' + str(args.seed),
           '--modoption', 'deathmode=neverend', '--modoption', 'startenergy=1000000000',
           '--modoption', 'startenergystorage=1000000000', '--modoption', 'multiplier_energyproduction=1000',
           '--extra-widget', str(HERE / 'widgets/air_arena.lua'),
           '--extra-widget', str(HERE / 'widgets/air_command_watch.lua')]
    if args.data:
        cmd += ['--data', str(args.data)]
    if args.game:
        cmd += ['--game', args.game]
    if case.get('factory_production', False):
        cmd += ['--modoption', 'startmetal=1000000', '--modoption', 'startmetalstorage=1000000']
    subprocess.run(cmd, check=True)
    script = base / 'script.txt'
    text = script.read_text()
    text = text.replace('[GAME]\n{', '[GAME]\n{\n FixedRNGSeed=' + str(args.seed) + ';', 1)
    text = re.sub(r'(\[TEAM1\]\s*\{.*?Side=)\w+;', lambda m: m[1] + args.defender + ';', text, count=1, flags=re.S)
    script.write_text(text)
    teams = json.loads((base / 'teams.json').read_text())
    teams['teams'][1]['side'] = args.defender
    (base / 'teams.json').write_text(json.dumps(teams, indent=2))
    staged = base / 'AI/Skirmish/BARbTest/test/script'
    overrides = ['builders and enemy factories frozen; own factories active' if case.get('factory_production', False)
                 else 'builder/factory tasks frozen', 'AIR role on both teams', 'sustainable-income combat gate waived',
                 'defensive fighters remain in home screen', 'supplied energy storage and 1000x passive energy',
                 'stockpile ammunition replenished']
    checked_replace(staged / 'src/setup.as', 'Global::AISettings::Role = derivedRole;',
                    'derivedRole = AiRole::AIR;\n Global::AISettings::Role = derivedRole;')
    for name, manager, wait in [('builder', 'aiBuilderMgr', 'TaskB::Wait(60 * SECOND)'),
                                ('factory', 'aiFactoryMgr', 'TaskS::Wait(false, 60 * SECOND)')]:
        p = staged / 'src/manager' / (name + '.as')
        source = p.read_text()
        at = source.index('{', source.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))
        condition = 'ai.teamId != 0' if name == 'factory' and case.get('factory_production', False) else 'ai.frame >= 0'
        p.write_text(source[:at+1] + '\n if (' + condition + ') return ' + manager + '.Enqueue(' + wait + '); // arena only\n' + source[at+1:])
    if case.get('factory_production', False):
        overrides.append('supplied initial metal/storage: 1000000; normal own factory production policy')
    checked_replace(staged / 'src/systems/air/air_economy.as',
                    'bool MassBombers() {',
                    'bool MassBombers() { if (ai.frame >= 0) return true; // supplied combat arena only')
    # Supplied combat deliberately has no opening crew/turrets or recruitment.
    # Preserve older pinned data, which predates this economy-only admission.
    if 'bool T1OpeningRaidEnabled = true;' in (role_settings_path(staged / 'src', 'Air')).read_text():
        checked_replace(role_settings_path(staged / 'src', 'Air'), 'bool T1OpeningRaidEnabled = true;', 'bool T1OpeningRaidEnabled = false;')
        overrides.append('T1 opening production gate disabled for supplied combat')
    for name, value in case.get('air_settings', {}).items():
        override_air_setting(role_settings_path(staged / 'src', 'Air'), name, value)
        overrides.append(f'Air setting {name} = {value} (case air_settings)')
    if case.get('bomber_only', True):
        checked_replace(role_settings_path(staged / 'src', 'Air'), 'float BomberWaveFighterRatio = 1.0f;', 'float BomberWaveFighterRatio = 0.0f;')
        raid_file = staged / 'src/systems/air/air_raids.as'
        escort_gate = ('AirOperations::AvailableFighters(true)' if 'AirOperations::AvailableFighters(true)' in raid_file.read_text()
                       else 'AirScreen::HomeValue()') + ' < AirEconomy::EnemyAir()'
        checked_replace(raid_file, escort_gate, 'false /* bomber-only arena */')
        overrides.append('T1 home-air and T2 escort launch gates waived')
    for profile in ('experimental_balanced', 'experimental_hard', 'experimental_terrible'):
        path = staged / profile / 'main.as'
        checked_replace(path, 'ArtilleryPolicy::Check();', 'ArtilleryPolicy::Check();\n AirArenaProbe::Tick();')
        with path.open('a') as out:
            out.write('\n' + (HERE / 'air_arena_probe.as').read_text())
    if args.endless:
        camera = base / 'LuaUI/Widgets/playtest_camera.lua'
        text, changes = re.subn(r'end_minute\s*=\s*[\d.]+', 'end_minute = nil', camera.read_text(), count=1)
        if changes != 1:
            raise ValueError('Could not disable fixture autoquit for endless mode')
        camera.write_text(text)
    (base / 'LuaUI/Config').mkdir(parents=True, exist_ok=True)
    if case.get('command_detail', False):
        (base / 'LuaUI/Config/full_match_perf.lua').write_text('return {command_detail=true,unit_command_detail=true}\n')
    if case.get('perimeter_probe', False):
        for profile in ('experimental_balanced', 'experimental_hard', 'experimental_terrible'):
            path=staged/profile/'main.as'
            checked_replace(path,'AirArenaProbe::Tick();','AirArenaProbe::Tick(); AirPerimeterProbe::Tick();')
            with path.open('a') as out:
                out.write('\n'+(HERE/'air_perimeter_probe.as').read_text())
        overrides.append('read-only fighter ownership/route-version probe and detailed command observer')
    case.update(speed=args.speed, minutes=args.minutes, endless=args.endless)
    (base / 'LuaUI/Config').mkdir(parents=True, exist_ok=True)
    (base / 'LuaUI/Config/air_arena.lua').write_text('return ' + lua(case) + '\n')
    git = ['git', '-c', 'safe.directory=' + ROOT.as_posix(), 'rev-parse', 'HEAD']
    manifest = {'case': case, 'game': args.game, 'engine': args.engine, 'map': args.map, 'profile': args.profile,
                'source_commit': subprocess.check_output(git, cwd=ROOT, text=True).strip(),
                'dll_sha256': hashlib.sha256(Path(args.dll).read_bytes()).hexdigest(), 'overrides': overrides,
                'harness_sha256': {str(p.relative_to(HERE)) if p.is_relative_to(HERE) else str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                                   for p in (Path(__file__).resolve(), HERE/'air_arena_probe.as',
                                             HERE/'widgets/air_arena.lua', checks_path)},
                'config_sha256': {str(p.relative_to(staged.parent)): hashlib.sha256(p.read_bytes()).hexdigest()
                                  for p in (staged.parent/'config').rglob('*.json')},
                'staged_script_sha256': {str(p.relative_to(staged)): hashlib.sha256(p.read_bytes()).hexdigest()
                                         for p in staged.rglob('*.as')}}
    (base / 'arena-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('Prepared arena:', base, flush=True)
    return base


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('command', choices=['list', 'prepare', 'run', 'matrix', 'summarize'])
    p.add_argument('--dir', type=Path, help='Existing explicit write directory; otherwise allocate a unique categorized game')
    p.add_argument('--case', default='t2-intercept')
    p.add_argument('--checks', help='Behavior-specific checks; defaults to the case or air_arena')
    p.add_argument('--side', choices=ROSTERS, default='armada')
    p.add_argument('--defender', choices=ROSTERS, default='cortex')
    p.add_argument('--seed', type=int, default=1651)
    p.add_argument('--visibility', choices=['radar', 'global'])
    p.add_argument('--unit', help='Replace the primary attacker with any loaded air UnitDef')
    p.add_argument('--fighters', type=int, help='Override the defensive pool (zero isolates static AA)')
    p.add_argument('--cases', default='t1-economy,t2-intercept,t2-flak,gunship,torpedo,torpedo-covered')
    p.add_argument('--sides', default='armada,cortex,legion')
    p.add_argument('--seeds', default='1651')
    p.add_argument('--dll', type=Path, default=DLL)
    p.add_argument('--data', type=Path, help='Pinned AI data for isolated regression games')
    p.add_argument('--profile', choices=['experimental_balanced', 'experimental_hard', 'experimental_terrible'], default='experimental_hard')
    p.add_argument('--map', default='Supreme Isthmus v1.7')
    p.add_argument('--map-file')
    p.add_argument('--game', default=GAME)
    p.add_argument('--engine', default=ENGINE)
    p.add_argument('--minutes', type=float, default=18)
    p.add_argument('--speed', type=float, default=8)
    p.add_argument('--wall-minutes', type=float, default=20)
    p.add_argument('--endless', action='store_true')
    a = p.parse_args()
    if a.command == 'list':
        for case in storage.definitions('cases'):
            if case.relative_to(HERE/'cases').parts[0] != 'air':
                continue
            print(case.stem, '-', json.loads(case.read_text())['description'])
        return
    if a.command == 'summarize':
        if a.dir is None:
            p.error('summarize requires --dir')
        summarize(a.dir)
        return
    if any(not math.isfinite(v) or v <= 0 for v in (a.minutes, a.speed, a.wall_minutes)):
        p.error('Finite positive minutes, wall-minutes and speed required')
    if a.command == 'matrix':
        if a.endless:
            p.error('Endless mode is one interactive arena, not a bounded matrix')
        if a.dir is None:
            a.dir = storage.allocate('air','combat','matrix','multi-map','supplied')
        results = []
        for case in a.cases.split(','):
            for side in a.sides.split(','):
                for seed in a.seeds.split(','):
                    folder = a.dir / f'{case}-{side}-{seed}'
                    command = [sys.executable, str(Path(__file__).resolve()), 'run', '--dir', str(folder),
                               '--case', case, '--side', side, '--defender', a.defender, '--seed', seed,
                               '--dll', str(a.dll), '--map', a.map, '--engine', a.engine,
                               '--minutes', str(a.minutes), '--speed', str(a.speed), '--wall-minutes', str(a.wall_minutes)]
                    for key in ('visibility', 'map_file', 'unit', 'fighters', 'checks', 'data', 'profile', 'game'):
                        value = getattr(a, key)
                        if value is not None:
                            command += ['--'+key.replace('_','-'), str(value)]
                    code = subprocess.run(command).returncode
                    results.append({'case': case, 'side': side, 'seed': int(seed), 'exit': code, 'directory': str(folder)})
                    a.dir.mkdir(parents=True, exist_ok=True)
                    (a.dir/'matrix-results.json').write_text(json.dumps(results, indent=2)+'\n')
        summarize(a.dir)
        sys.exit(any(r['exit'] for r in results))
    if a.dir is None:
        case_path = storage.resolve_definition(a.case, 'cases')
        map_slug = re.sub(r'[^a-z0-9]+', '-', a.map.lower()).strip('-')[:24].rstrip('-')
        a.dir = storage.allocate('air','combat',case_path.stem,map_slug,'supplied',
                                side=a.side, profile=a.profile, seed=a.seed, map=a.map)
    base = prepare(a)
    if a.command == 'prepare':
        return
    subprocess.run([sys.executable, str(HERE/'playtest.py'), 'launch', '--dir', str(base), '--engine', a.engine], check=True)
    if a.endless:
        print('Continuous arena running. Stop with: python tools/playtest/playtest.py stop --dir', base)
        return
    run = subprocess.run([sys.executable, str(HERE/'playtest.py'), 'watch', '--dir', str(base), '--role', 'AIR',
                          '--checks', a.checks, '--minutes', str(a.minutes), '--wall-minutes', str(a.wall_minutes), '--keep-going'])
    result = archive_results(base)
    sys.exit(run.returncode or bool(result['fixture_errors']))


if __name__ == '__main__':
    main()
