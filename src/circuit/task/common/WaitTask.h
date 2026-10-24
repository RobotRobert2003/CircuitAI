/*
 * WaitTask.h
 *
 *  Created on: Jul 24, 2016
 *      Author: evgenij
 */

#ifndef SRC_CIRCUIT_TASK_WAITTASK_H_
#define SRC_CIRCUIT_TASK_WAITTASK_H_

#include "task/UnitTask.h"

namespace circuit {

class IWaitTask: public IUnitTask {
public:
	IWaitTask(ITaskModule* mgr, bool stop, int timeout);
	virtual ~IWaitTask();

	virtual void AssignTo(CCircuitUnit* unit) override;
	virtual void RemoveAssignee(CCircuitUnit* unit) override;

	virtual void Start(CCircuitUnit* unit) override;
	virtual void Update() override;

	virtual void OnUnitIdle(CCircuitUnit* unit) override;
	virtual void OnUnitDestroyed(CCircuitUnit* unit, CEnemyInfo* attacker) override;

	// Configure before assignment. Clear the predecessor's queue and use engine
	// WAIT so an idle mobile cannot generate an automatic chase command.
	void SetStationary(bool value) { isStationary = value; if (value) isStop = true; }

protected:
	bool isStop;
	bool isStationary = false;
};

} // namespace circuit

#endif // SRC_CIRCUIT_TASK_WAITTASK_H_
