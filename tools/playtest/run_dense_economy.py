"""Physical dense economy / naval support acceptance, in isolated staged data."""
from script_settings import role_settings_path, role_script_path
import argparse, hashlib, json, re, shutil, subprocess, sys
from pathlib import Path
import playtest, storage
from air_arena import lua

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--case',choices=['air','sea','support'],required=True)
    p.add_argument('--dll',type=Path,required=True)
    p.add_argument('--data',type=Path,default=playtest.REPO/'data')
    p.add_argument('--minutes',type=int,default=8)
    p.add_argument('--game',default='Beyond All Reason test-31536-188afa8')
    p.add_argument('--profile',default='experimental_balanced')
    a=p.parse_args(); role='AIR' if a.case=='air' else 'SEA'
    d=storage.allocate(role.lower(),'layout','dense-'+a.case,'glacial','supplied',seed=1901)
    print('DENSE_DIRECTORY='+str(d),flush=True)
    starts=d/'starts.as'
    start=(1800,1650) if role=='AIR' else (1450,3700)
    starts.write_text(f'StartSpot(AIFloat3({start[0]},0,{start[1]}), AiRole::{role}, false),\nStartSpot(AIFloat3(7000,0,6500), AiRole::{role}, false),\n')
    call=[sys.executable,str(playtest.HERE/'playtest.py')]
    subprocess.run(call+['stage','--dir',str(d),'--dll',str(a.dll),'--data',str(a.data),'--map','Glacial Gap v1.1','--map-file',str(starts),
        '--game',a.game,'--engine','recoil_2026.07.04','--role',role,'--roles','all','--ally-spots','1',
        '--side','armada','--bonus','0','--ai-option','profile='+a.profile,'--ai-option','random_seed=1901',
        '--speed','15','--minutes',str(a.minutes),'--shots','2,5,7','--width','1280','--height','720','--lean-render',
        '--modoption','deathmode=neverend','--modoption','startmetal=100000','--modoption','startmetalstorage=100000',
        '--modoption','startenergy=1000000','--modoption','startenergystorage=1000000',
        '--extra-widget',str(playtest.HERE/'widgets/dense_economy_watch.lua')],check=True)
    staged=d/'AI/Skirmish/BARbTest/test/script'; src=staged/'src'
    g=role_settings_path(src, 'Sea');before,sea=g.read_text().split('namespace Sea {',1)
    sea=re.sub(r'bool ExperimentalBuild = (?:true|false);','bool ExperimentalBuild = true;',sea,count=1)
    g.write_text(before+'namespace Sea {'+sea)
    probe=(playtest.HERE/'dense_economy_probe.as').read_text().replace('bool supportCase=false;',f'bool supportCase={str(a.case=="support").lower()};')
    (src/'roles/dense_economy_probe.as').write_text(probe)
    for name,method in [('builder','MakeTask'),('factory','Produce')]:
        f=src/'manager'/f'{name}.as';s=f.read_text();b=s.index('{',s.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))
        f.write_text('#include "../roles/dense_economy_probe.as"\n'+s[:b+1]+f'\n if (ai.frame>=0) return DenseProbe::{method}(u);\n'+s[b+1:])
    f=role_script_path(src, role.lower()+'_build');s=f.read_text();b=s.index('{',s.index('void Tick()'))
    f.write_text(s[:b+1]+'\n DenseProbe::Tick();\n'+s[b+1:])
    f=src/'setup.as';s=f.read_text();f.write_text(s.replace('Global::AISettings::Role = derivedRole;',f'derivedRole=AiRole::{role};\nGlobal::AISettings::Role = derivedRole;'))
    case_path=playtest.HERE/'cases'/('air/layout/dense-converters.json' if a.case=='air' else 'sea/layout/dense-economy.json' if a.case=='sea' else 'sea/layout/dense-support.json')
    cfg=json.loads(case_path.read_text())
    (d/'LuaUI/Config').mkdir(parents=True,exist_ok=True)
    (d/'LuaUI/Config/dense_economy.lua').write_text('return '+lua(cfg)+'\n')
    checks=json.loads((playtest.HERE/'checks'/case_path.relative_to(playtest.HERE/'cases')).read_text())
    checks['stop_minute']=a.minutes
    for check in checks['expect']: check['by_minute']=a.minutes
    checks_path=d/'dense-checks.json';checks_path.write_text(json.dumps(checks,indent=2))
    (d/'dense-fixture.json').write_text(json.dumps({'case':a.case,'supplied_resources':True,'overrides':['builders run fixture work','factories recruit fixed products in support case','role forced','SEA experimental enabled'],**cfg},indent=2))
    (d/'dense-pins.json').write_text(json.dumps({'dll_sha256':hashlib.sha256(a.dll.read_bytes()).hexdigest(),
        'data':{str(f.relative_to(staged.parent)):hashlib.sha256(f.read_bytes()).hexdigest() for f in staged.parent.rglob('*') if f.is_file()},
        'probe_sha256':hashlib.sha256(probe.encode()).hexdigest(),
        'observer_sha256':hashlib.sha256((playtest.HERE/'widgets/dense_economy_watch.lua').read_bytes()).hexdigest()},indent=2))
    subprocess.run([sys.executable,str(playtest.REPO/'tools/knowledge/check_script_api.py'),'--dll',str(a.dll),'--scripts',str(staged)],check=True)
    subprocess.run(call+['launch','--dir',str(d),'--engine','recoil_2026.07.04'],check=True)
    result=subprocess.run(call+['watch','--dir',str(d),'--role',role,'--checks',str(checks_path),'--minutes',str(a.minutes),'--wall-minutes','15','--keep-going']).returncode
    archives=list((d/'runs').iterdir())
    if len(archives)==1:
        for name in ('dense-fixture.json','dense-pins.json'):
            shutil.copy2(d/name,archives[0]/name)
    return result

if __name__=='__main__':sys.exit(main())
