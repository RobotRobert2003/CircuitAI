"""Verify a deletion-only script cleanup against a pinned pre-change data tree.

The explicit manifest is a regression contract, not an automatic dead-code
classifier. Token subsequences prove no additions/reordering; exact surviving
function tokens and setting initializers provide the stronger body/value check.
Real host load and gameplay checks remain necessary.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
from review_script_dead_code import FUNCTION, mask
from check_settings_extraction import TOKEN, members


def tokens(source):
    return tuple(m[0] for m in TOKEN.finditer(source)
                 if not m[0].startswith(('//', '/*')))


def functions(source, omitted=()):
    code = mask(source)
    result = []
    for match in FUNCTION.finditer(code):
        if match[1] in omitted:
            continue
        depth, end = 1, match.end()
        while depth:
            depth += (code[end] == '{') - (code[end] == '}')
            end += 1
        result.append(tokens(source[match.start():end]))
    return Counter(result)


def verify(before, after, manifest):
    before, after = Path(before), Path(after)
    expected = json.loads(Path(manifest).read_text())['removals']
    removed_files = {r['file'].removeprefix('data/') for r in expected
                     if r['kind'] == 'file'}
    old_files = {p.relative_to(before) for p in (before/'script').rglob('*.as')}
    new_files = {p.relative_to(after) for p in (after/'script').rglob('*.as')}
    assert not new_files-old_files, 'Unexpected new script'
    assert {p.as_posix() for p in old_files-new_files} == removed_files
    checked = 0
    for relative in sorted(new_files):
        old, new = (before/relative).read_text(), (after/relative).read_text()
        # The approved lane batch removes five dead assignments inside the
        # loader. Everything else in that surviving function must be exact.
        expected_old = old
        for row in expected:
            if row['kind'] == 'lane-load' and row['file'] == 'data/'+relative.as_posix():
                expected_old = re.sub(r'(?m)^.*\b'+re.escape(row['name'])+r'\s*=.*\n', '', expected_old)
        remaining = iter(tokens(old))
        assert all(any(value == token for value in remaining) for token in tokens(new)), relative
        omitted = {row['name'].split('::')[-1] for row in expected
                   if row['file'] == 'data/'+relative.as_posix()
                   and row['kind'] in ('function', 'orphan-function', 'test-only-function')}
        assert functions(new) == functions(expected_old, omitted), f'Changed/unexpectedly removed function: {relative}'
        if 'settings' in relative.parts:
            assert not Counter(members(new))-Counter(members(old)), f'Changed setting: {relative}'
        checked += 1
    for row in expected:
        if not row['file'].startswith('data/') or row['kind'] in ('file', 'obsolete-include'):
            continue
        path = after/row['file'].removeprefix('data/')
        if not path.exists():
            continue
        code = mask(path.read_text())
        name = row['name'].split('::')[-1]
        assert not re.search(r'\b'+re.escape(name)+r'\b', code), f'Removal remains: {row}'
    return {'scripts_checked': checked, 'removed_files': len(removed_files),
            'surviving_bodies_and_settings_unchanged': True, 'manifest_checked': True}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before-data', type=Path, required=True)
    parser.add_argument('--after-data', type=Path, default=Path('data'))
    parser.add_argument('--manifest', type=Path, default=Path(__file__).parent/'fixtures/dead_code_cleanup.json')
    args = parser.parse_args()
    print(json.dumps(verify(args.before_data, args.after_data, args.manifest), indent=2))
