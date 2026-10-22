// Read-only diagnostics injected into isolated playtests, never production.
namespace SeaCapacityProbe {
    int last=-100000;
    void Tick() {
        if (ai.teamId!=0 || ai.frame-last<30*SECOND) return;
        last=ai.frame;
        for (uint i=0;i<SeaEconomy::owned.length();++i) {
            CCircuitUnit@ u=ai.GetTeamUnit(SeaEconomy::owned[i]);
            if (u is null || !SeaEconomy::ConstructorDef(u.circuitDef)) continue;
            IUnitTask@ task=u.task;
            IBuilderTask@ build=cast<IBuilderTask>(task);
            string detail="";
            if (build !is null) detail=" kind="+build.GetBuildType()+" def="+(build.buildDef is null ? "none" : build.buildDef.GetName())
                +" target="+(build.target is null ? -1 : build.target.id)+" guard="+build.GetGuardTargetId()
                +" at="+int(build.GetBuildPos().x)+","+int(build.GetBuildPos().z);
            GenericHelpers::LogUtil("[SeaCapacityProbe] worker="+u.id+" type="+(task is null ? -1 : task.GetType())
                +" dead="+(task is null || task.IsDead())+" primary="+(u is Builder::primaryT1SeaConstructor)+detail,1);
        }
    }
}
