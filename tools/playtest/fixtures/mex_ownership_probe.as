namespace MexOwnershipProbe {
    int hillAir=-1, foreignAir=-1;
    AIFloat3 hill(-1,0,-1), foreign(-1,0,-1);
    IUnitTask@ hillTask;
    IUnitTask@ foreignTask;
    IUnitTask@ staleTask;
    bool staleReported=false;
    const float cutoff=__CUTOFF__;
    void Report(const string& in label, bool pass) {
        GenericHelpers::LogUtil("[MexOwnershipTest] "+(pass?"PASS ":"FAIL ")+label,1);
        if (!pass) GenericHelpers::LogUtil("[INVARIANT] INV-227 mex navigation/ownership: "+label,1);
    }
    bool Handle(const string& in message) {
        array<string>@ p=message.split("|");
        if (p.length()<2 || p[0]!="mex-test") return false;
        if (p[1]=="hill" && p.length()==9) {
            CCircuitUnit@ low=ai.GetTeamUnit(parseInt(p[2]));
            CCircuitUnit@ high=ai.GetTeamUnit(parseInt(p[3]));
            hillAir=parseInt(p[4]);
            hill=AIFloat3(parseFloat(p[5]),0,parseFloat(p[6]));
            AIFloat3 bottom(parseFloat(p[7]),0,parseFloat(p[8]));
            Report("default configuration",Global::RoleSettings::MexOwnershipSeconds==600.f);
            Report("profile enabled",Global::RoleSettings::MexOwnershipEnabled);
            aiEconomyMgr.SetMexOwnership(true,cutoff);
            if (low !is null && high !is null)
                GenericHelpers::LogUtil("[MexOwnershipTest] legacy reach uphill="
                    +aiTerrainMgr.CanReachAtSafe(low,hill,low.circuitDef.GetBuildDistance())
                    +" downhill="+aiTerrainMgr.CanReachAtSafe(high,bottom,high.circuitDef.GetBuildDistance()),1);
            Report("valley cannot build mountain",low !is null && !aiEconomyMgr.CanReachMex(low,hill));
            Report("mountain cannot build valley",high !is null && !aiEconomyMgr.CanReachMex(high,bottom));
            Report("air can build mountain",aiEconomyMgr.CanReachMex(ai.GetTeamUnit(hillAir),hill));
        } else if (p[1]=="foreign" && p.length()==5) {
            foreignAir=parseInt(p[2]);
            foreign=AIFloat3(parseFloat(p[3]),0,parseFloat(p[4]));
            Report("ally protected",!aiEconomyMgr.IsOwnMex(foreign));
            IUnitTask@ rejected=aiEconomyMgr.EnqueueMexWithin(ai.GetTeamUnit(foreignAir),foreign,32,0,false);
            Report("opening cannot bypass ownership",rejected is null);
            aiEconomyMgr.SetMexOwnership(true,0);
            Report("zero disables protection",aiEconomyMgr.IsOwnMex(foreign));
            @staleTask=aiEconomyMgr.EnqueueMexWithin(ai.GetTeamUnit(foreignAir),foreign,32,0,false);
            Report("unstarted order supplied",staleTask !is null);
            aiEconomyMgr.SetMexOwnership(true,cutoff);
        } else if (p[1]=="before") {
            Report("protected before deadline",!aiEconomyMgr.IsOwnMex(foreign));
        } else if (p[1]=="after") {
            Report("released at deadline",aiEconomyMgr.IsOwnMex(foreign));
        }
        return true;
    }
    IUnitTask@ Task(CCircuitUnit@ unit) {
        if (unit.id==foreignAir && staleTask !is null && !staleReported) {
            if (!staleTask.IsDead()) return staleTask;
            staleReported=true;
            Report("stale order released",ai.frame<int(cutoff*SECOND));
        }
        if (unit.id==hillAir && hill.x>=0) {
            if (hillTask is null) @hillTask=aiEconomyMgr.EnqueueMexWithin(unit,hill,32,0,true);
            if (hillTask !is null && !hillTask.IsDead()) return hillTask;
        }
        if (unit.id==foreignAir && foreign.x>=0 && ai.frame>=int(cutoff*SECOND)) {
            if (foreignTask is null) @foreignTask=aiEconomyMgr.EnqueueMexWithin(unit,foreign,32,0,true);
            if (foreignTask !is null && !foreignTask.IsDead()) return foreignTask;
        }
        return aiBuilderMgr.Enqueue(TaskB::Wait(SECOND));
    }
}
