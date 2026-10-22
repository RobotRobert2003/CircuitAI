"""Summarize immutable ranged fixtures, or run a serial supplied-force matrix.

These measurements describe this fixture, not multiplayer FPS. Keep failed
runs and their pins; never overwrite a prior result with a better trial.
"""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def summarize(directory):
    directory = Path(directory)
    cfg = json.loads((directory / 'ranged-arena.json').read_text())
    text = (directory / 'infolog.txt').read_text(errors='replace')
    units, shooters, deaths, orders, first, damage = {}, set(), [], 0, None, 0
    positions, separations, shots, samples = {}, [], [], []
    forward, firing_samples, last_fire, reasons = [], [], {}, {}
    fps, cloaked, children, friendly_damage = [], set(), {}, 0
    order_frame = last_frame = 0
    spawned, sensor_advance = {}, {}
    detected, first_hit = {}, {}
    unit_commands, friendly_weapons = {}, {}
    starts = cfg.get('starts') or [[0,0],[0,1]]
    dx = starts[1][0] - starts[0][0]
    dz = starts[1][1] - starts[0][1]
    norm = max(1, (dx*dx+dz*dz)**.5)
    for line in text.splitlines():
        if 'COHORT:' in line and 'reason=' in line:
            reason=re.search(r'reason=(\d+)',line)
            if reason: reasons[reason[1]]=reasons.get(reason[1],0)+1
        if '[WorkforcePerf]' in line and 'ai_all_p95_ms=' in line:
            sample = {k: float(v) for k, v in re.findall(r'(\w+)=([\d.]+)', line)}
            if sample.get('frame', 0) <= cfg['minutes']*1800:
                samples.append(sample)
        if '[RangedArena] frame=' not in line:
            continue
        row = dict(re.findall(r'(\w+)=([^ ]+)', line))
        if not row.get('frame', '').isdigit():
            continue  # Shutdown may truncate even the event prefix.
        # A process stop can truncate any final event, not only positions.
        event=re.search(r'\[RangedArena\] frame=\d+ (\w+)',line)
        required={'spawn':('id','unit','team','x','z'), 'detected':('id','unit'), 'unit':('id','unit','x','z','hp','host'),
                  'orders':('team','nonlua','lua'), 'death':('id','team','unit','cost'),
                  'damage':('id','team','amount','attacker','attackerTeam','weapon'),
                  'shot':('id','unit','weapon','target','distance','intent'), 'render':('fps',)}
        if event and not all(k in row for k in required.get(event[1],())): continue
        frame = int(row['frame'])
        last_frame = max(last_frame, frame)
        # Watcher shutdown includes a grace interval. Compare the same game
        # window across runs instead of counting whichever extra frames ran.
        if frame > cfg['minutes']*1800: continue
        if ' spawn ' in line:
            units[int(row['id'])] = (row['unit'], int(row['team']))
            if 'x' in row: spawned[int(row['id'])] = (int(row['x']),int(row['z']))
        if ' detected ' in line:
            detected.setdefault(int(row['id']), frame)
        if ' child ' in line:
            host = int(row.get('host', row.get('parent', -1)))
            children[int(row['id'])] = host
        if ' render fps=' in line and frame >= 1800:
            fps.append(float(row['fps']))
        if ' unit id=' in line and row.get('cloak') == 'true':
            cloaked.add(int(row['id']))
        if ' shot ' in line and row['unit'] in cfg.get('units', [cfg['unit']]):
            shooters.add(int(row['id']))
            shots.append(row)
            last_fire[int(row['id'])]=frame
        if ' damage ' in line and row.get('attackerTeam') == '0':
            attacker = int(row['attacker'])
            attacker = children.get(attacker, attacker)
            if units.get(attacker, ('', -1))[0] in cfg.get('units', [cfg['unit']]):
                damage += max(0, int(row['amount']))
                first = frame if first is None else first
                if row['team'] == '0':
                    value=max(0,int(row['amount']));friendly_damage += value
                    name=row.get('weaponName',row['weapon']);friendly_weapons[name]=friendly_weapons.get(name,0)+value
                elif int(row['amount']) > 0:
                    first_hit.setdefault(int(row['id']), frame)
        if ' death ' in line:
            deaths.append(row)
        if ' orders ' in line and row['team'] == '0':
            orders = int(row['nonlua'])
            order_frame = frame
        if ' unit_command ' in line and 'key' in row and 'count' in row:
            unit_commands[row['key']]=int(row['count'])
        # The watcher can stop the engine while the final log line is being
        # written. Incomplete position rows supply no geometry evidence.
        if ' unit id=' in line and 'x' in row and 'z' in row and row.get('unit') in cfg.get('sensor_units', []):
            origin = spawned.get(int(row['id']))
            if origin:
                advance = ((int(row['x'])-origin[0])*dx+(int(row['z'])-origin[1])*dz)/norm
                sensor_advance[row['unit']] = max(sensor_advance.get(row['unit'],0),advance)
        if ' unit id=' in line and 'x' in row and 'z' in row and row.get('unit') in cfg.get('units', [cfg['unit']]):
            positions.setdefault(frame, []).append((int(row['x']), int(row['z'])))
            uid=int(row['id']); origin=spawned.get(uid)
            if origin:
                forward.append(((int(row['x'])-origin[0])*dx+(int(row['z'])-origin[1])*dz)/norm)
            if 600<=frame<=3600:
                firing_samples.append(frame-last_fire.get(uid,-10000)<=60)
    for frame, points in positions.items():
        if frame < 1800 or len(points) < 2:
            continue
        separations.append(min(((a[0]-b[0])**2+(a[1]-b[1])**2)**.5
                               for i, a in enumerate(points) for b in points[:i]))
    watched = cfg.get('units', [cfg['unit']])
    losses = [d for d in deaths if d['team'] == '0' and d['unit'] in watched]
    unrelated = [d for d in deaths if d['team'] == '0' and d['unit'] not in watched]
    kills = [d for d in deaths if d['team'] == str(cfg.get('enemy_team',1))]
    allied_losses = [d for d in deaths if d['team']=='0' and d['unit'] in cfg.get('support_units',[]) and int(d['frame'])<=30*cfg.get('support_deadline_seconds',cfg['minutes']*60)]
    checks = cfg.get('assertions', {})
    failures = []
    assigned_types = sorted(set(re.findall(r'RANGED: assigned (\w+)\(', text)))
    if len(assigned_types) < checks.get('min_types_assigned',0): failures.append('missing ranged unit admissions')
    if len(kills) < checks.get('min_kills', 1): failures.append('insufficient target kills')
    if len(shooters) < checks.get('min_shooters', 1) and cfg['unit'] != 'legvcarry': failures.append('no verified shots')
    if len(shots) > checks.get('max_shots', float('inf')): failures.append('unexpected shots')
    if len(losses) > checks.get('max_losses', 0): failures.append('ranged casualties')
    if len(allied_losses)>checks.get('max_allied_losses',float('inf')): failures.append('allied screen/support casualties')
    if len(unrelated) < checks.get('min_unrelated_losses', 0): failures.append('unrelated death not exercised')
    if len(cloaked) < checks.get('min_cloaked', 0): failures.append('cloak never observed')
    if friendly_damage > checks.get('max_friendly_damage', float('inf')): failures.append('friendly splash damage')
    first_shot=min((int(s['frame']) for s in shots),default=None)
    if damage<checks.get('min_damage',0): failures.append('insufficient useful engagement damage')
    if 'max_first_shot_seconds' in checks and (first_shot is None or first_shot/30>checks['max_first_shot_seconds']):
        failures.append('first actual shot exceeded deadline')
    # A shot at the first target cannot conceal a later aiming stall. Measure
    # each observable fixture enemy against positive damage by watched hulls,
    # not marker-weapon reloads, allied spam or post-deadline shutdown events.
    response = {str(unit): max(0, first_hit[unit]-frame)/30 if unit in first_hit else None
                for unit, frame in detected.items() if units.get(unit, ('', -1))[1] == 1}
    if 'max_target_response_seconds' in checks:
        limit = checks['max_target_response_seconds']
        if not response or any(delay is None or delay > limit for delay in response.values()):
            failures.append('visible target firing response exceeded deadline')
    for name in cfg.get('sensor_units', []):
        if sensor_advance.get(name,0) < checks.get('min_sensor_advance',0): failures.append('sensor did not advance: '+name)
    archives = sorted((directory/'runs').glob('*/result.json'))
    archived = json.loads(archives[-1].read_text()) if archives else {}
    verdict = archived.get('verdict')
    completed = False
    if archives and verdict == 'PASS' and archived.get('reason') == 'scenario complete with survival grace' and cfg.get('mode') != 'performance':
        checks_path=archives[-1].parent/'checks.json'
        timing_path=archives[-1].parent/'runner-timing.json'
        checks=json.loads(checks_path.read_text()) if checks_path.is_file() else {}
        timing=json.loads(timing_path.read_text()) if timing_path.is_file() else {}
        complete=timing.get('complete_frame')
        completed=bool(checks.get('complete_on') and complete is not None
            and last_frame>=complete+30*float(checks.get('completion_grace_seconds',10)))
    if not completed and last_frame < cfg['minutes']*1800-300: failures.append('incomplete observation window')
    if verdict and verdict != 'PASS': failures.append('original watch verdict: '+verdict)
    if re.search(r'\[INVARIANT\]|\[RangedArena\].*ERROR|Error in.*ranged_arena', text): failures.append('runtime/fixture error')
    result = dict(schema=10, case=cfg['name'], variant=cfg['variant'], seed=cfg['seed'], directory=str(directory),
                  completed_with_survival_grace=completed,
                  measurement_deadline_frame=cfg['minutes']*1800,
                  first_damage_seconds=first/30 if first else None, raw_damage_including_overkill=damage,
                  shooters_fired=len(shooters), shots=len(shots), enemy_kills=len(kills), friendly_losses=len(losses),
                  enemy_metal_destroyed=sum(float(d['cost']) for d in kills),
                  nonlua_commands=orders, commands_per_game_minute=orders/(order_frame/1800) if order_frame else None,
                  command_window_frame=order_frame, last_observed_frame=last_frame, watch_verdict=verdict,
                  sensor_forward_progress=sensor_advance,
                  target_response_seconds=response,
                  assigned_unit_types=assigned_types,
                  minimum_sampled_spacing_after_60s=min(separations) if separations else None,
                  render_fps_after_60s=fps, cloaked_units_observed=len(cloaked),
                  carrier_children_observed=len(children), friendly_damage_including_overkill=friendly_damage,
                  deaths=deaths,
                  allied_losses_during_support=len(allied_losses), unit_commands=unit_commands, friendly_damage_by_weapon=friendly_weapons,
                  first_shot_seconds=first_shot/30 if first_shot is not None else None,
                  firing_sample_fraction_20_to_120=sum(firing_samples)/len(firing_samples) if firing_samples else None,
                  minimum_forward_projection=min(forward) if forward else None,
                  maximum_forward_projection=max(forward) if forward else None,
                  engagement_reason_samples=reasons,
                  engine_ai_windows=samples, failures=failures, passed=not failures)
    # New analysis schema gets a new path. Earlier immutable measurements
    # remain valid evidence rather than being silently recomputed in place.
    output = directory / 'ranged-measurements-v10.json'
    if output.exists() and json.loads(output.read_text()) != result:
        raise RuntimeError('Refusing to overwrite a different measurement: ' + str(output))
    output.write_text(json.dumps(result, indent=2)+'\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--summarize', type=Path)
    parser.add_argument('--cases', nargs='+')
    parser.add_argument('--dll', type=Path)
    parser.add_argument('--data', type=Path, default=ROOT/'data')
    parser.add_argument('--variant', default='ranged', choices=['baseline','siege','ranged'])
    parser.add_argument('--profile', default='experimental_balanced')
    parser.add_argument('--game', default='Beyond All Reason test-31479-433a460')
    parser.add_argument('--minutes', type=int, default=4)
    parser.add_argument('--speed', type=int, default=8)
    parser.add_argument('--seed', type=int, default=2071)
    parser.add_argument('--headless', action='store_true')
    args = parser.parse_args()
    if args.summarize:
        print(json.dumps(summarize(args.summarize), indent=2))
        return 0
    if not args.cases or not args.dll: parser.error('--cases and --dll required')
    failures = 0
    for case in args.cases:
        command = [sys.executable, str(HERE/'ranged_arena.py'), '--case', case, '--dll', str(args.dll),
                   '--data', str(args.data), '--variant', args.variant, '--profile', args.profile,
                   '--minutes', str(args.minutes), '--speed', str(args.speed), '--seed', str(args.seed), '--game', args.game]
        print('BEGIN_CASE='+case, flush=True)
        if args.headless: command += ['--headless']
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        directory = None
        for line in process.stdout:
            print(line, end='', flush=True)
            if line.startswith('RANGED_ARENA='): directory = Path(line.strip().split('=',1)[1])
        code = process.wait()
        if directory and (directory/'infolog.txt').exists():
            result = summarize(directory)
            print('MEASUREMENTS='+json.dumps(result), flush=True)
            failures += bool(code or not result['passed'])
            # Reaching the observation deadline is not proof of production.
            # Keep the original combat/watch result immutable, and require the
            # separate completed-unit/queue analysis for production scenarios.
            cfg = json.loads((directory/'ranged-arena.json').read_text())
            if cfg.get('rush_lifecycle') and args.variant!='baseline':
                analysis = subprocess.run([sys.executable,str(HERE/'rush_report.py'),str(directory)])
                failures += bool(analysis.returncode)
            if cfg.get('production_assertions'):
                analysis = subprocess.run([sys.executable, str(HERE/'land_siege_report.py'), str(directory)])
                failures += bool(analysis.returncode)
            if cfg.get('trace_spam'):
                analysis = subprocess.run([sys.executable, str(HERE/'spam_report.py'), str(directory)])
                failures += bool(analysis.returncode)
            if cfg.get('deployment_assertions'):
                criteria = cfg['deployment_assertions']
                analysis = subprocess.run([sys.executable, str(HERE/'deployment_report.py'), str(directory),
                    '--seconds', str(criteria['seconds']), '--minimum', str(criteria['minimum'])])
                failures += bool(analysis.returncode)
        else: failures += 1
    return bool(failures)


if __name__ == '__main__': sys.exit(main())
