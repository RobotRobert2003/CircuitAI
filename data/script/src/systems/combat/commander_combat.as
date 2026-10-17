#include "../../global.as"

namespace CommanderCombat {
    int appliedRole=-1;
    string appliedSide;
    // Per-AI overrides (D-293). Any role, profile hook or message handler of
    // this AI may call Override(); it wins over the profile JSON and the
    // Global::Commander defaults and is re-applied after every role change.
    array<string> overrideKeys;
    array<float> overrideValues;
    void Option(const string &in key,float fallback) {
        const float value=aiSetupMgr.ConfigFloat("commander/combat/"+key,fallback);
        if(!aiBuilderMgr.SetCommanderCombatOption(key,value))
            GenericHelpers::LogUtil("[Commander] rejected option "+key,1);
    }
    bool Override(const string &in key,float value) {
        const bool accepted=aiBuilderMgr.SetCommanderCombatOption(key,value);
        if(!accepted) { GenericHelpers::LogUtil("[Commander] rejected override "+key,1); return false; }
        const int index=overrideKeys.find(key);
        if(index<0) { overrideKeys.insertLast(key); overrideValues.insertLast(value); }
        else overrideValues[index]=value;
        GenericHelpers::LogUtil("[Commander] override "+key+"="+value+(accepted?"":" rejected"),1);
        return accepted;
    }
    // Drop an override; the next Update re-applies JSON and defaults.
    void ClearOverride(const string &in key) {
        const int index=overrideKeys.find(key);
        if(index<0) return;
        overrideKeys.removeAt(index); overrideValues.removeAt(index);
        if(key.findFirst("t3.")==0) aiBuilderMgr.SetCommanderCombatOption("reset."+key,0.f);
        appliedRole=-1;
    }
    void Update() {
        // Configure once per role transition. Native observes only the maintained
        // commander registry; script does not scan units or issue combat orders.
        const int role=int(Global::AISettings::Role);
        const string side=Global::AISettings::Side.length()>0?Global::AISettings::Side:ai.GetSideName();
        if(role!=appliedRole || side!=appliedSide) {
            appliedRole=role;
            appliedSide=side;
            const bool front=role==int(AiRole::FRONT) || role==int(AiRole::TACTICAL);
            Option("enabled",Global::Commander::Enabled?1.f:0.f);
            Option("advance",front?1.f:0.f);
            aiBuilderMgr.SetCommanderCombatOption("front_duty",role==int(AiRole::FRONT)?1.f:0.f);
            Option("leash",front?Global::Commander::FrontLeash:Global::Commander::HomeLeash);
            Option("scan",Global::Commander::Scan);
            Option("support",Global::Commander::SupportMetal);
            Option("min_value",Global::Commander::MinimumValue);
            Option("kill_reward",Global::Commander::KillReward);
            Option("hp_reserve",Global::Commander::HpReserve);
            Option("retreat",Global::Commander::Retreat);
            Option("recover",Global::Commander::Recover);
            Option("aggression",Global::Commander::AggressionWeight);
            Option("step",Global::Commander::Step);
            Option("max_approach",Global::Commander::MaxApproach);
            Option("max_seconds",Global::Commander::MaxSeconds);
            Option("align_seconds",Global::Commander::AlignSeconds);
            Option("shots",Global::Commander::Shots);
            Option("margin",Global::Commander::EnergyMargin);
            Option("cloak_seconds",Global::Commander::CloakSeconds);
            Option("escape_seconds",Global::Commander::EscapeSeconds);
            Option("friendly_margin",Global::Commander::FriendlyMargin);
            Option("front_workers",Global::Commander::FrontWorkers);
            Option("front_distance",Global::Commander::FrontDistance);
            Option("front_standoff",Global::Commander::FrontStandoff);
            Option("front_radius",Global::Commander::FrontRadius);
            Option("front_threat",Global::Commander::FrontThreat);
            Option("front_recovery",Global::Commander::FrontRecovery?1.f:0.f);
            Option("front_mex_seconds",Global::Commander::FrontMexSeconds);
            Option("front_stall_seconds",Global::Commander::FrontStallSeconds);
            Option("t3_intercept",Global::Commander::T3Intercept);
            Option("t3_health",Global::Commander::T3Health);
            Option("t3_distance",Global::Commander::T3Distance);
            Option("afus_defence_radius",Global::Commander::AfusDefenceRadius);
            aiBuilderMgr.SetCommanderCombatOption("afus_def",-1.f);
            for(uint i=0;i<Global::Commander::AfusDefenceUnits.length();++i) {
                CCircuitDef@ afus=ai.GetCircuitDef(Global::Commander::AfusDefenceUnits[i]);
                if(afus !is null) aiBuilderMgr.SetCommanderCombatOption("afus_def",float(afus.id));
            }
            Option("detection_margin",Global::Commander::DetectionMargin);
            Option("fallback",Global::Commander::Fallback?1.f:0.f);
            Option("fallback_metal",Global::Commander::FallbackMetal);
            Option("fallback_range_scale",Global::Commander::FallbackRangeScale);
            Option("fallback_group_radius",Global::Commander::FallbackGroupRadius);
            Option("fallback_offset",Global::Commander::FallbackOffset);
            Option("fallback_search",Global::Commander::FallbackSearch);
            Option("fallback_hold_seconds",Global::Commander::FallbackHoldSeconds);
            Option("fallback_porc_range",Global::Commander::FallbackPorcRange);
            Option("sensor_memory",Global::Commander::SensorMemory);
            Option("t3_leash",Global::Commander::T3Leash);
            Option("t3_hold_seconds",Global::Commander::T3HoldSeconds);
            Option("t3_dodge_seconds",Global::Commander::T3DodgeSeconds);
            Option("t3_hunt_leash",Global::Commander::T3HuntLeash);
            Option("t3_screen",Global::Commander::T3Screen);
            Option("t3_hunt",Global::Commander::T3Hunt);
            Option("t3_artillery_approach",Global::Commander::T3ArtilleryApproach);
            Option("t3_trade",Global::Commander::T3Trade);
            Option("t3_cloaked_volley_risk",Global::Commander::T3CloakedVolleyRisk);
            Option("t3_retry_seconds",Global::Commander::T3RetrySeconds);
            Option("t3_bait_count",Global::Commander::T3BaitCount);
            Option("t3_bait_margin",Global::Commander::T3BaitMargin);
            Option("t3_bait_distance",Global::Commander::T3BaitDistance);
            Option("t3_bait_spacing",Global::Commander::T3BaitSpacing);
            Option("t3_bait_timeout",Global::Commander::T3BaitTimeout);
            // D-299 work ladder
            Option("line_income",Global::Commander::LineIncome);
            Option("line_min",Global::Commander::LineMin);
            Option("line_max",Global::Commander::LineMax);
            Option("line_radius",Global::Commander::LineRadius);
            Option("line_spacing",Global::Commander::LineSpacing);
            Option("line_hold_seconds",Global::Commander::LineHoldSeconds);
            Option("line_retry_seconds",Global::Commander::LineRetrySeconds);
            Option("timed_interval",Global::Commander::TimedInterval);
            Option("timed_until",Global::Commander::TimedUntil);
            Option("work_radius",Global::Commander::WorkRadius);
            Option("work_clearance",Global::Commander::WorkClearance);
            Option("repair_health",Global::Commander::RepairHealth);
            Option("reclaim_storage",Global::Commander::ReclaimStorage);
            Option("reclaim_metal",Global::Commander::ReclaimMetal);
            Option("radar_coverage",Global::Commander::RadarCoverage);
            Option("base_radius",Global::Commander::BaseRadius);
            Global::Commander::Work=aiSetupMgr.ConfigFloat("commander/combat/work",Global::Commander::Work?1.f:0.f)>0.f;
            aiBuilderMgr.SetCommanderCombatOption("work",Global::Commander::Work?1.f:0.f);
            const string baitName=aiSetupMgr.ConfigString("commander/combat/t3_bait_unit",
                UnitHelpers::GetStaticLLTNameForSide(side));
            CCircuitDef@ bait=ai.GetCircuitDef(baitName);
            aiBuilderMgr.SetCommanderCombatOption("t3_bait_def",bait is null?-1.f:float(bait.id));
            for(uint i=0;i<overrideKeys.length();++i)
                aiBuilderMgr.SetCommanderCombatOption(overrideKeys[i],overrideValues[i]);
            Global::Commander::FrontRadius=AiMax(100.f,aiSetupMgr.ConfigFloat("commander/combat/front_radius",Global::Commander::FrontRadius));
            Global::Commander::FrontRadarSpacing=AiMax(100.f,aiSetupMgr.ConfigFloat("commander/combat/front_radar_spacing",Global::Commander::FrontRadarSpacing));
            Global::Commander::FrontLaserSpacing=AiMax(100.f,aiSetupMgr.ConfigFloat("commander/combat/front_laser_spacing",Global::Commander::FrontLaserSpacing));
            Global::Commander::DonorReserve=AiMax(0.f,aiSetupMgr.ConfigFloat("commander/combat/donor_reserve",Global::Commander::DonorReserve));
            Global::Commander::GrantLimit=AiMax(1.f,aiSetupMgr.ConfigFloat("commander/combat/grant_limit",Global::Commander::GrantLimit));
            Global::Commander::EnergyRequestSeconds=AiMax(1.f,aiSetupMgr.ConfigFloat("commander/combat/request_seconds",Global::Commander::EnergyRequestSeconds));
            Global::Commander::GrantSeconds=AiMax(1.f,AiMin(10.f,aiSetupMgr.ConfigFloat("commander/combat/grant_seconds",Global::Commander::GrantSeconds)));
            GenericHelpers::LogUtil("[Commander] policy role="+role+" advance="+front,1);
        }
        CommanderFront::Update();
        CommanderEnergy::Update();
    }
}
