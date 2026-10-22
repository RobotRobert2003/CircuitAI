"""Compare unchanged TECH startup layouts on Supreme Isthmus and All That Glitters."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import playtest
import storage
from run_retirement_regression import inject_entry


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline',type=Path,required=True)
    parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    args=parser.parse_args()
    call=[sys.executable,str(playtest.HERE/'playtest.py')]
    results=[]
    for slug,name in [('supreme','Supreme Isthmus v1.7'),('glitters','All That Glitters v2.2.3')]:
        signatures=[]
        for label,pin in [('baseline',args.baseline),('candidate',args.candidate)]:
            directory=storage.allocate('tech','layout','compact-'+label,slug,'regression',seed=3071)
            try:
                subprocess.run(call+['stage','--dir',str(directory),'--dll',str(pin/'SkirmishAI.dll'),'--data',str(pin/'data'),
                    '--map',name,'--engine','recoil_2026.07.04','--role','TECH','--roles','TECH','--side','cortex',
                    '--ai-option','profile=experimental_balanced','--ai-option','random_seed=3071','--bonus','0',
                    '--mode','fast','--speed','20','--headless','--minutes','1'],check=True)
                # AI seed alone does not pin the engine's spawn displacement.
                # A few elmos of commander motion can block a different layout
                # candidate before frame 151. Compare identical engine inputs.
                script=directory/'script.txt'
                text,count=re.subn(r'(\[GAME\]\s*\{)',r'\1\n FixedRNGSeed=3071;',script.read_text(),count=1)
                if count!=1: raise ValueError('Missing game block')
                script.write_text(text)
                # Layout equality is a supplied-start geometry control, not an
                # autonomous opening comparison. Native pre-setup movement is
                # asynchronous even with RNG pinned. Hold builders and pass the
                # declared start into setup before any builder policy work.
                teams=json.loads((directory/'teams.json').read_text())['teams']
                starts={t['team']:f"AIFloat3({t['x']}f, 0.0f, {t['z']}f)" for t in teams}
                anchor=f"ai.teamId == 0 ? {starts[0]} : {starts[1]}"
                source=directory/'AI/Skirmish/BARbTest/test/script/src'
                setup=source/'setup.as'
                text=setup.read_text()
                signature='void setupMap(const AIFloat3& in startPos) {'
                if text.count(signature)!=1: raise ValueError('Missing setup signature')
                setup.write_text(text.replace(signature,'void setupMap(const AIFloat3& in observedPos) {\n        const AIFloat3 startPos = '+anchor+';'))
                inject_entry(source/'manager/builder.as','IUnitTask@ AiMakeTask(CCircuitUnit@ u)',
                    'if (ai.teamId >= 0) { if (!Global::Map::MapResolved) Setup::setupMap('+anchor+'); return aiBuilderMgr.Enqueue(TaskB::Wait(60 * SECOND)); }')
                (directory/'layout-control-inputs.json').write_text(json.dumps(dict(engine_seed=3071,
                    overrides=['canonical start anchors','builder work held during geometry observation'],
                    scripts={str(p.relative_to(source)):storage.file_hash(p) for p in source.rglob('*.as')}),indent=2))
                subprocess.run(call+['launch','--dir',str(directory),'--engine','recoil_2026.07.04','--headless'],check=True)
                code=subprocess.call(call+['watch','--dir',str(directory),'--minutes','1','--wall-minutes','6',
                    '--checks','tech/reliability/recovery-load'])
            finally:
                subprocess.run(call+['stop','--dir',str(directory)],check=False)
            archives=sorted((directory/'runs').glob('*/report.md'))
            archive=archives[-1].parent if archives else directory
            log=(archive/'infolog.txt').read_text(errors='replace')
            signature=[]
            for line in log.splitlines():
                match=re.search(r':T:(\d+):.*:L::(\[Layout\] (?:native factory pair committed|turret box \d|forward cluster \d|advanced lab\x27s footprint reserved|advanced lab on the front line).*)',line)
                if match: signature.append((int(match[1]),match[2]))
            signature.sort()
            valid=code==0 and len(signature)>=4 and '[Layout][Compact]' not in log and 'compact economy enabled' not in log
            signatures.append(signature)
            results.append(dict(map=slug,label=label,valid=valid,signature=signature,archive=str(archive)))
            args.out.parent.mkdir(parents=True,exist_ok=True)
            args.out.write_text(json.dumps(results,indent=2))
            if not valid: return 1
        if signatures[0]!=signatures[1]:
            print('LAYOUT_MISMATCH='+slug,flush=True)
            return 1
        print('LAYOUT_IDENTICAL='+slug,flush=True)
    return 0


if __name__=='__main__': sys.exit(main())
