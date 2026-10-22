"""Stream full-match diagnostic logs; inclusive timers are never added to children."""
import argparse
from collections import Counter
import hashlib,json,re
from pathlib import Path


def fields(text):
    result={}
    for key,value in re.findall(r'(\w+)=([^\s]+)',text):
        try: result[key]=float(value) if '.' in value else int(value)
        except ValueError:result[key]=value
    return result


def analyze(directory):
    log=directory/'infolog.txt'
    result={key:[] for key in ('minutes','scopes','phases','labels','gc','orders','order_details','origins','command_joint','command_units','command_unit','command_traffic','wait_removals','roster','teams','game_over','deaths','errors')}
    tags={'SkirmishPerf':'minutes','PerfPhase':'phases','PerfLabel':'labels','PerfGC':'gc',
          'AirOrders':'orders','AirOrdersDetail':'order_details','CommandOrigin':'origins',
          'CommandJoint':'command_joint','CommandUnits':'command_units','CommandUnit':'command_unit',
          'CommandTraffic':'command_traffic',
          'CommandWaitRemoval':'wait_removals',
          'FullMatchRoster':'roster','FullMatchTeam':'teams','FullMatchEnd':'game_over','SkirmishPerfTeamDied':'deaths'}
    reserve,failed,inv=Counter(),Counter(),Counter()
    last_frame=0
    # One streaming pass keeps memory proportional to compact telemetry, not
    # multi-gigabyte engine logs. Preserve individual team/phase intervals.
    with log.open(encoding='utf-8',errors='replace') as stream:
        for line in stream:
            frame=re.search(r'\[f=(-?\d+)\]',line)
            if frame:last_frame=max(last_frame,int(frame[1]))
            minute=last_frame//1800
            if 'RESERVE:' in line:reserve[minute]+=1
            if 'RESERVE:' in line and 'no room' in line:failed[minute]+=1
            warning=re.search(r'\[INVARIANT\] (INV-\d+)',line)
            if warning:inv[warning[1]]+=1
            if re.search(r': ERR\s+:|SCRIPT CRASH|Access violation|Fatal:|Error in GameFrame\(\)|\[PerfFixture\] ERROR',line):
                if len(result['errors'])<100:result['errors'].append(line.strip())
            tag=re.search(r'\[('+ '|'.join(tags)+r')\] (.*)',line)
            if tag:result[tags[tag[1]]].append(fields(tag[2]))
            scope=re.search(r'\[SkirmishScope\] frame=(\d+) name=(.*?) total_ms=([\d.]+) interval_ms=([\d.]+)',line)
            if scope:result['scopes'].append(dict(frame=int(scope[1]),name=scope[2],total_ms=float(scope[3]),interval_ms=float(scope[4])))
    result.update(last_frame=last_frame,reservation_lines=dict(reserve),failed_placement_lines=dict(failed),invariants=dict(inv))
    return result


def summary(result):
    phases,labels=Counter(),Counter()
    for row in result['phases']:phases[row['phase']]+=row['exclusive_ms']
    for row in result['labels']:labels[row['label']]+=row['exclusive_ms']
    # Disabled profiler scopes are unavailable, not evidence of zero cost.
    # Keep their FPS/progress observations in the raw interval data, but never
    # nominate such a window as the measured AI peak (including all-off runs).
    valid=[r for r in result['minutes'] if r.get('frame',0)>1800 and r.get('profiling',1)==1]
    return dict(last_minute=result['last_frame']/1800,ended=result['game_over'],
        latest=result['minutes'][-2:],roster=result['roster'][-2:],
        worst_ai=max(valid,key=lambda x:x['ai_mean_ms'],default=None),
        phase_exclusive_ms=phases.most_common(8),label_exclusive_ms=labels.most_common(8),
        max_team_orders=max((r for r in result['orders'] if 'all_apm' in r),key=lambda x:x['all_apm'],default=None),
        reservation_lines=sum(result['reservation_lines'].values()),invariants=result['invariants'],errors=result['errors'][:4])


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('directory',type=Path)
    p.add_argument('--live',action='store_true',help='Print only; do not publish a moving log')
    a=p.parse_args();result=analyze(a.directory)
    if not a.live:
        with (a.directory/'infolog.txt').open('rb') as stream:result['log_sha256']=hashlib.file_digest(stream,'sha256').hexdigest()
        path=a.directory/'full-match-performance-v1.json'
        if path.exists() and json.loads(path.read_text())!=result:raise ValueError('Conflicting immutable analysis')
        if not path.exists():path.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(summary(result),indent=2))


if __name__=='__main__':main()
