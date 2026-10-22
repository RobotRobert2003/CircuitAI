"""Generate the SEA review annex from the effective shared BAR roster (read only)."""
import json
from pathlib import Path
from documentation_store import document

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT.parent / 'rjm.bar.docs/tools/knowledge/.cache/kb.json'


def controls(name, unit):
    desc = NAMES['descriptions'].get(name, '').lower()
    weapons = unit.get('weapondefs', {})
    mobile = unit.get('speed',0)>0 or unit.get('canfly',False)
    if name in ('armpt','corpt'):
        return 'Fast radar/sonar picket and light AA escort; scout routes and protect the early fleet, raid exposed surface economy only with the short-range gun. Cannot attack submerged units; missile range is not surface-gun range.'
    if name=='legnavyscout':
        return 'Fast surface scout/raider; use vision to expose targets and raid isolated economy. Its gun is not an AA or anti-submarine weapon; pair with dedicated coverage.'
    if 'nanotc' in name:
        return 'Stationary build power in reach of real active projects; repair damaged ships and reclaim enemy units in reach before other work. Dense support pads must preserve production exits; no idle guard chains.'
    if name in ('armmls','cormls'):
        return 'Fast naval engineer: build or clear minefields at controlled approaches, repair/reclaim and supply forward build power; protect during construction.'
    if name=='leganavyengineer':
        return 'Combat engineer: mobile forward build power and its actual listed ship/defense build options; repair/reclaim behind screen; reserve exit space for built ships.'
    if name=='armexcalibur':
        return 'Optional surface missile boat despite its sub unit-group label; fire at surface targets from cover, preserve during reload; not an anti-submarine response.'
    if name=='leganavyflagship':
        return 'Protected surface capital artillery with its listed weapon groups; maintain AA/sub screen and sensor coverage; avoid congested channels. Not a drone carrier.'
    if name=='legnavydestro':
        return 'Surface gun destroyer plus carrier drone host. Screen against hovers/surface hulls, let the game own attached drone launch/docking orders, reclaim released drones into normal AI control; no torpedo/depth-charge weapon.'
    if any(w.get('customparams',{}).get('carried_unit') for w in weapons.values()):
        return 'Drone host: preserve the expensive carrier behind escorts; issue host targets, let game drone spawning/docking run; verify configured drone engagement range.'
    if 'anti-nuke' in desc or 'antinuke' in name or 'antiship' in name:
        return 'Rear fleet escort; stockpile interceptors; overlap fleet/base coverage; do not lead a charge.'
    if unit.get('canresurrect') or 'rezsub' in name or name in ('armrecl','correcl'):
        return 'Protected wreck-field reclaim/repair; resurrect intact valuable hulls only with energy and time; avoid depth charges.'
    if unit.get('buildoptions') and mobile:
        return 'Expand only into controlled water; repair/reclaim safely; assist funded active projects; leave idle guards. Engineer: forward defenses/mines and cheap assistance; advanced constructor: mex upgrades/fusions.'
    if unit.get('buildoptions'):
        return 'Reserve footprint, support and real product exit; continuous affordable counter production; replace forward only after verified egress.'
    if not mobile:
        if unit.get('extractsmetal'): return 'Take safe metal; upgrade before costly conversion; protect with mixed-layer coverage; preserve constructor access.'
        if unit.get('tidalgenerator') or unit.get('energymake') or 'fusion' in desc: return 'Energy balance; separate hazardous reactors from production; reserve later expansion and ship exits.'
        if 'mine' in name: return 'Cloaked ambush on a likely enemy water route; avoid friendly production exits; cover with vision and protect minelayers; mine detonation is engine controlled.'
        if 'drag' in name: return 'Fortification at a contested approach; preserve friendly movement corridors; never close shipyard exits.'
        if 'fatf' in name or 'pinpointer' in name: return 'Radar targeting support for distant fire; protect and fund its energy use; does not create sonar or line of sight.'
        if weapons: return 'Place behind an accessible fleet line/choke with sensors; cover actual target layer; never obstruct economic zones or ship exits.'
        if unit.get('radardistance') or unit.get('sonardistance'): return 'Overlapping sensor coverage at harbor/front; radar cannot replace sonar or precise LOS; protect cheaply.'
        return 'Economy/storage/conversion support as required by resource deficits; compact reserved zone outside ship exits.'
    if 'jam' in name: return 'Persistent escort behind combat hulls; one effective coverage area before duplicates; radar jamming does not substitute for sonar.'
    if unit.get('canfly'):
        if 'sonar' in desc or 'radar' in desc: return 'Spread reconnaissance with sonar overlap; expose subs for ranged fire; avoid AA. Submerged landing and sensor behavior require a separate runtime check.'
        if 'fighter' in desc: return 'Air cover above fleet; intercept strike aircraft; avoid unsupported land AA pursuit.'
        if any(w.get('waterweapon') for w in weapons.values()): return 'Sonar-supported attack on ships/subs; avoid flak; never assign hover or dry-land targets.'
        if 'carrier' in desc: return 'Protected drone launch platform; preserve host; respect native drone docking/spawning controls and avoid dense AA.'
        return 'Strike exposed surface/shore targets using vision; retreat/repair when a reusable defensive sortie permits; avoid torpedo-only target assumptions.'
    if 'nuclear' in desc or name in ('armseadragon','cordesolator'):
        return 'Optional nuclear stockpile plus torpedo defense; submerged positioning; strategic static targets, scout anti-nuke; preserve expensive hull.'
    if 'submarine' in desc or unit.get('movementclass','').startswith('UBOAT'):
        if max((w.get('range',0) for w in weapons.values()),default=0)>=600:
            return 'Long-range torpedo battery behind sonar/screen; exploit reload and range; focus valuable hulls; no hover/air/dry-land pursuit.'
        return 'Raid exposed water economy/ships, hunt subs with sonar; fast subs close against long-reload opponents; avoid destroyer/depth-charge concentrations.'
    if 'anti-air' in desc: return 'Escort fleet and harbor; intercept aircraft immediately; keep behind surface screen; no surface-target chase.'
    if name == 'legnavyfrigate': return 'Torpedo frigate for ships/subs; stay with surface-gun escort; cannot counter hovercraft despite frigate label.'
    if 'flagship' in desc: return 'Protected capital group with AA/anti-sub/repair; use actual weapon arcs and firing clearance; avoid choke congestion.'
    if 'missile' in desc or 'artillery' in desc: return 'Ranged static/shore bombardment behind mixed screen; select accessible firing water; sensor support; do not lead against mobile swarms.'
    if 'battleship' in desc: return 'Surface fire line with range advantage, anti-sub/AA escort; Legion hover movement and weapon groups require separate terrain checks.'
    if 'destroyer' in desc or 'cruiser' in desc: return 'Screen artillery and kite surface targets; actual water weapon range for subs; Legion T1 destroyer is surface-only; exploit independent turrets.'
    if 'anti-swarm' in desc or name in ('armlship','corfship','leganavyantiswarm'): return 'Fast anti-swarm flanks/raids; surround isolated expensive hulls; light AA is not fleet air defense; avoid ranged focus fire.'
    if unit.get('movementclass','').startswith('HOVER'): return 'Hover flank through mixed terrain; exploit torpedo immunity; surface targets and landing routes; do not confuse with submerged units.'
    if unit.get('domain') == 'amphibious': return 'Underwater transit to a passable shore; stage on land; layer-specific weapons; do not pursue impossible targets.'
    return 'Fast vision/economy raid or surface screen; spread to avoid area damage; focus exposed hulls; retreat from stronger ranged line; inspect listed weapons before assigning AA/AS.'


if __name__ == '__main__':
    data = json.loads(CACHE.read_text()); units=data['units']; NAMES=data['names']
    factories=['armsy','corsy','legsy','armasy','corasy','legadvshipyard','armplat','corplat','legsplab','armamsub','coramsub']
    selected=set(factories)
    for name in factories: selected.update(units.get(name,{}).get('buildoptions',[]))
    for name in list(selected):
        if units.get(name,{}).get('buildoptions') and (units[name].get('speed',0)>0 or units[name].get('canfly')):
            selected.update(units[name]['buildoptions'])
    naval_hosts=set(selected)
    for name,hosts in data['extra_units'].items():
        if naval_hosts.intersection(hosts): selected.add(name)
    rows=['# SEA unit controls and use cases', '',
        'Generated by `tools/knowledge/naval_roster.py` from effective BAR '+data['meta']['bar_commit']+'.',
        'Scope: all products of the nine ordinary naval/seaplane factories, both amphibious complexes, their naval constructors\' structures, and extras added to those hosts. Land structures accessible to naval constructors are deliberately retained. No generated Scavenger copies. Runtime build edges and weapon capabilities remain authoritative.', '',
        'Weapon entries are `mount: target categories; range; reload seconds`. They describe legal targets, not guaranteed accuracy/DPS. Costs are metal; movement is the real move class. Names and weapon numbers come from game data; control recommendations are analysis, not measured matchup guarantees.', '',
        '[Policy and verification plan](sea-combat-enhancement-plan.md). The public [naval guide](https://www.beyondallreason.info/guide/basics-on-sea-warfare) supplies fleet doctrine; individual details below use local Lua UnitDefs and effective categories.', '',
        '| Unit / name | M / movement | Weapons / sensors | Controls and use case |',
        '| --- | --- | --- | --- |']
    for name in sorted(selected):
        u=units.get(name)
        if not u: continue
        ws=[]
        for mount in u.get('weapons',[]):
            w=u.get('weapondefs',{}).get(mount.get('def','').lower(),{})
            ws.append(f"{mount.get('def','?')}: {mount.get('onlytargetcategory','engine default')}; {w.get('range','?')}; {w.get('reloadtime','?')}")
        for field in ('sightdistance','radardistance','sonardistance','radardistancejam'):
            if u.get(field): ws.append(field+'='+str(u[field]))
        extra=' **extra**' if name in data['extra_units'] else ''
        source='https://github.com/beyond-all-reason/Beyond-All-Reason/blob/'+data['meta']['bar_commit']+'/'+u['file']
        rows.append(f"| [{name}]({source}) — {NAMES['names'].get(name,name)}{extra} | {u.get('metalcost','?')} / {u.get('movementclass','air' if u.get('canfly') else 'static')} | {'<br>'.join(ws) or 'Unarmed'} | {controls(name,u)} |")
    rows+=['',f'Enumerated {sum(n in units for n in selected)} distinct UnitDefs.','',
        'Control gaps requiring individual fixtures: mines, naval engineers building ships, carrier drone launch/docking, nuclear submarine stockpiles, interceptor coverage, submerged seaplane landing, Legion switching weapon groups, and auxiliaries on disconnected ponds. Enumeration is not a claim these mechanics are already automated or tested.']
    (document('sea-unit-controls.md')).write_text('\n'.join(rows)+'\n',encoding='utf-8')
