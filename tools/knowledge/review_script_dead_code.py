"""Conservative AngelScript dead-code inventory; not a semantic reachability proof.

Includes are traversed from every deployed profile's init/main. Comment/string
masking prevents examples from becoming callers. A unique function identifier
with no caller is a candidate, except native callback names. Same-name overloads
and mutually unreachable call chains are intentionally not called dead. External
references and settings assigned without reads are reported for manual review.
"""
from pathlib import Path
from collections import Counter
import argparse,json,re,sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'playtest'))
from script_settings import mask

FUNCTION=re.compile(r'(?m)^\s*(?:const\s+)?(?:[\w:<>]+(?:\s*[@&])?\s+)((?!(?:if|for|while|switch|catch)\b)\w+)\s*\([^;{}]*\)\s*(?:const\s*)?\{')

def include_graph(start):
    seen=set(); missing=set();todo=[Path(start).resolve()]
    while todo:
        p=todo.pop()
        if p in seen:continue
        if not p.exists():missing.add(str(p));continue
        seen.add(p);raw=p.read_text();code=mask(raw)
        for match in re.finditer(r'(?m)^\s*#include\s+"([^"]+)"',raw):
            if '#include' in code[match.start():match.end()]:todo.append((p.parent/match[1]).resolve())
    return seen,sorted(missing)

def namespace_regions(code):
    regions=[]
    for m in re.finditer(r'\bnamespace\s+(\w+)\s*\{',code):
        depth=1;end=m.end()
        while depth and end<len(code):
            depth+=(code[end]=='{')-(code[end]=='}');end+=1
        parents=tuple(r[2] for r in regions if r[0]<m.start()<r[1])
        regions.append((m.end(),end,m[1],parents+(m[1],)))
    return regions

def namespace_at(regions,offset):
    matches=[r[3] for r in regions if r[0]<=offset<r[1]]
    return max(matches,key=len,default=())

def setting_references(codes):
    regions={p:namespace_regions(c) for p,c in codes.items()};settings={}
    for p,code in codes.items():
        if 'settings' not in p.parts:continue
        # Scalar tuning declarations, including comma-separated scalar members.
        for m in re.finditer(r'\b(?:bool|int|uint|float|string)\s+([^;{}]+);',code):
            for var in re.finditer(r'\b(\w+)\s*=(?!=)',m[1]):
                offset=m.start(1)+var.start(1);key=namespace_at(regions[p],offset)+(var[1],)
                settings[key]=dict(file=p,line=code.count('\n',0,offset)+1,name='::'.join(key),offset=offset,reads=[],writes=[])
    names={k[-1] for k in settings}
    for p,code in codes.items():
        for m in re.finditer(r'\b\w+(?:::\w+)*',code):
            parts=tuple(m[0].split('::'))
            if parts[-1] not in names:continue
            scope=namespace_at(regions[p],m.start());key=None
            for length in range(len(scope),-1,-1):
                candidate=scope[:length]+parts
                if candidate in settings:key=candidate;break
            if key is None:continue
            entry=settings[key]
            if p==entry['file'] and m.start()==entry['offset']:continue
            kind='writes' if re.match(r'\s*=(?!=)',code[m.end():]) else 'reads'
            entry[kind].append(dict(file=str(p),line=code.count('\n',0,m.start())+1))
    return [v for v in settings.values() if not v['reads']]

def review(root):
    root=Path(root).resolve(); script=root/'data/script';files=sorted(script.rglob('*.as'))
    codes={p:mask(p.read_text()) for p in files};counts=Counter(re.findall(r'\b\w+\b','\n'.join(codes.values())))
    profiles={};loaded=set()
    for folder in sorted(script.iterdir()):
        if not (folder/'main.as').exists():continue
        graph=set();missing=[]
        for name in ('main.as','init.as'):
            seen,lost=include_graph(folder/name);graph|=seen;missing+=lost
        profiles[folder.name]=dict(files=len(graph),missing=missing);loaded|=graph
    native='\n'.join(p.read_text(errors='replace') for p in (root/'src/circuit/script').glob('*.cpp'))
    callbacks=set(re.findall(r'GetFunc\(mod,\s*"[^"(]*?\b(\w+)\s*\(',native))
    ext={}
    for folder in ('src/circuit','tools','tests'):
        for p in (root/folder).rglob('*'):
            if p.is_file() and p.suffix in ('.as','.cpp','.h','.py','.lua','.json') and p.name!=Path(__file__).name:
                for name in set(re.findall(r'\b\w+\b',p.read_text(errors='replace'))):ext.setdefault(name,[]).append(p.relative_to(root).as_posix())
    functions=[];settings=[]
    for p,code in codes.items():
        for m in FUNCTION.finditer(code):
            name=m[1]
            if counts[name]!=1:continue
            functions.append(dict(file=p.relative_to(root).as_posix(),line=code.count('\n',0,m.start(1))+1,name=name,loaded=p in loaded,native_callback=name in callbacks,external=ext.get(name,[])))
        if 'settings' in p.parts:
            for m in re.finditer(r'\b(?:bool|int|uint|float|string)\s+(\w+)\s*=',code):
                if counts[m[1]]==1:settings.append(dict(file=p.relative_to(root).as_posix(),line=code.count('\n',0,m.start(1))+1,name=m[1],external=ext.get(m[1],[])))
    unused=setting_references(codes)
    for item in unused:
        item['file']=item['file'].relative_to(root).as_posix();item.pop('offset')
        for ref in item['writes']:ref['file']=Path(ref['file']).relative_to(root).as_posix()
    return dict(unread_settings=unused,files=len(files),profiles=profiles,unloaded=[p.relative_to(root).as_posix() for p in files if p not in loaded],functions=functions,settings=settings)

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2]);a=p.parse_args();print(json.dumps(review(a.root),indent=2))
