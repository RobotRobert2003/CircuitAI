"""Cross-role reservation probes or supplied three-SEA placement on Glacial."""
import argparse, json, shutil, subprocess, sys
from pathlib import Path
import playtest, storage

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll',type=Path,required=True)
    parser.add_argument('--supplied',action='store_true')
    args=parser.parse_args()
    scenario='allied-bases-supplied' if args.supplied else 'allied-bases-mixed'
    map_key='glacial' if args.supplied else 'supreme'
    map_name='Glacial Gap v1.1' if args.supplied else 'Supreme Isthmus v1.7'
    minutes=15 if args.supplied else 6
    shots='3@3500@1500:4600,6@3500@1500:4600,10@3500@1500:4600,14@3500@1500:4600' if args.supplied else '3,5.8'
    d=storage.allocate('sea','layout',scenario,map_key,'supplied' if args.supplied else 'regression',seed=1921)
    print('SEA_BASE_DIRECTORY='+str(d),flush=True)
    call=[sys.executable,str(playtest.HERE/'playtest.py')]
    cmd=call+['stage','--dir',str(d),'--dll',str(args.dll),'--data',str(playtest.REPO/'data'),
        '--map',map_name,'--engine','recoil_2026.07.04',
        '--role','SEA','--roles','SEA' if args.supplied else 'SEA,AIR,TECH','--side','armada','--bonus','0',
        '--ai-option','profile=experimental_hard','--ai-option','random_seed=1921','--speed','15','--minutes',str(minutes),
        '--shots',shots,
        '--width','1280','--height','720','--lean-render','--modoption','deathmode=neverend',
        '--extra-widget',str(playtest.HERE/'widgets/sea_allied_base_watch.lua')]
    if args.supplied:
        for k,v in [('startmetal',100000),('startmetalstorage',100000),('startenergy',1000000),('startenergystorage',1000000)]:
            cmd+=['--modoption',f'{k}={v}']
    subprocess.run(cmd,check=True)
    scripts=d/'AI/Skirmish/BARbTest/test/script'
    probe=(playtest.HERE/'sea_allied_base_probe.as').read_text().replace('namespace SeaBaseProbe {','namespace SeaBaseProbe {\n const bool SUPPLIED='+str(args.supplied).lower()+';')
    for profile in ['experimental_hard','experimental_balanced','experimental_terrible']:
        f=scripts/profile/'main.as';s=f.read_text()
        s=s.replace('ArtilleryPolicy::Check();','ArtilleryPolicy::Check();\n        SeaBaseProbe::Tick();',1)
        s=s.replace('Team::HandleMessage(msg, fromTeamId);','Team::HandleMessage(msg, fromTeamId);\n        SeaBaseProbe::Message(msg);',1)
        f.write_text(s+'\n'+probe)
    if args.supplied:
        for name,statement in [('builder','return SeaBaseProbe::MakeTask(u);'),('factory','return aiFactoryMgr.Enqueue(TaskS::Wait(false,SECOND));')]:
            f=scripts/'src/manager'/f'{name}.as';s=f.read_text();i=s.index('{',s.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))
            f.write_text(s[:i+1]+'\n if (ai.frame>=30*SECOND && Global::AISettings::Role==AiRole::SEA) '+statement+'\n'+s[i+1:])
    (d/'LuaUI/Config').mkdir(parents=True,exist_ok=True)
    # Lua reads a simple literal rather than relying on an optional JSON widget.
    from air_arena import lua
    (d/'LuaUI/Config/sea_base.lua').write_text('return '+lua({'supplied':args.supplied,'teams':json.loads((d/'teams.json').read_text())['teams']})+'\n')
    (d/'base-source.json').write_text(json.dumps({str(f.relative_to(scripts.parent)):storage.file_hash(f) for f in scripts.parent.rglob('*') if f.is_file()},indent=2))
    subprocess.run([sys.executable,str(playtest.REPO/'tools/knowledge/check_script_api.py'),'--dll',str(args.dll),'--scripts',str(scripts)],check=True)
    subprocess.run(call+['launch','--dir',str(d),'--engine','recoil_2026.07.04'],check=True)
    rc=subprocess.run(call+['watch','--dir',str(d),'--role','SEA','--checks','sea/layout/'+scenario+'.json','--minutes',str(minutes),'--wall-minutes','15','--keep-going']).returncode
    for archive in (d/'runs').iterdir():shutil.copy2(d/'base-source.json',archive/'base-source.json')
    return rc

if __name__=='__main__':sys.exit(main())
