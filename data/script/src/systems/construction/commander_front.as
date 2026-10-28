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
    // Native CCommanderControl::WorkKind. Kinds 0..4 predate the D-299 ladder:
    // assist within front_radius, a mex within front_radius, the spacing
    // radar, a laser at spacing, patrol. Kind 13 is the LOS-disc mex, 16 the
    // D-357 corridor sweep (named mex_los and mex_lane below; the native enum
    // calls 13 WORK_MEX).
    const int WORK_ASSIST=0, WORK_MEX=1, WORK_RADAR_SPACING=2, WORK_LASER=3, WORK_PATROL=4;
    const int WORK_LINE=5, WORK_REPAIR_DEFENCE=6, WORK_REPAIR_UNITS=7, WORK_RECLAIM=8;
    const int WORK_TIMED=9, WORK_RADAR=10, WORK_FACTORY=11, WORK_BASE=12, WORK_MEX_LOS=13, WORK_ADVANCE=14, WORK_HOLD=15;
    const int WORK_MEX_LANE=16;
    // D-356: the order of the rungs is profile policy, commander.json
    // commander/combat/front_ladder (a comma list of the names in Rung), read
    // once and again only when the string changes. The default is the meta's
    // order: take the corridor's metal first ("mex plus LLT at the cluster"),
    // then line turrets, repairs and reclaim, and only then walk on.
    const string DefaultLadder="mex_lane,line,repair_defence,repair_units,reclaim,mex_los,timed_laser,timed_aa,radar,advance,assist,factory,mex,radar_spacing,laser,base,hold,patrol";
    array<string> ladder;
    array<string> unknownRungs;
    string ladderSource;
    string Trim(const string &in text) {
        string value=text;
        while(value.length()>0 && value.substr(0,1)==" ") value=value.substr(1);
        while(value.length()>0 && value.substr(value.length()-1,1)==" ") value=value.substr(0,value.length()-1);
        return value;
    }
    void LoadLadder() {
        const string text=aiSetupMgr.ConfigString("commander/combat/front_ladder",DefaultLadder);
        if(text==ladderSource && ladder.length()>0) return;
        ladderSource=text;
        ladder.resize(0);
        array<string>@ parts=text.split(",");
        for(uint i=0;i<parts.length();++i) {
            const string name=Trim(parts[i]);
            if(name.length()>0) ladder.insertLast(name);
        }
        GenericHelpers::LogUtil("[CommanderFront] ladder="+text,1);
    }
    CCircuitDef@ Def(const string &in key,const string &in fallback) {
        return ai.GetCircuitDef(aiSetupMgr.ConfigString("commander/combat/"+key,fallback));
    }
    // One rung by name: null when it does not apply. Ladder rungs (D-299)
    // need Global::Commander::Work; the pre-D-299 spacing radar applies only
    // without it. Native chooses a reachable, locally safe target inside any
    // fallback perimeter and reuses existing build claims; combat preempts
    // every rung natively.
    IUnitTask@ Rung(CCircuitUnit@ unit,const string &in name,CCircuitDef@ laser,CCircuitDef@ aa,CCircuitDef@ radar) {
        const bool work=Global::Commander::Work;
        if(name=="mex_lane") return aiBuilderMgr.CommanderFrontWork(unit,WORK_MEX_LANE,laser,0.f);
        if(name=="advance") return aiBuilderMgr.CommanderFrontWork(unit,WORK_ADVANCE,null,0.f);
        if(name=="hold") return aiBuilderMgr.CommanderFrontWork(unit,WORK_HOLD,null,
            aiSetupMgr.ConfigFloat("commander/combat/front_hold_seconds",10.f));
        if(name=="assist") return aiBuilderMgr.CommanderFrontWork(unit,WORK_ASSIST,null,Global::Commander::FrontRadius);
        if(name=="mex") return aiBuilderMgr.CommanderFrontWork(unit,WORK_MEX,null,Global::Commander::FrontRadius);
        if(name=="laser") return aiBuilderMgr.CommanderFrontWork(unit,WORK_LASER,laser,Global::Commander::FrontLaserSpacing);
        if(name=="patrol") return aiBuilderMgr.CommanderFrontWork(unit,WORK_PATROL,null,Global::Commander::FrontRadius);
        if(name=="radar_spacing") return work?null:aiBuilderMgr.CommanderFrontWork(unit,WORK_RADAR_SPACING,radar,Global::Commander::FrontRadarSpacing);
        if(!work) return null;
        if(name=="line") return aiBuilderMgr.CommanderFrontWork(unit,WORK_LINE,laser,0.f);
        if(name=="repair_defence") return aiBuilderMgr.CommanderFrontWork(unit,WORK_REPAIR_DEFENCE,null,0.f);
        if(name=="repair_units") return aiBuilderMgr.CommanderFrontWork(unit,WORK_REPAIR_UNITS,null,0.f);
        if(name=="reclaim") return aiBuilderMgr.CommanderFrontWork(unit,WORK_RECLAIM,null,0.f);
        if(name=="mex_los") return aiBuilderMgr.CommanderFrontWork(unit,WORK_MEX_LOS,null,0.f);
        if(name=="timed_laser") return aiBuilderMgr.CommanderFrontWork(unit,WORK_TIMED,laser,0.f);
        if(name=="timed_aa") return aiBuilderMgr.CommanderFrontWork(unit,WORK_TIMED,aa,0.f);
        if(name=="radar") return aiBuilderMgr.CommanderFrontWork(unit,WORK_RADAR,radar,0.f);
        if(name=="radar_ghost") return FrontRadar::GhostTask(unit); // owner 2026-10-27: reach scouted enemy structures out of radar
        if(name=="factory") return aiBuilderMgr.CommanderFrontWork(unit,WORK_FACTORY,null,Global::Commander::FrontRadius);
        if(name=="base") return aiBuilderMgr.CommanderFrontWork(unit,WORK_BASE,null,0.f);
        if(unknownRungs.find(name)<0) {
            unknownRungs.insertLast(name);
            GenericHelpers::LogUtil("[CommanderFront] unknown ladder rung "+name,1);
        }
        return null;
    }
    IUnitTask@ Work(CCircuitUnit@ unit) {
        if(!Ready()) return null;
        // owner 2026-10-28: a ghost radar this commander ordered is finished before other rungs
        IUnitTask@ ghost=FrontRadar::GhostKeep(unit);
        if(ghost !is null) return ghost;
        LoadLadder();
        // Roles choose the order, definitions and spacing.
        const string side=UnitHelpers::GetSideForUnitName(unit.circuitDef.GetName());
        CCircuitDef@ laser=Def("line_unit",UnitHelpers::GetStaticLLTNameForSide(side));
        CCircuitDef@ aa=Def("timed_aa_unit",UnitHelpers::GetStaticAALightNameForSide(side));
        CCircuitDef@ radar=ai.GetCircuitDef(UnitHelpers::GetStaticRadarNameForSide(side));
        for(uint i=0;i<ladder.length();++i) {
            IUnitTask@ task=Rung(unit,ladder[i],laser,aa,radar);
            if(task !is null) return task;
        }
        return null;
    }
}
