#ifndef SRC_CIRCUIT_TASK_COMMON_EXTERNALCONTROLTASK_H_
#define SRC_CIRCUIT_TASK_COMMON_EXTERNALCONTROLTASK_H_

#include "task/UnitTask.h"
#include <string>

namespace circuit {
// Explicit script opt-in for units whose game gadget owns their command queue.
// The rule is a nonnegative owner id; absent/negative returns the unit to idle.
class CExternalControlTask final: public IUnitTask {
public:
    CExternalControlTask(ITaskModule* manager, const std::string& rule);
    void AssignTo(CCircuitUnit* unit) override;
    void Start(CCircuitUnit*) override {}
    void Update() override;
    void OnUnitIdle(CCircuitUnit*) override {}
    void OnUnitDamaged(CCircuitUnit*, CEnemyInfo*) override {}
    void OnUnitDestroyed(CCircuitUnit* unit, CEnemyInfo*) override;
    void OnUnitMoveFailed(CCircuitUnit*) override {}
    bool IsExternalControlled() const override { return true; }
private:
    std::string rule;
};
}
#endif
