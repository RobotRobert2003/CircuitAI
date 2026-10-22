// Supplied construction fixture. Native tasks/placement/queues remain real;
// the observed income stream is controlled separately from natural benchmarks.
namespace GantryProbe {
    bool active = false;
    string mode;
    int nextSample = 0;
    bool checked = false;
    bool droppedSupport = false, adoptedFrame = false;
    void Recover() {
        if (mode != "recovery") return;
        TechFactories::Cluster@ cluster = TechFactories::ExistingGantry();
        if (cluster is null) return;
        IBuilderTask@ support = cast<IBuilderTask>(cluster.gantrySupportTask);
        if (!droppedSupport && support !is null && !support.IsDead()
            && support.target is null && support.GetUnits().length() > 0) {
            array<CCircuitUnit@>@ workers = support.GetUnits();
            workers[0].CmdStop();
            droppedSupport = true;
            GenericHelpers::LogUtil("[GantryTest] dropped_support_order", 1);
        }
        CCircuitUnit@ factory = TechFactories::LabAt(cluster);
        if (adoptedFrame || factory is null || factory.GetBuildProgress() >= 1.0f) return;
        array<int>@ ids = ai.GetOwnedUnitIds();
        for (uint index = 0; index < ids.length(); ++index) {
            CCircuitUnit@ builder = ai.GetTeamUnit(ids[index]);
            if (builder is null || !builder.circuitDef.CanBuild(factory.circuitDef)) continue;
            // Lose only the script handle, never abort the productive native task.
            @cluster.labTask = null;
            IBuilderTask@ repair = cast<IBuilderTask>(TechFactories::Work(ai.GetCircuitDef(cluster.defName), builder, false));
            const bool correct = repair !is null && repair.target is factory;
            GenericHelpers::LogUtil("[GantryTest] " + (correct ? "PASS" : "FAIL") + " late_frame_adopted", 1);
            adoptedFrame = true;
            return;
        }
    }
    void Verify() {
        CCircuitDef@ definition = ai.GetCircuitDef(TechChain::DefFor("gantry"));
        array<int>@ ids = ai.GetOwnedUnitIds();
        CCircuitUnit@ builder = null;
        for (uint index = 0; index < ids.length(); ++index) {
            CCircuitUnit@ unit = ai.GetTeamUnit(ids[index]);
            if (unit !is null && unit.circuitDef.CanBuild(definition)) { @builder = unit; break; }
        }
        bool correct = builder !is null && TechGantry::Ready(definition, builder);
        const int previousSilo = TechChain::nukeFundingSilo;
        TechChain::nukeFundingSilo = 123;
        correct = correct && !TechGantry::Ready(definition, builder);
        TechChain::nukeFundingSilo = previousSilo;
        const uint previousMask = Global::RoleSettings::Tech::StrategyMask;
        Global::RoleSettings::Tech::StrategyMask |= uint(1) << uint(Strategy::T2_RUSH);
        correct = correct && !TechGantry::Ready(definition, builder);
        Global::RoleSettings::Tech::StrategyMask = previousMask;
        const float previousPower = Global::RoleSettings::Tech::GantryMinimumBuilderPower;
        Global::RoleSettings::Tech::GantryMinimumBuilderPower = 1000000.0f;
        correct = correct && !TechGantry::Ready(definition, builder);
        Global::RoleSettings::Tech::GantryMinimumBuilderPower = previousPower;
        TechPlan::phase = 0;
        array<TechChain::Step@>@ phase = TechPlan::NextPhase("afus");
        bool early = false;
        for (uint index = 0; index < phase.length(); ++index) if (phase[index].key == "earlygantry") early = true;
        correct = correct && early == Global::RoleSettings::Tech::EarlyGantryEnabled;
        if (!early) correct = correct && phase.length() == 4 && phase[0].key == "ap" && phase[1].key == "aap"
            && phase[2].key == "income" && phase[3].key == "gantry";
        GenericHelpers::LogUtil("[GantryTest] " + (correct ? "PASS" : "FAIL") + " admission_and_profile_sequence early=" + early, 1);
        checked = true;
    }
    void Tick() {
        if (!active || ai.teamId != 0) return;
        const bool starved = mode == "starved" && ai.frame < 2 * MINUTE;
        Economy::_UpdateSlidingMinima(ai.frame, starved ? 100.0f : 240.0f, starved ? 0.0f : 20000.0f);
        TechGantry::metalWindow.Push(ai.frame, starved ? 100.0f : 240.0f, 10 * SECOND, 2 * SECOND);
        TechChain::Tick();
        Recover();
        if (mode == "policy" && ai.frame >= MINUTE && !checked) Verify();
        if (ai.frame < nextSample) return;
        nextSample = ai.frame + 10 * SECOND;
        TechFactories::Cluster@ cluster = TechFactories::ExistingGantry();
        GenericHelpers::LogUtil("[GantryTest] sample mode=" + mode + " clusters=" + TechFactories::clusters.length()
            + " labs=" + TechFactories::LandFactoryCount() + " average=" + TechGantry::metalWindow.Mean()
            + " funded=" + TechGantry::Funded(ai.GetCircuitDef(TechChain::DefFor("gantry")), true)
            + " turrets=" + (cluster is null ? -1 : TechFactories::FinishedTurrets(cluster)), 1);
    }
    IUnitTask@ Task(CCircuitUnit@ builder) {
        if (!active || mode == "policy" || ai.teamId != 0 || builder is Builder::commander) return aiBuilderMgr.Enqueue(TaskB::Wait(SECOND));
        IUnitTask@ current = TechBuild::KeepCurrent(builder);
        if (current !is null) return current;
        IUnitTask@ work = TechGantry::SupportWork(builder);
        if (work is null) @work = TechGantry::EarlyWork(builder);
        return work is null ? aiBuilderMgr.Enqueue(TaskB::Wait(SECOND)) : work;
    }
    bool Handle(const string& in message) {
        array<string>@ fields = message.split("|");
        if (fields.length() < 2 || fields[0] != "gantry-probe") return false;
        if (fields[1] == "setup") {
            active = true; mode = fields[2];
            Global::RoleSettings::Tech::StrategyMask = uint(1) << uint(Strategy::T3_RUSH);
            TechPlan::plan = "t3rush";
            TechChain::active = true; TechChain::done = false; TechChain::objective = "afus";
            TechChain::steps.resize(0);
            TechChain::steps.insertLast(TechChain::Step("earlygantry", TechChain::DefFor("gantry"), 1));
            TechChain::skipped.resize(1);
            GenericHelpers::LogUtil("[GantryTest] setup mode=" + mode + " enabled=" + TechGantry::EarlyEnabled(), 1);
        }
        return true;
    }
}
