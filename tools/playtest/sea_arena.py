"""Isolated SEA combat fixtures. Assets are supplied; AI alone commands combat."""
from script_settings import role_settings_path
import argparse, hashlib, json, re, subprocess, sys, os
from pathlib import Path
import playtest, storage
from air_arena import lua
from sea_tempo_benchmark import summarize, audit
from sea_progression_audit import audit as audit_progression

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]


def audit_retreat(text):
    """Correlate a fresh policy hint, health retreat and an actual MOVE endpoint.

    This proves native staging admission/dispatch, not arrival, survival or
    repair. State sampling can follow the native order by up to one second.
    """
    hints={}; moves={}; states=[]
    for line in text.splitlines():
        match=re.search(r'\[f=0*(\d+)\]',line)
        if not match:continue
        frame=int(match[1]); fields=dict(re.findall(r'(\w+)=([^\s]+)',line))
        if '[RetreatProbe] waypoint' in line:
            hints.setdefault(fields['ship'],[]).append((frame,float(fields['x']),float(fields['z'])))
        elif '[RetreatProbe] state' in line and fields.get('retreat')=='true':
            states.append((fields['ship'],frame))
        elif '[SeaArena]' in line and ' move ' in line:
            moves.setdefault(fields['id'],[]).append((frame,float(fields['x']),float(fields['z'])))
    evidence=[]
    for unit,frame in states:
        prior=[hint for hint in hints.get(unit,[]) if hint[0]<=frame]
        if not prior:continue
        hint=prior[-1]
        if frame-hint[0]>=45*30:continue
        for command,x,z in moves.get(unit,[]):
            distance=((x-hint[1])**2+(z-hint[2])**2)**.5
            if frame-30<=command<=frame+60 and distance<=129:
                evidence.append(dict(unit=unit,retreat_frame=frame,command_frame=command,
                                     hint_frame=hint[0],endpoint_error=distance))
                break
    return ([] if evidence else ['No fresh retreat hint matched a native withdrawal MOVE'],evidence)


def audit_transit(text, case):
    """Physical arrival/health evidence, independent of AI decision messages."""
    spec=case['native_transit']; latest={}; maximum_queue=0
    for line in text.splitlines():
        if '[SeaArena]' not in line or ' boat ' not in line:continue
        fields=dict(re.findall(r'(\w+)=([^\s]+)',line))
        if fields.get('unit')==spec['unit'] and all(key in fields for key in ('x','z','health','maxhealth')):
            latest[fields['id']]=fields
            maximum_queue=max(maximum_queue,int(fields.get('queue',0)))
    expected=sum(g['count'] for g in case['groups'] if g['team']==0 and g['unit']==spec['unit'])
    failures=[]; x,z=spec['points'][-1]
    if 'maximum_queue' in spec and maximum_queue>spec['maximum_queue']:
        failures.append(f'INV-186: rounded straight transit queue {maximum_queue} exceeds {spec["maximum_queue"]}')
    if len(latest)!=expected:failures.append(f'Expected {expected} observed boats; got {len(latest)}')
    for unit,sample in latest.items():
        if int(sample['frame'])<90*30:failures.append(f'{unit}: missing late observation')
        if (float(sample['x'])-x)**2+(float(sample['z'])-z)**2>360**2:
            failures.append(f'{unit}: did not reach formation destination')
        if sample['health']!=sample['maxhealth']:failures.append(f'{unit}: damaged during empty-sea transit')
    return failures

def scenario_label(name, control=False):
    """Fit storage's 24-character category without merging long case names."""
    suffix='-ctrl' if control else '-cand'
    normalized=re.sub(r'[^a-z0-9]+','-',name.lower()).strip('-') or 'sea'
    if len(normalized+suffix)<=24:
        return normalized+suffix
    # The full case identity remains in sea-arena.json. Hash the unshortened
    # name: mere prefix truncation merged supported/unsupported counter cases.
    digest=hashlib.sha256(name.encode('utf-8')).hexdigest()[:8]
    return normalized[:10].rstrip('-')+'-'+digest+suffix

def frozen_actor_condition(manager, support_turrets):
    if not support_turrets:
        return 'ai.frame>=0'
    # Static nanos belong to FactoryManager, not BuilderManager. A repair
    # fixture must leave both their task selection and recovery subs active.
    return ('(SeaEconomy::ConstructorDef(u.circuitDef) || UnitHelpers::IsCommander(u.circuitDef))'
            if manager=='builder' else 'SeaEconomy::SupportedFactory(u.circuitDef)')

def apply_start_boxes(script, boxes):
    for team, box in enumerate(boxes):
        left, top, right, bottom = box
        if not (0 <= left < right <= 1 and 0 <= top < bottom <= 1): raise ValueError('Invalid normalized start box')
        replacement=f'[ALLYTEAM{team}] {{ NumAllies=0; StartRectLeft={left}; StartRectTop={top}; StartRectRight={right}; StartRectBottom={bottom}; }}'
        script,n=re.subn(r'\[ALLYTEAM'+str(team)+r'\]\s*\{[^}]*\}',lambda _: replacement,script,count=1)
        if n != 1: raise ValueError(f'Missing ally-team section for start box {team}')
    return script


def prepare(a):
    case=json.loads(storage.resolve_definition(a.case,'cases').read_text())
    if getattr(a,'mode','fast')!='visual': case['follow_shots']=[]
    label=scenario_label(case.get('name',Path(a.case).stem),a.control)
    d=storage.allocate('sea','combat',label,case.get('map_key','glacial'),'supplied',seed=a.seed)
    starts=d/'starts.as'; starts.write_text(''.join(f'StartSpot(AIFloat3({x},0,{z}), AiRole::SEA, false),\n' for x,z in case.get('starts',[[2300,4400],[4600,4400]])))
    call=[sys.executable,str(HERE/'playtest.py')]
    subprocess.run(call+['stage','--dir',str(d),'--dll',str(a.dll),'--data',str(a.data),'--map',case.get('map','Glacial Gap v1.1'),'--map-file',str(starts),
        *(['--game',a.game] if getattr(a,'game',None) else []),'--engine','recoil_2026.07.04','--role','SEA','--roles','all','--ally-spots','1','--side',a.side,
        '--speed',str(a.speed),'--minutes',str(a.minutes),'--mode',getattr(a,'mode','fast'),
        '--shots',case.get('shots','0.4@2400@3400:4450,0.7@2400@3400:4450,3@3200@3400:4450,7@4000@3400:4450') if getattr(a,'mode','fast')=='visual' else '',
        '--width','1280','--height','720','--lean-render','--bonus','0','--ai-option','profile='+a.profile,'--ai-option','random_seed='+str(a.seed),
        '--modoption','deathmode=neverend','--modoption','startenergy=1000000','--modoption','startenergystorage=1000000',
        '--extra-widget',str(HERE/'widgets/sea_arena.lua'),
        '--extra-widget',str(HERE/'widgets/workforce_perf_watch.lua'),
        *[x for w in (getattr(a,'extra_widget',None) or []) for x in ('--extra-widget',w)],
        # D-351: a case may force role settings in the staged script ("settings":
        # {"Key": "value"} is Sea.Key; "Role.Key" selects another role), so a
        # fixture such as the crowded coast no longer needs a hand-edited data copy.
        *[x for k,v in (case.get('settings') or {}).items() for x in ('--set',(k if '.' in k else 'Sea.'+k)+'='+str(v))]],check=True)
    script=d/'script.txt'; s=script.read_text();s=s.replace('[GAME]\n{','[GAME]\n{\n FixedRNGSeed='+str(a.seed)+';',1)
    s=apply_start_boxes(s,case.get('start_boxes', []))
    script.write_text(s)
    staged=d/'AI/Skirmish/BARbTest/test/script'; g=role_settings_path(staged/'src', 'Sea');s=g.read_text();before,sea=s.split('namespace Sea {',1)
    sea,n=re.subn(r'bool ExperimentalBuild = (true|false);','bool ExperimentalBuild = '+('false' if a.legacy_layout else 'true')+';',sea,count=1);assert n==1
    if a.control: sea=sea.replace('bool AdaptiveFleet = true;','bool AdaptiveFleet = false;')
    if a.order_slack is not None:
        sea,n=re.subn(r'float OrderPositionSlack = [^;]+;', 'float OrderPositionSlack = '+str(a.order_slack)+'f;',sea,count=1);assert n==1
    if case.get('scout_diagnostics'):
        sea=sea.replace('bool ScoutDiagnostics = false;', 'bool ScoutDiagnostics = true;')
    g.write_text(before+'namespace Sea {'+sea)
    # Constructors are frozen in all combat-only tests. Production is real only
    # in response cases, where actual supplied economy funds new hulls.
    for name,manager,wait in [('builder','aiBuilderMgr','TaskB::Wait(60*SECOND)'),('factory','aiFactoryMgr','TaskS::Wait(false,60*SECOND)')]:
        if name=='factory' and case.get('production'): continue
        p=staged/'src/manager'/(name+'.as');s=p.read_text();b=s.index('{',s.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))
        # Recovery submarines must retain their native reclaim/repair task and
        # leave the yard. Freezing them like construction ships can obstruct
        # subsequent hulls and turn a response test into a fixture artifact.
        condition=frozen_actor_condition(name,case.get('support_turrets',False))
        p.write_text(s[:b+1]+'\n if ('+condition+') return '+manager+'.Enqueue('+wait+'); // supplied fixture only\n'+s[b+1:])
    if case.get('production'):
        # Finish the supplied initial workforce before the first recruitment
        # decision; otherwise the just-spawned yard creates an extra builder.
        p=staged/'src/manager/factory.as';s=p.read_text();b=s.index('{',s.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))
        p.write_text(s[:b+1]+'\n if (ai.frame<600) return aiFactoryMgr.Enqueue(TaskS::Wait(false,SECOND)); // fixture setup barrier\n'+s[b+1:])
    setup=staged/'src/setup.as';s=setup.read_text();s=s.replace('Global::AISettings::Role = derivedRole;','derivedRole=AiRole::SEA;\nGlobal::AISettings::Role = derivedRole;');setup.write_text(s)
    if case.get('native_transit'):
        # Mechanism fixture, not autonomous combat evidence. Both builds get
        # identical routes/formation; only the candidate exposes compaction.
        spec=case['native_transit']
        p=staged/'src/systems/sea/sea_combat.as';s=p.read_text()
        s=s.replace('bool Active() { return ', 'bool Active() { return false && ',1);p.write_text(s)
        points=','.join(f'AIFloat3({float(x)},0,{float(z)})' for x,z in spec['points'])
        compact=('transit.SetMoveCompaction(Global::RoleSettings::Sea::CompactMoveRoutes);'
                 if 'CompactMoveRoutes' in g.read_text() else '')
        p=staged/'src/manager/military.as';s=p.read_text();b=s.index('{',s.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))
        s=s[:b+1]+f'\n if (ai.teamId==0 && u.circuitDef.GetName()=="{spec["unit"]}") return SeaTransitFixture::Task();\n'+s[b+1:]
        s+='''\nnamespace SeaTransitFixture {
            CRouteTask@ transit;
            IUnitTask@ Task() {
                if (transit is null || transit.IsDead()) {
                    @transit=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
                    transit.SetSeaControl(true); transit.SetTraversal(true,48,false);
                    transit.SetLanes(3,96,1); transit.SetRowSpacing(80);
                    '''+compact+''' array<AIFloat3> points={'''+points+'''};
                    transit.SetRoute(points);
                }
                return transit;
            }
        }\n'''
        p.write_text(s)
    if case.get('enemy_air_route'):
        # Script only the enemy transit. Friendly scout/AA orders remain wholly
        # production policy, so physical response is not a fixture instruction.
        points=','.join(f'AIFloat3({float(x)},160,{float(z)})' for x,z in case['enemy_air_route'])
        p=staged/'src/manager/military.as';s=p.read_text();b=s.index('{',s.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))
        s=s[:b+1]+'''\n if (ai.teamId==1 && u.circuitDef.IsAbleToFly()) {
            CRouteTask@ transit=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
            array<AIFloat3> points={'''+points+'''};
            transit.SetTraversal(true,64,false); transit.SetPatrol(true); transit.SetRoute(points); return transit;
        } // enemy flight path fixture only\n'''+s[b+1:];p.write_text(s)
    if case.get('enemy_routes'):
        # Deterministic opposing bait only. Friendly combat remains entirely AI
        # controlled; identical trajectories are used for old/new comparisons.
        p=staged/'src/systems/sea/sea_combat.as';s=p.read_text()
        s=s.replace('bool Active() { return ', 'bool Active() { return ai.teamId!=1 && ',1);p.write_text(s)
        clauses=[]
        for route in case['enemy_routes']:
            points=','.join(f'AIFloat3({float(x)},0,{float(z)})' for x,z in route['points'])
            clauses.append('if (ai.teamId==1 && u.circuitDef.GetName()=="'+route['unit']+'") { '
                'CRouteTask@ scripted=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route())); '
                'array<AIFloat3> points={'+points+'}; scripted.SetTraversal(true,32,false); '
                'scripted.SetPatrol(true); scripted.SetRoute(points); return scripted; }')
        p=staged/'src/manager/military.as';s=p.read_text();b=s.index('{',s.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))
        p.write_text(s[:b+1]+'\n'+'\n'.join(clauses)+'\n'+s[b+1:])
    if case.get('friendly_routes'):
        # Exercise escort following a moving protected ship. Only that ship's
        # route is scripted; support movement/stockpiling remains production AI.
        clauses, exclusions = [], []
        for route in case['friendly_routes']:
            points=','.join(f'AIFloat3({float(x)},0,{float(z)})' for x,z in route['points'])
            match='ai.teamId==0 && u.circuitDef.GetName()=="'+route['unit']+'"'
            exclusions.append('if (u !is null && '+match+') return false;')
            clauses.append('if ('+match+') { CRouteTask@ scripted=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route())); '
                'array<AIFloat3> points={'+points+'}; scripted.SetSeaControl(true); scripted.SetTraversal(true,32,false); '
                'scripted.SetPatrol(true); scripted.SetRoute(points); return scripted; }')
        p=staged/'src/systems/sea/sea_operations.as';s=p.read_text();b=s.index('{',s.index('bool Eligible(CCircuitUnit@ u)'))
        p.write_text(s[:b+1]+'\n'+'\n'.join(exclusions)+'\n'+s[b+1:])
        p=staged/'src/manager/military.as';s=p.read_text();b=s.index('{',s.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))
        p.write_text(s[:b+1]+'\n'+'\n'.join(clauses)+'\n'+s[b+1:])
    if case.get('verified_water_fixture'):
        # Isolate the post-survey policy with a declared scenario precondition.
        # This is not evidence that the natural-game survey gate has passed.
        x,z=case['verified_water_fixture']
        p=staged/'src/systems/sea/sea_invasion.as';s=p.read_text();b=s.index('{',s.index('void Tick()'))
        p.write_text(s[:b+1]+f'\n if (ai.teamId==0) {{ secured=ai.frame>=600; body=aiBattle.WaterBody(AIFloat3({x},0,{z}),false); return; }} // supplied survey precondition only\n'+s[b+1:])
    if case.get('retreat_boundary_observer'):
        # Read-only observation of actual offset candidates, before the runtime
        # bounds guard. This fixture proves edge geometry is exercised, rather
        # than treating an absence of crashes as evidence of coverage.
        path=staged/'src/systems/sea/sea_retreat.as'
        source=path.read_text()
        needle='const AIFloat3 point=anchorPosition+direction*(BehindLine/length)+tangent*offset;'
        assert source.count(needle)==1
        source=source.replace(needle,needle+'\n if (!ProductionMath::Inside(point.x,point.z,float(AiTerrainWidth()),float(AiTerrainHeight()),0)) AiLog("[RetreatBoundary] rejected ship="+ship.id+" x="+point.x+" z="+point.z);')
        path.write_text(source)
    if case.get('retreat_observer') or case.get('fireline_observer'):
        if case.get('screen_anchor_fixture'):
            # Mechanism isolation: hold the supplied submarine screen near its
            # spawn. Surface ships still choose combat and health retreat.
            path=staged/'src/systems/sea/sea_operations.as'
            source=path.read_text()
            needle='Cohort@ g=groups[k]; if (g.ids.length()==0) continue;'
            assert source.count(needle)==1
            source=source.replace(needle,needle+'''\n
            if (SeaSubmarines::Handles(ai.GetCircuitDef(g.defId))) {
                if (g.route is null || g.route.IsDead()) Route(g,g.centre+AIFloat3(128,0,0),false,true,true);
                continue;
            }
''')
            path.write_text(source)
        # Observation only; do not force retreat, alter health or command ships.
        path=staged/'src/systems/sea/sea_retreat.as'
        source=path.read_text()
        # D-346 added a second loop over owned ships (forward holds); probe the
        # withdrawal-waypoint loop, identified by its multi-line filter.
        needle='CCircuitUnit@ ship=ai.GetTeamUnit(SeaCombat::owned[i]);\n            if (ship is null || !ship.circuitDef.IsMobile() || ship.circuitDef.IsAbleToFly()\n'
        if source.count(needle)!=1: needle=needle.replace('\n','\r\n')
        assert source.count(needle)==1
        first=needle.split(';',1)[0]+';'
        source=source.replace(needle,first+'\n SeaRetreatProbe::Observe(ship);'+needle[len(first):])
        needle='ship.SetRetreatWaypoint(goal,anchor,ai.frame+WaypointSeconds*SECOND);'
        assert source.count(needle)==1
        source=source.replace(needle,needle+'\n if (anchor>=0) GenericHelpers::LogUtil("[RetreatProbe] waypoint ship="+ship.id+" anchor="+anchor+" x="+goal.x+" z="+goal.z,1);')
        source+='''
namespace SeaRetreatProbe {
    dictionary states;
    void Observe(CCircuitUnit@ unit) {
        if (unit is null) return;
        const bool retreat=unit.task !is null && unit.task.GetType()==int(Task::Type::RETREAT);
        bool previous=false; states.get(""+unit.id,previous);
        if (retreat!=previous) GenericHelpers::LogUtil("[RetreatProbe] state ship="+unit.id+" retreat="+retreat+" def="+unit.circuitDef.GetName(),1);
        states.set(""+unit.id,retreat);
    }
}
'''
        path.write_text(source)
    case.update(seed=a.seed,side=a.side,minutes=a.minutes,speed=a.speed,control=a.control,order_slack=a.order_slack)
    if a.cost:
        from run_full_match_performance import wrap
        wrap(staged/'src/systems/sea/sea_combat.as','Tick','void','','','sea.total')
        if (staged/'src/systems/sea/sea_control.as').exists():
            wrap(staged/'src/systems/sea/sea_control.as','Tick','void','','','sea.control')
        wrap(staged/'src/systems/sea/sea_operations.as','Tick','void','','','sea.operations')
        wrap(staged/'src/systems/sea/sea_operations.as','Census','void','','','sea.cohort-census')
        case['cost_profiling']=True
    (d/'LuaUI/Config').mkdir(exist_ok=True,parents=True);(d/'LuaUI/Config/sea_arena.lua').write_text('return '+lua(case)+'\n')
    (d/'sea-arena.json').write_text(json.dumps(case,indent=2))
    (d/'sea-arena-pins.json').write_text(json.dumps({
        'dll_sha256':hashlib.sha256(a.dll.read_bytes()).hexdigest(),
        'staged_data':{str(p.relative_to(staged.parent)):hashlib.sha256(p.read_bytes()).hexdigest()
            for p in staged.parent.rglob('*') if p.is_file() and p.suffix in ('.as','.json')},
        'observer_sha256':hashlib.sha256((HERE/'widgets/sea_arena.lua').read_bytes()).hexdigest(),
        'overrides':['SEA role forced','economic builders frozen; recovery active in supported fixtures','factories frozen unless production fixture; setup barrier at frame 600','supplied forces and startup energy','fixed engine RNG seed']
            +(['enemy transit routes scripted'] if case.get('enemy_routes') else [])
            +(['protected friendly ship route scripted; escort commands remain autonomous'] if case.get('friendly_routes') else [])
            +(['friendly native formation route supplied; mechanism test only'] if case.get('native_transit') else [])
            +(['verified-water gate supplied; not a natural survey test'] if case.get('verified_water_fixture') else [])
            +(['retreat state and waypoint observation; no surface retreat commands supplied'] if case.get('retreat_observer') else [])
            +(['read-only T1 submarine retreat-state observation'] if case.get('fireline_observer') else [])
            +(['read-only observation of off-map retreat candidates'] if case.get('retreat_boundary_observer') else [])
            +(['supplied submarines held near spawn; retreat mechanism test only'] if case.get('screen_anchor_fixture') else [])},indent=2))
    subprocess.run([sys.executable,str(ROOT/'tools/knowledge/check_script_api.py'),'--dll',str(a.dll),'--scripts',str(staged)],check=True)
    print('SEA_ARENA='+str(d),flush=True)
    return d,call,case.get('checks','sea-arena')

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--case',default='surface-line');p.add_argument('--dll',required=True,type=Path)
    p.add_argument('--extra-widget',action='append',help='Stage another widget under test, e.g. tools/widgets/gui_barb_team_link.lua');p.add_argument('--data',type=Path,default=ROOT/'data');p.add_argument('--side',default='armada');p.add_argument('--profile',default='experimental_hard')
    p.add_argument('--game',default=None)
    p.add_argument('--control',action='store_true');p.add_argument('--seed',type=int,default=1891);p.add_argument('--minutes',type=int,default=8);p.add_argument('--speed',type=int,default=10)
    p.add_argument('--legacy-layout',action='store_true',help='Verify adaptive combat independently of experimental building')
    p.add_argument('--cost',action='store_true',help='Record native phases and inclusive SEA policy CPU; run comparisons serially')
    p.add_argument('--order-slack',type=float,help='Isolate optional native naval order changes; zero uses native defaults')
    p.add_argument('--mode',choices=['fast','visual','performance'],default='fast')
    p.add_argument('--headless',action='store_true')
    a=p.parse_args();d,call,checks=prepare(a)
    subprocess.run(call+['launch','--dir',str(d),'--engine','recoil_2026.07.04']+(['--headless'] if a.headless else []),check=True,
        env={**os.environ,**({'CIRCUIT_PERF_PHASES':'1'} if a.cost else {})})
    code=subprocess.run(call+['watch','--dir',str(d),'--role','SEA','--checks',checks,'--minutes',str(a.minutes),'--wall-minutes','15']).returncode
    case=json.loads((d/'sea-arena.json').read_text())
    acceptance=case.get('acceptance')
    if acceptance or case.get('native_transit') or case.get('progression_audit') or case.get('retreat_observer') or case.get('production_audit') or case.get('handoff_audit'):
        archive=max((d/'runs').glob('*'),key=lambda p:p.name)
        text=(archive/'infolog.txt').read_text(errors='replace')
        measurements={}
        if case.get('retreat_observer'):
            failures,measurements=audit_retreat(text)
        elif case.get('progression_audit'):
            failures,measurements=audit_progression(text,case)
        else:
            failures=audit_transit(text,case) if case.get('native_transit') else audit(summarize(text),acceptance or {})
        for pattern in case.get('required_log_patterns', []):
            if not re.search(pattern, text): failures.append('Required policy evidence missing: '+pattern)
        if case.get('handoff_audit'):
            from sea_station_audit import audit_handoff
            handoff_failures, measurements['handoff'] = audit_handoff(text, case['handoff_audit'])
            failures.extend(handoff_failures)
        if case.get('station_audit'):
            from sea_station_audit import audit as audit_stations
            station_failures, measurements['stations'] = audit_stations(text, case['station_audit'])
            failures.extend(station_failures)
        if case.get('production_audit'):
            from sea_station_audit import audit_production
            production_failures, measurements['production'] = audit_production(text, case['production_audit'])
            failures.extend(production_failures)
        if case.get('visibility_audit'):
            from sea_station_audit import audit_visibility
            visibility_failures, measurements['visibility'] = audit_visibility(text, case['visibility_audit'])
            failures.extend(visibility_failures)
        if case.get('coast_audit'):
            from sea_station_audit import audit_coast
            coast_failures, measurements['coast'] = audit_coast(text, case['coast_audit'])
            failures.extend(coast_failures)
        # Never replace the runner's report/result. A smoke PASS may still be
        # a tactical failure; publish the explicit physical judgment beside it.
        with (archive/'sea-tempo-acceptance.json').open('x',encoding='utf-8') as f:
            json.dump(dict(acceptance=acceptance or case.get('progression_audit'),measurements=measurements,failures=failures,pass_outcome=not failures),f,indent=2)
        print('SEA outcome: '+('FAIL '+str(failures) if failures else 'PASS'),flush=True)
        code=code or int(bool(failures))
    return code

if __name__=='__main__':sys.exit(main())
