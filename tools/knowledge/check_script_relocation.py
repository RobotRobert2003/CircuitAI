"""Compare deployment trees after a path-only script migration.

The baseline is an external snapshot, never regenerated from the candidate.
Includes use the vendored scriptbuilder's relative-file resolution. Comparing
ordered edges preserves section traversal/deduplication and declaration order;
all bytes outside include directives must remain identical. No game execution
or late-game equivalence is inferred from a startup test alone.
"""
import argparse
import json
import os
import re
from pathlib import Path

INCLUDE = re.compile(rb'^\s*#include\s+"([^"\r\n]+)"[^\r\n]*', re.M)


def compare(before, after):
    before, after = Path(before).resolve(), Path(after).resolve()
    originals = {p.relative_to(before).as_posix(): p for p in before.rglob('*') if p.is_file()}
    current = {p.relative_to(after).as_posix(): p for p in after.rglob('*') if p.is_file()}
    mapping = {}
    for name in originals:
        candidates = [name] if name in current else [p for p in current if Path(p).name == Path(name).name]
        if len(candidates) != 1:
            raise ValueError('Missing or ambiguous relocation: ' + name)
        mapping[name] = candidates[0]
    if len(set(mapping.values())) != len(mapping) or set(mapping.values()) != set(current):
        raise ValueError('Added, duplicated or removed deployment files')

    def edges(path, root):
        return [os.path.relpath((path.parent / match[1].decode()).resolve(), root).replace('\\', '/')
                for match in INCLUDE.finditer(path.read_bytes())]

    missing = []
    for name, original in originals.items():
        candidate = current[mapping[name]]
        old, new = original.read_bytes(), candidate.read_bytes()
        if original.suffix != '.as':
            if old != new:
                raise ValueError('Non-script content changed: ' + name)
            continue
        if INCLUDE.sub(b'', old) != INCLUDE.sub(b'', new):
            raise ValueError('Non-include script content changed: ' + name)
        expected = [mapping.get(target, target) for target in edges(original, before)]
        actual = edges(candidate, after)
        if expected != actual:
            raise ValueError('Include target or order changed: ' + name)
        missing.extend({'source': mapping[name], 'target': target} for target in actual
                       if not (after / target).is_file())
    return {'files_verified': len(originals), 'relocations': {a: b for a, b in mapping.items() if a != b},
            'non_include_bytes_identical': True, 'ordered_include_edges_identical': True,
            'preexisting_missing_includes': missing}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before-data', required=True, type=Path)
    parser.add_argument('--after-data', default=Path(__file__).resolve().parents[2] / 'data', type=Path)
    arguments = parser.parse_args()
    print(json.dumps(compare(arguments.before_data, arguments.after_data), indent=2))
