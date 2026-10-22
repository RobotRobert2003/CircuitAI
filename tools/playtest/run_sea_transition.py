"""Supreme SEA mex/seaplane acceptance with real role decisions (supplied capital)."""
from script_settings import role_settings_path, role_script_path
import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
import playtest
import storage
from air_arena import lua


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll', type=Path, required=True)
    p.add_argument('--data', type=Path, default=playtest.REPO / 'data', help='Pinned script/profile baseline')
    p.add_argument('--game', default=None)
    p.add_argument('--side', choices=['armada', 'cortex', 'legion'], default='armada')
    p.add_argument('--experimental', action='store_true')
    p.add_argument('--natural', action='store_true', help='Ordinary resources, no supplied units, active opponent')
    p.add_argument('--minutes', type=int, default=10)
    p.add_argument('--capacity', action='store_true', help='Observe commander handoff and constructed factory support')
    p.add_argument('--support-limit', type=int, help='Explicit configured saturation fixture; zero disables new yard turrets')
    a = p.parse_args()
    d = storage.allocate('sea', 'economy', ('capacity-' if a.capacity else 'seaplane-') + a.side + ('-eco' if a.natural else ''), 'supreme', 'benchmark' if a.natural else 'supplied', seed=2091)
    print('SEA_TRANSITION_DIRECTORY=' + str(d), flush=True)
    call = [sys.executable, str(playtest.HERE / 'playtest.py')]
    stage = call + ['stage', '--dir', str(d), '--dll', str(a.dll), '--data', str(a.data),
        '--map', 'Supreme Isthmus v1.7', *(['--game',a.game] if a.game else []),
        '--engine', 'recoil_2026.07.04', '--role', 'SEA', '--roles', 'SEA', '--side', a.side,
        '--bonus', '0', '--ai-option', 'profile=experimental_balanced', '--ai-option', 'random_seed=2091',
        '--speed', '10', '--minutes', str(a.minutes), '--shots', '1@3200@6200:11000,3@3800@6200:11000,8@4000@6200:11000',
        '--width', '1280', '--height', '720', '--lean-render', '--modoption', 'deathmode=neverend',
        '--modoption', 'startmetal=100000', '--modoption', 'startmetalstorage=100000',
        '--modoption', 'startenergy=1000000', '--modoption', 'startenergystorage=1000000',
        '--extra-widget', str(playtest.HERE / 'widgets/sea_transition_watch.lua'),
        '--extra-widget', str(playtest.HERE / 'widgets/sea_watch.lua')]
    if a.natural:
        for option in ['startmetal=100000', 'startmetalstorage=100000', 'startenergy=1000000', 'startenergystorage=1000000']:
            at = stage.index(option); del stage[at-1:at+1]
        stage[stage.index('--shots')+1] = '5@3800@6200:11000,10@4200@6200:11000,20@4800@6200:11000,29@4800@6200:11000'
    if a.capacity:
        stage += ['--extra-widget',str(playtest.HERE/'widgets/sea_capacity_watch.lua')]
    subprocess.run(stage, check=True)
    src = d / 'AI/Skirmish/BARbTest/test/script/src'
    g = role_settings_path(src, 'Sea')
    before, sea = g.read_text().split('namespace Sea {', 1)
    sea = re.sub(r'bool ExperimentalBuild = (true|false);', 'bool ExperimentalBuild = ' + str(a.experimental).lower() + ';', sea, count=1)
    if a.support_limit is not None:
        if a.support_limit < 0: p.error('--support-limit must be nonnegative')
        sea = re.sub(r'int MaxSupportPerBerth = \d+;', 'int MaxSupportPerBerth = ' + str(a.support_limit) + ';', sea, count=1)
    g.write_text(before + 'namespace Sea {' + sea)
    # Opponent frozen; tested SEA builder/factory delegates are untouched.
    for name, manager, wait in [('builder', 'aiBuilderMgr', 'TaskB::Wait(SECOND)'), ('factory', 'aiFactoryMgr', 'TaskS::Wait(false,SECOND)')]:
        if a.natural:
            continue
        f = src / 'manager' / (name + '.as')
        s = f.read_text(); at = s.index('{', s.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)'))
        f.write_text(s[:at+1] + '\n if (ai.teamId!=0) return ' + manager + '.Enqueue(' + wait + ');\n' + s[at+1:])
    # Read-only script observer of the reserved support footprint.
    f = role_script_path(src, 'sea_build'); s = f.read_text(); needle = 'LayoutHelpers::CheckAlliedPlacements();'
    s = s.replace(needle, needle + '''
        if (ai.teamId==0 && ai.frame%(30*SECOND)<SECOND) {
            for (uint factoryIndex=0;factoryIndex<SeaEconomy::productionFactories.length();++factoryIndex) {
                CCircuitUnit@ yard=ai.GetTeamUnit(SeaEconomy::productionFactories[factoryIndex]);
                if (yard is null) continue;
                CCircuitDef@ product=SeaEconomy::Product(yard.id);
                GenericHelpers::LogUtil("[SeaCapacityDemand] yard="+yard.id+" local="+SeaEconomy::LocalPower(yard)
                    +" target="+SeaEconomy::SupportTarget(yard,product)+" pressure="+SeaEconomy::capacityPressure
                    +" turrets="+SeaBuild::CompletedSupport(yard)+" energyTarget="+SeaEconomy::HomeEnergyTarget(),1);
            }
            CCircuitDef@ pd=ai.GetCircuitDef(UnitHelpers::GetSeaplanePlatformNameForSide(Global::AISettings::Side));
            GenericHelpers::LogUtil("[SeaTransition] gate t2="+SeaFactories::T2Finished(Global::AISettings::Side)
                +" need="+SeaFactories::NeedSeaplane(Global::AISettings::Side)+" available="+pd.IsAvailable(ai.frame)
                +" queued="+aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::FACTORY),pd),1);
            for (uint i=0;i<SeaLayout::berths.length();++i) {
                SeaLayout::Berth@ b=SeaLayout::berths[i];
                if (b.slot<0 || !UnitHelpers::IsSeaplanePlatform(b.name)) continue;
                const int n=SupportFootprint(ai.GetCircuitDef(UnitHelpers::GetT1NavalNanoNameForSide(Global::AISettings::Side)),b.centre);
                GenericHelpers::LogUtil("[SeaTransition] footprint slots="+n+" platform="+b.name,1);
            }
        }
''')
    if a.support_limit is not None:
        # Fixture-only diagnostics: measure why actual role admission fails,
        # without introducing periodic logging in the shipped scripts.
        s=s.replace('IUnitTask@ CapacityFactory(CCircuitUnit@ u) {', '''int capacityProbeFrame=-1;
    IUnitTask@ CapacityFactory(CCircuitUnit@ u) {
        const bool probe=ai.teamId==0 && ai.frame-capacityProbeFrame>=30*SECOND;
        if (probe) {
            capacityProbeFrame=ai.frame;
            GenericHelpers::LogUtil("[CapacityProbe] selfVisible="+aiTerrainMgr.IsAreaVisible(u.GetPos(ai.frame),0)+" radarVisible="+aiTerrainMgr.IsAreaVisible(AIFloat3(6900,0,9700),0),1);
            GenericHelpers::LogUtil("[CapacityProbe] worker="+u.id+" pressure="+SeaEconomy::capacityPressure+" factories="+SeaEconomy::productionFactories.length()+" mex="+SeaEconomy::mexWorker,1);
            for (uint i=0;i<SeaLayout::berths.length();++i) {
                SeaLayout::Berth@ b=SeaLayout::berths[i];
                if (b.slot<0 || b.active || b.retired) continue;
                CCircuitDef@ d=ai.GetCircuitDef(b.name);
                GenericHelpers::LogUtil("[CapacityProbe] berth="+b.key+" forward="+SeaLayout::ForwardSite(d,b.centre,b.facing)+" visible="+SeaLayout::VisibleBuffer(d,b.centre,b.facing)+" centreVisible="+aiTerrainMgr.IsAreaVisible(b.centre,0),1);
            }
            for (uint i=0;i<SeaEconomy::projects.length();++i) {
                IBuilderTask@ p=cast<IBuilderTask>(SeaEconomy::projects[i]);
                if (p !is null && !p.IsDead()) GenericHelpers::LogUtil("[CapacityProbe] project="+p.buildDef.GetName()+" kind="+p.GetBuildType()+" frame="+(p.target !is null)+" workers="+p.GetUnits().length(),1);
            }
        }
''')
        s=s.replace('if (task is null) continue;\n            SeaEconomy::Admit(definition', 'if (probe) GenericHelpers::LogUtil("[CapacityProbe] placement="+definition.GetName()+" success="+(task !is null),1);\n            if (task is null) continue;\n            SeaEconomy::Admit(definition')
    f.write_text(s)
    (d / 'LuaUI/Config').mkdir(parents=True, exist_ok=True)
    (d / 'LuaUI/Config/sea_transition.lua').write_text('return ' + lua({'side': a.side, 'supplied': not a.natural, 'overflow': a.support_limit is not None}) + '\n')
    pins = {'supplied': not a.natural, 'experimental': a.experimental, 'side': a.side,
        'dll_sha256': hashlib.sha256(a.dll.read_bytes()).hexdigest(),
        'data': {str(f.relative_to(src.parent.parent)): hashlib.sha256(f.read_bytes()).hexdigest() for f in src.parent.parent.rglob('*') if f.is_file()}}
    (d / 'sea-transition-pins.json').write_text(json.dumps(pins, indent=2))
    # Lossless NTFS compression avoids another 389 MB debug-symbol copy on
    # this host; files stay byte-identical and archives retain original pins.
    subprocess.run(['compact.exe', '/C', '/EXE:LZX', '/I', '/Q', str(src.parent.parent / 'SkirmishAI.dbg')], check=False)
    subprocess.run([sys.executable, str(playtest.REPO / 'tools/knowledge/check_script_api.py'), '--dll', str(a.dll), '--scripts', str(src.parent)], check=True)
    subprocess.run(call + ['launch', '--dir', str(d), '--engine', 'recoil_2026.07.04'], check=True)
    checks=('sea/economy/capacity-natural.json' if a.natural else 'sea/economy/production-capacity.json') if a.capacity else ('sea/economy/seaplane-natural.json' if a.natural else 'sea/economy/seaplane-transition.json')
    if a.support_limit is not None: checks = 'sea/economy/capacity-overflow.json'
    result = subprocess.run(call + ['watch', '--dir', str(d), '--role', 'SEA', '--checks', checks,
        '--minutes', str(a.minutes), '--wall-minutes', '15', '--keep-going']).returncode
    if a.support_limit is not None:
        archive = max((d / 'runs').iterdir(), key=lambda entry: entry.name)
        admissions, completed = {}, []
        for line in (archive / 'infolog.txt').read_text(errors='replace').splitlines():
            frame = re.search(r'\[f=0*(\d+)\]', line)
            if not frame: continue
            admitted = re.search(r'\[SEA\]\[Capacity\] overflow factory=(\w+)', line)
            finished = re.search(r'SeaCapacity\] factory_completed (\w+)', line)
            if admitted: admissions.setdefault(admitted[1], int(frame[1]))
            if finished and finished[1] in admissions and int(frame[1]) >= admissions[finished[1]]:
                completed.append(dict(unit=finished[1], frame=int(frame[1]), admitted=admissions[finished[1]]))
        # A normal opening yard completed before overflow admission is not
        # evidence that the fallback succeeded. Preserve the runner verdict.
        (archive / 'overflow-acceptance.json').write_text(json.dumps(dict(support_limit=a.support_limit,
            admissions=admissions, completed=completed, passed=bool(completed)), indent=2))
        print('SEA overflow completion: ' + ('PASS' if completed else 'FAIL'), flush=True)
        result = result or int(not completed)
    return result


if __name__ == '__main__':
    sys.exit(main())
