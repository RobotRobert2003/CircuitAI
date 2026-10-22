// Shared defaults; existing Global namespaces are retained for callers.
namespace Global {
namespace Porc {
        // Late game: from either threshold on, every visited cluster may take the
        // full porcupine order within its income budget (native mode FULL). Before
        // that the native front-line heuristic decides (mode AUTO).
        int LateGameMinutes = 25;
        float LateGameMetalIncome = 120.0f;
        float LateGameEnergyIncome = 1500.0f;   // the income route needs both incomes
        float LateBudgetMod = 1.0f;          // per-point budget multiplier once late
        // Energy: while energy is stalling the late phase falls back to the native
        // heuristic and no budget bonus applies (defences are energy-heavy); a full
        // energy store raises the budget like a full metal store does.
        float ExcessEnergyPercent = 0.9f;
        float ExcessEnergyBudgetMod = 1.5f;
        // Construction turrets with late-game porc: while the mode is FULL and both
        // incomes are strong (no stall), one caretaker per cluster is placed at the
        // defence point being reinforced, so builders and the porc chain get help.
        bool NanoWithPorc = true;
        float NanoMetalIncome = 150.0f;
        float NanoEnergyIncome = 3000.0f;
        int NanosPerCluster = 1;
        // Pressure: enemy surface army (metal per enemy player, from aiEnemyMgr role
        // costs) versus our army cost. Forces FULL in any phase after the grace period.
        int PressureMinMinutes = 10;
        float PressureRatio = 1.2f;
        float PressureBudgetMod = 1.5f;
        // Banked metal: when the store is this full, raise the budget so it is spent
        // on defence instead of overflowing.
        float ExcessMetalPercent = 0.9f;
        float ExcessMetalBudgetMod = 2.0f;
    }
}
