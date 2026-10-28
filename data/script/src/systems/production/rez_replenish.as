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

SECOND LAB (SecondLab, owner 2026-10-28). Spam comes first: once Spam pumps
the first T1 bot lab of an AI that started on one (the lead), no pump is
released for rez bots and a builder adds one more T1 bot lab (BuilderTask),
the rez lab. It takes the rez bot orders; with the stock full it waits, and
from SpamFillIncomeRatio x the income the lead started spamming at it pumps
spam on the lead's lane (Spam::laneLead) until a rez bot is short or the
income falls under SpamFillReleaseFraction of that bar (_ReleaseSpamLab).
Donors are then the AIs that started on a bot lab, requesters the ones that
started on a vehicle plant.

Log lines (level 1), all "[RezRep] ...": stat (every LogSeconds), trigger,
order, give, request, request-from, received, lab2 (spam-start, lead, build,
designate, lost, fill, release).

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
    array<int> botLabIds;   // finished, not retiring T1 bot labs
    dictionary releasedAt;  // lab id -> int64 frame of the last spam release
    dictionary inARow;      // lab id -> int64 rez bot orders since its last own build (RezPerNormalBuild)
    int releases = 0;
    bool spamTookOver = false;   // StopRezWhenSpam: Spam has pumped one of our T1 bot labs
    bool cut = false;            // CutoffMetalIncome / CutoffMinutesAfterT2 reached
    int cutFrame = -1;
    int t2Frame = -1;            // our first finished T2 factory
    int incomeAboveSince = -1;   // first frame of the current run at or above CutoffMetalIncome
    dictionary capBeforeCut;     // rez def -> int64 maxThisUnit before the cutoff capped it (non-sticky undo)

    // SecondLab (owner, 2026-10-28)
    string firstFactory = "";    // our first finished factory (T1 bot lab, vehicle plant or air plant)
    float spamStartIncome = -1.0f;   // 10 s minimum metal income when Spam first pumped a bot lab of ours
    int leadLabId = -1;          // the bot lab pump whose lane the rez lab's spam runs
    int rezLabId = -1;           // the rez lab
    bool rezLabFilling = false;  // the rez lab is a Spam pump right now
    int lab2Builds = 0;
    int lastLab2Attempt = -100000;

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

    // A role that keeps its T1 bot lab (TECH and SUPPORT retire theirs at T2).
    bool RoleEligible()
    {
        if (Global::RezReplenish::IncludeTechSupport) return true;
        const AiRole r = Global::AISettings::Role;
        return r != AiRole::TECH && r != AiRole::SUPPORT;
    }

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
        botLabIds.resize(0);
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
            if (firstFactory.length() == 0 && (UnitHelpers::IsT1BotLab(name) || UnitHelpers::IsT1VehicleLab(name)
                || UnitHelpers::IsT1AircraftPlant(name))) {
                firstFactory = name;
                GenericHelpers::LogUtil("[RezRep] first-factory def=" + name + " min=" + (float(ai.frame) / MINUTE), 1);
            }
            if (UnitHelpers::IsT1BotLab(name)) {
                if (!Lifecycle::IsRetiring(u)) { ++botLabs; botLabIds.insertLast(int(u.id)); }
            } else if (UnitHelpers::IsT1VehicleLab(name) || UnitHelpers::IsT2VehicleLab(name)) {
                ++vehPlants;
            }
            if (t2Frame < 0 && (UnitHelpers::IsT2BotLab(name) || UnitHelpers::IsT2VehicleLab(name)
                || UnitHelpers::IsT2AircraftPlant(name) || UnitHelpers::IsT2Shipyard(name))) {
                t2Frame = ai.frame;
                GenericHelpers::LogUtil("[RezRep] t2-finished def=" + name + " min=" + (float(ai.frame) / MINUTE)
                    + " cutoffAt=" + (Global::RezReplenish::CutoffMinutesAfterT2 > 0.0f
                        ? "" + (float(ai.frame) / MINUTE + Global::RezReplenish::CutoffMinutesAfterT2) : "off"), 1);
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
        if (!Global::RezReplenish::Enabled || !RoleEligible() || cut || army <= Global::RezReplenish::ArmyMinMetal) return 0;
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
        if (cut) return 0;
        const int gifts = (Global::RezReplenish::ShareEnabled && _IsDonor()) ? GiftOutstanding() : 0;
        if (gifts > 0) return Keep() + gifts;
        return Target();
    }

    // Factory::AiMakeTask, before the role's production.
    IUnitTask@ FactoryMakeTask(CCircuitUnit@ factory)
    {
        if (!Global::RezReplenish::Enabled && !Global::RezReplenish::ShareEnabled) return null;
        if (factory is null || factory.circuitDef is null) return null;
        const string fname = factory.circuitDef.GetName();
        if (!UnitHelpers::IsT1BotLab(fname) || Lifecycle::IsRetiring(factory) || !RoleEligible()) return null;
        Scan();
        if (_SecondLabOn()) {
            _Designate(factory);   // a new lab asks before Update sees it
            // spam first: while Spam is on, only the rez lab makes rez bots (played 2026-10-28: the
            // lead's repeat ended between spam batches and it took rez orders instead)
            if (spamStartIncome >= 0.0f && Spam::IsActive() && factory.id != rezLabId) return null;
        }
        IUnitTask@ t = _Order(factory, fname);
        if (t !is null || !_SecondLabOn() || factory.id != rezLabId) return t;
        // the rez lab with its stock full (or orders in flight): spam on the lead's lane from the
        // fill-in income, else wait for the next shortage
        if (_FillOpen()) return null;   // Spam::FactoryMakeTask pumps it
        return aiFactoryMgr.Enqueue(TaskS::Wait(true, 5 * SECOND));
    }

    IUnitTask@ _Order(CCircuitUnit@ factory, const string &in fname)
    {
        const int want = Want();
        if (want <= 0 || spamTookOver) return null;
        if (rezAll + int(orderFrames.length()) >= want) return null;
        if (int(orderFrames.length()) >= Global::RezReplenish::MaxOrdersInFlight) return null;
        const int every = Global::RezReplenish::RezPerNormalBuild;
        if (every > 0 && rezAll >= Global::RezReplenish::InterleaveCriticalBelow
            && _Get(inARow, factory.id, 0) >= every) {
            _Set(inARow, factory.id, 0);
            return null;   // one build of the lab's own production
        }
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
        _Set(inARow, factory.id, _Get(inARow, factory.id, 0) + 1);
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
        _CheckCutoff();
        _CheckSpamTakeover();
        _SecondLabUpdate();
        _ReleaseSpamLab();
        if (ai.frame - lastLogFrame >= Global::RezReplenish::LogSeconds * SECOND) {
            lastLogFrame = ai.frame;
            GenericHelpers::LogUtil("[RezRep] stat army=" + int(army) + " units=" + armyUnits + " rez=" + rezFinished
                + " rezAll=" + rezAll + " target=" + target + " want=" + Want() + " botLabs=" + botLabs
                + " vehPlants=" + vehPlants + " native=" + int(aiMilitaryMgr.armyCost) + " orders=" + ordersTotal
                + " given=" + giftsGiven + " received=" + received + " requests=" + requestsSent
                + " spam=" + (spamTookOver ? 1 : 0) + " cut=" + (cut ? 1 : 0)
                + " income=" + int(Economy::GetMinMetalIncomeLast10s())
                + (_SecondLabOn() ? " lab2=" + rezLabId + " fill=" + (rezLabFilling ? 1 : 0) + " spamStart="
                    + int(spamStartIncome) + " lead=" + leadLabId + " lab2Builds=" + lab2Builds
                    + " lab2Rej=" + lab2Rej[0] + "/" + lab2Rej[1] + "/" + lab2Rej[2] + "/" + lab2Rej[3] + "/" + lab2Rej[4] : ""), 1);
        }
    }

    // Cutoffs (owner, 2026-10-27): from CutoffMetalIncome m/s (10 s minimum income) or
    // CutoffMinutesAfterT2 minutes after our first T2 factory finished, the AI is done with
    // rez bots: no orders, no Spam-lab take-back (its labs stay Spam pumps on their routes),
    // no gifts, no requests, rez bot defs capped at 0. Rez bots alive keep working.
    // CutoffSticky: stays cut once crossed; otherwise it undoes when the condition clears.
    void _CheckCutoff()
    {
        const float inc = Global::RezReplenish::CutoffMetalIncome;
        const float mins = Global::RezReplenish::CutoffMinutesAfterT2;
        if (inc <= 0.0f && mins <= 0.0f) return;
        const float income = Economy::GetMinMetalIncomeLast10s();
        if (inc > 0.0f && income >= inc) { if (incomeAboveSince < 0) incomeAboveSince = ai.frame; }
        else incomeAboveSince = -1;
        const bool byIncome = incomeAboveSince >= 0
            && ai.frame - incomeAboveSince >= int(Global::RezReplenish::CutoffIncomeSeconds * SECOND);
        const bool byT2 = mins > 0.0f && t2Frame >= 0 && ai.frame - t2Frame >= int(mins * MINUTE);
        const bool now = byIncome || byT2;
        if (now && !cut) {
            cut = true;
            cutFrame = ai.frame;
            orderFrames.resize(0);
            GenericHelpers::LogUtil("[RezRep] cutoff on reason=" + (byIncome ? "income" : "t2") + " min="
                + (float(ai.frame) / MINUTE) + " income=" + int(income) + " t2min="
                + (t2Frame < 0 ? "-" : "" + (float(t2Frame) / MINUTE)) + " rez=" + rezFinished + " army=" + int(army)
                + " botLabs=" + botLabs + " vehPlants=" + vehPlants, 1);
        } else if (!now && cut && !Global::RezReplenish::CutoffSticky) {
            cut = false;
            for (uint i = 0; i < rezNames.length(); ++i) {
                CCircuitDef@ d = ai.GetCircuitDef(rezNames[i]);
                if (d is null || !capBeforeCut.exists(rezNames[i])) continue;
                int64 c = 0;
                capBeforeCut.get(rezNames[i], c);
                d.maxThisUnit = int(c);
            }
            capBeforeCut.deleteAll();
            GenericHelpers::LogUtil("[RezRep] cutoff off min=" + (float(ai.frame) / MINUTE) + " income=" + int(income), 1);
        }
        if (!cut || !RoleEligible()) return;
        for (uint i = 0; i < rezNames.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(rezNames[i]);
            if (d is null || d.maxThisUnit == 0) continue;
            if (!capBeforeCut.exists(rezNames[i])) capBeforeCut.set(rezNames[i], int64(d.maxThisUnit));
            d.maxThisUnit = 0;
        }
    }

    // StopRezWhenSpam (owner, 2026-10-27): once Spam pumps any of our T1 bot labs this AI
    // builds no more rez bots, for good: no replenishment orders, no pump release, and the rez
    // bot defs are capped at 0 every update so neither factory.json's roll (when a lab is back
    // from the pump) nor a role cap can add one. Rez bots already alive keep working; a donor
    // still hands over spare ones it has.
    void _CheckSpamTakeover()
    {
        if (!Global::RezReplenish::StopRezWhenSpam || !RoleEligible()) return;
        if (!spamTookOver) {
            for (uint i = 0; i < botLabIds.length(); ++i) {
                if (!Spam::repeatTask.exists("" + botLabIds[i])) continue;
                spamTookOver = true;
                orderFrames.resize(0);
                GenericHelpers::LogUtil("[RezRep] spam-took-over lab=" + botLabIds[i] + " rez=" + rezFinished
                    + " rezAll=" + rezAll + " army=" + int(army) + " target=" + Target(), 1);
                break;
            }
            if (!spamTookOver) return;
        }
        for (uint i = 0; i < rezNames.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(rezNames[i]);
            if (d !is null && d.maxThisUnit != 0) d.maxThisUnit = 0;
        }
    }

    // A T1 bot lab that Spam turned into a pump runs one repeating recruit and never asks
    // Factory::AiMakeTask again, so FactoryMakeTask above is never reached (played: every
    // bot-lab FRONT stopped ordering rez bots once spam took its lab, minute 15-20). While
    // rez bots are short, end one pump's repeat the way Spam ends it itself; the lab asks
    // again, gets the rez bot order first and is a pump again once the stock is full.
    void _ReleaseSpamLab()
    {
        if (!Global::RezReplenish::Enabled && !Global::RezReplenish::ShareEnabled) return;
        if (_SecondLabOn()) { _ReleaseRezLab(); return; }   // spam first: only the rez lab's pump comes back
        if (!RoleEligible() || !Global::RezReplenish::ReleaseSpamLabs || Global::RezReplenish::StopRezWhenSpam) return;
        const int want = Want();
        if (want <= 0 || rezAll + int(orderFrames.length()) >= want) return;
        if (int(orderFrames.length()) >= Global::RezReplenish::MaxOrdersInFlight) return;
        for (uint i = 0; i < botLabIds.length(); ++i) {
            const string key = "" + botLabIds[i];
            if (!Spam::repeatTask.exists(key)) continue;
            if (ai.frame - _Get(releasedAt, botLabIds[i], -100000) < Global::RezReplenish::ReleaseSpacingSeconds * SECOND) continue;
            CCircuitUnit@ f = ai.GetTeamUnit(botLabIds[i]);
            IUnitTask@ task;
            if (f is null || !Spam::repeatTask.get(key, @task) || task is null || task.IsDead() || f.task !is task) continue;
            Spam::repeatTask.delete(key);
            task.Abort();
            _Set(releasedAt, botLabIds[i], ai.frame);
            ++releases;
            GenericHelpers::LogUtil("[RezRep] release spam lab=" + key + " rez=" + rezFinished + " rezAll=" + rezAll
                + " want=" + want + " army=" + int(army) + " releases=" + releases, 1);
            return;   // one lab at a time
        }
    }

    // SecondLab: by start factory, so a vehicle AI's own spam bot lab does not make it a donor
    bool _IsDonor()
    {
        if (_SecondLabOn()) return _StartedOnBotLab() && botLabs > 0 && !cut;
        return botLabs > 0 && RoleEligible() && !cut;
    }
    bool _IsRequester()
    {
        if (_SecondLabOn()) return firstFactory.length() > 0 && !_StartedOnBotLab() && vehPlants > 0;
        return botLabs == 0 && vehPlants > 0;
    }

    /**************************************************************************
     SecondLab (owner, 2026-10-28): the rez lab. See the header.
     **************************************************************************/
    bool _SecondLabOn() { return Global::RezReplenish::SecondLab && Global::RezReplenish::Enabled && RoleEligible(); }
    bool _StartedOnBotLab() { return UnitHelpers::IsT1BotLab(firstFactory); }

    bool _IsPump(int id) { return Spam::repeatTask.exists("" + id); }

    float _FillBar() { return spamStartIncome * Global::RezReplenish::SpamFillIncomeRatio; }

    // The rez lab may pump spam: Spam on and the income at the fill-in bar.
    bool _FillOpen()
    {
        return spamStartIncome > 0.0f && Spam::IsActive() && Economy::GetMinMetalIncomeLast10s() >= _FillBar();
    }

    // Make `f` the rez lab when none is set: a finished T1 bot lab of ours, after Spam took the
    // lead, that is neither the lead, an edge lane lab nor a pump.
    void _Designate(CCircuitUnit@ f)
    {
        if (rezLabId >= 0 || spamStartIncome < 0.0f || !_StartedOnBotLab() || f is null || f.circuitDef is null) return;
        if (f.id == leadLabId || _IsPump(f.id) || EdgeLanes::IsEdgeLab(f) || Lifecycle::IsRetiring(f)) return;
        if (!UnitHelpers::IsT1BotLab(f.circuitDef.GetName()) || f.GetBuildProgress() < 1.0f) return;
        rezLabId = f.id;
        rezLabFilling = false;
        if (leadLabId >= 0) Spam::laneLead.set("" + rezLabId, leadLabId);
        GenericHelpers::LogUtil("[RezRep] lab2 designate lab=" + rezLabId + " lead=" + leadLabId + " rez=" + rezFinished
            + " want=" + Want() + " army=" + int(army) + " min=" + (float(ai.frame) / MINUTE), 1);
    }

    // Update (every 2 s): the spam start, the lead, the rez lab's life and its fill-in state.
    // O(our T1 bot labs), a handful.
    void _SecondLabUpdate()
    {
        if (!_SecondLabOn() || !_StartedOnBotLab()) return;
        // the lead: a non-edge bot lab pump other than the rez lab; the first one marks the spam start
        if (leadLabId < 0 || ai.GetTeamUnit(leadLabId) is null || !_IsPump(leadLabId)) {
            int lead = -1;
            for (uint i = 0; i < botLabIds.length() && lead < 0; ++i) {
                const int id = botLabIds[i];
                if (id == rezLabId || !_IsPump(id) || EdgeLanes::IsEdgeKey("" + id)) continue;
                lead = id;
            }
            if (lead >= 0 && lead != leadLabId) {
                leadLabId = lead;
                if (spamStartIncome < 0.0f) {
                    spamStartIncome = AiMax(1.0f, Economy::GetMinMetalIncomeLast10s());
                    GenericHelpers::LogUtil("[RezRep] lab2 spam-start lead=" + lead + " income=" + int(spamStartIncome)
                        + " fillBar=" + int(_FillBar()) + " rez=" + rezFinished + " army=" + int(army)
                        + " min=" + (float(ai.frame) / MINUTE), 1);
                } else {
                    GenericHelpers::LogUtil("[RezRep] lab2 lead lead=" + lead + " lab2=" + rezLabId, 1);
                }
                if (rezLabId >= 0) Spam::laneLead.set("" + rezLabId, leadLabId);
            }
        }
        if (spamStartIncome < 0.0f) return;
        if (rezLabId >= 0) {
            CCircuitUnit@ f = ai.GetTeamUnit(rezLabId);
            if (f is null || Lifecycle::IsRetiring(f)) {
                GenericHelpers::LogUtil("[RezRep] lab2 lost lab=" + rezLabId + (f is null ? " (gone)" : " (retiring)"), 1);
                Spam::laneLead.delete("" + rezLabId);
                rezLabId = -1;
                rezLabFilling = false;
            }
        }
        if (rezLabId < 0) {
            for (uint i = 0; i < botLabIds.length() && rezLabId < 0; ++i) _Designate(ai.GetTeamUnit(botLabIds[i]));
            return;
        }
        const bool pumping = _IsPump(rezLabId);
        if (pumping != rezLabFilling) {
            rezLabFilling = pumping;
            GenericHelpers::LogUtil("[RezRep] lab2 fill " + (pumping ? "on" : "off") + " lab=" + rezLabId + " lead=" + leadLabId
                + " income=" + int(Economy::GetMinMetalIncomeLast10s()) + " bar=" + int(_FillBar()) + " rez=" + rezFinished
                + " rezAll=" + rezAll + " want=" + Want(), 1);
        }
    }

    // The rez lab's spam pump comes back when a rez bot is short or the income fell under
    // SpamFillReleaseFraction of the fill-in bar. The lead and every other pump are never released.
    void _ReleaseRezLab()
    {
        if (rezLabId < 0 || !rezLabFilling) return;
        const string key = "" + rezLabId;
        IUnitTask@ task;
        if (!Spam::repeatTask.get(key, @task) || task is null || task.IsDead()) return;
        CCircuitUnit@ f = ai.GetTeamUnit(rezLabId);
        if (f is null || f.task !is task) return;
        const int want = Want();
        const bool isShort = want > 0 && rezAll + int(orderFrames.length()) < want;
        const float income = Economy::GetMinMetalIncomeLast10s();
        const bool poor = income < _FillBar() * Global::RezReplenish::SpamFillReleaseFraction;
        if (!isShort && !poor) return;
        if (ai.frame - _Get(releasedAt, rezLabId, -100000) < Global::RezReplenish::ReleaseSpacingSeconds * SECOND) return;
        Spam::repeatTask.delete(key);
        task.Abort();
        _Set(releasedAt, rezLabId, ai.frame);
        ++releases;
        GenericHelpers::LogUtil("[RezRep] lab2 release lab=" + key + " reason=" + (isShort ? "rez" : "income")
            + " rez=" + rezFinished + " rezAll=" + rezAll + " want=" + want + " income=" + int(income)
            + " bar=" + int(_FillBar()) + " releases=" + releases, 1);
    }

    // Builder::AiMakeTask, before Spam's: one more T1 bot lab once Spam took the lead and no other
    // bot lab can be the rez lab. Native re-asks a builder every few seconds and swaps it to another
    // kind of job (played 2026-10-28: both smoke-test orders sat unbuilt), so a builder on our order
    // keeps it, up to two more join the order or help the frame, and a dead order with no frame is
    // ordered again after SecondLabRetrySeconds.
    IUnitTask@ lab2Task;
    array<IUnitTask@> lab2Help;
    int lab2FrameId = -1;
    array<int> lab2Rej = {0, 0, 0, 0, 0};   // asks refused: spacing, bank/energy, busy builder, want 0, no spot

    bool _OwnsTask(IUnitTask@ t)
    {
        if (t is null || t.IsDead()) return false;
        if (t is lab2Task) return true;
        for (uint i = 0; i < lab2Help.length(); ++i) if (t is lab2Help[i]) return true;
        return false;
    }

    // The frame our order raised, wherever native put it; null when none stands
    CCircuitUnit@ _Lab2Frame(CCircuitDef@ lab)
    {
        if (lab2FrameId >= 0) {
            CCircuitUnit@ f = ai.GetTeamUnit(lab2FrameId);
            if (f !is null) return f;
            lab2FrameId = -1;
        }
        IBuilderTask@ bt = (lab2Task is null || lab2Task.IsDead()) ? null : cast<IBuilderTask>(lab2Task);
        if (bt is null || bt.target is null || bt.target.circuitDef !is lab) return null;
        lab2FrameId = bt.target.id;
        return bt.target;
    }

    IUnitTask@ BuilderTask(CCircuitUnit@ u)
    {
        if (!_SecondLabOn() || spamStartIncome < 0.0f || !_StartedOnBotLab()) return null;
        if (u is null || u.circuitDef is null || !u.circuitDef.IsMobile() || UnitHelpers::IsCommander(u.circuitDef)) return null;
        if (_OwnsTask(u.task)) return u.task;
        if (rezLabId >= 0) return null;
        CCircuitDef@ lab = ai.GetCircuitDef(UnitHelpers::GetT1BotLabForSide(Global::AISettings::Side));
        if (lab is null || !u.circuitDef.CanBuild(lab)) return null;
        for (int i = int(lab2Help.length()) - 1; i >= 0; --i)
            if (lab2Help[i] is null || lab2Help[i].IsDead()) lab2Help.removeAt(i);
        CCircuitUnit@ frame = _Lab2Frame(lab);
        if (frame !is null) {
            if (frame.GetBuildProgress() >= 1.0f || lab2Help.length() >= 2) return null;
            IUnitTask@ h = aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, frame, 30 * SECOND));
            if (h !is null) lab2Help.insertLast(h);
            return h;
        }
        if (lab2Task !is null && !lab2Task.IsDead()) return (lab2Task.GetUnits().length() < 2) ? lab2Task : null;
        if (ai.frame - lastLab2Attempt < Global::RezReplenish::SecondLabRetrySeconds * SECOND) { ++lab2Rej[0]; return null; }
        if (aiEconomyMgr.isEnergyEmpty || aiEconomyMgr.metal.current < Global::RezReplenish::SecondLabMinMetalBank) { ++lab2Rej[1]; return null; }
        IBuilderTask@ current = u.task is null ? null : cast<IBuilderTask>(u.task);
        if (current !is null && Task::BuildType(current.GetBuildType()) < Task::BuildType::REPAIR) { ++lab2Rej[2]; return null; }
        Scan();
        if (Want() <= 0) { ++lab2Rej[3]; return null; }
        array<string> defs = UnitHelpers::GetRezBots(UnitHelpers::GetSideForUnitName(lab.GetName()));
        CCircuitDef@ rez = defs.length() == 0 ? null : ai.GetCircuitDef(defs[0]);
        lastLab2Attempt = ai.frame;
        CCircuitUnit@ lead = leadLabId < 0 ? null : ai.GetTeamUnit(leadLabId);
        const AIFloat3 home = lead is null ? Global::Map::StartPos : lead.GetPos(ai.frame);
        const float w = float(aiTerrainMgr.GetTerrainWidth()), h = float(aiTerrainMgr.GetTerrainHeight());
        // rings around the first lab, on bot ground the builder reaches, clear of allied layouts;
        // the ring start turns with each order so a refused spot is not ordered again
        for (int ring = 1; ring <= 3; ++ring) for (int k = 0; k < 8; ++k) {
            const float angle = float((k + lab2Builds * 3) % 8) * 0.785398f;
            const float r = float(ring) * Global::RezReplenish::SecondLabRingStep;
            const AIFloat3 p = AIFloat3(AiMax(256.0f, AiMin(w - 256.0f, home.x + cos(angle) * r)), 0,
                AiMax(256.0f, AiMin(h - 256.0f, home.z + sin(angle) * r)));
            if (!aiBattle.IsPassable(p, Lanes::BOT) || !aiTerrainMgr.CanReachAt(u, p, u.circuitDef.GetBuildDistance())
                || aiTerrainMgr.IsAllyLayoutBlocked(lab, p, 0)) continue;
            if (lab.maxThisUnit <= lab.count) lab.maxThisUnit = lab.count + 1;
            if (!lab.IsAvailable(ai.frame)) return null;
            @lab2Task = aiBuilderMgr.Enqueue(TaskB::Factory(Task::Priority::HIGH, lab, p, rez is null ? lab : rez, 128.0f,
                false, true, 120 * SECOND));
            if (lab2Task is null) return null;
            ++lab2Builds;
            GenericHelpers::LogUtil("[RezRep] lab2 build at " + int(p.x) + "," + int(p.z) + " builder=" + u.id
                + " lead=" + leadLabId + " rez=" + rezFinished + " want=" + Want() + " bank=" + int(aiEconomyMgr.metal.current)
                + " builds=" + lab2Builds + " min=" + (float(ai.frame) / MINUTE), 1);
            return lab2Task;
        }
        ++lab2Rej[4];
        return null;
    }

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
        if (cut) return;
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
            const int64 had = _Get(giftPending, fromTeamId, 0);
            const int room = Global::RezReplenish::ShareMaxOutstanding - (GiftOutstanding() - int(had));
            const int64 n = AiMin(AiMin(int(parseInt(p[3])), Global::RezReplenish::RequestUpTo), room);
            if (n <= 0) {
                GenericHelpers::LogUtil("[RezRep] request-full team=" + fromTeamId + " outstanding=" + GiftOutstanding(), 1);
                return true;
            }
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
