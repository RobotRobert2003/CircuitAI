// Idle T1 vehicle constructor reclaim (owner, 2026-10-20).
#include "../../global.as"
#include "../../task.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/spatial/map_helpers.as"
#include "../../helpers/math/idle_reclaim_math.as"

/******************************************************************************

IDLE RECLAIM

Barbs left battle wrecks on the ground and humans reclaimed them. An idle T1
vehicle constructor (patrol, wait, no work, or assisting a factory) now drives
to a wreck site that the threat map says is safe and area-reclaims it, the way
SeaRecovery sends rez subs to safe wrecks.

  sites   AngelScript cannot list map features, so wreck sites come from our
          own losses: every unit of ours killed by damage (health <= 0, so a
          transfer or a reclaim leaves none) adds WreckFraction of its cost to
          its SiteCell grid cell. Enemy wrecks lie in the same fights. A site
          expires SiteLifetimeSeconds after its last death.
  safety  the site centre and four points on its AreaRadius ring must all be
          at or under MaxSurfThreat, and CanReachAtSafe must find a safe path.
          Tick aborts a run whose site turns unsafe; the site then waits
          UnsafeRetrySeconds before anyone tries it again.
  order   one native area-reclaim task per site (CBReclaimTask with radius,
          CONTROL so metal features go first). The engine walks feature to
          feature inside the circle and skips wrecks an ally is resurrecting.
          Native aborts the task when metal is full (isMetalFull) and when the
          circle is empty; the task times out after JobTimeoutSeconds so real
          construction can take the con back.
  limits  MaxConcurrent runs per AI, one con per site; a con with no site is
          re-scanned at most every UnitRetrySeconds.

Cost: UnitRemoved is O(1) plus a dictionary lookup. Offer is O(sites), at most
MaxSites (48), with at most 4 threat/path checks, and runs only for an idle
listed con. Tick is O(jobs + sites) every 2 s. No feature or unit scans.

******************************************************************************/
namespace IdleReclaim {

    class Site {
        AIFloat3 pos;
        float metal = 0.0f;
        int key = 0;
        int lastAdded = 0;
        int retryAt = 0;
        int jobUnit = -1;
    }
    class Job {
        int unit = -1;
        int site = -1;       // Site.key
        int started = 0;
        IUnitTask@ task;
    }

    array<Site@> sites;
    array<Job@> jobs;
    dictionary unitRetry;    // con id -> frame of its next scan
    dictionary units;        // def name -> true (Global::IdleReclaim::Units)
    bool unitsBuilt = false;
    int lastRemovedId = -1;
    int lastRemovedFrame = -1;
    int nextTick = 0;

    bool Listed(const CCircuitDef@ d)
    {
        if (d is null) return false;
        if (!unitsBuilt) {
            unitsBuilt = true;
            for (uint i = 0; i < Global::IdleReclaim::Units.length(); ++i) units.set(Global::IdleReclaim::Units[i], true);
        }
        return units.exists(d.GetName());
    }

    Site@ FindSite(int key)
    {
        for (uint i = 0; i < sites.length(); ++i) if (sites[i].key == key) return sites[i];
        return null;
    }

    void DropSite(int key)
    {
        for (uint i = 0; i < sites.length(); ++i) {
            if (sites[i].key != key) continue;
            sites.removeAt(i);
            return;
        }
    }

    // From Military/Builder/Factory AiUnitRemoved. A unit in several managers
    // is reported once per frame.
    void UnitRemoved(CCircuitUnit@ unit)
    {
        if (unit is null) return;
        Release(unit.id);
        if (!Global::IdleReclaim::Enabled || unit.circuitDef is null) return;
        if (unit.id == lastRemovedId && ai.frame == lastRemovedFrame) return;
        lastRemovedId = unit.id;
        lastRemovedFrame = ai.frame;
        const CCircuitDef@ d = unit.circuitDef;
        if (d.IsAbleToFly() || d.costM < Global::IdleReclaim::MinUnitCost) return;
        if (unit.GetBuildProgress() < 1.0f || unit.GetHealthPercent() > 0.0f) return;   // nanoframe, transfer or reclaim
        const float metal = IdleReclaimMath::WreckMetal(d.costM, Global::IdleReclaim::WreckFraction);
        const AIFloat3 p = unit.GetPos(ai.frame);
        const int key = IdleReclaimMath::CellKey(p.x, p.z, Global::IdleReclaim::SiteCell);
        Site@ s = FindSite(key);
        if (s is null) {
            if (sites.length() >= uint(AiMax(1, Global::IdleReclaim::MaxSites))) {
                // full: replace the poorest unclaimed site
                int poorest = -1;
                for (uint i = 0; i < sites.length(); ++i)
                    if (sites[i].jobUnit < 0 && (poorest < 0 || sites[i].metal < sites[poorest].metal)) poorest = int(i);
                if (poorest < 0 || sites[poorest].metal >= metal) return;
                sites.removeAt(poorest);
            }
            @s = Site();
            s.key = key;
            s.pos = p;
            sites.insertLast(s);
            GenericHelpers::LogUtil("[IdleReclaim] site=" + key + " at " + int(p.x) + "," + int(p.z) + " from " + d.GetName(), 1);
        } else {
            // metal-weighted centre
            const float w = metal / AiMax(1.0f, s.metal + metal);
            s.pos = AIFloat3(s.pos.x + (p.x - s.pos.x) * w, s.pos.y, s.pos.z + (p.z - s.pos.z) * w);
        }
        s.metal += metal;
        s.lastAdded = ai.frame;
    }

    bool Safe(CCircuitUnit@ u, const AIFloat3 &in c)
    {
        const float r = Global::IdleReclaim::AreaRadius;
        array<float> threats = {
            aiBattle.SurfThreat(c),
            aiBattle.SurfThreat(AIFloat3(c.x + r, c.y, c.z)),
            aiBattle.SurfThreat(AIFloat3(c.x - r, c.y, c.z)),
            aiBattle.SurfThreat(AIFloat3(c.x, c.y, c.z + r)),
            aiBattle.SurfThreat(AIFloat3(c.x, c.y, c.z - r))
        };
        if (!IdleReclaimMath::AllSafe(threats, Global::IdleReclaim::MaxSurfThreat)) return false;
        return aiTerrainMgr.CanReachAtSafe(u, c, u.circuitDef.GetBuildDistance());
    }

    Job@ JobOf(int unitId)
    {
        for (uint i = 0; i < jobs.length(); ++i) if (jobs[i].unit == unitId) return jobs[i];
        return null;
    }

    // End a con's run. keepSite: the site still holds metal (timed out,
    // pre-empted, metal full or unsafe); otherwise the circle was emptied.
    void EndJob(uint i, bool keepSite, int retryAt)
    {
        Job@ j = jobs[i];
        Site@ s = FindSite(j.site);
        if (s !is null) {
            s.jobUnit = -1;
            s.retryAt = retryAt;
            if (!keepSite) DropSite(j.site);
        }
        jobs.removeAt(i);
    }

    // The con died or left: its site waits as if unsafe.
    void Release(int unitId)
    {
        for (uint i = 0; i < jobs.length(); ++i)
            if (jobs[i].unit == unitId) { EndJob(uint(i), true, ai.frame + Global::IdleReclaim::UnsafeRetrySeconds * SECOND); return; }
    }

    // Every 2 s (Economy::AiUpdateEconomy): end finished runs, abort unsafe
    // ones, expire old sites.
    void Tick()
    {
        if (ai.frame < nextTick) return;
        nextTick = ai.frame + 2 * SECOND;
        const int timeout = Global::IdleReclaim::JobTimeoutSeconds * SECOND;
        for (int i = int(jobs.length()) - 1; i >= 0; --i) {
            Job@ j = jobs[i];
            CCircuitUnit@ u = ai.GetTeamUnit(j.unit);
            if (u is null) { EndJob(uint(i), true, ai.frame); continue; }
            if (j.task is null || j.task.IsDead()) {
                // empty circle unless it ran its full time or stopped on a full bank
                const bool keep = aiEconomyMgr.isMetalFull || ai.frame - j.started >= timeout - 2 * SECOND;
                GenericHelpers::LogUtil("[IdleReclaim] done con=" + j.unit + " site=" + j.site + " after "
                    + ((ai.frame - j.started) / SECOND) + " s" + (keep ? " (site kept)" : ""), 1);
                EndJob(uint(i), keep, ai.frame);
                continue;
            }
            if (u.task !is j.task) { EndJob(uint(i), true, ai.frame); continue; }   // real work took the con
            Site@ s = FindSite(j.site);
            if (s !is null && aiBattle.SurfThreat(s.pos) > Global::IdleReclaim::MaxSurfThreat) {
                GenericHelpers::LogUtil("[IdleReclaim] abort con=" + j.unit + " site=" + j.site + ": threat "
                    + aiBattle.SurfThreat(s.pos), 1);
                IUnitTask@ t = j.task;
                EndJob(uint(i), true, ai.frame + Global::IdleReclaim::UnsafeRetrySeconds * SECOND);
                aiBuilderMgr.AbortTask(t);
            }
        }
        const int lifetime = Global::IdleReclaim::SiteLifetimeSeconds * SECOND;
        for (int i = int(sites.length()) - 1; i >= 0; --i)
            if (sites[i].jobUnit < 0 && IdleReclaimMath::Expired(ai.frame, sites[i].lastAdded, lifetime))
                sites.removeAt(i);
    }

    bool IdleTask(CCircuitUnit@ u, IUnitTask@ t)
    {
        if (t is null) return u.task is null || u.task.GetType() == int(Task::Type::IDLE);
        if (t.GetType() == int(Task::Type::WAIT) || t.GetType() == int(Task::Type::IDLE)) return true;
        IBuilderTask@ b = cast<IBuilderTask>(t);
        if (b is null) return false;
        const Task::BuildType kind = Task::BuildType(b.GetBuildType());
        const bool guard = kind == Task::BuildType::GUARD;
        const bool guardMobile = guard && b.target !is null && b.target.circuitDef !is null && b.target.circuitDef.IsMobile();
        return IdleReclaimMath::IdleWork(true, kind == Task::BuildType::PATROL, kind == Task::BuildType::WAIT, guard, guardMobile);
    }

    // From Builder::AiMakeTask after the role and native picks: an idle listed
    // con gets a wreck run instead; anything else keeps `t`.
    IUnitTask@ Offer(CCircuitUnit@ u, IUnitTask@ t)
    {
        if (!Global::IdleReclaim::Enabled || u is null || !Listed(u.circuitDef) || u.GetBuildProgress() < 1.0f) return t;
        Job@ mine = JobOf(u.id);
        if (mine !is null) {
            // its run is still live: keep it unless real work was found
            if (mine.task !is null && !mine.task.IsDead() && IdleTask(u, t)) return mine.task;
            return t;
        }
        if (!IdleTask(u, t) || aiEconomyMgr.isMetalFull
            || jobs.length() >= uint(AiMax(0, Global::IdleReclaim::MaxConcurrent)) || sites.length() == 0) return t;
        int64 retry = 0;
        if (unitRetry.get("" + u.id, retry) && ai.frame < int(retry)) return t;
        unitRetry.set("" + u.id, int64(ai.frame + Global::IdleReclaim::UnitRetrySeconds * SECOND));

        const AIFloat3 from = u.GetPos(ai.frame);
        const float maxSq = Global::IdleReclaim::MaxDistance * Global::IdleReclaim::MaxDistance;
        for (int attempt = 0; attempt < 4; ++attempt) {
            Site@ best = null;
            float bestScore = 0.0f;
            for (uint i = 0; i < sites.length(); ++i) {
                Site@ s = sites[i];
                if (s.jobUnit >= 0 || ai.frame < s.retryAt || s.metal < Global::IdleReclaim::MinSiteMetal) continue;
                const float sq = MapHelpers::SqDist(from, s.pos);
                if (sq > maxSq) continue;
                const float score = IdleReclaimMath::Score(s.metal, sqrt(sq), 600.0f);
                if (score > bestScore) { bestScore = score; @best = s; }
            }
            if (best is null) return t;
            if (!Safe(u, best.pos)) {
                best.retryAt = ai.frame + Global::IdleReclaim::UnsafeRetrySeconds * SECOND;
                continue;
            }
            IUnitTask@ run = aiBuilderMgr.Enqueue(TaskB::Reclaim(Task::Priority::LOW, best.pos, best.metal,
                Global::IdleReclaim::JobTimeoutSeconds * SECOND, Global::IdleReclaim::AreaRadius));
            if (run is null) return t;
            Job job;
            job.unit = u.id;
            job.site = best.key;
            job.started = ai.frame;
            @job.task = run;
            jobs.insertLast(job);
            best.jobUnit = u.id;
            GenericHelpers::LogUtil("[IdleReclaim] con=" + u.id + " " + u.circuitDef.GetName() + " -> site=" + best.key
                + " metal~" + int(best.metal) + " at " + int(best.pos.x) + "," + int(best.pos.z)
                + " dist=" + int(sqrt(MapHelpers::SqDist(from, best.pos))), 1);
            return run;
        }
        return t;
    }
}
