"""Read-only SEA frontier metrics; never reinterpret the original smoke verdict."""
import argparse
import json
import math
import re
from pathlib import Path


def analyze(path):
    teams, workers, retreats, losses, forts = {}, {}, [], [], []
    planned_forts, completed_forward_forts = [], []
    for line in path.read_text(errors='replace').splitlines():
        m = re.search(r'sample frame=(\d+) team=(\d+) mexes=(\d+) beyond2400=(\d+) furthest=(\d+)', line)
        if m:
            frame, team, mexes, forward, far = map(int, m.groups())
            teams[team] = dict(frame=frame, mexes=mexes, beyond2400=forward, furthest=far)
        m = re.search(r'worker frame=(\d+) team=(\d+) id=(\d+) x=(-?\d+) z=(-?\d+)', line)
        if m:
            f, team, uid, x, z = map(int, m.groups())
            workers.setdefault(uid, []).append((f, x, z))
        m = re.search(r'F:(\d+):.*\[SEA\]\[Expansion\] withdraw ship=(\d+) x=(-?\d+) z=(-?\d+)', line)
        if m:
            retreats.append(tuple(map(int, m.groups())))
        m = re.search(r'T:(\d+):F:(\d+):.*\[SEA\]\[Expansion\] fort=(\w+) ship=\d+ x=(-?\d+) z=(-?\d+)', line)
        if m:
            team, frame, definition, x, z = m.groups()
            planned_forts.append((int(team),int(frame),definition,int(x),int(z)))
        if '[SeaExpansionWatch] destroyed' in line and re.search(r'def=(armcs|corcs|legnavyconship) ', line):
            losses.append(line)
        if '[SeaExpansionWatch] finished' in line and re.search(r'def=(armtl|cortl|legtl|armfhlt|corfhlt|legfmg|armfrt|corfrt|legfrl) ', line):
            forts.append(line)
            m = re.search(r'\[f=0*(\d+)\].*finished team=(\d+) id=(\d+) def=(\w+) .*x=(-?\d+) z=(-?\d+)', line)
            if m:
                frame, team, uid, definition, x, z = m.groups()
                # A native completion close to a prior script cluster order is
                # stronger evidence than counting unrelated home defenses. Keep
                # original lines, use each order once, and label this spatial
                # correlation rather than claiming a native task-ID join.
                for i in range(len(planned_forts)-1,-1,-1):
                    t,f,d,px,pz=planned_forts[i]
                    if t==int(team) and d==definition and f<=int(frame) and math.hypot(px-int(x),pz-int(z))<=256:
                        completed_forward_forts.append(line)
                        planned_forts.pop(i)
                        break
    evidence = []
    for f, uid, x, z in retreats:
        before = [p for p in workers.get(uid, []) if f-150 <= p[0] <= f]
        after = [p for p in workers.get(uid, []) if f+300 <= p[0] <= f+900]
        if before and after:
            a, b = before[-1], after[-1]
            gain = math.hypot(a[1]-x,a[2]-z)-math.hypot(b[1]-x,b[2]-z)
            evidence.append(dict(frame=f, unit=uid, homeward_elmos=round(gain), end_frame=b[0]))
    return dict(teams=teams, constructor_losses=len(losses), loss_evidence=losses,
                completed_naval_defenses=len(forts), defense_evidence=forts,
                completed_forward_forts=len(completed_forward_forts), forward_fort_evidence=completed_forward_forts,
                withdrawal_orders=len(retreats), measured_withdrawals=evidence)


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('log',type=Path)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    result=json.dumps(analyze(args.log),indent=2)
    if args.output: args.output.write_text(result+'\n')
    else: print(result)
