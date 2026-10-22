"""Isolated rendered blueprint/resource regression; preserves all raw runs."""
import argparse
import subprocess
import sys
from pathlib import Path
import storage

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--map', choices=['supreme', 'metal-plate'], required=True)
    parser.add_argument('--dll', type=Path, required=True)
    parser.add_argument('--stage-only', action='store_true')
    args = parser.parse_args()
    game = storage.allocate('shared', 'layout', 'blueprints', args.map, 'regression')
    print('BLUEPRINT_GAME=' + str(game), flush=True)
    extra = []
    if args.map == 'metal-plate':
        first = [(1400, 1200, 'TECH'), (3400, 900, 'AIR')]
        spots = first + [(12288-x, 12288-z, role) for x, z, role in first]
        fixture = '#include "../types/start_spot.as"\nnamespace BlueprintPlate {\nStartSpot@[] spots = {\n'
        fixture += ',\n'.join(f'StartSpot(AIFloat3({x},0,{z}),AiRole::{role},false)' for x, z, role in spots)
        fixture += '\n};\ndictionary limits;\nMapConfig config=MapConfig("Full Metal Plate",limits,spots,null);\n}\n'
        map_file = game / 'blueprint_plate.as'
        map_file.write_text(fixture)
        extra = ['--map-file', str(map_file)]
    role = 'SEA' if args.map == 'supreme' else 'TECH'
    name = 'Supreme Isthmus v1.7' if args.map == 'supreme' else 'Full Metal Plate 1.7'
    def run(tool, *params):
        subprocess.run([sys.executable, str(HERE/tool), *map(str, params)], cwd=ROOT, check=True)
    run('playtest.py', 'stage', '--dir', game, '--dll', args.dll, '--map', name,
        '--roles', 'AIR,TECH,SEA' if role == 'SEA' else 'AIR,TECH', '--role', role,
        '--speed', '8', '--minutes', '8.1', '--shots', '',
        '--extra-widget', HERE.parent/'widgets/gui_barb_team_link.lua',
        '--extra-widget', HERE/'widgets/blueprint_watch.lua', *extra)
    if args.map == 'metal-plate':
        scripts = game / 'AI/Skirmish/BARbTest/test/script/src'
        (scripts/'maps/blueprint_plate.as').write_text(fixture)
        path = scripts/'maps.as'
        source = path.read_text()
        needle = 'void registerMaps() {'
        assert needle in source
        path.write_text('#include "maps/blueprint_plate.as"\n' + source.replace(
            needle, needle+'\n        mapManager.RegisterMapConfig(BlueprintPlate::config);', 1))
    run('prepare_blueprint_check.py', '--dir', game)
    if not args.stage_only:
        run('playtest.py', 'launch', '--dir', game)
        run('playtest.py', 'watch', '--dir', game, '--role', role, '--checks', 'shared/layout/blueprints' if args.map=='supreme' else 'shared/layout/blueprints-metal',
            '--minutes', '8.1', '--wall-minutes', '15', '--keep-going')


if __name__ == '__main__':
    main()
