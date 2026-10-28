// Lolcannons (owner, 2026-10-21; reworked 2026-10-26): Ragnarok, Calamity, Starfall.
#include "../../global.as"
#include "../../task.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/spatial/map_helpers.as"
#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/math/lolcannon_math.as"
#include "lolcannon_scouts.as"

/******************************************************************************

LOLCANNON

The three super cannons (armvulc Ragnarok, corbuzz Calamity, legstarfall
Starfall), "lolcannons", are built by FRONT and TECH only, and only through
this program (owner, 2026-10-26):

  gates   one cannon per entry of the role's gates, then one more every step
          metal/s past the last (owner 2026-10-27): TECH MetalIncomeGates (600)
          + ExtraCannonMetalStep (80), so 600, 680, 760, ...; FRONT
          FrontMetalIncomeGates (500) + FrontExtraCannonMetalStep (500), so
          500, 1000, 1500, ...; MaxCannons caps the count. Each also at
          MinEnergyIncome (5000) energy/s, as 10 s minima
          (Economy::GetMin*IncomeLast10s, so sustained over 10 s). A further
          cannon starts only while every earlier one stands.
  site    on rings round each enemy FRONT spawn (StartSpot role; every enemy
          spawn on a map without roles) that no earlier cannon was sited
          against, so the second covers a different spawn (TargetStarts),
          with the same blueprint, just inside the cannon's range
          (range - SiteRangeMarginMax .. range - SiteRangeMarginMin), the
          candidate nearest our base first, facing that start. The ground is
          measured the way TECH's layout measures its turret box (flat x
          buildable fraction, LayoutBoxMaxSlope) over the cannon, the turret
          block on one side and the storage strip on the other (FRONT keeps
          FrontBlockGap (64) of ground between them and the cannon, for the
          engine's own site search; TECH 16), and must hold
          the cannon's footprint and MinTurrets (16) turrets out of the block
          and its TurretSpareRows, centre out: each footprint is reserved
          through the layout reservations. The storages reserve where they can
          and never refuse a site; the rest are ordered at their spots.
          Further back (owner 2026-10-27): every BackOffAfter (3) failures for
          one cannon - a site search that found nothing, or a cannon order that
          put no frame down over GunMinTrySeconds (30) of orders - move the
          rings SiteBackStep (500)
          further out from the enemy start, past the cannon's reach if need be
          (no enemy start in range is allowed there), up to SiteBackLevels (6).
          When the cannon orders are what failed, the site moves at once (the
          crews stay); a rebuild on a done site that keeps failing gives the
          site up and the cannon is planned afresh. TECH
          keeps the reservations and pins its orders to them; FRONT runs no layout, so
          its orders go to the same spots unpinned: the cannon's, the turret
          block's and the storage strip's reservations are held (owner
          2026-10-28), each let go just before its own order and held again
          every 10 s while empty with no order, so no storage, ally or other
          build of ours lands on them while the turrets go up. An unpinned
          order may go up a little off its slot, so the turrets and storages
          are also counted round the block and the strip, wherever they
          stand: once there are as many as slots, nothing more is ordered
          (a live game put up 20+ storages per cannon). A cannon order alive GunFrameSeconds (300)
          with no frame down is aborted as a failure; a site whose turret
          block stands moves back only after BlockSiteFailures (6) of them.
          The engine drops a build order silently when the site has enemy
          threat on it or the builder cannot reach it, so the cannon is not
          ordered then (logged "held back"); GunFrameSeconds of that is a failure.
  crews   taken off every other task (Builder AiMakeTask asks here first):
            starter  one T2 air constructor: orders the cannon once
                     TurretsBeforeCannon (16) turrets stand (owner
                     2026-10-28: two FRONT cannons went up with none), or
                     TurretWaitSeconds (300) pass with no turret crew at all,
                     or TurretMaxWaitSeconds (900) in any case; turrets
                     meanwhile. A slot given up after three orders is tried
                     again every TurretRetrySeconds (120);
            air      AirCrew (50) air constructors, T1 or T2: build the
                     Turrets (22) of the TurretCols x TurretRows (4x4)
                     block and its spare rows, then assist;
            T1 ground GroundCrew (10) T1 bot or vehicle constructors
                     (owner 2026-10-28), while the block is short: the same
                     as the air crew; ordered from our T1 ground labs, so a
                     FRONT with no air plant still builds its block;
            store    StoreCrew (5) T2 air constructors: build the storages
                     (7 armuwadves / coruwadves, 9 legadvestore for the
                     Starfall) as a strip StorageCols (2) wide, then assist.
                     A storage slot that does not reserve, or whose orders
                     keep failing, moves to the nearest free spot within
                     StoreSearchRadius of the strip, off the turret block and
                     off every other storage slot.
          Our own finished air constructors are claimed first, new ones as
          they come out; the rest are ordered from our air plants,
          CrewRecruitBatch every CrewOrderSeconds. With no plant that makes a
          T2 air constructor, T2 ground constructors stand in for the starter
          and storage crews.
  done    the crews are released (the turret crews first finish any turrets
          still short, the starter and storage crew any storages, up to
          StoreFinishSeconds) and the cannon's fire is tiered (below). A lost
          cannon is rebuilt on its own site.
  fire    Military::AiMakeTask hands each lolcannon's CSuperTask the roster
          below and sets FireState (2, fire at will, owner 2026-10-26; kept
          once a minute); a roster target in range is ordered, best tier first:
            1 advanced fusions, advanced geothermals
            2 Pulsar, Bulwark, Bastion
            3 Keeper, Overseer, Soteria; anti-nukes (Citadel, Prevailer,
              Aegis, Rampart)
            4 commanders, fusions, advanced energy converters
            5 T3 units (what a gantry builds), T2 porc
            6 T1 porc, T1 economy
          Porc is any armed structure that is not a super weapon; T1 is what a
          T1 constructor or commander can build, T2 what only a T2
          constructor can. Native picks the best tier in range, keeps its
          target inside a tier, else the dearest (CSuperTask::UpdateTiered).
          Areas (owner 2026-10-27): the roster targets in range are grouped
          into areas of AreaRadius (300) round the best target left; an area
          ranks by its best tier, then by its roster metal, and is fired at
          its best target. Ragnarok and Calamity work down the top GunAreas
          (6), GunAreaSeconds (30) on each; the Starfall the top
          StarfallAreas (3), StarfallShotsPerArea (2) shots on each; then back
          to the top. Scouting that changes the top area (its best target
          gone, or a better one found) sends the gun back to the top at once
          (CSuperTask::SetTierRotation; TierTargeting.h).
  scouts  the first strike asks the allied AIR for ReconT1Scouts (10) T1
          scouts and ReconRadarScouts (3) radar planes at the strike, spread
          over ReconSpread (600) round it and on to the far map edge; every
          ReScoutSeconds (120) after, the same at the gun's current
          highest-rated area, and at once (at most every ReScoutMinSeconds,
          60) when that area moves further than ReconSpread from the last.
          A cannon that stands BlindScoutSeconds (60) knowing no roster
          target in range has the enemy spawn it was sited against scouted
          instead (again whenever a re-scout is due and none knows one).
          With no AIR on the map TECH builds and flies the package itself
          (team/lolcannon_recon.as, lolcannon_scouts.as).

Every other path is closed: each cannon def's maxThisUnit is held at its count
(every native path - the porc chain's slot 21, AIR's chain, the C++ super
weapon - checks IsAvailable), and any construction task for a cannon that this
program did not order is aborted (AiTaskAdded, then the next tick), whatever
created it. TECH's super cluster and Builder::EnqueueLRPCHeavy defer to this.

Cost: Tick once a second: three cap writes and, while building, a few
FindOwnNear lookups. The crew scan walks our units every CrewOrderSeconds while
a crew is short. The site search runs once per cannon (retried every 30 s on
failure): at most SiteProbes ground scores and reservation tries out of
starts x rings x SiteAngles candidates. The roster is built once a game: one
pass over the defs, CanBuild per constructor def x structure.

******************************************************************************/
namespace LolCannon {

    const int IDLE = 0, BUILD = 1, STORES = 2;   // STORES: the cannon stands, its storage crew finishes the strip
    const int STARTER = 0, AIR = 1, STORE = 2, GROUND = 3;   // GROUND: the T1 ground turret crew
    const array<string> CANNONS = { "armvulc", "corbuzz", "legstarfall" };
    const array<string> T2_GROUND = { "armack", "armacv", "corack", "coracv", "legack", "legacv" };
    const array<string> T1_GROUND = { "armck", "armcv", "corck", "corcv", "legck", "legcv" };

    int phase = IDLE;
    int built = 0;                   // cannons finished by the program (the gate index)
    bool rebuild = false;            // this BUILD restores a lost cannon on a done site
    int started = -1;
    bool ordering = false;
    array<IUnitTask@> pendingAbort;
    array<IUnitTask@> mine;

    // the crews
    dictionary crewOf;               // unit id -> STARTER / AIR / STORE / GROUND
    array<int> crewCount = { 0, 0, 0, 0 };
    array<IUnitTask@> recruitsT2;    // starter and storage crew orders in flight
    array<IUnitTask@> recruitsAir;   // air crew orders in flight
    array<IUnitTask@> recruitsGround;   // T1 ground crew orders in flight
    bool turretsOpen = true;         // a turret slot is still neither standing nor given up (Advance, once a second)
    dictionary groundLabs;           // lab id -> true: labs given a T2 ground stand-in order
    int nextCrewOrder = 0;

    // the site
    AIFloat3 site(-1.0f, 0.0f, -1.0f);
    int facing = 0;
    int gunRes = -1;
    IUnitTask@ gunTask;
    AIFloat3 blockCentre(-1.0f, 0.0f, -1.0f);
    AIFloat3 stripCentre(-1.0f, 0.0f, -1.0f);
    array<AIFloat3> turretPos;
    array<int> turretRes;
    array<IUnitTask@> turretTask;
    array<int> turretMiss;           // orders that came to nothing per slot
    array<AIFloat3> storePos;
    array<int> storeRes;
    array<IUnitTask@> storeTask;
    array<int> storeMiss;
    array<bool> storeDead;           // slots no free spot near the strip was found for
    array<AIFloat3> doneSites;       // the site of every cannon built, for a rebuild
    array<int> doneFacings;
    array<AIFloat3> doneTargets;     // the enemy spawn each finished cannon was sited against
    AIFloat3 siteTarget(-1.0f, 0.0f, -1.0f);   // ... and the one the current site is against
    int nextFireCheck = 0;
    // further back (owner 2026-10-27)
    int fails = 0;                   // failed site searches and cannon orders for this cannon
    int siteLevel = 0;               // the back-off level the current site was found at
    bool moveBack = false;           // the cannon orders failed BackOffAfter times: Advance moves the site
    int nextGunTry = 0;
    int gunOrderedAt = -1;           // the frame the current cannon order was given
    int gunTryFrom = -1;             // the frame the current try (orders with no frame yet) began, -1 none
    int quickEnds = 0;               // orders of this try that ended with no frame
    int unsafeFrom = -1;             // the frame the site was first found unsafe for an order, -1 safe
    int nextUnsafeLog = 0;
    array<AIFloat3> badStoreSpots;   // storage spots whose orders kept failing: not chosen again
    array<AIFloat3> failedSites;     // sites this cannon moved back from: later searches keep SiteAvoidRadius off them

    // the fire roster: def id -> tier 1..6, 0 none
    array<int> tierByDef;
    bool rosterReady = false;

    // the report (owner, 2026-10-26): "[LolCannon] REPORT" lines for the playtest analysis
    int orderFrame = -1;             // the cannon's first order
    int frameFrame = -1;             // its nanoframe first seen
    array<int> watchIds;             // finished cannons whose first target is not yet logged
    array<int> watchSince;

    int nextTick = 0;
    int nextPlan = 0;
    int nextGateLog = 0;
    int storesUntil = 0;
    int nextStoreFix = 0;
    int nextLog = 0;
    int nextTurretWaitLog = 0;
    int nextHold = 0;
    int nextTurretRetry = 0;
    int nextGunHoldLog = 0;
    int nanosNear = 0, nanosNearAll = 0, storesNear = 0, storesNearAll = 0;   // CountSite
    int blockFails = 0;              // cannon order failures on a site whose turret block stands

    bool Enabled() { return Global::LolCannon::Enabled; }
    bool RoleMay() { return Global::AISettings::Role == AiRole::FRONT || Global::AISettings::Role == AiRole::TECH; }
    bool IsCannon(const string &in name) { return CANNONS.find(name) >= 0; }
    string Side() { return Global::AISettings::Side; }
    string Key(int id) { return "" + id; }
    int CrewKind(int id)
    {
        int64 kind = -1;
        return crewOf.get(Key(id), kind) ? int(kind) : -1;
    }

    CCircuitDef@ Gun() { return ai.GetCircuitDef(UnitHelpers::GetLRPCHeavyNameForSide(Side())); }
    CCircuitDef@ Store()
    {
        const string s = Side();
        return ai.GetCircuitDef(s == "legion" ? "legadvestore" : (s == "cortex" ? "coruwadves" : "armuwadves"));
    }
    int StoresNeeded() { return (Side() == "legion") ? Global::LolCannon::LegionStorages : Global::LolCannon::Storages; }
    CCircuitDef@ Nano() { return ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(Side())); }
    bool IsT2Air(const string &in n) { return n == "armaca" || n == "coraca" || n == "legaca"; }
    bool IsT1Air(const string &in n) { return n == "armca" || n == "corca" || n == "legca"; }

    bool Gates(string &out why)
    {
        const float m = Economy::GetMinMetalIncomeLast10s(), e = Economy::GetMinEnergyIncomeLast10s();
        const int secs = ai.frame / SECOND;
        const array<float>@ gates = GateList();
        const int gate = int(Gate());
        why = "cannon " + (built + 1) + ": metal " + int(m) + "/" + gate + ", energy " + int(e) + "/"
            + int(Global::LolCannon::MinEnergyIncome) + " (10 s minima)";
        return Economy::IncomeWindowReady() && secs >= Global::LolCannon::MinGameSeconds && MoreCannons()
            && LolCannonMath::GateOpen(built, m, e, gates, Global::LolCannon::MinEnergyIncome, GateStep());
    }

    // The role's metal gates (owner 2026-10-27: TECH from 600 every 80, FRONT every 500).
    bool IsFront() { return Global::AISettings::Role == AiRole::FRONT; }
    array<float>@ GateList() { return IsFront() ? @Global::LolCannon::FrontMetalIncomeGates : @Global::LolCannon::MetalIncomeGates; }
    float GateStep() { return IsFront() ? Global::LolCannon::FrontExtraCannonMetalStep : Global::LolCannon::ExtraCannonMetalStep; }

    // The next cannon's metal gate, -1 none.
    float Gate()
    {
        return LolCannonMath::GateFor(built, GateList(), GateStep());
    }

    bool MoreCannons()
    {
        return Gate() >= 0.0f && (Global::LolCannon::MaxCannons <= 0 || built < Global::LolCannon::MaxCannons);
    }

    int Level()
    {
        return LolCannonMath::BackLevel(fails, Global::LolCannon::BackOffAfter, Global::LolCannon::SiteBackLevels);
    }

    // ---------------------------------------------------------------- the lock

    void Lock()
    {
        for (uint i = 0; i < CANNONS.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(CANNONS[i]);
            if (d !is null && d.maxThisUnit != d.count) d.maxThisUnit = d.count;
        }
    }

    // Public: a lolcannon crew member (other systems leave these alone).
    bool IsCrew(int id) { return phase != IDLE && CrewKind(id) >= 0; }

    // The starter taken off its cannon order by another system (c18e812e test:
    // FRONT's mex upgrades pulled it as a "helper" of the shared order, for up to
    // 15 min): handed the order back while it stands with no frame. Every 5 s.
    int nextTakeBack = 0;
    void TakeBackStarter()
    {
        if (ai.frame < nextTakeBack || phase != BUILD || gunTask is null || gunTask.IsDead()) return;
        nextTakeBack = ai.frame + 5 * SECOND;
        if (Gun() is null || aiBuilderMgr.FindUnfinishedNear(site, 128.0f, Gun()) !is null) return;
        ProbeOrder();
        array<string>@ keys = crewOf.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            if (CrewKind(parseInt(keys[i])) != STARTER) continue;
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(keys[i]));
            if (u is null || u.task is gunTask) continue;
            IUnitTask@ t = u.task;
            if (t !is null && Mine(t)) continue;   // on a turret or storage of ours
            string unsafe;
            if (!SiteSafe(u, unsafe)) continue;   // the engine would drop it straight off the order again
            GenericHelpers::LogUtil("[LolCannon] starter " + u.circuitDef.GetName() + " " + u.id + " taken back to its cannon order", 1);
            aiBuilderMgr.AssignTask(u, gunTask);
        }
    }

    // Diagnostic (fix 5 test: FRONT orders on safe, reachable sites still put no
    // frame down for 300-1264 s): every 30 s while the order stands with no
    // frame, who is on it, whether the engine found it a build position, and
    // where each starter is and what it does.
    int nextProbe = 0;
    void ProbeOrder()
    {
        if (ai.frame < nextProbe || ai.frame - gunOrderedAt < 20 * SECOND) return;
        nextProbe = ai.frame + 30 * SECOND;
        IBuilderTask@ bt = cast<IBuilderTask>(gunTask);
        array<CCircuitUnit@>@ on = gunTask.GetUnits();
        string s = "[LolCannon] probe: cannon order at (" + int(site.x) + ", " + int(site.z) + ") stands "
            + ((ai.frame - gunOrderedAt) / SECOND) + " s, " + on.length() + " unit(s) on it";
        for (uint i = 0; i < on.length(); ++i) s += (i == 0 ? " [" : ", ") + on[i].circuitDef.GetName() + " " + on[i].id;
        if (on.length() > 0) s += "]";
        if (bt !is null) {
            const AIFloat3 bp = bt.GetBuildPos();
            s += bp.x < 0.0f ? ", no build position" : ", build position (" + int(bp.x) + ", " + int(bp.z) + ") " + int(bp.distance2D(site)) + " off the site";
        }
        array<string>@ keys = crewOf.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            if (CrewKind(parseInt(keys[i])) != STARTER) continue;
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(keys[i]));
            if (u is null) continue;
            IUnitTask@ t = u.task;
            IBuilderTask@ ut = cast<IBuilderTask>(t);
            s += "; starter " + u.circuitDef.GetName() + " " + u.id + " " + int(u.GetPos(ai.frame).distance2D(site)) + " from the site, "
                + (t is null ? "no task" : (t is gunTask ? "on the order" : "task type " + t.GetType()
                + (ut is null ? "" : " build " + ut.GetBuildType() + (ut.buildDef is null ? "" : " " + ut.buildDef.GetName()))
                + (Mine(t) ? " (ours)" : "")));
        }
        GenericHelpers::LogUtil(s, 1);
    }

    bool Mine(IUnitTask@ t)
    {
        for (uint i = 0; i < mine.length(); ++i) if (mine[i] is t) return true;
        return false;
    }

    // Builder AiTaskAdded: a cannon construction this program did not order is aborted
    void TaskAdded(IUnitTask@ task)
    {
        if (!Enabled() || ordering || task is null) return;
        IBuilderTask@ bt = cast<IBuilderTask>(task);
        if (bt is null || bt.buildDef is null || Task::BuildType(bt.GetBuildType()) >= Task::BuildType::REPAIR) return;
        if (!IsCannon(bt.buildDef.GetName())) return;
        pendingAbort.insertLast(task);
        GenericHelpers::LogUtil("[LolCannon] " + bt.buildDef.GetName() + " ordered outside the lolcannon program (type "
            + int(bt.GetBuildType()) + "); aborting it", 1);
    }

    // ---------------------------------------------------------------- the crews

    int Wanted(int kind)
    {
        if (kind == STARTER) return 1;
        if (kind == STORE) return Global::LolCannon::StoreCrew;
        if (kind == GROUND) return Global::LolCannon::GroundCrew;
        return Global::LolCannon::AirCrew;
    }

    // The crew a constructor of this def may join now, -1 none.
    int KindFor(const string &in name, bool groundStandIn)
    {
        if (T1_GROUND.find(name) >= 0) return (turretsOpen && crewCount[GROUND] < Wanted(GROUND)) ? GROUND : -1;
        const bool t2 = IsT2Air(name) || (groundStandIn && T2_GROUND.find(name) >= 0);
        if (!t2 && !IsT1Air(name)) return -1;
        const int kind = LolCannonMath::CrewFor(t2, crewCount[STARTER], crewCount[STORE], Wanted(STORE),
            crewCount[AIR], (groundStandIn && !IsT2Air(name)) ? 0 : Wanted(AIR));
        return kind;
    }

    bool Claim(CCircuitUnit@ u, int kind, const string &in how)
    {
        if (u is null || kind < 0 || kind > GROUND) return false;
        crewOf.set(Key(u.id), int64(kind));
        ++crewCount[kind];
        GenericHelpers::LogUtil("[LolCannon] " + (kind == STARTER ? "starter" : (kind == STORE ? "storage crew " : (kind == GROUND ? "T1 ground crew " : "air crew ")))
            + (kind == STARTER ? "" : ("" + crewCount[kind] + " of " + Wanted(kind))) + ": " + u.circuitDef.GetName() + " " + u.id + " (" + how + ")", 1);
        return true;
    }

    void UnitAdded(CCircuitUnit@ unit)
    {
        if (!Enabled() || phase != BUILD || unit is null || unit.circuitDef is null || crewOf.exists(Key(unit.id))) return;
        const string name = unit.circuitDef.GetName();
        const bool standIn = groundLabs.exists(Key(unit.GetProducerId())) && unit.GetProductionFrame() >= started;
        Claim(unit, KindFor(name, standIn), "new");
    }

    void UnitRemoved(CCircuitUnit@ unit)
    {
        if (unit is null) return;
        const int kind = CrewKind(unit.id);
        if (kind < 0) return;
        crewOf.delete(Key(unit.id));
        if (kind <= GROUND && crewCount[kind] > 0) --crewCount[kind];
    }

    void ReleaseCrew(const string &in why)
    {
        GenericHelpers::LogUtil("[LolCannon] crews released (" + crewCount[STARTER] + " starter, " + crewCount[AIR] + " air, "
            + crewCount[STORE] + " storage, " + crewCount[GROUND] + " T1 ground): " + why, 1);
        crewOf.deleteAll();
        for (uint k = 0; k < crewCount.length(); ++k) crewCount[k] = 0;
        recruitsT2.resize(0);
        recruitsAir.resize(0);
        recruitsGround.resize(0);
        groundLabs.deleteAll();
    }

    // Our own finished air constructors off their tasks, every CrewOrderSeconds while short.
    // O(our units) per scan, only while a crew is short.
    void ClaimOwn()
    {
        if (crewCount[STARTER] >= 1 && crewCount[STORE] >= Wanted(STORE) && crewCount[AIR] >= Wanted(AIR)
            && (crewCount[GROUND] >= Wanted(GROUND) || !turretsOpen)) return;
        // no starter StarterGraceSeconds into the program: our own T2 ground
        // constructors may start the cannon (and fill the storage crew)
        const bool groundT2 = crewCount[STARTER] < 1 && ai.frame - started >= Global::LolCannon::StarterGraceSeconds * SECOND;
        array<Id>@ ids = ai.GetOwnedUnitIds();
        int taken = 0;
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null || u.circuitDef is null || u.GetBuildProgress() < 1.0f || crewOf.exists(Key(u.id))) continue;
            if (u.task !is null && u.task.GetType() == int(Task::Type::PLAYER)) continue;   // a player's own unit
            const bool standIn = groundT2 && T2_GROUND.find(u.circuitDef.GetName()) >= 0;
            const int kind = KindFor(u.circuitDef.GetName(), standIn);
            if (kind < 0 || !Claim(u, kind, standIn ? "taken off its task, ground stand-in" : "taken off its task")) continue;
            IUnitTask@ t = BuilderTask(u);
            if (t !is null) aiBuilderMgr.AssignTask(u, t);
            ++taken;
        }
        if (taken > 0) GenericHelpers::LogUtil("[LolCannon] " + taken + " of our constructors taken for the crews", 1);
    }

    int Alive(array<IUnitTask@>@ tasks)
    {
        for (int i = int(tasks.length()) - 1; i >= 0; --i)
            if (tasks[i] is null || tasks[i].IsDead()) tasks.removeAt(i);
        return int(tasks.length());
    }

    int Queue(CCircuitDef@ d, array<CCircuitUnit@>@ labs, int count, array<IUnitTask@>@ into, bool standIn)
    {
        if (d is null || labs.length() == 0 || count <= 0) return 0;
        if (d.maxThisUnit <= d.count + count) d.maxThisUnit = d.count + count + 1;   // role caps yield to the crew
        int queued = 0;
        for (int k = 0; k < count; ++k) {
            CCircuitUnit@ lab = labs[k % labs.length()];
            IUnitTask@ r = aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, d, lab.GetPos(ai.frame), 64.0f));
            if (r is null) continue;
            into.insertLast(r);
            if (standIn) groundLabs.set(Key(lab.id), true);
            ++queued;
        }
        return queued;
    }

    void Recruit()
    {
        const int needT2 = (1 - crewCount[STARTER]) + (Wanted(STORE) - crewCount[STORE]) - Alive(recruitsT2);
        const int needAir = Wanted(AIR) - crewCount[AIR] - Alive(recruitsAir);
        const int needGround = turretsOpen ? Wanted(GROUND) - crewCount[GROUND] - Alive(recruitsGround) : 0;
        if (needT2 <= 0 && needAir <= 0 && needGround <= 0) return;
        const string s = Side();
        CCircuitDef@ t1Air = ai.GetCircuitDef(UnitHelpers::GetT1AirConstructorNameForSide(s));
        CCircuitDef@ t2Air = ai.GetCircuitDef(UnitHelpers::GetT2AirConstructorNameForSide(s));
        array<CCircuitUnit@> t1Labs, t2Labs, groundT2Labs, groundT1Labs;
        array<CCircuitDef@> groundDefs, groundT1Defs;
        array<string>@ keys = Factory::allFactories.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            CCircuitUnit@ f = null;
            if (!Factory::allFactories.get(keys[i], @f) || f is null || f.circuitDef is null || f.GetBuildProgress() < 1.0f) continue;
            if (t2Air !is null && f.circuitDef.CanBuild(t2Air)) { t2Labs.insertLast(f); continue; }
            if (t1Air !is null && f.circuitDef.CanBuild(t1Air)) { t1Labs.insertLast(f); continue; }
            bool t1Ground = false;
            for (uint n = 0; n < T1_GROUND.length() && !t1Ground; ++n) {
                CCircuitDef@ d = ai.GetCircuitDef(T1_GROUND[n]);
                if (d is null || !f.circuitDef.CanBuild(d)) continue;
                groundT1Labs.insertLast(f); groundT1Defs.insertLast(d);
                t1Ground = true;
            }
            if (t1Ground) continue;
            for (uint n = 0; n < T2_GROUND.length(); ++n) {
                CCircuitDef@ d = ai.GetCircuitDef(T2_GROUND[n]);
                if (d is null || !f.circuitDef.CanBuild(d)) continue;
                groundT2Labs.insertLast(f); groundDefs.insertLast(d);
                break;
            }
        }
        int budget = Global::LolCannon::CrewRecruitBatch, queued = 0;
        string how = "";
        if (needT2 > 0) {
            int q = 0;
            if (t2Labs.length() > 0) { q = Queue(t2Air, t2Labs, AiMin(needT2, budget), recruitsT2, false); how += q + " " + t2Air.GetName(); }
            else if (groundT2Labs.length() > 0) {
                q = Queue(groundDefs[0], groundT2Labs, AiMin(needT2, budget), recruitsT2, true);
                how += q + " " + groundDefs[0].GetName() + " (no plant makes a T2 air constructor)";
            }
            budget -= q; queued += q;
        }
        if (needAir > 0 && budget > 0) {
            int q = 0;
            if (t1Labs.length() > 0) q = Queue(t1Air, t1Labs, AiMin(needAir, budget), recruitsAir, false);
            else if (t2Labs.length() > 0) q = Queue(t2Air, t2Labs, AiMin(needAir, budget), recruitsAir, false);
            if (q > 0) how += (how == "" ? "" : ", ") + q + " for the air crew";
            queued += q;
        }
        if (needGround > 0 && groundT1Labs.length() > 0) {
            // its own batch: the turret block is the one job T1 ground constructors do here
            int q = 0;
            const int n = AiMin(needGround, Global::LolCannon::CrewRecruitBatch);
            for (int k = 0; k < n; ++k) {
                const uint i = uint(k) % groundT1Labs.length();
                CCircuitDef@ d = groundT1Defs[i];
                if (d.maxThisUnit <= d.count + n) d.maxThisUnit = d.count + n + 1;   // role caps yield to the crew
                IUnitTask@ r = aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, d,
                    groundT1Labs[i].GetPos(ai.frame), 64.0f));
                if (r is null) continue;
                recruitsGround.insertLast(r);
                ++q;
            }
            if (q > 0) how += (how == "" ? "" : ", ") + q + " for the T1 ground crew";
            queued += q;
        }
        GenericHelpers::LogUtil("[LolCannon] crews short (starter " + crewCount[STARTER] + "/1, storage " + crewCount[STORE] + "/" + Wanted(STORE)
            + ", air " + crewCount[AIR] + "/" + Wanted(AIR) + ", T1 ground " + crewCount[GROUND] + "/" + Wanted(GROUND) + (turretsOpen ? "" : ", turrets done") + "): "
            + (queued > 0 ? "queued " + how : "no plant to order them from"), 1);
    }

    void OrderCrews()
    {
        if (ai.frame < nextCrewOrder) return;
        nextCrewOrder = ai.frame + Global::LolCannon::CrewOrderSeconds * SECOND;
        ClaimOwn();
        Recruit();
    }

    // ---------------------------------------------------------------- the site

    AIFloat3 Home()
    {
        return (Global::AISettings::Role == AiRole::TECH && Layout::HasComplex()) ? Layout::BaseCentre() : Global::Map::StartPos;
    }

    AIFloat3 At(const AIFloat3 &in c, const AIFloat3 &in side, float across, const AIFloat3 &in fwd, float along)
    {
        return AIFloat3(c.x + side.x * across + fwd.x * along, 0.0f, c.z + side.z * across + fwd.z * along);
    }

    void ReleaseAll(array<int>@ ids)
    {
        for (uint i = 0; i < ids.length(); ++i) if (ids[i] >= 0) aiTerrainMgr.ReleaseReservation(ids[i]);
    }

    // The first `want` candidates that reserve, in order; with `fill`, refused ones
    // (id -1, ordered unpinned) make up the count. Returns the reserved count.
    int Pick(CCircuitDef@ d, const array<AIFloat3> &in cand, int f, int want, bool fill, array<AIFloat3>@ pos, array<int>@ ids)
    {
        pos.resize(0); ids.resize(0);
        array<AIFloat3> refused;
        for (uint i = 0; i < cand.length() && int(pos.length()) < want; ++i) {
            const int id = aiTerrainMgr.CanReserveBuilding(d, cand[i], f) ? aiTerrainMgr.ReserveBuilding(d, cand[i], f) : -1;
            if (id >= 0) { pos.insertLast(aiTerrainMgr.GetReservationPos(id)); ids.insertLast(id); }
            else refused.insertLast(cand[i]);
        }
        const int n = int(pos.length());
        for (uint i = 0; fill && i < refused.length() && int(pos.length()) < want; ++i) { pos.insertLast(refused[i]); ids.insertLast(-1); }
        return n;
    }

    array<AIFloat3> First(const array<AIFloat3> &in a, int n)
    {
        array<AIFloat3> r;
        for (uint i = 0; i < a.length() && int(r.length()) < n; ++i) r.insertLast(a[i]);
        return r;
    }

    int TurretsWanted()
    {
        const int slots = Global::LolCannon::TurretCols * (Global::LolCannon::TurretRows + AiMax(0, Global::LolCannon::TurretSpareRows));
        return AiMin(slots, AiMax(Global::LolCannon::MinTurrets, Global::LolCannon::Turrets));
    }

    // Ground between the cannon and its turret block / storage strip. TECH's pinned
    // order goes straight onto its slot; FRONT's unpinned order goes through the
    // engine's site search, which also wants the cannon's block_map yard
    // (_default_: 3 cells, 48 elmos, each side) clear of turrets and of held
    // slots - with 16 it found no site once the turrets stood (fix 6 test).
    float BlockGap()
    {
        return aiTerrainMgr.IsLayoutEnabled() ? 16.0f : Global::LolCannon::FrontBlockGap;
    }

    // The cannon at gp facing f: the turret block's candidate slots on side `hand`
    // (+1/-1) and the storage strip's on the other, each centre out, spare rows last.
    void Slots(CCircuitDef@ gun, CCircuitDef@ nano, CCircuitDef@ st, const AIFloat3 &in gp, int f, float hand,
        array<AIFloat3> &out turrets, array<AIFloat3> &out stores, AIFloat3 &out block, AIFloat3 &out strip)
    {
        const AIFloat3 fwd = Layout::Fwd(f), side = Layout::Side(f);
        const float gunHalf = LolCannonMath::Pitch(Layout::Across(gun, f)) * 0.5f;
        const int cols = Global::LolCannon::TurretCols, rows = Global::LolCannon::TurretRows + AiMax(0, Global::LolCannon::TurretSpareRows);
        const float nA = LolCannonMath::Pitch(Layout::Across(nano, f)), nL = LolCannonMath::Pitch(Layout::Along(nano, f));
        block = At(gp, side, hand * (gunHalf + BlockGap() + float(cols) * nA * 0.5f), fwd, 0.0f);
        turrets.resize(0);
        for (int i = 0; i < rows; ++i) {
            const int r = LolCannonMath::CentreOut(i, rows);
            for (int c = 0; c < cols; ++c)
                turrets.insertLast(At(block, side, LolCannonMath::Offset(c, cols, nA), fwd, LolCannonMath::Offset(r, rows, nL)));
        }
        const int sc = Global::LolCannon::StorageCols;
        const int sr = LolCannonMath::Rows(StoresNeeded(), sc) + AiMax(0, Global::LolCannon::StorageSpareRows);
        const float sA = LolCannonMath::Pitch(Layout::Across(st, f)), sL = LolCannonMath::Pitch(Layout::Along(st, f));
        strip = At(gp, side, -hand * (gunHalf + BlockGap() + float(sc) * sA * 0.5f), fwd, 0.0f);
        stores.resize(0);
        for (int i = 0; i < sr; ++i) {
            const int r = LolCannonMath::CentreOut(i, sr);
            for (int c = 0; c < sc; ++c)
                stores.insertLast(At(strip, side, LolCannonMath::Offset(c, sc, sA), fwd, LolCannonMath::Offset(r, sr, sL)));
        }
    }

    // TECH's box measure over the cannon, its block and its strip.
    float GroundScore(CCircuitDef@ gun, CCircuitDef@ nano, CCircuitDef@ st, const AIFloat3 &in p, int f)
    {
        const float gunHalf = LolCannonMath::Pitch(Layout::Across(gun, f)) * 0.5f;
        const float blockW = float(Global::LolCannon::TurretCols) * LolCannonMath::Pitch(Layout::Across(nano, f));
        const float stripW = float(Global::LolCannon::StorageCols) * LolCannonMath::Pitch(Layout::Across(st, f));
        const float halfAcross = gunHalf + BlockGap() + AiMax(blockW, stripW);
        const float blockL = float(Global::LolCannon::TurretRows) * LolCannonMath::Pitch(Layout::Along(nano, f));
        const float stripL = float(LolCannonMath::Rows(StoresNeeded(), Global::LolCannon::StorageCols)) * LolCannonMath::Pitch(Layout::Along(st, f));
        const float halfAlong = AiMax(LolCannonMath::Pitch(Layout::Along(gun, f)), AiMax(blockL, stripL)) * 0.5f;
        return aiTerrainMgr.FlatFraction(p, f, halfAcross, halfAlong, Global::RoleSettings::Tech::LayoutBoxMaxSlope)
            * aiTerrainMgr.BuildableFraction(nano, p, halfAcross, halfAlong, f);
    }

    // why the last search found nothing (the "no site" line)
    int refusedGun = 0, shortTurrets = 0, bestTurrets = 0;
    int skipResource = 0, skipLayout = 0, skipFailed = 0;

    bool NearFailed(const AIFloat3 &in p)
    {
        const float r = Global::LolCannon::SiteAvoidRadius;
        for (uint i = 0; i < failedSites.length(); ++i)
            if (MapHelpers::SqDist(failedSites[i], p) < r * r) return true;
        return false;
    }

    // The cannon's footprint at the candidate or one of TrySite's slides: off
    // metal/geo spots and off ally layouts, reservations and structures
    // (CanReserveArea). Cheap rectangle tests before the ground score; what is
    // left for TrySite is our own zones and the engine's ground test.
    bool GunGroundFree(CCircuitDef@ gun, const AIFloat3 &in p, int f)
    {
        const float hA = LolCannonMath::Pitch(Layout::Across(gun, f)) * 0.5f, hL = LolCannonMath::Pitch(Layout::Along(gun, f)) * 0.5f;
        const AIFloat3 side = Layout::Side(f), fwd = Layout::Fwd(f);
        const array<float> slide = { 0.0f, 0.5f, -0.5f, 1.0f, -1.0f };
        bool resource = false;
        for (uint k = 0; k < slide.length(); ++k) {
            const AIFloat3 q = At(p, side, slide[k] * hA * 2.0f, fwd, 0.0f);
            if (aiTerrainMgr.IsResourceAreaBlocked(q, f, hA, hL)) { resource = true; continue; }
            if (aiTerrainMgr.CanReserveArea(q, f, hA, hL)) return true;
        }
        if (resource) ++skipResource; else ++skipLayout;
        return false;
    }
    int storesReserved = 0;          // of the site found
    AIFloat3 firstRefused;           // the first candidate whose cannon was refused, for the native reason
    int firstRefusedF = 0;

    // One candidate: the cannon and MinTurrets turrets reserved, either hand; the
    // storages reserve where they can and never refuse the site. On success the
    // slots are kept (TECH), or held (FRONT, keep false; HoldBlock) and let go
    // one by one for their own unpinned orders.
    bool TrySite(CCircuitDef@ gun, CCircuitDef@ nano, CCircuitDef@ st, const AIFloat3 &in p, int f, bool keep)
    {
        // the cannon at the candidate, else slid sideways (along the ring) up to its own width
        const AIFloat3 side = Layout::Side(f);
        const float w = LolCannonMath::Pitch(Layout::Across(gun, f));
        const array<float> slide = { 0.0f, 0.5f, -0.5f, 1.0f, -1.0f };
        int id = -1;
        for (uint k = 0; k < slide.length() && id < 0; ++k) {
            const AIFloat3 q = At(p, side, slide[k] * w, Layout::Fwd(f), 0.0f);
            if (aiTerrainMgr.CanReserveBuilding(gun, q, f)) id = aiTerrainMgr.ReserveBuilding(gun, q, f);
        }
        if (id < 0) {
            if (refusedGun++ == 0) { firstRefused = p; firstRefusedF = f; }
            return false;
        }
        const AIFloat3 gp = aiTerrainMgr.GetReservationPos(id);
        for (int h = 0; h < 2; ++h) {
            array<AIFloat3> tc, sc, tp, sp;
            AIFloat3 bc, stc;
            Slots(gun, nano, st, gp, f, (h == 0) ? 1.0f : -1.0f, tc, sc, bc, stc);
            array<int> tr, sr;
            const int turrets = Pick(nano, tc, f, TurretsWanted(), false, tp, tr);
            if (turrets < Global::LolCannon::MinTurrets) {
                bestTurrets = AiMax(bestTurrets, turrets);
                ReleaseAll(tr);
                continue;
            }
            storesReserved = Pick(st, sc, f, StoresNeeded(), true, sp, sr);
            site = gp; facing = f; blockCentre = bc; stripCentre = stc;
            turretPos = tp; storePos = sp;
            if (keep) { gunRes = id; turretRes = tr; storeRes = sr; }
            else {
                gunRes = id;
                turretRes = tr; storeRes = sr;
            }
            return true;
        }
        ++shortTurrets;
        aiTerrainMgr.ReleaseReservation(id);
        return false;
    }

    bool IsFrontSpawn(const AIFloat3 &in p)
    {
        if (Global::Map::Config is null) return true;
        StartSpot@[]@ spots = Global::Map::Config.StartSpots;
        if (spots is null || spots.length() == 0) return true;   // no roles on this map: every spawn counts
        StartSpot@ sp = MapHelpers::NearestSpot(p, spots);
        return sp is null || MapHelpers::SqDist(sp.pos, p) > 800.0f * 800.0f || sp.aiRole == AiRole::FRONT;
    }

    bool Targeted(const AIFloat3 &in p)
    {
        for (uint i = 0; i < doneTargets.length(); ++i)
            if (MapHelpers::SqDist(doneTargets[i], p) < 400.0f * 400.0f) return true;
        return false;
    }

    // The enemy spawns this cannon may be sited against (owner, 2026-10-26): enemy
    // FRONT spawns no earlier cannon was sited against; else any such enemy spawn;
    // else (every spawn taken) the front spawns again.
    array<AIFloat3> TargetStarts(string &out why)
    {
        const array<AIFloat3> all = Lanes::EnemyStarts();
        array<AIFloat3> fresh, freshAny, fronts;
        for (uint i = 0; i < all.length(); ++i) {
            const bool front = IsFrontSpawn(all[i]), taken = Targeted(all[i]);
            if (front) fronts.insertLast(all[i]);
            if (!taken) { freshAny.insertLast(all[i]); if (front) fresh.insertLast(all[i]); }
        }
        if (fresh.length() > 0) { why = fresh.length() + " enemy FRONT spawn(s) no cannon is sited against"; return fresh; }
        if (freshAny.length() > 0) { why = "no untargeted enemy FRONT spawn; " + freshAny.length() + " other enemy spawn(s)"; return freshAny; }
        why = "every enemy spawn already has a cannon; " + (fronts.length() > 0 ? "the FRONT spawns again" : "all spawns again");
        return fronts.length() > 0 ? fronts : all;
    }

    bool Plan()
    {
        CCircuitDef@ gun = Gun();
        CCircuitDef@ nano = Nano();
        CCircuitDef@ st = Store();
        if (gun is null || nano is null || st is null) return false;
        string targetWhy;
        const array<AIFloat3> starts = TargetStarts(targetWhy);
        if (starts.length() == 0) {
            GenericHelpers::LogUtil("[LolCannon] no enemy start known; site search retried in 30 s", 1);
            return false;
        }
        const AIFloat3 home = Home();
        const float range = gun.GetMaxRange();
        const float margin = 160.0f;
        // further back after repeated failures: the rings move out, past the cannon's reach if need be
        const int level = Level();
        const float back = LolCannonMath::BackShift(level, Global::LolCannon::SiteBackStep);
        const float marginMin = Global::LolCannon::SiteRangeMarginMin - back, marginMax = Global::LolCannon::SiteRangeMarginMax - back;
        const string backWhy = (level == 0) ? "" : "; back level " + level + " (rings " + int(back) + " further out after " + fails
            + " failures" + (marginMin < 0.0f ? ", the enemy start may be out of reach" : "") + ")";
        const float w = float(AiTerrainWidth()), h = float(AiTerrainHeight());
        // The SiteProbes candidates nearest home, kept sorted (insertion; n = starts x rings x angles).
        array<AIFloat3> best; array<float> bestD; array<int> bestF, bestS;
        // candidates kept: SiteProbes x 4 nearest home; SiteProbes of them may be tried
        const int probes = AiMax(1, Global::LolCannon::SiteProbes) * 4;
        for (uint s = 0; s < starts.length(); ++s) {
            for (int k = 0; ; ++k) {
                const float r = LolCannonMath::RingRadius(range, marginMin, marginMax, Global::LolCannon::SiteRangeStep, k);
                if (r < 0.0f) break;
                for (int a = 0; a < Global::LolCannon::SiteAngles; ++a) {
                    const float ang = float(a) * 6.2831853f / float(AiMax(1, Global::LolCannon::SiteAngles));
                    const AIFloat3 p(starts[s].x + cos(ang) * r, 0.0f, starts[s].z + sin(ang) * r);
                    if (p.x < margin || p.z < margin || p.x > w - margin || p.z > h - margin) continue;
                    const float d = MapHelpers::SqDist(p, home);
                    if (int(best.length()) >= probes && d >= bestD[best.length() - 1]) continue;
                    uint at = best.length();
                    while (at > 0 && bestD[at - 1] > d) --at;
                    best.insertAt(at, p); bestD.insertAt(at, d);
                    bestF.insertAt(at, LolCannonMath::Facing(starts[s].x - p.x, starts[s].z - p.z));
                    bestS.insertAt(at, int(s));
                    if (int(best.length()) > probes) { best.removeLast(); bestD.removeLast(); bestF.removeLast(); bestS.removeLast(); }
                }
            }
        }
        // FRONT runs no layout: the reservations are taken for the search only.
        const bool layoutOn = aiTerrainMgr.IsLayoutEnabled();
        if (!layoutOn && !aiTerrainMgr.SetLayoutEnabled(true)) {
            GenericHelpers::LogUtil("[LolCannon] the profile's layout gate is closed; no site can be measured", 1);
            return false;
        }
        int scored = 0, tried = 0;
        refusedGun = 0; shortTurrets = 0; bestTurrets = 0;
        bool found = false;
        skipResource = 0; skipLayout = 0; skipFailed = 0;
        for (uint i = 0; i < best.length() && !found && tried < Global::LolCannon::SiteProbes; ++i) {
            if (NearFailed(best[i])) { ++skipFailed; continue; }
            if (aiTerrainMgr.IsZoneAlly(best[i]) || !GunGroundFree(gun, best[i], bestF[i])) continue;
            ++scored;
            const float score = GroundScore(gun, nano, st, best[i], bestF[i]);
            if (score < Global::LolCannon::SiteMinScore) continue;
            ++tried;
            found = TrySite(gun, nano, st, best[i], bestF[i], layoutOn);
            if (found) { siteTarget = starts[bestS[i]]; siteLevel = level; }
            if (found)
                GenericHelpers::LogUtil("[LolCannon] site for " + gun.GetName() + " (range " + int(range) + ") at (" + int(site.x) + ", " + int(site.z)
                    + "), facing " + facing + ", " + int(sqrt(bestD[i])) + " from home, ground " + int(score * 100.0f) + "%; "
                    + turretPos.length() + " turrets and " + storePos.length() + " " + st.GetName() + " beside it ("
                    + storesReserved + " storage slots reserved)"
                    + (layoutOn ? " (reserved)" : " (FRONT: cannon, turret block and storage strip held, orders unpinned)") + "; against the enemy spawn at (" + int(siteTarget.x) + ", "
                    + int(siteTarget.z) + "), " + int(sqrt(MapHelpers::SqDist(site, siteTarget))) + " away: " + targetWhy + backWhy, 1);
        }
        if (!found && refusedGun > 0) {
            // one non-quiet try: native logs "RESERVE: refused <def> ...: <why>" (terrain, a blocked cell, the engine's ground test)
            const int probe = aiTerrainMgr.ReserveBuilding(gun, firstRefused, firstRefusedF);
            if (probe >= 0) aiTerrainMgr.ReleaseReservation(probe);
            GenericHelpers::LogUtil("[LolCannon] first refused cannon spot (" + int(firstRefused.x) + ", " + int(firstRefused.z) + ") facing "
                + firstRefusedF + ": " + (probe >= 0 ? "reserves without the pre-check (zone, ally layout or exit lane)" : "see the RESERVE line above"), 1);
        }
        if (!layoutOn) aiTerrainMgr.SetLayoutEnabled(false);
        if (!found)
            GenericHelpers::LogUtil("[LolCannon] no site for " + gun.GetName() + " (range " + int(range) + ") just inside reach of "
                + starts.length() + " enemy start(s): " + best.length() + " candidates, " + scored + " scored, " + tried
                + " tried (cannon refused " + refusedGun + ", turrets short " + shortTurrets + ", best " + bestTurrets + "/"
                + Global::LolCannon::MinTurrets + "); skipped: " + skipResource + " on metal/geo spots, " + skipLayout
                + " on ally layouts, reservations or structures, " + skipFailed + " near a failed site" + backWhy + "; retry in 30 s", 1);
        return found;
    }

    void ResetSlots()
    {
        @gunTask = null;
        turretTask.resize(0); turretMiss.resize(0);
        for (uint i = 0; i < turretPos.length(); ++i) { turretTask.insertLast(null); turretMiss.insertLast(0); }
        storeTask.resize(0); storeMiss.resize(0); storeDead.resize(0); badStoreSpots.resize(0);
        gunTryFrom = -1; quickEnds = 0;
        turretsOpen = true; nextHold = 0; nextTurretWaitLog = 0; blockFails = 0;
        nextTurretRetry = ai.frame + Global::LolCannon::TurretRetrySeconds * SECOND;
        for (uint i = 0; i < storePos.length(); ++i) { storeTask.insertLast(null); storeMiss.insertLast(0); storeDead.insertLast(false); }
        nextStoreFix = 0;
    }

    CCircuitUnit@ StandingGun()
    {
        CCircuitDef@ gun = Gun();
        if (gun is null || site.x < 0.0f) return null;
        CCircuitUnit@ g = aiBuilderMgr.FindOwnNear(site, 96.0f, gun);
        return (g !is null && g.GetBuildProgress() >= 1.0f) ? g : null;
    }

    // ---------------------------------------------------------------- orders

    IUnitTask@ Ordered(IUnitTask@ t)
    {
        if (t !is null) mine.insertLast(t);
        return t;
    }

    // Pinned to its reservation while it holds (TECH), else at the spot itself.
    IUnitTask@ OrderAt(Task::BuildType type, CCircuitDef@ d, const AIFloat3 &in p, int id)
    {
        if (d is null) return null;
        const bool pin = id >= 0 && aiTerrainMgr.GetReservationState(id) == 0;
        const AIFloat3 at = pin ? aiTerrainMgr.GetReservationPos(id) : p;
        ordering = true;
        IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Common(type, Task::Priority::HIGH, d, at, 0.0f, true, 180 * SECOND));
        ordering = false;
        if (t is null) return null;
        if (pin && !AiPinReservation(t, id)) {
            aiBuilderMgr.AbortTask(t);
            GenericHelpers::LogUtil("[LolCannon] could not pin " + d.GetName() + " to slot " + id, 1);
            return null;
        }
        return Ordered(t);
    }

    IUnitTask@ Wait(int seconds) { return aiBuilderMgr.Enqueue(TaskB::Wait(seconds * SECOND)); }

    // A slot list's next piece of work: finish an unfinished one, order a free slot
    // (at most `atOnce` in flight), or help one on its way; null when the list is done.
    // With `full` (as many of d stand or are framed round the list as it has slots,
    // wherever they went up) nothing new is ordered.
    IUnitTask@ SlotWork(CCircuitUnit@ u, CCircuitDef@ d, Task::BuildType type, const array<AIFloat3> &in at, array<int>@ ids,
        array<IUnitTask@>@ tasks, array<int>@ misses, const AIFloat3 &in centre, int atOnce, const string &in what, bool full,
        float near = 260.0f)
    {
        if (d is null || !u.circuitDef.CanBuild(d)) return null;
        CCircuitUnit@ unf = aiBuilderMgr.FindUnfinishedNear(centre, near, d);
        if (unf !is null) return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, unf, 30 * SECOND));
        if (full) return null;
        int flying = 0;
        IUnitTask@ help = null;
        for (uint k = 0; k < tasks.length(); ++k)
            if (tasks[k] !is null && !tasks[k].IsDead()) { ++flying; if (help is null) @help = tasks[k]; }
        for (uint k = 0; k < at.length() && flying < atOnce; ++k) {
            if ((tasks[k] !is null && !tasks[k].IsDead()) || misses[k] >= 3) continue;
            if (aiBuilderMgr.FindOwnNear(at[k], 24.0f, d) !is null) continue;
            if (tasks[k] !is null) ++misses[k];   // its last order ended with nothing standing
            if (ids[k] >= 0 && !aiTerrainMgr.IsLayoutEnabled()) {
                // FRONT: a held slot is let go for its own order, which goes there unpinned
                aiTerrainMgr.ReleaseReservation(ids[k]);
                ids[k] = -1;
            }
            @tasks[k] = OrderAt(type, d, at[k], ids[k]);
            if (tasks[k] is null) { ++misses[k]; continue; }
            GenericHelpers::LogUtil("[LolCannon] " + u.circuitDef.GetName() + " " + u.id + " orders " + what + " " + (k + 1) + " of "
                + at.length() + " at (" + int(at[k].x) + ", " + int(at[k].z) + ")", 2);
            return tasks[k];
        }
        return help;
    }

    IUnitTask@ TurretWork(CCircuitUnit@ u)
    {
        return SlotWork(u, Nano(), Task::BuildType::NANO, turretPos, turretRes, turretTask, turretMiss, blockCentre,
            Global::LolCannon::TurretsAtOnce, "turret", nanosNearAll >= int(turretPos.length()));
    }

    IUnitTask@ StoreWork(CCircuitUnit@ u)
    {
        // full counts the orders in flight too (each may not have its frame down yet):
        // short for a moment at worst, never over
        int flying = 0;
        for (uint k = 0; k < storeTask.length(); ++k) if (storeTask[k] !is null && !storeTask[k].IsDead()) ++flying;
        return SlotWork(u, Store(), Task::BuildType::STORE, storePos, storeRes, storeTask, storeMiss, stripCentre, 2, "storage",
            storesNearAll + flying >= int(storePos.length()), Global::LolCannon::StoreSearchRadius + 64.0f);
    }

    // Our units of d within r of c: finished, and all (frames too).
    void CountNear(CCircuitDef@ d, const AIFloat3 &in c, float r, int &out done, int &out all)
    {
        done = 0; all = 0;
        if (d is null || c.x < 0.0f) return;
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null || u.circuitDef !is d || MapHelpers::SqDist(u.GetPos(ai.frame), c) > r * r) continue;
            ++all;
            if (u.GetBuildProgress() >= 1.0f) ++done;
        }
    }

    // The turrets and storages round the block and the strip, wherever each went up
    // (owner 2026-10-28: a live game put up 20+ storages per cannon, each built a
    // little off its slot, so the slot saw none and ordered again). Once a second.
    void CountSite()
    {
        CountNear(Nano(), blockCentre, 260.0f, nanosNear, nanosNearAll);
        // the storages over a wider ring round the cannon: an unpinned order whose
        // spot was taken goes up wherever native finds room (c18e812e test: 1-6 extra)
        CountNear(Store(), site, Global::LolCannon::StoreCountRadius, storesNear, storesNearAll);
    }

    // Turret slots neither standing nor given up (three orders came to nothing);
    // none once as many turrets stand round the block as it has slots.
    int OpenTurrets()
    {
        CCircuitDef@ nano = Nano();
        if (nanosNear >= int(turretPos.length())) return 0;
        int n = 0;
        for (uint k = 0; k < turretPos.length(); ++k)
            if ((k >= turretMiss.length() || turretMiss[k] < 3) && (nano is null || aiBuilderMgr.FindOwnNear(turretPos[k], 24.0f, nano) is null)) ++n;
        return n;
    }

    // A storage at q would overlap the turret block (its slots and spare rows).
    bool OnTurretBlock(CCircuitDef@ st, const AIFloat3 &in q)
    {
        CCircuitDef@ nano = Nano();
        if (nano is null || st is null || blockCentre.x < 0.0f) return false;
        const AIFloat3 side = Layout::Side(facing), fwd = Layout::Fwd(facing);
        const float dx = q.x - blockCentre.x, dz = q.z - blockCentre.z;
        const float across = dx * side.x + dz * side.z, along = dx * fwd.x + dz * fwd.z;
        const int rows = Global::LolCannon::TurretRows + AiMax(0, Global::LolCannon::TurretSpareRows);
        const float halfA = float(Global::LolCannon::TurretCols) * LolCannonMath::Pitch(Layout::Across(nano, facing)) * 0.5f
            + LolCannonMath::Pitch(Layout::Across(st, facing)) * 0.5f;
        const float halfL = float(rows) * LolCannonMath::Pitch(Layout::Along(nano, facing)) * 0.5f
            + LolCannonMath::Pitch(Layout::Along(st, facing)) * 0.5f;
        return AiMax(across, -across) < halfA && AiMax(along, -along) < halfL;
    }

    // Every TurretRetrySeconds a turret slot given up (three orders came to nothing)
    // is tried again while nothing stands on it.
    void RetryTurrets()
    {
        if (ai.frame < nextTurretRetry) return;
        nextTurretRetry = ai.frame + Global::LolCannon::TurretRetrySeconds * SECOND;
        int n = 0;
        for (uint k = 0; k < turretMiss.length(); ++k)
            if (turretMiss[k] >= 3) { turretMiss[k] = 0; ++n; }
        if (n > 0) GenericHelpers::LogUtil("[LolCannon] " + n + " given-up turret slot(s) tried again", 1);
    }

    // FRONT (layout off): every empty turret and storage slot with no order in
    // flight, and the cannon's footprint while no cannon order is in flight and no
    // frame stands, are held again, so nothing else is built there. Every 10 s
    // while the crews work.
    void HoldBlock()
    {
        if (ai.frame < nextHold || aiTerrainMgr.IsLayoutEnabled()) return;
        nextHold = ai.frame + 10 * SECOND;
        CCircuitDef@ nano = Nano();
        CCircuitDef@ gun = Gun();
        if (nano is null || gun is null) return;
        bool switched = false;
        int held = 0;
        if (phase == BUILD && gunRes < 0 && (gunTask is null || gunTask.IsDead()) && StandingGun() is null
            && aiBuilderMgr.FindUnfinishedNear(site, 128.0f, gun) is null) {
            if (!aiTerrainMgr.SetLayoutEnabled(true)) return;
            switched = true;
            if (aiTerrainMgr.CanReserveBuilding(gun, site, facing)) gunRes = aiTerrainMgr.ReserveBuilding(gun, site, facing);
            if (gunRes >= 0 || ai.frame >= nextGunHoldLog) {
                nextGunHoldLog = ai.frame + 60 * SECOND;
                GenericHelpers::LogUtil("[LolCannon] the cannon's footprint at (" + int(site.x) + ", " + int(site.z) + ") "
                    + (gunRes >= 0 ? "held again" : "not held for now (the engine refuses the ground: a structure or units on it)"), 1);
            }
        }
        for (uint k = 0; k < turretPos.length() && k < turretRes.length(); ++k) {
            if (turretRes[k] >= 0 || turretMiss[k] >= 3 || (turretTask[k] !is null && !turretTask[k].IsDead())) continue;
            if (aiBuilderMgr.FindOwnNear(turretPos[k], 24.0f, nano) !is null) continue;
            if (!switched) {
                if (!aiTerrainMgr.SetLayoutEnabled(true)) return;
                switched = true;
            }
            if (!aiTerrainMgr.CanReserveBuilding(nano, turretPos[k], facing)) continue;
            turretRes[k] = aiTerrainMgr.ReserveBuilding(nano, turretPos[k], facing);
            if (turretRes[k] >= 0) ++held;
        }
        CCircuitDef@ st = Store();
        int heldStores = 0;
        for (uint k = 0; st !is null && k < storePos.length() && k < storeRes.length(); ++k) {
            if (storeRes[k] >= 0 || storeDead[k] || storeMiss[k] >= 3 || (storeTask[k] !is null && !storeTask[k].IsDead())) continue;
            if (storesNear >= int(storePos.length()) || aiBuilderMgr.FindOwnNear(storePos[k], 32.0f, st) !is null) continue;
            if (!switched) {
                if (!aiTerrainMgr.SetLayoutEnabled(true)) return;
                switched = true;
            }
            if (!aiTerrainMgr.CanReserveBuilding(st, storePos[k], facing)) continue;
            storeRes[k] = aiTerrainMgr.ReserveBuilding(st, storePos[k], facing);
            if (storeRes[k] >= 0) ++heldStores;
        }
        if (switched) aiTerrainMgr.SetLayoutEnabled(false);
        if (held + heldStores > 0)
            GenericHelpers::LogUtil("[LolCannon] " + held + " empty turret slot(s) and " + heldStores + " storage slot(s) held again", 1);
    }

    // FRONT's held turret slots still empty when the program ends are let go (and
    // the cannon's footprint, should it still be held).
    void ReleaseHeldBlock()
    {
        if (aiTerrainMgr.IsLayoutEnabled()) return;   // TECH keeps its layout
        ReleaseAll(turretRes);
        for (uint k = 0; k < turretRes.length(); ++k) turretRes[k] = -1;
        ReleaseAll(storeRes);
        for (uint k = 0; k < storeRes.length(); ++k) storeRes[k] = -1;
        if (gunRes >= 0) aiTerrainMgr.ReleaseReservation(gunRes);
        gunRes = -1;
    }

    // Another storage slot's spot (still to build or standing) within a storage's
    // pitch of q: two slots moved in one pass took the same free spot.
    bool TakenStoreSpot(uint slot, const AIFloat3 &in q, float step)
    {
        const float r = step * 0.9f;
        for (uint j = 0; j < storePos.length(); ++j)
            if (j != slot && !storeDead[j] && MapHelpers::SqDist(storePos[j], q) < r * r) return true;
        return false;
    }

    bool BadStoreSpot(const AIFloat3 &in q)
    {
        for (uint i = 0; i < badStoreSpots.length(); ++i)
            if (MapHelpers::SqDist(badStoreSpots[i], q) < 24.0f * 24.0f) return true;
        return false;
    }

    // The nearest spot round the strip, ring by ring out to StoreSearchRadius, where
    // a storage reserves (kept and pinned when `keep`); never within 24 of `avoid`,
    // never on the turret block (owner 2026-10-28), never on another storage slot's spot.
    bool FreeStoreSpot(CCircuitDef@ st, uint slot, const AIFloat3 &in avoid, bool keep, AIFloat3 &out at, int &out id)
    {
        id = -1;
        at = avoid;
        const float step = AiMax(LolCannonMath::Pitch(Layout::Across(st, facing)), LolCannonMath::Pitch(Layout::Along(st, facing)));
        const int rings = int(Global::LolCannon::StoreSearchRadius / step);
        const AIFloat3 side = Layout::Side(facing), fwd = Layout::Fwd(facing);
        for (int r = 0; r <= rings; ++r)
            for (int i = -r; i <= r; ++i)
                for (int j = -r; j <= r; ++j) {
                    if (AiMax(AiMax(i, -i), AiMax(j, -j)) != r) continue;   // this ring's edge only
                    const AIFloat3 q = At(stripCentre, side, float(i) * step, fwd, float(j) * step);
                    if (MapHelpers::SqDist(q, avoid) < 24.0f * 24.0f || BadStoreSpot(q) || OnTurretBlock(st, q) || TakenStoreSpot(slot, q, step)
                        || !aiTerrainMgr.CanReserveBuilding(st, q, facing)) continue;
                    if (keep) {
                        id = aiTerrainMgr.ReserveBuilding(st, q, facing);
                        if (id < 0) continue;
                        at = aiTerrainMgr.GetReservationPos(id);
                    } else at = q;
                    return true;
                }
        return false;
    }

    // Storage slots that cannot be built where the strip put them (refused at the
    // site search, or three orders there came to nothing) move to the nearest free
    // spot round the strip. Every 10 s while the crews work.
    void ReplaceStores()
    {
        if (ai.frame < nextStoreFix) return;
        nextStoreFix = ai.frame + 10 * SECOND;
        CCircuitDef@ st = Store();
        if (st is null || stripCentre.x < 0.0f) return;
        const bool layoutOn = aiTerrainMgr.IsLayoutEnabled();
        bool switched = false;
        for (uint k = 0; k < storePos.length(); ++k) {
            if (storeDead[k] || (storeTask[k] !is null && !storeTask[k].IsDead())) continue;
            const bool failing = storeMiss[k] >= 3;
            if (!failing && (storeRes[k] >= 0 || !layoutOn)) continue;   // reserved, or FRONT's unpinned slot still on its first tries
            if (aiBuilderMgr.FindOwnNear(storePos[k], 24.0f, st) !is null) continue;
            if (!switched && !layoutOn) {
                if (!aiTerrainMgr.SetLayoutEnabled(true)) return;
                switched = true;
            }
            const AIFloat3 old = storePos[k];
            if (storeRes[k] >= 0) { aiTerrainMgr.ReleaseReservation(storeRes[k]); storeRes[k] = -1; }
            AIFloat3 at;
            int id = -1;
            bool ok = false;
            if (!failing && aiTerrainMgr.CanReserveBuilding(st, old, facing)) {   // free again where it was laid out
                id = aiTerrainMgr.ReserveBuilding(st, old, facing);
                ok = id >= 0;
                if (ok) at = aiTerrainMgr.GetReservationPos(id);
            }
            if (failing) badStoreSpots.insertLast(old);   // never back to a spot whose orders kept failing
            if (!ok) ok = FreeStoreSpot(st, k, failing ? old : AIFloat3(-1000.0f, 0.0f, -1000.0f), layoutOn, at, id);
            if (!ok) {
                storeDead[k] = true;
                GenericHelpers::LogUtil("[LolCannon] storage " + (k + 1) + " of " + storePos.length() + " at (" + int(old.x) + ", " + int(old.z)
                    + "): no free spot within " + int(Global::LolCannon::StoreSearchRadius) + " of the strip", 1);
                continue;
            }
            storePos[k] = at; storeRes[k] = id; storeMiss[k] = 0; @storeTask[k] = null;
            GenericHelpers::LogUtil("[LolCannon] storage " + (k + 1) + " of " + storePos.length() + " moved from (" + int(old.x) + ", " + int(old.z)
                + ") to (" + int(at.x) + ", " + int(at.z) + ")" + (failing ? " after 3 failed orders" : ", its slot did not reserve"), 1);
        }
        if (switched) aiTerrainMgr.SetLayoutEnabled(false);
    }

    // Storage slots neither standing nor given up.
    int OpenStores()
    {
        CCircuitDef@ st = Store();
        if (storesNear >= int(storePos.length())) return 0;
        int n = 0;
        for (uint k = 0; k < storePos.length(); ++k)
            if (!storeDead[k] && (st is null || aiBuilderMgr.FindOwnNear(storePos[k], 24.0f, st) is null)) ++n;
        return n;
    }

    // A new cannon order only with `mayOrder` (the starter, or anyone able with no
    // starter in the crew); an order in flight is handed to whoever asks, to help.
    IUnitTask@ CannonWork(CCircuitUnit@ u, bool mayOrder)
    {
        CCircuitDef@ gun = Gun();
        if (gun is null || StandingGun() !is null) return null;
        CCircuitUnit@ gf = aiBuilderMgr.FindUnfinishedNear(site, 128.0f, gun);
        if (gf !is null) {
            gunTryFrom = -1; quickEnds = 0;
            return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, gf, 60 * SECOND));
        }
        if (!u.circuitDef.CanBuild(gun) || moveBack) return null;
        if (gunTask !is null && !gunTask.IsDead()) {
            if (ai.frame - gunOrderedAt < Global::LolCannon::GunFrameSeconds * SECOND) return gunTask;
            // alive with no frame down this long (Swirly Rock: 922 s): a failed try
            aiBuilderMgr.AbortTask(gunTask);
            gunTryFrom = -1; quickEnds = 0;
            nextGunTry = ai.frame + 3 * SECOND;
            GunFailed("the order stood " + ((ai.frame - gunOrderedAt) / SECOND) + " s with no frame down");
            return null;
        }
        if (!mayOrder) return null;
        if (ai.frame < nextGunTry || !TurretsReady()) return null;
        string unsafe;
        if (!SiteSafe(u, unsafe)) {
            // The engine's build-site search only takes ground with no enemy threat
            // that the builder can reach, and drops the order silently otherwise
            // (97cf37d7 test: most FRONT orders never started). Held, not ordered.
            if (unsafeFrom < 0) unsafeFrom = ai.frame;
            const int held = (ai.frame - unsafeFrom) / SECOND;
            nextGunTry = ai.frame + 5 * SECOND;
            if (held >= Global::LolCannon::GunFrameSeconds) {
                unsafeFrom = -1;
                GunFailed("the site stayed " + unsafe + " for " + held + " s");
                return null;
            }
            if (ai.frame >= nextUnsafeLog) {
                nextUnsafeLog = ai.frame + 60 * SECOND;
                GenericHelpers::LogUtil("[LolCannon] cannon order at (" + int(site.x) + ", " + int(site.z) + ") held back: the site is "
                    + unsafe + " for " + u.circuitDef.GetName() + " " + u.id + " (" + held + " s); the engine only builds on safe, reachable ground", 1);
            }
            return null;
        }
        unsafeFrom = -1;
        if (gunTask !is null) {
            // An order that ended with no frame: a try is GunMinTrySeconds of orders with
            // no frame, so a handover (a starter drafted or reassigned) is ordered again,
            // and orders that keep dying count one failure per GunMinTrySeconds.
            @gunTask = null;
            ++quickEnds;
            if (gunTryFrom < 0) gunTryFrom = gunOrderedAt;
            const int tried = (ai.frame - gunTryFrom) / SECOND;
            if (tried >= Global::LolCannon::GunMinTrySeconds) {
                const int n = quickEnds;
                gunTryFrom = ai.frame; quickEnds = 0;
                if (GunFailed(n + " order(s) over " + tried + " s, none put a frame down")) return null;
            }
        }
        if (gunRes >= 0 && !aiTerrainMgr.IsLayoutEnabled()) {
            // FRONT: the held footprint is let go for the order, which goes there unpinned
            aiTerrainMgr.ReleaseReservation(gunRes);
            gunRes = -1;
        }
        @gunTask = OrderAt(Task::BuildType::BIG_GUN, gun, site, gunRes);
        if (gunTask is null) {
            nextGunTry = ai.frame + 10 * SECOND;
            GunFailed("the order was refused");
            return null;
        }
        if (!aiTerrainMgr.IsLayoutEnabled()) {
            // FRONT (unpinned): the engine searches only round the site and, finding
            // no room there, ends the order with a "SITE: aborting" line instead of a
            // silent fallback - or a cannon far off its turret block.
            IBuilderTask@ bt = cast<IBuilderTask>(gunTask);
            if (bt !is null) bt.siteRadius = 128.0f;
        }
        if (orderFrame < 0) orderFrame = ai.frame;
        gunOrderedAt = ai.frame;
        nextGunTry = ai.frame + 3 * SECOND;   // one order at a time: crews asking in the same frame help this one
        string why;
        Gates(why);
        GenericHelpers::LogUtil("[LolCannon] " + u.circuitDef.GetName() + " " + u.id + " orders " + gun.GetName() + " at (" + int(site.x)
            + ", " + int(site.z) + "); " + why, 1);
        return gunTask;
    }

    // Turrets first (owner 2026-10-28): TurretsBeforeCannon stand, or TurretWaitSeconds
    // into the program with no turret crew at all, or TurretMaxWaitSeconds in any case.
    bool TurretsReady()
    {
        const int standing = AiMax(CountStanding(Nano(), turretPos, 24.0f), nanosNear);
        const int want = AiMin(Global::LolCannon::TurretsBeforeCannon, int(turretPos.length()));
        if (standing >= want) return true;
        const bool noCrew = crewCount[AIR] + crewCount[GROUND] == 0 && Alive(recruitsAir) + Alive(recruitsGround) == 0;
        const int waited = (ai.frame - started) / SECOND;
        if ((noCrew && waited >= Global::LolCannon::TurretWaitSeconds) || waited >= Global::LolCannon::TurretMaxWaitSeconds) {
            if (ai.frame >= nextTurretWaitLog) {
                nextTurretWaitLog = ai.frame + 60 * SECOND;
                GenericHelpers::LogUtil("[LolCannon] " + (noCrew ? "no turret crew" : "the turrets are still short") + " after " + waited
                    + " s; the cannon is ordered with " + standing + " of " + want + " turrets", 1);
            }
            return true;
        }
        if (ai.frame >= nextTurretWaitLog) {
            nextTurretWaitLog = ai.frame + 60 * SECOND;
            GenericHelpers::LogUtil("[LolCannon] the cannon waits for its turrets: " + standing + " of " + want + " stand (crews "
                + crewCount[AIR] + " air, " + crewCount[GROUND] + " T1 ground)", 1);
        }
        return false;
    }

    // A cannon order that came to nothing; true when the site is to move further back.
    // The engine's own test for a build site (IBuilderTask::FindBuildSite): no
    // enemy threat on it and the builder can reach it.
    bool SiteSafe(CCircuitUnit@ u, string &out why)
    {
        const float bd = u.circuitDef.GetBuildDistance();
        if (aiTerrainMgr.CanReachAtSafe(u, site, bd)) return true;
        why = aiTerrainMgr.CanReachAt(u, site, bd) ? "under enemy threat" : "out of reach";
        return false;
    }

    bool GunFailed(const string &in why)
    {
        @gunTask = null;
        const int want = AiMin(Global::LolCannon::TurretsBeforeCannon, int(turretPos.length()));
        if (!rebuild && want > 0 && AiMax(CountStanding(Nano(), turretPos, 24.0f), nanosNear) >= want) {
            // the turret block stands: the site is worth more tries before it is left
            ++blockFails;
            const bool leave = blockFails >= Global::LolCannon::BlockSiteFailures;
            GenericHelpers::LogUtil("[LolCannon] cannon order at (" + int(site.x) + ", " + int(site.z) + ") failed: " + why + " (" + blockFails
                + " of " + Global::LolCannon::BlockSiteFailures + " failures with the turret block standing" + (leave ? "; moving further back" : "") + ")", 1);
            if (leave) {
                fails = (Level() + 1) * Global::LolCannon::BackOffAfter;   // one level further back
                blockFails = 0;
                moveBack = true;
            }
            return leave;
        }
        const int before = Level();
        ++fails;
        const bool back = Level() > before || (rebuild && fails >= Global::LolCannon::BackOffAfter);
        GenericHelpers::LogUtil("[LolCannon] cannon order at (" + int(site.x) + ", " + int(site.z) + ") failed: " + why + " (" + fails
            + " failures" + (back ? "; moving further back" : "") + ")", 1);
        if (back) moveBack = true;
        return back;
    }

    // The cannon orders keep failing: a new site further back (the crews stay), or,
    // for a rebuild on a done site, that site given up and the cannon planned afresh.
    void MoveBack()
    {
        moveBack = false;
        if (gunTask !is null && !gunTask.IsDead()) aiBuilderMgr.AbortTask(gunTask);
        @gunTask = null;
        for (uint k = 0; k < turretTask.length(); ++k) if (turretTask[k] !is null && !turretTask[k].IsDead()) aiBuilderMgr.AbortTask(turretTask[k]);
        for (uint k = 0; k < storeTask.length(); ++k) if (storeTask[k] !is null && !storeTask[k].IsDead()) aiBuilderMgr.AbortTask(storeTask[k]);
        if (gunRes >= 0) aiTerrainMgr.ReleaseReservation(gunRes);
        gunRes = -1;
        ReleaseAll(turretRes); ReleaseAll(storeRes);
        turretRes.resize(0); storeRes.resize(0);
        const AIFloat3 old = site;
        failedSites.insertLast(old);
        if (rebuild) {
            for (uint i = 0; i < doneSites.length(); ++i) {
                if (MapHelpers::SqDist(doneSites[i], old) > 1.0f) continue;
                doneSites.removeAt(i); doneFacings.removeAt(i); doneTargets.removeAt(i);
                break;
            }
            if (built > 0) --built;
            rebuild = false;
            GenericHelpers::LogUtil("[LolCannon] the rebuild at (" + int(old.x) + ", " + int(old.z) + ") keeps failing; that site is given up and cannon "
                + (built + 1) + " is planned afresh", 1);
        } else if (Plan()) {
            ResetSlots();
            orderFrame = -1; frameFrame = -1;
            GenericHelpers::LogUtil("[LolCannon] site moved back from (" + int(old.x) + ", " + int(old.z) + ") to (" + int(site.x) + ", " + int(site.z)
                + "), back level " + siteLevel + "; the crews stay", 1);
            return;
        }
        ReleaseCrew("the cannon's site moved");
        phase = IDLE;
        nextPlan = ai.frame + 30 * SECOND;
    }

    // Builder AiMakeTask, asked first: a crew member's next piece of work.
    //   starter: the cannon order (once the turrets stand) and its frame, else turrets
    //   air, T1 ground: turrets, then the cannon
    //   storage: storages, then turrets, then the cannon
    // Once the cannon stands (STORES): the turret crews finish the turrets, the
    // starter and storage crew the storages.
    IUnitTask@ BuilderTask(CCircuitUnit@ u)
    {
        if (!Enabled() || (phase != BUILD && phase != STORES) || u is null || u.circuitDef is null || crewOf.isEmpty()) return null;
        const int kind = CrewKind(u.id);
        if (kind < 0) return null;
        if (phase == STORES) {
            const bool turretCrew = kind == AIR || kind == GROUND;
            IUnitTask@ w = turretCrew ? TurretWork(u) : StoreWork(u);
            if (w is null) @w = turretCrew ? StoreWork(u) : TurretWork(u);
            return (w is null) ? Wait(3) : w;   // the phase ends in FinishStores, not on one crew member's empty hand
        }
        IUnitTask@ t = null;
        // the starter keeps its cannon order when native asks again (Swirly Rock: a
        // FRONT ground starter walking out was handed turret work on a re-ask, and
        // its order stood 300 s untouched)
        if (kind == STARTER) @t = CannonWork(u, true);
        if (t is null && kind == STORE) @t = StoreWork(u);
        if (t is null) @t = TurretWork(u);
        if (t is null) @t = CannonWork(u, crewCount[STARTER] == 0);
        return (t is null) ? Wait(3) : t;
    }

    // ---------------------------------------------------------------- the fire roster

    void Tier(int tier, CCircuitDef@ d)
    {
        if (d is null || d.id < 0 || d.id >= int(tierByDef.length()) || tierByDef[d.id] != 0) return;
        tierByDef[d.id] = tier;
    }

    void TierNames(int tier, const array<string> &in names)
    {
        for (uint i = 0; i < names.length(); ++i) Tier(tier, ai.GetCircuitDef(names[i]));
    }

    bool BuiltBy(CCircuitDef@ d, const array<CCircuitDef@> &in builders)
    {
        for (uint i = 0; i < builders.length(); ++i) if (builders[i].CanBuild(d)) return true;
        return false;
    }

    // Once a game: the first tier a def is put in wins.
    void BuildRoster()
    {
        if (rosterReady) return;
        rosterReady = true;
        const int n = ai.GetDefCount() + 1;
        tierByDef.resize(n);
        for (int i = 0; i < n; ++i) tierByDef[i] = 0;
        const array<string> sides = { "armada", "cortex", "legion" };
        // 1 advanced fusions and advanced geothermals
        TierNames(1, UnitHelpers::GetAllAdvancedFusionReactors());
        TierNames(1, array<string> = { "armageo", "corageo", "legageo", "armuwageo", "coruwageo", "leganavaladvgeo" });
        // 2 Pulsar, Bulwark, Bastion
        TierNames(2, array<string> = { "armanni", "cordoom", "legbastion" });
        // 3 Keeper, Overseer, Soteria; the anti-nukes (Citadel, Prevailer, Aegis, Rampart)
        TierNames(3, array<string> = { "armgate", "corgate", "legdeflector", "legrampart" });
        TierNames(3, UnitHelpers::GetAllAntiNukes());
        // 4 commanders, fusions, advanced energy converters
        for (int i = 1; i < n; ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(i);
            if (UnitHelpers::IsCommander(d)) Tier(4, d);
        }
        TierNames(4, UnitHelpers::GetAllFusionReactors());
        TierNames(4, array<string> = { "armckfus", "armuwfus", "coruwfus" });
        for (uint s = 0; s < sides.length(); ++s) {
            Tier(4, ai.GetCircuitDef(UnitHelpers::GetAdvEnergyConverterNameForSide(sides[s])));
            Tier(4, ai.GetCircuitDef(UnitHelpers::GetAdvNavalEnergyConverterNameForSide(sides[s])));
        }
        // 5 and 6 from the build trees: who can build it decides its tech level
        array<CCircuitDef@> t1, t2, gantries;
        for (int i = 1; i < n; ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(i);
            if (d is null || !d.IsMobile() || d.GetBuildSpeed() <= 0.0f) continue;
            const int level = UnitHelpers::IsCommander(d) ? 1 : UnitHelpers::GetConstructorTier(d);
            if (level == 1) t1.insertLast(d); else if (level == 2) t2.insertLast(d);
        }
        const array<string> gantryNames = UnitHelpers::GetAllGantries();
        for (uint i = 0; i < gantryNames.length(); ++i) {
            CCircuitDef@ g = ai.GetCircuitDef(gantryNames[i]);
            if (g !is null) gantries.insertLast(g);
        }
        const array<string> t1Eco = { "armsolar", "corsolar", "legsolar", "armadvsol", "coradvsol", "legadvsol",
            "armwin", "corwin", "legwin", "armtide", "cortide", "legtide", "armgeo", "corgeo", "leggeo", "armuwgeo", "coruwgeo", "leguwgeo",
            "armmakr", "cormakr", "legeconv", "armfmkr", "corfmkr", "legfeconv",
            "armestor", "corestor", "legestor", "armmstor", "cormstor", "legmstor", "armuwes", "coruwes", "leguwestore", "armuwms", "coruwms", "leguwmstore" };
        for (int i = 1; i < n; ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(i);
            if (d is null || tierByDef[i] != 0) continue;
            if (d.IsMobile()) {
                if (BuiltBy(d, gantries)) Tier(5, d);   // T3 units
                continue;
            }
            const bool armed = d.HasSurfToLand() || d.HasSurfToWater() || d.HasSubToWater() || d.HasSurfToAir();
            const bool porc = armed && !d.IsRoleAny(Unit::Role::SUPER.mask);
            const bool eco = !armed && (d.GetExtractsMetal() > 0.0f || t1Eco.find(d.GetName()) >= 0);
            if (!porc && !eco) continue;
            if (BuiltBy(d, t1)) Tier(6, d);             // T1 porc, T1 economy
            else if (porc && BuiltBy(d, t2)) Tier(5, d);   // T2 porc
        }
        array<int> per(7, 0);
        for (int i = 0; i < n; ++i) if (tierByDef[i] > 0 && tierByDef[i] < 7) ++per[tierByDef[i]];
        for (int t = 1; t <= 6 && ai.teamId == ai.GetLeadTeamId(); ++t) {   // the names, once per ally team
            string names = "";
            for (int i = 0; i < n; ++i) {
                if (tierByDef[i] != t) continue;
                CCircuitDef@ d = ai.GetCircuitDef(i);
                if (d !is null) names += (names == "" ? "" : " ") + d.GetName() + "=" + int(d.costM);
            }
            GenericHelpers::LogUtil("[LolCannon] fire roster tier " + t + " (" + per[t] + "): " + names, 1);
        }
        GenericHelpers::LogUtil("[LolCannon] fire roster: tier 1 " + per[1] + ", 2 " + per[2] + ", 3 " + per[3] + ", 4 " + per[4]
            + ", 5 " + per[5] + ", 6 " + per[6] + " defs (" + t1.length() + " T1 and " + t2.length() + " T2 constructor defs, "
            + gantries.length() + " gantries)", 1);
    }

    // Military AiMakeTask: a lolcannon's CSuperTask orders roster targets; the unit fires at will otherwise.
    void FireControl(CCircuitUnit@ u, IUnitTask@ t)
    {
        if (!Enabled() || !Global::LolCannon::FireTiers || u is null || u.circuitDef is null || t is null
            || !IsCannon(u.circuitDef.GetName())) return;
        CSuperTask@ st = cast<CSuperTask>(t);
        if (st is null) return;
        BuildRoster();
        for (uint i = 0; i < tierByDef.length(); ++i)
            if (tierByDef[i] > 0) st.SetTargetTier(ai.GetCircuitDef(int(i)), tierByDef[i]);
        st.SetTierRetarget(Global::LolCannon::FireRetargetFrames);
        if (u.circuitDef.GetName() == "legstarfall")
            st.SetTierRotation(Global::LolCannon::StarfallAreas, SECOND, Global::LolCannon::StarfallShotsPerArea, Global::LolCannon::AreaRadius);
        else
            st.SetTierRotation(Global::LolCannon::GunAreas, Global::LolCannon::GunAreaSeconds * SECOND, 0, Global::LolCannon::AreaRadius);
        u.SetFireState(Global::LolCannon::FireState);   // owner 2026-10-26: fire at will; the tiered orders pick the target when one is in range
        GenericHelpers::LogUtil("[LolCannon] " + u.circuitDef.GetName() + " " + u.id + " fires at " + st.GetTierCount()
            + " roster defs, best tier first; fire state " + Global::LolCannon::FireState, 1);
    }

    // ---------------------------------------------------------------- the program

    void Begin(bool again)
    {
        rebuild = again;
        started = ai.frame;
        orderFrame = -1;
        frameFrame = -1;
        nextCrewOrder = 0;
        ResetSlots();
        phase = BUILD;
        CCircuitDef@ st = Store();
        GenericHelpers::LogUtil("[LolCannon] program " + (again ? "rebuilds the lost cannon" : "starts cannon " + (built + 1)) + ": crews of 1 + "
            + Wanted(AIR) + " air + " + Wanted(STORE) + " storage + " + Wanted(GROUND) + " T1 ground; " + turretPos.length() + " turrets, " + storePos.length() + " "
            + (st is null ? "storages" : st.GetName()) + ", " + (Gun() is null ? "cannon" : Gun().GetName())
            + (siteLevel > 0 ? "; site at back level " + siteLevel : ""), 1);
    }

    int CountStanding(CCircuitDef@ d, const array<AIFloat3> &in at, float radius)
    {
        int n = 0;
        for (uint k = 0; k < at.length(); ++k) if (d !is null && aiBuilderMgr.FindOwnNear(at[k], radius, d) !is null) ++n;
        return n;
    }

    // One line per finished cannon: when it was ordered, framed, finished, and what stands beside it.
    void Report(CCircuitUnit@ g)
    {
        const float secs = (frameFrame >= 0) ? float(ai.frame - frameFrame) / float(SECOND) : -1.0f;
        GenericHelpers::LogUtil("[LolCannon] REPORT finished cannon=" + (rebuild ? built : built + 1) + (rebuild ? " (rebuild)" : "")
            + " def=" + g.circuitDef.GetName() + " unit=" + g.id + " role=" + (Global::AISettings::Role == AiRole::TECH ? "TECH" : "FRONT")
            + " site=" + int(site.x) + "," + int(site.z) + " program=" + (started / SECOND) + "s ordered=" + (orderFrame < 0 ? -1 : orderFrame / SECOND)
            + "s framed=" + (frameFrame < 0 ? -1 : frameFrame / SECOND) + "s finished=" + (ai.frame / SECOND) + "s build=" + int(secs)
            + "s back=" + siteLevel + " fails=" + fails + " nanos=" + CountStanding(Nano(), turretPos, 24.0f) + "/" + turretPos.length()
            + " storages=" + CountStanding(Store(), storePos, 32.0f) + "/" + storePos.length()
            + " crews=" + crewCount[STARTER] + "+" + crewCount[AIR] + "+" + crewCount[STORE] + "+" + crewCount[GROUND]
            + " metal=" + int(Economy::GetMinMetalIncomeLast10s()) + " energy=" + int(Economy::GetMinEnergyIncomeLast10s()), 1);
        watchIds.insertLast(g.id);
        watchSince.insertLast(ai.frame);
    }

    // The first roster target each finished cannon takes (CSuperTask's TIER log names it).
    void WatchFirstTargets()
    {
        for (int i = int(watchIds.length()) - 1; i >= 0; --i) {
            CCircuitUnit@ g = ai.GetTeamUnit(watchIds[i]);
            CSuperTask@ st = (g is null || g.task is null) ? null : cast<CSuperTask>(g.task);
            const int target = (st is null) ? -1 : st.GetTierTargetId();
            const int waited = (ai.frame - watchSince[i]) / SECOND;
            if (target < 0 && g !is null && waited < 1200) {
                if (waited > 0 && waited % 120 == 0)
                    GenericHelpers::LogUtil("[LolCannon] unit " + watchIds[i] + " no roster target yet after " + waited + "s: task "
                        + (g.task is null ? "none" : (st is null ? "not a super task (type " + g.task.GetType() + ")" : "tiered over " + st.GetTierCount() + " defs")), 1);
                continue;
            }
            GenericHelpers::LogUtil("[LolCannon] REPORT first_target unit=" + watchIds[i] + " enemy=" + target + " at=" + (ai.frame / SECOND)
                + "s after_finish=" + waited + "s" + (g is null ? " (cannon lost)" : (target < 0 ? " (none in 20 min)" : "")), 1);
            watchIds.removeAt(i); watchSince.removeAt(i);
        }
    }

    void Finish()
    {
        Report(StandingGun());
        if (!rebuild) {
            ++built;
            doneSites.insertLast(site);
            doneFacings.insertLast(facing);
            doneTargets.insertLast(siteTarget);
        }
        rebuild = false;
        fails = 0; siteLevel = 0; moveBack = false; failedSites.resize(0);
        CountSite();
        const int stores = AiMax(CountStanding(Store(), storePos, 32.0f), storesNear);
        const int turrets = AiMax(CountStanding(Nano(), turretPos, 24.0f), nanosNear);
        const bool turretsShort = OpenTurrets() > 0;
        if ((stores < int(storePos.length()) || turretsShort) && Global::LolCannon::StoreFinishSeconds > 0) {
            // the storages and turrets are part of the order: their crews stay on them
            KeepOnly(STARTER, STORE, turretsShort, Gun().GetName() + " stands; " + stores + " of " + storePos.length() + " storages, "
                + turrets + " of " + turretPos.length() + " turrets; their crews finish them");
            phase = STORES;
            storesUntil = ai.frame + Global::LolCannon::StoreFinishSeconds * SECOND;
            return;
        }
        ReleaseHeldBlock();
        ReleaseCrew(Gun().GetName() + " stands (" + built + " built; the next at " + int(Gate()) + " metal/s)");
        phase = IDLE;
        nextPlan = ai.frame + 30 * SECOND;
    }

    // The finishing phase: done when every storage stands or no slot is left to
    // build (each short one found no free spot), and no turret slot is left open;
    // or after StoreFinishSeconds. The turret crews go once the turrets are done.
    void FinishStores()
    {
        const int stores = AiMax(CountStanding(Store(), storePos, 32.0f), storesNear);
        const bool done = stores >= int(storePos.length());
        const bool stuck = !done && OpenStores() == 0
            && aiBuilderMgr.FindUnfinishedNear(stripCentre, Global::LolCannon::StoreSearchRadius + 64.0f, Store()) is null;
        const bool turretsDone = !turretsOpen && aiBuilderMgr.FindUnfinishedNear(blockCentre, 260.0f, Nano()) is null;
        if (turretsDone && crewCount[AIR] + crewCount[GROUND] > 0 && !(done || stuck))
            KeepOnly(STARTER, STORE, false, "turrets " + CountStanding(Nano(), turretPos, 24.0f) + " of " + turretPos.length() + " done");
        if (!((done || stuck) && turretsDone) && ai.frame < storesUntil) return;
        string why = "";
        if (stuck) why = " (no free spot near the strip for the other " + (int(storePos.length()) - stores) + ")";
        else if (!done) why = " (gave up after " + Global::LolCannon::StoreFinishSeconds + " s)";
        GenericHelpers::LogUtil("[LolCannon] REPORT storages " + stores + "/" + storePos.length() + " turrets " + CountStanding(Nano(), turretPos, 24.0f)
            + "/" + turretPos.length() + " at=" + (ai.frame / SECOND) + "s" + why, 1);
        ReleaseHeldBlock();
        ReleaseCrew("storage strip " + (done ? "done" : "left short") + ", turrets " + (turretsDone ? "done" : "left short"));
        phase = IDLE;
        nextPlan = ai.frame + 30 * SECOND;
    }

    // Release every crew member but the two kinds given (and the turret crews, air
    // and T1 ground, with `turretCrews`).
    void KeepOnly(int a, int b, bool turretCrews, const string &in why)
    {
        array<string>@ keys = crewOf.getKeys();
        int let = 0;
        for (uint i = 0; i < keys.length(); ++i) {
            int64 v = -1;
            crewOf.get(keys[i], v);
            const int kind = int(v);
            if (kind == a || kind == b || (turretCrews && (kind == AIR || kind == GROUND))) continue;
            crewOf.delete(keys[i]);
            if (kind >= 0 && kind <= GROUND && crewCount[kind] > 0) --crewCount[kind];
            ++let;
        }
        if (!turretCrews) { recruitsAir.resize(0); recruitsGround.resize(0); }
        GenericHelpers::LogUtil("[LolCannon] " + let + " crew released, " + (crewCount[a] + crewCount[b] + (turretCrews ? crewCount[AIR] + crewCount[GROUND] : 0))
            + " kept: " + why, 1);
    }

    // A done site whose cannon is gone: rebuilt on the same spot, unpinned.
    bool CheckLost()
    {
        CCircuitDef@ gun = Gun();
        CCircuitDef@ nano = Nano();
        CCircuitDef@ st = Store();
        if (gun is null || nano is null || st is null) return false;
        for (uint i = 0; i < doneSites.length(); ++i) {
            if (aiBuilderMgr.FindOwnNear(doneSites[i], 96.0f, gun) !is null) continue;
            site = doneSites[i]; facing = doneFacings[i];
            array<AIFloat3> tc, sc;
            Slots(gun, nano, st, site, facing, 1.0f, tc, sc, blockCentre, stripCentre);
            const array<AIFloat3> tp = First(tc, TurretsWanted()), sp = First(sc, StoresNeeded());
            turretPos = tp; storePos = sp;
            gunRes = -1; turretRes.resize(0); storeRes.resize(0);
            for (uint k = 0; k < tp.length(); ++k) turretRes.insertLast(-1);
            for (uint k = 0; k < sp.length(); ++k) storeRes.insertLast(-1);
            fails = 0; siteLevel = 0; moveBack = false; failedSites.resize(0);
            GenericHelpers::LogUtil("[LolCannon] the cannon at (" + int(site.x) + ", " + int(site.z) + ") was lost; the crews rebuild it there", 1);
            Begin(true);
            return true;
        }
        return false;
    }

    void Advance()
    {
        if (phase == BUILD || phase == STORES) {
            CountSite();
            RetryTurrets();
            turretsOpen = OpenTurrets() > 0;
            HoldBlock();
            ReplaceStores();
        }
        if (phase == STORES) {
            FinishStores();
            return;
        }
        if (phase == IDLE) {
            if (CheckLost()) return;
            if (!MoreCannons() || ai.frame < nextPlan) return;
            // a further cannon only while every earlier one stands (a lost one is rebuilt first, above)
            for (uint i = 0; i < doneSites.length(); ++i)
                if (aiBuilderMgr.FindOwnNear(doneSites[i], 96.0f, Gun()) is null) return;
            string why;
            if (!Gates(why)) {
                if (ai.frame >= nextGateLog && Economy::GetMinMetalIncomeLast10s() >= Gate() * 0.5f) {
                    nextGateLog = ai.frame + 60 * SECOND;
                    GenericHelpers::LogUtil("[LolCannon] waiting for the gates: " + why, 1);
                }
                return;
            }
            nextPlan = ai.frame + 30 * SECOND;
            if (Gun() is null || Store() is null) return;
            if (!Plan()) {
                ++fails;   // BackOffAfter of these move the next search's rings further out
                // nothing even at the last level: start over from the first rings (the
                // ground and the layouts change as the game goes); failed sites stay avoided
                if (fails >= Global::LolCannon::BackOffAfter * (Global::LolCannon::SiteBackLevels + 1)) {
                    fails = 0;
                    GenericHelpers::LogUtil("[LolCannon] no site even " + int(LolCannonMath::BackShift(Global::LolCannon::SiteBackLevels,
                        Global::LolCannon::SiteBackStep)) + " further back; the search starts over from the first rings", 1);
                }
                return;
            }
            GenericHelpers::LogUtil("[LolCannon] gates open: " + why, 1);
            Begin(false);
            return;
        }
        if (moveBack && phase == BUILD) {
            MoveBack();
            if (phase != BUILD) return;
        }
        OrderCrews();
        TakeBackStarter();
        if (frameFrame < 0 && Gun() !is null && aiBuilderMgr.FindUnfinishedNear(site, 128.0f, Gun()) !is null) {
            frameFrame = ai.frame;
            GenericHelpers::LogUtil("[LolCannon] REPORT framed at=" + (ai.frame / SECOND) + "s ordered=" + (orderFrame < 0 ? -1 : orderFrame / SECOND) + "s", 1);
        }
        if (StandingGun() !is null) {
            Finish();
            return;
        }
        if (ai.frame >= nextLog) {
            nextLog = ai.frame + 60 * SECOND;
            const int turrets = CountStanding(Nano(), turretPos, 24.0f), stores = CountStanding(Store(), storePos, 32.0f);
            CCircuitUnit@ gf = (Gun() is null) ? null : aiBuilderMgr.FindUnfinishedNear(site, 128.0f, Gun());
            GenericHelpers::LogUtil("[LolCannon] building: crews " + crewCount[STARTER] + "+" + crewCount[AIR] + "+" + crewCount[STORE] + "+" + crewCount[GROUND]
                + " (" + recruitsT2.length() + "+" + recruitsAir.length() + "+" + recruitsGround.length() + " ordered), turrets " + turrets + " of " + turretPos.length()
                + ", storages " + stores + " of " + storePos.length() + ", cannon " + (gf is null ? "not started" : int(gf.GetBuildProgress() * 100.0f) + "%"), 1);
        }
    }

    // Economy AiUpdateEconomy: once a second
    void Tick()
    {
        if (!Enabled() || ai.frame < nextTick) return;
        nextTick = ai.frame + SECOND;
        Lock();
        for (uint i = 0; i < pendingAbort.length(); ++i)
            if (pendingAbort[i] !is null && !pendingAbort[i].IsDead() && !Mine(pendingAbort[i])) aiBuilderMgr.AbortTask(pendingAbort[i]);
        pendingAbort.resize(0);
        for (int i = int(mine.length()) - 1; i >= 0; --i)
            if (mine[i] is null || mine[i].IsDead()) mine.removeAt(i);
        if (RoleMay()) Advance();
        if (watchIds.length() > 0) WatchFirstTargets();
        ScoutAreas();
        LolCannonScouts::Tick();
        if (ai.frame >= nextFireCheck) {
            nextFireCheck = ai.frame + 60 * SECOND;
            KeepFireState();
        }
    }

    // ---------------------------------------------------------------- scouting the strikes

    int nextScout = -1;             // -1: no package yet
    bool struck = false;            // a cannon of ours has fired: its first strike was scouted
    int lastScoutFrame = -1;
    AIFloat3 lastScoutAt(-1, 0, -1);

    void SendScouts(const AIFloat3 &in at, const string &in why)
    {
        lastScoutFrame = ai.frame;
        lastScoutAt = at;
        nextScout = ai.frame + Global::LolCannon::ReScoutSeconds * SECOND;
        LolCannonRecon::Send(Global::LolCannon::ReconT1Scouts, Global::LolCannon::ReconRadarScouts, at,
            Global::LolCannon::ReconSpread, why);
    }

    // One line per cannon: its ranked areas, the one under fire marked.
    void LogAreas(CCircuitUnit@ g, CSuperTask@ st, const string &in why)
    {
        string areas = "";
        const int n = st.GetTierAreaCount(), under = st.GetTierAreaIndex();
        for (int i = 0; i < n; ++i) {
            const AIFloat3 p = st.GetTierAreaPos(i);
            areas += (i > 0 ? "; " : "") + (i == under ? "*" : "") + "#" + (i + 1) + " tier " + st.GetTierAreaTier(i) + " "
                + int(st.GetTierAreaMetal(i)) + "m (" + int(p.x) + "," + int(p.z) + ") target " + st.GetTierAreaTargetId(i);
        }
        GenericHelpers::LogUtil("[LolCannon] AREAS unit=" + g.id + " " + g.circuitDef.GetName() + " (" + why + "): "
            + (n == 0 ? "no roster target in range" : areas), 1);
    }

    // main.as AiSuperWeaponFired: the first strike of any cannon of ours sends the scouts there.
    void Fired(CCircuitUnit@ u, const AIFloat3 &in aim)
    {
        if (!Enabled() || u is null || u.circuitDef is null || !IsCannon(u.circuitDef.GetName())) return;
        if (aim.x < 0.0f || aim.z < 0.0f || struck) return;
        struck = true;
        CSuperTask@ st = (u.task is null) ? null : cast<CSuperTask>(u.task);
        if (st !is null) LogAreas(u, st, "first strike");
        SendScouts(aim, "first strike");
    }

    // After the first strike: the scouts to the current highest-rated area of the
    // first standing cannon that has one, every ReScoutSeconds, or sooner when
    // that area moved. A cannon that has stood BlindScoutSeconds knowing no
    // roster target in range (b4: twelve cannons never fired, so no scouts flew)
    // has the enemy spawn it was sited against scouted instead, before any
    // strike and whenever a re-scout is due and no cannon knows a target.
    // O(done sites) a second.
    int blindSince = -1;
    void ScoutAreas()
    {
        if (Global::LolCannon::ReScoutSeconds <= 0) return;
        const bool due = nextScout >= 0 && ai.frame >= nextScout;
        if (nextScout >= 0 && !due && ai.frame - lastScoutFrame < Global::LolCannon::ReScoutMinSeconds * SECOND) return;
        CCircuitDef@ gun = Gun();
        if (gun is null) return;
        int blind = -1;
        for (uint i = 0; i < doneSites.length(); ++i) {
            CCircuitUnit@ g = aiBuilderMgr.FindOwnNear(doneSites[i], 96.0f, gun);
            CSuperTask@ st = (g is null || g.task is null) ? null : cast<CSuperTask>(g.task);
            if (st is null) continue;
            if (st.GetTierAreaCount() <= 0) {
                if (blind < 0) blind = int(i);
                continue;
            }
            blindSince = -1;
            if (nextScout < 0) return;   // the first strike sends the first package
            const AIFloat3 top = st.GetTierAreaPos(0);
            const float spread = Global::LolCannon::ReconSpread;
            const bool moved = MapHelpers::SqDist(top, lastScoutAt) > spread * spread;
            if (!due && !moved) return;
            LogAreas(g, st, due ? "re-scout" : "top area moved");
            SendScouts(top, due ? "highest-rated area" : "highest-rated area moved");
            return;
        }
        if (blind < 0 || doneTargets[blind].x < 0.0f) { blindSince = -1; return; }
        if (blindSince < 0) blindSince = ai.frame;
        if (nextScout < 0 ? ai.frame - blindSince >= Global::LolCannon::BlindScoutSeconds * SECOND : due) {
            GenericHelpers::LogUtil("[LolCannon] AREAS: no cannon of ours knows a roster target in range ("
                + (ai.frame - blindSince) / SECOND + " s); scouting the enemy spawn it was sited against", 1);
            SendScouts(doneTargets[blind], "no roster target in range");
        }
    }

    // Every standing lolcannon of ours at its fire state, once a minute (a task or a
    // player may have changed it). O(done sites).
    void KeepFireState()
    {
        CCircuitDef@ gun = Gun();
        if (gun is null) return;
        for (uint i = 0; i < doneSites.length(); ++i) {
            CCircuitUnit@ g = aiBuilderMgr.FindOwnNear(doneSites[i], 96.0f, gun);
            if (g !is null && g.GetBuildProgress() >= 1.0f) g.SetFireState(Global::LolCannon::FireState);
        }
    }
}
