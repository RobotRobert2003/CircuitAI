"""Prepare isolated AIR fixtures after playtest.py stage; never edits production data."""
from script_settings import role_settings_path
import argparse
import json
from pathlib import Path
from benchmark_store import RAW_ROOT
import re

ROOT = Path(__file__).resolve().parents[2]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dir', type=Path, required=True)
    parser.add_argument('--scenario', choices=['natural', 'constructor', 'growth', 'transport', 'capacity', 'loss', 'windloss', 'switch', 'attack', 'screen', 'idle', 'legacy', 'defence'], default='natural')
    parser.add_argument('--seed', type=int, default=930146)
    args = parser.parse_args()
    base = args.dir.resolve()
    if not base.is_relative_to((RAW_ROOT).resolve()):
        parser.error('fixture directory must be under benchmark-repository build-theatres')
    script = base / 'script.txt'
    text = script.read_text()
    text = re.sub(r'\bFixedRNGSeed\s*=\s*\d+;', '', text, flags=re.I)
    text = text.replace('[GAME]\n{', '[GAME]\n{\n\tFixedRNGSeed=' + str(args.seed) + ';', 1)
    if 'FixedRNGSeed=' not in text:
        text = re.sub(r'(\[GAME\]\s*\{)', r'\1\n FixedRNGSeed=' + str(args.seed) + ';', text, count=1, flags=re.I)
    if args.seed <= 0:
        parser.error('Use a positive seed')
    # Engine RNG and CircuitAI RNG are separate. Pin both for reproducible
    # fixtures; the first AI initializes the process-shared game attribute.
    text = re.sub(r'\brandom_seed\s*=\s*\d+;', '', text, flags=re.I)
    def pin_ai(match):
        block = match[0]
        option = re.search(r'\[OPTIONS\]\s*\{', block, re.I)
        setting = '\n random_seed=' + str(args.seed) + ';'
        if option:
            return block[:option.end()] + setting + block[option.end():]
        return block[:-1] + '\n [OPTIONS]\n {' + setting + '\n }\n }'
    text, count = re.subn(r'\[AI\d+\]\s*\{.*?\}', pin_ai, text, flags=re.I | re.S)
    if count == 0:
        parser.error('No AI sections to seed')
    script.write_text(text)
    config = {'scenario': args.scenario, 'seed': args.seed, 'engine_seed': args.seed, 'ai_seed': args.seed}
    (base / 'air-fixture.json').write_text(json.dumps(config, indent=2))
    widgets = base / 'LuaUI/Widgets'
    if args.scenario not in ['natural', 'legacy']:
        (widgets / 'air_fixture.lua').write_text('local scenario = ' + json.dumps(args.scenario) + '\n' + (ROOT / 'tools/playtest/widgets/air_fixture.lua').read_text())
    if args.scenario == 'legacy':
        path = role_settings_path(base / 'AI/Skirmish/BARbTest/test/script/src', 'Air')
        source = path.read_text()
        before, marker, after = source.partition('namespace Air {')
        if not marker or 'bool ExperimentalBuild = true;' not in after:
            parser.error('staged AIR flag not found')
        path.write_text(before + marker + after.replace('bool ExperimentalBuild = true;', 'bool ExperimentalBuild = false;', 1))
    if args.scenario == 'screen':
        # Isolate screen geometry at supplied fleet sizes, independent of economy.
        path = role_settings_path(base / 'AI/Skirmish/BARbTest/test/script/src', 'Air')
        path.write_text(path.read_text().replace('int HomeFighterFloor = 6;', 'int HomeFighterFloor = 60;'))
    if args.scenario == 'defence':
        # Bound fixture load; six-plus-bay capacity has its own full stress test.
        path = role_settings_path(base / 'AI/Skirmish/BARbTest/test/script/src', 'Air')
        path.write_text(path.read_text().replace('int MaxProductionBays = 0;', 'int MaxProductionBays = 3;'))
    if args.scenario == 'idle':
        # Force a real idle interval only in the staged test controller.
        path = base / 'AI/Skirmish/BARbTest/test/script/src/systems/air/air_production.as'
        source = path.read_text()
        marker = 'const bool basic = UnitHelpers::IsT1AircraftPlant(name);'
        if marker not in source:
            parser.error('AIR production fixture insertion point not found')
        source = source.replace(marker, marker + '''
        if (ai.teamId == 0 && basic && ai.frame >= 10800 && ai.frame < 14400) {
            GenericHelpers::LogUtil("[AIR][Fixture] factory idle interval", 1);
            return aiFactoryMgr.Enqueue(TaskS::Wait(false, 3 * SECOND));
        }''', 1)
        path.write_text(source)
    if args.scenario in ['transport', 'screen', 'defence']:
        # Real allied-message protocol; two roles request together, one duplicate.
        staged = base / 'AI/Skirmish/BARbTest/test/script'
        for profile in ['experimental_balanced', 'experimental_hard', 'experimental_terrible']:
            path = staged / profile / 'main.as'
            source = path.read_text()
            source = source.replace('ArtilleryPolicy::Check();', '''ArtilleryPolicy::Check();
        if (!airProbeRequested && ai.teamId != 0 && ai.frame >= 1800 && ai.frame < 1900) {
            airProbeRequested = true;
            Team::Ferry::RequestTransport("AIR fixture: any allied role");
            AiSendMessage("barbferry|req|" + int(Global::Map::StartPos.x) + "|" + int(Global::Map::StartPos.z));
        }''')
            source += '\nnamespace Main { bool airProbeRequested = false; }\n'
            path.write_text(source)
    print('AIR fixture:', args.scenario, 'seed', args.seed, base)

if __name__ == '__main__':
    main()
