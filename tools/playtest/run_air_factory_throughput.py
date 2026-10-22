"""Supplied AIR factory throughput and priority regression; no live installation."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import re
from analyze_factory_throughput import analyze
import ranged_arena


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', required=True, type=Path)
    parser.add_argument('--data', type=Path, default=ranged_arena.ROOT/'data')
    parser.add_argument('--side', choices=['armada','cortex','legion'], default='armada')
    parser.add_argument('--labs', type=int, choices=[1,6,9], default=6)
    parser.add_argument('--scenario', choices=['funded','growth','transport','energy-starved','ownership'], default='funded')
    parser.add_argument('--profile', default='experimental_balanced')
    parser.add_argument('--game', default='Beyond All Reason test-31578-8247b61')
    parser.add_argument('--variant', choices=['baseline','ranged'], default='ranged')
    parser.add_argument('--minutes', type=int, default=3)
    parser.add_argument('--speed', type=int, default=8)
    parser.add_argument('--seed', type=int, default=2071)
    parser.add_argument('--headless', action='store_true')
    args = parser.parse_args()
    case = json.loads((ranged_arena.HERE/'cases/air/economy/factory-throughput.json').read_text())
    case['side'] = args.side
    suffix = {'funded':'full','growth':'grow','transport':'ferry','energy-starved':'energy','ownership':'owner'}[args.scenario]
    case['storage_scenario'] = 'air-queue-'+args.side[:3]+str(args.labs)+'-'+suffix
    case['groups'][0]['count'] = args.labs
    if args.labs == 9:
        # The south-east grid cell is a mountain on Glitters. Keep the ninth
        # lab and its assistants on the same known-buildable northern plateau.
        case['groups'][0]['count'] = 8
        case['groups'].append({'unit':'armaap','count':1,'team':0,'position':[4400,2100]})
    support = [g for g in case['groups'] if g['unit']=='armnanotc']
    case['groups'] = [g for g in case['groups'] if g['unit']!='armnanotc']
    for index in range(args.labs):
        group = dict(support[0]); group['position'] = [2832+(index%3)*700,2580+(index//3)*700]
        if index == 8: group['position'] = [4232,1880]
        case['groups'].append(group)
    if args.scenario == 'energy-starved':
        case['groups'] = [g for g in case['groups'] if g['unit']!='armafus']
        case['start_energy'] = 0
        case['photos'] = [90,150]
        case['checks'] = 'factory-energy-starved'
    if args.scenario == 'transport':
        case['groups'].append({'unit':'armap','count':1,'team':0,'position':[5000,2500]})
    if args.side != 'armada':
        prefix = 'cor' if args.side=='cortex' else 'leg'
        for group in case['groups']:
            if group['team']==0:
                group['unit'] = prefix+group['unit'][3:]
        case['unit'] = prefix+'aap'
    with tempfile.TemporaryDirectory(prefix='air-throughput-') as temp:
        args.case = Path(temp)/'case.json'
        args.case.write_text(json.dumps(case))
        directory, command = ranged_arena.prepare(args)
    # Explicit fixture inputs, never installed in the runtime source. These
    # exercise the real callback/arbitration without a synthetic copy of it.
    main = directory/'AI/Skirmish/BARbTest/test/script'/args.profile/'main.as'
    source = main.read_text()
    start = source.index('{',source.index('void AiUpdate()'))+1
    probe = ''
    if args.scenario=='growth':
        probe = '\n if (ai.teamId==0) aiTerrainMgr.SetLayoutInt("air.techGrowth",1);\n'
    elif args.scenario=='transport':
        probe = '''
        if (ai.teamId==0 && ai.frame==110*SECOND) {
            Team::Ferry::requestPending=true; Team::Ferry::requestHeavy=true;
            Team::Ferry::requestTeam=0; Team::Ferry::requestPos=Global::Map::StartPos;
            Team::Ferry::orderedFrame=-1; Team::Ferry::buildingId=-1;
            GenericHelpers::LogUtil("[FactoryProbe] heavy transport requested",1);
        }
'''
    elif args.scenario=='ownership':
        probe = '''
        if (ai.teamId==0 && ai.frame==110*SECOND) {
            array<Id>@ ids=ai.GetOwnedUnitIds();
            for (uint i=0;i<ids.length();++i) {
                CCircuitUnit@ unit=ai.GetTeamUnit(ids[i]);
                if (unit is null || !UnitHelpers::IsT2AircraftPlant(unit.circuitDef.GetName())) continue;
                if (ai.UnitControl(unit,false)) GenericHelpers::LogUtil("[FactoryProbe] player ownership id="+unit.id,1);
                break;
            }
        }
'''
    main.write_text(source[:start]+probe+source[start:])
    pins_path = directory/'ranged-arena-pins.json'
    pins = json.loads(pins_path.read_text())
    pins['files'][str(main.relative_to(directory/'AI/Skirmish/BARbTest/test'))] = ranged_arena.storage.file_hash(main)
    if probe:
        pins['overrides'].append('AIR throughput fixture: '+args.scenario+' (exact injection in throughput-fixture.json)')
    pins_path.write_text(json.dumps(pins, indent=2)+'\n')
    (directory/'throughput-fixture.json').write_text(json.dumps({'scenario':args.scenario,'labs':args.labs,'side':args.side,'profile':args.profile,'probe':probe},indent=2))
    launch=command+['launch','--dir',str(directory),'--engine','recoil_2026.07.04']
    if args.headless: launch.append('--headless')
    subprocess.run(launch,check=True)
    verdict = subprocess.call(command+['watch','--dir',str(directory),'--role','AIR','--checks',case.get('checks','factory-throughput'),
        '--minutes',str(args.minutes),'--wall-minutes','8','--keep-going'])
    report = (directory/'report.md').read_text(encoding='utf-8')
    log = Path(re.search(r'^- Log: (.+)$', report, re.M)[1])
    result = analyze(log)
    problems = []
    labs = [v for v in result['factories'].values() if v['unit']==case['unit']]
    if len(labs)!=args.labs: problems.append('Missing observed T2 laboratories')
    if args.scenario in ('funded','growth','transport') and args.variant!='baseline':
        for laboratory in labs:
            if laboratory['samples']<2701 or laboratory['fundedEmpty']/laboratory['samples']>.05:
                problems.append('Funded laboratory queue empty for more than 5% of observation')
            if laboratory['completed']<1: problems.append('Laboratory completed no aircraft')
            if laboratory['build_commands']>laboratory['completed']+2:
                problems.append('Excess build commands relative to completed aircraft')
    if args.scenario=='transport':
        contents=log.read_text(encoding='utf-8',errors='replace')
        transport = {'armada': 'armhvytrans', 'cortex': 'corhvytrans', 'legion': 'legatrans'}[args.side]
        if '[FactoryProbe] heavy transport requested' not in contents or not re.search(r'finished .*unit='+transport+r'\b',contents):
            problems.append('Requested heavy transport was not completed')
    if args.scenario=='ownership':
        contents=log.read_text(encoding='utf-8',errors='replace')
        control=re.search(r'\[FactoryProbe\] player ownership id=(\d+)',contents)
        if not control: problems.append('Player ownership was not exercised')
        elif any(int(frame)>3330 for frame in re.findall(r'\[RangedArena\] frame=(\d+) factory_order id='+control[1]+r' ',contents)):
            problems.append('Factory received production orders after player takeover')
    result['problems']=problems
    (log.parent/'factory-throughput.json').write_text(json.dumps(result,indent=2)+'\n')
    print('THROUGHPUT_RESULT='+json.dumps(result),flush=True)
    return verdict or bool(problems)


if __name__=='__main__':
    raise SystemExit(main())
