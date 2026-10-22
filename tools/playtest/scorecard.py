"""Immutable match evidence, strict comparison cohorts and a private OpenSkill ladder.

python tools/playtest/scorecard.py record <write-dir> --run <archived-run>
python tools/playtest/scorecard.py rebuild
python tools/playtest/scorecard.py compare <card-a.json> <card-b.json>
"""
import argparse
import datetime as dt
import hashlib
import importlib.metadata
import json
import math
import os
import re
import shutil
import sys
import time
import uuid
from pathlib import Path
from benchmark_store import RAW_ROOT

from benchmark_store import EVIDENCE_ROOT, require_checkout

ROOT = Path(__file__).resolve().parents[2]
STORE = EVIDENCE_ROOT / 'scorecards'
SCHEMA = 2
MODEL_VERSION = '6.1.2'


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def file_hash(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    temp.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n', encoding='utf-8')
    os.replace(temp, path)


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def script_options(text):
    # The harness emits one entire modoption per line. Preserve embedded ';'.
    m = re.search(r'\[MODOPTIONS\]\s*\{\s*\n(.*?)^\s*\}', text, re.S | re.M | re.I)
    if not m:
        raise ValueError('Missing MODOPTIONS: cannot establish comparable settings')
    return dict(re.findall(r'^\s*(\w+)=(.*);\s*$', m[1], re.M))


def capture(directory, scenario=None):
    """Call immediately before launch, after all staging/role overrides."""
    directory = Path(directory)
    teams = read_json(directory / 'teams.json')
    script = (directory / 'script.txt').read_text(encoding='utf-8')
    ai = directory / 'AI/Skirmish/BARbTest/test'
    hashes = {str(p.relative_to(ai)).replace('\\', '/'): file_hash(p)
              for p in sorted(ai.rglob('*')) if p.is_file() and p.suffix in ('.as', '.json', '.lua')
              and p.name != 'AIInfo.lua'}
    widgets = {p.name: file_hash(p) for p in sorted((directory / 'LuaUI/Widgets').glob('*.lua'))}
    ai_options = re.findall(r'\[OPTIONS\]\s*\{([^}]+)\}', script, re.I)
    opts = [dict(re.findall(r'(\w+)\s*=\s*([^;]*);', block)) for block in ai_options]
    now = dt.datetime.now(dt.timezone.utc)
    manifest = {
        'schema': SCHEMA, 'run_id': now.strftime('%Y%m%dT%H%M%S.%fZ') + '-' + uuid.uuid4().hex[:8],
        'started_at_utc': now.isoformat(), 'started_at_local': now.astimezone().isoformat(),
        'map': teams['map'], 'game': teams['game'], 'teams': teams['teams'],
        'modoptions': script_options(script), 'ai_options': opts,
        'handicaps': re.findall(r'Handicap=(\d+);', script),
        'scenario': scenario or {}, 'widgets': widgets,
        'dll_sha256': file_hash(ai / 'SkirmishAI.dll'), 'data_sha256': digest(hashes),
        'data_files': hashes, 'start_script_sha256': file_hash(directory / 'script.txt'),
        'execution': read_json(directory / 'playtest_camera.json') if (directory / 'playtest_camera.json').exists() else {},
    }
    config = directory / 'LuaUI/Config/scorecard_run.lua'
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text('return {teams={' + ','.join(str(t['team']) for t in teams['teams']) + '}}\n')
    write_json(directory / 'scorecard-manifest.json', manifest)
    return manifest


def condition(manifest, runtime):
    """No build hash here: changing the AI is the experimental variable."""
    return {
        'schema': SCHEMA, 'map': manifest['map'], 'map_checksum': runtime.get('mapChecksum'),
        'game': manifest['game'], 'game_checksum': runtime.get('gameChecksum'),
        'engine_sha256': manifest.get('engine_sha256'),
        'engine_version': manifest.get('engine_version'),
        'modoptions': manifest['modoptions'],
        'teams': [{k: t[k] for k in ('team', 'ally', 'side', 'role', 'x', 'z')} for t in manifest['teams']],
        'ai_options': manifest['ai_options'], 'handicaps': manifest['handicaps'],
        'scenario': manifest['scenario'], 'widgets': manifest['widgets'],
    }


def compare(a, b):
    left, right = a['condition'], b['condition']
    differences = [k for k in sorted(set(left) | set(right)) if left.get(k) != right.get(k)]
    starts_a, starts_b = a.get('actual_starts', {}), b.get('actual_starts', {})
    if set(starts_a) != set(starts_b) or any(math.dist(starts_a[k], starts_b[k]) > 32 for k in starts_a if k in starts_b):
        differences.append('actual_starts_over_32_elmos')
    return {'strong_candidate': not differences and a['quality']['comparable'] and b['quality']['comparable'],
            'mismatched_dimensions': differences,
            'note': 'Exact conditions; build identity may differ. Never pool mismatched cohorts.'}


def parse_log(path):
    result = {'events': [], 'roles': {}, 'starts': {}, 'invariants': {}, 'errors': [], 'flanks': {}, 'last_frame': 0}
    with Path(path).open(encoding='utf-8', errors='replace') as stream:
        for line in stream:
            f = re.search(r'\[f=(\d+)\]', line)
            if f:
                result['last_frame'] = max(result['last_frame'], int(f[1]))
            event = re.search(r'\[Scorecard\] (\w+) (\{.*\})', line)
            if event:
                try:
                    result['events'].append((event[1], json.loads(event[2])))
                except (ValueError, TypeError):
                    result['errors'].append('Malformed scorecard event')
            role = re.search(r'\[GameDetails\] skirmishAI=\d+ team=(\d+).*?side=\'(\w+)\'.*?role=(\d+)', line)
            if role:
                result['roles'][int(role[1])] = {'side': role[2], 'role': int(role[3])}
            start = re.search(r':::AI LOG:S:\d+:T:(\d+):.*Captured start position \(([-\d.eE+]+),([-\d.eE+]+)\)', line)
            if start:
                result['starts'][int(start[1])] = [float(start[2]),float(start[3])]
            inv = re.search(r'\[INVARIANT\] (INV-\d+)', line)
            if inv:
                result['invariants'][inv[1]] = result['invariants'].get(inv[1], 0) + 1
            # GC teardown warnings do not invalidate a legitimate completed match.
            if re.search(r'Access violation|SCRIPT CRASH|has crashed|failed handling event|\.as \(.*: (?:ERR|WARN)|Error in.*scorecard', line):
                result['errors'].append(line.strip()[:500])
            flank = re.search(r':::AI LOG:S:\d+:T:(\d+):F:(\d+):L::\[TECH\]\[Flank\] (.*)', line)
            if flank:
                team = result['flanks'].setdefault(int(flank[1]), {'orders': [], 'routed': {}})
                if flank[3].startswith('ordered'):
                    team['orders'].append({'frame': int(flank[2]), 'message': flank[3].strip()})
                unit = re.search(r'routed (\w+) unit=(\d+)', flank[3])
                if unit:
                    team['routed'].setdefault(unit[2], {'name': unit[1], 'frame': int(flank[2])})
    return result


def ratio(a, b):
    return a / b if a is not None and b is not None and b > 0 else None


def team_metrics(team, events, flank, end_frame):
    samples = [e for kind, e in events if kind == 'sample' and e['team'] == team and e['frame'] <= end_frame]
    combat = [e for kind, e in events if kind == 'combat' and e['team'] == team and e['frame'] <= end_frame]
    last = samples[-1] if samples else {}
    milestones = {}
    for mark in (5, 10, 15, 20, 30, 40):
        nearby = [s for s in samples if s['frame'] == mark * 1800]
        milestones[str(mark)] = nearby[-1] if nearby else None
    elapsed = end_frame / 1800
    high_income = [s for s in samples if s.get('metalIncome', 0) >= 200 and not s.get('dead')]
    starved = [s for s in high_income if s.get('combatCompleted', 0) == 0]
    # Sampling counts are diagnostic observations, not interpolated continuous durations.
    return {
        'samples': samples, 'last': last, 'fixed_minute_snapshots': milestones,
        'first_combat_minute': combat[0]['frame'] / 1800 if combat else None,
        'first_specialist_minute': next((e['frame'] / 1800 for e in combat if e['specialist']), None),
        'first_t2_combat_minute': next((e['frame'] / 1800 for e in combat if e['tier'] == 2), None),
        'first_t3_combat_minute': next((e['frame'] / 1800 for e in combat if e['tier'] >= 3), None),
        'combat_completions': len(combat), 'combat_metal_per_minute': ratio(sum(e['metal'] for e in combat), elapsed),
        'specialist_completions': sum(e['specialist'] for e in combat),
        'metal_excess_fraction': ratio(last.get('metalExcess'), last.get('metalProduced', 0) + last.get('metalReceived', 0)),
        'damage_exchange_ratio': ratio(last.get('damageDealt'), last.get('damageReceived')),
        'combat_kill_loss_metal_ratio': ratio(last.get('combatKilledMetal'), last.get('combatLostMetal')),
        'factory_idle_sample_fraction': ratio(sum(s['idleFactories'] for s in samples), sum(s['factories'] for s in samples)),
        'high_income_samples_without_combat': len(starved),
        'high_income_samples': len(high_income),
        'flank_orders': flank.get('orders', []),
        'flank_routed_unique_ids': len(flank.get('routed', {})),
        'first_flank_route_minute': min((r['frame']/1800 for r in flank.get('routed', {}).values()), default=None),
    }


def make_card(manifest, parsed):
    events = parsed['events']
    runtime = next((e for kind, e in events if kind == 'init'), {})
    outcome = next((e for kind, e in events if kind == 'outcome' and e.get('source') == 'engine_GameOver'), None)
    end_frame = outcome['frame'] if outcome else parsed['last_frame']
    expected_roles = {'FRONT': 0, 'AIR': 1, 'TECH': 2, 'SEA': 3, 'SUPPORT': 4, 'TACTICAL': 5}
    roster_ok = all(parsed['roles'].get(t['team']) == {'side': t['side'], 'role': expected_roles[t['role']]}
                    for t in manifest['teams'])
    starts_ok = all(t['team'] in parsed.get('starts', {}) and
                    math.dist(parsed['starts'][t['team']], [t['x'],t['z']]) <= 64 for t in manifest['teams'])
    metrics = {str(t['team']): team_metrics(t['team'], events, parsed['flanks'].get(t['team'], {}), end_frame)
               for t in manifest['teams']}
    complete_samples = all(m['last'] and end_frame - m['last']['frame'] <= 1800 for m in metrics.values())
    known_content = all(runtime.get(k) not in (None, '', 'unknown') for k in ('mapChecksum', 'gameChecksum'))
    quality = {'roster_verified': roster_ok, 'starts_verified': starts_ok, 'content_verified': known_content, 'samples_complete': complete_samples,
               'errors': parsed['errors'], 'invariants': parsed['invariants'],
               'comparable': roster_ok and starts_ok and known_content and complete_samples and not parsed['errors']}
    if parsed['errors'] or not roster_ok or not starts_ok or not known_content or not complete_samples:
        status = 'invalid'
    elif outcome is None:
        status = 'censored'
    else:
        status = 'completed'
    winners = [int(x) for x in outcome['winners'].split(',') if x] if outcome else []
    allies = sorted(set(t['ally'] for t in manifest['teams']))
    valid_winners = not winners or (len(winners) < len(allies) and set(winners) <= set(allies))
    entrants = []
    for t in manifest['teams']:
        identity = {'dll': manifest['dll_sha256'], 'data': manifest['data_sha256'],
                    'options': manifest['ai_options'][t['team']] if len(manifest['ai_options']) > t['team'] else {},
                    'side': t['side'], 'role': t['role']}
        entrants.append({'team': t['team'], 'ally': t['ally'], 'side': t['side'], 'role': t['role'],
                         'id': digest(identity), 'identity': identity})
    distinct = len({e['id'] for e in entrants}) == len(entrants)
    rateable = status == 'completed' and valid_winners and distinct and len(allies) >= 2
    card = {'schema': SCHEMA, 'id': manifest['run_id'], 'manifest': manifest,
            'recorded_at_utc': dt.datetime.now(dt.timezone.utc).isoformat(),
            'condition': condition(manifest, runtime), 'quality': quality,
            'actual_starts': {str(k):v for k,v in parsed.get('starts', {}).items()},
            'status': status, 'outcome': outcome, 'winners': winners, 'entrants': entrants,
            'rating_eligible': rateable,
            'rating_exclusion': None if rateable else ('duplicate entrant self-play' if not distinct else status if status != 'completed' else 'invalid winners or fewer than two opponents'),
            'game_minutes': end_frame / 1800, 'metrics': metrics}
    card['cohort'] = digest(card['condition'])
    return card


def record(directory, run, store=STORE):
    if store == STORE:
        require_checkout()
    directory, run, store = Path(directory), Path(run), Path(store)
    # A reusable engine directory may already contain a later experiment.
    # Prefer the watcher's snapshot for every input used to derive this card.
    def input_path(name):
        return run / name if (run / name).exists() else directory / name
    manifest = read_json(input_path('scorecard-manifest.json'))
    launched = read_json(input_path('launched.json'))
    engine = Path(launched['engine'])
    manifest['engine_version'] = engine.name
    headless = manifest['scenario'].get('headless')
    if not isinstance(headless,bool):
        raise ValueError('Manifest must declare the executed headless/display mode')
    inputs = read_json(run / 'run-inputs.json') if (run / 'run-inputs.json').exists() else {}
    manifest['engine_sha256'] = inputs.get('engine_sha256') or file_hash(engine / ('spring-headless.exe' if headless else 'spring.exe'))
    manifest['headless'] = headless
    parsed = parse_log(run / 'infolog.txt')
    card = make_card(manifest, parsed)
    card['evidence'] = {'run': str(run.resolve()), 'log_sha256': file_hash(run / 'infolog.txt'),
                        'report': str((run / 'report.md').resolve())}
    date = manifest['started_at_utc'][:10]
    dest = store / date / (card['id'] + '.json')
    if dest.exists():
        previous = read_json(dest)
        if previous['evidence'] != card['evidence']:
            raise ValueError('Existing scorecard evidence differs; refusing to overwrite history')
        if previous['schema'] == SCHEMA:
            return dest
        # Re-derive a newer schema from identical evidence, preserving the old
        # interpretation. The ledger consumes only the current card, not revisions.
        revision = store / 'revisions' / card['id'] / f"schema-{previous['schema']}.json"
        if revision.exists() and read_json(revision) != previous:
            raise ValueError('Conflicting archived scorecard revision')
        write_json(revision, previous)
    write_json(dest, card)
    render_card(card, dest.with_suffix('.md'))
    # Preserve input evidence with the archived run, not just its reusable write-dir.
    # Preserve the pre-launch snapshot recorded by the generic watcher; store
    # this engine-enriched interpretation as a separate artifact.
    if not (run / 'scorecard-manifest.json').exists():
        write_json(run / 'scorecard-manifest.json', read_json(directory / 'scorecard-manifest.json'))
    write_json(run / 'scorecard-runtime-manifest.json', manifest)
    for name in ('script.txt', 'teams.json', 'staged.json', 'launched.json'):
        if not (run / name).exists():
            shutil.copy2(directory / name, run / name)
    return dest


def render_card(card, path):
    m=card['manifest']
    def show(value):
        if value is None: return 'not observed / unavailable'
        if isinstance(value,float): return f'{value:.3f}'
        return str(value)
    lines=[f"# Scorecard — {m['map']}", '',
        f"- Started UTC: {m['started_at_utc']}",f"- Started local: {m['started_at_local']}",
        f"- Status: **{card['status']}**, observed {card['game_minutes']:.2f} game minutes",
        f"- Game: {m['game']}; engine: {m.get('engine_version','unknown')}",
        f"- Legion enabled: {m['modoptions'].get('experimentallegionfaction','unknown')}",
        f"- Strict comparison cohort: `{card['cohort']}`",
        f"- DLL: `{m['dll_sha256']}`; data: `{m['data_sha256']}`",
        f"- Outcome: {card['outcome'] or 'no confirmed game outcome; not a draw'}",
        f"- OpenSkill eligible: {card['rating_eligible']}; exclusion: {card['rating_exclusion'] or 'none'}",
        f"- Actual roster verified: {card['quality']['roster_verified']}; errors: {len(card['quality']['errors'])}",
        f"- Invariant violations: {card['quality']['invariants']}", '',
        'Damage, production and economy explain behavior; they do not award OpenSkill points.',
        'Private ratings and their uncertainty are in the generated ratings ledger. These are not public BAR ratings.', '',
        '| Metric | ' + ' | '.join(f"Team {e['team']} {e['side']} {e['role']}" for e in card['entrants'])+' |',
        '| --- | '+' | '.join('---:' for _ in card['entrants'])+' |']
    fields=[('first_combat_minute','First combat completion (min)'),('combat_completions','Combat completions'),
        ('specialist_completions','Configured specialist completions'),('combat_metal_per_minute','Completed combat metal/min'),
        ('first_t2_combat_minute','First T2 combat (min)'),('first_t3_combat_minute','First T3 combat (min)'),
        ('first_flank_route_minute','First completed unit assigned flank route (min)'),('flank_routed_unique_ids','Flank routed IDs (lower bound)'),
        ('metal_excess_fraction','Metal excess / (produced + received)'),('damage_exchange_ratio','Damage dealt / received'),
        ('combat_kill_loss_metal_ratio','Enemy combat metal killed / lost'),
        ('factory_idle_sample_fraction','Idle factory fraction across samples'),
        ('high_income_samples_without_combat','Half-minute samples at +200 with no combat ever completed')]
    for key,label in fields:
        lines.append('| '+label+' | '+' | '.join(show(card['metrics'][str(e['team'])][key]) for e in card['entrants'])+' |')
    lines += ['', '## Fixed-time economy and army', '', '| Team | Game minute | Metal income | Army metal | Combat completed |', '| --- | ---: | ---: | ---: | ---: |']
    for team,metric in card['metrics'].items():
        for minute,sample in metric['fixed_minute_snapshots'].items():
            if sample:
                lines.append(f"| {team} | {minute} | {sample['metalIncome']:.1f} | {sample['armyMetal']:.1f} | {sample['combatCompleted']} |")
    lines += ['', '## Exact settings and evidence', '',
        '```json',json.dumps({'modoptions':m['modoptions'],'ai_options':m['ai_options'],'teams':m['teams'],
                            'scenario':m['scenario'],'evidence':card['evidence']},indent=2),'```','']
    Path(path).write_text('\n'.join(lines),encoding='utf-8')


def load_model():
    try:
        import openskill
    except ImportError:
        sys.path.insert(0, str(RAW_ROOT / 'scorecard-deps'))
        import openskill
    version = importlib.metadata.version('openskill')
    if version != MODEL_VERSION:
        raise RuntimeError(f'Install openskill=={MODEL_VERSION}; found {version}')
    from openskill.models import PlackettLuce
    return PlackettLuce()


def rating_fields(r):
    return {'mu': r.mu, 'sigma': r.sigma, 'match_rating': r.mu - r.sigma,
            'conservative_rating': r.ordinal(), 'approx_95_low': r.mu-1.96*r.sigma,
            'approx_95_high': r.mu+1.96*r.sigma}


def ratings_for(cards):
    model = load_model()
    ratings, games, events = {}, {}, []
    for card in sorted(cards, key=lambda c: (c['manifest']['started_at_utc'], c['id'])):
        ids = [(card['cohort'], e['id']) for e in card['entrants']]
        before = []
        for key in ids:
            ratings.setdefault(key, model.rating())
            games.setdefault(key, 0)
            before.append(rating_fields(ratings[key]))
        allies = sorted(set(e['ally'] for e in card['entrants']))
        grouped = [[ratings[ids[i]] for i, e in enumerate(card['entrants']) if e['ally'] == a] for a in allies]
        prediction = model.predict_win(grouped) if len(allies) > 1 else []
        if card['rating_eligible']:
            # This pinned implementation treats zero ranks as unspecified in
            # part of its ranking path. Use explicit one-based ranks for ties.
            ranks = [1 if not card['winners'] or a in card['winners'] else 2 for a in allies]
            updated = model.rate(grouped, ranks=ranks)
            for ally, values in zip(allies, updated):
                indices = [i for i,e in enumerate(card['entrants']) if e['ally']==ally]
                for i, value in zip(indices, values):
                    ratings[ids[i]] = value
                    games[ids[i]] += 1
        events.append({'card': card['id'], 'cohort': card['cohort'], 'updated': card['rating_eligible'],
                       'predicted_win_by_ally': dict(zip(map(str, allies), prediction)),
                       'before': before, 'after': [rating_fields(ratings[k]) for k in ids]})
    return {'model': 'OpenSkill PlackettLuce', 'version': MODEL_VERSION,
            'parameters': {'mu':25,'sigma':25/3,'beta':25/6,'tau':25/300,'kappa':0.0001},
            'scope': 'Private map/settings/AI-faction-role ladder; NOT BAR public account ratings',
            'events': events,
            'entrants': [{'cohort':k[0], 'entrant':k[1], 'rated_games':games[k], 'provisional':games[k]<10,
                          **rating_fields(v)} for k,v in sorted(ratings.items())]}


def rebuild(store=STORE):
    if store == STORE:
        require_checkout()
    store=Path(store)
    store.mkdir(parents=True,exist_ok=True)
    lock=store/'.rebuild-lock'
    deadline=time.monotonic()+30
    while True:
        try:
            descriptor=os.open(lock,os.O_CREAT|os.O_EXCL|os.O_WRONLY)
            os.write(descriptor,str(os.getpid()).encode())
            os.close(descriptor)
            break
        except FileExistsError:
            if time.monotonic()>=deadline:
                raise RuntimeError('Scorecard index is locked; verify the owning process before removing .rebuild-lock')
            time.sleep(0.1)
    try:
        return _rebuild(store)
    finally:
        lock.unlink()


def _rebuild(store):
    store = Path(store)
    cards = [read_json(p) for p in sorted(store.glob('*/*.json'))]
    ratings = ratings_for(cards)
    write_json(store / 'ratings.json', ratings)
    rows = ['# Map/settings scorecards', '',
            'Private OpenSkill estimates use confirmed outcomes only. Censored games never become draws.',
            'Compare within an exact cohort; Legion on/off and different rosters/settings stay separate.',
            'First runs are provisional baselines, not calibrated public BAR ratings.', '',
            '| Started (UTC) | Map | Legion | Cohort | Status | Minutes | Combat completions by team | Specialist completions by team | Rated | Card |',
            '| --- | --- | --- | --- | --- | ---: | --- | --- | --- | --- |']
    for c in cards:
        m = c['manifest']
        relative = f"{m['started_at_utc'][:10]}/{c['id']}.md"
        render_card(c,store/relative)
        combat = ', '.join(f"{k}: {v['combat_completions']}" for k,v in c['metrics'].items())
        specialist = ', '.join(f"{k}: {v['specialist_completions']}" for k,v in c['metrics'].items())
        rows.append(f"| {m['started_at_utc']} | {m['map']} | {m['modoptions'].get('experimentallegionfaction','unknown')} | {c['cohort'][:12]} | {c['status']} | {c['game_minutes']:.2f} | {combat} | {specialist} | {'yes' if c['rating_eligible'] else 'no'} | [Scorecard]({relative}) |")
    rows += ['', '## Rating events', '', '| Card | Updated | Pre-game win probabilities | Post-game mu / sigma (team order) |', '| --- | --- | --- | --- |']
    for e in ratings['events']:
        values = '; '.join(f"{r['mu']:.3f} / {r['sigma']:.3f}" for r in e['after'])
        rows.append(f"| {e['card']} | {e['updated']} | {e['predicted_win_by_ally']} | {values} |")
    (store / 'README.md').write_text('\n'.join(rows)+'\n', encoding='utf-8')
    return store / 'README.md'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('record'); p.add_argument('directory'); p.add_argument('--run', required=True)
    sub.add_parser('rebuild')
    p = sub.add_parser('compare'); p.add_argument('a'); p.add_argument('b')
    args = parser.parse_args()
    if args.command == 'record': print(record(args.directory, args.run))
    elif args.command == 'rebuild': print(rebuild())
    else: print(json.dumps(compare(read_json(args.a),read_json(args.b)),indent=2))


if __name__ == '__main__':
    main()
