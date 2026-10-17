#include "../src/setup.as"
#include "../src/helpers/common/generic_helpers.as"
#include "../src/global.as"
#include "../src/maps.as"
#include "../src/types/strategy.as" // for StrategyUtil names when logging

namespace Main {

	// Weighted strategy configuration for HARD difficulty.
	// Values are likelihoods in [0.0, 1.0] for enabling a given strategy.
	// Adjust these to tune how often a strategy is chosen at game start.
	namespace StrategyWeights {
		float Tech_Spam_Rush = 0.85f;   // 85% chance
		float Tech_T3_RUSH = 0.35f;   // 35% chance
		float Tech_NUKE_RUSH = 0.25f; // 25% chance
		float Tech_T2_RUSH = 0.25f; // Independent finite heavy-delivery rush
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

		if (DecideEnabled(StrategyWeights::Tech_Spam_Rush)) {
			Global::RoleSettings::Tech::EnableStrategy(Strategy::SPAM_RUSH);
		}
		if (DecideEnabled(StrategyWeights::Tech_T3_RUSH)) {
			Global::RoleSettings::Tech::EnableStrategy(Strategy::T3_RUSH);
		}
		if (DecideEnabled(StrategyWeights::Tech_NUKE_RUSH)) {
			Global::RoleSettings::Tech::EnableStrategy(Strategy::NUKE_RUSH);
		}

		// Append the new draw: preserve the order of the three established rolls.
		if (DecideEnabled(StrategyWeights::Tech_T2_RUSH)) {
			Global::RoleSettings::Tech::EnableStrategy(Strategy::T2_RUSH);
		}

		GenericHelpers::LogUtil(
			"[Strategy] (EXPERIMENTAL BALANCED) Decided: Tech mask=" + Global::RoleSettings::Tech::StrategyMask +
			" (" + StrategyUtil::NamesFromMask(Global::RoleSettings::Tech::StrategyMask) + ")",
			2);
	}

	void AiMain()
	{
		Global::RoleSettings::MexOwnershipEnabled = true;
		// Also initialize before setupMap (and when reconstructing a saved game).
		aiEconomyMgr.SetMexOwnership(true, Global::RoleSettings::MexOwnershipSeconds);
		Global::RoleSettings::Air::FundFirstLab = true;
        Global::Commander::AfusDefenceRadius = Global::Commander::BaseRadius;
        Global::Commander::FrontRecovery = true;
        Global::Commander::FrontMexSeconds = 1.f;
        Global::RoleSettings::Tech::EcoFlakEnabled = true;
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
		Commands::DrawTick();   // the widget's map drawing, paced under the server's flood guard
		// Update cached enemy threat information roughly every 10 seconds (300 frames).
		//if ((ai.frame % (10 * SECOND)) == 0) {
		Military::UpdateEnemyThreatCache();
		Military::UpdateEnemyCostCache();
        Aggression::Update();
        CommanderCombat::Update();

		if (Global::profileController !is null) {
			Global::profileController.MainUpdate();
		}
		Team::Roster::Update();  // announce ourselves to allied BARb instances until the roster is complete
		Spam::Update();          // economy-gated spam: activation, focus rotation
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
        Global::RoleSettings::Tech::EarlyGantryEnabled = true;
        Global::RoleSettings::Front::VehicleTankOpenerChance = 0.5f;
	}

}  // namespace Main
