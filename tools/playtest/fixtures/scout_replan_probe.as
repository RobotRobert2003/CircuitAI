// D-311: supply the exact state that used to lose its replan event. All
// contacts/coverage are still observed by the real AI; no hidden target IDs.
namespace ScoutReplanProbe {
    int actor = -1;
    int injected = -1;
    bool finished = false;
    void Before() {
        if (ai.teamId != 0 || injected >= 0 || ai.frame < ScoutRaid::lastTick + SECOND) return;
        const AIFloat3 screen(4000, 0, 7200);
        if (aiBattle.GroundHazard(screen, Global::ScoutRaid::HazardMargin) <= 0.f) return;
        for (uint i = 0; i < ScoutRaid::raiders.length(); ++i) {
            ScoutRaid::Raider@ r = ScoutRaid::raiders[i];
            CCircuitUnit@ u = ai.GetTeamUnit(r.id);
            AIFloat3 seen;
            if (u is null || r.task is null || r.queued || r.target < 0
                || !ScoutRaid::ContactAlive(r.target, seen)) continue;
            const AIFloat3 pos = u.GetPos(ai.frame);
            if (aiBattle.GroundHazard(pos, Global::ScoutRaid::HazardMargin) > 0.f) continue;
            r.route = {pos, screen}; r.cursor = 0;
            r.task.SetRoute(r.route);
            r.hazardSince = -1;
            r.nextReplan = ai.frame + 4 * SECOND;
            r.lastPos = pos; r.lastMove = ai.frame;
            actor = r.id; injected = ai.frame;
            GenericHelpers::LogUtil("[ScoutReplanTest] injected live_target="+r.target+" unit="+actor,1);
            return;
        }
    }
    void After() {
        if (injected < 0 || finished || ai.teamId != 0) return;
        ScoutRaid::Raider@ r = ScoutRaid::Find(actor);
        if (r is null) {
            finished = true;
            GenericHelpers::LogUtil("[ScoutReplanTest] FAIL lost owner",1);
        } else if (r.route.length() == 0 && !r.queued) {
            finished = true;
            GenericHelpers::LogUtil("[ScoutReplanTest] FAIL cleared route lost pending replan",1);
        } else if (r.route.length() > 1 && !r.queued && r.hazardSince < 0) {
            finished = true;
            GenericHelpers::LogUtil("[ScoutReplanTest] PASS live_target_hazard_replanned unit="+actor,1);
        } else if (ai.frame > injected + 4 * SECOND) {
            finished = true;
            GenericHelpers::LogUtil("[ScoutReplanTest] FAIL replan deadline",1);
        }
    }
}
