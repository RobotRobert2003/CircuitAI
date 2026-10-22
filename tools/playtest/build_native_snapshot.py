"""Build a pinned BARb source snapshot against an existing read-only Recoil wrapper.

Writes only a new benchmark validation directory. Does not configure or build
inside the reference engine checkout and does not deploy to a game install.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

from benchmark_store import VALIDATION_ROOT, require_checkout


def restore_source_times(source, cached, newest_object):
    """Content checks decide reuse; source mtimes alone cannot establish it."""
    changed_time=max(time.time(),newest_object+1)
    counts={'changed':0,'reused':0}
    for path in (source/'src').rglob('*'):
        if not path.is_file():continue
        prior=cached/'source'/path.relative_to(source)
        identical=prior.is_file() and hashlib.sha256(path.read_bytes()).digest()==hashlib.sha256(prior.read_bytes()).digest()
        # A file can be edited and restored byte-for-byte after the previous
        # build. Keep its proven snapshot timestamp so Ninja does not rebuild
        # every consumer of an unchanged header. Changed older files are still
        # forced newer than every imported object, preventing stale binaries.
        stamp=prior.stat().st_mtime if identical else changed_time
        os.utime(path,(stamp,stamp))
        counts['reused' if identical else 'changed']+=1
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--session', required=True)
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--stage-only', action='store_true', help='Pin sources and build command without starting the compiler')
    parser.add_argument('--reuse', type=Path, help='Copy an earlier immutable object cache; ninja still validates source/header timestamps and commands')
    args = parser.parse_args()
    require_checkout()
    repo = Path(__file__).resolve().parents[2]
    engine = repo.parent / 'bar-RecoilEngine'
    reference = engine / 'build-amd64-windows'
    destination = (VALIDATION_ROOT / args.session).resolve()
    if not destination.is_relative_to(VALIDATION_ROOT.resolve()) or destination == VALIDATION_ROOT.resolve():
        raise ValueError('Build destination must be a named validation subdirectory')
    destination.mkdir(parents=True, exist_ok=False)
    source = destination / 'source'
    for name in ('src', 'data'):
        shutil.copytree(repo / name, source / name)
    for name in ('CMakeLists.txt', 'VERSION'):
        shutil.copy2(repo / name, source / name)
    ninja = (reference / 'build.ninja').read_text()
    blocks = re.findall(r'^build ([^\n]+): CXX_COMPILER__BARb_unscanned_RELWITHDEBINFO ([^\n]+)\n((?:  [^\n]*\n)+)', ninja, re.M)
    if not blocks:
        raise ValueError('No BARb compilation rules in the reference build')
    output = [
        'rule cxx',
        '  command = /usr/bin/x86_64-w64-mingw32-g++-posix $DEFINES $INCLUDES $FLAGS -MD -MF $out.d -o $out -c $in',
        '  depfile = $out.d', '  deps = gcc',
        'rule link',
        '  command = /usr/bin/x86_64-w64-mingw32-g++-posix $FLAGS -shared -o $out $in $LIBRARIES',
        'rule symbols',
        '  command = x86_64-w64-mingw32-objcopy --only-keep-debug SkirmishAI.full.dll SkirmishAI.dbg && x86_64-w64-mingw32-strip --strip-debug --strip-unneeded -o SkirmishAI.dll SkirmishAI.full.dll && x86_64-w64-mingw32-objcopy --add-gnu-debuglink=SkirmishAI.dbg SkirmishAI.dll',
    ]
    objects = []
    compiled_sources = set()
    native_variables = None
    for object_path, inputs, variables in blocks:
        source_path = inputs.split(' || ')[0]
        compiled_sources.add(source_path)
        if '/AI/Skirmish/BARb/src/circuit/' in source_path:
            native_variables = variables
        local = f'objects/{len(objects):03d}.obj'
        objects.append(local)
        output.append(f'build {local}: cxx {source_path}')
        for key in ('DEFINES', 'INCLUDES', 'FLAGS'):
            match = re.search(r'^  ' + key + r' = (.*)$', variables, re.M)
            if match is None:
                raise ValueError(f'Missing {key}: {object_path}')
            output.append(f'  {key} = {match[1]}')
    # The reference build is read-only and its generated source list can lag
    # new CircuitAI files. Reuse its native flags, never its source inventory.
    prefix = '/build/src/AI/Skirmish/BARb/'
    for path in sorted((source / 'src/circuit').rglob('*.cpp')):
        source_path = prefix + path.relative_to(source).as_posix()
        if source_path in compiled_sources:
            continue
        if native_variables is None:
            raise ValueError('No native CircuitAI compilation flags in reference')
        local = f'objects/{len(objects):03d}.obj'
        objects.append(local)
        output.append(f'build {local}: cxx {source_path}')
        for key in ('DEFINES', 'INCLUDES', 'FLAGS'):
            match = re.search(r'^  ' + key + r' = (.*)$', native_variables, re.M)
            output.append(f'  {key} = {match[1]}')
    link = re.search(r'^build AI/Skirmish/BARb/data/SkirmishAI.dll: [^\n]+\n((?:  [^\n]*\n)+)', ninja, re.M)[1]
    flags = re.search(r'^  LINK_FLAGS = (.*)$', link, re.M)[1]
    libraries = re.search(r'^  LINK_LIBRARIES = (.*)$', link, re.M)[1]
    libraries = libraries.replace('AI/Wrappers/', '/build/out/AI/Wrappers/')
    output += [f'build SkirmishAI.full.dll: link {" ".join(objects)}',
               f'  FLAGS = {flags}', f'  LIBRARIES = {libraries}',
               'build SkirmishAI.dll SkirmishAI.dbg: symbols SkirmishAI.full.dll',
               'default SkirmishAI.dll']
    (destination / 'objects').mkdir()
    if args.reuse:
        cached = args.reuse.resolve()
        if not (cached/'build.ninja').is_file():
            raise ValueError('Reuse source is not a snapshot build')
        shutil.copytree(cached/'objects', destination/'objects', dirs_exist_ok=True)
        for name in ('.ninja_deps', '.ninja_log'):
            if (cached/name).is_file(): shutil.copy2(cached/name,destination/name)
        # Snapshot B may be edited before snapshot A's compiler finishes. Its
        # changed files can therefore be older than A's objects. Timestamp-only
        # reuse is unsound: compare source content before importing that cache.
        newest=max((p.stat().st_mtime for p in (destination/'objects').glob('*.obj')),default=0)
        print('SOURCE_REUSE='+json.dumps(restore_source_times(source,cached,newest)),flush=True)
    (destination / 'build.ninja').write_text('\n'.join(output) + '\n')
    image = 'ghcr.io/beyond-all-reason/recoil-build-amd64-windows:latest'
    command = ['docker', 'run', '--rm', '-v', f'{engine.as_posix()}:/build/src:ro',
               '-v', f'{source.as_posix()}:/build/src/AI/Skirmish/BARb:ro',
               '-v', f'{reference.as_posix()}:/build/out:ro',
               '-v', f'{destination.as_posix()}:/work', '-w', '/work',
               '--entrypoint', 'ninja', image, '-j', str(max(1, args.jobs))]
    print('BUILD_DIRECTORY=' + str(destination), flush=True)
    if args.stage_only:
        (destination / 'build-plan.json').write_text(json.dumps({'command': command, 'objects': len(objects)}, indent=2) + '\n')
        print('STAGED_ONLY', flush=True)
        return 0
    with (destination / 'build.log').open('w') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    metadata = {'command': command, 'exit_code': result.returncode, 'objects': len(objects),
                'reference_ninja_sha256': hashlib.sha256(ninja.encode()).hexdigest()}
    if result.returncode == 0:
        metadata['sha256'] = {name: hashlib.sha256((destination / name).read_bytes()).hexdigest()
                              for name in ('SkirmishAI.dll', 'SkirmishAI.dbg')}
        shutil.copytree(source / 'data', destination / 'data')
    (destination / 'build.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(json.dumps(metadata), flush=True)
    return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
