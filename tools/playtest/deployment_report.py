"""Check every supplied primary unit advances toward the enemy by a deadline."""
import argparse,json,re
from pathlib import Path

def measure(directory, seconds, minimum):
    cfg=json.loads((directory/'ranged-arena.json').read_text())
    dx,dz=(cfg['starts'][1][i]-cfg['starts'][0][i] for i in range(2));n=(dx*dx+dz*dz)**.5
    origins,progress={},{}
    for line in (directory/'infolog.txt').read_text(errors='replace').splitlines():
        m=re.search(r'\[RangedArena\] frame=(\d+) (spawn|unit) id=(\d+).*unit='+re.escape(cfg['unit'])+r' x=(-?[\d.]+) z=(-?[\d.]+)',line)
        if not m or int(m[1])>=seconds*30:continue
        point=float(m[4]),float(m[5]);ident=m[3]
        if m[2]=='spawn':origins[ident]=point;progress[ident]=0
        elif ident in origins:
            origin=origins[ident];progress[ident]=max(progress[ident],((point[0]-origin[0])*dx+(point[1]-origin[1])*dz)/n)
    return dict(case=cfg['name'],variant=cfg['variant'],by_seconds=seconds,required_forward_elmos=minimum,
                progress_by_unit=progress,passed=bool(progress) and all(v>=minimum for v in progress.values()))

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('directory',type=Path)
    p.add_argument('--seconds',type=int,default=100);p.add_argument('--minimum',type=float,default=500)
    a=p.parse_args();r=measure(a.directory,a.seconds,a.minimum);out=a.directory/'deployment-measurements-v1.json'
    if out.exists() and json.loads(out.read_text())!=r:raise RuntimeError('immutable result changed')
    out.write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r,indent=2));raise SystemExit(0 if r['passed'] else 1)
