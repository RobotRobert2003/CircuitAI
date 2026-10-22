"""Stage connected-mountain regressions; never changes the live install."""
import argparse, subprocess, sys
from pathlib import Path
from benchmark_store import RAW_ROOT
import scorecard
ROOT=scorecard.ROOT
MAPS={'supreme':'Supreme Isthmus v1.7','glacial':'Glacial Gap v1.1','ascendancy':'Ascendancy v2.2'}
def main():
    p=argparse.ArgumentParser();p.add_argument('--map',choices=MAPS,required=True);p.add_argument('--dir',required=True);p.add_argument('--dll',required=True);p.add_argument('--side',default='legion');p.add_argument('--survey-only',action='store_true');a=p.parse_args()
    directory=Path(a.dir).resolve()
    if not directory.is_relative_to(RAW_ROOT): raise ValueError('Use an isolated build-theatres directory')
    command=[sys.executable,str(ROOT/'tools/playtest/playtest.py'),'stage','--dir',str(directory),'--dll',a.dll,'--map',MAPS[a.map],'--game','Beyond All Reason test-31450-6562fb1','--engine','recoil_2026.07.04','--roles','all' if a.survey_only else 'TECH','--side',a.side,'--headless','--shots','','--speed','12','--minutes','6' if a.survey_only else '35','--ai-option','profile=experimental_balanced','--modoption','experimentallegionfaction=1','--modoption','experimentalextraunits=0','--modoption','scavunitsforplayers=0']
    for widget in ['lane_benchmark_watch','scorecard_metrics','mountain_regression_watch']+([] if a.survey_only else ['flank_economy_fixture','flank_effectiveness']): command+=['--extra-widget',str(ROOT/'tools/playtest/widgets'/f'{widget}.lua')]
    if a.map=='ascendancy': command+=['--map-file',str(ROOT/'tools/playtest/fixtures/ascendancy.as')]
    subprocess.run(command,cwd=ROOT,check=True)
    overrides=[]
    if a.map=='ascendancy':
        path=directory/'AI/Skirmish/BARbTest/test/script/src/setup.as';s=path.read_text(encoding='utf-8');old='AiRole defaultRole = RoleHelpers::DefaultRoleForFactory(defaultFactoryName);';assert s.count(old)==1;path.write_text(s.replace(old,'AiRole defaultRole = AiRole::TECH;'),encoding='utf-8',newline='\n');overrides.append('Staged unknown-map fallback TECH role')
    scorecard.capture(directory,{'benchmark':'connected-mountain','minutes_limit':6 if a.survey_only else 35,'headless':True,'speed':12,'income_fixture':not a.survey_only,'role_overrides':overrides})
    print(directory)
if __name__=='__main__': main()
