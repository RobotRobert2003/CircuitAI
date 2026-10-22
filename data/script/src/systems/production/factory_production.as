

#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/construction/economy_helpers.as"
#include "../../global.as"

namespace FactoryProduction {

    // ==================== Configuration Constants ====================

    // Economic tier thresholds by metal income
    const array<float> TIER_INCOME_THRESHOLDS = {20.0f, 40.0f, 80.0f, 999999.0f};

    // Response scaling: how much enemy threat boosts role probability
    const float THREAT_RESPONSE_SCALE = 0.8f;

    // Batch size: repeat last picked unit this many times before rerolling
    const int BATCH_REUSE_COUNT = 3;

    // Role names that must align with behaviour.json role definitions
    // Full list from behaviour.json line 43:
    // builder, scout, raider, riot, assault, skirmish, artillery, anti_air, anti_sub, anti_heavy, bomber, support, mine, transport, air, sub, static, heavy, super, commander
    const array<string> KNOWN_ROLES = {
        "builder", "scout", "raider", "riot", "assault", "skirmish", 
        "artillery", "anti_air", "anti_sub", "anti_heavy", "bomber",
        "support", "mine", "transport", "air", "sub", "static", "heavy", "super", "commander"
    };

    // ==================== Global State ====================

    // Cache: role name -> circuit role mask
    dictionary roleMaskCache;
    // Role *indices*, not masks. The two are not interchangeable and the
    // difference is not visible at a call site: a mask is 1 << index, so
    // passing one where the other is wanted compiles, runs, and reads far out
    // of bounds. CEnemyManager::GetEnemyThreat / GetEnemyCost index a 64-entry
    // array by index; Military's caches query them, and did so with masks until
    // an access violation at f=180 on Eight Horses made it obvious. Anything
    // taking a "Type" wants this table; anything taking a "Mask" wants the one
    // above.
    dictionary roleTypeCache;

    // Cache: unit name -> array<string> of role names it belongs to
    // NOT USED - scanning units during initialization causes engine crashes
    // Use GetUnitsWithRole() for on-demand role queries during gameplay instead
    dictionary unitRoleCache;

    // Per-factory batch tracking: factory name -> {def: CCircuitDef@, count: int}
    // No longer used now that we enqueue full batches immediately.
    // dictionary factoryBatchState;

    // External priority queue: array of CCircuitDef@ to build before normal logic
    array<CCircuitDef@> priorityQueue;

    // ==================== Factory Configuration Structure ====================

    // Per-factory config: roles, tier probabilities, and unit mappings
    class FactoryConfig {
        string factoryName;
        array<string> roles;                    // Ordered list of roles this factory considers
        array<array<float>> tierProbabilities;  // Per-tier probability arrays (one per tier)
        dictionary unitsByRole;                 // role name -> array<string> of unit names

        FactoryConfig(const string &in name) {
            factoryName = name;
        }

        // Add a role with its unit list
        void AddRole(const string &in roleName, const array<string> &in unitNames) {
            roles.insertLast(roleName);
            unitsByRole.set(roleName, unitNames);
        }

        // Set tier probability array (must match roles.length)
        void SetTierProbabilities(uint tier, const array<float> &in probs) {
            while (tierProbabilities.length() <= tier) {
                array<float> empty;
                tierProbabilities.insertLast(empty);
            }
            tierProbabilities[tier] = probs;
        }

        // Get units for a role
        array<string> GetUnitsForRole(const string &in roleName) const {
            if (!unitsByRole.exists(roleName)) {
                array<string> empty;
                return empty;
            }
            array<string>@ units = null;
            unitsByRole.get(roleName, @units);
            if (units is null) {
                array<string> empty;
                return empty;
            }
            return units;
        }
    }

    // Registry of all factory configs
    dictionary factoryConfigs; // factory name -> FactoryConfig@

    // ==================== Initialization ====================

    void Initialize() {
        GenericHelpers::LogUtil("[FactoryProduction] Initialize() called - starting initialization", 2);
        
        GenericHelpers::LogUtil("[FactoryProduction] Calling BuildRoleCaches()", 2);
        BuildRoleCaches();
        GenericHelpers::LogUtil("[FactoryProduction] BuildRoleCaches() completed", 2);
        
        GenericHelpers::LogUtil("[FactoryProduction] Calling RegisterFactoryConfigs()", 2);
        RegisterFactoryConfigs();
        GenericHelpers::LogUtil("[FactoryProduction] RegisterFactoryConfigs() completed", 2);
        
        GenericHelpers::LogUtil("[FactoryProduction] Initialization complete:", 2);
        GenericHelpers::LogUtil("  - Roles cached: " + roleMaskCache.getSize() + "/" + KNOWN_ROLES.length(), 2);
        GenericHelpers::LogUtil("  - Unit-role mappings: on-demand (scan during gameplay, not init)", 2);
        GenericHelpers::LogUtil("  - Factories registered: " + factoryConfigs.getSize(), 2);
    }

    // Build role mask and unit-role caches at startup
    void BuildRoleCaches() {
        GenericHelpers::LogUtil("[FactoryProduction] BuildRoleCaches: Clearing existing caches", 3);
        roleMaskCache.deleteAll();
        roleTypeCache.deleteAll();
        unitRoleCache.deleteAll();

        GenericHelpers::LogUtil("[FactoryProduction] BuildRoleCaches: Building role caches for " + KNOWN_ROLES.length() + " roles", 2);

        // Cache role masks for fast lookup - use pre-initialized Unit::Role namespace
        // to avoid calling GetTypeMask during iteration which might cause issues
        GenericHelpers::LogUtil("[FactoryProduction] BuildRoleCaches: Caching role masks from Unit::Role namespace", 3);
        roleMaskCache.set("builder", int(Unit::Role::BUILDER.mask));
        roleMaskCache.set("scout", int(Unit::Role::SCOUT.mask));
        roleMaskCache.set("raider", int(Unit::Role::RAIDER.mask));
        roleMaskCache.set("riot", int(Unit::Role::RIOT.mask));
        roleMaskCache.set("assault", int(Unit::Role::ASSAULT.mask));
        roleMaskCache.set("skirmish", int(Unit::Role::SKIRM.mask));
        roleMaskCache.set("artillery", int(Unit::Role::ARTY.mask));
        roleMaskCache.set("anti_air", int(Unit::Role::AA.mask));
        roleMaskCache.set("anti_sub", int(Unit::Role::AS.mask));
        roleMaskCache.set("anti_heavy", int(Unit::Role::AH.mask));
        roleMaskCache.set("bomber", int(Unit::Role::BOMBER.mask));
        roleMaskCache.set("support", int(Unit::Role::SUPPORT.mask));
        roleMaskCache.set("mine", int(Unit::Role::MINE.mask));
        roleMaskCache.set("transport", int(Unit::Role::TRANS.mask));
        roleMaskCache.set("air", int(Unit::Role::AIR.mask));
        roleMaskCache.set("sub", int(Unit::Role::SUB.mask));
        roleMaskCache.set("static", int(Unit::Role::STATIC.mask));
        roleMaskCache.set("heavy", int(Unit::Role::HEAVY.mask));
        roleMaskCache.set("super", int(Unit::Role::SUPER.mask));
        roleMaskCache.set("commander", int(Unit::Role::COMM.mask));

        // Same roles, indexed form. See the roleTypeCache comment above.
        roleTypeCache.set("builder", int(Unit::Role::BUILDER.type));
        roleTypeCache.set("scout", int(Unit::Role::SCOUT.type));
        roleTypeCache.set("raider", int(Unit::Role::RAIDER.type));
        roleTypeCache.set("riot", int(Unit::Role::RIOT.type));
        roleTypeCache.set("assault", int(Unit::Role::ASSAULT.type));
        roleTypeCache.set("skirmish", int(Unit::Role::SKIRM.type));
        roleTypeCache.set("artillery", int(Unit::Role::ARTY.type));
        roleTypeCache.set("anti_air", int(Unit::Role::AA.type));
        roleTypeCache.set("anti_sub", int(Unit::Role::AS.type));
        roleTypeCache.set("anti_heavy", int(Unit::Role::AH.type));
        roleTypeCache.set("bomber", int(Unit::Role::BOMBER.type));
        roleTypeCache.set("support", int(Unit::Role::SUPPORT.type));
        roleTypeCache.set("mine", int(Unit::Role::MINE.type));
        roleTypeCache.set("transport", int(Unit::Role::TRANS.type));
        roleTypeCache.set("air", int(Unit::Role::AIR.type));
        roleTypeCache.set("sub", int(Unit::Role::SUB.type));
        roleTypeCache.set("static", int(Unit::Role::STATIC.type));
        roleTypeCache.set("heavy", int(Unit::Role::HEAVY.type));
        roleTypeCache.set("super", int(Unit::Role::SUPER.type));
        roleTypeCache.set("commander", int(Unit::Role::COMM.type));
        
        GenericHelpers::LogUtil("[FactoryProduction] BuildRoleCaches: Cached " + roleMaskCache.getSize()
            + " role masks and " + roleTypeCache.getSize() + " role indices", 2);

        // Build unit -> roles mapping - DISABLED due to crashes
        // The issue is that calling GetCircuitDef/IsRoleAny during early initialization
        // causes engine crashes. We'll use factory configs exclusively instead.
        GenericHelpers::LogUtil("[FactoryProduction] BuildRoleCaches: Skipping unit-role pre-cache (causes engine crashes)", 2);
        GenericHelpers::LogUtil("[FactoryProduction] BuildRoleCaches: Use factory configs or GetUnitsWithRoleByMask() for role queries", 2);
    }

    // Register per-factory role/unit configurations
    void RegisterFactoryConfigs() {
        GenericHelpers::LogUtil("[FactoryProduction] RegisterFactoryConfigs: Clearing existing configs", 3);
        factoryConfigs.deleteAll();

        GenericHelpers::LogUtil("[FactoryProduction] RegisterFactoryConfigs: Registering factories from modular configs", 2);
        
        // Modular config registration (organized by factory type)
        SeaConfigs::RegisterSeaFactories();
        HoverConfigs::RegisterHoverFactories();
        BotConfigs::RegisterBotFactories();
        VehicleConfigs::RegisterVehicleFactories();
        AirConfigs::RegisterAirFactories();
        
        GenericHelpers::LogUtil("[FactoryProduction] RegisterFactoryConfigs: Registered " + factoryConfigs.getSize() + " total factory configs", 2);
    }

    // ==================== Tier and Threat Helpers ====================

    int GetEconomicTier(float metalIncome) {
        for (uint i = 0; i < TIER_INCOME_THRESHOLDS.length(); ++i) {
            if (metalIncome < TIER_INCOME_THRESHOLDS[i]) {
                return int(i);
            }
        }
        return int(TIER_INCOME_THRESHOLDS.length()) - 1;
    }

    // Normalize raw threat values coming from managers into a safe, non-negative value.
    // - NaN or negative values are treated as 0.
    // - Extremely small magnitudes (denormals, logging noise) are clamped to 0.
    float NormalizeThreat(float value)
    {
        if (!(value == value) || value < 0.0f) {
            return 0.0f;
        }
        // Treat ultra-small values as noise; they should not influence decisions.
        if (value > 0.0f && value < 1e-6f) {
            return 0.0f;
        }
        return value;
    }

    // Compute a per-role threat factor in [0, 1] based on the role's threat share.
    //  - 0   => effectively no threat for this role (weight should be suppressed).
    //  - 0..1 => proportion of total threat attributed to this role.
    // The factor is intentionally simple so that base economic tier probabilities
    // remain the primary driver, while threat gates roles on/off when needed.
    float ComputeRoleThreatFactor(const string &in roleName, float roleThreat, float totalThreat)
    {
        float normTotal = NormalizeThreat(totalThreat);
        float normRole  = NormalizeThreat(roleThreat);

        if (normTotal <= 0.0f || normRole <= 0.0f) {
            return 0.0f;
        }

        float ratio = normRole / normTotal;
        if (!(ratio == ratio) || ratio < 0.0f) {
            ratio = 0.0f;
        }
        if (ratio > 1.0f) {
            ratio = 1.0f;
        }

        // For future tuning we could apply a non-linear curve here, but keeping it
        // linear keeps behavior easy to reason about.
        return ratio;
    }

    // Apply threat-based weighting to role probabilities using cached enemy threat data.
    array<float> ApplyThreatWeighting(const array<float> &in baseProbs, const array<string> &in roles) {
        array<float> weighted;
        weighted.resize(baseProbs.length());

        // Use cached total mobile threat as an approximation
        float totalThreat = NormalizeThreat(aiEnemyMgr.mobileThreat);

        if (totalThreat <= 0.0f) {
            GenericHelpers::LogUtil("[FactoryProduction] ApplyThreatWeighting: no valid enemy threat, using filtered base probabilities", 3);
        } else {
            GenericHelpers::LogUtil("[FactoryProduction] Applying threat weighting (total threat: " + totalThreat + ")", 3);
        }

        // Only iterate across indices that are valid for both arrays
        uint sharedLen = baseProbs.length();
        if (roles.length() < sharedLen) {
            sharedLen = roles.length();
        }

        // Boost probabilities based on enemy role threat
        for (uint i = 0; i < sharedLen; ++i) {
            const string roleName = roles[i];
            float base = baseProbs[i];

            // Prefer cached per-role threat where available.
            float rawRoleThreat = Military::GetCachedRoleThreat(roleName);
            float roleThreatFactor = ComputeRoleThreatFactor(roleName, rawRoleThreat, totalThreat);

            // Logic:
            // 1. If threat factor > 0, boost base weight.
            // 2. If threat factor <= 0:
            //    - If role is REACTIVE (useless without target), weight = 0.
            //    - Otherwise, weight = base (don't suppress general roles).
            
            float weight = base;
            
            if (roleThreatFactor > 0.0f) {
                float boost = 1.0f + (THREAT_RESPONSE_SCALE * roleThreatFactor);
                weight = base * boost;
            } else {
                // No threat for this role (or no threat at all)
                // Suppress specific reactive roles that are wasteful without targets
                if (roleName == "anti_air" || roleName == "anti_sub" || roleName == "anti_heavy") {
                    weight = 0.0f;
                    if (base > 0.0f) {
                        GenericHelpers::LogUtil("  - Role '" + roleName + "' suppressed (reactive role with no threat)", 3);
                    }
                } else {
                    weight = base;
                }
            }

            weighted[i] = weight;

            if (rawRoleThreat > 0.0f) {
                GenericHelpers::LogUtil(
                    "  - Role '" + roleName + "': threat=" + rawRoleThreat +
                    ", factor=" + roleThreatFactor +
                    ", base=" + base +
                    ", weighted=" + weighted[i],
                    3
                );
            }
        }

        // Copy through any remaining probabilities unchanged if baseProbs is longer than roles
        for (uint i = sharedLen; i < baseProbs.length(); ++i) {
            weighted[i] = baseProbs[i];
        }

        return weighted;
    }

    // ==================== Unit Selection ====================

    // Pick a role index from weighted probabilities over a filtered set of role indices.
    // "roleIndices" contains the indices into cfg.roles that are currently valid (have candidates).
    // Returns the chosen index into cfg.roles, or -1 if no valid role was found.
    int PickRoleIndex(const array<float> &in weights, const array<int> &in roleIndices) {
        if (weights.length() == 0 || roleIndices.length() == 0) {
            return -1;
        }

        // Build a compact weight array aligned with roleIndices
        array<float> filtered;
        filtered.resize(roleIndices.length());
        for (uint i = 0; i < roleIndices.length(); ++i) {
            int idx = roleIndices[i];
            if (idx < 0 || idx >= int(weights.length())) {
                filtered[i] = 0.0f;
            } else {
                filtered[i] = weights[idx];
            }
        }

        int pickLocal = AiDice(filtered);
        if (pickLocal < 0 || pickLocal >= int(roleIndices.length())) {
            return -1;
        }
        return roleIndices[pickLocal];
    }

    // Get all available units with a specific role by querying the role mask
    // Example: GetUnitsWithRole("anti_air") returns all anti-air units that are currently available
    // Note: This scans all units on-demand but is safe to call during gameplay (not initialization)
    array<CCircuitDef@> GetUnitsWithRole(const string &in roleName) {
        array<CCircuitDef@> results;
        
        // Get the role mask for the requested role
        int maskVal = 0;
        if (!roleMaskCache.get(roleName, maskVal) || maskVal == 0) {
            GenericHelpers::LogUtil("[FactoryProduction] GetUnitsWithRole('" + roleName + "'): Role not found in cache", 3);
            return results;
        }
        
        int frame = ai.frame;
        int defCount = ai.GetDefCount();
        
        // Scan all units for this role (safe during gameplay, just not during initialization)
        for (int idx = 0; idx < defCount; ++idx) {
            CCircuitDef@ def = ai.GetCircuitDef(idx);
            if (def is null) continue;
            
            // Check if unit has this role and is available
            if (def.IsRoleAny(maskVal) && def.IsAvailable(frame)) {
                results.insertLast(def);
            }
        }
        
        GenericHelpers::LogUtil("[FactoryProduction] GetUnitsWithRole('" + roleName + "'): Found " + results.length() + " available units", 3);
        return results;
    }

    // Get available unit defs for a role from factory config
    array<CCircuitDef@> GetAvailableUnitsForRole(const FactoryConfig@ cfg, const string &in roleName) {
        array<CCircuitDef@> available;
        if (cfg is null) return available;

        array<string> unitNames = cfg.GetUnitsForRole(roleName);
        int frame = ai.frame;

        for (uint i = 0; i < unitNames.length(); ++i) {
            CCircuitDef@ def = ai.GetCircuitDef(unitNames[i]);
            if (def !is null && def.IsAvailable(frame)) {
                available.insertLast(def);
            }
        }

        return available;
    }

    // ==================== Tactical Scoring Helpers ====================

    // Surface roles used to approximate "ground" enemy investment for layer weighting
    const array<string> SURFACE_ROLES = {
        "assault", "skirmish", "riot", "artillery", "heavy",
        "super", "raider", "support", "builder"
    };

    // Compute average health and speed across all candidates for normalization.
    void ComputeHealthAndSpeedAverages(const array<CCircuitDef@> &in candidates,
                                       float &out averageHealth, float &out averageSpeed)
    {
        float totalHealth = 0.f;
        float totalSpeed = 0.f;

        for (uint i = 0; i < candidates.length(); ++i) {
            totalHealth += candidates[i].health;
            totalSpeed  += candidates[i].speed;
        }

        const float denom = candidates.length() + 0.0f;
        averageHealth = (denom > 0.f) ? (totalHealth / denom) : 0.f;
        averageSpeed  = (denom > 0.f) ? (totalSpeed  / denom) : 0.f;
    }

    float ComputeLayerDamage(const CCircuitDef@ d, float wAir, float wSurf, float wWater)
    {
        float tAir   = d.GetAirThreat();
        float tSurf  = d.GetSurfThreat();
        float tWater = d.GetWaterThreat();

        // Guard against NaN threat values coming from the engine
        if (!(tAir == tAir))   tAir   = 0.f;
        if (!(tSurf == tSurf)) tSurf  = 0.f;
        if (!(tWater == tWater)) tWater = 0.f;

        float dmg = tAir  * wAir
                  + tSurf * wSurf
                  + tWater* wWater;

        // Final NaN guard
        if (!(dmg == dmg)) dmg = 0.f;
        return dmg;
    }

    float ComputeVersatilityBonus(const CCircuitDef@ d, float epsThreat)
    {
        int versatilityLayers = 0;
        if (d.GetAirThreat()   > epsThreat) ++versatilityLayers;
        if (d.GetSurfThreat()  > epsThreat) ++versatilityLayers;
        if (d.GetWaterThreat() > epsThreat) ++versatilityLayers;

        if (versatilityLayers <= 1) return 1.f;
        return 1.f + 0.12f * float(versatilityLayers - 1);
    }

    // Survivability: normalized sqrt(health), clamped to [0.6, 1.6].
    float ComputeSurvivability(const CCircuitDef@ d, float averageHealth)
    {
        float denom = sqrt(averageHealth) + 1.f;
        if (denom <= 0.f) return 1.f;

        float survivability = sqrt(d.health) / denom;
        if (survivability < 0.6f) survivability = 0.6f;
        if (survivability > 1.6f) survivability = 1.6f;
        return survivability;
    }

    // Mobility: bucketed reward based on speed ratio against average speed.
    float ComputeMobility(const CCircuitDef@ d, float averageSpeed)
    {
        float speedRatio = d.speed / (averageSpeed + 1.f);
        if (speedRatio > 1.3f) return 1.15f;
        if (speedRatio > 1.0f) return 1.05f;
        if (speedRatio > 0.8f) return 1.00f;
        if (speedRatio > 0.6f) return 0.90f;
        return 0.80f;
    }

    // Precompute raw cost-efficiency values for CostInversion
    // Precompute cost-efficiency terms used for CostInversion.
    void ComputeCostEfficiencyRaw(const array<CCircuitDef@> &in candidates,
                                  float airWeight, float surfaceWeight, float waterWeight,
                                  array<float> &out costEfficiencyRaw, float &out maxCostEfficiencyRaw)
    {
        costEfficiencyRaw.resize(candidates.length());
        maxCostEfficiencyRaw = 0.f;

        for (uint i = 0; i < candidates.length(); ++i) {
            CCircuitDef@ d = candidates[i];
            float layerDamage = ComputeLayerDamage(d, airWeight, surfaceWeight, waterWeight);
            if (!(layerDamage == layerDamage) || layerDamage < 0.f) {
                layerDamage = 0.f;
            }

            float healthRoot = sqrt(d.health);
            if (!(healthRoot == healthRoot) || healthRoot < 0.f) {
                healthRoot = 0.f;
            }

            float baseRaw = layerDamage * AiMax(1.f, healthRoot);

            float denom = d.costM + 1.f;
            if (denom <= 0.f) {
                denom = 1.f;
            }

            float costEffRaw = baseRaw / denom;
            if (!(costEffRaw == costEffRaw) || costEffRaw < 0.f) {
                costEffRaw = 0.f;
            }
            costEfficiencyRaw[i] = costEffRaw;
            if (costEffRaw > maxCostEfficiencyRaw) {
                maxCostEfficiencyRaw = costEffRaw;
            }
        }

        if (maxCostEfficiencyRaw <= 0.f) {
            maxCostEfficiencyRaw = 1.f;
        }
    }

    // Map raw cost efficiency into a mild multiplier in roughly [0.9, 1.1].
    float ComputeCostInversion(const array<float> &in costEfficiencyRaw, uint index, float maxCostEfficiencyRaw)
    {
        if (index >= costEfficiencyRaw.length()) {
            return 1.0f;
        }

        float raw = costEfficiencyRaw[index];
        if (!(raw == raw) || raw < 0.f) {
            raw = 0.f;
        }

        if (!(maxCostEfficiencyRaw == maxCostEfficiencyRaw) || maxCostEfficiencyRaw <= 0.f) {
            maxCostEfficiencyRaw = 1.f;
        }

        float ratio = raw / maxCostEfficiencyRaw;
        if (!(ratio == ratio)) {
            ratio = 0.f;
        }

        float inv = 0.9f + 0.2f * ratio;
        if (!(inv == inv)) {
            inv = 1.0f;
        }
        return inv;
    }

    // ==================== Tactical Scoring: Enhanced Pick ====================

    CCircuitDef@ EnhancedPickBestUnit(const string &in factoryName, const array<CCircuitDef@> &in candidates)
    {
        if (candidates.length() == 0) return null;
        if (candidates.length() == 1) return candidates[0];

        // 1. Aggregate enemy layer threats and weights
    float airWeight, surfaceWeight, waterWeight;
    float totalAirThreat, totalSurfaceThreat, totalWaterThreat;
    Military::GetEnemyLayerWeights(airWeight, surfaceWeight, waterWeight,
                 totalAirThreat, totalSurfaceThreat, totalWaterThreat);

        GenericHelpers::LogUtil(
            "[FactoryProduction] Enemy layer threats (air=" + totalAirThreat + ", surface=" + totalSurfaceThreat + ", water=" + totalWaterThreat + ") " +
            "weights (air=" + airWeight + ", surface=" + surfaceWeight + ", water=" + waterWeight + ")",
            4
        );

        // 2. Averages for survivability and mobility
    float averageHealth, averageSpeed;
    ComputeHealthAndSpeedAverages(candidates, averageHealth, averageSpeed);

        GenericHelpers::LogUtil(
            "[FactoryProduction] Candidate averages (health=" + averageHealth + ", speed=" + averageSpeed + ") for factory '" + factoryName + "'",
            4
        );

        // 3. Precompute cost-efficiency raw values
    array<float> costEfficiencyRaw;
    float maxCostEfficiencyRaw;
    ComputeCostEfficiencyRaw(candidates, airWeight, surfaceWeight, waterWeight,
                 costEfficiencyRaw, maxCostEfficiencyRaw);

        GenericHelpers::LogUtil(
            "[FactoryProduction] Max raw cost efficiency for factory '" + factoryName + "' = " + maxCostEfficiencyRaw,
            4
        );

        // 4. Score each candidate
    const float EPS_THREAT = 0.25f;  // minimum per-layer threat to count towards versatility
        array<float> scores;
        scores.resize(candidates.length());

        float bestScore = -1.f;
        int bestIdx = 0;

        for (uint i = 0; i < candidates.length(); ++i) {
            CCircuitDef@ d = candidates[i];

            float layerDamage      = ComputeLayerDamage(d, airWeight, surfaceWeight, waterWeight);
            float versatilityBonus = ComputeVersatilityBonus(d, EPS_THREAT);
            float survivability    = ComputeSurvivability(d, averageHealth);
            float mobility         = ComputeMobility(d, averageSpeed);
            float costInversion    = ComputeCostInversion(costEfficiencyRaw, i, maxCostEfficiencyRaw);

            float score = layerDamage * versatilityBonus * survivability * mobility * costInversion;

            // Guard against NaN/inf/negative scores before further adjustments
            if (!(score == score) || score <= 0.f) {
                score = 0.0001f;
            }

            // Submarine override emphasis
            bool subOverride = false;
            if (totalWaterThreat / (totalSurfaceThreat + 1.f) > 0.35f && d.GetWaterThreat() > 3.0f) {
                score *= 1.25f;
                subOverride = true;
            }

            // Small randomness for diversity
            float randJitter = 0.97f + (float(AiRandom(0, 1000)) / 1000.f) * 0.06f;
            score *= randJitter;

            if (!(score == score) || score <= 0.f) {
                score = 0.0001f;
            }

            scores[i] = score;

            GenericHelpers::LogUtil(
                "[FactoryProduction] Score for '" + d.GetName() + "' in factory '" + factoryName + "'" +
                " | layerDmg=" + layerDamage +
                " | vers=" + versatilityBonus +
                " | surv=" + survivability +
                " | mob=" + mobility +
                " | costInv=" + costInversion +
                " | subOverride=" + (subOverride ? "yes" : "no") +
                " | finalScore=" + score,
                5
            );
            if (score > bestScore) {
                bestScore = score;
                bestIdx = int(i);
            }
        }

        // 5. Top-K soft random selection (avoid pure determinism)
        const int K = AiMin(5, int(scores.length()));

        array<int> idx;
        idx.resize(scores.length());
        for (uint i = 0; i < idx.length(); ++i) {
            idx[i] = int(i);
        }

        // Partial selection sort for top K
        for (int a = 0; a < K; ++a) {
            int best = a;
            for (int b = a + 1; b < int(idx.length()); ++b) {
                if (scores[idx[b]] > scores[idx[best]]) {
                    best = b;
                }
            }
            if (best != a) {
                int tmp = idx[a];
                idx[a] = idx[best];
                idx[best] = tmp;
            }

            GenericHelpers::LogUtil(
                "[FactoryProduction] TopK rank " + a + " candidate='" + candidates[idx[a]].GetName() + "' score=" + scores[idx[a]] + "",
                4
            );
        }

        // Build decayed weights for top-K candidates (simple geometric decay)
        array<float> weights;
        weights.resize(K);
        float decayFactor = 1.0f;
        const float DECAY_STEP = 0.6f; // next candidate weight *= DECAY_STEP
        for (int i = 0; i < K; ++i) {
            weights[i] = scores[idx[i]] * decayFactor;
            decayFactor *= DECAY_STEP;
        }

        int pickLocal = AiDice(weights);
        if (pickLocal < 0 || pickLocal >= K) pickLocal = 0;

        CCircuitDef@ chosen = candidates[idx[pickLocal]];

        GenericHelpers::LogUtil(
            "[FactoryProduction] EnhancedPickBestUnit: factory='" + factoryName + "' picked='" + chosen.GetName() + "' (rank=" + pickLocal + ")",
            3
        );

        return chosen;
    }

    // ==================== Main Production Logic ====================

    IUnitTask@ MakeTask(CCircuitUnit@ factory) {
        if (factory is null || factory.circuitDef is null) {
            GenericHelpers::LogUtil("[FactoryProduction] MakeTask called with null factory or def", 3);
            return null;
        }

        const string factoryName = factory.circuitDef.GetName();
        const AIFloat3 pos = factory.GetPos(ai.frame);

        GenericHelpers::LogUtil("[FactoryProduction] MakeTask for factory '" + factoryName + "'", 3);

        // Ignore non-factory build-assist structures (nanoturrets, etc.) that should never
        // drive unit production themselves. They assist nearby factories but are not
        // factories in their own right, so we signal the caller to use its default logic
        // by returning null immediately.
        if (factoryName == "legnanotc" ||
            factoryName == "armnanotc" || factoryName == "armnanotcplat" ||
            factoryName == "cornanotc" || factoryName == "cornanotcplat")
        {
            GenericHelpers::LogUtil("[FactoryProduction] Skipping non-factory build assist unit '" + factoryName + "'", 3);
            return null; // caller (e.g. Front role) falls back to DefaultMakeTask or other handling
        }

        // 1. Consume priority queue first
        if (priorityQueue.length() > 0) {
            CCircuitDef@ priorityDef = priorityQueue[0];
            priorityQueue.removeAt(0);
            if (priorityDef.IsAvailable(ai.frame)) {
                GenericHelpers::LogUtil("[FactoryProduction] Building priority unit: " + priorityDef.GetName() + " (queue remaining: " + priorityQueue.length() + ")", 2);
                return aiFactoryMgr.Enqueue(
                    TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::HIGH, priorityDef, pos, 64.0f)
                );
            } else {
                GenericHelpers::LogUtil("[FactoryProduction] Priority unit '" + priorityDef.GetName() + "' not available, skipping", 3);
            }
        }

        // 2. Check if factory has a registered config
        FactoryConfig@ cfg = null;
        if (!factoryConfigs.get(factoryName, @cfg) || cfg is null) {
            GenericHelpers::LogUtil("[FactoryProduction] No config for factory '" + factoryName + "', falling back to legacy logic", 3);
            return null; // Caller can fall back to DefaultMakeTask or existing logic
        }

        // 3. Determine economic tier
        float metalIncome = aiEconomyMgr.metal.income;
        int tier = GetEconomicTier(metalIncome);
        if (tier >= int(cfg.tierProbabilities.length())) {
            tier = int(cfg.tierProbabilities.length()) - 1;
        }
        if (tier < 0 || cfg.tierProbabilities[tier].length() == 0) {
            GenericHelpers::LogUtil("[FactoryProduction] Invalid tier " + tier + " for factory '" + factoryName + "', no probabilities configured (tiers=" + cfg.tierProbabilities.length() + ")", 2);
            return null;
        }

        // Log detailed tier and probability info for debugging
        string baseProbStr = "";
        if (cfg.tierProbabilities[tier].length() > 0) {
            for (uint i = 0; i < cfg.tierProbabilities[tier].length(); ++i) {
                if (i > 0) baseProbStr += ",";
                baseProbStr += "" + cfg.tierProbabilities[tier][i];
            }
        }

        GenericHelpers::LogUtil(
            "[FactoryProduction] Factory '" + factoryName + "' tier=" + tier +
            " income=" + metalIncome +
            " roles=" + cfg.roles.length() +
            " probs=" + cfg.tierProbabilities[tier].length() +
            " baseProbs=[" + baseProbStr + "]",
            3
        );

        // 4. Apply threat-based weighting
        array<float> baseProbs = cfg.tierProbabilities[tier];
        array<float> weightedProbs = ApplyThreatWeighting(baseProbs, cfg.roles);

        // Extra logging of weighted probabilities and role alignment
        string weightedProbStr = "";
        for (uint i = 0; i < weightedProbs.length(); ++i) {
            if (i > 0) weightedProbStr += ",";
            weightedProbStr += "" + weightedProbs[i];
        }
        string roleNamesStr = "";
        for (uint i = 0; i < cfg.roles.length(); ++i) {
            if (i > 0) roleNamesStr += ",";
            roleNamesStr += cfg.roles[i];
        }
        GenericHelpers::LogUtil(
            "[FactoryProduction] Weighted probs for factory '" + factoryName + "': roles=[" + roleNamesStr + "] weights=[" + weightedProbStr + "]",
            4
        );

        // 5. Build list of roles that actually have at least one available unit
        array<int> validRoleIndices;
        for (uint i = 0; i < cfg.roles.length(); ++i) {
            const string roleName = cfg.roles[i];
            array<CCircuitDef@> tmp = GetAvailableUnitsForRole(cfg, roleName);
            if (tmp.length() > 0) {
                validRoleIndices.insertLast(int(i));
            } else {
                // Log roles filtered out due to no available units
                GenericHelpers::LogUtil(
                    "[FactoryProduction] Factory '" + factoryName + "' role '" + roleName + "' has no available units (candidates=" + tmp.length() + ")",
                    4
                );
            }
        }

        if (validRoleIndices.length() == 0) {
            GenericHelpers::LogUtil("[FactoryProduction] No roles with available units for factory '" + factoryName + "'", 3);
            return null;
        }

        // 6. Pick a role from the filtered set
        int roleIdx = PickRoleIndex(weightedProbs, validRoleIndices);
        if (roleIdx < 0 || roleIdx >= int(cfg.roles.length())) {
            GenericHelpers::LogUtil(
                "[FactoryProduction] Failed to pick valid role index (got " + roleIdx + ") for factory '" + factoryName + "' validRoleIndices=" + validRoleIndices.length() +
                " (factory='" + factoryName + "')",
                2
            );
            return null;
        }
        string chosenRole = cfg.roles[roleIdx];

        GenericHelpers::LogUtil("[FactoryProduction] Factory '" + factoryName + "' selected role: '" + chosenRole + "' (index " + roleIdx + ")", 3);

        // 7. Get available units for chosen role (must be non-empty by construction)
        array<CCircuitDef@> candidates = GetAvailableUnitsForRole(cfg, chosenRole);
        
        string candidateNames = "";
        for (uint i = 0; i < candidates.length(); ++i) {
            if (i > 0) candidateNames += ", ";
            candidateNames += candidates[i].GetName();
        }
        GenericHelpers::LogUtil("[FactoryProduction] Available candidates for role '" + chosenRole + "': [" + candidateNames + "]", 3);

        // 8. Pick best unit using tactical scoring
        CCircuitDef@ chosenDef = EnhancedPickBestUnit(factoryName, candidates);
        if (chosenDef is null) {
            GenericHelpers::LogUtil("[FactoryProduction] EnhancedPickBestUnit returned null for factory '" + factoryName + "', role '" + chosenRole + "'", 3);
            return null;
        }

        Task::RecruitType rtype = (chosenRole == "builder") ? Task::RecruitType::BUILDPOWER : Task::RecruitType::FIREPOWER;

        GenericHelpers::LogUtil(
            "[FactoryProduction] Factory '" + factoryName + "' queuing batch of " + BATCH_REUSE_COUNT +
            " x '" + chosenDef.GetName() + "' (role: " + chosenRole + ", tier: " + tier + ", cost: " + chosenDef.costM + ")",
            2
        );

        // 9. Enqueue a full batch immediately; the engine will consume this queue
        // before calling MakeTask for this factory again.
        IUnitTask@ lastTask = null;
        for (int i = 0; i < BATCH_REUSE_COUNT; ++i) {
            @lastTask = aiFactoryMgr.Enqueue(
                TaskS::Recruit(rtype, Task::Priority::NORMAL, chosenDef, pos, 64.0f)
            );
        }

        return lastTask;
    }

} // namespace FactoryProduction

// Include modular factory configuration files after namespace definition
// This avoids circular dependency issues with FactoryConfig class
#include "factory_configs/factory_configs_sea.as"
#include "factory_configs/factory_configs_hover.as"
#include "factory_configs/factory_configs_bot.as"
#include "factory_configs/factory_configs_vehicle.as"
#include "factory_configs/factory_configs_air.as"
