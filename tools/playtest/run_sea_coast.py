"""Supplied SEA loss/constructor-transfer/coastal-recovery acceptance arena."""
import argparse
import json
from pathlib import Path
from benchmark_store import RAW_ROOT
import subprocess
import sys
import playtest
import storage
from air_arena import lua
from run_sea import MAPS

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll',type=Path,required=True)
    p.add_argument('--map',choices=MAPS,default='supreme')
    p.add_argument('--side',choices=['armada','cortex','legion'],default='armada')
    p.add_argument('--mode',choices=['lost','held','retake'],default='lost')
    p.add_argument('--profile',default='experimental_balanced')
    p.add_argument('--minutes',type=float,default=14)
    p.add_argument('--game',default=None)
    p.add_argument('--stage-only',action='store_true')
    a=p.parse_args()
    d=storage.allocate('sea','strategy','coast-'+a.mode+'-'+a.side,a.map,'supplied',seed=219001)
    print('COAST_DIRECTORY='+str(d),flush=True)
    (RAW_ROOT / 'coast-current.txt').write_text(str(d))
    cli=[sys.executable,str(playtest.HERE/'playtest.py')]
    cmd=cli+['stage','--dir',str(d),'--dll',str(a.dll),'--map',MAPS[a.map],
        *(['--game',a.game] if a.game else []),'--engine','recoil_2026.07.04',
        '--role','SEA','--roles','SEA','--side',a.side,'--bonus','0','--speed','15',
        '--minutes',str(a.minutes),'--shots','3,6,10,13','--width','1280','--height','720',
        '--lean-render','--modoption','deathmode=neverend','--ai-option','profile='+a.profile,
        '--set','InvariantForwardSeconds=100000','--set','FirstFactorySeconds=100000',
        '--extra-widget',str(playtest.HERE/'widgets/sea_coast.lua')]
    subprocess.run(cmd,check=True)
    cfg={'teams':json.loads((d/'teams.json').read_text())['teams'],'side':a.side,'mode':a.mode}
    (d/'LuaUI/Config').mkdir(parents=True,exist_ok=True)
    (d/'LuaUI/Config/sea_coast.lua').write_text('return '+lua(cfg)+'\n')
    base=d/'AI/Skirmish/BARbTest/test/script'
    # Freeze unrelated production in this controlled fixture, but execute real
    # naval census, loss detector, placement, recruitment and garrison policies.
    path=base/'src/manager/builder.as';s=path.read_text()
    needle='IUnitTask@ AiMakeTask(CCircuitUnit@ u) {'
    s=s.replace(needle,needle+'\n if (ai.teamId!=0 || ai.frame<3600) return aiBuilderMgr.Enqueue(TaskB::Wait(SECOND));\n')
    path.write_text(s)
    path=base/'src/manager/factory.as';s=path.read_text()
    needle='IUnitTask@ AiMakeTask(CCircuitUnit@ u)\n\t{'
    assert needle in s
    s=s.replace(needle,needle+'\n if (ai.teamId!=0 || ai.frame<3600) return aiFactoryMgr.Enqueue(TaskS::Wait(false,SECOND));\n')
    path.write_text(s)
    path=base/'src/systems/sea/sea_coast.as';s=path.read_text()
    # Read-only telemetry sent to an unsynced observer for screenshots/assertions.
    needle='            Garrison();'
    assert s.count(needle)==1
    s=s.replace(needle,needle+'''
        if (ai.teamId==0 && Active() && ai.frame%(10*SECOND)==0) {
            ai.CallUI("coastprobe|state|"+depot.x+"|"+depot.z+"|"+sectors.length());
            for (uint i=0;i<sectors.length();++i) ai.CallUI("coastprobe|beach|"+i+"|"+sectors[i].beach.x+"|"+sectors[i].beach.z+"|"+sectors[i].sea.x+"|"+sectors[i].sea.z);
        }
''')
    path.write_text(s)
    checks=json.loads((playtest.HERE/'checks/sea/strategy/coastal-fallback.json').read_text())
    checks['stop_minute']=a.minutes
    if a.mode=='held':
        checks['expect']=[{'key':'control','pattern':'CoastFixture.*held control complete','by_minute':a.minutes,'scope':'any'}]
        checks['forbid'].append({'key':'false-loss','pattern':'SEA.*Coast.*fallback=true','scope':'any'})
    if a.mode=='retake':
        checks['expect'].append({'key':'retake','pattern':'SEA.*Coast.*fallback=false','by_minute':a.minutes,'scope':'any'})
    if a.mode=='lost' and a.minutes>=25:
        # The longer arena supplies a real amphibious wave and a capable
        # minelayer at 15 minutes. Keep these requirements out of short smoke
        # cases; archive this exact check set before launching the game.
        for key,pattern in [
            ('radar',r'finished (armrad|corrad|legrad)'),
            ('sonar-defense',r'finished (armdl|cordl|legctl)'),
            ('jammer',r'finished (armjamt|corjamt|legjam)'),
            ('fortification',r'finished (armfort|corfort|legforti)'),
            ('medium-mine',r'finished (armmine2|cormine2|legmine2)'),
            ('amphibious-response',r'invader damaged by live defense'),
        ]:
            checks['expect'].append({'key':key,'pattern':'CoastFixture.*'+pattern,
                                     'by_minute':a.minutes,'scope':'any'})
    (d/'coast-checks.json').write_text(json.dumps(checks,indent=2))
    (d/'fixture.json').write_text(json.dumps(vars(a),default=str,indent=2))
    if a.stage_only:return 0
    subprocess.run(cli+['launch','--dir',str(d),'--engine','recoil_2026.07.04'],check=True)
    return subprocess.run(cli+['watch','--dir',str(d),'--role','SEA','--checks',str(d/'coast-checks.json'),'--minutes',str(a.minutes),'--keep-going','--wall-minutes','15']).returncode

if __name__=='__main__':raise SystemExit(main())
