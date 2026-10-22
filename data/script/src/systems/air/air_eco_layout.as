// AIR's persistent economy modules, independent of the aircraft campus.
// Slots/claims and allied exclusion remain owned by the native layout service.
// D-292: two module kinds share one list and one named-state key space.
//   kind 0 (KindAfus):   AFUS reactor + eight advanced converters (none on metal maps) + support bank
//   kind 1 (KindFusion): ordinary fusion reactor + its own support bank
// A module only ever serves orders of its own kind; reactor spacing applies across kinds.
namespace AirEcoLayout {
    const int KindAfus = 0;
    const int KindFusion = 1;
    string Prefix() { return aiEconomyMgr.IsMetalMap() ? "air.fieldEco." : "air.eco."; }
    int ConverterSlots(int kind = 0) { return kind == KindFusion || aiEconomyMgr.IsMetalMap() ? 0 : 8; }
    string KindName(int kind) { return kind == KindFusion ? "fusion" : "afus"; }
    CCircuitDef@ ReactorDef(const string &in side, int kind) {
        return ai.GetCircuitDef(kind == KindFusion ? UnitHelpers::GetFusionNameForSide(side) : UnitHelpers::GetAdvFusionNameForSide(side));
    }
    int SupportSlots(int kind) {
        return AiMax(0, AiMin(20, kind == KindFusion ? Global::RoleSettings::Air::FusionSupportSlots
            : Global::RoleSettings::Air::EcoSupportSlots));
    }
    bool IsFusion(const CCircuitDef@ d) {
        return d !is null && d.GetName() == UnitHelpers::GetFusionNameForSide(UnitHelpers::GetSideForUnitName(d.GetName()));
    }
    class Module {
        string key;
        string side;
        int zone = 0;
        int facing = 0;
        bool started = false;
        array<int> slots; // reactor first, then advanced converters
        array<int> support; // schema 2: independent economy turret bank
        int supportRetry = 0;
        int kind = 0; // KindAfus or KindFusion; persisted as <key>.kind (absent in schema 2 = KindAfus)
    }
    array<Module@> modules;
    array<int> retryAfter = {0, 0}; // per kind: a failed fusion search never delays AFUS planning, and the reverse
    int planFrame = -100000;
    dictionary supportPositions;
    string PositionKey(const AIFloat3 &in pos) { return "" + int(pos.x / 8.0f + .5f) + ":" + int(pos.z / 8.0f + .5f); }
    bool Owns(const AIFloat3 &in pos) { return supportPositions.exists(PositionKey(pos)); }
    int ReactorAt(const AIFloat3 &in pos) {
        int owner = -1;
        if (!supportPositions.get(PositionKey(pos), owner) || owner < 0 || owner >= int(modules.length())
            || modules[owner].slots.length() == 0) return -1;
        CCircuitUnit@ u = aiTerrainMgr.GetReservationUnit(modules[owner].slots[0]);
        return u is null ? -1 : u.id;
    }
    void IndexSupport() {
        supportPositions.deleteAll();
        for (uint i = 0; i < modules.length(); ++i) for (uint s = 0; s < modules[i].support.length(); ++s) {
            const int pin = modules[i].support[s];
            if (aiTerrainMgr.GetReservationState(pin) >= 0)
                supportPositions.set(PositionKey(aiTerrainMgr.GetReservationPos(pin)), int(i));
        }
    }

    void Save(Module@ m)
    {
        aiTerrainMgr.SetLayoutInt(Prefix() + "count", int(modules.length()));
        aiTerrainMgr.SetLayoutInt(m.key + ".zone", m.zone);
        aiTerrainMgr.SetLayoutInt(m.key + ".facing", m.facing);
        aiTerrainMgr.SetLayoutInt(m.key + ".started", m.started ? 1 : 0);
        aiTerrainMgr.SetLayoutInt(m.key + ".side", m.side == "cortex" ? 1 : m.side == "legion" ? 2 : 0);
        aiTerrainMgr.SetLayoutInt(m.key + ".count", int(m.slots.length()));
        for (uint i = 0; i < m.slots.length(); ++i) aiTerrainMgr.SetLayoutInt(m.key + ".slot." + i, m.slots[i]);
        aiTerrainMgr.SetLayoutInt(m.key + ".schema", 3);
        aiTerrainMgr.SetLayoutInt(m.key + ".kind", m.kind);
        aiTerrainMgr.SetLayoutInt(m.key + ".supportCount", int(m.support.length()));
        for (uint i = 0; i < m.support.length(); ++i) aiTerrainMgr.SetLayoutInt(m.key + ".support." + i, m.support[i]);
        IndexSupport();
    }
    void Init()
    {
        modules.resize(0); retryAfter[0] = 0; retryAfter[1] = 0; planFrame = -100000;
        ResetFallback();
        const int count = aiTerrainMgr.GetLayoutInt(Prefix() + "count", 0);
        for (int i = 0; i < count; ++i) {
            Module m;
            m.key = Prefix() + i;
            m.zone = aiTerrainMgr.GetLayoutInt(m.key + ".zone", 0);
            m.facing = aiTerrainMgr.GetLayoutInt(m.key + ".facing", AirLayout::facing);
            m.started = aiTerrainMgr.GetLayoutInt(m.key + ".started", 0) != 0;
            const int side = aiTerrainMgr.GetLayoutInt(m.key + ".side", 0);
            m.side = side == 1 ? "cortex" : side == 2 ? "legion" : "armada";
            m.kind = aiTerrainMgr.GetLayoutInt(m.key + ".kind", KindAfus) == KindFusion ? KindFusion : KindAfus;
            const int n = aiTerrainMgr.GetLayoutInt(m.key + ".count", 0);
            for (int s = 0; s < AiMin(n, 9); ++s) m.slots.insertLast(aiTerrainMgr.GetLayoutInt(m.key + ".slot." + s, -1));
            const int support = aiTerrainMgr.GetLayoutInt(m.key + ".supportCount", 0);
            for (int s = 0; s < AiMin(support, 20); ++s) m.support.insertLast(aiTerrainMgr.GetLayoutInt(m.key + ".support." + s, -1));
            modules.insertLast(m);
        }
        IndexSupport();
    }
    bool NearReactor(const AIFloat3 &in pos, float separation)
    {
        for (uint i = 0; i < modules.length(); ++i) {
            Module@ m = modules[i];
            if (m.slots.length() > 0 && aiTerrainMgr.GetReservationState(m.slots[0]) >= 0
                && MapHelpers::SqDist(pos, aiTerrainMgr.GetReservationPos(m.slots[0])) < separation * separation) return true;
        }
        return false;
    }
    void ReleaseUnused(Module@ m)
    {
        for (uint i = 0; i < m.slots.length(); ++i) aiTerrainMgr.ReleasePersistentBuilding(m.slots[i]);
        for (uint i = 0; i < m.support.length(); ++i) aiTerrainMgr.ReleasePersistentBuilding(m.support[i]);
        if (m.zone > 0) aiTerrainMgr.ReleaseZone(m.zone);
        m.slots.resize(0); m.support.resize(0); m.zone = 0; Save(m);
    }
    // Reserve a whole support bank or nothing. The first candidate fits between
    // reactor and converters before the module envelope is claimed. Alternatives
    // allow safe supplementary banks for old occupied modules, without moving them.
    void ReserveSupport(Module@ m) {
        if (m is null || m.slots.length() == 0 || m.support.length() > 0 || ai.frame < m.supportRetry) return;
        m.supportRetry = ai.frame + 30 * SECOND;
        CCircuitDef@ nano = ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(m.side));
        CCircuitDef@ reactor = ReactorDef(m.side, m.kind);
        if (nano is null || reactor is null) return;
        const int count = SupportSlots(m.kind);
        if (count == 0) return;
        // GetFootprint is in half-cells; adjacent centers need a full footprint.
        const float step = float(AiMax(nano.GetFootprintX(), nano.GetFootprintZ())) * SQUARE_SIZE * 2.0f;
        const AIFloat3 origin = aiTerrainMgr.GetReservationPos(m.slots[0]);
        const float first = float(reactor.GetFootprintZ()) * SQUARE_SIZE + step * .5f + 16;
        for (int candidate = 0; candidate < 5; ++candidate) {
            array<int> pins;
            const int f = candidate == 0 ? m.facing : (m.facing + candidate - 1) % 4;
            const float offset = candidate == 0 ? first : first + step;
            for (int i = 0; i < count; ++i) {
                const AIFloat3 p = AirLayout::Offset(origin, f, (float(i % 6) - 2.5f) * step,
                    offset + float(i / 6) * step);
                if (!AirHome::EconomySite(p) || !ProductionMath::WithinReach(MapHelpers::SqDist(p, origin), nano.GetBuildDistance())
                    || !aiTerrainMgr.CanReserveBuilding(nano, p, f)) break;
                const int pin = aiTerrainMgr.ReservePersistentBuilding(nano, p, f);
                if (pin < 0) break;
                pins.insertLast(pin);
            }
            if (int(pins.length()) == count) {
                m.support = pins;
                if (m.key.length() > 0) Save(m);
                return;
            }
            for (uint i = 0; i < pins.length(); ++i) aiTerrainMgr.ReleasePersistentBuilding(pins[i]);
        }
    }
    Module@ Reserve(const string &in side, Module@ reuse = null, int kind = 0)
    {
        if (kind != KindFusion) kind = KindAfus;
        if (!AirLayout::enabled || ai.frame < retryAfter[kind]) return null;
        CCircuitDef@ reactor = ReactorDef(side, kind);
        CCircuitDef@ converter = ai.GetCircuitDef(UnitHelpers::GetAdvEnergyConverterNameForSide(side));
        const int converters = ConverterSlots(kind);
        if (reactor is null || (converter is null && converters > 0)) return null;
        const int f = AirLayout::facing;
        const float rw = float(reactor.GetFootprintX()) * SQUARE_SIZE;
        const float rd = float(reactor.GetFootprintZ()) * SQUARE_SIZE;
        const float cw = converter is null ? 0.0f : float(converter.GetFootprintX()) * SQUARE_SIZE;
        const float cd = converter is null ? 0.0f : float(converter.GetFootprintZ()) * SQUARE_SIZE;
        const float pitch = 2.0f * cw; // advanced converters touch footprint edges
        CCircuitDef@ nano = ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(side));
        const float nanoSize = nano is null ? 0.0f : float(AiMax(nano.GetFootprintX(), nano.GetFootprintZ())) * SQUARE_SIZE * 2.0f;
        const int supportRows = (SupportSlots(kind) + 5) / 6;
        const float across = AiMax(converters == 0 ? rw : AiMax(rw, 1.5f * pitch + cw),
            3.0f * nanoSize) + 16.0f;
        const float bankZ = rd + AiMax(Global::RoleSettings::Air::EcoConverterClearance,
            float(supportRows) * nanoSize + 32.0f) + cd;
        const float front = converters == 0 ? rd + float(supportRows) * nanoSize + 32.0f : bankZ + 3.0f * cd;
        const float along = (front + rd) * 0.5f + 16.0f;
        const float shift = (front - rd) * 0.5f;
        // Fine candidate spacing can move an unused module around one blocker
        // without requiring another whole module-width of free land.
        const float step = 128.0f;
        const AIFloat3 anchor = AirLayout::Offset(Global::Map::StartPos, f, 0.0f, -900.0f);
        const int rings = 1 + int((Global::RoleSettings::Air::HomeEconomyRadius + 900.0f) / step);
        for (int ring = 0; ring <= rings; ++ring) {
            const int width = 2 * ring + 1;
            for (int cell = 0; cell < width * width; ++cell) {
                const int x = cell % width - ring, z = cell / width - ring;
                if (ring > 0 && x > -ring && x < ring && z > -ring && z < ring) continue;
                AIFloat3 at = AirLayout::Offset(anchor, f, float(x) * step, float(z) * step);
                if (!AirLayout::Inside(at, AiMax(across, front)) || !AirHome::EconomySite(at)
                    || NearReactor(at, Global::RoleSettings::Air::EcoReactorSpacing)) continue;
                bool near = AirLayout::bays.length() == 0 && MapHelpers::SqDist(at, Global::Map::StartPos)
                    < Global::RoleSettings::Air::EcoFactorySeparation * Global::RoleSettings::Air::EcoFactorySeparation;
                for (uint b = 0; b < AirLayout::bays.length(); ++b) {
                    AirLayout::Bay@ bay = AirLayout::bays[b];
                    if (bay.slot >= 0 && MapHelpers::SqDist(at, bay.centre)
                        < Global::RoleSettings::Air::EcoFactorySeparation * Global::RoleSettings::Air::EcoFactorySeparation) near = true;
                }
                if (near || !aiTerrainMgr.CanReserveBuilding(reactor, at, f)) continue;
                const AIFloat3 zone = AirLayout::Offset(at, f, 0.0f, shift);
                bool home = true;
                for (int corner = 0; corner < 4; ++corner)
                    if (!AirHome::EconomySite(AirLayout::Offset(zone, f, corner % 2 == 0 ? -across : across,
                        corner < 2 ? -along : along))) home = false;
                if (!home || !aiTerrainMgr.CanReserveArea(zone, f, across, along)) continue;
                array<int> slots;
                const int first = aiTerrainMgr.ReservePersistentBuilding(reactor, at, f);
                if (first < 0) continue;
                slots.insertLast(first);
                at = aiTerrainMgr.GetReservationPos(first);
                for (int s = 0; s < converters; ++s) {
                    const AIFloat3 p = AirLayout::Offset(at, f, (float(s % 4) - 1.5f) * pitch,
                        bankZ + float(s / 4) * (2.0f * cd));
                    const int id = aiTerrainMgr.ReservePersistentBuilding(converter, p, f);
                    if (id < 0) break;
                    slots.insertLast(id);
                }
                if (slots.length() != uint(1 + converters) || (converters>0
                    && !LayoutHelpers::CheckGrid(slots,1,4,f,pitch,2.0f*cd))) {
                    for (uint s = 0; s < slots.length(); ++s) aiTerrainMgr.ReleasePersistentBuilding(slots[s]);
                    continue;
                }
                Module@ m = reuse is null ? Module() : reuse;
                m.side = side; m.facing = f; m.slots = slots; m.supportRetry = 0; m.kind = kind;
                ReserveSupport(m);
                const int envelope = aiTerrainMgr.ReserveZone(AirLayout::Offset(at, f, 0.0f, shift), f, across, along, false);
                if (envelope <= 0) {
                    for (uint s = 0; s < slots.length(); ++s) aiTerrainMgr.ReleasePersistentBuilding(slots[s]);
                    for (uint s = 0; s < m.support.length(); ++s) aiTerrainMgr.ReleasePersistentBuilding(m.support[s]);
                    m.support.resize(0); m.slots.resize(0);
                    continue;
                }
                if (reuse is null) m.key = Prefix() + modules.length();
                m.side = side; m.facing = f; m.slots = slots;
                m.zone = envelope;
                if (reuse is null) modules.insertLast(m);
                Save(m);
                GenericHelpers::LogUtil("[AIR][EcoLayout] reserved " + m.key + " reactor=" + int(at.x) + "," + int(at.z)
                    + " converters=" + converters + " support=" + m.support.length() + " zone=" + m.zone
                    + " kind=" + KindName(kind), 1);
                return m;
            }
        }
        retryAfter[kind] = ai.frame + 10 * SECOND;
        return null;
    }
    Module@ Activate(Module@ m)
    {
        if (m.started) return m;
        if (m.slots.length() == 0) return Reserve(m.side, m, m.kind);
        array<int> pins = m.slots;
        for (uint i = 0; i < m.support.length(); ++i) pins.insertLast(m.support[i]);
        const int state = LayoutHelpers::ActivationState(pins);
        if (state == 2) { m.started = true; Save(m); return m; }
        if (state == 0) return m;
        GenericHelpers::LogUtil("[AIR][EcoLayout] relocate blocked unused " + m.key, 1);
        ReleaseUnused(m); retryAfter[m.kind] = 0;
        return Reserve(m.side, m, m.kind);
    }
    void PlanAhead()
    {
        if (!AirLayout::enabled || ai.frame - planFrame < SECOND) return;
        if (MetalEconomy::Active() && AirLayout::bays.length() == 0) return;
        planFrame = ai.frame;
        // Counts are kept per kind so fusion modules never satisfy (or starve)
        // the AFUS plan. O(modules) per second; modules stay in single digits.
        array<int> active = {0, 0}, planned = {0, 0};
        Module@ retryA = null;
        Module@ retryF = null;
        for (uint i = 0; i < modules.length(); ++i) {
            Module@ m = modules[i];
            if (m.started && m.support.length() == 0) ReserveSupport(m);
            if (!m.started && LayoutHelpers::ActivationState(m.slots) == 2) { m.started = true; Save(m); }
            if (m.started) ++active[m.kind];
            if (m.slots.length() > 0) ++planned[m.kind];
            else if (!m.started && m.kind == KindFusion && retryF is null) @retryF = m;
            else if (!m.started && m.kind == KindAfus && retryA is null) @retryA = m;
        }
        if (planned[KindAfus] < AirMath::PlannedBays(active[KindAfus], AiMax(2, Global::RoleSettings::Air::PlannedEcoModules)))
            Reserve(Global::AISettings::Side, retryA, KindAfus);
        // Fusion modules only in the fusion era: no early land use before the
        // first reactor matters (D-292).
        if ((AirEconomy::PreparingFusion() || AirEconomy::HasReactor())
            && planned[KindFusion] < AirMath::PlannedBays(active[KindFusion], AiMax(1, Global::RoleSettings::Air::PlannedFusionModules)))
            Reserve(Global::AISettings::Side, retryF, KindFusion);
        AuditReactors();
    }
    bool Managed(const CCircuitDef@ d)
    {
        const string side = UnitHelpers::GetSideForUnitName(d.GetName());
        return d.GetName() == UnitHelpers::GetAdvFusionNameForSide(side)
            || d.GetName() == UnitHelpers::GetAdvEnergyConverterNameForSide(side)
            || d.GetName() == UnitHelpers::GetFusionNameForSide(side); // D-292: ordinary fusion is a module kind
    }
    // D-292 fallback: a fusion never stalls (D-148 first-fusion target) when the
    // home disc has no module site. Only after module placement has failed
    // continuously for FusionModuleFallbackSeconds does AirLayout run its old
    // ring search; each such order is recorded so INV-203 can tell it apart
    // from an unmanaged placement. An attempt gap over 10 s restarts the window.
    int fusionFailSince = -1, fusionLastAttempt = -1;
    array<IUnitTask@> fallbackTasks;
    void ResetFallback() { fusionFailSince = -1; fusionLastAttempt = -1; fallbackTasks.resize(0); }
    bool FusionFallbackDue(const CCircuitDef@ d)
    {
        if (!IsFusion(d)) return false;
        if (!AirLayout::enabled) return true; // no modules exist without the layout: old placement, no delay
        if (fusionFailSince < 0 || ai.frame - fusionLastAttempt > 10 * SECOND) fusionFailSince = ai.frame;
        fusionLastAttempt = ai.frame;
        return ai.frame - fusionFailSince >= Global::RoleSettings::Air::FusionModuleFallbackSeconds * SECOND;
    }
    void FallbackPlaced(IUnitTask@ t, const CCircuitDef@ d)
    {
        if (t is null) return;
        fallbackTasks.insertLast(t);
        GenericHelpers::LogUtil("[AIR][EcoLayout] fusion fallback field site: no module fits def=" + d.GetName()
            + " waited=" + ((ai.frame - fusionFailSince) / SECOND) + "s", 1);
        fusionFailSince = -1;
    }
    // INV-203, once a second from PlanAhead: every unstarted AIR fusion/AFUS
    // order is pinned to slot 0 of a module of its own kind, or is a recorded
    // fallback. O(projects * modules); both stay small (tens x single digits).
    void AuditReactors()
    {
        for (int i = int(fallbackTasks.length()) - 1; i >= 0; --i)
            if (fallbackTasks[i] is null || fallbackTasks[i].IsDead()) fallbackTasks.removeAt(i);
        for (uint i = 0; i < AirBuild::projects.length(); ++i) {
            IBuilderTask@ t = cast<IBuilderTask>(AirBuild::projects[i]);
            if (t is null || t.IsDead() || t.target !is null || t.buildDef is null
                || t.GetBuildType() != int(Task::BuildType::ENERGY) || !AirBuild::IsReactor(t.buildDef)) continue;
            if (fallbackTasks.findByRef(AirBuild::projects[i]) >= 0) continue;
            const int kind = IsFusion(t.buildDef) ? KindFusion : KindAfus;
            // A pin is served on the order's first assignment (IBuilderTask
            // keeps pinnedReservation apart from reservationId until then), so
            // an order enqueued since the last audit still reads -1. Match it
            // by its build position, as INV-078 does for wind pins; a genuine
            // field order is at no module's reactor position.
            const int slot = AiTaskReservationId(AirBuild::projects[i]);
            const AIFloat3 at = t.GetBuildPos();
            bool pinned = false;
            for (uint m = 0; m < modules.length() && !pinned; ++m) {
                if (modules[m].kind != kind || modules[m].slots.length() == 0) continue;
                const int reactor = modules[m].slots[0];
                pinned = reactor == slot || (slot < 0 && aiTerrainMgr.GetReservationState(reactor) >= 0
                    && MapHelpers::SqDist(at, aiTerrainMgr.GetReservationPos(reactor)) < 1.0f);
            }
            if (!pinned) Invariants::Violation("INV-203", t.buildDef.GetName() + " slot " + slot,
                "AIR reactor order is not pinned to a " + KindName(kind) + " module reactor slot");
        }
    }
    IUnitTask@ Place(CCircuitUnit@ u, CCircuitDef@ d, Task::BuildType type, Task::Priority priority)
    {
        const string side = UnitHelpers::GetSideForUnitName(d.GetName());
        const bool fusion = d.GetName() == UnitHelpers::GetFusionNameForSide(side);
        const bool reactor = fusion || d.GetName() == UnitHelpers::GetAdvFusionNameForSide(side);
        const int kind = fusion ? KindFusion : KindAfus; // advanced converters live in AFUS modules
        // One extra module is allowed when all existing slots of this kind are occupied.
        const uint count = modules.length();
        for (uint i = 0; i <= count; ++i) {
            Module@ m = i == count ? Reserve(side, null, kind) : modules[i];
            if (m is null || m.side != side || m.kind != kind) continue;
            @m = Activate(m);
            if (m is null) continue;
            const uint limit = reactor && m.slots.length() > 0 ? 1 : m.slots.length();
            for (uint s = reactor ? 0 : 1; s < limit; ++s) {
                const int slot = m.slots[s];
                if (aiTerrainMgr.GetReservationState(slot) != 0 || !aiTerrainMgr.IsReservationBuildable(slot)) continue;
                if (!aiTerrainMgr.CanReachAt(u, aiTerrainMgr.GetReservationPos(slot), u.circuitDef.GetBuildDistance())) continue;
                IUnitTask@ task = AirLayout::Pinned(type, priority, d, slot);
                if (task is null) continue;
                m.started = true; Save(m);
                if (m.zone <= 0 || m.slots.length() != uint(1 + ConverterSlots(m.kind)))
                    Invariants::Violation("INV-107", m.key, "AIR economy module order lacks its complete reserved module");
                if (fusion) fusionFailSince = -1;
                GenericHelpers::LogUtil("[AIR][EcoLayout] place " + d.GetName() + " in " + m.key + " slot=" + slot
                    + " kind=" + KindName(m.kind), 1);
                return task;
            }
        }
        return null;
    }
    IUnitTask@ Nano(CCircuitUnit@ u, CCircuitDef@ nano) {
        for (uint i = 0; i < modules.length(); ++i) {
            Module@ m = modules[i];
            if (m.slots.length() == 0) continue;
            CCircuitUnit@ reactor = aiTerrainMgr.GetReservationUnit(m.slots[0]);
            // Reserved future districts are not a reason to build unused power.
            if (reactor is null || reactor.GetBuildProgress() >= 1.0f || AirWorkforce::shortage <= 0
                || !AirWorkforce::Useful(reactor, u)) continue;
            const CCircuitDef@ job = reactor.circuitDef;
            if (job.GetBuildTime() <= 0 || !AirWorkforce::Fund(nano, u.circuitDef.GetBuildSpeed(),
                nano.GetBuildSpeed() * job.costM / job.GetBuildTime(), nano.GetBuildSpeed() * job.costE / job.GetBuildTime())) continue;
            ReserveSupport(m);
            for (uint s = 0; s < m.support.length(); ++s) {
                const int pin = m.support[s];
                if (aiTerrainMgr.GetReservationState(pin) != 0 || !aiTerrainMgr.IsReservationBuildable(pin)) continue;
                const AIFloat3 pos = aiTerrainMgr.GetReservationPos(pin);
                if (!aiTerrainMgr.CanReachAt(u, pos, u.circuitDef.GetBuildDistance())) continue;
                IUnitTask@ task = AirLayout::Pinned(Task::BuildType::NANO, Task::Priority::HIGH, nano, pin);
                if (task !is null) return task;
            }
        }
        return null;
    }
    void Leave() { modules.resize(0); supportPositions.deleteAll(); retryAfter[0] = 0; retryAfter[1] = 0; planFrame = -100000; ResetFallback(); }
}
