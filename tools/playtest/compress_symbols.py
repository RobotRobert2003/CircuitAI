"""Losslessly compress idle playtest symbols on Windows; default is a dry run.

Only build-theatres/**/*.dbg is eligible. No files are removed, linked, renamed,
or rewritten by this tool. compact.exe changes Windows storage representation;
ordinary readers and crash symbolisers still see the original file bytes.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import ctypes
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
from benchmark_store import RAW_ROOT
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
STORE = RAW_ROOT
REPARSE = 0x400
COMPRESSED = 0x800
SPARSE = 0x200
MIN_SIZE = 32 * 1024 * 1024


def checked_path(path, root=STORE):
    """Reject links at every component, including an externally redirected root."""
    path, root = Path(os.path.abspath(path)), Path(os.path.abspath(root))
    if not path.is_relative_to(root) or path == root:
        raise ValueError(f"Outside symbol store: {path}")
    for part in (path, *path.parents):
        if part.lstat().st_file_attributes & REPARSE:
            raise ValueError(f"Reparse point is not an archive file: {part}")
    if path.suffix.lower() != ".dbg" or not path.is_file():
        raise ValueError(f"Not a symbol file: {path}")
    if path.stat().st_nlink != 1:
        raise ValueError(f"Shared hard link left unchanged: {path}")
    return path


def allocated_bytes(path):
    # Unlike st_size, this accounts for NTFS and WOF/LZX compression. Windows
    # reports ordinary uncompressed file length, not cluster slack, through this
    # API; report this as allocated file data, not a whole-volume accounting.
    api = ctypes.WinDLL("kernel32", use_last_error=True).GetCompressedFileSizeW
    api.argtypes = [ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_uint32)]
    api.restype = ctypes.c_uint32
    high = ctypes.c_uint32()
    ctypes.set_last_error(0)
    low = api(str(path), ctypes.byref(high))
    if low == 0xffffffff and ctypes.get_last_error():
        raise ctypes.WinError(ctypes.get_last_error())
    return (high.value << 32) | low


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def identity(stat):
    return (stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns)


def eligible(path, root=STORE):
    path = checked_path(path, root)
    stat = path.stat()
    # WOF files can be sparse without the NTFS COMPRESSED flag. Avoid inflating
    # existing compression, and never follow a symbol shared with another tree.
    return (stat.st_size >= MIN_SIZE
            and not stat.st_file_attributes & (COMPRESSED | SPARSE)
            and allocated_bytes(path) >= stat.st_size * 0.98)


def discover(root=STORE):
    found = []
    def traversal_error(error):
        raise error
    for base, dirs, files in os.walk(root, followlinks=False, onerror=traversal_error):
        dirs[:] = [d for d in dirs
                   if not (Path(base) / d).lstat().st_file_attributes & REPARSE]
        for name in files:
            if not name.lower().endswith(".dbg"):
                continue
            path = Path(base) / name
            try:
                if eligible(path, root):
                    found.append(path)
            except ValueError:
                # Shared files and links are deliberately not maintenance targets.
                continue
    return sorted(found)


def require_idle():
    # Fail closed if the process inventory is unavailable. Reading names through
    # Process avoids requesting command lines or privileged CIM access.
    script = ("$ErrorActionPreference='Stop'; @([System.Diagnostics.Process]::"
              "GetProcesses() | Where-Object { $_.ProcessName -match "
              "'^(spring|recoil)' } | Select-Object Id,ProcessName) | ConvertTo-Json -Compress")
    result = subprocess.run(["powershell.exe", "-NoProfile", "-Command", script],
                            capture_output=True, text=True, check=True)
    if json.loads(result.stdout or "[]"):
        raise RuntimeError("Stop game processes before compressing playtest symbols")


def compress_one(path):
    path = checked_path(path)
    if not eligible(path):
        return {"path": str(path.relative_to(ROOT)), "status": "skipped"}
    start = time.monotonic()
    before = path.stat()
    old_size = allocated_bytes(path)
    old_hash = digest(path)
    if identity(before) != identity(path.stat()):
        raise RuntimeError(f"File changed during initial hashing: {path}")
    result = subprocess.run(["compact.exe", "/C", "/Q", "/EXE:LZX", str(path)],
                            capture_output=True, text=True)
    # Check content even if compact reports an error; retain the evidence record
    # before the caller stops subsequent work. Never delete the original on error.
    new_hash = digest(path)
    after = path.stat()
    verified = old_hash == new_hash and identity(before) == identity(after)
    return {"path": str(path.relative_to(ROOT)),
            "status": "verified" if result.returncode == 0 and verified else "failed",
            "logical_bytes": before.st_size, "before_bytes": old_size,
            "after_bytes": allocated_bytes(path), "sha256_before": old_hash,
            "sha256_after": new_hash, "mtime_ns": after.st_mtime_ns,
            "seconds": round(time.monotonic() - start, 3),
            "exit_code": result.returncode, "output": result.stdout,
            "error": result.stderr}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="perform verified compression")
    parser.add_argument("--workers", type=int, choices=range(1, 5), default=2)
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("This maintenance tool requires Windows compression APIs")
    require_idle()
    candidates = discover()
    before_bytes = sum(allocated_bytes(p) for p in candidates)
    print(json.dumps({"eligible_files": len(candidates), "before_GiB": before_bytes / 2**30,
                      "mode": "apply" if args.apply else "dry-run"}), flush=True)
    if not args.apply:
        return
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    report_dir = STORE / "storage-audit" / stamp
    report_dir.mkdir(parents=True, exist_ok=False)
    (report_dir / "plan.json").write_text(json.dumps({
        "root": str(STORE), "algorithm": "LZX", "workers": args.workers,
        "files": [str(p.relative_to(ROOT)) for p in candidates]}, indent=2))
    results = []
    started = time.monotonic()
    print(f"REPORT {report_dir}", flush=True)
    with (report_dir / "results.jsonl").open("x", encoding="utf-8") as log:
        # Submit one bounded batch at a time so an error does not leave hundreds
        # of queued mutations, and games launched during maintenance stop it.
        with ThreadPoolExecutor(max_workers=args.workers) as pool:
            for offset in range(0, len(candidates), args.workers):
                require_idle()
                batch = candidates[offset:offset + args.workers]
                futures = [pool.submit(compress_one, p) for p in batch]
                failed = False
                for path, future in zip(batch, futures):
                    try:
                        result = future.result()
                    except Exception as error:
                        result = {"path": str(path), "status": "failed", "error": str(error)}
                    log.write(json.dumps(result) + "\n")
                    log.flush()
                    results.append(result)
                    failed |= result["status"] == "failed"
                saved = sum(r.get("before_bytes", 0) - r.get("after_bytes", 0) for r in results)
                print(f"Verified {len(results)}/{len(candidates)}; reclaimed {saved / 2**30:.2f} GiB", flush=True)
                if failed:
                    raise RuntimeError(f"Verification failed; see {report_dir}")
    summary = {"files": len(results), "verified": sum(r["status"] == "verified" for r in results),
               "saved_bytes": saved if results else 0,
               "seconds": round(time.monotonic() - started, 3)}
    (report_dir / "summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary), flush=True)


if __name__ == "__main__":
    main()
