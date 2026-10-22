"""Fixed idle-constructor populations: isolate census scaling from diverging battles."""
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
    p.add_argument('--revised',type=Path,default=playtest.REPO/'data')
    a=p.parse_args();results=[]
    call=[sys.executable,str(playtest.HERE/'playtest.py')]
    for revision,data in [('baseline',a.baseline),('revised',a.revised)]:
        root=storage.allocate('air','performance','wf-scale-'+revision,'supreme','supplied')
        starts=root/'starts.as'
        starts.write_text('StartSpot(AIFloat3(2155,0,11747), AiRole::AIR, false),\n'
                          'StartSpot(AIFloat3(11456,0,1901), AiRole::SUPPORT, false),\n')
        subprocess.run(call+['stage','--dir',str(root),'--dll',str(a.dll),'--data',str(data),
            '--map','Supreme Isthmus v1.7','--map-file',str(starts),'--role','AIR','--roles','all',
            '--side','armada','--game','Beyond All Reason test-31479-433a460','--engine','recoil_2026.07.04',
            '--minutes','11','--speed','30','--shots','','--lean-render','--width','1280','--height','720',
            '--modoption','deathmode=neverend','--ai-option','profile=experimental_hard',
            '--ai-option','random_seed=1815001',
            '--extra-widget',str(playtest.HERE/'widgets/workforce_perf_watch.lua'),
            '--extra-widget',str(playtest.HERE/'widgets/workforce_scaling.lua')],check=True)
        scripts=root/'AI/Skirmish/BARbTest/test/script/src'
        for name,manager,descriptor in [('builder','aiBuilderMgr','TaskB::Wait(3600 * SECOND)'),
                                        ('factory','aiFactoryMgr','TaskS::Wait(false, 3600 * SECOND)')]:
            path=scripts/'manager'/(name+'.as');text=path.read_text()
            at=text.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)');brace=text.index('{',at)
            path.write_text(text[:brace+1]+'\n if (ai.frame >= 0) return '+manager+'.Enqueue('+descriptor+');\n'+text[brace+1:])
        storage.write_json(root/'scaling-fixture.json',dict(revision=revision,seed=1815001,
            populations=[100,500,1000],idle_only=True,projects=0,production_frozen=True,provided_factory=True,
            scope='aggregate AI callback time; fixed idle units, not active-project census timing'))
        subprocess.run([sys.executable,str(playtest.HERE/'prepare_air_check.py'),'--dir',str(root),
            '--scenario','natural','--seed','1815001'],check=True)
        subprocess.run([sys.executable,str(playtest.REPO/'tools/knowledge/check_script_api.py'),'--dll',str(a.dll)],check=True)
        subprocess.run(call+['launch','--dir',str(root),'--engine','recoil_2026.07.04'],check=True)
        code=subprocess.call(call+['watch','--dir',str(root),'--role','AIR','--checks','air_workforce_scaling',
            '--minutes','11','--wall-minutes','15','--keep-going'])
        results.append(dict(directory=str(root),exit=code))
        storage.write_json(RAW_ROOT / 'workforce-scaling.json',results)
    return any(r['exit'] for r in results)


if __name__=='__main__':raise SystemExit(main())
