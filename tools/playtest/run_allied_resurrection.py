"""Actual allied AI and human-command protection, plus cancellation release."""
import argparse,json,re,subprocess,sys
from pathlib import Path
import playtest,storage

def main():
    p=argparse.ArgumentParser();p.add_argument('--dll',type=Path,required=True);p.add_argument('--human',action='store_true');a=p.parse_args()
    d=storage.allocate('sea','reliability','allied-rez-human' if a.human else 'allied-rez-ai','supreme','supplied')
    starts=d/'starts.as';starts.write_text('StartSpot(AIFloat3(5800,0,10500),AiRole::SEA,false),\nStartSpot(AIFloat3(11500,0,7500),AiRole::SEA,false)')
    cli=[sys.executable,str(playtest.HERE/'playtest.py')]
    subprocess.run(cli+['stage','--dir',str(d),'--dll',str(a.dll),'--data',str(playtest.REPO/'data'),'--map','Supreme Isthmus v1.7','--map-file',str(starts),'--roles','all','--role','SEA','--side','armada','--bonus','0','--game','Beyond All Reason test-31536-188afa8','--engine','recoil_2026.07.04','--ai-option','profile=experimental_balanced','--ai-option','cheating=false','--modoption','deathmode=neverend','--modoption','startmetal=0','--modoption','startenergy=1000000','--modoption','startenergystorage=1000000','--speed','10','--minutes','2','--shots','0.8@2200@6200:10700,1.5@2200@6200:10700','--lean-render','--extra-widget',str(playtest.HERE/'widgets/allied_resurrection_watch.lua')]+(['--extra-widget',str(playtest.REPO/'tools/widgets/gui_barb_resurrection_claims.lua')] if a.human else []),check=True)
    path=d/'script.txt';s=path.read_text()
    if a.human:
        s=s.replace('Spectator=1; Team=2;','Spectator=0; Team=2;').replace('[TEAM2] { AllyTeam=2;','[TEAM2] { AllyTeam=0;')
    else:
        s=re.sub(r'(\[TEAM1\]\s*\{\s*AllyTeam=)1;',r'\g<1>0;',s)
    path.write_text(s)
    src=d/'AI/Skirmish/BARbTest/test/script/src'
    for manager in ('builder','factory'):
        path=src/'manager'/f'{manager}.as';s=path.read_text();i=s.index('{',s.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))
        line='if (!SeaRecovery::IsSub(u.circuitDef)) return aiBuilderMgr.Enqueue(TaskB::Wait(60*SECOND));' if manager=='builder' else 'if (ai.frame>=0) return aiFactoryMgr.Enqueue(TaskS::Wait(false,60*SECOND));'
        path.write_text(s[:i+1]+'\n'+line+'\n'+s[i+1:])
    path=src/'settings/roles/sea.as';s=path.read_text();path.write_text(s.replace('bool FleetOperations = true;', 'bool FleetOperations = false;'))
    path=src/'manager/military.as';s=path.read_text();i=s.index('{',s.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))
    path.write_text(s[:i+1]+'\n if (ai.frame>=0) { CRouteTask@ hold=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route())); array<AIFloat3> stay={u.GetPos(ai.frame)}; hold.SetHoldPosition(true); hold.SetPatrol(true); hold.SetRoute(stay); return hold; }\n'+s[i+1:])
    if not a.human:
        path=src/'systems/sea/sea_recovery.as';s=path.read_text();s=s.replace('if (Protected(u)) return','if (ai.teamId==1) return aiBuilderMgr.FindRecoveryTask(u,2,24000,null);\n        if (Protected(u)) return',1);path.write_text(s)
    (d/'LuaUI/Config').mkdir(parents=True,exist_ok=True)
    (d/'LuaUI/Config/allied_resurrection.lua').write_text('return {human='+str(a.human).lower()+'}')
    storage.write_json(d/'checks.json',{'stop_minute':2,'expect':[{'key':v,'pattern':'AlliedResurrectionTest\\] PASS '+v,'scope':'any','by_minute':2} for v in ('protected','released')],'forbid':[{'key':'errors','pattern':'AlliedResurrectionTest\\] FAIL|SCRIPT CRASH|: ERR\\s+:|\\[INVARIANT\\]','scope':'any'}]})
    print('ALLIED_RECOVERY='+str(d),flush=True)
    subprocess.run(cli+['launch','--dir',str(d),'--engine','recoil_2026.07.04'],check=True)
    return subprocess.call(cli+['watch','--dir',str(d),'--checks',str(d/'checks.json'),'--minutes','2','--role','SEA','--wall-minutes','10','--keep-going'])
if __name__=='__main__':raise SystemExit(main())
