"""Stage and run reproducible supplied AIR workforce fixtures, without live installs."""
from script_settings import role_script_path
import argparse
import json
from pathlib import Path
import subprocess
import sys
import playtest
import storage


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dll', type=Path, required=True)
    p.add_argument('--data', type=Path, default=playtest.REPO/'data')
    p.add_argument('--side', choices=['armada', 'cortex', 'legion'], default='armada')
    p.add_argument('--scenario', choices=['donations', 'energy-starved', 'six-labs', 'lifecycle'], default='donations')
    p.add_argument('--minutes', type=float, default=16)
    p.add_argument('--stop', type=int, default=600)
    p.add_argument('--headless', action='store_true')
    p.add_argument('--profile', default='experimental_hard')
    a = p.parse_args()
    root = storage.allocate('air', 'economy', 'workforce-'+a.scenario, 'supreme', 'supplied')
    starts = root/'starts.as'
    starts.write_text('StartSpot(AIFloat3(2155,0,11747), AiRole::AIR, false),\n'
                      'StartSpot(AIFloat3(4700,0,11000), AiRole::SUPPORT, false),\n'
                      'StartSpot(AIFloat3(11456,0,1901), AiRole::FRONT, false),\n')
    call = [sys.executable, str(playtest.HERE/'playtest.py')]
    stage = call+['stage','--dir',str(root),'--dll',str(a.dll),'--data',str(a.data),'--map','Supreme Isthmus v1.7',
        '--map-file',str(starts),'--role','AIR','--roles','all','--ally-spots','1,2','--side',a.side,
        '--game','Beyond All Reason test-31479-433a460','--engine','recoil_2026.07.04',
        '--minutes',str(a.minutes),'--speed','30','--shots','' if a.headless else '3,6,10,15',
        '--width','1280','--height','720','--lean-render','--modoption','deathmode=neverend',
        '--ai-option','profile='+a.profile,'--ai-option','random_seed=1810001',
        '--extra-widget',str(playtest.HERE/'widgets/air_workforce_watch.lua'),
        '--extra-widget',str(playtest.HERE/'widgets/air_workforce_fixture.lua'),
        '--extra-widget',str(playtest.HERE/'widgets/air_watch.lua'),
        '--extra-widget',str(playtest.HERE/'widgets/air_command_watch.lua')]
    if a.headless: stage.append('--headless')
    subprocess.run(stage, check=True)
    subprocess.run([sys.executable,str(playtest.HERE/'prepare_air_check.py'),'--dir',str(root),'--scenario','natural','--seed','1810001'],check=True)
    scripts=root/'AI/Skirmish/BARbTest/test/script/src'
    setup=scripts/'setup.as';text=setup.read_text();needle='Global::AISettings::Role = derivedRole;'
    assert text.count(needle)==1
    setup.write_text(text.replace(needle,'derivedRole = ai.teamId == 0 ? AiRole::AIR : AiRole::SUPPORT;\n'+needle))
    for name,manager,descriptor in [('builder','aiBuilderMgr','TaskB::Wait(60 * SECOND)'),('factory','aiFactoryMgr','TaskS::Wait(false, 60 * SECOND)')]:
        path=scripts/'manager'/(name+'.as');text=path.read_text();at=text.index('IUnitTask@ AiMakeTask(CCircuitUnit@ u)');brace=text.index('{',at)
        path.write_text(text[:brace+1]+'\n if (ai.teamId != 0) return '+manager+'.Enqueue('+descriptor+');\n'+text[brace+1:])
    # Hold the donor's grant for the explicit transfer rather than automatic sharing.
    team=scripts/'systems/team/team_economy.as';text=team.read_text();needle='void ShareOverflow()\n    {'
    assert text.count(needle)==1
    team.write_text(text.replace(needle,needle+'\n        if (ai.teamId != 0) return;'))
    probe='const bool AirWorkforceFixtureSix = '+str(a.scenario=='six-labs').lower()+';\n'
    probe+='const bool AirWorkforceFixtureLifecycle = '+str(a.scenario=='lifecycle').lower()+';\n'
    probe+=(playtest.HERE/'air_workforce_probe.as').read_text()
    (scripts/'manager/air_workforce_probe.as').write_text(probe)
    build=role_script_path(scripts, 'air_build');text=build.read_text();needle='        ReturnEconomyWorkers();';assert text.count(needle)==1
    probe_include = '../../manager/air_workforce_probe.as' if build.parent.name == 'air' else '../manager/air_workforce_probe.as'
    build.write_text('#include "'+probe_include+'"\n'+text.replace(needle,needle+'\n        AirWorkforceProbe::Tick();'))
    config=root/'LuaUI/Config';config.mkdir(exist_ok=True)
    (config/'air_workforce.lua').write_text(f'return {{scenario="{a.scenario}",side="{a.side}",stop={a.stop}}}\n')
    storage.write_json(root/'workforce-fixture.json',{'scenario':a.scenario,'side':a.side,'profile':a.profile,
        'supplied_assets':True,'donation_stop_seconds':a.stop,'seed':1810001,'enemy_frozen':True})
    subprocess.run([sys.executable,str(playtest.REPO/'tools/knowledge/check_script_api.py'),'--dll',str(a.dll)],check=True)
    launch=call+['launch','--dir',str(root),'--engine','recoil_2026.07.04']
    if a.headless: launch.append('--headless')
    subprocess.run(launch,check=True)
    watched = subprocess.call(call+['watch','--dir',str(root),'--role','AIR','--checks','air_workforce_budget',
        '--minutes',str(a.minutes),'--wall-minutes','20','--keep-going'])
    audited = subprocess.call([sys.executable,str(playtest.HERE/'audit_air_workforce.py'),str(root)])
    return watched or audited


if __name__=='__main__':
    raise SystemExit(main())
