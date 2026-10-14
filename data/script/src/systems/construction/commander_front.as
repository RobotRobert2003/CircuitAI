// FRONT duty is offered before default economy can enqueue a base job.
// Only task offers mutate native structure ownership; combat can preempt them.
namespace CommanderFront {
    bool wasReady=false;
    const array<string> nanos={"armnanotc","cornanotc","legnanotc","armnanotcplat","cornanotcplat","legnanotcplat"};
    bool Ready() {
        if(Global::AISettings::Role!=AiRole::FRONT || aiFactoryMgr.GetFactoryCount()<1) return false;
        for(uint i=0;i<nanos.length();++i) {
            CCircuitDef@ def=ai.GetCircuitDef(nanos[i]);
            if(def !is null && def.count-aiBuilderMgr.GetUnfinishedCount(def)>=1) return true;
        }
        return false;
    }
    void Update() {
        const bool ready=Ready();
        aiBuilderMgr.SetCommanderCombatOption("front_ready",ready?1.f:0.f);
        if(ready!=wasReady) {
            wasReady=ready;
            GenericHelpers::LogUtil("[CommanderFront] ready="+(ready?1:0),1);
        }
    }
    // D-299 ladder kinds (native CCommanderControl::WorkKind).
    const int WORK_ASSIST=0, WORK_MEX=1, WORK_LASER=3, WORK_PATROL=4;
    const int WORK_LINE=5, WORK_REPAIR_DEFENCE=6, WORK_REPAIR_UNITS=7, WORK_RECLAIM=8;
    const int WORK_TIMED=9, WORK_RADAR=10, WORK_FACTORY=11, WORK_BASE=12, WORK_MEX_LOS=13;
    CCircuitDef@ Def(const string &in key,const string &in fallback) {
        return ai.GetCircuitDef(aiSetupMgr.ConfigString("commander/combat/"+key,fallback));
    }
    IUnitTask@ Work(CCircuitUnit@ unit) {
        if(!Ready()) return null;
        // Roles choose the order, definitions and spacing. Native chooses a
        // reachable, locally safe target inside any fallback perimeter and
        // reuses existing build claims. Combat preempts every rung natively.
        const string side=UnitHelpers::GetSideForUnitName(unit.circuitDef.GetName());
        CCircuitDef@ laser=Def("line_unit",UnitHelpers::GetStaticLLTNameForSide(side));
        CCircuitDef@ aa=Def("timed_aa_unit",UnitHelpers::GetStaticAALightNameForSide(side));
        CCircuitDef@ radar=ai.GetCircuitDef(UnitHelpers::GetStaticRadarNameForSide(side));
        IUnitTask@ task=null;
        if(Global::Commander::Work) {
            // Fallback line turrets; repairs (static defence, then T3/T2/T1);
            // metal reclaim while storage has room; extractors on open spots
            // in line of sight; timed LLT then light AA;
            // radar outside friendly coverage; assist builds, then plants.
            @task=aiBuilderMgr.CommanderFrontWork(unit,WORK_LINE,laser,0.f);
            if(task is null) @task=aiBuilderMgr.CommanderFrontWork(unit,WORK_REPAIR_DEFENCE,null,0.f);
            if(task is null) @task=aiBuilderMgr.CommanderFrontWork(unit,WORK_REPAIR_UNITS,null,0.f);
            if(task is null) @task=aiBuilderMgr.CommanderFrontWork(unit,WORK_RECLAIM,null,0.f);
            if(task is null) @task=aiBuilderMgr.CommanderFrontWork(unit,WORK_MEX_LOS,null,0.f);
            if(task is null) @task=aiBuilderMgr.CommanderFrontWork(unit,WORK_TIMED,laser,0.f);
            if(task is null) @task=aiBuilderMgr.CommanderFrontWork(unit,WORK_TIMED,aa,0.f);
            if(task is null) @task=aiBuilderMgr.CommanderFrontWork(unit,WORK_RADAR,radar,0.f);
            if(task !is null) return task;
        }
        @task=aiBuilderMgr.CommanderFrontWork(unit,WORK_ASSIST,null,Global::Commander::FrontRadius);
        if(task !is null) return task;
        if(Global::Commander::Work) {
            @task=aiBuilderMgr.CommanderFrontWork(unit,WORK_FACTORY,null,Global::Commander::FrontRadius);
            if(task !is null) return task;
        }
        @task=aiBuilderMgr.CommanderFrontWork(unit,WORK_MEX,null,Global::Commander::FrontRadius);
        if(task !is null) return task;
        if(!Global::Commander::Work) {
            // Pre-D-299 spacing radar; the ladder's coverage radar replaces it.
            @task=aiBuilderMgr.CommanderFrontWork(unit,2,radar,Global::Commander::FrontRadarSpacing);
            if(task !is null) return task;
        }
        @task=aiBuilderMgr.CommanderFrontWork(unit,WORK_LASER,laser,Global::Commander::FrontLaserSpacing);
        if(task !is null) return task;
        if(Global::Commander::Work) {
            // Fell back to the main base: assist base construction, then plants.
            @task=aiBuilderMgr.CommanderFrontWork(unit,WORK_BASE,null,0.f);
            if(task !is null) return task;
        }
        return aiBuilderMgr.CommanderFrontWork(unit,WORK_PATROL,null,Global::Commander::FrontRadius);
    }
}
