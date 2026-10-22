"""Zero-bonus TECH T3 strategy integration; no supplied economy or task probes."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import playtest
import storage


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', type=Path, required=True)
    parser.add_argument('--side', choices=('armada', 'cortex', 'legion'), default='cortex')
    parser.add_argument('--minutes', type=float, default=35)
    args = parser.parse_args()
    directory = storage.allocate('tech', 'economy', 'gantry-natural-'+args.side, 'supreme', 'natural')
    print('GANTRY_DIRECTORY='+str(directory), flush=True)
    call = [sys.executable, str(playtest.HERE/'playtest.py')]
    subprocess.run(call+['stage', '--dir', str(directory), '--dll', str(args.dll),
        '--map', 'Supreme Isthmus v1.7', '--role', 'TECH', '--roles', 'TECH,FRONT,AIR', '--side', args.side,
        '--ai-option', 'profile=experimental_balanced', '--bonus', '0', '--speed', '20', '--minutes', str(args.minutes),
        '--shots', '10,15,20,25,30', '--lean-render', '--modoption', 'deathmode=neverend',
        '--extra-widget', str(playtest.HERE/'widgets/gantry_fixture.lua')], check=True)
    profile = directory/'AI/Skirmish/BARbTest/test/script/experimental_balanced/main.as'
    content=profile.read_text()
    for key,value in {'Tech_Spam_Rush':'0.0f','Tech_T2_RUSH':'0.0f','Tech_T3_RUSH':'1.0f','Tech_NUKE_RUSH':'0.0f'}.items():
        content,count=re.subn(r'(float\s+'+key+r'\s*=\s*)[0-9.]+f', r'\g<1>'+value, content)
        if count != 1:
            raise ValueError('Missing unique strategy probability: '+key)
    profile.write_text(content)
    widget=directory/'LuaUI/Widgets/gantry_fixture.lua'
    widget.write_text(widget.read_text().replace('__MODE__','natural').replace('__SIDE__',args.side))
    checks=directory/'gantry-checks.json'
    checks.write_text(json.dumps({'stop_minute':args.minutes,'expect':[
        {'key':'gantry completed', 'pattern':r'\[GantryTest\] PASS physical gantry completed', 'by_minute':args.minutes, 'scope':'any'}],
        'forbid':[{'key':'script failure', 'pattern':r'\[INVARIANT\]|: ERR\s+:|SCRIPT CRASH|Lib exception', 'scope':'any'}]}, indent=2))
    subprocess.run(call+['launch','--dir',str(directory)],check=True)
    return subprocess.run(call+['watch','--dir',str(directory),'--role','TECH','--minutes',str(args.minutes),
        '--wall-minutes','15','--keep-going','--checks',str(checks)]).returncode


if __name__ == '__main__':
    sys.exit(main())
