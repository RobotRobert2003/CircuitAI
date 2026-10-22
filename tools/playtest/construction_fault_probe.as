// Only injected into isolated fault games. STOP is issued by the AI itself,
// so this tests missing engine intent without a player-order ownership event.
// A separate ownership lease proves that the watchdog does not steal control.
namespace ConstructionFaultProbe {
    int worker=-1, frameId=-1, started=-1, leaseAt=-1;
    float initialProgress=0;
    bool dropDone=false, leaseDone=false, transferDone=false;
    int transferAt=-1;
    IUnitTask@ project;
    void Tick() {
        if (Global::AISettings::Role!=AiRole::TECH && Global::AISettings::Role!=AiRole::SEA) return;
        if (!dropDone && worker<0 && ai.frame>30*SECOND) {
            array<int>@ ids=ai.GetOwnedUnitIds();
            for (uint i=0;i<ids.length();++i) {
                CCircuitUnit@ u=ai.GetTeamUnit(ids[i]);
                if (u is null || !u.circuitDef.IsMobile() || u.circuitDef.GetBuildSpeed()<=0 || u.task is null) continue;
                IBuilderTask@ b=cast<IBuilderTask>(u.task);
                if (b is null || b.buildDef is null || b.GetBuildType()>=int(Task::BuildType::REPAIR) || b.target is null) continue;
                const float progress=b.target.GetBuildProgress();
                if (progress<=0 || progress>0.8f) continue;
                worker=u.id; frameId=b.target.id; initialProgress=progress; started=ai.frame; @project=u.task;
                u.CmdStop();
                GenericHelpers::LogUtil("[ConstructionFault] dropped-command worker="+worker+" frame="+frameId+" progress="+progress,1);
                break;
            }
        }
        if (!dropDone && worker>=0) {
            CCircuitUnit@ building=ai.GetTeamUnit(frameId);
            if (building !is null && building.GetBuildProgress()>initialProgress+0.05f) {
                GenericHelpers::LogUtil("[ConstructionFault] dropped-command=PASS worker="+worker+" frame="+frameId+" elapsed="+(ai.frame-started),1);
                dropDone=true; worker=-1; @project=null;
            } else if (ai.frame-started>90*SECOND) {
                GenericHelpers::LogUtil("[ConstructionFault] dropped-command=FAIL worker="+worker+" frame="+frameId,1);
                dropDone=true; worker=-1; @project=null;
            }
        }
        if (dropDone && !leaseDone && worker<0 && ai.frame>180*SECOND) {
            array<int>@ ids=ai.GetOwnedUnitIds();
            for (uint i=0;i<ids.length();++i) {
                CCircuitUnit@ u=ai.GetTeamUnit(ids[i]);
                if (u is null || UnitHelpers::IsCommander(u.circuitDef) || !u.circuitDef.IsMobile()
                    || u.circuitDef.GetBuildSpeed()<=0 || u.task is null) continue;
                IBuilderTask@ b=cast<IBuilderTask>(u.task);
                if (b is null || b.buildDef is null || b.GetBuildType()>=int(Task::BuildType::REPAIR)) continue;
                worker=u.id; @project=u.task; leaseAt=ai.frame;
                ai.UnitControl(u,false); u.CmdStop();
                GenericHelpers::LogUtil("[ConstructionFault] ownership-lease worker="+worker,1);
                break;
            }
        }
        if (!leaseDone && leaseAt>=0 && ai.frame-leaseAt>=40*SECOND) {
            CCircuitUnit@ u=ai.GetTeamUnit(worker);
            bool retained=false;
            array<CCircuitUnit@>@ members=project.GetUnits();
            for (uint i=0;i<members.length();++i) if (members[i].id==worker) retained=true;
            const bool safe=u !is null && u.task !is null && u.task.GetType()==int(Task::Type::PLAYER) && !retained;
            GenericHelpers::LogUtil("[ConstructionFault] ownership-lease="+(safe ? "PASS" : "FAIL")+" worker="+worker,1);
            if (u !is null) ai.UnitControl(u,true);
            leaseDone=true; worker=-1; @project=null;
        }
        if (leaseDone && !transferDone && worker<0 && ai.frame>300*SECOND) {
            const int recipient=Team::SeaAssist::PickTactical();
            if (recipient<0) return;
            array<int>@ ids=ai.GetOwnedUnitIds();
            for (uint i=0;i<ids.length();++i) {
                CCircuitUnit@ u=ai.GetTeamUnit(ids[i]);
                if (u is null || UnitHelpers::IsCommander(u.circuitDef) || !u.circuitDef.IsMobile()
                    || u.circuitDef.GetBuildSpeed()<=0 || u.task is null) continue;
                IBuilderTask@ b=cast<IBuilderTask>(u.task);
                if (b is null || b.buildDef is null || b.GetBuildType()>=int(Task::BuildType::REPAIR)) continue;
                worker=u.id; @project=u.task; transferAt=ai.frame;
                array<CCircuitUnit@> gift(1); @gift[0]=u;
                ai.GiveUnits(gift,recipient);
                GenericHelpers::LogUtil("[ConstructionFault] transfer worker="+worker+" recipient="+recipient,1);
                break;
            }
        }
        if (!transferDone && transferAt>=0 && ai.frame-transferAt>=40*SECOND) {
            bool retained=false;
            array<CCircuitUnit@>@ members=project.GetUnits();
            for (uint i=0;i<members.length();++i) if (members[i].id==worker) retained=true;
            GenericHelpers::LogUtil("[ConstructionFault] transferred-worker="+(!retained && ai.GetTeamUnit(worker) is null ? "PASS" : "FAIL")+" worker="+worker,1);
            transferDone=true; worker=-1; @project=null;
        }
    }
}
