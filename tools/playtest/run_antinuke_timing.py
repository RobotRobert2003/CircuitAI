"""SMRTBARb at +50: natural or explicitly supplied antinuke-versus-nuke timing."""
import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dir', required=True)
    p.add_argument('--dll', required=True)
    p.add_argument('--data', type=Path, default=ROOT/'data')
    p.add_argument('--role', choices=['TECH', 'AIR'], default='TECH')
    p.add_argument('--side', choices=['armada','cortex','legion'], default='armada')
    p.add_argument('--minutes', type=float, default=20)
    p.add_argument('--map', default='Supreme Isthmus v1.7')
    p.add_argument('--objective', default='afus', choices=['afus','fusion','eco','t2'])
    p.add_argument('--stage-only', action='store_true')
    p.add_argument('--diagnostic', action='store_true', help='retain unmet timing deadlines and observe through the full horizon')
    p.add_argument('--supplied-income', action='store_true', help='All That Glitters only: supply defender income and enemy scouts; suppress AIR ground raids')
    a=p.parse_args()
    if a.supplied_income and a.map!='All That Glitters v3.0': p.error('Supplied economy positions require All That Glitters v3.0')
    d=Path(a.dir).resolve(); d.mkdir(parents=True,exist_ok=True)
    # Use the real role starts; only remove unused slots from runner selection.
    from playtest import map_spots, running_pids
    map_source=ROOT/'data/script/src/maps/supreme_isthmus_v1_7.as' if a.map=='Supreme Isthmus v1.7' else None
    spots=map_spots(a.map,map_source)
    west=next(s for s in spots[:len(spots)//2] if s[2]==a.role)
    east=next(s for s in spots[len(spots)//2:] if s[2]=='TECH')
    x,z=west[:2]; ex,ez=east[:2]
    mapfile=d/'selection.as'
    mapfile.write_text(f'StartSpot(AIFloat3({x},0,{z}), AiRole::{a.role}, false),\nStartSpot(AIFloat3({ex},0,{ez}), AiRole::TECH, false)\n')
    check=d/'checks.json'
    check.write_text(json.dumps({'stop_minute':a.minutes,'expect':[
        {'key':'pad','pattern':r'\['+a.role+r'\]\[AntiNuke\] reserved slot=', 'by_minute':2,'scope':'tech'},
        {'key':'anti frame','pattern':r'\[AntiNukeTest\] created kind=anti team=0 ', 'by_minute':12,'scope':'any'},
        {'key':'anti finished','pattern':r'\[AntiNukeTest\] finished kind=anti team=0 ', 'by_minute':14,'scope':'any'},
        {'key':'anti armed','pattern':r'\[AntiNukeTest\] stock kind=anti team=0 .*count=[1-9]', 'by_minute':15,'scope':'any'},
        {'key':'nano reach','pattern':r'\[AntiNukeTest\] PASS nano range ', 'by_minute':14,'scope':'any'},
        {'key':'nuke launch','pattern':r'\[AntiNukeTest\] projectile kind=silo team=1 ', 'by_minute':a.minutes,'scope':'any'}],
        'forbid':[{'key':'script','pattern':r': ERR\s+:|SCRIPT CRASH|Lib exception','scope':'any'},
            {'key':'policy or reach','pattern':r'\[AntiNukeTest\] FAIL ', 'scope':'any'}]},indent=2))
    cmd=[sys.executable,str(HERE/'playtest.py')]
    stage=cmd+['stage','--dir',str(d),'--dll',a.dll,'--data',str(a.data),'--map',a.map,
        '--map-file',str(mapfile),'--role',a.role,'--roles','TECH,AIR','--side',a.side,'--bonus-all','50',
        '--modoption','ai_incomemultiplier=1','--modoption','dynamiccheats=0','--modoption','deathmode=neverend',
        '--ai-option','profile=experimental_balanced','--ai-option','random_seed=22901',
        '--set',f'RushObjective="{a.objective}"','--speed','20','--minutes',str(a.minutes),'--headless','--lean-render',
        '--extra-widget',str(HERE/'widgets/antinuke_timing_watch.lua')]
    if a.supplied_income:
        stage+=['--extra-widget',str(HERE/'widgets/antinuke_income_fixture.lua'),
            '--set','Air.T1OpeningRaidEnabled=false']
    subprocess.run(stage,cwd=ROOT,check=True)
    if a.supplied_income:
        (d/'LuaUI/Config').mkdir(parents=True,exist_ok=True)
        (d/'LuaUI/Config/antinuke_fixture.lua').write_text('return {side="'+a.side+'"}\n')
        production=d/'AI/Skirmish/BARbTest/test/script/src/systems/air/air_production.as'
        s=production.read_text(); marker='CCircuitDef@ d = ai.GetCircuitDef(name);'
        if s.count(marker)!=1: raise ValueError('Recruit hook changed')
        s=s.replace(marker,marker+'\n        // Supplied timing fixture: preserve workers/scouts/fighters, suppress ground raids.\n'
            '        if (d !is null && d.GetBuildSpeed() <= 0.0f && name != "armpeep" && name != "corfink" && name != "legow"\n'
            '            && name != "armfig" && name != "corveng" && name != "legfig"\n'
            '            && name != "armhawk" && name != "corvamp" && name != "legvenator") return null;')
        production.write_text(s)
    chain=d/'AI/Skirmish/BARbTest/test/script/src/roles/tech/tech_chain.as'
    s=chain.read_text(); marker='objective = requestedObjective.length() > 0 ? requestedObjective : Global::RoleSettings::Tech::RushObjective;'
    if s.count(marker)!=1: raise ValueError('Rush objective hook changed')
    chain.write_text(s.replace(marker,marker+'\n        if (ai.teamId == 1) objective = "nuke";'))
    script=d/'script.txt'; s=script.read_text()
    s=s.replace('[GAME]\n{','[GAME]\n{\n FixedRNGSeed=22901;',1)
    script.write_text(s)
    staged_root=d/'AI/Skirmish/BARbTest/test'
    hashes={str(path.relative_to(staged_root)):hashlib.sha256(path.read_bytes()).hexdigest()
        for path in staged_root.rglob('*') if path.is_file() and path.suffix in {'.as','.json','.dll'}}
    (d/'scenario.json').write_text(json.dumps({'arguments':{k:str(v) if isinstance(v,Path) else v for k,v in vars(a).items()},
        'supplied_income':a.supplied_income,'supplied_enemy_scouts':a.supplied_income,
        'ground_raids_suppressed':a.supplied_income,'staged_hashes':hashes},indent=2))
    if a.stage_only: return 0
    watch=cmd+['watch','--dir',str(d),'--role',a.role,'--checks',str(check),
        '--minutes',str(a.minutes),'--wall-minutes','20']
    if a.diagnostic: watch.append('--keep-going')
    try:
        subprocess.run(cmd+['launch','--dir',str(d),'--headless'],cwd=ROOT,check=True)
        return subprocess.run(watch,cwd=ROOT).returncode
    finally:
        if running_pids(d):
            subprocess.run(cmd+['stop','--dir',str(d)],cwd=ROOT,check=False)

if __name__=='__main__':
    raise SystemExit(main())
