"""Stage real-terrain amphibious capability fixtures without touching live data."""
import argparse
import json
import subprocess
import sys
from pathlib import Path
from benchmark_store import RAW_ROOT

ROOT = Path(__file__).resolve().parents[2]
MAPS = {
    'tundra': ('Tundra Continents v2.3.1', (2800,800), (3200,800), (6000,11400)),
    'supreme': ('Supreme Isthmus v1.7', (837,10407), (2155,11747), (11456,1901)),
    'serene': ('Serene Caldera v1.3', (8800,1100), (9200,1100), (6600,14250)),
}
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--map',choices=MAPS,required=True)
p.add_argument('--dir',type=Path,required=True)
p.add_argument('--dll',required=True)
p.add_argument('--profile',default='experimental_balanced')
p.add_argument('--minutes',default='22')
p.add_argument('--guarded',action='store_true')
p.add_argument('--windowed',action='store_true',help='Render the game and capture unit-following screenshots')
p.add_argument('--speed',type=float,help='Simulation speed (default: 3 when windowed, 25 when headless)')
p.add_argument('--marauder-delay-seconds',type=int,default=0,help='Give slower Telchines a head start for independent combat observation')
a=p.parse_args()
if not 0<=a.marauder_delay_seconds<=300: p.error('Marauder delay must be between 0 and 300 seconds')
if a.speed is not None and not 0<a.speed<=100: p.error('Speed must be greater than 0 and at most 100')
base=a.dir.resolve()
if not base.is_relative_to(RAW_ROOT): p.error('Use benchmark-repository build-theatres')
base.mkdir(parents=True,exist_ok=True)
name,tech,air,enemy=MAPS[a.map]
fixture=base/'starts.as'
fixture.write_text('\n'.join(f'StartSpot(AIFloat3({x},0,{z}), AiRole::{role}, false),' for (x,z),role in [(tech,'TECH'),(air,'AIR'),(enemy,'FRONT'),((enemy[0]+300,enemy[1]),'FRONT')]))
subprocess.run([sys.executable,str(ROOT/'tools/playtest/playtest.py'),'stage','--dir',str(base),'--dll',a.dll,
    '--map',name,'--map-file',str(fixture),'--game','Beyond All Reason test-31450-6562fb1',
    '--engine','recoil_2026.07.04','--role','TECH','--roles','TECH,AIR','--side','legion',
    *([] if a.windowed else ['--headless']),
    '--shots','','--speed',str(a.speed if a.speed is not None else (3 if a.windowed else 25)),
    '--minutes',a.minutes,'--ai-option','profile='+a.profile,
    '--set','PlanCombatGate=0','--set','PlanT3RushCombatGate=0',
    '--modoption','experimentallegionfaction=1','--modoption','experimentalextraunits=0','--modoption','deathmode=neverend',
    '--extra-widget',str(ROOT/'tools/playtest/widgets/amphibious_fixture.lua'),
    *(['--extra-widget',str(ROOT/'tools/playtest/widgets/amphibious_visual.lua')] if a.windowed else [])],check=True)
scripts=base/'AI/Skirmish/BARbTest/test/script/src'
setup=scripts/'setup.as'
text=setup.read_text()
needle='Global::AISettings::Role = derivedRole;'
assert text.count(needle)==1
setup.write_text(text.replace(needle,'derivedRole = ai.teamId == 0 ? AiRole::TECH : (ai.teamId == 1 ? AiRole::AIR : AiRole::FRONT);\n\t\t'+needle))
builder=scripts/'manager/builder.as'
text=builder.read_text(); needle='IUnitTask@ AiMakeTask(CCircuitUnit@ u) {'; assert text.count(needle)==1
builder.write_text(text.replace(needle,needle+'\n        if (ai.frame >= 0) return aiBuilderMgr.Enqueue(TaskB::Wait(60 * SECOND)); // capability fixture'))
factory=scripts/'manager/factory.as'
text=factory.read_text(); needle='IUnitTask@ AiMakeTask(CCircuitUnit@ u)'; at=text.index(needle); brace=text.index('{',at)
factory.write_text(text[:brace+1]+'\n        if (ai.frame >= 0) return aiFactoryMgr.Enqueue(TaskS::Wait(false, 60 * SECOND)); // capability fixture'+text[brace+1:])
military=scripts/'manager/military.as'
text=military.read_text(); needle='@t = TechFlank::MilitaryTask(u);'; assert text.count(needle)==1
military.write_text(text.replace(needle,'if (ai.teamId >= 2) return null; // after amphibious scope check; opposing fixture stays stationary\n        '+needle))
(base/'LuaUI/Config').mkdir(parents=True,exist_ok=True)
(base/'LuaUI/Config/amphibious_fixture.lua').write_text('return {guarded='+str(a.guarded).lower()+', marauderDelay='+str(a.marauder_delay_seconds)+'}\n')
(base/'amphibious-fixture.json').write_text(json.dumps({'map':name,'profile':a.profile,'role_override':'0 TECH, 1 AIR, enemy FRONT','autonomous_builders':False,'global_los':True,'guarded':a.guarded,'require_front_controls':True,'deathmode':'neverend','marauder_delay_seconds':a.marauder_delay_seconds,'visual_observer':a.windowed,'speed':a.speed if a.speed is not None else (3 if a.windowed else 25)},indent=2))
print(base)
