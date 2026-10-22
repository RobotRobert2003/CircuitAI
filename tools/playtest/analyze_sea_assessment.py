"""Read-only natural SEA assessment: retain outcomes, coverage and raw metrics."""
import argparse,json,re
from pathlib import Path

def analyze(directory):
    teams=json.loads((directory/'teams.json').read_text())['teams']
    sea={t['team']:t for t in teams if t['role']=='SEA'}
    result={i:dict(side=t['side'],economy=[],first_completed={},navy={}) for i,t in sea.items()}
    errors=[];roster={};observer=[]
    path=max((directory/'runs').glob('*/infolog.txt')) if (directory/'runs').exists() else directory/'infolog.txt'
    for line in path.read_text(errors='replace').splitlines():
        if '[INVARIANT]' in line or 'SCRIPT CRASH' in line or ': ERR ' in line:errors.append(line)
        values=dict(re.findall(r'(\w+)=([^ ]*)',line))
        if '[SeaAssessment] observer ' in line:observer.append(values)
        if '[SeaAssessment] roster ' in line:roster.setdefault(values['factory'],[]).append(values['unit'])
        if '[SeaConversion] sample ' in line and int(values['team']) in result:
            team=result[int(values['team'])];frame=int(values['frame'])
            units={k:int(v) for k,v in (x.split(':') for x in values.get('units','').split(',') if ':' in x)}
            for name in units:team['first_completed'].setdefault(name,frame/1800)
            if frame%9000==0:
                team['economy'].append(dict(minute=frame/1800,**{k:float(values[k]) for k in ('mi','mu','m','ms','ei','eu','e','es','capacity','converted')},units=units))
        if '[SeaAssessment] frame=' in line and int(values['team']) in result:
            result[int(values['team'])]['navy'][values['unit']]={k:float(values[k]) for k in ('tier','finished','lost','rawDamage','cost')}
    # Old observer versions missed the privileged handler flag. Never present
    # their zero counters as evidence that vessels failed to fire.
    damage_valid=bool(observer) and all(v.get('attached')=='true' for v in observer) and int(observer[-1].get('damageEvents','0'))>0
    if not damage_valid:
        for team in result.values():
            for unit in team['navy'].values():unit['rawDamage']=None
    return dict(teams=result,loaded_roster=roster,errors=errors,damage_observer_valid=damage_valid,observer=observer,limitations=['First completion times sampled every 30 seconds.', 'Raw damage includes overkill; support ships need purpose-specific cases.', 'Natural production is not complete roster coverage.', 'Null damage means the damage observer did not prove attachment and event delivery.'])

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('directory',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    with a.output.open('x') as stream:json.dump(analyze(a.directory),stream,indent=2)
