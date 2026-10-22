"""Replay-only naval opening survey in an isolated write directory."""
import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path
import playtest
import storage


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('replay', type=Path)
    args = parser.parse_args()
    replay = args.replay.resolve()
    directory = storage.allocate('sea', 'combat', 'opening-replay',
                                 'glacial' if 'Glacial' in replay.name else 'supreme', 'regression')
    widgets = directory / 'LuaUI/Widgets'
    widgets.mkdir(parents=True)
    source = playtest.HERE / 'widgets/sea_opening_replay.lua'
    (widgets / source.name).write_bytes(source.read_bytes())
    (directory / 'springsettings.cfg').write_text(
        'SpringData = '+str(playtest.BAR_DATA)+'\nLuaUI = 1\nThreadPinPolicy = 0\nLogFlush = 1\n')
    engine = playtest.engine_dir('recoil_2026.07.04')
    (directory/'replay.json').write_text(json.dumps({'source':str(replay),
        'sha256':hashlib.sha256(replay.read_bytes()).hexdigest(),'engine':str(engine)},indent=2))
    print('REPLAY_DIR='+str(directory),flush=True)
    process = subprocess.Popen([str(engine/'spring-headless.exe'),'--write-dir',str(directory),str(replay)],
        cwd=engine,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        result = process.wait(timeout=600)
    except subprocess.TimeoutExpired:
        process.terminate()
        process.wait(timeout=30)
        raise
    lines=(directory/'infolog.txt').read_text(errors='replace').splitlines()
    evidence=[line for line in lines if '[SeaOpeningReplay]' in line]
    (directory/'opening-evidence.txt').write_text('\n'.join(evidence)+'\n')
    print('\n'.join(evidence),flush=True)
    return int(result!=0 or not any('[SeaOpeningReplay] complete' in line for line in evidence))


if __name__=='__main__':
    sys.exit(main())

