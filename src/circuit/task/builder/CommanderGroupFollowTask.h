#pragma once
#include "task/common/WaitTask.h"

namespace circuit {
// Movement-only escort: engine GUARD would start construction without the
// group's owned-nano prerequisite. One task per member, ordinary retreat rules.
class CCommanderGroupFollowTask final: public IWaitTask {
public:
    CCommanderGroupFollowTask(ITaskModule* manager,int target,float radius);
    void Start(CCircuitUnit* unit) override;
    void Update() override;
    void OnUnitIdle(CCircuitUnit* unit) override;
    void OnUnitDamaged(CCircuitUnit* unit,CEnemyInfo* attacker) override;
    int Target() const { return target; }
private:
    void Follow(CCircuitUnit* unit);
    int target,next=0,sent=-10000;
    float radius;
    bool waiting=false;
    springai::AIFloat3 goal{-1,0,-1};
};
}
