// FRONT first factory at the spawn (owner, 2026-10-19).
//
// Native orders the first factory as a "plop": it has no site of its own and
// is built wherever the builder that takes it is standing (BuilderTask.cpp
// AssignTo). Native holds that order until energy income can feed the plant,
// and meanwhile the commander takes mexes. Played (All That Simmers, team 14):
// energy stayed +49..+64 for four minutes, the commander walked off mexing,
// and the vehicle plant went up near the enemy front at 4:12.
//
// Two rules while no factory of ours stands or is framed:
// - leash: a commander job whose site is more than SpawnFactoryLeashRadius
//   from the spawn becomes a solar at the spawn instead, so the commander is
//   home when native hands it the plant;
// - watchdog: from SpawnFactorySeconds, while energy income is below what
//   native's start check needs for the plant, every commander job other than
//   the plant becomes a solar at the spawn, so the check passes sooner.
// The plant itself stays native's order (a script-made one would leave
// native's held plop order to come back later as a second plant).
// Both stop once a factory is framed, or after SpawnFactoryLeashMaxSeconds.
namespace FrontSpawnFactory {
    bool done = false;
    IBuilderTask@ homeEnergy = null;
    int lastLogFrame = -1000000;

    void Reset() { done = false; @homeEnergy = null; lastLogFrame = -1000000; }

    bool FactoryFramed()
    {
        if (aiFactoryMgr.GetFactoryCount() > 0) return true;
        if (Global::AISettings::StartFactory.length() == 0) return false;
        CCircuitDef@ def = ai.GetCircuitDef(Global::AISettings::StartFactory);
        return def !is null && (def.count > 0 || aiBuilderMgr.GetUnfinishedCount(def) > 0);
    }

    float Distance2D(const AIFloat3 &in a, const AIFloat3 &in b)
    {
        const float dx = a.x - b.x;
        const float dz = a.z - b.z;
        return sqrt(dx * dx + dz * dz);
    }

    // The energy income native's start check asks for this plant
    // (EconomyManager::UpdateFactoryTasks: cost / (build time / commander speed)).
    float EnergyNeeded(CCircuitUnit@ comm)
    {
        if (Global::AISettings::StartFactory.length() == 0) return 0.0f;
        CCircuitDef@ def = ai.GetCircuitDef(Global::AISettings::StartFactory);
        const float speed = comm.circuitDef.GetBuildSpeed();
        if (def is null || speed <= 0.0f) return 0.0f;
        const float seconds = def.GetBuildTime() / speed;
        return seconds > 0.0f ? def.costE / seconds : 0.0f;
    }

    void Log(const string &in msg)
    {
        if (ai.frame - lastLogFrame < 5 * SECOND) return;
        lastLogFrame = ai.frame;
        GenericHelpers::LogUtil("[FRONT][SpawnFactory] " + msg, 1);
    }

    IUnitTask@ HomeEnergy(CCircuitUnit@ comm, const string &in why)
    {
        if (homeEnergy !is null && homeEnergy.IsDead()) @homeEnergy = null;
        if (homeEnergy !is null) return homeEnergy;
        const string name = UnitHelpers::GetSolarNameForSide(Global::AISettings::Side);
        if (Global::energyAllowed !is null && !Global::energyAllowed(name)) return null;   // D-077
        CCircuitDef@ solar = ai.GetCircuitDef(name);
        if (solar is null || !solar.IsAvailable(ai.frame) || !comm.circuitDef.CanBuild(solar)) return null;
        @homeEnergy = cast<IBuilderTask>(aiBuilderMgr.Enqueue(TaskB::Common(Task::BuildType::ENERGY,
            Task::Priority::HIGH, solar, Global::Map::StartPos, SQUARE_SIZE * 16, true, 60 * SECOND)));
        if (homeEnergy !is null) {
            const AIFloat3 at = comm.GetPos(ai.frame);
            Log(name + " at the spawn instead (" + why + "); commander " + int(Distance2D(at, Global::Map::StartPos))
                + " from the spawn | E +" + int(aiEconomyMgr.energy.income) + " of " + int(EnergyNeeded(comm))
                + " | M +" + int(aiEconomyMgr.metal.income));
        }
        return homeEnergy;
    }

    // The commander's job before the first factory: the default task, or a solar at the spawn.
    IUnitTask@ Steer(CCircuitUnit@ comm, IUnitTask@ defaultTask)
    {
        if (done || comm is null || !Global::RoleSettings::Front::SpawnFactoryEnabled) return defaultTask;
        if (FactoryFramed() || ai.frame > Global::RoleSettings::Front::SpawnFactoryLeashMaxSeconds * SECOND) {
            done = true;
            const bool framed = FactoryFramed();
            lastLogFrame = -1000000;
            Log(framed ? "a factory is framed; leash off" : "no factory after "
                + Global::RoleSettings::Front::SpawnFactoryLeashMaxSeconds + " s; leash off, native as before");
            return defaultTask;
        }
        IBuilderTask@ build = cast<IBuilderTask>(defaultTask);
        const AIFloat3 at = comm.GetPos(ai.frame);
        const float radius = Global::RoleSettings::Front::SpawnFactoryLeashRadius;
        if (build !is null && Task::BuildType(build.GetBuildType()) == Task::BuildType::FACTORY) {
            // native's plop: it is built where the commander stands when it takes it
            if (radius <= 0.0f || Distance2D(at, Global::Map::StartPos) <= radius) {
                Log("commander takes the " + (build.buildDef is null ? "factory" : build.buildDef.GetName())
                    + " " + int(Distance2D(at, Global::Map::StartPos)) + " from the spawn");
                return defaultTask;
            }
            IUnitTask@ home = HomeEnergy(comm, "the factory would go where the commander stands");
            return home !is null ? home : defaultTask;
        }
        if (radius > 0.0f && build !is null) {
            const AIFloat3 site = build.GetBuildPos();
            if (site.x >= 0.0f && Distance2D(site, Global::Map::StartPos) > radius) {
                IUnitTask@ home = HomeEnergy(comm, "leash: a job " + int(Distance2D(site, Global::Map::StartPos)) + " out");
                if (home !is null) return home;
            }
        }
        if (ai.frame >= Global::RoleSettings::Front::SpawnFactorySeconds * SECOND
            && aiEconomyMgr.energy.income < EnergyNeeded(comm)
            && (build is null || Task::BuildType(build.GetBuildType()) != Task::BuildType::ENERGY)) {
            IUnitTask@ home = HomeEnergy(comm, "no factory at " + Global::RoleSettings::Front::SpawnFactorySeconds + " s");
            if (home !is null) return home;
        }
        return defaultTask;
    }
}
