"""Supreme Isthmus physical economy-block acceptance, using real placement tasks."""
from script_settings import role_settings_path, role_script_path
import argparse, hashlib, json, re, shutil, subprocess, sys
from pathlib import Path
import playtest, storage
from air_arena import lua

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll',type=Path,required=True)
    p.add_argument('--experimental',action='store_true')
    a=p.parse_args()
    d=storage.allocate('sea','layout','economy-block-exp' if a.experimental else 'economy-block','supreme','supplied',seed=1911)
    print('SEA_BLOCK_DIRECTORY='+str(d),flush=True)
    call=[sys.executable,str(playtest.HERE/'playtest.py')]
    subprocess.run(call+['stage','--dir',str(d),'--dll',str(a.dll),'--data',str(playtest.REPO/'data'),
        '--map','Supreme Isthmus v1.7','--engine','recoil_2026.07.04',
        '--role','SEA','--roles','SEA','--side','armada','--bonus','0','--ai-option','profile=experimental_hard',
        '--ai-option','random_seed=1911','--speed','15','--minutes','12','--shots','3@2200@6200:11000,6@2200@6200:11000,11@2200@6200:11000',
        '--width','1280','--height','720','--lean-render','--modoption','deathmode=neverend',
        '--modoption','startmetal=100000','--modoption','startmetalstorage=100000',
        '--modoption','startenergy=1000000','--modoption','startenergystorage=1000000',
        '--extra-widget',str(playtest.HERE/'widgets/dense_economy_watch.lua'),
        '--extra-widget',str(playtest.HERE/'widgets/sea_economy_block_watch.lua')],check=True)
    src=d/'AI/Skirmish/BARbTest/test/script/src'
    g=role_settings_path(src, 'Sea');before,sea=g.read_text().split('namespace Sea {',1)
    sea=re.sub(r'bool ExperimentalBuild = (true|false);','bool ExperimentalBuild = '+str(a.experimental).lower()+';',sea,count=1)
    g.write_text(before+'namespace Sea {'+sea)
    shutil.copy2(playtest.HERE/'sea_economy_block_probe.as',src/'roles/sea_economy_block_probe.as')
    for name,method in [('builder','MakeTask'),('factory','Produce')]:
        f=src/'manager'/f'{name}.as';s=f.read_text();b=s.index('{',s.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))
        f.write_text('#include "../roles/sea_economy_block_probe.as"\n'+s[:b+1]+f'\n if (ai.frame>=0) return SeaBlockProbe::{method}(u);\n'+s[b+1:])
    f=role_script_path(src, 'sea_build');s=f.read_text();b=s.index('{',s.index('void Tick()'))
    f.write_text(s[:b+1]+'\n SeaBlockProbe::Tick();\n'+s[b+1:])
    (d/'LuaUI/Config').mkdir(parents=True,exist_ok=True)
    case=json.loads((playtest.HERE/'cases/sea/layout/economy-block.json').read_text())
    (d/'LuaUI/Config/dense_economy.lua').write_text('return '+lua(case)+'\n')
    pins={'supplied':True,'experimental':a.experimental,'dll_sha256':hashlib.sha256(a.dll.read_bytes()).hexdigest(),
        'staged_data':{str(f.relative_to(src.parent.parent)):hashlib.sha256(f.read_bytes()).hexdigest() for f in src.parent.parent.rglob('*') if f.is_file()}}
    (d/'sea-block-pins.json').write_text(json.dumps(pins,indent=2))
    subprocess.run([sys.executable,str(playtest.REPO/'tools/knowledge/check_script_api.py'),'--dll',str(a.dll),'--scripts',str(src.parent)],check=True)
    subprocess.run(call+['launch','--dir',str(d),'--engine','recoil_2026.07.04'],check=True)
    result=subprocess.run(call+['watch','--dir',str(d),'--role','SEA','--checks','sea/layout/economy-block.json','--minutes','12','--wall-minutes','15','--keep-going']).returncode
    for archive in (d/'runs').iterdir(): shutil.copy2(d/'sea-block-pins.json',archive/'sea-block-pins.json')
    return result

if __name__=='__main__': sys.exit(main())
