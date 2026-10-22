"""Independent SEA economy/egress scorecard; never rewrites original reports."""
import argparse
import json
from pathlib import Path
import re
import statistics

def analyze(path):
    events=[]; samples=[]; exits=[]; delayed=[]; violations=[]
    with path.open(encoding='utf-8', errors='replace') as stream:
        for line in stream:
            if '[SeaWatch] finished' in line:
                m=re.search(r'frame=(\d+).*def=(\w+)',line)
                if m: events.append((int(m[1]),m[2]))
            if '[SeaWatch] sample' in line:
                m=re.search(r'frame=(\d+) metal=([\d.]+)/([\d.]+) income=([\d.]+) use=([\d.]+) energy=([\d.]+)/([\d.]+) income=([\d.]+) use=([\d.]+) yards=(\d+) busy=(\d+) bp=([\d.]+) idle=([\d.]+) units=(.*)',line)
                if m:
                    keys=['frame','metal','metal_storage','metal_income','metal_use','energy','energy_storage','energy_income','energy_use','yards','busy_yards','build_power','idle_power']
                    row=dict(zip(keys,map(float,m.groups()[:13])))
                    row['units']={n:int(c) for n,c in (s.split(':') for s in m[14].split(',') if ':' in s)}
                    samples.append(row)
            if '[SeaWatch] egress' in line:
                m=re.search(r'seconds=([\d.]+)',line)
                if m: exits.append(float(m[1]))
            if '[SeaWatch] exit-delay' in line: delayed.append(line)
            if re.search(r'INVARIANT|: ERR\s+:|SCRIPT CRASH|Access violation',line): violations.append(line)
    def first(names): return min((f/1800 for f,n in events if n in names),default=None)
    milestones={
        't1_yard':first({'armsy','corsy','legsy'}),
        't2_yard':first({'armasy','corasy','legadvshipyard'}),
        't2_constructor':first({'armacsub','coracsub','leganavyconsub'}),
        'naval_fusion':first({'armuwfus','coruwfus','leganavalfusion'}),
        'first_nano':first({'armnanotcplat','cornanotcplat','legnanotcplat'})}
    live=[row for row in samples if row['units']]
    # A dead team keeps returning zero-income samples. Never score those as
    # successful late economy, or silently drop the loss from a comparison.
    first_empty=next((row['frame'] for row in samples if not row['units'] and live and row['frame']>live[0]['frame']),None)
    checkpoints={}
    for minute in (5,10,15,20,30,45):
        if samples and samples[-1]['frame']>=minute*1800:
            row=min(samples,key=lambda r:abs(r['frame']-minute*1800))
            checkpoints[str(minute)]=row if row['units'] else {'status':'eliminated_or_no_owned_units','frame':row['frame']}
    failures=[]
    if milestones['t1_yard'] is None or milestones['t1_yard']>4: failures.append('No completed opening shipyard by four minutes')
    if not exits: failures.append('No observed product left a shipyard')
    if violations: failures.append('Runtime errors/invariants present')
    operational=bool(samples and (samples[-1]['yards']>0 or samples[-1]['build_power']>0))
    return {'schema':3,'log':str(path.resolve()),'milestones_minutes':milestones,'checkpoints':checkpoints,
        'survival':{'first_empty_minute':first_empty/1800 if first_empty is not None else None,
            'last_live_sample_minute':live[-1]['frame']/1800 if live else None,
            'operational_at_last_sample':operational,
            'operational_definition':'Owns at least one yard or any build power; remaining extractors alone do not qualify.',
            'status':'eliminated_or_no_owned_units' if first_empty is not None else 'remnants_without_build_power' if live and not operational else 'alive_at_last_sample' if live else 'unobserved'},
        'egress':{'departures':len(exits),'median_seconds':statistics.median(exits) if exits else None,
            'p95_seconds':sorted(exits)[min(len(exits)-1,int(len(exits)*.95))] if exits else None,
            'over_60s_observations':len(delayed),'limitation':'Includes constructors. Older observers can miss delayed departures. Destroyed and still-pending products have no successful departure record; their denominator was not captured.'},
        'runtime_violations':len(violations),'failures':failures,'samples':samples}

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('log',type=Path);p.add_argument('--output',type=Path,required=True)
    a=p.parse_args(); result=analyze(a.log)
    if a.output.exists(): raise SystemExit('Refusing to overwrite an existing scorecard; choose a revision path')
    a.output.write_text(json.dumps(result,indent=2))
    print(json.dumps({k:v for k,v in result.items() if k not in ('samples','checkpoints')},indent=2))
    raise SystemExit(bool(result['failures']))
