#include "tech_weapons.as"

// D-152: finite protected sites. Reservation is distinct from a paid order.
namespace TechFortifications {
    class Piece {
        string role;
        AIFloat3 pos;
        int slot = -1;
        IUnitTask@ task;
    }
    class Site {
        string key;
        int asset = -1;
        bool advanced = false;
        array<Piece@> pieces;
    }
    array<Site@> sites;
    dictionary retry;
    int last = -1;
    int planFrame = -100000;
    float budget = 0.0f;
    float share = 0.05f;
    float radius = 2200.0f;
    int parallel = 2;
    bool advancedAccess = false;

    void Reset()
    {
        sites.resize(0); retry.deleteAll(); last = -1; planFrame = -100000; budget = 0.0f; advancedAccess = false;
    }
    bool Advanced()
    {
        CCircuitDef@ mex = ai.GetCircuitDef(UnitHelpers::GetT2MexNameForSide(Global::AISettings::Side));
        if (mex is null) return false;
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u !is null && u.GetBuildProgress() >= 1.0f && u.circuitDef.CanBuild(mex)) return true;
        }
        return false;
    }
    bool Asset(CCircuitUnit@ u)
    {
        if (u is null || u.GetBuildProgress() < 1.0f) return false;
        const string n = u.circuitDef.GetName();
        // All factions and both geo tiers; underwater sites use floating teeth.
        if (n.findFirst("geo") >= 0) return true;
        CCircuitDef@ mex = ai.GetCircuitDef(UnitHelpers::GetT2MexNameForSide(UnitHelpers::GetSideForUnitName(n)));
        return mex !is null && u.circuitDef.GetExtractsMetal() >= mex.GetExtractsMetal()
            && mex.GetExtractsMetal() > 0.0f;
    }
    void Add(Site@ s, const string &in role, const AIFloat3 &in p)
    {
        if (!TechWeapons::OnMap(p) || aiBattle.IsFriendlyLane(p)) return;
        CCircuitDef@ d = TechWeapons::Def(role);
        if (d is null || !WallHelpers::Allowed(d, p)) return;
        Piece v; v.role = role; v.pos = p;
        const string key = s.key + "." + role + "." + int(p.x) + "." + int(p.z);
        v.slot = aiTerrainMgr.GetLayoutInt(key, -1);
        if (v.slot < 0 || aiTerrainMgr.GetReservationState(v.slot) < 0) {
            if (!aiTerrainMgr.CanReserveBuilding(d, p, 0)) return;
            v.slot = aiTerrainMgr.ReservePersistentBuilding(d, p, 0);
            if (v.slot < 0) return;
            aiTerrainMgr.SetLayoutInt(key, v.slot);
        }
        v.pos = aiTerrainMgr.GetReservationPos(v.slot);
        if (!WallHelpers::Allowed(d, v.pos)) {
            aiTerrainMgr.ReleasePersistentBuilding(v.slot);
            return;
        }
        s.pieces.insertLast(v);
    }
    Site@ Find(const string &in key)
    {
        for (uint i = 0; i < sites.length(); ++i) if (sites[i].key == key) return sites[i];
        return null;
    }
    void Lane(bool advanced)
    {
        // TECH walls belong to forward weapon/asset protection, not a fixed
        // line just beyond the home-base exclusion disk.
        if (Global::AISettings::Role == AiRole::TECH) return;
        const string key = advanced ? "fort.lane.t2" : "fort.lane.t1";
        if (Find(key) !is null) return;
        Site s; s.key = key; s.advanced = advanced;
        const AIFloat3 base = Global::Map::StartPos;
        const AIFloat3 front = Layout::FrontTarget();
        const int facing = LayoutHelpers::FacingToward(base, front);
        const AIFloat3 dir = Layout::Fwd(facing);
        WallHelpers::Refresh();
        // Move toward the front, but never beyond it or the worker's search radius.
        const float frontDistance = (front.x - base.x) * dir.x + (front.z - base.z) * dir.z;
        const float limit = AiMin(radius, frontDistance - 128.0f);
        float along = AiMax(752.0f, WallHelpers::baseRadius + 96.0f) + (advanced ? 48.0f : 0.0f);
        for (; along <= limit; along += 32.0f) {
            const AIFloat3 centre = TechWeapons::Along(base, dir, along, 0.0f);
            const float halfX = dir.x == 0.0f ? 496.0f : 16.0f;
            const float halfZ = dir.z == 0.0f ? 496.0f : 16.0f;
            if (!WallHelpers::InBase(centre, halfX, halfZ)) break;
        }
        if (along > limit) return;
        // A broad central gap keeps the actual lane and factory traffic open.
        for (int k = -15; k <= 15; ++k) {
            if (k > -5 && k < 5) continue;
            Add(s, advanced ? "fort" : "teeth", TechWeapons::Along(base, dir, along, float(k) * 32.0f));
        }
        if (!advanced) {
            Add(s, "llt", TechWeapons::Along(base, dir, along - 112.0f, -256.0f));
            Add(s, "aal", TechWeapons::Along(base, dir, along - 112.0f, 256.0f));
        }
        if (s.pieces.length() > 0) {
            sites.insertLast(s);
            GenericHelpers::LogUtil("[TECH][Fortify] planned " + key + " pieces=" + s.pieces.length(), 1);
        }
    }
    void Protect(CCircuitUnit@ u)
    {
        const AIFloat3 p = u.GetPos(ai.frame);
        if (WallHelpers::InBase(p) || Global::AISettings::Role == AiRole::TECH
            && !TechWeapons::NearFront(p,Global::RoleSettings::Tech::WeaponWallFrontRadius)) return;
        const string key = "fort.asset." + u.id;
        if (Find(key) !is null) return;
        int64 due = -1;
        if (retry.get(key, due) && ai.frame < due) return;
        Site s; s.key = key; s.asset = u.id; s.advanced = true;
        const float size = float(AiMax(u.circuitDef.GetFootprintX(), u.circuitDef.GetFootprintZ())) * SQUARE_SIZE;
        const int first = int((size + 96.0f) / 32.0f) + 1;
        float r = 0.0f;
        const string wall = p.y < 0.0f ? "fteeth" : "teeth";
        // A geo/mex can sit inside an economic zone. Search a wider perimeter
        // before giving up; never silently publish a zero-piece protected site.
        for (int extra = 0; extra <= 12 && s.pieces.length() == 0; extra += 2) {
            const int steps = first + extra;
            r = float(steps) * 32.0f;
            for (int edge = 0; edge < 4; ++edge) {
                for (int k = -steps; k < steps; ++k) {
                    if (k >= -1 && k <= 1) continue;
                    Add(s, wall, LayoutHelpers::Offset(p, edge, float(k) * 32.0f, r));
                }
            }
        }
        if (s.pieces.length() == 0) {
            retry.set(key, int64(ai.frame + 60 * SECOND));
            GenericHelpers::LogUtil("[TECH][Fortify] no perimeter for " + u.circuitDef.GetName() + " " + u.id + "; retry in 60s", 1);
            return;
        }
        if (p.y >= 0.0f) {
            Add(s, "llt", AIFloat3(p.x - r + 64.0f, 0.0f, p.z));
            Add(s, "aal", AIFloat3(p.x + r - 64.0f, 0.0f, p.z));
        } else Add(s, "fhlt", AIFloat3(p.x + r - 64.0f, 0.0f, p.z));
        sites.insertLast(s);
        GenericHelpers::LogUtil("[TECH][Fortify] protect " + u.circuitDef.GetName() + " " + u.id + " pieces=" + s.pieces.length(), 1);
    }
    void Tick()
    {
        if (!Global::RoleSettings::Tech::ExperimentalBuild || !aiTerrainMgr.IsLayoutEnabled()) return;
        if (last < 0) {
            share = aiSetupMgr.ConfigFloat("weapons/fortification/share", share);
            radius = aiSetupMgr.ConfigFloat("weapons/fortification/work_radius", radius);
            parallel = aiSetupMgr.ConfigInt("weapons/fortification/concurrent", parallel);
            last = ai.frame;
        }
        const float mi = Economy::GetMinMetalIncomeLast10s();
        budget = AiMin(300.0f, budget + AiMax(0.0f, mi * share * float(ai.frame - last) / SECOND));
        last = ai.frame;
        if (ai.frame - planFrame < 10 * SECOND) return;
        planFrame = ai.frame;
        // Expansion claims must exist before fortification takes any space.
        if (TechFactories::clusters.length() < 3 && ai.frame < 60 * SECOND) return;
        Lane(false);
        advancedAccess = Advanced();
        if (advancedAccess) Lane(true);
        for (int i = int(sites.length()) - 1; i >= 0; --i) {
            Site@ s = sites[i];
            // A late ally announcement can invalidate a planned, unstarted wall.
            for (int j = int(s.pieces.length()) - 1; j >= 0; --j) {
                Piece@ p = s.pieces[j];
                if (WallHelpers::Allowed(TechWeapons::Def(p.role), p.pos)) continue;
                IBuilderTask@ task = cast<IBuilderTask>(p.task);
                if (aiTerrainMgr.GetReservationState(p.slot) > 1 || (task !is null && task.target !is null)) continue;
                if (p.task !is null && !p.task.IsDead()) aiBuilderMgr.AbortTask(p.task);
                aiTerrainMgr.ReleasePersistentBuilding(p.slot);
                s.pieces.removeAt(j);
            }
            if (s.pieces.length() == 0) { sites.removeAt(i); continue; }
            if (s.asset < 0 || ai.GetTeamUnit(s.asset) !is null) continue;
            for (uint j = 0; j < s.pieces.length(); ++j) {
                if (s.pieces[j].task !is null && !s.pieces[j].task.IsDead()) aiBuilderMgr.AbortTask(s.pieces[j].task);
                aiTerrainMgr.ReleasePersistentBuilding(s.pieces[j].slot);
            }
            sites.removeAt(i);
        }
        if (!advancedAccess) return;
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (Asset(u)) Protect(u);
        }
    }
    IUnitTask@ Work(CCircuitUnit@ u)
    {
        if (u is null || aiEconomyMgr.isEnergyStalling || aiEconomyMgr.metal.current < 50.0f) return null;
        if (!advancedAccess && aiBuilderMgr.GetStaticBuildPowerNear(Layout::BaseCentre(), Global::RoleSettings::Tech::EcoBuildPowerRadius) <= 0.0f) return null;
        int pending = 0;
        for (uint i = 0; i < sites.length(); ++i)
            for (uint j = 0; j < sites[i].pieces.length(); ++j)
                if (sites[i].pieces[j].task !is null && !sites[i].pieces[j].task.IsDead()) ++pending;
        if (pending >= parallel) return null;
        // Resource perimeters first, then the base's lane lines. Idle air
        // constructors use this same finite plan instead of scattering turrets.
        for (uint i = 0; i < sites.length(); ++i) {
            Site@ s = sites[sites.length() - i - 1];
            for (uint j = 0; j < s.pieces.length(); ++j) {
                Piece@ p = s.pieces[j];
                if (aiTerrainMgr.GetReservationState(p.slot) != 0) continue;
                if (Global::AISettings::Role == AiRole::TECH && !TechForward::T2Released()
                    && p.pos.distance2D(Layout::BaseCentre()) >= Global::RoleSettings::Tech::WeaponBaseRadius) continue;
                CCircuitDef@ d = TechWeapons::Def(p.role);
                if (d is null || budget < d.costM || !TechForward::Buildable(u, d) || !WallHelpers::Allowed(d, p.pos)) continue;
                if (MapHelpers::SqDist(u.GetPos(ai.frame), p.pos) > radius * radius
                    || !aiTerrainMgr.CanReachAt(u, p.pos, u.circuitDef.GetBuildDistance()) || aiBattle.SurfThreat(p.pos) > 1.0f) continue;
                if (aiBattle.IsFriendlyLane(p.pos)) continue;
                IUnitTask@ t = aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::DEFENCE, Task::Priority::NORMAL, d, p.pos, 0.0f, true, 180 * SECOND));
                if (t is null) continue;
                if (!AiPinReservation(t, p.slot)) { aiBuilderMgr.AbortTask(t); continue; }
                @p.task = t; budget -= d.costM;
                if (aiBattle.IsFriendlyLane(p.pos)) Invariants::Violation("INV-085", s.key, "fortification ordered inside friendly lane");
                GenericHelpers::LogUtil("[TECH][Fortify] " + s.key + " orders " + d.GetName() + " at " + int(p.pos.x) + "," + int(p.pos.z), 1);
                return t;
            }
        }
        return null;
    }
}
