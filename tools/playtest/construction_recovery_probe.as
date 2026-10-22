// Staged fixture only. Exercises real enqueue/pin/abort ownership in one
// callback, before a worker can start either synthetic task. No resource gifts.
namespace ConstructionRecoveryProbe {
    bool pinChecked=false;
    IUnitTask@ orphan;
    int orphanFrame=-1;
    bool orphanChecked=false;
    void Tick() {
        if (Global::AISettings::Role!=AiRole::TECH && Global::AISettings::Role!=AiRole::SEA) return;
        if (!pinChecked && Global::AISettings::Role==AiRole::TECH && ai.frame>15*SECOND && Layout::nano !is null) {
            const int slot=aiTerrainMgr.NextSlotAny(Layout::nanoGroup,Global::Map::StartPos);
            if (slot>=0) {
                CCircuitDef@ d=Layout::nano;
                const int before=aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::NANO),d);
                const AIFloat3 pos=aiTerrainMgr.GetReservationPos(slot);
                IUnitTask@ first=aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::NANO,Task::Priority::HIGH,d,pos,0.0f,true,120*SECOND));
                IUnitTask@ second=aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::NANO,Task::Priority::HIGH,d,pos,0.0f,true,120*SECOND));
                const bool a=first !is null && AiPinReservation(first,slot);
                const bool b=second !is null && AiPinReservation(second,slot);
                if (second !is null) aiBuilderMgr.AbortTask(second);
                const bool held=aiTerrainMgr.GetReservationState(slot)==1;
                if (first !is null) aiBuilderMgr.AbortTask(first);
                const bool free=aiTerrainMgr.GetReservationState(slot)==0;
                const bool counts=aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::NANO),d)==before;
                GenericHelpers::LogUtil("[ConstructionProbe] pin-transaction="+(a && !b && held && free && counts ? "PASS" : "FAIL")+" slot="+slot+" counts="+counts,1);
                pinChecked=true;
                // Reproduce the actual infinite legacy-chain prerequisite:
                // unassigned, unframed, unpinned and timeout=0. The watchdog
                // must retire it while preserving all real layout tasks.
                @orphan=aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::NANO,Task::Priority::HIGH,d,pos,0.0f,true,0));
                orphanFrame=ai.frame;
            }
        }
        if (orphanFrame>=0 && !orphanChecked && ai.frame-orphanFrame>10*SECOND) {
            GenericHelpers::LogUtil("[ConstructionProbe] orphan-transaction="+(orphan !is null && orphan.IsDead() ? "PASS" : "FAIL"),1);
            if (orphan !is null && !orphan.IsDead()) aiBuilderMgr.AbortTask(orphan);
            @orphan=null;
            orphanChecked=true;
        }
        if (ai.frame%(15*SECOND)>=SECOND) return;
        array<int>@ ids=ai.GetOwnedUnitIds();
        for (uint i=0;i<ids.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(ids[i]);
            if (u is null || !u.circuitDef.IsMobile() || u.circuitDef.GetBuildSpeed()<=0 || u.task is null) continue;
            IBuilderTask@ b=cast<IBuilderTask>(u.task);
            if (Global::AISettings::Role==AiRole::SEA && UnitHelpers::IsCommander(u.circuitDef) && !SeaLayout::hadFactory) {
                CCircuitDef@ yard=ai.GetCircuitDef(UnitHelpers::GetT1ShipyardForSide(UnitHelpers::GetSideForUnitName(u.circuitDef.GetName())));
                if (yard !is null) GenericHelpers::LogUtil("[ConstructionProbe] opening def="+yard.GetName()+" available="+yard.IsAvailable(ai.frame)
                    +" canBuild="+u.circuitDef.CanBuild(yard)+" have="+SeaEconomy::Have(yard)+" allowed="+SeaFactories::FactoryAllowed(yard)
                    +" queued="+aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::FACTORY),yard),1);
            }
            GenericHelpers::LogUtil("[ConstructionProbe] worker="+u.id+" def="+u.circuitDef.GetName()+" task="+int(u.task.GetType())
                +" kind="+(b is null ? -1 : b.GetBuildType())+" build="+(b is null || b.buildDef is null ? "none" : b.buildDef.GetName())
                +" target="+(b is null || b.target is null ? -1 : b.target.id),1);
        }
    }
}
