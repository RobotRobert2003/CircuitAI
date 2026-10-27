// Rez bot replenishment and sharing (owner, 2026-10-26). Settings: settings/shared/rez_replenish.as.
#include "../../define.as"
#include "../../global.as"
#include "../../settings/shared/rez_replenish.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/spatial/map_helpers.as"
#include "../construction/lifecycle.as"
#include "../team/roster.as"

/******************************************************************************

REZ BOT REPLENISHMENT

Before this, a bot-lab AI got its rez bots only from the factory.json roll
(armlab / corlab / leglab: 5 % of T1 bot lab builds, 15 % for Legion's upper
tiers) under FRONT's StartCapRezBots cap (10, armrectr and cornecro). The roll
is reached only when no opener, bot wave, spam lane or siege order claims the
lab first, so a FRONT typically held 0-3.

Here, every T1 bot lab of this AI asks FactoryMakeTask before its role's own
production. While the alive mobile army (finished mobile units without build
power: no constructors, rez bots or commander) is worth more than
ArmyMinMetal, the lab builds rez bots until finished + in production reaches
the target: Target, or with Scale the ScaleTargets entry of the highest
ScaleArmy step the army exceeds. The rez bot def's maxThisUnit is raised to
the target when it is lower.

SHARING. A BARb with a T1 bot lab announces itself ("barbrez|lab|1"). A BARb
with a vehicle plant and no T1 bot lab asks the nearest announced one
("barbrez|req|have|n|army") when it has fewer than RequestBelow rez bots and
an army above RequestMinArmy. The bot-lab AI adds n to what its labs keep in
stock and gives each finished rez bot above max(own target, ShareKeepMin) to
the oldest requester with ai.GiveUnits ("barbrez|sent|id|def").

Log lines (level 1), all "[RezRep] ...": stat (every LogSeconds), trigger,
order, give, request, request-from, received.

******************************************************************************/
namespace RezReplenish {

    const string MSG = "barbrez";

    array<string> rezNames;

    // scan results
    int scanFrame = -1;
    float army = 0.0f;
    int armyUnits = 0;
    int rezFinished = 0;
    int rezAll = 0;
    int botLabs = 0;
    int vehPlants = 0;
    array<int> rezIds;      // finished rez bots, ascending id

    // production
    array<int> orderFrames;
    int lastRezAll = 0;
    int ordersTotal = 0;
    int lastTarget = -1;

    // sharing, donor side
    array<int> giftQueue;          // requester team ids, oldest first
    dictionary giftPending;        // team -> int64 left to give
    dictionary giftExpiry;         // team -> int64 frame
    int giftsGiven = 0;
    int lastGiftFrame = -100000;
    int lastAnnounceFrame = -100000;
    bool announcedLab = false;

    // sharing, requester side
    dictionary donors;             // team -> int64 last announce frame
    int lastRequestFrame = -100000;
    int requestsSent = 0;
    int received = 0;

    int lastUpdateFrame = -100000;
    int lastLogFrame = -100000;

    int64 _Get(dictionary@ d, int team, int64 dflt) {
        const string key = "" + team;
        if (!d.exists(key)) return dflt;
        int64 v = 0;
        d.get(key, v);
        return v;
    }
    void _Set(dictionary@ d, int team, int64 v) { d.set("" + team, v); }

    void Scan()
    {
        if (scanFrame == ai.frame) return;
        scanFrame = ai.frame;
        if (rezNames.length() == 0) rezNames = UnitHelpers::GetAllRezBots();
        army = 0.0f; armyUnits = 0; rezFinished = 0; rezAll = 0; botLabs = 0; vehPlants = 0;
        rezIds.resize(0);
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null || u.circuitDef is null) continue;
            const CCircuitDef@ d = u.circuitDef;
            const string name = d.GetName();
            const bool done = u.GetBuildProgress() >= 1.0f;
            if (rezNames.find(name) >= 0) {
                ++rezAll;
                if (done) { ++rezFinished; rezIds.insertLast(int(u.id)); }
                continue;
            }
            if (!done) continue;
            if (d.IsMobile()) {
                if (d.GetBuildSpeed() > 0.0f) continue;   // constructors, assist bots, commander
                army += d.costM;
                ++armyUnits;
                continue;
            }
            if (UnitHelpers::IsT1BotLab(name)) {
                if (!Lifecycle::IsRetiring(u)) ++botLabs;
            } else if (UnitHelpers::IsT1VehicleLab(name) || UnitHelpers::IsT2VehicleLab(name)) {
                ++vehPlants;
            }
        }
        rezIds.sortAsc();
        // a lab picked up an order when the rez count rose
        if (rezAll > lastRezAll) {
            int started = rezAll - lastRezAll;
            while (started > 0 && orderFrames.length() > 0) { orderFrames.removeAt(0); --started; }
        }
        lastRezAll = rezAll;
        const int timeout = Global::RezReplenish::OrderTimeoutSeconds * SECOND;
        while (orderFrames.length() > 0 && ai.frame - orderFrames[0] > timeout) orderFrames.removeAt(0);
    }

    // The own target for the current army; 0 = no replenishment (below the threshold or off).
    int Target()
    {
        if (!Global::RezReplenish::Enabled || army <= Global::RezReplenish::ArmyMinMetal) return 0;
        if (!Global::RezReplenish::Scale) return Global::RezReplenish::Target;
        int t = 0;
        const int n = AiMin(int(Global::RezReplenish::ScaleArmy.length()), int(Global::RezReplenish::ScaleTargets.length()));
        for (int i = 0; i < n; ++i) {
            if (army > Global::RezReplenish::ScaleArmy[i]) t = Global::RezReplenish::ScaleTargets[i];
        }
        return t;
    }

    int GiftOutstanding()
    {
        int sum = 0;
        for (uint i = 0; i < giftQueue.length(); ) {
            const int team = giftQueue[i];
            const int64 left = _Get(giftPending, team, 0);
            if (left <= 0 || ai.frame > _Get(giftExpiry, team, 0)) {
                if (left > 0) GenericHelpers::LogUtil("[RezRep] request-expired team=" + team + " left=" + left, 1);
                giftPending.delete("" + team);
                giftExpiry.delete("" + team);
                giftQueue.removeAt(i);
                continue;
            }
            sum += int(left);
            ++i;
        }
        return sum;
    }

    int Keep() { return AiMax(Target(), Global::RezReplenish::ShareKeepMin); }

    // Rez bots (finished + in production) our labs keep.
    int Want()
    {
        const int gifts = (Global::RezReplenish::ShareEnabled && botLabs > 0) ? GiftOutstanding() : 0;
        if (gifts > 0) return Keep() + gifts;
        return Target();
    }

    // Factory::AiMakeTask, before the role's production.
    IUnitTask@ FactoryMakeTask(CCircuitUnit@ factory)
    {
        if (!Global::RezReplenish::Enabled && !Global::RezReplenish::ShareEnabled) return null;
        if (factory is null || factory.circuitDef is null) return null;
        const string fname = factory.circuitDef.GetName();
        if (!UnitHelpers::IsT1BotLab(fname) || Lifecycle::IsRetiring(factory)) return null;
        Scan();
        const int want = Want();
        if (want <= 0) return null;
        if (rezAll + int(orderFrames.length()) >= want) return null;
        if (int(orderFrames.length()) >= Global::RezReplenish::MaxOrdersInFlight) return null;
        array<string> defs = UnitHelpers::GetRezBots(UnitHelpers::GetSideForUnitName(fname));
        if (defs.length() == 0) return null;
        CCircuitDef@ d = ai.GetCircuitDef(defs[0]);
        if (d is null) return null;
        if (d.maxThisUnit < want) d.maxThisUnit = want;
        if (!d.IsAvailable(ai.frame)) return null;
        IUnitTask@ t = aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH,
            d, factory.GetPos(ai.frame), 64.f));
        if (t is null) return null;
        orderFrames.insertLast(ai.frame);
        ++ordersTotal;
        GenericHelpers::LogUtil("[RezRep] order def=" + defs[0] + " lab=" + factory.id + " rez=" + rezFinished
            + " rezAll=" + rezAll + " want=" + want + " target=" + Target() + " army=" + int(army)
            + " orders=" + ordersTotal, 1);
        return t;
    }

    // Main::AiUpdate (every 30 frames).
    void Update()
    {
        if (ai.frame - lastUpdateFrame < 2 * SECOND) return;
        lastUpdateFrame = ai.frame;
        Scan();
        const int target = Target();
        if (target != lastTarget) {
            if (lastTarget >= 0 || target > 0)
                GenericHelpers::LogUtil("[RezRep] trigger target=" + target + " was=" + lastTarget + " army=" + int(army)
                    + " rez=" + rezFinished + " rezAll=" + rezAll + " botLabs=" + botLabs, 1);
            lastTarget = target;
        }
        if (Global::RezReplenish::ShareEnabled) _Share();
        if (ai.frame - lastLogFrame >= Global::RezReplenish::LogSeconds * SECOND) {
            lastLogFrame = ai.frame;
            GenericHelpers::LogUtil("[RezRep] stat army=" + int(army) + " units=" + armyUnits + " rez=" + rezFinished
                + " rezAll=" + rezAll + " target=" + target + " want=" + Want() + " botLabs=" + botLabs
                + " vehPlants=" + vehPlants + " native=" + int(aiMilitaryMgr.armyCost) + " orders=" + ordersTotal
                + " given=" + giftsGiven + " received=" + received + " requests=" + requestsSent, 1);
        }
    }

    bool _IsDonor() { return botLabs > 0; }
    bool _IsRequester() { return botLabs == 0 && vehPlants > 0; }

    void _Share()
    {
        const bool donor = _IsDonor();
        if (donor && ai.frame - lastAnnounceFrame >= Global::RezReplenish::AnnounceSeconds * SECOND) {
            lastAnnounceFrame = ai.frame;
            announcedLab = true;
            AiSendMessage(MSG + "|lab|1|" + rezFinished);
        } else if (!donor && announcedLab) {
            announcedLab = false;
            AiSendMessage(MSG + "|lab|0");
        }
        if (donor) _Give();
        if (_IsRequester()) _Request();
    }

    void _Give()
    {
        if (GiftOutstanding() <= 0) return;
        if (ai.frame - lastGiftFrame < Global::RezReplenish::GiftSpacingSeconds * SECOND) return;
        if (rezFinished <= Keep() || rezIds.length() == 0) return;
        const int recipient = giftQueue[0];
        CCircuitUnit@ u = ai.GetTeamUnit(rezIds[rezIds.length() - 1]);   // the newest
        if (u is null || u.circuitDef is null) return;
        const int unitId = u.id;
        const string name = u.circuitDef.GetName();
        array<CCircuitUnit@> give(1);
        @give[0] = u;
        ai.GiveUnits(give, recipient);
        lastGiftFrame = ai.frame;
        ++giftsGiven;
        const int64 left = _Get(giftPending, recipient, 1) - 1;
        _Set(giftPending, recipient, left);
        rezIds.removeLast();
        --rezFinished; --rezAll; lastRezAll = rezAll;
        AiSendMessage(MSG + "|sent|" + unitId + "|" + name, recipient);
        GenericHelpers::LogUtil("[RezRep] give unit=" + unitId + " def=" + name + " to=" + recipient + " left=" + left
            + " rez=" + rezFinished + " keep=" + Keep() + " army=" + int(army) + " given=" + giftsGiven, 1);
        GiftOutstanding();   // drops a filled request
    }

    int _PickDonor()
    {
        array<string>@ keys = donors.getKeys();
        int best = -1;
        float bestD = 1e30f;
        for (uint i = 0; i < keys.length(); ++i) {
            const int team = int(parseInt(keys[i]));
            const int64 seen = _Get(donors, team, -1);
            if (seen < 0 || ai.frame - seen > 3 * Global::RezReplenish::AnnounceSeconds * SECOND) continue;
            Team::Roster::Entry@ e = Team::Roster::Get(team);
            const float dist = (e is null) ? 1e29f : MapHelpers::SqDist(Global::Map::StartPos, e.startPos);
            if (dist < bestD) { bestD = dist; best = team; }
        }
        return best;
    }

    void _Request()
    {
        if (rezAll >= Global::RezReplenish::RequestBelow) return;
        if (army <= Global::RezReplenish::RequestMinArmy) return;
        if (ai.frame - lastRequestFrame < Global::RezReplenish::RequestCooldownSeconds * SECOND) return;
        const int donor = _PickDonor();
        if (donor < 0) return;
        const int n = AiMax(1, Global::RezReplenish::RequestUpTo - rezAll);
        lastRequestFrame = ai.frame;
        ++requestsSent;
        AiSendMessage(MSG + "|req|" + rezAll + "|" + n + "|" + int(army), donor);
        GenericHelpers::LogUtil("[RezRep] request to=" + donor + " have=" + rezAll + " n=" + n + " army=" + int(army)
            + " requests=" + requestsSent, 1);
    }

    // Team::HandleMessage. Both sides.
    bool HandleMessage(const string &in msg, int fromTeamId)
    {
        if (msg.length() < MSG.length() + 1 || msg.substr(0, MSG.length() + 1) != MSG + "|") return false;
        array<string>@ p = msg.split("|");
        if (p.length() < 2) return true;
        if (p[1] == "lab") {
            if (p.length() >= 3 && p[2] == "1") _Set(donors, fromTeamId, ai.frame);
            else donors.delete("" + fromTeamId);
            return true;
        }
        if (p[1] == "req") {
            Scan();
            if (!Global::RezReplenish::ShareEnabled || !_IsDonor() || p.length() < 4) {
                AiSendMessage(MSG + "|lab|0", fromTeamId);
                return true;
            }
            const int64 n = AiMin(int(parseInt(p[3])), 4);
            const int64 had = _Get(giftPending, fromTeamId, 0);
            _Set(giftPending, fromTeamId, (n > had) ? n : had);
            _Set(giftExpiry, fromTeamId, ai.frame + Global::RezReplenish::RequestExpirySeconds * SECOND);
            if (giftQueue.find(fromTeamId) < 0) giftQueue.insertLast(fromTeamId);
            GenericHelpers::LogUtil("[RezRep] request-from team=" + fromTeamId + " have=" + p[2] + " n=" + n
                + " theirArmy=" + (p.length() >= 5 ? p[4] : "?") + " outstanding=" + GiftOutstanding()
                + " rez=" + rezFinished + " keep=" + Keep(), 1);
            return true;
        }
        if (p[1] == "sent") {
            ++received;
            GenericHelpers::LogUtil("[RezRep] received unit=" + (p.length() >= 3 ? p[2] : "?") + " def="
                + (p.length() >= 4 ? p[3] : "?") + " from=" + fromTeamId + " received=" + received, 1);
            return true;
        }
        return true;
    }
}
