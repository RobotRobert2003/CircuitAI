void test_air_parity_still_builds_bombers() { Check(AirMath::BomberOrders(1000,1000,6,3)==3); }
void test_t1_opening_waits_for_completed_crew() { Check(!AirMath::T1OpeningReady(2,3,2,2,false)); }
void test_t1_opening_waits_for_completed_support() { Check(!AirMath::T1OpeningReady(3,3,1,2,false)); }
void test_t1_opening_defers_energy_recovery() { Check(!AirMath::T1OpeningReady(3,3,2,2,true)); }
void test_t1_opening_admits_funded_complete_opening() { Check(AirMath::T1OpeningReady(3,3,2,2,false)); }
void test_t1_opening_one_and_ten_are_inclusive() { Check(AirMath::OpeningWave(1,10,1)==1 && AirMath::OpeningWave(1,10,10)==10); }
void test_recon_half_sight_overlap_uses_radius_pitch() { Check(AirMath::RadarSpacing(1250,.5f)==1250 && AirMath::RadarSpacing(1275,.5f)==1275); }
void test_recon_zero_overlap_uses_diameter_pitch() { Check(AirMath::RadarSpacing(1250,0)==2500); }
void test_recon_invalid_spacing_fails_closed() { Check(AirMath::RadarSpacing(0,.5f)==0 && AirMath::RadarSpacing(1250,-.1f)==0 && AirMath::RadarSpacing(1250,1)==0); }
void test_recon_narrow_map_uses_multiple_ranks() { Check(AirMath::RadarColumns(20,5000,1250)==5); }
void test_recon_full_width_line_has_no_extra_column() { Check(AirMath::RadarColumns(20,4999,1250)==4); }
void test_recon_columns_cannot_exceed_cohort() { Check(AirMath::RadarColumns(20,1.0e10f,.001f)==20); }
void test_recon_degenerate_span_keeps_one_column() { Check(AirMath::RadarColumns(20,0,1250)==1 && AirMath::RadarColumns(0,5000,1250)==0); }
void test_recon_must_visit_its_slot_before_dispatch() { Check(!AirMath::RadarReady(false,100,480)); }
void test_recon_reached_plane_can_circle_its_slot() { Check(AirMath::RadarReady(true,600*600,480)); }
void test_recon_displaced_plane_is_not_ready() { Check(!AirMath::RadarReady(true,1000*1000,480) && !AirMath::RadarReady(true,0,0)); }
void test_air_funded_workforce_precedes_peacetime_replacements() { Check(AirMath::WorkforceTurn(true,true,false,0,2)); }
void test_air_immediate_incursion_gets_first_combat_order() { Check(!AirMath::WorkforceTurn(true,true,true,0,2)); }
void test_air_continuous_incursion_cannot_starve_workforce() { Check(AirMath::WorkforceTurn(true,true,true,2,2)); }
void test_air_unfunded_workforce_does_not_interrupt_defense() { Check(!AirMath::WorkforceTurn(true,false,false,10,2)); }
void test_air_met_workforce_does_not_expand_without_bound() { Check(!AirMath::WorkforceTurn(false,true,true,10,2)); }
void test_air_low_income_can_save_first_lab_capital() { Check(AirMath::SaveForLab(false,false,false,true,600,480,20,1500,12,1200,900,2900)); }
void test_first_lab_low_income_partial_bank() { Check(AirMath::LabFunding(1500,100,13,0,0,2900,20000,60,180,.75f)); }
void test_first_lab_committed_projects_are_reserved() { Check(!AirMath::LabFunding(1500,100,13,0,500,2900,20000,60,180,.75f)); }
void test_first_lab_production_usage_is_not_free_income() { Check(!AirMath::LabFunding(1500,100,13,5,0,2900,20000,60,180,.75f)); }
void test_first_lab_faster_builder_shortens_forecast() { Check(!AirMath::LabFunding(1500,100,13,0,0,2900,20000,300,180,.75f)); }
void test_first_lab_weak_energy_blocks_admission() { Check(!AirMath::LabFunding(200,200,50,0,0,30000,20000,60,180,.75f)); }
void test_first_lab_emergency_bank_is_preserved() { Check(!AirMath::LabFunding(99,100,1000,0,0,2900,20000,60,180,.75f)); }
void test_first_lab_complete_cost_must_fit_bounded_horizon() { Check(!AirMath::LabFunding(100,100,13,0,0,2900,20000,1,180,.75f)); }
void test_first_lab_unfunded_usage_rejected_even_with_full_price() { Check(!AirMath::LabFunding(3000,100,13,20,0,2900,20000,60,180,.75f)); }
void test_first_lab_invalid_inputs_fail_closed() {
    Check(!AirMath::LabFunding(1500,100,13,0,0,2900,20000,0,180,.75f));
    Check(!AirMath::LabFunding(1500,100,13,0,0,2900,20000,60,0,.75f));
    Check(!AirMath::LabFunding(1500,100,13,0,0,2900,20000,60,180,1.1f));
    Check(!AirMath::LabFunding(1500,100,13,0,0,2900,20000,60,180,-1));
}
void test_air_energy_recovery_never_saves_lab_capital() { Check(!AirMath::SaveForLab(false,false,true,true,600,480,20,1500,12,1200,900,2900)); }
void test_air_weak_energy_does_not_start_capital_budget() { Check(!AirMath::SaveForLab(false,false,false,true,600,480,20,1100,12,1200,900,2900)); }
void test_air_queued_lab_ends_capital_saving() { Check(!AirMath::SaveForLab(false,true,false,true,600,480,20,1500,12,1200,900,2900)); }
void test_air_second_lab_does_not_use_first_lab_budget() { Check(!AirMath::SaveForLab(true,false,false,true,600,480,20,1500,12,1200,900,2900)); }
void test_air_initial_screen_precedes_lab_saving() { Check(!AirMath::SaveForLab(false,false,false,false,600,480,20,1500,12,1200,900,2900)); }
void test_air_full_lab_bank_ends_saving() { Check(!AirMath::SaveForLab(false,false,false,true,600,480,20,1500,12,1200,2900,2900)); }
void test_air_access_energy_floor_can_save_below_production_energy() { Check(AirMath::SaveForLab(false,false,false,true,480,480,12,450,12,450,200,2900)); }
void test_air_access_saving_preserves_early_opening() { Check(!AirMath::SaveForLab(false,false,false,true,479,480,20,900,12,450,200,2900)); }
void test_air_access_saving_waits_for_energy_floor() { Check(!AirMath::SaveForLab(false,false,false,true,600,480,20,449,12,450,200,2900)); }
void test_air_badly_losing_preserves_fighter_priority() { Check(AirMath::BomberOrders(100,500,6,3)==0); }
void test_air_clear_sky_allocation_is_bounded() { Check(AirMath::BomberOrders(1000,0,6,3)==6); }
void test_air_campus_attempts_full_size_before_compacting() { Check(AirMath::CampusSize(false,5)==6); }
void test_air_compact_search_retries_large_then_medium_then_single() { Check(AirMath::CampusSize(true,3)==6 && AirMath::CampusSize(true,4)==3 && AirMath::CampusSize(true,5)==1); }
void test_air_invalid_campus_variant_preserves_full_plan() { Check(AirMath::CampusSize(true,-1)==6); }
void test_air_interleave_is_exact_per_cycle() { int n=0; for(int i=0;i<20;++i) if(AirMath::BomberTurn(i,3)) ++n; Check(n==6); }
void test_air_invalid_sequence_cannot_recruit_strike() { Check(!AirMath::BomberTurn(-1,6)); }
void test_air_unarmed_contact_does_not_stop_strike() { Check(!AirMath::Emergency(0,100,1.5f)); }
void test_air_one_expensive_bomber_can_be_emergency() { Check(AirMath::Emergency(300,100,1.5f)); }
void test_air_sufficient_defense_does_not_veto_strike() { Check(!AirMath::Emergency(300,500,1.5f)); }
void test_air_mixed_tier_defense_uses_value() { Check(AirMath::Missing(600,450,150)==1); }
void test_air_pending_fighter_value_removes_deficit() { Check(AirMath::Missing(600,600,150)==0); }
void test_air_fractional_deficit_rounds_up() { Check(AirMath::Missing(601,600,150)==1); }
void test_air_wave_is_energy_limited() { Check(AirMath::WaveTarget(10,8,4,80,0,240,1,100,1000,310,18500)==12); }
void test_air_wave_is_metal_limited() { Check(AirMath::WaveTarget(10,8,4,80,0,240,1,10,20000,310,18500)==8); }
void test_air_wave_is_factory_limited() { Check(AirMath::WaveTarget(10,8,4,80,0,240,.05f,1000,100000,310,18500)==12); }
void test_air_held_fleet_counts_toward_reachable_size() { Check(AirMath::WaveTarget(10,8,4,80,10,240,.05f,1000,100000,310,18500)==22); }
void test_air_wave_never_exceeds_cap() { Check(AirMath::WaveTarget(100,8,4,80,200,240,1,1000,100000,310,18500)==80); }

void test_air_extreme_deficit_saturates_before_conversion() { Check(AirMath::Missing(1.0e11f,0,0.001f)==2147483647); }
void test_air_extreme_wave_schedule_remains_capped() { Check(AirMath::WaveTarget(2147483647,8,2147483647,80,0,1.0e11f,1.0e11f,1.0e11f,1.0e11f,1,1)==80); }

void test_air_unlimited_campus_keeps_expanding() { Check(AirMath::BayAllowed(50,0) && AirMath::PlannedBays(50,6)==51); }
void test_air_explicit_factory_limit_is_respected() { Check(!AirMath::BayAllowed(6,6)); }
void test_air_campus_reserves_minimum_before_growth() { Check(AirMath::PlannedBays(0,6)==6 && AirMath::PlannedBays(5,6)==6); }
void test_air_income_spike_does_not_start_growth() { Check(!AirMath::GrowthPhase(false,100,50) && !AirMath::GrowthPhase(true,49.9f,50)); }
void test_air_sustained_fifty_starts_growth() { Check(AirMath::GrowthPhase(true,50,50)); }
void test_air_two_afus_completes_growth_objective() { Check(!AirMath::MassBombersReady(1,2) && AirMath::MassBombersReady(2,2)); }
void test_air_bomber_admission_requires_both_incomes() { Check(AirMath::SustainedProduction(true,50,1830,30,60,30)); }
void test_air_high_metal_cannot_mask_energy_shortfall() { Check(!AirMath::SustainedProduction(true,500,1829,30,60,30)); }
void test_air_high_energy_cannot_mask_metal_shortfall() { Check(!AirMath::SustainedProduction(true,29,50000,30,60,30)); }
void test_air_bomber_admission_waits_for_complete_window() { Check(!AirMath::SustainedProduction(false,500,50000,30,60,30)); }
void test_air_invalid_payload_ratio_fails_closed() { Check(!AirMath::SustainedProduction(true,500,50000,30,0,30)); }
void test_air_opening_random_bounds_are_inclusive() { Check(AirMath::OpeningWave(10,20,10)==10 && AirMath::OpeningWave(10,20,20)==20); }
void test_air_economy_opening_preserves_draw() { Check(AirMath::OperationSize(64,8,false,17,false,false,8)==17); }
void test_air_opening_does_not_waive_payload() { Check(AirMath::OperationSize(64,18,false,17,false,false,8)==0); }
void test_air_front_assault_uses_available_force_before_opening() { Check(AirMath::OperationSize(64,35,false,17,true,false,8)==64); }
void test_air_defence_does_not_wait_for_offensive_opening() { Check(AirMath::OperationSize(7,6,false,17,false,true,8)==6); }
void test_air_later_raid_funds_target() { Check(AirMath::OperationSize(64,28,true,17,false,false,8)==28); }
void test_air_insufficient_cohort_is_not_released() { Check(AirMath::OperationSize(5,6,true,17,false,true,8)==0); }
void test_air_bad_opening_settings_are_bounded() { Check(AirMath::OpeningWave(20,10,1)==20 && AirMath::OpeningWave(1000,2000,1000)==300); }
void test_air_shared_economy_retires_small_energy() { Check(!AirMath::EnergyEraAllows(true,false,true,false) && !AirMath::EnergyEraAllows(true,false,false,true)); }
void test_air_shared_economy_keeps_reactors_and_converters() { Check(AirMath::EnergyEraAllows(false,false,true,true)); }
void test_air_first_afus_retires_advanced_solar() { Check(AirMath::EnergyEraAllows(false,true,true,false) && !AirMath::EnergyEraAllows(false,true,true,true)); }

void test_air_campus_growth_cannot_overflow() { Check(AirMath::PlannedBays(2147483647,6)==2147483647); }
void test_air_wipeout_increases_next_resistance() { Check(AirMath::RaidResistance(1,0,.3f,.8f,1.5f,.9f,3)==1.5f); }
void test_air_repeated_losses_have_bounded_resistance() { Check(AirMath::RaidResistance(2.5f,0,.3f,.8f,1.5f,.9f,3)==3); }
void test_air_good_survival_relaxes_learned_resistance() { Check(AirMath::RaidResistance(2,1,.3f,.8f,1.5f,.5f,3)==1); }
void test_air_success_cannot_erase_base_unknown_reserve() { Check(AirMath::RaidResistance(1,1,.3f,.8f,1.5f,.5f,3)==1); }
void test_air_neutral_survival_keeps_resistance() { Check(AirMath::RaidResistance(2,.5f,.3f,.8f,1.5f,.9f,3)==2); }
void test_air_invalid_resistance_is_safe() { Check(AirMath::RaidResistance(-1,0,.3f,.8f,1.5f,.9f,3)==1); }
void test_air_overflow_funds_serial_growth() { Check(AirMath::OverflowGrowth(true,false,false,5000,40000,100,5000,0,0,9700,69000,.65f,180)); }
void test_air_growth_leaves_production_share() { Check(!AirMath::OverflowGrowth(true,false,false,1000,40000,100,5000,0,0,9700,69000,.65f,180)); }
void test_air_growth_deducts_existing_commitments() { Check(!AirMath::OverflowGrowth(true,false,false,5000,40000,100,5000,2000,0,9700,69000,.65f,180)); }
void test_air_growth_needs_energy_funding() { Check(!AirMath::OverflowGrowth(true,false,false,20000,1000,100,100,0,0,9700,69000,.65f,180)); }
void test_air_growth_never_overrides_recovery() { Check(!AirMath::OverflowGrowth(true,true,false,20000,100000,100,5000,0,0,9700,69000,.65f,180)); }
void test_air_growth_never_starts_parallel_reactors() { Check(!AirMath::OverflowGrowth(true,false,true,20000,100000,100,5000,0,0,9700,69000,.65f,180)); }
void test_air_growth_does_not_spend_nonfloating_bank() { Check(!AirMath::OverflowGrowth(false,false,false,20000,100000,100,5000,0,0,9700,69000,.65f,180)); }
void test_air_growth_invalid_share_fails_closed() { Check(!AirMath::OverflowGrowth(true,false,false,20000,100000,100,5000,0,0,9700,69000,2,180)); }
void test_air_queued_reactor_blocks_parallel_growth() { Check(AirMath::PendingReactor(true,true,false,0)); }
void test_air_unfinished_reactor_blocks_parallel_growth() { Check(AirMath::PendingReactor(true,true,true,.8f)); }
void test_air_completed_reactor_does_not_block_growth() { Check(!AirMath::PendingReactor(true,true,true,1)); }
void test_air_small_energy_does_not_block_reactors() { Check(!AirMath::PendingReactor(false,true,false,0)); }
void test_air_reactor_repair_is_not_new_construction() { Check(!AirMath::PendingReactor(true,false,true,.8f)); }
void test_air_retained_intercept_survives_snapshot_reorder() { array<int> ids={12,5}; array<float> needs={100,100}; Check(AirMath::RetainedContact(5,ids,needs)==1); }
void test_air_disappeared_intercept_frees_group_immediately() { array<int> ids={12}; array<float> needs={100}; Check(AirMath::RetainedContact(5,ids,needs)==-1); }
void test_air_fully_funded_contact_does_not_keep_extra_group() { array<int> ids={5}; array<float> needs={-50}; Check(AirMath::RetainedContact(5,ids,needs)==-1); }
void test_air_invalid_contact_snapshot_releases_group() { array<int> ids={5}; array<float> needs; Check(AirMath::RetainedContact(5,ids,needs)==-1); }
void test_air_low_income_full_store_can_fund_transition_capacity() { Check(AirMath::TransitionStorage(false,1340,1350,2900)); }
void test_air_transition_storage_stops_at_lab_capacity() { Check(!AirMath::TransitionStorage(false,2900,2900,2900)); }
void test_air_transition_storage_does_not_spend_an_empty_bank() { Check(!AirMath::TransitionStorage(false,200,1350,2900)); }
void test_air_transition_storage_does_not_expand_after_t2() { Check(!AirMath::TransitionStorage(true,1340,1350,2900)); }

void test_recon_partial_waits_until_deadline() { Check(!AirMath::ReconRelease(3,3,20,89,90)); }
void test_recon_partial_releases_at_deadline() { Check(AirMath::ReconRelease(3,3,20,90,90)); }
void test_recon_deadline_breaks_assembly_stall() { Check(AirMath::ReconRelease(1,0,20,90,90)); }
void test_recon_full_wave_launches_early() { Check(AirMath::ReconRelease(20,20,20,1,90)); }
void test_recon_never_launches_empty() { Check(!AirMath::ReconRelease(0,0,20,999,90)); }
void test_recon_full_unassembled_wave_waits() { Check(!AirMath::ReconRelease(20,19,20,89,90)); }
void test_defense_radius_includes_boundary() { Check(AirMath::BaseContact(1800*1800,1800)); }
void test_defense_does_not_claim_frontline() { Check(!AirMath::BaseContact(1801*1801,1800)); }
void test_gunship_group_has_small_raid_floor() { Check(AirMath::DefenceWave(100,0,250,0.35f,2,4,30)==4); }
void test_gunship_budget_never_shrinks_as_aa_grows() {
    int previous = 0;
    for (int aa = 0; aa <= 10000; aa += 100) {
        const int required = AirMath::DefenceWave(500, float(aa), 330, .35f, 2, 4, 30);
        Check(required >= previous && required >= 4 && required <= 30); previous = required;
    }
}
void test_gunship_new_arrival_does_not_waive_deadline() { Check(!AirMath::DefenceRelease(1,1,4,44,45)); }
void test_gunship_exact_deadline_releases_partial() { Check(AirMath::DefenceRelease(1,0,4,45,45)); }
void test_gunship_invalid_limits_still_require_one() { Check(AirMath::DefenceWave(0,0,330,.35f,2,0,-5)==1); }
void test_gunship_aa_budget_increases_group() { Check(AirMath::DefenceWave(100,1000,250,0.35f,2,4,30)==9); }
void test_gunship_heavier_aircraft_need_fewer_members() { Check(AirMath::DefenceWave(100,1000,500,0.35f,2,4,30)==5); }
void test_gunship_budget_is_capped() { Check(AirMath::DefenceWave(100000,100000,50,0.35f,2,4,30)==30); }
void test_gunship_invalid_cost_keeps_floor() { Check(AirMath::DefenceWave(100,1000,0,0.35f,2,4,30)==4); }
void test_gunship_births_do_not_release_unassembled_group() { Check(!AirMath::DefenceRelease(10,3,9,44,45)); }
void test_gunship_ready_group_releases_immediately() { Check(AirMath::DefenceRelease(10,9,9,1,45)); }
void test_gunship_deadline_releases_stalled_small_group() { Check(AirMath::DefenceRelease(2,1,9,45,45)); }
void test_gunship_empty_group_never_releases() { Check(!AirMath::DefenceRelease(0,0,9,100,45)); }
void test_gunship_aa_preempts_heavy_incumbent_in_either_scan_order() {
    Check(AirMath::PreferDefensiveGunshipTarget(true, 100125, false, 225000));
    Check(!AirMath::PreferDefensiveGunshipTarget(false, 225000, true, 100125));
}
void test_gunship_same_tier_retains_incumbent_and_stable_ties() {
    Check(!AirMath::PreferDefensiveGunshipTarget(true, 100650, true, 125125));
    Check(!AirMath::PreferDefensiveGunshipTarget(true, 100125, true, 100125));
    Check(AirMath::PreferDefensiveGunshipTarget(false, 100650, false, -1));
}
void test_gunship_dedicated_mobile_aa_includes_advanced_bots() {
    Check(AirMath::DefensiveGunshipPriority(true,true,true,true,750,400));
    Check(!AirMath::DefensiveGunshipPriority(true,true,false,true,125,400));
    Check(!AirMath::DefensiveGunshipPriority(true,false,true,true,125,400));
}
void test_gunship_static_aa_boundary_and_profile_disable() {
    Check(AirMath::DefensiveGunshipPriority(true,true,true,false,400,400));
    Check(!AirMath::DefensiveGunshipPriority(true,true,true,false,401,400));
    Check(!AirMath::DefensiveGunshipPriority(true,true,true,false,100,0));
    Check(!AirMath::DefensiveGunshipPriority(true,true,true,false,-1,400));
    Check(!AirMath::DefensiveGunshipPriority(false,true,true,true,125,400));
}
void test_defense_counts_frames_and_orders_once() { Check(AirMath::DefenceDeficit(20,7,5,3)==5); }
void test_defense_stops_at_shared_target() { Check(AirMath::DefenceDeficit(20,18,2,1)==0); }
void test_advanced_defense_bombers_skip_t1_mobiles() { Check(!AirMath::DefensiveBomberTarget(true,true,false)); }
void test_advanced_defense_bombers_accept_heavy() { Check(AirMath::DefensiveBomberTarget(true,true,true)); }
void test_advanced_defense_bombers_accept_foothold() { Check(AirMath::DefensiveBomberTarget(true,false,false)); }
void test_t1_defense_bombers_accept_light_intruders() { Check(AirMath::DefensiveBomberTarget(false,true,false)); }

void test_naval_parity_needs_no_air_spending() { Check(AirMath::NavalDeficit(4000,4000,0,0)==0); }
void test_naval_deficit_matches_local_gap() { Check(AirMath::NavalDeficit(8000,4000,2000,3000)==4000); }
void test_naval_subs_need_asw_despite_surface_parity() { Check(AirMath::NavalDeficit(3000,6000,2500,0)==2500); }
void test_naval_invalid_force_values_do_not_trigger() { Check(AirMath::NavalDeficit(3000,-1,0,0)==0); }
void test_naval_runtime_costs_round_up() { Check(AirMath::NavalWave(4000,300,1.25f,400,2,60)==13 && AirMath::NavalWave(4000,300,1.25f,480,2,60)==11); }
void test_naval_wave_is_bounded() { Check(AirMath::NavalWave(1000000,300,1.25f,400,2,60)==60); }
void test_naval_trivial_gap_does_not_make_a_wave() { Check(AirMath::NavalWave(299,300,1.25f,400,2,60)==0); }
void test_naval_zero_cost_is_not_infinite_aircraft() { Check(AirMath::NavalWave(4000,300,1.25f,0,2,60)==0); }
void test_naval_partial_releases_at_deadline() { Check(AirMath::NavalRelease(2,13,90,90,true)); }
void test_naval_partial_does_not_release_early() { Check(!AirMath::NavalRelease(2,13,89,90,true)); }
void test_naval_full_releases_without_timer() { Check(AirMath::NavalRelease(13,13,0,90,true)); }
void test_naval_deadline_preserves_route_safety() { Check(!AirMath::NavalRelease(2,13,1000,90,false)); }
void test_naval_no_contact_does_not_launch() { Check(!AirMath::NavalRelease(2,0,1000,90,true)); }
void test_naval_empty_reserve_never_launches() { Check(!AirMath::NavalRelease(0,13,1000,90,true)); }
void test_naval_sector_halo_keeps_nearby_friendly_formation() { Check(AirMath::NavalSectorContains(2530.0f*2530,2400*1.25f) && !AirMath::NavalSectorContains(2530.0f*2530,2400)); }
void test_naval_sector_excludes_remote_support() { Check(!AirMath::NavalSectorContains(3100.0f*3100,3000)); }
void test_naval_sector_includes_boundary() { Check(AirMath::NavalSectorContains(9000000,3000)); }
void test_naval_sector_rejects_invalid_distance() { Check(!AirMath::NavalSectorContains(-1,3000)); }
