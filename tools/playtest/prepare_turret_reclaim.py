"""Stage a supplied, isolated turret interruption fixture; never writes the live install."""
import argparse
import json
from pathlib import Path
from benchmark_store import RAW_ROOT
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dir', type=Path, required=True)
    p.add_argument('--dll', type=Path, required=True)
    p.add_argument('--profile', default='experimental_balanced')
    args = p.parse_args()
    base = args.dir.resolve()
    if not base.is_relative_to(RAW_ROOT):
        p.error('Use an isolated directory under build-theatres')
    subprocess.run([sys.executable, str(HERE / 'playtest.py'), 'stage', '--dir', str(base),
        '--dll', str(args.dll.resolve()), '--map', 'Supreme Isthmus v1.7', '--role', 'TECH',
        '--roles', 'TECH', '--side', 'armada', '--bonus', '0', '--minutes', '9', '--speed', '5',
        '--shots', '', '--width', '1280', '--height', '720', '--lean-render',
        '--ai-option', 'profile=' + args.profile, '--modoption', 'experimentalextraunits=1',
        '--modoption', 'experimentallegionfaction=1', '--modoption', 'deathmode=neverend',
        '--modoption', 'startmetal=100000', '--modoption', 'startmetalstorage=100000',
        '--modoption', 'startenergy=100000', '--modoption', 'startenergystorage=100000',
        '--extra-widget', str(HERE / 'widgets/turret_reclaim.lua')], check=True)
    staged = base / 'AI/Skirmish/BARbTest/test/script'
    if args.profile.startswith('experimental_'):
        for name in ('builder', 'factory'):
            path = staged / 'src/manager' / (name + '.as')
            text = path.read_text()
            at = text.index('{', text.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)')) + 1
            hook = '\n if (ai.frame >= 0) return aiBuilderMgr.Enqueue(TaskB::Wait(60 * SECOND)); // fixture only\n'
            if name == 'factory':
                hook = '''
 if (u.circuitDef.GetName().findFirst("nanotc") >= 0) {
     // Exercise the same ordinary repair work and no_disrupt binding under all roles.
     if (u.circuitDef.GetName().findFirst("2") >= 0) u.AddAttribute(aiAttrMasker.GetTypeMask("no_disrupt").type);
     return aiFactoryMgr.DefaultMakeTask(u);
 }
 if (ai.frame >= 0) return aiFactoryMgr.Enqueue(TaskS::Wait(false, 60 * SECOND)); // fixture only
'''
            path.write_text(text[:at] + hook + text[at:])
        path = staged / args.profile / 'main.as'
        text = path.read_text()
        at = text.index('{', text.index('void AiUpdate()')) + 1
        text = text[:at] + '\n if (ai.teamId == 1 && Global::profileController !is null && Global::AISettings::Role != AiRole::FRONT) Commands::SwitchRole("FRONT"); // fixture only\n' + text[at:]
        at = text.index('{', text.index('void AiLuaMessage(')) + 1
        hook = '''
        if (data.findFirst("turretfixture|player|") == 0) {
            array<string>@ parts = data.split("|");
            if (parts.length() == 3) ai.UnitControl(parseInt(parts[2]), false);
            return;
        }
'''
        path.write_text(text[:at] + hook + text[at:])
    config = base / 'LuaUI/Config/turret_reclaim.lua'
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text('return {roles=' + ('true' if args.profile.startswith('experimental_') else 'false') + '}\n')
    (base / 'turret-fixture.json').write_text(json.dumps({
        'profile': args.profile, 'scenario': 'turret-enemy-reclaim', 'supplied': True,
        'overrides': ['full initial stores', 'explicit LOS', 'supplied friendly repair sites and enemies',
                      'experimental mobile builders/factories wait; turrets use native repair chooser',
                      'extra turrets marked no_disrupt', 'sequential role handoffs',
                      'enemy role FRONT with frozen constructors',
                      'explicit lifecycle capture/neutrality/range/destruction/player control',
                      'legacy only: remove nonsupplied initial units, use stationary enemy storage targets']}, indent=2))
    print(base)


if __name__ == '__main__':
    main()
