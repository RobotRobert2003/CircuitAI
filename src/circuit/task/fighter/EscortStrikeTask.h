/*
 * EscortStrikeTask.h
 *
 * Strike aircraft that fly with another cohort instead of on a route of their
 * own (the Armada Liches with a T2 bomber raid; AirLiches:: in
 * data/script/src/systems/air/air_liches.as). Every member guards one living
 * escort target (the vip), picked from the unit ids script supplies; when the
 * vip dies the members guard the nearest living one. A member stays on its
 * guard until an allowed target is in sight within the strike radius of it,
 * then breaks off with one ATTACK on that unit; when the target drops out of
 * sight it bombs the spot where it was last seen (ATTACK ground), and it
 * rejoins the escort when the target is gone or the order expires.
 * Script owns the roster and its weights, the radius, the strikers per target
 * and the attack time; this task owns the orders. Decisions that need no
 * engine are in EscortStrikeRules.h.
 *
 * Orders: one GUARD per member per escort change, one ATTACK per strike and
 * one more each time its target leaves or re-enters sight.
 * Nothing is re-issued while a member's order stands (lag fix, 2026-10-23).
 * Every unit and enemy is held by id and resolved at the point of use.
 */
#ifndef SRC_CIRCUIT_TASK_FIGHTER_ESCORTSTRIKETASK_H_
#define SRC_CIRCUIT_TASK_FIGHTER_ESCORTSTRIKETASK_H_

#include "task/fighter/FighterTask.h"

#include <map>
#include <set>
#include <vector>

namespace circuit {

class CCircuitDef;

class CEscortStrikeTask final: public IFighterTask {
public:
	CEscortStrikeTask(ITaskModule* mgr);
	virtual ~CEscortStrikeTask();

	virtual bool CanAssignTo(CCircuitUnit* unit) const override;
	virtual void AssignTo(CCircuitUnit* unit) override;
	virtual void RemoveAssignee(CCircuitUnit* unit) override;
	virtual bool ForgetUnit(CCircuitUnit* unit) override;

	virtual void Start(CCircuitUnit* unit) override;
	virtual void Update() override;

	virtual void OnUnitIdle(CCircuitUnit* unit) override;
	virtual void OnUnitDamaged(CCircuitUnit* unit, CEnemyInfo* attacker) override;
	virtual void OnUnitDestroyed(CCircuitUnit* unit, CEnemyInfo* attacker) override;
	void OnWeaponFired(CCircuitUnit* unit, int weaponDefId);

	// Script hooks
	void AddEscortTarget(int unitId);  // a candidate vip, by unit id
	void AllowStrikeDef(CCircuitDef* def, float priority);
	/*
	 * radius         a member breaks off for a target this close to it, elmos
	 * perTarget      members striking one target at once; <= 0 no limit
	 * attackSeconds  an ATTACK not resolved by then ends and the member rejoins
	 */
	void SetStrikePolicy(float radius, int perTarget, int attackSeconds);
	int GetVipId() const { return vipId; }
	int GetStriking() const { return static_cast<int>(strikes.size()); }
	int GetStrikesIssued() const { return strikesIssued; }
	int GetShotsFired() const { return shotsFired; }
	int GetTargetsDestroyed() const { return targetsDestroyed; }

private:
	struct SStrike {
		int targetId;
		int until;
		bool fired;
		bool ground;                       // the standing ATTACK is on lastSeen, not the unit
		springai::AIFloat3 lastSeen;       // the target's position when last in sight
	};
	struct SCandidate {
		CEnemyInfo* enemy;
		float priority;
	};

	CCircuitUnit* ResolveVip(int frame);
	void CollectCandidates();
	bool TryStrike(CCircuitUnit* unit, int frame);
	void GuardVip(CCircuitUnit* unit, CCircuitUnit* vip, int frame);
	void CheckGuards(CCircuitUnit* vip, int frame);
	bool IsTargetGone(int targetId) const;
	void FollowTarget(CCircuitUnit* unit, SStrike& strike, int frame);
	void EndStrike(int unitId, const char* reason);
	int StrikersOn(int targetId) const;

	std::vector<int> vipIds;               // candidates in script order; dead ones pruned
	int vipId;                             // the escort target now, -1 none
	std::map<int, float> allowedStrikeDefs;
	float strikeRadius;
	int perTarget;
	int attackFrames;
	std::map<int, SStrike> strikes;        // member id -> its attack
	std::map<int, int> guarding;           // member id -> vip id its standing GUARD names
	std::map<int, int> lastOrder;          // member id -> frame of its last order
	std::set<int> fired;                   // members that released a weapon on a strike
	std::vector<SCandidate> candidates;    // this update's targets, one enemy scan
	int strikesIssued;
	int shotsFired;
	int targetsDestroyed;
	int nextGuardCheck;                    // frame of the next engine-attack check on the guards
};

} // namespace circuit

#endif // SRC_CIRCUIT_TASK_FIGHTER_ESCORTSTRIKETASK_H_
