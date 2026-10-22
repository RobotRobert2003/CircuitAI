// Air transport ferry: AIR builds a transport for TECH, TECH flies donations.
#include "../../define.as"
#include "../../unit.as"
#include "../../task.as"
#include "../../global.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/spatial/map_helpers.as"
#include "roster.as"
#include "heavy_transport.as"
#include "../presentation/widget_link.as"

/******************************************************************************

TRANSPORT FERRY

A donated T2 constructor used to walk to its new owner: 410-470 metal of
unescorted builder crossing a contested map. This flies it instead.

The protocol is three messages over AiSendMessage, the channel the roster
already uses. It is deliberately not ai.CallUI - that is a one-way mirror to
the local LuaUI for display and never reaches another AI, so it cannot carry
coordination.

    barbferry|req|<x>|<z>     TECH -> all, when it starts its first T2 lab.
                              Carries TECH's base position so AIR need not
                              have seen TECH's roster line yet.
    barbferry|ack             AIR  -> TECH, "I am building one for you".
    barbferry|give|<unitId>   AIR  -> TECH, "it is over your base and yours".

Sequence, in the order the units actually move:

  1. a teammate wants a transport   -> broadcast req. Any role may call
                                       RequestTransport(); TECH does so on its
                                       own once its metal income clears
                                       RequestMinMetalIncome and it owns no
                                       transport, and again after
                                       RequestCooldownSeconds if that is still
                                       true (the transport died, or AIR was busy)
  2. AIR takes the request          -> the next air factory task is a
                                       transport, ahead of everything else
  3. transport finishes             -> AIR flies it to TECH's base itself,
                                       still owning it, so the hand-over
                                       happens where TECH wants the unit
  4. transport arrives              -> ai.GiveUnits to TECH, send give
  5. TECH receives it               -> CFerryTask holds it at TECH's base and
                                       it is never an army unit, because
                                       ROLE_TYPE(TRANS) now maps to FERRY in
                                       CMilitaryManager::DefaultMakeTask
  6. TECH donates a constructor     -> ferry.SetCargo(unit, recipient base):
                                       pick up, fly, drop
  7. the drop lands                 -> TECH gives the constructor to the
                                       recipient and the transport flies home

Every failure path falls back to the old behaviour - give the constructor and
let it walk - so a ferry that cannot be built, is shot down, or fails to lift
its cargo costs time, never the donation.

TRANSPORT CAP. Every transport def is capped at 0 for every role, from the
first tick. A transport with a role entry in behaviour.json is, to the native
recruiter, just another air unit, and it built extras that then sat idle with
nothing to carry. AIR raises the def it owes to owned+1 for exactly as long as
a request is open, so the ferry's explicit Recruit is the only order that can
ever produce one.

See doc/transport-ferry.md.

******************************************************************************/
namespace Team {
namespace Ferry {

    const string MSG = "barbferry";

    // CFerryTask::EState. Mirrored rather than registered as an enum: only the
    // two terminal values matter to policy.
    const int StateUnloading = 4;
    const int StateDone = 5;
    int unloadingSince = -1;      // INV-052 (D-122)
    bool unloadFlagged = false;
    const int StateFailed = 6;

    // ---- AIR side
    bool requestPending = false;   // a TECH asked and we have not delivered
    int  requestTeam = -1;
    AIFloat3 requestPos;
    int  orderedFrame = -1;        // a Recruit task is queued; do not queue more
    bool capsApplied = false;      // the 0 cap has been put on every transport def
    int  buildingId = -1;          // transport we are flying to TECH
    bool announced = false;
    bool buildingHoldApplied = false;
    array<int> waitingTeams;
    array<bool> waitingHeavy;
    bool requestHeavy = false;
    array<AIFloat3> waitingPositions;

    void StartNextRequest()
    {
        if (requestPending || buildingId >= 0 || waitingTeams.length() == 0) return;
        requestTeam = waitingTeams[0]; requestPos = waitingPositions[0];
        requestHeavy = waitingHeavy[0]; waitingHeavy.removeAt(0);
        waitingTeams.removeAt(0); waitingPositions.removeAt(0);
        requestPending = true; announced = false; orderedFrame = -1;
        GenericHelpers::LogUtil("[Ferry] AIR: serving team " + requestTeam + " queued=" + waitingTeams.length(), 1);
    }

    // ---- requester side (TECH by default; any role may ask)
    int  lastRequestFrame = -1;    // cooldown anchor; -1 = never asked
    int  transportId = -1;         // our ferry transport, once received
    bool transportHoldApplied = false;
    int  cargoId = -1;             // constructor in flight
    int  runStart = -1;            // D-110: the frame the run in flight began (INV-042)
    // D-110 (owner's rule): the cargo of a run is not interrupted until the drop-off
    bool IsCargo(int id) { return cargoId >= 0 && id == cargoId; }
    // D-112 (owner: a T2 constructor built for a teammate is allowed no action and
    // given no order, so the pickup cannot go wrong): a gift is the one in flight
    // or one queued behind it; from the moment it is a gift it is out of TECH's
    // builder pool, parked behind the base on open ground, clear of the factory
    // lanes and of TECH's own builders
    bool IsGift(int id) { return IsCargo(id) || queuedCargo.find(id) >= 0; }

    // Caller has established IsGift. Resolve exclusive logistics ownership
    // before shared builder providers, tracking gates and idle-work fallbacks.
    // Keep an existing hold instead of allocating/reissuing one on every ask.
    IUnitTask@ GiftTask(CCircuitUnit@ unit)
    {
        IUnitTask@ current = unit.task;
        IBuilderTask@ builderTask = cast<IBuilderTask>(current);
        if (IsCargo(unit.id) && current !is null && !current.IsDead() && builderTask is null) return current;
        if (current !is null && !current.IsDead() && current.GetType() == Task::Type::WAIT)
            return current;
        return Park(unit, false);
    }
    AIFloat3 runDrop;              // D-112: where the run in flight drops
    dictionary runAttempts;        // D-112: unit id -> flown runs tried
    // The parking spot of gift `slot`: ParkDistance behind our start (away from the
    // map centre, where the labs face), gifts ParkSpacing apart side by side
    AIFloat3 ParkSpot(int slot)
    {
        const float cx = float(AiTerrainWidth()) * 0.5f, cz = float(AiTerrainHeight()) * 0.5f;
        float dx = Global::Map::StartPos.x - cx, dz = Global::Map::StartPos.z - cz;
        float len = sqrt(dx * dx + dz * dz);
        if (len < 1.0f) { dx = 1.0f; dz = 0.0f; len = 1.0f; }
        dx /= len; dz /= len;
        const float side = float((slot + 1) / 2) * Global::Ferry::ParkSpacing * ((slot % 2 == 1) ? 1.0f : -1.0f);
        float x = Global::Map::StartPos.x + dx * Global::Ferry::ParkDistance - dz * side;
        float z = Global::Map::StartPos.z + dz * Global::Ferry::ParkDistance + dx * side;
        const float m = 64.0f;
        x = (x < m) ? m : ((x > float(AiTerrainWidth()) - m) ? float(AiTerrainWidth()) - m : x);
        z = (z < m) ? m : ((z > float(AiTerrainHeight()) - m) ? float(AiTerrainHeight()) - m : z);
        return AIFloat3(x, 0.0f, z);
    }
    // Take a gift out of every task (its old task carries on without it) onto a
    // long wait, and walk it to its parking spot once
    // assign: true where no MakeTask will assign the returned task (queueing, a re-queue)
    IUnitTask@ Park(CCircuitUnit@ u, bool assign = true)
    {
        if (u is null) return null;
        const int slot = (queuedCargo.find(u.id) >= 0) ? queuedCargo.find(u.id) : 0;
        const AIFloat3 spot = ParkSpot(slot);
        IUnitTask@ w = aiBuilderMgr.Enqueue(TaskB::Wait(Global::Ferry::ParkWaitSeconds * SECOND));
        if (w is null) return null;
        if (assign) aiBuilderMgr.AssignTask(u, w);
        if (MapHelpers::SqDist(u.GetPos(ai.frame), spot) > 64.0f * 64.0f) u.CmdMoveTo(spot);
        GenericHelpers::LogUtil("[Ferry] TECH: gift " + u.circuitDef.GetName() + " " + u.id + " parked at (" + int(spot.x) + ", " + int(spot.z)
            + "), no other order until its run (D-112)", 1);
        return w;
    }
    int  cargoRecipient = -1;
    // Constructors waiting for the transport, oldest first. A run in flight
    // used to mean "walk it"; now it means "next".
    array<int> queuedCargo;
    array<int> queuedRecipient;

    bool IsEnabled() { return Global::Ferry::Enabled; }

    string TransportForSide(const string &in side)
    {
        if (requestHeavy && Global::AISettings::Role == AiRole::AIR) {
            string heavy;
            if (Global::Ferry::HeavyTransportBySide.get(side, heavy)) return heavy;
            return "";
        }
        // exists() first: a failed get leaves the &out undefined, not "".
        if (!Global::Ferry::TransportBySide.exists(side)) return "";
        string name = "";
        Global::Ferry::TransportBySide.get(side, name);
        return name;
    }

    // The CFerryTask a transport carries. Every TRANS-role unit gets one from
    // CMilitaryManager::DefaultMakeTask, so this is null only before the unit
    // has been given a task, or after it died.
    CFerryTask@ TaskOf(CCircuitUnit@ u)
    {
        if (u is null || u.task is null) return null;
        IFighterTask@ ft = cast<IFighterTask>(u.task);
        if (ft is null) return null;
        return cast<CFerryTask>(ft);
    }

    CCircuitUnit@ Transport()
    {
        return (transportId < 0) ? null : ai.GetTeamUnit(transportId);
    }

    // Apply `pos` as the hold of unit `id`, if its CFerryTask exists yet.
    //
    // The hold is applied from Update(), retried every tick until it takes,
    // and NOT trusted to a single call from OnUnitAdded. Natively,
    // CMilitaryManager's attackerFinishedHandler puts a new unit on the idle
    // task and *then* raises UnitAdded; the CFerryTask is only assigned
    // afterwards, by UpdateIdle -> MakeTask. So at OnUnitAdded time TaskOf()
    // is null, a one-shot SetHoldPos is silently lost, and the transport sits
    // over the builder's base forever - which is exactly what was observed.
    bool _ApplyHold(int id, const AIFloat3 &in pos, const string &in tag)
    {
        CCircuitUnit@ u = ai.GetTeamUnit(id);
        if (u is null) return false;
        CFerryTask@ t = TaskOf(u);
        if (t is null) return false;
        t.SetHoldPos(pos);
        GenericHelpers::LogUtil("[Ferry] " + tag + ": transport " + id + " flying to ("
            + int(pos.x) + "," + int(pos.z) + ")", 1);
        return true;
    }

    // Cap every transport def at 0. Idempotent; the helper only writes on change.
    void _CapAll()
    {
        UnitHelpers::BatchApplyUnitCaps(Global::Ferry::AllTransportDefs, 0);
        capsApplied = true;
    }

    // Open exactly one build slot for the def we owe: owned + 1. Anything
    // already owned stays owned; nothing beyond the one order can be built.
    void _OpenSlot(const string &in name)
    {
        CCircuitDef@ d = ai.GetCircuitDef(name);
        if (d is null) return;
        const int cap = UnitDefHelpers::GetUnitDefCount(name) + 1;
        array<string> one = { name };
        UnitHelpers::BatchApplyUnitCaps(one, cap);
        GenericHelpers::LogUtil("[Ferry] AIR: build slot open for " + name + " (cap " + cap + ")", 2);
    }

    void _CloseSlot(const string &in name)
    {
        array<string> one = { name };
        UnitHelpers::BatchApplyUnitCaps(one, 0);
    }

    /**************************************************************************
     Requesting. Any role may call this; the cooldown is the only gate.
     **************************************************************************/
    bool RequestTransport(const string &in why)
    {
        if (!IsEnabled()) return false;
        if (transportId >= 0) return false;   // already have one
        if (lastRequestFrame >= 0
            && (ai.frame - lastRequestFrame) < int(Global::Ferry::RequestCooldownSeconds) * SECOND) {
            return false;
        }
        const AIFloat3 p = Global::Map::StartPos;
        array<Team::Roster::Entry@>@ providers = Team::Roster::WithRole(AiRole::AIR);
        int provider=-1; float nearest=1e30f;
        for (uint index=0; index<providers.length(); ++index) {
            const float distance=MapHelpers::SqDist(p,providers[index].startPos);
            if (distance<nearest || (distance==nearest && providers[index].teamId<provider)) {
                nearest=distance; provider=providers[index].teamId;
            }
        }
        if (provider<0) return false;
        lastRequestFrame = ai.frame;
        AiSendMessage(MSG + "|req|" + int(p.x) + "|" + int(p.z) + "|light", provider);
        GenericHelpers::LogUtil("[Ferry] requested a transport (" + why + ")", 1);
        WidgetLink::Send("ferry", "req|" + int(p.x) + "|" + int(p.z));
        return true;
    }

    bool IsHeavyTransport(CCircuitUnit@ unit) {
        return unit !is null && Global::Ferry::HeavyTransportDefs.find(unit.circuitDef.GetName()) >= 0;
    }
    bool IsLightTransport(CCircuitUnit@ unit) {
        return unit !is null && Global::Ferry::LightTransportDefs.find(unit.circuitDef.GetName()) >= 0;
    }
    // Request identity is (team, cargo class). Heavy demand cannot upgrade or
    // erase a pending constructor ferry. O(queued allied obligations), bounded
    // by two classes per ally; no new periodic work or cross-team broadcast.
    int QueuedRequest(int team, bool heavy) {
        for (uint index=0; index<waitingTeams.length(); ++index)
            if (waitingTeams[index]==team && waitingHeavy[index]==heavy) return int(index);
        return -1;
    }
    // TECH asks on its own. Not "when the T2 lab starts": that fired on the
    // lab task being *enqueued*, which is when TECH plans it, well before any
    // builder touches it - so the transport arrived far too early. Income is
    // the honest signal for "about to tech", and "owns none" plus the cooldown
    // covers the transport dying or AIR being busy the first time.
    void _AutoRequest()
    {
        if (Global::AISettings::Role != AiRole::TECH) return;
        if (transportId >= 0) return;
        if (Economy::GetMinMetalIncomeLast10s() < Global::Ferry::RequestMinMetalIncome) return;
        RequestTransport("TECH at +" + int(Global::Ferry::RequestMinMetalIncome) + " metal, no transport");
    }

    /**************************************************************************
     AIR: take the request, build the transport ahead of everything else.
     **************************************************************************/
    // Factory::AiMakeTask asks here before the role handler, the same way it
    // asks Spam. Returns null unless we owe someone a transport.
    IUnitTask@ FactoryMakeTask(CCircuitUnit@ factory)
    {
        if (!IsEnabled() || factory is null || factory.circuitDef is null) return null;
        if (Global::AISettings::Role == AiRole::TECH && transportId < 0
            && (queuedCargo.length()>0 || Economy::GetMinMetalIncomeLast10s()>=Global::Ferry::RequestMinMetalIncome)) {
            string name;
            if (!Global::Ferry::TransportBySide.get(Global::AISettings::Side,name)) return null;
            CCircuitDef@ light=ai.GetCircuitDef(name);
            if (light is null || !factory.circuitDef.CanBuild(light) || Lifecycle::IsRetiring(factory)
                || light.count+aiFactoryMgr.GetPendingRecruitCount(light)>0) return null;
            light.maxThisUnit=light.count+1;
            return aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER,
                Task::Priority::NOW,light,factory.GetPos(ai.frame),64.0f));
        }
        if (!requestPending || buildingId >= 0) return null;
        if (Global::AISettings::Role != AiRole::AIR) return null;
        if (factory is null || factory.circuitDef is null) return null;
        // One transport, not one per poll. The factory asks for a task every
        // time it goes idle, and buildingId is only set once the unit *exists*
        // - so without this latch every poll between the order and the unit
        // popping queued another transport, and the air plant built nothing
        // else for the rest of the game. Re-armed only if the order produced
        // nothing within OrderTimeoutSeconds (factory died, def disabled).
        if (orderedFrame >= 0) {
            CCircuitDef@ pendingDef = ai.GetCircuitDef(TransportForSide(Global::AISettings::Side));
            // A slow funded frame is still the same obligation. Never duplicate it on a timer.
            if (pendingDef !is null) {
                if (aiFactoryMgr.GetPendingRecruitCount(pendingDef) > 0) return null;
                array<Id>@ own = ai.GetOwnedUnitIds();
                for (uint i = 0; i < own.length(); ++i) {
                    CCircuitUnit@ frame = ai.GetTeamUnit(own[i]);
                    if (frame !is null && frame.circuitDef is pendingDef && frame.GetBuildProgress() < 1.0f) return null;
                }
            }
            if ((ai.frame - orderedFrame) < int(Global::Ferry::OrderTimeoutSeconds) * SECOND) {
                return null;
            }
            GenericHelpers::LogUtil("[Ferry] AIR: transport order timed out; re-ordering", 2);
            orderedFrame = -1;
        }
        // Only the air plant builds it. Both the light and heavy transports
        // come from the T1 plant, so this never waits on T2.
        if (factory.circuitDef.GetName() != UnitHelpers::GetT1AirPlantForSide(Global::AISettings::Side)) return null;

        const string name = TransportForSide(Global::AISettings::Side);
        if (name.length() == 0) return null;
        CCircuitDef@ d = ai.GetCircuitDef(name);
        if (d is null) {
            GenericHelpers::LogUtil("[Ferry] AIR: '" + name + "' is not a loaded def; cannot fill the request", 2);
            return null;
        }
        // Not IsAvailable(): the cap is 0 until _OpenSlot below raises it, so
        // that test would always fail here. The tech gate (sinceFrame) is the
        // only other thing IsAvailable adds and the T1 air plant clears it.

        if (!announced) {
            announced = true;
            AiSendMessage(MSG + "|ack", requestTeam);
        }
        _OpenSlot(name);
        if (!factory.circuitDef.CanBuild(d) || Lifecycle::IsRetiring(factory)) return null;
        IUnitTask@ order = aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::NOW,
                d, factory.GetPos(ai.frame), 64.f));
        if (order !is null) {
            orderedFrame = ai.frame;
            GenericHelpers::LogUtil("[Ferry] AIR: ordered one " + name + " for team " + requestTeam, 1);
        }
        return order;
    }

    // Military::AiUnitAdded. Two cases: AIR's new transport, and the one TECH
    // receives from AIR.
    // True for a unit we should treat as the ferry transport. The role tag is
    // the primary test, but a def missing its "transport" tag in behaviour.json
    // is exactly the failure that sent the first transports to the front, so
    // the configured name counts too: Global::Ferry::TransportBySide is the
    // single place that decides what the ferry is.
    bool IsFerryTransport(const CCircuitDef@ d)
    {
        if (d is null) return false;
        if (d.IsRoleAny(Unit::Role::TRANS.mask)) return true;
        return Global::Ferry::AllTransportDefs.find(d.GetName()) >= 0;
    }

    void OnUnitAdded(CCircuitUnit@ unit)
    {
        if (!IsEnabled() || unit is null || unit.circuitDef is null) return;
        if (!IsFerryTransport(unit.circuitDef)) return;

        if (Global::AISettings::Role == AiRole::AIR) {
            if (requestPending && buildingId < 0 && unit.circuitDef.GetName() == TransportForSide(Global::AISettings::Side)) {
                buildingId = unit.id;
                orderedFrame = -1;   // the order produced its unit
                // Fly it over before handing it across. A unit given at our own
                // base would have to cross the map under TECH's control with no
                // task that knows where to send it. The hold usually cannot be
                // applied yet (see _ApplyHold); Update() keeps trying.
                buildingHoldApplied = _ApplyHold(unit.id, requestPos, "AIR");
                GenericHelpers::LogUtil("[Ferry] AIR: transport " + unit.id + " built for team "
                    + requestTeam + (buildingHoldApplied ? "" : "; hold pending task"), 1);
            }
            return;
        }
        // Any role that asked for one keeps it. A transport arriving unasked -
        // a human gift - is kept too; there is no better use for it.
        HeavyTransport::Added(unit);
        if (!IsLightTransport(unit)) return;
        _CloseSlot(unit.circuitDef.GetName());
        if (transportId < 0 || transportId == unit.id) {
            transportId = unit.id;
            transportHoldApplied = _ApplyHold(unit.id, Global::Map::StartPos, "reserved");
            GenericHelpers::LogUtil("[Ferry] transport " + unit.id + " received and reserved"
                + (transportHoldApplied ? "" : "; hold pending task"), 1);
            WidgetLink::Send("ferry", "have|" + unit.id);
        }
    }

    void OnUnitRemoved(CCircuitUnit@ unit)
    {
        if (unit is null) return;
        dropOverrides.delete("" + unit.id);
        if (unit.id == buildingId) {
            buildingId = -1;
            buildingHoldApplied = false;
            orderedFrame = -1;   // shot down in transit: the request is still owed
        }
        HeavyTransport::Removed(unit);
        if (unit.id == transportId) {
            transportId = -1;
            transportHoldApplied = false;
            GenericHelpers::LogUtil("[Ferry] transport lost; donations walk until the next request lands", 1);
            _WalkQueue("transport lost");
        }
        for (uint i = 0; i < queuedCargo.length(); ++i) {
            if (queuedCargo[i] == unit.id) {
                queuedCargo.removeAt(i);
                queuedRecipient.removeAt(i);
                break;
            }
        }
    }

    // No transport to wait for: every queued constructor walks now.
    void _WalkQueue(const string &in why)
    {
        while (queuedCargo.length() > 0) {
            const int id = queuedCargo[0];
            const int to = queuedRecipient[0];
            queuedCargo.removeAt(0);
            queuedRecipient.removeAt(0);
            CCircuitUnit@ u = ai.GetTeamUnit(id);
            if (u is null || to < 0 || to == ai.teamId) continue;
            array<CCircuitUnit@> give(1);
            @give[0] = u;
            ai.GiveUnits(give, to);
            GenericHelpers::LogUtil("[Ferry] TECH: " + why + "; gave queued constructor " + id + " to team " + to, 1);
        }
    }

    // The transport is free: start the oldest queued run.
    int safeRetryFrame = -1;
    int awaitTransportSince = -1;
    void _StartNext()
    {
        if (ai.frame < safeRetryFrame) return;
        if (HeavyTransport::Busy(TaskOf(Transport()))) return;
        while (queuedCargo.length() > 0) {
            const int id = queuedCargo[0];
            const int to = queuedRecipient[0];
            queuedCargo.removeAt(0);
            queuedRecipient.removeAt(0);
            CCircuitUnit@ u = ai.GetTeamUnit(id);
            if (u is null) continue;
            Team::Roster::Entry@ e = Team::Roster::Get(to);
            if (e !is null && TryCarry(u, to, e.startPos)) {
                GenericHelpers::LogUtil("[Ferry] TECH: next run from the queue: " + id + " to team " + to
                    + " (" + queuedCargo.length() + " still waiting)", 1);
                return;
            }
            // No roster entry or the ferry refused: this one walks.
            if (to >= 0 && to != ai.teamId) {
                array<CCircuitUnit@> give(1);
                @give[0] = u;
                ai.GiveUnits(give, to);
                GenericHelpers::LogUtil("[Ferry] TECH: could not start a run for " + id + "; gave it to team " + to, 1);
            }
        }
    }

    /**************************************************************************
     TECH: fly a donation instead of walking it.
     **************************************************************************/
    // True when the ferry took the job. False means "walk it", and the caller
    // donates immediately exactly as it did before.
    // Every refusal says why, at level 1. A silent false here is
    // indistinguishable from a pickup in a LOG_LEVEL 1 log, and that cost a
    // whole game of not knowing whether the transport was ever asked.
    bool _Refuse(const string &in why)
    {
        GenericHelpers::LogUtil("[Ferry] TECH: not carrying - " + why + "; constructor walks", 1);
        return false;
    }

    // Optional caller-selected safe anchor. Preserve it while a busy ferry
    // queues the cargo; ordinary T2 donations retain the first-mex policy.
    dictionary dropOverrides;
    bool TryCarry(CCircuitUnit@ cargo, int recipient, const AIFloat3 &in dropPos, bool useProvidedDrop = false)
    {
        if (!IsEnabled()) return _Refuse("ferry disabled");
        if (cargo is null || recipient < 0) return _Refuse("no cargo or no recipient");
        if (useProvidedDrop) dropOverrides.set("" + cargo.id, dropPos);
        CCircuitUnit@ t = Transport();
        if (t !is null && !IsLightTransport(t)) {
            Invariants::Violation("INV-195",""+t.id,"constructor ferry claimed a non-light transport");
            return _Refuse("constructor carrier class mismatch");
        }
        CFerryTask@ task = TaskOf(t);
        if (task is null) {
            const CCircuitDef@ localPlant=ai.GetCircuitDef(UnitHelpers::GetT1AirPlantForSide(Global::AISettings::Side));
            if (t is null && (localPlant is null || localPlant.count==0)
                && Team::Roster::WithRole(AiRole::AIR).length() == 0)
                return _Refuse("no allied AIR transport provider");
            if (queuedCargo.find(cargo.id) < 0) {
                queuedCargo.insertLast(cargo.id); queuedRecipient.insertLast(recipient);
            }
            if (awaitTransportSince < 0) awaitTransportSince = ai.frame;
            RequestTransport("constructor awaiting first-mex delivery");
            GenericHelpers::LogUtil("[Ferry] TECH: queued " + cargo.id + " until its transport arrives", 1);
            return true; // ferry.cargo owns the gift while AIR fulfills the request
        }
        if (cargoId >= 0 || HeavyTransport::Busy(task)) {
            // A run is in flight: queue behind it rather than walk. "If an air
            // transport is available always deliver it" - it is, just busy.
            if (queuedCargo.find(cargo.id) < 0) {
                queuedCargo.insertLast(cargo.id);
                queuedRecipient.insertLast(recipient);
            }
            // D-112: parked by the ferry.cargo rule at its next ask (a new gift is idle
            // and asks at once). Not assigned here: this runs inside the unit-added
            // hook, and native assigns the unit to its idle task right after it returns
            // (an assignment here would leave the unit listed by two tasks)
            GenericHelpers::LogUtil("[Ferry] TECH: queued " + cargo.id + " for team " + recipient
                + " behind cargo " + cargoId + " (" + queuedCargo.length() + " waiting)", 1);
            return true;
        }
        // D-110 (played: no unload ever took at a teammate's start, their busiest
        // ground): the drop is FerryDropPullback short of it, toward our base
        Team::Roster::Entry@ ally = Team::Roster::Get(recipient);
        const bool explicitAnchor = dropOverrides.exists("" + cargo.id);
        const bool mexAnchor = !explicitAnchor && ally !is null && ally.firstMex.x >= 0.0f;
        AIFloat3 drop = mexAnchor ? ally.firstMex : dropPos;
        if (explicitAnchor) dropOverrides.get("" + cargo.id, drop);
        if (!mexAnchor && !explicitAnchor) {
            const float dx = Global::Map::StartPos.x - dropPos.x, dz = Global::Map::StartPos.z - dropPos.z;
            const float len = sqrt(dx * dx + dz * dz);
            const float pull = Global::Ferry::DropPullback;
            if (len > 2.0f * pull) drop = AIFloat3(dropPos.x + dx / len * pull, dropPos.y, dropPos.z + dz / len * pull);
        }
        const AIFloat3 safe = aiTerrainMgr.FindSafeDropSpot(cargo, drop, Global::Ferry::SafeDropRadius,
            Global::Ferry::DropSurfaceThreat, Global::Ferry::DropAirThreat);
        if (safe.x < 0.0f) {
            safeRetryFrame = ai.frame + 10 * SECOND;
            GenericHelpers::LogUtil("[Ferry] waiting for safe ground near recipient " + recipient + " first mex/start", 1);
            if (queuedCargo.find(cargo.id) < 0) { queuedCargo.insertLast(cargo.id); queuedRecipient.insertLast(recipient); }
            return true; // retain cargo for a later safe delivery
        }
        drop = safe;
        if (aiBattle.SurfThreat(drop) > Global::Ferry::DropSurfaceThreat || aiBattle.AirThreat(drop) > Global::Ferry::DropAirThreat)
            Invariants::Violation("INV-086", "" + cargo.id, "ferry selected an unsafe landing point");
        if (!task.SetCargo(cargo.id, drop, Global::Ferry::DropSurfaceThreat, Global::Ferry::DropAirThreat)) return _Refuse("CFerryTask refused SetCargo (state " + task.GetState() + ")");
        cargoId = cargo.id;
        cargoRecipient = recipient;
        runStart = ai.frame;
        runDrop = drop;
        { int64 n = 0; runAttempts.get("" + cargo.id, n); runAttempts.set("" + cargo.id, n + 1); }   // int64: the dictionary's integer type
        GenericHelpers::LogUtil("[Ferry] TECH: carrying " + cargo.id + " to team " + recipient
            + " at (" + int(drop.x) + "," + int(drop.z) + ") anchor=" + (mexAnchor ? "first-mex" : "start")
            + " distance=" + int(sqrt(MapHelpers::SqDist(drop, mexAnchor ? ally.firstMex : dropPos))), 1);
        WidgetLink::Send("ferry", "carry|" + cargo.id + "|" + recipient);
        return true;
    }

    // Hand the cargo over and release the transport. `delivered` distinguishes
    // a flown delivery from a fallback, for the log only - the constructor
    // changes hands either way.
    void _Finish(bool delivered)
    {
        if (!delivered) {
            CFerryTask@ ft = TaskOf(Transport());
            GenericHelpers::LogUtil("[Ferry] TECH: run for cargo " + cargoId + " did not complete (task "
                + (ft is null ? "gone" : "state " + ft.GetState()) + "); giving where it stands", 1);
        }
        CCircuitUnit@ cargo = (cargoId < 0) ? null : ai.GetTeamUnit(cargoId);
        // D-112 (the owner's game: a gift still at base was handed over while the
        // transport carried another unit): a failed run whose cargo is far from the
        // drop gives nothing; the gift is parked and queued first for another run,
        // FerryRunAttempts in all, then it walks
        if (!delivered && cargo !is null && cargoRecipient >= 0
            && MapHelpers::SqDist(cargo.GetPos(ai.frame), runDrop) > Global::Ferry::GiveNearDrop * Global::Ferry::GiveNearDrop)
        {
            int64 tries = 0;
            runAttempts.get("" + cargoId, tries);
            if (tries < Global::Ferry::FerryRunAttempts) {
                GenericHelpers::LogUtil("[Ferry] TECH: cargo " + cargoId + " is not at the drop (" + int(sqrt(MapHelpers::SqDist(cargo.GetPos(ai.frame), runDrop)))
                    + " away): not given; queued again for run " + (tries + 1) + " of " + Global::Ferry::FerryRunAttempts + " (D-112)", 1);
                queuedCargo.insertAt(0, cargoId);
                queuedRecipient.insertAt(0, cargoRecipient);
                cargoId = -1;
                Park(cargo);
                cargoRecipient = -1;
                runStart = -1;
                CFerryTask@ rt = TaskOf(Transport());
                if (rt !is null) rt.Reset();   // home, setting down whatever is aboard
                _StartNext();
                return;
            }
        }
        if (cargo !is null && cargoRecipient >= 0 && cargoRecipient != ai.teamId) {
            array<CCircuitUnit@> give(1);
            @give[0] = cargo;
            ai.GiveUnits(give, cargoRecipient);
            GenericHelpers::LogUtil("[Ferry] TECH: " + (delivered ? "delivered" : "fell back, gave")
                + " constructor " + cargoId + " to team " + cargoRecipient, 1);
            WidgetLink::Send("ferry", (delivered ? "done|" : "fallback|") + cargoId + "|" + cargoRecipient);
        }
        cargoId = -1;
        cargoRecipient = -1;
        runStart = -1;
        CFerryTask@ task = TaskOf(Transport());
        if (task !is null) task.Reset();   // sends it home
        _StartNext();
    }

    /**************************************************************************
     Tick. Main::AiUpdate, every 30 frames.
     **************************************************************************/
    void Update()
    {
        if (!IsEnabled()) return;
        if (!capsApplied) _CapAll();
        HeavyTransport::Update();

        if (Global::AISettings::Role == AiRole::AIR) {
            for (uint i = 0; i < waitingTeams.length(); ++i) {
                if ((requestPending && waitingTeams[i] == requestTeam && waitingHeavy[i] == requestHeavy)
                    || QueuedRequest(waitingTeams[i],waitingHeavy[i]) != int(i))
                    Invariants::Violation("INV-075", "" + waitingTeams[i], "duplicate AIR transport obligation");
            }
        }

        _AutoRequest();

        // Holds first: they almost never take at OnUnitAdded (see _ApplyHold).
        if (buildingId >= 0 && !buildingHoldApplied) {
            buildingHoldApplied = _ApplyHold(buildingId, requestPos, "AIR");
        }
        if (transportId >= 0 && !transportHoldApplied) {
            transportHoldApplied = _ApplyHold(transportId, Global::Map::StartPos, "reserved");
        }

        // AIR: has the transport reached the requester's base? Hand it over there.
        if (buildingId >= 0 && requestPending) {
            CCircuitUnit@ t = ai.GetTeamUnit(buildingId);
            if (t is null) {
                buildingId = -1;
                buildingHoldApplied = false;
                announced = false;
            } else if (MapHelpers::SqDist(t.GetPos(ai.frame), requestPos)
                       < Global::Ferry::ArriveRadius * Global::Ferry::ArriveRadius) {
                const int gaveId = buildingId;   // log after the fields are cleared
                array<CCircuitUnit@> give(1);
                @give[0] = t;
                ai.GiveUnits(give, requestTeam);
                AiSendMessage(MSG + "|give|" + gaveId, requestTeam);
                _CloseSlot(TransportForSide(Global::AISettings::Side));
                requestPending = false;
                buildingId = -1;
                buildingHoldApplied = false;
                GenericHelpers::LogUtil("[Ferry] AIR: transport " + gaveId
                    + " arrived and transferred to team " + requestTeam, 1);
                WidgetLink::Send("ferry", "gave|" + gaveId + "|" + requestTeam);
                StartNextRequest();
            }
        }

        // A new gift may precede the income-triggered transport request. Keep it
        // for the arriving carrier, with a bounded fallback if AIR cannot help.
        if (cargoId < 0 && queuedCargo.length() > 0) {
            if (TaskOf(Transport()) !is null) {
                awaitTransportSince = -1;
                _StartNext();
            } else {
                if (awaitTransportSince < 0) awaitTransportSince = ai.frame;
                if (ai.frame - awaitTransportSince >= Global::Ferry::AwaitTransportSeconds * SECOND) {
                    _WalkQueue("transport arrival time-out"); awaitTransportSince = -1;
                } else RequestTransport("queued constructor delivery");
            }
        } else if (queuedCargo.length() == 0) awaitTransportSince = -1;
        // TECH: poll the run.
        if (cargoId >= 0) {
            CFerryTask@ task = TaskOf(Transport());
            if (task is null) {
                _Finish(false);   // transport died mid-run; walk the rest
                return;
            }
            const int st = task.GetState();
            // INV-052 (D-122): a run unloads within FerryUnloadSeconds (played: the
            // cargo out at 7 s, the run done at 90+ s, the transport idle)
            if (st == StateUnloading) {
                if (unloadingSince < 0) unloadingSince = ai.frame;
                else if (!unloadFlagged && ai.frame - unloadingSince > Global::Ferry::FerryUnloadSeconds * SECOND) {
                    unloadFlagged = true;
                    Invariants::Violation("INV-052", "" + cargoId, "ferry run for cargo " + cargoId + " unloading for "
                        + int((ai.frame - unloadingSince) / SECOND) + " s");
                }
            } else { unloadingSince = -1; unloadFlagged = false; }
            if (st == StateDone) {
                _Finish(true);
            } else if (st == StateFailed) {
                _Finish(false);
            }
        }
    }

    /**************************************************************************
     Messages. Team::HandleMessage routes here.
     **************************************************************************/
    bool HandleMessage(const string &in msg, int fromTeamId)
    {
        if (!IsEnabled()) return false;
        array<string>@ p = msg.split("|");
        if (p.length() < 2 || p[0] != MSG) return false;

        // Withdraw only this ally's heavy obligation. Constructor requests and
        // already started builds/flights keep their existing ownership/lifecycle.
        if (p[1] == "cancel" && p.length() >= 3 && p[2] == "heavy") {
            if (Global::AISettings::Role != AiRole::AIR) return true;
            array<Id>@ allies = ai.GetTeamIds();
            if (fromTeamId == ai.teamId || allies.find(fromTeamId) < 0) return true;
            const int queued = QueuedRequest(fromTeamId, true);
            if (queued >= 0) {
                waitingTeams.removeAt(queued); waitingPositions.removeAt(queued); waitingHeavy.removeAt(queued);
            }
            if (requestPending && requestTeam == fromTeamId && requestHeavy && orderedFrame < 0 && buildingId < 0) {
                _CloseSlot(TransportForSide(Global::AISettings::Side));
                requestPending = false; requestTeam = -1; announced = false;
                StartNextRequest();
            }
            return true;
        }

        if (p[1] == "req") {
            if (Global::AISettings::Role != AiRole::AIR) return true;
            array<Id>@ allies = ai.GetTeamIds();
            if (fromTeamId == ai.teamId || allies.find(fromTeamId) < 0) return true;
            const bool heavy = p.length() >= 5 && p[4] == "heavy";
            if (requestPending && requestTeam == fromTeamId && requestHeavy == heavy) return true;
            if (QueuedRequest(fromTeamId,heavy)>=0) return true;
            AIFloat3 wantedPos = Global::Map::StartPos;
            if (p.length() >= 4) {
                wantedPos = AIFloat3(parseFloat(p[2]), 0.f, parseFloat(p[3]));
            }
            // Prefer the roster's own position when we have it: the sender's
            // message may predate a start-position correction.
            Team::Roster::Entry@ e = Team::Roster::Get(fromTeamId);
            if (e !is null) wantedPos = e.startPos;
            if (!(wantedPos.x >= 0.0f && wantedPos.x <= float(AiTerrainWidth()) && wantedPos.z >= 0.0f && wantedPos.z <= float(AiTerrainHeight()))) return true;
            waitingTeams.insertLast(fromTeamId); waitingPositions.insertLast(wantedPos); waitingHeavy.insertLast(heavy);
            GenericHelpers::LogUtil("[Ferry] AIR: queued request from team " + fromTeamId, 1);
            StartNextRequest();
            return true;
        }
        if (p[1] == "ack") {
            GenericHelpers::LogUtil("[Ferry] TECH: team " + fromTeamId + " is building our transport", 2);
            return true;
        }
        if (p[1] == "give") {
            // Unit ids are global, so the id in the message is ours now. Take it
            // here as well as in OnUnitAdded: a gifted unit may reach us through
            // a different native handler, and Update() applies the hold either
            // way once the CFerryTask exists.
            if (p.length() >= 3 && transportId < 0 && IsLightTransport(ai.GetTeamUnit(parseInt(p[2])))) {
                transportId = parseInt(p[2]);
                transportHoldApplied = false;
            }
            GenericHelpers::LogUtil("[Ferry] team " + fromTeamId + " transferred transport "
                + (p.length() >= 3 ? p[2] : "?"), 2);
            return true;
        }
        return false;
    }

}  // namespace Ferry
}  // namespace Team
