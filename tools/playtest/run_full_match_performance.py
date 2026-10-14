"""Serial natural-economy 8v8 diagnostics, ending on GameOver or a safety horizon.

Only the staged tree gains timing wrappers and, for Full Metal Plate, explicit
start/role registration. Production policy, cadence and commands stay intact.
"""
from script_settings import role_settings_path, role_script_path
import argparse,json,os,re,subprocess,sys
from pathlib import Path
from benchmark_store import RAW_ROOT
import playtest,storage
from air_arena import lua


def wrap(path,name,result,args,call,label):
    source=path.read_text(encoding='utf-8')
    pattern=re.compile(r'\b'+re.escape(result)+r'\s+'+name+r'\s*\('+re.escape(args)+r'\)\s*\{')
    matches=list(pattern.finditer(source))
    if len(matches)!=1:raise ValueError(f'Expected one definition: {path} {name}')
    match=matches[0]
    private='_Perf_'+name
    value='' if result=='void' else result+' value = '
    returned='' if result=='void' else 'return value;'
    wrapper=(f'{result} {name}({args}) {{\n'
             f' if (AiPerfEnabled) AiPerfBeginLabel("{label}");\n'
             f' {value}{private}({call});\n'
             f' if (AiPerfEnabled) AiPerfEndLabel();\n {returned}\n}}\n'
             f'{result} {private}({args}) {{')
    path.write_text(source[:match.start()]+wrapper+source[match.end():],encoding='utf-8')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--map',choices=['metal-plate','glacial','serene','glitters','supreme','shore'],required=True)
    p.add_argument('--dll',type=Path,required=True)
    p.add_argument('--data',type=Path,help='Matching pinned data tree; defaults to current repository data')
    # D-298: default to the lobby's last game; a pinned archive dies on the next BAR update.
    p.add_argument('--game',default=None)
    p.add_argument('--profile',default='experimental_balanced')
    p.add_argument('--profiles',help='Comma-separated per-team profiles for compatibility coverage; excluded from cost comparisons')
    p.add_argument('--mode',choices=['fast','visual','performance'],default='performance')
    p.add_argument('--speed',type=int,default=20)
    p.add_argument('--headless',action='store_true')
    p.add_argument('--native-phases',action='store_true',help='Opt-in attribution; disabled in headline comparisons')
    p.add_argument('--minutes',type=int,default=90,help='Safety horizon; GameOver ends earlier')
    p.add_argument('--stage-only',action='store_true')
    p.add_argument('--keep-going',action='store_true',help='Bounded diagnostic continuation after recorded failures; preserves FAIL verdicts')
    p.add_argument('--detail-sea',action='store_true',help='Additional staged SEA subphase labels; use in a separate attribution run')
    p.add_argument('--detail-air',action='store_true',help='Additional staged AIR subphase labels; attribution overhead is recorded')
    p.add_argument('--command-detail',action='store_true',help='Read-only unit/command/origin counts; adds observer overhead, not gameplay orders')
    p.add_argument('--verify-indexes',action='store_true',help='Correctness only: duplicate live route/economy scans; timings are invalid')
    a=p.parse_args()
    profiles=a.profiles.split(',') if a.profiles else None
    if profiles:
        if a.mode=='performance':p.error('Mixed-profile compatibility requires --mode fast or visual')
        data=a.data or playtest.REPO/'data'
        if any(not re.fullmatch(r'[a-z_]+',name) or not (data/'script'/name/'init.as').is_file() for name in profiles):
            p.error('Unknown compatibility profile')
    # Native oracles deliberately repeat old work (and snapshot verification
    # rebuilds the legacy ally view). Presence, even value "0", enables them.
    # Reject contaminated timing rather than silently unsetting user intent.
    oracles=('CIRCUIT_VERIFY_RANGED_QUERIES','CIRCUIT_VERIFY_RANGED_SNAPSHOT','CIRCUIT_VERIFY_GUARD',
             'CIRCUIT_VERIFY_ECONOMY_INDEX','CIRCUIT_VERIFY_POINT_ROUTES',
             'CIRCUIT_VERIFY_EMPTY_PACK','CIRCUIT_VERIFY_SEA_STATIC_INDEX')
    if any(name in os.environ for name in oracles) and not a.verify_indexes:
        p.error('Unset verification oracles for timing runs: '+', '.join(oracles))
    traces=('CIRCUIT_COMMANDER_TRACE','CIRCUIT_RANGED_TRACE')
    if a.mode=='performance' and any(name in os.environ for name in traces):
        p.error('Unset diagnostic traces for timing runs: '+', '.join(traces))
    d=storage.allocate('shared','performance','full-match-profile',a.map,'natural',seed=220001)
    print('FULL_MATCH_DIRECTORY='+str(d),flush=True)
    (RAW_ROOT / 'perf-current.txt').write_text(str(d))
    name={'metal-plate':'Full Metal Plate 1.7','glacial':'Glacial Gap v1.1','serene':'Serene Caldera v1.3',
          'glitters':'All That Glitters v2.2.3','supreme':'Supreme Isthmus v1.7','shore':'Shore_to_Shore_V3'}[a.map]
    role='SEA' if a.map=='serene' else 'AIR'
    extra=[]
    if a.map=='metal-plate':
        first=[(1400,1200,'TECH'),(3400,900,'AIR'),(800,3400,'SUPPORT'),(2100,2500,'TACTICAL'),
               (4600,1600,'FRONT'),(3600,3000,'FRONT'),(2200,4300,'FRONT'),(800,5100,'FRONT')]
        spots=first+[(12288-x,12288-z,r) for x,z,r in first]
        fixture='namespace FullMatchPlate {\nStartSpot@[] spots={\n'+',\n'.join(
            f'StartSpot(AIFloat3({x},0,{z}),AiRole::{r},false)' for x,z,r in spots)
        fixture+='\n};\ndictionary limits;\nMapConfig config=MapConfig("Full Metal Plate",limits,spots,null);\n}\n'
        map_file=d/'metal-plate-eight.as';map_file.write_text(fixture)
        extra=['--map-file',str(map_file)]
    if a.map=='shore':
        # User-approved 8v8 fixture only: keep every production start, limit,
        # weight and role. Add two forward-water SEA starts per team.
        fixture=(playtest.REPO/'data/script/src/maps/shore_to_shore.as').read_text()
        first='StartSpot(AIFloat3(14800, 0,  550)'
        assert fixture.count(first)==1
        fixture=fixture.replace(first,
            'StartSpot(AIFloat3( 3400, 0,  650), AiRole::SEA, false),\n'
            '        StartSpot(AIFloat3( 3400, 0, 2300), AiRole::SEA, false),\n        '+first)
        last='StartSpot(AIFloat3(13250, 0, 2700), AiRole::SEA,       false)'
        assert fixture.count(last)==1
        fixture=fixture.replace(last,last+',\n'
            '        StartSpot(AIFloat3(11960, 0,  650), AiRole::SEA, false),\n'
            '        StartSpot(AIFloat3(11960, 0, 2300), AiRole::SEA, false)')
        map_file=d/'shore-eight.as';map_file.write_text(fixture)
        extra=['--map-file',str(map_file)]
    focus={'x':2800,'z':2600,'height':6500} if a.map=='metal-plate' else {'x':2000,'z':3200,'height':6500}
    if a.map=='serene':focus={'x':7680,'z':6500,'height':10500}
    if a.map=='glitters':focus={'x':3072,'z':5120,'height':10000}
    if a.map=='shore':focus={'x':7680,'z':1536,'height':15500}
    if a.map=='supreme':focus={'x':6144,'z':6144,'height':12000}
    # The screenshot callback captures the current speed before queued speed
    # commands apply. Resume after the screenshot, never in the same frame.
    shot_minutes=[5,10,15,20,30,40,50,60,70,80,89]
    changes=[(0,a.speed),(4,1),(19,1),(39,1),(59,1),(79,1)]
    # Glacial includes adjacent 1x profiler-on/off/on observations. Populations
    # still evolve, so this is a confound check, not an exact overhead estimate.
    profiler_control=a.mode=='visual' and a.map in ('glacial','serene','shore')
    if profiler_control:changes += [(29,1),(34.15,a.speed)]
    changes += [(m+.15,a.speed) for m in shot_minutes if not (profiler_control and m==30)]
    if a.mode!='visual' or a.headless:
        shot_minutes=[]
        changes=[(0,a.speed)]
    plan=','.join(f'{m}:{speed}' for m,speed in sorted(changes))
    shots=','.join(f'{m}@{focus["height"]}@{focus["x"]}:{focus["z"]}' for m in shot_minutes)
    cli=[sys.executable,str(playtest.HERE/'playtest.py')]
    cmd=cli+['stage','--dir',str(d),'--dll',str(a.dll),'--map',name,*extra,
       *(['--game',a.game] if a.game else []),'--engine','recoil_2026.07.04',
       '--roles','all','--role',role,'--side','armada','--bonus','0',
       '--ai-option','profile='+a.profile,'--ai-option','random_seed=220001',
       '--modoption','deathmode=com','--minutes',str(a.minutes),'--speed',str(a.speed),'--speed-plan',plan,'--mode',a.mode,
       '--shots',shots,'--width','1280','--height','720','--lean-render']
    if a.headless:cmd+=['--headless']
    if a.data:cmd+=['--data',str(a.data)]
    for widget in ['skirmish_perf_watch.lua','air_command_watch.lua','perf_spectator_cleanup.lua','full_match_perf.lua']:
        cmd+=['--extra-widget',str(playtest.HERE/'widgets'/widget)]
    subprocess.run(cmd,check=True)
    scripts=d/'AI/Skirmish/BARbTest/test/script'
    if a.verify_indexes:
        path=role_settings_path(scripts/'src', 'Sea');source=path.read_text(encoding='utf-8')
        needle='bool VerifyPowerIndex = false;'
        if source.count(needle)!=1:raise ValueError('Expected candidate power-index verification switch')
        path.write_text(source.replace(needle,'bool VerifyPowerIndex = true;'),encoding='utf-8')
    from ranged_arena import pool_symbols
    pool_symbols(scripts.parent)
    if a.map=='shore':
        (scripts/'src/maps/shore_to_shore.as').write_text(fixture)
    if a.map=='metal-plate':
        (scripts/'src/maps/full_match_plate.as').write_text(fixture)
        path=scripts/'src/maps.as';source=path.read_text()
        needle='void registerMaps() {';assert source.count(needle)==1
        path.write_text('#include "maps/full_match_plate.as"\n'+source.replace(needle,needle+'\n mapManager.RegisterMapConfig(FullMatchPlate::config);'))
    for manager in ['builder','factory','military']:
        wrap(scripts/f'src/manager/{manager}.as','AiMakeTask','IUnitTask@','CCircuitUnit@ u','u',manager+'-dispatch')
    wrap(scripts/'src/manager/economy.as','AiUpdateEconomy','void','','','economy-update')
    for wrapped_role in ['air','tech','sea','front','support','tactical']:
        wrap(role_script_path(scripts/'src', wrapped_role),wrapped_role.title()+'_MainUpdate','void','','',wrapped_role+'-update')
    if a.detail_air:
        for section,method in [('economy','Tick'),('production','Tick'),('recon','Tick'),
                               ('operations','Tick'),('screen','Tick'),('base_response','Tick'),('naval_support','Tick'),
                               ('workforce','Tick'),('raids','Update'),('waves','Update')]:
            wrap(scripts/f'src/systems/air/air_{section}.as',method,'void','','','air.'+section)
    if a.detail_sea:
        for section in ['economy','combat','patrol','operations','recovery','coast','expansion','invasion','eco_layout']:
            wrap(scripts/f'src/systems/sea/sea_{section}.as','Tick','void','','','sea.'+section)
        for section in ['build','factories']:
            wrap(role_script_path(scripts/'src', 'sea_'+section),'Tick','void','','','sea.'+section)
        wrap(scripts/'src/systems/sea/sea_layout.as','RefreshGeometry','void','','','sea.geometry')
        wrap(scripts/'src/systems/sea/sea_shorelines.as','Tick','void','','','sea.shore-classification')
        # Attribution only. Keep nested labels separate from their parents:
        # objective selection, route solving and AA danger checks scale with
        # different inputs and must not be credited to layout work by default.
        wrap(scripts/'src/systems/sea/sea_operations.as','Census','void','','','sea.cohort-census')
        route_path=scripts/'src/systems/sea/sea_operations.as'
        transit=', bool transit=false' if 'bool transit=false' in route_path.read_text() else ''
        cautious=', bool cautious=true' if 'bool cautious=true' in route_path.read_text() else ''
        wrap(route_path,'Route','bool',
             'Cohort@ g, const AIFloat3 &in goal, bool withdrawing, bool scout, bool hold=false'+transit+cautious,
             'g,goal,withdrawing,scout,hold'+(',transit' if transit else '')+(',cautious' if cautious else ''),'sea.route')
        wrap(scripts/'src/systems/sea/sea_patrol.as','InterceptionSite','bool',
             'CCircuitUnit@ u,const AIFloat3 &in p,int body,const string &in cellKey',
             'u,p,body,cellKey','sea.aa-safety')
        path=scripts/'src/systems/sea/sea_operations.as'
        source=path.read_text(encoding='utf-8')
        needle='array<AIFloat3>@ points=aiBattle.GetTerrainRoute(g.centre,goal,5,10,1,3,1000000);'
        if source.count(needle)!=1:raise ValueError('Expected one naval route query for attribution')
        # AngelScript does not implicitly/explicitly cast bool to int here.
        source=source.replace(needle,needle+'\n if (AiPerfEnabled) AiLog("[PerfSeaRoute] frame="+ai.frame+" team="+ai.teamId+" cohort="+g.serial+" lead="+lead.id+" members="+g.ids.length()+" points="+points.length()+" withdrawing="+(withdrawing ? 1 : 0)+" hold="+(hold ? 1 : 0)'+('+" transit="+(transit ? 1 : 0)' if transit else '')+('+" cautious="+(cautious ? 1 : 0)' if cautious else '')+');')
        path.write_text(source,encoding='utf-8')
    cfg=d/'LuaUI/Config';cfg.mkdir(exist_ok=True)
    (cfg/'full_match_perf.lua').write_text('return '+lua({**focus,'command_detail':a.detail_sea or a.command_detail,
                                                        'unit_command_detail':a.command_detail,
                                                        'screenshots':a.mode=='visual' and not a.headless,
                                                        'horizon_frame':a.minutes*1800})+'\n')
    profiler={'profiling':True}
    if profiler_control:profiler['changes']=[{'minute':30,'enabled':False},{'minute':32,'enabled':True}]
    (cfg/'skirmish_perf.lua').write_text('return '+lua(profiler)+'\n')
    path=d/'script.txt';source=path.read_text();assert source.count('[GAME]\n{')==1
    if profiles:
        pattern=r'profile='+re.escape(a.profile)+r';'
        if len(re.findall(pattern,source))!=len(profiles):raise ValueError('One compatibility profile required per AI team')
        selected=iter(profiles)
        source=re.sub(pattern,lambda match:'profile='+next(selected)+';',source)
        teams_path=d/'teams.json';teams=json.loads(teams_path.read_text())
        for team in teams['teams']:
            if int(team['team'])<len(profiles):team['profile']=profiles[int(team['team'])]
        teams_path.write_text(json.dumps(teams,indent=2)+'\n')
    path.write_text(source.replace('[GAME]\n{','[GAME]\n{\n FixedRNGSeed=220001;',1))
    checks=json.loads((playtest.HERE/'checks/shared/performance/full-match-profile.json').read_text())
    checks['stop_minute']=a.minutes
    checks['pass_on']['pattern']=r'\[FullMatch(?:End|Horizon)\]'
    (d/'full-match-checks.json').write_text(json.dumps(checks,indent=2))
    (d/'full-match-manifest.json').write_text(json.dumps({
        'map':name,'game':a.game,'seed':220001,'profile':a.profile,'profiles_by_team':profiles,'focus_role':role,'native_phases':a.native_phases,'engine_profiler':True,
        'mode':a.mode,'requested_speed':a.speed,'headless':a.headless,
        'diagnostic_keep_going':a.keep_going,
        'ranged_verification_oracles':False,
        'index_verification_oracles':a.verify_indexes,'valid_for_timing':not a.verify_indexes and not profiles,
        'labels':'staged wrappers only; no policy/cadence/command changes','camera':focus,'safety_horizon':a.minutes,
        'ordinary_resources':True,'legion_enabled':True,'shore_extra_sea_starts_per_team':2 if a.map=='shore' else 0,'deathmode':'com','spectator_cleanup':True,'engine_profiler_plan':profiler,'sea_subphases':a.detail_sea,
        'air_subphases':a.detail_air,
        'unit_command_detail':a.command_detail,'command_observer_note':'Engine UnitCommand events, not network packets; source labels retained.',
        'data_hashes':{str(x.relative_to(scripts.parent)):storage.file_hash(x) for x in scripts.parent.rglob('*') if x.is_file() and x.suffix!='.dbg'}},indent=2))
    subprocess.run([sys.executable,str(playtest.REPO/'tools/knowledge/check_script_api.py'),'--dll',str(a.dll),'--scripts',str(scripts)],check=True)
    if a.stage_only:return 0
    env={**os.environ}
    env.pop('CIRCUIT_PERF_PHASES',None)
    if a.native_phases:env['CIRCUIT_PERF_PHASES']='1'
    if a.verify_indexes:env.update(CIRCUIT_VERIFY_ECONOMY_INDEX='1',CIRCUIT_VERIFY_POINT_ROUTES='1',
                                  CIRCUIT_VERIFY_EMPTY_PACK='1',CIRCUIT_VERIFY_SEA_STATIC_INDEX='1')
    playtest.validate_checks(d/'full-match-checks.json')
    try:
        subprocess.run(cli+['launch','--dir',str(d),'--engine','recoil_2026.07.04']+(['--headless'] if a.headless else []),env=env,check=True)
        return subprocess.run(cli+['watch','--dir',str(d),'--role',role,'--checks',str(d/'full-match-checks.json'),
            '--play-decided','--minutes',str(a.minutes+1),'--wall-minutes','180']+(['--keep-going'] if a.keep_going else [])).returncode
    finally:
        subprocess.run(cli+['stop','--dir',str(d)],check=True)


if __name__=='__main__':raise SystemExit(main())
