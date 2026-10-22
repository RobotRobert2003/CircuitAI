#include "../define.as"
#include "../unit.as"
#include "../helpers/common/generic_helpers.as"
#include "../systems/combat/porc_policy.as"
#include "../systems/combat/spam.as"
#include "../systems/combat/scout_raid.as"
#include "../systems/team/ferry.as"
#include "../systems/amphibious/amphibious_ops.as"

namespace Military {

    // Cohort travel policy; native targeting/terrain/safety may stop the move.
    // Called only after a contact/objective is cleared, not per member/frame.
    AIFloat3 AiGroundObjective(CCircuitUnit@ u, const AIFloat3& in previous)
    {
        if (u is null) return previous;
        const AIFloat3 pos = u.GetPos(ai.frame);
        const int lane = Lanes::BestLane(Lanes::BOT);
        if (lane >= 0) {
            float nearest = 1e30f;
            int step = 0;
            // Bounded samples follow lane bends instead of a map-wide search.
            for (int i = 0; i <= 20; ++i) {
                const float distance = pos.SqDistance2D(aiBattle.GetLanePoint(lane, float(i) / 20.0f));
                if (distance < nearest) { nearest = distance; step = i; }
            }
            return aiBattle.GetLanePoint(lane, float(AiMin(20, step + 2)) / 20.0f);
        }
        const array<AIFloat3> starts = Lanes::EnemyStarts();
        AIFloat3 goal = previous;
        float nearest = 1e30f;
        for (uint i = 0; i < starts.length(); ++i) {
            const float distance = pos.SqDistance2D(starts[i]);
            if (distance > 256.0f * 256.0f && distance < nearest) { nearest = distance; goal = starts[i]; }
        }
        return goal;
    }

	// ==================== Hooks (config / role-driven) ====================

	IUnitTask@ AiMakeTask(CCircuitUnit@ u)
	{
		// A transport is never spam and never subject to a role's military
		// policy: it exists to carry, and the only task that carries is the
		// native CFerryTask that DefaultMakeTask hands a TRANS-role unit.
		// TECH's handler returns null for every military unit below +50 metal
		// income - right for its army, fatal here: the ferry transport arrives
		// at +20, sat task-less for thousands of frames, and every donation
		// walked because TryCarry refuses a transport with no task. Decided
		// here, role-independently, before any policy sees the unit.
		if (u !is null && Team::Ferry::IsFerryTransport(u.circuitDef)) {
			return aiMilitaryMgr.DefaultMakeTask(u);
		}

		// Super statics - nuke and EMP silos, Juno, Perdition, Catalyst - are
		// commandfire weapons: they fire ONLY on an explicit order, and the only
		// thing that orders them is the native CSuperTask. A role's military
		// policy is about its army; TECH's returns null for every unit below
		// +50 metal income, which left its Juno and Catalyst with no task and
		// no target selection until the economy caught up. Same shape as the
		// transport guard above: decided here, before any policy sees the unit.
		if (u !is null && u.circuitDef !is null && !u.circuitDef.IsMobile()
			&& u.circuitDef.IsRoleAny(Unit::Role::SUPER.mask)) {
			GenericHelpers::LogUtil("[Military] super static " + u.circuitDef.GetName() + "(" + u.id
				+ ") -> native CSuperTask", 1);
			return aiMilitaryMgr.DefaultMakeTask(u);
		}

		IUnitTask@ t = TechHeavyDelivery::MilitaryTask(u);
        if (t !is null) return t;
        @t = AmphibiousOps::MilitaryTask(u);
        if (t !is null) return t;
        @t = TechFlank::MilitaryTask(u);
		if (t !is null) return t;
		@t = Spam::MilitaryMakeTask(u);   // spam units join their factory's route
		if (t !is null) return t;
		@t = ScoutRaid::MilitaryMakeTask(u);   // D-296: non-spam land scouts raid the backline
		if (t !is null) return t;
		// Preserve specialist owners above; production is unaffected.
		@t = aiMilitaryMgr.TryMakeRangedTask(u);
		if (t !is null) return t;

		RoleConfig@ cfg = (Global::profileController is null) ? null : Global::profileController.RoleCfg;
		if (cfg !is null && cfg.MilitaryAiMakeTaskHandler !is null) {
			@t = cfg.MilitaryAiMakeTaskHandler(u);
		}
		else {
			@t = aiMilitaryMgr.DefaultMakeTask(u);
		}

		return t;
	}

	void AiTaskAdded(IUnitTask@ task)
	{
		RoleConfig@ cfg = (Global::profileController is null) ? null : Global::profileController.RoleCfg;
		if (cfg !is null && cfg.MilitaryAiTaskAddedHandler !is null) {
			cfg.MilitaryAiTaskAddedHandler(task);
		}
	}

	void AiTaskRemoved(IUnitTask@ task, bool done)
	{
		Spam::OnTaskRemoved(task);
		ScoutRaid::TaskRemoved(task);
		TechFlank::TaskRemoved(task);
        AmphibiousOps::TaskRemoved(task);
		RoleConfig@ cfg = (Global::profileController is null) ? null : Global::profileController.RoleCfg;
		if (cfg !is null && cfg.MilitaryAiTaskRemovedHandler !is null) {
			cfg.MilitaryAiTaskRemovedHandler(task, done);
		}
	}

	void AiUnitAdded(CCircuitUnit@ unit, Unit::UseAs usage)
	{
		Team::Ferry::OnUnitAdded(unit);   // claim a transport, ours or a gift

		// Delegate to role-specific handler if registered
		RoleConfig@ cfg = (Global::profileController is null) ? null : Global::profileController.RoleCfg;
		if (cfg !is null && cfg.MilitaryAiUnitAdded !is null) {
			cfg.MilitaryAiUnitAdded(unit, usage);
		}
	}

	void AiUnitRemoved(CCircuitUnit@ unit, Unit::UseAs usage)
	{
        TechHeavyDelivery::Removed(unit);
		Team::Ferry::OnUnitRemoved(unit);
		TechFlank::UnitRemoved(unit);
        AmphibiousOps::UnitRemoved(unit);
        ScoutRaid::UnitRemoved(unit);

		// Delegate to role-specific handler if registered
		RoleConfig@ cfg = (Global::profileController is null) ? null : Global::profileController.RoleCfg;
		if (cfg !is null && cfg.MilitaryAiUnitRemoved !is null) {
			cfg.MilitaryAiUnitRemoved(unit, usage);
		}
	}

	void AiLoad(IStream& istream)
	{
        AmphibiousOps::Reset(); // ephemeral routes are rebuilt through Military::AiMakeTask
        AmphibiousOps::lastTick = -100000; // a loaded frame may precede the last live update
        FrontOpener::Load(); // retire ephemeral opener task ownership after reload
        ScoutRaid::Reset(); // raid routes are rebuilt through Military::AiMakeTask
        ScoutRaid::lastTick = -100000;
	}

	void AiSave(OStream& ostream)
	{
	}

	void AiMakeDefence(int cluster, const AIFloat3& in pos)
	{
		RoleConfig@ cfg = (Global::profileController is null) ? null : Global::profileController.RoleCfg;
		if(cfg !is null && cfg.AiMakeDefenceHandler !is null) {
			cfg.AiMakeDefenceHandler(cluster, pos);
		} else {
			if ((ai.frame > 10 * MINUTE)
			|| (aiEconomyMgr.metal.income > 10.f)
			|| (aiEnemyMgr.mobileThreat > 0.f))
			{
				GenericHelpers::LogUtil("Military::AiMakeDefence", 4);
				Porc::MakeDefence(cluster, pos);   // shared policy, then native placement
			}
		}
		//AiLog("SMRT: Frame - " + ai.frame);
		// if ((ai.frame > 10 * MINUTE)
		// 	|| (aiEconomyMgr.metal.income > 10.f)
		// 	|| (aiEnemyMgr.mobileThreat > 0.f))
		// {
		// 	GenericHelpers::LogUtil("Military::AiMakeDefence", 4);
		// 	aiMilitaryMgr.DefaultMakeDefence(cluster, pos);
		// }
	}

	// ==================== Enemy Threat Layer Cache & Helpers ====================

	// Cached per-layer threats and weights, updated periodically from Main::AiUpdate.
	float g_cachedTotalAirThreat    = 0.f;
	float g_cachedTotalSurfaceThreat = 0.f;
	float g_cachedTotalWaterThreat  = 0.f;
	float g_cachedAirWeight         = 0.f;
	float g_cachedSurfaceWeight     = 0.f;
	float g_cachedWaterWeight       = 0.f;

	// Cached per-role threats used by higher-level logic (optional, but prepared here for reuse).
	dictionary g_cachedRoleThreats; // key: string roleName, value: float threat

	// ==================== Enemy Cost Cache ====================

	// Cached per-role enemy costs and aggregated layer costs.
	dictionary g_cachedRoleCosts;    // key: string roleName, value: float cost
	float g_cachedTotalAirCost      = 0.f;
	float g_cachedTotalSurfaceCost  = 0.f;
	float g_cachedTotalWaterCost    = 0.f;

	// Derived, cached enemy surface metrics for use by roles (to avoid recomputing in each role).
	float g_cachedEnemySurfaceCostPerPlayer = 0.f;
	float g_cachedEnemyAirCostPerPlayer     = 0.f;
	float g_cachedEnemyWaterCostPerPlayer   = 0.f;
	int   g_cachedEnemyPlayerCount          = 1;

	// Update the cached enemy threat information for roles and layers.
	// Intended to be called every ~10 seconds from Main::AiUpdate to amortize expensive queries.
	void UpdateEnemyThreatCache()
	{
		g_cachedRoleThreats.deleteAll();

		float mobileThreat = aiEnemyMgr.mobileThreat;
		if (!(mobileThreat == mobileThreat) || mobileThreat < 0.f) {
			mobileThreat = 0.f;
		} else if (mobileThreat > 1e12f) {
			// Clamp garbage large values
			mobileThreat = 0.f;
		} else if (mobileThreat > 0.f && mobileThreat < 1e-38f) {
			// Clamp denormals to zero
			mobileThreat = 0.f;
		}
		GenericHelpers::LogUtil("[Military] UpdateEnemyThreatCache: start (frame=" + ai.frame + " mobileThreat=" + mobileThreat + ")", 3);

		// Helper lambda-like local function via manual loop for each known role in behaviour.
		array<string> roles;
		roles.insertLast("anti_air");
		roles.insertLast("air");
		roles.insertLast("bomber");
		// Surface roles as defined in FactoryProduction::SURFACE_ROLES
		for (uint i = 0; i < FactoryProduction::SURFACE_ROLES.length(); ++i) {
			roles.insertLast(FactoryProduction::SURFACE_ROLES[i]);
		}
		roles.insertLast("sub");
		roles.insertLast("anti_sub");

		// GetEnemyThreat takes a role *index*, not a role mask: it indexes a
		// 64-entry array directly. This read roleMaskCache and passed the mask
		// (1 << index), which for "super" is 262144 - a read two megabytes past
		// the array that faulted at f=180 on Eight Horses. roleTypeCache holds
		// the same roles in indexed form; native now bounds-checks as well.
		int roleType = 0;
		for (uint i = 0; i < roles.length(); ++i) {
			const string roleName = roles[i];
			float threat = 0.f;
			if (FactoryProduction::roleTypeCache.get(roleName, roleType)) {
				GenericHelpers::LogUtil("[Military] UpdateEnemyThreatCache: querying role '" + roleName + "' type=" + roleType, 4);
				threat = aiEnemyMgr.GetEnemyThreat(roleType);
				GenericHelpers::LogUtil("[Military] UpdateEnemyThreatCache: threat retrieved=" + threat, 4);
			} else {
				GenericHelpers::LogUtil("[Military] UpdateEnemyThreatCache: no role index for '" + roleName + "'", 2);
			}
			// Sanitize threat from enemy manager
			if (!(threat == threat) || threat < 0.f) {
				threat = 0.f;
			} else if (threat > 1e12f) {
				// Clamp garbage large values
				threat = 0.f;
			} else if (threat > 0.f && threat < 1e-38f) {
				// Clamp denormals to zero to avoid pathological floats
				threat = 0.f;
			}
			
			GenericHelpers::LogUtil("[Military] UpdateEnemyThreatCache: setting dictionary for " + roleName, 4);
			g_cachedRoleThreats.set(roleName, threat);
			GenericHelpers::LogUtil("[Military] Threat cache role '" + roleName + "' = " + threat, 4);
		}

		// Aggregate into layers using the cached role threats
		g_cachedTotalAirThreat     = 0.f;
		g_cachedTotalSurfaceThreat = 0.f;
		g_cachedTotalWaterThreat   = 0.f;

		// Air: anti-air + air + bomber
		g_cachedTotalAirThreat += GetCachedRoleThreat("anti_air");
		g_cachedTotalAirThreat += GetCachedRoleThreat("air");
		g_cachedTotalAirThreat += GetCachedRoleThreat("bomber");

		// Surface: assault/skirm/riot/artillery/heavy/super/raider/support/builder
		for (uint i = 0; i < FactoryProduction::SURFACE_ROLES.length(); ++i) {
			g_cachedTotalSurfaceThreat += GetCachedRoleThreat(FactoryProduction::SURFACE_ROLES[i]);
		}

		// Water: submarines + anti-submarines
		g_cachedTotalWaterThreat += GetCachedRoleThreat("sub");
		g_cachedTotalWaterThreat += GetCachedRoleThreat("anti_sub");

		// Sanitize aggregates
		if (!(g_cachedTotalAirThreat == g_cachedTotalAirThreat) || g_cachedTotalAirThreat < 0.f) {
			g_cachedTotalAirThreat = 0.f;
		}
		if (!(g_cachedTotalSurfaceThreat == g_cachedTotalSurfaceThreat) || g_cachedTotalSurfaceThreat < 0.f) {
			g_cachedTotalSurfaceThreat = 0.f;
		}
		if (!(g_cachedTotalWaterThreat == g_cachedTotalWaterThreat) || g_cachedTotalWaterThreat < 0.f) {
			g_cachedTotalWaterThreat = 0.f;
		}

		float totalLayerThreat = g_cachedTotalAirThreat + g_cachedTotalSurfaceThreat + g_cachedTotalWaterThreat;
		if (!(totalLayerThreat == totalLayerThreat) || totalLayerThreat <= 0.f) {
			totalLayerThreat = 1.f;
		}
		g_cachedAirWeight     = g_cachedTotalAirThreat     / totalLayerThreat;
		g_cachedSurfaceWeight = g_cachedTotalSurfaceThreat / totalLayerThreat;
		g_cachedWaterWeight   = g_cachedTotalWaterThreat   / totalLayerThreat;

		GenericHelpers::LogUtil(
			"[Military] Threat cache aggregates | air=" + g_cachedTotalAirThreat +
			" surface=" + g_cachedTotalSurfaceThreat +
			" water=" + g_cachedTotalWaterThreat +
			" | weights air=" + g_cachedAirWeight +
			" surface=" + g_cachedSurfaceWeight +
			" water=" + g_cachedWaterWeight,
			3
		);
	}

	// Update the cached enemy cost information for roles and layers.
	// Intended to be called every ~10 seconds from Main::AiUpdate to amortize expensive queries.
	void UpdateEnemyCostCache()
	{
		g_cachedRoleCosts.deleteAll();
		GenericHelpers::LogUtil("[Military] UpdateEnemyCostCache: start (frame=" + ai.frame + ")", 3);

		array<string> roles;
		roles.insertLast("anti_air");
		roles.insertLast("air");
		roles.insertLast("bomber");
		// Surface roles as defined in FactoryProduction::SURFACE_ROLES
		for (uint i = 0; i < FactoryProduction::SURFACE_ROLES.length(); ++i) {
			roles.insertLast(FactoryProduction::SURFACE_ROLES[i]);
		}
		roles.insertLast("sub");
		roles.insertLast("anti_sub");

		// Role *index*, not mask - see UpdateEnemyThreatCache above.
		int roleType = 0;
		for (uint i = 0; i < roles.length(); ++i) {
			const string roleName = roles[i];
			float cost = 0.f;
			if (FactoryProduction::roleTypeCache.get(roleName, roleType)) {
				GenericHelpers::LogUtil("[Military] UpdateEnemyCostCache: querying role '" + roleName + "' type=" + roleType, 4);
				cost = aiEnemyMgr.GetEnemyCost(roleType);
			} else {
				GenericHelpers::LogUtil("[Military] UpdateEnemyCostCache: no role index for '" + roleName + "'", 2);
			}
			// Sanitize cost from enemy manager
			if (!(cost == cost) || cost < 0.f) {
				cost = 0.f;
			} else if (cost > 1e12f) {
				// Clamp garbage large values
				cost = 0.f;
			} else if (cost > 0.f && cost < 1e-38f) {
				// Clamp denormals to zero to avoid pathological floats
				cost = 0.f;
			}
			g_cachedRoleCosts.set(roleName, cost);
			GenericHelpers::LogUtil("[Military] Cost cache role '" + roleName + "' = " + cost, 4);
		}

		// Aggregate into layers using the cached role costs
		g_cachedTotalAirCost     = 0.f;
		g_cachedTotalSurfaceCost = 0.f;
		g_cachedTotalWaterCost   = 0.f;

		// Air: anti-air + air + bomber
		g_cachedTotalAirCost += GetCachedRoleCost("anti_air");
		g_cachedTotalAirCost += GetCachedRoleCost("air");
		g_cachedTotalAirCost += GetCachedRoleCost("bomber");

		// Surface: assault/skirm/riot/artillery/heavy/super/raider/support/builder
		for (uint i = 0; i < FactoryProduction::SURFACE_ROLES.length(); ++i) {
			g_cachedTotalSurfaceCost += GetCachedRoleCost(FactoryProduction::SURFACE_ROLES[i]);
		}

		// Water: submarines + anti-submarines
		g_cachedTotalWaterCost += GetCachedRoleCost("sub");
		g_cachedTotalWaterCost += GetCachedRoleCost("anti_sub");

		g_cachedEnemyPlayerCount = ai.GetEnemyTeamSize();
		if (g_cachedEnemyPlayerCount < 1) {
			g_cachedEnemyPlayerCount = 1;
		}
		g_cachedEnemySurfaceCostPerPlayer = g_cachedTotalSurfaceCost / float(g_cachedEnemyPlayerCount);
		g_cachedEnemyAirCostPerPlayer     = g_cachedTotalAirCost / float(g_cachedEnemyPlayerCount);
		g_cachedEnemyWaterCostPerPlayer   = g_cachedTotalWaterCost / float(g_cachedEnemyPlayerCount);

		GenericHelpers::LogUtil(
			"[Military] Cost cache aggregates | air=" + g_cachedTotalAirCost +
			" surface=" + g_cachedTotalSurfaceCost +
			" water=" + g_cachedTotalWaterCost +
			" | enemyPlayerCount=" + g_cachedEnemyPlayerCount +
			" surfacePerPlayer=" + g_cachedEnemySurfaceCostPerPlayer +
			" airPerPlayer=" + g_cachedEnemyAirCostPerPlayer +
			" waterPerPlayer=" + g_cachedEnemyWaterCostPerPlayer,
			3
		);
	}

	// Helper to safely read a cached role threat; returns 0 if missing.
	float GetCachedRoleThreat(const string &in roleName)
	{
		float threat = 0.f;
		if (g_cachedRoleThreats.get(roleName, threat)) {
			// Centralized NaN/negative/denormal guards for all threat consumers
			if (!(threat == threat) || threat < 0.f) {
				threat = 0.f;
			} else if (threat > 1e12f) {
				threat = 0.f;
			} else if (threat > 0.f && threat < 1e-38f) {
				threat = 0.f;
			}
			return threat;
		}
		return 0.f;
	}

	// Helper to safely read a cached role cost; returns 0 if missing.
	float GetCachedRoleCost(const string &in roleName)
	{
		float cost = 0.f;
		if (g_cachedRoleCosts.get(roleName, cost)) {
			// Centralized NaN/negative/denormal guards for all cost consumers
			if (!(cost == cost) || cost < 0.f) {
				cost = 0.f;
			} else if (cost > 1e12f) {
				cost = 0.f;
			} else if (cost > 0.f && cost < 1e-38f) {
				cost = 0.f;
			}
			return cost;
		}
		return 0.f;
	}

	// Convenience accessors for derived enemy surface metrics.
	float GetEnemySurfaceCostPerPlayer()
	{
		return g_cachedEnemySurfaceCostPerPlayer;
	}

	float GetEnemyAirCostPerPlayer()
	{
		return g_cachedEnemyAirCostPerPlayer;
	}

	float GetEnemyWaterCostPerPlayer()
	{
		return g_cachedEnemyWaterCostPerPlayer;
	}

	int GetEnemyPlayerCount()
	{
		return g_cachedEnemyPlayerCount;
	}

	// Convenience accessor to retrieve current cached layer weights and totals, without recomputing.
	void GetEnemyLayerWeights(float &out airWeight, float &out surfaceWeight, float &out waterWeight,
							  float &out totalAirThreat, float &out totalSurfaceThreat, float &out totalWaterThreat)
	{
		airWeight           = g_cachedAirWeight;
		surfaceWeight       = g_cachedSurfaceWeight;
		waterWeight         = g_cachedWaterWeight;
		totalAirThreat      = g_cachedTotalAirThreat;
		totalSurfaceThreat  = g_cachedTotalSurfaceThreat;
		totalWaterThreat    = g_cachedTotalWaterThreat;
	}

}  // namespace Military
