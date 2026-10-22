"""Prepare an isolated AIR guard-recovery fixture; never edits deployment data."""
from script_settings import role_script_path
import argparse
from pathlib import Path
from benchmark_store import RAW_ROOT
import shutil

HOOK = '''        // TEST ONLY: non-interruptible native guards exercise reconciliation.
        for (int tier=1;tier<=2;++tier) {
            if (ai.teamId != 0 || ai.frame < (tier==1 ? 9 : 12)*60*SECOND
                || aiTerrainMgr.GetLayoutInt("fixture.guard."+tier,0)!=0) continue;
            array<Id>@ workers=ai.GetOwnedUnitIds();
            for(uint i=0;i<workers.length();++i) {
                CCircuitUnit@ w=ai.GetTeamUnit(workers[i]);
                if(w is null || !UnitHelpers::IsAirConstructor(w.circuitDef)
                    || UnitHelpers::GetConstructorTier(w.circuitDef)!=tier || w.GetBuildProgress()<1) continue;
                CCircuitUnit@ plant=NearestPlant(w); if(plant is null) continue;
                IUnitTask@ guard=aiBuilderMgr.Enqueue(TaskB::Guard(Task::Priority::HIGH,plant,false,60*SECOND));
                aiBuilderMgr.AssignTask(w,guard);
                GenericHelpers::LogUtil("[AirDonation] injected native guard tier="+tier+" worker="+w.id,1);
                aiTerrainMgr.SetLayoutInt("fixture.guard."+tier,1); return;
            }
        }
'''


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    root=RAW_ROOT
    if not args.output.resolve().is_relative_to(root) or args.output.exists():
        parser.error('Use a new isolated build-theatres output directory')
    shutil.copytree(args.data,args.output)
    map_file=args.output/'script/src/maps/glacial_gap.as'
    content=map_file.read_text()
    for coordinate in ('430, 0, 2300','13890, 0, 2246'):
        content=content.replace(coordinate+'), AiRole::FRONT',coordinate+'), AiRole::AIR')
    map_file.write_text(content)
    policy=args.role_script_path(output / 'script/src', 'air_build')
    content=policy.read_text();needle='        ReturnEconomyWorkers();'
    assert content.count(needle)==1
    policy.write_text(content.replace(needle,HOOK+needle))


if __name__=='__main__':
    main()
