"""Embed the strategy module in the single-file deployable widget; --check in CI."""
import argparse
from pathlib import Path

root = Path(__file__).resolve().parent
widget = root / 'gui_barb_team_link.lua'
start, end = '-- BEGIN STRATEGY MODULE\n', '-- END STRATEGY MODULE\n'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
source = widget.read_text(encoding='utf-8')
module = (root / 'include/barb_strategy.lua').read_text(encoding='utf-8')
if start in source:
    before, rest = source.split(start, 1)
    _, after = rest.split(end, 1)
else:
    before, after = source.split('function widget:ViewResize', 1)
    after = 'function widget:ViewResize' + after
result = before + start + module.rstrip() + '\n' + end + after
if args.check:
    if result != source:
        raise SystemExit('Strategy module differs: run tools/widgets/embed_strategy.py')
else:
    widget.write_text(result, encoding='utf-8')
