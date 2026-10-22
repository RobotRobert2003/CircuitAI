"""Real-VM TECH cluster policy checks; isolated from the live install."""
import argparse, subprocess, sys
from pathlib import Path
import playtest, storage

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', required=True)
    args=parser.parse_args()
    directory=storage.allocate('tech','layout','weapon-front-policy','supreme','supplied',seed=2701)
    print(directory,flush=True)
    call=[sys.executable,str(playtest.HERE/'playtest.py')]
    subprocess.run(call+['stage','--dir',str(directory),'--dll',args.dll,'--data',str(playtest.REPO/'data'),
        '--map','Supreme Isthmus v1.7','--game','Beyond All Reason test-31536-188afa8','--engine','recoil_2026.07.04',
        '--role','TECH','--roles','TECH','--side','cortex','--bonus','0','--ai-option','profile=experimental_balanced',
        '--ai-option','random_seed=2701','--minutes','2','--speed','10','--shots','1.5','--width','1280','--height','720','--lean-render'],check=True)
    script=directory/'AI/Skirmish/BARbTest/test/script/experimental_balanced/main.as'
    source=script.read_text().replace('ArtilleryPolicy::Check();','ArtilleryPolicy::Check(); TechWeaponPolicyProbe::Tick();')
    script.write_text(source+'\n'+(playtest.HERE/'tech_weapon_policy_probe.as').read_text())
    subprocess.run(call+['launch','--dir',str(directory),'--engine','recoil_2026.07.04'],check=True)
    return subprocess.run(call+['watch','--dir',str(directory),'--role','TECH','--checks','tech/construction/weapon-front-policy',
        '--minutes','2','--wall-minutes','5']).returncode
if __name__=='__main__': sys.exit(main())

