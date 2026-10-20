#ifndef CIRCUIT_RANGED_ENGAGEMENT_H
#define CIRCUIT_RANGED_ENGAGEMENT_H
#include "task/fighter/RangedWorld.h"
#include <memory>

namespace springai { class Weapon; }
namespace circuit {
class IUnitTask;
class IPathQuery;
class CRangedEngagement {
public:
    CRangedEngagement(CCircuitAI* ai, IUnitTask* owner, CCircuitUnit* unit);
    ~CRangedEngagement();
    void Update(CCircuitUnit* unit);
    void Idle() { nextFrame=0; }
    void MoveFailed() { query.reset(); moving=false; completedMove=false; orientUntil=0; nextFrame=0; ++failures; ++rejections; }
    void Release(CCircuitUnit* unit, bool commands=true);
    int Target() const { return target; }
    bool IsSustainedRush() const { return world.IsSustainedRush(id); }
private:
    void SelectTarget(CCircuitUnit* unit,int id,int weapon,float damage,float score=-1.f);
    bool Move(CCircuitUnit* unit,const springai::AIFloat3& destination,bool escape,bool urgent=false);
    void Hold(CCircuitUnit* unit,bool unsafe=false);
    void Disperse(CCircuitUnit* unit);
    void UpdateCohort(CCircuitUnit* unit);
    bool LegalPath(CCircuitUnit* unit,const std::vector<springai::AIFloat3>& route,bool escape);
    bool SafeMove(CCircuitUnit* unit,const springai::AIFloat3& from,const springai::AIFloat3& to,float margin,bool escape);
    CCircuitAI* ai;
    IUnitTask* owner;
    // Tasks may outlive the derived manager destructor during shutdown.
    std::shared_ptr<CRangedWorld> worldOwner;
    CRangedWorld& world;
    const CRangedWorld::Capabilities& caps;
    int id, target=-1, weaponIndex=-1, nextFrame=0, targetFrame=0;
    int lastReload=-1, burstUntil=0, withdrawalUntil=0, failures=0;
    int lastProgressFrame=0, lastMoveFrame=-10000;
    int lastShotFrame=0, orientUntil=0;
    int traceFrame=-150;
    size_t pathCursor=0;
    springai::AIFloat3 lastPos, destination;
    std::unique_ptr<springai::Weapon> liveWeapon;
    std::shared_ptr<IPathQuery> query;
    // Callback cancellation must not depend on allocator reuse of this/owner.
    std::shared_ptr<int> lifetime=std::make_shared<int>(0);
    unsigned generation=0;
    bool urgentMove=false;
    bool completedMove=false;
    int moveObjective=-1, moveMode=-1;
    bool moving=false, issuing=false, released=false, cloakWanted=false, reorient=false;
    float reservedDamage=0.f;
    float heldScore=0.f; int heldScoreFrame=-1; // current target's score, the tick it last passed the candidate filters
    std::vector<int> nearby;
    // D-295 assist state: reused query buffer (capacity retained), the
    // current assisted contact id (log once per change), and the INV-206
    // one-decision follow-up of an accepted assist Move.
    std::vector<int> assistNearby;
    int assistTarget=-1, assistCheckFrame=-1, assistIdleStreak=0;
    // Monotonic count of rejected worker paths and engine move failures;
    // unlike `failures` it is never reset by progress (INV-206 baseline).
    unsigned rejections=0, assistCheckRejections=0;
    bool assistInvariantLogged=false;
    std::vector<springai::AIFloat3> path;
};
}
#endif
