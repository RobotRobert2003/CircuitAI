"""Summarize observed construction liveness without treating idle as a failure.

Samples have 30-second gaps: a stationary empty-queue span is a diagnostic,
not proof that work was continuously absent between observations. Resource,
threat and ownership context still needs native logs. Read a pinned raw run.
"""
import argparse
import collections
import json
from pathlib import Path
import re


def summarize(directory):
    directory = Path(directory)
    text = (directory / 'infolog.txt').read_text(errors='replace')
    spans, active, factories, finished = [], {}, {}, collections.Counter()
    fifth_turret, first_fusion = {}, {}
    for line in text.splitlines():
        if '[ConstructionWatch]' not in line:
            continue
        row = dict(re.findall(r'(\w+)=([^ ]+)', line))
        if not all(k in row for k in ('frame', 'id', 'team', 'def', 'event')):
            continue
        if row['event'] not in ('finished','sample'):
            continue
        if row['event'] == 'finished':
            finished[(row['team'], row['def'])] += 1
            if row['def'] in ('armnanotc','cornanotc','legnanotc') and finished[(row['team'],row['def'])] == 5:
                fifth_turret.setdefault(row['team'],int(row['frame']))
            if row['def'] in ('armfus','corfus','legfus'):
                first_fusion.setdefault(row['team'],int(row['frame']))
            if row['def'] in ('armsy', 'corsy', 'legsy'):
                factories.setdefault(row['team'], row)
            continue
        # Include all construction-ship names actually represented in the
        # three faction roster; submarines/commanders are separate actors.
        if row['def'] not in ('armcs', 'corcs', 'legnavyconship'):
            continue
        key = (row['team'], row['id'])
        frame = int(row['frame'])
        pos = (float(row['x']), float(row['z']))
        empty = row.get('command') == '-1' and float(row['progress']) >= 1
        old = active.get(key)
        continues = old and frame-old['last'] <= 900 and sum((a-b)**2 for a,b in zip(pos, old['pos'])) < 32**2
        if old and (not empty or not continues):
            spans.append(old)
            del active[key]
        if empty:
            if key not in active:
                active[key] = dict(team=int(row['team']), unit=int(row['id']), definition=row['def'], first=frame, last=frame, pos=pos)
            active[key]['last'] = frame
    spans.extend(active.values())
    spans.sort(key=lambda s: s['last']-s['first'], reverse=True)
    for span in spans:
        span['sampled_seconds'] = (span['last']-span['first']) / 30
    invariants = collections.Counter(re.findall(r'\[INVARIANT\] (INV-\d+)', text))
    first_launch = {}
    for team, frame in re.findall(r'\[NukeRush\] launch team=(\d+).*?frame=(\d+)',text):
        first_launch.setdefault(team,int(frame))
    return dict(directory=str(directory),
        fifth_turret_frames=fifth_turret, first_fusion_frames=first_fusion, first_launch_frames=first_launch,
        opening_facings=[dict(preferred=int(p),actual=int(a)) for p,a in re.findall(r'SEA_OPENING: preferred=(\d+) actual=(\d+)',text)],
        fault_passes=dict(collections.Counter(re.findall(r'\[ConstructionFault\] ([\w-]+)=PASS',text))),
        empty_stationary_ship_spans=spans[:20],
        first_finished_yards=factories,
        completed_construction=dict((team+':'+unit,count) for (team,unit),count in sorted(finished.items())),
        invariants=dict(invariants),
        native_retries=len(re.findall(r'BUILD_RECOVERY: .*action=retry', text)),
        native_releases=len(re.findall(r'BUILD_RECOVERY: .*action=release', text)),
        physical_yard_exits=len(re.findall(r'event=yard-exit ', text)),
        unverified_yard_exits=len(re.findall(r'event=exit-unverified ', text)),
        pin_passes=text.count('pin-transaction=PASS'),
        orphan_passes=text.count('orphan-transaction=PASS'),
        script_errors=len(re.findall(r': ERR\s+:', text)))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    print(json.dumps(summarize(parser.parse_args().directory), indent=2))
