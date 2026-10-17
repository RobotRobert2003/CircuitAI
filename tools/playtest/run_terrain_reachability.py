"""Actual native reachability boundaries and builder recovery from an invalid site."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

import playtest
import storage
from run_retirement_regression import inject_entry


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pin', type=Path, required=True)
    parser.add_argument('--profile', default='experimental_balanced')
    args = parser.parse_args()
    directory = storage.allocate('shared', 'reliability', 'terrain-reach', 'glitters', 'supplied', seed=3141)
    print('TERRAIN_REACH_DIRECTORY='+str(directory), flush=True)
    starts = directory/'starts.as'
    starts.write_text('StartSpot(AIFloat3(2000,0,2000), AiRole::FRONT, false),\n'
                      'StartSpot(AIFloat3(5000,0,8500), AiRole::FRONT, false),\n')
    call = [sys.executable, str(playtest.HERE/'playtest.py')]
    subprocess.run(call+['stage', '--dir', str(directory), '--dll', str(args.pin/'SkirmishAI.dll'),
        '--data', str(args.pin/'data'), '--map', 'All That Glitters v2.2.3', '--map-file', str(starts),
        '--engine', 'recoil_2026.07.04', '--role', 'FRONT', '--roles', 'FRONT', '--side', 'armada',
        '--ai-option', 'profile='+args.profile, '--ai-option', 'random_seed=3141', '--bonus', '0',
        '--mode', 'fast', '--speed', '20', '--minutes', '2', '--headless', '--shots', '',
        '--modoption', 'deathmode=neverend', '--modoption', 'startmetal=100000',
        '--modoption', 'startmetalstorage=1000000', '--modoption', 'startenergy=1000000',
        '--modoption', 'startenergystorage=1000000', '--extra-widget',
        str(playtest.HERE/'widgets/terrain_reachability_watch.lua')], check=True)
    source = directory/'AI/Skirmish/BARbTest/test/script/src'
    (source/'terrain_reachability_probe.as').write_bytes((playtest.HERE/'fixtures/terrain_reachability_probe.as').read_bytes())
    profile = source.parent/args.profile/'main.as'
    profile.write_text('#include "../src/terrain_reachability_probe.as"\n'+profile.read_text())
    inject_entry(profile, 'void AiLuaMessage(const string& in data)', 'if (TerrainReachProbe::Handle(data)) return;')
    inject_entry(source/'roles/front/front.as', 'void Front_EconomyUpdate()', 'if (ai.teamId >= 0) return;')
    inject_entry(source/'systems/construction/commander_front.as', 'void Update()',
                 'if (ai.teamId >= 0) { aiBuilderMgr.SetCommanderCombatOption("front_duty",0); return; }')
    inject_entry(source/'manager/builder.as', 'IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
                 'if (ai.teamId >= 0) return TerrainReachProbe::Task(u);')
    inject_entry(source/'manager/factory.as', 'IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
                 'if (ai.teamId >= 0) return aiFactoryMgr.Enqueue(TaskS::Wait(false, SECOND));')
    inject_entry(source/'systems/diagnostics/invariants.as', 'void Tick()', 'if (ai.frame >= 0) return;')
    checks = directory/'terrain-reach-checks.json'
    labels = ['queries kind='+str(i) for i in range(3)]+['null_unit', 'invalid_task_aborted', 'physical_valid_turret']
    checks.write_text(json.dumps({'stop_minute':2,
        'complete_on':{'key':'complete','pattern':r'\[TerrainReachTest\] PASS physical_valid_turret','scope':'any'},
        'completion_grace_seconds':10,
        'expect':[{'key':label,'pattern':r'\[TerrainReachTest\] PASS '+label,'by_minute':2,'scope':'any'} for label in labels],
        'forbid':[{'key':'failure','pattern':r'\[TerrainReachTest\] FAIL|: ERR\s+:|\.as \(\d+,\s*\d+\)\s*:\s*WARN\s*:|SCRIPT CRASH|Lib exception|Access violation|has crashed|Fatal:|Error in.*terrain_reachability','scope':'any'}]},indent=2))
    (directory/'terrain-reach-inputs.json').write_text(json.dumps({'profile':args.profile,
        'overrides':['supplied air constructor and turret; resource banks',
                     'ordinary economy, work and whole-base periodic invariants suspended',
                     'real native queries, builder task abort and physical legal-site recovery'],
        'scripts':{str(p.relative_to(source.parent)):storage.file_hash(p) for p in source.parent.rglob('*.as')},
        'widget_sha256':storage.file_hash(directory/'LuaUI/Widgets/terrain_reachability_watch.lua')},indent=2))
    try:
        subprocess.run(call+['launch','--dir',str(directory),'--engine','recoil_2026.07.04','--headless'],check=True)
        return subprocess.call(call+['watch','--dir',str(directory),'--role','FRONT','--minutes','2',
            '--wall-minutes','6','--checks',str(checks)])
    finally:
        subprocess.run(call+['stop','--dir',str(directory)],check=False)


if __name__ == '__main__':
    sys.exit(main())
