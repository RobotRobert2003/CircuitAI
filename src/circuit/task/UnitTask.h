/*
 * UnitTask.h
 *
 *  Created on: Sep 2, 2014
 *      Author: rlcevg
 */

#ifndef SRC_CIRCUIT_TASK_UNITTASK_H_
#define SRC_CIRCUIT_TASK_UNITTASK_H_

#include "script/RefCounter.h"

#include "AIFloat3.h"
//#define DEBUG_SAVELOAD 1
#ifdef DEBUG_SAVELOAD
#include "Log.h"
#endif

#include <set>
#include <map>
#include <memory>

namespace springai {
	class Unit;
}

namespace circuit {

class CCircuitUnit;
class CEnemyInfo;
class ITaskModule;
class IPathQuery;
class CQueryPathSingle;
class CQueryPathMulti;

class IUnitTask: public IRefCounter<IUnitTask> {  // CSquad, IAction
public:
	enum class Priority: char {LOW = 0, NORMAL = 1, HIGH = 2, NOW = 99};
	enum class Type: char {NIL, PLAYER, IDLE, WAIT, RETREAT, BUILDER, FACTORY, FIGHTER};
	enum class State: char {ROAM, ENGAGE, DISENGAGE, REGROUP};

protected:
	IUnitTask(ITaskModule* mgr, Priority priority, Type type, int timeout);
	IUnitTask(ITaskModule* mgr, Type type);  // Load
	virtual ~IUnitTask();
public:
	virtual void ClearRelease();

	virtual bool CanAssignTo(CCircuitUnit* unit) const;
	virtual void AssignTo(CCircuitUnit* unit);
	virtual void RemoveAssignee(CCircuitUnit* unit);
	// D-108 crash: drop a unit about to be freed from this task's sets, without
	// handing it to the idle task (RemoveAssignee would), so no task keeps a
	// dangling pointer (played: CSRepairTask::Update on a freed unit)
	// virtual (D-112 crash): a task's own sets of units (a builder task's traveled /
	// engaged / approaching, a fighter task's cowards / shields) forget it too
	virtual bool ForgetUnit(CCircuitUnit* unit) { pathQueries.erase(unit); return units.erase(unit) > 0; }

	virtual void Start(CCircuitUnit* unit) = 0;  // <=> IAction::OnStart()
	virtual void Update() = 0;
	virtual void Stop(bool done);  // <=> IAction::OnEnd()
protected:
	// NOTE: Do not run time consuming code here. Instead create separate task.
	virtual void Finish();
	virtual void Cancel();  // TODO: Make pure virtual?

public:
	virtual void OnUnitIdle(CCircuitUnit* unit) = 0;
	virtual void OnUnitDamaged(CCircuitUnit* unit, CEnemyInfo* attacker) = 0;
	virtual void OnUnitDestroyed(CCircuitUnit* unit, CEnemyInfo* attacker) = 0;
	virtual void OnUnitMoveFailed(CCircuitUnit* unit);

	virtual void OnTravelEnd(CCircuitUnit* unit);
	virtual void OnRearmStart(CCircuitUnit* unit);

	const std::set<CCircuitUnit*>& GetAssignees() const { return units; }
	Priority GetPriority() const { return priority; }
	Type GetType() const { return type; }
	ITaskModule* GetManager() const { return manager; }

	int GetLastTouched() const { return lastTouched; }
	int GetTimeout() const { return timeout; }

	virtual void Dead();
	bool IsDead() const { return isDead; }
	virtual bool IsEnemyReclaim() const { return false; }
	virtual bool IsExternalControlled() const { return false; }

	// AS API
	void Abort();
	void Done();

protected:
	bool IsQueryReady(CCircuitUnit* unit) const;

public:
	friend bool operator>>(std::istream& is, IUnitTask& data);
	friend std::ostream& operator<<(std::ostream& os, const IUnitTask& data);
protected:
	virtual bool Load(std::istream& is);
	virtual void Save(std::ostream& os) const;

	ITaskModule* manager;
	std::set<CCircuitUnit*> units;
	Type type;
	Priority priority;
	State state;
	std::map<CCircuitUnit*, std::shared_ptr<IPathQuery>> pathQueries;  // IPathQuery owner

	int lastTouched;
	int timeout;

	unsigned int updCount;
	bool isDead;

#ifdef DEBUG_VIS
public:
	virtual void Log();
#endif
};

inline bool operator>>(std::istream& is, IUnitTask& data)
{
	return data.Load(is);
}

inline std::ostream& operator<<(std::ostream& os, const IUnitTask& data)
{
	data.Save(os);
	return os;
}

} // namespace circuit

#endif // SRC_CIRCUIT_TASK_UNITTASK_H_
