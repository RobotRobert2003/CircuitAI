"""Independent SEA combat/order scorecard; never overwrites evidence."""
import argparse,json,re,statistics
from pathlib import Path

def analyze(path):
    roster={}
    def unit_row(team,name):
        return roster.setdefault(str(team),{}).setdefault(name,{'spawned':0,'produced':0,'lost':0,'raw_damage':0.0})
    units={}; detected={}; first_order={}; damage=[0.,0.]; lost=[0.,0.]; kills=[0.,0.]
    apm=[[],[]]; repeats=[[],[]]; errors=[]; responses=[]; produced=[]; samples=[]; timings=[]; mismatches=[]; finished=[]; threats=[]; decisions=[]; sources=[]; carriers=[]
    event=re.compile(r'\[SeaArena\] frame=(\d+) (\w+)\s*(.*)')
    with Path(path).open(encoding='utf-8',errors='replace') as source:
        for line in source:
            if '[SEA][Response]' in line: responses.append(line.strip())
            m=re.search(r':T:(\d+):F:(\d+):L::\[SEA\]\[(Threat|Response)\] (.*)',line)
            if m:
                row={'team':int(m[1]),'frame':int(m[2]),**dict(re.findall(r'(\w+)=([^ ]+)',m[4].strip()))}
                (threats if m[3]=='Threat' else decisions).append(row)
            if '[WorkforcePerf] frame=' in line:
                timings.append({k:float(v) for k,v in re.findall(r'(\w+)=([\d.]+)',line)})
            if '[WorkforcePerf] ERROR' in line:errors.append(line.strip())
            if ': ERR ' in line or 'SCRIPT CRASH' in line or 'INVARIANT' in line: errors.append(line.strip())
            m=event.search(line)
            if not m:continue
            frame=int(m[1]);kind=m[2];v=dict(re.findall(r'(\w+)=([^ ]+)',m[3].strip()))
            required={
                'spawn':('id','team','unit'),'produced':('id','team','unit'),'child':('id','team','unit'),
                'detected':('id',),'attack':('id','target'),'damage':('victim','attacker','team','amount'),
                'death':('id','team','cost'),'orders':('team','apm','repeated'),
                'order_sources':('team','sources')}
            if not line.endswith('\n') or any(key not in v for key in required.get(kind,())):
                errors.append(f'Incomplete SeaArena {kind} event at frame {frame}; excluded from totals')
                continue
            if kind=='ERROR':errors.append(line.strip())
            elif kind=='category_mismatch':mismatches.append({'frame':frame,**v})
            elif kind=='finished':finished.append({'frame':frame,**v})
            elif kind=='order_sources':sources.append({'frame':frame,'team':int(v['team']),**{k:int(n) for k,n in (p.split(':') for p in v['sources'].split(','))}})
            elif kind=='carrier_owner':carriers.append({'frame':frame,**v})
            elif kind in ('spawn','produced','child'):
                units[int(v['id'])]={'team':int(v['team']),'unit':v['unit']}
                unit_row(int(v['team']),v['unit'])['produced' if kind=='produced' else 'spawned']+=1
                if kind=='produced':produced.append({'frame':frame,**v})
            elif kind=='detected':detected.setdefault(int(v['id']),frame)
            elif kind=='attack' and units.get(int(v['id']),{}).get('team')==0:first_order.setdefault(int(v['target']),frame)
            elif kind=='damage' and int(v['team']) in (0,1):
                damage[int(v['team'])]+=float(v['amount'])
                attacker=units.get(int(v['attacker']))
                if attacker:unit_row(attacker['team'],attacker['unit'])['raw_damage']+=float(v['amount'])
            elif kind=='death':
                team=int(v['team']);lost[team]+=float(v['cost'])
                victim=units.get(int(v['id']))
                if victim:unit_row(team,victim['unit'])['lost']+=1
                if v.get('attackerTeam') in ('0','1'):kills[int(v['attackerTeam'])]+=float(v['cost'])
            elif kind=='orders' and int(v['team']) in (0,1):
                team=int(v['team']);apm[team].append(int(v['apm']));repeats[team].append(int(v['repeated']))
            elif kind=='sample':samples.append({'frame':frame,**{k:float(x) for k,x in v.items()}})
    latency=[(f-detected[target])/30 for target,f in first_order.items() if target in detected and f>=detected[target]]
    return {'schema':3,'log':str(Path(path).resolve()),'unit_roster':roster,'fixture_errors':errors,'order_sources':sources,'carrier_ownership':carriers,
        'raw_weapon_damage_by_team':damage,'metal_lost_by_team':lost,'last_hit_kill_metal_by_team':kills,
        'minute_apm_by_team':apm,'minute_identical_order_signatures_by_team':repeats,
        'peak_apm_by_team':[max(x,default=0) for x in apm],
        'detection_to_first_attack_order_seconds':latency,'median_detection_to_order':statistics.median(latency) if latency else None,
        'response_decisions':responses,'threat_observations':threats,'decisions':decisions,'produced':produced,'finished':finished,'samples':samples,'engine_ai_timings':timings,'target_category_mismatches':mismatches,
        'limitations':['Raw damage includes overkill; last-hit credit is not proportional damage credit.',
            'Commands count per-unit engine callbacks, not player UI actions or network packet bytes. Lua gadget commands are included in legacy totals; use order_sources where available. Non-Lua is a proxy, not a packet measurement.',
            'Older observers omit carrier-child damage and losses; updated child records expand accounting and cannot be compared silently with old totals.',
            'Profiler covers all engine AI callbacks, not this policy alone; concurrent games and changing live populations invalidate CPU comparisons.',
            'A fixed matchup is a regression fixture, not proof of human PvP superiority.',
            'Both AIs use the selected policy; not a candidate-vs-baseline tournament.']}

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('log',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    if a.output.exists():raise SystemExit('Refusing to overwrite scorecard')
    r=analyze(a.log);a.output.write_text(json.dumps(r,indent=2)+'\n')
    print(json.dumps({k:r[k] for k in ('fixture_errors','raw_weapon_damage_by_team','metal_lost_by_team','peak_apm_by_team','median_detection_to_order')},indent=2))
