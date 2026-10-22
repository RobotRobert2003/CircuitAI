void test_control_requires_positive_survey_and_fleet_evidence() {
    Check(SeaMath::ControlState(0,1000,300,90,0,10,.6f,600)==0);
    Check(SeaMath::ControlState(0,1000,300,90,6,10,.6f,600)==3);
    Check(SeaMath::ControlState(0,100,300,90,10,10,.6f,600)==0);
    Check(SeaMath::ControlState(0,1000,30,90,10,10,.6f,600)==0);
    Check(SeaMath::ControlState(0,1000,300,90,0,0,.6f,600)==0);
}
void test_control_revokes_on_contact_and_distinguishes_advantage() {
    Check(SeaMath::ControlState(1000,1000,300,90,10,10,.6f,600)==1);
    Check(SeaMath::ControlState(1000,1600,300,90,10,10,.6f,600)==2);
    Check(SeaMath::ControlState(0,1600,300,90,5,10,.6f,600)==0);
}
void test_scout_raids_reject_hidden_submerged_allied_and_outmatching_targets() {
    Check(SeaMath::ScoutRaidTarget(32,true,false,300,0,96));
    Check(SeaMath::ScoutRaidTarget(0,true,true,650,300,96));
    Check(!SeaMath::ScoutRaidTarget(0,true,true,300,650,96));
    Check(!SeaMath::ScoutRaidTarget(0,false,false,650,0,96));
    Check(!SeaMath::ScoutRaidTarget(128,true,false,650,0,96));
    Check(!SeaMath::ScoutRaidTarget(2,true,false,650,0,96));
    Check(!SeaMath::ScoutRaidTarget(1,true,false,650,0,96));
    Check(!SeaMath::ScoutRaidTarget(16,false,false,650,0,96));
    Check(!SeaMath::ScoutRaidTarget(0,true,true,396,300,96));
}
void test_scout_assembly_does_not_release_understrength_suicide_wave() {
    Check(SeaMath::ScoutRaidExpired(10,30,90,2,2,3,false));
    Check(!SeaMath::ScoutRaidExpired(10,30,90,3,2,3,false));
    Check(SeaMath::ScoutRaidExpired(31,30,90,3,2,3,false));
    Check(!SeaMath::ScoutRaidExpired(31,30,90,3,3,3,true));
    Check(SeaMath::ScoutRaidExpired(91,30,90,3,3,3,true));
}
void test_invasion_replans_only_uncommitted_or_dead_slots() {
    Check(SeaMath::ReplanInvasionSlot(-1,false,false));
    Check(SeaMath::ReplanInvasionSlot(4,true,true));
    Check(SeaMath::ReplanInvasionSlot(0,false,true));
    Check(SeaMath::ReplanInvasionSlot(0,true,false));
    Check(!SeaMath::ReplanInvasionSlot(0,true,true));
    for (int state=1;state<=3;++state)
        Check(!SeaMath::ReplanInvasionSlot(state,false,false));
}
void test_conversion_counts_active_draw_and_pending_capacity_once() {
    // 2000 income, 300 productive spending, 700 conversion, 980 completed +
    // committed capacity, 100 reserve: another 620 E/s can be converted.
    Check(SeaMath::ConversionGap(2000,1000,700,980,100)==620);
    Check(SeaMath::ConversionGap(2000,300,0,980,100)==620);
    Check(SeaMath::ConversionGap(2000,1000,700,1580,100)==20);
    Check(SeaMath::ConversionGap(500,1000,0,70,100)==0);
    Check(SeaMath::ConversionGap(500,0,50,70,100)==330);
}
void test_conversion_uses_surplus_and_activation_bank_not_metal_income_ceiling() {
    Check(SeaMath::ConversionReady(false,750,1000,.75f,2000,250,620,600,0,3));
    Check(SeaMath::ConversionReady(false,725,1000,.75f,2000,250,60,70,2,3));
    Check(!SeaMath::ConversionReady(false,724,1000,.75f,2000,250,620,600,0,3));
    Check(!SeaMath::ConversionReady(false,900,1000,.75f,2000,250,449,600,0,3));
    Check(!SeaMath::ConversionReady(false,900,1000,.75f,2000,250,620,600,3,3));
    Check(!SeaMath::ConversionReady(true,1000,1000,.75f,2000,250,620,600,0,3));
    Check(!SeaMath::ConversionReady(false,0,0,.75f,2000,250,620,600,0,3));
    Check(!SeaMath::ConversionReady(false,590,1000,0,2000,250,620,600,0,3));
}
void test_fusion_investment_needs_sustained_income_and_uncommitted_bank() {
    Check(SeaMath::CapitalEnergyReady(35,1200,300,1000,5200,33500,360,.45f,30,1200));
    Check(!SeaMath::CapitalEnergyReady(29,1200,6000,50000,5200,33500,360,.45f,30,1200));
    Check(!SeaMath::CapitalEnergyReady(35,1199,6000,50000,5200,33500,360,.45f,30,1200));
    Check(!SeaMath::CapitalEnergyReady(35,1200,99,1000,5200,33500,360,.45f,30,1200));
    Check(!SeaMath::CapitalEnergyReady(35,1200,300,499,5200,33500,360,.45f,30,1200));
    Check(!SeaMath::CapitalEnergyReady(30,1200,100,1000,5200,33500,360,.45f,30,1200));
}
void test_seaplane_requires_sustained_income_even_with_gifted_bank() {
    Check(!SeaMath::SeaplaneEconomyReady(false,80,1500,100000,100000,1450,5000,80,1500,500,1000));
    Check(!SeaMath::SeaplaneEconomyReady(true,79.9f,1500,100000,100000,1450,5000,80,1500,500,1000));
    Check(!SeaMath::SeaplaneEconomyReady(true,80,1499,100000,100000,1450,5000,80,1500,500,1000));
}
void test_sea_control_requires_complete_recent_coverage_and_quiet() {
    Check(SeaMath::SeaSecured(0,1,0,900,900));
    Check(!SeaMath::SeaSecured(-1,1,0,900,900));
    Check(!SeaMath::SeaSecured(0,.999f,0,900,900));
    Check(!SeaMath::SeaSecured(0,1,1,900,900));
    Check(!SeaMath::SeaSecured(0,1,-1,900,900));
    Check(!SeaMath::SeaSecured(0,1,0,899,900));
    Check(!SeaMath::SeaSecured(0,1,0,-1,900));
}
void test_invasion_admission_needs_escort_predecessor_and_both_resources() {
    Check(SeaMath::InvasionFactoryReady(true,true,true,true,150,5000,150,5000));
    Check(!SeaMath::InvasionFactoryReady(false,true,true,true,150,5000,150,5000));
    Check(!SeaMath::InvasionFactoryReady(true,false,true,true,150,5000,150,5000));
    Check(!SeaMath::InvasionFactoryReady(true,true,false,true,150,5000,150,5000));
    Check(!SeaMath::InvasionFactoryReady(true,true,true,false,150,5000,150,5000));
    Check(!SeaMath::InvasionFactoryReady(true,true,true,true,149,5000,150,5000));
    Check(!SeaMath::InvasionFactoryReady(true,true,true,true,150,4999,150,5000));
}
void test_seaplane_preserves_full_cost_and_reserve_after_commitments() {
    Check(SeaMath::SeaplaneEconomyReady(true,80,1500,1950,6000,1450,5000,80,1500,500,1000));
    Check(!SeaMath::SeaplaneEconomyReady(true,80,1500,1949,6000,1450,5000,80,1500,500,1000));
    Check(!SeaMath::SeaplaneEconomyReady(true,80,1500,1950,5999,1450,5000,80,1500,500,1000));
    // A 400-metal queued commitment is unavailable even with 2300 banked.
    Check(!SeaMath::SeaplaneEconomyReady(true,100,2000,2300-400,10000,1450,5000,80,1500,500,1000));
    Check(!SeaMath::SeaplaneEconomyReady(true,100,2000,-100,10000,1450,5000,80,1500,500,1000));
}
void test_seaplane_uses_actual_faction_and_modified_costs() {
    Check(SeaMath::SeaplaneEconomyReady(true,80,1500,1900,6500,1400,5500,80,1500,500,1000));
    Check(!SeaMath::SeaplaneEconomyReady(true,80,1500,1950,6000,2900,10000,80,1500,500,1000));
    Check(!SeaMath::SeaplaneEconomyReady(true,80,1500,1950,6000,-1,5000,80,1500,500,1000));
    Check(!SeaMath::SeaplaneEconomyReady(true,80,1500,1950,6000,1450,5000,80,1500,-1,1000));
}

void test_rear_fusion_footprint_keeps_protected_margin() {
    Check(SeaMath::RearFootprint(-160,96,64));
    Check(!SeaMath::RearFootprint(-159,96,64));
    Check(!SeaMath::RearFootprint(160,96,64));
    Check(!SeaMath::RearFootprint(-160,-1,64));
}
void test_shared_factory_support_budget_and_pending_power() {
    Check(SeaMath::ProductionShare(300,1200)==.25f);
    Check(SeaMath::ProductionShare(900,1200)==.75f);
    Check(SeaMath::ProductionShare(300,300)==1);
    Check(SeaMath::ProductionShare(0,0)==0);
    Check(SeaMath::ProductionShare(300,0)==0);
    Check(SeaMath::SupportNeeded(1000,800,300,200,40));
    Check(!SeaMath::SupportNeeded(899,800,300,200,40));
    // Framed/queued 200 BP removes a shortage even before it becomes usable.
    Check(!SeaMath::SupportNeeded(1000,1000,300,200,40));
    Check(!SeaMath::SupportNeeded(20000,8300,300,200,40));
    Check(SeaMath::SupportNeeded(20000,8100,300,200,40));
}
void test_counter_admission_and_time_to_coverage() {
    // Existing and queued coverage together prevent duplicate responses.
    Check(SeaMath::Deficit(1500,900,600)==0);
    Check(SeaMath::Deficit(1500,900,300)==300);
    // Prefer the timely adequate escort over a capital hull for a small raid.
    Check(SeaMath::CounterScore(300,400,10,true)>SeaMath::CounterScore(300,10000,120,true));
    Check(SeaMath::CounterScore(300,400,10,false)==0);
    Check(SeaMath::CounterScore(300,400,0,true)==0);
    Check(SeaMath::CounterScore(0,400,10,true)==0);
    Check(SeaMath::CounterScore(300,0,10,true)==0);
    // A lower income tech transition is still constrained by its full package.
    Check(!SeaMath::TechReady(30,800,800,2000,30,800,800,4400,22000,150,.65));
    Check(SeaMath::TechReady(30,800,1500,2000,30,800,800,4400,22000,150,.65));
    Check(!SeaMath::TechReady(30,799,5000,2000,30,800,800,4400,22000,150,.65));
}
void test_canceled_unframed_berth_is_retryable() {
    Check(SeaMath::RetryBerth(true,false,0));
    Check(!SeaMath::RetryBerth(true,true,0));
    Check(!SeaMath::RetryBerth(true,false,1));
    Check(!SeaMath::RetryBerth(true,false,2));
    Check(!SeaMath::RetryBerth(true,false,3));
    Check(!SeaMath::RetryBerth(true,false,-1));
    Check(!SeaMath::RetryBerth(false,false,0));
}
void test_safety_interruption_restarts_unchanged_site_timer() {
    Check(SeaMath::RestartStability(-1,false));
    Check(SeaMath::RestartStability(1200,true));
    Check(!SeaMath::RestartStability(1200,false));
}

void test_yard_whole_footprint_stays_forward_of_economy() {
    Check(SeaMath::ForwardFootprint(300,100,72,128));
    Check(!SeaMath::ForwardFootprint(299,100,72,128));
    Check(!SeaMath::ForwardFootprint(300,-1,72,128));
    Check(!SeaMath::ForwardFootprint(300,100,72,-1));
}

void test_aa_screen_slots_stay_separate_and_overlap() {
    // Reinforcements/losses do not move survivors' slots. Fixed six columns
    // form as many rows as necessary rather than collapsing to a centre.
    for (int n=0;n<120;++n) for (int j=0;j<n;++j)
        Check(SeaMath::AAColumn(n,6)!=SeaMath::AAColumn(j,6)
            || SeaMath::AARow(n,6)!=SeaMath::AARow(j,6));
    Check(SeaMath::AAColumn(0,6)==0 && SeaMath::AAColumn(1,6)==1 && SeaMath::AAColumn(2,6)==-1);
    Check(SeaMath::AARow(6,6)==1 && SeaMath::AAColumn(6,6)==0);
    Check(SeaMath::AARow(6,0)==6); // invalid column tuning cannot divide by zero
    Check(SeaMath::AASpacing(320,750)==320);
    Check(SeaMath::AASpacing(320,400)==220);
}
void test_interception_respects_speed_weapon_reach_and_horizon() {
    Check(SeaMath::InterceptLead(700,60,750,12)==0);
    Check(SeaMath::InterceptLead(990,60,750,12)==4);
    Check(SeaMath::InterceptLead(5000,60,750,12)==12);
    Check(SeaMath::InterceptLead(5000,0,750,12)==0);
    Check(SeaMath::InterceptLead(5000,60,750,0)==0);
}

void test_recovery_low_metal_hysteresis() {
    Check(SeaMath::RecoveryLowMetal(false,199,1000,.2f,.4f));
    Check(!SeaMath::RecoveryLowMetal(false,200,1000,.2f,.4f));
    Check(SeaMath::RecoveryLowMetal(true,399,1000,.2f,.4f));
    Check(!SeaMath::RecoveryLowMetal(true,400,1000,.2f,.4f));
    Check(!SeaMath::RecoveryLowMetal(true,0,0,.2f,.4f));
}
void test_recovery_fleet_and_income_both_scale_capacity() {
    Check(SeaMath::RecoveryCount(1000,1499,60,6000)==0);
    Check(SeaMath::RecoveryCount(20,1500,60,6000)==1);
    Check(SeaMath::RecoveryCount(60,6000,60,6000)==2);
    Check(SeaMath::RecoveryCount(600,6000,60,6000)==2);
    Check(SeaMath::RecoveryCount(120,60000,60,6000)==3);
    Check(SeaMath::RecoveryCount(600,60000,60,6000)==11);
    Check(SeaMath::RecoveryCount(60,6000,0,6000)==0);
}
void test_expansion_rejects_hostile_coverage_and_invalid_thresholds() {
    Check(!SeaMath::ExpansionNeedsEscort(3600,10000));
    Check(SeaMath::ExpansionNeedsEscort(3601,10000));
    Check(SeaMath::ExpansionThreatSafe(0,.1f));
    Check(SeaMath::ExpansionThreatSafe(.1f,.1f));
    Check(!SeaMath::ExpansionThreatSafe(.1001f,.1f));
    Check(!SeaMath::ExpansionThreatSafe(-1,.1f));
    Check(!SeaMath::ExpansionThreatSafe(0,-1));
}
void test_cluster_fortification_preserves_metal_reserve_and_energy_funding() {
    Check(SeaMath::ExpansionFortFunded(120,10,0,50,170,500));
    Check(!SeaMath::ExpansionFortFunded(119,10,0,50,170,500));
    Check(!SeaMath::ExpansionFortFunded(120,10,0,49,170,500));
    Check(!SeaMath::ExpansionFortFunded(1000,0,10000,50,170,500));
}
void test_capacity_and_commander_boundaries() {
    Check(SeaMath::AssistPriority(true,false,false)==-1);
    Check(SeaMath::AssistPriority(false,true,false)==1);
    Check(SeaMath::AssistPriority(false,false,true)==1);
    Check(SeaMath::AssistPriority(false,false,false)==0);
    Check(!SeaMath::CommanderHandoff(false,10,4));
    Check(!SeaMath::CommanderHandoff(true,3,4));
    Check(SeaMath::CommanderHandoff(true,4,4));
    Check(!SeaMath::CommanderHandoff(true,4,0));
    Check(SeaMath::CapacityPressure(51,50,200,1000,false));
    Check(!SeaMath::CapacityPressure(51,50,199,1000,false));
    Check(!SeaMath::CapacityPressure(50,60,990,1000,false));
    Check(SeaMath::CapacityPressure(50,60,990,1000,true));
    Check(!SeaMath::CapacityPressure(50,60,990,0,true));
    Check(SeaMath::HarborAdmission(true,false,false));
    Check(!SeaMath::HarborAdmission(false,true,false));
    Check(!SeaMath::HarborAdmission(false,false,true));
    Check(SeaMath::HarborAdmission(false,true,true));
}
void test_mission_prefers_production_denial_but_defends_urgent_contacts() {
    const float yard=SeaMath::ObjectiveScore(8|32,true,650,1000,false,false);
    Check(yard>SeaMath::ObjectiveScore(0,false,150,300,false,false));
    Check(SeaMath::ObjectiveScore(0,false,880,300,true,false)>yard);
    Check(SeaMath::ObjectiveScore(8|32,true,650,1000,false,true)>yard);
}
void test_pursuit_accounts_for_free_fire_and_mission_leash() {
    Check(!SeaMath::Engagement(7000,700,0));
    Check(SeaMath::Engagement(800,700,0));
    Check(SeaMath::Engagement(900,700,.02f));
    Check(SeaMath::PursuitBad(230,81,67.2f,1,1,3,30,0,12,0));
    Check(!SeaMath::PursuitBad(230,81,67.2f,1,2,3,30,0,12,0));
    Check(SeaMath::PursuitBad(150,81,60,1,3,6,10,.02f,12,0));
    Check(SeaMath::PursuitBad(0,81,60,1,3,6,50,0,12,1));
    Check(!SeaMath::PursuitBad(0,81,90,.8f,1,6,0,.05f,12,0));
    Check(SeaMath::PursuitBad(0,81,90,.7f,.6f,6,0,.05f,12,0));
    Check(!SeaMath::PursuitBad(0,81,90,.7f,2,6,0,.05f,12,0));
}
void test_growth_does_not_credit_expanders_or_other_tiers() {
    Check(SeaMath::LocalWorkPower(125,true,true,true,false)==0);
    Check(SeaMath::LocalWorkPower(350,false,false,true,false)==0);
    Check(SeaMath::LocalWorkPower(125,false,true,false,false)==0);
    Check(SeaMath::LocalWorkPower(125,false,true,true,true)==0);
    Check(SeaMath::LocalWorkPower(125,false,true,true,false)==125);
    Check(SeaMath::GrowthUsage(20,5)==15);
    Check(SeaMath::GrowthUsage(3,5)==0);
}
void test_reinforcements_join_locally_without_inheriting_far_release() {
    Check(SeaMath::JoinCohort(100,720,2,24,false,false));
    Check(!SeaMath::JoinCohort(100,720,2,24,true,false));
    Check(SeaMath::JoinCohort(100,720,2,24,true,true));
    Check(!SeaMath::JoinCohort(100,720,24,24,false,true));
    Check(!SeaMath::JoinCohort(721*721,720,2,24,false,true));
}
void test_remembered_structure_requires_visual_reacquisition() {
    Check(SeaMath::ApproachRange(700,500,false)==616);
    Check(SeaMath::ApproachRange(700,500,true)==400);
    Check(SeaMath::ApproachRange(300,500,true)==264);
}
void test_first_t2_startup_buffer_preserves_expansion_reserve() {
    Check(SeaMath::TechStartupBank(80,2,800,true)==160);
    Check(SeaMath::TechStartupBank(30,2,800,true)==100);
    Check(SeaMath::TechStartupBank(500,2,800,true)==800);
    Check(SeaMath::TechStartupBank(80,2,800,false)==800);
    Check(SeaMath::TechReady(80,1200,160,1000,30,800,160,4000,20000,150,.65f));
    Check(!SeaMath::TechReady(29,1200,160,1000,30,800,160,4000,20000,150,.65f));
}
void test_shore_survey_cannot_repeat_nearby_coast_forever() {
    Check(SeaMath::ScoutScore(true,true,100,6000)>SeaMath::ScoutScore(false,true,100,200));
    Check(SeaMath::ScoutScore(false,true,100,6000)>SeaMath::ScoutScore(true,false,3600,200));
    Check(SeaMath::ScoutScore(true,true,100,1000)>SeaMath::ScoutScore(true,true,100,2000));
}
void test_asw_arc_is_symmetric_and_uses_all_slots() {
    Check(SeaMath::AntiSubAngle(0,1,2.4f)==0);
    Check(SeaMath::AntiSubAngle(0,3,2.4f)==-1.2f);
    Check(SeaMath::AntiSubAngle(1,3,2.4f)==0);
    Check(SeaMath::AntiSubAngle(2,3,2.4f)==1.2f);
}
void test_submarine_priority_includes_antisub_and_naval_infrastructure() {
    const int flagship=SeaMath::SubmarineTargetRank(true,false,false,false);
    const int ship=SeaMath::SubmarineTargetRank(false,false,false,false);
    const int factory=SeaMath::SubmarineTargetRank(false,true,false,true);
    Check(flagship>ship && ship>factory && factory>0);
    const int antiSubmarine=SeaMath::SubmarineTargetRank(false,false,false,false,true);
    Check(flagship>antiSubmarine && antiSubmarine>ship);
    Check(SeaMath::SubmarineTargetRank(false,true,false,false)>0);
    Check(SeaMath::SubmarineTargetRank(false,true,false,false)<factory);
    Check(SeaMath::SubmarineTargetRank(false,false,true,false)==ship);
}
void test_shore_deadlines_prioritize_access_without_starving_interior() {
    // A nearby coast just reaching its revisit deadline must not suppress
    // the first survey of a distant construction-accessible enemy coast.
    Check(SeaMath::SurveyPriority(2,true,0,90,12000,12000)>SeaMath::SurveyPriority(2,false,90,90,0,12000));
    Check(SeaMath::SurveyPriority(2,true,0,90,0,12000)>SeaMath::SurveyPriority(1,true,0,180,0,12000));
    Check(SeaMath::SurveyPriority(1,true,0,180,0,12000)>SeaMath::SurveyPriority(0,true,0,300,0,12000));
    Check(SeaMath::SurveyPriority(0,false,1500,300,0,12000)>SeaMath::SurveyPriority(2,false,90,90,0,12000));
    Check(SeaMath::SurveyPriority(2,false,90,90,0,12000)>SeaMath::SurveyPriority(2,false,90,90,6000,12000));
}
void test_enemy_shore_revisit_beats_ordinary_first_survey() {
    // The scout-only priority floor leaves the old submarine ranks unchanged.
    Check(SeaMath::SurveyPriority(6,false,90,90,6000,12000)
        >SeaMath::SurveyPriority(2,true,0,90,0,12000));
    Check(SeaMath::SurveyPriority(6,true,0,90,6000,12000)
        >SeaMath::SurveyPriority(6,false,90,90,0,12000));
    // Age still grows for other waters; this is a preference, not a permanent
    // ban on surveying them. Fresh coast cells are filtered by the controller.
    Check(SeaMath::SurveyPriority(0,false,3000,300,0,12000)
        >SeaMath::SurveyPriority(6,false,90,90,0,12000));
    // A remote end should be inspected before polishing adjacent coast cells.
    Check(SeaMath::SurveyPriority(7,true,0,90,9000,12000)
        >SeaMath::SurveyPriority(6,true,0,90,4000,12000));
}
void test_fleet_ratio_counts_pending_and_disables_zero_weights() {
    Check(SeaMath::CompositionDeficit(3,1)>SeaMath::CompositionDeficit(6,1));
    Check(SeaMath::CompositionDeficit(6,2)==SeaMath::CompositionDeficit(3,1));
    Check(SeaMath::CompositionDeficit(0,0)<SeaMath::CompositionDeficit(100,1));
}
void test_scout_retention_never_delays_threat_or_task_recovery() {
    Check(SeaMath::RetainScoutTravel(true,true,true,true,false));
    Check(!SeaMath::RetainScoutTravel(false,true,true,true,false));
    Check(!SeaMath::RetainScoutTravel(true,false,true,true,false));
    Check(!SeaMath::RetainScoutTravel(true,true,false,true,false));
    Check(!SeaMath::RetainScoutTravel(true,true,true,false,false));
    Check(!SeaMath::RetainScoutTravel(true,true,true,true,true));
}

void test_guardable_land_excludes_rocks_and_narrow_fragments() {
    Check(!SeaMath::GuardableLand(20,8,64,16));
    Check(!SeaMath::GuardableLand(100,4,64,16));
    Check(SeaMath::GuardableLand(64,16,64,16));
    Check(SeaMath::GuardableLand(10000,9000,64,16));
}
void test_capacity_projects_are_bounded_per_factory_not_globally_serialized() {
    Check(SeaMath::SupportProjectAvailable(1,4,false));
    Check(!SeaMath::SupportProjectAvailable(1,4,true));
    Check(!SeaMath::SupportProjectAvailable(4,4,false));
    Check(!SeaMath::SupportProjectAvailable(0,0,false));
}
void test_amphibious_interception_requires_fresh_local_known_contact() {
    Check(SeaMath::AmphibiousIntercept(256|2,970,1000000,500,5000)); // Marauder is below 1000 metal
    Check(SeaMath::AmphibiousIntercept(256|2,2000,1000000,1000,5000));
    Check(!SeaMath::AmphibiousIntercept(256|2|1,2000,1000000,1000,5000));
    Check(!SeaMath::AmphibiousIntercept(256|2|128,2000,1000000,1000,5000));
    Check(!SeaMath::AmphibiousIntercept(2,2000,1000000,1000,5000));
    Check(!SeaMath::AmphibiousIntercept(256|2,500,1000000,1000,5000));
    Check(!SeaMath::AmphibiousIntercept(256|2,2000,26000000,1000,5000));
}
void test_unplanned_invasion_slots_never_own_overflow_factory_tasks() {
    Check(!SeaMath::MatchesFactoryReservation(-1,-1,-1));
    Check(!SeaMath::MatchesFactoryReservation(-1,25,-1));
    Check(!SeaMath::MatchesFactoryReservation(33,25,26));
    Check(SeaMath::MatchesFactoryReservation(25,25,-1));
    Check(SeaMath::MatchesFactoryReservation(26,25,26));
}
void test_replacement_line_requires_numbers_and_health_adjusted_power() {
    Check(!SeaMath::ReplacementReady(2,4000,1000,3,1.15f));
    Check(!SeaMath::ReplacementReady(6,900,1000,3,1.15f));
    Check(SeaMath::ReplacementReady(3,1200,1000,3,1.15f));
    Check(SeaMath::ReplacementReady(4,1600,0,3,1.15f));
}

void test_engaged_fleet_outranks_distant_yard() {
    // D-301: an armed warship 600 away beats a yard 3000 away once engaged.
    const float yard=SeaMath::ObjectiveScore(8|32,true,650,3000,false,false);
    const float warship=SeaMath::ObjectiveScore(0,false,880,600,false,false);
    Check(yard>warship);
    Check(SeaMath::EngagedObjectiveScore(warship,true,3.0f)>yard);
    Check(SeaMath::EngagedObjectiveScore(warship,false,3.0f)==warship);
    Check(SeaMath::EngagedObjectiveScore(warship,true,1.0f)==warship);
}
void test_capital_ships_follow_the_cruiser_core() {
    Check(SeaMath::CapitalTarget(3,4,3,3)==0);
    Check(SeaMath::CapitalTarget(4,4,3,3)==1);
    Check(SeaMath::CapitalTarget(7,4,3,3)==2);
    Check(SeaMath::CapitalTarget(40,4,3,3)==3);
    Check(SeaMath::CapitalTarget(9,4,0,3)==0);
}

void test_worker_groups_rotate_and_replace_missing_lead() {
    Check(SeaMath::WorkerGroup(0,0,0)==0);
    Check(SeaMath::WorkerGroup(1,0,0)==1);
    Check(SeaMath::WorkerGroup(1,1,0)==2);
    Check(SeaMath::WorkerGroup(1,1,1)==0);
    Check(SeaMath::WorkerGroup(2,1,1)==1);
    Check(SeaMath::WorkerGroup(2,2,1)==2);
    Check(SeaMath::WorkerGroup(0,2,2)==0);
}
void test_tech_support_uses_work_and_completion_time() {
    Check(SeaMath::TechSupportCount(18000,90,100,100,2)==2);
    Check(SeaMath::TechSupportCount(45000,90,100,100,2)==4);
    Check(SeaMath::TechSupportCount(45100,90,100,100,2)==5);
    Check(SeaMath::TechSupportCount(100,90,100,100,2)==2);
    Check(SeaMath::TechSupportCount(100,0,100,0,2)==2);
}

void test_tech_conversion_redirect_keeps_unneeded_conversion() {
 Check(SeaMath::TechConversionRedirect(1000,200,100,100,100,1150,45,300)==10);
}
void test_tech_conversion_redirect_is_zero_when_funded() {
 Check(SeaMath::TechConversionRedirect(2000,200,100,100,100,1150,45,300)==0);
}
void test_tech_conversion_redirect_cannot_invent_capacity() {
 Check(SeaMath::TechConversionRedirect(0,200,100,100,100,1150,45,20)==20);
}

void test_hover_superior_needs_a_gun_a_hover_and_the_ratio() {
    // A strong destroyer group against one hover holds; an equal force does not.
    Check(SeaMath::HoverSuperior(true,4800,160,160,2.0f));
    Check(!SeaMath::HoverSuperior(true,4800,4800,4800,2.0f));
    Check(SeaMath::HoverSuperior(true,4800,2400,2400,2.0f));
    Check(!SeaMath::HoverSuperior(true,4799,2400,2400,2.0f));
    // Hover-blind or torpedo-only hulls never stand; no hover, no decision.
    Check(!SeaMath::HoverSuperior(false,4800,160,160,2.0f));
    Check(!SeaMath::HoverSuperior(true,4800,160,0,2.0f));
    Check(!SeaMath::HoverSuperior(true,4800,0,160,0.0f));
}
