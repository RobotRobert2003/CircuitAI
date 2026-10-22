"""Immutable, content-addressed symbols; never hard-link mutable build output.

Publish through a temporary file and atomically replace the destination. This
also prevents restaging a run from overwriting symbols shared by older runs.
"""
import hashlib
import os
from pathlib import Path
import shutil
import tempfile
from benchmark_store import RAW_ROOT, require_checkout


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def replace_link(source, destination, allow_copy=True):
    destination = Path(destination)
    descriptor, temporary = tempfile.mkstemp(prefix='.symbol-', dir=destination.parent)
    os.close(descriptor)
    temporary = Path(temporary)
    try:
        temporary.unlink()
        try:
            os.link(source, temporary)
        except OSError:
            if not allow_copy:
                raise
            # Cross-volume or link-count limit: retain bytes, forgo savings.
            shutil.copy2(source, temporary)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def stage_symbols(source, destination, pool=None):
    if pool is None:
        require_checkout()
        pool = RAW_ROOT / 'symbols'
    pool = Path(pool)
    pool.mkdir(parents=True, exist_ok=True)
    checksum = digest(source)
    target = pool / (checksum + '.dbg')
    if not target.exists():
        descriptor, temporary = tempfile.mkstemp(prefix='.incoming-', dir=pool)
        os.close(descriptor)
        temporary = Path(temporary)
        try:
            shutil.copy2(source, temporary)
            if digest(temporary) != checksum:
                raise RuntimeError('Build symbols changed while being staged')
            # Exclusive hard-link publication tolerates concurrent staging.
            try:
                os.link(temporary, target)
            except FileExistsError:
                pass
        finally:
            temporary.unlink(missing_ok=True)
    if digest(target) != checksum:
        raise RuntimeError('Corrupt symbol pool: ' + str(target))
    replace_link(target, destination)
    return checksum
