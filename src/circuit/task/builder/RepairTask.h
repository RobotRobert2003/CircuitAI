/*
 * RepairTask.h
 *
 *  Created on: Jan 29, 2015
 *      Author: rlcevg
 */

#ifndef SRC_CIRCUIT_TASK_REPAIRTASK_H_
#define SRC_CIRCUIT_TASK_REPAIRTASK_H_

#include "task/common/RepairTask.h"

namespace circuit {

class CEconomyManager;

class CBRepairTask final: public IRepairTask {
public:
	CBRepairTask(ITaskModule* mgr, Priority priority, CAllyUnit* target, int timeout = 0);
	CBRepairTask(ITaskModule* mgr);  // Load
	virtual ~CBRepairTask();

	virtual bool CanAssignTo(CCircuitUnit* unit) const override;
	// D-299: commanders never take generic repairs; the FRONT work ladder
	// invites exactly one. Transient (not saved): a reload re-offers it.
	void InviteCommander(int unitId) { invitedCommander = unitId; stationaryCommander=-1; }
    void InviteStationaryCommander(int unitId) { invitedCommander=unitId; stationaryCommander=unitId; }
    bool IsStationaryCommander(CCircuitUnit* unit) const { return unit->GetId()==stationaryCommander; }
    void UpdateStationary(CCircuitUnit* unit);

	virtual void Start(CCircuitUnit* unit) override;

	virtual void OnUnitIdle(CCircuitUnit* unit) override;
	virtual void OnUnitDamaged(CCircuitUnit* unit, CEnemyInfo* attacker) override;

private:
	virtual bool Reevaluate(CCircuitUnit* unit) override;

	virtual bool Load(std::istream& is) override;

	int invitedCommander = -1;
    int stationaryCommander = -1;
};

} // namespace circuit

#endif // SRC_CIRCUIT_TASK_REPAIRTASK_H_
