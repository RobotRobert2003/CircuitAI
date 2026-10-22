#include "../../helpers/math/recovery_math.as"
#include "../../helpers/units/unit_helpers.as"
#include "roster.as"
#include "ferry.as"

// D-218. One request per loss episode, one TECH donor, one live production
// order per request. Constructors are tracked by lifecycle events, not a
// once-per-second army scan. Only the small allied request queue is polled.
namespace Team { namespace Recovery {
    const string Prefix = "barbrescue";
    dictionary constructors;
    dictionary unavailableUntil;
    dictionary cancelledEpisode;
    bool hadConstructor = false;
    int donor = -1, episode = -1, lastRequest = -1;

    class Request {
        int team = -1, episode = -1, seen = -1;
        int factory = -1, definition = -1, gift = -1, nextGive = -1;
        int savedCap = -1, openedCap = -1;
        IUnitTask@ order;
    }
    array<Request@> pending;

    // Lua relay acknowledges enqueueing; forwarding happens on its next
    // GameFrame, never re-entering the sending AngelScript context. Without
    // the optional host widget the existing allied native channel is reliable.
    void Send(int target, const string &in verb, int token) {
        const string payload = Prefix + "|" + verb + "|" + token;
        const string reply = ai.CallUI("barbrescue-relay|" + ai.teamId + "|" + target + "|" + verb + "|" + token);
        if (reply != "barbrescue-queued") AiSendMessage(payload, target);
        GenericHelpers::LogUtil("[Recovery] channel=" + (reply == "barbrescue-queued" ? "lua" : "native")
            + " verb=" + verb + " target=" + target, 1);
    }

    bool IsGift(int id) {
        for (uint i = 0; i < pending.length(); ++i) if (pending[i].gift == id) return true;
        return false;
    }

    bool OnUnitAdded(CCircuitUnit@ unit) {
        if (unit is null || UnitHelpers::GetConstructorTier(unit.circuitDef) == 0) return false;
        // Only the explicitly ordered product can become a recovery gift.
        // Donor leaders, donations received from others and the opener are kept.
        if (Global::AISettings::Role == AiRole::TECH) for (uint i = 0; i < pending.length(); ++i) {
            Request@ r = pending[i];
            if (r.factory == unit.GetProducerId() && r.definition == unit.circuitDef.id && r.gift < 0) {
                r.gift = unit.id;
                ReleaseCap(r);
                @r.order = null;
                GenericHelpers::LogUtil("[Recovery] built gift=" + unit.id + " team=" + r.team, 1);
                return true; // do not register this temporary cargo as TECH's primary
            }
        }
        constructors.set("" + unit.id, true);
        hadConstructor = true;
        return false;
    }
    void OnUnitRemoved(CCircuitUnit@ unit) {
        if (unit !is null) constructors.delete("" + unit.id);
    }

    void ReleaseCap(Request@ r) {
        if (r.definition <= 0) return;
        CCircuitDef@ d = ai.GetCircuitDef(r.definition);
        // Restore only our lease; never overwrite a newer role policy change.
        if (d !is null && d.maxThisUnit == r.openedCap) d.maxThisUnit = r.savedCap;
        r.openedCap = -1;
    }

    void KeepUnsentGift(Request@ r) {
        if (r.gift < 0) return;
        CCircuitUnit@ kept = ai.GetTeamUnit(r.gift);
        if (kept !is null && !Team::Ferry::IsGift(kept.id)) {
            constructors.set("" + kept.id, true); hadConstructor = true;
        }
    }

    int PickDonor() {
        array<Team::Roster::Entry@>@ teams = Team::Roster::WithRole(AiRole::TECH);
        int best = -1;
        float distance = 1e30f;
        for (uint i = 0; i < teams.length(); ++i) {
            Team::Roster::Entry@ e = teams[i];
            if (e is null || e.teamId == ai.teamId || !Team::IsAlly(e.teamId)) continue;
            if (unavailableUntil.exists("" + e.teamId)) {
                int64 until = 0; unavailableUntil.get("" + e.teamId, until);
                if (ai.frame < until) continue;
            }
            // Keep the accepted donor through lab construction and transit.
            // Re-electing the nearest TECH on every heartbeat used to cancel
            // an underway delivery when a nearer TECH itself recovered.
            if (e.teamId == donor) return donor;
            const float d = MapHelpers::SqDist(Global::Map::StartPos, e.startPos);
            if (d < distance || (d == distance && e.teamId < best)) { best = e.teamId; distance = d; }
        }
        return best;
    }

    bool NeedsRequest() {
        return RecoveryMath::NeedsRequest(int(constructors.getSize()), hadConstructor,
            Builder::commander !is null, Global::BuilderRecovery::CommanderCounts,
            ai.frame, Global::BuilderRecovery::OpeningGraceSeconds * SECOND);
    }

    bool WantsFactory(CCircuitUnit@ factory) {
        if (!Global::BuilderRecovery::Enabled || Global::AISettings::Role != AiRole::TECH
            || factory is null || !UnitHelpers::IsT1BotLab(factory.circuitDef.GetName())
            || Lifecycle::IsRetiring(factory) || constructors.getSize() == 0) return false;
        for (uint i = 0; i < pending.length(); ++i)
            if (pending[i].gift < 0 && pending[i].order is null && ai.frame >= pending[i].nextGive) return true;
        return false;
    }

    IUnitTask@ FactoryMakeTask(CCircuitUnit@ factory) {
        if (!WantsFactory(factory)) return null;
        // Use the actual lab's build menu, including a captured other-faction
        // lab. No hardcoded side assumption and no persistent cap inflation.
        array<string> names = UnitHelpers::GetAllT1BotConstructors();
        CCircuitDef@ product = null;
        for (uint i = 0; i < names.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(names[i]);
            if (d !is null && factory.circuitDef.CanBuild(d)) { @product = d; break; }
        }
        if (product is null || !product.IsBuildAllowed()) return null;
        // Serialize recovery production: a single short cap lease and no
        // ambiguous completion when several bot labs ask in the same frame.
        for (uint i = 0; i < pending.length(); ++i) if (pending[i].order !is null) return null;
        for (uint i = 0; i < pending.length(); ++i) {
            Request@ r = pending[i];
            if (r.gift >= 0 || ai.frame < r.nextGive) continue;
            r.definition = product.id; r.savedCap = product.maxThisUnit;
            r.openedCap = AiMax(product.maxThisUnit, product.count + 1);
            product.maxThisUnit = r.openedCap;
            if (!product.IsAvailable(ai.frame)) { ReleaseCap(r); return null; }
            @r.order = aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER,
                Task::Priority::HIGH, product, factory.GetPos(ai.frame), 64.0f));
            if (r.order is null) { ReleaseCap(r); return null; }
            r.factory = factory.id;
            GenericHelpers::LogUtil("[Recovery] ordered " + product.GetName() + " factory=" + factory.id + " team=" + r.team, 1);
            return r.order;
        }
        return null;
    }

    bool HandleMessage(const string &in msg, int from) {
        if (msg.findFirst(Prefix + "|") != 0) return false;
        array<string>@ parts = msg.split("|");
        if (parts.length() != 3 || from == ai.teamId || !Team::IsAlly(from)) return true;
        const int token = int(parseInt(parts[2]));
        if (token < 0 || !Global::BuilderRecovery::Enabled) return true;
        if (parts[1] == "unavailable") {
            if (from == donor && token == episode)
                unavailableUntil.set("" + from, int64(ai.frame + Global::BuilderRecovery::LeaseSeconds * SECOND));
            return true;
        }
        if (Global::AISettings::Role != AiRole::TECH) return true;
        int index = -1;
        for (uint i = 0; i < pending.length(); ++i) if (pending[i].team == from) { index = int(i); break; }
        if (parts[1] == "cancel") {
            int64 last = -1;
            if (cancelledEpisode.exists("" + from)) cancelledEpisode.get("" + from, last);
            if (token > last) cancelledEpisode.set("" + from, int64(token));
            if (index >= 0 && pending[index].episode == token) {
                ReleaseCap(pending[index]);
                KeepUnsentGift(pending[index]);
                // A queued recruit may finish for TECH; a ferry already in
                // flight keeps its sole task owner and completes normally.
                pending.removeAt(index);
                GenericHelpers::LogUtil("[Recovery] completed/cancelled team=" + from, 1);
            }
            return true;
        }
        if (parts[1] != "request") return true;
        int64 cancelled = -1;
        if (cancelledEpisode.exists("" + from)) cancelledEpisode.get("" + from, cancelled);
        if (!RecoveryMath::AcceptEpisode(token, int(cancelled))) return true;
        // A TECH that also needs rescue must not strand nearer allies behind
        // its missing builders. They can try another TECH at the next retry.
        if (NeedsRequest()) { Send(from, "unavailable", token); return true; }
        if (index >= 0) {
            Request@ old = pending[index];
            if (token < old.episode) return true;
            old.seen = ai.frame;
            old.episode = token;
            return true; // heartbeat never adds a second order or cargo
        }
        Request@ r = Request(); r.team = from; r.episode = token; r.seen = ai.frame;
        pending.insertLast(r);
        GenericHelpers::LogUtil("[Recovery] queued team=" + from + " episode=" + token, 1);
    	return true;
    }

    bool HandleLua(const string &in msg) {
        if (msg.findFirst("barbrescue-lua|") != 0) return false;
        array<string>@ p = msg.split("|");
        if (p.length() == 5 && int(parseInt(p[2])) == ai.teamId)
            HandleMessage(Prefix + "|" + p[3] + "|" + p[4], int(parseInt(p[1])));
        return true;
    }

    void Update() {
        if (!Global::BuilderRecovery::Enabled || !Team::Roster::IsReady()) return;
        if (!NeedsRequest()) {
            if (donor >= 0) Send(donor, "cancel", episode);
            donor = -1; episode = -1; lastRequest = -1;
        } else if (RecoveryMath::Due(ai.frame, lastRequest, Global::BuilderRecovery::RetrySeconds * SECOND)) {
            const int chosen = PickDonor();
            if (chosen != donor && donor >= 0) Send(donor, "cancel", episode);
            donor = chosen;
            if (episode < 0) episode = ai.frame;
            lastRequest = ai.frame;
            if (donor >= 0) {
                Send(donor, "request", episode);
                GenericHelpers::LogUtil("[Recovery] request TECH=" + donor + " episode=" + episode, 1);
            }
        }
        for (int i = int(pending.length()) - 1; i >= 0; --i) {
            Request@ r = pending[i];
            if (Global::AISettings::Role != AiRole::TECH || ai.frame - r.seen > Global::BuilderRecovery::LeaseSeconds * SECOND) {
                ReleaseCap(r); KeepUnsentGift(r); pending.removeAt(i); continue;
            }
            if (r.gift >= 0) {
                CCircuitUnit@ u = ai.GetTeamUnit(r.gift);
                if (u is null) { r.gift = -1; r.factory = -1; r.definition = -1; r.nextGive = ai.frame + Global::BuilderRecovery::RetrySeconds * SECOND; }
                else if (!Team::Ferry::IsGift(u.id) && ai.frame >= r.nextGive) {
                    r.nextGive = ai.frame + Global::BuilderRecovery::RetrySeconds * SECOND;
                    Team::Roster::Entry@ e = Team::Roster::Get(r.team);
                    // Only an existing ferry: rescue never waits for AIR to
                    // manufacture a transport. Busy owned ferries may queue it.
                    if (e !is null && Team::Ferry::Transport() !is null) {
                        const AIFloat3 anchor = e.firstMex.x >= 0.0f ? e.firstMex : e.startPos;
                        const AIFloat3 safe = aiTerrainMgr.FindSafeDropSpot(u, anchor, Global::BuilderRecovery::DropRadius,
                            Global::Ferry::DropSurfaceThreat, Global::Ferry::DropAirThreat);
                        if (safe.x >= 0.0f && Team::Ferry::TryCarry(u, r.team, safe, true)) continue;
                        GenericHelpers::LogUtil("[Recovery] no usable ferry landing; giving directly team=" + r.team, 1);
                    }
                    array<CCircuitUnit@> give = {u};
                    ai.GiveUnits(give, r.team);
                    GenericHelpers::LogUtil("[Recovery] transfer requested gift=" + r.gift + " team=" + r.team, 1);
                }
            } else if (r.order !is null && (r.order.IsDead() || ai.GetTeamUnit(r.factory) is null)) {
                ReleaseCap(r); @r.order = null; r.factory = -1; r.definition = -1;
            }
            for (int j = 0; j < i; ++j) if (pending[j].team == r.team)
                Invariants::Violation("INV-159", "" + r.team, "duplicate constructor recovery obligation");
        }
    }
} }
