"""Run a reproducible TECH duel and archive its scorecard without touching BAR's install."""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from benchmark_store import RAW_ROOT

import scorecard
import storage

ROOT = scorecard.ROOT
MAPS = {'supreme': 'Supreme Isthmus v1.7', 'glacial': 'Glacial Gap v1.1', 'ascendancy': 'Ascendancy v2.2'}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('map', choices=MAPS)
    p.add_argument('--dir', help='Optional explicit directory; otherwise allocate a categorized benchmark game')
    p.add_argument('--dll', required=True)
    p.add_argument('--game', required=True)
    p.add_argument('--minutes', type=int, default=45)
    p.add_argument('--legion', choices=('on','off'), default='on')
    p.add_argument('--swap', action='store_true')
    p.add_argument('--calendar', default='2026-09-29T17', help='Pinned in-game calendar YYYY-MM-DDTHH; wall-clock timestamps are independent')
    args = p.parse_args()
    dest = Path(args.dir).resolve() if args.dir else storage.allocate(
        'tech','strategy','scorecard',args.map,'benchmark', legion=args.legion, swap=args.swap)
    # Never accept a destination inside the live install.
    if not dest.is_relative_to(RAW_ROOT):
        p.error('--dir must be inside this benchmark-repository build-theatres directory')
    tool = ROOT / 'tools/playtest/playtest.py'
    factions = ['cortex', 'legion' if args.legion == 'on' else 'armada']
    if args.swap: factions.reverse()
    stage = [sys.executable,str(tool),'stage','--dir',str(dest),'--dll',args.dll,
             '--map',MAPS[args.map],'--game',args.game,'--roles','TECH','--side',factions[0],
             '--speed','12','--minutes',str(args.minutes),'--shots','','--headless',
             '--ai-option','profile=experimental_balanced','--modoption','experimentallegionfaction='+('1' if args.legion=='on' else '0'),
             '--extra-widget',str(ROOT/'tools/playtest/widgets/scorecard_metrics.lua')]
    calendar = re.fullmatch(r'(\d{4})-(\d{2})-(\d{2})T(\d{2})',args.calendar)
    if not calendar: p.error('--calendar requires YYYY-MM-DDTHH')
    for key,value in zip(('date_year','date_month','date_day','date_hour'),calendar.groups()):
        stage += ['--modoption',key+'='+value]
    if args.map == 'ascendancy':
        stage += ['--map-file',str(ROOT/'tools/playtest/fixtures/ascendancy.as')]
    subprocess.run(stage,check=True,cwd=ROOT)
    teams = scorecard.read_json(dest/'teams.json')
    script = (dest/'script.txt').read_text()
    for t, faction in zip(teams['teams'],factions):
        t['side']=faction
        pattern=rf'(\[TEAM{t["team"]}\]\s*\{{[^}}]*?Side=)\w+(;)'
        script, count=re.subn(pattern,rf'\g<1>{faction}\2',script,flags=re.S)
        if count != 1: raise RuntimeError('Cannot identify benchmark faction slot')
    (dest/'script.txt').write_text(script)
    scorecard.write_json(dest/'teams.json',teams)
    overrides=[]
    if args.map == 'ascendancy':
        setup=dest/'AI/Skirmish/BARbTest/test/script/src/setup.as'
        old='AiRole defaultRole = RoleHelpers::DefaultRoleForFactory(defaultFactoryName);'
        text=setup.read_text()
        if text.count(old)!=1: raise RuntimeError('Ascendancy role fixture no longer matches setup')
        setup.write_text(text.replace(old,'AiRole defaultRole = AiRole::TECH;'))
        overrides.append('unknown-map fallback role forced TECH in staged setup.as')
    # Record the entire actual modoption set; don't silently copy future lobby changes
    # into an existing comparison group.
    manifest=scorecard.capture(dest,{'mode':'TECH duel','minutes_limit':args.minutes,
        'income_fixture':False,'role_overrides':overrides,'headless':True,'speed':12})
    checks={'stop_minute':args.minutes,'expect':[{'key':'observer','pattern':r'\[Scorecard\] init','scope':'any','by_minute':1}],
            'forbid':[{'key':'script','pattern':r'\.as \(.*: (ERR|WARN)|SCRIPT CRASH|Error in.*scorecard','scope':'any'},
                      {'key':'invariant','pattern':r'\[INVARIANT\]','scope':'any'}]}
    scorecard.write_json(dest/'scorecard-checks.json',checks)
    subprocess.run([sys.executable,str(tool),'launch','--dir',str(dest),'--headless'],check=True,cwd=ROOT)
    run=None
    watcher=subprocess.Popen([sys.executable,str(tool),'watch','--dir',str(dest),'--checks',str(dest/'scorecard-checks.json'),
        '--minutes',str(args.minutes),'--wall-minutes','40','--keep-going'],cwd=ROOT,
        stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,encoding='utf-8',errors='replace')
    for line in watcher.stdout:
        if '[playtest]' in line: print(line.rstrip(),flush=True)
        if '[playtest] report: ' in line: run=Path(line.split('[playtest] report: ',1)[1].strip()).parent
    watcher.wait()
    if run is None: raise RuntimeError('Watcher did not archive a report; inspect isolated process before retry')
    card=scorecard.record(dest,run)
    print('[scorecard] '+str(card),flush=True)
    print('[scorecard] index '+str(scorecard.rebuild()),flush=True)
    # A completed measurement can legitimately retain a failing gameplay report.
    return 0 if scorecard.read_json(card)['status'] != 'invalid' else 1


if __name__=='__main__': sys.exit(main())
