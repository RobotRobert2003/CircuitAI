// role: TECH
#include "../../global.as"
#include "../../systems/construction/local_geothermal.as"
#include "../../helpers/roles/role_limit_helpers.as"
#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/units/unitdef_helpers.as"
#include "../../types/role_config.as"
#include "../../types/terrain.as"

// Guard assignment helper utilities
#include "../../helpers/construction/guard_helpers.as"
// Economy decision helpers (converter logic, nano counts, etc.)
#include "../../helpers/construction/economy_helpers.as"
// Collection/dictionary helpers
#include "../../helpers/common/collection_helpers.as"
#include "../../helpers/objectives/objective_helpers.as"
// Builder state and helpers
#include "../../helpers/spatial/map_helpers.as"
#include "../../manager/builder.as"
#include "../../systems/team/team.as"
#include "../../systems/construction/layout.as"
#include "../../systems/construction/eco_flak.as"
#include "../../systems/construction/eco_planner.as"
#include "../../systems/construction/lifecycle.as"
#include "../../systems/diagnostics/invariants.as"
#include "tech_build.as"
#include "tech_rules.as"
#include "tech_chain.as"
#include "tech_plan.as"
#include "tech_heavy_rush.as"
#include "tech_transport.as"

namespace RoleTech
{
	// One-time flag to apply economy-threshold behaviors only once when threshold is reached
	bool hasAppliedT1EcoThreshold = false;
	bool hasAppliedT1VehicleEcoThreshold = false;
	// One-way gate to unlock advanced storages when economy is ready
	bool hasUnlockedAdvancedStorage = false;
	bool economySwitched = false;   // TECH's own economy settings applied (D-054)
	// One-way gate: have the T2 rush bots had their engine cap restored?
	bool hasUncappedRushBots = false;
	// One-way gate: after first T2 bot lab, allow one T1 metal storage (raise cap to 1)
	bool hasRaisedT1MetalStorageCap = false;
	// One-way gate: has a landlocked start unlocked shipyards and hover plants?
	bool hasUnlockedLandLockedWaterFactories = false;
	// One-way gate: has the nuke silo targeted the farthest tech spot?
	bool hasTargetedFarthestTech = false;
	// Nuke first strike: the CSuperTask whose target position is overridden, and the
	// frame at which Tech_UpdateNukeFirstStrike hands targeting back to native code.
	CSuperTask @g_nukeFirstStrikeTask = null;
	int g_nukeFirstStrikeUntilFrame = -1;
	// Global fast-assist cap for TECH role (computed from income in Tech_IncomeBuilderLimits)
	int g_fastAssistBotCap = 0;

	// Engine-supplied maxthisunit for the T2 rush bots - Sprinter (armfast),
	// Fiend (corpyro), Hoplite (legstr) - snapshotted before Tech_ApplyStartLimits
	// zeroes the combat lists, so the rush can restore the real value instead of an
	// invented one. The engine value is MAX_UNITS clamped by any game-level unit
	// restriction (Recoil UnitDef.cpp: maxThisUnit / unitRestricted), which a
	// hardcoded cap would silently ignore.
	dictionary g_rushBotEngineCaps;

	// The opening (D-063): before any other structure the commander claims
	// every mex it can reach within OpeningMexRadius of the start, nearest
	// to itself first (native orders the spots by the builder's position), so
	// it walks a chain and not a star. Native's start-factory job is held
	// until then and released the moment the mexes are claimed, or at the
	// deadline, or when the commander is lost (R-1 of the D-062 review).
	namespace Opening
	{
		bool complete = false;
		int startFrame = 0;
		int claimed = 0;               // distinct spots ordered
		array<AIFloat3> spots;         // where they are

		float MexRadius()
		{
			return (Global::Map::Config.TechOpeningMexRadius > 0.0f)
				? Global::Map::Config.TechOpeningMexRadius
				: Global::RoleSettings::Tech::OpeningMexRadius;
		}

		int MexCap()
		{
			if (MetalEconomy::Active()) return MetalEconomy::OpeningCap();
			return (Global::Map::Config.TechOpeningMexCap > 0)
				? Global::Map::Config.TechOpeningMexCap
				: Global::RoleSettings::Tech::OpeningMexCap;   // 0 = every spot inside the radius
		}

		void Init()
		{
			const int labs = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1BotLabs());
			complete = labs > 0;
			startFrame = ai.frame;
			claimed = 0;
			spots.resize(0);
			aiEconomyMgr.holdStartFactory = true;   // for the whole game: the script orders every factory (D-066)
			// TECH owns storage order (the planner); the native periodic storage
			// job otherwise races it and counts only completed stores.
			aiEconomyMgr.autoStorageEnabled = false;
			if (!complete)
			{
				string which = " (all)";
				if (MexCap() > 0) which = " (nearest " + MexCap() + ")";
				GenericHelpers::LogUtil("[TECH][Opening] mexes within " + int(MexRadius()) + " elmos first"
					+ which + "; start factory held up to " + Global::RoleSettings::Tech::OpeningMaxSeconds + " s", 1);
			}
		}

		void Finish(const string &in reason)
		{
			if (complete) return;
			complete = true;
			// Native's start-factory job stays off (D-066): TechBuild orders the
			// lab on its reserved slot the next time a builder asks.
			GenericHelpers::LogUtil("[TECH][Opening] complete after " + claimed + " mexes, "
				+ int((ai.frame - startFrame) / SECOND) + " s: " + reason + "; the lab is next", 1);
		}

		// The commander defs carry the COMM role; any of them standing counts.
		bool CommanderAlive()
		{
			array<string> names = { "armcom", "corcom", "legcom" };
			for (uint i = 0; i < names.length(); ++i)
			{
				CCircuitDef@ d = ai.GetCircuitDef(names[i]);
				if (d !is null && UnitHelpers::IsCommander(d) && d.count > 0) return true;
			}
			return false;
		}

		// From Tech_EconomyUpdate: the deadline and the commander's death end
		// the hold whatever the mex count.
		void Tick()
		{
			if (complete || !Global::RoleSettings::Tech::ExperimentalBuild) return;
			const int deadline = MetalEconomy::Active() ? MetalEconomy::OpeningDeadlineSeconds : Global::RoleSettings::Tech::OpeningMaxSeconds;
			if (ai.frame - startFrame > deadline * SECOND)
			{
				Finish("deadline");
				return;
			}
			if (!CommanderAlive())
			{
				Finish("no commander");
			}
		}

		IUnitTask@ MakeTask(CCircuitUnit@ unit)
		{
			if (complete || unit is null || unit.circuitDef is null
				|| !UnitHelpers::IsCommander(unit.circuitDef)) return null;
			// Native re-asks a busy builder every few seconds and swaps only
			// when the kind differs: the mex the commander is on is the answer.
			IBuilderTask@ cur = (unit.task is null) ? null : cast<IBuilderTask>(unit.task);
			if (cur !is null && Task::BuildType(cur.GetBuildType()) == Task::BuildType::MEX)
				return unit.task;
			// The cap is the opener's own count of distinct spots ordered: native
			// re-evaluates "open" on every call, so a native cap of three kept
			// reaching for the next open spot once the first three were ours
			// (played: a fourth mex at 1,866 elmos).
			if (MexCap() > 0 && claimed >= MexCap())
			{
				if (aiEconomyMgr.GetMexTaskCountWithin(Global::Map::StartPos, MexRadius()) > 0)
					return aiBuilderMgr.Enqueue(TaskB::Wait(SECOND));
				Finish("the " + MexCap() + " nearest spots are ordered and none is pending");
				return null;
			}
			// An untaken mex order in the radius is handed back before a new spot
			// is closed (native), so one order exists at a time.
			IUnitTask@ mex = aiEconomyMgr.EnqueueMexWithin(unit, Global::Map::StartPos, MexRadius(), 0);
			if (mex !is null)
			{
				IBuilderTask@ order = cast<IBuilderTask>(mex);
				AIFloat3 at = Global::Map::StartPos;
				if (order !is null) at = order.GetBuildPos();
				bool known = false;
				for (uint i = 0; i < spots.length(); ++i)
					if (MapHelpers::SqDist(spots[i], at) < 64.0f * 64.0f) known = true;
				if (!known)
				{
					spots.insertLast(at);
					++claimed;
					GenericHelpers::LogUtil("[TECH][Opening] home mex order " + claimed + "/" + MexCap() + " at (" + int(at.x) + ", " + int(at.z) + "), "
						+ int(sqrt(MapHelpers::SqDist(at, Global::Map::StartPos))) + " from start", 1);
				}
				return mex;
			}
			// No open spot left: complete only once no mex order in the radius
			// is still pending (one may be assigned to another builder).
			if (aiEconomyMgr.GetMexTaskCountWithin(Global::Map::StartPos, MexRadius()) > 0)
				return aiBuilderMgr.Enqueue(TaskB::Wait(SECOND));
			if (MetalEconomy::Active()) return aiBuilderMgr.Enqueue(TaskB::Wait(SECOND));
			Finish("every reachable spot inside the radius is taken and no mex order is pending");
			return null;
		}
	}

	/******************************************************************************

	INITIALIZATION

	******************************************************************************/
	void Tech_Init()
	{
        aiBuilderMgr.recoverConstruction = true;
        TechFortifications::Reset();
        TechReclaim::ProtectEnergyStorage();   // D-290 (owner): TECH never reclaims an energy storage, on any path

		// Apply TECH role settings
		aiTerrainMgr.SetAllyZoneRange(Global::RoleSettings::Tech::AllyRange);
		// The experimental build system (D-066): on, this instance's builders
		// are sequenced by TechBuild and placed by the layout; native chooses
		// nothing and spirals nowhere. Off, TECH is stock like every other role.
		if (Global::RoleSettings::Tech::ExperimentalBuild)
		{
			Layout::Enable(Global::RoleSettings::Tech::LayoutEnabled);
			aiEconomyMgr.assistNanoEnabled = false;   // the planner owns turrets (D-063)
			aiBuilderMgr.experimentalBuild = true;
			aiBuilderMgr.experimentalDirectRange = Global::RoleSettings::Tech::ExperimentalBuildDirectRange;
			aiBuilderMgr.experimentalSearchRadius = Global::RoleSettings::Tech::ExperimentalSearchRadius;
			Opening::Init();
			GenericHelpers::LogUtil("[TECH][Build] experimental build system on: direct range "
				+ int(aiBuilderMgr.experimentalDirectRange) + ", search radius " + int(aiBuilderMgr.experimentalSearchRadius), 1);
            TechHeavyRush::Init();
			TechChain::Init();   // D-070: the rush chain, after the opening so it can take the opening over
			TechPlan::Init();    // D-080: what follows the objective
			@Global::energyAllowed = @TechBuild::EnergyAllowed;   // D-077: no T1 energy in the fusion era, whoever orders it
		}
		else
		{
			aiBuilderMgr.experimentalBuild = false;
			GenericHelpers::LogUtil("[TECH][Build] experimental build system off: stock ladder and placement", 1);
		}

		// The role's own economy settings (D-047, D-051) wait for the income
		// floors (D-054); until then the shared economy.json defaults stand.
		if (Global::RoleSettings::Tech::EconomySwitchEnabled)
		{
			GenericHelpers::LogUtil("[TECH][Economy] on shared defaults (reclEnergyEff=" + aiEconomyMgr.reclEnergyEff
				+ ", assist nanos " + (aiEconomyMgr.assistNanoEnabled ? "on" : "off") + ") until +"
				+ int(Global::RoleSettings::Tech::EconomySwitchMetalIncome) + " metal and +"
				+ int(Global::RoleSettings::Tech::EconomySwitchEnergyIncome) + " energy", 1);
		}
		else
		{
			Tech_ApplyEconomySettings("at init");
		}
		// Change scout cap (unit count)
		aiMilitaryMgr.quota.scout = Global::RoleSettings::Tech::MilitaryScoutCap;

		// Change attack gate (power threshold, not a headcount)
		aiMilitaryMgr.quota.attack = Global::RoleSettings::Tech::MilitaryAttackThreshold;

		// Change raid thresholds (power)
		aiMilitaryMgr.quota.raid.min = Global::RoleSettings::Tech::MilitaryRaidMinPower;
		aiMilitaryMgr.quota.raid.avg = Global::RoleSettings::Tech::MilitaryRaidAvgPower;

		GenericHelpers::LogUtil("[Tech][Quota] scout=" + aiMilitaryMgr.quota.scout +
									" attack=" + aiMilitaryMgr.quota.attack +
									" raid.min=" + aiMilitaryMgr.quota.raid.min +
									" raid.avg=" + aiMilitaryMgr.quota.raid.avg,
								3);

		Tech_ApplyStartLimits();
		Tech_ApplyAttributes();

		// Log all strategic objectives with distance from start
		ObjectiveHelpers::LogAllObjectivesFromStart(AiRole::TECH, "TECH");
	}

	// TECH's economy settings, this instance only (economy.json is shared):
	// reclaim old energy sooner (D-047), cap solars if asked, and take the nano
	// count away from native assist (D-051). Applied at init when the switch
	// is off, else from Tech_EconomyUpdate once income clears both floors (D-054).
	void Tech_ApplyEconomySettings(const string &in when)
	{
		economySwitched = true;
		// D-077: with the experimental build the energy.reclaim row owns energy
		// reclaim (one owner per decision); native's ReclaimOldEnergy is off
		aiEconomyMgr.reclEnergyEff = Global::RoleSettings::Tech::ExperimentalBuild ? 0.0f : Global::RoleSettings::Tech::ReclaimEnergyEff;
		aiEconomyMgr.reclaimOldConvertersAlways = Global::RoleSettings::Tech::ReclaimOldConvertersAlways;
		// The later economy switch must retain the same single layout owner as
		// Tech_Init; native factory-assist orders have no reserved turret slot.
		aiEconomyMgr.assistNanoEnabled = !Global::RoleSettings::Tech::ExperimentalBuild && Global::RoleSettings::Tech::AssistNanoEnabled;
		aiEconomyMgr.assistNanoIncomeMod = Global::RoleSettings::Tech::AssistNanoIncomeMod;
		const string side = Global::AISettings::Side;
		CCircuitDef@ solar = ai.GetCircuitDef(UnitHelpers::GetSolarNameForSide(side));
		CCircuitDef@ adv = ai.GetCircuitDef(UnitHelpers::GetAdvSolarNameForSide(side));
		if (solar !is null && Global::RoleSettings::Tech::EnergyLimitSolar >= 0)
			aiEconomyMgr.SetEnergyCondition(solar, Global::RoleSettings::Tech::EnergyLimitSolar, -1.0f, -1.0f);
		if (adv !is null && Global::RoleSettings::Tech::EnergyLimitAdvSolar >= 0)
			aiEconomyMgr.SetEnergyCondition(adv, Global::RoleSettings::Tech::EnergyLimitAdvSolar, -1.0f, -1.0f);
		GenericHelpers::LogUtil("[TECH][Economy] own settings " + when + ": reclEnergyEff=" + Global::RoleSettings::Tech::ReclaimEnergyEff
			+ " assist nanos " + (Global::RoleSettings::Tech::AssistNanoEnabled ? "on" : "off")
			+ " solar limit " + (solar is null ? -1 : aiEconomyMgr.GetEnergyLimit(solar))
			+ " adv solar limit " + (adv is null ? -1 : aiEconomyMgr.GetEnergyLimit(adv)), 1);
	}

	// D-068: the one income under which TECH's labs make no combat unit while the
	// experimental build system is on. The legacy gates (the T2 rush's early gate,
	// the bot-lab and vehicle-plant expansion gates) are raised to it, never
	// lowered; 0 means never. Off the switch, the legacy gate is returned as is.
	// Played (2026-09-21, Supreme Isthmus): the rush gate (100) opened at 17 min
	// on a reclaim-inflated 10 s income and the advanced lab made Fiends and Ducks.
	float Tech_CombatGate(float legacyGate)
	{
		if (!Global::RoleSettings::Tech::ExperimentalBuild)
			return legacyGate;
		// D-080: the plan's gate (200, or 500 for the T3 rush); ExpCombatMetalIncome 0 keeps "never"
		if (Global::RoleSettings::Tech::ExpCombatMetalIncome <= 0.0f)
			return 1.0e9f;
		const float g = TechPlan::CombatGate();
		return (g > legacyGate) ? g : legacyGate;
	}

	// The units whose engine cap Tech snapshots at start and releases at the rush gate:
	// the rush bots (Sprinter/Fiend/Hoplite) and the amphibious T2 bots
	// (Platypus/Duck/Telchine) that Tech_FactoryAiMakeTask substitutes on land-locked
	// starts. Both sets sit in the T2 combat cap list, so both must be released together.
	array<string> Tech_GetGatedT2Bots()
	{
		array<string> ids = UnitHelpers::GetAllFastT2Bots();
		array<string> amph = UnitHelpers::GetAllAmphibiousT2Bots();
		for (uint i = 0; i < amph.length(); ++i)
			ids.insertLast(amph[i]);
		return ids;
	}

	// Restore the engine's own maxthisunit for the gated T2 bots. Called when the
	// T2 rush is active so they are never the limiting factor; falls back to
	// leaving the def alone if no snapshot exists.
	void Tech_UncapRushBots(const string &in reason)
	{
		array<string> rushBots = Tech_GetGatedT2Bots();
		for (uint i = 0; i < rushBots.length(); ++i)
		{
			CCircuitDef @rd = ai.GetCircuitDef(rushBots[i]);
			if (rd is null)
				continue;

			int engineCap = 0;
			if (!g_rushBotEngineCaps.get(rushBots[i], engineCap))
			{
				GenericHelpers::LogUtil("[TECH][Limits] No engine cap snapshot for rush bot '"
					+ rushBots[i] + "'; leaving cap at " + rd.maxThisUnit, 2);
				continue;
			}
			if (rd.maxThisUnit != engineCap)
			{
				rd.maxThisUnit = engineCap;
				GenericHelpers::LogUtil("[TECH][Limits] Rush bot '" + rushBots[i]
					+ "' uncapped to engine limit " + engineCap + " (" + reason + ")", 2);
			}
		}
	}

	void Tech_ApplyStartLimits()
	{
		GenericHelpers::LogUtil("[TECH] Enter Tech_ApplyStartLimits", 4);

		// ****************** COMBAT UNIT LIMITS ****************** //
		// Don't let tech player build anything except t3. Or logically enable T1/T2 later if desired
		//
		// Snapshot the gated T2 bots (rush + amphibious) before the blanket caps below
		// zero them; capturing by name covers whichever list they sit in.
		{
			array<string> rushBots = Tech_GetGatedT2Bots();
			for (uint i = 0; i < rushBots.length(); ++i)
			{
				CCircuitDef @rd = ai.GetCircuitDef(rushBots[i]);
				if (rd !is null)
					g_rushBotEngineCaps.set(rushBots[i], rd.maxThisUnit);
			}
		}

		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT1CombatUnits(), Global::RoleSettings::Tech::StartCapT1CombatUnits);
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT2CombatUnits(), Global::RoleSettings::Tech::StartCapT2CombatUnits);

		// SPAM_RUSH is decided in Main::AiMain by ApplyTechStrategyWeights, which runs
		// before ApplyProfileSettings reaches Tech_Init, so the strategy is known here.
		// When the rush is on, the three rush bots must not stay capped: they are what
		// the additional T2 bot labs exist to produce, alongside T3 from the gantry.
		// The primary T2 lab still makes fast-assist bots - that branch is ordered
		// ahead of the combat batch in Tech_FactoryAiMakeTask.
		//
		// The cap is NOT lifted here. Releasing it at start makes the bots buildable
		// from frame 0, and the script's own income gate does not protect against that:
		// it only guards the batch in Tech_FactoryAiMakeTask. Native production
		// (DefaultMakeTask -> CreateFactoryTask -> UpdateFirePower -> RequiredFireDef)
		// selects purely on availability and has no income threshold, so an uncapped
		// rush bot is produced as soon as any T2 bot lab exists - and the first lab is
		// allowed at MinimumMetalIncomeForT2Lab (18), far below the rush gate. That
		// stalls the economy. Tech_EconomyUpdate lifts the cap at the same income the
		// batch uses, so cap release and production gate unlock together.
		hasUncappedRushBots = false;

		// ****************** REZBOT LIMITS ****************** //
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllRezBots(), Global::RoleSettings::Tech::StartCapRezBots);

		// ****************** FAST ASSIST LIMITS ****************** //
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllFastAssistBots(), Global::RoleSettings::Tech::StartCapFastAssistBots);

		// ****************** LAB LIMITS ****************** //
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT1BotLabs(), Global::RoleSettings::Tech::StartCapT1BotLabs);
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT2BotLabs(), Global::RoleSettings::Tech::StartCapT2BotLabs);

		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT1VehicleLabs(), Global::RoleSettings::Tech::StartCapT1VehiclePlants);
		// TECH role must not build T2 Vehicle Plants
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT2VehicleLabs(), 0);

		// Hover plants start capped at 0. Only a landlocked start raises them (and the
		// shipyards below), at the income gate in Tech_UpdateLandLockedWaterExpansion.
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT1HoverPlants(), 0);
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllFloatingHoverPlants(), 0);

		// ****************** Aircraft Plant LIMITS ****************** //
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT1AircraftPlants(), Global::RoleSettings::Tech::StartCapT1AircraftPlants);
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT2AircraftPlants(), Global::RoleSettings::Tech::StartCapT2AircraftPlants);

		// ****************** Shipyard LIMITS ****************** //
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT1Shipyards(), Global::RoleSettings::Tech::StartCapT1Shipyards);
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT2Shipyards(), Global::RoleSettings::Tech::StartCapT2Shipyards);

		// ****************** ENERGY LIMITS ****************** //
		// Don't over produce t1 solars. At the moment reclaiming energy buildings is not possible

		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT1Solar(), Global::RoleSettings::Tech::StartCapT1Solar);
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT2Solar(), Global::RoleSettings::Tech::MaxAdvancedSolars);
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllFusionReactors(), Global::RoleSettings::Tech::StartCapFusionReactors);
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllAdvancedFusionReactors(), Global::RoleSettings::Tech::StartCapAdvancedFusionReactors);

		// ****************** STATIC LAND DEFENCE LIMITS ****************** //
		// TECH must not build anti-ground land defenses (AA and LRPC remain allowed)
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllLandDefences(), 0);

		// ****************** SUPER WEAPON LIMITS ****************** //
		// Apply a unified cap across all nuke silos
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllNukeSilos(), Global::RoleSettings::Tech::NukeLimit);

		// ****************** T1 METAL STORAGE LIMITS ****************** //
		// Per request: start with standard T1 metal storages disabled (cap=0).
		// Do NOT change T1 energy storage limits here.
		{
			array<string> t1Metal = UnitHelpers::GetAllT1MetalStorages();
			UnitHelpers::BatchApplyUnitCaps(t1Metal, 0);
			GenericHelpers::LogUtil("[TECH][Limits] T1 metal storage init cap set to 0", 3);
			hasRaisedT1MetalStorageCap = false; // ensure locked at start
		}

		// ****************** ADVANCED STORAGE LIMITS ****************** //
		// Per request: start with advanced metal/energy storages disabled (cap=0).
		// Do NOT change T1 storages.
		{
			array<string> advE = UnitHelpers::GetAllAdvancedEnergyStorages();
			array<string> advM = UnitHelpers::GetAllAdvancedMetalStorages();
			UnitHelpers::BatchApplyUnitCaps(advE, 0);
			UnitHelpers::BatchApplyUnitCaps(advM, 0);
			GenericHelpers::LogUtil("[TECH][Limits] Advanced storages init caps set: energy=0, metal=0", 3);
			hasUnlockedAdvancedStorage = false; // ensure locked at start
		}

		// Ignore all T1 combat units for TECH role
		array<string> t1Units = UnitHelpers::GetAllT1CombatUnits();
		UnitDefHelpers::SetIgnoreFor(t1Units, true);

		// Tag only T1/T2 land + air labs as 'support' for TECH role (keep factories conservative by default)
		// Excludes: T3 gantries and shipyards/sea labs.
		{
			array<string> supportLabs = UnitHelpers::GetAllT1T2LandLabsAndAircraftPlants();
			UnitDefHelpers::SetMainRoleFor(supportLabs, "support");
			GenericHelpers::LogUtil("[TECH][Labs] Set mainRole=support for T1/T2 bot, vehicle, and air plants only (excluding gantries/shipyards)", 3);
		}

		// For TECH, set max caps for non-construction aircraft using global settings
		array<string> t1AirCombat = UnitHelpers::GetAllT1AircraftCombatUnits();
		UnitHelpers::BatchApplyUnitCaps(t1AirCombat, Global::RoleSettings::Tech::StartCapT1AirCombatUnits);
		array<string> t2AirCombat = UnitHelpers::GetAllT2AircraftCombatUnits();
		UnitHelpers::BatchApplyUnitCaps(t2AirCombat, Global::RoleSettings::Tech::StartCapT2AirCombatUnits);

		GenericHelpers::LogUtil("Tech start limits applied", 3);

		// Re-apply merged map+role unit limits so map constraints always win over role caps
		if (Global::Map::MergedUnitLimits.getKeys().length() > 0)
		{
			GenericHelpers::LogUtil("[TECH][Limits] Applying merged map+role unit limits (start)", 3);
			UnitHelpers::ApplyUnitLimits(Global::Map::MergedUnitLimits);

			// Print out all unit limits from the merged dictionary for visibility
			array<string> @_mk = Global::Map::MergedUnitLimits.getKeys();
			for (uint i = 0; i < _mk.length(); ++i)
			{
				const string uname = _mk[i];
				int cap = 0;
				if (Global::Map::MergedUnitLimits.get(uname, cap))
				{
					GenericHelpers::LogUtil("[TECH][Limits] merged unit cap: " + uname + " = " + cap, 3);
				}
			}
		}
		else
		{
			GenericHelpers::LogUtil("[TECH][Limits] No merged unit limits found to apply at start", 3);
		}
	}

	void Tech_ApplyAttributes()
	{
		GenericHelpers::LogUtil("[TECH] Enter Tech_ApplyAttributes", 4);

		// Add VAMPIRE attribute to T1/T2 bot constructors, fast assist bots, and construction turrets
		// This ensures they stay near the base or are treated as base defenders/builders
		// Note: BASE attribute is dynamic (per unit), VAMPIRE is static (per def)

		// Apply per-unitdef attributes via UnitDefHelpers using attribute name string
		UnitDefHelpers::AddAttrFor(UnitHelpers::GetAllT1BotConstructors(), "vampire");
		UnitDefHelpers::AddAttrFor(UnitHelpers::GetAllT2BotConstructors(), "vampire");
		UnitDefHelpers::AddAttrFor(UnitHelpers::GetAllFastAssistBots(), "vampire");
		UnitDefHelpers::AddAttrFor(UnitHelpers::GetT1NanoUnitNames(), "vampire");

		GenericHelpers::LogUtil("[TECH] Applied VAMPIRE attribute to T1/T2 bot constructors, fast assist bots, and all T1 nanos", 3);
	}

	/******************************************************************************

	MAIN HOOKS

	******************************************************************************/

	void Tech_MainUpdate()
	{
		GenericHelpers::LogUtil("[TECH] Enter Tech_MainUpdate", 4);
		Tech_UpdateNukeFirstStrike();
	}

	// Release the first-strike override once the silo has had time to fire, so its
	// CSuperTask returns to native target selection. An invalid position (x == -1,
	// geom::is_valid) clears the override. The handle is ref-counted; the
	// task-removed hook drops it early if the task dies first.
	void Tech_UpdateNukeFirstStrike()
	{
		if (g_nukeFirstStrikeTask is null || ai.frame < g_nukeFirstStrikeUntilFrame)
			return;
		g_nukeFirstStrikeTask.SetTargetPos(AIFloat3(-1.0f, 0.0f, 0.0f));
		@g_nukeFirstStrikeTask = null;
		GenericHelpers::LogUtil("[TECH] Nuke first-strike override released; native targeting resumes", 2);
	}

	// T2 combat bots from the advanced lab: the donation plan gives N of them
	// to the closest allies (Team::Donation::OnCombatBotBuilt, D-041).
	void Tech_MilitaryAiUnitAdded(CCircuitUnit @unit, Unit::UseAs usage)
	{
		Invariants::OnUnitAdded(unit);   // D-076: INV-001
        if (TechHeavyRush::OnFinished(unit)) return;
        // D-158: keep the amphibious wave together; constructor donations are separate.
        if (!AmphibiousOps::Active() || unit is null || AmphibiousOps::Kind(unit.circuitDef)<0)
            Team::Donation::OnCombatBotBuilt(unit);
	}

	void Tech_MilitaryAiTaskRemoved(IUnitTask @task, bool done)
	{
		if (g_nukeFirstStrikeTask !is null && task is g_nukeFirstStrikeTask)
		{
			@g_nukeFirstStrikeTask = null;
		}
	}

	/******************************************************************************

	ECONOMY HOOKS

	******************************************************************************/

	void Tech_EconomyUpdate()
	{
		GenericHelpers::LogUtil("[TECH] Enter Tech_EconomyUpdate", 4);
		// float metalIncome = Global::Economy::GetMetalIncome();
		float metalIncome = Economy::GetMinMetalIncomeLast10s();

		int t2ConstructionBotCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotConstructors());
		int t1ConstructionBotCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1BotConstructors());

		bool hasT2Lab = (@Factory::primaryT2BotLab !is null);
		bool hasT1Lab = (@Factory::primaryT1BotLab !is null);

		float energyIncome = aiEconomyMgr.energy.income;
		float metalCurrent = aiEconomyMgr.metal.current;

		// Economy switch (D-054): the role's own settings once both incomes clear the floors.
		if (!economySwitched && Global::RoleSettings::Tech::EconomySwitchEnabled
			&& metalIncome >= Global::RoleSettings::Tech::EconomySwitchMetalIncome
			&& energyIncome >= Global::RoleSettings::Tech::EconomySwitchEnergyIncome)
		{
			Tech_ApplyEconomySettings("at +" + int(metalIncome) + " metal, +" + int(energyIncome) + " energy");
		}

		// Ensure factory assist is required when we have a T2 lab but no T2 constructors yet
		// This helps bootstrap the first T2 constructor quickly
		if (hasT2Lab && t2ConstructionBotCount < 1)
		{
			aiFactoryMgr.isAssistRequired = true;
			GenericHelpers::LogUtil("[TECH][Assist] Forcing factory assist: T2 lab present, T2 constructors=0", 3);
		}

		Opening::Tick();
		TechBuild::Tick();
		TechChain::Tick();
        TechHeavyRush::Tick();
        TechGantry::SampleIncome();
        TechHeavyChoice::Tick();   // D-287: the late latch, O(1), stops once latched
        TechGantryScale::Tick();   // D-288: gantry target/cap/due, O(tier-3 clusters)
		Lanes::Tick();         // D-127: lanes between both teams' starts, drawn after the intro
		TechFlank::Tick();     // D-136: dedicated accessible-flank production
		TechFactories::PlanAhead();
		TechFortifications::Tick();
		TechWeapons::Tick();   // D-126: weapon clusters: analysis, discovery, budget, the super cannon
		Invariants::Tick();   // D-076: the role's promises, checked once a second
		Tech_IncomeBuilderLimits(metalIncome);
		// The native plan owns geometry and slot state; this refreshes restored
		// state and the optional overlay.
		Layout::Update(metalIncome, hasT2Lab, t2ConstructionBotCount);
        EcoFlak::Tick();

		// --- Unlock advanced storages when economy is strong enough ---
		if (!hasUnlockedAdvancedStorage && metalIncome >= 100.0f)
		{
			array<string> advE = UnitHelpers::GetAllAdvancedEnergyStorages();
			array<string> advM = UnitHelpers::GetAllAdvancedMetalStorages();
			UnitHelpers::BatchApplyUnitCaps(advE, 1);
			UnitHelpers::BatchApplyUnitCaps(advM, 1);
			hasUnlockedAdvancedStorage = true;
			GenericHelpers::LogUtil("[TECH][Limits] Advanced storages unlocked at mi>=100: energy=1, metal=1", 2);
			// Ensure merged map+role limits are reapplied so map constraints win
			if (Global::Map::MergedUnitLimits.getKeys().length() > 0)
			{
				GenericHelpers::LogUtil("[TECH][Limits] Re-applying merged map+role unit limits after storage unlock", 4);
				UnitHelpers::ApplyUnitLimits(Global::Map::MergedUnitLimits);
			}
		}

		// D-288: the per-second income-scaled gantry cap that stood here (metal 250
		// and energy 6000 per gantry, two string arrays allocated each second) is
		// replaced by TechGantryScale, ticked above: one owner of target, cap and due.

		// --- Dynamic T2 Bot Lab cap ---
		// The primary T2 bot lab is reserved for fast-assist production, so the T2 combat
		// rush depends on additional labs existing. Tech_ApplyStartLimits pins maxThisUnit to
		// StartCapT2BotLabs (1) and nothing raised it again, unlike T1 bot labs below, so a
		// second lab was impossible: CCircuitDef::IsAvailable() is maxThisUnit > count, and
		// Builder::EnqueueT2BotLabIfNeeded bails on that check.
		{
			int allowedT2Labs = EconomyHelpers::AllowedT2BotLabCountFromIncome(
				/*mi*/ metalIncome,
				/*ei*/ energyIncome,
				/*metalIncomePerLab*/ Global::RoleSettings::Tech::MetalIncomePerT2Lab,
				/*energyIncomePerLab*/ Global::RoleSettings::Tech::EnergyIncomePerT2Lab);
			if (allowedT2Labs < 1)
				allowedT2Labs = 1;
			if (allowedT2Labs > Global::RoleSettings::Tech::MaxT2BotLabs)
				allowedT2Labs = Global::RoleSettings::Tech::MaxT2BotLabs;

			UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT2BotLabs(), allowedT2Labs);

			// Release the rush bots' engine cap once income reaches the same gate the T2
			// combat batch uses in Tech_FactoryAiMakeTask (botLabGate). Doing it earlier
			// lets native production build them from the first T2 lab at ~18 income and
			// stall the economy; doing it here keeps cap release and production gate in
			// step. One-way: once unlocked it stays unlocked, so a dip in income does not
			// re-cap mid-rush.
			//
			// Also re-asserted on later passes because Tech_IncomeBuilderLimits and the
			// storage-unlock branch both re-apply Global::Map::MergedUnitLimits, which can
			// re-cap these defs; this runs after those and is a no-op when already correct.
			if (Global::RoleSettings::Tech::HasStrategy(Strategy::SPAM_RUSH))
			{
				const float rushGate = Tech_CombatGate(Global::RoleSettings::Tech::MetalIncomeThresholdForEarlyBotLabExpansion);
				if (!hasUncappedRushBots && metalIncome >= rushGate)
				{
					hasUncappedRushBots = true;
					GenericHelpers::LogUtil("[TECH][Factory] combat production unlocked at +" + metalIncome + " metal (gate " + rushGate + ")", 1);
					Tech_UncapRushBots("metalIncome " + metalIncome + " >= rush gate " + rushGate);
					if (Global::RoleSettings::Tech::ExperimentalBuild)
					{
						// The T1 scouts' cap is lifted here, at the same gate (D-068)
						array<string> t1BotScouts = UnitHelpers::GetAllT1BotScouts();
						UnitHelpers::BatchApplyUnitCaps(t1BotScouts, 100);
					}
				}
				else if (hasUncappedRushBots)
				{
					Tech_UncapRushBots("re-assert after limit re-apply, allowed=" + allowedT2Labs);
				}
			}
			GenericHelpers::LogUtil(
				"[TECH][Labs] T2 bot lab cap=" + allowedT2Labs +
					" (mi=" + metalIncome + "/" + Global::RoleSettings::Tech::MetalIncomePerT2Lab +
					" ei=" + energyIncome + "/" + Global::RoleSettings::Tech::EnergyIncomePerT2Lab +
					" max=" + Global::RoleSettings::Tech::MaxT2BotLabs + ")",
				3);
		}

		// --- Dynamic T1 Bot Lab caps and land factory placement after eco threshold ---
		if (!hasAppliedT1EcoThreshold && metalIncome >= Global::RoleSettings::Tech::MetalIncomeThresholdForBotLabExpansion)
		{
			// Allow up to 5 T1 bot labs across all sides when economy is strong
			UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT1BotLabs(), 3);

			// After threshold, remove 'support' behavior from land factories so they can be built outside base
			array<string> landLabs = UnitHelpers::GetAllLandLabs();
			UnitDefHelpers::SetMainRoleFor(landLabs, "static");
			GenericHelpers::LogUtil("[TECH][Labs] Eco>=threshold: cap T1 bot labs to 5 and set land factories mainRole=static", 3);

			// Ensure high caps for T1 bot scouts (ticks and equivalents)
			// armada: armflea (Tick), cortex: corak (raider), legion: leggob (light skirm)
			// With the experimental system on this waits for the combat gate (D-068).
			if (!Global::RoleSettings::Tech::ExperimentalBuild)
			{
				array<string> t1BotScouts = UnitHelpers::GetAllT1BotScouts();
				UnitHelpers::BatchApplyUnitCaps(t1BotScouts, 100);
			}

			// // Ensure high caps for fast T2 bots per side (canonical unit IDs)
			// // armada: armfast (Sprinter), cortex: corpyro (Fiend), legion: legstr (Hoplite)
			// {
			//     array<string> fastT2Bots = UnitHelpers::GetAllFastT2Bots();
			//     UnitHelpers::BatchApplyUnitCaps(fastT2Bots, 100);
			// }

			Global::RoleSettings::Tech::MaxT1Builders = 25;

			Global::RoleSettings::Tech::MaxT2BotLabs = 3;
			// Mark threshold actions applied so this block does not run again
			hasAppliedT1EcoThreshold = true;
		}

		// --- Dynamic T1 Vehicle Plant caps and land factory placement after eco threshold ---
		if (!hasAppliedT1VehicleEcoThreshold && metalIncome >= Global::RoleSettings::Tech::MetalIncomeThresholdForVehiclePlantExpansion)
		{
			// Allow up to 3 T1 vehicle plants across all sides when economy is strong
			UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT1VehicleLabs(), 3);

			// After threshold, remove 'support' behavior from land factories so they can be built outside base
			// (This is redundant if bot lab expansion already ran, but safe to repeat or ensure)
			array<string> landLabs = UnitHelpers::GetAllLandLabs();
			UnitDefHelpers::SetMainRoleFor(landLabs, "static");
			GenericHelpers::LogUtil("[TECH][Labs] Eco>=threshold: cap T1 vehicle plants to 3 and set land factories mainRole=static", 3);

			// Ensure high caps for T1 vehicle scouts
			{
				array<string> t1VehScouts = UnitHelpers::GetAllT1VehicleScouts();
				UnitHelpers::BatchApplyUnitCaps(t1VehScouts, 100);
			}

			Global::RoleSettings::Tech::MaxT1Builders = 25;

			// Mark threshold actions applied so this block does not run again
			hasAppliedT1VehicleEcoThreshold = true;
		}

		// --- Dynamic Aircraft Plant caps: compute allowed T1/T2 from incomes and apply to all sides ---
		{
			// int allowedT1Air = EconomyHelpers::AllowedT1AircraftPlantCountFromIncome(
			//     /*mi*/ metalIncome,
			//     /*ei*/ energyIncome,
			//     /*metalIncomePerPlant*/ Global::RoleSettings::Tech::RequiredMetalIncomeForAirPlant,
			//     /*energyIncomePerPlant*/ Global::RoleSettings::Tech::RequiredEnergyIncomeForAirPlant
			// );
			int allowedT1Air = 0;
			int allowedT2Air = EconomyHelpers::AllowedT2AircraftPlantCountFromIncome(
				/*mi*/ metalIncome,
				/*ei*/ energyIncome,
				/*metalIncomePerPlant*/ Global::RoleSettings::Tech::RequiredMetalIncomeForT2AircraftPlant,
				/*energyIncomePerPlant*/ Global::RoleSettings::Tech::RequiredEnergyIncomeForT2AircraftPlant);

			if (allowedT2Air > 0)
			{
				allowedT1Air = 1; // We don't really need more than 1 t1 lab
			}

			GenericHelpers::LogUtil(
				"[TECH][AirPlants] Allowed T1/T2 from income: " + allowedT1Air + "/" + allowedT2Air +
					" (t1 miPer=" + Global::RoleSettings::Tech::RequiredMetalIncomeForAirPlant +
					", eiPer=" + Global::RoleSettings::Tech::RequiredEnergyIncomeForAirPlant +
					"; t2 miPer=" + Global::RoleSettings::Tech::RequiredMetalIncomeForT2AircraftPlant +
					", eiPer=" + Global::RoleSettings::Tech::RequiredEnergyIncomeForT2AircraftPlant + ")",
				3);

			array<string> t1AirPlants = UnitHelpers::GetAllT1AircraftPlants();
			array<string> t2AirPlants = UnitHelpers::GetAllT2AircraftPlants();
			UnitHelpers::BatchApplyUnitCaps(t1AirPlants, allowedT1Air);
			UnitHelpers::BatchApplyUnitCaps(t2AirPlants, allowedT2Air);
		}

		// Landlocked start: shipyards and hover plants unlock at the income gate. Runs
		// last so it re-asserts its caps after the limit re-applies above.
		Tech_UpdateLandLockedWaterExpansion(metalIncome);
	}

	/******************************************************************************

	LANDLOCKED WATER EXPANSION

	A start the map script flags landLocked (StartSpot.landLocked ->
	Global::Map::LandLocked) sits on ground the land army cannot leave, so the
	role techs with a bot lab and leaves with amphibious units. Shipyards and
	hover plants are capped at 0 by Tech_ApplyStartLimits like every other Tech
	start; on a landlocked start this unlock raises those caps once metal income
	reaches MetalIncomeThresholdForLandLockedWaterExpansion, and the T2
	constructor ladder then places one T1 shipyard, one hover plant and, on top
	of a T1 shipyard, one T2 shipyard. The native factory chooser never picks
	them (factory.json switch importance is 0 for shipyards and hover plants),
	so Tech_TryEnqueueLandLockedWaterFactory is the only path that builds them.
	A start that is not landlocked is never unlocked.

	One-way, and re-asserted every economy pass because Tech_IncomeBuilderLimits
	and the storage unlock re-apply Global::Map::MergedUnitLimits, which can
	re-cap these defs.

	******************************************************************************/
	void Tech_UpdateLandLockedWaterExpansion(float metalIncome)
	{
		if (!Global::Map::LandLocked)
			return;

		const float gate = Global::RoleSettings::Tech::MetalIncomeThresholdForLandLockedWaterExpansion;
		if (!hasUnlockedLandLockedWaterFactories)
		{
			if (metalIncome < gate)
				return;
			hasUnlockedLandLockedWaterFactories = true;
			GenericHelpers::LogUtil("[TECH][LandLocked] mi " + metalIncome + " >= " + gate
				+ ": unlocking shipyards (T1=" + Global::RoleSettings::Tech::LandLockedMaxT1Shipyards
				+ ", T2=" + Global::RoleSettings::Tech::LandLockedMaxT2Shipyards
				+ ") and hover plants (" + Global::RoleSettings::Tech::LandLockedMaxHoverPlants + ")", 2);
		}
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT1Shipyards(), Global::RoleSettings::Tech::LandLockedMaxT1Shipyards);
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT2Shipyards(), Global::RoleSettings::Tech::LandLockedMaxT2Shipyards);
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllT1HoverPlants(), Global::RoleSettings::Tech::LandLockedMaxHoverPlants);
		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetAllFloatingHoverPlants(), Global::RoleSettings::Tech::LandLockedMaxHoverPlants);
	}

	// T2 constructor ladder step. Order: T1 shipyard, hover plant (land variant,
	// then floating), T2 shipyard once a T1 shipyard stands. Each Builder::Enqueue*
	// wrapper enforces its own cooldown and the caps above, so a step that is at
	// cap or cooling down yields to the next one.
	IUnitTask @Tech_TryEnqueueLandLockedWaterFactory(const string &in side, float metalIncome, float energyIncome, float metalCurrent, const AIFloat3 &in anchor)
	{
		if (!hasUnlockedLandLockedWaterFactories)
			return null;

		if (UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1Shipyards()) < Global::RoleSettings::Tech::LandLockedMaxT1Shipyards)
		{
			IUnitTask @tSy = Builder::EnqueueT1Shipyard(side, anchor, Global::RoleSettings::Tech::LandLockedShipyardSearchRadius, 600 * SECOND);
			if (tSy !is null)
				return tSy;
		}

		const int hoverPlants = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1HoverPlants())
			+ UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllFloatingHoverPlants());
		if (hoverPlants < Global::RoleSettings::Tech::LandLockedMaxHoverPlants)
		{
			IUnitTask @tHp = Builder::EnqueueT1HoverPlant(side, anchor, SQUARE_SIZE * 24, 600 * SECOND);
			if (tHp !is null)
				return tHp;
			IUnitTask @tFhp = Builder::EnqueueFloatingHoverPlant(side, anchor, SQUARE_SIZE * 24, 600 * SECOND);
			if (tFhp !is null)
				return tFhp;
		}

		if (EconomyHelpers::ShouldBuildT2Shipyard(
				/*mi*/ metalIncome,
				/*ei*/ energyIncome,
				/*metalCurrent*/ metalCurrent,
				/*reqMi*/ Global::RoleSettings::Tech::MetalIncomeThresholdForLandLockedWaterExpansion,
				/*reqMetalCurrent*/ 0.0f,
				/*reqEi*/ Global::RoleSettings::Tech::LandLockedMinEnergyIncomeForT2Shipyard,
				/*t2ShipyardCount*/ UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2Shipyards()),
				/*maxAllowed*/ Global::RoleSettings::Tech::LandLockedMaxT2Shipyards,
				/*hasPrimaryFactory*/ Factory::primaryT1Shipyard !is null))
		{
			IUnitTask @tAsy = Builder::EnqueueT2Shipyard(side, Factory::GetT1ShipyardPos(), SQUARE_SIZE * 60, 600 * SECOND);
			if (tAsy !is null)
				return tAsy;
		}
		return null;
	}

	/******************************************************************************

	FACTORY HOOKS

	******************************************************************************/

	// Helper to enqueue a batch of units if available
	IUnitTask @Tech_EnqueueUnitBatch(const string& in unitName, int count, const AIFloat3& in pos, Task::Priority priority = Task::Priority::NORMAL)
	{
		if (unitName.length() == 0)
			return null;
		CCircuitDef @def = ai.GetCircuitDef(unitName);
		if (def !is null && def.IsAvailable(ai.frame))
		{
			GenericHelpers::LogUtil("[TECH][Factory] EnqueueUnitBatch: " + count + "x '" + unitName + "'", 3);
			IUnitTask @last = null;
			for (int i = 0; i < count; ++i)
			{
				@last = aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::FIREPOWER, priority, def, pos, 64.f));
			}
			return last;
		}
		return null;
	}

	IUnitTask @Tech_FactoryAiMakeTask(CCircuitUnit @u)
	{
		// Ensure we always fall back to default factory task unless we can recruit constructors
		// based on global minimum thresholds.
		const CCircuitDef @facDef = (u is null ? null : u.circuitDef);
		if (facDef is null)
		{
			return AmphibiousOps::DefaultFactoryTask(u);
		}

		// D-119: construction turrets are the native factory manager's assistants,
		// asked here, not by the builder rules: a front cluster's turret works for
		// its own factory (D-109, D-114, D-117: rule turret.spam never reached
		// them; it only saw turrets a reclaim pull had moved to the builder side)
		// D-121: an island TECH's shipyards (the harbour)
		if (UnitHelpers::IsT1Shipyard(facDef.GetName()) || UnitHelpers::IsT2Shipyard(facDef.GetName())
			|| (TechHarbour::Enabled() && UnitHelpers::IsT1HoverPlant(facDef.GetName())))
		{
			IUnitTask@ yt = TechHarbour::YardTask(u);
			if (yt !is null) return yt;
		}
		CCircuitDef@ clusterNano = TechFactories::Nano();
		if (clusterNano !is null && facDef.GetName() == clusterNano.GetName() && TechFactories::ClusterOfTurret(u) !is null)
		{
			IUnitTask@ ft = TechFactories::TurretFocus(u, true);
			if (ft !is null) return ft;
		}
		// D-289: every other TECH construction turret runs the one ladder
		// (frames in reach, then a producing factory in reach); null leaves
		// native's default (repair, feature reclaim, wait). The nuke opening's
		// own branch (D-229) is step 2 of the ladder.
		if (!facDef.IsMobile() && UnitHelpers::IsT1Nano(facDef.GetName()))
		{
			IUnitTask@ tw = Tech_TurretWork(u, true);
			if (tw !is null) return tw;
		}

		// D-076: a retiring factory produces nothing (played: the T1 lab built a
		// Lazarus while a constructor and a turret were reclaiming it)
		if (Lifecycle::IsRetiring(u))
		{
			GenericHelpers::LogUtil("[TECH][Factory] " + facDef.GetName() + " " + u.id + " is retiring: no production", 3);
			return null;
		}

        // D-229: the first-shot budget needs two technology builders, not the
        // normal bank-driven constructor expansion. This only owns bot labs
        // while the selected nuke silo is unfinished. Donation/recovery queues
        // are still handled by their existing higher-level request owners.
        if (TechChain::NukeRush() && (UnitHelpers::IsT1BotLab(facDef.GetName()) || UnitHelpers::IsT2BotLab(facDef.GetName()))) {
            const bool advanced = UnitHelpers::IsT2BotLab(facDef.GetName());
            const string conSide = UnitHelpers::GetSideForUnitName(facDef.GetName());
            array<string> names = advanced ? UnitHelpers::GetT2BotConstructors(conSide) : UnitHelpers::GetT1BotConstructors(conSide);
            if (names.length() > 0) {
                CCircuitDef@ conDef = ai.GetCircuitDef(names[0]);
                const int wanted = advanced ? TechChain::wantAck : TechChain::wantCk;
                if (conDef !is null && conDef.count + aiFactoryMgr.GetPendingRecruitCount(conDef) < wanted) {
                    if (conDef.maxThisUnit < wanted) conDef.maxThisUnit = wanted;
                    return aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, conDef, u.GetPos(ai.frame), 64.f));
                }
            }
            return aiFactoryMgr.Enqueue(TaskS::Wait(false, 3 * SECOND));
        }
        if (TechChain::nukeOpening && facDef.GetName() == UnitHelpers::GetT1AirPlantForSide(Global::AISettings::Side)
            && ai.frame < Global::RoleSettings::Tech::NukeRushScoutSeconds * SECOND) {
            if (TechChain::NukeRush()) {
                CCircuitDef@ silo = ai.GetCircuitDef(TechChain::DefFor("silo"));
                CCircuitUnit@ frame = silo is null ? null : aiBuilderMgr.FindUnfinishedNear(Layout::BaseCentre(),
                    Global::RoleSettings::Tech::ChainAssistRadius, silo);
                // Survey shortly before stockpiling rather than repeatedly
                // replacing scouts while the economy is still funding a silo.
                if (frame is null || frame.GetBuildProgress() < 0.70f)
                    return aiFactoryMgr.Enqueue(TaskS::Wait(false, 3 * SECOND));
            }
            CCircuitDef@ scout = ai.GetCircuitDef(UnitHelpers::GetT1AirScoutForSide(Global::AISettings::Side));
            const int scoutCount = Global::RoleSettings::Tech::NukeRushScouts;
            if (scout !is null && scout.count + aiFactoryMgr.GetPendingRecruitCount(scout) < scoutCount) {
                if (scout.maxThisUnit < scoutCount) scout.maxThisUnit = scoutCount;
                return aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::HIGH, scout, u.GetPos(ai.frame), 64.f));
            }
            // Once the silo stands, filled reconnaissance does not block the
            // ordinary air-constructor / T2-air economic transition.
            if (TechChain::NukeRush()) return aiFactoryMgr.Enqueue(TaskS::Wait(false, 3 * SECOND));
        }
		// Determine side from factory unit name
		string side = UnitHelpers::GetSideForUnitName(facDef.GetName());
		const AIFloat3 pos = u.GetPos(ai.frame);
		float metalIncome = Economy::GetMinMetalIncomeLast10s();
		GenericHelpers::LogUtil("[TECH][Factory] MakeTask called for factory '" + facDef.GetName() + "' (side=" + side + ")", 4);
		// Debug: log current primary factory ids vs this unit
		{
			int uid = u.id;
			int pT1Bot = (Factory::primaryT1BotLab is null ? -1 : Factory::primaryT1BotLab.id);
			int pT2Bot = (Factory::primaryT2BotLab is null ? -1 : Factory::primaryT2BotLab.id);
			int pT1Air = (Factory::primaryT1AirPlant is null ? -1 : Factory::primaryT1AirPlant.id);
			int pT2Air = (Factory::primaryT2AirPlant is null ? -1 : Factory::primaryT2AirPlant.id);
			GenericHelpers::LogUtil("[TECH][Factory] ids: u=" + uid + " pT1Bot=" + pT1Bot + " pT2Bot=" + pT2Bot + " pT1Air=" + pT1Air + " pT2Air=" + pT2Air, 4);
		}
		// Select income gate based on strategy: use rush threshold when SPAM_RUSH is enabled
		const bool isEarlyBotLabExpansionEnabled = Global::RoleSettings::Tech::HasStrategy(Strategy::SPAM_RUSH);
		// D-068: with the experimental system on both gates are at least ExpCombatMetalIncome
		const float botLabGate = Tech_CombatGate(isEarlyBotLabExpansionEnabled ? Global::RoleSettings::Tech::MetalIncomeThresholdForEarlyBotLabExpansion : Global::RoleSettings::Tech::MetalIncomeThresholdForBotLabExpansion);

		const float vehiclePlantGate = Tech_CombatGate(isEarlyBotLabExpansionEnabled ? Global::RoleSettings::Tech::MetalIncomeThresholdForEarlyVehiclePlantExpansion : Global::RoleSettings::Tech::MetalIncomeThresholdForVehiclePlantExpansion);

		GenericHelpers::LogUtil("[TECH][Factory] Strategy gate: EarlyBotLabExpansion=" + (isEarlyBotLabExpansionEnabled ? "on" : "off") + " botLabGate=" + botLabGate + " vehiclePlantGate=" + vehiclePlantGate, 4);

		// Diagnostic: if this is a gantry, explicitly log that we delegate to default
		// (no custom gantry build queue here by design)
		if (UnitHelpers::IsGantryLab(facDef.GetName()))
		{
            // Finish the admitted batch before selecting another. Completion
            // refill re-enters this policy after every product, not every batch.
            IUnitTask@ pending = aiFactoryMgr.GetPendingFactoryTask(u);
            if (pending !is null) return pending;
			GenericHelpers::LogUtil("[TECH][Factory] Gantry detected ('" + facDef.GetName() + "')", 3);
            IUnitTask@ amphib = AmphibiousOps::Produce(u, botLabGate);
            if (amphib !is null) return amphib;
			// If economy is very strong, queue a batch of signature experimentals.
			// D-287: after the late latch the batch is the terrain's heavy (land:
			// Thor-class, amphibious: Titan-class), the other heavy as fallback.
			if (metalIncome > 200.0f)
			{
				IUnitTask @tSig = TechHeavyChoice::Late()
					? TechHeavyChoice::LateBatch(u, side, /*count*/ 5)
					: Factory::EnqueueGantrySignatureBatch(u, side, /*count*/ 5, Task::Priority::HIGH);
				if (tSig !is null)
					return tSig;
			}
			// Fallback: Let default choose heavy/super units to build
			return AmphibiousOps::DefaultFactoryTask(u);
		}

		// Check T1 constructor threshold
		if (UnitHelpers::IsT1BotLab(facDef.GetName()))
		{
			int t1CtorCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1BotConstructors());
			if (t1CtorCount < Global::RoleSettings::Tech::MinimumT1ConstructorBots)
			{
				// Recruit only bot constructors from a bot lab
				array<string> t1BotCtors = UnitHelpers::GetT1BotConstructors(side);
				if (t1BotCtors.length() > 0)
				{
					CCircuitDef @t1Ctor = ai.GetCircuitDef(t1BotCtors[0]);
					if (t1Ctor !is null && t1Ctor.IsAvailable(ai.frame))
					{
						// Recruit a T1 constructor bot
						return aiFactoryMgr.Enqueue(
							TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, t1Ctor, pos, 64.f));
					}
				}
			}
		}

		// D-103 (owner's rule): the T1 air plant makes the air constructor that
		// builds the advanced aircraft plant, while we have none
		// D-109 (owner's rule): and keeps T1AirConstructorTarget of them: more than
		// T1AirReleaseAbove carry the base so the T1 land constructors go forward
		if (facDef.GetName() == UnitHelpers::GetT1AirPlantForSide(side)
			&& (TechChain::AirConstructors() == 0 || TechForward::T1AirCons() < Global::RoleSettings::Tech::T1AirConstructorTarget))
		{
			CCircuitDef @airCon = ai.GetCircuitDef(UnitHelpers::GetT1AirConstructorNameForSide(side));
			if (airCon !is null && airCon.IsAvailable(ai.frame))
			{
				GenericHelpers::LogUtil("[TECH][Factory] " + facDef.GetName() + ": an air constructor for the advanced aircraft plant (D-103)", 1);
				return aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, airCon, pos, 64.f));
			}
		}

		// D-108 (owner's rule): a dedicated air role with no builder to take it is
		// filled first, whatever the bank and the cap
		if (facDef.GetName() == UnitHelpers::GetT2AirPlantForSide(side) && TechBuild::AirRoleVacant())
		{
			CCircuitDef @aca = ai.GetCircuitDef(UnitHelpers::GetT2AirConstructorNameForSide(side));
			if (aca !is null)
			{
				if (aca.maxThisUnit <= aca.count) aca.maxThisUnit = aca.count + 1;
				GenericHelpers::LogUtil("[TECH][Factory] " + facDef.GetName() + ": a T2 air constructor for a vacant dedicated role (D-108)", 1);
				return aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, aca, pos, 64.f));
			}
		}

        IUnitTask@ heavyRush = TechHeavyRush::Produce(u);
        if (heavyRush !is null) return heavyRush;

		// D-103 (owner's rule): T2 constructors whenever the metal bank is over
		// T2ConstructorBankShare of storage, up to T2ConstructorCap (bot and air)
		if (UnitHelpers::IsT2BotLab(facDef.GetName()) || facDef.GetName() == UnitHelpers::GetT2AirPlantForSide(side))
		{
			// D-119 (owner): T2 construction bots at most T2BotConstructorCap; the
			// T2 air constructors (the dedicated roles, D-107) keep T2ConstructorCap
			const bool botLab = UnitHelpers::IsT2BotLab(facDef.GetName());
			const int t2Cons = botLab ? UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotConstructors())
				: UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2AirConstructors());
			const int t2Cap = botLab ? Global::RoleSettings::Tech::T2BotConstructorCap : Global::RoleSettings::Tech::T2ConstructorCap;
			const float stor = aiEconomyMgr.metal.storage;
			const bool bankHigh = stor > 0.0f && aiEconomyMgr.metal.current > Global::RoleSettings::Tech::T2ConstructorBankShare * stor;
			if (bankHigh && t2Cons < t2Cap)
			{
				const string conName = botLab
					? UnitHelpers::GetT2BotConstructors(side)[0] : UnitHelpers::GetT2AirConstructorNameForSide(side);
				CCircuitDef @t2c = ai.GetCircuitDef(conName);
				if (t2c !is null)
				{
					if (t2c.maxThisUnit < t2Cap) t2c.maxThisUnit = t2Cap;
					if (t2c.IsAvailable(ai.frame))
					{
						GenericHelpers::LogUtil("[TECH][Factory] " + facDef.GetName() + ": T2 constructor " + (t2Cons + 1) + " of " + t2Cap
							+ " (bank " + int(aiEconomyMgr.metal.current) + " of " + int(stor) + ") (D-103)", 1);
						return aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, t2c, pos, 64.f));
					}
				}
			}
		}

		// Check T2 constructor threshold
		if (UnitHelpers::IsT2BotLab(facDef.GetName()))
		{
			int t2CtorCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotConstructors());
			if (t2CtorCount < Global::RoleSettings::Tech::MinimumT2ConstructorBots)
			{
				// Recruit only bot constructors from a bot lab
				array<string> t2BotCtors = UnitHelpers::GetT2BotConstructors(side);
				if (t2BotCtors.length() > 0)
				{
					CCircuitDef @t2Ctor = ai.GetCircuitDef(t2BotCtors[0]);
					if (t2Ctor !is null && t2Ctor.IsAvailable(ai.frame))
					{
						// Recruit a T2 constructor bot
						return aiFactoryMgr.Enqueue(
							TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, t2Ctor, pos, 64.f));
					}
				}
			}

			// PRIMARY lab only: fill the income-scaled target, bounded by D-119's
			// hard cap. Other labs remain available for combat. Compact layouts
			// admit mobile support with a smaller bank; opening priorities above
			// and the one-at-a-time recruit path remain unchanged (D-308).
			if (Factory::primaryT2BotLab !is null && u.id == Factory::primaryT2BotLab.id)
			{
				array<string> fastAssist = UnitHelpers::GetFastAssistBots(side);
				int haveAssist = UnitDefHelpers::SumUnitDefCounts(fastAssist);
				float metalCurrent = aiEconomyMgr.metal.current;
				const float assistReserve = CompactEco::Active()
					? Global::RoleSettings::Tech::CompactFastAssistMetalReserve
					: Global::RoleSettings::Tech::FastAssistMetalReserve;
				GenericHelpers::LogUtil(
					"[TECH][Factory] Fast-assist check: have=" + haveAssist + " cap=" + g_fastAssistBotCap +
						" metalCurrent=" + metalCurrent + " side=" + side,
					4);
				if (fastAssist.length() == 0)
				{
					GenericHelpers::LogUtil("[TECH][Factory] No fast-assist unit defined for side=" + side + ", skipping", 4);
				}
				if (g_fastAssistBotCap <= 0)
				{
					GenericHelpers::LogUtil("[TECH][Factory] Fast-assist cap is 0 at current income, skipping", 4);
				}
				if (metalCurrent <= assistReserve)
				{
					GenericHelpers::LogUtil("[TECH][Factory] Metal reserve at/below " + assistReserve + ", skipping fast-assist enqueue", 4);
				}
				if (fastAssist.length() > 0 && haveAssist < g_fastAssistBotCap && metalCurrent > assistReserve)
				{
					string assistName = fastAssist[0];
					CCircuitDef @assistDef = ai.GetCircuitDef(assistName);
					bool avail = (assistDef !is null && assistDef.IsAvailable(ai.frame));
					if (avail)
					{
						GenericHelpers::LogUtil(
							"[TECH][Factory] Enqueue fast-assist bot '" + assistName + "' have=" + haveAssist +
								" cap=" + g_fastAssistBotCap + " metalCurrent=" + metalCurrent + " side=" + side +
								" pos=(" + pos.x + "," + pos.y + "," + pos.z + ")",
							3);
						return aiFactoryMgr.Enqueue(
							TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, assistDef, pos, 64.f));
					}
					else
					{
						const string defName = (assistDef is null ? "null" : assistDef.GetName());
						string availDetail = "false";
						int maxUnits = -1;

						if (assistDef is null)
						{
							availDetail = "null_def";
						}
						else
						{
							maxUnits = assistDef.maxThisUnit;
							if (!assistDef.IsAvailable(ai.frame))
							{
								availDetail = "not_available";
							}
						}

						GenericHelpers::LogUtil(
							"[TECH][Factory][WARN] Fast-assist NOT enqueued: assistName='" + assistName + "' assistDef=" + defName +
								" available=" + availDetail +
								" maxUnits=" + maxUnits +
								" ai.frame=" + ai.frame +
								" fastAssistList.len=" + fastAssist.length() +
								" haveAssist=" + haveAssist +
								" cap=" + g_fastAssistBotCap +
								" metalCurrent=" + metalCurrent +
								" side=" + side +
								" pos=(" + pos.x + "," + pos.y + "," + pos.z + ")" +
								" primaryT2BotLab.id=" + (Factory::primaryT2BotLab is null ? -1 : Factory::primaryT2BotLab.id) +
								" primaryT1BotLab.id=" + (Factory::primaryT1BotLab is null ? -1 : Factory::primaryT1BotLab.id),
							2);
						// Fast-assist not available now; fall through to allow other factory logic to proceed
					}
				}
				else if (fastAssist.length() > 0 && haveAssist >= g_fastAssistBotCap)
				{
					GenericHelpers::LogUtil("[TECH][Factory] Fast-assist at/over cap (" + haveAssist + "/" + g_fastAssistBotCap + ")", 4);
				}
			}
		}

		// After bot lab logic: maintain air constructor counts from aircraft plants (T1/T2)
		// Only the PRIMARY T1/T2 aircraft plant should perform this maintenance (mirror bot lab checks)
		// If either tier's air constructor count is below 50, prioritize making construction aircraft
		{
			// Current counts per tier
			int t1AirCtorCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1AirConstructors());
			// T2 air constructors list
			int t2AirCtorCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2AirConstructors());

			const string facName = facDef.GetName();
			// If this factory is the PRIMARY T1 aircraft plant and we're under 50 T1 air constructors, build one
			if (Factory::primaryT1AirPlant !is null && u.id == Factory::primaryT1AirPlant.id && t1AirCtorCount < 100)
			{
				string ctorName = UnitHelpers::GetT1AirConstructorNameForSide(side);
				CCircuitDef @ctorDef = ai.GetCircuitDef(ctorName);
				if (ctorDef !is null && ctorDef.IsAvailable(ai.frame))
				{
					GenericHelpers::LogUtil("[TECH][Factory] T1 air ctor below target (" + t1AirCtorCount + "), enqueue '" + ctorName + "'", 3);
					return aiFactoryMgr.Enqueue(
						TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, ctorDef, pos, 64.f));
				}
			}

			// If this factory is the PRIMARY T2 aircraft plant and we're under 50 T2 air constructors, build one
			// D-080: T2 construction aircraft are the mobile build power from +200 metal, one per PlanAirConstructorPerMetal
			if (Factory::primaryT2AirPlant !is null && u.id == Factory::primaryT2AirPlant.id && t2AirCtorCount < TechPlan::AirConstructorsWanted())
			{
				string ctorName2 = UnitHelpers::GetT2AirConstructorNameForSide(side);
				CCircuitDef @ctorDef2 = ai.GetCircuitDef(ctorName2);
				if (ctorDef2 !is null && ctorDef2.IsAvailable(ai.frame))
				{
					GenericHelpers::LogUtil("[TECH][Factory] T2 air ctor below target (" + t2AirCtorCount + "), enqueue '" + ctorName2 + "'", 3);
					return aiFactoryMgr.Enqueue(
						TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, ctorDef2, pos, 64.f));
				}
			}
		}
        IUnitTask@ amphib = AmphibiousOps::Produce(u, botLabGate);
        if (amphib !is null) return amphib;
        // D-121: an island TECH's land labs make no combat units once the harbour
		// runs (they cannot leave the island); constructors above still come
		if (TechHarbour::HoldsLandCombat(facDef.GetName()))
			return aiFactoryMgr.Enqueue(TaskS::Wait(false, 10 * SECOND));
		GenericHelpers::LogUtil("[TECH][Factory] Checking bot lab for scout/fast bot enqueue", 4);
		// float metalIncome = Global::Economy::GetMetalIncome();
		// After builder production priorities, if this is a T1 bot lab and eco is strong, enqueue a block of scouts
		if (UnitHelpers::IsT1BotLab(facDef.GetName()))
		{

			if (metalIncome >= botLabGate)
			{
				const bool landLocked = Global::Map::LandLocked;
				string unitName;

				if (landLocked)
				{
					// Use amphibious T1 AA bots for landlocked starts
					unitName = UnitHelpers::GetT1AntiAirBotForSide(side);
					GenericHelpers::LogUtil("[TECH][Factory] LandLocked start: using amphib AA bot '" + unitName + "' instead of ground scout", 3);
				}
				else
				{
					// Use normal T1 ground scouts
					unitName = UnitHelpers::GetT1BotScoutForSide(side);
				}

				GenericHelpers::LogUtil("[TECH][Factory] Eco>=gate: enqueue 10 '" + unitName + "' from T1 bot lab (gate=" + botLabGate + ")", 3);
				IUnitTask @last = Tech_EnqueueUnitBatch(unitName, 10, pos);
				if (last !is null)
					return last;
			}
		}

		// After builder production priorities, if this is a T2 bot lab and eco is strong, enqueue a block of units.
		// If the current start point is land-locked by water (Global::Map::LandLocked == true), prefer amphibious T2 units
		// instead of ground-only fast T2 bots, since ground T2 is less effective on water-heavy maps.
		if (UnitHelpers::IsT2BotLab(facDef.GetName()))
		{
			GenericHelpers::LogUtil("[TECH][Factory] Checking T2 bot lab for fast T2 bot/amphib enqueue", 4);
			if (metalIncome >= botLabGate)
			{
				const bool landLocked = Global::Map::LandLocked;
				string unitName;
				if (landLocked)
				{
					// Amphibious choices per side
					unitName = UnitHelpers::GetAmphibiousT2BotForSide(side);
					GenericHelpers::LogUtil("[TECH][Factory] LandLocked start: using amphib unit '" + unitName + "' instead of ground fast T2", 3);
				}
				else
				{
					// Use canonical ground fast T2 bots consistent with caps and units.json
					array<string> fastBots = UnitHelpers::GetFastT2Bots(side);
					if (fastBots.length() > 0)
					{
						unitName = fastBots[0];
					}
				}

				GenericHelpers::LogUtil("[TECH][Factory] Eco>=gate: enqueue 10 '" + unitName + "' from T2 bot lab (gate=" + botLabGate + ")", 3);
                // The shared wave producer above owns its bounded queue; do not add a legacy ten-unit batch.
                if (AmphibiousOps::Active() && AmphibiousOps::Kind(ai.GetCircuitDef(unitName))>=0)
                    return aiFactoryMgr.Enqueue(TaskS::Wait(false, 5 * SECOND));
				IUnitTask @last2 = Tech_EnqueueUnitBatch(unitName, 10, pos);
				if (last2 !is null)
					return last2;
			}
		}

		// After builder production priorities, if this is a T1 vehicle plant and eco is strong, enqueue a block of scouts
		if (UnitHelpers::IsT1VehicleLab(facDef.GetName()))
		{
			if (metalIncome >= vehiclePlantGate)
			{
				string unitName = UnitHelpers::GetT1VehicleScoutForSide(side);
				GenericHelpers::LogUtil("[TECH][Factory] Eco>=gate: enqueue 10 '" + unitName + "' from T1 vehicle plant (gate=" + vehiclePlantGate + ")", 3);
				IUnitTask @last = Tech_EnqueueUnitBatch(unitName, 10, pos);
				if (last !is null)
					return last;
			}
		}

		// After builder production priorities, if this is a T2 vehicle plant and eco is strong, enqueue a block of units.
		if (UnitHelpers::IsT2VehicleLab(facDef.GetName()))
		{
			if (metalIncome >= vehiclePlantGate)
			{
				string unitName = UnitHelpers::GetMainBattleTankForSide(side);

				GenericHelpers::LogUtil("[TECH][Factory] Eco>=gate: enqueue 10 '" + unitName + "' from T2 vehicle plant (gate=" + vehiclePlantGate + ")", 3);
				IUnitTask @last2 = Tech_EnqueueUnitBatch(unitName, 10, pos);
				if (last2 !is null)
					return last2;
			}
		}
		// D-119: with its T2 constructors and fast assist bots capped, the advanced
		// bot lab reaches this fallback under the combat gate, and native's choice is
		// combat (played: Pyros at +91, INV-010): it waits for the gate instead
		if (UnitHelpers::IsT2BotLab(facDef.GetName()) && metalIncome < botLabGate)
			return aiFactoryMgr.Enqueue(TaskS::Wait(false, 5 * SECOND));
		GenericHelpers::LogUtil("[TECH][Factory] No custom tasks applicable; using DefaultMakeTask for factory '" + facDef.GetName() + "'", 4);
		return AmphibiousOps::DefaultFactoryTask(u);
	}

	/**************************************************************************
	 BASE LAYOUT

	 Pushed once at setup (LayoutHelpers::ApplyForRole), before the native
	 chooser places the start factory. Native code plans the exact factory
	 clusters and the full/half mature-economy module; script selects candidates
	 and controls progression. Settings:
	 Global::RoleSettings::Tech::Layout*. Doc: doc/layout-design.md.
	 **************************************************************************/
	void Tech_LayoutPlan(const string &in side)
	{
		Layout::Plan(side);
	}

	string Tech_SelectFactoryHandler(const AIFloat3& in pos, bool isStart, bool isReset)
	{
		GenericHelpers::LogUtil("[TECH] Enter Tech_SelectFactoryHandler", 4);

		if (isStart)
		{
			if (Global::Map::NearestMapStartPosition !is null)
			{
				// Prefer configured map role weights; fallback to role-appropriate default if none found
				// D-102 (owner's rule): when our last factory is gone (isReset) the build
				// sequence decides: no lab, or the advanced lab before a T1 lab
				const string fac = isReset ? TechBuild::ResetFactory()
					: FactoryHelpers::SelectStartFactoryForRole(Global::AISettings::Role, Global::AISettings::Side);
				if (isReset && fac == "") return "none";
				// D-101 (owner's rule): while a construction turret stands the new one is
				// placed by the layout (played: the rebuilt T1 lab went back into its old footprint)
				if (isReset && fac != "") aiTerrainMgr.SetResetFactorySlot(Layout::ReserveFactorySite(ai.GetCircuitDef(fac)));
				return fac;
			}
			else
			{
				GenericHelpers::LogUtil("[Tech_SelectFactoryHandler] nearestMapPosition is null", 2);
				// Even if nearest start is unavailable, attempt a safe fallback
				return FactoryHelpers::GetFallbackStartFactoryForRole(Global::AISettings::Role, Global::AISettings::Side);
			}
		}

		return "";
	}

	bool Tech_AiIsSwitchTime(int lastSwitchFrame)
	{
		GenericHelpers::LogUtil("[TECH] Enter Tech_AiIsSwitchTime", 4);

		int interval = (20 * SECOND);
		return (lastSwitchFrame + interval) <= ai.frame;
	}

	bool Tech_AiIsSwitchAllowed(const CCircuitDef @facDef, float armyCost, int factoryCount, float metalCurrent, bool&out assistRequired)
	{
		GenericHelpers::LogUtil("[TECH] Enter Tech_AiIsSwitchAllowed", 4);

		float metalIncome = aiEconomyMgr.metal.income;
		bool switchAllowed = metalIncome > 100.0f;

		// Always disable factory assist until at least one gantry exists (land or water)
		int landGantryCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllLandGantries());
		int waterGantryCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllWaterGantries());
		int totalGantryCount = landGantryCount + waterGantryCount;

		// Note: assistRequired is the out parameter; ensure we set it before returning
		// If no gantries exist yet, force assist off regardless of switchAllowed.
		assistRequired = (totalGantryCount < 1) ? false : (!switchAllowed);

		GenericHelpers::LogUtil(
			"[TECH] switch_allowed=" + (switchAllowed ? "true" : "false") +
				" assist_required=" + (assistRequired ? "true" : "false") +
				" gantries_total=" + totalGantryCount + " (land=" + landGantryCount + ", water=" + waterGantryCount + ")",
			2);

		return switchAllowed;
	}

	int Tech_MakeSwitchInterval()
	{
		GenericHelpers::LogUtil("[TECH] Enter Tech_MakeSwitchInterval", 4);
		return AiRandom(Global::RoleSettings::Tech::MinAiSwitchTime, Global::RoleSettings::Tech::MaxAiSwitchTime) * SECOND;
	}

	void Tech_FactoryAiUnitAdded(CCircuitUnit @unit, Unit::UseAs usage)
	{
		if (unit is null)
		{
			GenericHelpers::LogUtil("[TECH] AiUnitAdded: unit=<null>", 2);
			return;
		}
		GenericHelpers::LogUtil("[TECH] Enter Tech_FactoryAiUnitAdded", 4);
		// Lab tracking is now centralized in Factory::AiUnitAdded

		// When the first T2 bot lab is created, raise T1 metal storage cap to 1 (if previously 0)
		if (!hasRaisedT1MetalStorageCap)
		{
			const CCircuitDef @cdef = unit.circuitDef;
			if (cdef !is null)
			{
				string uname = cdef.GetName();
				if (UnitHelpers::IsT2BotLab(uname))
				{
					int t2LabCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotLabs());
					if (t2LabCount <= 1)
					{
						array<string> t1Metal = UnitHelpers::GetAllT1MetalStorages();
						UnitHelpers::BatchApplyUnitCaps(t1Metal, 1);
						hasRaisedT1MetalStorageCap = true;
						GenericHelpers::LogUtil("[TECH][Limits] First T2 bot lab created; raising T1 metal storage cap to 1", 2);
						// Re-apply merged map+role limits so map constraints win
						if (Global::Map::MergedUnitLimits.getKeys().length() > 0)
						{
							GenericHelpers::LogUtil("[TECH][Limits] Re-applying merged map+role unit limits after T1 metal storage unlock", 4);
							UnitHelpers::ApplyUnitLimits(Global::Map::MergedUnitLimits);
						}
					}
				}
			}
		}
	}

	void Tech_FactoryAiUnitRemoved(CCircuitUnit @unit, Unit::UseAs usage)
	{
		GenericHelpers::LogUtil("[TECH] Enter Tech_FactoryAiUnitRemoved", 4);
		Lifecycle::Forget(unit);   // D-076
		// Lab tracking is now centralized in Factory::AiUnitRemoved
	}

	/******************************************************************************

	MILITARY HOOKS

	******************************************************************************/

	IUnitTask @Tech_MilitaryAiMakeTask(CCircuitUnit @u)
	{
        if (TechChain::nukeOpening && u !is null
            && u.circuitDef.GetName() == UnitHelpers::GetT1AirScoutForSide(Global::AISettings::Side)) {
            array<AIFloat3> route = Lanes::ScriptStarts(true);
            if (route.length() > 0) {
                CRouteTask@ recon = cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
                if (recon !is null) {
                    recon.SetAirControl(true); recon.SetPatrol(true);
                    u.SetIdleMode(0); u.SetFireState(0);
                    recon.SetRoute(route);
                    GenericHelpers::LogUtil("[TECH][NukeRush] scout " + u.id + " surveys enemy starts", 1);
                    return recon;
                }
            }
        }
		// D-121: an island TECH's fleet runs its yard's route to the enemy
		if (u !is null && u.circuitDef !is null && TechHarbour::IsHarbourUnit(u.circuitDef))
		{
			IUnitTask @fleet = TechHarbour::FleetTask(u);
			if (fleet !is null) return fleet;
		}
		float metalIncome = Economy::GetMinMetalIncomeLast10s();

		// Check if this is a nuclear silo and we haven't targeted the farthest tech spot yet
		const CCircuitDef @def = (u is null ? null : u.circuitDef);
		if (def !is null)
		{
			string name = def.GetName();
			array<string> silos = UnitHelpers::GetAllNukeSilos();
			if (silos.find(name) >= 0)
			{
				if (!hasTargetedFarthestTech)
				{
					// Find farthest Tech spot
					AIFloat3 startPos = Global::Map::StartPos;
					float maxDistSq = -1.0f;
					AIFloat3 targetPos;
					bool found = false;

					for (uint i = 0; i < Global::Map::Config.StartSpots.length(); ++i)
					{
						const StartSpot @spot = Global::Map::Config.StartSpots[i];
						if (spot.aiRole == AiRole::TECH)
						{
							float d = MapHelpers::SqDist(startPos, spot.pos);
							if (d > maxDistSq)
							{
								maxDistSq = d;
								targetPos = spot.pos;
								found = true;
							}
						}
					}

					if (found)
					{
						// Give the silo its native CSuperTask and point it at the spot with
						// CSuperTask::SetTargetPos: ExecuteAttack then sends the same
						// ai_super_intention / ai_super_fire rules messages and the attack-ground
						// order itself, every reload, until Tech_UpdateNukeFirstStrike clears the
						// override after NukeFirstStrikeOverrideSeconds.
						//
						// This used to return aiFactoryMgr.Enqueue(TaskS::Wait(...)): a task owned
						// by the FACTORY manager handed to a MILITARY unit. IUnitTask::AssignTo only
						// removes the unit from its own manager's idle task, so the silo stayed in
						// the military idle list, was later also given a CSuperTask, and when the
						// factory Wait timed out its Stop() re-parented the unit to the factory idle
						// task while the super task still listed it. When the silo died only the
						// current task was told; the super task kept a freed pointer and crashed in
						// CSuperTask::ExecuteAttack (2026-09-18, f=37389). ITaskModule::AssignTask
						// now refuses tasks of another manager as well.
						IUnitTask @siloTask = aiMilitaryMgr.DefaultMakeTask(u);
						IFighterTask @fighterTask = cast<IFighterTask>(siloTask);
						CSuperTask @superTask = (fighterTask is null) ? null : cast<CSuperTask>(fighterTask);
						if (superTask !is null)
						{
							hasTargetedFarthestTech = true;
							superTask.SetTargetPos(targetPos);
							@g_nukeFirstStrikeTask = superTask;
							g_nukeFirstStrikeUntilFrame = ai.frame + Global::RoleSettings::Tech::NukeFirstStrikeOverrideSeconds * SECOND;
							GenericHelpers::LogUtil("[TECH] Nuke Silo " + u.id + " first strike at farthest Tech spot (distSq=" + maxDistSq + ")", 2);
						}
						return siloTask;
					}
				}
			}
		}

		if (metalIncome < 50.0f)
		{
			return null;
		}

		return aiMilitaryMgr.DefaultMakeTask(u);
	}

	void Tech_AiMakeDefence(int cluster, const AIFloat3& in pos)
	{
		// The experimental system (D-066) defends its base itself: one light
		// laser and one light AA after the first turret (TechBuild::Defence).
		// Native's porc chain - up to junos and launchers - is not asked.
		if (Global::RoleSettings::Tech::ExperimentalBuild)
			return;
		// float metalIncome = Economy::GetMetalIncome();
		float metalIncome = Economy::GetMinMetalIncomeLast10s();

		if (metalIncome < Global::RoleSettings::Tech::MilitaryDefenceMetalIncomeThreshold)
		{
			// Shared porcupine policy (Military::Porc) decides how much, native code places it
			Military::Porc::MakeDefence(cluster, pos);
		}
	}

	/******************************************************************************

	BUILDER HOOKS

	******************************************************************************/

	void Tech_BuilderAiUnitAdded(CCircuitUnit @unit, Unit::UseAs usage)
	{
		Invariants::OnUnitAdded(unit);   // D-076: INV-001
		// Donation hook: when the 3rd T2 constructor is created, donate it to the team leader
		if (unit is null)
			return;
		const CCircuitDef @d = unit.circuitDef;
		if (d is null)
			return;

		// Add BASE attribute to T1 bot constructors, T2 bot constructors, and T2 fast assist bots
		// This ensures they stay near the base or are treated as base defenders/builders
		string name = d.GetName();
		bool isT1BotCtor = (UnitHelpers::GetAllT1BotConstructors().find(name) >= 0);
		bool isT2BotCtor = UnitHelpers::IsT2BotConstructor(name);
		bool isFastAssist = (UnitHelpers::GetAllFastAssistBots().find(name) >= 0);

		if (isT1BotCtor || isT2BotCtor || isFastAssist)
		{
			GenericHelpers::LogUtil("[TECH] Adding BASE attribute to builder: " + name + " id=" + unit.id, 3);
			unit.AddAttribute(Unit::Attr::BASE.type);
		}

		Team::Donation::OnConstructorBuilt(unit);   // a requested constructor goes to its requester; the rest are ours
		if (Team::IsT2Constructor(d))
		{
			aiFactoryMgr.isAssistRequired = false;
		}
	}

	void Tech_BuilderAiUnitRemoved(CCircuitUnit @unit, Unit::UseAs usage)
	{ /* other bookkeeping moved to Builder::AiUnitRemoved */
        if (unit !is null) {
            EcoPlanner::conversionReasons.delete("" + unit.id);
            floatAssistReasons.delete("" + unit.id);
        }
	}

	IUnitTask @Tech_BuilderAiMakeTask(CCircuitUnit @u)
	{
		GenericHelpers::LogUtil("[TECH] Enter Tech_BuilderAiMakeTask", 4);
		// The hard split (D-066): the experimental system is a different
		// sequence and never reaches the stock rungs below.
		if (Global::RoleSettings::Tech::ExperimentalBuild)
		{
			IUnitTask @tExp = TechBuild::MakeTask(u);
			if (tExp !is null)
				return tExp;
			return aiBuilderMgr.Enqueue(TaskB::Wait(3 * SECOND));
		}
		// Pre-create a default task to return if no other rules trigger
		IUnitTask @defaultTask = Builder::MakeDefaultTaskWithLog(u.id, "TECH");
		// If the default task is a BUILDER and its build type is MEX/MEXUP/GEO/GEOUP, don't override it; return immediately.
		{
			IBuilderTask @defaultBuilderTask = cast<IBuilderTask>(defaultTask);
			if (defaultBuilderTask !is null)
			{
				Task::BuildType dbt = Task::BuildType(defaultBuilderTask.GetBuildType());

				// Special handling for MEXUP: only allow if we built the underlying MEX
				if (dbt == Task::BuildType::MEXUP)
				{
					if (Economy::MexTracker::IsOwnedMex(defaultBuilderTask.GetBuildPos()))
					{
						GenericHelpers::LogUtil("[TECH] defaultTask (BUILDER) is MEXUP for owned MEX; upgrading immediately.", 3);
						string side = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
						string t2MexName = UnitHelpers::GetT2MexNameForSide(side);
						CCircuitDef @upgradeDef = ai.GetCircuitDef(t2MexName);
						if (upgradeDef !is null)
						{
							return aiBuilderMgr.Enqueue(TaskB::Spot(Task::BuildType::MEXUP, Task::Priority::NOW, upgradeDef, defaultBuilderTask.GetBuildPos(), -1));
						}
						// return defaultTask;
					}
					else
					{
						GenericHelpers::LogUtil("[TECH] defaultTask (BUILDER) is MEXUP for unowned/ally MEX; redirecting to owned MEX", 3);

						// Find nearest owned Mex to upgrade using MexTracker
						AIFloat3 unitPos = u.GetPos(ai.frame);
						AIFloat3 bestPos = Economy::MexTracker::GetNearestNonUpgradedMex(unitPos);

						if (bestPos.x != -1)
						{
							// Get T2 Mex Def for upgrade
							string side = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
							string t2MexName = UnitHelpers::GetT2MexNameForSide(side);
							CCircuitDef @upgradeDef = ai.GetCircuitDef(t2MexName);

							if (upgradeDef !is null)
							{
								GenericHelpers::LogUtil("[TECH] Redirecting MEXUP to nearest owned Mex at (" + bestPos.x + "," + bestPos.z + ")", 3);
								return aiBuilderMgr.Enqueue(TaskB::Spot(Task::BuildType::MEXUP, Task::Priority::NOW, upgradeDef, bestPos, -1));
							}
						}

						// return null;
					}
				}

				if (dbt == Task::BuildType::MEX || dbt == Task::BuildType::GEO || dbt == Task::BuildType::GEOUP)
				{
					GenericHelpers::LogUtil("[TECH] defaultTask (BUILDER) is MEX/GEO/GEOUP; returning immediately.", 3);
					return defaultTask;
				}
			}
		}

		// Log economy snapshot for task decisions
		// float metalIncome = Global::Economy::MetalIncome;
		// float energyIncome = Global::Economy::EnergyIncome;
		float metalIncome = Economy::GetMinMetalIncomeLast10s();
		float energyIncome = Economy::GetMinEnergyIncomeLast10s();

		GenericHelpers::LogUtil("[TECH] Econ snapshot metalIncome=" + metalIncome + " energyIncome=" + energyIncome, 2);

		const CCircuitDef @udef = (u is null ? null : u.circuitDef);

		// Turrets and every economy structure come from the planner's one
		// next-building function (EcoPlanner::Decide, D-063), reached through
		// the commander and constructor branches below; nothing is placed
		// outside the turret box.

		bool isCommander = UnitHelpers::IsCommander(udef);

		if (isCommander)
		{
			// return null;
			return Tech_Commander_AiMakeTask(u, defaultTask, metalIncome);
		}
		GenericHelpers::LogUtil("[TECH] Not a commander, checking constructor tier", 4);

		int constructorTier = UnitHelpers::GetConstructorTier(udef);

		// Check if we have T2 constructors but un-upgraded mexes near start
		if (constructorTier == 2)
		{
			// Count total T2 mexes globally
			array<string> t2Mexes = UnitHelpers::GetAllT2Mexes();
			int totalT2MexCount = UnitDefHelpers::SumUnitDefCounts(t2Mexes);

			if (totalT2MexCount < 3)
			{
				const float checkRadius = 600.0f;
				const AIFloat3 startPos = Global::Map::StartPos;

				// Count owned mexes within range of start position
				int nearbyOwnedMexCount = Economy::MexTracker::GetOwnedMexCountInRange(startPos, checkRadius);

				// If we have fewer T2 mexes than owned mexes near start, assume start mexes aren't fully upgraded
				// and move the builder to the nearest start mex to wait/prioritize upgrades.
				if (totalT2MexCount < nearbyOwnedMexCount)
				{

					AIFloat3 unitPos = u.GetPos(ai.frame);
					AIFloat3 bestPos = Economy::MexTracker::GetNearestNonUpgradedMexInRange(unitPos, startPos, checkRadius);

					if (bestPos.x != -1)
					{
						GenericHelpers::LogUtil("[TECH] T2 Constructor available but local mexes not upgraded (T2Mex=" + totalT2MexCount + " < LocalOwned=" + nearbyOwnedMexCount + "). Moving to nearest mex at (" + bestPos.x + "," + bestPos.z + ")", 3);
						string side = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
						string t2MexName = UnitHelpers::GetT2MexNameForSide(side);
						CCircuitDef @upgradeDef = ai.GetCircuitDef(t2MexName);

						if (upgradeDef !is null)
						{
							return aiBuilderMgr.Enqueue(TaskB::Spot(Task::BuildType::MEXUP, Task::Priority::NOW, upgradeDef, bestPos, -1));
						}
					}
					// return null;
				}
			}
		}

		if (constructorTier == 1)
		{
			IUnitTask @recycleTask = Recycle(u, metalIncome);
			if (recycleTask !is null)
			{
				GenericHelpers::LogUtil("[TECH] Recycling task assigned", 2);
				return recycleTask;
			}

			GenericHelpers::LogUtil("[TECH] Attempt Tier 1 Build Tasks", 4);

			// Route T1 constructors by movement type: bots vs aircraft vs others
			if (UnitHelpers::IsAirConstructor(udef))
			{
				return Tech_T1AirConstructor_AiMakeTask(u, metalIncome, energyIncome, defaultTask);
			}
			if (UnitHelpers::IsT1BotConstructor(udef.GetName()))
			{
				return Tech_T1BotConstructor_AiMakeTask(u, metalIncome, energyIncome, defaultTask);
			}

			// Fallback: use the pre-created default task for non-bot T1 constructors (e.g., vehicles/ships)
			return defaultTask;
		}

		// Otherwise do normal selection (and we simply won't accept stray factory tasks)
		// Before falling back, if this is an extra T2 constructor assigned as guard, enforce it
		if (constructorTier == 2)
		{
			GenericHelpers::LogUtil("[TECH] Attempt Tier 2 Build Tasks", 4);
			string ctorName = udef.GetName();
			bool isEnergyFull = aiEconomyMgr.isEnergyFull;
			bool isEnergyLessThan90Percent = aiEconomyMgr.energy.current < aiEconomyMgr.energy.storage * Global::RoleSettings::Tech::EnergyStorageLowPercent;
			float metalCurrent = aiEconomyMgr.metal.current;

			// Route T2 constructors by movement type: bots vs aircraft vs others
			if (UnitHelpers::IsAirConstructor(udef))
			{
				return Tech_T2AirConstructor_AiMakeTask(u, isEnergyFull, metalIncome, energyIncome, metalCurrent, isEnergyLessThan90Percent, defaultTask);
			}
			if (UnitHelpers::IsT2BotConstructor(ctorName))
			{
				GenericHelpers::LogUtil("[TECH] T2 Bot constructor making task: " + ctorName + " id=" + u.id, 2);
				return Tech_T2BotConstructor_AiMakeTask(u, isEnergyFull, metalIncome, energyIncome, metalCurrent, isEnergyLessThan90Percent, defaultTask);
			}
			if (UnitHelpers::IsFastAssistBot(ctorName))
			{
				GenericHelpers::LogUtil("[TECH] Fast-assist bot making task: " + ctorName + " id=" + u.id, 2);
				// Use a dedicated helper for fast-assist builders so their behavior can
				// diverge from normal T2 bot constructors if needed.
				return Tech_T2FastAssistBotConstructor_AiMakeTask(u, isEnergyFull, metalIncome, energyIncome, metalCurrent, isEnergyLessThan90Percent, defaultTask);
			}

			// Fallback: use the pre-created default task for non-bot T2 constructors (e.g., vehicles/ships)
			return defaultTask;
		}

		// Allow null to propagate; Builder::AiMakeTask will fallback to DefaultMakeTask if needed
		GenericHelpers::LogUtil("[TECH] No role-specific task; using pre-created default", 2);
		return defaultTask;
	}

	void Tech_BuilderAiTaskAdded(IUnitTask @task)
	{
		GenericHelpers::LogUtil("[TECH] Enter Tech_BuilderAiTaskAdded", 4);
		if (task is null)
			return;

		// MexTracker bookkeeping is done role-independently in Builder::AiTaskAdded.
		IBuilderTask @builderTask = cast<IBuilderTask>(task);
		if (builderTask !is null && Task::BuildType(builderTask.GetBuildType()) == Task::BuildType::MEXUP)
		{
			GenericHelpers::LogUtil("[TECH] AiTaskAdded: MEX upgrade started", 2);
		}
	}

	void Tech_BuilderAiTaskRemoved(IUnitTask @task, bool done)
	{
		GenericHelpers::LogUtil("[TECH] Enter Tech_BuilderAiTaskRemoved", 4);
		if (task is null)
			return;

		IBuilderTask @builderTask = cast<IBuilderTask>(task);
		if (builderTask !is null)
		{
			Task::BuildType bt = Task::BuildType(builderTask.GetBuildType());
            if (done && bt == Task::BuildType::ENERGY && builderTask.buildDef !is null
                && builderTask.buildDef.GetName() == TechChain::DefFor("afus"))
                aiTerrainMgr.SetLayoutInt("tech.heavy.afus-completed", 1);

			// MexTracker bookkeeping is done role-independently in Builder::AiTaskRemoved.
			if (bt == Task::BuildType::MEXUP)
			{
				GenericHelpers::LogUtil("[TECH] AiTaskRemoved: MEX upgrade " + (done ? "completed" : "aborted"), 2);
			}
		}
	}

	/******************************************************************************

	ECONOMY LOGIC

	******************************************************************************/

	void Tech_IncomeBuilderLimits(float metalIncome)
	{
		GenericHelpers::LogUtil("[TECH] Enter Tech_IncomeBuilderLimits", 4);

		// Determine cap: 35 metal income per lab (e.g., 70 -> 2 labs)
		int rezBotCap = 1 * int(metalIncome / 20.0f);
		if (rezBotCap < 5)
			rezBotCap = 1;

		string side = Global::AISettings::Side;

		array<string> rezList = UnitHelpers::GetRezBots(side);
		UnitHelpers::BatchApplyUnitCaps(rezList, rezBotCap);
		int rezCount = UnitDefHelpers::SumUnitDefCounts(rezList);
		GenericHelpers::LogUtil("[TECH][Limits] RezBots cap=" + rezBotCap + " current=" + rezCount + " side=" + side, 4);

		// D-308: compact banks need mobile support sooner. Scalar work only in
		// the existing economy callback; no new scans, timers or cached state.
		const float assistIncomeScale = CompactEco::Active()
			? Global::RoleSettings::Tech::CompactFastAssistIncomeScale : 1.0f;
		g_fastAssistBotCap = TechEconomyMath::FastAssistTarget(metalIncome, assistIncomeScale,
			TechChain::Active(), Global::RoleSettings::Tech::FastAssistBotCap);

		array<string> faList = UnitHelpers::GetFastAssistBots(side);
		UnitHelpers::BatchApplyUnitCaps(faList, g_fastAssistBotCap);
		int faCount = UnitDefHelpers::SumUnitDefCounts(faList);
		GenericHelpers::LogUtil("[TECH][Limits] FastAssist cap=" + g_fastAssistBotCap + " current=" + faCount + " side=" + side, 4);

		// T1 builder cap via economic helper; honor min and global max
		int t1BuilderCap = EconomyHelpers::CalculateT1BuilderCap(
			/*metalIncome*/ metalIncome,
			/*minCap*/ 5,
			/*maxCap*/ Global::RoleSettings::Tech::MaxT1Builders);

		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetT1LandBuilders(side), t1BuilderCap);

		// T2 builder cap via economic helper; honor min and global max
		int t2BuilderCap = EconomyHelpers::CalculateT2BuilderCap(
			/*metalIncome*/ metalIncome,
			/*minCap*/ 3,
			/*maxCap*/ Global::RoleSettings::Tech::MaxT2Builders);

		UnitHelpers::BatchApplyUnitCaps(UnitHelpers::GetT2LandBuilders(side), t2BuilderCap);
		// D-119: the T2 construction bots' hard cap, whatever raised it
		{
			array<string> t2Bots = UnitHelpers::GetAllT2BotConstructors();
			for (uint i = 0; i < t2Bots.length(); ++i) {
				CCircuitDef@ d = ai.GetCircuitDef(t2Bots[i]);
				if (d !is null && d.maxThisUnit > Global::RoleSettings::Tech::T2BotConstructorCap) d.maxThisUnit = Global::RoleSettings::Tech::T2BotConstructorCap;
			}
		}

		// Ensure merged map+role limits are reapplied after dynamic economy-based caps
		if (Global::Map::MergedUnitLimits.getKeys().length() > 0)
		{
			GenericHelpers::LogUtil("[TECH][Limits] Re-applying merged map+role unit limits (economy update)", 4);
			UnitHelpers::ApplyUnitLimits(Global::Map::MergedUnitLimits);
		}
		TechHarbour::ReapplyCaps();   // D-121: the harbour's own units stay open
	}

	/******************************************************************************

	COMMANDER LOGIC

	******************************************************************************/

	// Turret assist priority (D-065). Static builders never walk, so "in
	// reach" is decided natively from the turret's build distance and the
	// target's radius. Order: any reclaim of ours in reach; then the first
	// structure under construction in reach of: advanced converter, turret,
	// advanced fusion, T1 converter, fusion, advanced solar, solar, wind,
	// then the other economy structures (storages, mex); null lets native's
	// default assist pick whatever else is in range.
	string Tech_T1MexName(const string &in side)
	{
		if (side == "cortex") return "cormex";
		if (side == "legion") return "legmex";
		return "armmex";
	}

	// D-289 (owner: "if nothing in range is worth assisting that is high
	// priority, the fallback should be factory assist"): one ladder for every
	// TECH construction turret, asked from the factory side (Tech_FactoryAiMakeTask:
	// turrets are the native factory manager's assistants, D-119) and from the
	// builder side (rows turret.assist, turret.any, turret.factory, turret.wait,
	// after a reclaim pull moved the turret). In order:
	//   1 a reclaim of ours in reach the D-290 gate allows (builder side only;
	//     PullTurrets moves factory-side turrets onto a reclaim)
	//   2 high-priority frames in reach: the nuke opening's projects; else the
	//     advanced fusion while the converters starve (D-107), the chain's current
	//     dear frame, the advanced lab, the gantry, the T1 lab, then the D-065
	//     economy order
	//   3 any frame of ours in reach (exact: build distance + its model radius)
	//   4 assist a producing, non-spam, non-retiring factory in reach
	//      (Tech_TurretFactoryAssist)
	//   then wait (builder side) or native's default (repair, feature reclaim, wait).
	// Cost per ask: FindReclaimTargetFor O(reclaims); one FindUnfinishedNear O(N)
	// at build distance + TurretFrameMaxRadius, cached per (turret, frame) and
	// shared by steps 2 and 3; only when it finds a frame, the ordered
	// FindUnfinishedFor scans (O(N) each, up to ~15). Step 4 is O(F) over
	// Factory::factoryList plus one FindProducedNear O(N) factory side. The def
	// lists are built once (side is fixed): no per-ask array allocation.
	array<CCircuitDef@> turretOrderDefs;   // D-065 order behind the labs
	array<CCircuitDef@> turretRushDefs;    // D-229 nuke-opening projects
	bool turretOrderBuilt = false;
	bool turretRushBuilt = false;
	void Tech_TurretAddDefs(array<CCircuitDef@>@ defs, const array<string>@ names)
	{
		for (uint i = 0; i < names.length(); ++i) {
			CCircuitDef@ d = ai.GetCircuitDef(names[i]);
			if (d !is null) defs.insertLast(d);
		}
	}
	int turretNearId = -1;
	int turretNearAt = -1;
	CCircuitUnit@ turretNear = null;   // valid only for (turretNearId, turretNearAt): never read across frames
	CCircuitUnit@ Tech_TurretNearFrame(CCircuitUnit@ u)
	{
		if (turretNearId == u.id && turretNearAt == ai.frame) return turretNear;
		turretNearId = u.id;
		turretNearAt = ai.frame;
		@turretNear = aiBuilderMgr.FindUnfinishedNear(u.GetPos(ai.frame),
			u.circuitDef.GetBuildDistance() + Global::RoleSettings::Tech::TurretFrameMaxRadius, null);
		return turretNear;
	}
	IUnitTask@ Tech_TurretRepair(CCircuitUnit@ target, bool factorySide, Task::Priority prio)
	{
		if (factorySide) return aiFactoryMgr.Enqueue(TaskS::Repair(prio, target));
		// 30 s: a reclaim or a dearer frame that begins meanwhile is taken at the next ask
		return aiBuilderMgr.Enqueue(TaskB::Repair(prio, target, 30 * SECOND));
	}

	// Steps 1-2. Also SUPPORT's turret assist (support_build.as) and rule turret.assist.
	IUnitTask @Tech_TurretAssist(CCircuitUnit @u, bool factorySide = false)
	{
		if (u is null || u.circuitDef is null) return null;
		const bool nukeRush = TechChain::NukeRush();
		// step 1: a reclaim of ours in reach (D-290: only one the gate allows now)
		if (!factorySide) {
			CCircuitUnit@ reclaim = null;
			if (nukeRush) {
				// The retiring lab is a durable lifecycle target. Reclaim task
				// entries can disappear when another worker's short task ends;
				// keep the refund staffed until the lab itself is gone. Match the
				// INV-008 envelope: the lab's model extends beyond its centre.
				CCircuitUnit@ retiredLab = ai.GetTeamUnit(TechChain::nukeRetiredLabId);
				const float reach = u.circuitDef.GetBuildDistance() + Global::RoleSettings::Tech::ReclaimTurretMargin;
				if (retiredLab !is null && MapHelpers::SqDist(u.GetPos(ai.frame), retiredLab.GetPos(ai.frame)) <= reach * reach)
					@reclaim = retiredLab;
			}
			if (reclaim is null) @reclaim = aiBuilderMgr.FindReclaimTargetFor(u);
			if (reclaim !is null && TechReclaim::Allowed(reclaim, "turret.join"))
			{
				if (LOG_LEVEL >= 2) GenericHelpers::LogUtil("[TECH][Turret] " + u.id + " reclaims " + reclaim.circuitDef.GetName(), 2);
				return aiBuilderMgr.Enqueue(TaskB::Reclaim(Task::Priority::HIGH, reclaim, (nukeRush ? 30 : 120) * SECOND));
			}
		}
		// step 2: nothing under construction within build distance + the largest
		// frame radius means no ordered scan below can find one
		if (Tech_TurretNearFrame(u) is null) return null;
		if (nukeRush) {
			// A silo is not in TECH's ordinary economic assist list. Native
			// fallback can refuse a large frame while metal is low, leaving
			// completed in-range turrets idle during the timed opening.
			if (!turretRushBuilt) {
				turretRushBuilt = true;
				const array<string> rush = {TechChain::DefFor("alab"), TechChain::DefFor("nano"), TechChain::DefFor("mstor"), TechChain::DefFor("estor"),
					TechChain::DefFor("fusion"), TechChain::DefFor("silo"), TechChain::DefFor("ap"),
					TechChain::DefFor("wind"), TechChain::DefFor("solar")};
				Tech_TurretAddDefs(turretRushDefs, rush);
			}
			for (uint i = 0; i < turretRushDefs.length(); ++i) {
				CCircuitUnit@ rushFrame = aiBuilderMgr.FindUnfinishedFor(u, turretRushDefs[i]);
				if (rushFrame !is null) return Tech_TurretRepair(rushFrame, factorySide, Task::Priority::HIGH);
			}
			return null;
		}
		const string side = Global::AISettings::Side;
		// D-107 (owner's rule): after the reclaim, the same switch as the air
		// constructors: the advanced converter first while energy overflows, the
		// advanced fusion first the moment the converters cannot stay on
		if (TechBuild::ConvertersStarve())
		{
			CCircuitDef @af = ai.GetCircuitDef(UnitHelpers::GetAdvFusionNameForSide(side));
			CCircuitUnit @afFrame = (af is null) ? null : aiBuilderMgr.FindUnfinishedFor(u, af);
			if (afFrame !is null)
			{
				if (LOG_LEVEL >= 2) GenericHelpers::LogUtil("[TECH][Turret] " + u.id + " assists the advanced fusion: the converters cannot stay on (D-107)", 2);
				return Tech_TurretRepair(afFrame, factorySide, Task::Priority::HIGH);
			}
		}
		// D-289: the chain's current dear frame (the rush's own target) first
		{
			CCircuitDef@ dear = TechChain::CurrentFrameDef();
			CCircuitUnit@ dearFrame = (dear is null) ? null : aiBuilderMgr.FindUnfinishedFor(u, dear);
			if (dearFrame !is null)
			{
				if (LOG_LEVEL >= 2) GenericHelpers::LogUtil("[TECH][Turret] " + u.id + " assists the chain's " + dear.GetName(), 2);
				return Tech_TurretRepair(dearFrame, factorySide, Task::Priority::HIGH);
			}
		}
		if (!turretOrderBuilt)
		{
			turretOrderBuilt = true;
			const array<string> order = {
				UnitHelpers::GetT2BotLabForSide(side),      // D-289: the labs, then the D-065 economy order
				UnitHelpers::GetLandGantryForSide(side),
				UnitHelpers::GetT1BotLabForSide(side),
				UnitHelpers::GetAdvEnergyConverterNameForSide(side),
				UnitHelpers::GetT1NanoNameForSide(side),
				UnitHelpers::GetAdvFusionNameForSide(side),
				UnitHelpers::GetEnergyConverterNameForSide(side),
				UnitHelpers::GetFusionNameForSide(side),
				UnitHelpers::GetAdvSolarNameForSide(side),
				UnitHelpers::GetSolarNameForSide(side),
				UnitHelpers::GetWindNameForSide(side),
				UnitHelpers::GetEnergyStorageNameForSide(side),
				UnitHelpers::GetMetalStorageNameForSide(side),
				Tech_T1MexName(side)
			};
			Tech_TurretAddDefs(turretOrderDefs, order);
		}
		for (uint i = 0; i < turretOrderDefs.length(); ++i)
		{
			CCircuitUnit @target = aiBuilderMgr.FindUnfinishedFor(u, turretOrderDefs[i]);
			if (target is null) continue;
			if (LOG_LEVEL >= 2) GenericHelpers::LogUtil("[TECH][Turret] " + u.id + " assists " + turretOrderDefs[i].GetName(), 2);
			return Tech_TurretRepair(target, factorySide, Task::Priority::HIGH);
		}
		return null;
	}

	// Step 3: any structure of ours under construction in exact reach. The
	// nearest frame (shared with step 2) names the def; FindUnfinishedFor applies
	// the engine's reach (build distance + model radius). Replaces the 700-elmo
	// search that handed out 30 s repairs no turret could execute. Not during the
	// nuke opening (its build power stays on its own projects, D-229).
	IUnitTask@ Tech_TurretAnyFrame(CCircuitUnit@ u, bool factorySide)
	{
		if (u is null || u.circuitDef is null || TechChain::NukeRush()) return null;
		CCircuitUnit@ near = Tech_TurretNearFrame(u);
		if (near is null || near.circuitDef is null) return null;
		CCircuitUnit@ f = aiBuilderMgr.FindUnfinishedFor(u, near.circuitDef);
		if (f is null) {
			if (LOG_LEVEL >= 3) GenericHelpers::LogUtil("[TECH][Turret] " + u.id + " nearest frame " + near.circuitDef.GetName() + " " + near.id + " is out of reach", 3);
			return null;
		}
		return factorySide ? aiFactoryMgr.Enqueue(TaskS::Repair(Task::Priority::NORMAL, f))
			: aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::NORMAL, f, 30 * SECOND));
	}

	// D-289: the economy guard of step 4: production does not take the build
	// power while the bank is nearly empty and a dear frame of ours is going up
	// (that frame is starved already). Energy stalling is not a reason by
	// default (played 20261013T234723Z: TECH's energy bank sat near zero from
	// 8 to 14 min and the guard kept every turret idle beside a producing lab;
	// native's static repair already pauses with CmdWait while energy is empty).
	bool Tech_TurretFactoryGuarded(string &out why)
	{
		if (Global::RoleSettings::Tech::TurretFactorySkipOnEnergyStall && aiEconomyMgr.isEnergyStalling) { why = "energy stalling"; return true; }
		const float stor = aiEconomyMgr.metal.storage;
		if (stor > 0.0f && aiEconomyMgr.metal.current < Global::RoleSettings::Tech::TurretFactoryMinBankShare * stor
			&& aiBuilderMgr.CountUnfinishedNear(Layout::BaseCentre(), Global::RoleSettings::Tech::EcoBuildPowerRadius,
				Global::RoleSettings::Tech::ChainParallelCostM, null) > 0) { why = "bank low with a dear frame up"; return true; }
		if (TechChain::NukeRush() && TechChain::nukeFundingSilo >= 0 && !Global::RoleSettings::Tech::TurretFactoryInNukeFunding) { why = "nuke silo funding"; return true; }
		why = "";
		return false;
	}

	// D-289: the factory a turret may assist: complete, producing (a FACTORY
	// task in hand, not a wait), not a spam lab (D-119 / INV-049: its two turrets
	// only), not retiring (D-076), its centre within build distance +
	// TurretFactoryReachMargin (a guard repairs the factory's curBuild at its
	// yard: Recoil BuilderCAI.cpp:931). Nearest; ties to the heavy-rush lab, then
	// the lower id. O(F) over Factory::factoryList, no allocation.
	CCircuitUnit@ Tech_TurretFactoryFor(CCircuitUnit@ u)
	{
		const float reach = u.circuitDef.GetBuildDistance() + Global::RoleSettings::Tech::TurretFactoryReachMargin;
		const float reachSq = reach * reach;
		const AIFloat3 here = u.GetPos(ai.frame);
		CCircuitUnit@ best = null;
		float bestSq = 1.0e30f;
		for (uint i = 0; i < Factory::factoryList.length(); ++i) {
			CCircuitUnit@ fac = Factory::factoryList[i];
			if (fac is null || fac is u || fac.circuitDef is null || fac.task is null) continue;
			if (fac.task.GetType() != int(Task::Type::FACTORY)) continue;
			if (Lifecycle::IsRetiring(fac) || TechFactories::IsSpamLab(fac)) continue;
			const float sq = MapHelpers::SqDist(here, fac.GetPos(ai.frame));
			if (sq > reachSq) continue;
			bool better = sq < bestSq;
			if (!better && sq == bestSq && best !is null) {
				const bool facHeavy = fac.id == TechHeavyRush::labId;
				const bool bestHeavy = best.id == TechHeavyRush::labId;
				better = (facHeavy && !bestHeavy) || (facHeavy == bestHeavy && fac.id < best.id);
			}
			if (better) { bestSq = sq; @best = fac; }
		}
		return best;
	}

	// Step 4. Builder side: an interruptible guard of the factory for
	// TurretFactoryGuardSeconds, then the ladder runs again (a frame that starts
	// in reach pre-empts it; FindMatchingGuard keeps an identical guard without a
	// new command). Factory side: a repair of what the factory is producing.
	dictionary turretFactoryLogged;   // "turret|factory" -> true: one line per pair
	IUnitTask@ Tech_TurretFactoryAssist(CCircuitUnit@ u, bool factorySide)
	{
		if (u is null || u.circuitDef is null) return null;
		string why;
		if (Tech_TurretFactoryGuarded(why)) return null;
		CCircuitUnit@ fac = Tech_TurretFactoryFor(u);
		if (fac is null) return null;
		IUnitTask@ t = null;
		if (factorySide) {
			CCircuitUnit@ buildee = aiBuilderMgr.FindProducedNear(fac.GetPos(ai.frame), TechFactories::LabYardRadius);
			if (buildee is null) return null;   // between two units: native's default, asked again shortly
			const float reach = u.circuitDef.GetBuildDistance() + Global::RoleSettings::Tech::TurretFactoryReachMargin;
			if (MapHelpers::SqDist(u.GetPos(ai.frame), buildee.GetPos(ai.frame)) > reach * reach) return null;
			@t = aiFactoryMgr.Enqueue(TaskS::Repair(Task::Priority::NORMAL, buildee));
		} else {
			// Not GuardHelpers::AssignWorkerGuard: it refuses a guard that lacks the
			// BUILDER role, and a construction turret has none (no build options;
			// behaviour.json role "support"), so every builder-side factory assist
			// was refused (played: INV-200, 20261013T234555Z). The spam-lab rule it
			// also enforces (INV-049) is applied by Tech_TurretFactoryFor. Same
			// reuse as the helper: an identical healthy guard sends no new command.
			const SServBTask guard = TaskB::Guard(Task::Priority::LOW, fac, true, Global::RoleSettings::Tech::TurretFactoryGuardSeconds * SECOND);
			@t = aiBuilderMgr.FindMatchingGuard(u, guard);
			if (t is null) @t = aiBuilderMgr.Enqueue(guard);
		}
		if (t !is null) {
			const string key = u.id + "|" + fac.id;
			if (!turretFactoryLogged.exists(key)) {
				turretFactoryLogged.set(key, true);
				GenericHelpers::LogUtil("[TECH][Turret] " + u.id + " assists factory " + fac.circuitDef.GetName() + " " + fac.id
					+ " (" + (factorySide ? "factory side" : "builder side") + ", D-289)", 1);
			}
		}
		return t;
	}

	// The whole ladder, steps 1-4 (the factory side; the builder side runs the
	// same steps as rule rows). Records the turret's wait for INV-200.
	IUnitTask@ Tech_TurretWork(CCircuitUnit@ u, bool factorySide)
	{
		IUnitTask@ t = Tech_TurretAssist(u, factorySide);
		if (t is null) @t = Tech_TurretAnyFrame(u, factorySide);
		if (t is null) @t = Tech_TurretFactoryAssist(u, factorySide);
		// Factory side, a null with a factory candidate in reach is a factory
		// between two units (or its buildee beyond reach): tried, not waiting.
		bool waiting = (t is null);
		if (waiting && factorySide && Tech_TurretFactoryFor(u) !is null) waiting = false;
		Tech_TurretWaited(u, waiting);
		return t;
	}

	// INV-200 state: turret id -> frame it started waiting (no ladder step
	// answered); cleared when one does. Read once a second by Invariants::Tick,
	// which walks only these entries.
	dictionary turretWaitingSince;
	void Tech_TurretWaited(CCircuitUnit@ u, bool waiting)
	{
		if (u is null) return;
		const string key = "" + u.id;
		if (!waiting) {
			turretWaitingSince.delete(key);
			Invariants::turretBlockedSince.delete(key);   // a later wait starts INV-200's clock afresh
			return;
		}
		if (!turretWaitingSince.exists(key)) turretWaitingSince.set(key, int64(ai.frame));
	}

	IUnitTask @Tech_Commander_AiMakeTask(CCircuitUnit @u, IUnitTask @defaultTask, float metalIncome)
	{
		GenericHelpers::LogUtil("[TECH] Enter Tech_Commander_AiMakeTask", 4);

		GenericHelpers::LogUtil("[TECH] Commander making task: " + u.circuitDef.GetName() + " id=" + u.id, 2);
		IUnitTask @recycleTask = Recycle(u, metalIncome);
		if (recycleTask !is null)
			return recycleTask;

		GenericHelpers::LogUtil("[TECH] No commander-specific task, using pre-created default", 2);
		// Use the pre-created default task passed from caller when no commander-specific path applies
		// The commander opens the economy by the planner (D-058); a native default
		// that is a mex or geo keeps priority (checked by the caller).
		if (Global::RoleSettings::Tech::EcoPlannerEnabled)
		{
			const string ecoKey = EcoPlanner::Next(u, metalIncome, aiEconomyMgr.energy.income);
			if (ecoKey.length() > 0)
			{
				IUnitTask @redirect = Tech_RedirectEnergyToReactor("eco planner: " + ecoKey, u);
				if (redirect !is null)
					return redirect;
				IUnitTask @tEco = EcoPlanner::Execute(ecoKey, u);
				if (tEco !is null)
					return tEco;
			}
		}
		return defaultTask;
	}

	/******************************************************************************

	BUILDER LOGIC

	******************************************************************************/

	// Finishing a reactor that is already under construction beats starting any new
	// energy structure: the metal is already committed, and an unfinished reactor
	// produces nothing until it completes. Returns an assist task when a Fusion or
	// Advanced Fusion is in progress, otherwise null so the caller proceeds normally.
	// A merely queued reactor does not qualify - see Builder::GetReactorUnderConstruction.
	// Before any energy rung: finish what is already going up. A reactor
	// first, then the T1 energy structure the script last queued
	// (Global::RoleSettings::Tech::EnergyFocus*). Returns null when nothing is
	// under construction or it has its share of assists, and the rung proceeds.
	// True when the constructor is already on a construction task: a build in
	// progress, or a site it is walking to. The assist rungs never pull such a
	// unit off its job (D-050); the re-evaluation that asked is told "keep it".
	bool Tech_IsBuilding(CCircuitUnit @u)
	{
		if (u is null || u.task is null) return false;
		IBuilderTask @cur = cast<IBuilderTask>(u.task);
		if (cur is null) return false;
		return Task::BuildType(cur.GetBuildType()) < Task::BuildType::REPAIR;
	}

	IUnitTask @Tech_RedirectEnergyToReactor(const string &in what, CCircuitUnit @u = null)
	{
		if (Tech_IsBuilding(u)) return null;
		IUnitTask @assist = Builder::EnqueueAssistReactor(Task::Priority::HIGH, 60 * SECOND);
		if (assist !is null)
		{
			GenericHelpers::LogUtil("[TECH][Energy] Reactor under construction; redirecting "
				+ what + " to assist it instead", 2);
			return assist;
		}
		if (Global::RoleSettings::Tech::EnergyFocusAssist)
		{
			@assist = Builder::EnqueueAssistEnergy(Task::Priority::NORMAL, 60 * SECOND,
				Global::RoleSettings::Tech::EnergyFocusMaxAssists);
			if (assist !is null)
			{
				GenericHelpers::LogUtil("[TECH][Energy] energy structure under construction; redirecting "
					+ what + " to assist it instead", 2);
			}
		}
		return assist;
	}

	/**************************************************************************
	 FLOATING METAL

	 Spend a full bank. Runs at the top of both constructor policies and
	 returns null unless metal is floating (Global::RoleSettings::Tech::Float*).

	 T2 constructors: an advanced converter if there is energy income to
	 convert, otherwise the energy first - an advanced fusion when rich, a
	 fusion when not - then a nuclear silo if none is planned. Every one of
	 these has an income gate further down the ladder that a full bank on a
	 modest income never clears; here the bank itself is the justification.

	 T1 constructors cannot build any of those. Their best use while floating
	 is to assist the T2 constructor that can, so they guard it. Only when
	 there is no T2 constructor do they fall through to the normal ladder,
	 whose nano rung is now capped at NanoReserveSurplus beyond the target.
	 **************************************************************************/
	bool Tech_IsFloating(float metalIncome)
	{
		if (metalIncome < Global::RoleSettings::Tech::FloatMetalIncome) return false;
		return aiEconomyMgr.isMetalFull
			|| aiEconomyMgr.metal.current >= Global::RoleSettings::Tech::FloatMetalCurrent;
	}

    dictionary floatAssistReasons;
    bool Tech_ProductiveWorker(CCircuitUnit@ worker) {
        if (worker is null || ai.GetTeamUnit(worker.id) !is worker
            || worker.task is null || worker.task.IsDead() || worker.task.IsExternalControlled()) return false;
        IBuilderTask@ task = cast<IBuilderTask>(worker.task);
        if (task is null) return false;
        const Task::BuildType kind = Task::BuildType(task.GetBuildType());
        if (kind == Task::BuildType::GUARD || kind == Task::BuildType::WAIT
            || kind == Task::BuildType::RECLAIM) return false;
        if (task.target !is null)
            return ai.GetTeamUnit(task.target.id) is task.target && !Lifecycle::IsRetiring(task.target)
                && task.target.GetBuildProgress() < 1.0f;
        // A live owned construction task may still be travelling to its frame,
        // or deliberately resource-starved. Neither needs a progress timer.
        return task.buildDef !is null;
    }
    IUnitTask@ Tech_FloatSpend(CCircuitUnit@ u, bool isT2, float metalIncome, float energyIncome) {
        EcoPlanner::ConversionDecision@ previous = EcoPlanner::conversionDecision;
        if (previous is null) EcoPlanner::BeginConversionDecision(u);
        IUnitTask@ task = Tech_FloatSpendImpl(u, isT2, metalIncome, energyIncome);
        if (previous is null) EcoPlanner::EndConversionDecision(previous);
        return task;
    }
	IUnitTask @Tech_FloatSpendImpl(CCircuitUnit @u, bool isT2, float metalIncome, float energyIncome)
	{
		if (u is null || u.circuitDef is null) return null;
		if (!Tech_IsFloating(metalIncome)) return null;
		const string side = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());
		const float bank = aiEconomyMgr.metal.current;

		if (!isT2)
		{
            CCircuitUnit@ target = Builder::primaryT2BotConstructor;
            const bool productive = target !is u && Tech_ProductiveWorker(target);
            const string reason = productive ? "productive:" + target.id : "no productive owned construction";
            string previousReason;
            if (!floatAssistReasons.get("" + u.id, previousReason) || previousReason != reason) {
                floatAssistReasons.set("" + u.id, reason);
                GenericHelpers::LogUtil("[TECH][FloatAssist] worker=" + u.id + " " + reason, 1);
            }
			if (productive)
			{
				return GuardHelpers::AssignWorkerGuard(u, target, Task::Priority::HIGH, true, 60 * SECOND);
			}
			return null;   // nothing a T1 constructor can spend it on; normal ladder, capped nanos
		}

		AIFloat3 at = Factory::GetT2BotLabPos();
		if (energyIncome >= Global::RoleSettings::Tech::FloatConverterMinEnergyIncome)
		{
			IUnitTask @t = EcoPlanner::Enqueue("advconv", u);
			if (t !is null)
			{
				GenericHelpers::LogUtil("[TECH][Float] advanced converter (metal " + int(bank) + ", energy income " + int(energyIncome) + ")", 1);
				return t;
			}
		}
		// A failed converter attempt must still reach funded reactor growth.
		// Existing energy ownership and Layout reservations remain authoritative.
		{
			if (bank >= Global::RoleSettings::Tech::FloatAFUSMetalCurrent)
			{
				IUnitTask @t = EcoPlanner::Enqueue("afus", u);
				if (t !is null)
				{
					GenericHelpers::LogUtil("[TECH][Float] advanced fusion (metal " + int(bank) + ", energy income " + int(energyIncome) + ")", 1);
					return t;
				}
			}
			IUnitTask @t = EcoPlanner::Enqueue("fusion", u);
			if (t !is null)
			{
				GenericHelpers::LogUtil("[TECH][Float] fusion (metal " + int(bank) + ", energy income " + int(energyIncome) + ")", 1);
				return t;
			}
		}

		const int silos = EconomyHelpers::GetNukeSiloCount() + Builder::NukeSiloQueuedCount;
		if (silos < Global::RoleSettings::Tech::FloatMaxNukeSilos)
		{
			IUnitTask @t = Builder::EnqueueNukeSilo(side, at, SQUARE_SIZE * 32, SECOND * 300);
			if (t !is null)
			{
				GenericHelpers::LogUtil("[TECH][Float] nuclear silo (metal " + int(bank) + ")", 1);
				return t;
			}
		}
		return null;
	}

	IUnitTask @Tech_T1BotConstructor_AiMakeTask(CCircuitUnit @u, float metalIncome, float energyIncome, IUnitTask @defaultTask)
	{
		{
			IUnitTask @tFloat = Tech_FloatSpend(u, false, metalIncome, energyIncome);
			if (tFloat !is null) return tFloat;
		}
		GenericHelpers::LogUtil("[TECH] Enter Tech_T1BotConstructor_AiMakeTask", 4);
		// Economy snapshot is provided by caller (to avoid repeated global reads)

		AIFloat3 conLocation = u.GetPos(ai.frame);

		string unitSide = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());

		// Primary Constructor Tasks
		// if (u is Builder::primaryT1BotConstructor)
		//{
		GenericHelpers::LogUtil("[TECH] Primary T1 bot constructor making task: " + u.circuitDef.GetName() + " id=" + u.id, 2);
		// Keep local counts for decisions that need them
		int t2ConstructionBotCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotConstructors());
		int t2LabCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotLabs());

		//******************************* T2 LAB CHECKS ******************************//
		// Hybrid policy: require minimum incomes for the FIRST T2 lab; after that, scale allowed count by income-per-lab.
		// Reference old threshold helper (ShouldBuildT2BotLab) for first-gate semantics.
		bool shouldT2Lab = EconomyHelpers::ShouldBuildT2BotLabFromIncomeWithFirstGate(
			/*mi*/ metalIncome,
			/*ei*/ energyIncome,
			/*currentT2Labs*/ t2LabCount,
			/*metalIncomePerLab*/ Global::RoleSettings::Tech::MetalIncomePerT2Lab,
			/*energyIncomePerLab*/ Global::RoleSettings::Tech::EnergyIncomePerT2Lab,
			/*firstLabRequiredMetalIncome*/ Global::RoleSettings::Tech::MinimumMetalIncomeForT2Lab,
			/*firstLabRequiredEnergyIncome*/ Global::RoleSettings::Tech::MinimumEnergyIncomeForT2Lab,
			/*maxAllowed*/ Global::RoleSettings::Tech::MaxT2BotLabs);
		if (shouldT2Lab)
		{
			GenericHelpers::LogUtil("[TECH] Econ OK for T2 attempt", 2);
			// For the FIRST T2 lab, place at the map StartPos; for additional labs, place at the commander's position.
			AIFloat3 anchorPos;
			if (t2LabCount == 0)
			{
				anchorPos = Global::Map::StartPos;
				GenericHelpers::LogUtil("[TECH] T2 lab anchor: StartPos (first lab)", 3);
			}
			else
			{
				CCircuitUnit @com = Builder::GetCommander();
				if (com !is null)
				{
					anchorPos = com.GetPos(ai.frame);
					GenericHelpers::LogUtil("[TECH] T2 lab anchor: Commander position", 4);
				}
				else
				{
					// Fallback: previous behavior (near existing T2 bot lab or commander if absent)
					anchorPos = Factory::GetT2BotLabPos();
					GenericHelpers::LogUtil("[TECH] T2 lab anchor: Fallback to T2 Bot Lab position (commander absent)", 4);
				}
			}
			bool routedT2;   // D-114: a front factory cluster from +200 metal
			IUnitTask @tLabF = TechFactories::Route(UnitHelpers::GetT2BotLabForSide(unitSide), u, routedT2);
			if (routedT2) return tLabF;
			IUnitTask @tLab = Builder::EnqueueT2BotLabIfNeeded(unitSide, anchorPos, SQUARE_SIZE * 20, SECOND * 300);
			if (tLab !is null)
				return tLab;
		}
		else
		{
			GenericHelpers::LogUtil("[TECH] Econ NOT OK for T2)", 2);
		}

		// ********************** AIRCRAFT PLANT CHECKS ********************** //
		// Consider a T1 aircraft plant if economy allows and within max allowed
		int t1AirPlants = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1AircraftPlants());
		GenericHelpers::LogUtil(
			"[TECH] T1AirPlant check: metalIncome=" + metalIncome + " energyIncome=" + energyIncome + " metalCurrent=" + aiEconomyMgr.metal.current +
				" t1Count=" + t1AirPlants + " max=" + Global::RoleSettings::Tech::MaxT1AircraftPlants,
			3);
		bool shouldT1Air = EconomyHelpers::ShouldBuildT1AircraftPlant(
			metalIncome,
			energyIncome,
			aiEconomyMgr.metal.current,
			Global::RoleSettings::Tech::RequiredMetalIncomeForAirPlant,
			Global::RoleSettings::Tech::RequiredMetalCurrentForAirPlant,
			Global::RoleSettings::Tech::RequiredEnergyIncomeForAirPlant,
			t1AirPlants,
			Global::RoleSettings::Tech::MaxT1AircraftPlants);

		GenericHelpers::LogUtil("[TECH] ShouldBuildT1AircraftPlant => " + (shouldT1Air ? "true" : "false"), 3);
		if (shouldT1Air)
		{
			AIFloat3 preferredPosition = Factory::GetPreferredFactoryPos();
			IUnitTask @tAir = Builder::EnqueueT1AirFactory(unitSide, preferredPosition, SQUARE_SIZE * 24, 30 * SECOND, Task::Priority::HIGH);
			if (tAir !is null)
				return tAir;
		}

		// A mex upgrade outranks the whole energy ladder: best metal per metal,
		// and the supply of spots is finite. See doc/known-issues.md KI-213.
		if (Global::RoleSettings::MexUpgradeFirst)
		{
			IUnitTask@ tMexUp = EconomyHelpers::EnqueueMexUpgradeIfFirst(u, Global::Map::StartPos,
					Global::RoleSettings::MexUpgradeRadius,
					Global::RoleSettings::MexUpgradeMaxConcurrent, "TECH");
			if (tMexUp !is null) return tMexUp;
		}

		// ********************** ENERGY/CONVERTER/SOLAR CHECKS********************** //
		// The eco planner (D-058) decides solars, winds, converters and storages.
		if (Global::RoleSettings::Tech::EcoPlannerEnabled)
		{
			const string ecoKey = EcoPlanner::Next(u, metalIncome, energyIncome);
			if (ecoKey.length() > 0)
			{
				IUnitTask @redirect = Tech_RedirectEnergyToReactor("eco planner: " + ecoKey, u);
				if (redirect !is null)
					return redirect;
				IUnitTask @tEco = EcoPlanner::Execute(ecoKey, u);
				if (tEco !is null)
					return tEco;
			}
		}
		if (!Global::RoleSettings::Tech::EcoPlannerEnabled && EconomyHelpers::ShouldBuildT1EnergyConverter(
				metalIncome,
				energyIncome,
				aiEconomyMgr.energy.current,
				aiEconomyMgr.energy.storage,
				Global::RoleSettings::Tech::BuildT1ConvertersUntilMetalIncome,
				Global::RoleSettings::Tech::BuildT1ConvertersMinimumEnergyIncome,
				Global::RoleSettings::Tech::BuildT1ConvertersMinimumEnergyCurrentPercent))
		{
			IUnitTask @redirect = Tech_RedirectEnergyToReactor("T1 energy converter", u);
			if (redirect !is null)
				return redirect;
			IUnitTask @tConv = Builder::EnqueueT1EnergyConverter(unitSide, conLocation, SQUARE_SIZE * 32, SECOND * 30);
			if (tConv !is null)
				return tConv;
		}

		// Build regular solar?
		if (!Global::RoleSettings::Tech::EcoPlannerEnabled && EconomyHelpers::ShouldBuildT1Solar(
				/*ei*/ energyIncome,
				/*min*/ Global::RoleSettings::Tech::SolarEnergyIncomeMinimum))
		{
			IUnitTask @redirect = Tech_RedirectEnergyToReactor("T1 solar", u);
			if (redirect !is null)
				return redirect;
			IUnitTask @tSolar = Builder::EnqueueT1Solar(u.id, unitSide, conLocation, SQUARE_SIZE * 32, SECOND * 75);
			if (tSolar !is null)
				return tSolar;
		}

		// Build a T1 nano caretaker if under desired target (income-based) or reserves allow
		float energyPercent = (aiEconomyMgr.energy.storage > 0.0f) ? (aiEconomyMgr.energy.current / aiEconomyMgr.energy.storage) : 0.0f;
		// Not while the first T2 constructors are being paid for, nor with an
		// empty bank: the turret would only deepen the stall (D-051).
		const bool nanoHeld = Global::RoleSettings::Tech::NanoHoldForFirstT2Constructors
			&& t2LabCount > 0 && t2ConstructionBotCount < Global::RoleSettings::Tech::MinimumT2ConstructorBots;
		const bool nanoBankLow = aiEconomyMgr.metal.current < Global::RoleSettings::Tech::NanoMinMetalCurrent;
		// Only build nanos if we have a preferred factory to anchor around
		if (!Global::RoleSettings::Tech::EcoPlannerEnabled && !nanoHeld && !nanoBankLow && Factory::GetPreferredFactory() !is null && EconomyHelpers::ShouldBuildT1Nano(
														   energyIncome,
														   metalIncome,
														   Global::RoleSettings::Tech::NanoEnergyPerUnit,
														   Global::RoleSettings::Tech::NanoMetalPerUnit,
														   Global::RoleSettings::Tech::NanoMaxCount,
														   aiEconomyMgr.metal.current,
														   Global::RoleSettings::Tech::NanoBuildWhenOverMetal,
														   energyPercent,
														   Global::RoleSettings::Tech::NanoReserveSurplus))
		{
			// Always place nano near our preferred factory location, not the constructor's current position
			AIFloat3 nanoPos = Factory::GetPreferredFactoryPos();
			IUnitTask @tNano = EcoPlanner::Enqueue("nano", u);
			if (tNano is null && !Layout::HasComplex())
				@tNano = Builder::EnqueueT1Nano(unitSide, nanoPos, /*shake*/ SQUARE_SIZE * 24, /*timeout*/ 30);
			if (tNano !is null)
				return tNano;
		}

		// Advanced T1 solar decision via unified helper with TECH thresholds and T2 gating
			if (!Global::RoleSettings::Tech::EcoPlannerEnabled && EconomyHelpers::ShouldBuildT1AdvancedSolar(
				/*energyIncome*/ energyIncome,
				/*metalIncome*/ metalIncome,
				/*energyIncomeMinimumThreshold*/ Global::RoleSettings::Tech::AdvancedSolarEnergyIncomeMinimum,
				/*energyIncomeMaximumThreshold*/ Global::RoleSettings::Tech::AdvancedSolarEnergyIncomeMaximum,
				/*t2ConstructorCount*/ t2ConstructionBotCount,
				/*t2FactoryCount*/ t2LabCount,
				/*isT2FactoryQueued*/ Factory::IsT2LabBuildQueued(),
				/*enableT2ProgressGate*/ true,
				/*metalIncomeFallbackMinimum*/ 6.0f))
		{
				IUnitTask @redirect = Tech_RedirectEnergyToReactor("advanced solar", u);
				if (redirect !is null)
					return redirect;
				IUnitTask @tAdvSolar = Builder::EnqueueT1AdvancedSolar(u.id, unitSide, conLocation, SQUARE_SIZE * 32, SECOND * 75);
			if (tAdvSolar !is null)
				return tAdvSolar;
		}

		// After eco threshold, expand T1 bot labs up to 5 via builder logic (uses cooldown in Builder)
		if (metalIncome >= Global::RoleSettings::Tech::MetalIncomeThresholdForBotLabExpansion)
		{
			int t1LabCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1BotLabs());
			if (t1LabCount < 5)
			{
				AIFloat3 preferredPosition = Factory::GetPreferredFactoryPos();
				bool routedT1;   // D-114: a front factory cluster from +200 metal
				IUnitTask @tLab1F = TechFactories::Route(UnitHelpers::GetT1BotLabForSide(unitSide), u, routedT1);
				if (routedT1) { if (tLab1F !is null) return tLab1F; }
				IUnitTask @tLab1 = routedT1 ? null : Builder::EnqueueT1BotLab(unitSide, preferredPosition, SQUARE_SIZE * 24, 300 * SECOND, Task::Priority::NORMAL);
				if (tLab1 !is null)
					return tLab1;
			}
		}

		// After eco threshold, expand T1 vehicle plants up to 3 via builder logic
		if (metalIncome >= Global::RoleSettings::Tech::MetalIncomeThresholdForVehiclePlantExpansion)
		{
			int t1VehCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1VehicleLabs());
			if (t1VehCount < 3)
			{
				AIFloat3 preferredPosition = Factory::GetPreferredFactoryPos();
				const string vpName = (unitSide == "armada") ? "armvp" : ((unitSide == "legion") ? "legvp" : "corvp");
				bool routedVp;   // D-114: a front factory cluster from +200 metal
				IUnitTask @tLabVehF = TechFactories::Route(vpName, u, routedVp);
				if (routedVp) { if (tLabVehF !is null) return tLabVehF; }
				IUnitTask @tLabVeh = routedVp ? null : Builder::EnqueueT1VehiclePlant(unitSide, preferredPosition, SQUARE_SIZE * 24, 300 * SECOND, Task::Priority::NORMAL);
				if (tLabVeh !is null)
					return tLabVeh;
			}
		}

		// if (Builder::primaryT2BotConstructor !is null)
		// {
		// 	return GuardHelpers::AssignWorkerGuard(u, Builder::primaryT2BotConstructor, Task::Priority::HIGH, true, 120 * SECOND);
		// }
		// }
		// else if (u is Builder::secondaryT1BotConstructor)
		// {
		// 	GenericHelpers::LogUtil("[TECH] Secondary T1 constructor making task: " + u.circuitDef.GetName() + " id=" + u.id, 2);
		// 	// Check if anything needs to be recycled
		// 	IUnitTask @recycleTask = Recycle(u, metalIncome);
		// 	if (recycleTask !is null)
		// 		return recycleTask;

		// 	if (EconomyHelpers::ShouldSecondaryT1AssistPrimary(
		// 			/*metalIncome*/ metalIncome,
		// 			/*threshold*/ 80.0f))
		// 	{
		// 		GenericHelpers::LogUtil("[TECH] Secondary T1 assisting primary", 2);
		// 		return GuardHelpers::AssignWorkerGuard(u, Builder::primaryT1BotConstructor, Task::Priority::HIGH, true, 20 * SECOND);
		// 	}
		// }

		GenericHelpers::LogUtil("[TECH] No role-specific task; using pre-created default", 2);
		// Use the pre-created default task passed from caller when no T1-constructor-specific path applies
		return defaultTask;
	}

	IUnitTask @Tech_T1AirConstructor_AiMakeTask(CCircuitUnit @u, float metalIncome, float energyIncome, IUnitTask @defaultTask)
	{
		GenericHelpers::LogUtil("[TECH] Enter Tech_T1AirConstructor_AiMakeTask", 4);
		// For now, reuse the full T1 bot constructor logic for air constructors as well.
		// If we later want air-specific behavior (e.g., different placement), we can
		// specialize this function while keeping the same signature.
		return Tech_T1BotConstructor_AiMakeTask(u, metalIncome, energyIncome, defaultTask);
	}

	IUnitTask @Tech_T2BotConstructor_AiMakeTask(CCircuitUnit @u, bool isEnergyFull, float metalIncome, float energyIncome, float metalCurrent, bool isEnergyLessThan90Percent, IUnitTask @defaultTask)
	{
		{
			IUnitTask @tFloat = Tech_FloatSpend(u, true, metalIncome, energyIncome);
			if (tFloat !is null) return tFloat;
		}

		string unitSide = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());

		AIFloat3 anchor = Factory::GetT2BotLabPos();

		// D-288: one gantry policy - TechGantryScale decides when one is due (this
		// legacy rung is kept for a disabled layout; the gantry.scale rule row
		// normally claims the T2 constructor first)
		if (TechGantryScale::Due())
		{
			bool routedG;   // D-114: a front factory cluster from +200 metal
			IUnitTask @tGantryF = TechFactories::Route(UnitHelpers::GetLandGantryForSide(unitSide), u, routedG);
			if (routedG && tGantryF !is null) return tGantryF;
			IUnitTask @tGantry = routedG ? null : Builder::EnqueueLandGantry(unitSide);
			if (tGantry !is null)
				return tGantry;
		}

		// Landlocked start: shipyards / hover plant unlocked at the income gate
		IUnitTask @tWater = Tech_TryEnqueueLandLockedWaterFactory(unitSide, metalIncome, energyIncome, metalCurrent, anchor);
		if (tWater !is null)
			return tWater;

		// The eco planner (D-058) decides converters, fusions and storages.
		if (Global::RoleSettings::Tech::EcoPlannerEnabled)
		{
			const string ecoKey = EcoPlanner::Next(u, metalIncome, energyIncome);
			if (ecoKey.length() > 0)
			{
				IUnitTask @redirect = Tech_RedirectEnergyToReactor("eco planner: " + ecoKey, u);
				if (redirect !is null)
					return redirect;
				IUnitTask @tEco = EcoPlanner::Execute(ecoKey, u);
				if (tEco !is null)
					return tEco;
			}
		}
		if (!Global::RoleSettings::Tech::EcoPlannerEnabled && EconomyHelpers::ShouldBuildT2EnergyConverter(
				/*metalIncome*/ metalIncome,
				/*energyIncome*/ energyIncome,
				/*energy<90%*/ isEnergyLessThan90Percent,
				/*energyFull*/ isEnergyFull,
				/*reqMi*/ Global::RoleSettings::Tech::MinimumMetalIncomeForAdvConverter,
				/*reqEi*/ Global::RoleSettings::Tech::MinimumEnergyIncomeForAdvConverter))
		{
			GenericHelpers::LogUtil("[TECH] Economy OK to build Advanced Energy Converter", 2);
			IUnitTask @redirect = Tech_RedirectEnergyToReactor("advanced energy converter", u);
			if (redirect !is null)
				return redirect;
			IUnitTask @tConv = EcoPlanner::Enqueue("advconv", u);
			if (tConv !is null)
				return tConv;
		}

		// Nuke silo decision via helper using cached snapshot
		int nukeTotal = EconomyHelpers::GetNukeSiloCount();
		int nukeQueued = Builder::NukeSiloQueuedCount;
		if (EconomyHelpers::ShouldBuildNuclearSilo(
				/*mi*/ metalIncome,
				/*ei*/ energyIncome,
				/*queued*/ nukeQueued,
				/*total*/ nukeTotal,
				/*rushCount*/ Global::RoleSettings::Tech::NukeRush,
				/*reqMiRush*/ Global::RoleSettings::Tech::MinimumMetalIncomeForNukeRush,
				/*reqEiRush*/ Global::RoleSettings::Tech::MinimumEnergyIncomeForNukeRush,
				/*reqMiReg*/ Global::RoleSettings::Tech::MinimumMetalIncomeForNuke,
				/*reqEiReg*/ Global::RoleSettings::Tech::MinimumEnergyIncomeForNuke))
		{
			GenericHelpers::LogUtil("[TECH] Economy OK to build Nuke Silo", 2);
			IUnitTask @tNuke = Builder::EnqueueNukeSilo(unitSide, anchor, SQUARE_SIZE * 32, SECOND * 300);
			if (tNuke !is null)
				return tNuke;
		}

		// Anti-nuke decision: ensure at least target number based on income-scaled allowance and minimum
		int antiNukeTotal = EconomyHelpers::GetAntiNukeCount();
		int allowedAnti = EconomyHelpers::AllowedAntiNukesFromIncome(
			/*metalIncome*/ metalIncome,
			/*per*/ Global::RoleSettings::Tech::MetalIncomePerAntiNuke);
		if (EconomyHelpers::ShouldBuildAntiNuke(
				/*mi*/ metalIncome,
				/*ei*/ energyIncome,
				/*current*/ antiNukeTotal,
				/*reqMi*/ Global::RoleSettings::Tech::MinimumMetalIncomeForAntiNuke,
				/*reqEi*/ Global::RoleSettings::Tech::MinimumEnergyIncomeForAntiNuke,
				/*minCount*/ Global::RoleSettings::Tech::MinimumAntiNukeCount,
				/*allowed*/ allowedAnti))
		{
			GenericHelpers::LogUtil("[TECH] Economy OK to build Anti-Nuke (below target)", 2);
			IUnitTask @tAmd = Builder::EnqueueAntiNuke(unitSide, anchor, SQUARE_SIZE * 32, SECOND * 300);
			if (tAmd !is null)
				return tAmd;
		}

		if (!Global::RoleSettings::Tech::EcoPlannerEnabled && EconomyHelpers::ShouldBuildAdvancedFusionReactor(
				/*mi*/ metalIncome,
				/*ei*/ energyIncome,
				/*energy<90%*/ isEnergyLessThan90Percent,
				/*nukeRush*/ Global::RoleSettings::Tech::NukeRush,
				/*nukeSilos*/ nukeTotal,
				/*reqMi*/ Global::RoleSettings::Tech::MinimumMetalIncomeForAFUS,
				/*reqEi*/ Global::RoleSettings::Tech::MinimumEnergyIncomeForAFUS))
		{
			GenericHelpers::LogUtil("[TECH] Economy OK to build Advanced Fusion Reactor", 2);
			// Additional gate: If a nuclear silo is on cooldown and we have <2 AFUS built, suppress AFUS build
			// NOTE: There's no explicit nuke-silo cooldown helper; we treat "queued" as a cooldown proxy.
			int afusBuilt = 0;
			{
				array<string> afusNames = UnitHelpers::GetAllAdvancedFusionReactors();
				for (uint i = 0; i < afusNames.length(); ++i)
				{
					CCircuitDef @d = ai.GetCircuitDef(afusNames[i]);
					if (d !is null)
					{
						afusBuilt += d.count;
					}
				}
			}
			const bool nukeCooldownActive = Builder::IsNukeSiloBuildQueued(); // TODO: replace with explicit cooldown if added
			if (nukeCooldownActive && afusBuilt < 2)
			{
				GenericHelpers::LogUtil("[TECH] Suppress AFUS: nuke silo cooldown active and AFUS<2 (built=" + afusBuilt + ")", 2);
			}
			else
			{
				IUnitTask @tAfus = EcoPlanner::Enqueue("afus", u);
				if (tAfus !is null)
					return tAfus;
			}
		}

		if (!Global::RoleSettings::Tech::EcoPlannerEnabled && EconomyHelpers::ShouldBuildFusionReactor(
				/*mi*/ metalIncome,
				/*ei*/ energyIncome,
				/*energy<90%*/ isEnergyLessThan90Percent,
				/*reqMi*/ Global::RoleSettings::Tech::MinimumMetalIncomeForFUS,
				/*reqEi*/ Global::RoleSettings::Tech::MinimumEnergyIncomeForFUS,
				/*maxEi*/ Global::RoleSettings::Tech::MaxEnergyIncomeForFUS))
		{
			GenericHelpers::LogUtil("[TECH] Economy OK to build fusion reactor", 2);
			IUnitTask @tFus = EcoPlanner::Enqueue("fusion", u);
			if (tFus !is null)
				return tFus;
		}

		GenericHelpers::LogUtil("[TECH] No role-specific task; using pre-created default", 2);
		// Use the pre-created default task passed from caller when no T2-constructor-specific path applies
		return defaultTask;
	}

	// Dedicated make-task for fast-assist T2 builders. For now this mirrors the
	// T2 bot constructor logic exactly, but is kept separate so it can diverge
	// later without impacting normal T2 bots.
	IUnitTask @Tech_T2FastAssistBotConstructor_AiMakeTask(CCircuitUnit @u, bool isEnergyFull, float metalIncome, float energyIncome, float metalCurrent, bool isEnergyLessThan90Percent, IUnitTask @defaultTask)
	{

		string unitSide = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());

		IUnitTask @recycleTask = Recycle(u, metalIncome);
		if (recycleTask !is null)
		{
			GenericHelpers::LogUtil("[TECH] Recycling task assigned", 2);
			return recycleTask;
		}

		GenericHelpers::LogUtil("[TECH] No fast-assist-specific task; using pre-created default", 2);
		return defaultTask;
	}

	IUnitTask @Tech_T2AirConstructor_AiMakeTask(CCircuitUnit @u, bool isEnergyFull, float metalIncome, float energyIncome, float metalCurrent, bool isEnergyLessThan90Percent, IUnitTask @defaultTask)
	{
		GenericHelpers::LogUtil("[TECH] Enter Tech_T2AirConstructor_AiMakeTask", 4);
		// For now, reuse the full T2 bot constructor logic for air constructors as well.
		// If we later want air-specific behavior, we can specialize this function while
		// keeping the same signature.
		return Tech_T2BotConstructor_AiMakeTask(u, isEnergyFull, metalIncome, energyIncome, metalCurrent, isEnergyLessThan90Percent, defaultTask);
	}

	IUnitTask @Recycle(CCircuitUnit @u, float metalIncome)
	{
		GenericHelpers::LogUtil(
			"[TECH] Enter Recycle IsT2LabQueued=" + (Factory::IsT2LabBuildQueued() ? "true" : "false") +
				" MetalCurrent=" + aiEconomyMgr.metal.current + " metalIncome=" + metalIncome,
			4);

		// Policy: Never recycle T1/T2 labs if we already have at least one Advanced Fusion built
		// Sum counts across all factions' Advanced Fusion reactor unit IDs
		array<string> afusNames = UnitHelpers::GetAllAdvancedFusionReactors();
		int afusBuilt = 0;
		for (uint i = 0; i < afusNames.length(); ++i)
		{
			CCircuitDef @d = ai.GetCircuitDef(afusNames[i]);
			if (d !is null)
			{
				afusBuilt += d.count;
			}
		}
		if (afusBuilt >= 1)
		{
			GenericHelpers::LogUtil("[TECH] Skip recycle: Advanced Fusion present (total=" + afusBuilt + ")", 2);
			return null;
		}

		// Gate reclaim of the T1 bot lab until we have sufficient T1 construction bots on the field
		int t1CtorCountForRecycle = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1BotConstructors());
		// Additional gate: do NOT reclaim if metal income is healthy (> 45)
		if (Factory::IsT2LabBuildQueued() && aiEconomyMgr.metal.current < 100.0f && t1CtorCountForRecycle >= 3 && metalIncome <= 45.0f)
		{
			// Reclaim T1 Lab if T2 lab is queued and metal stored is low
			if (Factory::primaryT1BotLab !is null && TechReclaim::Allowed(Factory::primaryT1BotLab, "recycle.t1"))   // D-290
			{
				// AIFloat3 labPos = Factory::primaryT1BotLab.GetPos(ai.frame);
				IUnitTask @t = aiBuilderMgr.Enqueue(
					TaskB::Reclaim(Task::Priority::NORMAL, Factory::primaryT1BotLab, 180 * SECOND));
				if (t !is null)
				{
					GenericHelpers::LogUtil("[TECH] Reclaiming primary T1 bot lab (t1CtorCount=" + t1CtorCountForRecycle + ")", 2);
					// Proactively clear the primary pointer to avoid later references during reclaim
					@Factory::primaryT1BotLab = null;
					return t;
				}
			}
		}

		// If an Advanced Fusion OR a Nuclear Silo is queued and metal reserves are low, consider reclaiming the primary T2 bot lab
		// New rule: Only proceed if there is enough free metal storage to hold the lab's metal cost (to avoid wasting reclaim).
		if ((Builder::IsAdvancedFusionBuildQueued() || Builder::IsNukeSiloBuildQueued()) && aiEconomyMgr.metal.current < 600.0f)
		{
			if (Factory::primaryT2BotLab !is null)
			{
				const CCircuitDef @labDef = Factory::primaryT2BotLab.circuitDef;
				float labCostM = (labDef is null ? 0.0f : labDef.costM);
				const SResourceInfo @metal = aiEconomyMgr.metal;
				float freeStorage = ((metal is null) ? 0.0f : (metal.storage - metal.current));

				if (labCostM > 0.0f && freeStorage >= labCostM && TechReclaim::Allowed(Factory::primaryT2BotLab, "recycle.t2"))   // D-290
				{
					IUnitTask @t2 = aiBuilderMgr.Enqueue(
						TaskB::Reclaim(Task::Priority::NORMAL, Factory::primaryT2BotLab, 180 * SECOND));
					if (t2 !is null)
					{
						GenericHelpers::LogUtil("[TECH] Reclaiming primary T2 bot lab for AFUS/NUKE (labCostM=" + labCostM + ", freeStorage=" + freeStorage + ")", 2);
						// Proactively clear the primary pointer to avoid later references during reclaim
						@Factory::primaryT2BotLab = null;
						return t2;
					}
				}
				else
				{
					GenericHelpers::LogUtil(
						"[TECH] Suppress reclaim of T2 bot lab: insufficient free metal storage (labCostM=" + labCostM + ", freeStorage=" + freeStorage + ")",
						2);
				}
			}
		}

		return null;
	}

	/******************************************************************************

	ROLE CONFIGURATION

	******************************************************************************/

	bool Tech_RoleMatch(AiRole preferredMapRole, const string&in side, const AIFloat3& in pos, const string&in defaultStartFactory)
	{
		GenericHelpers::LogUtil("[TECH] Enter Tech_RoleMatch", 4);
		bool match = false;

		if (preferredMapRole == AiRole::TECH)
			match = true;

		if (match)
		{
			GenericHelpers::LogUtil("[RoleMatch] TECH", 2);
		}

		return match;
	}

	// Rules moved to EconomyHelpers

	void Register()
	{
		GenericHelpers::LogUtil("[TECH] Enter Register", 4);
		if (RoleConfigs::Get(AiRole::TECH) !is null)
			return;
		RoleConfig @cfg = RoleConfig(AiRole::TECH, cast<MainUpdateDelegate @>(@Tech_MainUpdate));

		@cfg.InitHandler = cast<InitDelegate @>(@Tech_Init);

		@cfg.AiIsSwitchTimeHandler = cast<AiIsSwitchTimeDelegate @>(@Tech_AiIsSwitchTime);
		@cfg.AiIsSwitchAllowedHandler = cast<AiIsSwitchAllowedDelegate @>(@Tech_AiIsSwitchAllowed);
		@cfg.MakeSwitchIntervalHandler = cast<MakeSwitchIntervalDelegate @>(@Tech_MakeSwitchInterval);

		@cfg.BuilderAiUnitAdded = cast<AiUnitAddedDelegate @>(@Tech_BuilderAiUnitAdded);
		@cfg.BuilderAiUnitRemoved = cast<AiUnitRemovedDelegate @>(@Tech_BuilderAiUnitRemoved);

		@cfg.FactoryAiMakeTaskHandler = cast<AiMakeTaskDelegate @>(@Tech_FactoryAiMakeTask);
		@cfg.FactoryAiUnitAdded = cast<AiUnitAddedDelegate @>(@Tech_FactoryAiUnitAdded);
		@cfg.FactoryAiUnitRemoved = cast<AiUnitRemovedDelegate @>(@Tech_FactoryAiUnitRemoved);

		@cfg.BuilderAiMakeTaskHandler = cast<AiMakeTaskDelegate @>(@Tech_BuilderAiMakeTask);
		@cfg.BuilderAiTaskAddedHandler = cast<AiTaskAddedDelegate @>(@Tech_BuilderAiTaskAdded);
		@cfg.BuilderAiTaskRemovedHandler = cast<AiTaskRemovedDelegate @>(@Tech_BuilderAiTaskRemoved);

		@cfg.MilitaryAiMakeTaskHandler = cast<AiMakeTaskDelegate @>(@Tech_MilitaryAiMakeTask);
		@cfg.MilitaryAiTaskRemovedHandler = cast<AiTaskRemovedDelegate @>(@Tech_MilitaryAiTaskRemoved);
		@cfg.MilitaryAiUnitAdded = cast<AiUnitAddedDelegate @>(@Tech_MilitaryAiUnitAdded);

		@cfg.SelectFactoryHandler = cast<SelectFactoryDelegate @>(@Tech_SelectFactoryHandler);
		@cfg.EconomyUpdateHandler = cast<EconomyUpdateDelegate @>(@Tech_EconomyUpdate);

		@cfg.AiMakeDefenceHandler = cast<AiMakeDefence @>(@Tech_AiMakeDefence);
		@cfg.LayoutPlanHandler = cast<LayoutPlanDelegate @>(@Tech_LayoutPlan);

		@cfg.RoleMatchHandler = cast<RoleMatchDelegate @>(@Tech_RoleMatch);

		RoleConfigs::Register(cfg);
	}

}
