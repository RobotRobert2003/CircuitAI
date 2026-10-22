"""Assert the played sustained-rush lifecycle, including the exact 25% boundary."""
import argparse
import json
from pathlib import Path
import re


def analyze(directory):
    cfg=json.loads((directory/'ranged-arena.json').read_text())
    log=(directory/'infolog.txt').read_text(errors='replace')
    starts=[]; ends=[]
    for line in log.splitlines():
        frame=re.search(r'\[f=0*(\d+)\]',line)
        if not frame: continue
        row={'frame':int(frame[1]),**dict(re.findall(r'(\w+)=([^ ]+)',line))}
        row['frame']=int(frame[1])
        if 'RUSH: start ' in line: starts.append(row)
        if 'RUSH: end ' in line: ends.append(row)
    failures=[]
    if not starts: failures.append('No sustained campaign started')
    if not ends: failures.append('No campaign completion observed')
    if cfg.get('rush_loss_steps') and starts and ends:
        first=starts[0]
        end=next((e for e in ends if e['campaign']==first['campaign']),None)
        initial=int(first['initial'])
        quarter=next(s for s in cfg['rush_loss_steps'] if s['remaining']==initial*.25)
        # A live turret may kill the sixth survivor before the next deliberate
        # removal. Judge the observed original roster, not the planned clock.
        # Keep the v1 result: it incorrectly treated that legitimate death as
        # an early fallback. No runtime behavior or casualty limit is relaxed.
        original=set(); quarter_frame=None; below_frame=None
        front_unit=re.escape(cfg.get('rush_front_unit','corthud'))
        for line in log.splitlines():
            event=re.search(r'\[RangedArena\] frame=(\d+) (spawn|death) id=(\d+) team=0 unit='+front_unit+r'\b',line)
            if not event: continue
            frame,kind,unit=int(event[1]),event[2],int(event[3])
            if kind=='spawn' and frame<=cfg['rush_capture_seconds']*30: original.add(unit)
            elif kind=='death' and unit in original:
                original.remove(unit)
                if len(original)==initial*.25 and quarter_frame is None: quarter_frame=frame
                if len(original)<initial*.25 and below_frame is None: below_frame=frame
        if not end or end['reason']!='losses' or int(end['remaining'])>=initial*.25:
            failures.append('Wrong original-roster loss completion')
        elif quarter_frame is None or below_frame is None or below_frame<=quarter_frame or not below_frame<=end['frame']<=below_frame+30:
            failures.append('Did not retain exact-quarter commitment and end promptly below it')
        if initial!=24 or quarter['remaining']!=6: failures.append('Unexpected supplied original roster')
    result={'schema':2,'directory':str(directory),'starts':starts,'ends':ends,'failures':failures,'passed':not failures}
    output=directory/'rush-measurements-v2.json'
    if output.exists() and json.loads(output.read_text())!=result:
        raise RuntimeError('Refusing to overwrite different rush measurements: '+str(output))
    output.write_text(json.dumps(result,indent=2)+'\n')
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('directory',type=Path)
    result=analyze(parser.parse_args().directory)
    print(json.dumps(result,indent=2));raise SystemExit(not result['passed'])
