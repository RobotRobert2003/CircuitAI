"""Serial paired naval fixtures with pinned controls and independent scorecards."""
import argparse,hashlib,json,shutil,subprocess,sys
from pathlib import Path
import analyze_sea_arena,playtest,storage

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll',required=True,type=Path)
    p.add_argument('--baseline-dll',required=True,type=Path)
    p.add_argument('--baseline',required=True,type=Path)
    p.add_argument('--cases',default='surface-line,submarine-screen,hover-screen,air-cover,shore-siege,response-submarine,large-fleet')
    p.add_argument('--minutes',default=8,type=int)
    a=p.parse_args()
    root=storage.allocate('sea','combat','paired-cohort','glacial','supplied',seed=1891)
    for label,source in [('candidate',playtest.REPO/'data'),('control',a.baseline)]:shutil.copytree(source,root/label)
    print('SEA_COMBAT_COHORT='+str(root),flush=True)
    records=[]
    for case in a.cases.split(','):
        for label,dll in [('control',a.baseline_dll),('candidate',a.dll)]:
            cmd=[sys.executable,str(playtest.HERE/'sea_arena.py'),'--case',case,'--dll',str(dll),'--data',str(root/label),'--minutes',str(a.minutes)]
            if label=='control':cmd.append('--control')
            out=root/(case+'-'+label+'.txt')
            with out.open('w') as stream:r=subprocess.run(cmd,stdout=stream,stderr=subprocess.STDOUT)
            paths=[line.split('=',1)[1] for line in out.read_text(errors='replace').splitlines() if line.startswith('SEA_ARENA=')]
            rec=dict(case=case,variant=label,exit=r.returncode,dll_sha256=hashlib.sha256(dll.read_bytes()).hexdigest())
            if paths:
                d=Path(paths[0]);rec['directory']=str(d)
                archives=sorted((d/'runs').glob('*'))
                if archives:
                    log=archives[-1]/'infolog.txt';score=analyze_sea_arena.analyze(log)
                    (archives[-1]/'combat-scorecard.json').write_text(json.dumps(score,indent=2)+'\n')
                    rec.update(archive=str(archives[-1]),lost=score['metal_lost_by_team'],apm=score['peak_apm_by_team'],errors=score['fixture_errors'])
            records.append(rec);storage.write_json(root/'cohort.json',{'runs':records,'complete':False})
            print(json.dumps(rec),flush=True)
    storage.write_json(root/'cohort.json',{'runs':records,'complete':True,'scope':'Both teams use the same selected policy; paired regression, not win-rate tournament.'})
    return any(r['exit'] or r.get('errors') or 'archive' not in r for r in records)

if __name__=='__main__':sys.exit(main())
