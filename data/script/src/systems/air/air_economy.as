#include "air_layout.as"
#include "../../manager/economy.as"
#include "../../helpers/math/air_math.as"
#include "air_workforce.as"

namespace AirEconomy {
    float metal = 0.0f, energy = 0.0f, bankM = 0.0f, bankE = 0.0f;
    float demandM = 0.0f, demandE = 0.0f;
    int sampleFrame = -1, stableSince = -1, lastLog = -100000;
    bool recovery = false;
    int badSamples = 0, goodSamples = 0;
    int t1 = 0, t2 = 0;
    string state = "BOOTSTRAP";
    array<int> owned;
    dictionary nanoBay; // one primary bay per live assistant
    dictionary supportOwner; // snapped reserved position -> bay; rebuilt only after layout changes
    int supportRevision = -1;
    array<float> power;
    array<int> nanoCount;
    array<int> nanoFuture;

    bool Active() { return Global::AISettings::Role == AiRole::AIR && AirLayout::enabled; }
    bool TechGrowth() { return !MetalEconomy::Active() && aiTerrainMgr.GetLayoutInt("air.techGrowth", 0) != 0; }
    bool GrowthComplete() { return aiTerrainMgr.GetLayoutInt("air.massBombers", 0) != 0; }
    bool MassBombers() {
        CCircuitDef@ bomber = ai.GetCircuitDef(UnitHelpers::GetT2WaveBomberForSide(Global::AISettings::Side));
        const float floor = Global::RoleSettings::Air::BomberSustainableMetal;
        return t2 > 0 && bomber !is null && bomber.costM > 0
            && AirMath::SustainedProduction(Economy::IncomeWindowReady(), Economy::GetMinMetalIncomeLast10s(),
                Economy::GetMinEnergyIncomeLast10s(), floor, bomber.costE / bomber.costM, 30);
    }
    int CompletedAfus() {
        int count = 0;
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ unit = ai.GetTeamUnit(ids[i]);
            if (unit !is null && unit.GetBuildProgress() >= 1.0f && unit.circuitDef.GetName()
                == UnitHelpers::GetAdvFusionNameForSide(UnitHelpers::GetSideForUnitName(unit.circuitDef.GetName()))) ++count;
        }
        return count;
    }
    void UpdateMilestones() {
        if (MetalEconomy::Active()) return;
        if (!TechGrowth() && AirMath::GrowthPhase(Economy::IncomeWindowReady(), Economy::GetMinMetalIncomeLast10s(),
            Global::RoleSettings::Air::TechEconomyMinMetal)) {
            aiTerrainMgr.SetLayoutInt("air.techGrowth", 1);
            GenericHelpers::LogUtil("[AIR][Growth] shared TECH economy enabled at M10=" + Economy::GetMinMetalIncomeLast10s(), 1);
        }
        if (!GrowthComplete() && AirMath::MassBombersReady(CompletedAfus(), Global::RoleSettings::Air::MassBomberAfusCount)) {
            aiTerrainMgr.SetLayoutInt("air.massBombers", 1);
            GenericHelpers::LogUtil("[AIR][Growth] growth objective reached; completed AFUS=" + CompletedAfus(), 1);
        }
    }
    bool HasReactor()
    {
        const string side = Global::AISettings::Side;
        const string fusion = UnitHelpers::GetFusionNameForSide(side);
        const string advanced = UnitHelpers::GetAdvFusionNameForSide(side);
        for (uint i = 0; i < owned.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(owned[i]);
            if (u !is null && u.GetBuildProgress() >= 1.0f
                && (u.circuitDef.GetName() == fusion || u.circuitDef.GetName() == advanced)) return true;
        }
        return false;
    }
    bool PreparingFusion()
    {
        return !HasReactor() && ProductionMath::PreparationDue(ai.frame / SECOND,
            Global::RoleSettings::Air::FirstFusionTargetSeconds, Global::RoleSettings::Air::FirstFusionLeadSeconds);
    }
    bool NeedsMexUpgrade(const CCircuitDef@ d)
    {
        if (d is null || d.GetExtractsMetal() <= 0.0f) return false;
        string side = UnitHelpers::GetSideForUnitName(d.GetName());
        if (side.length() == 0) side = Global::AISettings::Side;
        CCircuitDef@ advanced = ai.GetCircuitDef(UnitHelpers::GetT2MexNameForSide(side));
        return ProductionMath::MexNeedsUpgrade(d.GetExtractsMetal(), advanced is null ? 0.0f : advanced.GetExtractsMetal());
    }
    int MexCount()
    {
        int count = 0;
        for (uint i = 0; i < owned.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(owned[i]);
            if (u !is null && u.circuitDef.GetExtractsMetal() > 0.0f) ++count;
        }
        return count;
    }
    bool MexesReady()
    {
        // Fresh ownership, no radius or reach exemption; frames are not upgraded income.
        array<Id>@ ids = ai.GetOwnedUnitIds();
        int basic = 0, unfinished = 0;
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null || u.circuitDef.GetExtractsMetal() <= 0.0f) continue;
            if (NeedsMexUpgrade(u.circuitDef)) ++basic;
            else if (u.GetBuildProgress() < 1.0f) ++unfinished;
        }
        const int queued = aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::MEX), null)
            + aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::MEXUP), null);
        return ProductionMath::ReactorMayStart(basic, unfinished, queued);
    }
    bool HasAdvancedBuilder()
    {
        CCircuitDef@ mex = ai.GetCircuitDef(UnitHelpers::GetT2MexNameForSide(Global::AISettings::Side));
        if (mex is null) return false;
        for (uint i = 0; i < owned.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(owned[i]);
            if (u !is null && u.GetBuildProgress() >= 1.0f && u.circuitDef.CanBuild(mex)) return true;
        }
        return false;
    }
    int Count(const string &in name)
    {
        CCircuitDef@ d = ai.GetCircuitDef(name);
        return d is null ? 0 : d.count;
    }
    bool HasMobileConstructor()
    {
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u !is null && u.GetBuildProgress() >= 1.0f && u.circuitDef.IsMobile()
                && u.circuitDef.GetBuildSpeed() > 0.0f && !UnitHelpers::IsCommander(u.circuitDef)) return true;
        }
        return false;
    }
    int CompletedConstructors()
    {
        int count = 0;
        array<Id>@ ids = ai.GetOwnedUnitIds();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(ids[i]);
            if (u is null || u.GetBuildProgress() < 1.0f) continue;
            const string name = u.circuitDef.GetName();
            if (name == UnitHelpers::GetT1AirConstructorNameForSide(UnitHelpers::GetSideForUnitName(name))) ++count;
        }
        return count;
    }
    int Planned(CCircuitDef@ d, Task::BuildType type)
    {
        return d is null ? 0 : d.count + aiBuilderMgr.GetQueuedBuildCount(int(type), d);
    }
    void Reset()
    {
        AirWorkforce::Reset();
        sampleFrame = -1; stableSince = -1; lastLog = -100000;
        recovery = false; badSamples = 0; goodSamples = 0;
        armedAirMemory = 0.0f; armedAirFrame = -1;
        t1 = 0; t2 = 0; state = "BOOTSTRAP";
        owned.resize(0); nanoBay.deleteAll(); power.resize(0); nanoCount.resize(0); nanoFuture.resize(0);
        supportOwner.deleteAll(); supportRevision = -1;
    }
    string Fighter(bool advanced, const string &in faction = "")
    {
        const string side = faction.length() > 0 ? faction : Global::AISettings::Side;
        if (advanced) return UnitHelpers::GetT2FighterForSide(side);
        return side == "cortex" ? "corveng" : side == "legion" ? "legfig" : "armfig";
    }
    float armedAirMemory = 0.0f;
    int armedAirFrame = -1;
    float EnemyAir()
    {
        if (armedAirFrame != ai.frame) {
            const float dt = armedAirFrame < 0 ? 0.0f : float(ai.frame - armedAirFrame) / float(SECOND);
            armedAirMemory = AiMax(aiBattle.GetArmedAirCost(), armedAirMemory * AiMax(0.0f, 1.0f - dt / 300.0f));
            armedAirFrame = ai.frame;
        }
        return armedAirMemory;
    }
    int HomeTarget()
    {
        CCircuitDef@ d = ai.GetCircuitDef(Fighter(t2 > 0));
        const float cost = d is null ? 150.0f : AiMax(d.costM, 1.0f);
        return AiMax(Global::RoleSettings::Air::HomeFighterFloor,
            AiMin(Global::RoleSettings::Air::HomeFighterCeiling,
                int(EnemyAir() / cost * Global::RoleSettings::Air::HomeAirValueRatio + 0.999f)));
    }
    void Mix(bool advanced, float &out work, float &out costM, float &out costE)
    {
        CCircuitDef@ f = ai.GetCircuitDef(Fighter(advanced));
        const string side = Global::AISettings::Side;
        const string bn = advanced ? UnitHelpers::GetT2WaveBomberForSide(side)
            : (side == "cortex" ? "corshad" : side == "legion" ? "legmos" : "armthund");
        CCircuitDef@ b = ai.GetCircuitDef(bn);
        work = 0.0f; costM = 0.0f; costE = 0.0f;
        if (f is null) return;
        work = f.GetBuildTime(); costM = f.costM; costE = f.costE;
        if (b !is null && (!advanced || MassBombers())) {
            // Forecast the current order mix, not the old fixed seven/three.
            const float strikes = float(AirMath::BomberOrders(AirProduction::AvailableFighterValue(), EnemyAir(),
                MassBombers() ? Global::RoleSettings::Air::MassBomberOrdersClear : Global::RoleSettings::Air::BomberOrdersClear,
                MassBombers() ? Global::RoleSettings::Air::MassBomberOrdersParity : Global::RoleSettings::Air::BomberOrdersParity));
            const float fighters = 10.0f - strikes;
            work = (work * fighters + b.GetBuildTime() * strikes) / 10.0f;
            costM = (costM * fighters + b.costM * strikes) / 10.0f;
            costE = (costE * fighters + b.costE * strikes) / 10.0f;
        }
    }
    int SupportBay(const CCircuitDef@ d, const AIFloat3 &in pos)
    {
        if (d is null || AirEcoLayout::Owns(pos)) return -1;
        const int revision = aiTerrainMgr.GetLayoutInt("air.supportRevision", 0);
        if (supportRevision != revision) {
            supportOwner.deleteAll(); supportRevision = revision;
            for (uint b = 0; b < AirLayout::bays.length(); ++b) {
                for (uint s = 0; s < AirLayout::bays[b].nanos.length(); ++s) {
                    const int slot = AirLayout::bays[b].nanos[s];
                    if (aiTerrainMgr.GetReservationState(slot) < 0) continue;
                    const AIFloat3 at = aiTerrainMgr.GetReservationPos(slot);
                    supportOwner.set("" + int(at.x / 8.0f + 0.5f) + ":" + int(at.z / 8.0f + 0.5f), int(b));
                }
            }
        }
        int owner = -1;
        if (supportOwner.get("" + int(pos.x / 8.0f + 0.5f) + ":" + int(pos.z / 8.0f + 0.5f), owner)
            && owner >= 0 && owner < int(AirLayout::bays.length())) {
            CCircuitUnit@ plant = ai.GetTeamUnit(AirLayout::bays[owner].factoryId);
            if (plant !is null && !Lifecycle::IsRetiring(plant)
                && MapHelpers::SqDist(pos, plant.GetPos(ai.frame)) <= d.GetBuildDistance() * d.GetBuildDistance()) return owner;
        }
        int best = -1;
        float dist = d.GetBuildDistance() * d.GetBuildDistance();
        for (uint b = 0; b < AirLayout::bays.length(); ++b) {
            CCircuitUnit@ plant = ai.GetTeamUnit(AirLayout::bays[b].factoryId);
            if (plant is null || Lifecycle::IsRetiring(plant)) continue;
            const float sq = MapHelpers::SqDist(pos, plant.GetPos(ai.frame));
            if (sq < dist) { best = int(b); dist = sq; }
        }
        return best;
    }
    float HomeValueTarget()
    {
        CCircuitDef@ d = ai.GetCircuitDef(Fighter(t2 > 0));
        return float(HomeTarget()) * (d is null ? 150.0f : AiMax(d.costM, 1.0f));
    }
    void RefreshSupport()
    {
        owned = ai.GetOwnedUnitIds();
        nanoBay.deleteAll();
        power.resize(AirLayout::bays.length()); nanoCount.resize(power.length()); nanoFuture.resize(power.length());
        for (uint b = 0; b < power.length(); ++b) {
            CCircuitUnit@ plant = ai.GetTeamUnit(AirLayout::bays[b].factoryId);
            power[b] = plant !is null && !Lifecycle::IsRetiring(plant) && plant.GetBuildProgress() >= 1.0f ? plant.circuitDef.GetBuildSpeed() : 0.0f;
            nanoCount[b] = 0; nanoFuture[b] = 0;
        }
        for (uint i = 0; i < owned.length(); ++i) {
            CCircuitUnit@ n = ai.GetTeamUnit(owned[i]);
            if (n is null || Lifecycle::IsRetiring(n)) continue;
            const string name = n.circuitDef.GetName();
            if (name != UnitHelpers::GetT1NanoNameForSide(UnitHelpers::GetSideForUnitName(name))) continue;
            const int best = SupportBay(n.circuitDef, n.GetPos(ai.frame));
            if (best >= 0 && AirEcoLayout::Owns(n.GetPos(ai.frame)))
                Invariants::Violation("INV-125", "" + n.id, "economy support credited to an aircraft production bay");
            if (best < 0) continue;
            nanoBay.set("" + n.id, int64(best));
            if (n.GetBuildProgress() < 1.0f) { ++nanoFuture[best]; continue; }
            ++nanoCount[best];
            power[best] += n.circuitDef.GetBuildSpeed();
        }
    }
    bool ExistingT2SupportReady()
    {
        // Re-read gifts, deaths and completion immediately before an order.
        RefreshSupport();
        int factories = 0, finished = 0, least = Global::RoleSettings::Air::T2ExpansionSupport;
        for (uint i = 0; i < owned.length(); ++i) {
            CCircuitUnit@ plant = ai.GetTeamUnit(owned[i]);
            if (plant is null || !UnitHelpers::IsT2AircraftPlant(plant.circuitDef.GetName()) || Lifecycle::IsRetiring(plant)) continue;
            ++factories;
            if (plant.GetBuildProgress() >= 1.0f) ++finished;
            int count = 0;
            for (uint b = 0; b < AirLayout::bays.length(); ++b)
                if (AirLayout::bays[b].factoryId == plant.id) { count = nanoCount[b]; break; }
            least = AiMin(least, count);
        }
        return ProductionMath::ExpansionSupportReady(factories, finished, least, Global::RoleSettings::Air::T2ExpansionSupport);
    }
    void Tick()
    {
        if (!Active() || (sampleFrame >= 0 && ai.frame - sampleFrame < SECOND)) return;
        sampleFrame = ai.frame;
        UpdateMilestones();
        LayoutHelpers::CheckAlliedPlacements();
        AirLayout::PlanAhead();
        if (aiEconomyMgr.assistNanoEnabled)
            Invariants::Violation("INV-073", "AIR", "native nano planner enabled while AIR owns production support");
        metal = Economy::GetMinMetalIncomeLast10s(); energy = Economy::GetMinEnergyIncomeLast10s();
        bankM = aiEconomyMgr.metal.current; bankE = aiEconomyMgr.energy.current;
        const bool bad = aiEconomyMgr.isEnergyStalling && bankE < aiEconomyMgr.energy.storage * 0.3f;
        badSamples = bad ? badSamples + 1 : 0;
        goodSamples = !bad && bankE > aiEconomyMgr.energy.storage * 0.45f ? goodSamples + 1 : 0;
        if (badSamples >= 3) recovery = true;
        if (goodSamples >= 10) recovery = false;
        owned = ai.GetOwnedUnitIds();
        nanoBay.deleteAll();
        power.resize(AirLayout::bays.length()); nanoCount.resize(power.length()); nanoFuture.resize(power.length());
        for (uint b = 0; b < power.length(); ++b) {
            if (!AirLayout::Inside(AirLayout::bays[b].centre, 0.0f))
                Invariants::Violation("INV-074", "" + b, "AIR published a bay outside map bounds");
            power[b] = 0.0f; nanoCount[b] = 0; nanoFuture[b] = 0;
            AirLayout::bays[b].factoryId = -1;
        }
        t1 = 0; t2 = 0;
        for (uint i = 0; i < owned.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(owned[i]);
            if (u is null || Lifecycle::IsRetiring(u)) continue;
            const string name = u.circuitDef.GetName();
            // A native MEX task can build T2 directly when a gifted constructor
            // is available. Task completion then registers it as an ordinary
            // mex; reconcile observed T2 structures before proposing upgrades.
            if (UnitHelpers::IsT2Mex(name) && u.GetBuildProgress() >= 1.0f) {
                Economy::MexTracker::RegisterMex(u.GetPos(ai.frame));
                Economy::MexTracker::MarkUpgraded(u.GetPos(ai.frame));
            }
            if (!UnitHelpers::IsT1AircraftPlant(name) && !UnitHelpers::IsT2AircraftPlant(name)) continue;
            if (u.GetBuildProgress() >= 1.0f) { if (UnitHelpers::IsT2AircraftPlant(name)) ++t2; else ++t1; }
            int best = -1;
            float dist = 96.0f * 96.0f;
            for (uint b = 0; b < AirLayout::bays.length(); ++b) {
                if (AirLayout::bays[b].defName != name) continue;
                const float sq = MapHelpers::SqDist(u.GetPos(ai.frame), AirLayout::bays[b].centre);
                if (sq < dist) { best = int(b); dist = sq; }
            }
            // Gifts and role switches adopt the standing plant; never move it.
            if (best < 0) {
                AirLayout::Bay bay; bay.key = AirLayout::Key(int(AirLayout::bays.length()));
                bay.defName = name; bay.factoryId = u.id; bay.centre = u.GetPos(ai.frame); bay.facing = AirLayout::facing;
                AirLayout::bays.insertLast(bay); AirLayout::AdoptSupport(bay);
                power.insertLast(0.0f); nanoCount.insertLast(0); nanoFuture.insertLast(0);
                best = int(power.length()) - 1;
            }
            AirLayout::bays[best].factoryId = u.id;
            if (u.GetBuildProgress() >= 1.0f) power[best] = u.circuitDef.GetBuildSpeed();
        }
        const string nanoName = UnitHelpers::GetT1NanoNameForSide(Global::AISettings::Side);
        RefreshSupport();
        demandM = 0.0f; demandE = 0.0f;
        for (uint b = 0; b < power.length(); ++b) {
            float work = 0.0f, cm = 0.0f, ce = 0.0f;
            Mix(UnitHelpers::IsT2AircraftPlant(AirLayout::bays[b].defName), work, cm, ce);
            const float rate = ProductionMath::Rate(work, power[b], Global::RoleSettings::Air::WarmFactoryGapSeconds);
            demandM += rate * cm; demandE += rate * ce;
        }
        AirWorkforce::Tick();
        const bool spare = !recovery && metal * Global::RoleSettings::Air::ProductionIncomeShare > demandM * 1.15f
            && energy * 0.8f > demandE * 1.15f && bankM > 500.0f;
        if (!spare) stableSince = -1; else if (stableSince < 0) stableSince = ai.frame;
        string next = t1 + t2 == 0 ? "BOOTSTRAP" : t2 > 1 ? "MULTIPLANT" : t2 == 1 ? "T2_SUSTAIN" : metal >= 15.0f ? "T1_SCALE" : "T1_CONTEST";
        CCircuitDef@ ad = ai.GetCircuitDef(UnitHelpers::GetT2AirPlantForSide(Global::AISettings::Side));
        if (t2 == 0 && Planned(ad, Task::BuildType::FACTORY) > 0) next = "T2_TRANSITION";
        if (next != state) { state = next; GenericHelpers::LogUtil("[AIR][State] " + state, 1); }
        if (ai.frame - lastLog >= Global::RoleSettings::Air::TelemetrySeconds * SECOND) {
            lastLog = ai.frame;
            GenericHelpers::LogUtil("[AIR][Economy] " + state + (recovery ? " RECOVERY" : "") + " M=" + int(metal) + " bank=" + int(bankM)
                + " E=" + int(energy) + " bank=" + int(bankE) + " pull=" + int(aiEconomyMgr.energy.pull)
                + " plants=" + t1 + "/" + t2 + " aircraftDemand=" + int(demandM) + "/" + int(demandE), 1);
            GenericHelpers::LogUtil("[AIR][Projects] energyQueued=" + aiBuilderMgr.GetQueuedBuildCount(int(Task::BuildType::ENERGY), null)
                + " committed=" + int(AirBuild::Committed(false)) + "/" + int(AirBuild::Committed(true)), 1);
            CCircuitDef@ crew1 = ai.GetCircuitDef(UnitHelpers::GetT1AirConstructorNameForSide(Global::AISettings::Side));
            CCircuitDef@ crew2 = ai.GetCircuitDef(UnitHelpers::GetT2AirConstructorNameForSide(Global::AISettings::Side));
            GenericHelpers::LogUtil("[AIR][Workforce] t1=" + (crew1 is null ? 0 : crew1.count) + "/" + ConstructorTarget(crew1, false)
                + " t2=" + (crew2 is null ? 0 : crew2.count) + "/" + ConstructorTarget(crew2, true)
                + " targetBP=" + int(ConstructionTarget()) + " floating=" + MetalFloating() + " savingLab=" + SavingForFirstLab(), 1);
            GenericHelpers::LogUtil("[AIR][Fusion] target=" + Global::RoleSettings::Air::FirstFusionTargetSeconds
                + "s mexes=" + MexCount() + " upgraded=" + (MexesReady() ? "all" : "pending")
                + " reactor=" + (HasReactor() ? "online" : "pending"), 1);
            for (uint b = 0; b < power.length(); ++b) {
                CCircuitDef@ nd = ai.GetCircuitDef(nanoName);
                GenericHelpers::LogUtil("[AIR][Bay] " + b + " plant=" + AirLayout::bays[b].factoryId + " BP=" + int(power[b])
                    + " nanos=" + nanoCount[b] + "+" + nanoFuture[b] + "/" + NanoTarget(b)
                    + " available=" + (nd !is null && nd.IsAvailable(ai.frame) ? "yes" : "no")
                    + " firstSlot=" + (AirLayout::bays[b].nanos.length() > 0 ? aiTerrainMgr.GetReservationState(AirLayout::bays[b].nanos[0]) : -1), 1);
            }
        }
    }
    bool BankedLab(CCircuitDef@ plant)
    {
        return plant !is null && plant.costM > 0.0f && aiEconomyMgr.metal.current >= plant.costM;
    }
    bool Transition(CCircuitDef@ plant)
    {
        if (MetalEconomy::Active()) return t2 == 0 ? MetalEconomy::AirScreenReady()
            : MetalEconomy::Funded(plant) && MetalMath::Sustainable(metal, energy, 30, 40) >= 15;
        return plant !is null && (BankedLab(plant) || Economy::GetMinEnergyIncomeLast10s() >= Global::RoleSettings::Air::TransitionMinEnergy)
            && ProductionMath::LabIncomeReady(Economy::GetMinMetalIncomeLast10s(),
            Economy::IncomeWindowReady(), Global::RoleSettings::Air::TransitionMinMetal, aiEconomyMgr.metal.current, plant.costM);
    }
    bool SavingForFirstLab()
    {
        if (MetalEconomy::Active()) return false;
        if (AirBuild::FundedLab() !is null) return !recovery;
        CCircuitDef@ lab = ai.GetCircuitDef(UnitHelpers::GetT2AirPlantForSide(Global::AISettings::Side));
        return lab !is null && !Transition(lab) && AirMath::SaveForLab(t2 > 0,
            Planned(lab, Task::BuildType::FACTORY) > 0, recovery,
            aiTerrainMgr.GetLayoutInt("air.screen.established", 0) != 0,
            ai.frame / SECOND, Global::RoleSettings::Air::TransitionEarliestSeconds,
            metal, energy, Global::RoleSettings::Air::FusionAccessMinMetal,
            Global::RoleSettings::Air::FusionAccessMinEnergy, bankM, lab.costM);
    }
    int NanoTarget(uint bay)
    {
        if (bay >= power.length() || recovery) return 0;
        const bool advanced = UnitHelpers::IsT2AircraftPlant(AirLayout::bays[bay].defName);
        CCircuitDef@ plant = ai.GetCircuitDef(AirLayout::bays[bay].defName);
        CCircuitDef@ nano = ai.GetCircuitDef(UnitHelpers::GetT1NanoNameForSide(Global::AISettings::Side));
        if (plant is null || nano is null) return 0;
        float work = 0.0f, cm = 0.0f, ce = 0.0f; Mix(advanced, work, cm, ce);
        const int count = AiMax(1, advanced ? t2 : t1 + t2);
        const float share = Global::RoleSettings::Air::ProductionIncomeShare / float(count);
        float rate = ProductionMath::FundedRate(100.0f, cm, ce, metal * share, energy * share);
        const int limit = advanced ? AiMin(20, AiMax(Global::RoleSettings::Air::T2NanoSoftLimit, Global::RoleSettings::Air::T2ExpansionSupport)) : AiMin(5, Global::RoleSettings::Air::T1NanoLimit);
        // Demand must survive missing/blocked reservations. Otherwise a locally
        // placed starter with no initial pins has target zero and never reaches
        // RepairSupport to allocate its first turret.
        const int cap = limit;
        const int production = ProductionMath::SupportTarget(work, plant.GetBuildSpeed(), nano.GetBuildSpeed(), Global::RoleSettings::Air::WarmFactoryGapSeconds, rate, cap);
        const int expansion = advanced && Transition(plant) ? AiMin(cap, Global::RoleSettings::Air::T2ExpansionSupport) : 0;
        const int opening = !advanced && CompletedConstructors() >= Global::RoleSettings::Air::OpeningAirConstructors
            ? AiMin(cap, OpeningNanoTarget()) : 0;
        return AiMax(opening, AiMax(expansion, production));
    }
    int OpeningNanoTarget() { return AiMax(0, AiMin(5, AiMin(Global::RoleSettings::Air::T1NanoLimit, Global::RoleSettings::Air::OpeningNanoCount))); }
    int OpeningNanoCompleted()
    {
        int count = 0;
        for (uint b = 0; b < AirLayout::bays.length() && b < nanoCount.length(); ++b)
            if (UnitHelpers::IsT1AircraftPlant(AirLayout::bays[b].defName) && AirLayout::bays[b].factoryId >= 0) count += nanoCount[b];
        return count;
    }
    bool OpeningSupportNeeded()
    {
        return t1 > 0 && t2 == 0 && CompletedConstructors() >= Global::RoleSettings::Air::OpeningAirConstructors
            && OpeningNanoCompleted() < OpeningNanoTarget();
    }
    float ConstructionTarget()
    {
        return AirWorkforce::mobile + AirWorkforce::arriving + AirWorkforce::shortage;
    }
    bool MetalFloating() { return ProductionMath::MetalFloating(aiEconomyMgr.metal.current, aiEconomyMgr.metal.storage); }
    int ConstructorTarget(CCircuitDef@ d, bool advanced)
    {
        return AirWorkforce::ConstructorTarget(d, advanced);
    }
    bool FundConstructor(CCircuitDef@ d, float producerPower = 0)
    {
        if (producerPower <= 0) for (uint i = 0; i < power.length(); ++i) producerPower = AiMax(producerPower, power[i]);
        return d !is null && AirWorkforce::Fund(d, producerPower,
            d.GetBuildSpeed() * AirWorkforce::jobMetalPerPower, d.GetBuildSpeed() * AirWorkforce::jobEnergyPerPower);
    }
}
