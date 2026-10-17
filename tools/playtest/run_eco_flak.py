"""Supplied physical TECH perimeter/flak checks; no timing claims."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import playtest
import storage
from run_retirement_regression import inject_entry

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll',type=Path,required=True)
    p.add_argument('--data',type=Path,required=True)
    p.add_argument('--side',choices=['armada','cortex','legion'],default='armada')
    p.add_argument('--profile',default='experimental_balanced')
    p.add_argument('--visual',action='store_true')
    p.add_argument('--compact',action='store_true',help='Use the real compact bank planner on Coastlines Dry')
    args=p.parse_args()
    enabled=args.profile=='experimental_balanced'
    map_key='coastlines' if args.compact else 'supreme'
    map_name='Coastlines_Dry_V2.2.1' if args.compact else 'Supreme Isthmus v1.7'
    x,z=(9106,2986) if args.compact else (1600,10100)
    directory=storage.allocate('tech','economy','eco-flak-'+args.side,map_key,'supplied',seed=3211)
    print('ECO_FLAK_DIRECTORY='+str(directory),flush=True)
    starts=directory/'starts.as'
    enemy=(845,3320) if args.compact else (10000,2000)
    starts.write_text(f'StartSpot(AIFloat3({x},0,{z}), AiRole::TECH, false),\nStartSpot(AIFloat3({enemy[0]},0,{enemy[1]}), AiRole::FRONT, false),\n')
    call=[sys.executable,str(playtest.HERE/'playtest.py')]
    stage=call+['stage','--dir',str(directory),'--dll',str(args.dll),'--data',str(args.data),
        '--map',map_name,'--map-file',str(starts),'--role','TECH','--roles','all','--ally-spots','1',
        '--engine','recoil_2026.07.04','--side',args.side,
        '--ai-option','profile='+args.profile,'--ai-option','random_seed=3211','--bonus','0',
        '--mode','visual' if args.visual else 'fast','--speed','20','--minutes','12',
        '--shots',f'3@2400@{x}:{z}' if args.visual else '', '--lean-render',
        '--modoption','deathmode=neverend','--modoption','experimentallegionfaction=1',
        '--modoption','startmetal=100000','--modoption','startmetalstorage=1000000',
        '--modoption','startenergy=1000000','--modoption','startenergystorage=1000000',
        '--extra-widget',str(playtest.HERE/'widgets/eco_flak_watch.lua')]
    if not args.visual: stage.append('--headless')
    subprocess.run(stage,check=True)
    source=directory/'AI/Skirmish/BARbTest/test/script/src'
    setup=source/'setup.as'
    setup.write_text(setup.read_text().replace('Global::AISettings::Role = derivedRole;',
        'derivedRole=ai.teamId==0?AiRole::TECH:AiRole::FRONT; Global::AISettings::Role = derivedRole;'))
    fixture=(playtest.HERE/'fixtures/eco_flak_probe.as').read_text().replace('__SIDE__',args.side).replace('__ENABLED__',str(enabled).lower()).replace('__COMPACT__',str(args.compact).lower())
    fixture=fixture.replace('1600',str(x)).replace('10100',str(z))
    (source/'eco_flak_probe.as').write_text(fixture)
    profile=source.parent/args.profile/'main.as'
    profile.write_text('#include "../src/eco_flak_probe.as"\n'+profile.read_text())
    inject_entry(profile,'void AiLuaMessage(const string& in data)','if (EcoFlakProbe::Handle(data)) return;')
    inject_entry(profile,'void AiUpdate()','EcoFlakProbe::Tick();')
    inject_entry(source/'roles/tech/tech.as','void Tech_EconomyUpdate()','if (ai.frame>=0) return;')
    inject_entry(source/'manager/builder.as','IUnitTask@ AiMakeTask(CCircuitUnit@ u)','if (ai.frame>=0) return EcoFlakProbe::Task(u);')
    inject_entry(source/'manager/factory.as','IUnitTask@ AiMakeTask(CCircuitUnit@ u)','if (ai.frame>=0) return aiFactoryMgr.Enqueue(TaskS::Wait(false,SECOND));')
    inject_entry(source/'manager/military.as','IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
        'if (ai.frame>=0) { CRouteTask@ route=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route())); '
        'array<AIFloat3> points={u.GetPos(ai.frame)}; route.SetTraversal(true,48,false); route.SetRoute(points); return route; }')
    inject_entry(source/'systems/diagnostics/invariants.as','void Tick()','if (ai.frame>=0) return;')
    widget=directory/'LuaUI/Widgets/eco_flak_watch.lua'
    widget_source=widget.read_text().replace('__SIDE__',args.side).replace('__ENABLED__',str(enabled).lower())
    for old,new in [('1500',x-100),('1600',x),('1700',x+100),('1400',x-200),('10200',z+100),('10100',z),('10000',z-100),('10400',z+300)]:
        widget_source=widget_source.replace(old,str(new))
    widget.write_text(widget_source)
    complete=r'\[EcoFlakTest\] PASS '+('all waves' if enabled else 'disabled profile')
    checks={'stop_minute':12,'complete_on':{'key':'complete','pattern':complete,'scope':'any'},'completion_grace_seconds':5,
        'expect':[{'key':s,'pattern':r'\[EcoFlakTest\] PASS '+s,'scope':'any','by_minute':12} for s in
            ['default policy','geometry registered','profile gate','missing geometry rejected','no pre-AFUS construction']+
            (['first AFUS minimum','order cooldown','physical order outside economy','air escalation','cap held','destroyed flak rebuilt','all waves'] if enabled else ['disabled profile'])+
            (['compact economy unchanged'] if enabled and args.compact else [])],
        'forbid':[{'key':'failure','pattern':r'\[EcoFlakTest\] FAIL|\[INVARIANT\]|: ERR\s+:|SCRIPT CRASH|Lib exception|Access violation|has crashed|Fatal:|Error in.*eco_flak|\[GiveUnits\].*not a valid object-name','scope':'any'}]}
    check=directory/'eco-flak-checks.json';check.write_text(json.dumps(checks,indent=2))
    (directory/'eco-flak-inputs.json').write_text(json.dumps({'side':args.side,'profile':args.profile,'map':map_name,'compact':args.compact,'cap':3,
        'overrides':['real compact bank planner' if args.compact else 'supplied economy envelope','six supplied constructors and AFUS','cap 3; default 1 minimum/30-second cooldown','other builders and combat held','whole-base geometry invariants disabled for supplied envelope'],
        'scripts':{str(x.relative_to(directory)):storage.file_hash(x) for x in source.parent.rglob('*.as')},'widget':storage.file_hash(widget)},indent=2))
    try:
        subprocess.run(call+['launch','--dir',str(directory),'--engine','recoil_2026.07.04']+([] if args.visual else ['--headless']),check=True)
        return subprocess.call(call+['watch','--dir',str(directory),'--role','TECH','--minutes','12','--wall-minutes','10','--checks',str(check)])
    finally: subprocess.run(call+['stop','--dir',str(directory)],check=False)

if __name__=='__main__': sys.exit(main())
