/*
 * GuardTask.h
 *
 *  Created on: Jul 13, 2016
 *      Author: rlcevg
 */

#ifndef SRC_CIRCUIT_TASK_BUILDER_GUARDTASK_H_
#define SRC_CIRCUIT_TASK_BUILDER_GUARDTASK_H_

#include "task/builder/BuilderTask.h"
#include "task/builder/GuardIntent.h"
#include "unit/CircuitUnit.h"

namespace circuit {

class CBGuardTask final: public IBuilderTask {
public:
	CBGuardTask(ITaskModule* mgr, Priority priority,
				CCircuitUnit* vip, bool isInterrupt, int timeout);
	virtual ~CBGuardTask();

	virtual bool CanAssignTo(CCircuitUnit* unit) const override;
	virtual void AssignTo(CCircuitUnit* unit) override;
	virtual void RemoveAssignee(CCircuitUnit* unit) override;

	virtual void Stop(bool done) override;
	int GetGuardTargetId() const { return vipId; } // opt-in script observation; no ownership change
	bool MatchesGuard(int workerId, int targetId, Priority requestedPriority, bool interrupt, int requestedTimeout, int frame) const {
		// Reuse never renews the original deadline. A missing engine command is
		// recovered by this task's existing Execute/OnUnitIdle path.
		// Only reevaluation consumes a returned current task without a transfer.
		// Ordinary AssignTask removes the old assignee first, which can abort it.
		return reevaluatingWorker == workerId && !IsDead() && vipId == targetId && priority == requestedPriority
			&& isInterrupt == interrupt && timeout == requestedTimeout
			&& guard::LeaseAlive(lastTouched, timeout, frame);
	}

protected:
	virtual bool Execute(CCircuitUnit* unit) override;

public:
	virtual void OnUnitIdle(CCircuitUnit* unit) override;

protected:
	virtual bool Reevaluate(CCircuitUnit* unit);

private:
	bool IsTargetBuilder() const;
	bool KeepGuard(CCircuitUnit* unit, const char* source) const;

	ICoreUnit::Id vipId;
	bool isInterrupt;
	int reevaluatingWorker = -1; // callback-local identity, deliberately not serialized
};

} // namespace circuit

#endif // SRC_CIRCUIT_TASK_BUILDER_GUARDTASK_H_
