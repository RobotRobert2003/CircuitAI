// TECH's hand-outs to its allies: T2 combat bots by plan, T2 constructors on request.
#include "../../define.as"
#include "../../global.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/units/unitdef_helpers.as"
#include "../../helpers/spatial/map_helpers.as"
#include "../../types/ai_role.as"
#include "roster.as"
#include "../presentation/widget_link.as"
#include "ferry.as"
#include "../../manager/economy.as"

/******************************************************************************

DONATION

Two separate hand-outs, both from the TECH role (D-041).

1. T2 COMBAT BOTS, BY PLAN. A TECH instance batches the fast T2 bot from its
   advanced lab (Sprinter / Fiend / Hoplite, or the amphibious bot on a
   landlocked start) long before its allies have a T2 lab. It gives N of
   those away, one per build, each to the closest allied BARb that has had
   the fewest so far (closest by start position from the team roster; allies
   without a roster entry come last, with no roster at all the lead team).

   N is drawn once, when the first such bot appears, from a decreasing
   distribution over T2BotDonationMin..T2BotDonationMax:

       weight(k) = Decay^(k-Min)      k = Min .. Max
       P(k)      = weight(k) / sum

   so the minimum is the most likely outcome and the maximum the least. The
   draw uses AiRandom, the AI's own generator. Constructors are NOT part of
   this: TECH keeps every T2 constructor it builds for itself unless asked.

2. T2 CONSTRUCTORS, ON REQUEST. Any teammate may ask (`barbdon|conreq`).
   TECH always answers: the request goes on a queue, the advanced bot lab
   builds one extra constructor ahead of everything else, and the next T2
   constructor to finish goes to the oldest requester - flown by the ferry
   transport when TECH owns one (manager/ferry.as), walked with ai.GiveUnits
   when it does not. The requester side asks on its own from Update():
   a non-TECH BARb with no T2 constructor and no T2 lab of its own, whose
   sliding-minimum metal income clears Global::ConstructorRequest::
   RequestMinMetalIncome, asks once (MaxRequests), with a cooldown for the
   case where no TECH is on the team yet. SUPPORT ("front tech") techs on
   its own and never asks automatically (AutoRequestFromSupport). Roles may
   also call RequestConstructor(why) directly, and TECH always serves that.

Transfers use ai.GiveUnits, which detaches the unit from every task on the
donor before the engine moves it; the recipient adopts it through its normal
unit-given path.

******************************************************************************/
namespace Team {
namespace Donation {

    const string MSG = "barbdon";

    // ---- T2 combat bots (TECH side)
    int botsBuilt = 0;         // donated-class bots this instance has produced
    int botPlanned = -1;       // donations still to make; -1 = not drawn yet
    int botGiven = 0;
    // team id string -> count, read and written as int64 (see D-019) and
    // ALWAYS read through Count() below. Two rules of the dictionary add-on
    // bit this table, one after the other:
    //   1. set(string, int) stores INT64 and get(string, int&out) cannot read
    //      it back - every count read as 0, closest ally got everything.
    //   2. get(key, int64&out c) on a key that does not exist returns false
    //      and leaves c UNDEFINED: an &out argument is an uninitialised
    //      temporary copied back regardless of the return value, so the
    //      "= 0" initialiser is overwritten with junk.
    // Never trust an &out after a failed get: check exists() first.
    dictionary givenTo;

    // ---- T2 constructors on request (TECH side)
    array<int> pendingRequests;   // requester team ids, oldest first
    int ordered = 0;              // extra constructors ordered and not yet built
    int orderedFrame = -1;        // when the last order was placed
    int constructorsGiven = 0;

    // ---- requester side
    int requestsSent = 0;
    int lastRequestFrame = -1;

    bool IsEnabled() { return Global::ConstructorRequest::Enabled; }

    int64 Count(int teamId)
    {
        const string key = "" + teamId;
        if (!givenTo.exists(key)) return 0;
        int64 c = 0;
        givenTo.get(key, c);
        return c;
    }

    void Bump(int teamId)
    {
        givenTo.set("" + teamId, Count(teamId) + 1);
    }

    // The bots the plan gives away: what TECH's advanced bot lab batches.
    bool IsDonatedBotDef(const CCircuitDef@ d)
    {
        if (d is null) return false;
        const string n = d.GetName();
        if (UnitHelpers::GetAllFastT2Bots().find(n) >= 0) return true;
        return UnitHelpers::GetAllAmphibiousT2Bots().find(n) >= 0;
    }

    // How many to donate: one draw from the decreasing distribution over minCount..maxCount.
    int DrawCount(int minCount, int maxCount)
    {
        if (minCount < 0) minCount = 0;
        if (maxCount < minCount) maxCount = minCount;
        const int span = maxCount - minCount + 1;
        const float decay = Global::RoleSettings::Tech::T2BotDonationDecay;
        array<float> weights(span);
        float sum = 0.0f;
        float w = 1.0f;
        for (int k = 0; k < span; ++k) {
            weights[k] = w;
            sum += w;
            w *= decay;
        }
        int roll = AiRandom(0, 999);
        if (roll < 0) roll = 0;
        if (roll > 999) roll = 999;
        const float target = (float(roll) + 0.5f) / 1000.0f * sum;
        float acc = 0.0f;
        for (int k = 0; k < span; ++k) {
            acc += weights[k];
            if (target < acc) return minCount + k;
        }
        return maxCount;
    }

    // Allies ordered by distance of their announced start from ours; unknown ones last.
    array<int> AlliesByDistance()
    {
        array<int> ordered;
        array<float> dist;
        array<int> allies = Team::Roster::AllyTeamIds();
        for (uint i = 0; i < allies.length(); ++i) {
            Team::Roster::Entry@ e = Team::Roster::Get(allies[i]);
            const float d = (e is null) ? 1e30f : MapHelpers::SqDist(Global::Map::StartPos, e.startPos);
            uint pos = 0;
            while (pos < dist.length() && dist[pos] <= d) ++pos;
            ordered.insertAt(pos, allies[i]);
            dist.insertAt(pos, d);
        }
        return ordered;
    }

    // Closest ally that has received the fewest bots so far.
    int PickRecipient()
    {
        array<int> ordered = AlliesByDistance();
        if (ordered.length() == 0) {
            const int leader = ai.GetLeadTeamId();
            return (leader == ai.teamId) ? -1 : leader;
        }
        int best = -1;
        int64 bestCount = 1000000;
        for (uint i = 0; i < ordered.length(); ++i) {
            const int64 c = Count(ordered[i]);
            if (c < bestCount) { bestCount = c; best = ordered[i]; }   // ties keep the closer one
        }
        GenericHelpers::LogUtil("[Team][Donation] PickRecipient -> team " + best + " (count " + bestCount
            + " of " + ordered.length() + " allies)", 1);
        return best;
    }

    // Hand a unit to a teammate: flown by the ferry when one is owned and
    // free (constructors only - that is what the ferry is for), walked with
    // GiveUnits otherwise. True when it changed hands or is in the air.
    bool _Deliver(CCircuitUnit@ unit, int recipient, const string &in what, bool tryFerry)
    {
        if (unit is null || recipient < 0 || recipient == ai.teamId) return false;
        const string name = unit.circuitDef.GetName();
        const int unitId = unit.id;
        if (tryFerry) {
            // Team::Ferry hands the unit over itself once the drop lands. A
            // refusal - no transport yet, one already in the air, the
            // transport dead - falls through to the walk.
            Team::Roster::Entry@ e = Team::Roster::Get(recipient);
            if (e !is null && Team::Ferry::TryCarry(unit, recipient, e.startPos)) {
                GenericHelpers::LogUtil("[Team][Donation] " + what + " " + name + "(" + unitId
                    + ") being ferried to team " + recipient, 1);
                return true;
            }
        }
        array<CCircuitUnit@> give(1);
        @give[0] = unit;   // valid handle this frame
        ai.GiveUnits(give, recipient);
        GenericHelpers::LogUtil("[Team][Donation] Gave " + what + " " + name + " (id=" + unitId
            + ") to team " + recipient, 1);
        WidgetLink::Send("donation", name + "|" + recipient);
        return true;
    }

    /**************************************************************************
     T2 combat bots. Military::AiUnitAdded of the TECH role.
     **************************************************************************/
    void OnCombatBotBuilt(CCircuitUnit@ unit)
    {
        if (Global::AISettings::Role != AiRole::TECH) return;
        if (unit is null || unit.circuitDef is null || !IsDonatedBotDef(unit.circuitDef)) return;
        ++botsBuilt;
        if (botPlanned < 0) {
            botPlanned = DrawCount(Global::RoleSettings::Tech::T2BotDonationMin,
                                   Global::RoleSettings::Tech::T2BotDonationMax);
            GenericHelpers::LogUtil("[Team][Donation] Plan: donate " + botPlanned + " T2 bots (min "
                + Global::RoleSettings::Tech::T2BotDonationMin + ", max "
                + Global::RoleSettings::Tech::T2BotDonationMax + ")", 1);
        }
        if (botGiven >= botPlanned) return;   // plan met; the rest are ours, quietly

        const int recipient = PickRecipient();
        if (recipient == ai.teamId) {
            GenericHelpers::LogUtil("[Team][Donation] BUG: recipient resolved to our own team; keeping the bot", 1);
            return;
        }
        if (recipient < 0) {
            GenericHelpers::LogUtil("[Team][Donation] No recipient (no allies or we lead alone); keeping "
                + unit.circuitDef.GetName(), 1);
            return;
        }
        if (_Deliver(unit, recipient, "T2 bot #" + botsBuilt, false)) {
            ++botGiven;
            Bump(recipient);
            GenericHelpers::LogUtil("[Team][Donation] T2 bots given " + botGiven + "/" + botPlanned, 1);
        }
    }

    /**************************************************************************
     T2 constructors on request. TECH side.
     **************************************************************************/
    bool _IsPending(int teamId)
    {
        return pendingRequests.find(teamId) >= 0;
    }

    // T2 constructors on this team now (a parked delivery still counts until
    // it is handed over, so at most one extra is ever kept).
    int _OwnT2Constructors()
    {
        return UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotConstructors());
    }

    // Builder::AiUnitAdded of the TECH role: every finished builder passes here.
    void OnConstructorBuilt(CCircuitUnit@ unit)
    {
        if (Global::AISettings::Role != AiRole::TECH) return;
        if (unit is null || unit.circuitDef is null) return;
        if (!Team::IsT2Constructor(unit.circuitDef)) return;
        // D-108: a T2 air constructor that fills (or holds) a dedicated role is TECH's
        if (TechBuild::ClaimOnBuilt(unit) || TechBuild::IsDedicatedAirCon(unit)) {
            GenericHelpers::LogUtil("[Team][Donation] " + unit.circuitDef.GetName() + "(" + unit.id + ") is TECH's dedicated air constructor: kept (D-108)", 1);
            return;
        }
        // Fulfil the request with the roster ordered by FactoryMakeTask.
        // A harbour sub cannot upgrade a teammate's land mexes or be parked
        // behind our land base; it must not consume a pending bot order.
        if (UnitHelpers::GetAllT2BotConstructors().find(unit.circuitDef.GetName())<0) return;
        if (ordered > 0) --ordered;
        if (_OwnT2Constructors() <= Global::RoleSettings::Tech::DonationKeepT2Constructors) {
            GenericHelpers::LogUtil("[Team][Donation] T2 constructor " + unit.circuitDef.GetName() + "("
                + unit.id + ") is ours: TECH keeps its first " + Global::RoleSettings::Tech::DonationKeepT2Constructors, 1);
            return;
        }
        if (pendingRequests.length() == 0) {
            GenericHelpers::LogUtil("[Team][Donation] T2 constructor " + unit.circuitDef.GetName() + "("
                + unit.id + ") is ours: no request pending", 1);
            return;
        }
        const int recipient = pendingRequests[0];
        pendingRequests.removeAt(0);
        if (_Deliver(unit, recipient, "requested constructor", true)) {
            ++constructorsGiven;
            AiSendMessage(MSG + "|sent|" + unit.id, recipient);
        }
    }

    // Factory::AiMakeTask asks here before the role handler, as it asks the
    // ferry. Returns a constructor order for TECH's advanced bot lab while
    // requests outnumber what is already ordered; null otherwise.
    IUnitTask@ FactoryMakeTask(CCircuitUnit@ factory)
    {
        if (!IsEnabled() || Global::AISettings::Role != AiRole::TECH) return null;
        if (factory is null || factory.circuitDef is null) return null;
        // An order that produced nothing within the timeout (lab died, def
        // capped) is forgotten so the next lab poll re-orders. Checked before
        // the count gate: with one request and one dead order the gate used to
        // return first and the time-out was never reached (CR-014).
        if (ordered > 0 && orderedFrame >= 0
            && (ai.frame - orderedFrame) > Global::ConstructorRequest::OrderTimeoutSeconds * SECOND) {
            GenericHelpers::LogUtil("[Team][Donation] constructor order timed out; re-ordering", 1);
            ordered = 0;
        }
        if (int(pendingRequests.length()) <= ordered) {
            return null;
        }
        // TECH's own first: no order for an ally while TECH has fewer T2
        // constructors than it keeps (Tech::DonationKeepT2Constructors).
        if (_OwnT2Constructors() < Global::RoleSettings::Tech::DonationKeepT2Constructors) {
            return null;
        }
        if (!UnitHelpers::IsT2BotLab(factory.circuitDef.GetName())) return null;
        array<string> ctors = UnitHelpers::GetT2BotConstructors(Global::AISettings::Side);
        if (ctors.length() == 0) return null;
        CCircuitDef@ d = ai.GetCircuitDef(ctors[0]);
        if (d is null || !d.IsAvailable(ai.frame)) return null;
        IUnitTask@ order = aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH,
                d, factory.GetPos(ai.frame), 64.f));
        if (order is null) return null;   // nothing ordered, nothing counted (CR-014)
        ++ordered;
        orderedFrame = ai.frame;
        GenericHelpers::LogUtil("[Team][Donation] TECH: ordered " + ctors[0] + " for team "
            + pendingRequests[0] + " (pending " + pendingRequests.length() + ", ordered " + ordered + ")", 1);
        return order;
    }

    /**************************************************************************
     Requester side.
     **************************************************************************/
    bool _HasTechAlly()
    {
        array<Team::Roster::Entry@>@ all = Team::Roster::All();
        if (all is null) return false;
        for (uint i = 0; i < all.length(); ++i) {
            Team::Roster::Entry@ e = all[i];
            if (e !is null && e.teamId != ai.teamId && e.role == AiRole::TECH) return true;
        }
        return false;
    }

    // Ask the team's TECH for a T2 constructor. Any role may call this.
    bool RequestConstructor(const string &in why)
    {
        if (!IsEnabled()) return false;
        if (Global::AISettings::Role == AiRole::TECH) return false;
        if (lastRequestFrame >= 0
            && (ai.frame - lastRequestFrame) < Global::ConstructorRequest::RequestCooldownSeconds * SECOND) {
            return false;
        }
        lastRequestFrame = ai.frame;
        ++requestsSent;
        AiSendMessage(MSG + "|conreq");
        GenericHelpers::LogUtil("[Team][Donation] requested a T2 constructor from TECH (" + why + ")", 1);
        WidgetLink::Send("donation", "conreq|" + requestsSent);
        return true;
    }

    // Main::AiUpdate, every 30 frames: the automatic request.
    // Roles that tech on their own never ask automatically. A SUPPORT
    // ("front tech") player builds its own T2; an unrequested constructor
    // there is a gift it did not need. An explicit RequestConstructor() from
    // any role is still always served (D-046).
    bool _AutoRequestsForRole()
    {
        const AiRole role = Global::AISettings::Role;
        if (role == AiRole::TECH) return false;
        if (role == AiRole::SUPPORT && !Global::ConstructorRequest::AutoRequestFromSupport) return false;
        return true;
    }

    void Update()
    {
        if (!IsEnabled() || !_AutoRequestsForRole()) return;
        if (requestsSent >= Global::ConstructorRequest::MaxRequests) return;
        if (Economy::GetMinMetalIncomeLast10s() < Global::ConstructorRequest::RequestMinMetalIncome) return;
        if (UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotConstructors()) > 0) return;
        if (UnitDefHelpers::SumUnitDefCounts(UnitHelpers::GetAllT2BotLabs()) > 0) return;
        if (!_HasTechAlly()) return;
        RequestConstructor("+" + int(Global::ConstructorRequest::RequestMinMetalIncome)
            + " metal, no T2 constructor, no T2 lab");
    }

    // Team::HandleMessage. Both sides.
    bool HandleMessage(const string &in msg, int fromTeamId)
    {
        array<string>@ p = msg.split("|");
        if (p.length() < 2 || p[0] != MSG) return false;
        if (p[1] == "conreq") {
            if (Global::AISettings::Role != AiRole::TECH) return true;
            if (!IsEnabled() || fromTeamId == ai.teamId) return true;
            if (_IsPending(fromTeamId)) {
                GenericHelpers::LogUtil("[Team][Donation] TECH: team " + fromTeamId + " already has a request pending", 1);
                return true;
            }
            pendingRequests.insertLast(fromTeamId);
            AiSendMessage(MSG + "|ack", fromTeamId);
            GenericHelpers::LogUtil("[Team][Donation] TECH: constructor request from team " + fromTeamId
                + " queued (pending " + pendingRequests.length() + ")", 1);
            return true;
        }
        if (p[1] == "ack") {
            GenericHelpers::LogUtil("[Team][Donation] team " + fromTeamId + " (TECH) is building our constructor", 1);
            return true;
        }
        if (p[1] == "sent") {
            GenericHelpers::LogUtil("[Team][Donation] team " + fromTeamId + " sent constructor "
                + (p.length() >= 3 ? p[2] : "?"), 1);
            return true;
        }
        return false;
    }
}  // namespace Donation
}  // namespace Team
