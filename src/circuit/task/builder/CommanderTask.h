#pragma once
#include "task/fighter/FighterTask.h"

namespace circuit {
// Owns one retained resume token. Removal never resumes implicitly: player,
// capture, death and retreat takeovers must remain authoritative.
class CCommanderTask final : public IFighterTask {
public:
    CCommanderTask(ITaskModule* manager,IUnitTask* previous);
    ~CCommanderTask() override;
    void AssignTo(CCircuitUnit* unit) override;
    void RemoveAssignee(CCircuitUnit* unit) override;
    bool ForgetUnit(CCircuitUnit* unit) override;
    void Start(CCircuitUnit*) override {}
    void Update() override {}
    void Stop(bool done) override;
    void OnUnitIdle(CCircuitUnit*) override {}
    void OnUnitDamaged(CCircuitUnit*,CEnemyInfo*) override {}
    void OnUnitDestroyed(CCircuitUnit* unit,CEnemyInfo*) override;
    void OnUnitMoveFailed(CCircuitUnit* unit) override;
    void Resume(CCircuitUnit* unit);
    // D-299: hand the unit back to its manager for a new task instead of the
    // retained previous one (a fallback line must not resume front work).
    void Handover(CCircuitUnit* unit);
private:
    IUnitTask* previous;
    int oldFire=2,oldMove=1;
    bool oldCloak=false;
    void Restore(CCircuitUnit* unit);
};
}
