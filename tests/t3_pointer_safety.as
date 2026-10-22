// Loaded only by prepare_t3_pointer_safety.py in an isolated engine fixture.
namespace T3PointerFixture {
    CCircuitUnit@ donated;
    void Check(bool ok, const string &in label) {
        GenericHelpers::LogUtil("[T3PointerFixture] " + (ok ? "PASS " : "FAIL ") + label, 1);
    }
    void Message(const string &in data) {
        if (data.findFirst("t3pointer|") != 0) return;
        array<string>@ f = data.split("|");
        if (f.length() != 4) return;
        const int actor = parseInt(f[2]), target = parseInt(f[3]);
        Global::T3Unstick::Enabled = true;
        Global::Team::AllyClearEnabled = true;
        Check(!ai.IsOwnedUnit(null), "null ownership");
        T3Unstick::UnitAdded(null);
        T3Unstick::TaskAdded(null);
        T3Unstick::StartRound(null, null, AIFloat3());
        T3Unstick::EndRound(null, null, AIFloat3());
        T3Unstick::Nudge(null, AIFloat3());
        Check(!T3Unstick::IsT3(null) && !T3Unstick::RoundBusy(null)
            && T3Unstick::BuilderTask(null) is null && Team::AllyClear::BuilderTask(null) is null
            && !Team::AllyClear::Pending(null), "null entry points");
        ai.GiveUnits(null, ai.teamId);
        CCircuitUnit@ u = ai.GetTeamUnit(actor);
        if (f[1] == "donate") {
            Check(ai.IsOwnedUnit(u), "donor owns turret");
            if (!ai.IsOwnedUnit(u)) return;
            aiBuilderMgr.TurretsOnReclaim(target, 32.0f, true, false);
            IUnitTask@ before = u.task;
            Check(Team::AllyClear::LiveReclaim(before, ai.GetTeamUnit(target)), "donor turret on reclaim");
            @donated = u;
            array<CCircuitUnit@> offer = {null, u, u};
            ai.GiveUnits(offer, 0);
            Check(!ai.IsOwnedUnit(u), "duplicate donation removed once");
            Check(aiBuilderMgr.Enqueue(TaskB::Reclaim(Task::Priority::HIGH, u, 60 * SECOND)) is null,
                "reject donated target");
            Check(aiBuilderMgr.TurretsOnReclaim(actor, 32.0f, true, false) == -1, "reject missing turret");
            T3Unstick::Nudge(u, AIFloat3());
            Check(T3Unstick::BuilderTask(u) is null && Team::AllyClear::BuilderTask(u) is null,
                "reject donated worker");
        } else if (f[1] == "round") {
            Check(ai.IsOwnedUnit(u), "recipient owns hull");
            if (!ai.IsOwnedUnit(u)) return;
            T3Unstick::UnitAdded(u);
            T3Unstick::Hull@ h = T3Unstick::Find(actor);
            Check(h !is null && h.unit is u, "tracked hull identity");
            if (h is null) return;
            // Reach both allied blockers without changing shipped defaults.
            h.rounds = 1;
            T3Unstick::StartRound(h, u, u.GetPos(ai.frame));
            T3Unstick::RoundBusy(h);
            Check(h.roundStart >= 0 && h.blockers.length() > 0, "active blocker handoffs");
            if (h.blockers.length() > 0) {
                CCircuitUnit@ b = ai.GetTeamUnit(h.blockers[0]);
                T3Unstick::Hull overlapping;
                overlapping.id = actor; @overlapping.unit = u; overlapping.rounds = 1;
                T3Unstick::StartRound(overlapping, u, u.GetPos(ai.frame));
                T3Unstick::EndRound(overlapping, null, u.GetPos(ai.frame));
                CCircuitUnit@ shared = null;
                Check(T3Unstick::blockerUnit.get("" + b.id, @shared) && shared is b
                    && T3Unstick::activeBlockers.find(b.id) >= 0, "shared blocker survives other round");
                Team::AllyClear::Req r;
                r.key = "t3.fixture"; r.reclaimUntil = ai.frame + SECOND;
                r.received.set("" + b.id, @u); // stale identity under the offered ID
                Check(Team::AllyClear::Received(r, b.id) is null, "reject mismatched identity");
                r.received.delete("" + b.id);
                Check(Team::AllyClear::Received(r, b.id) is b, "accept matching identity");
                r.reclaimUntil = ai.frame;
                Check(Team::AllyClear::Received(r, b.id) is null, "reject expired offer");
            }
        } else if (f[1] == "late") {
            Check(!ai.IsOwnedUnit(donated), "old donor handle stays invalid");
            Check(T3Unstick::BuilderTask(donated) is null, "late callback rejects old donor");
        }
    }
}
