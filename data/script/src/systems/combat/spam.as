// Spam: economy-gated mass production of cheap units sent down fixed routes.
#include "../../define.as"
#include "../../unit.as"
#include "../../task.as"
#include "../../global.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/spatial/map_helpers.as"
#include "../../helpers/math/spam_math.as"
#include "../team/roster.as"
#include "../presentation/widget_link.as"
#include "edge_lanes.as"

/******************************************************************************

SPAM

Units listed as products in Global::Spam::UnitByFactory get their own
behaviour once the economy
clears Global::Spam::MinMetalIncome and MinEnergyIncome (both, sliding 10 s
minimum; deactivation at ReleaseFraction of each so a dip does not flap):

  factories   Income-budgeted T1 factories in Global::Spam::UnitByFactory
              produces that unit on repeat and nothing else while spam is
              active (Factory::AiMakeTask asks here first).
  routes      Each spam factory owns one native CRouteTask (TaskF::Route)
              holding a multi-step route from the factory to the destination.
              Routes of different factories run in parallel lanes: the k-th
              factory is offset sideways by LaneSpacing * (0, +1, -1, +2, ...)
              from the direct line, with two intermediate waypoints so the
              lane is held, not just the end point.
  units       A finished spam unit is assigned to its factory's route task
              from Military::AiMakeTask using the real producer ID (nearest
              live pump only for gifts or a lost producer). Plain move orders
              nothing on the way interrupts the run; the units hold at the
              destination and fire at whatever comes into range.
  focus       The destination is BehindEnemyDistance beyond the current focus
              along the line from our start through it, clamped to the map:
              behind the enemy line and past its radar and LOS when the map
              allows. Actual enemy lobby starts take precedence; map slots
              exclude allied starts/boxes, with a mirrored-start fallback.
              It rotates through
              the enemy spots nearest-first every RefocusMinutes, and
              SetFocus(pos) retargets on demand. Every refocus rebuilds every
              factory route and the route task re-issues it to all units
              already on the field.

Everything here is data on the script side plus one native task type; the
task keeps only unit pointers it is told about through the normal assignment
path and drops them through the normal removal path.

******************************************************************************/
namespace Spam {
    bool active = false;
    int activeSinceFrame = -1;
    dictionary routeByFactory;     // factory id string -> CRouteTask@
    dictionary laneByFactory;      // factory id string -> int lane (0, 1, -1, 2, -2 ...)
    // D-119 (owner: each spam lab correlates to a lane; lanes spaced apart, spread
    // across the active front, straight to the enemy backline): a role may give a
    // factory a SPREAD lane: a line parallel to the axis from our start to the
    // enemy starts, at a sideways place across the front. It replaces the lane
    // number's offset for that factory
    dictionary spreadByFactory;    // factory id string -> float sideways place (elmos from the axis)
    int lanesIssued = 0;
    // D-111 (owner: each factory correlates directly to a lane): a spam unit
    // runs the lane of the factory that built it, for good; the nearest
    // factory only decides at its first sight (it spawns at its factory)
    dictionary producerOf;         // unit id string -> factory id
    int routesVersion = 0;         // bumped whenever any route changes (a role re-applies factory routes)
    dictionary repeatTask;         // factory id -> owned persistent recruit handle
    dictionary factoryVersion;     // route version last installed on factory
    dictionary routedUnits;        // unit id string -> factory id (INV-043)
    int routeCheckFrame = -1;
    int adoptFrame = -100000;
    // Two different points, previously conflated:
    //   focus  - WHERE THE RUN ENDS. An enemy start spot; the destination is
    //            BehindEnemyDistance past it. Rotates on the refocus timer.
    //   front  - WHERE THE RUN GOES THROUGH. The AI's current combat focus
    //            from aiMilitaryMgr.GetCombatFocusPos(): the leader of the
    //            strongest ATTACK squad, else the enemy centroid. Spam is
    //            worth most crossing the fight - vision and decoy targets
    //            where the shooting already is - and only then carrying on
    //            into the backline.
    AIFloat3 focus;
    bool hasFocus = false;
    int focusIdx = 0;
    int lastFocusFrame = -1;
    AIFloat3 front;
    bool hasFront = false;
    // Diagnostics. Activation is one line; everything between activation and a
    // unit actually moving used to be silent, so a game where spam activated
    // and then did nothing (Eight Horses, f=19115: "Activated", no "Route
    // created", ever) could not be told apart from one where no spam factory
    // existed. Both memos log only when the answer changes, so a factory that
    // asks every few seconds produces one line, not hundreds.
    dictionary rejectByFactory;    // factory id string -> last reason logged
    int lastIdleReportFrame = -1;

    bool IsEnabled()
    {
        if (SeaCoast::Active()) return false; // lost-sea labs/land army defend their coast
        if (!Global::Spam::Enabled) return false;
        if (Global::Map::LandLocked && !Global::Spam::AllowLandLocked) {
            if (!landLockedReported) {
                landLockedReported = true;
                GenericHelpers::LogUtil("[Spam] Off: this start is land-locked; the T1 factories keep their role logic (Global::Spam::AllowLandLocked)", 1);
            }
            return false;
        }
        return true;
    }
    bool landLockedReported = false;
    bool IsActive() { return active; }

    dictionary spamProducts;
    bool productsReady = false;
    bool IsSpamDef(const CCircuitDef@ d)
    {
        if (d is null) return false;
        if (!productsReady) {
            // Configuration is fixed for this AI instance. Resolve once, then
            // O(1) membership without allocating a factory-key list per unit.
            // JSON "spam" is also a role: the native loader treats colliding
            // attribute names as roles, so testing Attr::SPAM never enrolled
            // Pawns. Use the explicit pump roster; do not capture rezzers that
            // happen to carry the broad combat-role label "spam".
            array<string>@ keys = Global::Spam::UnitByFactory.getKeys();
            for (uint i=0; i<keys.length(); ++i) {
                string name;
                if (Global::Spam::UnitByFactory.get(keys[i],name)) spamProducts.set(name,true);
            }
            productsReady = true;
        }
        return spamProducts.exists(d.GetName());
    }

    // The spam unit a factory produces, "" when the factory is not a spam factory.
    string SpamUnitFor(const CCircuitDef@ facDef)
    {
        if (facDef is null) return "";
        string name = "";
        if (!Global::Spam::UnitByFactory.get(facDef.GetName(), name)) return "";
        return name;
    }

    /**************************************************************************
     Activation (Main::AiUpdate, every 30 frames).
     **************************************************************************/
    void Update()
    {
        EdgeLanes::Update();   // owner, 2026-10-17: the edge lanes' lab and its repeat
        const float mi = Economy::GetMinMetalIncomeLast10s();
        const float ei = Economy::GetMinEnergyIncomeLast10s();
        const bool funded = IsEnabled() && SpamMath::Funded(mi, ei, aiEconomyMgr.isEnergyEmpty,
            aiEconomyMgr.isMetalFull, aiEconomyMgr.metal.current, Global::Spam::MinMetalIncome,
            Global::Spam::MinEnergyIncome, Global::Spam::FloatMetalIncome, Global::Spam::MinMetalBank,
            active, Global::Spam::ReleaseFraction);
        // Persistent repeats do not re-ask the factory hook on every offspring.
        // The once-a-second policy census owns cancellation; ongoing units keep
        // their MOVE route. Only abort a task still owned by this controller.
        MaintainFactories(funded && aiBuilderMgr.GetWorkerCount() >= Global::Spam::MinWorkers);
        if (!IsEnabled()) { active = false; return; }
        if (!active) {
            if (mi < Global::Spam::MinMetalIncome || ei < Global::Spam::MinEnergyIncome) {
                // Dedicated pressure needs a mature, funded economy; no fusion
                // building is required. Below the gate these units remain normal
                // early raiders. Report the shortfall occasionally so
                // "never activated" is distinguishable from "never evaluated".
                // Level 1, every two minutes: LOG_LEVEL is 1, and "never activated"
                // has to be tellable from "never evaluated" in a game log.
                if (lastIdleReportFrame < 0 || (ai.frame - lastIdleReportFrame) >= 2 * MINUTE) {
                    lastIdleReportFrame = ai.frame;
                    GenericHelpers::LogUtil("[Spam] Idle: mi=" + int(mi) + "/" + int(Global::Spam::MinMetalIncome)
                        + " ei=" + int(ei) + "/" + int(Global::Spam::MinEnergyIncome), 1);
                }
            }
            if (funded) {
                active = true;
                activeSinceFrame = ai.frame;
                _EnsureFocus();
                GenericHelpers::LogUtil("[Spam] Activated: mi=" + mi + " ei=" + ei + " focus=(" + int(focus.x) + "," + int(focus.z) + ")", 1);
                WidgetLink::Send("spam", "on|" + int(mi) + "|" + int(ei));
            }
            return;
        }
        if (!funded) {
            active = false;
            GenericHelpers::LogUtil("[Spam] Deactivated: mi=" + mi + " ei=" + ei + "; units on the field keep their routes", 1);
            WidgetLink::Send("spam", "off|" + int(mi) + "|" + int(ei));
            return;
        }
        CheckRoutedUnits();   // D-111: INV-043
        if (repeatTask.getSize() == 0 && ai.frame % (30 * SECOND) == 0)
            GenericHelpers::LogUtil("[Spam] waiting for eligible pump; workers=" + aiBuilderMgr.GetWorkerCount(), 1);
        AdoptProducedUnits();
        if (lastFocusFrame >= 0 && (ai.frame - lastFocusFrame) >= Global::Spam::RefocusMinutes * MINUTE) {
            NextFocus();
        }
        UpdateFront();
    }

    void AdoptProducedUnits()
    {
        if (routeByFactory.getSize() == 0 || ai.frame - adoptFrame < 5 * SECOND) return;
        adoptFrame = ai.frame;
        // An already-finished raider can be sitting in an ordinary assembling
        // squad when its factory becomes a spam pump. Make the transition once;
        // steady-state routes get no orders from this O(U) census.
        array<int>@ ids = ai.GetOwnedUnitIds();
        int joined = 0;
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null || !IsSpamDef(u.circuitDef) || u.GetBuildProgress() < 1.0f) continue;
            if (u.task !is null && (u.task.GetType() == int(Task::Type::PLAYER)
                || u.task.GetType() == int(Task::Type::RETREAT) || u.task.IsExternalControlled())) continue;
            IFighterTask@ fight = u.task is null ? null : cast<IFighterTask>(u.task);
            if (fight !is null && cast<CRouteTask>(fight) !is null) continue;
            IUnitTask@ route = MilitaryMakeTask(u);
            if (route !is null && aiMilitaryMgr.TransferUnit(u, route)) ++joined;
        }
        if (joined > 0) GenericHelpers::LogUtil("[Spam] released " + joined + " existing units onto producer lanes", 1);
    }

    int LabsWanted()
    {
        const float income = Economy::GetMinMetalIncomeLast10s();
        return SpamMath::Labs(AiMax(income, active ? Global::Spam::MinMetalIncome : 0.0f),
            Global::Spam::MinMetalIncome, Global::Spam::LabMetalStep, Global::Spam::MaxLabs);
    }

    int lastLabAttempt = -100000;
    IUnitTask@ BuilderMakeTask(CCircuitUnit@ u)
    {
        if (!active || u is null || !u.circuitDef.IsMobile() || UnitHelpers::IsCommander(u.circuitDef)
            || aiBuilderMgr.GetWorkerCount() < Global::Spam::MinWorkers
            || aiEconomyMgr.isEnergyEmpty || aiEconomyMgr.metal.current < Global::Spam::MinMetalBank) return null;
        // Native re-asks while a constructor walks to a pinned site, before a
        // frame exists. Do not enqueue the next turret and abandon that walk.
        // The role's existing keep-current rule still owns the current job.
        IBuilderTask@ current = u.task is null ? null : cast<IBuilderTask>(u.task);
        if (current !is null && Task::BuildType(current.GetBuildType()) < Task::BuildType::REPAIR) return null;
        CCircuitDef@ lab = ai.GetCircuitDef(UnitHelpers::GetT1BotLabForSide(Global::AISettings::Side));
        if (lab is null || !u.circuitDef.CanBuild(lab) || TechForward::Recalled(u)) return null;
        const int queued = aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::FACTORY), lab);
        if (Global::AISettings::Role == AiRole::TECH && Global::RoleSettings::Tech::ExperimentalBuild) {
            // Keep TECH's reserved clusters and exact advanced-lab-before-T1
            // rebuild lifecycle; only remove the unrelated +200/air-worker gate.
            if (!TechFactories::AdvancedLabUp()) return null;
            array<TechFactories::Cluster@> clusters = TechForward::SpamClusters();
            IUnitTask@ task = TechFactories::Work(lab, u, int(clusters.length()) < LabsWanted() && queued == 0);
            if (task !is null) TechForward::lastOrderT1 = ai.frame;
            return task;
        }
        // Other roles get one dedicated land pump before their own planner.
        // Existing mapped factories can provide the remaining income-scaled
        // pumps. Never repurpose an aircraft lab or shipyard.
        if (lab.count + queued > 0 || ai.frame - lastLabAttempt < 30 * SECOND) return null;
        CCircuitDef@ product = ai.GetCircuitDef(SpamUnitFor(lab));
        if (product is null) return null;
        lastLabAttempt = ai.frame;
        _EnsureFocus();
        const AIFloat3 home = Global::Map::StartPos;
        // Search a bounded ring outside the core. Native factory placement
        // respects all allied layout reservations; connectivity uses the spam
        // unit's movement area, not the flying constructor's movement area.
        for (int ring = 1; ring <= 3; ++ring) for (int k = 0; k < 8; ++k) {
            const float angle = float(k) * 0.785398f;
            const AIFloat3 p = _Clamp(AIFloat3(home.x + cos(angle) * float(ring) * 600.0f, 0,
                home.z + sin(angle) * float(ring) * 600.0f));
            if (!aiBattle.IsPassable(p, Lanes::BOT) || !aiTerrainMgr.CanReachAt(u, p, u.circuitDef.GetBuildDistance())
                || aiTerrainMgr.IsAllyLayoutBlocked(lab, p, 0) || ReachableNear(product, p, focus).x < 0.0f) continue;
            if (lab.maxThisUnit <= lab.count) lab.maxThisUnit = lab.count + 1;
            if (!lab.IsAvailable(ai.frame)) return null;
            GenericHelpers::LogUtil("[Spam] dedicated land lab at " + int(p.x) + "," + int(p.z), 1);
            return aiBuilderMgr.Enqueue(TaskB::Factory(Task::Priority::NORMAL, lab, p, product, 128.0f));
        }
        return null;
    }

    void MaintainFactories(bool enabled)
    {
        array<string>@ keys = repeatTask.getKeys();
        array<CCircuitUnit@> labs;
        for (uint i = 0; i < keys.length(); ++i) {
            CCircuitUnit@ f = ai.GetTeamUnit(int(parseInt(keys[i])));
            IUnitTask@ task;
            if (!repeatTask.get(keys[i], @task)) continue;
            if (f is null || task is null || task.IsDead() || f.task !is task) { repeatTask.delete(keys[i]); continue; }
            if (!enabled || Lifecycle::IsRetiring(f) || Team::Recovery::WantsFactory(f) || int(labs.length()) >= LabsWanted()) {
                repeatTask.delete(keys[i]); task.Abort(); continue;
            }
            CRouteTask@ route;
            if (!routeByFactory.get(keys[i], @route) || route is null || route.GetRouteSize() == 0)
                Invariants::Violation("INV-157", keys[i], "repeating spam factory lacks a reachable MOVE route");
            CCircuitDef@ d = ai.GetCircuitDef(SpamUnitFor(f.circuitDef));
            if (d !is null && d.maxThisUnit < d.count + 50) d.maxThisUnit = d.count + 50;
            labs.insertLast(f);
        }
        // O(F^2) stable ordering is bounded by MaxLabs (6), never unit count.
        // Geometry only changes on new labs/front displacement; equality in
        // SetSpreadLanes prevents repeated unit orders for unchanged positions.
        SetSpreadLanes(labs);
        for (uint i = 0; i < labs.length(); ++i) {
            const string key = "" + labs[i].id;
            int previous = -1;
            if (!factoryVersion.get(key, previous) || previous != routesVersion) {
                labs[i].CmdFactoryRoute(RouteOf(labs[i]));
                factoryVersion.set(key, routesVersion);
            }
        }
    }

    // Poll the AI's combat focus and rebuild every lane when it has moved far
    // enough to matter. This is the "route updated whenever the combat target
    // changed" half; the refocus timer above only moves the destination.
    void UpdateFront()
    {
        const AIFloat3 p = aiMilitaryMgr.GetCombatFocusPos();
        if (p.x < 0.0f) {   // invalid: no army and no known enemy
            return;
        }
        if (hasFront && MapHelpers::SqDist(p, front)
                < Global::Spam::FrontMoveThreshold * Global::Spam::FrontMoveThreshold) {
            return;
        }
        front = p;
        hasFront = true;
        RefreshRoutes();
        GenericHelpers::LogUtil("[Spam] Front moved to (" + int(p.x) + "," + int(p.z) + "); "
            + routeByFactory.getSize() + " route(s) rebuilt", 2);
        WidgetLink::Send("spam", "front|" + int(p.x) + "|" + int(p.z));
    }

    /**************************************************************************
     Focus (the target the routes lead behind).
     **************************************************************************/
    // Map start spots that are neither ours nor an ally's, nearest to us first.
    array<AIFloat3> EnemyStartSpots()
    {
        array<AIFloat3> result;
        // Lobby starts are authoritative. Unoccupied friendly map slots are
        // not enemies: selecting the nearest unused slot sent spam backwards.
        for (int i = 0; i < aiSetupMgr.GetScriptStartCount(); ++i)
            if (aiSetupMgr.IsScriptStartEnemy(i)) result.insertLast(aiSetupMgr.GetScriptStart(i));
        if (result.length() > 0) return result;
        StartSpot@[]@ spots = Global::Map::Config.StartSpots;
        if (spots is null || spots.length() == 0) return result;
        dictionary taken;
        const int own = MapHelpers::NearestSpotIdx(Global::Map::StartPos, spots);
        if (own >= 0) taken.set("" + own, true);
        array<Team::Roster::Entry@>@ allies = Team::Roster::All();
        for (uint i = 0; i < allies.length(); ++i) {
            if (allies[i].spotIndex >= 0) taken.set("" + allies[i].spotIndex, true);
        }
        array<float> dist;
        for (uint i = 0; i < spots.length(); ++i) {
            if (taken.exists("" + i)) continue;
            if (aiSetupMgr.EnemyStartBoxAt(spots[i].pos) == 0) continue;
            const float d = MapHelpers::SqDist(Global::Map::StartPos, spots[i].pos);
            uint pos = 0;
            while (pos < dist.length() && dist[pos] <= d) ++pos;
            result.insertAt(pos, spots[i].pos);
            dist.insertAt(pos, d);
        }
        return result;
    }

    AIFloat3 _MirrorOfStart()
    {
        const float w = float(aiTerrainMgr.GetTerrainWidth());
        const float h = float(aiTerrainMgr.GetTerrainHeight());
        return AIFloat3(w - Global::Map::StartPos.x, 0.0f, h - Global::Map::StartPos.z);
    }

    void _EnsureFocus()
    {
        if (hasFocus) return;
        focusIdx = 0;
        array<AIFloat3> enemies = EnemyStartSpots();
        SetFocus(enemies.length() > 0 ? enemies[0] : _MirrorOfStart());
    }

    void NextFocus()
    {
        array<AIFloat3> enemies = EnemyStartSpots();
        if (enemies.length() == 0) { SetFocus(_MirrorOfStart()); return; }
        focusIdx = (focusIdx + 1) % int(enemies.length());
        SetFocus(enemies[focusIdx]);
    }

    // Retarget every route and every unit already on the field.
    void SetFocus(const AIFloat3 &in pos)
    {
        focus = pos;
        hasFocus = true;
        lastFocusFrame = ai.frame;
        RefreshRoutes();
        GenericHelpers::LogUtil("[Spam] Focus set to (" + int(pos.x) + "," + int(pos.z) + "); " + routeByFactory.getSize() + " route(s) rebuilt", 1);
        WidgetLink::Send("spam", "focus|" + int(pos.x) + "|" + int(pos.z));
    }

    /**************************************************************************
     Routes.
     **************************************************************************/
    AIFloat3 _Clamp(const AIFloat3 &in p)
    {
        const float margin = Global::Spam::MapMargin;
        const float w = float(aiTerrainMgr.GetTerrainWidth());
        const float h = float(aiTerrainMgr.GetTerrainHeight());
        float x = p.x, z = p.z;
        if (x < margin) x = margin;
        if (x > w - margin) x = w - margin;
        if (z < margin) z = margin;
        if (z > h - margin) z = h - margin;
        return AIFloat3(x, 0.0f, z);
    }

    // Destination: BehindEnemyDistance past the focus on the line from our start.
    AIFloat3 Destination()
    {
        float dx = focus.x - Global::Map::StartPos.x;
        float dz = focus.z - Global::Map::StartPos.z;
        float len = sqrt(dx * dx + dz * dz);
        if (len < 1.0f) { dx = 1.0f; dz = 0.0f; len = 1.0f; }
        const float d = Global::Spam::BehindEnemyDistance;
        return _Clamp(AIFloat3(focus.x + dx / len * d, 0.0f, focus.z + dz / len * d));
    }

    // Factory -> two lane waypoints -> destination. Lane k is offset sideways by
    // LaneSpacing * k from the direct line so several factories run in parallel.
    array<AIFloat3> BuildRoute(const AIFloat3 &in from, int lane)
    {
        array<AIFloat3> route;
        const AIFloat3 to = Destination();
        float dx = to.x - from.x;
        float dz = to.z - from.z;
        float len = sqrt(dx * dx + dz * dz);
        if (len < 1.0f) { route.insertLast(to); return route; }
        const float nx = -dz / len;   // left-hand normal
        const float nz = dx / len;
        const float off = Global::Spam::LaneSpacing * float(lane);

        // Via the front when we know where it is, otherwise the old straight
        // run. The lane offset is applied to every waypoint including the
        // destination, so parallel lanes stay parallel the whole way instead
        // of converging on one point.
        if (hasFront) {
            // Half way to the front, then the front itself: two waypoints hold
            // the lane on the approach, which one waypoint would not.
            route.insertLast(_Clamp(AIFloat3(from.x + (front.x - from.x) * 0.5f + nx * off, 0.0f,
                                             from.z + (front.z - from.z) * 0.5f + nz * off)));
            route.insertLast(_Clamp(AIFloat3(front.x + nx * off, 0.0f, front.z + nz * off)));
        } else {
            route.insertLast(_Clamp(AIFloat3(from.x + dx * 0.33f + nx * off, 0.0f, from.z + dz * 0.33f + nz * off)));
            route.insertLast(_Clamp(AIFloat3(from.x + dx * 0.66f + nx * off, 0.0f, from.z + dz * 0.66f + nz * off)));
        }
        route.insertLast(_Clamp(AIFloat3(to.x + nx * off, 0.0f, to.z + nz * off)));
        return route;
    }

    // D-119: the axis of the spread lanes: from our start toward the focus (the
    // enemy start the runs end behind); `nx, nz` sideways. Not the centre of all
    // unused start spots: on a many-spot map most of them are empty
    void _Axis(float &out ax, float &out az, float &out nx, float &out nz)
    {
        _EnsureFocus();
        ax = focus.x - Global::Map::StartPos.x; az = focus.z - Global::Map::StartPos.z;
        float len = sqrt(ax * ax + az * az);
        if (len < 1.0f) { ax = 1.0f; az = 0.0f; len = 1.0f; }
        ax /= len; az /= len;
        nx = -az; nz = ax;
    }
    float _Along(const AIFloat3 &in p, float ax, float az) { return (p.x - Global::Map::StartPos.x) * ax + (p.z - Global::Map::StartPos.z) * az; }
    float _Side(const AIFloat3 &in p, float nx, float nz) { return (p.x - Global::Map::StartPos.x) * nx + (p.z - Global::Map::StartPos.z) * nz; }
    AIFloat3 _At(float along, float side, float ax, float az, float nx, float nz)
    {
        return AIFloat3(Global::Map::StartPos.x + ax * along + nx * side, 0.0f, Global::Map::StartPos.z + az * along + nz * side);
    }

    // The lab -> half way to its lane's front point -> its lane's front point ->
    // straight on to the enemy backline (BehindEnemyDistance past the focus), all
    // but the first leg on one line parallel to the axis
    array<AIFloat3> BuildSpreadRoute(const AIFloat3 &in from, float side)
    {
        float ax, az, nx, nz;
        _Axis(ax, az, nx, nz);
        const float back = _Along(focus, ax, az) + Global::Spam::BehindEnemyDistance;
        const float fromAlong = _Along(from, ax, az);
        float frontAlong = hasFront ? _Along(front, ax, az) : fromAlong + (back - fromAlong) * 0.5f;
        if (frontAlong < fromAlong + 200.0f) frontAlong = fromAlong + 200.0f;
        const AIFloat3 fp = _At(frontAlong, side, ax, az, nx, nz);
        array<AIFloat3> route;
        route.insertLast(_Clamp(AIFloat3((from.x + fp.x) * 0.5f, 0.0f, (from.z + fp.z) * 0.5f)));
        route.insertLast(_Clamp(fp));
        route.insertLast(_Clamp(_At(back, side, ax, az, nx, nz)));
        return route;
    }

    // D-119: spread lanes for these factories, one each, LaneSpacing apart, centred
    // on the active front (the combat focus; the axis while none is known), the
    // set shifted to stay on the map. Sorted by the labs' own sideways places, so
    // no two routes cross.
    void SetSpreadLanes(array<CCircuitUnit@>@ labs)
    {
        const uint n = labs.length();
        if (n == 0) return;
        float ax, az, nx, nz;
        _Axis(ax, az, nx, nz);
        const float step = Global::Spam::LaneSpacing;
        const float centre = hasFront ? _Side(front, nx, nz) : 0.0f;
        float first = centre - step * float(n - 1) * 0.5f;
        float last = first + step * float(n - 1);
        // on the map: the corners' sideways places, less the margin
        const float w = float(aiTerrainMgr.GetTerrainWidth()), h = float(aiTerrainMgr.GetTerrainHeight());
        const array<float> cx = { 0.0f, w, 0.0f, w }, cz = { 0.0f, 0.0f, h, h };
        float mlo = 1.0e30f, mhi = -1.0e30f;
        for (uint i = 0; i < 4; ++i) {
            const float s = _Side(AIFloat3(cx[i], 0.0f, cz[i]), nx, nz);
            if (s < mlo) mlo = s;
            if (s > mhi) mhi = s;
        }
        mlo += Global::Spam::MapMargin; mhi -= Global::Spam::MapMargin;
        if (last > mhi) { first -= last - mhi; last = mhi; }
        if (first < mlo) { last += mlo - first; first = mlo; }
        // the labs by their own sideways place
        array<CCircuitUnit@> order;
        array<float> key;
        for (uint i = 0; i < n; ++i) {
            if (labs[i] is null) continue;
            const float s = _Side(labs[i].GetPos(ai.frame), nx, nz);
            uint at = 0;
            while (at < key.length() && key[at] <= s) ++at;
            order.insertAt(at, labs[i]);
            key.insertAt(at, s);
        }
        bool changed = false;
        for (uint i = 0; i < order.length(); ++i) {
            const float side = first + step * float(i);
            const string k = "" + order[i].id;
            float cur = 0.0f;
            if (spreadByFactory.get(k, cur) && abs(cur - side) < 50.0f) continue;
            spreadByFactory.set(k, side);
            changed = true;
            CRouteTask@ task = null;
            array<AIFloat3> points = _RouteOfKey(k, order[i].GetPos(ai.frame));
            if (routeByFactory.get(k, @task) && task !is null && points.length() > 0) task.SetRoute(points);
            GenericHelpers::LogUtil("[Spam] factory " + order[i].id + " runs spread lane " + (i + 1) + " of " + order.length()
                + " at " + int(side) + " elmos sideways (front at " + int(centre) + ", lanes " + int(step) + " apart) (D-119)", 1);
        }
        if (changed) ++routesVersion;
    }
    array<AIFloat3> _RouteOfKey(const string &in key, const AIFloat3 &in from)
    {
        float side = 0.0f;
        int lane = 0;
        if (!laneByFactory.get(key, lane)) lane = 0;
        array<AIFloat3> valid;
        CCircuitUnit@ f = ai.GetTeamUnit(int(parseInt(key)));
        CCircuitDef@ d = f is null ? null : ai.GetCircuitDef(SpamUnitFor(f.circuitDef));
        if (d is null) return valid;
        // the edge lab's lane: its three rally points, already playable and reachable
        if (EdgeLanes::IsEdgeKey(key)) return EdgeLanes::Route(d, from);
        array<AIFloat3> raw = spreadByFactory.get(key, side) ? BuildSpreadRoute(from, side) : BuildRoute(from, lane);
        for (uint i = 0; i < raw.length(); ++i)
            if (aiTerrainMgr.CanTraverse(d, from, raw[i])) valid.insertLast(raw[i]);
        // A lane offset/behind-start extension can fall into water or a cliff.
        // Use the reachable enemy start as the endpoint, never a mid-map stop.
        if (valid.length() == 0 || MapHelpers::SqDist(valid[valid.length()-1], raw[raw.length()-1]) > 1.0f) {
            AIFloat3 end = ReachableNear(d, from, raw[raw.length()-1]);
            if (end.x < 0.0f) end = ReachableNear(d, from, focus);
            if (end.x < 0.0f) { valid.resize(0); return valid; }
            valid.insertLast(end);
        }
        return valid;
    }

    AIFloat3 ReachableNear(CCircuitDef@ def, const AIFloat3 &in from, const AIFloat3 &in desired)
    {
        if (aiTerrainMgr.CanTraverse(def, from, desired)) return desired;
        // A legal commander start can sit on a rim which ordinary bots cannot
        // reach. Find nearby ground in the SAME connected movement area, not
        // merely any dry cell. At most 64 cached area lookups, only on route
        // creation/retarget or bounded factory-site admission, never per unit.
        for (int ring=1; ring<=4; ++ring) for (int k=0; k<16; ++k) {
            const float a=float(k)*0.392699f;
            const AIFloat3 p=_Clamp(AIFloat3(desired.x+cos(a)*float(ring)*256.0f,0,
                desired.z+sin(a)*float(ring)*256.0f));
            if (aiTerrainMgr.CanTraverse(def,from,p)) return p;
        }
        return AIFloat3(-1,0,-1);
    }

    // D-111: the waypoints of a factory's lane, for its factory route
    array<AIFloat3> RouteOf(CCircuitUnit@ factory)
    {
        _EnsureFocus();
        return _RouteOfKey("" + factory.id, factory.GetPos(ai.frame));
    }

    // D-312: logistics borrows a real spam lane without creating a factory or
    // route task. O(F) live route entries, only when planning a delivery. Choose
    // nearest the midpoint of the active lane set; team-local factory ID breaks
    // even-lane ties. Empty sets use the same centreline spam would create.
    array<AIFloat3> DeliveryLane()
    {
        _EnsureFocus();
        array<string>@ keys=routeByFactory.getKeys();
        array<int> ids; array<float> sides;
        float low=1e30f, high=-1e30f;
        for (uint i=0;i<keys.length();++i) {
            CRouteTask@ task;
            CCircuitUnit@ factory=ai.GetTeamUnit(int(parseInt(keys[i])));
            if (EdgeLanes::IsEdgeKey(keys[i])) continue;   // the edge lane is not lent to deliveries
            if (factory is null || !routeByFactory.get(keys[i],@task) || task is null || task.IsDead()) continue;
            float side=0.0f;
            if (!spreadByFactory.get(keys[i],side)) {
                int lane=0;
                if (!laneByFactory.get(keys[i],lane)) lane=0;
                side=float(lane)*Global::Spam::LaneSpacing;
            }
            ids.insertLast(factory.id); sides.insertLast(side);
            low=AiMin(low,side); high=AiMax(high,side);
        }
        int selected=-1; float nearest=1e30f;
        for (uint i=0;i<ids.length();++i) {
            const float distance=abs(sides[i]-(low+high)*0.5f);
            if (distance<nearest || (distance==nearest && ids[i]<selected)) {
                nearest=distance; selected=ids[i];
            }
        }
        if (selected>=0) {
            CCircuitUnit@ factory=ai.GetTeamUnit(selected);
            array<AIFloat3> points=RouteOf(factory);
            points.insertAt(0,factory.GetPos(ai.frame));
            return points;
        }
        float ax,az,nx,nz; _Axis(ax,az,nx,nz);
        array<AIFloat3> points=BuildSpreadRoute(Global::Map::StartPos,hasFront?_Side(front,nx,nz):0.0f);
        points.insertAt(0,Global::Map::StartPos);
        return points;
    }
    int _NextLane()
    {
        // 0, +1, -1, +2, -2, ...
        const int n = lanesIssued++;
        if (n == 0) return 0;
        const int k = (n + 1) / 2;
        return (n % 2 == 1) ? k : -k;
    }

    // The route task of a factory, created on first use.
    CRouteTask@ RouteFor(CCircuitUnit@ factory)
    {
        if (factory is null) return null;
        const string key = "" + factory.id;
        CRouteTask@ task = null;
        if (routeByFactory.get(key, @task) && task !is null) return task;

        _EnsureFocus();
        array<AIFloat3> points = _RouteOfKey(key, factory.GetPos(ai.frame));
        if (points.length() == 0) return null;

        int lane = 0;
        if (!laneByFactory.get(key, lane)) {
            lane = _NextLane();
            laneByFactory.set(key, lane);
        }
        points = _RouteOfKey(key, factory.GetPos(ai.frame));
        if (points.length() == 0) return null;
        IUnitTask@ t = aiMilitaryMgr.Enqueue(TaskF::Route());
        IFighterTask@ ft = cast<IFighterTask>(t);
        @task = (ft is null) ? null : cast<CRouteTask>(ft);
        if (task is null) return null;
        task.SetRoute(points);
        // Spread WITHIN the factory's line: each unit is dealt its own lane
        // across a band, so the stream crosses the map as a broad front that
        // one shell cannot erase and that sees a band's width, then focuses
        // back toward one endpoint. The factory-level offset above keeps
        // different factories' bands apart; this keeps one band from being a
        // single file.
        if (EdgeLanes::IsEdgeKey(key)) task.SetLanes(Global::Spam::EdgeUnitLanes, Global::Spam::EdgeUnitLaneSpacing, Global::Spam::EndSpread);
        else task.SetLanes(Global::Spam::UnitLanes, Global::Spam::UnitLaneSpacing, Global::Spam::EndSpread);
        routeByFactory.set(key, @task);
        ++routesVersion;
        GenericHelpers::LogUtil("[Spam] Route created for factory " + factory.id + " lane " + lane
            + " -> (" + int(Destination().x) + "," + int(Destination().z) + ")", 1);
        return task;
    }

    void RefreshRoutes()
    {
        array<string>@ keys = routeByFactory.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            CRouteTask@ task = null;
            if (!routeByFactory.get(keys[i], @task) || task is null) continue;
            CCircuitUnit@ factory = ai.GetTeamUnit(int(parseInt(keys[i])));
            if (factory is null) { task.Abort(); routeByFactory.delete(keys[i]); continue; }
            // A focus can move to another island. Keep the last reachable
            // backline route until a reachable focus is available.
            array<AIFloat3> points = _RouteOfKey(keys[i], factory.GetPos(ai.frame));
            if (points.length() > 0) task.SetRoute(points);
        }
        ++routesVersion;
    }

    // Nearest known spam factory to a position (spam units spawn at their factory).
    CCircuitUnit@ _NearestSpamFactory(const AIFloat3 &in pos)
    {
        CCircuitUnit@ best = null;
        float bestSq = 1e30f;
        array<string>@ keys = routeByFactory.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            CCircuitUnit@ f = ai.GetTeamUnit(int(parseInt(keys[i])));
            if (f is null || EdgeLanes::IsEdgeKey(keys[i])) continue;
            const float sq = MapHelpers::SqDist(pos, f.GetPos(ai.frame));
            if (sq < bestSq) { bestSq = sq; @best = f; }
        }
        return best;
    }

    /**************************************************************************
     Hooks.
     **************************************************************************/
    // Factory::AiMakeTask asks here first. Returns null when this factory is not
    // producing spam right now, so the normal role logic runs.
    // Log `why` for this factory, but only when it differs from the last answer.
    void _Reject(CCircuitUnit@ factory, const string &in why)
    {
        const string key = "" + factory.id;
        string last = "";
        if (rejectByFactory.get(key, last) && last == why) return;
        rejectByFactory.set(key, why);
        if (why.length() == 0) return;   // memo cleared on success; nothing to say
        GenericHelpers::LogUtil("[Spam] " + factory.circuitDef.GetName() + " (" + factory.id
            + ") not spamming: " + why, 1);
    }

    IUnitTask@ FactoryMakeTask(CCircuitUnit@ factory)
    {
        // D-309: finish the finite opener before converting its producer to a pump.
        if (FrontOpener::OwnsFactory(factory)) return null;
        // owner, 2026-10-17: an edge lab spams its own lane, never as an income pump
        IUnitTask@ edge = EdgeLanes::FactoryMakeTask(factory);
        if (edge !is null) return edge;
        if (EdgeLanes::IsEdgeLab(factory)) return null;
        if (!active || factory is null || factory.circuitDef is null) return null;
        const string unitName = SpamUnitFor(factory.circuitDef);
        if (unitName.length() == 0) {
            // Not a spam factory. Expected for every T2/T3/air/sea factory, so
            // this is the one rejection worth keeping quiet.
            return null;
        }
        if (Lifecycle::IsRetiring(factory)) { _Reject(factory, "retiring"); return null; }
        if (aiBuilderMgr.GetWorkerCount() < Global::Spam::MinWorkers) {
            _Reject(factory, "recovering workers (" + aiBuilderMgr.GetWorkerCount() + ")"); return null;
        }
        CCircuitDef@ d = ai.GetCircuitDef(unitName);
        if (d is null) {
            _Reject(factory, "unit '" + unitName + "' is not a loaded def");
            return null;
        }
        if (int(repeatTask.getSize()) >= LabsWanted()) return null;
        if (d.maxThisUnit < d.count + 50) d.maxThisUnit = d.count + 50;
        if (!d.IsAvailable(ai.frame)) {
            // The likely cause when a listed T1 factory still exists and still
            // produces nothing: a role start limit or a reached unit cap makes
            // the spam unit unavailable.
            _Reject(factory, "'" + unitName + "' unavailable (tech gate or unit limit)");
            return null;
        }
        if (RouteFor(factory) is null) { _Reject(factory, "no reachable enemy land route"); return null; }
        _Reject(factory, "");   // clear only after admission, not on every failed retry
        IUnitTask@ task = aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::FIREPOWER,
            Task::Priority::NORMAL, d, factory.GetPos(ai.frame), 64.f, true));
        repeatTask.set("" + factory.id, @task);
        GenericHelpers::LogUtil("[Spam] repeat factory=" + factory.id + " unit=" + unitName, 1);
        return task;
    }

    // Military::AiMakeTask asks here first. Spam units join their factory's route
    // while spam is active or while any route still exists (units built just
    // before deactivation still go).
    IUnitTask@ MilitaryMakeTask(CCircuitUnit@ u)
    {
        // Also guards AdoptProducedUnits: mature income must not strip a
        // gathering opener into individual lanes before its power threshold.
        if (FrontOpener::OwnsUnit(u)) return null;
        if (EdgeLanes::IsReleased(u)) return null;   // reached its edge lane's end: normal attacks (owner, 2026-10-17)
        if (!IsEnabled() || u is null || !IsSpamDef(u.circuitDef)) return null;
        if (routeByFactory.getSize() == 0) return null;
        const string ukey = "" + u.id;
        int fid = u.GetProducerId();
        CCircuitUnit@ factory = null;
        int saved = -1;
        if (producerOf.get(ukey, saved)) fid = saved;
        if (routeByFactory.exists("" + fid)) @factory = ai.GetTeamUnit(fid);
        if (factory is null) {
            // A known non-spam producer's raiders remain ordinary combat.
            // Only transferred/resurrected units or a destroyed pump fall back.
            if (fid >= 0 && ai.GetTeamUnit(fid) !is null) return null;
            @factory = _NearestSpamFactory(u.GetPos(ai.frame));
            if (factory is null) return null;
            producerOf.set(ukey, factory.id);
        }
        CRouteTask@ task = RouteFor(factory);
        if (task is null) return null;
        routedUnits.set(ukey, factory.id);
        return task;
    }

    // INV-043 (D-111): a spam unit given its lane stays on it (a unit found on
    // another task names what took it: the owner saw routes cleared at once)
    void CheckRoutedUnits()
    {
        if (ai.frame - routeCheckFrame < 10 * SECOND) return;
        routeCheckFrame = ai.frame;
        array<string>@ keys = routedUnits.getKeys();
        int moved = 0;
        string example = "";
        for (uint i = 0; i < keys.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(int(parseInt(keys[i])));
            if (u is null) { routedUnits.delete(keys[i]); producerOf.delete(keys[i]); continue; }
            IFighterTask@ ft = (u.task is null) ? null : cast<IFighterTask>(u.task);
            if (u.task !is null && u.task.GetType() == Task::Type::PLAYER) { routedUnits.delete(keys[i]); continue; }
            CRouteTask@ rt = (ft is null) ? null : cast<CRouteTask>(ft);
            if (rt !is null) continue;
            ++moved;
            if (example.length() == 0) example = u.circuitDef.GetName() + " " + u.id + " now on task type " + ((u.task is null) ? -1 : int(u.task.GetType()));
            routedUnits.delete(keys[i]);
        }
        if (moved > 0) Invariants::Violation("INV-043", "spam", moved + " spam unit(s) left their lane (" + example + ")");
    }

    void OnFactoryRemoved(CCircuitUnit@ factory)
    {
        if (factory is null) return;
        EdgeLanes::OnFactoryRemoved(factory);
        const string key = "" + factory.id;
        CRouteTask@ task = null;
        if (routeByFactory.get(key, @task) && task !is null) {
            task.Abort();   // its units go idle and rejoin the nearest remaining route
        }
        routeByFactory.delete(key);
        laneByFactory.delete(key);
        spreadByFactory.delete(key);
        repeatTask.delete(key);
        factoryVersion.delete(key);
    }

    void OnTaskRemoved(IUnitTask@ task)
    {
        if (task is null || routeByFactory.getSize() == 0) return;
        array<string>@ keys = routeByFactory.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            CRouteTask@ t = null;
            if (routeByFactory.get(keys[i], @t) && t is task) routeByFactory.delete(keys[i]);
        }
    }
}  // namespace Spam
