#include "../../helpers/math/build_power_math.as"
#include "../team/team_economy.as"

// AIR owns the observation and admissions; arithmetic has no role dependency.
namespace AirWorkforce {
    int interval = -1, fullSamples = 0, logFrame = -100000;
    array<float> banks;
    array<float> metalRates, energyRates;
    bool pressure = false;
    float incomeM = 0, incomeE = 0, usageM = 0, usageE = 0;
    float received = 0, sent = 0, excess = 0;
    float committedM = 0, committedE = 0, admittedM = 0, admittedE = 0;
    float admittedUsageM = 0, admittedUsageE = 0, fundedUsageM = 0, fundedUsageE = 0;
    float mobile = 0, arriving = 0, idle = 0, shortage = 0, economicStatic = 0;
    float constructionPower = 0, workingPower = 0;
    float jobMetalPerPower = 0, jobEnergyPerPower = 0;
    int pendingSupport = 0;
    dictionary assigned, workerTarget, workerPower, previousProgress, futureEconomic;
    dictionary projectProgress, stalledSeconds, deliveredPower;
    string reason = "not sampled";
    int fundedFrame = -1;
    string fundedName;

    void Reset() {
        interval = -1; fullSamples = 0; logFrame = -100000; banks.resize(0); pressure = false;
        metalRates.resize(0); energyRates.resize(0);
        assigned.deleteAll(); workerTarget.deleteAll(); workerPower.deleteAll(); previousProgress.deleteAll(); futureEconomic.deleteAll();
        projectProgress.deleteAll(); stalledSeconds.deleteAll(); deliveredPower.deleteAll();
        admittedM = 0; admittedE = 0; committedM = 0; committedE = 0;
        admittedUsageM = 0; admittedUsageE = 0;
        mobile = 0; arriving = 0; idle = 0; shortage = 0; economicStatic = 0;
        fundedFrame = -1; fundedName = "";
    }
    float Horizon() { return AiMax(1.0f, Global::RoleSettings::Air::WorkforceHorizonSeconds); }
    float ReserveM() {
        // Save a concrete first-lab bank, while allowing an investment above it.
        CCircuitDef@ lab = ai.GetCircuitDef(UnitHelpers::GetT2AirPlantForSide(Global::AISettings::Side));
        return AiMax(Global::RoleSettings::Air::WorkforceReserveMetal + AirBuild::LabReserve(false),
            lab !is null && AirEconomy::SavingForFirstLab() ? AiMin(lab.costM, AirEconomy::bankM) : 0.0f);
    }
    float ReserveE() { return Global::RoleSettings::Air::WorkforceReserveEnergy + AirBuild::LabReserve(true); }
    float Room(bool energy) {
        return BuildPowerMath::Room(energy ? TeamEconomy::OwnEnergy(TeamEconomy::CURRENT) : TeamEconomy::OwnMetal(TeamEconomy::CURRENT),
            energy ? ReserveE() : ReserveM(), energy ? incomeE : incomeM,
            energy ? usageE + admittedUsageE : usageM + admittedUsageM,
            energy ? committedE + admittedE : committedM + admittedM, Horizon());
    }
    bool Investment(const CCircuitDef@ d) {
        return d !is null && (UnitHelpers::IsAirConstructor(d)
            || d.GetName() == UnitHelpers::GetT1NanoNameForSide(UnitHelpers::GetSideForUnitName(d.GetName())));
    }
    bool IdleWorker(CCircuitUnit@ worker) {
        if (worker is null) return false;
        IUnitTask@ task = worker.task;
        if (task is null) return true;
        IBuilderTask@ job = cast<IBuilderTask>(task);
        if (job !is null) return job.IsDead() || job.GetBuildType() == int(Task::BuildType::WAIT);
        // PLAYER and RETREAT are unavailable even though neither casts to a
        // builder job. Observation must not release or steal their ownership.
        const int kind = task.GetType();
        return kind == int(Task::Type::NIL) || kind == int(Task::Type::IDLE) || kind == int(Task::Type::WAIT);
    }
    void AddPower(const string &in key, float amount) {
        float prior = 0; assigned.get(key, prior);
        if (prior + amount < -.1f) Invariants::Violation("INV-126", key, "AIR removed more assigned power than its ownership ledger contains");
        assigned.set(key, AiMax(0.0f, prior + amount));
    }
    void FutureSupport(const AIFloat3 &in pos, float power) {
        const int reactor = AirEcoLayout::ReactorAt(pos);
        if (reactor < 0) return;
        const string key = "" + reactor;
        float existing = 0; futureEconomic.get(key, existing); futureEconomic.set(key, existing + power);
    }
    void Assign(CCircuitUnit@ worker, IUnitTask@ task) {
        if (worker is null) return;
        const string key = "" + worker.id;
        int old = -1; float power = 0;
        workerTarget.get(key, old); workerPower.get(key, power);
        if (old >= 0) AddPower("" + old, -power);
        IBuilderTask@ build = cast<IBuilderTask>(task);
        const int target = build !is null && build.target !is null ? build.target.id : -1;
        power = worker.circuitDef.GetBuildSpeed();
        workerTarget.set(key, target); workerPower.set(key, power);
        if (target >= 0) AddPower("" + target, power);
    }
    float Assigned(CCircuitUnit@ target, CCircuitUnit@ except = null) {
        if (target is null) return 0;
        float value = 0; assigned.get("" + target.id, value);
        int owner = -1;
        if (except !is null && workerTarget.get("" + except.id, owner) && owner == target.id)
            value -= except.circuitDef.GetBuildSpeed();
        return AiMax(0.0f, value);
    }
    bool Useful(CCircuitUnit@ target, CCircuitUnit@ worker) {
        if (target is null || worker is null) return false;
        const CCircuitDef@ d = target.circuitDef;
        const float already = Assigned(target, worker);
        const float remaining = d.GetBuildTime() * AiMax(0.0f, 1.0f - target.GetBuildProgress());
        const float baseline = remaining / (AirBuild::IsReactor(d)
            ? Global::RoleSettings::Air::ReactorProjectSeconds : Global::RoleSettings::Air::SmallProjectSeconds);
        const float extra = BuildPowerMath::Power(Room(false), Room(true), d.GetBuildTime(), d.costM, d.costE);
        float working = 0; deliveredPower.get("" + target.id, working);
        // Funding may shorten the horizon, but don't send a worker to a job
        // already about to finish. Arriving assignments still count once.
        return already < AiMin(remaining / Global::RoleSettings::Air::WorkforceMinJobSeconds,
            AiMax(baseline, working + extra));
    }
    void Tick() {
        // Engine resource buckets are reset each SECOND, not each callback.
        const int now = ai.frame / SECOND;
        if (now == interval) return;
        const bool continuous = interval >= 0 && now == interval + 1;
        const float elapsed = interval >= 0 ? float(AiMax(1, now - interval)) : 1.0f;
        interval = now; admittedM = 0; admittedE = 0; admittedUsageM = 0; admittedUsageE = 0;
        incomeM = AiMax(0.0f, TeamEconomy::OwnMetal(TeamEconomy::INCOME));
        incomeE = AiMax(0.0f, TeamEconomy::OwnEnergy(TeamEconomy::INCOME));
        usageM = AiMax(0.0f, TeamEconomy::OwnMetal(TeamEconomy::USAGE));
        usageE = AiMax(0.0f, TeamEconomy::OwnEnergy(TeamEconomy::USAGE));
        received = AiMax(0.0f, TeamEconomy::OwnMetal(TeamEconomy::RECEIVED));
        sent = AiMax(0.0f, TeamEconomy::OwnMetal(TeamEconomy::SENT));
        excess = AiMax(0.0f, TeamEconomy::OwnMetal(TeamEconomy::EXCESS));
        // Do not forecast future gifts. The current bank admits donated capital;
        // receipt-inclusive native averages are never added to own production.
        const float bank = TeamEconomy::OwnMetal(TeamEconomy::CURRENT);
        const float storage = TeamEconomy::OwnMetal(TeamEconomy::STORAGE);
        if (!continuous) { banks.resize(0); metalRates.resize(0); energyRates.resize(0); fullSamples = 0; }
        metalRates.insertLast(incomeM); energyRates.insertLast(incomeE);
        if (metalRates.length() > 10) { metalRates.removeAt(0); energyRates.removeAt(0); }
        for (uint i = 0; i < metalRates.length(); ++i) {
            incomeM = AiMin(incomeM, metalRates[i]); incomeE = AiMin(incomeE, energyRates[i]);
        }
        if (bank >= storage * Global::RoleSettings::Air::WorkforceHighFill && storage > 0) ++fullSamples;
        else fullSamples = 0;
        banks.insertLast(bank);
        const int window = AiMax(2, Global::RoleSettings::Air::WorkforcePressureSeconds);
        if (banks.length() > uint(window)) banks.removeAt(0);
        pressure = BuildPowerMath::Pressure(bank, storage, banks[0], int(banks.length()), window,
            fullSamples, Global::RoleSettings::Air::WorkforceHighFill, Global::RoleSettings::Air::WorkforceRiseMetal)
            || BuildPowerMath::Refilling(banks, storage, Global::RoleSettings::Air::WorkforceRefillLow,
                Global::RoleSettings::Air::WorkforceHighFill)
            || (pressure && bank >= storage * Global::RoleSettings::Air::WorkforceLowFill);
        assigned.deleteAll(); workerTarget.deleteAll(); workerPower.deleteAll();
        futureEconomic.deleteAll();
        mobile = 0; arriving = 0; idle = 0; economicStatic = 0; pendingSupport = 0;
        constructionPower = 0; workingPower = 0; committedM = 0; committedE = 0;
        float investmentUsageM = 0, investmentUsageE = 0;
        dictionary progress;
        for (uint i = 0; i < AirEconomy::owned.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(AirEconomy::owned[i]);
            if (u is null) continue;
            const CCircuitDef@ d = u.circuitDef;
            // Most late-game AIR units are combat aircraft. They contribute no
            // workforce capacity; avoid progress, lifecycle and name queries.
            if (d.GetBuildSpeed() <= 0.0f || Lifecycle::IsRetiring(u)) continue;
            const float fraction = u.GetBuildProgress();
            const bool investment = Investment(d);
            if (investment) {
                const string key = "" + u.id;
                float prior = fraction;
                if (previousProgress.get(key, prior)) {
                    const float paid = AiMax(0.0f, fraction - prior) / elapsed;
                    investmentUsageM += paid * d.costM; investmentUsageE += paid * d.costE;
                }
                if (fraction < 1.0f) {
                    progress.set(key, fraction);
                    committedM += (1.0f - fraction) * d.costM;
                    committedE += (1.0f - fraction) * d.costE;
                    if (UnitHelpers::IsAirConstructor(d)) arriving += d.GetBuildSpeed();
                    else { ++pendingSupport; FutureSupport(u.GetPos(ai.frame), d.GetBuildSpeed()); }
                }
            }
            if (fraction < 1.0f || d.GetBuildSpeed() <= 0.0f) continue;
            Assign(u, u.task);
            if (UnitHelpers::IsAirConstructor(d)) {
                mobile += d.GetBuildSpeed(); constructionPower += d.GetBuildSpeed();
                if (IdleWorker(u)) idle += d.GetBuildSpeed();
            } else if (investment && AirEcoLayout::Owns(u.GetPos(ai.frame))) {
                economicStatic += d.GetBuildSpeed(); constructionPower += d.GetBuildSpeed();
            } else if (UnitHelpers::IsCommander(d)) constructionPower += d.GetBuildSpeed();
        }
        previousProgress = progress;
        // Reserve outstanding investments as capital. Their observed spending
        // is removed from the usage forecast, avoiding a second debit.
        usageM = AiMax(0.0f, usageM - investmentUsageM);
        usageE = AiMax(0.0f, usageE - investmentUsageE);
        const array<string> sides = {"armada", "cortex", "legion"};
        for (uint s = 0; s < sides.length(); ++s) for (int tier = 1; tier <= 2; ++tier) {
            CCircuitDef@ d = ai.GetCircuitDef(tier == 1 ? UnitHelpers::GetT1AirConstructorNameForSide(sides[s])
                : UnitHelpers::GetT2AirConstructorNameForSide(sides[s]));
            if (d is null) continue;
            const int queued = aiFactoryMgr.GetPendingRecruitCount(d);
            arriving += float(queued) * d.GetBuildSpeed();
            committedM += float(queued) * d.costM; committedE += float(queued) * d.costE;
        }
        dictionary seen;
        dictionary nextProgress, nextStall;
        deliveredPower.deleteAll();
        float needed = 0;
        jobMetalPerPower = 0; jobEnergyPerPower = 0;
        for (uint i = 0; i < AirBuild::projects.length(); ++i) {
            IBuilderTask@ task = cast<IBuilderTask>(AirBuild::projects[i]);
            if (task is null || task.IsDead() || task.buildDef is null) continue;
            if (task.target is null && task.GetBuildType() == int(Task::BuildType::NANO)) {
                ++pendingSupport; committedM += task.buildDef.costM; committedE += task.buildDef.costE;
                FutureSupport(task.GetBuildPos(), task.buildDef.GetBuildSpeed());
            }
            if (task.target is null || !AirHome::EconomySite(task.target.GetPos(ai.frame))) continue;
            const string key = "" + task.target.id;
            if (seen.exists(key) || task.target.GetBuildProgress() >= 1.0f) continue;
            seen.set(key, true);
            const CCircuitDef@ d = task.target.circuitDef;
            if (UnitHelpers::IsT1AircraftPlant(d.GetName()) || UnitHelpers::IsT2AircraftPlant(d.GetName())) continue;
            const float allocated = Assigned(task.target);
            const float fraction = task.target.GetBuildProgress();
            float prior = fraction, stalled = 0;
            const bool observed = continuous && projectProgress.get(key, prior);
            const float delta = observed ? AiMax(0.0f, fraction - prior) : 0;
            if (observed && allocated > 0 && delta < .000001f) {
                stalledSeconds.get(key, stalled); stalled += elapsed;
            }
            nextProgress.set(key, fraction); nextStall.set(key, stalled);
            const float working = delta * d.GetBuildTime() / elapsed;
            workingPower += working;
            deliveredPower.set(key, working);
            // Existing assignees with no progress need recovery, not more
            // aircraft. Keep assistance eligible; guard recovery has its owner.
            if (stalled >= Global::RoleSettings::Air::WorkforceStallSeconds) continue;
            const float extra = BuildPowerMath::Power(Room(false), Room(true), d.GetBuildTime(), d.costM, d.costE);
            const float remaining = d.GetBuildTime() * (1.0f - task.target.GetBuildProgress());
            float future = 0; futureEconomic.get(key, future);
            const float missing = BuildPowerMath::ProjectShortage(working, extra, remaining,
                Global::RoleSettings::Air::WorkforceMinJobSeconds, allocated, future);
            if (missing > needed && d.GetBuildTime() > 0) {
                needed = missing;
                jobMetalPerPower = d.costM / d.GetBuildTime(); jobEnergyPerPower = d.costE / d.GetBuildTime();
            }
        }
        projectProgress = nextProgress; stalledSeconds = nextStall;
        shortage = BuildPowerMath::Shortage(needed, idle, arriving);
        reason = needed <= 0 ? "no funded workload" : shortage <= 0 ? "available or arriving power" : "funded workload";
        if (ai.frame - logFrame >= Global::RoleSettings::Air::TelemetrySeconds * SECOND) {
            logFrame = ai.frame;
            GenericHelpers::LogUtil("[AIR][Capacity] own=" + int(incomeM) + "/" + int(incomeE)
                + " usage=" + int(usageM) + "/" + int(usageE) + " gifts=" + int(received) + " sent=" + int(sent)
                + " excess=" + int(excess) + " pressure=" + pressure + " mobile=" + int(mobile)
                + " arriving=" + int(arriving) + " idle=" + int(idle) + " ecoStatic=" + int(economicStatic)
                + " working=" + int(workingPower) + " shortage=" + int(shortage) + " reason=" + reason, 1);
        }
    }
    bool Fund(CCircuitDef@ d, float power, float extraM = 0, float extraE = 0) {
        fundedFrame = -1; fundedName = "";
        if (d is null || power <= 0.0f) return false;
        const float seconds = AiMax(1.0f, d.GetBuildTime() / power);
        const bool ready = BuildPowerMath::Funded(TeamEconomy::OwnMetal(TeamEconomy::CURRENT), ReserveM(), incomeM, usageM + admittedUsageM,
            committedM + admittedM, d.costM, seconds, extraM, Horizon())
            && BuildPowerMath::Funded(TeamEconomy::OwnEnergy(TeamEconomy::CURRENT), ReserveE(), incomeE, usageE + admittedUsageE,
            committedE + admittedE, d.costE, seconds, extraE, Horizon());
        if (ready) { fundedFrame = ai.frame; fundedName = d.GetName(); fundedUsageM = extraM; fundedUsageE = extraE; }
        return ready;
    }
    void Admit(CCircuitDef@ d, bool requireFunding = false, bool economicSupport = false) {
        if (d is null) return;
        if (requireFunding && (fundedFrame != ai.frame || fundedName != d.GetName()))
            Invariants::Violation("INV-124", d.GetName(), "AIR workforce expansion admitted without a current two-resource budget");
        if (fundedFrame == ai.frame && fundedName == d.GetName()) {
            admittedUsageM += fundedUsageM; admittedUsageE += fundedUsageE;
        }
        fundedFrame = -1; fundedName = "";
        admittedM += d.costM; admittedE += d.costE;
        if (UnitHelpers::IsAirConstructor(d)) { arriving += d.GetBuildSpeed(); shortage = AiMax(0.0f, shortage - d.GetBuildSpeed()); }
        else {
            ++pendingSupport;
            if (economicSupport) shortage = AiMax(0.0f, shortage - d.GetBuildSpeed());
        }
    }
    int ConstructorTarget(CCircuitDef@ d, bool advanced) {
        if (d is null) return 0;
        const int present = AirProduction::Projected(d);
        const int floor = advanced ? 2 : Global::RoleSettings::Air::OpeningAirConstructors;
        const int ordinary = advanced ? Global::RoleSettings::Air::MaxT2EconomyBuilders : Global::RoleSettings::Air::MaxT1EconomyBuilders;
        const int cap = pressure ? AiMax(ordinary, Global::RoleSettings::Air::WorkforceSafetyConstructors) : ordinary;
        if (present < floor) return floor;
        if (shortage < d.GetBuildSpeed() * .25f || present >= cap) return present;
        return present + 1; // reassess after each completed/funded investment
    }
}
