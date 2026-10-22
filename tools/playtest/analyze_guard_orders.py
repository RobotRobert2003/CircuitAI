"""Extract guard counts from immutable game logs; never equate counts with FPS."""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import re


def analyze(archive):
    log=archive/'infolog.txt'
    raw=log.read_bytes()
    text=raw.decode('utf-8',errors='replace')
    result=json.loads((archive/'result.json').read_text())
    samples=[dict(zip(('frame','commands','guards','repeated_targets','finished_mobile'),map(int,m)))
        for m in re.findall(r'\[GuardTest\] frame=(\d+) commands=(\d+) guards=(\d+) repeated_targets=(\d+) finished_mobile=(\d+)',text)]
    native=collections.Counter(source+'/'+action for source,action in re.findall(r'GUARD: unit=\d+ target=\d+ source=(\w+) action=(\w+)',text))
    return {'archive':str(archive),'raw_log_sha256':hashlib.sha256(raw).hexdigest(),
        'verdict':result['verdict'],'last_sample':samples[-1] if samples else None,
        'team0_cumulative_samples':samples,'native_all_teams':dict(native),
        'fixture_passes':sorted(set(re.findall(r'\[GuardTest\] PASS (\w+)',text))),
        'stop_recovery_frames':[int(n) for n in re.findall(r'\[GuardTest\] STOP recovery frames=(\d+)',text)],
        'invariant_events':text.count('[INVARIANT]'),
        'limitations':['repeated_targets includes required recovery and is not an exact duplicate-queue count',
            'native trace includes all AI teams; synchronized observer counts only team 0 non-Lua commands',
            'natural games can diverge; total commands and population are reported without an FPS claim',
            'supplied fixture repeats task admission; natural games retain normal role decisions']}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('archives',type=Path,nargs='+')
    p.add_argument('--output',type=Path,required=True)
    a=p.parse_args()
    rows=[]
    for archive in a.archives:
        row=analyze(archive.resolve()); rows.append(row)
        target=archive/'guard-analysis.json'
        payload=json.dumps(row,indent=2)+'\n'
        if target.exists() and target.read_text()!=payload:
            raise ValueError('Refusing to overwrite differing analysis: '+str(target))
        target.write_text(payload)
    a.output.write_text(json.dumps({'schema':1,'runs':rows},indent=2)+'\n')
    print(json.dumps([{'archive':r['archive'],'verdict':r['verdict'],'counts':r['last_sample']} for r in rows],indent=2))


if __name__=='__main__': main()
