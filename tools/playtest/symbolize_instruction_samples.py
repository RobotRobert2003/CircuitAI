"""Resolve conditional AI instruction samples against the exact pinned PE symbols.

These are wall-clock instruction locations, not call stacks or CPU-cycle shares.
"""
import argparse,csv,json,struct,subprocess
from collections import Counter
from pathlib import Path


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('prefix',type=Path)
    p.add_argument('--dll',type=Path,required=True)
    a=p.parse_args()
    prefix=a.prefix.resolve();dll=a.dll.resolve();dbg=dll.with_suffix('.dbg')
    modules=json.loads(Path(str(prefix)+'.modules.json').read_text(encoding='utf-8-sig'))
    counts=Counter();locations=Counter();threads=Counter()
    with Path(str(prefix)+'.samples.csv').open() as stream:
        for r in csv.DictReader(stream):
            address=int(r['rip'],16);threads[int(r['tid'])]+=1
            module=next((m for m in modules if m['base']<=address<m['base']+m['size']),None)
            name=module['name'] if module else 'unresolved'
            counts[name]+=1
            if name.lower()=='skirmishai.dll':locations[address-module['base']]+=1
    with dll.open('rb') as stream:
        stream.seek(0x3c);pe=struct.unpack('<I',stream.read(4))[0]
        stream.seek(pe+24);kind=struct.unpack('<H',stream.read(2))[0]
        if kind!=0x20b:raise ValueError('Expected PE32+ DLL')
        stream.seek(pe+24+24);image_base=struct.unpack('<Q',stream.read(8))[0]
    response=Path(str(prefix)+'.addresses.txt')
    response.write_text('\n'.join(hex(image_base+rva) for rva in locations)+'\n')
    raw=Path(str(prefix)+'.symbols.txt')
    if locations:
        # Evidence lives outside the source checkout. Mount just the immutable
        # symbols and sample directory; never assume either is under the repo.
        cmd=['docker','run','--rm','--pull=never','--network','none',
             '-v',str(dbg.parent)+':/symbols:ro','-v',str(response.parent)+':/samples:ro','--entrypoint',
             'x86_64-w64-mingw32-addr2line','ghcr.io/beyond-all-reason/recoil-build-amd64-windows:latest',
             '-a','-f','-C','-i','-e','/symbols/'+dbg.name,
             '@/samples/'+response.name]
        text=subprocess.run(cmd,check=True,capture_output=True,text=True).stdout
    else:text=''
    raw.write_text(text)
    resolved=[];current=None
    for line in text.splitlines():
        if line.startswith('0x'):
            current={'rva':hex(int(line,16)-image_base),'samples':locations[int(line,16)-image_base],'inline':[]}
            resolved.append(current)
        elif current is not None:current['inline'].append(line)
    before=json.loads(Path(str(prefix)+'.threads-before.json').read_text(encoding='utf-8-sig'))
    after=json.loads(Path(str(prefix)+'.threads-after.json').read_text(encoding='utf-8-sig'))
    old={x['tid']:x['cpu_ms'] for x in before}
    result={'module_samples':counts.most_common(),'thread_samples':threads.most_common(),
            'thread_cpu_ms':sorted([[x['tid'],x['cpu_ms']-old[x['tid']]] for x in after if x['tid'] in old],key=lambda x:-x[1]),
            'ai_locations':sorted(resolved,key=lambda x:-x['samples']),
            'limitations':'Randomized conditional wall-clock instruction samples; inline symbols are not runtime stacks. Capture pauses perturb timing.'}
    Path(str(prefix)+'.resolved.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v[:8] for k,v in result.items() if isinstance(v,list)},indent=2))


if __name__=='__main__':main()
