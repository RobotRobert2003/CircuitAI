#include "../../global.as"
#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/construction/economy_helpers.as"
#include "tech_chain.as"

// D-080: what the TECH role does once its rush objective stands. The owner's
// list: (A) nuke - a silo the fastest way; (B) t2rush - +200 metal, then T2
// fast assault units while the economy climbs to +500, then T3 in mass with
// many turrets; (C) t3rush - +500 metal before any combat unit, then T3; (D)
// lrpc - +300 metal, then the long-range plasma cannon. Every plan climbs the
// metal ladder the same way (TechChain's income steps: converters when energy
// floats, T2 mex upgrades, the next advanced fusion) and no plan produces a
// mobile combat unit under its income gate. From +200 metal the T2 air plant
// and T2 construction aircraft become the mobile build power. Phase 2 (native,
// KI-417 and KI-418): the nuke's first shot at the enemy tech location, the
// cannon on high ground with sight, land constructors guarding allied ones.
namespace TechPlan {
    string plan = "";        // nuke | t2rush | t3rush | lrpc
    int phase = 0;           // 0 = the rush objective, then 1, 2 ...

    string Choose()
    {
        const string want = Global::RoleSettings::Tech::EndgamePlan;
        if (want == "t2rush") return "spamrush"; // legacy explicit plan alias
        if (want == "nuke" || want == "spamrush" || want == "t3rush" || want == "lrpc") return want;
        if (Global::RoleSettings::Tech::HasStrategy(Strategy::NUKE_RUSH)) return "nuke";
        if (Global::RoleSettings::Tech::HasStrategy(Strategy::SPAM_RUSH)) return "spamrush";
        if (Global::RoleSettings::Tech::HasStrategy(Strategy::T3_RUSH)) return "t3rush";
        return "eco";

    }

    void Init()
    {
        plan = Choose();
        phase = 0;
        CCircuitDef@ afus = ai.GetCircuitDef(TechChain::DefFor("afus"));
        if (afus !is null && afus.count > aiBuilderMgr.GetUnfinishedCount(afus))
            aiTerrainMgr.SetLayoutInt("tech.heavy.afus-completed", 1);
        GenericHelpers::LogUtil("[TECH][Plan] " + plan + " (combat gate +" + int(CombatGate()) + " metal; T2 air constructors from +"
            + int(Global::RoleSettings::Tech::PlanAirConstructorsFromMetal) + ")", 1);
    }

    // The metal income under which no mobile combat unit is produced.
    float CombatGate()
    {
        if (plan == "t3rush") return Global::RoleSettings::Tech::PlanT3RushCombatGate;
        return Global::RoleSettings::Tech::PlanCombatGate;
    }

    // T2 construction aircraft wanted: none before PlanAirConstructorsFromMetal,
    // then one per PlanAirConstructorPerMetal of income, at most PlanMaxAirConstructors.
    int AirConstructorsWanted()
    {
        const float mi = Economy::GetMinMetalIncomeLast10s();
        if (mi < Global::RoleSettings::Tech::PlanAirConstructorsFromMetal) return 0;
        int n = int(mi / Global::RoleSettings::Tech::PlanAirConstructorPerMetal);
        if (n > Global::RoleSettings::Tech::PlanMaxAirConstructors) n = Global::RoleSettings::Tech::PlanMaxAirConstructors;
        return n;
    }

    // The steps of the next phase after `objective` stood; empty = no more.
    // Income steps are metal-income targets the chain's ladder climbs.
    array<TechChain::Step@>@ NextPhase(const string &in objective)
    {
        array<TechChain::Step@> s;
        if (TechHeavyRush::Pending()) {
            // Sequence prerequisite, not a permanent obligation to replace a
            // destroyed silo before each remaining heavy recruit.
            if (objective == "nuke") TechHeavyRush::SiloReady();
            // Rebuild after the nuke refund, then establish the heavy foundation.
            s.insertLast(TechChain::Step("alab", TechChain::DefFor("alab"), 1));
            s.insertLast(TechChain::Step("moho", TechChain::DefFor("moho"), 2));
            s.insertLast(TechChain::Step("fusion", TechChain::DefFor("fusion"), 1));
            s.insertLast(TechChain::Step("heavy", "", 1));
            return s;
        }
        // The heavy foundation displaced the normal first-AFUS objective.
        // Restore it in phase one without consuming the selected plan's phase
        // or rerolling/restarting its completed-ever heavy obligation.
        const bool restoreAfus = phase == 0 && TechHeavyRush::Selected()
            && TechHeavyRush::completed >= TechHeavyRush::TargetCount()
            && aiTerrainMgr.GetLayoutInt("tech.heavy.afus-completed", 0) == 0;
        if (restoreAfus)
            s.insertLast(TechChain::Step("afus", TechChain::DefFor("afus"), 1));
        ++phase;
        const int gate200 = int(Global::RoleSettings::Tech::PlanCombatGate);
        const int gate500 = int(Global::RoleSettings::Tech::PlanT3RushCombatGate);
        const int lrpcAt = int(Global::RoleSettings::Tech::PlanLrpcMetal);
        if (plan == "nuke") {
            if (phase == 1) {
                if (objective != "nuke" && !TechHeavyRush::SiloReady()) s.insertLast(TechChain::Step("silo", TechChain::DefFor("silo"), 1));
                else s.insertLast(TechChain::Step("ap", TechChain::DefFor("ap"), 1)); // D-229: no aircraft-factory spending before the rush silo
                s.insertLast(TechChain::Step("income", "", gate200));
            } else if (phase == 2) {
                s.insertLast(TechChain::Step("ap", TechChain::DefFor("ap"), 1));   // D-103: only an air constructor builds the advanced aircraft plant
                s.insertLast(TechChain::Step("aap", TechChain::DefFor("aap"), 1));
                s.insertLast(TechChain::Step("income", "", gate500));
            }
        } else if (plan == "spamrush") {
            if (phase == 1) {
                s.insertLast(TechChain::Step("ap", TechChain::DefFor("ap"), 1));   // D-103: only an air constructor builds the advanced aircraft plant
                s.insertLast(TechChain::Step("aap", TechChain::DefFor("aap"), 1));
                s.insertLast(TechChain::Step("income", "", gate200));
            } else if (phase == 2) {
                s.insertLast(TechChain::Step("income", "", gate500));
                s.insertLast(TechChain::Step("gantry", TechChain::DefFor("gantry"), 1));
            }
        } else if (plan == "t3rush") {
            if (phase == 1) {
                if (TechGantry::EarlyEnabled()) {
                    if (!restoreAfus) s.insertLast(TechChain::Step("afus", TechChain::DefFor("afus"), 1));
                    s.insertLast(TechChain::Step("earlygantry", TechChain::DefFor("gantry"), 1));
                }
                s.insertLast(TechChain::Step("ap", TechChain::DefFor("ap"), 1));   // D-103: only an air constructor builds the advanced aircraft plant
                s.insertLast(TechChain::Step("aap", TechChain::DefFor("aap"), 1));
                s.insertLast(TechChain::Step("income", "", gate500));
                s.insertLast(TechChain::Step("gantry", TechChain::DefFor("gantry"), 1));
            }
        } else if (plan == "lrpc") {
            if (phase == 1) {
                s.insertLast(TechChain::Step("ap", TechChain::DefFor("ap"), 1));   // D-103: only an air constructor builds the advanced aircraft plant
                s.insertLast(TechChain::Step("aap", TechChain::DefFor("aap"), 1));
                s.insertLast(TechChain::Step("income", "", lrpcAt));
                s.insertLast(TechChain::Step("lrpc", TechChain::DefFor("lrpc"), 1));
            } else if (phase == 2) {
                s.insertLast(TechChain::Step("income", "", gate500));
            }
        }
        if (restoreAfus && (s.length() == 0 || s[0].key != "afus"))
            Invariants::Violation("INV-193", plan, "completed heavy batch lost first-AFUS continuation");
        return s;
    }

    string PhaseName() { return plan + " phase " + phase; }
}
