"""Validate the D-207 enrollment and unchanged classifications against its checkpoint.

Uses parsed JSONC for semantics; checks outside each enrolled object separately,
normalizing Git's CRLF/LF checkout conversion. It detects unrelated content
changes, not raw line-ending identity. It never rewrites the configuration.
"""
import argparse
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UNITS = ('armfboy', 'armfido', 'armsnipe', 'armmanni', 'cormort', 'corban',
         'cortrem', 'legamcluster', 'legmed', 'legvcarry')


def parse(raw):
    text = raw.decode('utf-8')
    text = re.sub(r'/\*.*?\*/|//[^\n]*', '', text, flags=re.S)
    return json.loads(re.sub(r',(\s*[}\]])', r'\1', text))


def span(raw, unit):
    start = re.search(rb'"' + unit.encode() + rb'"\s*:\s*\{', raw)
    if not start:
        return None
    opening = start.end()-1
    depth = 0
    # Nested threat/vs objects are part of the unit. Stopping at the first
    # closing brace silently missed Starlight's later retreat override.
    for token in re.finditer(rb'"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/|[{}]', raw[opening:]):
        if token[0] == b'{': depth += 1
        elif token[0] == b'}':
            depth -= 1
            if depth == 0: return start.start(), opening+token.end()
    raise ValueError('Unclosed unit: '+unit)


def neutralize(raw):
    for unit in UNITS:
        bounds = span(raw, unit)
        if bounds: raw = raw[:bounds[0]]+raw[bounds[1]:]
    return raw.replace(b'\r\n', b'\n') # Git's configured checkout conversion


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', default='24e0c4d7')
    args = parser.parse_args()
    count = files = 0
    for path in sorted((ROOT/'data/config').rglob('behaviour*.json')):
        if path.name not in ('behaviour.json', 'behaviour_leg.json'): continue
        relative = path.relative_to(ROOT).as_posix()
        old = subprocess.check_output(['git', '-c', 'safe.directory='+ROOT.as_posix(),
                                       'show', args.base+':'+relative], cwd=ROOT)
        raw = path.read_bytes()
        before, after = parse(old), parse(raw)
        assert neutralize(old) == neutralize(raw), relative+' unrelated bytes changed'
        modified = False
        for unit in UNITS:
            original = before.get('behaviour', {}).get(unit)
            if original is None: continue
            current = after['behaviour'][unit]
            expected = dict(original)
            expected['attribute'] = list(original.get('attribute', []))+['ranged']
            if unit == 'armsnipe' and 'ret_hold' not in expected['attribute']:
                expected['attribute'].append('ret_hold')
            expected['ranged'] = current['ranged']
            assert expected['ranged']['target_mode'] in ('precision','skirmish','bombardment','carrier')
            if unit in ('armsnipe', 'armmanni'):
                assert expected['ranged'].get('advance_unknown_radar') is (unit == 'armsnipe')
            if unit == 'armmanni': expected['retreat'] = .65
            assert current == expected, relative+' unexpected fields: '+unit
            count += 1; modified = True
        files += modified
    assert count == 77 and files == 15, (count, files)
    print(f'ranged profile audit: {count} entries / {files} files; roles and unrelated content preserved (Git EOL normalization allowed)')


if __name__ == '__main__': main()
