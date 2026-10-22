"""Supplied physical delivery fixtures, separate from natural rush economy games."""
import argparse
from pathlib import Path
import subprocess
import sys
import json
import re
import os
import playtest
import storage
from run_retirement_regression import inject_entry


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll',type=Path,required=True)
    parser.add_argument('--side',choices=('armada','cortex','legion'),default='cortex')
    parser.add_argument('--mode',choices=('flight','walk','mex','local','request','constructor'),default='flight')
    parser.add_argument('--game',default='Beyond All Reason test-31578-8247b61')
    parser.add_argument('--profile',default='experimental_balanced')
    args=parser.parse_args()
    minutes = 10 if args.mode in ('local', 'request') else 5
    label='cons' if args.mode=='constructor' else args.mode
    directory=storage.allocate('tech','economy','delivery-'+label+'-'+args.side,'supreme','supplied')
    print('DELIVERY_DIRECTORY='+str(directory),flush=True)
    # Standard map positions, reduced population. Team 2 is the closer FRONT;
    # team 3 is closer to TECH but farther from the actual front.
    mapfile=directory/'fixture-map.as'
    mapfile.write_text('''StartSpot@[] spots = {
StartSpot(AIFloat3(837,0,10407), AiRole::TECH, false),
StartSpot(AIFloat3(2155,0,11747), AiRole::AIR, false),
StartSpot(AIFloat3(4595,0,7440), AiRole::FRONT, false),
StartSpot(AIFloat3(2513,0,7983), AiRole::FRONT, false),
StartSpot(AIFloat3(11456,0,1901), AiRole::TECH, false)
};''')
    command=[sys.executable,str(playtest.HERE/'playtest.py')]
    subprocess.run(command+['stage','--dir',str(directory),'--dll',str(args.dll),
        '--map','Supreme Isthmus v1.7','--map-file',str(mapfile),'--ally-spots','1,2,3,4','--game',args.game,
        '--role','TECH','--roles','TECH,FRONT,AIR','--side',args.side,'--ai-option','profile='+args.profile,
        '--speed','10','--minutes',str(minutes),'--bonus','0','--shots','0.8@2200@1400:10000,1.6@3000@2900:8700,3@2400@4595:7440,4.5@2400@4595:7440',
        '--lean-render','--modoption','deathmode=neverend','--modoption','startmetal=100000',
        '--modoption','startmetalstorage=100000','--modoption','startenergy=1000000',
        '--modoption','startenergystorage=1000000','--extra-widget',str(playtest.HERE/'widgets/heavy_delivery_fixture.lua')],check=True)
    source=directory/'AI/Skirmish/BARbTest/test/script/src'
    (source/'heavy_delivery_probe.as').write_bytes((playtest.HERE/'fixtures/heavy_delivery_probe.as').read_bytes())
    profile=source.parent/args.profile/'main.as'
    profile.write_text('#include "../src/heavy_delivery_probe.as"\n'+profile.read_text())
    inject_entry(profile,'void AiLuaMessage(const string& in data)','if (HeavyDeliveryProbe::Handle(data)) return;')
    # Deliberately isolate logistics from the natural economy acceptance game.
    # Keep the real ferry/pool/factory callbacks; prevent supplied banks from
    # starting unrelated layout/spam projects after the delivery has finished.
    inject_entry(source/'roles/tech/tech.as','void Tech_EconomyUpdate()',
        'if (HeavyDeliveryProbe::active && ai.teamId == 0) { TechHeavyRush::Tick(); return; }')
    widget=directory/'LuaUI/Widgets/heavy_delivery_fixture.lua'
    widget.write_text(widget.read_text().replace('__MODE__',args.mode).replace('__SIDE__',args.side)
        .replace('frame==8700', 'frame=='+str(minutes*1800-300)))
    checks=directory/'delivery-checks.json'
    check=json.loads((playtest.HERE/'checks/tech/logistics/heavy-delivery.json').read_text())
    check['stop_minute']=minutes
    check['expect'][0]['by_minute']=minutes
    checks.write_text(json.dumps(check,indent=2))
    subprocess.run(command+['launch','--dir',str(directory)],check=True,
        env={**os.environ,'CIRCUIT_PERF_PHASES':'1'})
    result=subprocess.run(command+['watch','--dir',str(directory),'--role','TECH','--minutes',str(minutes),
        '--wall-minutes','10','--keep-going','--checks',str(checks)])
    log=(directory/'infolog.txt').read_text(errors='replace')
    summary=dict(directory=str(directory),mode=args.mode,side=args.side,watch_exit=result.returncode,
        deliveries=re.findall(r'\[HeavyDeliveryTest\] PASS given .*',log),
        failures=re.findall(r'.*(?:\[HeavyDeliveryTest\] FAIL|: ERR\s+:|SCRIPT CRASH).*',log),
        final=re.findall(r'\[HeavyDeliveryTest\] (?:PASS|FAIL) final .*',log))
    (directory/'delivery-result.json').write_text(json.dumps(summary,indent=2))
    print(json.dumps(summary,indent=2))
    return 0 if len(summary['deliveries'])==3 and not summary['failures'] and result.returncode==0 else 1

if __name__=='__main__': sys.exit(main())
