"""Read physical SEA arena/economy evidence without rewriting original verdicts.

Reports commands received by the engine, not network packets or human APM.
Different survivors in natural games do not establish same-state CPU savings.
"""
import argparse
import collections
import json
from pathlib import Path
import re


def summarize(text):
    spawned, dead = {}, set()
    losses, damage, commands = collections.Counter(), collections.Counter(), collections.Counter()
    objectives, samples, failures, breaks, perf = {}, [], [], [], []
    death_frames, per_def_orders, sources = {}, {}, {}
    end = 0
    coastal_missions = 0
    for line in text.splitlines():
        frame = re.search(r'\[f=(\d+)\]', line)
        if frame:
            end = max(end, int(frame[1]))
        fields = dict(re.findall(r'(\w+)=([^\s]+)', line))
        if '[SeaArena]' in line:
            if ' spawn ' in line:
                spawned[fields['id']] = fields
                if fields['team'] == '1':
                    objectives[fields['id']] = dict(unit=fields['unit'], first_hit=None, destroyed=None)
            elif ' death ' in line:
                dead.add(fields['id'])
                death_frames[fields['id']] = int(fields['frame'])
                losses[fields['team']] += float(fields['cost'])
                if fields['id'] in objectives:
                    objectives[fields['id']]['destroyed'] = int(fields['frame']) / 30
            elif ' damage ' in line:
                if not {'team','amount','victim','frame'} <= fields.keys():
                    # A failed/crashed fixture can end mid-log-record. Preserve
                    # that limitation rather than inventing a hit or aborting
                    # publication of the other immutable observations.
                    failures.append('Incomplete damage record: '+line)
                    continue
                damage[fields['team']] += float(fields['amount'])
                target = objectives.get(fields['victim'])
                if fields['team']=='0' and target is not None and target['first_hit'] is None:
                    target['first_hit'] = int(fields['frame']) / 30
            elif ' orders ' in line:
                commands[fields['team']] += int(fields['apm'])
            elif ' order_types ' in line:
                counter = per_def_orders.setdefault(fields['team'], collections.Counter())
                counter.update({k: int(v) for k, v in (item.rsplit(':', 1) for item in fields['units'].split(','))})
            elif ' order_sources ' in line:
                counter = sources.setdefault(fields['team'], collections.Counter())
                counter.update({k: int(v) for k, v in (item.rsplit(':', 1) for item in fields['sources'].split(','))})
        if '[WorkforcePerf]' in line and 'ai_all_p95_ms' in fields:
            perf.append({k: float(v) for k, v in fields.items()
                         if k in ('frame','samples','sim_speed') or k.startswith('ai_all_')})
        if '[SEA][Pursuit] break' in line:
            breaks.append(dict(frame=int(frame[1]) if frame else None, **fields))
        if '[SEA][CoastSupport]' in line and ':T:0:' in line:
            coastal_missions += 1
        if '[SeaWatch] sample' in line:
            sample = re.search(r'frame=(\d+) metal=([\d.]+)/([\d.]+) income=([\d.]+) use=([\d.]+) energy=([\d.]+)/([\d.]+) income=([\d.]+) use=([\d.]+) yards=(\d+) busy=(\d+) bp=([\d.]+) idle=([\d.]+) units=(.*)', line)
            if sample:
                keys = ('frame', 'metal', 'metal_storage', 'metal_income', 'metal_usage', 'energy', 'energy_storage', 'energy_income', 'energy_usage', 'yards', 'busy_yards', 'workforce_power', 'idle_power')
                record = dict(zip(keys, map(float, sample.groups()[:-1])))
                record['units'] = sample[14]
                samples.append(record)
        if '[INVARIANT]' in line or re.search(r': ERR\s+:|SCRIPT CRASH|Lib exception|\[SeaArena\].*ERROR', line):
            failures.append(line)
    exposure = {}
    for unit_id, unit in spawned.items():
        counter = exposure.setdefault(unit['team'], collections.Counter())
        counter[unit['unit']] += max(0, death_frames.get(unit_id, end)-int(unit['frame'])) / 1800
    return dict(schema=1, end_seconds=end/30, losses_metal=dict(losses),
                reported_damage=dict(damage), engine_commands_full_minute_windows=dict(commands),
                orders_by_def=per_def_orders, command_sources=sources,
                supplied_alive_unit_minutes=exposure, ai_all_teams_timing_windows=perf,
                survivors={team: collections.Counter(v['unit'] for k, v in spawned.items() if k not in dead and v['team'] == team)
                           for team in ('0', '1')}, objectives=objectives, pursuit_breaks=breaks,
                coastal_missions=coastal_missions, economy=samples, failures=failures)


def audit(summary, acceptance):
    """Physical outcomes, separate from smoke checks and original verdicts."""
    failures=[]
    if acceptance.get('coastal_mission') and summary.get('coastal_missions',0)==0:
        failures.append('No surplus-cohort coastal mission observed')
    for unit,minimum in acceptance.get('minimum_survivors',{}).items():
        actual=summary['survivors'].get('0',{}).get(unit,0)
        if actual<minimum: failures.append(f'{unit}: {actual} survivors; expected at least {minimum}')
    # A spawned mex may be removed by game rules or reclaimed by its owner.
    # A death without observed friendly damage is not proof of an AI attack.
    deaths=collections.Counter(v['unit'] for v in summary['objectives'].values()
                               if v['destroyed'] is not None and v.get('first_hit') is not None)
    for unit,minimum in acceptance.get('destroyed_units',{}).items():
        if deaths[unit]<minimum: failures.append(f'{unit}: {deaths[unit]} confirmed destroyed; expected at least {minimum}')
    return failures


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('log', type=Path)
    p.add_argument('--output', type=Path)
    a = p.parse_args()
    result = summarize(a.log.read_text(errors='replace'))
    result['source'] = str(a.log.resolve())
    text = json.dumps(result, indent=2)
    if a.output:
        # A new derived report never replaces the runner's original verdict.
        with a.output.open('x', encoding='utf-8') as f:
            f.write(text+'\n')
    else:
        print(text)


if __name__ == '__main__':
    main()
