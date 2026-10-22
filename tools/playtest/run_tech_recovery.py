"""Focused TECH layout loss and gantry completion checks (supplied, not timing benchmarks)."""
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
    parser.add_argument('--dll', type=Path, required=True)
    parser.add_argument('--data', type=Path, required=True)
    parser.add_argument('--scenario', choices=('recovery', 'gantry'), required=True)
    parser.add_argument('--profile', default='experimental_balanced')
    args = parser.parse_args()
    directory = storage.allocate('tech', 'economy', 'recovery-'+args.scenario, 'supreme', 'supplied', seed=3061)
    print('TECH_RECOVERY_DIRECTORY='+str(directory), flush=True)
    call = [sys.executable, str(playtest.HERE/'playtest.py')]
    subprocess.run(call+['stage', '--dir', str(directory), '--dll', str(args.dll), '--data', str(args.data),
        '--map', 'Supreme Isthmus v1.7', '--engine', 'recoil_2026.07.04', '--role', 'TECH', '--roles', 'TECH',
        '--side', 'armada', '--ai-option', 'profile='+args.profile, '--ai-option', 'random_seed=3061',
        '--bonus', '0', '--mode', 'fast', '--speed', '20', '--minutes', '8', '--shots', '', '--lean-render',
        '--modoption', 'deathmode=neverend', '--modoption', 'startmetal=100000',
        '--modoption', 'startmetalstorage=1000000', '--modoption', 'startenergy=1000000',
        '--modoption', 'startenergystorage=1000000', '--extra-widget', str(playtest.HERE/'widgets/tech_recovery_watch.lua')], check=True)
    source = directory/'AI/Skirmish/BARbTest/test/script/src'
    (source/'tech_recovery_probe.as').write_bytes((playtest.HERE/'fixtures/tech_recovery_probe.as').read_bytes())
    profile = source.parent/args.profile/'main.as'
    profile.write_text('#include "../src/tech_recovery_probe.as"\n'+profile.read_text())
    inject_entry(profile, 'void AiLuaMessage(const string& in data)', 'if (TechRecoveryProbe::Handle(data)) return;')
    inject_entry(source/'roles/tech/tech.as', 'void Tech_EconomyUpdate()', 'if (ai.teamId >= 0) { TechRecoveryProbe::Tick(); return; }')
    economy = source/'manager/economy.as'
    economy.write_text(economy.read_text().replace('_UpdateSlidingMinima(ai.frame, metal.income, energy.income);',
        '_UpdateSlidingMinima(ai.frame, TechRecoveryProbe::MetalIncome(), energy.income);'))
    inject_entry(source/'manager/builder.as', 'IUnitTask@ AiMakeTask(CCircuitUnit@ u)', 'if (ai.teamId >= 0) return TechRecoveryProbe::Task(u);')
    if args.scenario == 'recovery':
        inject_entry(source/'manager/factory.as', 'IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
                     'if (ai.teamId >= 0) return aiFactoryMgr.Enqueue(TaskS::Wait(false, SECOND));')
    # Supplied buildings deliberately bypass natural layout creation. Periodic
    # whole-base geometry checks cannot judge them; admission invariants stay on.
    inject_entry(source/'systems/diagnostics/invariants.as', 'void Tick()', 'if (ai.frame >= 0) return;')
    widget = directory/'LuaUI/Widgets/tech_recovery_watch.lua'
    widget.write_text(widget.read_text().replace('__MODE__', args.scenario))
    pattern = r'\[TechRecoveryTest\] PASS '+('all_waves converter_rebuilt_low_income' if args.scenario == 'recovery' else 'gantry_three_refills')
    checks = directory/'tech-recovery-checks.json'
    checks.write_text(json.dumps({'stop_minute':8, 'complete_on':{'key':'complete','pattern':pattern,'scope':'any'},
        'completion_grace_seconds':5, 'expect':[{'key':'physical outcome', 'pattern':pattern, 'by_minute':8, 'scope':'any'}],
        'forbid':[{'key':'failure','pattern':r'\[TechRecoveryTest\] FAIL|\[INVARIANT\]|: ERR\s+:|SCRIPT CRASH|Lib exception|Access violation|has crashed|Fatal:|Error in.*tech_recovery','scope':'any'}]}, indent=2))
    if args.scenario == 'recovery':
        contract = json.loads(checks.read_text())
        contract['expect'].append({'key':'dedicated reactor worker chooses conversion','pattern':r'\[TechRecoveryTest\] PASS dedicated_converter_precedes_afus income=8','by_minute':8,'scope':'any'})
        checks.write_text(json.dumps(contract, indent=2))
    (directory/'tech-recovery-inputs.json').write_text(json.dumps({'scenario':args.scenario,'profile':args.profile,
        'overrides':['supplied force/banks','controlled sliding income','ordinary economy Tick suspended',
                     'initial explicit persistent slots; wave 1 real TECH rules, wave 2 dedicated AFUS worker',
                     'extra workers held or assisting between waves','base geometry Tick suspended'],
        'files':{str(p.relative_to(directory)):storage.file_hash(p) for p in source.parent.rglob('*.as')},
        'widget_sha256':storage.file_hash(widget)},indent=2))
    try:
        subprocess.run(call+['launch','--dir',str(directory),'--engine','recoil_2026.07.04'], check=True)
        return subprocess.call(call+['watch','--dir',str(directory),'--role','TECH','--minutes','8',
                                    '--wall-minutes','10','--checks',str(checks)])
    finally:
        subprocess.run(call+['stop','--dir',str(directory)], check=False)


if __name__ == '__main__':
    sys.exit(main())
