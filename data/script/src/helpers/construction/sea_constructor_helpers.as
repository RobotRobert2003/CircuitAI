// The naval economy ladder a construction ship runs, shared by every role
// that owns one. SEA wrote it; TACTICAL runs it on the ship SEA donates.
#include "../../define.as"
#include "../../global.as"
#include "../../unit.as"
#include "../../task.as"
#include "../common/generic_helpers.as"
#include "../units/unit_helpers.as"
#include "../units/unitdef_helpers.as"
#include "economy_helpers.as"
#include "guard_helpers.as"
#include "../../manager/builder.as"
#include "../../manager/factory.as"

/******************************************************************************

SEA CONSTRUCTOR LADDERS

What a T1 construction ship does, in order, when it is the primary sea
constructor: a T2 shipyard when the economy clears it, a mex upgrade when
that policy is on, a naval energy converter, a nano for whichever factory
needs one, and tidals while energy income is short. What a T2 construction
sub does: an advanced naval converter, then a naval fusion. Every other
construction ship assists the primary while energy is low.

This used to live inline in the SEA role, so a TACTICAL player given a
construction ship (manager/sea_assist.as) could unlock its shipyards and seed
one, and then had no idea what to do with the ship afterwards: no eco, no
nanos, the ship idle in SEA's water. The ladder is the same policy for both
roles; what differs is only the numbers, which the caller passes in as a
Settings object. SeaConstructor::FromSea() fills one from
Global::RoleSettings::Sea, which is what "mimic SEA" means.

The ladders return null when no rung fires; the caller decides the default.
Objectives (SEA's seaplane platform chain) are the caller's business too and
run before the ladder.

******************************************************************************/
namespace SeaConstructor {

    class Settings {
        // T1 ladder
        float MinimumMetalIncomeForT2Shipyard = 40.0f;
        float RequiredMetalCurrentForT2Shipyard = 800.0f;
        float MinimumEnergyIncomeForT2Shipyard = 800.0f;
        int MaxT2Shipyards = 1;
        float BuildT1ConvertersUntilMetalIncome = 40.0f;
        float BuildT1ConvertersMinimumEnergyIncome = 250.0f;
        float BuildT1ConvertersMinimumEnergyCurrentPercent = 0.90f;
        float NanoEnergyPerUnit = 200.0f;
        float NanoMetalPerUnit = 20.0f;
        int NanoMaxCount = 200;
        float NanoBuildWhenOverMetal = 1000.0f;
        float TidalEnergyIncomeMinimum = 1200.0f;
        // T2 ladder
        float EnergyStorageLowPercent = 0.90f;
        float MinimumMetalIncomeForAdvConverter = 18.0f;
        float MinimumEnergyIncomeForAdvConverter = 1200.0f;
        float MinimumMetalIncomeForFUS = 30.0f;
        float MinimumEnergyIncomeForFUS = 1200.0f;
        float MaxEnergyIncomeForFUS = 999999.0f;
        // Assist
        float AssistPrimaryWorkerEnergyIncomeMinimum = 500.0f;
    }

    // SEA's own numbers. TACTICAL uses these unchanged (D-042).
    Settings@ FromSea()
    {
        Settings@ s = Settings();
        s.MinimumMetalIncomeForT2Shipyard = Global::RoleSettings::Sea::MinimumMetalIncomeForT2Shipyard;
        s.RequiredMetalCurrentForT2Shipyard = Global::RoleSettings::Sea::RequiredMetalCurrentForT2Shipyard;
        s.MinimumEnergyIncomeForT2Shipyard = Global::RoleSettings::Sea::MinimumEnergyIncomeForT2Shipyard;
        s.MaxT2Shipyards = Global::RoleSettings::Sea::MaxT2Shipyards;
        s.BuildT1ConvertersUntilMetalIncome = Global::RoleSettings::Sea::BuildT1ConvertersUntilMetalIncome;
        s.BuildT1ConvertersMinimumEnergyIncome = Global::RoleSettings::Sea::BuildT1ConvertersMinimumEnergyIncome;
        s.BuildT1ConvertersMinimumEnergyCurrentPercent = Global::RoleSettings::Sea::BuildT1ConvertersMinimumEnergyCurrentPercent;
        s.NanoEnergyPerUnit = Global::RoleSettings::Sea::NanoEnergyPerUnit;
        s.NanoMetalPerUnit = Global::RoleSettings::Sea::NanoMetalPerUnit;
        s.NanoMaxCount = Global::RoleSettings::Sea::NanoMaxCount;
        s.NanoBuildWhenOverMetal = Global::RoleSettings::Sea::NanoBuildWhenOverMetal;
        s.TidalEnergyIncomeMinimum = Global::RoleSettings::Sea::TidalEnergyIncomeMinimum;
        s.EnergyStorageLowPercent = Global::RoleSettings::Sea::EnergyStorageLowPercent;
        s.MinimumMetalIncomeForAdvConverter = Global::RoleSettings::Sea::MinimumMetalIncomeForAdvConverter;
        s.MinimumEnergyIncomeForAdvConverter = Global::RoleSettings::Sea::MinimumEnergyIncomeForAdvConverter;
        s.MinimumMetalIncomeForFUS = Global::RoleSettings::Sea::MinimumMetalIncomeForFUS;
        s.MinimumEnergyIncomeForFUS = Global::RoleSettings::Sea::MinimumEnergyIncomeForFUS;
        s.MaxEnergyIncomeForFUS = Global::RoleSettings::Sea::MaxEnergyIncomeForFUS;
        s.AssistPrimaryWorkerEnergyIncomeMinimum = Global::RoleSettings::Sea::AssistPrimaryWorkerEnergyIncomeMinimum;
        return s;
    }

    // Detection by the unit-helper lists, not by name suffix: Legion's T2 sub
    // is leganavyconsub, which the old "acsub" suffix test missed.
    bool IsT1(const CCircuitDef@ d)
    {
        return d !is null && UnitHelpers::GetAllT1SeaConstructors().find(d.GetName()) >= 0;
    }

    bool IsT2(const CCircuitDef@ d)
    {
        return d !is null && UnitHelpers::GetAllT2SeaConstructors().find(d.GetName()) >= 0;
    }

    // The primary T1 construction ship's ladder. Null when no rung fires.
    IUnitTask@ T1Ladder(CCircuitUnit@ u, Settings@ s, const string &in tag)
    {
        if (u is null || u.circuitDef is null || s is null) return null;
        const float mi = aiEconomyMgr.metal.income;
        const float ei = aiEconomyMgr.energy.income;
        const AIFloat3 conLocation = u.GetPos(ai.frame);
        const string unitSide = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());

        // T2 shipyard when the economy and a standing T1 shipyard allow it.
        {
            const int t2ShipyardCount = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2Shipyards());
            const bool hasPrimaryT1Shipyard = (Factory::primaryT1Shipyard !is null);
            // D-300: SEA's first T2 yard has one owner, SeaBuild::TechYard
            // (tech save). Two order paths produced duplicate, never-started
            // orders. TACTICAL keeps the ladder gate (40 M/s) unchanged (D-042).
            bool t2Ready = false;
            if (Global::AISettings::Role == AiRole::SEA) {
                t2Ready = false;
            } else {
                t2Ready = EconomyHelpers::ShouldBuildT2Shipyard(mi, ei, aiEconomyMgr.metal.current,
                    s.MinimumMetalIncomeForT2Shipyard, s.RequiredMetalCurrentForT2Shipyard,
                    s.MinimumEnergyIncomeForT2Shipyard, t2ShipyardCount, s.MaxT2Shipyards,
                    hasPrimaryT1Shipyard);
            }
            if (t2Ready) {
                IUnitTask@ t = Builder::EnqueueT2Shipyard(unitSide, Factory::GetT1ShipyardPos(), SQUARE_SIZE * 60, 600 * SECOND);
                if (t !is null) return t;
            }
        }
        // A mex upgrade outranks the whole energy ladder (KI-213).
        if (Global::RoleSettings::MexUpgradeFirst) {
            IUnitTask@ t = EconomyHelpers::EnqueueMexUpgradeIfFirst(u, Global::Map::StartPos,
                    Global::RoleSettings::MexUpgradeRadius, Global::RoleSettings::MexUpgradeMaxConcurrent, tag);
            if (t !is null) return t;
        }
        // Naval energy converter.
        if (EconomyHelpers::ShouldBuildT1EnergyConverter(mi, ei, aiEconomyMgr.energy.current, aiEconomyMgr.energy.storage,
                s.BuildT1ConvertersUntilMetalIncome, s.BuildT1ConvertersMinimumEnergyIncome,
                s.BuildT1ConvertersMinimumEnergyCurrentPercent)) {
            IUnitTask@ t = Builder::EnqueueT1NavalEnergyConverter(unitSide, conLocation, SQUARE_SIZE * 32, SECOND * 30);
            if (t !is null) return t;
        }
        // A nano for whichever factory needs one; water labs get naval nanos.
        {
            const float energyPercent = (aiEconomyMgr.energy.storage > 0.0f)
                ? (aiEconomyMgr.energy.current / aiEconomyMgr.energy.storage) : 0.0f;
            if (Factory::GetPreferredFactory() !is null && EconomyHelpers::ShouldBuildT1Nano(ei, mi,
                    s.NanoEnergyPerUnit, s.NanoMetalPerUnit, s.NanoMaxCount,
                    aiEconomyMgr.metal.current, s.NanoBuildWhenOverMetal, energyPercent)) {
                CCircuitUnit@ targetFactory = Factory::SelectFactoryNeedingNano();
                if (targetFactory !is null) {
                    IUnitTask@ t = Factory::EnqueueNanoForFactory(targetFactory, Task::Priority::NORMAL);
                    if (t !is null) return t;
                }
            }
        }
        // Tidals at sea instead of solars.
        if (EconomyHelpers::ShouldBuildT1Solar(ei, s.TidalEnergyIncomeMinimum)) {
            IUnitTask@ t = Builder::EnqueueT1Tidal(unitSide, conLocation, SQUARE_SIZE * 32, SECOND * 30);
            if (t !is null) return t;
        }
        return null;
    }

    // The primary T2 construction sub's ladder. Null when no rung fires.
    IUnitTask@ T2Ladder(CCircuitUnit@ u, Settings@ s, const string &in tag)
    {
        if (u is null || u.circuitDef is null || s is null) return null;
        const float mi = aiEconomyMgr.metal.income;
        const float ei = aiEconomyMgr.energy.income;
        const bool isEnergyFull = aiEconomyMgr.isEnergyFull;
        const bool isEnergyLow = aiEconomyMgr.energy.current < aiEconomyMgr.energy.storage * s.EnergyStorageLowPercent;
        const string unitSide = UnitHelpers::GetSideForUnitName(u.circuitDef.GetName());

        // Advanced naval energy converter when energy is healthy.
        if (EconomyHelpers::ShouldBuildT2EnergyConverter(mi, ei, isEnergyLow, isEnergyFull,
                s.MinimumMetalIncomeForAdvConverter, s.MinimumEnergyIncomeForAdvConverter)) {
            IUnitTask@ t = Builder::EnqueueAdvNavalEnergyConverter(unitSide, Factory::GetT2ShipyardPos(), SQUARE_SIZE * 32, SECOND * 60);
            if (t !is null) return t;
        }
        // One naval fusion.
        if (EconomyHelpers::ShouldBuildFusionReactor(mi, ei, isEnergyLow,
                s.MinimumMetalIncomeForFUS, s.MinimumEnergyIncomeForFUS, s.MaxEnergyIncomeForFUS)) {
            const string navalFusName = UnitHelpers::GetNavalFusionNameForSide(unitSide);
            CCircuitDef@ navalFus = (navalFusName.length() == 0 ? null : ai.GetCircuitDef(navalFusName));
            if (navalFus !is null && navalFus.count < 1) {
                IUnitTask@ t = Builder::EnqueueNavalFUS(unitSide, Factory::GetT2ShipyardPos(), SQUARE_SIZE * 32, SECOND * 300);
                if (t !is null) return t;
            }
        }
        return null;
    }

    // Any other construction ship: guard the primary while energy is low.
    IUnitTask@ AssistPrimary(CCircuitUnit@ u, Settings@ s, int timeoutFrames)
    {
        if (u is null || s is null || Builder::primaryT1SeaConstructor is null) return null;
        if (u is Builder::primaryT1SeaConstructor) return null;
        if (!EconomyHelpers::ShouldAssistPrimaryWorker(aiEconomyMgr.energy.income, s.AssistPrimaryWorkerEnergyIncomeMinimum)) return null;
        return GuardHelpers::AssignWorkerGuard(u, Builder::primaryT1SeaConstructor, Task::Priority::HIGH, true, timeoutFrames);
    }
}
