// Shared porcupine (static defence) policy.
#include "../../define.as"
#include "../../unit.as"
#include "../../global.as"
#include "../../helpers/common/generic_helpers.as"

/******************************************************************************

PORCUPINE POLICY

Native CMilitaryManager::DefaultMakeDefence decides per cluster visit how much
static defence a metal cluster may take. Its own heuristic ("isPorc") fills the
full porcupine order only on clusters it considers front line: rich clusters
far from base, clusters with two threatened neighbours, or clusters outside
our influence. Every other cluster gets `porcupine.prevent` (one) structure
and keeps it for the whole game, and queued follow-ups there are aborted. That
is right in the opening and starves the base and the interior late in the
game, when the front has moved on but income could pay for real defence.

The native code now reads two script knobs before it places anything:

  aiMilitaryMgr.porcMode       0 AUTO    native heuristic, unchanged
                               1 PREVENT preventive count only
                               2 FULL    whole porcupine order, budget-limited
  aiMilitaryMgr.porcBudgetMod  multiplier on the per-point budget
                               (amount.factor x min(metal, energy income) x eco)

Military::Porc::MakeDefence sets both from DecideMode and then calls the native
placement, so the order, layout and cost bookkeeping stay native. Decision:

  phase     early while frame < LateGameMinutes and the incomes are below
            LateGameMetalIncome / LateGameEnergyIncome -> AUTO. Otherwise late
            -> FULL with LateBudgetMod.
  energy    while energy is stalling the late phase falls back to AUTO and the
            budget bonus is withheld: static defence is energy-heavy and the
            native budget already takes min(metal, energy income). A full energy
            store raises the budget (ExcessEnergyBudgetMod) like a full metal
            store does.
  pressure  after PressureMinMinutes, when the enemy surface army (metal, per
            enemy player) exceeds ours by PressureRatio -> FULL with at least
            PressureBudgetMod, in any phase, stall or not.
  bank      metal store at ExcessMetalPercent or more -> budget at least
            ExcessMetalBudgetMod, in any mode: banked metal becomes defence.
  nanos     with NanoWithPorc, a FULL visit whose incomes clear NanoMetalIncome /
            NanoEnergyIncome (and no stall) also places up to NanosPerCluster
            caretakers at the defence point, so the porc chain and the builders
            around it get build power. Tracked per cluster in this AI's lifetime.

Every role without its own AiMakeDefenceHandler goes through this policy
(Military::AiMakeDefence); TECH keeps its income gate and then uses it too.
Settings live in Global::Porc.

******************************************************************************/
namespace Military {
namespace Porc {
    // Mirrors CMilitaryManager::porcMode
    const int MODE_AUTO = 0;
    const int MODE_PREVENT = 1;
    const int MODE_FULL = 2;

    string ModeName(int mode)
    {
        if (mode == MODE_FULL) return "FULL";
        if (mode == MODE_PREVENT) return "PREVENT";
        return "AUTO";
    }

    // Enemy mobile surface army in metal, per enemy player: sum of the cached
    // per-role enemy costs for the main surface combat roles.
    float EnemySurfaceArmyCostPerPlayer()
    {
        float cost = 0.0f;
        cost += aiEnemyMgr.GetEnemyCost(Unit::Role::ASSAULT.type);
        cost += aiEnemyMgr.GetEnemyCost(Unit::Role::RAIDER.type);
        cost += aiEnemyMgr.GetEnemyCost(Unit::Role::RIOT.type);
        cost += aiEnemyMgr.GetEnemyCost(Unit::Role::SKIRM.type);
        cost += aiEnemyMgr.GetEnemyCost(Unit::Role::ARTY.type);
        cost += aiEnemyMgr.GetEnemyCost(Unit::Role::HEAVY.type);
        cost += aiEnemyMgr.GetEnemyCost(Unit::Role::AH.type);
        if (!(cost == cost) || cost < 0.0f) cost = 0.0f;   // NaN / negative guard
        int enemies = ai.GetEnemyTeamSize();
        if (enemies < 1) enemies = 1;
        return cost / float(enemies);
    }

    // Pure decision from the inputs; see the header for the rules.
    int DecideMode(int frame, float metalIncome, float energyIncome, bool energyStalling,
                   float ourArmyCost, float enemyArmyCostPerPlayer,
                   float metalCurrent, float metalStorage, float energyCurrent, float energyStorage,
                   float &out budgetMod, string &out reason)
    {
        int mode = MODE_AUTO;
        budgetMod = 1.0f;
        reason = "early";

        const bool lateByTime = frame >= Global::Porc::LateGameMinutes * MINUTE;
        const bool lateByIncome = metalIncome >= Global::Porc::LateGameMetalIncome
            && energyIncome >= Global::Porc::LateGameEnergyIncome;
        if (lateByTime || lateByIncome) {
            if (energyStalling) {
                reason = "late but energy stalling: native heuristic";
            } else {
                mode = MODE_FULL;
                budgetMod = Global::Porc::LateBudgetMod;
                reason = lateByIncome ? "late: income" : "late: time";
            }
        }

        if (frame >= Global::Porc::PressureMinMinutes * MINUTE
            && enemyArmyCostPerPlayer > 0.0f
            && enemyArmyCostPerPlayer > ourArmyCost * Global::Porc::PressureRatio) {
            mode = MODE_FULL;
            if (budgetMod < Global::Porc::PressureBudgetMod) budgetMod = Global::Porc::PressureBudgetMod;
            reason = "pressure: enemy " + int(enemyArmyCostPerPlayer) + " vs ours " + int(ourArmyCost);
        }

        if (metalStorage > 0.0f && metalCurrent >= metalStorage * Global::Porc::ExcessMetalPercent) {
            if (budgetMod < Global::Porc::ExcessMetalBudgetMod) budgetMod = Global::Porc::ExcessMetalBudgetMod;
            reason += ", metal bank full";
        }
        if (energyStorage > 0.0f && energyCurrent >= energyStorage * Global::Porc::ExcessEnergyPercent) {
            if (budgetMod < Global::Porc::ExcessEnergyBudgetMod) budgetMod = Global::Porc::ExcessEnergyBudgetMod;
            reason += ", energy bank full";
        }
        if (energyStalling && budgetMod > 1.0f) {
            budgetMod = 1.0f;
            reason += ", stall caps budget";
        }
        return mode;
    }

    // Caretakers placed by porc, per cluster: key cluster id -> int count
    dictionary nanosByCluster;

    void _TryNanoWithPorc(int cluster, const AIFloat3 &in pos, int mode, float metalIncome, float energyIncome, bool energyStalling)
    {
        if (!Global::Porc::NanoWithPorc || mode != MODE_FULL || energyStalling) return;
        if (metalIncome < Global::Porc::NanoMetalIncome || energyIncome < Global::Porc::NanoEnergyIncome) return;
        const string key = "" + cluster;
        // exists() first. Every cluster misses this table the first time, and
        // a failed get leaves `count` undefined rather than 0: junk that read
        // above NanosPerCluster returned here before the first nano was ever
        // queued, so cluster nanos could silently never be built.
        int count = 0;
        if (nanosByCluster.exists(key)) nanosByCluster.get(key, count);
        if (count >= Global::Porc::NanosPerCluster) return;
        IUnitTask@ t = Builder::EnqueueT1Nano(Global::AISettings::Side, pos, SQUARE_SIZE * 16, 300 * SECOND, Task::Priority::NORMAL);
        if (t is null) return;   // cooldown, cap or unavailable def: try again on the next visit
        nanosByCluster.set(key, count + 1);
        GenericHelpers::LogUtil("[Porc] cluster=" + cluster + " caretaker " + (count + 1) + "/" + Global::Porc::NanosPerCluster
            + " enqueued with porc (mi=" + metalIncome + " ei=" + energyIncome + ")", 2);
    }

    // Set the native knobs for this visit, run the native placement, then the caretaker.
    void MakeDefence(int cluster, const AIFloat3 &in pos)
    {
        float budgetMod = 1.0f;
        string reason;
        const float metalIncome = Economy::GetMinMetalIncomeLast10s();
        const float energyIncome = Economy::GetMinEnergyIncomeLast10s();
        const bool energyStalling = aiEconomyMgr.isEnergyStalling;
        const int mode = DecideMode(ai.frame, metalIncome, energyIncome, energyStalling,
                                    aiMilitaryMgr.armyCost, EnemySurfaceArmyCostPerPlayer(),
                                    aiEconomyMgr.metal.current, aiEconomyMgr.metal.storage,
                                    aiEconomyMgr.energy.current, aiEconomyMgr.energy.storage,
                                    budgetMod, reason);
        aiMilitaryMgr.porcMode = mode;
        aiMilitaryMgr.porcBudgetMod = budgetMod;
        GenericHelpers::LogUtil("[Porc] cluster=" + cluster + " mode=" + ModeName(mode) + " budgetMod=" + budgetMod
            + " mi=" + metalIncome + " ei=" + energyIncome + " (" + reason + ")", 3);
        aiMilitaryMgr.DefaultMakeDefence(cluster, pos);
        _TryNanoWithPorc(cluster, pos, mode, metalIncome, energyIncome, energyStalling);
    }
}  // namespace Porc
}  // namespace Military
