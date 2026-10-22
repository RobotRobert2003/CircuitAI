#include "task/common/ExternalControlTask.h"
#include "task/IdleTask.h"
#include "module/TaskModule.h"
#include "unit/CircuitUnit.h"
#include "Unit.h"

namespace circuit {
CExternalControlTask::CExternalControlTask(ITaskModule* manager, const std::string& rule)
    : IUnitTask(manager, Priority::NORMAL, Type::WAIT, 0), rule(rule) {}

void CExternalControlTask::AssignTo(CCircuitUnit* unit)
{
    // IUnitTask::AssignTo removes WAIT, which is itself an engine command.
    // Do not touch the gadget's queue, even during ownership handover.
    manager->GetIdleTask()->RemoveAssignee(unit);
    unit->SetTask(this);
    units.insert(unit);
    lastTouched = -1;
}

void CExternalControlTask::Update()
{
    for (auto it = units.begin(); it != units.end();) {
        CCircuitUnit* unit = *it++;
        if (unit->GetUnit()->GetRulesParamFloat(rule.c_str(), -1.f) < 0.f) {
            RemoveAssignee(unit);
        }
    }
    if (units.empty()) Done();
}

void CExternalControlTask::OnUnitDestroyed(CCircuitUnit* unit, CEnemyInfo*)
{
    RemoveAssignee(unit);
    if (units.empty()) Done();
}
}
