// Lolcannons (owner, 2026-10-21): Ragnarok, Calamity, Starfall.
#include "../../global.as"
#include "../../task.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/spatial/map_helpers.as"
#include "../../helpers/units/unit_helpers.as"

/******************************************************************************

LOLCANNON

The three super cannons (armvulc Ragnarok, corbuzz Calamity, legstarfall
Starfall) are built by FRONT and TECH only, and only through this program:

  gates   all required: metal income >= MinMetalIncome and energy income >=
          MinEnergyIncome as 10 s minima (Economy::GetMin*IncomeLast10s, so
          sustained over 10 s), and game time >= MinGameSeconds. Checked when
          the program starts and again before the cannon is ordered.
  crew    CrewMin..CrewMax T2 constructors (armack/armacv, corack/coracv,
          legack/legacv) are recruited from our finished T2 labs and claimed
          as they come out. Only the crew builds the program (AiMakeTask asks
          here first), so they stay dedicated until the cannon stands.
  site    the cannon's footprint is reserved round the base centre, facing
          the map centre, with a construction turret block (4 to 20 slots,
          biggest that fits: 5x4, 4x4, 4x3, 3x3, 3x2, 2x2) laid behind it.
  order   1. the turret block; 2. Storages hardened energy storages
          (armuwadves / coruwadves), LegionStorages for the Starfall
          (legadvestore); 3. the cannon, pinned to its reserved footprint.
          A lost cannon is rebuilt on the same site.

Every other path is closed: each cannon def's maxThisUnit is held at its count
(every native path - the porc chain's slot 21, AIR's chain, the C++ super
weapon - checks IsAvailable), and any construction task for a cannon that this
program did not order is aborted (AiTaskAdded, then the next tick), whatever
created it. TECH's super cluster and Builder::EnqueueLRPCHeavy defer to this.

Cost: Tick once a second: three cap writes, a few FindOwnNear lookups, the
crew re-order every CrewOrderSeconds over the factory list. The site search
(at most ~220 reservation probes) runs once, retried every 30 s on failure.

******************************************************************************/
namespace LolCannon {

    const int IDLE = 0, TURRETS = 1, STORAGE = 2, CANNON = 3, DONE = 4;
    const array<string> CANNONS = { "armvulc", "corbuzz", "legstarfall" };

    int phase = IDLE;
    int started = -1;
    int built = 0;
    bool ordering = false;
    array<IUnitTask@> pendingAbort;
    array<IUnitTask@> mine;

    // the crew
    array<int> crew;
    int crewWanted = 0;
    array<IUnitTask@> recruits;
    dictionary recruitLabs;          // lab id -> true
    int nextCrewOrder = 0;

    // the site
    AIFloat3 site(-1.0f, 0.0f, -1.0f);
    AIFloat3 blockCentre(-1.0f, 0.0f, -1.0f);
    int facing = 0;
    int gunRes = -1;
    int group = 0;
    int groupSlots = 0;
    array<AIFloat3> turretPos;
    IUnitTask@ gunTask;
    array<IUnitTask@> storeTasks;
    array<IUnitTask@> turretTasks;
    int storeBase = 0;               // our storages of the kind when the program started
    int storeOrders = 0;

    int lastWork = 0;
    int nextTick = 0;
    int nextPlan = 0;
    int nextGateLog = 0;
    int nextLog = 0;

    bool Enabled() { return Global::LolCannon::Enabled; }
    bool RoleMay() { return Global::AISettings::Role == AiRole::FRONT || Global::AISettings::Role == AiRole::TECH; }
    bool IsCannon(const string &in name) { return CANNONS.find(name) >= 0; }
    bool IsCrew(int id) { return crew.find(id) >= 0; }
    string Side() { return Global::AISettings::Side; }

    CCircuitDef@ Gun() { return ai.GetCircuitDef(UnitHelpers::GetLRPCHeavyNameForSide(Side())); }
    CCircuitDef@ Store()
    {
        const string s = Side();
        return ai.GetCircuitDef(s == "legion" ? "legadvestore" : (s == "cortex" ? "coruwadves" : "armuwadves"));
    }
    int StoresNeeded() { return (Side() == "legion") ? Global::LolCannon::LegionStorages : Global::LolCannon::Storages; }
    CCircuitDef@ Nano() { return ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(Side())); }
    array<string> CrewNames()
    {
        const string s = Side();
        if (s == "cortex") return array<string> = { "corack", "coracv" };
        if (s == "legion") return array<string> = { "legack", "legacv" };
        return array<string> = { "armack", "armacv" };
    }

    string PhaseName(int p)
    {
        if (p == TURRETS) return "turrets";
        if (p == STORAGE) return "storages";
        if (p == CANNON) return "cannon";
        if (p == DONE) return "done";
        return "idle";
    }

    bool Gates(string &out why)
    {
        const float m = Economy::GetMinMetalIncomeLast10s(), e = Economy::GetMinEnergyIncomeLast10s();
        const int secs = ai.frame / SECOND;
        why = "metal " + int(m) + "/" + int(Global::LolCannon::MinMetalIncome) + ", energy " + int(e) + "/"
            + int(Global::LolCannon::MinEnergyIncome) + " (10 s minima), time " + (secs / 60) + ":" + ((secs % 60 < 10) ? "0" : "") + (secs % 60)
            + "/" + (Global::LolCannon::MinGameSeconds / 60) + ":00";
        return Economy::IncomeWindowReady() && secs >= Global::LolCannon::MinGameSeconds
            && m >= Global::LolCannon::MinMetalIncome && e >= Global::LolCannon::MinEnergyIncome;
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

    // ---------------------------------------------------------------- the crew

    void UnitAdded(CCircuitUnit@ unit)
    {
        if (!Enabled() || unit is null || unit.circuitDef is null) return;
        if (phase < TURRETS || phase > CANNON || int(crew.length()) >= crewWanted || IsCrew(unit.id)) return;
        if (CrewNames().find(unit.circuitDef.GetName()) < 0) return;
        if (unit.GetProductionFrame() < started || !recruitLabs.exists("" + unit.GetProducerId())) return;
        crew.insertLast(unit.id);
        GenericHelpers::LogUtil("[LolCannon] crew " + crew.length() + " of " + crewWanted + ": " + unit.circuitDef.GetName() + " " + unit.id, 1);
    }

    void UnitRemoved(CCircuitUnit@ unit)
    {
        if (unit is null) return;
        const int k = crew.find(unit.id);
        if (k >= 0) crew.removeAt(k);
    }

    void OrderCrew()
    {
        if (ai.frame < nextCrewOrder) return;
        nextCrewOrder = ai.frame + Global::LolCannon::CrewOrderSeconds * SECOND;
        for (int i = int(recruits.length()) - 1; i >= 0; --i)
            if (recruits[i] is null || recruits[i].IsDead()) recruits.removeAt(i);
        const int missing = crewWanted - int(crew.length()) - int(recruits.length());
        if (missing <= 0) return;
        const array<string> names = CrewNames();
        array<CCircuitUnit@> labs;
        array<CCircuitDef@> cons;
        array<string>@ keys = Factory::allFactories.getKeys();
        for (uint i = 0; i < keys.length(); ++i) {
            CCircuitUnit@ f = null;
            if (!Factory::allFactories.get(keys[i], @f) || f is null || f.circuitDef is null || f.GetBuildProgress() < 1.0f) continue;
            for (uint n = 0; n < names.length(); ++n) {
                CCircuitDef@ d = ai.GetCircuitDef(names[n]);
                if (d is null || !f.circuitDef.CanBuild(d)) continue;
                labs.insertLast(f); cons.insertLast(d);
                break;
            }
        }
        if (labs.length() == 0) {
            GenericHelpers::LogUtil("[LolCannon] crew " + crew.length() + " of " + crewWanted + ": no finished T2 lab to recruit from; retry in "
                + Global::LolCannon::CrewOrderSeconds + " s", 1);
            return;
        }
        int queued = 0;
        for (int k = 0; k < missing; ++k) {
            CCircuitUnit@ lab = labs[k % labs.length()];
            CCircuitDef@ d = cons[k % cons.length()];
            if (d.maxThisUnit <= d.count + missing) d.maxThisUnit = d.count + missing + 1;   // role caps (TECH's T2 cap) yield to the crew
            IUnitTask@ r = aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, d, lab.GetPos(ai.frame), 64.0f));
            if (r is null) continue;
            recruits.insertLast(r);
            recruitLabs.set("" + lab.id, true);
            ++queued;
        }
        GenericHelpers::LogUtil("[LolCannon] crew " + crew.length() + " of " + crewWanted + ": queued " + queued + " T2 constructor(s) at "
            + labs.length() + " lab(s)", 1);
    }

    void ReleaseCrew(const string &in why)
    {
        GenericHelpers::LogUtil("[LolCannon] crew of " + crew.length() + " released: " + why, 1);
        crew.resize(0);
        recruits.resize(0);
    }

    // ---------------------------------------------------------------- the site

    int FacingOf(const AIFloat3 &in dir)
    {
        if ((dir.x < 0.0f ? -dir.x : dir.x) > (dir.z < 0.0f ? -dir.z : dir.z)) return (dir.x > 0.0f) ? 1 : 3;
        return (dir.z > 0.0f) ? 0 : 2;
    }

    bool Plan()
    {
        CCircuitDef@ gun = Gun();
        CCircuitDef@ nano = Nano();
        if (gun is null || nano is null) return false;
        const AIFloat3 base = Layout::BaseCentre();
        AIFloat3 dir(float(AiTerrainWidth()) * 0.5f - base.x, 0.0f, float(AiTerrainHeight()) * 0.5f - base.z);
        const float len = sqrt(dir.x * dir.x + dir.z * dir.z);
        if (len < 1.0f) dir = AIFloat3(0.0f, 0.0f, 1.0f); else dir = AIFloat3(dir.x / len, 0.0f, dir.z / len);
        facing = FacingOf(dir);
        const AIFloat3 centre(base.x - dir.x * 300.0f, 0.0f, base.z - dir.z * 300.0f);   // a little behind the base
        const array<int> sizes = Global::LolCannon::TurretBlocks;
        const float m = 96.0f;
        for (float r = Global::LolCannon::SiteMinDistance; r <= Global::LolCannon::SiteMaxDistance; r += 160.0f) {
            for (int a = 0; a < 16; ++a) {
                const float ang = float(a) * 6.2831853f / 16.0f;
                const AIFloat3 p(centre.x + cos(ang) * r, 0.0f, centre.z + sin(ang) * r);
                if (p.x < m || p.z < m || p.x > float(AiTerrainWidth()) - m || p.z > float(AiTerrainHeight()) - m) continue;
                if (!aiTerrainMgr.CanReserveBuilding(gun, p, facing)) continue;
                const int id = aiTerrainMgr.ReserveBuilding(gun, p, facing);
                if (id < 0) continue;
                const AIFloat3 gp = aiTerrainMgr.GetReservationPos(id);
                int best = -1, bestCount = 0, g = 0;
                for (uint o = 0; o + 1 < sizes.length(); o += 2) {
                    g = aiTerrainMgr.ReserveNanoBlockAt(nano, gun, gp, facing, sizes[o], sizes[o + 1], 0);
                    const int cnt = (g > 0) ? aiTerrainMgr.GetGroupCount(g, false) : 0;
                    if (cnt >= sizes[o] * sizes[o + 1] && cnt >= Global::LolCannon::MinTurrets) { best = int(o); bestCount = cnt; break; }
                    if (g > 0) aiTerrainMgr.ReleaseGroup(g);
                    g = 0;
                    if (cnt > bestCount) { bestCount = cnt; best = int(o); }
                }
                if (g == 0 && best >= 0 && bestCount >= Global::LolCannon::MinTurrets) {
                    g = aiTerrainMgr.ReserveNanoBlockAt(nano, gun, gp, facing, sizes[best], sizes[best + 1], 0);
                    bestCount = (g > 0) ? aiTerrainMgr.GetGroupCount(g, false) : 0;
                    if (bestCount < Global::LolCannon::MinTurrets) { if (g > 0) aiTerrainMgr.ReleaseGroup(g); g = 0; }
                }
                if (g == 0) { aiTerrainMgr.ReleaseReservation(id); continue; }
                gunRes = id; site = gp; group = g; groupSlots = AiMin(bestCount, 20);
                const AIFloat3 back = Layout::Fwd(facing);
                const float depth = float(Layout::Along(gun, facing)) * SQUARE_SIZE;
                blockCentre = AIFloat3(gp.x - back.x * (depth + 64.0f), 0.0f, gp.z - back.z * (depth + 64.0f));
                GenericHelpers::LogUtil("[LolCannon] site for " + gun.GetName() + " at (" + int(gp.x) + ", " + int(gp.z) + "), facing " + facing
                    + ", turret block of " + groupSlots + " (" + sizes[best] + "x" + sizes[best + 1] + ") behind it", 1);
                return true;
            }
        }
        GenericHelpers::LogUtil("[LolCannon] no site for " + gun.GetName() + " with a turret block of " + Global::LolCannon::MinTurrets
            + "+ round (" + int(centre.x) + ", " + int(centre.z) + "); retry in 30 s", 1);
        return false;
    }

    int FinishedTurrets()
    {
        CCircuitDef@ nano = Nano();
        if (nano is null) return 0;
        int n = 0;
        for (uint k = 0; k < turretPos.length(); ++k)
            if (aiBuilderMgr.FindOwnNear(turretPos[k], 32.0f, nano) !is null) ++n;
        return n;
    }

    CCircuitUnit@ StandingGun()
    {
        CCircuitDef@ gun = Gun();
        if (gun is null || site.x < 0.0f) return null;
        CCircuitUnit@ g = aiBuilderMgr.FindOwnNear(site, 96.0f, gun);
        return (g !is null && g.GetBuildProgress() >= 1.0f) ? g : null;
    }

    AIFloat3 StorePos(int k)
    {
        CCircuitDef@ gun = Gun();
        const float half = (gun is null) ? 64.0f : float(Layout::Across(gun, facing)) * SQUARE_SIZE * 0.5f;
        const AIFloat3 s = Layout::Side(facing);
        const float lat = ((k % 2 == 0) ? -1.0f : 1.0f) * (half + 110.0f + float(k / 2 % 3) * 100.0f);
        return AIFloat3(site.x + s.x * lat, 0.0f, site.z + s.z * lat);
    }

    // ---------------------------------------------------------------- orders

    IUnitTask@ Ordered(IUnitTask@ t)
    {
        if (t !is null) { mine.insertLast(t); lastWork = ai.frame; }
        return t;
    }

    IUnitTask@ OrderPinned(Task::BuildType type, CCircuitDef@ d, int id)
    {
        if (d is null || id < 0 || aiTerrainMgr.GetReservationState(id) != 0) return null;
        const AIFloat3 p = aiTerrainMgr.GetReservationPos(id);
        ordering = true;
        IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Common(type, Task::Priority::HIGH, d, p, 0.0f, true, 180 * SECOND));
        ordering = false;
        if (t is null) return null;
        if (!AiPinReservation(t, id)) {
            aiBuilderMgr.AbortTask(t);
            GenericHelpers::LogUtil("[LolCannon] could not pin " + d.GetName() + " to slot " + id, 1);
            return null;
        }
        return Ordered(t);
    }

    IUnitTask@ Wait(int seconds) { return aiBuilderMgr.Enqueue(TaskB::Wait(seconds * SECOND)); }

    IUnitTask@ TurretWork(CCircuitUnit@ u)
    {
        CCircuitDef@ nano = Nano();
        if (nano is null) return null;
        for (int i = int(turretTasks.length()) - 1; i >= 0; --i)
            if (turretTasks[i] is null || turretTasks[i].IsDead()) turretTasks.removeAt(i);
        const int sid = aiTerrainMgr.NextSlotAny(group, site);
        if (sid >= 0 && u.circuitDef.CanBuild(nano) && int(turretTasks.length()) < Global::LolCannon::TurretsAtOnce) {
            const AIFloat3 sp = aiTerrainMgr.GetReservationPos(sid);
            IUnitTask@ t = OrderPinned(Task::BuildType::NANO, nano, sid);
            if (t !is null) {
                turretTasks.insertLast(t);
                bool known = false;
                for (uint q = 0; q < turretPos.length(); ++q) if (MapHelpers::SqDist(turretPos[q], sp) < 16.0f) known = true;
                if (!known) turretPos.insertLast(sp);
                GenericHelpers::LogUtil("[LolCannon] " + u.circuitDef.GetName() + " " + u.id + " orders turret " + turretPos.length() + " of "
                    + groupSlots + " at (" + int(sp.x) + ", " + int(sp.z) + ")", 2);
                return t;
            }
        }
        CCircuitUnit@ tf = aiBuilderMgr.FindUnfinishedNear(blockCentre, 320.0f, nano);
        if (tf !is null) { lastWork = ai.frame; return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, tf, 30 * SECOND)); }
        if (turretTasks.length() > 0) return turretTasks[0];   // help a turret order on its way
        return Wait(3);
    }

    IUnitTask@ StoreWork(CCircuitUnit@ u)
    {
        CCircuitDef@ st = Store();
        if (st is null || !u.circuitDef.CanBuild(st)) return Wait(3);
        CCircuitUnit@ sf = aiBuilderMgr.FindUnfinishedNear(site, 700.0f, st);
        if (sf !is null) { lastWork = ai.frame; return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, sf, 30 * SECOND)); }
        for (int i = int(storeTasks.length()) - 1; i >= 0; --i)
            if (storeTasks[i] is null || storeTasks[i].IsDead()) storeTasks.removeAt(i);
        if (int(storeTasks.length()) < 2 && st.count + int(storeTasks.length()) < storeBase + StoresNeeded()) {
            const AIFloat3 p = StorePos(storeOrders++);
            IUnitTask@ t = Ordered(aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::STORE, Task::Priority::HIGH, st, p, 160.0f, true, 180 * SECOND)));
            if (t !is null) {
                storeTasks.insertLast(t);
                GenericHelpers::LogUtil("[LolCannon] " + u.circuitDef.GetName() + " " + u.id + " orders " + st.GetName() + " (" + (st.count - storeBase + 1)
                    + " of " + StoresNeeded() + ") near (" + int(p.x) + ", " + int(p.z) + ")", 1);
                return t;
            }
        }
        if (storeTasks.length() > 0) return storeTasks[0];
        return Wait(3);
    }

    IUnitTask@ CannonWork(CCircuitUnit@ u)
    {
        CCircuitDef@ gun = Gun();
        if (gun is null || !u.circuitDef.CanBuild(gun)) return Wait(3);
        if (gunTask !is null && !gunTask.IsDead()) return gunTask;
        @gunTask = null;
        CCircuitUnit@ gf = aiBuilderMgr.FindUnfinishedNear(site, 128.0f, gun);
        if (gf !is null) { lastWork = ai.frame; return aiBuilderMgr.Enqueue(TaskB::Repair(Task::Priority::HIGH, gf, 60 * SECOND)); }
        string why;
        if (!Gates(why)) {
            if (ai.frame >= nextGateLog) {
                nextGateLog = ai.frame + 60 * SECOND;
                GenericHelpers::LogUtil("[LolCannon] cannon waits for the gates: " + why, 1);
            }
            return Wait(5);
        }
        if (gunRes < 0 || aiTerrainMgr.GetReservationState(gunRes) != 0) {
            gunRes = aiTerrainMgr.ReserveBuilding(gun, site, facing);   // the footprint again (a rebuild, or a lost order)
            if (gunRes < 0) return Wait(5);
        }
        @gunTask = OrderPinned(Task::BuildType::BIG_GUN, gun, gunRes);
        if (gunTask !is null)
            GenericHelpers::LogUtil("[LolCannon] " + u.circuitDef.GetName() + " " + u.id + " orders " + gun.GetName() + " at (" + int(site.x) + ", "
                + int(site.z) + "): " + FinishedTurrets() + " turrets, " + (Store() is null ? 0 : Store().count - storeBase) + " storages, crew "
                + crew.length() + "; " + why, 1);
        return (gunTask is null) ? Wait(5) : gunTask;
    }

    // Builder AiMakeTask, asked first: a crew member's next piece of work
    IUnitTask@ BuilderTask(CCircuitUnit@ u)
    {
        if (!Enabled() || u is null || u.circuitDef is null || !IsCrew(u.id)) return null;
        if (phase == TURRETS) return TurretWork(u);
        if (phase == STORAGE) return StoreWork(u);
        if (phase == CANNON) return CannonWork(u);
        return null;
    }

    // ---------------------------------------------------------------- the program

    void Advance()
    {
        if (phase == IDLE) {
            if (built >= Global::LolCannon::MaxCannons || ai.frame < nextPlan) return;
            string why;
            if (!Gates(why)) {
                if (ai.frame / SECOND >= Global::LolCannon::MinGameSeconds && ai.frame >= nextGateLog) {
                    nextGateLog = ai.frame + 60 * SECOND;
                    GenericHelpers::LogUtil("[LolCannon] waiting for the gates: " + why, 1);
                }
                return;
            }
            nextPlan = ai.frame + 30 * SECOND;
            if (Gun() is null || Store() is null || !Plan()) return;
            started = ai.frame;
            lastWork = ai.frame;
            const float m = Economy::GetMinMetalIncomeLast10s();
            crewWanted = AiMax(Global::LolCannon::CrewMin, AiMin(Global::LolCannon::CrewMax,
                Global::LolCannon::CrewMin + int((m - Global::LolCannon::MinMetalIncome) / AiMax(1.0f, Global::LolCannon::CrewMetalStep))));
            storeBase = Store().count;
            storeOrders = 0;
            turretPos.resize(0);
            nextCrewOrder = 0;
            phase = TURRETS;
            GenericHelpers::LogUtil("[LolCannon] program starts: " + why + "; crew of " + crewWanted + ", then " + groupSlots + " turrets, "
                + StoresNeeded() + " " + Store().GetName() + ", " + Gun().GetName(), 1);
            return;
        }
        if (phase == DONE) {
            if (StandingGun() is null) {
                phase = CANNON; started = ai.frame; lastWork = ai.frame; nextCrewOrder = 0;
                GenericHelpers::LogUtil("[LolCannon] the cannon was lost; the crew rebuilds it on its site", 1);
            } else if (built < Global::LolCannon::MaxCannons) {
                phase = IDLE;
            }
            return;
        }
        OrderCrew();
        const int stalled = ai.frame - lastWork;
        if (phase == TURRETS) {
            const int done = FinishedTurrets();
            if (done >= groupSlots || (done >= Global::LolCannon::MinTurrets && stalled >= Global::LolCannon::StallSeconds * SECOND)) {
                phase = STORAGE; lastWork = ai.frame;
                GenericHelpers::LogUtil("[LolCannon] " + done + " of " + groupSlots + " turrets stand; storages next", 1);
            }
        } else if (phase == STORAGE) {
            CCircuitDef@ st = Store();
            if (st !is null && st.count >= storeBase + StoresNeeded()) {
                phase = CANNON; lastWork = ai.frame;
                GenericHelpers::LogUtil("[LolCannon] " + StoresNeeded() + " " + st.GetName() + " stand; the cannon next", 1);
            }
        } else if (phase == CANNON) {
            if (StandingGun() !is null) {
                ++built; phase = DONE;
                ReleaseCrew(Gun().GetName() + " stands (" + built + " of " + Global::LolCannon::MaxCannons + ")");
            }
        }
        if (ai.frame >= nextLog) {
            nextLog = ai.frame + 60 * SECOND;
            GenericHelpers::LogUtil("[LolCannon] " + PhaseName(phase) + ": crew " + crew.length() + " of " + crewWanted + " (" + recruits.length()
                + " queued), turrets " + FinishedTurrets() + " of " + groupSlots + ", storages "
                + (Store() is null ? 0 : Store().count - storeBase) + " of " + StoresNeeded(), 1);
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
    }
}
