"""Hash-verify and deduplicate archived AI symbols, retaining every original path.

Only isolated AI/Skirmish snapshots and symbol pools are eligible. Mutable build
outputs are excluded. Dry run by default. Never follows directory junctions.
"""
import argparse
from collections import defaultdict
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
from benchmark_store import require_checkout
from compress_symbols import allocated_bytes
from symbol_store import digest, replace_link


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    root = require_checkout().resolve()
    report = root / 'build-theatres/storage-audit' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ-symbols')
    report.mkdir(parents=True)
    groups = defaultdict(list)
    physical = {}
    for tree in ('build-theatres', 'build-validation'):
        for parent, directories, files in os.walk(root / tree, followlinks=False):
            directories[:] = [d for d in directories if not (Path(parent)/d).is_junction() and not (Path(parent)/d).is_symlink()]
            parts = Path(parent).relative_to(root).parts
            if not ('AI' in parts and 'Skirmish' in parts or 'symbols' in parts):
                continue
            for name in files:
                path = Path(parent) / name
                if path.suffix.lower() != '.dbg' or path.is_symlink():
                    continue
                if not path.resolve().is_relative_to(root):
                    raise RuntimeError('Symbol path escaped benchmark store')
                stat = path.stat()
                identity = (stat.st_dev, stat.st_ino)
                if identity not in physical:
                    physical[identity] = [path, stat, []]
                    groups[stat.st_size].append(identity)
                physical[identity][2].append(path)
    print(f'Inventory: {len(physical)} physical symbol files; hashing duplicate-size groups', flush=True)
    before_free = shutil.disk_usage(root).free
    saved = linked = checked = 0
    with (report / 'results.jsonl').open('x') as ledger:
        for size, identities in groups.items():
            if len(identities) < 2:
                continue
            hashes = {}
            # Retain compressed copies first, avoiding accidental expansion.
            identities.sort(key=lambda identity: allocated_bytes(physical[identity][0]))
            for identity in identities:
                path, before, paths = physical[identity]
                checksum = digest(path)
                if path.stat().st_mtime_ns != before.st_mtime_ns:
                    raise RuntimeError('Archive changed during hashing: ' + str(path))
                checked += 1
                canonical = hashes.get(checksum)
                if canonical is None:
                    hashes[checksum] = path
                else:
                    reclaimable = allocated_bytes(path)
                    row = dict(paths=[str(p.relative_to(root)) for p in paths], canonical=str(canonical.relative_to(root)), sha256=checksum, size=size, mtime_ns=before.st_mtime_ns, allocated_bytes=reclaimable, applied=False)
                    # Write preservation evidence before any replacement.
                    ledger.write(json.dumps(row)+'\n'); ledger.flush()
                    if args.apply:
                        for duplicate in paths:
                            current = duplicate.stat()
                            if (current.st_dev,current.st_ino,current.st_size,current.st_mtime_ns) != (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns):
                                raise RuntimeError('Archive changed before replacement')
                            replace_link(canonical, duplicate, allow_copy=False)
                            if not os.path.samefile(canonical, duplicate) and digest(duplicate) != checksum:
                                raise RuntimeError('Post-replacement verification failed')
                            linked += 1
                        # External hard links retain the original allocation.
                        if before.st_nlink == len(paths) and all(os.path.samefile(canonical,p) for p in paths):
                            saved += reclaimable
                        row['applied'] = True
                        ledger.write(json.dumps(row)+'\n'); ledger.flush()
                if checked % 10 == 0:
                    print(f'Hashed {checked}; replaced {linked} paths; released {saved/2**30:.2f} GiB',flush=True)
    summary = dict(hashed=checked, linked_paths=linked, released_file_data_bytes=saved, volume_free_before=before_free, volume_free_after=shutil.disk_usage(root).free)
    (report/'summary.json').write_text(json.dumps(summary,indent=2))
    print(str(report),json.dumps(summary),flush=True)


if __name__ == '__main__':
    main()
