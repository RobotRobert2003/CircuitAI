"""Index source test definitions without moving cases or historical evidence.

Discovery is deliberately conservative: extracted names are source definitions,
not pass claims. Runner-generated combinations remain named families; the
benchmark catalog, not this inventory, owns execution evidence.
"""
import os
from documentation_store import document
import argparse
import ast
import hashlib
import json
import re
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = document('testing')
DOMAINS = ('air', 'sea', 'tech', 'front', 'tactical', 'support')


def domain(path):
    parts = path.as_posix().lower().replace('-', '_').split('/')
    for name in DOMAINS:
        if name in parts or any(p.startswith(('test_' + name + '_', 'run_' + name + '_', name + '_')) for p in parts):
            return name
    return 'shared'


def discover():
    records = []
    paths = set()
    for base in ('tools/playtest/cases', 'tools/playtest/checks'):
        paths.update((ROOT / base).rglob('*.json'))
    paths.update((ROOT / 'tests').rglob('*_test.cpp'))
    paths.update((ROOT / 'tests').rglob('*_tests.as'))
    for base in ('tools', 'tests'):
        paths.update((ROOT / base).rglob('test_*.py'))
    paths.update((ROOT / 'tools/knowledge').glob('check_*.py'))
    paths.update((ROOT / 'tools/playtest').glob('*.py'))
    paths.update((ROOT / 'tools/playtest').glob('*.sh'))
    paths.update((ROOT / 'tools/playtest').glob('*.as'))
    paths.update((ROOT / 'tools/playtest/widgets').glob('*.lua'))
    paths.update((ROOT / 'tools').glob('run_*tests.sh'))
    for path in sorted(paths):
        rel = path.relative_to(ROOT)
        if any(p in ('runs', '__pycache__') for p in rel.parts):
            continue
        raw = path.read_bytes()
        source = raw.decode('utf-8-sig', errors='replace')
        names = []
        title = path.stem
        kind = 'suite'
        detail = ''
        if path.suffix == '.json':
            obj = json.loads(source)
            if '/cases/' in rel.as_posix():
                kind = 'scenario'
                title = obj.get('name', title)
                detail = 'Map: ' + str(obj.get('map', 'selected by runner'))
            else:
                kind = 'checks'
                for category in ('expect', 'forbid'):
                    names.extend(category + ': ' + str(v.get('key', v.get('pattern', '?'))) for v in obj.get(category, []))
        elif path.suffix == '.py':
            tree = ast.parse(source)
            names = sorted(n.name for n in ast.walk(tree) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name.startswith('test_'))
            if path.name.startswith('check_'):
                kind = 'validator'
            elif not path.name.startswith('test_'):
                kind = 'runner family' if (path.name.startswith('run_') or path.name.endswith('arena.py') or path.name=='playtest.py') else 'tool'
                # Discover explicit scenario options, but not faction/map/profile
                # cross-products which are dimensions rather than designed cases.
                for node in ast.walk(tree):
                    if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Attribute) or node.func.attr != 'add_argument':
                        continue
                    if not any(isinstance(a, ast.Constant) and a.value in ('--case', '--scenario', '--subset') for a in node.args):
                        continue
                    for kw in node.keywords:
                        if kw.arg == 'choices' and isinstance(kw.value, (ast.List, ast.Tuple)):
                            names.extend('scenario: ' + x.value for x in kw.value.elts if isinstance(x, ast.Constant) and isinstance(x.value, str))
            detail = (ast.get_docstring(tree) or '').split('\n')[0]
        elif path.suffix == '.as':
            names = re.findall(r'\bvoid\s+(test_\w+)\s*\(', source)
            if rel.parts[0]=='tools':
                kind='fixture/observer'
                detail='Scripted test probe; inspect the linked source for stages and assertions.'
        elif path.suffix == '.lua':
            kind='fixture/observer'
            detail='In-game fixture/observer; source inventory, not a claim of execution.'
        elif path.suffix == '.cpp':
            names = re.findall(r'\b(?:void|bool)\s+(test\w*|Test\w+)\s*\(', source)
            detail = 'Native executable; unnamed assertions remain inside the linked suite.'
        else:
            kind = 'runner family'
        area = rel.parts[4] if len(rel.parts) > 4 and rel.parts[2] in ('cases', 'checks') else (
            'fixtures' if kind=='fixture/observer' else 'policy' if path.suffix == '.as' else 'native' if path.suffix == '.cpp' else
            'validation' if kind == 'validator' else 'runners' if kind == 'runner family' else 'tooling')
        records.append(dict(id=rel.as_posix(), domain=domain(rel), area=area, kind=kind, title=title,
                            definitions=sorted(set(names)), detail=detail,
                            sha256=hashlib.sha256(raw).hexdigest(), execution='not inferred'))
    return records


def render(records):
    outputs = {OUT / 'catalog.json': json.dumps({'schema': 1, 'scope': 'Source definitions, not execution results', 'records': records}, indent=2) + '\n'}
    counts = Counter(r['domain'] for r in records)
    intro = '''# Test definition catalog

Generated by `python tools/knowledge/index_test_cases.py`; verify freshness with
`--check`. This is an inventory of designed scenarios, assertions, suites and
runner families. A listed definition does **not** mean it passed or was played.

## Browse by domain

| Domain | Source files |
| --- | ---: |
'''
    for name in sorted(set(counts) | set(DOMAINS)):
        intro += f'| [{name}](index/{name}.md) | {counts[name]} |\n'
        lines = [f'# {name.upper()} test definitions', '', 'Generated source inventory. Execution is not inferred.', '']
        subset = [r for r in records if r['domain'] == name]
        if not subset:
            lines += ['No dedicated source definitions discovered. Shared suites may exercise this role;',
                      'this is a coverage gap, not a claim of no testing or of passing behavior.', '']
        for area, kind in sorted({(r['area'], r['kind']) for r in subset}):
            lines += [f'## {area.title()} / {kind.title()}', '']
            for r in subset:
                if r['kind'] != kind or r['area'] != area:
                    continue
                lines += [f"### [{r['title']}]({os.path.relpath(ROOT / r['id'], OUT / 'index').replace(chr(92), '/')})", '']
                if r['detail']:
                    lines += [r['detail'], '']
                lines += ['- `' + n.replace('`', "'") + '`' for n in r['definitions']]
                if r['definitions']:
                    lines += ['']
        outputs[OUT / 'index' / (name + '.md')] = '\n'.join(lines)
    intro += '''
## Organization and evidence

- Reusable game scenarios: `tools/playtest/cases/<domain>/<area>/`.
- Runtime expectations: `tools/playtest/checks/<domain>/<area>/`.
- Native and embedded-VM suites: `tests/`, linked above without changing runner paths.
- Tooling tests and validators: alongside their owners under `tools/`.
- Standalone script probes and Lua widgets: indexed as fixtures/observers, so
  earlier tests embedded in tools remain discoverable without inventing results.
- Parameterized runner families are indexed as families; their Cartesian products
  are not falsely counted as individual executed cases.
- [Machine-readable definitions](catalog.json) include source hashes and named
  assertions where statically identifiable. Native unnamed assertions stay in
  the linked executable suite; this is not assertion-level coverage analysis.
- [Benchmark index](https://github.com/S3KCentrifugal/CircuitAI.benchmarks/blob/main/doc/benchmarks/README.md) and
  [evidence catalog](https://github.com/S3KCentrifugal/CircuitAI.benchmarks/blob/main/doc/benchmarks/catalog.json) own recorded results.
- [Storage conventions](../test-storage.md) define immutable raw games and
  compact evidence bundles. [Migration audit](../test-storage-moves.md) preserves
  historical benchmark paths. This index does not move or rewrite evidence.

Add cases using the existing domain/area convention, then regenerate this index.
Keep checks near their domain and link a runner that can reproduce the case.
Use result manifests for game/content/DLL/data hashes, seeds, PASS/FAIL status
and screenshots; never encode success in a scenario filename.
'''
    outputs[OUT / 'README.md'] = intro
    return outputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    outputs = render(discover())
    stale = []
    for path, content in outputs.items():
        if args.check:
            if not path.exists() or path.read_text(encoding='utf-8') != content:
                stale.append(str(path))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding='utf-8', newline='\n')
    print(json.dumps({'files': len(outputs), 'stale': stale}))
    return bool(stale)


if __name__ == '__main__':
    raise SystemExit(main())
