// D-352: this AI's mex territory claim, computed from its role's opening plan
// and the unit definitions, broadcast in the roster line and applied natively
// for every ally with the same numbers (resource/MexTerritory.h).
#include "../../define.as"
#include "../../global.as"
#include "../../types/ai_role.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/spatial/map_helpers.as"
#include "../../helpers/units/unit_helpers.as"
#include "../presentation/widget_link.as"

/******************************************************************************

MEX CLAIM

Native owns the mechanism (fields, the theatre mask, the four rules, the race,
the lane partition); this file owns the policy numbers per role:

    ground class     the T1 bot constructor of the side (the LAND bit, lanes)
    own class        SEA: construction ship; TACTICAL: construction hovercraft;
                     AIR: construction aircraft; others: the ground class
    readiness        the frame the first constructor of the own class exists:
                     estimated from the opening plan (home spots, the walk to
                     the yard, the factory, the constructor) with the defs and
                     the measured income, then replaced by observation
    secure seconds   the role's securing structures timed with the
                     constructor's build power and the income
    combat class     SEA: patrol boat; TACTICAL: hover raider; AIR: none
    anchor           SEA: the planned T1 shipyard berth, then the yard itself

Everything is re-announced on a change (readiness by more than
ReannounceSeconds, anchor by more than ReannounceAnchor elmos, a class
change), never periodically. Every ally applies the broadcast numbers, never
a local estimate, so all allies resolve the same owner for every spot.

******************************************************************************/
// Global scope on purpose: a roster Entry member of a namespaced class type
// fails AngelScript's declaration pass ("Namespace 'MexClaim' doesn't exist").
class MexClaimData {
    string groundDef;
    string classDef;
    string combatDef;
    int readyFrame = 0;
    int combatReadyFrame = 0;
    int secureSeconds = 0;
    AIFloat3 anchor = AIFloat3(-1.0f, 0.0f, -1.0f);
    bool laneSpots = false;
    bool valid = false;
}

namespace Team {
namespace MexClaim {
    MexClaimData current;
    bool announcedOnce = false;
    bool enemyAnnounced = false;
    bool sentInvalid = false;     // a roster reply went out before the first claim was computed
    bool rosterDumped = false, windowDumped = false;
    int widgetFrame = -1;
    string widgetLast;

    bool Enabled() { return Global::RoleSettings::MexClaim::TheatresEnabled && Global::RoleSettings::MexOwnershipEnabled; }

    float HomeRadius()
    {
        if (Global::AISettings::Role == AiRole::SEA && Global::RoleSettings::Sea::HomeMexRadius > 0.0f)
            return Global::RoleSettings::Sea::HomeMexRadius;
        return Global::RoleSettings::MexClaim::HomeRadius;
    }

    bool LaneSpots(AiRole role)
    {
        switch (role) {
            case AiRole::FRONT: return Global::RoleSettings::MexClaim::FrontLaneSpots;
            case AiRole::SUPPORT: return Global::RoleSettings::MexClaim::SupportLaneSpots;
            case AiRole::TACTICAL: return Global::RoleSettings::MexClaim::TacticalLaneSpots;
            case AiRole::TECH: return Global::RoleSettings::MexClaim::TechLaneSpots;
            case AiRole::AIR: return Global::RoleSettings::MexClaim::AirLaneSpots;
            case AiRole::SEA: return Global::RoleSettings::MexClaim::SeaLaneSpots;
        }
        return false;
    }

    string GroundDef(const string &in side)
    {
        array<string> bots = UnitHelpers::GetT1BotConstructors(side);
        return bots.length() > 0 ? bots[0] : "armck";
    }
    string ConShip(const string &in side)
    {
        if (side == "cortex") return "corcs";
        if (side == "legion") return "legnavyconship";
        return "armcs";
    }
    string PatrolBoat(const string &in side)
    {
        if (side == "cortex") return "corpt";
        if (side == "legion") return "legnavyscout";
        return "armpt";
    }
    string HoverRaider(const string &in side)
    {
        if (side == "cortex") return "corsh";
        if (side == "legion") return "legsh";
        return "armsh";
    }
    string MexName(const string &in side)
    {
        if (side == "cortex") return "cormex";
        if (side == "legion") return "legmex";
        return "armmex";
    }

    // Seconds a builder of buildPower needs for def at this income: the
    // slower of the build-time bound and the metal bound.
    float StepSeconds(CCircuitDef@ def, float buildPower, float income)
    {
        if (def is null) return 0.0f;
        const float byTime = buildPower > 0.0f ? def.GetBuildTime() / buildPower : 0.0f;
        const float byMetal = income > 0.0f ? def.costM / income : 0.0f;
        return AiMax(byTime, byMetal);
    }
    float Income()
    {
        return AiMax(Global::RoleSettings::MexClaim::ExpectedOpeningIncome, aiEconomyMgr.metal.income);
    }
    float CommanderPower()
    {
        const CCircuitDef@ c = Builder::commander !is null ? Builder::commander.circuitDef : null;
        return c !is null ? c.GetBuildSpeed() : 300.0f;
    }
    float CommanderSpeed()
    {
        const CCircuitDef@ c = Builder::commander !is null ? Builder::commander.circuitDef : null;
        return c !is null && c.GetSpeed() > 0.0f ? c.GetSpeed() : 37.5f;
    }

    // The commander's opener: the home spots (rule 1), walked from the start.
    float OpenerSeconds(const string &in side)
    {
        CCircuitDef@ mex = ai.GetCircuitDef(MexName(side));
        const float radius = HomeRadius();
        const float income = Income();
        float seconds = 0.0f;
        const int count = ai.GetMetalSpotCount();
        for (int i = 0; i < count; ++i) {
            const AIFloat3 p = ai.GetMetalSpot(i);
            if (p.x < 0.0f || MapHelpers::SqDist(p, Global::Map::StartPos) > radius * radius) continue;
            seconds += StepSeconds(mex, CommanderPower(), income) + sqrt(MapHelpers::SqDist(p, Global::Map::StartPos)) / CommanderSpeed();
        }
        return seconds;
    }

    // The factory a role's own class comes from, and its observed handle.
    string FactoryName(AiRole role, const string &in side)
    {
        if (role == AiRole::SEA) return UnitHelpers::GetT1ShipyardForSide(side);
        if (role == AiRole::TACTICAL) return UnitHelpers::GetT1HoverPlantForSide(side);
        if (role == AiRole::AIR) return UnitHelpers::GetT1AirPlantForSide(side);
        return "";
    }
    CCircuitUnit@ FactoryUnit(AiRole role)
    {
        if (role == AiRole::SEA) return Factory::primaryT1Shipyard;
        if (role == AiRole::TACTICAL) return Factory::primaryT1HoverPlant;
        if (role == AiRole::AIR) return Factory::primaryT1AirPlant;
        return null;
    }
    CCircuitUnit@ ConstructorUnit(AiRole role)
    {
        if (role == AiRole::SEA) return Builder::primaryT1SeaConstructor;
        if (role == AiRole::TACTICAL) return Builder::primaryT1HoverConstructor;
        if (role == AiRole::AIR) return Builder::primaryT1AirConstructor;
        return null;
    }
    string ClassDef(AiRole role, const string &in side)
    {
        if (role == AiRole::SEA) return ConShip(side);
        if (role == AiRole::TACTICAL) return UnitHelpers::GetT1HoverConstructor(side);
        if (role == AiRole::AIR) return UnitHelpers::GetT1AirConstructorNameForSide(side);
        return GroundDef(side);
    }
    string CombatDef(AiRole role, const string &in side)
    {
        if (role == AiRole::SEA) return PatrolBoat(side);
        if (role == AiRole::TACTICAL) return HoverRaider(side);
        return "";
    }

    // Where the own class leaves from: SEA's planned berth, then its yard;
    // a hover or air plant once it stands; the start before that.
    AIFloat3 Anchor(AiRole role, const string &in side)
    {
        CCircuitUnit@ factory = FactoryUnit(role);
        if (factory !is null) return factory.GetPos(ai.frame);
        return Global::Map::StartPos;
    }

    // Securing structures timed with the constructor's build power.
    int SecureSeconds(AiRole role, const string &in side, CCircuitDef@ ctor)
    {
        int llt = 0, aa = 0;
        if (role == AiRole::AIR) { llt = Global::RoleSettings::MexClaim::AirSecureLLT; aa = Global::RoleSettings::MexClaim::AirSecureAA; }
        else if (role == AiRole::TACTICAL) { llt = Global::RoleSettings::MexClaim::TacticalSecureLLT; aa = Global::RoleSettings::MexClaim::TacticalSecureAA; }
        else if (role == AiRole::SEA) { llt = Global::RoleSettings::MexClaim::SeaSecureLLT; aa = Global::RoleSettings::MexClaim::SeaSecureAA; }
        if (ctor is null || (llt == 0 && aa == 0)) return 0;
        const float income = Income();
        float seconds = 0.0f;
        if (llt > 0) seconds += float(llt) * StepSeconds(ai.GetCircuitDef(UnitHelpers::GetStaticLLTNameForSide(side)), ctor.GetBuildSpeed(), income);
        if (aa > 0) seconds += float(aa) * StepSeconds(ai.GetCircuitDef(UnitHelpers::GetStaticAALightNameForSide(side)), ctor.GetBuildSpeed(), income);
        return int(seconds);
    }

    // Seconds from game start until the first constructor of the role's own
    // class exists, with no observation: the enemy table uses this for a seat
    // of each class at the enemy sources (the owner's symmetric clock).
    float EstimateSeconds(AiRole role, const string &in side, const AIFloat3 &in anchor)
    {
        const string factoryName = FactoryName(role, side);
        if (factoryName.length() == 0) return 0.0f;
        CCircuitDef@ factory = ai.GetCircuitDef(factoryName);
        CCircuitDef@ ctor = ai.GetCircuitDef(ClassDef(role, side));
        const float income = Income();
        float seconds = OpenerSeconds(side);
        seconds += sqrt(MapHelpers::SqDist(Global::Map::StartPos, anchor)) / CommanderSpeed();
        seconds += StepSeconds(factory, CommanderPower(), income);
        seconds += StepSeconds(ctor, factory !is null ? factory.GetBuildSpeed() : 150.0f, income);
        return seconds;
    }

    // The readiness frame, observed where the opening has happened.
    int ReadyFrame(AiRole role, const string &in side, const AIFloat3 &in anchor)
    {
        if (FactoryName(role, side).length() == 0) return 0;
        CCircuitUnit@ ctor = ConstructorUnit(role);
        if (ctor !is null && ctor.GetBuildProgress() >= 1.0f) return AiMax(0, ai.frame);
        CCircuitDef@ factoryDef = ai.GetCircuitDef(FactoryName(role, side));
        CCircuitDef@ ctorDef = ai.GetCircuitDef(ClassDef(role, side));
        const float income = Income();
        CCircuitUnit@ factory = FactoryUnit(role);
        if (factory !is null) {
            const float remaining = (1.0f - AiMin(1.0f, factory.GetBuildProgress())) * StepSeconds(factoryDef, CommanderPower(), income);
            const float ctorSeconds = ctor !is null ? (1.0f - AiMin(1.0f, ctor.GetBuildProgress())) * StepSeconds(ctorDef, factoryDef !is null ? factoryDef.GetBuildSpeed() : 150.0f, income)
                : StepSeconds(ctorDef, factoryDef !is null ? factoryDef.GetBuildSpeed() : 150.0f, income);
            return ai.frame + int((remaining + ctorSeconds) * SECOND);
        }
        return int(EstimateSeconds(role, side, anchor) * SECOND);
    }

    int CombatReadyFrame(AiRole role, const string &in side, int readyFrame)
    {
        const string combat = CombatDef(role, side);
        if (combat.length() == 0) return 0;
        CCircuitDef@ factoryDef = ai.GetCircuitDef(FactoryName(role, side));
        CCircuitDef@ ctorDef = ai.GetCircuitDef(ClassDef(role, side));
        CCircuitDef@ combatDef = ai.GetCircuitDef(combat);
        const float income = Income();
        const float power = factoryDef !is null ? factoryDef.GetBuildSpeed() : 150.0f;
        // The combat unit follows the constructor out of the same factory.
        const float after = StepSeconds(combatDef, power, income) - StepSeconds(ctorDef, power, income);
        return AiMax(0, readyFrame + int(after * SECOND));
    }

    MexClaimData Compute()
    {
        MexClaimData c;
        if (!Global::Map::MapResolved || !Global::Map::HasStart) return c;
        const AiRole role = Global::AISettings::Role;
        const string side = Global::AISettings::Side;
        c.groundDef = GroundDef(side);
        c.classDef = ClassDef(role, side);
        c.combatDef = CombatDef(role, side);
        c.anchor = Anchor(role, side);
        c.readyFrame = ReadyFrame(role, side, c.anchor);
        c.combatReadyFrame = CombatReadyFrame(role, side, c.readyFrame);
        c.secureSeconds = SecureSeconds(role, side, ai.GetCircuitDef(c.classDef));
        c.laneSpots = LaneSpots(role);
        c.valid = true;
        return c;
    }

    bool Changed(const MexClaimData &in a, const MexClaimData &in b)
    {
        if (a.valid != b.valid || a.groundDef != b.groundDef || a.classDef != b.classDef || a.combatDef != b.combatDef
            || a.laneSpots != b.laneSpots) return true;
        if (abs(float(a.readyFrame - b.readyFrame)) > float(Global::RoleSettings::MexClaim::ReannounceSeconds * SECOND)) return true;
        if (abs(float(a.combatReadyFrame - b.combatReadyFrame)) > float(Global::RoleSettings::MexClaim::ReannounceSeconds * SECOND)) return true;
        if (abs(float(a.secureSeconds - b.secureSeconds)) > float(Global::RoleSettings::MexClaim::ReannounceSeconds)) return true;
        const float move = float(Global::RoleSettings::MexClaim::ReannounceAnchor);
        if (MapHelpers::SqDist(a.anchor, b.anchor) > move * move) return true;
        return false;
    }

    // Roster line fields (after commanderId): ground|class|ready|ax|az|secure|combat|combatReady|lane
    string Encode()
    {
        const MexClaimData c = current;
        if (!c.valid) sentInvalid = true;
        return c.groundDef + "|" + c.classDef + "|" + c.readyFrame + "|" + int(c.anchor.x) + "|" + int(c.anchor.z)
            + "|" + c.secureSeconds + "|" + c.combatDef + "|" + c.combatReadyFrame + "|" + (c.laneSpots ? 1 : 0);
    }

    // Apply a (possibly allied) claim natively with the broadcast numbers only.
    void Apply(int team, const AIFloat3 &in start, const MexClaimData &in c)
    {
        if (!Enabled() || !c.valid) return;
        aiEconomyMgr.SetMexAllyClaim(team, start, c.anchor, c.groundDef, c.classDef, c.readyFrame, float(c.secureSeconds),
            c.combatDef, c.combatReadyFrame, c.laneSpots);
    }

    // The enemy is credited with every class at the readiness our own side
    // announces for it (owner's decision 2026-10-20: symmetric clock): the
    // earliest allied claim of that class, which every ally holds, so the table
    // is identical on every ally; a class nobody on our side fields gets a
    // position-free estimate at the fixed opening income, also identical.
    float EnemyReadySeconds(AiRole role, const string &in classDef, const string &in combatDef)
    {
        float best = -1.0f;
        array<Team::Roster::Entry@>@ all = Team::Roster::All();
        for (uint i = 0; i < all.length(); ++i) {
            const MexClaimData c = all[i].claim;
            if (!c.valid) continue;
            if (classDef.length() > 0 && c.classDef == classDef && (best < 0.0f || float(c.readyFrame) / SECOND < best)) best = float(c.readyFrame) / SECOND;
            if (combatDef.length() > 0 && c.combatDef == combatDef && (best < 0.0f || float(c.combatReadyFrame) / SECOND < best)) best = float(c.combatReadyFrame) / SECOND;
        }
        if (classDef.length() > 0 && current.valid && current.classDef == classDef && (best < 0.0f || float(current.readyFrame) / SECOND < best)) best = float(current.readyFrame) / SECOND;
        if (combatDef.length() > 0 && current.valid && current.combatDef == combatDef && (best < 0.0f || float(current.combatReadyFrame) / SECOND < best)) best = float(current.combatReadyFrame) / SECOND;
        if (best >= 0.0f) return best;
        // Nobody on our side fields it: factory plus constructor at the fixed income, no opener, no walk.
        const string side = Global::AISettings::Side;
        const float income = Global::RoleSettings::MexClaim::ExpectedOpeningIncome;
        CCircuitDef@ factory = ai.GetCircuitDef(FactoryName(role, side));
        CCircuitDef@ unit = ai.GetCircuitDef(combatDef.length() > 0 ? combatDef : classDef);
        return StepSeconds(factory, 300.0f, income) + StepSeconds(unit, factory !is null ? factory.GetBuildSpeed() : 150.0f, income);
    }
    void AnnounceEnemy()
    {
        if (!Enabled()) return;
        const string side = Global::AISettings::Side;
        CCircuitDef@ lab = ai.GetCircuitDef(UnitHelpers::GetT1BotLabForSide(side));
        CCircuitDef@ bot = ai.GetCircuitDef(GroundDef(side));
        const float income = Global::RoleSettings::MexClaim::ExpectedOpeningIncome;
        aiEconomyMgr.SetMexEnemyClass(GroundDef(side), StepSeconds(lab, 300.0f, income) + StepSeconds(bot, lab !is null ? lab.GetBuildSpeed() : 150.0f, income));
        aiEconomyMgr.SetMexEnemyClass(ConShip(side), EnemyReadySeconds(AiRole::SEA, ConShip(side), ""));
        aiEconomyMgr.SetMexEnemyClass(UnitHelpers::GetT1HoverConstructor(side), EnemyReadySeconds(AiRole::TACTICAL, UnitHelpers::GetT1HoverConstructor(side), ""));
        aiEconomyMgr.SetMexEnemyClass(UnitHelpers::GetT1AirConstructorNameForSide(side), EnemyReadySeconds(AiRole::AIR, UnitHelpers::GetT1AirConstructorNameForSide(side), ""));
        aiEconomyMgr.SetMexEnemyClass(HoverRaider(side), EnemyReadySeconds(AiRole::TACTICAL, "", HoverRaider(side)));
        aiEconomyMgr.SetMexEnemyClass(PatrolBoat(side), EnemyReadySeconds(AiRole::SEA, "", PatrolBoat(side)));
    }

    void Setup()
    {
        if (!Enabled()) return;
        aiEconomyMgr.SetMexTheatres(true, Global::RoleSettings::MexClaim::TheatreSeconds, HomeRadius());
        // D-358: the lane partition is the field's corridor table; only the band
        // radius is still read (merge radius and share are retired, see KI-668).
        aiEconomyMgr.SetMexLaneSettings(Global::RoleSettings::MexClaim::LaneMergeRadius,
            Global::RoleSettings::MexClaim::LaneMergeShare, Global::RoleSettings::MexClaim::LaneBandRadius);
    }

    // Roster::Update, every 30 frames: recompute, re-announce on a change,
    // apply our own claim, dump at the roster's completion and the window's
    // end, refresh the widget overlay. Returns true when the roster must rebroadcast.
    bool Tick()
    {
        if (!Enabled() || !Global::Map::MapResolved || !Global::Map::HasStart) return false;
        if (!enemyAnnounced) { enemyAnnounced = true; Setup(); AnnounceEnemy(); }  // Setup again: the role is known now (SEA home radius)
        const MexClaimData next = Compute();
        bool rebroadcast = false;
        if (!announcedOnce || Changed(current, next)) {
            current = next;
            Apply(ai.teamId, Global::Map::StartPos, current);
            // The first line goes out with the roster's own announcement, unless a
            // reply already carried an empty claim: then the allies need this one.
            rebroadcast = announcedOnce || sentInvalid;
            sentInvalid = false;
            announcedOnce = true;
            // The enemy clock stays symmetric with ours as the income estimate moves.
            AnnounceEnemy();
            GenericHelpers::LogUtil("[Team][MexClaim] " + Encode(), 1);
        }
        if (!rosterDumped && Team::Roster::Count() > 0 && Team::Roster::IsComplete()) {
            bool allClaims = true;
            array<Team::Roster::Entry@>@ all = Team::Roster::All();
            for (uint i = 0; i < all.length(); ++i) if (!all[i].claim.valid) allClaims = false;
            if (allClaims || ai.frame >= 3 * MINUTE) {
                rosterDumped = true;
                aiEconomyMgr.DumpMexTerritory(allClaims ? "roster" : "roster-partial");
            }
        }
        const int windowFrame = int(Global::RoleSettings::MexOwnershipSeconds * SECOND);
        if (!windowDumped && windowFrame > 0 && ai.frame >= windowFrame) {
            windowDumped = true;
            aiEconomyMgr.DumpMexTerritory("window");
        }
        if (widgetFrame < 0 || ai.frame - widgetFrame >= Global::RoleSettings::MexClaim::WidgetSeconds * SECOND) {
            widgetFrame = ai.frame;
            const string text = aiEconomyMgr.DescribeMexTerritory();
            if (text != widgetLast) {
                widgetLast = text;
                WidgetLink::SetState("territory", WidgetLink::Line("territory", text));
            }
        }
        return rebroadcast;
    }
}  // namespace MexClaim
}  // namespace Team
