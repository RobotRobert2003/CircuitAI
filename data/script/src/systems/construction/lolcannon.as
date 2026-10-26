// Lolcannons (owner, 2026-10-21; reworked 2026-10-26): Ragnarok, Calamity, Starfall.
#include "../../global.as"
#include "../../task.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/spatial/map_helpers.as"
#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/math/lolcannon_math.as"

/******************************************************************************

LOLCANNON

The three super cannons (armvulc Ragnarok, corbuzz Calamity, legstarfall
Starfall), "lolcannons", are built by FRONT and TECH only, and only through
this program (owner, 2026-10-26):

  gates   one cannon per MetalIncomeGates entry: the first at 600 metal/s, the
          second at 1000, each also at MinEnergyIncome (5000) energy/s, as 10 s
          minima (Economy::GetMin*IncomeLast10s, so sustained over 10 s). A
          further cannon starts only while every earlier one stands.
  site    on rings round each enemy FRONT spawn (StartSpot role; every enemy
          spawn on a map without roles) that no earlier cannon was sited
          against, so the second covers a different spawn (TargetStarts),
          with the same blueprint, just inside the cannon's range
          (range - SiteRangeMarginMax .. range - SiteRangeMarginMin), the
          candidate nearest our base first, facing that start. The ground is
          measured the way TECH's layout measures its turret box (flat x
          buildable fraction, LayoutBoxMaxSlope) over the cannon, the turret
          block on one side and the storage strip on the other, and must hold
          the cannon's footprint and MinTurrets (16) turrets out of the block
          and its TurretSpareRows, centre out: each footprint is reserved
          through the layout reservations. The storages reserve where they can
          and never refuse a site; the rest are ordered at their spots. TECH
          keeps the reservations and pins its orders to them; FRONT runs no layout, so
          its reservations are taken only for the search and its orders go to
          the same spots unpinned.
  crews   taken off every other task (Builder AiMakeTask asks here first):
            starter  one T2 air constructor: orders the cannon at once;
            air      AirCrew (50) air constructors, T1 or T2: build the
                     TurretCols x TurretRows (4x4) turret block, then assist;
            store    StoreCrew (5) T2 air constructors: build the storages
                     (6 armuwadves / coruwadves, 8 legadvestore for the
                     Starfall) as a strip StorageCols (2) wide, then assist.
                     A storage slot that does not reserve, or whose orders
                     keep failing, moves to the nearest free spot within
                     StoreSearchRadius of the strip.
          Our own finished air constructors are claimed first, new ones as
          they come out; the rest are ordered from our air plants,
          CrewRecruitBatch every CrewOrderSeconds. With no plant that makes a
          T2 air constructor, T2 ground constructors stand in for the starter
          and storage crews.
  done    the air crew is released (the starter and storage crew first finish
          any storages still short, up to StoreFinishSeconds), the cannon's fire is tiered (below) and the
          AIR ally is asked for one scout sweep of ReconT1Scouts T1 scouts and
          ReconRadarScouts radar/sonar planes (team/lolcannon_recon.as). A
          lost cannon is rebuilt on its own site.
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
    const int STARTER = 0, AIR = 1, STORE = 2;
    const array<string> CANNONS = { "armvulc", "corbuzz", "legstarfall" };
    const array<string> T2_GROUND = { "armack", "armacv", "corack", "coracv", "legack", "legacv" };

    int phase = IDLE;
    int built = 0;                   // cannons finished by the program (the gate index)
    bool rebuild = false;            // this BUILD restores a lost cannon on a done site
    int started = -1;
    bool ordering = false;
    array<IUnitTask@> pendingAbort;
    array<IUnitTask@> mine;

    // the crews
    dictionary crewOf;               // unit id -> STARTER / AIR / STORE
    array<int> crewCount = { 0, 0, 0 };
    array<IUnitTask@> recruitsT2;    // starter and storage crew orders in flight
    array<IUnitTask@> recruitsAir;   // air crew orders in flight
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
        const array<float>@ gates = @Global::LolCannon::MetalIncomeGates;
        const int gate = (built < int(gates.length())) ? int(gates[built]) : -1;
        why = "cannon " + (built + 1) + ": metal " + int(m) + "/" + gate + ", energy " + int(e) + "/"
            + int(Global::LolCannon::MinEnergyIncome) + " (10 s minima)";
        return Economy::IncomeWindowReady() && secs >= Global::LolCannon::MinGameSeconds
            && LolCannonMath::GateOpen(built, m, e, gates, Global::LolCannon::MinEnergyIncome);
    }

    // ---------------------------------------------------------------- the lock

    void Lock()
    {
        for (uint i = 0; i < CANNONS.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(CANNONS[i]);
            if (d !is null && d.maxThisUnit != d.count) d.maxThisUnit = d.count;
        }
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
        return Global::LolCannon::AirCrew;
    }

    // The crew a constructor of this def may join now, -1 none.
    int KindFor(const string &in name, bool groundStandIn)
    {
        const bool t2 = IsT2Air(name) || (groundStandIn && T2_GROUND.find(name) >= 0);
        if (!t2 && !IsT1Air(name)) return -1;
        const int kind = LolCannonMath::CrewFor(t2, crewCount[STARTER], crewCount[STORE], Wanted(STORE),
            crewCount[AIR], (groundStandIn && !IsT2Air(name)) ? 0 : Wanted(AIR));
        return kind;
    }

    bool Claim(CCircuitUnit@ u, int kind, const string &in how)
    {
        if (u is null || kind < 0 || kind > STORE) return false;
        crewOf.set(Key(u.id), int64(kind));
        ++crewCount[kind];
        GenericHelpers::LogUtil("[LolCannon] " + (kind == STARTER ? "starter" : (kind == STORE ? "storage crew " : "air crew "))
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
        if (kind <= STORE && crewCount[kind] > 0) --crewCount[kind];
    }

    void ReleaseCrew(const string &in why)
    {
        GenericHelpers::LogUtil("[LolCannon] crews released (" + crewCount[STARTER] + " starter, " + crewCount[AIR] + " air, "
            + crewCount[STORE] + " storage): " + why, 1);
        crewOf.deleteAll();
        for (uint k = 0; k < crewCount.length(); ++k) crewCount[k] = 0;
        recruitsT2.resize(0);
        recruitsAir.resize(0);
        groundLabs.deleteAll();
    }

    // Our own finished air constructors off their tasks, every CrewOrderSeconds while short.
    // O(our units) per scan, only while a crew is short.
    void ClaimOwn()
    {
        if (crewCount[STARTER] >= 1 && crewCount[STORE] >= Wanted(STORE) && crewCount[AIR] >= Wanted(AIR)) return;
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
        if (taken > 0) GenericHelpers::LogUtil("[LolCannon] " + taken + " of our air constructors taken for the crews", 1);
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
        if (needT2 <= 0 && needAir <= 0) return;
        const string s = Side();
        CCircuitDef@ t1Air = ai.GetCircuitDef(UnitHelpers::GetT1AirConstructorNameForSide(s));
        CCircuitDef@ t2Air = ai.GetCircuitDef(UnitHelpers::GetT2AirConstructorNameForSide(s));
        array<CCircuitUnit@> t1Labs, t2Labs, groundT2Labs;
        array<CCircuitDef@> groundDefs;
        array<string>@ keys = Factory::allFactories.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            CCircuitUnit@ f = null;
            if (!Factory::allFactories.get(keys[i], @f) || f is null || f.circuitDef is null || f.GetBuildProgress() < 1.0f) continue;
            if (t2Air !is null && f.circuitDef.CanBuild(t2Air)) { t2Labs.insertLast(f); continue; }
            if (t1Air !is null && f.circuitDef.CanBuild(t1Air)) { t1Labs.insertLast(f); continue; }
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
        GenericHelpers::LogUtil("[LolCannon] crews short (starter " + crewCount[STARTER] + "/1, storage " + crewCount[STORE] + "/" + Wanted(STORE)
            + ", air " + crewCount[AIR] + "/" + Wanted(AIR) + "): " + (queued > 0 ? "queued " + how : "no plant to order them from"), 1);
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

    int TurretsWanted() { return AiMax(Global::LolCannon::MinTurrets, Global::LolCannon::TurretCols * Global::LolCannon::TurretRows); }

    // The cannon at gp facing f: the turret block's candidate slots on side `hand`
    // (+1/-1) and the storage strip's on the other, each centre out, spare rows last.
    void Slots(CCircuitDef@ gun, CCircuitDef@ nano, CCircuitDef@ st, const AIFloat3 &in gp, int f, float hand,
        array<AIFloat3> &out turrets, array<AIFloat3> &out stores, AIFloat3 &out block, AIFloat3 &out strip)
    {
        const AIFloat3 fwd = Layout::Fwd(f), side = Layout::Side(f);
        const float gunHalf = LolCannonMath::Pitch(Layout::Across(gun, f)) * 0.5f;
        const int cols = Global::LolCannon::TurretCols, rows = Global::LolCannon::TurretRows + AiMax(0, Global::LolCannon::TurretSpareRows);
        const float nA = LolCannonMath::Pitch(Layout::Across(nano, f)), nL = LolCannonMath::Pitch(Layout::Along(nano, f));
        block = At(gp, side, hand * (gunHalf + 16.0f + float(cols) * nA * 0.5f), fwd, 0.0f);
        turrets.resize(0);
        for (int i = 0; i < rows; ++i) {
            const int r = LolCannonMath::CentreOut(i, rows);
            for (int c = 0; c < cols; ++c)
                turrets.insertLast(At(block, side, LolCannonMath::Offset(c, cols, nA), fwd, LolCannonMath::Offset(r, rows, nL)));
        }
        const int sc = Global::LolCannon::StorageCols;
        const int sr = LolCannonMath::Rows(StoresNeeded(), sc) + AiMax(0, Global::LolCannon::StorageSpareRows);
        const float sA = LolCannonMath::Pitch(Layout::Across(st, f)), sL = LolCannonMath::Pitch(Layout::Along(st, f));
        strip = At(gp, side, -hand * (gunHalf + 16.0f + float(sc) * sA * 0.5f), fwd, 0.0f);
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
        const float halfAcross = gunHalf + 16.0f + AiMax(blockW, stripW);
        const float blockL = float(Global::LolCannon::TurretRows) * LolCannonMath::Pitch(Layout::Along(nano, f));
        const float stripL = float(LolCannonMath::Rows(StoresNeeded(), Global::LolCannon::StorageCols)) * LolCannonMath::Pitch(Layout::Along(st, f));
        const float halfAlong = AiMax(LolCannonMath::Pitch(Layout::Along(gun, f)), AiMax(blockL, stripL)) * 0.5f;
        return aiTerrainMgr.FlatFraction(p, f, halfAcross, halfAlong, Global::RoleSettings::Tech::LayoutBoxMaxSlope)
            * aiTerrainMgr.BuildableFraction(nano, p, halfAcross, halfAlong, f);
    }

    // why the last search found nothing (the "no site" line)
    int refusedGun = 0, shortTurrets = 0, bestTurrets = 0;
    int skipResource = 0, skipLayout = 0;

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
    // slots are kept (TECH) or read and released (FRONT, keep false).
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
                aiTerrainMgr.ReleaseReservation(id); ReleaseAll(tr); ReleaseAll(sr);
                gunRes = -1;
                turretRes.resize(0); storeRes.resize(0);
                for (uint i = 0; i < tp.length(); ++i) turretRes.insertLast(-1);
                for (uint i = 0; i < sp.length(); ++i) storeRes.insertLast(-1);
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
        const float w = float(AiTerrainWidth()), h = float(AiTerrainHeight());
        // The SiteProbes candidates nearest home, kept sorted (insertion; n = starts x rings x angles).
        array<AIFloat3> best; array<float> bestD; array<int> bestF, bestS;
        // candidates kept: SiteProbes x 4 nearest home; SiteProbes of them may be tried
        const int probes = AiMax(1, Global::LolCannon::SiteProbes) * 4;
        for (uint s = 0; s < starts.length(); ++s) {
            for (int k = 0; ; ++k) {
                const float r = LolCannonMath::RingRadius(range, Global::LolCannon::SiteRangeMarginMin, Global::LolCannon::SiteRangeMarginMax,
                    Global::LolCannon::SiteRangeStep, k);
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
        skipResource = 0; skipLayout = 0;
        for (uint i = 0; i < best.length() && !found && tried < Global::LolCannon::SiteProbes; ++i) {
            if (aiTerrainMgr.IsZoneAlly(best[i]) || !GunGroundFree(gun, best[i], bestF[i])) continue;
            ++scored;
            const float score = GroundScore(gun, nano, st, best[i], bestF[i]);
            if (score < Global::LolCannon::SiteMinScore) continue;
            ++tried;
            found = TrySite(gun, nano, st, best[i], bestF[i], layoutOn);
            if (found) siteTarget = starts[bestS[i]];
            if (found)
                GenericHelpers::LogUtil("[LolCannon] site for " + gun.GetName() + " (range " + int(range) + ") at (" + int(site.x) + ", " + int(site.z)
                    + "), facing " + facing + ", " + int(sqrt(bestD[i])) + " from home, ground " + int(score * 100.0f) + "%; "
                    + turretPos.length() + " turrets and " + storePos.length() + " " + st.GetName() + " beside it ("
                    + storesReserved + " storage slots reserved)"
                    + (layoutOn ? " (reserved)" : " (FRONT: unpinned)") + "; against the enemy spawn at (" + int(siteTarget.x) + ", "
                    + int(siteTarget.z) + "): " + targetWhy, 1);
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
                + " on ally layouts, reservations or structures; retry in 30 s", 1);
        return found;
    }

    void ResetSlots()
    {
        @gunTask = null;
        turretTask.resize(0); turretMiss.resize(0);
        for (uint i = 0; i < turretPos.length(); ++i) { turretTask.insertLast(null); turretMiss.insertLast(0); }
        storeTask.resize(0); storeMiss.resize(0); storeDead.resize(0);
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
    IUnitTask@ SlotWork(CCircuitUnit@ u, CCircuitDef@ d, Task::BuildType type, const array<AIFloat3> &in at, array<int>@ ids,
        array<IUnitTask@>@ tasks, array<int>@ misses, const AIFloat3 &in centre, int atOnce, const string &in what, float near = 260.0f)
    {
        if (d is null || !u.circuitDef.CanBuild(d)) return null;
        CCircuitUnit@ unf = aiBuilderMgr.FindUnfinishedNear(centre, near, d);
        if (unf !is null) return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, unf, 30 * SECOND));
        int flying = 0;
        IUnitTask@ help = null;
        for (uint k = 0; k < tasks.length(); ++k)
            if (tasks[k] !is null && !tasks[k].IsDead()) { ++flying; if (help is null) @help = tasks[k]; }
        for (uint k = 0; k < at.length() && flying < atOnce; ++k) {
            if ((tasks[k] !is null && !tasks[k].IsDead()) || misses[k] >= 3) continue;
            if (aiBuilderMgr.FindOwnNear(at[k], 24.0f, d) !is null) continue;
            if (tasks[k] !is null) ++misses[k];   // its last order ended with nothing standing
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
            Global::LolCannon::TurretsAtOnce, "turret");
    }

    IUnitTask@ StoreWork(CCircuitUnit@ u)
    {
        return SlotWork(u, Store(), Task::BuildType::STORE, storePos, storeRes, storeTask, storeMiss, stripCentre, 2, "storage",
            Global::LolCannon::StoreSearchRadius + 64.0f);
    }

    // The nearest spot round the strip, ring by ring out to StoreSearchRadius, where
    // a storage reserves (kept and pinned when `keep`); never within 24 of `avoid`.
    bool FreeStoreSpot(CCircuitDef@ st, const AIFloat3 &in avoid, bool keep, AIFloat3 &out at, int &out id)
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
                    if (MapHelpers::SqDist(q, avoid) < 24.0f * 24.0f || !aiTerrainMgr.CanReserveBuilding(st, q, facing)) continue;
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
            if (!ok) ok = FreeStoreSpot(st, failing ? old : AIFloat3(-1000.0f, 0.0f, -1000.0f), layoutOn, at, id);
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
        int n = 0;
        for (uint k = 0; k < storePos.length(); ++k)
            if (!storeDead[k] && (st is null || aiBuilderMgr.FindOwnNear(storePos[k], 24.0f, st) is null)) ++n;
        return n;
    }

    IUnitTask@ CannonWork(CCircuitUnit@ u)
    {
        CCircuitDef@ gun = Gun();
        if (gun is null || StandingGun() !is null) return null;
        CCircuitUnit@ gf = aiBuilderMgr.FindUnfinishedNear(site, 128.0f, gun);
        if (gf !is null) return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, gf, 60 * SECOND));
        if (!u.circuitDef.CanBuild(gun)) return null;
        if (gunTask !is null && !gunTask.IsDead()) return gunTask;
        @gunTask = OrderAt(Task::BuildType::BIG_GUN, gun, site, gunRes);
        if (gunTask !is null) {
            if (orderFrame < 0) orderFrame = ai.frame;
            string why;
            Gates(why);
            GenericHelpers::LogUtil("[LolCannon] " + u.circuitDef.GetName() + " " + u.id + " orders " + gun.GetName() + " at (" + int(site.x)
                + ", " + int(site.z) + "); " + why, 1);
        }
        return gunTask;
    }

    // Builder AiMakeTask, asked first: a crew member's next piece of work.
    //   starter: the cannon order, then turrets, then the cannon
    //   air:     turrets, then the cannon
    //   storage: storages, then turrets, then the cannon
    IUnitTask@ BuilderTask(CCircuitUnit@ u)
    {
        if (!Enabled() || (phase != BUILD && phase != STORES) || u is null || u.circuitDef is null || crewOf.isEmpty()) return null;
        const int kind = CrewKind(u.id);
        if (kind < 0) return null;
        if (phase == STORES) {
            IUnitTask@ w = StoreWork(u);
            return (w is null) ? Wait(3) : w;   // the phase ends in FinishStores, not on one crew member's empty hand
        }
        IUnitTask@ t = null;
        if (kind == STARTER && (gunTask is null || gunTask.IsDead())) @t = CannonWork(u);
        if (t is null && kind == STORE) @t = StoreWork(u);
        if (t is null) @t = TurretWork(u);
        if (t is null) @t = CannonWork(u);
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
            + Wanted(AIR) + " air + " + Wanted(STORE) + " storage; " + turretPos.length() + " turrets, " + storePos.length() + " "
            + (st is null ? "storages" : st.GetName()) + ", " + (Gun() is null ? "cannon" : Gun().GetName()), 1);
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
            + "s nanos=" + CountStanding(Nano(), turretPos, 24.0f) + "/" + turretPos.length()
            + " storages=" + CountStanding(Store(), storePos, 32.0f) + "/" + storePos.length()
            + " crews=" + crewCount[STARTER] + "+" + crewCount[AIR] + "+" + crewCount[STORE]
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
        LolCannonRecon::Send(Global::LolCannon::ReconT1Scouts, Global::LolCannon::ReconRadarScouts);
        rebuild = false;
        const int stores = CountStanding(Store(), storePos, 32.0f);
        if (stores < int(storePos.length()) && Global::LolCannon::StoreFinishSeconds > 0) {
            // the storages are part of the order: the starter and storage crew stay on them
            KeepOnly(STARTER, STORE, Gun().GetName() + " stands; " + stores + " of " + storePos.length() + " storages, the storage crew finishes them");
            phase = STORES;
            storesUntil = ai.frame + Global::LolCannon::StoreFinishSeconds * SECOND;
            return;
        }
        ReleaseCrew(Gun().GetName() + " stands (" + built + " of " + Global::LolCannon::MetalIncomeGates.length() + ")");
        phase = IDLE;
        nextPlan = ai.frame + 30 * SECOND;
    }

    // The storage phase: done when every storage stands, when no slot is left to
    // build (each short one found no free spot) or after StoreFinishSeconds.
    void FinishStores()
    {
        const int stores = CountStanding(Store(), storePos, 32.0f);
        const bool done = stores >= int(storePos.length());
        const bool stuck = !done && OpenStores() == 0
            && aiBuilderMgr.FindUnfinishedNear(stripCentre, Global::LolCannon::StoreSearchRadius + 64.0f, Store()) is null;
        if (!done && !stuck && ai.frame < storesUntil) return;
        string why = "";
        if (stuck) why = " (no free spot near the strip for the other " + (int(storePos.length()) - stores) + ")";
        else if (!done) why = " (gave up after " + Global::LolCannon::StoreFinishSeconds + " s)";
        GenericHelpers::LogUtil("[LolCannon] REPORT storages " + stores + "/" + storePos.length() + " at=" + (ai.frame / SECOND) + "s" + why, 1);
        ReleaseCrew("storage strip " + (done ? "done" : "left short"));
        phase = IDLE;
        nextPlan = ai.frame + 30 * SECOND;
    }

    // Release every crew member but the two kinds given.
    void KeepOnly(int a, int b, const string &in why)
    {
        array<string>@ keys = crewOf.getKeys();
        int let = 0;
        for (uint i = 0; i < keys.length(); ++i) {
            int64 v = -1;
            crewOf.get(keys[i], v);
            const int kind = int(v);
            if (kind == a || kind == b) continue;
            crewOf.delete(keys[i]);
            if (kind >= 0 && kind <= STORE && crewCount[kind] > 0) --crewCount[kind];
            ++let;
        }
        recruitsAir.resize(0);
        GenericHelpers::LogUtil("[LolCannon] " + let + " crew released, " + (crewCount[a] + crewCount[b]) + " kept: " + why, 1);
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
            GenericHelpers::LogUtil("[LolCannon] the cannon at (" + int(site.x) + ", " + int(site.z) + ") was lost; the crews rebuild it there", 1);
            Begin(true);
            return true;
        }
        return false;
    }

    void Advance()
    {
        if (phase == BUILD || phase == STORES) ReplaceStores();
        if (phase == STORES) {
            FinishStores();
            return;
        }
        if (phase == IDLE) {
            if (CheckLost()) return;
            if (built >= int(Global::LolCannon::MetalIncomeGates.length()) || ai.frame < nextPlan) return;
            // a further cannon only while every earlier one stands (a lost one is rebuilt first, above)
            for (uint i = 0; i < doneSites.length(); ++i)
                if (aiBuilderMgr.FindOwnNear(doneSites[i], 96.0f, Gun()) is null) return;
            string why;
            if (!Gates(why)) {
                if (ai.frame >= nextGateLog && Economy::GetMinMetalIncomeLast10s() >= Global::LolCannon::MetalIncomeGates[built] * 0.5f) {
                    nextGateLog = ai.frame + 60 * SECOND;
                    GenericHelpers::LogUtil("[LolCannon] waiting for the gates: " + why, 1);
                }
                return;
            }
            nextPlan = ai.frame + 30 * SECOND;
            if (Gun() is null || Store() is null || !Plan()) return;
            GenericHelpers::LogUtil("[LolCannon] gates open: " + why, 1);
            Begin(false);
            return;
        }
        OrderCrews();
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
            GenericHelpers::LogUtil("[LolCannon] building: crews " + crewCount[STARTER] + "+" + crewCount[AIR] + "+" + crewCount[STORE]
                + " (" + recruitsT2.length() + "+" + recruitsAir.length() + " ordered), turrets " + turrets + " of " + turretPos.length()
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
        if (ai.frame >= nextFireCheck) {
            nextFireCheck = ai.frame + 60 * SECOND;
            KeepFireState();
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
