"""Stage T3 ally-clear and active-turret donation checks in an isolated engine."""
import argparse
from pathlib import Path
import subprocess
import sys

from benchmark_store import RAW_ROOT

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dir', type=Path, required=True)
    parser.add_argument('--dll', type=Path, required=True)
    parser.add_argument('--profile', default='experimental_balanced')
    args = parser.parse_args()
    base = args.dir.resolve()
    if not base.is_relative_to(RAW_ROOT):
        parser.error('Use the external benchmark raw directory')
    subprocess.run([sys.executable, str(HERE / 'playtest.py'), 'stage', '--dir', str(base),
                    '--dll', str(args.dll.resolve()), '--map', 'All That Glitters v2.2.3',
                    '--roles', 'all', '--role', 'TECH', '--side', 'armada', '--bonus', '0',
                    '--minutes', '2', '--speed', '20', '--headless',
                    '--ai-option', 'profile=' + args.profile, '--modoption', 'deathmode=neverend',
                    '--modoption', 'startmetal=100000', '--modoption', 'startenergy=100000',
                    '--extra-widget', str(HERE / 'widgets/t3_pointer_safety.lua')], check=True)
    script = base / 'AI/Skirmish/BARbTest/test/script'
    (script / 't3_pointer_safety.as').write_text((ROOT / 'tests/t3_pointer_safety.as').read_text())
    main = script / args.profile / 'main.as'
    text = main.read_text(encoding='utf-8')
    text = '#include "../t3_pointer_safety.as"\n' + text
    at = text.index('{', text.index('void AiLuaMessage(')) + 1
    text = text[:at] + '\n if (data.findFirst("t3pointer|") == 0) { T3PointerFixture::Message(data); return; }\n' + text[at:]
    at = text.index('{', text.index('void AiUpdate()')) + 1
    text = text[:at] + '\n Global::Team::AllyClearEnabled = true; // supplied cross-profile protocol coverage\n' + text[at:]
    main.write_text(text, encoding='utf-8')
    print(base)


if __name__ == '__main__':
    main()
