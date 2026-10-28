// Front radar (owner, 2026-10-27): more long-range radars, closer to the front.
#include "../../define.as"
#include "../../unit.as"
#include "../../task.as"
#include "../../global.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/spatial/map_helpers.as"
#include "../world/lanes.as"

/******************************************************************************

FRONT RADAR

The porc chain's long-range radar (slot 24, armarad / corarad / legarad) is
one entry of the land chain, so a defence point gets one only after about
4,600 metal (6,300 with enemy air) has gone into that point, and native puts
it in the back column, 80 elmos behind the point. The sensor step at the end
of DefaultMakeDefence never picks it: it ranks radars by area per metal, so
the T1 radar always wins. Long-range radars therefore come late, at most one
per well-funded point, and as often in the base as at the front.

This step adds radars at the front. Every 5 s (Update) we list our own
long-range radars (finished or not) and our finished mexes and guns. An
anchor's front-ness is its distance to the nearest enemy start; the anchors
within Depth of our front-most one are the front. A FRONT constructor that
can build the radar (BuilderTask) then orders one when fewer of our radars
stand at the front than the income ladder allows:

  radars  metal  energy income (10 s minimum)
  1        60    1200
  2       100    2000
  3       150    3000
  4       220    4500

The site is the front-most anchor whose spot, Back elmos behind it toward our
start, has no long-range radar within Spacing (ours, the live order's, or one
an allied SMRTBARb reported), is not under enemy surface threat above
MaxThreat and is reachable. Radars of the porc chain count like any other, so
a front point that already has its chain radar is not doubled. One order
lives at a time, joined by at most one more constructor; an order that dies
with no radar near its site blocks that site for FailSeconds. The native task
timeout counts from the task's last touch, which each joining builder renews,
so an order still alive OrderSeconds after it was placed with no radar frame
near its site is aborted here and its site blocked for FailSeconds; one with
a frame is left to finish. A radar (or frame) of ours that was there at the
last scan and is gone at this one (tracked by unit id) was lost: its spot is
blocked for LostSeconds, doubled for each earlier loss within Spacing/2 of it
(capped at LostMaxSeconds), so the count drops and the next radar goes to the
next front anchor instead of the spot that keeps dying. When the front moves
on, radars left behind stop counting and new ones go up at the new front.

Every AI with the step on (any role) sends its radar list to the allies at
least every BroadcastSeconds and whenever it changes (frontradar|have|x,z;..),
so two FRONTs do not put radars side by side. Settings: Global::FrontRadar.

Cost: the scan walks our own units once per 5 s (one def comparison each);
BuilderTask returns at the first guard for every builder that cannot build
the radar, and otherwise loops over the front anchors (a few dozen at most);
a loop that finds no site holds every builder off for 5 s.

GHOST RADARS (owner, 2026-10-27)

The FRONT commander's "radar_ghost" ladder rung (commander.json front_ladder,
right after "radar") puts a T1 radar (armrad / corrad / legrad) where it
reaches the last-known images of enemy structures that neither our team's
radar nor LOS covers now (CBattleAnalysis ghosts: identified, static, out of
radar and LOS, spot not seen empty). So scouted enemy porc and mexes stay on
radar, and artillery on the ranged controller (Mauser, Quaker, Tremor,
Astraeus) can shell them from max range instead of walking in for vision.

An image counts as reached when it lies within GhostCoverage x the T1 radar's
range of one of our T1 radars (or GhostCoverage x the long-range radar's range
of one of those), finished or a frame, of our live order, or of an allied
SMRTBARb's ghost order of the last GhostAllySeconds (frontradar|ghost|x,z): a
jammed or terrain-hidden image is not chased with a second radar. For each
unreached image within reach + GhostTravel of the commander the site is the
nearest point to the commander that reaches it (the commander's own spot when
it already does); sites under enemy surface threat above GhostMaxThreat,
unreachable ones and ones near a failed order are skipped, and the site that
reaches the most unreached images wins (ties: the shorter walk). One order at
a time per AI, the commander that placed it keeps it, at most one order per
GhostIntervalSeconds; an order that dies with no radar near its site blocks
that spot for GhostFailSeconds. Cost per ladder offer: one pass over the
ghost list, then O(k^2) over the k unreached images near the commander
(capped at GhostMaxCandidates); a pass that finds nothing holds the rung off
for 5 s.

******************************************************************************/
namespace FrontRadar {
    const string PREFIX = "frontradar|have|";
    const string GHOST_PREFIX = "frontradar|ghost|";

    class AllyRadars {
        array<AIFloat3> at;
        int frame = 0;
    }
    dictionary allies;               // sender team id -> AllyRadars@
    array<AIFloat3> ours;            // our long-range radars, finished or not (last scan)
    array<Id> oursIds;               // their unit ids, same order (a radar gone at the next scan was lost)
    array<AIFloat3> lostSpots;       // spots where one of our radars died, with the loss count there
    array<int> lostCount;
    int orderFrame = -1;             // when the live order was placed
    array<AIFloat3> anchors;         // front anchors, nearest the enemy first (last scan)
    float frontDist = -1.0f;         // our front-most anchor's distance to the nearest enemy start
    int frontCount = 0;              // our radars within the front band (last scan)
    array<AIFloat3> enemyStarts;
    array<AIFloat3> failed;
    array<int> failedUntil;
    IUnitTask@ order;
    AIFloat3 orderSite(-1.0f, 0.0f, -1.0f);
    int lastScan = -100000, lastReport = -100000, lastBroadcast = -100000;
    string lastSent = "";
    int idleUntil = -1;              // no site was found: builders stop asking until then
    // Ghost radars (owner, 2026-10-27)
    array<AIFloat3> oursT1;          // our T1 radars, finished or not (last scan)
    IUnitTask@ ghostOrder;
    AIFloat3 ghostSite(-1.0f, 0.0f, -1.0f);
    int ghostOwner = -1;             // the commander that placed the live ghost order
    int ghostFrame = -1;             // when the live ghost order was placed
    int ghostNext = 0;               // no new ghost order before this frame
    int ghostOpen = 0;               // unreached images near the last asking commander
    array<AIFloat3> ghostFailed;
    array<int> ghostFailedUntil;
    array<AIFloat3> allyGhost;       // allied SMRTBARb ghost orders, with the frame they arrived
    array<int> allyGhostFrame;

    bool Enabled() { return Global::FrontRadar::Enabled; }
    bool GhostEnabled() { return Global::FrontRadar::GhostEnabled; }
    bool Orders()
    {
        return Enabled() && (!Global::FrontRadar::FrontRoleOnly || Global::AISettings::Role == AiRole::FRONT);
    }

    // Looked up on every call, never cached: the first scans run before
    // Global::AISettings::Side is set, when the name falls back to armarad.
    CCircuitDef@ RadarDef()
    {
        return ai.GetCircuitDef(UnitHelpers::GetStaticT2RadarNameForSide(Global::AISettings::Side));
    }

    // Pure: how many front radars the incomes allow
    int Wanted(float mi, float ei)
    {
        const int steps = AiMin(int(Global::FrontRadar::Metal.length()), int(Global::FrontRadar::Energy.length()));
        int n = 0;
        while (n < steps && mi >= Global::FrontRadar::Metal[n] && ei >= Global::FrontRadar::Energy[n]) ++n;
        return n;
    }

    // Distance to the nearest enemy start, -1 without any
    float EnemyDist(const AIFloat3 &in p)
    {
        float best = -1.0f;
        for (uint i = 0; i < enemyStarts.length(); ++i) {
            const float d = MapHelpers::SqDist(p, enemyStarts[i]);
            if (best < 0.0f || d < best) best = d;
        }
        return (best < 0.0f) ? -1.0f : sqrt(best);
    }

    // Pure: Back elmos behind the anchor, toward our start
    AIFloat3 Site(const AIFloat3 &in anchor, const AIFloat3 &in home, float back)
    {
        const float dx = home.x - anchor.x, dz = home.z - anchor.z;
        const float len = sqrt(dx * dx + dz * dz);
        if (len < 1.0f) return anchor;
        const float b = AiMin(back, len);
        return AIFloat3(anchor.x + dx / len * b, 0.0f, anchor.z + dz / len * b);
    }

    bool Near(const array<AIFloat3> &in list, const AIFloat3 &in p, float r)
    {
        const float r2 = r * r;
        for (uint i = 0; i < list.length(); ++i)
            if (MapHelpers::SqDist(list[i], p) <= r2) return true;
        return false;
    }

    // Any long-range radar (ours, the live order's, or an ally's) within Spacing of the site
    bool Covered(const AIFloat3 &in site)
    {
        const float r = Global::FrontRadar::Spacing;
        if (Near(ours, site, r)) return true;
        if (order !is null && !order.IsDead() && MapHelpers::SqDist(orderSite, site) <= r * r) return true;
        const int stale = 3 * AiMax(1, Global::FrontRadar::BroadcastSeconds) * SECOND;
        array<string>@ keys = allies.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            AllyRadars@ a;
            if (!allies.get(keys[i], @a) || a is null || ai.frame - a.frame > stale) continue;
            if (Near(a.at, site, r)) return true;
        }
        return false;
    }

    bool Failed(const AIFloat3 &in site)
    {
        const float r2 = Global::FrontRadar::Spacing * Global::FrontRadar::Spacing * 0.25f;
        for (uint i = 0; i < failed.length(); ++i)
            if (ai.frame < failedUntil[i] && MapHelpers::SqDist(failed[i], site) <= r2) return true;
        return false;
    }

    void Block(const AIFloat3 &in site, int seconds)
    {
        failed.insertLast(site);
        failedUntil.insertLast(ai.frame + seconds * SECOND);
    }

    // One of our radars (finished or a frame) was there at the last scan and is gone:
    // its spot is skipped LostSeconds, doubled for each earlier loss within Spacing/2
    void Lost(const AIFloat3 &in at)
    {
        const float r2 = Global::FrontRadar::Spacing * Global::FrontRadar::Spacing * 0.25f;
        int k = -1;
        for (uint i = 0; i < lostSpots.length(); ++i)
            if (MapHelpers::SqDist(lostSpots[i], at) <= r2) { k = int(i); break; }
        if (k < 0) { lostSpots.insertLast(at); lostCount.insertLast(0); k = int(lostSpots.length()) - 1; }
        int seconds = Global::FrontRadar::LostSeconds;
        for (int n = 0; n < lostCount[k] && seconds < Global::FrontRadar::LostMaxSeconds; ++n) seconds *= 2;
        seconds = AiMin(seconds, Global::FrontRadar::LostMaxSeconds);
        ++lostCount[k];
        Block(at, seconds);
        GenericHelpers::LogUtil("[FrontRadar] radar at (" + int(at.x) + "," + int(at.z) + ") lost; site skipped " + seconds + " s", 1);
    }

    // Our radars and the front anchors, from our own units
    void Scan()
    {
        const CCircuitDef@ rd = RadarDef();
        const int radarDefId = (rd is null) ? -1 : int(rd.id);
        const CCircuitDef@ rd1 = ai.GetCircuitDef(UnitHelpers::GetStaticRadarNameForSide(Global::AISettings::Side));
        const int radarT1Id = (rd1 is null) ? -1 : int(rd1.id);
        array<AIFloat3> radarsT1;
        array<AIFloat3> radars;
        array<Id> radarIds;
        array<AIFloat3> cand;
        array<float> candDist;
        float best = -1.0f;
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null) continue;
            const CCircuitDef@ d = u.circuitDef;
            if (d is null || d.IsMobile()) continue;
            if (int(d.id) == radarDefId) { radars.insertLast(u.GetPos(ai.frame)); radarIds.insertLast(u.id); continue; }
            if (int(d.id) == radarT1Id) { radarsT1.insertLast(u.GetPos(ai.frame)); continue; }
            if (u.GetBuildProgress() < 1.0f) continue;
            if (d.GetExtractsMetal() <= 0.0f && d.GetMaxRange() <= 0.0f) continue;
            const AIFloat3 p = u.GetPos(ai.frame);
            const float dist = EnemyDist(p);
            if (dist < 0.0f) continue;
            cand.insertLast(p);
            candDist.insertLast(dist);
            if (best < 0.0f || dist < best) best = dist;
        }
        for (uint i = 0; i < oursIds.length(); ++i)
            if (radarIds.find(oursIds[i]) < 0) Lost(ours[i]);
        ours = radars;
        oursIds = radarIds;
        oursT1 = radarsT1;
        frontDist = best;
        anchors.resize(0);
        frontCount = 0;
        if (best < 0.0f) return;
        // the front band, nearest the enemy first (insertion sort: a few dozen at most)
        array<float> dists;
        const float limit = best + Global::FrontRadar::Depth;
        for (uint i = 0; i < cand.length(); ++i) {
            if (candDist[i] > limit) continue;
            uint k = anchors.length();
            anchors.insertLast(cand[i]);
            dists.insertLast(candDist[i]);
            while (k > 0 && dists[k - 1] > dists[k]) {
                const float t = dists[k - 1]; dists[k - 1] = dists[k]; dists[k] = t;
                const AIFloat3 q = anchors[k - 1]; anchors[k - 1] = anchors[k]; anchors[k] = q;
                --k;
            }
        }
        const float radarLimit = limit + Global::FrontRadar::Back + 200.0f;
        for (uint i = 0; i < ours.length(); ++i) {
            const float dist = EnemyDist(ours[i]);
            if (dist >= 0.0f && dist <= radarLimit) ++frontCount;
        }
    }

    void Broadcast()
    {
        string body = "";
        for (uint i = 0; i < ours.length(); ++i)
            body += (i == 0 ? "" : ";") + int(ours[i].x) + "," + int(ours[i].z);
        if (order !is null && !order.IsDead())
            body += (body == "" ? "" : ";") + int(orderSite.x) + "," + int(orderSite.z);
        if (body == lastSent && ai.frame - lastBroadcast < Global::FrontRadar::BroadcastSeconds * SECOND) return;
        lastSent = body;
        lastBroadcast = ai.frame;
        AiSendMessage(PREFIX + body);
    }

    // Team::HandleMessage: an allied SMRTBARb's radar list
    bool HandleMessage(const string &in msg, int fromTeamId)
    {
        if (msg.findFirst(GHOST_PREFIX) == 0) {
            array<string>@ xz = msg.substr(GHOST_PREFIX.length()).split(",");
            if (xz.length() == 2) {
                allyGhost.insertLast(AIFloat3(float(parseInt(xz[0])), 0.0f, float(parseInt(xz[1]))));
                allyGhostFrame.insertLast(ai.frame);
            }
            return true;
        }
        if (msg.findFirst(PREFIX) != 0) return false;
        AllyRadars@ a = AllyRadars();
        a.frame = ai.frame;
        const string body = msg.substr(PREFIX.length());
        if (body.length() > 0) {
            array<string>@ items = body.split(";");
            for (uint i = 0; i < items.length(); ++i) {
                array<string>@ xz = items[i].split(",");
                if (xz.length() != 2) continue;
                a.at.insertLast(AIFloat3(float(parseInt(xz[0])), 0.0f, float(parseInt(xz[1]))));
            }
        }
        allies.set("" + fromTeamId, @a);
        return true;
    }

    // Main::AiUpdate, every 30 frames; the work runs every 5 s
    void Update()
    {
        if (!Enabled() && !Global::FrontRadar::Report && !GhostEnabled()) return;
        if (ai.frame - lastScan < 5 * SECOND) return;
        lastScan = ai.frame;
        if (enemyStarts.length() == 0) enemyStarts = Lanes::EnemyStarts();
        Scan();
        if (order !is null && order.IsDead()) {
            if (!Near(ours, orderSite, 600.0f)) {
                Block(orderSite, Global::FrontRadar::FailSeconds);
                GenericHelpers::LogUtil("[FrontRadar] order at (" + int(orderSite.x) + "," + int(orderSite.z) + ") died with no radar; site skipped "
                    + Global::FrontRadar::FailSeconds + " s", 1);
            }
            @order = null;
        } else if (order !is null && ai.frame - orderFrame >= Global::FrontRadar::OrderSeconds * SECOND) {
            // The native timeout counts from the task's last touch, which every joining
            // builder renews, so an order that never starts its frame can live for ever.
            IBuilderTask@ bt = cast<IBuilderTask>(order);
            if ((bt is null || bt.target is null) && !Near(ours, orderSite, 600.0f)) {
                aiBuilderMgr.AbortTask(order);
                @order = null;
                Block(orderSite, Global::FrontRadar::FailSeconds);
                GenericHelpers::LogUtil("[FrontRadar] order at (" + int(orderSite.x) + "," + int(orderSite.z) + ") aborted: no radar frame after "
                    + Global::FrontRadar::OrderSeconds + " s; site skipped " + Global::FrontRadar::FailSeconds + " s", 1);
            }
        }
        for (int i = int(failed.length()) - 1; i >= 0; --i) {
            if (ai.frame < failedUntil[i]) continue;
            failed.removeAt(i);
            failedUntil.removeAt(i);
        }
        GhostUpdate();
        if (Enabled()) Broadcast();
        if (ai.frame - lastReport >= Global::FrontRadar::ReportSeconds * SECOND) {
            lastReport = ai.frame;
            GenericHelpers::LogUtil("[FrontRadar] census: " + ours.length() + " long-range radars, " + frontCount + " at the front (front "
                + int(frontDist) + " from the enemy, " + anchors.length() + " anchors); wanted "
                + Wanted(Economy::GetMinMetalIncomeLast10s(), Economy::GetMinEnergyIncomeLast10s())
                + (Orders() ? "" : " (not ordering)"), 1);
            if (GhostEnabled())
                GenericHelpers::LogUtil("[FrontRadar] ghosts: " + aiBattle.GetGhostCount() + " enemy structure images out of radar, "
                    + oursT1.length() + " T1 radars of ours, " + ghostOpen + " unreached near the commander at its last ask", 1);
        }
    }

    // Ghost radars: an image already in reach of one of our radars (finished or a
    // frame), of our live order or of an ally's recent order
    bool GhostReached(const AIFloat3 &in g)
    {
        const float r1 = Global::FrontRadar::GhostRadarRange * Global::FrontRadar::GhostCoverage;
        if (Near(oursT1, g, r1)) return true;
        if (Near(ours, g, Global::FrontRadar::GhostT2RadarRange * Global::FrontRadar::GhostCoverage)) return true;
        if (ghostOrder !is null && !ghostOrder.IsDead() && MapHelpers::SqDist(ghostSite, g) <= r1 * r1) return true;
        return Near(allyGhost, g, r1);
    }

    bool GhostFailed(const AIFloat3 &in site)
    {
        const float r = Global::FrontRadar::GhostFailRadius;
        for (uint i = 0; i < ghostFailed.length(); ++i)
            if (ai.frame < ghostFailedUntil[i] && MapHelpers::SqDist(ghostFailed[i], site) <= r * r) return true;
        return false;
    }

    // Update, after the scan: a dead order with no radar near its site blocks the spot
    void GhostUpdate()
    {
        if (ghostOrder !is null && ghostOrder.IsDead()) {
            if (!Near(oursT1, ghostSite, 400.0f)) {
                ghostFailed.insertLast(ghostSite);
                ghostFailedUntil.insertLast(ai.frame + Global::FrontRadar::GhostFailSeconds * SECOND);
                GenericHelpers::LogUtil("[FrontRadar] ghost radar order at (" + int(ghostSite.x) + "," + int(ghostSite.z)
                    + ") died with no radar; spot skipped " + Global::FrontRadar::GhostFailSeconds + " s", 1);
            }
            @ghostOrder = null;
            ghostOwner = -1;
        } else if (ghostOrder !is null && ai.frame - ghostFrame >= Global::FrontRadar::GhostOrderSeconds * SECOND) {
            // The native timeout counts from the last touch, which the owner renews
            // on every ask (GhostKeep): an order whose frame never starts is aborted here.
            IBuilderTask@ bt = cast<IBuilderTask>(ghostOrder);
            if ((bt is null || bt.target is null) && !Near(oursT1, ghostSite, 400.0f)) {
                aiBuilderMgr.AbortTask(ghostOrder);
                @ghostOrder = null;
                ghostOwner = -1;
                ghostFailed.insertLast(ghostSite);
                ghostFailedUntil.insertLast(ai.frame + Global::FrontRadar::GhostFailSeconds * SECOND);
                GenericHelpers::LogUtil("[FrontRadar] ghost radar order at (" + int(ghostSite.x) + "," + int(ghostSite.z)
                    + ") aborted: no radar frame after " + Global::FrontRadar::GhostOrderSeconds + " s; spot skipped "
                    + Global::FrontRadar::GhostFailSeconds + " s", 1);
            }
        }
        for (int i = int(ghostFailed.length()) - 1; i >= 0; --i) {
            if (ai.frame < ghostFailedUntil[i]) continue;
            ghostFailed.removeAt(i);
            ghostFailedUntil.removeAt(i);
        }
        const int stale = Global::FrontRadar::GhostAllySeconds * SECOND;
        for (int i = int(allyGhost.length()) - 1; i >= 0; --i) {
            if (ai.frame - allyGhostFrame[i] <= stale) continue;
            allyGhost.removeAt(i);
            allyGhostFrame.removeAt(i);
        }
    }

    // CommanderFront::Work asks this before its ladder: the commander that placed the
    // live ghost order keeps it until the order ends. Played 2026-10-28 (All That
    // Glitters, 2 games): 30 orders, 32 "died with no radar" - an earlier rung (mex,
    // line turret, repair, reclaim) handed the walking commander other work and the
    // abandoned order timed out.
    IUnitTask@ GhostKeep(CCircuitUnit@ u)
    {
        if (!GhostEnabled() || u is null || ghostOrder is null || ghostOrder.IsDead() || int(u.id) != ghostOwner) return null;
        return ghostOrder;
    }

    // CommanderFront "radar_ghost" rung: a T1 radar that reaches scouted enemy
    // structures our radar does not cover
    IUnitTask@ GhostTask(CCircuitUnit@ u)
    {
        if (!GhostEnabled() || u is null || u.circuitDef is null) return null;
        if (ghostOrder !is null && !ghostOrder.IsDead()) return (int(u.id) == ghostOwner) ? ghostOrder : null;
        if (ai.frame < ghostNext) return null;
        CCircuitDef@ rd = ai.GetCircuitDef(UnitHelpers::GetStaticRadarNameForSide(UnitHelpers::GetSideForUnitName(u.circuitDef.GetName())));
        if (rd is null || !u.circuitDef.CanBuild(rd) || !rd.IsAvailable(ai.frame)) return null;
        if (aiEconomyMgr.metal.current < rd.costM * 0.5f) return null;
        const AIFloat3 pos = u.GetPos(ai.frame);
        const float reach = Global::FrontRadar::GhostRadarRange * Global::FrontRadar::GhostCoverage;
        const float scan = reach + Global::FrontRadar::GhostTravel;
        array<AIFloat3> open;
        const int n = aiBattle.GetGhostCount();
        for (int i = 0; i < n && int(open.length()) < Global::FrontRadar::GhostMaxCandidates; ++i) {
            const AIFloat3 g = aiBattle.GetGhostPos(i);
            if (MapHelpers::SqDist(pos, g) > scan * scan || GhostReached(g)) continue;
            open.insertLast(g);
        }
        ghostOpen = int(open.length());
        int bestCount = 0;
        float bestWalk = 0.0f;
        AIFloat3 best;
        const float m = 64.0f;
        for (uint i = 0; i < open.length(); ++i) {
            const float d = sqrt(MapHelpers::SqDist(pos, open[i]));
            const float t = (d <= reach) ? 0.0f : (d - reach * 0.98f) / d;   // 2% inside, so rounding keeps the image reached
            const AIFloat3 site(AiMax(m, AiMin(float(AiTerrainWidth()) - m, pos.x + (open[i].x - pos.x) * t)), 0.0f,
                AiMax(m, AiMin(float(AiTerrainHeight()) - m, pos.z + (open[i].z - pos.z) * t)));
            int count = 0;
            for (uint k = 0; k < open.length(); ++k)
                if (MapHelpers::SqDist(site, open[k]) <= reach * reach) ++count;
            const float walk = sqrt(MapHelpers::SqDist(pos, site));
            if (count < bestCount || (count == bestCount && walk >= bestWalk)) continue;
            if (GhostFailed(site) || aiBattle.SurfThreat(site) > Global::FrontRadar::GhostMaxThreat) continue;
            if (!aiTerrainMgr.CanReachAt(u, site, u.circuitDef.GetBuildDistance())) continue;
            bestCount = count; bestWalk = walk; best = site;
        }
        if (bestCount == 0) { ghostNext = ai.frame + 5 * SECOND; return null; }
        @ghostOrder = aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::DEFENCE, Task::Priority::NORMAL, rd, best,
            Global::FrontRadar::GhostShake, true, Global::FrontRadar::GhostOrderSeconds * SECOND));
        if (ghostOrder is null) { ghostNext = ai.frame + 5 * SECOND; return null; }
        ghostSite = best;
        ghostOwner = int(u.id);
        ghostFrame = ai.frame;
        ghostNext = ai.frame + Global::FrontRadar::GhostIntervalSeconds * SECOND;
        AiSendMessage(GHOST_PREFIX + int(best.x) + "," + int(best.z));
        GenericHelpers::LogUtil("[FrontRadar] commander " + u.circuitDef.GetName() + " " + u.id + " orders ghost radar " + rd.GetName()
            + " at (" + int(best.x) + "," + int(best.z) + "), walk " + int(bestWalk) + ", reaches " + bestCount + " of " + open.length()
            + " unreached enemy structure images (" + n + " out of radar)", 1);
        return ghostOrder;
    }

    // Builder::AiMakeTask asks here after EdgePorc
    IUnitTask@ BuilderTask(CCircuitUnit@ u)
    {
        if (!Orders() || u is null || !u.circuitDef.IsMobile() || UnitHelpers::IsCommander(u.circuitDef)) return null;
        CCircuitDef@ rd = RadarDef();
        if (rd is null || !u.circuitDef.CanBuild(rd)) return null;
        IBuilderTask@ current = u.task is null ? null : cast<IBuilderTask>(u.task);
        if (current !is null && Task::BuildType(current.GetBuildType()) < Task::BuildType::REPAIR) return null;
        if (order !is null && !order.IsDead()) {
            if (order.GetUnits().length() < 2 && aiTerrainMgr.CanReachAt(u, orderSite, u.circuitDef.GetBuildDistance())) return order;
            return null;
        }
        if (anchors.length() == 0) return null;
        const float mi = Economy::GetMinMetalIncomeLast10s();
        const float ei = Economy::GetMinEnergyIncomeLast10s();
        const int want = Wanted(mi, ei);
        if (frontCount >= want || !rd.IsAvailable(ai.frame) || ai.frame < idleUntil) return null;
        const AIFloat3 home = Global::Map::StartPos;
        for (uint i = 0; i < anchors.length(); ++i) {
            const AIFloat3 site = Site(anchors[i], home, Global::FrontRadar::Back);
            if (Covered(site) || Failed(site)) continue;
            if (aiBattle.SurfThreat(site) > Global::FrontRadar::MaxThreat) continue;
            if (!aiTerrainMgr.CanReachAt(u, site, u.circuitDef.GetBuildDistance())) continue;
            @order = aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::DEFENCE, Task::Priority::NORMAL, rd, site,
                Global::FrontRadar::Shake, true, Global::FrontRadar::OrderSeconds * SECOND));
            if (order is null) return null;
            orderSite = site;
            orderFrame = ai.frame;
            GenericHelpers::LogUtil("[FrontRadar] " + u.circuitDef.GetName() + " " + u.id + " orders " + rd.GetName() + " " + (frontCount + 1)
                + " of " + want + " at (" + int(site.x) + "," + int(site.z) + "), " + int(EnemyDist(site)) + " from the enemy (front "
                + int(frontDist) + ", anchor " + int(EnemyDist(anchors[i])) + "; mi=" + int(mi) + " ei=" + int(ei) + ")", 1);
            Broadcast();
            return order;
        }
        idleUntil = ai.frame + 5 * SECOND;   // every front site covered, hot or out of reach: re-checked after the next scan
        return null;
    }
}  // namespace FrontRadar
