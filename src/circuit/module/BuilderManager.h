/*
 * BuilderManager.h
 *
 *  Created on: Dec 1, 2014
 *      Author: rlcevg
 */
#ifndef SRC_CIRCUIT_MODULE_BUILDERMANAGER_H_
#define SRC_CIRCUIT_MODULE_BUILDERMANAGER_H_

#include "module/TaskModule.h"
#include "task/builder/BuilderTask.h"
#include "terrain/TerrainData.h"
#include "unit/CircuitUnit.h"
#include "util/DefinitionCounts.h"
#include "spring/ResurrectionClaim.h"

#include <map>
#include <set>
#include <string>
#include <vector>
#include <unordered_set>

namespace springai {
	class AIFloat3;
}

namespace circuit {

class IGridLink;
class CQueryCostMap;
class CBRepairTask;
class CBReclaimTask;
class CCombatTask;
class CCommanderTask;

struct SBuildChain;

namespace TaskB {
	struct SBuildTask {
		IBuilderTask::BuildType type;
		IBuilderTask::Priority priority;
		CCircuitDef* buildDef;
		springai::AIFloat3 position;
		SResource cost;
		union {
			CCircuitDef* reprDef;
			CCircuitUnit* target;
			IGridLink* link;
		} ref;
		union {
			int pointId;
			int spotId;
		} i;
		union {
			float shake;
			float radius;
		} f;
		union {
			bool isPlop;
			bool isMetal;
		} b;
		bool isActive;
		int timeout;
	};

	struct SServBTask {
		IBuilderTask::BuildType type;
		IBuilderTask::Priority priority;
		springai::AIFloat3 position;
		CCircuitUnit* target;
		float powerMod;
		bool isInterrupt;
		int timeout;
	};

	static inline SBuildTask Common(IBuilderTask::BuildType type, IBuilderTask::Priority priority,
			CCircuitDef* buildDef, const springai::AIFloat3& position,
			float shake = SQUARE_SIZE * 32,  // Alter/randomize position by offset
			bool isActive = true,  // Should task go to general queue or remain detached?
			int timeout = ASSIGN_TIMEOUT)
	{
		SBuildTask ti;
		ti.type = type;
		ti.priority = priority;
		ti.buildDef = buildDef;
		ti.position = position;
		ti.f.shake = shake;
		ti.isActive = isActive;
		ti.timeout = timeout;

		ti.cost = {0.f, 0.f};
		ti.ref.reprDef = nullptr;
		ti.i.pointId = -1;
		ti.b.isPlop = false;
		return ti;
	}
	static inline SBuildTask Spot(IBuilderTask::BuildType type, IBuilderTask::Priority priority,
			CCircuitDef* buildDef, const springai::AIFloat3& position, int spotId,
			bool isActive = true, int timeout = ASSIGN_TIMEOUT)
	{
		SBuildTask ti;
		ti.type = type;
		ti.priority = priority;
		ti.buildDef = buildDef;
		ti.position = position;
		ti.i.spotId = spotId;
		ti.isActive = isActive;
		ti.timeout = timeout;
		return ti;
	}
	static inline SBuildTask Factory(IBuilderTask::Priority priority, CCircuitDef* buildDef,
			const springai::AIFloat3& position, CCircuitDef* reprDef,
			float shake = SQUARE_SIZE * 32, bool isPlop = false,
			bool isActive = true, int timeout = ASSIGN_TIMEOUT)
	{
		SBuildTask ti;
		ti.type = IBuilderTask::BuildType::FACTORY;
		ti.priority = priority;
		ti.buildDef = buildDef;
		ti.position = position;
		ti.ref.reprDef = reprDef;
		ti.f.shake = shake;
		ti.b.isPlop = isPlop;
		ti.isActive = isActive;
		ti.timeout = timeout;
		return ti;
	}
	static inline SBuildTask Pylon(IBuilderTask::Priority priority, CCircuitDef* buildDef,
			const springai::AIFloat3& position, IGridLink* link, float cost,
			bool isActive = true, int timeout = ASSIGN_TIMEOUT)
	{
		SBuildTask ti;
		ti.type = IBuilderTask::BuildType::PYLON;
		ti.priority = priority;
		ti.buildDef = buildDef;
		ti.position = position;
		ti.cost = {cost, 0.f};
		ti.ref.link = link;
		ti.isActive = isActive;
		ti.timeout = timeout;
		return ti;
	}
	static inline SBuildTask Repair(IBuilderTask::Priority priority,
			CCircuitUnit* target, int timeout = ASSIGN_TIMEOUT)
	{
		SBuildTask ti;
		ti.type = IBuilderTask::BuildType::REPAIR;
		ti.priority = priority;
		ti.ref.target = target;
		ti.isActive = true;
		ti.timeout = timeout;
		return ti;
	}
	static inline SBuildTask Reclaim(IBuilderTask::Priority priority,
			const springai::AIFloat3& position, float cost,
			int timeout, float radius = .0f, bool isMetal = true)
	{
		SBuildTask ti;
		ti.type = IBuilderTask::BuildType::RECLAIM;
		ti.priority = priority;
		ti.position = position;
		ti.cost = {cost, 0.f};
		ti.ref.target = nullptr;
		ti.f.radius = radius;
		ti.b.isMetal = isMetal;
		ti.isActive = true;
		ti.timeout = timeout;
		return ti;
	}
	static inline SBuildTask Reclaim(IBuilderTask::Priority priority,
			CCircuitUnit* target, int timeout = ASSIGN_TIMEOUT)
	{
		SBuildTask ti;
		ti.type = IBuilderTask::BuildType::RECLAIM;
		ti.priority = priority;
		ti.ref.target = target;
		ti.isActive = true;
		ti.timeout = timeout;
		return ti;
	}
	static inline SBuildTask Resurrect(IBuilderTask::Priority priority,
			const springai::AIFloat3& position, float cost,
			int timeout, float radius = .0f)
	{
		SBuildTask ti;
		ti.type = IBuilderTask::BuildType::RESURRECT;
		ti.priority = priority;
		ti.position = position;
		ti.cost = {cost, 0.f};
		ti.f.radius = radius;
		ti.isActive = true;
		ti.timeout = timeout;
		return ti;
	}
	static inline SBuildTask Terraform(IBuilderTask::Priority priority,
			CCircuitUnit* target, const springai::AIFloat3& position = -RgtVector,
			float cost = 1.0f, bool isActive = true, int timeout = ASSIGN_TIMEOUT)
	{
		SBuildTask ti;
		ti.type = IBuilderTask::BuildType::TERRAFORM;
		ti.priority = priority;
		ti.position = position;
		ti.cost = {cost, 0.f};
		ti.ref.target = target;
		ti.isActive = isActive;
		ti.timeout = timeout;
		return ti;
	}

	static inline SServBTask Patrol(IBuilderTask::Priority priority,
			const springai::AIFloat3& position, int timeout)
	{
		SServBTask ti;
		ti.type = IBuilderTask::BuildType::PATROL;
		ti.priority = priority;
		ti.position = position;
		ti.timeout = timeout;
		return ti;
	}
	static inline SServBTask Guard(IBuilderTask::Priority priority,
			CCircuitUnit* target, bool isInterrupt, int timeout = ASSIGN_TIMEOUT)
	{
		SServBTask ti;
		ti.type = IBuilderTask::BuildType::GUARD;
		ti.priority = priority;
		ti.target = target;
		ti.isInterrupt = isInterrupt;
		ti.timeout = timeout;
		return ti;
	}
	static inline SServBTask Combat(float powerMod)
	{
		SServBTask ti;
		ti.type = IBuilderTask::BuildType::COMBAT;
		ti.powerMod = powerMod;
		return ti;
	}
	static inline SServBTask Wait(int timeout)
	{
		SServBTask ti;
		ti.type = IBuilderTask::BuildType::WAIT;
		ti.timeout = timeout;
		return ti;
	}
} // namespace TaskB

class CBuilderManager final: public ITaskModule {
public:
    void ClearBuildRadii() { buildRadii.clear(); }
    // Optional script-owned placement limits, independent of role names.
    // Empty for legacy callers. Definition lookup is logarithmic in the small
    // configured set; final sites are checked as well as requested anchors.
    void SetBuildRadius(const CCircuitDef* definition, const springai::AIFloat3& center, float radius) {
        if (!definition) return;
        if (radius < 0.f) buildRadii.erase(definition->GetId());
        else buildRadii[definition->GetId()] = {center, radius * radius};
    }
    bool IsBuildPositionAllowed(const CCircuitDef* definition, const springai::AIFloat3& position) const {
        const auto found = buildRadii.find(definition->GetId());
        return found == buildRadii.end() || position.SqDistance2D(found->second.first) <= found->second.second;
    }
    // D-290: script-owned set of definitions our builders never reclaim (TECH:
    // energy storage). Mechanism only; empty unless a script fills it, so other
    // roles and the legacy profiles are unchanged. Indexed by definition id:
    // O(1) test per reclaim enqueue, one bit per definition. Not serialized:
    // the role's InitHandler rebuilds it after load; a role switch clears it.
    void SetReclaimProtected(const CCircuitDef* definition, bool isProtected) {
        if ((definition == nullptr) || (definition->GetId() < 0)) return;
        const auto index = static_cast<std::size_t>(definition->GetId());
        if (index >= reclaimProtected.size()) {
            if (!isProtected) return;
            reclaimProtected.resize(index + 1, false);
        }
        reclaimProtected[index] = isProtected;
    }
    bool IsReclaimProtected(const CCircuitDef* definition) const {
        if ((definition == nullptr) || (definition->GetId() < 0)) return false;
        const auto index = static_cast<std::size_t>(definition->GetId());
        return (index < reclaimProtected.size()) && reclaimProtected[index];
    }
    void ClearReclaimProtected() { reclaimProtected.clear(); }
private:
    std::map<int, std::pair<springai::AIFloat3, float>> buildRadii;
    std::vector<bool> reclaimProtected;  // D-290: by CCircuitDef::Id
public:
	friend class CBuilderScript;

	CBuilderManager(CCircuitAI* circuit);
	virtual ~CBuilderManager();

	void InitHandlers();
private:
	void ReadConfig();
	void Init();

public:
	virtual int UnitCreated(CCircuitUnit* unit, CCircuitUnit* builder) override;
	virtual int UnitFinished(CCircuitUnit* unit) override;
	virtual int UnitIdle(CCircuitUnit* unit) override;
	virtual int UnitDamaged(CCircuitUnit* unit, CEnemyInfo* attacker) override;
	virtual int UnitDestroyed(CCircuitUnit* unit, CEnemyInfo* attacker) override;
	virtual int UnitCaptured(CCircuitUnit* unit, int oldTeamId, int newTeamId) override;  // D-108 crash

	CCircuitDef* GetTerraDef() const { return terraDef; }

	float GetGoalExecTime() const { return goalExecTime; }
	unsigned int GetWorkerCount() const { return workers.size(); }
    CCommanderTask* EnqueueCommander(IUnitTask* previous);
    bool SetCommanderCombatOption(const std::string& name,float value);
    float GetCommanderEnergyReserve() const;
    float GetCommanderEnergyDeficit() const;
    int GetCommanderOperation() const;
    IUnitTask* CommanderFrontWork(CCircuitUnit* unit,int kind,CCircuitDef* def,float radius);
	void AddBuildPower(CCircuitUnit* unit);
	void DelBuildPower(CCircuitUnit* unit);
	float GetBuildPower() const { return buildPower; }
	float GetBuildPowerNear(const springai::AIFloat3& position, float radius) const;
	// Only the immobile assist power (construction turrets) within radius, in
	// workertime units: the planner's turret target ignores the commander and
	// constructors passing through (D-066 follow-up).
	float GetStaticBuildPowerNear(const springai::AIFloat3& position, float radius) const;
	// Experimental build mode (D-064, doc/experimental-build.md): a builder
	// stops at the engine's own build range (reach + buildee radius, x0.9),
	// gets one construction command with no command timeout, and inside
	// experimentalDirectRange the engine walks the last leg itself. Off by
	// default; a role's script turns it on for its own AI instance only.
	const std::set<CCircuitUnit*>& GetWorkers() const { return workers; }
	bool IsExperimentalBuild() const { return experimentalBuild; }
	bool IsConstructionRecoveryEnabled() const { return recoverConstruction; }
	static bool IsLayoutEconomy(IBuilderTask::BuildType type) {
		return type == IBuilderTask::BuildType::ENERGY || type == IBuilderTask::BuildType::CONVERT
			|| type == IBuilderTask::BuildType::STORE || type == IBuilderTask::BuildType::NANO;
	}
	bool SuppressEconomyChain(IBuilderTask::BuildType type) const {
		return recoverConstruction && experimentalBuild && IsLayoutEconomy(type);
	}
	bool IsExperimentalAirDirect() const { return experimentalAirDirect; }
	float GetExperimentalDirectRange() const { return experimentalDirectRange; }
	float GetExperimentalSearchRadius() const { return experimentalSearchRadius; }
	// D-066: the nearest live, untaken order of `type` in native's queue that
	// this builder may take (defence, sensors, the watchdog's repairs). The
	// script pulls them when its sequence says so; nothing else assigns them
	// in the experimental system.
	IUnitTask* FindQueuedTask(CCircuitUnit* builder, IBuilderTask::BuildType type);
	// mode 0: metal features, 1: completed naval repair (optional def filter),
	// 2: naval wreck resurrection. Script orders the independent queries.
	IBuilderTask* FindRecoveryTask(CCircuitUnit* unit, int mode, float radius, const CCircuitDef* preferred, int groupLimit = 1, bool highestValue = false, float combatClearance = 0.f);
    float GetRecoveryMetal(CCircuitUnit* worker, float radius);
    bool ReceiveResurrectionClaim(const char* message);
private:
    struct SRelayedResurrection { ResurrectionClaim claim; int team; int expires; };
    std::map<int, SRelayedResurrection> relayedResurrections;
    void RefreshRecoveryFeatures();
	struct SRecoveryFeature { int id; springai::AIFloat3 pos; float metal; bool resurrect; float vesselMetal; };
	std::vector<SRecoveryFeature> recoveryFeatures;
	int recoveryFrame = -100000;
public:
	// Turret assist (D-065): the own unit being reclaimed that this builder
	// can reach without moving (nearest), and the unfinished structure of
	// `def` it can reach (nearest); null when none.
	CCircuitUnit* FindReclaimTargetFor(CCircuitUnit* builder);
	CCircuitUnit* FindUnfinishedFor(CCircuitUnit* builder, const CCircuitDef* def);
	// Structures of `def` under construction (ours), and the nearest one to a
	// point within radius; for the planner's turret focus (D-063 follow-up 5).
	int GetUnfinishedCount(const CCircuitDef* def) const;
	CCircuitUnit* FindUnfinishedNear(const springai::AIFloat3& pos, float radius, const CCircuitDef* def);
	// D-119: a mobile unit of ours still being built near pos: what a factory there is producing
	CCircuitUnit* FindProducedNear(const springai::AIFloat3& pos, float radius);
	// D-098: structures of ours under construction within radius costing at least minCostM, `except` not counted
	int CountUnfinishedNear(const springai::AIFloat3& pos, float radius, float minCostM, const CCircuitDef* except);
	// D-105: the build power (workertime) within radius, the two defs and one unit not counted
	float GetBuildPowerNearExcept(const springai::AIFloat3& pos, float radius, const CCircuitDef* ex1, const CCircuitDef* ex2, const CCircuitUnit* exUnit) const;
	// D-077: the nearest finished unit of ours of def within radius of pos (null def: any).
	CCircuitUnit* FindOwnNear(const springai::AIFloat3& pos, float radius, const CCircuitDef* def);
	// D-078 (owner's rule): every construction turret within its build distance
	// (+ margin) of the unit targetId that is not already reclaiming it. With
	// apply, each is taken off its task and put on one shared reclaim of the
	// target now. Returns how many were off it (before applying); -1 if the
	// target is gone.
	int TurretsOnReclaim(int targetId, float margin, bool apply, bool preserveReclaimPriority = false);
	int GetQueuedBuildCount(IBuilderTask::BuildType type, const CCircuitDef* buildDef) const;
	bool CanEnqueueTask(const unsigned mod = 8) const { return buildTasksCount < workers.size() * mod; }
	const std::set<IBuilderTask*>& GetTasks(IBuilderTask::BuildType type) const;
	void ActivateTask(IBuilderTask* task);

	IBuilderTask* Enqueue(const TaskB::SBuildTask& ti);
	IBuilderTask* EnqueueLayout(const TaskB::SBuildTask& ti, const std::string& groupName, CCircuitUnit* builder);
	IBuilderTask* EnqueueFactoryNano(const TaskB::SBuildTask& ti, CCircuitUnit* builder);
	IUnitTask* Enqueue(const TaskB::SServBTask& ti);
	IUnitTask* FindMatchingGuard(CCircuitUnit* unit, const TaskB::SServBTask& ti);
	virtual CRetreatTask* EnqueueRetreat() override;
	inline IBuilderTask* EnqueueB(const TaskB::SServBTask& ti) {
		assert((ti.type == IBuilderTask::BuildType::PATROL) || (ti.type == IBuilderTask::BuildType::GUARD));
		return static_cast<IBuilderTask*>(Enqueue(ti));
	}

	virtual void AssignTask(CCircuitUnit* unit, IUnitTask* task) override;
	virtual void AssignTask(CCircuitUnit* unit) override;
private:
	virtual void DequeueTask(IUnitTask* task, bool done = false) override;

public:
	virtual void FallbackTask(CCircuitUnit* unit) override;

    void MarkUnfinishedUnit(CAllyUnit* target, IBuilderTask* task);
    // Called at unregister, before any later script can observe a dead unit.
    void ForgetUnfinishedCount(CAllyUnit* target) { unfinishedCounts.Erase(target); }
	void MarkRepairUnit(ICoreUnit::Id targetId, CBRepairTask* task) {
		repairUnits[targetId] = task;
	}
	// Reclaim bookkeeping is mirrored into CAllyTeam so every AI on the team
	// stops repairing the unit; see CAllyTeam::MarkReclaim.
	void MarkReclaimUnit(CAllyUnit* target, CBReclaimTask* task);

	bool IsBuilderInArea(CCircuitDef* buildDef, const springai::AIFloat3& position) const;  // Check if build-area has proper builder
	bool HasFreeAssists(CCircuitUnit* builder) const;
	SBuildChain* GetBuildChain(IBuilderTask::BuildType buildType, CCircuitDef* cdef) const;

	IBuilderTask* GetRepairTask(ICoreUnit::Id unitId) const;
	// D-299: the repair task for target (own or allied), reused if one exists.
	IBuilderTask* EnqueueRepairFor(CAllyUnit* target, int timeout, CCircuitUnit* commander = nullptr);
	IBuilderTask* GetReclaimFeatureTask(const springai::AIFloat3& pos, float radius) const;
	IBuilderTask* GetResurrectTask(const springai::AIFloat3& pos, float radius) const;
	void RegisterReclaim(CAllyUnit* unit);
	void UnregisterReclaim(CAllyUnit* unit);
	// True when this AI or ANY teammate is reclaiming the unit.
	bool IsReclaimUnit(CAllyUnit* unit) const;
	bool IsReclaimFeature(const springai::AIFloat3& pos, float radius) const {
		return GetReclaimFeatureTask(pos, radius) != nullptr;
	}
	bool IsResurrect(const springai::AIFloat3& pos, float radius) const {
		return GetResurrectTask(pos, radius) != nullptr;
	}

	void SetCanUpMex(CCircuitDef* cdef, bool value);
	bool CanUpMex(CCircuitDef* cdef) const;
	void SetCanUpGeo(CCircuitDef* cdef, bool value);
	bool CanUpGeo(CCircuitDef* cdef) const;

	void IncGuardCount() { ++guardCount; }
	void DecGuardCount() { --guardCount; }

	/*
	 * Unused default tasks. Every role's builder policy calls DefaultMakeTask
	 * before its own ladder so that a native mex/geo task can win, and then
	 * usually returns something else. DefaultMakeTask ENQUEUES what it
	 * returns - an energy structure, a nano, a Wait - so the abandoned task
	 * stayed in buildTasks for ASSIGN_TIMEOUT and the next idle builder took
	 * it: with three constructors that was a native solar, a script solar and
	 * a script advanced solar under construction at once. MakeTask now
	 * remembers the tasks DefaultMakeTask created for THIS call and aborts the
	 * ones the caller did not take. Tasks DefaultMakeTask merely found in the
	 * queue, and the mex tasks MakeEconomyTasks leaves for pickup on purpose,
	 * are untouched.
	 */
	virtual IUnitTask* MakeTask(CCircuitUnit* unit) override;
	virtual void DiscardUnusedTask(IUnitTask* task) override;
	void AbortLayoutTasks();

private:
	virtual IUnitTask* DefaultMakeTask(CCircuitUnit* unit) override;
	IUnitTask* DefaultMakeTaskImpl(CCircuitUnit* unit);
	IUnitTask* lastEnqueued = nullptr;        // most recent task any Enqueue created
	std::vector<IUnitTask*> freshDefaults;    // created by DefaultMakeTask during the current MakeTask
	IUnitTask* freshMade = nullptr;           // MakeTask's return value, if it was one of freshDefaults
	int discardCount = 0;
	int discardLogFrame = 0;
	IBuilderTask* MakeEnergizerTask(CCircuitUnit* unit, const CQueryCostMap* query);
	IBuilderTask* MakeCommTask(CCircuitUnit* unit, const CQueryCostMap* query, float sqMaxBaseRange);
	IBuilderTask* MakeBuilderTask(CCircuitUnit* unit, const CQueryCostMap* query);
	IBuilderTask* CreateBuilderTask(const springai::AIFloat3& position, CCircuitUnit* unit);

	void AddBuildList(CCircuitUnit* unit, int hiddenDefs);
	void RemoveBuildList(CCircuitUnit* unit, int hiddenDefs);

	void Watchdog();

	Handlers2 createdHandler;
	Handlers1 finishedHandler;
	Handlers1 idleHandler;
	EHandlers damagedHandler;
	EHandlers destroyedHandler;

	std::map<CAllyUnit*, IBuilderTask*> unfinishedUnits;
    DefinitionCounts<CAllyUnit*> unfinishedCounts;
    void EraseUnfinishedUnit(CAllyUnit* target);
	std::map<ICoreUnit::Id, CBRepairTask*> repairUnits;
	std::map<CAllyUnit*, CBReclaimTask*> reclaimUnits;
	std::map<CAllyUnit*, ICoreUnit::Id> reclaimIds;  // the id behind each key: UnregisterReclaim may get a freed pointer (CR-001)
	std::vector<std::set<IBuilderTask*>> buildTasks;  // UnitDef based tasks
	unsigned int assistCount;  // builders that can assist
	unsigned int guardCount;  // assist guards
	unsigned int buildTasksCount;
	float buildPower;

	float goalExecTime = 0.f;  // seconds
	std::set<CCircuitUnit*> workers;
	std::map<CCircuitUnit*, std::shared_ptr<IPathQuery>> costQueries;  // IPathQuery owner
	std::map<CCircuitUnit*, int> dangerTime;  // unit: frame
	int dangerHysteresis;  // frames
	bool experimentalBuild = false;          // script property (D-064, D-066: the whole experimental build system)
	bool recoverConstruction = false;        // opt-in TECH/SEA; independent of placement mode
	int constructionRetrySeconds = 10;
	int constructionReleaseSeconds = 30;
	int nextLegacyWatchdog = 0;
	bool experimentalAirDirect = false;     // opt-in: engine controls flying constructors' last approach
	float experimentalDirectRange = 1600.f;  // elmos
	float experimentalSearchRadius = 512.f;  // elmos: how far from the asked anchor a site may be packed (D-066)

	CCircuitDef* terraDef = nullptr;
	std::unordered_map<IBuilderTask::BT, std::unordered_map<CCircuitDef*, SBuildChain*>> buildChains;  // owner
	struct SSuper {
		float minIncome;  // metal per second
		float maxTime;  // seconds
	} super;

	struct SWorkExt {
		bool canUpMex : 1;
		bool canUpGeo : 1;
	};
	std::unordered_map<CCircuitDef*, SWorkExt> workerDefs;

public:
	void UpdateAreaUsers();
private:
	std::unordered_set<terrain::SMobileType::Id> workerMobileTypes;
	std::map<terrain::SArea*, std::map<CCircuitDef*, int>> buildAreas;  // area <=> worker types

	virtual void Load(std::istream& is) override;
	virtual void Save(std::ostream& os) const override;

#ifdef DEBUG_VIS
public:
	void Log();
#endif
};

} // namespace circuit

#endif // SRC_CIRCUIT_MODULE_BUILDERMANAGER_H_
