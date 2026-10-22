// Lanes between both teams' start positions (D-127): doc/roles/tech-lanes.md.
#include "../../define.as"
#include "../../global.as"
#include "../../helpers/common/generic_helpers.as"
#include "../presentation/commands.as"
#include "../construction/layout.as"
#include "../combat/spam.as"
#include "../team/team.as"
#include "water_theatres.as"
#include "strategic_sites.as"
#include "../diagnostics/invariants.as"

/******************************************************************************

LANES (D-127)

The owner's request: at game start, from both teams' start positions, find the
lanes between them and tell apart what can use each: land (tanks and bots),
bot-only, amphibious, hover, all-terrain (the slopes only spiders and
all-terrain bots climb, often the map edges), naval, and air (routes around
enemy AA). The integrated control panel selects a player/all and owns visibility;
cached, and recalculated as the front moves; TECH plans attacks on them.

The analysis is native (aiBattle.AnalyseLanes, src/circuit/terrain/BattleLanes.cpp):
the engine's slope map against each BAR movedef class's slope and depth limits,
diverse paths (each pass penalises the last), merged into lanes, each kept
under the least capable class that can use it.

Only TECH under the experimental build runs it for now; nothing here is
TECH-specific, so another role may call Tick later.

******************************************************************************/
namespace Lanes {

    const int LAND = 0, BOT = 1, AMPH = 2, HOVER = 3, ALLTERRAIN = 4, NAVAL = 5, AIR = 6;
    const array<string> NAMES = {"LAND", "BOT", "AMPHIBIOUS", "HOVER", "ALL-TERRAIN", "NAVAL", "AIR"};

    bool loaded = false;
    bool background = true;
    int staggerSeconds = 2;
    int observedRevision = 0, requestFrame = -1, nextPanelFrame = -1;
    bool waiting = false;
    string pendingWhy;
    array<AIFloat3> pendingOurs, pendingTheirs;
    AIFloat3 pendingFront;

    float specialistMinSpan = 1024.0f, specialistSpanFraction = 0.45f;
    float specialistBias = 3.0f;
    float teachingChokeWidth = 900.0f;
    float highGroundRise = 128.0f;
    float highGroundDetour = 4.0f;
    int highGroundRoutes = 3;
    int cliffApproachClass = BOT;
    float cliffDescentDrop = 256.0f, cliffDescentRun = 1600.0f, cliffDescentProgress = 0.9f;
    float mountainGradeWeight = 8.0f, mountainPeakTolerance = 256.0f;
    float mountainSurfaceWeight = 12.0f, mountainHeightWeight = 4.0f;
    float cliffPreference = 8.0f, cliffQualityTolerance = 0.1f, cliffHeightFraction = 0.5f;
    void LoadSettings()
    {
        if (loaded) return;
        loaded = true;
        background = aiSetupMgr.ConfigBool("lanes/background", true);
        staggerSeconds = AiMax(0, AiMin(10, aiSetupMgr.ConfigInt("lanes/stagger_seconds", 2)));

        CCircuitDef@ flak = ai.GetCircuitDef("armflak");
        if (flak !is null && flak.GetAirThreat() <= 0.0f) Invariants::Violation("INV-064", "air-threat", "BAR flak must contribute anti-air threat to tactical routing");
        specialistMinSpan = aiSetupMgr.ConfigFloat("lanes/specialist_min_span", specialistMinSpan);
        specialistSpanFraction = aiSetupMgr.ConfigFloat("lanes/specialist_span_fraction", specialistSpanFraction);
        specialistBias = aiSetupMgr.ConfigFloat("lanes/specialist_bias", specialistBias);
        teachingChokeWidth = aiSetupMgr.ConfigFloat("lanes/teaching_choke_width", teachingChokeWidth);
        highGroundRise = aiSetupMgr.ConfigFloat("lanes/high_ground_rise", highGroundRise);
        highGroundDetour = aiSetupMgr.ConfigFloat("lanes/high_ground_detour", highGroundDetour);
        highGroundRoutes = aiSetupMgr.ConfigInt("lanes/high_ground_routes", highGroundRoutes);
        cliffApproachClass = aiSetupMgr.ConfigInt("lanes/cliff_approach_class", cliffApproachClass);
        cliffDescentDrop = aiSetupMgr.ConfigFloat("lanes/cliff_descent_drop", cliffDescentDrop);
        cliffDescentRun = aiSetupMgr.ConfigFloat("lanes/cliff_descent_run", cliffDescentRun);
        cliffDescentProgress = aiSetupMgr.ConfigFloat("lanes/cliff_descent_progress", cliffDescentProgress);
        mountainGradeWeight = aiSetupMgr.ConfigFloat("lanes/mountain_grade_weight", mountainGradeWeight);
        mountainPeakTolerance = aiSetupMgr.ConfigFloat("lanes/mountain_peak_tolerance", mountainPeakTolerance);
        mountainSurfaceWeight = aiSetupMgr.ConfigFloat("lanes/mountain_surface_weight", mountainSurfaceWeight);
        mountainHeightWeight = aiSetupMgr.ConfigFloat("lanes/mountain_height_weight", mountainHeightWeight);
        cliffPreference = aiSetupMgr.ConfigFloat("lanes/cliff_preference", cliffPreference);
        cliffQualityTolerance = aiSetupMgr.ConfigFloat("lanes/cliff_quality_tolerance", cliffQualityTolerance);
        cliffHeightFraction = aiSetupMgr.ConfigFloat("lanes/cliff_height_fraction", cliffHeightFraction);
        Global::RoleSettings::Tech::LanesEnabled = aiSetupMgr.ConfigBool("lanes/enabled", Global::RoleSettings::Tech::LanesEnabled);
        Global::RoleSettings::Tech::LaneAlternatives = aiSetupMgr.ConfigInt("lanes/alternatives", Global::RoleSettings::Tech::LaneAlternatives);
        Global::RoleSettings::Tech::LaneMergeRadius = aiSetupMgr.ConfigFloat("lanes/merge_radius", Global::RoleSettings::Tech::LaneMergeRadius);
        Global::RoleSettings::Tech::LaneThreatWeight = aiSetupMgr.ConfigFloat("lanes/threat_weight", Global::RoleSettings::Tech::LaneThreatWeight);
        Global::RoleSettings::Tech::LaneRecalcSeconds = aiSetupMgr.ConfigFloat("lanes/recalc_seconds", Global::RoleSettings::Tech::LaneRecalcSeconds);
        Global::RoleSettings::Tech::LaneRecalcShift = aiSetupMgr.ConfigFloat("lanes/recalc_shift", Global::RoleSettings::Tech::LaneRecalcShift);
        Global::RoleSettings::Tech::LaneRecalcMinSeconds = aiSetupMgr.ConfigFloat("lanes/recalc_min_seconds", Global::RoleSettings::Tech::LaneRecalcMinSeconds);
        Global::RoleSettings::Tech::LaneDrawSeconds = aiSetupMgr.ConfigInt("lanes/draw_seconds", Global::RoleSettings::Tech::LaneDrawSeconds);
    }

    bool Enabled()
    {
        return Global::RoleSettings::Tech::LanesEnabled
            && ((Global::RoleSettings::Tech::ExperimentalBuild && Global::AISettings::Role == AiRole::TECH)
            || (Global::RoleSettings::Air::ExperimentalBuild && Global::AISettings::Role == AiRole::AIR));
    }

    int calcs = 0;
    int lastCalc = -100000;
    AIFloat3 lastFront(-1.0f, 0.0f, -1.0f);

    array<AIFloat3> AllyStarts()
    {
        array<AIFloat3> scripted = ScriptStarts(false);
        if (scripted.length() > 0) return scripted;
        array<AIFloat3> r = {Global::Map::StartPos};
        StartSpot@[]@ spots = Global::Map::Config.StartSpots;
        if (spots is null) return r;
        array<Team::Roster::Entry@>@ allies = Team::Roster::All();
        for (uint i = 0; i < allies.length(); ++i) {
            const int s = allies[i].spotIndex;
            if (s < 0 || s >= int(spots.length())) continue;
            if (spots[s].pos.distance2D(Global::Map::StartPos) < 64.0f) continue;
            r.insertLast(spots[s].pos);
        }
        return r;
    }

    // the enemy's starts: map start spots inside an enemy ally team's start box
    // (the lobby's boxes); without boxes, every spot neither ours nor an ally's
    // (Spam::EnemyStartSpots: on a 16-spot map in a 1v1 that is 15 spots)
    // first choice: the start script's playing teams (fixed starts, or chosen before the game)
    array<AIFloat3> ScriptStarts(bool enemy)
    {
        array<AIFloat3> r;
        for (int i = 0; i < aiSetupMgr.GetScriptStartCount(); ++i)
            if (aiSetupMgr.IsScriptStartEnemy(i) == enemy) r.insertLast(aiSetupMgr.GetScriptStart(i));
        return r;
    }
    array<AIFloat3> EnemyStarts()
    {
        array<AIFloat3> scripted = ScriptStarts(true);
        if (scripted.length() > 0) return scripted;
        array<AIFloat3> all = Spam::EnemyStartSpots();
        array<AIFloat3> boxed;
        bool known = false;
        for (uint i = 0; i < all.length(); ++i) {
            const int b = aiSetupMgr.EnemyStartBoxAt(all[i]);
            if (b >= 0) known = true;
            if (b == 1) boxed.insertLast(all[i]);
        }
        return (known && boxed.length() > 0) ? boxed : all;
    }

    AIFloat3 Front()
    {
        AIFloat3 z = aiBattle.CombatNear(Global::Map::StartPos, Global::RoleSettings::Tech::WeaponCombatMinHeat);
        return (z.x < 0.0f) ? Layout::FrontTarget() : z;
    }

    void Compute(const string &in why)
    {
        if (waiting || aiBattle.IsLanePending()) return;
        array<AIFloat3> ours = AllyStarts();
        array<AIFloat3> theirs = EnemyStarts();
        if (theirs.length() == 0) Invariants::Violation("INV-063", "lane-starts", "tactical survey has no enemy destinations");
        aiBattle.ClearLaneEnds();
        // Per-player lanes originate at this AI; territory uses all allied starts.
        aiBattle.AddAllyEnd(Global::Map::StartPos);
        for (uint i = 0; i < theirs.length(); ++i) aiBattle.AddEnemyEnd(theirs[i]);
        // the first calculation is terrain only; later ones weigh the threat seen
        const float w = (calcs == 0) ? 0.0f : Global::RoleSettings::Tech::LaneThreatWeight;
        aiBattle.SetCliffDescentParams(cliffApproachClass, cliffDescentDrop, cliffDescentRun, cliffDescentProgress);
        aiBattle.SetMountainPathParams(mountainGradeWeight, mountainPeakTolerance);
        aiBattle.SetSpecialistSpan(specialistMinSpan, specialistSpanFraction);
        aiBattle.SetMountainShelfParams(mountainSurfaceWeight, mountainHeightWeight);
        aiBattle.SetCliffPreference(cliffPreference, cliffQualityTolerance, cliffHeightFraction);
        pendingOurs = ours; pendingTheirs = theirs; pendingWhy = why;
        pendingFront = Front(); requestFrame = ai.frame;
        if (background) waiting = aiBattle.RequestLanes(Global::RoleSettings::Tech::LaneAlternatives, Global::RoleSettings::Tech::LaneMergeRadius, w, specialistBias, highGroundRise, highGroundDetour, highGroundRoutes);
        else {
            aiBattle.AnalyseLanes(Global::RoleSettings::Tech::LaneAlternatives, Global::RoleSettings::Tech::LaneMergeRadius, w, specialistBias, highGroundRise, highGroundDetour, highGroundRoutes);
            waiting = true;
        }
        Poll();
    }

    // Called for every experimental role, not only TECH: a player-panel survey
    // must finish even if that AI does not run automatic lane planning.
    // Worker results are installed by the native scheduler on MAIN only. Script
    // validates/publishes a complete revision; calcs never advances on enqueue.
    void Poll()
    {
        if (waiting && !aiBattle.IsLanePending()) {
            waiting = false;
            if (aiBattle.GetLaneRevision() == observedRevision) {
                Invariants::Violation("INV-070", "lane-job", "lane job ended without a published generation");
                lastCalc = ai.frame; // bound retries after a failed job
            } else Finish();
        }
        if (nextPanelFrame >= 0 && ai.frame >= nextPanelFrame && !waiting && !aiBattle.IsLanePending()) {
            nextPanelFrame = -1;
            Compute("panel request");
        }
    }
    void Finish()
    {
        aiBattle.BeginLanePostprocess();
        const int revision = aiBattle.GetLaneRevision();
        if (revision <= observedRevision)
            Invariants::Violation("INV-070", "lane-generation", "lane publication must advance exactly once");
        observedRevision = revision;
        const int n = aiBattle.GetLaneCount();
        const string why = pendingWhy;
        array<AIFloat3> ours = pendingOurs, theirs = pendingTheirs;
        ++calcs;
        lastCalc = requestFrame;
        lastFront = pendingFront;
        BuildLessons();
        int specialists = 0;
        for (int lane = 0; lane < n; ++lane) {
            if (aiBattle.IsLaneSpecialist(lane)) ++specialists;
            if (aiBattle.GetLaneClass(lane) == ALLTERRAIN && !aiBattle.IsLaneSpecialist(lane))
                Invariants::Violation("INV-071", "" + lane, "all-terrain lane must cross one substantial connected mountain");
            const int cls = aiBattle.GetLaneClass(lane);
            bool valid = cls >= 0 && cls <= AIR && (aiBattle.GetLaneMask(lane) & (1 << cls)) != 0;
            if (valid && aiBattle.GetLaneWidth(lane) > 0.0f) valid = aiBattle.IsPassable(aiBattle.GetLaneChoke(lane), cls);
            const int samples = AiMax(2, int(aiBattle.GetLaneLength(lane) / 64.0f));
            if (valid) for (int k = 0; k <= samples; ++k) {
                if (!aiBattle.IsPassable(aiBattle.GetLanePoint(lane, float(k) / samples), cls)) { valid = false; break; }
            }
            if (!valid) Invariants::Violation("INV-062", "" + lane, "lane class must traverse its sampled path and choke");
            const AIFloat3 descent = aiBattle.GetLaneDescent(lane);
            const AIFloat3 ascent = aiBattle.GetLaneAscent(lane);
            if (ascent.x >= 0.0f && (descent.x < 0.0f || aiBattle.GetLaneCliffQuality(lane, 0) <= 0.0f
                || aiBattle.GetLaneCliffQuality(lane, 1) <= 0.0f))
                Invariants::Violation("INV-066", "" + lane, "paired cliff route must verify walker-only steep descent on both ends");
            if (descent.x >= 0.0f && (cls != ALLTERRAIN || (aiBattle.GetLaneMask(lane) & (1 << BOT)) != 0
                || !aiBattle.IsPassable(descent, cliffApproachClass)))
                Invariants::Violation("INV-065", "" + lane, "cliff descent must start on accessible ground on a crawler-only lane");
            if (descent.x >= 0.0f) {
                const AIFloat3 start = aiBattle.GetLanePoint(lane, 0.0f), end = aiBattle.GetLanePoint(lane, 1.0f);
                const float dx = end.x-start.x, dz = end.z-start.z, span = dx*dx + dz*dz;
                const float progress = (span > 1.0f) ? ((descent.x-start.x)*dx + (descent.z-start.z)*dz)/span : 0.0f;
                if (progress + 0.001f < AiMin(1.0f, AiMax(0.0f, cliffDescentProgress)))
                    Invariants::Violation("INV-065", "" + lane, "cliff descent must retain the traverse until configured destination-side progress");
            }
        }
        GenericHelpers::LogUtil("[Lanes] qualified specialists=" + specialists, 1);
        GenericHelpers::LogUtil("[Lanes] calculation " + calcs + " (" + why + "): " + n + " lane(s) between " + ours.length()
            + " allied territory starts and " + theirs.length() + " enemy starts (D-127)", 1);
        for (int i = 0; i < n; ++i) {
            const AIFloat3 ch = aiBattle.GetLaneChoke(i);
            GenericHelpers::LogUtil("[Lanes] " + (i + 1) + " " + NAMES[aiBattle.GetLaneClass(i)] + ": " + int(aiBattle.GetLaneLength(i)) + " long, "
                + ((aiBattle.GetLaneWidth(i) > 0.0f) ? ("narrowest " + int(aiBattle.GetLaneWidth(i)) + " at (" + int(ch.x) + ", " + int(ch.z) + "), ") : "")
                + aiBattle.GetLaneHeat(i) + " path(s), threat " + int(aiBattle.GetLaneThreat(i))
                + ((aiBattle.GetLaneFront(i) >= 0.0f) ? (", enemy from " + int(aiBattle.GetLaneFront(i) * 100) + "%") : ""), 1);
        }
        LogAttackPlan();
        WaterTheatres::Analyse(ours, theirs);
        StrategicSites::Analyse(ours, theirs);
        if (overlay) PublishOverlay(false); // refresh the cache without extending the display window
        aiBattle.EndLanePostprocess();
    }

    // ---------------------------------------------------------------- attack planning (TECH)

    // Minimise threat-weighted length, discounted by the lane's usable width.
    int BestLane(int cls)
    {
        int best = -1;
        float bestScore = 1e30f;
        for (int i = 0; i < aiBattle.GetLaneCount(); ++i) {
            if (aiBattle.GetLaneClass(i) != cls) continue;
            const float s = (1.0f + aiBattle.GetLaneThreat(i)) * aiBattle.GetLaneLength(i) / (1.0f + aiBattle.GetLaneWidth(i) * 0.001f);
            if (s < bestScore) { bestScore = s; best = i; }
        }
        return best;
    }

    void LogAttackPlan()
    {
        string plan = "";
        for (int c = 0; c < int(NAMES.length()); ++c) {
            const int l = BestLane(c);
            if (l < 0) continue;
            plan += (plan == "" ? "" : "; ") + NAMES[c] + " down lane " + (l + 1);
        }
        GenericHelpers::LogUtil("[Lanes] attack plan: " + (plan == "" ? "no lane" : plan) + " (D-127)", 1);
    }

    // ---------------------------------------------------------------- tick

    void Tick()
    {
        if (!Enabled()) return;
        LoadSettings();
        if (waiting || aiBattle.IsLanePending()) return;
        if (calcs == 0) {
            if (ai.frame < 30 + (ai.teamId % 16) * staggerSeconds * SECOND) return;   // the map, starts and roster are known
            Compute("game start");
        } else {
            const AIFloat3 f = Front();
            const float moved = (lastFront.x < 0.0f) ? 0.0f : f.distance2D(lastFront);
            // (played: the front flipped 6700 between the combat heat and the fallback
            // front as heat came and went, and recalculated every 20 s)
            const bool rested = ai.frame - lastCalc >= int(Global::RoleSettings::Tech::LaneRecalcMinSeconds * SECOND);
            if (rested && moved >= Global::RoleSettings::Tech::LaneRecalcShift)
                Compute("the front moved " + int(moved));
            else if (ai.frame - lastCalc >= int(Global::RoleSettings::Tech::LaneRecalcSeconds * SECOND))
                Compute("every " + int(Global::RoleSettings::Tech::LaneRecalcSeconds) + " s");
        }
        // The control panel owns visibility; calculating never opens an overlay.
    }

    // ---------------------------------------------------------------- read-only control-panel publication

    bool overlay = false;

    // AI-owned tactical interpretation, available to future attack planners.
    // 0 advance/scout, 1 contain a choke, 2 specialist flank, 3 naval access,
    // 4 air approach. Positions are terrain opportunities, never orders.
    class Lesson {
        int kind = 0;
        AIFloat3 anchor;
    }
    array<Lesson@> lessons;
    void BuildLessons() {
        lessons.resize(0);
        for (int i = 0; i < aiBattle.GetLaneCount(); ++i) {
            Lesson@ l = Lesson();
            const int cls = aiBattle.GetLaneClass(i);
            l.anchor = aiBattle.GetLanePoint(i, 0.5f);
            const AIFloat3 descent = aiBattle.GetLaneDescent(i);
            if (descent.x >= 0.0f) { l.kind = 5; l.anchor = descent; }
            else if (cls == AIR) l.kind = 4;
            else if (cls == NAVAL) l.kind = 3;
            else if (cls == ALLTERRAIN || cls == AMPH || cls == HOVER) {
                l.kind = 2;
                // Place the flank cue on the middle of the longest section
                // ordinary bots cannot traverse, not on a shared approach.
                int runStart = -1, bestStart = -1, bestLength = 0;
                for (int k = 0; k <= 100; ++k) {
                    const bool exclusive = k < 100 && !aiBattle.IsPassable(aiBattle.GetLanePoint(i, float(k) / 100.0f), BOT);
                    if (exclusive && runStart < 0) runStart = k;
                    if (!exclusive && runStart >= 0) {
                        if (k-runStart > bestLength) { bestStart = runStart; bestLength = k-runStart; }
                        runStart = -1;
                    }
                }
                if (bestStart >= 0) l.anchor = aiBattle.GetLanePoint(i, float(bestStart + bestLength / 2) / 100.0f);
            } else if (aiBattle.GetLaneWidth(i) > 0.0f && aiBattle.GetLaneWidth(i) <= teachingChokeWidth) {
                l.kind = 1;
                l.anchor = aiBattle.GetLaneChoke(i);
            }
            lessons.insertLast(l);
        }
    }

    string XY(const AIFloat3& in p) { return "" + int(p.x) + "," + int(p.z); }
    string OverlayMessage(const string &in topic, const string &in payload) {
        return ai.CallUI("barbtheatre|1|" + ai.teamId + "|" + topic + "|" + payload);
    }
    bool PublishOverlay(bool reveal = true) {
        if (OverlayMessage("begin", "" + Global::RoleSettings::Tech::LaneDrawSeconds + "," + int(ai.GetTidalStrength())) != "theatre-v1") return false;
        for (int i = 0; i < aiBattle.GetLaneCount(); ++i) {
            const int n = AiMax(2, int(aiBattle.GetLaneLength(i) / 128.0f));
            string pts;
            for (int k = 0; k <= n; ++k) pts += (k == 0 ? "" : ";") + XY(aiBattle.GetLanePoint(i, float(k) / n));
            OverlayMessage("lane", "" + (i+1) + "," + aiBattle.GetLaneClass(i) + "|" + pts);
            Lesson@ lesson = lessons[i];
            OverlayMessage("laneinfo", "" + (i+1) + "," + int(aiBattle.GetLaneLength(i)) + "," + int(aiBattle.GetLaneWidth(i))
                + "," + aiBattle.GetLaneThreat(i) + "," + aiBattle.GetLaneFront(i) + "," + aiBattle.GetLaneMask(i)
                + "," + lesson.kind + "," + XY(lesson.anchor) + "," + lastCalc + "," + calcs);
            const AIFloat3 ascent = aiBattle.GetLaneAscent(i);
            if (ascent.x >= 0.0f) OverlayMessage("cliffinfo", "" + (i+1) + "," + XY(ascent)
                + "," + aiBattle.GetLaneCliffQuality(i, 0) + "," + aiBattle.GetLaneCliffQuality(i, 1));
        }
        for (uint i = 0; i < WaterTheatres::bodies.length(); ++i) {
            WaterTheatres::Body@ b = WaterTheatres::bodies[i];
            if (int(b.cells.length()) < WaterTheatres::minCells) continue;
            OverlayMessage("body", "" + b.id + "," + (b.pond ? 1 : 0) + "," + (b.shared ? 1 : 0) + ","
                + (b.friendly ? 1 : 0) + "," + XY(b.centre) + "," + int(b.area) + ","
                + XY(b.yard) + "," + XY(b.tidal) + "," + XY(b.plane) + "," + b.facing);
            string edges;
            for (uint j = 0; j < b.shore.length(); ++j) {
                const int c = b.shore[j], x = c % WaterTheatres::width, z = c / WaterTheatres::width;
                const int px = x * WaterTheatres::CELL, pz = z * WaterTheatres::CELL;
                if (WaterTheatres::At(x-1,z) != b.id) edges += "" + px + "," + pz + "," + px + "," + (pz+64) + ";";
                if (WaterTheatres::At(x+1,z) != b.id) edges += "" + (px+64) + "," + pz + "," + (px+64) + "," + (pz+64) + ";";
                if (WaterTheatres::At(x,z-1) != b.id) edges += "" + px + "," + pz + "," + (px+64) + "," + pz + ";";
                if (WaterTheatres::At(x,z+1) != b.id) edges += "" + px + "," + (pz+64) + "," + (px+64) + "," + (pz+64) + ";";
                if (edges.length() > 6000) { OverlayMessage("shore", "" + b.id + "|" + edges); edges = ""; }
            }
            if (edges.length() > 0) OverlayMessage("shore", "" + b.id + "|" + edges);
        }
        for (uint i=0;i<StrategicSites::geos.length();++i) {
            StrategicSites::Geo@ g=StrategicSites::geos[i];
            OverlayMessage("geo", "" + i + "," + XY(g.pos) + "," + g.use + "," + int(g.coverage*100) + "," + (g.friendly?1:0));
        }
        for (uint i=0;i<StrategicSites::islands.length();++i) {
            StrategicSites::Island@ p=StrategicSites::islands[i];
            OverlayMessage("island", "" + i + "," + XY(p.pos) + "," + int(p.radius) + "," + p.cells);
        }
        for (uint i=0;i<StrategicSites::beaches.length();++i) {
            StrategicSites::Beach@ b=StrategicSites::beaches[i]; string pts;
            for (uint j=0;j<b.normals.length();++j) pts += (j==0?"":";") + XY(b.points[j]) + "," + XY(b.points[j+1]) + "," + XY(b.normals[j]);
            OverlayMessage("beach", "" + i + "," + b.use + "|" + pts);
        }
        OverlayMessage(reveal ? "show" : "refresh", "");
        GenericHelpers::LogUtil("[Theatres] overlay published: " + aiBattle.GetLaneCount() + " lanes; no placement changes", 1);
        return true;
    }

    void RequestOverlay(bool force = false) {
        if (Global::Map::Config is null || ai.frame < 90) return;
        LoadSettings();
        const bool rested = ai.frame-lastCalc >= int(Global::RoleSettings::Tech::LaneRecalcMinSeconds*SECOND);
        Poll();
        overlay = true; // retain display intent while the first result is pending
        if (!waiting && !aiBattle.IsLanePending() && nextPanelFrame < 0
            && (calcs == 0 || (force && rested) || ai.frame-lastCalc > int(Global::RoleSettings::Tech::LaneRecalcSeconds*SECOND)))
            nextPanelFrame = ai.frame + (ai.teamId % 16) * staggerSeconds * SECOND;
        if (calcs > 0) PublishOverlay(false);
    }

    void OnRoleLeave()
    {
        aiBattle.CancelLaneRequest();
        waiting = false;
        nextPanelFrame = -1;
        if (overlay) OverlayMessage("remove", "");
        overlay = false;
        calcs = 0;
        lastCalc = -100000;
    }
}
