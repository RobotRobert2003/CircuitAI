"""Compare complete read-only settings snapshots from two host logs."""
import argparse
from pathlib import Path
import re,json

PHASES=('before-main','after-main','after-setup','minute-one')

def read(path):
    snapshots={}
    for line in Path(path).open(encoding='utf-8',errors='replace'):
        match=re.search(r'\[SettingsProbe\] (\S+) (\S+?)=(.*)',line)
        if not match:continue
        key=(match[1],match[2]);value=match[3].strip()
        if key in snapshots and snapshots[key]!=value:raise ValueError('Repeated phase changed: '+str(key))
        snapshots[key]=value
    return snapshots

def compare(before,after,fields):
    original,current=read(before),read(after)
    for label,snapshot in [('before',original),('after',current)]:
        for phase in PHASES:
            count=sum(key[0]==phase for key in snapshot)
            if count!=fields:raise ValueError(f'{label} {phase}: expected {fields}, found {count}')
    differences=[{'phase':key[0],'setting':key[1],'before':original.get(key),'after':current.get(key)}
                 for key in sorted(original.keys()|current.keys()) if original.get(key)!=current.get(key)]
    if differences:raise ValueError(json.dumps(differences,indent=2))
    return {'fields':fields,'phases':list(PHASES),'values_compared':len(original),'differences':0}

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--before',required=True);p.add_argument('--after',required=True);p.add_argument('--fields',type=int,required=True)
    a=p.parse_args();print(json.dumps(compare(a.before,a.after,a.fields),indent=2))