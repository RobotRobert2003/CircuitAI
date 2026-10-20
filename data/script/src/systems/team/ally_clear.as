// Ally clear (owner, 2026-10-17): TECH and AIR may reclaim an allied SMRTBARb's
// T1 porc and T1 eco that stand in their planned construction-turret blocks,
// T2 factories and spam factories. Human allies are never touched.
#include "../../define.as"
#include "../../global.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/spatial/map_helpers.as"
#include "roster.as"

/******************************************************************************

ALLY CLEAR

Scripts can only reclaim units they own, so this reuses the GeoRelease
hand-over (geo_release.as): the planner asks, the allied owner gives its own
matching buildings, the planner reclaims them as its own and keeps the metal.

  1. TECH (TechFactories::ReadyCluster) or AIR (AirLayout::Activate) is about
     to give up a planned site because it is blocked. Before relocating it
     calls Hold(key, centre, halfX, halfZ): the first call broadcasts
     allyclear|request|key|x|z|hx|hz to the allied SMRTBARbs and holds the
     site for ReplySeconds.
  2. Each allied SMRTBARb (any role) answers: its own finished or unfinished
     units of the allowed definitions whose footprint overlaps the rectangle
     are given to the requester (GiveUnits), then allyclear|grant|key|ids.
     Energy buildings stay while the owner is stalling energy.
  3. The requester's builders reclaim the given units (BuilderTask, at most two
     builders each); the site is held until they are gone or ReclaimSeconds
     pass. Then the planner's own checks decide: the site is buildable again,
     or it relocates as before.

A site is asked about once per RetrySeconds. Allowed: Global::Team::AllyClearPorc
and AllyClearEco (owner's lists, 2026-10-17).

******************************************************************************/
namespace Team {
namespace AllyClear {
    const string Prefix = "allyclear|";

    class Req {
        string key;
        AIFloat3 centre;
        int sent = -1, replyUntil = 0, reclaimUntil = 0;
        array<int> units;   // given to us, to reclaim
    }
    dictionary reqs;          // key -> Req@
    dictionary allowed;       // def name -> true
    bool allowedReady = false;
    dictionary reclaimTask;   // unit id -> IUnitTask@

    bool Enabled() { return Global::Team::AllyClearEnabled; }
    bool t3Requests = false;  // T3Unstick asked from this AI (any role)
    bool IsT3Key(const string &in key) { return key.findFirst("t3.") == 0; }
    bool IsRequester()
    {
        return Enabled() && (t3Requests || Global::AISettings::Role == AiRole::TECH || Global::AISettings::Role == AiRole::AIR);
    }
    bool Allowed(const string &in name)
    {
        if (!allowedReady) {
            for (uint i = 0; i < Global::Team::AllyClearPorc.length(); ++i) allowed.set(Global::Team::AllyClearPorc[i], true);
            for (uint i = 0; i < Global::Team::AllyClearEco.length(); ++i) allowed.set(Global::Team::AllyClearEco[i], true);
            allowedReady = true;
        }
        return allowed.exists(name);
    }
    bool IsEco(const string &in name) { return Global::Team::AllyClearEco.find(name) >= 0; }

    // ---------------------------------------------------------------- requester

    // True while the site should wait instead of relocating
    bool Hold(const string &in key, const AIFloat3 &in centre, float halfX, float halfZ)
    {
        // T3Unstick (owner, 2026-10-20): any role may ask to free a penned T3
        if (Enabled() && IsT3Key(key)) t3Requests = true;
        if (!IsRequester()) return false;
        Req@ r = null;
        if (reqs.get(key, @r) && r !is null) {
            if (ai.frame < r.replyUntil) return true;
            if (Pending(r) && ai.frame < r.reclaimUntil) return true;
            if (ai.frame - r.sent < int(Global::Team::AllyClearRetrySeconds) * SECOND) return false;
        }
        // only allied SMRTBARbs can answer; none known: nothing to wait for
        array<Team::Roster::Entry@>@ allies = Team::Roster::All();
        bool any = false;
        for (uint i = 0; i < allies.length() && !any; ++i) any = allies[i].teamId != ai.teamId;
        if (!any) return false;
        @r = Req();
        r.key = key; r.centre = centre; r.sent = ai.frame;
        r.replyUntil = ai.frame + int(Global::Team::AllyClearReplySeconds) * SECOND;
        r.reclaimUntil = r.replyUntil + int(Global::Team::AllyClearReclaimSeconds) * SECOND;
        reqs.set(key, @r);
        AiSendMessage(Prefix + "request|" + key + "|" + int(centre.x) + "|" + int(centre.z) + "|" + int(halfX) + "|" + int(halfZ));
        GenericHelpers::LogUtil("[AllyClear] asked the allied SMRTBARbs to clear " + key + " at (" + int(centre.x) + "," + int(centre.z)
            + ") " + int(halfX * 2) + "x" + int(halfZ * 2), 1);
        return true;
    }
    // True while a request made by Hold still waits for answers or reclaims (asks nothing)
    bool Busy(const string &in key)
    {
        Req@ r = null;
        if (!reqs.get(key, @r) || r is null) return false;
        return ai.frame < r.replyUntil || (Pending(r) && ai.frame < r.reclaimUntil);
    }
    bool Pending(Req@ r)
    {
        for (uint i = 0; i < r.units.length(); ++i) if (ai.GetTeamUnit(r.units[i]) !is null) return true;
        return false;
    }

    // Builder::AiMakeTask asks here: reclaim the nearest unit an ally gave us
    IUnitTask@ BuilderTask(CCircuitUnit@ u)
    {
        if (!IsRequester() || u is null || !u.circuitDef.IsMobile() || reqs.getSize() == 0) return null;
        IBuilderTask@ current = u.task is null ? null : cast<IBuilderTask>(u.task);
        if (current !is null && Task::BuildType(current.GetBuildType()) < Task::BuildType::REPAIR) return null;
        CCircuitUnit@ best = null;
        float bestSq = 1.0e30f;
        array<string>@ keys = reqs.getKeys();
        for (uint k = 0; k < keys.length(); ++k) {
            Req@ r = null;
            if (!reqs.get(keys[k], @r) || r is null) continue;
            for (uint i = 0; i < r.units.length(); ++i) {
                CCircuitUnit@ g = ai.GetTeamUnit(r.units[i]);
                if (g is null) continue;
                IUnitTask@ live = null;
                if (reclaimTask.get("" + g.id, @live) && live !is null && !live.IsDead()) {
                    if (live.GetUnits().length() < 2) return live;
                    continue;
                }
                if (!aiTerrainMgr.CanReachAt(u, g.GetPos(ai.frame), u.circuitDef.GetBuildDistance())) continue;
                const float sq = MapHelpers::SqDist(u.GetPos(ai.frame), g.GetPos(ai.frame));
                if (sq < bestSq) { bestSq = sq; @best = g; }
            }
        }
        if (best is null) return null;
        IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Reclaim(Task::Priority::HIGH, best, 60 * SECOND));
        if (t !is null) reclaimTask.set("" + best.id, @t);
        return t;
    }

    // ---------------------------------------------------------------- owner

    bool HandleMessage(const string &in message, int sender)
    {
        if (message.findFirst(Prefix) != 0) return false;
        array<string>@ f = message.split("|");
        if (f.length() < 3) return true;
        if (f[1] == "request" && f.length() >= 7) {
            if (!Enabled() || sender == ai.teamId) return true;
            Team::Roster::Entry@ who = Team::Roster::Get(sender);
            const bool t3 = IsT3Key(f[2]);   // T3Unstick: any SMRTBARb role, and its wider list (turrets, T2 flak/arty)
            if (who is null || (!t3 && who.role != AiRole::TECH && who.role != AiRole::AIR)) return true;
            const float x = float(parseInt(f[3])), z = float(parseInt(f[4]));
            const float hx = float(parseInt(f[5])), hz = float(parseInt(f[6]));
            const bool keepEnergy = aiEconomyMgr.isEnergyStalling;
            array<CCircuitUnit@> give;
            array<int> ids;
            array<Id>@ own = ai.GetOwnedUnitIds();
            for (uint i = 0; i < own.length(); ++i) {
                CCircuitUnit@ u = ai.GetTeamUnit(own[i]);
                if (u is null || u.circuitDef is null || u.circuitDef.IsMobile()) continue;
                const string name = u.circuitDef.GetName();
                if (!(Allowed(name) || (t3 && T3Unstick::Clearable(name))) || (keepEnergy && IsEco(name))) continue;
                const AIFloat3 p = u.GetPos(ai.frame);
                const float rx = float(u.circuitDef.GetFootprintX()) * SQUARE_SIZE;   // half the footprint, elmos
                const float rz = float(u.circuitDef.GetFootprintZ()) * SQUARE_SIZE;
                if (abs(p.x - x) > hx + rx || abs(p.z - z) > hz + rz) continue;
                give.insertLast(u); ids.insertLast(u.id);
            }
            if (give.length() == 0) return true;
            ai.GiveUnits(give, sender);
            string list = "";
            for (uint i = 0; i < ids.length(); ++i) list += (i > 0 ? "," : "") + ids[i];
            AiSendMessage(Prefix + "grant|" + f[2] + "|" + list, sender);
            GenericHelpers::LogUtil("[AllyClear] gave " + ids.length() + " building(s) in " + f[2] + " to "
                + Team::Roster::RoleName(who.role) + " team " + sender + " to reclaim: " + list, 1);
            return true;
        }
        if (f[1] == "grant" && f.length() >= 4) {
            Req@ r = null;
            if (!reqs.get(f[2], @r) || r is null) return true;
            array<string>@ ids = f[3].split(",");
            for (uint i = 0; i < ids.length(); ++i) {
                const int id = parseInt(ids[i]);
                if (id > 0 && r.units.find(id) < 0) r.units.insertLast(id);
            }
            GenericHelpers::LogUtil("[AllyClear] team " + sender + " gave " + ids.length() + " building(s) in " + f[2] + "; reclaiming", 1);
            return true;
        }
        return true;
    }
}  // namespace AllyClear
}  // namespace Team
