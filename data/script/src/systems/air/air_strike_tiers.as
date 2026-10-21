// AIR role: tiered strike rosters (owner 2026-10-21). The Liche runs and the T2 bomber
// waves pick their targets the same way, each from its own list.
#include "../../helpers/units/unit_helpers.as"

/******************************************************************************

STRIKE TIERS

A Roster puts target defs in tiers 1 (best) .. n. Every def of tier t gets the
native strike weight TierWeight(t) * 1000 / its metal cost: the native scorer
multiplies a def's weight by its metal cost, so cost cancels and the tier
decides, then distance and route risk. Keep each tier's weight far enough above
the next (20x) that a cheaper def of a lower tier never outranks a dearer one
of a higher tier; Finish logs a warning when it would.

In flight the native immediate strike retargets to the best visible allowed
static near the aircraft whose weight reaches the handoff threshold. Threshold
is the lowest weight of the tier just above the current target's, so only a
strictly higher tier takes over. A target of no known tier (a fallback target,
or one seen only between scans) counts as top tier: only a top-tier target
takes over from it.

Targets are remembered by enemy id from the ground contacts (one shared scan a
second for every registered roster): a chosen target is often one seen long
before and out of radar now.

AirBomberTargets is the T2 bomber wave's roster: economy in place of the
Liche's defences. Off unless Global::RoleSettings::Air::BomberTiersEnabled.

******************************************************************************/
namespace AirStrikeTiers {
    class Roster {
        string tag;
        array<float> weightByDef;   // def id -> native strike weight, 0 = not a target
        array<int> tierByDef;       // def id -> tier 1..tiers, 0 = none
        array<float> tierMin;       // tier -> lowest static weight in it
        array<float> tierMax;       // tier -> highest static weight in it
        dictionary seenTier;        // enemy id string -> tier, for every target seen as a ground contact
        int tiers = 0;
        int targets = 0;

        bool Ready() { return tiers > 0; }
        void Begin(const string &in name, int tierCount)
        {
            tag = name;
            tiers = tierCount;
            targets = 0;
            const int n = ai.GetDefCount() + 1;
            weightByDef.resize(n); tierByDef.resize(n);
            for (int i = 0; i < n; ++i) { weightByDef[i] = 0.0f; tierByDef[i] = 0; }
            tierMin.resize(tiers + 1); tierMax.resize(tiers + 1);
            for (int t = 0; t <= tiers; ++t) { tierMin[t] = 0.0f; tierMax[t] = 0.0f; }
        }
        // The first tier a def is added to wins.
        void Add(int tier, const array<string> &in names, float weight)
        {
            if (tier < 1 || tier > tiers) return;
            for (uint i = 0; i < names.length(); ++i) {
                CCircuitDef@ d = ai.GetCircuitDef(names[i]);
                if (d is null || d.id < 0 || d.id >= int(tierByDef.length()) || tierByDef[d.id] != 0) continue;
                tierByDef[d.id] = tier;
                weightByDef[d.id] = weight * 1000.0f / AiMax(1.0f, d.costM);
                ++targets;
                // Only statics take part in the in-flight handoff.
                if (d.IsMobile()) continue;
                if (tierMin[tier] <= 0.0f || weightByDef[d.id] < tierMin[tier]) tierMin[tier] = weightByDef[d.id];
                if (weightByDef[d.id] > tierMax[tier]) tierMax[tier] = weightByDef[d.id];
            }
        }
        void Finish()
        {
            for (int t = 1; t < tiers; ++t)
                if (tierMin[t] > 0.0f && tierMax[t + 1] >= tierMin[t])
                    GenericHelpers::LogUtil("[AIR][" + tag + "] WARNING tier " + t + " lowest weight " + tierMin[t]
                        + " <= tier " + (t + 1) + " highest " + tierMax[t + 1] + ": raise the tier weights apart", 1);
            GenericHelpers::LogUtil("[AIR][" + tag + "] roster targets=" + targets, 2);
        }
        void Allow(CAirWaveTask@ wt)
        {
            for (int i = 0; i < int(weightByDef.length()); ++i)
                if (weightByDef[i] > 0.0f) wt.AllowStrikeDef(ai.GetCircuitDef(i), weightByDef[i]);
        }
        int DefTier(int defId)
        {
            return (defId < 0 || defId >= int(tierByDef.length())) ? 0 : tierByDef[defId];
        }
        // Tier of an enemy by id, from the last time it was a ground contact; 0 when it is not a
        // target of this roster or was never seen as one.
        int TargetTier(int enemyId)
        {
            int64 tier = 0;
            if (enemyId < 0 || !seenTier.get("" + enemyId, tier)) return 0;
            return int(tier);
        }
        // Handoff threshold while the run is on a target of `tier`: the lowest weight of the nearest
        // tier above it; a top-tier target keeps itself.
        float Threshold(int tier)
        {
            if (tier <= 0) tier = 1;
            if (tier > tiers) tier = tiers;
            for (int t = tier - 1; t >= 1; --t) if (tierMin[t] > 0.0f) return tierMin[t];
            return tierMin[tier] > 0.0f ? tierMin[tier] : 1.0f;
        }
    }

    array<Roster@> active;   // rosters fed by Remember

    void Register(Roster@ r) { if (r !is null && active.findByRef(r) < 0) active.insertLast(r); }

    // One scan of the current ground contacts for every registered roster, at most once a second
    // unless forced (a launch reads the tier of the target it just picked).
    int lastScan = -100000;
    void Remember(bool force = false)
    {
        if (active.length() == 0 || (!force && ai.frame - lastScan < SECOND)) return;
        lastScan = ai.frame;
        const int contacts = aiBattle.GetGroundContactCount();
        for (int i = 0; i < contacts; ++i) {
            const int defId = aiBattle.GetGroundContactDefId(i);
            for (uint r = 0; r < active.length(); ++r) {
                const int tier = active[r].DefTier(defId);
                if (tier > 0) active[r].seenTier.set("" + aiBattle.GetGroundContactId(i), int64(tier));
            }
        }
    }
}  // namespace AirStrikeTiers

namespace AirBomberTargets {
    AirStrikeTiers::Roster roster;
    array<CAirWaveTask@> runs;     // live offensive T2 bomber waves
    array<int> runTarget;          // parallel to runs: target id * 8 + tier last logged

    bool Enabled() { return Global::RoleSettings::Air::BomberTiersEnabled && Global::RoleSettings::Air::ExperimentalBuild; }

    void Init() { runs.resize(0); runTarget.resize(0); }

    void InitRoster()
    {
        if (roster.Ready()) return;
        roster.Begin("Bomber", 5);
        const array<string> sides = {"armada", "cortex", "legion"};
        array<string> advFusions, fusions, converters;
        for (uint i = 0; i < sides.length(); ++i) {
            advFusions.insertLast(UnitHelpers::GetAdvFusionNameForSide(sides[i]));
            fusions.insertLast(UnitHelpers::GetFusionNameForSide(sides[i]));
            converters.insertLast(UnitHelpers::GetAdvEnergyConverterNameForSide(sides[i]));
            converters.insertLast(UnitHelpers::GetAdvNavalEnergyConverterNameForSide(sides[i]));
        }
        fusions.insertLast("armckfus"); // real cloakable fusion; visibility gates still apply
        roster.Add(1, advFusions, Global::RoleSettings::Air::BomberWeightAdvFusion);
        roster.Add(2, fusions, Global::RoleSettings::Air::BomberWeightFusion);
        roster.Add(3, converters, Global::RoleSettings::Air::BomberWeightConverter);
        roster.Add(4, array<string> = {"armageo", "corageo", "legageo", "armgmm", "armuwageo", "coruwageo", "leganavaladvgeo"},
            Global::RoleSettings::Air::BomberWeightAdvGeo);
        roster.Add(5, UnitHelpers::GetAllLabs(), Global::RoleSettings::Air::BomberWeightFactory);
        roster.Finish();
        AirStrikeTiers::Register(@roster);
    }

    // After AirOperations::Configure(wt, true, 5): the tier weights replace Configure's for these defs
    // (heavy ground units keep theirs: they only matter to defensive sorties), and only a top-tier
    // target interrupts until the wave has a target.
    void Apply(CAirWaveTask@ wt)
    {
        if (!Enabled() || wt is null) return;
        InitRoster();
        roster.Allow(wt);
        _SetHandoff(wt, 0);
    }
    void _SetHandoff(CAirWaveTask@ wt, int tier)
    {
        wt.SetAttackHandoffPolicy(Global::RoleSettings::Air::StrikeEarlyAttack, roster.Threshold(tier),
            Global::RoleSettings::Air::StrikeImmediateRadius);
    }

    void Launched(CAirWaveTask@ wt)
    {
        if (!Enabled() || wt is null) return;
        runs.insertLast(wt); runTarget.insertLast(-1);
        _SetHandoff(wt, roster.TargetTier(wt.GetStrikeTargetId()));
    }

    // Air_MainUpdate, every 30 frames: keep each wave's handoff threshold one tier above its target.
    void Update()
    {
        for (int i = int(runs.length()) - 1; i >= 0; --i)
            if (runs[i] is null || runs[i].IsDead()) { runs.removeAt(i); runTarget.removeAt(i); }
        if (!Enabled() || !AirEconomy::Active()) return;
        InitRoster();
        AirStrikeTiers::Remember();
        for (uint r = 0; r < runs.length(); ++r) {
            const int target = runs[r].GetStrikeTargetId();
            const int tier = roster.TargetTier(target);
            _SetHandoff(runs[r], tier);
            if (target * 8 + tier == runTarget[r]) continue;
            runTarget[r] = target * 8 + tier;
            GenericHelpers::LogUtil("[AIR][Bomber] run target=" + target + " tier=" + tier
                + " handoff=" + roster.Threshold(tier), 1);
        }
    }
}  // namespace AirBomberTargets
