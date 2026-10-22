"""Natural-economy Thug integration games: no supplied units or tactical orders.

The two small matches use declared FRONT start locations. The 8v8 games use
the production map rosters. This runner observes naturally produced Thugs;
it does not supply an army, income or engagement orders. --bot-opening is an
explicit targeted integration option: team 0 starts with a T1 bot factory,
then uses ordinary production weights and economy. The pin records this.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

import playtest
import storage
from air_arena import lua
from ranged_arena import pool_symbols

MAPS = {
    'comet': ('Comet Catcher Remake 1.8', [(4000,1800),(4000,5000)], (4000,3400)),
    'glitters': ('All That Glitters v2.2.3', [(3061,1967),(3212,8249)], (3100,5000)),
    'supreme': ('Supreme Isthmus v1.7', None, (6100,6200)),
    'glacial': ('Glacial Gap v1.1', None, (7600,2800)),
}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--map',choices=MAPS,required=True)
    p.add_argument('--dll',type=Path,required=True)
    p.add_argument('--data',type=Path,required=True)
    p.add_argument('--minutes',type=int,default=30)
    p.add_argument('--seed',type=int,default=2071)
    p.add_argument('--profile',default='experimental_balanced')
    p.add_argument('--bot-opening',action='store_true',help='Targeted integration: select corlab as team 0 FRONT opener; resources and subsequent production remain ordinary')
    a=p.parse_args()
    name,starts,focus=MAPS[a.map]
    directory=storage.allocate('shared','combat','thug-natural',a.map,'natural',seed=a.seed)
    print('THUG_NATURAL='+str(directory),flush=True)
    extra=[]
    if starts:
        path=directory/'starts.as'
        path.write_text('\n'.join(f'StartSpot(AIFloat3({x},0,{z}),AiRole::FRONT,false),' for x,z in starts))
        extra=['--map-file',str(path),'--ally-spots','1']
    cli=[sys.executable,str(playtest.HERE/'playtest.py')]
    cmd=cli+['stage','--dir',str(directory),'--dll',str(a.dll),'--data',str(a.data),
        '--map',name,*extra,'--game','Beyond All Reason test-31479-433a460',
        '--engine','recoil_2026.07.04','--role','FRONT','--roles','all','--side','cortex',
        '--bonus','0','--ai-option','profile='+a.profile,'--ai-option','random_seed='+str(a.seed),
        '--modoption','deathmode=com','--minutes',str(a.minutes),'--speed','16',
        '--shots',','.join(f'{t}@2500@{focus[0]}:{focus[1]}' for t in [5,10,15,25]),
        '--width','1280','--height','720','--lean-render']
    for widget in ['ranged_arena.lua','workforce_perf_watch.lua','perf_spectator_cleanup.lua','full_match_perf.lua']:
        cmd+=['--extra-widget',str(playtest.HERE/'widgets'/widget)]
    subprocess.run(cmd,check=True)
    staged=directory/'AI/Skirmish/BARbTest/test'
    pool_symbols(staged)
    if a.bot_opening:
        path=staged/'script/src/helpers/construction/factory_helpers.as';source=path.read_text()
        needle='string SelectStartFactoryForRole(AiRole role, const string &in side)'
        start=source.index('{',source.index(needle))+1
        path.write_text(source[:start]+'\n if (ai.teamId==0 && role==AiRole::FRONT && side=="cortex") return "corlab"; // declared integration opener\n'+source[start:])
    if a.map=='comet':
        # Comet has no production start/role map. Register the fixture's actual
        # starts, not a forced role in AiMakeTask or an artificial build order.
        fixture='namespace ThugComet { StartSpot@[] spots={'+','.join(
            f'StartSpot(AIFloat3({x},0,{z}),AiRole::FRONT,false)' for x,z in starts)+\
            '}; dictionary limits; MapConfig config=MapConfig("Comet Catcher Remake",limits,spots,null); }\n'
        (staged/'script/src/maps/thug_comet.as').write_text(fixture)
        path=staged/'script/src/maps.as';source=path.read_text()
        needle='void registerMaps() {';assert source.count(needle)==1
        path.write_text('#include "maps/thug_comet.as"\n'+source.replace(needle,needle+'\n mapManager.RegisterMapConfig(ThugComet::config);'))
    script=directory/'script.txt'
    script.write_text(script.read_text().replace('[GAME]\n{','[GAME]\n{\n FixedRNGSeed='+str(a.seed)+';',1))
    cfg=directory/'LuaUI/Config';cfg.mkdir(exist_ok=True)
    arena=dict(name='thug-natural-'+a.map,unit='corthud',variant='ranged',natural=True,
        groups=[],photos=[],seed=a.seed,minutes=a.minutes,speed=16,starts=[list(s) for s in starts] if starts else [],
        trace_orders=False,command_breakdown=True)
    (cfg/'ranged_arena.lua').write_text('return '+lua(arena)+'\n')
    (directory/'ranged-arena.json').write_text(json.dumps(arena,indent=2)+'\n')
    (cfg/'full_match_perf.lua').write_text('return '+lua(dict(x=focus[0],z=focus[1],height=2500,teams=2 if starts else 16))+'\n')
    (cfg/'perf_spectator_cleanup.lua').write_text('return '+lua(dict(teams=2 if starts else 16))+'\n')
    checks=json.loads((playtest.HERE/'checks/shared/combat/thug-natural.json').read_text())
    checks['stop_minute']=a.minutes
    (directory/'checks.json').write_text(json.dumps(checks,indent=2)+'\n')
    (directory/'thug-natural-pins.json').write_text(json.dumps(dict(map=name,seed=a.seed,
        profile=a.profile,minutes=a.minutes,ordinary_resources=True,supplied_units=False,
        opening_factory_override='corlab' if a.bot_opening else None,production_weight_overrides=False,dll_sha256=storage.file_hash(a.dll),
        staged_map_registration=a.map=='comet',
        data_hashes={str(f.relative_to(staged)):storage.file_hash(f) for f in staged.rglob('*')
            if f.suffix in ('.as','.json','.lua')},observer_sha256=storage.file_hash(playtest.HERE/'widgets/ranged_arena.lua')),indent=2)+'\n')
    subprocess.run([sys.executable,str(playtest.REPO/'tools/knowledge/check_script_api.py'),
        '--dll',str(a.dll),'--scripts',str(staged/'script')],check=True)
    subprocess.run(cli+['launch','--dir',str(directory),'--engine','recoil_2026.07.04'],
        env={**os.environ,'CIRCUIT_PERF_PHASES':'1'},check=True)
    return subprocess.run(cli+['watch','--dir',str(directory),'--role','FRONT',
        '--checks',str(directory/'checks.json'),'--minutes',str(a.minutes),
        '--wall-minutes','45','--keep-going']).returncode


if __name__=='__main__':sys.exit(main())
