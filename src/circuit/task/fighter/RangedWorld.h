#ifndef CIRCUIT_RANGED_WORLD_H
#define CIRCUIT_RANGED_WORLD_H

#include "terrain/RangedGeometry.h"
#include "terrain/GroundCohort.h"
#include "terrain/LocalRush.h"
#include "AIFloat3.h"
#include <map>
#include <memory>
#include <unordered_map>
#include <vector>

namespace springai { class WeaponMount; }
namespace circuit {
class CCircuitAI;
class CCircuitDef;
class CCircuitUnit;
class CWeaponDef;

// Per-AI callback-thread service: fresh legal data; buffers retain allocation.
// Inventory O(N+E+F+C+I/64): world scan N, enemies E, friends F, touched cells C,
// engine ID bound I. Same ascending order/ties; no cross-frame observation cache.
// Member/history/shot/escort bookkeeping retains its separate map lookup costs.
class CRangedWorld {
public:
    struct Weapon {
        std::unique_ptr<springai::WeaponMount> mount;
        CWeaponDef* def = nullptr; // owned by CircuitAI
        std::vector<float> damage;
        int category = 0, index = 0;
        float range = 0.f, arc = -1.f, reload = 1.f, burst = 0.f;
        float heightMod = 1.f, cylinder = 0.f, speed = 0.f, gravity = 0.f;
        float splash = 0.f, alphaScale = 1.f;
        float beamMinIntensity = 1.f, beamTargetBorder = 0.f;
        bool ballistic = false, high = false, forward = false, fake = false, guided = false, instant = false, continuous = false;
        Weapon(); ~Weapon();
        Weapon(Weapon&&) noexcept; Weapon& operator=(Weapon&&) noexcept;
    };
    struct Capabilities {
        std::vector<Weapon> weapons;
        float turnRate = 1.f, acceleration = 0.f, speed = 0.f, blastRadius = 0.f;
        float radius = 16.f, cloakCost = 0.f, cloakMoving = 0.f;
        bool cloak = false;
    };
    struct Contact {
        int id = -1;
        int armor = 0;
        CCircuitDef* def = nullptr;
        springai::AIFloat3 pos, velocity;
        float health = 1.f, radius = 16.f, cost = 1.f, groundRange = 0.f;
        float explosionRadius = 0.f, hazardRadius = 0.f;
        float tech = 1.f; // BAR customparams.techlevel, 1 when absent
        bool los = false, armed = false, mobile = false;
    };
    struct Friend {
        int id; springai::AIFloat3 pos; float radius;
        bool screen; float radar, jammer, los;
        CCircuitDef* def=nullptr;
        float combatHealth=-1.f; // lazy, invalidated with the per-frame snapshot
        float range=0.f;    // D-295: LAND weapon range of a screen definition
        bool assist=false;  // D-295: definition itself assists (excluded as engager)
    };
    struct Slot { springai::AIFloat3 pos; float spacing, value; float radius=0.f; bool coordinated=false; };

    explicit CRangedWorld(CCircuitAI* circuit);
    ~CRangedWorld();
    const Capabilities& CapabilitiesFor(CCircuitDef* def);
    void Refresh();
    void Join(CCircuitUnit* unit);
    void Leave(int id);
    void SetSlot(int id, const springai::AIFloat3& pos, float spacing, float value);
    bool FreeSlot(int id, const springai::AIFloat3& pos, float spacing) const;
    void Nearby(const springai::AIFloat3& pos, float radius, std::vector<int>& result) const;
    const std::vector<Contact>& Contacts() const { return contacts; }
    const std::vector<int>& Objectives() const { return objectives; }
    // press (owner 2026-10-19, RangedPolicy::pressStatic): armed static
    // contacts of that tech level or lower count only with their death blast.
    bool Safe(const springai::AIFloat3& from, const springai::AIFloat3& to, float margin, bool escaping=false, float press=0.f) const;
    float Danger(const springai::AIFloat3& pos, float margin, float press=0.f) const;
    int DangerSign(const springai::AIFloat3& pos, float margin, float press=0.f) const;
    static bool Pressed(const Contact& c, float press) {
        return press>0.f && c.def && c.armed && !c.mobile && c.tech<=press;
    }
    static float HazardFor(const Contact& c, float press) {
        return Pressed(c,press) ? c.explosionRadius : c.hazardRadius;
    }
    bool FriendlySplash(int id, const springai::AIFloat3& target, float radius) const;
    bool FriendlyLine(const Weapon& weapon, int id, const springai::AIFloat3& from, const springai::AIFloat3& target) const;
    bool HasScreen(int id, const springai::AIFloat3& from, const springai::AIFloat3& target) const;
    // D-295: is an allied screen (any team of our allyteam, from the friendly
    // snapshot) already within its ground range + margin of this LOS ground
    // contact? Memoised per contact per frame (and per margin); one local
    // allies.Any per first call. Ally receives the engaging friend's unit id.
    bool Engaged(int contact, float margin, int* ally=nullptr) const;
    float Range(const Weapon& weapon, const springai::AIFloat3& from, const springai::AIFloat3& to) const;
    bool Trajectory(const Weapon& weapon, const springai::AIFloat3& from, const springai::AIFloat3& to) const;
    void ReserveShot(int owner, int target, float damage, int until);
    float Reserved(int target, int owner) const;
    void ReleaseShot(int owner);
    float Progress(int target, float penalty) const;
    float ClusterValue(const springai::AIFloat3& target, float radius) const;
    bool Escort(CCircuitUnit* sensor, springai::AIFloat3& position);
    bool HasMembers() const { return !slots.empty(); }
    struct CohortPlan {
        int formationFrame=-1, formationPartner=-1;
        bool formationRear=false;
        float formationScreenOffset=0.f;
        int frame=-1, target=-1, regroupUntil=0, nextRegroup=0, nextMerge=0;
        springai::AIFloat3 center, back, focus;
        float radius=0.f;
        cohort::Mode mode=cohort::Mode::ADVANCE;
        std::vector<int> members;
        std::vector<int> candidates; // reused local enemy-query storage
        // Permissions live only for this observed plan. IDs, never contact
        // indices, survive a snapshot refresh. Every route revalidates them.
        std::vector<int> assault;
        cohort::Reason reason=cohort::Reason::TRAVEL;
        float loss=1.f, advantage=0.f;
        int assemblyTarget=-1, objectiveFrame=-1;
        int protectedTarget=-1; // last legally seen commander/reclaimer; losing LOS is not a kill
        springai::AIFloat3 strategic;
        bool committed=false, supporting=false;
        bool sustainedRush=false, rushFallback=false;
        int rushFrame=-1;
        float screenDepth=0.f;
    };
    const CohortPlan& PlanCohort(CCircuitUnit* unit);
    bool IsSustainedRush(int id) const { return rushes.Active(id); }
    bool CohortSafe(CCircuitUnit* unit,const springai::AIFloat3& from,
                    const springai::AIFloat3& to,float margin,bool escaping);
    void ReleaseEscort(int id) { escorts.erase(id); }

private:
    CCircuitAI* circuit;
    int frame = -1;
    float largestRange = 0.f, largestStaticRange = 0.f, largestSpacing = 0.f, largestFriendRadius = 0.f;
    float largestScreenRange = 0.f; // D-295: bounds Engaged's local ally query
    // D-295 memo: -1 unknown, 0 not engaged, k>0 engaged by friends[k-1].
    // Owned by the callback thread; invalidated lazily when frame or margin
    // differs. Assign is O(E) at most once per frame, only if an assister asks.
    mutable std::vector<int> engagedMemo;
    mutable int engagedFrame = -1;
    mutable float engagedMargin = -1.f;
    float largestCohortHazard = 0.f;
    bool nonnegativeHazardCosts = true;
    bool finiteStaticHazards = true;
    struct Metadata { float radar=0.f, jammer=0.f, los=0.f; int armor=0; float explosionRadius=0.f; float tech=1.f; };
    std::unordered_map<int,Metadata> metadata;
    const Metadata& MetadataFor(CCircuitDef* def);
    std::unordered_map<int,Capabilities> capabilities;
    std::vector<Contact> contacts;
    std::vector<Friend> friends;
    // Per-observation definition prototypes. Unit IDs/positions are never
    // cached; mutable policy flags are reread on every Refresh publication.
    std::vector<Friend> friendlyDefinitions;
    std::vector<int> friendlyDefinitionFrames;
    std::vector<int> friendlyIds;
    ranged::OrderedIds friendlyOrder;
    std::vector<int> objectives;
    ranged::SpatialIndex enemies, staticHazards, formations;
    mutable ranged::SpatialIndex allies;
    mutable bool alliesDirty = true;
    void EnsureAllies() const;
    ranged::CellStore<float> clusterValues;
    std::map<int,Slot> slots;
    struct Shot { int target, until; float damage; };
    std::unordered_map<int,Shot> shots;
    std::unordered_map<int,float> reserved;
    struct History { float health=0.f; int stalled=0, frame=0, seen=0, engaged=-1; };
    std::unordered_map<int,History> history;
    struct EscortLease { int anchor=-1; bool jammer=false; };
    std::map<int,EscortLease> escorts;
    // Callback-thread IDs only. Rebuilt on task recreation, removed on Leave.
    // Formation buckets bound local recruitment; at most cohortSize members
    // are sampled per plan, once per decision frame, not once per shooter.
    std::map<int,CohortPlan> cohorts;
    std::unordered_map<int,int> membership;
    int nextCohort=0;
    rush::Registry rushes;
    std::vector<rush::Registry::Member> rushCandidates;
    void ApplyRush(CCircuitUnit* unit, CohortPlan& group);
    void JoinCohort(CCircuitUnit* unit);
    const CohortPlan& PlanIndependentCohort(CCircuitUnit* unit);
    void InvalidateCohortPlans(CohortPlan& group);
    float EffectiveDps(CCircuitDef* def,int armor,int category,
                       const springai::AIFloat3& from,const springai::AIFloat3& to,
                       float horizon,bool advancing);
    void AssessCohort(CCircuitUnit* unit,CohortPlan& group,const Contact& target,float range);
};
}
#endif
