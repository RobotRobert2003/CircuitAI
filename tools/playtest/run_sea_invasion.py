"""Supplied SEA transition fixtures. Actual AI builds, escorts and invades."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import playtest
import storage
from air_arena import lua


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll', required=True, type=Path)
    p.add_argument('--side', choices=['armada', 'cortex', 'legion'], default='armada')
    p.add_argument('--profile', default='experimental_balanced')
    p.add_argument('--minutes', type=int, default=24)
    p.add_argument('--stage-only', action='store_true')
    p.add_argument('--blocked', action='store_true', help='Retain an enemy sub; transition must remain blocked')
    a = p.parse_args()
    label = 'amphibious-blocked' if a.blocked else 'amphibious-transition'
    d = storage.allocate('sea', 'combat', label.replace('amphibious','amphib')+'-'+a.side, 'supreme', 'supplied', seed=2121)
    starts=d/'starts.as'
    starts.write_text('StartSpot(AIFloat3(5800,0,10500), AiRole::SEA, false),\nStartSpot(AIFloat3(11456,0,1901), AiRole::SEA, false)')
    call=[sys.executable,str(playtest.HERE/'playtest.py')]
    subprocess.run(call+['stage','--dir',str(d),'--dll',str(a.dll),'--data',str(playtest.REPO/'data'),
        '--map','Supreme Isthmus v1.7','--map-file',str(starts),'--engine','recoil_2026.07.04','--role','SEA','--roles','all','--ally-spots','1','--side',a.side,
        '--speed','20','--minutes',str(a.minutes),'--shots','2@8500@8500:6500,5@6500@10800:4000,10@5500@10800:4000,16@5500@11000:2800',
        '--width','1280','--height','720','--lean-render','--bonus','0','--ai-option','profile='+a.profile,
        '--ai-option','random_seed=2121','--modoption','deathmode=neverend',
        '--modoption','startmetal=20000','--modoption','startmetalstorage=100000',
        '--modoption','startenergy=1000000','--modoption','startenergystorage=1000000',
        '--extra-widget',str(playtest.HERE/'widgets/sea_invasion_watch.lua')],check=True)
    staged=d/'AI/Skirmish/BARbTest/test/script'
    setup=staged/'src/setup.as'
    setup.write_text(setup.read_text().replace('Global::AISettings::Role = derivedRole;',
        'derivedRole=AiRole::SEA;\nGlobal::AISettings::Role = derivedRole;'))
    combat=staged/'src/systems/sea/sea_combat.as'
    combat.write_text(combat.read_text().replace('bool Active() { return Global::AISettings::Role',
        'bool Active() { return ai.teamId==0 && Global::AISettings::Role'))
    if a.blocked:
        # Keep the hostile contact alive. This negative fixture validates the
        # survey gate directly, not whether the supplied navy can win a fight.
        operations=staged/'src/systems/sea/sea_operations.as'
        operations.write_text(operations.read_text().replace('void Tick() {','void Tick() { if (ai.teamId>=0) return; // negative fixture: stationary navy\n',1))
    # The opposing player is a stationary target/known-contact fixture. Supplied
    # sensing planes stay put so coverage comes from real sensors, never globallos.
    for name,manager,wait in [('builder','aiBuilderMgr','TaskB::Wait(60*SECOND)'),
        ('factory','aiFactoryMgr','TaskS::Wait(false,60*SECOND)'),('military','aiMilitaryMgr','TaskF::Wait(60*SECOND)')]:
        f=staged/'src/manager'/(name+'.as');s=f.read_text();at=s.index('{',s.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))
        cond='ai.teamId!=0'
        if name=='military': cond+=' || u.circuitDef.GetName()=="armsehak"'
        if name=='military' and a.blocked: cond+=' || SeaFactories::CombatHull(u.circuitDef)'
        if name=='factory': cond+=' || !SeaInvasion::Factory(u.circuitDef)'
        body='return '+manager+'.Enqueue('+wait+');'
        if name=='military':
            body='CRouteTask@ hold=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route())); array<AIFloat3> stay={u.GetPos(ai.frame)}; hold.SetHoldPosition(true); hold.SetPatrol(true); hold.SetRoute(stay); return hold;'
        f.write_text(s[:at+1]+'\n if ('+cond+') { '+body+' } // supplied fixture only\n'+s[at+1:])
    cfg=dict(side=a.side,blocked=a.blocked,minutes=a.minutes)
    (d/'LuaUI/Config').mkdir(exist_ok=True,parents=True)
    (d/'LuaUI/Config/sea_invasion.lua').write_text('return '+lua(cfg)+'\n')
    (d/'invasion-pins.json').write_text(json.dumps(dict(cfg,seed=2121,profile=a.profile,
        dll_sha256=hashlib.sha256(a.dll.read_bytes()).hexdigest(),
        scripts={str(f.relative_to(staged)):hashlib.sha256(f.read_bytes()).hexdigest() for f in staged.rglob('*.as')},
        overrides=['SEA forced','opponent frozen','non-invasion factories frozen','supplied economy, workers, navy and legitimate stationary sensor aircraft','no globallos']
            +(['stationary friendly navy retains live enemy contact'] if a.blocked else [])),indent=2))
    subprocess.run([sys.executable,str(playtest.REPO/'tools/knowledge/check_script_api.py'),'--dll',str(a.dll),'--scripts',str(staged)],check=True)
    dbg=d/'AI/Skirmish/BARbTest/test/SkirmishAI.dbg'
    if dbg.exists(): subprocess.run(['compact.exe','/C','/EXE:LZX','/I',str(dbg)],check=True)
    print('SEA_INVASION='+str(d),flush=True)
    if a.stage_only: return 0
    subprocess.run(call+['launch','--dir',str(d),'--engine','recoil_2026.07.04'],check=True)
    return subprocess.call(call+['watch','--dir',str(d),'--role','SEA','--checks',label,
        '--minutes',str(a.minutes),'--wall-minutes','25','--keep-going'])


if __name__=='__main__': raise SystemExit(main())
