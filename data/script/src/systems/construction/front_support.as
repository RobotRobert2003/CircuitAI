// FRONT's one-member construction group. Policy owns income, roster and defs;
// native work owns local placement, task handover and fresh coverage queries.
namespace FrontSupport {
    int member=-1;
    bool enabled=false;
    uint scannedRevision=0;
    bool scanned=false;
    const array<string> candidates={"armck","corck","legck","armcv","corcv","legcv","armch","corch","legch","armbeaver","cormuskrat","legotter"};
    bool Eligible(CCircuitUnit@ unit) {
        return unit !is null && candidates.find(unit.circuitDef.GetName())>=0
            && !unit.circuitDef.IsAbleToFly() && unit.task !is null && !unit.task.IsExternalControlled()
            && unit.task.GetType()!=int(Task::Type::PLAYER)
            && !Team::Ferry::IsGift(unit.id) && !Team::Recovery::IsGift(unit.id);
    }
    void Definition(const string &in key,const string &in fallback) {
        CCircuitDef@ def=ai.GetCircuitDef(aiSetupMgr.ConfigString("commander/combat/"+key,fallback));
        aiBuilderMgr.SetCommanderCombatOption(key,def is null?-1.f:float(def.id));
    }
    void Update() {
        if(Global::AISettings::Role!=AiRole::FRONT) return;
        if(!enabled && aiEconomyMgr.metal.income>=aiSetupMgr.ConfigFloat("commander/combat/front_support_income",20.f))
            enabled=true; // once reached, replace losses even after income drops
        if(!enabled) return;
        CCircuitUnit@ unit=ai.GetTeamUnit(member);
        if(!Eligible(unit)) {
            if(member>=0) scanned=false; // task ownership can change without an owned-unit revision
            member=-1;
            // One owned-ID scan per ownership revision while vacant. Stable
            // IDs only, no handles retained through deaths or transfers.
            const uint revision=ai.GetOwnedUnitRevision();
            if(!scanned || scannedRevision!=revision) {
                scanned=true;scannedRevision=revision;
                array<int>@ ids=ai.GetOwnedUnitIds();
                for(uint i=0;i<ids.length();++i) {
                    CCircuitUnit@ candidate=ai.GetTeamUnit(ids[i]);
                    if(Eligible(candidate) && (member<0 || candidate.id<member)) member=candidate.id;
                }
            }
            @unit=ai.GetTeamUnit(member);
            aiBuilderMgr.SetCommanderCombatOption("front_support_unit",float(member));
            if(unit !is null) {
                const string side=UnitHelpers::GetSideForUnitName(unit.circuitDef.GetName());
                Definition("front_support_def",side=="cortex"?"corhllt":side=="legion"?"legmg":"armbeamer");
                Definition("front_support_nano",side=="cortex"?"cornanotc":side=="legion"?"legnanotc":"armnanotc");
                Definition("front_support_radar",UnitHelpers::GetStaticRadarNameForSide(side));
                Definition("front_support_jammer",UnitHelpers::GetStaticJammerNameForSide(side));
                Definition("front_support_aa",UnitHelpers::GetStaticAALightNameForSide(side));
                GenericHelpers::LogUtil("[FrontSupport] member="+member+" side="+side,1);
            }
        }
        aiBuilderMgr.SetCommanderCombatOption("front_support_unit",float(member));
    }
    IUnitTask@ Recruit(CCircuitUnit@ factory) {
        Update();
        if(!enabled || member>=0) return null;
        // Count across every eligible definition before asking any factory.
        // Pending registry is updated synchronously, so parallel labs cannot
        // enqueue one replacement each. Existing unfinished units are members.
        for(uint i=0;i<candidates.length();++i) {
            CCircuitDef@ def=ai.GetCircuitDef(candidates[i]);
            if(def !is null && aiFactoryMgr.GetPendingRecruitCount(def)>0) return null;
        }
        for(uint i=0;i<candidates.length();++i) {
            CCircuitDef@ def=ai.GetCircuitDef(candidates[i]);
            if(def !is null && factory.circuitDef.CanBuild(def) && def.IsAvailable(ai.frame))
                return aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER,Task::Priority::HIGH,def,factory.GetPos(ai.frame),64.f));
        }
        return null;
    }
    IUnitTask@ Work(CCircuitUnit@ unit) {
        Update();
        return unit.id==member?aiBuilderMgr.CommanderFrontWork(unit,19,null,0.f):null;
    }
}
