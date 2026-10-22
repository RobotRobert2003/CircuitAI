"""Serial paired 8v8 controls. AI timing scope is engine-wide, not per role."""
import argparse
from pathlib import Path
from benchmark_store import RAW_ROOT
import subprocess
import sys
import playtest
import storage


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll',type=Path,required=True)
    p.add_argument('--baseline',type=Path,required=True)
    p.add_argument('--revised',type=Path,required=True)
    p.add_argument('--minutes',type=int,default=30)
    a=p.parse_args()
    call=[sys.executable,str(playtest.HERE/'playtest.py')]
    results=[]
    for multi in [False,True]:
        for name,data in [('baseline',a.baseline),('revised',a.revised)]:
            root=storage.allocate('air','performance','wf-'+name+('-multi' if multi else '-one'),'supreme','natural')
            subprocess.run(call+['stage','--dir',str(root),'--dll',str(a.dll),'--data',str(data),
                '--map','Supreme Isthmus v1.7','--game','Beyond All Reason test-31479-433a460','--engine','recoil_2026.07.04',
                '--role','AIR','--roles','all','--side','armada','--minutes',str(a.minutes),'--speed','30',
                '--shots','5,15,25','--lean-render','--width','1280','--height','720',
                '--ai-option','profile=experimental_hard','--ai-option','random_seed=1814001',
                '--extra-widget',str(playtest.HERE/'widgets/workforce_perf_watch.lua'),
                '--extra-widget',str(playtest.HERE/'widgets/air_command_watch.lua')],check=True)
            if multi:
                script=root/'AI/Skirmish/BARbTest/test/script/src/setup.as'
                text=script.read_text();needle='Global::AISettings::Role = derivedRole;'
                assert text.count(needle)==1
                script.write_text(text.replace(needle,'if (derivedRole == AiRole::TACTICAL || derivedRole == AiRole::SUPPORT) derivedRole = AiRole::AIR;\n'+needle))
            storage.write_json(root/'performance-fixture.json',dict(multiple_air=multi,revision=name,seed=1814001,
                timing_scope='all engine AI callbacks per simulation frame; not per-AI/census',resources_supplied=False))
            subprocess.run([sys.executable,str(playtest.HERE/'prepare_air_check.py'),'--dir',str(root),'--scenario','natural','--seed','1814001'],check=True)
            subprocess.run([sys.executable,str(playtest.REPO/'tools/knowledge/check_script_api.py'),'--dll',str(a.dll)],check=True)
            subprocess.run(call+['launch','--dir',str(root),'--engine','recoil_2026.07.04'],check=True)
            code=subprocess.call(call+['watch','--dir',str(root),'--role','AIR','--checks','air_workforce_performance',
                '--minutes',str(a.minutes),'--wall-minutes','60','--keep-going'])
            results.append(dict(directory=str(root),exit=code))
            storage.write_json(RAW_ROOT / 'workforce-performance.json',results)
    return any(row['exit'] for row in results)


if __name__=='__main__': raise SystemExit(main())
