/*
 * RetreatTask.h
 *
 *  Created on: Jan 18, 2015
 *      Author: rlcevg
 */

#ifndef SRC_CIRCUIT_TASK_RETREATTASK_H_
#define SRC_CIRCUIT_TASK_RETREATTASK_H_

#include "task/UnitTask.h"
#include "util/Defines.h"

#include <unordered_map>

namespace circuit {

class CQueryCostMap;

class CRetreatTask final: public IUnitTask {
public:
	CRetreatTask(ITaskModule* mgr, int timeout = ASSIGN_TIMEOUT);
	virtual ~CRetreatTask();

	virtual void ClearRelease() override;

	virtual void AssignTo(CCircuitUnit* unit) override;
	virtual void RemoveAssignee(CCircuitUnit* unit) override;

	virtual void Start(CCircuitUnit* unit) override;
	virtual void Update() override;
protected:
	virtual void Finish() override;
	virtual void Cancel() override;

public:
	virtual void OnUnitIdle(CCircuitUnit* unit) override;
	virtual void OnUnitDamaged(CCircuitUnit* unit, CEnemyInfo* attacker) override;
	virtual void OnUnitDestroyed(CCircuitUnit* unit, CEnemyInfo* attacker) override;

	void CheckRepairer(CCircuitUnit* newRep);
	void SetRepairer(CCircuitUnit* unit) { repairer = unit; }
	CCircuitUnit* GetRepairer() const { return repairer; }

	virtual void Dead();

private:
	void Recovered(CCircuitUnit* unit);
	// D-346: forward repair point checks; arrival radius in elmos.
	bool HoldValid(CCircuitUnit* unit, int frame);
	static constexpr float HOLD_RADIUS = 128.f;
	// D-348: the forward hold each traveling unit last pathed to. A path is
	// re-planned only when the hold moves more than HOLD_REPATH elmos. Keyed by
	// unit, erased on RemoveAssignee. Bounded by the task's assignees.
	std::unordered_map<CCircuitUnit*, springai::AIFloat3> holdPathed;
	static constexpr float HOLD_REPATH = 64.f;

	void ApplyPath(const CQueryPathSingle* query);
	CCircuitUnit* ValidateNewRepairer(const IPathQuery* query, int newRepId) const;
	void ApplyCostMap(const CQueryCostMap* query, CCircuitUnit* newRep);

	CCircuitUnit* repairer;
	std::shared_ptr<IPathQuery> costQuery;  // owner
};

} // namespace circuit

#endif // SRC_CIRCUIT_TASK_RETREATTASK_H_
