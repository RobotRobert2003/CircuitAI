"""Isolated late TECH conversion-capacity fixture; real builder decisions."""
import argparse
import subprocess
import sys
import playtest
import storage

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll',required=True)
    args=parser.parse_args()
    directory=storage.allocate('tech','economy','conversion-capacity','supreme','supplied',seed=2671)
    print(directory,flush=True)
    call=[sys.executable,str(playtest.HERE/'playtest.py')]
    subprocess.run(call+['stage','--dir',str(directory),'--dll',args.dll,'--data',str(playtest.REPO/'data'),
        '--map','Supreme Isthmus v1.7','--game','Beyond All Reason test-31536-188afa8',
        '--engine','recoil_2026.07.04','--role','TECH','--roles','TECH','--side','legion',
        '--bonus','0','--ai-option','profile=experimental_balanced','--ai-option','random_seed=2671',
        '--minutes','12','--speed','10','--shots','2,6,11','--width','1280','--height','720','--lean-render',
        '--modoption','deathmode=neverend','--modoption','startmetal=20000',
        '--modoption','startmetalstorage=100000','--modoption','startenergy=1000000',
        '--modoption','startenergystorage=1000000','--extra-widget',str(playtest.HERE/'widgets/tech_conversion_watch.lua')],check=True)
    scripts=directory/'AI/Skirmish/BARbTest/test/script'
    main_file=scripts/'experimental_balanced/main.as'
    source=main_file.read_text()
    source=source.replace('ApplyProfileSettings();','ApplyProfileSettings(); Global::RoleSettings::Tech::RushObjective = "afus";')
    source=source.replace('ArtilleryPolicy::Check();','ArtilleryPolicy::Check(); TechConversionProbe::Tick();')
    main_file.write_text(source+'\n'+(playtest.HERE/'tech_conversion_probe.as').read_text())
    subprocess.run(call+['launch','--dir',str(directory),'--engine','recoil_2026.07.04'],check=True)
    return subprocess.run(call+['watch','--dir',str(directory),'--role','TECH',
        '--checks','tech/economy/conversion-capacity.json','--minutes','12','--wall-minutes','12','--keep-going']).returncode

if __name__=='__main__':
    sys.exit(main())
