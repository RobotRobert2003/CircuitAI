// TECH's build rules as one ordered table (D-067).
#include "../../define.as"
#include "../../unit.as"
#include "../../task.as"
#include "../../global.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/units/unitdef_helpers.as"
#include "../../helpers/spatial/map_helpers.as"
#include "../../manager/builder.as"
#include "../../manager/factory.as"
#include "../../systems/construction/layout.as"
#include "../../systems/construction/eco_planner.as"
#include "../../systems/combat/spam.as"
#include "tech_forward.as"
#include "tech_factories.as"
#include "tech_harbour.as"
#include "tech_weapons.as"
#include "tech_fortifications.as"
#include "tech_flank.as"
#include "../../systems/world/lanes.as"

/******************************************************************************

TECH RULES (D-067)

Every decision TECH's experimental build system makes for a builder is one
row of the table below, evaluated top to bottom for the asking builder. A
row is: a key, who it applies to, a list of named predicates over a context
read once per ask, and an act that returns a task. The first row whose
predicates hold and whose act returns a task wins; the choice is logged.

Why a table: a rule that lives inside one rung's `if` is invisible to the
next rung, and that is how "no T1 lab once the advanced lab is under way"
was lost when the lab logic moved (D-066 follow-up 16). A predicate has one
name and one definition, referenced by every row it applies to; the order
of rows is the sequencing policy and nothing else is.

The T1 bot lab, as an example of the reasoning the table has to carry
(researched in doc/tech-eco-meta.md and the knowledge base's
70-strategy/75-team-roles.md, 50-economy/52-scaling-curves.md):

  lab.t1.opening   at game start, a throwaway at the commander, to be
                   reclaimed the moment the advanced lab begins
  lab.t1.recover   every constructor lost and no lab of any tier standing
                   or ordered: the commander rebuilds one to get builders
  fwd.t1           D-109: the spam labs go forward (the spam cluster), built
                   by the released T1 land constructors, one per +100 metal
  never            for a T1 front - TECH does not fight T1 lane battles -
                   and never a second T1 lab early ("one factory with
                   turrets beats two without", the official economy guide)

Placement is not decided here. An act names a def and asks Layout
(the turret box, a factory slot, an exact spot, a packed anchor).

******************************************************************************/
namespace TechRules {

    const int COMMANDER = 1;
    const int CON_T1 = 2;
    const int CON_T2 = 4;
    const int TURRET = 8;
    const int SEA_CON = 16;        // D-121: construction ships and subs (the harbour's; no land rule reaches them)
    const int MOBILE = COMMANDER | CON_T1 | CON_T2;
    const int CONSTRUCTORS = CON_T1 | CON_T2;
    const int ANY = MOBILE | TURRET;

    // ---------------------------------------------------------------- context

    class Ctx {
        CCircuitUnit@ u;
        const CCircuitDef@ d;
        int who;
        float mi;                   // 10-second minimum metal income
        float ei;                   // 10-second minimum energy income
        EcoPlanner::State@ eco;     // banks, counts, build power, options (read once)
        bool openingDone;
        bool intoT2;                // the advanced lab is ordered, framed or standing
        int t1Labs;                 // standing
        int t2Labs;
        int constructors;           // mobile constructors alive, commander excluded
        bool spamGate;              // the spam economy thresholds are met
        // derived economy flags, the same definitions the planner uses
        float energyTarget;
        bool draining;
        bool floatingE;
        bool floatingM;
        float surplus;
        bool fusionEra;
        // D-075: build-power scaling (the owner's rule)
        float mPull;                // metal demand this frame
        bool aheadM;                // the metal bank full or rising (TechBuild::MetalAhead) with a bank of PowerTurretBankFactor turrets
        CCircuitUnit@ building;     // the nearest structure of ours under construction within ChainAssistRadius, or null
    }

    Ctx@ Build(CCircuitUnit@ u)
    {
        if (AiPerfEnabled) AiPerfBegin(1);
        Ctx@ result = BuildMeasured(u);
        if (AiPerfEnabled) AiPerfEnd(1);
        return result;
    }

    Ctx@ BuildMeasured(CCircuitUnit@ u)
    {
        Ctx@ c = Ctx();
        @c.u = u;
        @c.d = u.circuitDef;
        if (!c.d.IsMobile()) c.who = TURRET;
        else if (SeaConstructor::IsT1(c.d) || SeaConstructor::IsT2(c.d) || TechHarbour::IsHoverConstructor(c.d)) c.who = SEA_CON;   // D-121
        else if (UnitHelpers::IsCommander(c.d)) c.who = COMMANDER;
        else c.who = (UnitHelpers::GetConstructorTier(c.d) >= 2) ? CON_T2 : CON_T1;
        c.mi = Economy::GetMinMetalIncomeLast10s();
        c.ei = Economy::GetMinEnergyIncomeLast10s();
        // D-289: no turret row reads the planner state, the counts or the
        // building/ahead flags; skip EcoPlanner::Read and the aheadM scan for
        // turrets (one O(N) read and one FindUnfinishedNear per turret ask). The
        // trace reads only mi, ei and the energy target.
        if (c.who == TURRET) {
            @c.eco = null;
            c.openingDone = RoleTech::Opening::complete;
            c.intoT2 = TechBuild::IntoT2();   // the trace's T1/T2 tag
            c.energyTarget = EcoPlanner::TargetEnergy(c.mi);
            @c.building = null;
            return c;
        }
        @c.eco = EcoPlanner::Read(u, c.mi, c.ei);
        c.openingDone = RoleTech::Opening::complete;
        c.intoT2 = TechBuild::IntoT2();
        c.t1Labs = UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT1BotLabs());
        c.t2Labs = TechFlank::NormalLabCount();
        // Read already by EcoPlanner above; only read-only getters intervened.
        c.constructors = c.eco.t1Cons + c.eco.t2Cons;
        c.spamGate = Global::Spam::Enabled && c.mi >= Global::Spam::MinMetalIncome && c.ei >= Global::Spam::MinEnergyIncome;
        const EcoPlanner::State@ s = c.eco;
        c.energyTarget = EcoPlanner::TargetEnergy(s.mIncome);
        c.draining = (s.eStor > 0.0f) && (s.eCur < Global::RoleSettings::Tech::EcoEnergyLowPercent * s.eStor) && (s.ePull > s.eIncome);
        c.floatingE = (s.eStor > 0.0f) && (s.eCur >= Global::RoleSettings::Tech::EcoConvertEnergyPercent * s.eStor);
        c.floatingM = aiEconomyMgr.isMetalFull
            || ((s.mStor > 0.0f) && (s.mCur >= Global::RoleSettings::Tech::EcoFloatMetalPercent * s.mStor) && (s.mIncome >= 5.0f));
        c.surplus = s.eIncome - s.ePull;
        c.fusionEra = (s.t2Cons > 0) && (s.eIncome >= Global::RoleSettings::Tech::EcoFusionEnergyIncome);
        c.mPull = aiEconomyMgr.metal.pull;
        {
            CCircuitDef@ nano = ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(Global::AISettings::Side));
            const float bank = (nano is null) ? 1.0e9f : nano.costM * Global::RoleSettings::Tech::PowerTurretBankFactor;
            c.aheadM = TechBuild::MetalAhead() && (s.mCur >= bank);   // read from the bank, not the pull (D-075 played)
        }
        @c.building = null;
        if (c.aheadM) {
            CCircuitUnit@ f = aiBuilderMgr.FindUnfinishedNear(Layout::BaseCentre(), Global::RoleSettings::Tech::ChainAssistRadius, null);
            if (f !is null && f.circuitDef !is null && !f.circuitDef.IsMobile()) @c.building = f;
        }
        return c;
    }

    // ---------------------------------------------------------------- predicates (named once)

    funcdef bool When(Ctx@ c);

    // Read live, not from the context: the opening act itself marks the
    // opening complete when no spot is left, and the lab row is next in the
    // same pass (played: the first lab was traced as lab.t1.recover).
    bool OpeningDone(Ctx@ c)      { return RoleTech::Opening::complete; }
    bool OpeningPending(Ctx@ c)   { return !RoleTech::Opening::complete; }
    bool IntoT2(Ctx@ c)           { return c.intoT2; }
    bool NotIntoT2(Ctx@ c)        { return !c.intoT2; }
    bool NoT1Lab(Ctx@ c)          { return c.t1Labs == 0 && aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::FACTORY), ai.GetCircuitDef(UnitHelpers::GetT1BotLabForSide(Global::AISettings::Side))) == 0; }
    bool NoLabAtAll(Ctx@ c)       { return c.t1Labs == 0 && c.t2Labs == 0 && !c.intoT2; }
    bool NoConstructors(Ctx@ c)   { return c.constructors == 0; }

    bool EcoOnline(Ctx@ c)        { return TechBuild::EcoOnline(); }   // D-102

    bool NotMetalFull(Ctx@ c)     { return !TechBuild::MetalFullLong(); }   // D-105: converters make metal; a full bank wastes it
    bool DearFrameUp(Ctx@ c)      { return aiBuilderMgr.CountUnfinishedNear(Layout::BaseCentre(), Global::RoleSettings::Tech::EcoBuildPowerRadius, Global::RoleSettings::Tech::ChainParallelCostM, null) > 0; }   // D-105
    bool TurretRoom(Ctx@ c)       { return !Layout::TurretsCapped() && Layout::CanPlaceTurret(); }   // D-105
    bool MetalFloodedLong(Ctx@ c) { return TechBuild::MetalFullLong(); }   // D-105
   // D-102: the advanced lab again once the economy is online
    bool NoAfusYetOrAgain(Ctx@ c) { return !TechBuild::IntoAfus() || (c.t2Labs == 0 && TechBuild::EcoOnline()); }   // D-078, D-102

    bool ChainActive(Ctx@ c)      { return TechChain::Active(); }
    bool ChainInactive(Ctx@ c)    { return !TechChain::Active(); }
    // D-105 (played: income +300 to +600 with the bank full and one spam lab):
    // the spam labs scale with income, ExpSpamLabs at the online income, one more
    // per SpamLabMetalStep above it, up to SpamLabsMax
    int SpamLabsFor(float mi)
    {
        int n = Global::RoleSettings::Tech::ExpSpamLabs;
        if (mi > Global::RoleSettings::Tech::LabEcoOnlineMetalIncome)
            n += int((mi - Global::RoleSettings::Tech::LabEcoOnlineMetalIncome) / Global::RoleSettings::Tech::SpamLabMetalStep);
        return (n > Global::RoleSettings::Tech::SpamLabsMax) ? Global::RoleSettings::Tech::SpamLabsMax : n;
    }
    bool SpamLabsWanted(Ctx@ c)   { return c.t1Labs < SpamLabsFor(c.mi) && aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::FACTORY), null) == 0; }
    bool MetalBottleneck(Ctx@ c)  { return c.mi < Global::RoleSettings::Tech::EcoMexExpandUntilIncome; }
    bool Draining(Ctx@ c)         { return c.draining; }

    bool EnergyShort(Ctx@ c)      { return c.energyTarget > c.ei && !c.floatingE; }

    bool EnergyIdle(Ctx@ c)       { return !c.eco.energyBuilding; }
    bool EnergyBusy(Ctx@ c)       { return c.eco.energyBuilding; }
    bool EnergyAssistable(Ctx@ c) { return c.eco.energyAssistable; }
    bool NotStalling(Ctx@ c)      { return !aiEconomyMgr.isEnergyStalling; }
    bool T2LabRetiring(Ctx@ c)    { return Factory::primaryT2BotLab !is null && Lifecycle::IsRetiring(Factory::primaryT2BotLab); }   // D-078
   // D-078: no advanced lab is ordered once the advanced fusion is under way
    bool NoDearOrderPending(Ctx@ c) { return !TechChain::DearOrderPending(); }   // D-084
    bool EnergyFloatsBank(Ctx@ c) { return TechChain::EnergyFloats(); }   // D-079: the bank-based float, the chain's definition
    bool EnergyReclaimable(Ctx@ c){ const EcoPlanner::State@ s = c.eco; return TechBuild::ReactorStands() && (s.winds + s.solars + s.advSolars) > 0; }   // D-077; D-101: a finished reactor, not a frame
    bool MetalAhead(Ctx@ c)       { return c.aheadM; }                 // D-075: income above spending, the bank rising
    bool StructureBuilding(Ctx@ c){ return c.building !is null; }      // D-075: a structure of ours is under construction
    bool ConverterSurplus(Ctx@ c) { return c.floatingE || c.surplus >= 2.0f * Global::RoleSettings::Tech::EcoConverterUse; }
    // Energy income past EcoEnergyRatioHigh times the metal income and metal not
    // floating: the energy is worth more as metal (played: ten solars, no converter)
    bool EnergyOutscalesMetal(Ctx@ c) { return c.mi > 0.0f && c.ei >= Global::RoleSettings::Tech::EcoEnergyRatioHigh * c.mi && !c.floatingM; }
    bool ConverterWanted(Ctx@ c)  { return ConverterSurplus(c) || EnergyOutscalesMetal(c); }
    bool MetalFloating(Ctx@ c)    { return c.floatingM; }
    bool EnergyAhead(Ctx@ c)      { return c.ei < 2.0f * c.energyTarget; }
    bool EnergyForMe(Ctx@ c)      { return c.eco.builderIsT2 || !c.fusionEra; }   // in the fusion era T1 builders leave energy to T2
    bool FirstTurretStands(Ctx@ c){ return aiBuilderMgr.GetStaticBuildPowerNear(Layout::BaseCentre(), Global::RoleSettings::Tech::EcoBuildPowerRadius) > 0.0f; }

    bool BaseFactoryToGo(Ctx@ c)  { return TechFactories::BaseLandFactory() !is null; }   // D-114
    bool FrontClusterOpen(Ctx@ c) { return TechFactories::OpenAbove(2) || TechFactories::RefillWanted(1, 3); }   // D-114
    bool LandCon(Ctx@ c)          { return TechForward::IsLand(c.u); }        // D-109: a bot, not an air constructor
    bool T1LandReleased(Ctx@ c)   { return TechForward::T1Released(); }       // D-109
    bool T2LandReleased(Ctx@ c)   { return TechForward::T2Released(); }       // D-109

    // ---------------------------------------------------------------- acts

    funcdef IUnitTask@ Act(Ctx@ c);

    IUnitTask@ ByKey(Ctx@ c, const string &in key) { return EcoPlanner::Enqueue(key, c.u); }

    // D-289: the turret ladder, steps 1-2, 3 and 4 (RoleTech::Tech_TurretWork)
    IUnitTask@ DoTurretAssist(Ctx@ c)
    {
        IUnitTask@ t = RoleTech::Tech_TurretAssist(c.u);
        if (t !is null) RoleTech::Tech_TurretWaited(c.u, false);
        return t;
    }
    IUnitTask@ DoTurretAny(Ctx@ c)
    {
        IUnitTask@ t = RoleTech::Tech_TurretAnyFrame(c.u, false);
        if (t !is null) RoleTech::Tech_TurretWaited(c.u, false);
        return t;
    }
    IUnitTask@ DoTurretWait(Ctx@ c)
    {
        RoleTech::Tech_TurretWaited(c.u, true);   // INV-200
        // D-229: the nuke opening re-asks its turrets every 2 s (its projects start often)
        return TechBuild::Wait((TechChain::NukeRush() ? 2 : 5) * SECOND);
    }
    IUnitTask@ DoWaitShort(Ctx@ c)      { return TechBuild::Wait(5 * SECOND); }
    IUnitTask@ DoAirDedicated(Ctx@ c)   { return TechBuild::AirDedicated(c.u); }   // D-107
    IUnitTask@ DoAirDefend(Ctx@ c)                                                  // D-123
    {
        IUnitTask@ t = TechWeapons::Work(c.u);   // D-126: a weapon cluster's slot before the old defence ring
        return (t !is null) ? t : TechBuild::AirDefence(c.u);
    }
    IUnitTask@ DoWeaponsSuper(Ctx@ c)   { return TechWeapons::SuperTask(c.u); }    // D-126
    IUnitTask@ DoWeaponsCluster(Ctx@ c) { return TechWeapons::Work(c.u); }         // D-126
    IUnitTask@ DoFlankFactory(Ctx@ c) { return TechFlank::Work(c.u); }
    IUnitTask@ DoAirFlexible(Ctx@ c)    { return TechBuild::AirFlexible(c.u); }    // D-107
    IUnitTask@ DoBaseFactoryReclaim(Ctx@ c) { return TechFactories::ReclaimBaseFactory(c.u); }   // D-114
    IUnitTask@ DoFrontCluster(Ctx@ c)       { return TechFactories::OpenWork(c.u); }            // D-114
    IUnitTask@ DoHarbourSea(Ctx@ c)     { return TechHarbour::SeaTask(c.u); }       // D-121
    IUnitTask@ DoHarbourYard(Ctx@ c)    { return TechHarbour::LandTask(c.u); }      // D-121
    IUnitTask@ DoHarbourFloat(Ctx@ c)   { return TechHarbour::CommanderFloat(c.u); } // D-121
    IUnitTask@ DoTurretSpam(Ctx@ c)     { return TechFactories::TurretFocus(c.u); }    // D-109, D-114: every front cluster's turrets
    IUnitTask@ DoFerryCargo(Ctx@ c)                                                 // D-110
    {
        if (!Team::Ferry::IsGift(c.u.id)) return null;
        return Team::Ferry::GiftTask(c.u);
    }
    IUnitTask@ DoLandRecall(Ctx@ c)     { return TechForward::Recall(c.u); }       // D-109
    IUnitTask@ DoDefendMexes(Ctx@ c)    { return TechForward::DefendMexes(c.u); }  // D-109
    IUnitTask@ DoForwardT1(Ctx@ c)      { return TechForward::ForwardT1(c.u, c.mi); }   // D-109
    IUnitTask@ DoT1Turret(Ctx@ c)       { return Layout::NanoTask(c.u, Task::Priority::HIGH); }   // D-105
    // D-105, D-289: a turret with nothing high-priority in reach assists the
    // nearest producing factory in reach (the fallback, no longer only a metal sink)
    IUnitTask@ DoTurretFactory(Ctx@ c)
    {
        IUnitTask@ t = RoleTech::Tech_TurretFactoryAssist(c.u, false);
        if (t !is null) RoleTech::Tech_TurretWaited(c.u, false);
        return t;
    }
    IUnitTask@ DoWait(Ctx@ c)           { return TechBuild::Wait(3 * SECOND); }
    IUnitTask@ DoGantrySupport(Ctx@ c) { return TechGantry::SupportWork(c.u); }
    bool GantryScaleDue(Ctx@ c)        { return TechGantryScale::Due(); }        // D-288: O(1), set at 1 Hz
    IUnitTask@ DoGantryScale(Ctx@ c)   { return TechGantryScale::Work(c.u); }    // D-288
    IUnitTask@ DoKeepCurrent(Ctx@ c)    { return TechBuild::KeepCurrent(c.u); }
    IUnitTask@ DoRecovery(Ctx@ c)       { return TechBuild::RecoverEconomy(c.u); }
    IUnitTask@ DoEcoFlak(Ctx@ c)        { return EcoFlak::Work(c.u); }
    IUnitTask@ DoCompactSupport(Ctx@ c) { return c.draining ? null : CompactEco::SupportTask(c.u); }
    IUnitTask@ DoLocalGeo(Ctx@ c) {
        // Keep the committed silo/first-stockpile budget intact. Geothermal
        // remains available before the silo phase and after the first missile.
        if (TechChain::nukeLabReleased || TechChain::nukeFundingSilo >= 0) {
            if (TechChain::NukeRush() || TechChain::nukeFundingSilo >= 0) return null;
        }
        return LocalGeothermal::Work(c.u);
    }
    IUnitTask@ DoChain(Ctx@ c)
    {
        IUnitTask@ t = TechChain::Next(c.u);
        // A rush placement waiting on its turret frames must not fall through
        // to an economy row that starts the same fusion at an unsupported site.
        return (t is null && TechChain::NukeRush()) ? TechBuild::Wait(SECOND) : t;
    }
    IUnitTask@ DoOpening(Ctx@ c)        { return RoleTech::Opening::MakeTask(c.u); }
    IUnitTask@ DoReclaimT1Lab(Ctx@ c)
    {
        return TechBuild::ReclaimT1Lab(c.u, (c.who == COMMANDER) ? Global::RoleSettings::Tech::ExpCommanderHomeRadius
                                                                  : Global::RoleSettings::Tech::ExpAssistRadius);
    }
    IUnitTask@ DoStartFactory(Ctx@ c)   { return TechBuild::StartFactory(c.u); }

    IUnitTask@ DoExpandMex(Ctx@ c)      { return TechBuild::ExpandMex(c.u, c.mi); }
    IUnitTask@ DoEnergy(Ctx@ c)
    {
        string why;
        const string key = EcoPlanner::PickEnergy(c.eco, why, c.draining ? "energy draining" : "energy below target " + int(c.energyTarget));
        if (key.length() == 0) return null;
        IUnitTask@ redirect = RoleTech::Tech_RedirectEnergyToReactor("rule energy: " + key, c.u);
        if (redirect !is null) return redirect;
        return ByKey(c, key);
    }
    IUnitTask@ DoAssistEnergy(Ctx@ c)   { return ByKey(c, "assistenergy"); }
    IUnitTask@ DoT2Lab(Ctx@ c)
    {
        string why;
        if (EcoPlanner::PickT2Lab(c.eco, why).length() == 0) return null;
        return ByKey(c, "t2lab");
    }
    IUnitTask@ DoMexUpgrade(Ctx@ c)
    {
        string why;
        if (EcoPlanner::PickMexUpgrade(c.eco, why).length() == 0) return null;
        return ByKey(c, "mexup");
    }
    IUnitTask@ DoConverter(Ctx@ c)
    {
        string why;
        // when energy outscales metal a T1 converter's draw is granted even without a measured surplus
        float surplus = c.surplus;
        if (EnergyOutscalesMetal(c) && surplus < Global::RoleSettings::Tech::EcoConverterUse) surplus = Global::RoleSettings::Tech::EcoConverterUse;
        const string key = EcoPlanner::PickConverter(c.eco, surplus, why);
        if (key.length() == 0) {
            // An abstract supply gate is insufficient when the real chooser
            // cannot offer work. Release the hold for this decision only.
            if (EcoPlanner::conversionDecision !is null) EcoPlanner::conversionDecision.selectionRejected = true;
            EcoPlanner::TraceConversion(c.u, EcoPlanner::conversionDecision !is null
                && EcoPlanner::conversionDecision.placementRejected ? EcoPlanner::PLACEMENT : EcoPlanner::NO_OPTION);
            return null;
        }
        return ByKey(c, key);
    }
    // D-075, the owner's rule: metal income above spending while a structure
    // is under construction means build power is short: a construction
    // turret (the box slot nearest a lab), Layout::TurretsAllowed at a time (D-097);
    // the rest assist the turret going up. When nothing is under
    // construction the rows below order the next structure by priority.
    int powerTurretNoSlotLog = -100000;
    IUnitTask@ DoReclaimT2Lab(Ctx@ c) { return TechBuild::ReclaimT2Lab(c.u); }   // D-078
    IUnitTask@ DoEnergyReclaim(Ctx@ c) { return TechBuild::ReclaimEnergy(c.u, c.eco); }   // D-077
    IUnitTask@ DoPowerTurret(Ctx@ c)
    {
        const EcoPlanner::State@ s = c.eco;
        CCircuitDef@ nano = ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(Global::AISettings::Side));
        if (nano is null || !nano.IsAvailable(ai.frame)) return null;
        // before the advanced lab the rush owns the builders: only a bank that
        // has sat full for PowerAheadSeconds counts (played: a rising bank of 800
        // sent the commander to a turret at 4:00 and the advanced lab came at 7:13)
        if (!TechBuild::IntoT2() && !TechBuild::MetalFullLong()) return null;
        // build power scales with income: at the target, the rows below spend the metal instead
        // ... unless the metal bank has been full for PowerAheadSeconds: a full
        // bank with a structure under construction is build power short whatever
        // the ratio says (played: the advanced fusion took six minutes at a full
        // bank with the rule at its cap; the cap exists for the idle base after
        // the objective, D-075)
        if (!TechBuild::MetalFullLong() && s.buildPowerNear >= s.mIncome * Global::RoleSettings::Tech::PowerBuildPowerPerMetal) return null;
        const bool onNano = (c.building.circuitDef is nano);
        if (!onNano && !Layout::TurretsCapped() && c.d.CanBuild(nano)) {   // D-097: queued orders count too
            IUnitTask@ t = Layout::NanoTask(c.u, Task::Priority::HIGH);
            if (t !is null) {
                GenericHelpers::LogUtil("[TECH][Power] +" + int(s.mIncome) + " metal, " + TechBuild::MetalAheadWhy() + " (" + int(s.mCur) + " of " + int(s.mStor)
                    + ") while " + c.building.circuitDef.GetName() + " is under construction: turret by " + c.d.GetName() + " " + c.u.id, 1);
                return t;
            }
            if (ai.frame - powerTurretNoSlotLog > 30 * SECOND) {
                powerTurretNoSlotLog = ai.frame;
                GenericHelpers::LogUtil("[TECH][Power] no turret slot for " + c.d.GetName() + " (" + (s.turretSlot ? "slot yes" : "slot no") + ")", 1);
            }
        }
        if (s.nanosBuilding > 0) return ByKey(c, "assistnano");
        // D-098 (owner's rule): metal high while a structure is going up and no
        // turret may start: this builder's power goes on that structure
        if (c.building !is null && c.d.IsMobile())
            return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, c.building, 60 * SECOND));
        return null;
    }
    IUnitTask@ DoTurret(Ctx@ c)
    {
        string why;
        const string key = EcoPlanner::PickTurret(c.eco, c.floatingM, why);   // "nano", "assistnano" or ""
        if (key.length() == 0) return null;
        return ByKey(c, key);
    }
    IUnitTask@ DoEnergyStorage(Ctx@ c)
    {
        const EcoPlanner::State@ s = c.eco;
        const string name = UnitHelpers::GetEnergyStorageNameForSide(Global::AISettings::Side);
        const bool lulls = s.winds >= Global::RoleSettings::Tech::EcoStorageWinds && s.estors + s.estorsQueued < 1 && s.mIncome >= 4.0f;
        const bool small = s.estors + s.estorsQueued < Global::RoleSettings::Tech::EcoMaxEnergyStorages
            && s.eStor < s.eIncome * Global::RoleSettings::Tech::EcoStorageSeconds && s.mIncome >= 15.0f
            && s.mCur >= Global::RoleSettings::Tech::EcoStorageMinMetalBank;
        if (!(lulls || small) || !EcoPlanner::Buildable(name, s)) return null;
        return ByKey(c, "estor");
    }
    IUnitTask@ DoMetalStorage(Ctx@ c)
    {
        const EcoPlanner::State@ s = c.eco;
        const string name = UnitHelpers::GetMetalStorageNameForSide(Global::AISettings::Side);
        if (!(aiEconomyMgr.isMetalFull && s.mstors + s.mstorsQueued < Global::RoleSettings::Tech::EcoMaxMetalStorages && s.mIncome >= 20.0f)) return null;
        if (!EcoPlanner::Buildable(name, s)) return null;
        return ByKey(c, "mstor");
    }
    IUnitTask@ DoBestPayback(Ctx@ c)
    {
        const array<EcoPlanner::Option@>@ opts = EcoPlanner::EnergyOptions(c.eco);
        for (uint i = 0; i < opts.length(); ++i)
            if (EcoPlanner::Affordable(opts[i], c.eco)) return ByKey(c, opts[i].key);
        return null;
    }
    IUnitTask@ DoLegacy(Ctx@ c)
    {
        if (c.who == COMMANDER) return RoleTech::Tech_Commander_AiMakeTask(c.u, null, c.mi);
        return TechBuild::Strategic(c.u, c.mi, c.ei);
    }
    IUnitTask@ DoDefence(Ctx@ c)        { return TechBuild::Defence(c.u); }
    IUnitTask@ DoQueuedRepair(Ctx@ c)   { return TechBuild::QueuedOrder(c.u); }
    IUnitTask@ DoAssistAny(Ctx@ c)
    {
        return TechBuild::AssistAny(c.u, (c.who == COMMANDER) ? Global::RoleSettings::Tech::ExpCommanderHomeRadius
                                                               : Global::RoleSettings::Tech::ExpAssistRadius);
    }
    IUnitTask@ DoGuardFactory(Ctx@ c)   { return TechBuild::GuardFactory(c.u); }

    array<When@> W0() { array<When@> a; return a; }
    array<When@> W1(When@ a1) { array<When@> a = {a1}; return a; }
    array<When@> W2(When@ a1, When@ a2) { array<When@> a = {a1, a2}; return a; }
    array<When@> W3(When@ a1, When@ a2, When@ a3) { array<When@> a = {a1, a2, a3}; return a; }
    array<When@> W4(When@ a1, When@ a2, When@ a3, When@ a4) { array<When@> a = {a1, a2, a3, a4}; return a; }
    array<When@> W5(When@ a1, When@ a2, When@ a3, When@ a4, When@ a5) { array<When@> a = {a1, a2, a3, a4, a5}; return a; }

    // ---------------------------------------------------------------- the table

    class Rule {
        string key;
        int who;
        array<When@> when;
        Act@ act;
        string note;
        Rule(const string &in k, int w, array<When@> ws, Act@ a, const string &in n)
        {
            key = k; who = w; when = ws; @act = a; note = n;
        }
    }

    array<Rule@> table;
    Rule@ airDefendRule = Rule("air.defend", CONSTRUCTORS, W0(), @DoAirDefend, "D-123: in place of a wait");   // D-123: the trace of a wait replaced

    void Init()
    {
        if (table.length() > 0) return;
        table.insertLast(Rule("ferry.cargo",       MOBILE,       W0(), @DoFerryCargo,   "D-110/D-112/D-160: a gift belongs to the ferry before discretionary harbour or economy work"));
        table.insertLast(Rule("harbour.sea",       SEA_CON,      W0(), @DoHarbourSea,   "D-121: construction ships and subs: the advanced shipyard, floating turrets, then the sea economy"));
        table.insertLast(Rule("harbour.yard",      MOBILE,       W0(), @DoHarbourYard,  "D-121: an island TECH with its advanced fusions: the T1 shipyard offshore, once"));
        table.insertLast(Rule("harbour.float",     COMMANDER,    W0(), @DoHarbourFloat, "D-121: an island TECH's commander: floating converters while energy floats (the land is for labs and fusions)"));
        table.insertLast(Rule("turret.spam",       TURRET,       W0(), @DoTurretSpam,   "D-109: the two turrets directly behind a spam lab always work for that lab"));
        table.insertLast(Rule("turret.assist",     TURRET,       W0(), @DoTurretAssist, "D-289 steps 1-2: a reclaim in reach the D-290 gate allows, then high-priority frames in reach (nuke projects; the advanced fusion when converters starve; the chain's dear frame; the labs; the D-065 economy order)"));
        table.insertLast(Rule("turret.any",        TURRET,       W0(), @DoTurretAny,    "D-289 step 3: any structure of ours under construction in exact reach (build distance + model radius)"));
        table.insertLast(Rule("turret.factory",    TURRET,       W0(), @DoTurretFactory, "D-289 step 4 (owner): nothing high-priority in reach: guard a producing, non-spam, non-retiring factory in reach (not while energy stalls, the bank is nearly empty under a dear frame, or the nuke silo is funded)"));
        table.insertLast(Rule("turret.wait",       TURRET,       W0(), @DoTurretWait,   "5 s (2 s in the nuke opening); INV-200 watches the wait"));
        table.insertLast(Rule("land.recall",       CONSTRUCTORS, W0(), @DoLandRecall,   "D-109: a tier whose air constructors went down: its land constructors drop a forward job for the eco rows"));
        table.insertLast(Rule("weapons.super",     CONSTRUCTORS, W0(), @DoWeaponsSuper, "D-126 (owner): a super cannon framed or startable: every air constructor builds it"));
        table.insertLast(Rule("keep.current",      MOBILE,       W0(), @DoKeepCurrent,  "the construction the builder is on, when native re-asks"));
        table.insertLast(Rule("eco.recover",       MOBILE,       W0(), @DoRecovery, "D-306: restore safe lost layout capacity before discretionary growth"));
        table.insertLast(Rule("eco.flak", CON_T2, W0(), @DoEcoFlak, "D-321: perimeter flak minimum, air response and replacement; shared cooldown and per-cluster cap"));
        if (Global::Map::Config.TechCompactEconomy)
            table.insertLast(Rule("eco.compact.support", CON_T1, W0(), @DoCompactSupport, "D-307: one local turret for an active compact economy bank"));
        table.insertLast(Rule("gantry.support", CON_T1, W0(), @DoGantrySupport, "D-281: capable constructors carry an admitted gantry turret assignment before discretionary forward work"));
        table.insertLast(Rule("air.dedicated",     CON_T2,       W0(), @DoAirDedicated, "D-107: the first two T2 air constructors: one only advanced energy converters, the other only advanced fusions, always"));
        table.insertLast(Rule("gantry.scale",      CON_T2,       W1(@GantryScaleDue), @DoGantryScale, "D-288 (owner): one gantry per GantryScaleMetalStep of 10 s minimum metal income: opens and feeds the front T3 cluster; lab.front and gantry.support also finish it"));
        table.insertLast(Rule("flank.factory",     CONSTRUCTORS, W0(), @DoFlankFactory, "D-136: from +200 metal a separate T2 lab feeds an accessible specialist land flank"));
        table.insertLast(Rule("air.flex",          CON_T2,       W0(), @DoAirFlexible,  "D-107: the other T2 air constructors: advanced converters while energy overflows, the advanced fusion going up when the converters cannot stay on"));
        table.insertLast(Rule("defence.fortify", CONSTRUCTORS, W0(), @DoDefence, "D-152: lane walls after base build power, or T2 resource protection, within the fortification budget"));
        table.insertLast(Rule("weapons.cluster",   CONSTRUCTORS, W0(), @DoWeaponsCluster, "D-126: from +200 metal, within the weapon budget: the highest-priority weapon cluster's next slot (kill zone, air defence, artillery, long range, coast, the super cannon's escort)"));
        table.insertLast(Rule("fwd.t2.defend",     CON_T2,       W2(@LandCon, @T2LandReleased), @DoDefendMexes, "D-109: the T2 air constructors are up: T2 land constructors defend the mex clusters, long-range AA then flak"));
        table.insertLast(Rule("fwd.t1",            CON_T1,       W2(@LandCon, @T1LandReleased), @DoForwardT1,   "D-109: more than 5 T1 air constructors: T1 land constructors build the spam cluster forward (labs, their turrets, AA, pads)"));
        table.insertLast(Rule("opening.mex",       COMMANDER,    W1(@OpeningPending), @DoOpening,      "the nearest OpeningMexCap mexes within OpeningMexRadius"));
        table.insertLast(Rule("lab.t1.reclaim",    MOBILE,       W1(@IntoT2), @DoReclaimT1Lab, "the advanced lab is under way: every builder in range reclaims the T1 lab"));
        table.insertLast(Rule("lab.t2.reclaim",     MOBILE,       W1(@T2LabRetiring), @DoReclaimT2Lab, "D-078: the advanced lab is retiring (an advanced fusion is under construction, the bank has room): every builder reclaims it, turrets in range join"));
        table.insertLast(Rule("lab.base.reclaim",   MOBILE,       W1(@BaseFactoryToGo), @DoBaseFactoryReclaim, "D-114: with 3 land factories on the map the base's land factories are retired and reclaimed; their ground goes back to the economy"));
        table.insertLast(Rule("lab.front",          CONSTRUCTORS, W1(@FrontClusterOpen), @DoFrontCluster, "D-114: a front cluster's lost turret; an open T2 or T3 front factory cluster: its turrets, help on one going up, then its factory"));
        table.insertLast(Rule("energy.reclaim",     MOBILE,       W2(@EnergyReclaimable, @NotStalling), @DoEnergyReclaim, "D-077: a fusion stands and energy income without the T1 sources covers the pull by ReclaimT1EnergyMargin: reclaim winds and solars nearest the base centre; advanced solars at ReclaimAdvSolarMargin; an advanced fusion reclaims all"));
        // D-105 (owner's rule): T1 constructors add build power before assisting a
        // T2 construction; the reclaim rows above stay first
        table.insertLast(Rule("power.t1",          CON_T1,       W2(@DearFrameUp, @TurretRoom), @DoT1Turret,     "D-105: a dear frame is up and the turret calculation has room: a T1 constructor adds a construction turret rather than assist"));
        table.insertLast(Rule("energy.convert.float", MOBILE,     W4(@EnergyFloatsBank, @NotStalling, @NoDearOrderPending, @NotMetalFull), @DoConverter,    "D-079: before the chain - energy floats (TechChain::EnergyFloats): a converter, whatever the chain is doing"));
        table.insertLast(Rule("power.turret",      MOBILE,       W4(@MetalAhead, @StructureBuilding, @NotStalling, @NoDearOrderPending), @DoPowerTurret, "D-075: metal income above spending while a structure is under construction: a turret, Layout::TurretsAllowed at a time (D-097), else assist the turret going up"));
        table.insertLast(Rule("energy.geo",        MOBILE,       W0(), @DoLocalGeo, "safe local geothermal before discretionary reactors"));
        table.insertLast(Rule("chain.next",        MOBILE,       W1(@ChainActive), @DoChain,      "the rush chain (D-070): the first unmet target - assist its frame, wait for its order, or order it"));
        table.insertLast(Rule("lab.t1.opening",    MOBILE,       W3(@OpeningDone, @NotIntoT2, @NoT1Lab), @DoStartFactory, "the throwaway first lab at the commander; a constructor uses the pair's slot"));
        table.insertLast(Rule("lab.t1.recover",    COMMANDER,    W3(@OpeningDone, @NoConstructors, @NoLabAtAll), @DoStartFactory, "every constructor and every lab lost: the commander rebuilds a T1 lab"));
        table.insertLast(Rule("mex.expand",        CONSTRUCTORS, W2(@OpeningDone, @MetalBottleneck), @DoExpandMex,    "the nearest open spot within EcoMexExpandRadius while metal is the bottleneck"));
        table.insertLast(Rule("energy.draining",   MOBILE,       W2(@Draining, @EnergyIdle), @DoEnergy,       "the base is stalling: cheapest energy per E/s, a fusion in the fusion era"));
        table.insertLast(Rule("energy.assist",     MOBILE,       W3(@Draining, @EnergyBusy, @EnergyAssistable), @DoAssistEnergy, "stalling and one is going up within EcoAssistRadius: assist it"));
        table.insertLast(Rule("lab.t2",            CONSTRUCTORS, W2(@OpeningDone, @NoAfusYetOrAgain), @DoT2Lab,        "the advanced lab the moment +18 metal / 250 energy clear (PickT2Lab); again once the economy is online and none stands (D-102)"));
        table.insertLast(Rule("mex.upgrade",       CON_T2,       W0(), @DoMexUpgrade,   "the nearest owned T1 mex within MexUpgradeRadius, one at a time"));
        table.insertLast(Rule("energy.convert",    MOBILE,       W3(@ConverterWanted, @NotStalling, @NotMetalFull), @DoConverter,    "energy floating, a surplus of twice a converter's draw, or energy income past EcoEnergyRatioHigh x metal: a converter"));
        table.insertLast(Rule("turret.build",      MOBILE,       W0(), @DoTurret,       "static build power under EcoBuildPowerPerMetal x metal, or metal floating: a turret on its slot; else assist the one going up"));
        table.insertLast(Rule("energy.short",      MOBILE,       W3(@EnergyShort, @EnergyIdle, @EnergyForMe), @DoEnergy,       "below the energy target and nothing going up: cheapest energy per E/s"));
        table.insertLast(Rule("energy.assist2",    MOBILE,       W3(@EnergyShort, @EnergyBusy, @EnergyAssistable), @DoAssistEnergy, "below target and one is going up within EcoAssistRadius: assist it"));
        table.insertLast(Rule("storage.energy",    MOBILE,       W0(), @DoEnergyStorage, "one energy storage once winds carry the base, or the bank holds under EcoStorageSeconds"));
        table.insertLast(Rule("storage.metal",     MOBILE,       W0(), @DoMetalStorage, "metal storage when the bank is full"));
        table.insertLast(Rule("energy.float",      MOBILE,       W3(@MetalFloating, @EnergyAhead, @EnergyIdle), @DoBestPayback,  "metal floating with energy ahead: the best-payback source anyway"));
        table.insertLast(Rule("legacy.strategic",  MOBILE,       W1(@ChainInactive), @DoLegacy,       "the role's strategic rungs as they stand (nukes, anti-nuke, gantry, water factories, T2 constructor policy)"));
        table.insertLast(Rule("defence.base",      CONSTRUCTORS, W1(@FirstTurretStands), @DoDefence,      "one light laser and one light AA near the factories"));
        table.insertLast(Rule("order.repair",      CONSTRUCTORS, W0(), @DoQueuedRepair, "native's queued repairs of our own unfinished structures within ExpOrderRadius"));
        table.insertLast(Rule("assist.any",        MOBILE,       W0(), @DoAssistAny,    "the nearest structure under construction within the builder's assist radius"));
        table.insertLast(Rule("guard.factory",     CONSTRUCTORS, W0(), @DoGuardFactory, "guard the primary T1 lab"));
        table.insertLast(Rule("air.defend",        CONSTRUCTORS, W0(), @DoAirDefend,    "D-123 (owner): an air constructor with nothing else to do builds defences: the mex clusters' AA, then a ring round the base toward the front"));
        table.insertLast(Rule("wait",              MOBILE,       W0(), @DoWait,         "3 s, then ask again"));
        GenericHelpers::LogUtil("[Rule] table of " + table.length() + " rules loaded", 1);
    }

    // ---------------------------------------------------------------- evaluation and trace

    dictionary lastKeyByUnit;   // unit id -> last key, for the level-1 change trace
    dictionary lastIdleAsks;    // D-123: air constructor -> asks in a row while idle

    IUnitTask@ Evaluate(CCircuitUnit@ u)
    {
        if (AiPerfEnabled) AiPerfBegin(3);
        EcoPlanner::ConversionDecision@ previous = EcoPlanner::conversionDecision;
        EcoPlanner::BeginConversionDecision(u);
        IUnitTask@ result = EvaluateMeasured(u);
        EcoPlanner::EndConversionDecision(previous);
        if (AiPerfEnabled) AiPerfEnd(3);
        return result;
    }

    IUnitTask@ EvaluateMeasured(CCircuitUnit@ u)
    {
        if (u is null || u.circuitDef is null) return null;
        // Preserve ownership even when a caller invokes the role directly.
        // In particular D-123 must not turn a ferry wait into air defence.
        if (Team::Ferry::IsGift(u.id)) return Team::Ferry::GiftTask(u);
        Init();
        Ctx@ c = Build(u);
        {   // diagnostic (D-070 benchmarks): what the unit holds when it is asked
            IBuilderTask@ cur = (u.task is null) ? null : cast<IBuilderTask>(u.task);
            const string sig = (u.task is null) ? "no task" : ((cur is null) ? "non-builder task" : ("builder task type " + int(cur.GetBuildType())
                + (cur.buildDef is null ? "" : " " + cur.buildDef.GetName())));
            const string id = "ask" + u.id;
            string last; lastKeyByUnit.get(id, last);
            if (last != sig) { lastKeyByUnit.set(id, sig); GenericHelpers::LogUtil("[Rule][ask] " + c.d.GetName() + " " + u.id + " holds " + sig, 3); }
        }
        // D-123: an air constructor asked again and again while idle is being handed
        // a job it never takes up (played: chain.next and power.turret, 60 s and
        // more idle): after AirIdleAsks such asks, defences
        // Dedicated economy workers must retry their own layout, not accumulate
        // idle asks and escape into defensive work. Two ID comparisons; no scan.
        const bool dedicatedEconomy = Global::AISettings::Role == AiRole::TECH && TechBuild::IsDedicatedAirCon(u);
        if (UnitHelpers::IsAirConstructor(c.d) && !dedicatedEconomy) {
            const string ik = "idle" + u.id;
            int64 asks = 0;
            if (!lastIdleAsks.get(ik, asks)) asks = 0;
            const bool idleNow = (u.task is null) || int(u.task.GetType()) == int(Task::Type::IDLE);
            asks = idleNow ? asks + 1 : 0;
            lastIdleAsks.set(ik, asks);
            if (asks >= Global::RoleSettings::Tech::AirIdleAsks) {
                if (AiPerfEnabled) AiPerfBeginLabel("idle-air-defense");
                IUnitTask@ dt = TechBuild::AirDefence(u);
                if (AiPerfEnabled) AiPerfEndLabel();
                if (dt !is null) { lastIdleAsks.set(ik, int64(0)); Trace(c, airDefendRule); return dt; }
            }
        }
        bool openingWorker = MetalEconomy::Active() && MetalEconomy::OpeningWorker(u);
        const bool nukeRush = TechChain::NukeRush();
        for (uint i = 0; i < table.length(); ++i) {
            Rule@ r = table[i];
            if (dedicatedEconomy && r.key == "weapons.super") continue;
            // D-229: a first-shot investment has a fixed upgrade/build-power
            // budget. Once its silo stands this gate disappears; the shared
            // economic policy and its placement sequence are unchanged.
            if (nukeRush) {
                if (r.key == "eco.recover" || r.key == "eco.compact.support") continue;
                if (r.key == "defence.fortify" || r.key == "mex.upgrade" || r.key == "mex.expand"
                    || r.key == "energy.reclaim" || r.key == "lab.t2" || r.key == "defence.base"
                    || r.key == "power.t1" || r.key == "power.turret" || r.key == "turret.build"
                    || r.key == "weapons.super" || r.key == "weapons.cluster" || r.key == "flank.factory"
                    || r.key == "air.dedicated" || r.key == "air.flex" || r.key == "fwd.t1" || r.key == "fwd.t2.defend"
                    || r.key == "energy.convert.float" || r.key == "energy.float" || r.key == "storage.metal") continue;
            }
            if (MetalEconomy::Active()) {
                // Keep lab reclaim/rebuild precedence, then protect the two
                // dedicated opening workers before discretionary investment.
                if (r.key == "power.t1") {
                    openingWorker = false;
                    IUnitTask@ dedicated = MetalEconomy::DedicatedTask(u);
                    if (dedicated !is null) return dedicated;
                    if (u.id == MetalEconomy::workers[2] && aiTerrainMgr.GetLayoutInt("metal.techTransition", 0) == 0
                        && !c.eco.t2Lab && c.eco.t2LabQueued == 0) {
                        IUnitTask@ transition = DoT2Lab(c);
                        if (transition !is null) {
                            aiTerrainMgr.SetLayoutInt("metal.techTransition", 1);
                            return transition;
                        }
                    }
                }
                if (openingWorker && r.key != "ferry.cargo" && r.key != "keep.current"
                    && r.key != "lab.t1.reclaim" && r.key != "lab.t2.reclaim" && r.key != "lab.base.reclaim") continue;
                if (r.key == "mex.expand" && c.openingDone && (c.who & MOBILE) != 0) {
                    IUnitTask@ field = MetalEconomy::EconomyTask(u);
                    if (field !is null) return field;
                }
                if (MetalEconomy::SkipTechRule(r.key)) continue;
            }
            if ((r.who & c.who) == 0) continue;
            if (AiPerfEnabled) AiPerfBeginLabel(r.key);
            bool ok = true;
            for (uint k = 0; k < r.when.length() && ok; ++k) ok = r.when[k](c);
            if (!ok) {
                if (AiPerfEnabled) AiPerfEndLabel();
                continue;
            }
            const string previousAdmissionRule = Invariants::constructionAdmissionRule;
            Invariants::constructionAdmissionRule = r.key;
            IUnitTask@ t = r.act(c);
            Invariants::constructionAdmissionRule = previousAdmissionRule;
            if (AiPerfEnabled) AiPerfEndLabel();
            if (t is null) continue;
            // D-123 (owner: an air constructor never does nothing): whichever row
            // answered with a wait (played: the rush chain's "order out", 60 s
            // idle), defences come first; the wait is dropped
            if (UnitHelpers::IsAirConstructor(c.d) && !dedicatedEconomy) {
                IBuilderTask@ bt = cast<IBuilderTask>(t);
                if (bt !is null && Task::BuildType(bt.GetBuildType()) == Task::BuildType::WAIT) {
                    if (AiPerfEnabled) AiPerfBeginLabel("wait-air-defense");
                    IUnitTask@ dt = TechBuild::AirDefence(c.u);
                    // A blocked front/layout request is not a reason to leave a
                    // mobile air builder idle while reachable home frames exist.
                    // Ferry cargo and dedicated economy ownership retain their
                    // exclusive contracts; no shared task is aborted here.
                    if (dt is null && r.key != "ferry.cargo" && r.key != "air.dedicated"
                        && r.key != "keep.current" && !nukeRush)
                        @dt = TechBuild::AssistAny(c.u, Global::RoleSettings::Tech::EcoAssistRadius);
                    if (AiPerfEnabled) AiPerfEndLabel();
                    if (dt !is null) {
                        aiBuilderMgr.AbortTask(t);
                        Trace(c, airDefendRule);
                        return dt;
                    }
                }
            }
            Trace(c, r);
            return t;
        }
        return null;
    }

    void Trace(Ctx@ c, const Rule@ r)
    {
        if (MetalEconomy::Active() && MetalEconomy::OpeningWorker(c.u)
            && (r.key == "weapons.cluster" || r.key == "weapons.super" || r.key == "defence.fortify"
                || r.key == "flank.factory" || r.key == "fwd.t1" || r.key == "lab.front"))
            Invariants::Violation("INV-113", "" + c.u.id, "dedicated metal opening worker diverted to " + r.key);
        const string id = "" + c.u.id;
        string last;
        lastKeyByUnit.get(id, last);
        const int level = (last == r.key || r.key == "keep.current" || r.key == "wait" || r.key == "turret.wait") ? 3 : 1;
        lastKeyByUnit.set(id, r.key);
        GenericHelpers::LogUtil("[Rule] " + r.key + " for " + c.d.GetName() + " " + c.u.id + " | M +" + int(c.mi) + " E " + int(c.ei)
            + "/" + int(c.energyTarget) + (c.intoT2 ? " T2" : " T1") + (c.draining ? " draining" : "") + (c.floatingE ? " E-float" : "")
            + (c.floatingM ? " M-float" : ""), level);
    }
}
