#include "../../helpers/math/transport_math.as"

// TECH carrier pool, independent of the constructor ferry's single cargo queue.
// IDs are lifecycle-maintained; one reconstruction census covers load/late setup.
// Update is O(P), not O(army), once per existing Ferry::Update. Native ferry tasks
// own load/flight state. Never reset a carrier another logistics owner is using.
namespace Team { namespace HeavyTransport {
    array<int> carriers;
    dictionary held; // carrier ID -> CFerryTask@; task replacement invalidates the hold
    bool reconstructed = false;
    int desired = 0;
    int lastRequestFrame = -1;
    int requestedProvider = -1;
    const string TargetKey = "tech.transport.target";

    void CancelRequest() {
        if (requestedProvider < 0) return;
        AiSendMessage(Ferry::MSG + "|cancel|heavy", requestedProvider);
        requestedProvider = -1;
        lastRequestFrame = -1;
    }

    bool Enabled() { return Global::Ferry::Enabled && Global::AISettings::Role == AiRole::TECH
        && Global::RoleSettings::Tech::HeavyTransportPoolEnabled; }
    void Added(CCircuitUnit@ unit) {
        if (!Enabled() || !Ferry::IsHeavyTransport(unit) || unit.GetBuildProgress() < 1.0f) return;
        if (carriers.find(unit.id) < 0) { carriers.insertLast(unit.id); carriers.sortAsc(); }
        CCircuitDef@ definition = ai.GetCircuitDef(unit.circuitDef.GetName());
        if (definition !is null) definition.maxThisUnit = 0; // close the explicit slot after completion
    }
    void Removed(CCircuitUnit@ unit) {
        if (unit is null) return;
        const int index = carriers.find(unit.id);
        if (index >= 0) carriers.removeAt(index);
        held.delete("" + unit.id);
    }
    bool Busy(CFerryTask@ task) {
        return task !is null && task.GetState() != 0
            && task.GetState() != Ferry::StateDone && task.GetState() != Ferry::StateFailed;
    }
    int Available(CCircuitUnit@ cargo) {
        if (!Enabled() || cargo is null) return -1;
        for (uint index = 0; index < carriers.length(); ++index) {
            const int id = carriers[index];
            CFerryTask@ task = Ferry::TaskOf(ai.GetTeamUnit(id));
            if (task !is null && task.GetState() == 0 && task.CanCarry(cargo.id)) return id;
        }
        return -1;
    }
    int CompletedCount() { return int(carriers.length()); }
    string OwnDefinition() {
        string name;
        if (!Global::Ferry::HeavyTransportBySide.get(Global::AISettings::Side, name)) return "";
        return name;
    }
    bool HasLocalFactory() {
        // Fixed six-definition lookup, not a census of factories or units.
        const array<string> names = {"armap", "corap", "legap", "armaap", "coraap", "legaap"};
        CCircuitDef@ carrier = ai.GetCircuitDef(OwnDefinition());
        if (carrier is null || !TechTransport::WantsCarrier(carrier)) return false;
        for (uint index = 0; index < names.length(); ++index) {
            CCircuitDef@ factory = ai.GetCircuitDef(names[index]);
            if (factory !is null && factory.count > 0 && factory.CanBuild(carrier)) return true;
        }
        return false;
    }
    int IncomingLocal() {
        CCircuitDef@ definition = ai.GetCircuitDef(OwnDefinition());
        return definition is null ? 0 : aiFactoryMgr.GetPendingRecruitCount(definition)
            + aiBuilderMgr.GetUnfinishedCount(definition);
    }
    IUnitTask@ FactoryTask(CCircuitUnit@ factory) {
        if (!Enabled() || factory is null || CompletedCount() + IncomingLocal() >= desired) return null;
        CCircuitDef@ definition = ai.GetCircuitDef(OwnDefinition());
        if (definition is null || !TechTransport::WantsCarrier(definition)
            || !factory.circuitDef.CanBuild(definition) || Lifecycle::IsRetiring(factory)) return null;
        // The explicit order owns this temporary cap; generic production never
        // sees an open discretionary transport slot after the enqueue.
        definition.maxThisUnit = definition.count + 1;
        IUnitTask@ task = aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER,
            Task::Priority::NOW, definition, factory.GetPos(ai.frame), 64.0f));
        if (task !is null) GenericHelpers::LogUtil("[HeavyTransport] local order " + OwnDefinition()
            + " owned=" + CompletedCount() + " target=" + desired, 1);
        return task;
    }
    void Request() {
        if (!Enabled() || CompletedCount() >= desired || HasLocalFactory()) return;
        if (lastRequestFrame >= 0 && ai.frame - lastRequestFrame < int(Global::Ferry::RequestCooldownSeconds) * SECOND) return;
        array<Team::Roster::Entry@>@ providers = Team::Roster::WithRole(AiRole::AIR);
        int provider = -1;
        float nearest = 1e30f;
        for (uint index = 0; index < providers.length(); ++index) {
            string name;
            if (!Global::Ferry::HeavyTransportBySide.get(providers[index].side, name)
                || !TechTransport::WantsCarrier(ai.GetCircuitDef(name))) continue;
            const float distance = MapHelpers::SqDist(Global::Map::StartPos, providers[index].startPos);
            if (distance < nearest || (distance == nearest && providers[index].teamId < provider)) {
                nearest = distance; provider = providers[index].teamId;
            }
        }
        if (provider < 0) return; // target stays outstanding, including late roster announcements
        if (requestedProvider >= 0 && requestedProvider != provider) CancelRequest();
        lastRequestFrame = ai.frame;
        requestedProvider = provider;
        AiSendMessage(Ferry::MSG + "|req|" + int(Global::Map::StartPos.x) + "|"
            + int(Global::Map::StartPos.z) + "|heavy", provider);
        GenericHelpers::LogUtil("[HeavyTransport] request AIR=" + provider + " owned="
            + CompletedCount() + " target=" + desired, 1);
    }
    void Update() {
        if (!Enabled()) {
            CancelRequest();
            if (desired != 0) { desired = 0; aiTerrainMgr.SetLayoutInt(TargetKey, 0); }
            return;
        }
        if (AiPerfEnabled) AiPerfBeginLabel("tech-transport-pool");
        UpdateImpl();
        if (AiPerfEnabled) AiPerfEndLabel();
    }
    void UpdateImpl() {
        if (!reconstructed) {
            desired = aiTerrainMgr.GetLayoutInt(TargetKey, 0);
            array<Id>@ own = ai.GetOwnedUnitIds();
            for (uint index = 0; index < own.length(); ++index) Added(ai.GetTeamUnit(own[index]));
            reconstructed = true;
        }
        bool needed = false;
        for (uint index = 0; index < Global::Ferry::HeavyTransportDefs.length(); ++index) {
            if (TechTransport::WantsCarrier(ai.GetCircuitDef(Global::Ferry::HeavyTransportDefs[index]))) {
                needed = true;
                break;
            }
        }
        const int target = needed ? TransportMath::DesiredCount(Economy::GetMinMetalIncomeLast10s(),
            Global::Ferry::RequestMinMetalIncome, Global::RoleSettings::Tech::HeavyTransportAdditionalIncomeStart,
            Global::RoleSettings::Tech::HeavyTransportMetalPerAdditional, desired) : 0;
        if (target != desired) {
            desired = target;
            aiTerrainMgr.SetLayoutInt(TargetKey, desired);
            GenericHelpers::LogUtil("[HeavyTransport] pool target=" + desired, 1);
        }
        if (!needed) CancelRequest();
        for (uint index = 0; index < carriers.length(); ++index) {
            const string key = "" + carriers[index];
            CFerryTask@ task = Ferry::TaskOf(ai.GetTeamUnit(carriers[index]));
            CFerryTask@ previous;
            held.get(key, @previous);
            if (task !is null && task !is previous
                && Ferry::_ApplyHold(carriers[index], Global::Map::StartPos, "pool")) held.set(key, @task);
            if (task !is null && !(carriers[index] == Ferry::transportId && Ferry::cargoId >= 0)
                && (task.GetState() == Ferry::StateDone || task.GetState() == Ferry::StateFailed)
                && ai.GetTeamUnit(task.GetCargoId()) is null) task.Reset();
        }
        Request(); // receipt, not acknowledgement, closes the outstanding deficit
    }
} }
