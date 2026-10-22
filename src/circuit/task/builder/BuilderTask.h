/*
 * BuilderTask.h
 *
 *  Created on: Sep 11, 2014
 *      Author: rlcevg
 */

#ifndef SRC_CIRCUIT_TASK_BUILDER_BUILDERTASK_H_
#define SRC_CIRCUIT_TASK_BUILDER_BUILDERTASK_H_

#include "task/UnitTask.h"
#include "task/builder/ConstructionRecovery.h"
#include "util/Defines.h"
#include "util/math/Geometry.h"

#include <map>
#include <vector>

namespace circuit {

class CCircuitDef;
class CAllyUnit;
class CTerrainManager;

struct SBuildChain;

struct SResource {
	float metal;
	float energy;
};

class IBuilderTask: public IUnitTask {
public:
	friend class CInitScript;

	enum class BuildType: char {
		FACTORY = 0,
		NANO,
		STORE,
		PYLON,
		ENERGY,
		GEO,
		GEOUP,
		DEFENCE,  // lotus, defender, stardust, stinger
		BUNKER,  // ddm, anni
		BIG_GUN,  // super weapons
		RADAR,
		SONAR,
		CONVERT,
		MEX,
		MEXUP,
		REPAIR,
		RECLAIM,
		RESURRECT,
		RECRUIT,
		TERRAFORM,
		_SIZE_,  // selectable tasks count
		PATROL, GUARD, COMBAT, WAIT,  // builder actions that can't be reassigned
		DEFAULT = BIG_GUN
	};
	using BT = std::underlying_type<BuildType>::type;

	using BuildName = std::map<std::string, BuildType>;
	static BuildName& GetBuildNames() { return buildNames; }
private:
	static BuildName buildNames;

protected:
	IBuilderTask(ITaskModule* mgr, Priority priority,
				 CCircuitDef* buildDef, const springai::AIFloat3& position,
				 Type type, BuildType buildType, SResource cost, float shake = SQUARE_SIZE * 32, int timeout = ASSIGN_TIMEOUT);
	IBuilderTask(ITaskModule* mgr, Type type, BuildType buildType);  // Load
public:
	virtual ~IBuilderTask();

	virtual bool CanAssignTo(CCircuitUnit* unit) const override;
	virtual void AssignTo(CCircuitUnit* unit) override;
	virtual void RemoveAssignee(CCircuitUnit* unit) override;
	// D-112 crash: a unit about to be freed leaves every set of this task (the
	// update loop iterates `traveled`), without RemoveAssignee's reassignment
	virtual bool ForgetUnit(CCircuitUnit* unit) override {
		if ((unitIt != units.end()) && (*unitIt == unit)) {
			++unitIt;
		}
		if (initiator == unit) {
			initiator = nullptr;
		}
		traveled.erase(unit);
		executors.erase(unit);
		engaged.erase(unit);
		approaching.erase(unit);
		constructionHealth.erase(unit);
		return IUnitTask::ForgetUnit(unit);
	}

	virtual void Start(CCircuitUnit* unit) override;
	virtual void Update() override;
	virtual void Stop(bool done) override;
protected:
	virtual void Finish() override;
	virtual void Cancel() override;

	virtual bool Execute(CCircuitUnit* unit);

public:
	virtual void OnUnitIdle(CCircuitUnit* unit) override;
	virtual void OnUnitDamaged(CCircuitUnit* unit, CEnemyInfo* attacker) override;
	virtual void OnUnitDestroyed(CCircuitUnit* unit, CEnemyInfo* attacker) override;

	virtual void OnTravelEnd(CCircuitUnit* unit) override;

	virtual void Activate();
	void Deactivate();

	const springai::AIFloat3& GetTaskPos() const { return position; }
	CCircuitDef* GetBuildDef() const { return buildDef; }

	virtual bool IsGeneric() const { return false; }
	BuildType GetBuildType() const { return buildType; }
	// D-211: opt-in, transient recovery selection. Script re-adopts after load.
	// Prevent legacy feature-area reevaluation from silently changing the job.
	bool recoveryControlled = false;
	float GetBuildPowerM() const { return buildPower.metal; }
	float GetBuildPowerE() const { return buildPower.energy; }
	float GetCostM() const { return cost.metal; }
	float GetCostE() const { return cost.energy; }

	virtual void SetBuildPos(const springai::AIFloat3& pos);
	const springai::AIFloat3& GetBuildPos() const { return buildPos; }
	const springai::AIFloat3& GetPosition() const { return geom::is_valid(buildPos) ? buildPos : position; }

	virtual void SetTarget(CCircuitUnit* unit);
	CCircuitUnit* GetTarget() const { return target; }
	void UpdateTarget(CCircuitUnit* unit);

	bool IsEqualBuildPos(CCircuitUnit* unit) const;

	void SetFacing(int value) { facing = value; }
	int GetFacing() const { return facing; }

	void SetNextTask(IBuilderTask* task) { nextTask = task; }
	IBuilderTask* GetNextTask() const { return nextTask; }

	float ClampPriority() const { return std::min(static_cast<float>(priority), 1.0f); }  // FIXME: BA

protected:
	void SetTaskPos(const springai::AIFloat3& pos) { position = pos; }
	CCircuitUnit* GetNextAssignee();
	void Update(CCircuitUnit* unit);
	virtual bool Reevaluate(CCircuitUnit* unit);
	// Experimental build mode (D-064): the manager's flag; the engine's build
	// range for this unit and site (reach + buildee radius, x0.9); the command
	// timeout (none in the mode); engage when inside the range, or inside the
	// direct range on safe ground, cancelling the AI path.
	bool IsExperimental() const;
	float EngageRange(CCircuitUnit* unit);
	int CmdTimeout(int frame) const;
	bool TryEngage(CCircuitUnit* unit);
	// Move to a free point on the range circle; the construction command
	// follows on arrival (the idle event). True when a move was given.
	bool Approach(CCircuitUnit* unit);
	void UpdatePath(CCircuitUnit* unit);
	void ApplyPath(const CQueryPathSingle* query);
	void HideAssignee(CCircuitUnit* unit);
	void ShowAssignee(CCircuitUnit* unit);
	virtual CAllyUnit* FindSameAlly(CCircuitUnit* builder, const std::vector<springai::Unit*>& friendlies);
	virtual void FindBuildSite(CCircuitUnit* builder, const springai::AIFloat3& pos, float searchRadius);
	void FindFacing(const springai::AIFloat3& pos);

	void ExecuteChain(SBuildChain* chain);

	virtual bool Load(std::istream& is) override;
	virtual void Save(std::ostream& os) const override;

	BuildType buildType;
	springai::AIFloat3 position;
	float shake;  // Alter/randomize position by offset
	CCircuitDef* buildDef;
	bool canAutoAbort;

	SResource buildPower;  // task's metal and energy per second expenditure
	SResource cost;
	CCircuitUnit* target;  // FIXME: Replace target with unitId
	springai::AIFloat3 buildPos;
	int facing;
	int reservationId;  // CTerrainManager reservation this site was served from; -1 = none
	int pinnedReservation;  // an exact layout task: serve exactly this slot; -1 = none
	bool pinRequired;
	bool pinFailed;
	bool layoutOwned;
	void TakeReservation(CTerrainManager* terrainMgr);  // after a FindBuildSite that may have served one
public:
	bool PinReservation(int id);
	void RequireReservation() { pinRequired = true; pinnedReservation = -1; layoutOwned = true; }
	bool IsLayoutOwned() const { return layoutOwned; }
	int GetReservationId() const { return reservationId; }
	// Called by the existing watchdog, only for script-opted-in roles.
	void RecoverConstruction(CCircuitUnit* unit, int retryFrames, int releaseFrames);
protected:
	bool AdoptStandingFrame(CCircuitUnit* unit);
	bool TryBuildCachedSite(CCircuitUnit* unit);
	std::map<CCircuitUnit*, construction::Observation> constructionHealth;
	IBuilderTask* nextTask;  // old list style
	CCircuitUnit* initiator;

	SResource savedIncome;
	int buildFails;

	decltype(units)::const_iterator unitIt;  // update iterator

	std::set<CCircuitUnit*> traveled;
	std::set<CCircuitUnit*> executors;
	std::set<CCircuitUnit*> engaged;  // D-064: units whose construction command stands (a second one restarts the nanolathe)
	std::set<CCircuitUnit*> approaching;  // D-064: units walking to their approach point; the arrival idle gives the command

#ifdef DEBUG_VIS
	virtual void Log() override;
#endif
};

} // namespace circuit

#endif // SRC_CIRCUIT_TASK_BUILDER_BUILDERTASK_H_
