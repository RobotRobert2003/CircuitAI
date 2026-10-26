#include "front_constructors.as"
// FRONT's one-member construction group. Policy owns income, roster and defs;
// native work owns local placement, task handover and fresh coverage queries.
namespace CommanderGroup {
    int member=-1;
    bool enabled=false;
    bool Eligible(CCircuitUnit@ unit) {
        return FrontConstructors::Eligible(unit)
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
        FrontConstructors::Load();
        if(!enabled && (aiTerrainMgr.GetLayoutInt("front.constructor.group_enabled",0)!=0
            || aiEconomyMgr.metal.income>=aiSetupMgr.ConfigFloat("commander/combat/commander_group_income",20.f))) {
            enabled=true; // once reached, replace losses even after income drops
            aiTerrainMgr.SetLayoutInt("front.constructor.group_enabled",1);
        }
        if(!enabled) return;
        CCircuitUnit@ unit=ai.GetTeamUnit(FrontConstructors::seats[2]);
        const int selected=Eligible(unit)?unit.id:-1;
        if(member!=selected) {
            member=selected;
            aiBuilderMgr.SetCommanderCombatOption("commander_group_unit",float(member));
            if(unit !is null) {
                const string side=UnitHelpers::GetSideForUnitName(unit.circuitDef.GetName());
                Definition("commander_group_def",side=="cortex"?"corhllt":side=="legion"?"legmg":"armbeamer");
                Definition("commander_group_nano",side=="cortex"?"cornanotc":side=="legion"?"legnanotc":"armnanotc");
                Definition("commander_group_radar",UnitHelpers::GetStaticRadarNameForSide(side));
                Definition("commander_group_jammer",UnitHelpers::GetStaticJammerNameForSide(side));
                Definition("commander_group_aa",UnitHelpers::GetStaticAALightNameForSide(side));
                GenericHelpers::LogUtil("[CommanderGroup] member="+member+" side="+side,1);
            }
        }
        aiBuilderMgr.SetCommanderCombatOption("commander_group_unit",float(member));
    }
    IUnitTask@ Recruit(CCircuitUnit@ factory) {
        Update();
        return FrontConstructors::Recruit(factory,enabled);
    }
    IUnitTask@ Work(CCircuitUnit@ unit) {
        Update();
        return unit.id==member?aiBuilderMgr.CommanderFrontWork(unit,19,null,0.f):null;
    }
}
