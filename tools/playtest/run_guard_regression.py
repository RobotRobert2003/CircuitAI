"""Serial native GUARD regression: supplied recovery fixture or ordinary SEA."""
from script_settings import role_script_path
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import playtest
import storage


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll',type=Path,required=True)
    p.add_argument('--label',required=True)
    p.add_argument('--fixture',action='store_true')
    p.add_argument('--expect-suppression',action='store_true')
    p.add_argument('--minutes',type=int,default=10)
    a=p.parse_args()
    d=storage.allocate('shared','performance','guard-'+a.label,'supreme' if a.fixture else 'glacial','supplied' if a.fixture else 'benchmark',seed=2231)
    print('GUARD_DIRECTORY='+str(d),flush=True)
    call=[sys.executable,str(playtest.HERE/'playtest.py')]
    stage=call+['stage','--dir',str(d),'--dll',str(a.dll),'--data',str(playtest.REPO/'data'),
        '--map','Supreme Isthmus v1.7' if a.fixture else 'Glacial Gap v1.1',
        '--game','Beyond All Reason test-31479-433a460','--engine','recoil_2026.07.04',
        '--role','SEA','--roles','SEA','--side','armada','--bonus','0',
        '--ai-option','profile=experimental_balanced','--ai-option','random_seed=2231',
        '--speed','10','--minutes',str(a.minutes),'--width','1280','--height','720','--lean-render',
        '--shots','1@2600@6150:10800,3@2600@6150:10800,4@2600@6150:10800' if a.fixture else '3@2800@1450:4350,6@3200@1450:4350,9@3200@1450:4350',
        '--extra-widget',str(playtest.HERE/'widgets/guard_watch.lua')]
    if a.fixture:
        stage+=['--modoption','deathmode=neverend','--modoption','startmetal=100000','--modoption','startmetalstorage=100000',
                '--modoption','startenergy=1000000','--modoption','startenergystorage=1000000']
    subprocess.run(stage,check=True)
    src=d/'AI/Skirmish/BARbTest/test/script/src'
    if a.fixture:
        (src/'guard_probe.as').write_bytes((playtest.HERE/'guard_probe.as').read_bytes())
        mainfile=src.parent/'experimental_balanced/main.as'
        text=mainfile.read_text()
        needle='void AiLuaMessage(const string& in data)'
        at=text.index('{',text.index(needle))
        mainfile.write_text('#include "../src/guard_probe.as"\n'+text[:at+1]+'\n if (GuardProbe::Handle(data)) return;\n'+text[at+1:])
        # SEA intentionally releases guards from idle constructors/factories.
        # Fixture-owned native tasks must not compete with that role policy.
        # Natural tests retain it unchanged, including ordinary guard cleanup.
        sea=role_script_path(src, 'sea_build');text=sea.read_text()
        needle='CCircuitUnit@ target=ai.GetTeamUnit(t.GetGuardTargetId());'
        assert text.count(needle)==1
        sea.write_text(text.replace(needle,'if (GuardProbe::Owns(u.id)) continue;\n            '+needle))
        # Builders wait for fixture tasks; real native guard Execute/idle/path
        # and factory production still run. Opponent cannot disrupt the setup.
        b=src/'manager/builder.as';text=b.read_text();at=text.index('{',text.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))
        b.write_text(text[:at+1]+'\n if (ai.teamId>=0) return aiBuilderMgr.Enqueue(TaskB::Wait(SECOND));\n'+text[at+1:])
        f=src/'manager/factory.as';text=f.read_text();at=text.index('{',text.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))
        f.write_text(text[:at+1]+'\n if (ai.teamId!=0) return aiFactoryMgr.Enqueue(TaskS::Wait(false,SECOND));\n'+text[at+1:])
    (d/'LuaUI/Config').mkdir(parents=True,exist_ok=True)
    (d/'LuaUI/Config/guard_test.lua').write_text('return {fixture='+str(a.fixture).lower()+',expect_suppression='+str(a.expect_suppression).lower()+'}\n')
    script=d/'script.txt';script.write_text(script.read_text().replace('[GAME]\n{','[GAME]\n{\n FixedRNGSeed=2231;',1))
    (d/'guard-pins.json').write_text(json.dumps({'label':a.label,'fixture':a.fixture,'minutes':a.minutes,
        'dll_sha256':hashlib.sha256(a.dll.read_bytes()).hexdigest(),
        'data':{str(f.relative_to(src.parent.parent)):hashlib.sha256(f.read_bytes()).hexdigest() for f in src.parent.parent.rglob('*') if f.is_file() and f.suffix in ('.as','.json','.lua')}},indent=2))
    subprocess.run(['compact.exe','/C','/EXE:LZX','/I','/Q',str(src.parent.parent/'SkirmishAI.dbg')],check=False)
    subprocess.run([sys.executable,str(playtest.REPO/'tools/knowledge/check_script_api.py'),'--dll',str(a.dll),'--scripts',str(src.parent)],check=True)
    env=dict(os.environ,CIRCUIT_VERIFY_GUARD='1')
    subprocess.run(call+['launch','--dir',str(d),'--engine','recoil_2026.07.04'],env=env,check=True)
    checks='shared/performance/guard-fixture.json' if a.fixture else 'shared/performance/guard-natural.json'
    return subprocess.run(call+['watch','--dir',str(d),'--role','SEA','--checks',checks,'--minutes',str(a.minutes),'--wall-minutes','15','--keep-going']).returncode


if __name__=='__main__':
    sys.exit(main())
