// Test-only identical-input workload. Appended to an isolated profile, never data/.
namespace WeaponPerformanceProbe {
    int rounds = 0;
    array<TechWeapons::WCluster@> fixture;
    void Tick() {
        if (Global::AISettings::Role != AiRole::TECH || ai.frame < 10 * SECOND || rounds >= 100) return;
        CCircuitUnit@ u = Builder::GetCommander();
        if (u is null || u.circuitDef is null) return;
        CCircuitDef@ d = TechWeapons::Def("super");
        if (d is null || u.circuitDef.CanBuild(d) || UnitHelpers::IsAirConstructor(u.circuitDef)) {
            GenericHelpers::LogUtil("[WeaponPerf] FAIL fixture requires a ground builder unable to build the super cannon",1);
            rounds = 100; return;
        }
        if (fixture.length() == 0) {
            for (int i = 0; i < 32; ++i) {
                TechWeapons::WCluster c; c.kind = TechWeapons::KILL;
                for (int j = 0; j < 16; ++j) c.slots.insertLast(TechWeapons::Slot("super", u.GetPos(ai.frame)));
                fixture.insertLast(c);
            }
        }
        array<TechWeapons::WCluster@> saved = TechWeapons::clusters;
        const bool enabled = Global::RoleSettings::Tech::WeaponClustersEnabled;
        const bool experimental = Global::RoleSettings::Tech::ExperimentalBuild;
        const float start = Global::RoleSettings::Tech::WeaponStartMetalIncome;
        const float gate = Global::RoleSettings::Tech::WeaponKillMinIncome;
        const int concurrent = Global::RoleSettings::Tech::WeaponMaxConcurrent;
        Global::RoleSettings::Tech::WeaponClustersEnabled = true;
        Global::RoleSettings::Tech::ExperimentalBuild = true;
        Global::RoleSettings::Tech::WeaponStartMetalIncome = 0;
        Global::RoleSettings::Tech::WeaponKillMinIncome = 0;
        Global::RoleSettings::Tech::WeaponMaxConcurrent = 4;
        for (uint i = 0; i < fixture.length(); ++i) fixture[i].pos = u.GetPos(ai.frame);
        TechWeapons::clusters = fixture;
        // ABBA ordering, ten unchanged asks per second. No order/site is reachable:
        // every slot has the validated definition the builder cannot construct.
        const bool old = rounds % 4 == 0 || rounds % 4 == 3;
        bool clean = true;
        AiPerfBeginLabel(old ? "weapon-fixture-old" : "weapon-fixture-new");
        for (int i = 0; i < 10; ++i) {
            IUnitTask@ task = old ? TechWeapons::FixtureOldWork(u) : TechWeapons::Work(u);
            if (task !is null) clean = false;
        }
        AiPerfEndLabel();
        TechWeapons::clusters = saved;
        Global::RoleSettings::Tech::WeaponClustersEnabled = enabled;
        Global::RoleSettings::Tech::ExperimentalBuild = experimental;
        Global::RoleSettings::Tech::WeaponStartMetalIncome = start;
        Global::RoleSettings::Tech::WeaponKillMinIncome = gate;
        Global::RoleSettings::Tech::WeaponMaxConcurrent = concurrent;
        ++rounds;
        if (!clean) GenericHelpers::LogUtil("[WeaponPerf] FAIL unexpected task",1);
        if (rounds == 100) GenericHelpers::LogUtil("[WeaponPerf] PASS 500 old and 500 new asks, 32 clusters x 16 slots, actual UnitDef mapping, no orders",1);
    }
}
