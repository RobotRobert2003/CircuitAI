"""Supplied-force ranged combat: unchanged AI commands team 0; fixture owns team 1.

Each invocation allocates an immutable run identity. Economy is frozen only in
the staged scripts. --variant siege isolates the original two-list proposal;
--variant baseline takes a pinned pre-change --data/--dll pair.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from benchmark_store import RAW_ROOT
import storage
import playtest
from air_arena import lua

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def pool_symbols(staged):
    """Compatibility hook for callers; shared staging owns symbol retention."""
    from symbol_store import stage_symbols
    path = staged / 'SkirmishAI.dbg'
    if path.exists():
        stage_symbols(path, path)


def prepare(args):
    case = json.loads(storage.resolve_definition(args.case, 'cases').read_text())
    role = case.get('role', 'FRONT')
    if role not in ('FRONT', 'TECH', 'AIR', 'SEA', 'SUPPORT', 'TACTICAL'): raise ValueError('Unsupported arena role: '+role)
    directory = storage.allocate('shared', 'combat', case.get('storage_scenario',case['name']), case['map_key'], 'supplied', seed=args.seed)
    starts = directory / 'starts.as'
    starts.write_text(''.join(f'StartSpot(AIFloat3({x},0,{z}), AiRole::{role if i==0 else case.get("enemy_role",role)}, false),\n' for i,(x,z) in enumerate(case['starts'])))
    command = [sys.executable, str(HERE / 'playtest.py')]
    stage = command + ['stage','--dir',str(directory),'--dll',str(args.dll),'--data',str(args.data),
        '--map',case['map'],'--map-file',str(starts),'--role',role,'--roles','all','--ally-spots',case.get('ally_spots','1'),
        '--side',case.get('side','armada'),
        '--engine','recoil_2026.07.04','--speed',str(args.speed),'--mode',getattr(args,'mode','fast'),'--minutes',str(args.minutes),
        '--shots','','--width','1280','--height','720','--lean-render','--bonus','0',
        '--ai-option','profile='+args.profile,'--ai-option','random_seed='+str(args.seed),
        '--modoption','deathmode=neverend','--modoption','startenergy='+str(case.get('start_energy',1000000)),
        '--modoption','startmetal='+str(case.get('start_metal',1000)),
        '--modoption','startmetalstorage='+str(case.get('start_metal',1000)),
        '--modoption','startenergystorage=1000000',
        '--extra-widget',str(HERE/'widgets/ranged_arena.lua'),
        '--extra-widget',str(HERE/'widgets/workforce_perf_watch.lua')]
    # Declared per-case mod options (e.g. the Legion faction for legscout).
    for key, value in case.get('modoptions', {}).items():
        stage += ['--modoption', f'{key}={value}']
    if args.headless: stage += ['--headless']
    # No --game: playtest.py resolves the lobby's last game archive, so a
    # pinned archive name does not go stale when the installed BAR updates.
    if args.game: stage += ['--game',args.game]
    if case.get('aggression_widget_test'):
        stage += ['--extra-widget',str(ROOT/'tools/widgets/gui_barb_team_link.lua'),
                  '--extra-widget',str(HERE/'widgets/aggression_watch.lua')]
    subprocess.run(stage, check=True)
    script = directory/'script.txt'
    script.write_text(script.read_text().replace('[GAME]\n{','[GAME]\n{\n FixedRNGSeed='+str(args.seed)+';',1))
    staged = directory/'AI/Skirmish/BARbTest/test'
    pool_symbols(staged)
    setup=staged/'script/src/setup.as'
    fixture_role=('(ai.teamId==0?AiRole::'+role+':AiRole::'+case['enemy_role']+')') if case.get('enemy_role') else 'AiRole::'+role
    setup.write_text(setup.read_text().replace('Global::AISettings::Role = derivedRole;',
        'derivedRole='+fixture_role+'; Global::AISettings::Role = derivedRole;'))
    for name,manager,wait in [('builder','aiBuilderMgr','TaskB::Wait(60*SECOND)'),('factory','aiFactoryMgr','TaskS::Wait(false,60*SECOND)')]:
        path = staged/'script/src/manager'/(name+'.as')
        source = path.read_text(); start = source.index('{',source.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))+1
        repair='\n if (ai.teamId==1 && !u.circuitDef.IsMobile()) return aiBuilderMgr.DefaultMakeTask(u);' if name=='builder' and case.get('enemy_repair') else ''
        if name=='builder' and case.get('friendly_repair'):
            repair+='\n if (ai.teamId==0 && !u.circuitDef.IsMobile()) return aiBuilderMgr.DefaultMakeTask(u);'
        condition = 'ai.teamId==1' if name=='factory' and case.get('production') else 'ai.frame>=0'
        if name=='builder' and case.get('builders'): condition = 'ai.teamId==1'
        if name=='builder' and case.get('commander_front_work'):
            condition = 'ai.teamId!=0 || !u.circuitDef.IsRoleAny(Unit::Role::COMM.mask)'
        if name=='builder' and case.get('production'):
            repair += '\n if (ai.teamId==0 && !u.circuitDef.IsMobile()) return aiBuilderMgr.DefaultMakeTask(u);'
        path.write_text(source[:start]+repair+'\n if ('+condition+') return '+manager+'.Enqueue('+wait+'); // supplied arena only\n'+source[start:])
    path = staged/'script/src/manager/military.as'
    source = path.read_text(); start = source.index('{',source.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))+1
    # Normal combat cases leave friendly commands to the AI. Production-only
    # cases can explicitly hold them to retain the supplied enemy demand.
    # The enemy follows a declared path or holds, with normal weapon firing.
    destination = case.get('enemy_destination')
    point = f'AIFloat3({destination[0]},0,{destination[1]})' if destination else 'u.GetPos(ai.frame)'
    if case.get('enemy_waypoints'):
        point = ','.join(f'AIFloat3({x},0,{z})' for x,z in case['enemy_waypoints'])
    override = '''
        if (ai.teamId==1 && u.circuitDef.IsMobile()) {
            CRouteTask@ route=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
            array<AIFloat3> points={'''+point+'''};
            route.SetTraversal(true,48,false); route.SetRoute(points); return route;
        } // enemy fixture only
'''
    if case.get('hold_friendly'):
        override += '''
        if (ai.teamId==0 && u.circuitDef.IsMobile()) {
            CRouteTask@ route=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
            array<AIFloat3> points={u.GetPos(ai.frame)};
            route.SetTraversal(true,48,false); route.SetRoute(points); return route;
        } // production-only fixture: retain army investment without clearing opponents
'''
    if case.get('native_route'):
        spec = case['native_route']
        points = ','.join(f'AIFloat3({x},0,{z})' for x,z in spec['points'])
        override += '''
        if (ai.teamId==0 && u.circuitDef.GetName()=="'''+case['unit']+'''") {
            if (FixtureRoute is null) {
                @FixtureRoute=cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
                array<AIFloat3> points={'''+points+'''};
                FixtureRoute.SetLanes('''+str(spec['lanes'])+','+str(spec['spacing'])+''',1);
                FixtureRoute.SetTraversal(false,'''+str(spec['radius'])+''',false);
                FixtureRoute.SetRoute(points);
            }
            return FixtureRoute;
        } // supplied route: exercise ordinary spam's native arrival/idle path
'''
    if case.get('hold_all'):
        override=override.replace('ai.teamId==0 && u.circuitDef.IsMobile()','u.circuitDef.IsMobile()')
    if case.get('enemy_commander_home'):
        # D-294: the opposing start commander carries radar; routed with the
        # fixture it escorts the supplied T3 and confounds concealed approaches.
        override=override.replace('if (ai.teamId==1 && u.circuitDef.IsMobile())',
            'if (ai.teamId==1 && u.circuitDef.IsMobile() && !u.circuitDef.IsRoleAny(Unit::Role::COMM.mask))',1)
    override=override.replace('ai.teamId==1','ai.teamId=='+str(case.get('enemy_team',1)))
    patched = source[:start]+override+source[start:]
    if case.get('native_route'): patched = 'CRouteTask@ FixtureRoute;\n'+patched
    path.write_text(patched)
    if 'aggression_delta' in case:
        path=staged/'script'/args.profile/'main.as'
        source=path.read_text(); start=source.index('{',source.index('void AiUpdate()'))+1
        path.write_text(source[:start]+'\n if (ai.teamId==0) aiMilitaryMgr.SetAggressionDelta('+str(float(case['aggression_delta']))+'f); // declared fixture offset\n'+source[start:])
    if case.get('commander_observation'):
        path=staged/'script'/args.profile/'main.as'
        source=path.read_text(); start=source.index('{',source.index('void AiUpdate()'))+1
        # Frozen economic builders never ask for an opening factory, so Setup's
        # usual role resolution does not run. Declare only the fixture role.
        source=source[:start]+'\n Global::AISettings::Role='+fixture_role+'; // commander fixture role\n'+source[start:]
        if case.get('enemy_commander_home'):
            # D-294: ...and its own commander control would deploy it with the T3.
            source=source[:start]+'\n if (ai.teamId=='+str(case.get('enemy_team',1))+' && ai.frame<2*SECOND) CommanderCombat::Override("enabled",0.f); // keep enemy commander home\n'+source[start:]
        # D-293: exercise the per-AI script override on team 0 only; it must
        # win over the profile JSON that CommanderCombat::Update applies.
        for key,value in case.get('commander_overrides',{}).items():
            source=source[:start]+'\n if (ai.teamId==0 && ai.frame<2*SECOND) CommanderCombat::Override("'+key+'",'+repr(float(value))+'f); // per-AI override fixture\n'+source[start:]
        declarations=''
        events=''
        for index,event in enumerate(case.get('commander_override_events',[])):
            key=event['key']
            if not re.fullmatch(r'[a-zA-Z0-9_.]+',key):raise ValueError('Invalid commander option key')
            flag='_CommanderFixtureEvent'+str(index)
            declarations+='bool '+flag+'=false;\n'
            action=('CommanderCombat::ClearOverride("'+key+'");' if event.get('clear') else
                    'CommanderCombat::Override("'+key+'",'+repr(float(event['value']))+'f);')
            events+='\n if(ai.teamId==0 && ai.frame>='+str(int(event['seconds']))+'*SECOND && !'+flag+') { '+flag+'=true; '+action+' }\n'
        if case.get('commander_lifecycle_probe'):
            declarations+='int _CommanderFixtureOperation=-1; bool _CommanderFixtureCompared=false;\n'
            events+='''
 if(ai.teamId==0 && ai.frame>=10*SECOND && _CommanderFixtureOperation<0)
     _CommanderFixtureOperation=aiBuilderMgr.GetCommanderOperation();
 if(ai.teamId==0 && ai.frame>=20*SECOND && !_CommanderFixtureCompared) {
     _CommanderFixtureCompared=true;
     AiLog(_CommanderFixtureOperation==aiBuilderMgr.GetCommanderOperation()
         ? "[RangedArena] lifecycle_operation_preserved"
         : "[RangedArena] ERROR unrelated_loss_changed_operation");
 }
'''
        source=source[:start]+events+source[start:]
        if case.get('commander_energy_test'):
            source=source[:start]+'''\n
 if (ai.teamId==0 && ai.frame==22*SECOND)
     TeamEconomy::SendEnergy(1,TeamEconomy::OwnEnergy(TeamEconomy::CURRENT)); // declared one-time bank drain
'''+source[start:]
        path.write_text(declarations+source)
    if case.get('trace_spam'):
        # Supplied buildings did not come through TECH's reserved layout.
        # Its geometry/economy Tick cannot judge this isolated production
        # fixture. Lifecycle OnUnitAdded and Spam's own invariants stay active.
        path=staged/'script/src/systems/diagnostics/invariants.as'
        source=path.read_text(); start=source.index('{',source.index('void Tick()'))+1
        path.write_text(source[:start]+'\n if (ai.frame>=0) return; // supplied-layout fixture only\n'+source[start:])
        path=staged/'script/src/systems/combat/spam.as'
        source=path.read_text(); start=source.index('{',source.index('void Update()'))+1
        probe='''
        if (ai.teamId==0 && ai.frame % (10*SECOND)==0) {
            GenericHelpers::LogUtil("[SpamProbe] workers="+aiBuilderMgr.GetWorkerCount(),1);
            array<int>@ ids=ai.GetOwnedUnitIds();
            for (uint i=0;i<ids.length();++i) {
                CCircuitUnit@ u=ai.GetTeamUnit(ids[i]);
                if (u is null || SpamUnitFor(u.circuitDef).length()==0) continue;
                GenericHelpers::LogUtil("[SpamProbe] factory="+u.id+" task="+(u.task is null ? -1 : int(u.task.GetType()))+" retiring="+Lifecycle::IsRetiring(u),1);
            }
        }
'''
        path.write_text(source[:start]+probe+source[start:])
    if args.variant=='siege':
        for path in (staged/'config').rglob('behaviour*.json'):
            data=path.read_bytes()
            for name in case.get('units',[case['unit']]):
                pattern=rb'("'+name.encode()+rb'"\s*:\s*\{)(.*?)(\n[ \t]*\},?)'
                match=re.search(pattern,data,re.S)
                if not match: continue
                block=re.sub(rb'("role"\s*:\s*)\[[^\]]*\]',rb'\1["artillery"]',match[2])
                if b'"attribute"' in block: block=re.sub(rb'("attribute"\s*:\s*)\[[^\]]*\]',rb'\1["siege"]',block)
                else: block=re.sub(rb'("role"[^\n]*\n)',rb'\1\t\t\t\t"attribute": ["siege"],\n',block)
                data=data[:match.start(2)]+block+data[match.end(2):]
            path.write_bytes(data)
    case.update(variant=args.variant,profile=args.profile,seed=args.seed,minutes=args.minutes,speed=args.speed,headless=args.headless)
    case['mode'] = getattr(args, 'mode', 'fast')
    if case['mode'] != 'visual':
        case['photos'] = []
    if case.get('fireline_observer'):
        # Read task ownership in the real host; never issue combat commands.
        profile=staged/'script'/args.profile/'main.as'
        source=profile.read_text()
        start=source.index('{',source.index('void AiUpdate()'))+1
        probe='''
        if (ai.teamId==0) {
            array<int>@ observed=ai.GetOwnedUnitIds();
            for (uint i=0;i<observed.length();++i) {
                CCircuitUnit@ unit=ai.GetTeamUnit(observed[i]);
                if (unit is null || unit.circuitDef.GetName()!="armmanni" || unit.task is null) continue;
                if (unit.task.GetType()==int(Task::Type::RETREAT)) AiLog("[INVARIANT] Starlight entered retreat");
                if (unit.GetHealthPercent()<.65f) AiLog("[FirelineTest] damaged gun holds native firing owner");
            }
        }
'''
        profile.write_text(source[:start]+probe+source[start:])
    config=directory/'LuaUI/Config';config.mkdir(parents=True,exist_ok=True)
    (config/'ranged_arena.lua').write_text('return '+lua(case)+'\n')
    (directory/'ranged-arena.json').write_text(json.dumps(case,indent=2)+'\n')
    pins={'dll_sha256':hashlib.sha256(args.dll.read_bytes()).hexdigest(),
          'diagnostics':{name:os.environ[name] for name in
              ('CIRCUIT_RANGED_TRACE','CIRCUIT_VERIFY_RANGED_QUERIES','CIRCUIT_VERIFY_RANGED_SNAPSHOT','CIRCUIT_PERF_PHASES','CIRCUIT_COMMANDER_TRACE')
              if name in os.environ},
          'files':{str(p.relative_to(staged)):storage.file_hash(p) for p in staged.rglob('*') if p.is_file() and p.suffix in ('.as','.json')},
          'observer_sha256':storage.file_hash(HERE/'widgets/ranged_arena.lua'),
          'overrides':['supplied forces','fixed seed','startup energy'] +
              ((['enemy factories and mobile builders frozen','scripted enemy path'] if case.get('production')
                else ['frozen economic builders/factories','scripted enemy path'])
               if args.profile.startswith('experimental_') else ['native legacy economy remains active'])}
    if case.get('commander_trace'):
        pins['diagnostics']['CIRCUIT_COMMANDER_TRACE']='1'
    if case.get('production'):
        pins['overrides'] += ['team 0 factories and static assistants active; mobile builders '+('active' if case.get('builders') else 'frozen')]
    if case.get('commander_front_work'):
        pins['overrides'] += ['team 0 commanders use real FRONT builder policy; other builders frozen']
    if case.get('trace_spam'):
        pins['overrides'] += ['TECH layout/economy invariant Tick disabled for supplied buildings; production/lifecycle and spam invariants retained', 'read-only factory task census every 10 seconds']
    if case.get('hold_friendly'):
        pins['overrides'] += ['friendly combat held for production measurement']
    if case.get('native_route'):
        pins['overrides'] += ['friendly ordinary native route and lane geometry supplied; arrival/idle mechanism test']
    (directory/'ranged-arena-pins.json').write_text(json.dumps(pins,indent=2)+'\n')
    subprocess.run([sys.executable,str(ROOT/'tools/knowledge/check_script_api.py'),'--dll',str(args.dll),'--scripts',str(staged/'script')],check=True)
    print('RANGED_ARENA='+str(directory),flush=True)
    return directory, command


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case',required=True)
    parser.add_argument('--dll',required=True,type=Path)
    parser.add_argument('--data',type=Path,default=ROOT/'data')
    parser.add_argument('--variant',choices=['baseline','siege','ranged'],default='ranged')
    parser.add_argument('--profile',default='experimental_balanced')
    parser.add_argument('--game',default=None,help='game archive name (default: the last lobby script\'s, via playtest.py)')
    parser.add_argument('--seed',type=int,default=2071)
    parser.add_argument('--minutes',type=int,default=4)
    parser.add_argument('--speed',type=int,default=20)
    parser.add_argument('--mode',choices=['fast','visual','performance'],default='fast')
    parser.add_argument('--headless',action='store_true')
    parser.add_argument('--stage-only',action='store_true')
    args=parser.parse_args();directory,command=prepare(args)
    if args.stage_only: return 0
    launch=command+['launch','--dir',str(directory),'--engine','recoil_2026.07.04']
    if args.headless: launch+=['--headless']
    # Validate before spawning; cleanup must also run if the watcher cannot start.
    case=json.loads((directory/'ranged-arena.json').read_text())
    playtest.validate_checks(case.get('checks','ranged-arena'))
    watch=command+['watch','--dir',str(directory),'--role',case.get('role','FRONT'),'--checks',case.get('checks','ranged-arena'),
        '--play-decided','--minutes',str(args.minutes),'--wall-minutes','8']
    # Supplied arenas can temporarily have no enemies between waves. Their
    # completion/grace contract (or fixed performance horizon) owns the end.
    try:
        environment=dict(os.environ)
        if case.get('commander_trace'):
            if args.mode=='performance':raise ValueError('Commander trace is diagnostic, not a performance input')
            environment['CIRCUIT_COMMANDER_TRACE']='1'
        subprocess.run(launch,check=True,env=environment)
        return subprocess.run(watch,check=False).returncode
    finally:
        subprocess.run(command+['stop','--dir',str(directory)],check=True)

if __name__=='__main__':sys.exit(main())
