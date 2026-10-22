"""One-time, byte-preserving documentation migration with a reversible ledger.

Run --apply only after reviewing --inventory. Copies are hash verified before
individual originals are unlinked; no recursive delete or junction traversal.
Markdown links are relocated against their *old* resolved targets, including
source/evidence links. Legacy undecodable bytes and newline styles survive.
"""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
from documentation_store import SOURCE_ROOT, DOC_ROOT

LINK = re.compile(r'(!?\[[^\]]*\]\()([^\s)]+)(\))')


def inventory():
    moves = {p: DOC_ROOT / p.relative_to(SOURCE_ROOT/'doc')
             for p in (SOURCE_ROOT/'doc').rglob('*') if p.is_file()}
    for base, target in [('changelog','changelog'), ('data/script','scripting'),
                         ('tools/playtest','testing/playtest')]:
        for p in (SOURCE_ROOT/base).rglob('*.md'):
            moves[p] = DOC_ROOT/target/p.relative_to(SOURCE_ROOT/base)
    for p in (SOURCE_ROOT/'skills').glob('*/references/*.md'):
        moves[p] = DOC_ROOT/'skills'/p.relative_to(SOURCE_ROOT/'skills')
    moves[SOURCE_ROOT/'README.md'] = DOC_ROOT/'repository.md'
    moves[SOURCE_ROOT/'BARB5_CHANGELOG.md'] = DOC_ROOT/'history/BARB5_CHANGELOG.md'
    return moves


def relocate(raw, source, destination, moves):
    text = raw.decode('utf-8', errors='surrogateescape')
    def link(match):
        target=match[2]
        if target.startswith(('http:', 'https:', 'mailto:', '#', 'app:', 'codex:')): return match[0]
        file, marker, anchor=target.partition('#')
        if not file: return match[0]
        resolved=(source.parent/file).resolve()
        mapped=moves.get(resolved,resolved)
        path=os.path.relpath(mapped,destination.parent).replace('\\','/')
        return match[1]+path+(marker+anchor if marker else '')+match[3]
    return LINK.sub(link,text).encode('utf-8', errors='surrogateescape')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply',action='store_true')
    args=parser.parse_args()
    moves=inventory()
    if (DOC_ROOT/'documentation-store.json').exists():
        raise RuntimeError('Migration already performed; use the ledger and canonical paths.')
    print(json.dumps({'files':len(moves),'bytes':sum(p.stat().st_size for p in moves)},indent=2))
    if not args.apply: return
    records=[]
    for source,destination in moves.items():
        assert source.is_relative_to(SOURCE_ROOT) and destination.is_relative_to(DOC_ROOT)
        if destination.exists(): raise FileExistsError(destination)
        raw=source.read_bytes()
        moved=relocate(raw,source,destination,moves) if source.suffix=='.md' else raw
        destination.parent.mkdir(parents=True,exist_ok=True)
        destination.write_bytes(moved)
        if destination.read_bytes()!=moved: raise IOError('Copy verification failed: '+str(destination))
        records.append({'old':source.relative_to(SOURCE_ROOT).as_posix(),
                        'new':destination.relative_to(DOC_ROOT).as_posix(),
                        'original_sha256':hashlib.sha256(raw).hexdigest(),
                        'relocated_sha256':hashlib.sha256(moved).hexdigest(),
                        'original_bytes':len(raw),'relocated_bytes':len(moved)})
    # Preserve exact original bytes as a compact audit archive; Markdown link
    # rewriting is explicitly distinguished from byte-identical asset copies.
    import zipfile
    with zipfile.ZipFile(DOC_ROOT/'documentation-originals.zip','x',zipfile.ZIP_DEFLATED) as archive:
        for source in moves: archive.writestr(source.relative_to(SOURCE_ROOT).as_posix(),source.read_bytes())
    (DOC_ROOT/'documentation-migration.json').write_text(json.dumps({'schema':1,'moves':records},indent=2)+'\n')
    (DOC_ROOT/'documentation-store.json').write_text(json.dumps({'schema':1,'project':'CircuitAI','source':'S3KCentrifugal/CircuitAI'},indent=2)+'\n')
    # Update discoverable operational entry points before removing originals.
    for source in [SOURCE_ROOT/'AGENTS.md',*(SOURCE_ROOT/'skills').glob('*/SKILL.md')]:
        source.write_bytes(relocate(source.read_bytes(),source,source,moves))
    for source,destination in moves.items():
        source.unlink() # a verified individual file, never a computed directory
        if source.name=='README.md' or source==SOURCE_ROOT/'BARB5_CHANGELOG.md':
            target=os.path.relpath(destination,source.parent).replace('\\','/')
            source.write_text(f'# CircuitAI documentation\n\nSee the [canonical document]({target}) in `rjm.bar.docs/projects/circuitai/`.\n',encoding='utf-8')


if __name__=='__main__': main()
