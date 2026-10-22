"""Audit real factory repeat, completed offspring and per-producer MOVE travel.

Reads observer evidence only. It never supplies production or combat orders.
Factory geometry is outside the supplied-force scenario; all counters are
bounded to its observation deadline. The original watcher verdict is retained.
"""
import argparse
import json
from pathlib import Path
import re


def measure(text, deadline, direction=(0,1)):
    parents, finished, repeat, queues, starts, advance, moves, ends = {}, set(), set(), {}, {}, {}, set(), {}
    for line in text.splitlines():
        frame = re.search(r'\[RangedArena\] frame=(\d+) ', line)
        if not frame or int(frame[1]) > deadline:
            continue
        fields = dict(re.findall(r'(\w+)=([^ ]+)', line[frame.end():]))
        event = line[frame.end():].split(' ', 1)[0]
        ident = fields.get('id')
        if event == 'child' and 'parent' in fields:
            parents[ident] = fields['parent']
        elif event == 'finished':
            finished.add(ident)
        elif event == 'factory' and fields.get('repeat') == 'true':
            repeat.add(ident)
            queues[ident] = max(queues.get(ident, 0), int(fields['builds']))
        elif event == 'unit' and ident in parents and ident in finished:
            x,z = float(fields['x']),float(fields['z'])
            origin = starts.setdefault(ident,(x,z))
            advance[ident] = max(advance.get(ident,0), (x-origin[0])*direction[0]+(z-origin[1])*direction[1])
            if fields.get('command') == '10':
                moves.add(ident)
        elif event == 'lane' and int(fields.get('count',0)) > 0 and fields.get('endcmd')=='10':
            ends[fields['parent']] = [float(fields['endx']),float(fields['endz'])]
    produced = {fid:sum(ident in finished and parent == fid for ident,parent in parents.items()) for fid in sorted(repeat)}
    routed = {fid:sum(ident in moves and advance.get(ident,0)>800 for ident,parent in parents.items() if parent==fid) for fid in sorted(repeat)}
    failures=[]
    if not repeat: failures.append('no engine-repeat factory')
    if any(n<2 for n in produced.values()): failures.append('fewer than two completed offspring per repeating factory')
    if any(n<1 for n in routed.values()): failures.append('no completed offspring made >800 elmos progress on MOVE for a repeating factory')
    if any(n>1 for n in queues.values()): failures.append('repeat queue accumulated duplicate builds')
    if len(repeat)>1 and len({tuple(ends[f]) for f in repeat if f in ends})<len(repeat): failures.append('factories lack separate final lane endpoints')
    return dict(repeating_factories=sorted(repeat),completed=produced,move_progress_units=routed,
                maximum_repeat_queue=queues,last_lane_endpoints=ends,failures=failures,passed=not failures)


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('directory',type=Path);args=p.parse_args()
    cfg=json.loads((args.directory/'ranged-arena.json').read_text())
    dx,dz=(cfg['starts'][1][i]-cfg['starts'][0][i] for i in range(2));length=(dx*dx+dz*dz)**.5
    text=(args.directory/'infolog.txt').read_text(errors='replace')
    result=measure(text,cfg['minutes']*1800,(dx/length,dz/length))
    frames=[int(f) for f in re.findall(r'\[RangedArena\] frame=(\d+)',text)]
    if not frames or max(frames)<cfg['minutes']*1800-300:
        result['failures'].append('incomplete observation window')
    archives=sorted((args.directory/'runs').glob('*/result.json'))
    verdict=json.loads(archives[-1].read_text()).get('verdict') if archives else None
    if verdict!='PASS':result['failures'].append('original watch verdict: '+str(verdict))
    if re.search(r'\[INVARIANT\]|: ERR\s+:|\[RangedArena\].*ERROR',text):
        result['failures'].append('runtime/fixture error')
    if cfg.get('drop_energy_after_seconds'):
        grace=(cfg['drop_energy_after_seconds']+30)*30
        states=[(int(f),state) for f,state in re.findall(r'\[RangedArena\] frame=(\d+) factory .*repeat=(true|false)',text) if grace<=int(f)<=cfg['minutes']*1800]
        if not states or any(state=='true' for _,state in states):result['failures'].append('repeat not cancelled after income loss')
    result['passed']=not result['failures']
    result.update(case=cfg['name'],variant=cfg['variant'],deadline_frame=cfg['minutes']*1800,
                  watch_verdict=verdict,last_observed_frame=max(frames,default=0))
    # v2 measured directional movement; v3 additionally rejects incomplete or
    # failed observations. Keep earlier measurement files byte-for-byte.
    path=args.directory/'spam-measurements-v3.json'
    if path.exists() and json.loads(path.read_text()) != result: raise RuntimeError('immutable result changed')
    path.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2));return int(not result['passed'])

if __name__=='__main__':raise SystemExit(main())
