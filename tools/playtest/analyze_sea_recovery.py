"""Summarize observed production/recovery evidence, never rewrite check verdicts."""
import argparse
import collections
import json
from pathlib import Path
import re


def analyze(path):
    teams = collections.defaultdict(lambda: dict(factories={}, products=0, peak_subs=0))
    checks, samples, empty, progress_stalls, timers, idle_intervals, malformed = [], 0, [], [], [], [], []
    previous = {}
    for line in Path(path).read_text(errors='replace').splitlines():
        fields = dict(re.findall(r'(\w+)=([^\s]+)', line))
        if '[SeaRecoveryTest] PASS ' in line:
            checks.append(line.split('PASS ', 1)[1])
        if '[SeaRecoveryTest] census ' in line:
            t = teams[fields['team']]
            t['peak_subs'] = max(t['peak_subs'], int(fields['subs']))
        if '[SeaRecoveryTest] product ' in line:
            teams[fields['team']]['products'] += 1
        if '[SeaRecoveryTest] idle-end ' in line:
            idle_intervals.append(float(fields['seconds']))
        if '[SeaRecoveryTest] yard ' in line:
            required = {'team','id','name','tier','produced','emptySeconds','frame','product','progress'}
            if not required.issubset(fields):
                # Engine termination can leave a partial final log record.
                # Preserve the limitation instead of inventing zero progress.
                malformed.append(line[:500])
                continue
            samples += 1
            t = teams[fields['team']]
            t['factories'][fields['id']] = dict(name=fields['name'], tier=int(fields['tier']),
                                               produced=int(fields['produced']))
            # Empty duration is measured at 1 Hz by the observer. This list
            # does not invent a cause: retirement and limits need log review.
            if float(fields['emptySeconds']) >= 15:
                empty.append(fields)
            old = previous.get(fields['id'])
            if old and fields['product'] != 'nil' and old['product'] == fields['product']:
                if float(fields['progress']) <= float(old['progress']) and int(fields['frame']) > int(old['frame']):
                    progress_stalls.append(fields)
            previous[fields['id']] = fields
        if '[WorkforcePerf] frame=' in line:
            timers.append(fields)
    return dict(teams=dict(teams), checks_seen=sorted(set(checks)), factory_samples=samples,
                empty_at_least_15_seconds=empty, no_progress_samples=progress_stalls,
                empty_interval_count=len(idle_intervals),
                longest_completed_empty_interval=max(idle_intervals, default=0),
                completed_empty_seconds=sum(idle_intervals),
                incomplete_factory_records=malformed,
                engine_ai_minute_samples=timers,
                limitations=['10-second factory observations and 1-second empty-queue sampling; not every engine frame',
                             'No-progress samples can include resource stalls, obstruction, or waiting; diagnose separately',
                             'AI timing covers all AI callbacks; no baseline or internet APM comparison'])


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('log', type=Path)
    p.add_argument('--output', type=Path)
    a = p.parse_args()
    result = analyze(a.log)
    text = json.dumps(result, indent=2) + '\n'
    if a.output: a.output.write_text(text)
    else: print(text)


if __name__ == '__main__': main()
