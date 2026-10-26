// Stable FRONT seats, assigned in completion order rather than engine unit-ID
// order. A casualty opens only its own seat; surviving workers never reshuffle.
namespace FrontConstructors {
    array<int> seats = {-1, -1, -1}; // Base Support Group, expansion, Commander Group
    array<bool> filled = {false, false, false};
    bool loaded = false;
    IUnitTask@ recruit = null;
    void Load() {
        if (loaded) return;
        loaded = true;
        for (uint i = 0; i < seats.length(); ++i) {
            seats[i] = aiTerrainMgr.GetLayoutInt("front.constructor." + i, -1);
            filled[i] = aiTerrainMgr.GetLayoutInt("front.constructor.filled." + i, 0) != 0;
        }
    }
    void Save(int seat) {
        aiTerrainMgr.SetLayoutInt("front.constructor." + seat, seats[seat]);
        aiTerrainMgr.SetLayoutInt("front.constructor.filled." + seat, filled[seat] ? 1 : 0);
    }
    const array<string> candidates = {"armck","corck","legck","armcv","corcv","legcv",
        "armch","corch","legch","armbeaver","cormuskrat","legotter"};
    bool Eligible(CCircuitUnit@ unit) {
        return unit !is null && candidates.find(unit.circuitDef.GetName()) >= 0
            && !unit.circuitDef.IsAbleToFly();
    }
    int Seat(int id) { Load(); return seats.find(id); }
    bool IsBase(int id) { Load(); return id >= 0 && seats[0] == id; }
    int Missing() {
        Load();
        for (uint i = 0; i < seats.length(); ++i) if (seats[i] < 0) return int(i);
        return -1;
    }
    bool OnAdded(CCircuitUnit@ unit) {
        if (Global::AISettings::Role != AiRole::FRONT || !Eligible(unit)) return false;
        if (Team::Ferry::IsGift(unit.id) || Team::Recovery::IsGift(unit.id)) return false;
        // Called on builder admission/completion. No recurring owned-army scan,
        // borrowed handles, or random-ID ordering. At most three comparisons.
        int seat = Seat(unit.id);
        if (seat < 0) {
            seat = Missing();
            if (seat >= 0) { seats[seat] = unit.id; filled[seat] = true; Save(seat); }
            GenericHelpers::LogUtil("[FrontConstructors] assigned unit=" + unit.id + " seat=" + seat, 1);
        }
        if (seat == 0) unit.AddAttribute(Unit::Attr::BASE.type);
        else unit.DelAttribute(Unit::Attr::BASE.type);
        return true; // bypass generic primary/secondary/guard reassignment
    }
    void OnRemoved(CCircuitUnit@ unit) {
        const int seat = Seat(unit.id);
        if (seat < 0) return;
        seats[seat] = -1; Save(seat);
        GenericHelpers::LogUtil("[FrontConstructors] vacant seat=" + seat + " unit=" + unit.id, 1);
    }
    IUnitTask@ Recruit(CCircuitUnit@ factory, bool commanderEnabled) {
        const int seat = Missing();
        if (seat < 0) return null;
        // Preserve constructor/scout/raiders/constructor opening order. Once
        // a seat has existed, replacing it precedes all optional production.
        if (seat == 1 && !filled[1] && !RoleFront::g_frontPostRaidConstructorQueued) return null;
        if (seat == 2 && !filled[2] && !commanderEnabled) return null;
        // Hold our one recruit through frame construction; the shared pending
        // index counts only unstarted orders. Release the handle on completion
        // or cancellation, without retaining an engine unit across callbacks.
        if (recruit !is null && !recruit.IsDead()) return null;
        @recruit = null;
        for (uint i = 0; i < candidates.length(); ++i) {
            CCircuitDef@ def = ai.GetCircuitDef(candidates[i]);
            if (def !is null && aiFactoryMgr.GetPendingRecruitCount(def) > 0) return null;
        }
        for (uint i = 0; i < candidates.length(); ++i) {
            CCircuitDef@ def = ai.GetCircuitDef(candidates[i]);
            if (def is null || !factory.circuitDef.CanBuild(def) || !def.IsAvailable(ai.frame)) continue;
            IUnitTask@ task = aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER,
                Task::Priority::HIGH, def, factory.GetPos(ai.frame), 64.f));
            @recruit = task;
            if (task !is null) GenericHelpers::LogUtil("[FrontConstructors] recruit seat=" + seat + " def=" + def.GetName(), 1);
            return task;
        }
        return null;
    }
    bool Local(IUnitTask@ task) {
        IBuilderTask@ build = cast<IBuilderTask>(task);
        if (build is null) return false;
        const AIFloat3 p = build.GetBuildPos();
        const float radius = Global::RoleSettings::Front::BaseSupportRadius;
        return p.x >= 0.f && p.z >= 0.f && MapHelpers::SqDist(p, Global::Map::StartPos) <= radius * radius;
    }
    IUnitTask@ BaseWork(CCircuitUnit@ unit) {
        // Keep an in-progress local structure; never abort shared work merely
        // to select another economic rung. Native retreat/combat owns safety.
        IBuilderTask@ current = cast<IBuilderTask>(unit.task);
        if (current !is null && !current.IsDead() && current.target !is null
            && current.GetBuildType() < int(Task::BuildType::REPAIR) && Local(current)) return current;
        IUnitTask@ normal = aiBuilderMgr.DefaultMakeTask(unit);
        IBuilderTask@ build = cast<IBuilderTask>(normal);
        if (normal is null) return aiBuilderMgr.Enqueue(TaskB::Wait(SECOND));
        if (normal.GetType() == int(Task::Type::WAIT)) return normal;
        if (Local(normal) && build.GetBuildType() == int(Task::BuildType::ENERGY)) return normal;
        IUnitTask@ special = RoleFront::Front_T1Constructor_AiMakeTask(unit, null,
            Economy::GetMinMetalIncomeLast10s(), Economy::GetMinEnergyIncomeLast10s(),
            aiEconomyMgr.isEnergyStalling, aiEconomyMgr.isEnergyFull);
        if (special !is null) return special;
        if (Local(normal)) return normal;
        // Rejected fresh defaults are retired by the native default-task owner;
        // queued tasks belonging to other builders remain untouched.
        return aiBuilderMgr.Enqueue(TaskB::Patrol(Task::Priority::LOW, Global::Map::StartPos, 10 * SECOND));
    }
}
