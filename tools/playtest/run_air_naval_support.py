"""Isolated radar patrol and torpedo fleet-relief acceptance games (D194)."""
from script_settings import role_settings_path
import argparse, hashlib, json, shutil, subprocess, sys
from pathlib import Path
import playtest, storage
from air_arena import lua

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--case',choices=['patrol','zero','full','partial','naval','stall','parity','hover','remote','sub','aa','basin','factory','danger'],required=True)
    p.add_argument('--map',choices=['supreme','glacial'],default='supreme')
    p.add_argument('--side',choices=['armada','cortex','legion'],default='armada')
    p.add_argument('--profile',default='experimental_hard')
    p.add_argument('--dll',type=Path,required=True)
    p.add_argument('--headless',action='store_true')
    a=p.parse_args();recon=a.case in ('patrol','zero','full','partial')
    d=storage.allocate('air','combat',('recon-' if recon else 'naval-')+a.case+'-'+a.side,a.map,'supplied',seed=1941)
    print('AIR_NAVAL_DIRECTORY='+str(d),flush=True)
    starts=d/'starts.as';starts.write_text('StartSpot(AIFloat3(2155,0,11747), AiRole::AIR, false),\n'
        'StartSpot(AIFloat3(837,0,10407), AiRole::FRONT, false),\n'
        'StartSpot(AIFloat3(10129,0,541), AiRole::FRONT, false),\n')
    if a.map=='glacial':starts.write_text('StartSpot(AIFloat3(490,0,1140), AiRole::AIR, false),\nStartSpot(AIFloat3(1430,0,4000), AiRole::FRONT, false),\nStartSpot(AIFloat3(14000,0,1100), AiRole::FRONT, false),\n')
    map_name='Supreme Isthmus v1.7' if a.map=='supreme' else 'Glacial Gap v1.1'
    call=[sys.executable,str(playtest.HERE/'playtest.py')]
    args=call+['stage','--dir',str(d),'--dll',str(a.dll),'--map',map_name,'--map-file',str(starts),
        '--roles','all','--role','AIR','--ally-spots','1,2','--side',a.side,'--bonus','0','--ai-option','profile='+a.profile,
        '--ai-option','random_seed=1941','--game','Beyond All Reason test-31479-433a460','--engine','recoil_2026.07.04',
        '--speed','10','--minutes','7','--shots','','--width','1280','--height','720','--lean-render',
        '--modoption','deathmode=neverend','--modoption','startmetal=100000','--modoption','startmetalstorage=100000',
        '--modoption','startenergy=1000000','--modoption','startenergystorage=1000000',
        '--extra-widget',str(playtest.HERE/'widgets/air_naval_support_watch.lua'),
        '--extra-widget',str(playtest.HERE/'widgets/air_command_watch.lua')]
    if a.headless:args+=['--headless']
    subprocess.run(args,check=True)
    # The generic launcher allocates a separate spectator team at (64,64).
    # BAR can spawn a hostile commander there; join its empty team to our ally
    # so it cannot contaminate a naval-only fixture with a real base emergency.
    script=d/'script.txt';text=script.read_text();script.write_text(text.replace('[GAME]\n{','[GAME]\n{\n FixedRNGSeed=1941;',1).replace('[TEAM3] { AllyTeam=2;', '[TEAM3] { AllyTeam=0;'))
    src=d/'AI/Skirmish/BARbTest/test/script'
    f=src/'src/setup.as';s=f.read_text();f.write_text(s.replace('Global::AISettings::Role = derivedRole;',
        'if (ai.teamId == 0) derivedRole = AiRole::AIR; else derivedRole = AiRole::FRONT;\nGlobal::AISettings::Role = derivedRole;'))
    # Only economic construction is frozen: defender production and combat are real.
    for module in ('builder','factory'):
        f=src/f'src/manager/{module}.as';s=f.read_text();at=s.index('{',s.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))
        condition='ai.frame>=0' if module=='builder' or recon or a.case in ('stall','parity','hover','remote','sub','aa','basin','factory','danger') else 'ai.teamId!=0'
        action='aiBuilderMgr.Enqueue(TaskB::Wait(60*SECOND))' if module=='builder' else 'aiFactoryMgr.Enqueue(TaskS::Wait(false,60*SECOND))'
        f.write_text(s[:at+1]+f'\n if ({condition}) return {action};\n'+s[at+1:])
    f=src/'src/manager/military.as';s=f.read_text();at=s.index('{',s.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))
    f.write_text(s[:at+1]+'''
    if(ai.teamId!=0) {
        CRouteTask@ task=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
        array<AIFloat3> route={u.GetPos(ai.frame)};
        task.SetAirControl(true);task.SetTraversal(true,128,false);task.SetRoute(route);return task;
    }
'''+s[at+1:])
    # Read-only per-policy state exposes causality; no target or movement override.
    probe='''
namespace AirNavalProbe {
    int sampled=-100000;
    void Tick() {
        if(ai.teamId!=0 || ai.frame-sampled<10*SECOND)return;sampled=ai.frame;
        for(int i=0;i<aiBattle.GetGroundContactCount();++i) {
            const AIFloat3 p=aiBattle.GetGroundContactPos(i);
            if(!AirBaseResponse::InBase(p))continue;
            const CCircuitDef@ d=ai.GetCircuitDef(aiBattle.GetGroundContactDefId(i));
            if(d !is null)GenericHelpers::LogUtil("[AirNavalProbe] base contact="+d.GetName()+" id="+aiBattle.GetGroundContactId(i)+" pos="+int(p.x)+","+int(p.z),1);
        }
        for(int i=0;i<aiBattle.GetNavalForceCount();++i) {
            const CCircuitDef@ d=ai.GetCircuitDef(aiBattle.GetNavalForceDefId(i));
            if(d !is null && d.GetName()=="corcrus") {
                const AIFloat3 p=aiBattle.GetNavalForcePos(i);
                GenericHelpers::LogUtil("[AirNavalProbe] zero-weight AA raw="+aiBattle.AirThreat(p)+" physical="+aiBattle.AirThreatAlong(p,p,0),1);
            }
        }
        GenericHelpers::LogUtil("[AirNavalProbe] waiting="+AirRecon::waiting.getSize()+" patrols="+AirRecon::patrols.getSize()
            +" sweeping="+AirRecon::sweeping.getSize()+" forces="+aiBattle.GetNavalForceCount()
            +" deficit="+int(AirNavalSupport::deficit)+" desired="+AirNavalSupport::desired
            +" route="+AirNavalSupport::routeReady+" held="+AirNavalSupport::held.getSize()
            +" active="+AirNavalSupport::active.getSize()+" phase="+AirNavalSupport::phase
            +" navalRisk="+(AirNavalSupport::targetIndex<0?0:aiBattle.AirThreat(aiBattle.GetNavalForcePos(AirNavalSupport::targetIndex))),1);
    }
}
'''
    for profile in ('experimental_hard','experimental_balanced','experimental_terrible'):
        f=src/profile/'main.as';s=f.read_text();f.write_text(s.replace('ArtilleryPolicy::Check();','ArtilleryPolicy::Check(); AirNavalProbe::Tick();')+'\n'+probe)
    if a.case in ('patrol','zero'):
        f=role_settings_path(src/'src', 'Air');s=f.read_text().replace('int RadarMaxWaitSeconds = 90;','int RadarMaxWaitSeconds = 180;');f.write_text(s)
    cfg={'case':a.case,'side':a.side,'speed':10,'recon':recon,'headless':a.headless,'map':a.map}
    (d/'LuaUI/Config').mkdir(parents=True,exist_ok=True);(d/'LuaUI/Config/air_naval_support.lua').write_text('return '+lua(cfg)+'\n')
    expects=[('fixture',r'AirNavalWatch.*loaded')]
    if recon:
        expects += [('patrol',r'AIR.*Recon.*patrol plane='),('launch',r'AIR.*Recon.*synchronized sweep=.*reason=' + ('full' if a.case=='full' else 'deadline'))]
    elif a.case in ('naval','stall','sub','aa','factory'):
        expects += [('launch',r'AIR.*Naval.*launch='),('attack',r'AIR.*Naval.*attack='),('damage',r'AirNavalWatch.*torpedo_damage')]
        if a.case=='naval': expects+=[('recruit',r'AIR.*Produce.*naval.relief'),('finish',r'AirNavalWatch.*torpedo_finished')]
        if a.case=='stall': expects+=[('deadline',r'AIR.*Naval.*launch=.*reason=deadline')]
    if a.case in ('patrol','zero'):expects += [('escape',r'AirNavalWatch.*AA_escape frame=')]
    if a.case=='zero':expects += [('zero_physical',r'zero-weight AA raw=0 physical=1')]
    if a.case=='danger':expects += [('route_hold',r'AIR.*Naval.*hold: no acceptable open-water/AA approach')]
    if a.case=='factory' and a.map=='glacial':expects += [('fleet_cleared',r'AirNavalWatch.*census.*dead=6')]
    forbids=[('script',r': ERR\s+:|SCRIPT CRASH|Lib exception'),('invariant','INVARIANT|AirOrders.*ERROR'),
        ('crash','Access violation|has crashed|Fatal:'),('widget',r'Error in.*air_naval_support_watch|Removed widget: AIR naval support fixture')]
    if a.case in ('patrol','zero'):forbids += [('escape_failure','AA_escape_failed')]
    if a.case in ('parity','hover','remote','basin','danger'):forbids += [('false_support',r'AIR.*Naval.*launch=|AIR.*Produce.*naval.relief')]
    checks={'stop_minute':7,'expect':[{'key':k,'pattern':v,'scope':'any','by_minute':7} for k,v in expects],
        'forbid':[{'key':k,'pattern':v,'scope':'any'} for k,v in forbids]}
    cp=d/'naval-checks.json';cp.write_text(json.dumps(checks,indent=2))
    manifest={'case':cfg,'supplied_resources':True,'visibility':'ordinary radar/LOS/sonar; no globallos',
        'overrides':['economic builders frozen','other teams hold fixture positions','factories frozen except production case',
            'spectator team allied to team 0; its corner commander is not an enemy',
            '180-second radar deadline in patrol/zero cases only'],
        'dll_sha256':hashlib.sha256(a.dll.read_bytes()).hexdigest(),
        'data':{str(f.relative_to(src.parent)):hashlib.sha256(f.read_bytes()).hexdigest() for f in src.parent.rglob('*') if f.is_file()}}
    (d/'naval-manifest.json').write_text(json.dumps(manifest,indent=2))
    subprocess.run([sys.executable,str(playtest.REPO/'tools/knowledge/check_script_api.py'),'--dll',str(a.dll),'--scripts',str(src)],check=True)
    subprocess.run(call+['launch','--dir',str(d),'--engine','recoil_2026.07.04']+(['--headless'] if a.headless else []),check=True)
    rc=subprocess.run(call+['watch','--dir',str(d),'--role','AIR','--checks',str(cp),'--minutes','7','--wall-minutes','12','--keep-going']).returncode
    archives=list((d/'runs').iterdir())
    if len(archives)==1:shutil.copy2(d/'naval-manifest.json',archives[0]/'naval-manifest.json')
    return rc

if __name__=='__main__':sys.exit(main())

