"""Read-only scout benchmark extraction; engine orders are not network packets.

Supply completed archive directories containing infolog.txt. Keep independent
trials as separate rows; never combine diagnostic and timing samples silently.
"""
import argparse
import json
from pathlib import Path
import re
import statistics


def summarize(archive):
    text = (archive/'infolog.txt').read_text(errors='replace')
    orders = [int(value) for value in re.findall(r'\[SeaArena\].*orders team=0 apm=(\d+)', text)]
    cpu = [float(value) for value in re.findall(r'\[WorkforcePerf\].*ai_all_mean_ms=([\d.]+)', text)]
    if not orders or not cpu:
        raise ValueError(f'Missing command/CPU measurements: {archive}')
    row = dict(archive=str(archive), minute_orders=orders, total_orders=sum(orders),
               mean_combined_ai_ms=statistics.mean(cpu), cpu_minute_samples=cpu,
               diagnostics='[SEA][ScoutOrders]' in text)
    physical = archive/'sea-tempo-acceptance.json'
    if physical.exists():
        row['physical_acceptance'] = json.loads(physical.read_text())
    return row


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archives', nargs='+', type=Path)
    args = parser.parse_args()
    print(json.dumps([summarize(path) for path in args.archives], indent=2))
