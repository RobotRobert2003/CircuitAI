#include "../src/setup.as"
#include "../src/helpers/common/generic_helpers.as"
#include "../src/global.as"
#include "../src/maps.as"
#include "../src/types/strategy.as" // for StrategyUtil names when logging

namespace Main {

    const int NukeRushSecondCallSeconds = 18 * 60;

	// One roll (owner, 2026-10-27): exactly one rush, T3 70%, capital 25%, nuke 5%; any weight left below 1.0 is "none".
	// The separate spam roll is off (SingleRoll); with SingleRoll false, roll 2 adds the spam rush at Tech_Spam_Rush as before.
	// History: two rolls from 2026-10-17 (nuke 25%, T3 35%, heavy 25%, none 15%; spam 85%), T3 100% from 2026-10-26.
	namespace StrategyWeights {
		bool SingleRoll = true;
		float Tech_NUKE_RUSH = 0.05f; // owner, 2026-10-27
		float Tech_T3_RUSH = 0.70f;   // owner, 2026-10-27
		float Tech_T2_RUSH = 0.0f;    // the finite heavy-delivery rush (TechHeavyRush)
		float Tech_CAPITAL_RUSH = 0.25f; // owner, 2026-10-27: T2-plant capital bombers for AIR (TechCapitalRush)
		float Tech_Spam_Rush = 0.85f; // roll 2, only without SingleRoll
	}

	// Decide a boolean from a probability using AiDice with two weights: off vs on.
	bool DecideEnabled(float probability) {
		// Clamp to [0,1]
		float p = AiMax(0.0f, AiMin(probability, 1.0f));
		// Build weights {off, on}
		array<float>@ w = array<float>(2);
		w[0] = 1.0f - p;
		w[1] = p;
		int idx = AiDice(w);
		return (idx == 1);
	}

	void ApplyTechStrategyWeights() {
		// Start fresh (no strategies), then enable per dice outcome
		Global::RoleSettings::Tech::StrategyMask = 0;

		// Roll 1: one main rush, mutually exclusive (any weight left below 1.0 is "none")
		const float wNuke = AiMax(0.0f, StrategyWeights::Tech_NUKE_RUSH);
		const float wT3 = AiMax(0.0f, StrategyWeights::Tech_T3_RUSH);
		const float wT2 = AiMax(0.0f, StrategyWeights::Tech_T2_RUSH);
		const float wCapital = AiMax(0.0f, StrategyWeights::Tech_CAPITAL_RUSH);
		array<float>@ w = array<float>(5);
		w[0] = wNuke;
		w[1] = wT3;
		w[2] = wT2;
		w[3] = wCapital;
		w[4] = AiMax(0.0f, 1.0f - wNuke - wT3 - wT2 - wCapital);
		const int pick = AiDice(w);
		if (pick == 0) Global::RoleSettings::Tech::EnableStrategy(Strategy::NUKE_RUSH);
		else if (pick == 1) Global::RoleSettings::Tech::EnableStrategy(Strategy::T3_RUSH);
		else if (pick == 2) Global::RoleSettings::Tech::EnableStrategy(Strategy::T2_RUSH);
		else if (pick == 3) Global::RoleSettings::Tech::EnableStrategy(Strategy::CAPITAL_RUSH);

		// Roll 2: the spam rush, on its own (none with the single roll)
		const bool spam = !StrategyWeights::SingleRoll && DecideEnabled(StrategyWeights::Tech_Spam_Rush);
		if (spam) {
			Global::RoleSettings::Tech::EnableStrategy(Strategy::SPAM_RUSH);
		}

		GenericHelpers::LogUtil(
			"[Strategy] (EXPERIMENTAL BALANCED) Decided: Tech mask=" + Global::RoleSettings::Tech::StrategyMask +
			" (" + StrategyUtil::NamesFromMask(Global::RoleSettings::Tech::StrategyMask) + "); roll 1: "
			+ (pick == 0 ? "NUKE_RUSH" : pick == 1 ? "T3_RUSH" : pick == 2 ? "T2_RUSH (heavy rush)" : pick == 3 ? "CAPITAL_RUSH" : "none")
			+ (StrategyWeights::SingleRoll ? " (single roll)" : ", roll 2: spam rush " + (spam ? "on" : "off")),
			1);
	}

	void AiMain()
	{
        ThugFireAtWill::Enabled = true;
        // Missing working-copy policy. Existing pending-all overrides retain precedence.
        Global::RoleSettings::Air::BankFunding = true; // AIR: bank funds energy/cons/T2 turrets; far mexes past a small home (owner 2026-10-17)
        Global::RoleSettings::Air::FirstLabBankAssist = true; // AIR: idle T1 cons help the first T2 lab once the bank covers it (owner 2026-10-18)
        Global::GremlinEcoFire::Enabled = true; // Gremlins scout, firing only at enemy economy (owner 2026-10-19)
        Global::RoleSettings::Tech::LayoutNoRoomRetrySeconds = 1.0f; // owner 2026-10-19: no-room sweep backoff 1-3 s
        Global::RoleSettings::Air::EcoSlotRetrySeconds = 2.0f;      // owner 2026-10-19: one AIR reactor order per slot per 2 s
        Global::RoleSettings::Air::T2HeavyAirIncomeThreshold = 175.0f;
        Global::RoleSettings::Tech::NukeRushSecondCallSeconds = NukeRushSecondCallSeconds;
        Global::RoleSettings::Tech::NukeRushSecondCallLimit = 8;
        Global::RoleSettings::Tech::NukeRushSiloPerAfus = true;
        Global::RoleSettings::Tech::NukeLimit = 15;
        Global::RoleSettings::Tech::HeavyAlternate = true; // owner 2026-10-22: late heavy batches alternate Thor / Titan (land and amphibious)
        // owner 2026-10-26: after the t3rush units, every TECH gantry alternates these pairs, first unit first, on every map
        Global::RoleSettings::Tech::HeavyPairArmada = array<string> = {"armbanth", "armthor"};         // Titan, Thor
        Global::RoleSettings::Tech::HeavyPairCortex = array<string> = {"corkorg", "corcat"};           // Juggernaut, Catapult
        Global::RoleSettings::Tech::HeavyPairLegion = array<string> = {"legeheatraymech", "legelrpcmech"}; // Sol Invictus, Astraeus
        Global::RoleSettings::Tech::NukeRushAfusSiloMetalIncome = 50.0f;
        Global::RoleSettings::Tech::NukeRushAfusSiloEnergyIncome = 2000.0f;
        Global::Military::NoTelchines = true;
        Global::RoleSettings::Front::ReclaimT1EnergyAfterFusion = true;
        Global::RoleSettings::Front::EcoLadder = true;
        Global::RoleSettings::Front::EcoLadderGantryMetalIncome = 225.0f;   // owner, 2026-10-25 (175 from 2026-10-18)
        Global::RoleSettings::Front::EcoLadderGantryAfterAdvFusions = 1;
        Global::RoleSettings::Front::EcoLadderLaterAdvFusionAtStart = true;
        Global::RoleSettings::Front::SpawnFactoryEnabled = true;
        Global::RoleSettings::Front::T2FactoryNanos = 6; // owner 2026-10-25: a T2 lab's turrets from its frame (front_factory_nanos.as)
        Global::RoleSettings::Front::T2FactoryNanosMax = 14; // owner 2026-10-25: up to 14 as the metal bank nears overflow
        Global::RoleSettings::Front::Recovery = true; // owner 2026-10-19: after losing the base, T1 eco and retake the mexes first (front_recovery.as)
        Global::RoleSettings::Front::TimeTriggerForFirstT2LabMinMetalIncome = 20.0f; // 22-min T2 lab/plant trigger needs +20 metal (AI 11 ordered legavp at +3 after losing its base)
        Global::Team::PinpointerPoolSize = 3;
        Global::Spam::EdgePorcEnabled = true;
        Global::FrontRadar::Enabled = true; // owner 2026-10-27: long-range radars just behind the front (systems/combat/front_radar.as)
        Global::Spam::LaneReleaseAtEnd = true;
		Global::RoleSettings::MexOwnershipEnabled = true;
		// Also initialize before setupMap (and when reconstructing a saved game).
		aiEconomyMgr.SetMexOwnership(true, Global::RoleSettings::MexOwnershipSeconds);
		// D-352: mex ownership by theatre (home, sea, lanes, the race); the claim
		// numbers go out with the roster once the role and start are known.
		Global::RoleSettings::MexClaim::TheatresEnabled = true;
		Team::MexClaim::Setup();
		Global::RoleSettings::Air::FundFirstLab = true;
		// AIR Armada (owner, 2026-10-17): Liches from 150 metal/s (10 s minimum), launched with each bomber wave,
		// own tiered targets: shields, Pulsar class, anti-nukes/silos, geo, gantries, T2 factories
		// (src/settings/roles/air.as LichesEnabled, off there; systems/air/air_liches.as)
		Global::RoleSettings::Air::LichesEnabled = true;
		// AIR (owner, 2026-10-21): T2 bombers pick tiered economy targets the Liche way (advanced fusion, fusion,
		// T2 converter, advanced geo, factory); the Liches guard the raid's bombers (owner, 2026-10-24)
		// (src/settings/roles/air.as BomberTiersEnabled, off there; systems/air/air_strike_tiers.as)
		Global::RoleSettings::Air::BomberTiersEnabled = true;
        Global::Commander::AfusDefenceRadius = Global::Commander::BaseRadius;
        Global::Commander::FrontRecovery = true;
        Global::RoleSettings::Sea::FleetRerouteSeconds = 3; // owner 2026-10-19: SEA cohort chasing one target re-routes at most every 3 s
        Global::RoleSettings::Sea::FleetReroutesPerTick = 8;     // and at most 8 such re-routes per tick (Glacial Gap lag)
        Global::Commander::FrontMexSeconds = 1.f;
        Global::RoleSettings::Tech::EcoFlakEnabled = true;
        Global::LolCannon::Enabled = true; // Ragnarok/Calamity/Starfall only via the gated FRONT/TECH program (owner 2026-10-21)
        Global::RoleSettings::Tech::LayoutForwardTurretsEarly = true; // owner 2026-10-19: the forward turret block fills once the economy moves into it
        Global::RoleSettings::Tech::LayoutForwardTurretDemand = true; // owner 2026-10-20: the forward cluster's advanced fusions and converters order its turrets (second round)
        Global::RoleSettings::Tech::AfusAtOnce = 1;                   // owner 2026-10-20: one advanced fusion at a time, whoever orders it
        Global::RoleSettings::Tech::LayoutForwardTurretMinimum = 12;  // owner 2026-10-20: T1 constructors put 12 turrets in the forward cluster before helping its economy
		GenericHelpers::LogUtil("Running AiMain()", 1);

        // The opening Tick must search for gaps and raid just like later scouts.
        Global::ScoutRaid::KeepNativeScouts = 0;
        Global::RoleSettings::Tech::HeavyDeliveryFrontEnabled = true;
        Global::RoleSettings::Tech::HeavyDeliveryBlockedSeconds = 5.0f;

		// Air-factory gate. Native CEnemyManager::IsAirValid() tests
		//     GetEnemyThreat(AA) <= maxAAThreat
		// and CFactoryManager/CFactoryData use it to suspend air production.
		// Raise the ceiling far above any reachable AA threat so air is always
		// buildable. This is the supported replacement for the removed
		// Military::AiIsAirValid hook (upstream a78e0f6c, 2025-11-02).
		// Runs after CEnemyManager::ReadConfig() (AllyTeam.cpp:81), so it wins
		// over the quota.aa_threat value derived from map size.
		aiEnemyMgr.maxAAThreat = 1.0e30f;

		GenericHelpers::LogUtil("registerMaps", 1);
		Maps::registerMaps();
		// Map + profile setup deferred until first factory selection in AiGetFactoryToBuild

		// HARD difficulty strategy selection: decide per-weight which strategies to enable for the TECH role
		ApplyTechStrategyWeights();

		
		// for (Id defId = 1, count = ai.GetDefCount(); defId <= count; ++defId) {
		// 	CCircuitDef@ cdef = ai.GetCircuitDef(defId);
		// 	if (cdef.costM >= 200.f && !cdef.IsMobile() && aiEconomyMgr.GetEnergyMake(cdef) > 1.f)
		// 		cdef.AddAttribute(Unit::Attr::BASE.type);  // Build heavy energy at base
		// }

		// Example of user-assigned custom attributes
		array<string> names = {Factory::armalab, Factory::coralab, Factory::armavp, Factory::coravp,
			Factory::armaap, Factory::coraap, Factory::armasy, Factory::corasy};
		for (uint i = 0; i < names.length(); ++i)
			Factory::userData[ai.GetCircuitDef(names[i]).id].attr |= Factory::Attr::T2;
		names = {Factory::armshltx, Factory::corgant, Factory::leggant};
		for (uint i = 0; i < names.length(); ++i)
			Factory::userData[ai.GetCircuitDef(names[i]).id].attr |= Factory::Attr::T3;

		ApplyProfileSettings();
	}

    void AiSuperWeaponFired(CCircuitUnit@ unit, const AIFloat3& in aim)
    {
        ArtilleryPolicy::Fired(unit, aim);
    }
    void AiUnitDestroyed(CCircuitUnit@ unit)
    {
        ArtilleryPolicy::Removed(unit);
    }

	void AiUpdate()  // SlowUpdate, every 30 frames with initial offset of skirmishAIId
	{
		ArtilleryPolicy::Check();
        Lanes::Poll(); // complete async surveys for every role before consumers run
        AmphibiousOps::Tick();
        ScoutRaid::Tick(); // D-296: no-op unless the profile JSON enables scout raids
        GremlinEcoFire::Tick(); // Gremlins scout, firing only at enemy economy in reach
        ThugFireAtWill::Tick(); // preserve the working-copy fire-state fallback after task changes
		Commands::DrawTick();   // the widget's map drawing, paced under the server's flood guard
		// Update cached enemy threat information roughly every 10 seconds (300 frames).
		//if ((ai.frame % (10 * SECOND)) == 0) {
		Military::UpdateEnemyThreatCache();
		Military::UpdateEnemyCostCache();
        Aggression::Update();
        CommanderCombat::Update();
        FrontWaveEscort::Update();   // T2 tank wave escorts follow their wave (no-op without a wave)
        FrontArtySquad::Update();   // T2 artillery squads follow their lead (no-op without a squad)
        T3Unstick::Tick();      // free T3 units penned in by our T1 porc, eco and construction turrets

		if (Global::profileController !is null) {
			Global::profileController.MainUpdate();
		}
		Team::Roster::Update();  // announce ourselves to allied BARb instances until the roster is complete
		Spam::Update();          // economy-gated spam: activation, focus rotation
		FrontRadar::Update();    // owner, 2026-10-27: long-range radars at the front (census, allies' list)
		Team::Ferry::Update();   // transport ferry: hand-over on arrival, run polling
		Team::SeaAssist::Update();  // SEA seeds a TACTICAL ally with a construction ship
		Team::Donation::Update();   // a teammate without T2 asks TECH for a constructor
		Team::CheckOrphaned();   // recover lost mobile constructors through TECH
	}

	void AiMessage(const string& in msg, int fromTeamId)  // AiSendMessage from an allied BARb instance
	{
		Team::HandleMessage(msg, fromTeamId);
	}

	void AiLuaMessage(const string& in data)  // Spring.SendSkirmishAIMessage(teamID, msg) from the local LuaUI
	{
		if (!Team::Recovery::HandleLua(data) && !Commands::Handle(data)) {
			GenericHelpers::LogUtil("[AI][LuaMessage] ignored: " + data, 3);
		}
	}

	//Use this to modify global.as and apply difficulty/profile settings
	void ApplyProfileSettings()
	{
        // Ally clear message protocol (owner, 2026-10-17; src/systems/team/ally_clear.as), used here by T3 unstick
        Global::Team::AllyClearEnabled = true;
        // T3 unstick (owner, 2026-10-20): a T3 that stops moving while ordered out is freed by reclaiming the T1 porc,
        // T1 eco, T1 construction turrets, T2 flak and T2 pop-up artillery around it (src/settings/shared/t3_unstick.as, off there)
        Global::T3Unstick::Enabled = true;
        Global::RoleSettings::Tech::EarlyGantryEnabled = true;
        // Gantry turrets (owner, 2026-10-26; tested 2026-10-27 in 69 headless 8v8 games): every builder and
        // turret builds the gantry block's turret frames first, the block opens at 80% of the gantry's income gate, and
        // the T1 air plant keeps 4 more T1 air constructors for it (src/settings/roles/tech.as GantryNano*, off there)
        Global::RoleSettings::Tech::GantryNanoFirst = true;
        Global::RoleSettings::Tech::GantryNanoPrebuildShare = 0.8f;
        Global::RoleSettings::Tech::GantryNanoExtraAirCons = 4;
        Global::RoleSettings::Front::EcoLadderGantryNanoFirst = true;
        // TECH t3rush gantry turrets (owner, 2026-10-18): a random 14-20 construction turrets while the gantry goes up,
        // then a slower climb to 40 over the 5 minutes after it stands (src/settings/roles/tech.as T3RushTurrets*, off there)
        Global::RoleSettings::Tech::T3RushTurretsMin = 14;
        Global::RoleSettings::Tech::T3RushTurretsMax = 20;
        Global::RoleSettings::Tech::T3RushTurretsRampSeconds = 300;
        Global::RoleSettings::Tech::T3RushTurretsRampTo = 40;
        // TECH gantry (owner, 2026-10-17): the nearest spot up to 40% toward the front first, cramped allowed,
        // 24+ turrets, exit clear 480 ahead and leading to the front (src/settings/roles/tech.as GantryNearMaxShare, 0 there)
        Global::RoleSettings::Tech::GantryNearMaxShare = 0.4f;
        Global::RoleSettings::Front::VehicleTankOpenerChance = 0.5f;
        // FRONT vehicles (owner, 2026-10-19): every 3 min from the opener to the first T2 factory, 50% for 5-8
        // medium tanks held at the plant until the last is out (src/settings/roles/front.as VehicleTankMass*, off there)
        Global::RoleSettings::Front::VehicleTankMassChance = 0.5f;
        // ... and a T2 vehicle plant all game: every 3 min, 35% for 5-8 Bull/Tiger/Prometheus sent as one attack squad
        // with a jammer, radar and flak vehicle built first, kept at the wave's safe centre (owner, 2026-10-19/20)
        Global::RoleSettings::Front::VehicleT2TankMassChance = 0.35f;
        Global::RoleSettings::Front::VehicleT2WaveEscorts = true;
        // ... and 15% for a faction artillery squad instead (owner, 2026-10-20; systems/production/front_arty_squad.as)
        Global::RoleSettings::Front::VehicleT2ArtySquadChance = 0.15f;
        // FRONT bot labs (owner, 2026-10-19): every 3 min from the opener wave to the first T2 factory, 50% for 10-15
        // Pawns/Grunts or 15-20 Goblins held at the lab until the last is out, then one attack wave (BotWave*, off in src)
        Global::RoleSettings::Front::BotWaveChance = 0.5f;
		// FRONT (owner, 2026-10-17): two FRONTs each build a spam lab for an edge lane, left and right
		// (src/settings/shared/spam.as EdgeLanesEnabled, off there; systems/combat/edge_lanes.as)
		Global::Spam::EdgeLanesEnabled = true;
	}

}  // namespace Main
