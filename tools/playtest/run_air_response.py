"""Isolated AIR scout-deadline and allied-base intrusion acceptance fixtures."""
import argparse, hashlib, json, shutil, subprocess, sys
from pathlib import Path
import playtest, storage
from air_arena import lua

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--case',choices=['partial','full','defense','t1','outside','small'],required=True)
    p.add_argument('--side',choices=['armada','cortex','legion'],default='armada')
    p.add_argument('--profile',default='experimental_hard')
    p.add_argument('--dll',type=Path,required=True)
    p.add_argument('--data',type=Path,default=playtest.REPO/'data')
    p.add_argument('--baseline',action='store_true')
    a=p.parse_args(); recon=a.case in ('partial','full')
    d=storage.allocate('air','combat',('old-' if a.baseline else '')+'resp-'+a.case+'-'+a.side,'supreme','supplied',seed=1931)
    print('AIR_RESPONSE_DIRECTORY='+str(d),flush=True)
    starts=d/'starts.as'
    starts.write_text('StartSpot(AIFloat3(2155,0,11747), AiRole::AIR, false),\n'
        'StartSpot(AIFloat3(837,0,10407), AiRole::FRONT, false),\n'
        'StartSpot(AIFloat3(10129,0,541), AiRole::FRONT, false),\n')
    call=[sys.executable,str(playtest.HERE/'playtest.py')]
    subprocess.run(call+['stage','--dir',str(d),'--dll',str(a.dll),'--data',str(a.data),
        '--map','Supreme Isthmus v1.7','--map-file',str(starts),'--roles','all','--role','AIR',
        '--ally-spots','1,2','--side',a.side,'--bonus','0','--ai-option','profile='+a.profile,
        '--ai-option','random_seed=1931','--game','Beyond All Reason test-31479-433a460','--engine','recoil_2026.07.04',
        '--speed','10','--minutes','7','--shots','','--width','1280','--height','720','--lean-render',
        '--modoption','deathmode=neverend','--modoption','startmetal=100000','--modoption','startmetalstorage=100000',
        '--modoption','startenergy=1000000','--modoption','startenergystorage=1000000',
        '--extra-widget',str(playtest.HERE/'widgets/air_response_watch.lua'),
        '--extra-widget',str(playtest.HERE/'widgets/air_command_watch.lua')],check=True)
    src=d/'AI/Skirmish/BARbTest/test/script'
    # The shipped Supreme table re-derives this location as TECH regardless
    # of the startscript label; use FRONT for the deliberately frozen ally.
    f=src/'src/setup.as';s=f.read_text()
    f.write_text(s.replace('Global::AISettings::Role = derivedRole;',
        'if (ai.teamId == 1) derivedRole = AiRole::FRONT;\nGlobal::AISettings::Role = derivedRole;'))
    # Freeze economic placement only. Defender factory and military decisions are real.
    f=src/'src/manager/builder.as';s=f.read_text();at=s.index('{',s.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))
    f.write_text(s[:at+1]+'\n if (ai.frame>=0) return aiBuilderMgr.Enqueue(TaskB::Wait(60*SECOND));\n'+s[at+1:])
    if recon or a.case=='small':
        f=src/'src/manager/factory.as';s=f.read_text();at=s.index('{',s.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))
        f.write_text(s[:at+1]+'\n if (ai.frame>=0) return aiFactoryMgr.Enqueue(TaskS::Wait(false,60*SECOND));\n'+s[at+1:])
    # Only fixture enemies receive a scripted approach; defender orders are unmodified.
    f=src/'src/manager/military.as';s=f.read_text();at=s.index('{',s.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))
    s=s[:at+1]+'''\n if (ai.teamId==2 && u.circuitDef.GetName()=="armmar") {
        CRouteTask@ march=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
        array<AIFloat3> points={AIFloat3(837,0,10407)};
        march.SetAirControl(true); march.SetTraversal(true,128,true); march.SetRoute(points); return march;
    }\n'''+s[at+1:]
    if a.case=='outside': s=s.replace('AIFloat3(837,0,10407)','AIFloat3(4400,0,7400)')
    f.write_text(s)
    if recon:
        probe=(playtest.HERE/'air_recon_probe.as').read_text()
        for profile in ('experimental_hard','experimental_balanced','experimental_terrible'):
            f=src/profile/'main.as';s=f.read_text();f.write_text(s.replace('ArtilleryPolicy::Check();','ArtilleryPolicy::Check(); AirReconProbe::Tick();')+'\n'+probe)
    cfg={'case':a.case,'side':a.side,'speed':10,'recon':recon}
    (d/'LuaUI/Config').mkdir(parents=True,exist_ok=True)
    (d/'LuaUI/Config/air_response.lua').write_text('return '+lua(cfg)+'\n')
    checks={'stop_minute':7,'expect':[{'key':'fixture','pattern':r'\[AirResponseWatch\] loaded','scope':'any','by_minute':1}],
        'forbid':[{'key':k,'pattern':pat,'scope':'any'} for k,pat in [
            ('script',r': ERR\s+:|SCRIPT CRASH|Lib exception'),('invariant','INVARIANT|AirOrders.*ERROR'),
            ('crash','Access violation|has crashed|Fatal:'),('widget',r'Error in.*air_response_watch|Removed widget: AIR response fixture')]]}
    expected={
        'partial':[('deadline',r'\[AIR\]\[Recon\] synchronized sweep=3 .*reason=deadline'),('survey','AirReconProbe.*surveying=3')],
        'full':[('full',r'\[AIR\]\[Recon\] synchronized sweep=20 .*reason=full')],
        'defense':[('dispatch',r'\[AIR\]\[BaseResponse\] dispatched='),('production','Produce.*base.defence'),
            ('bomber_damage',r'AirResponseWatch.*damage.*attacker=(armpnix|corhurc|legphoenix)'),('gunship_finished',r'AirResponseWatch.*finished.*def=(armbrawl|corape|legstronghold)')],
        't1':[('production','Produce.*base.defence'),('damage',r'AirResponseWatch.*damage.*attacker=(armkam|corshad|legmos)')],
        'small':[('bomber_damage',r'AirResponseWatch.*damage.*attacker=(armpnix|corhurc|legphoenix)')],
        'outside':[]}
    for key,pat in expected[a.case]: checks['expect'].append({'key':key,'pattern':pat,'scope':'any','by_minute':7})
    if a.case=='outside': checks['forbid'].append({'key':'false_emergency','pattern':r'\[AIR\]\[BaseResponse\] contact=true','scope':'any'})
    cp=d/'response-checks.json';cp.write_text(json.dumps(checks,indent=2))
    manifest={'case':cfg,'supplied_resources':True,'visibility':'ordinary radar/LOS; no globallos',
        'overrides':['economic builders frozen','frozen allied role forced FRONT','enemy Marauders march to allied base']+(['factories frozen'] if recon or a.case=='small' else []),
        'dll_sha256':hashlib.sha256(a.dll.read_bytes()).hexdigest(),
        'data':{str(f.relative_to(src.parent)):hashlib.sha256(f.read_bytes()).hexdigest() for f in src.parent.rglob('*') if f.is_file()}}
    (d/'response-manifest.json').write_text(json.dumps(manifest,indent=2))
    subprocess.run([sys.executable,str(playtest.REPO/'tools/knowledge/check_script_api.py'),'--dll',str(a.dll),'--scripts',str(src)],check=True)
    subprocess.run(call+['launch','--dir',str(d),'--engine','recoil_2026.07.04'],check=True)
    rc=subprocess.run(call+['watch','--dir',str(d),'--role','AIR','--checks',str(cp),'--minutes','7','--wall-minutes','12','--keep-going']).returncode
    archives=list((d/'runs').iterdir())
    if len(archives)==1: shutil.copy2(d/'response-manifest.json',archives[0]/'response-manifest.json')
    return rc

if __name__=='__main__':sys.exit(main())
