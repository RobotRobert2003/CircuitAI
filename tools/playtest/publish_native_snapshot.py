"""Publish a verified snapshot to the required development output, never live BAR."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
DESTINATION = ROOT.parent / 'bar-RecoilEngine/build-amd64-windows/install/AI/Skirmish/BARb/stable'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pin', required=True, type=Path)
    args = parser.parse_args()
    pin = args.pin.resolve()
    metadata = json.loads((pin/'build.json').read_text())
    if metadata['exit_code'] != 0:
        raise ValueError('Cannot publish a failed build')
    for name in ('SkirmishAI.dll', 'SkirmishAI.dbg'):
        actual = hashlib.sha256((pin/name).read_bytes()).hexdigest()
        if actual != metadata['sha256'][name]:
            raise ValueError('Build hash mismatch: '+name)
    data = pin/'data'
    subprocess.run([sys.executable,str(ROOT/'tools/knowledge/check_script_api.py'),
        '--dll',str(pin/'SkirmishAI.dll'),'--scripts',str(data/'script')],check=True)
    DESTINATION.mkdir(parents=True,exist_ok=True)
    # Only remove data that a previous publication explicitly owned. Never
    # recursively delete this engine output or follow a deployment symlink.
    manifest=DESTINATION/'circuit-data-manifest.json'
    files=sorted(str(p.relative_to(data)).replace('\\','/') for p in data.rglob('*') if p.is_file())
    previous=json.loads(manifest.read_text()) if manifest.exists() else []
    for relative in sorted(set(previous)-set(files)):
        stale=DESTINATION/relative
        if not stale.resolve().is_relative_to(DESTINATION.resolve()) or stale.is_symlink():
            raise ValueError('Unsafe stale publication path: '+relative)
        if stale.is_file(): stale.unlink()
    shutil.copytree(data,DESTINATION,dirs_exist_ok=True)
    for name in ('SkirmishAI.dll','SkirmishAI.dbg'):
        shutil.copy2(pin/name,DESTINATION/name)
    subprocess.run([sys.executable,str(ROOT/'tools/knowledge/check_script_api.py'),
        '--dll',str(DESTINATION/'SkirmishAI.dll'),'--scripts',str(DESTINATION/'script')],check=True)
    manifest.write_text(json.dumps(files,indent=2)+'\n')
    (pin/'publication.json').write_text(json.dumps({'destination':str(DESTINATION),
        'sha256':metadata['sha256']},indent=2)+'\n')
    print('PUBLISHED='+str(DESTINATION))

if __name__=='__main__': main()
