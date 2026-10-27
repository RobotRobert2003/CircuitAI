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
 * Siege mode (SetSiege, the TECH capital rush with no AIR ally): no escort.
 * Each member takes the best scouted roster target anywhere (in sight or only
 * remembered), the unit while in sight, else ATTACK ground on its last known
 * spot, and keeps it until it no longer exists (dead, or its spot in sight and
 * empty for SIEGE_HIDDEN_FRAMES); an expired or finished order is given again on the same target.
 * Members with no target fly back to SetHome's spot (one MOVE) and wait there.
 *
 * Fighter mode (SetFighterEscort, the capital rush's T2 fighters, owner 2026-10-27): the
 * members only guard (script allows no strike defs), keep their def's fire and move
 * states so the engine's air GUARD engages whatever attacks the vip, and are not
 * re-guarded when it does.
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
	void SetSiege(bool on) { siege = on; }
	void SetHome(const springai::AIFloat3& pos) { home = pos; }
	void SetFighterEscort(bool on) { fighterEscort = on; }
	bool IsSiege() const { return siege; }
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
		bool reissue;                      // siege: the order ended with the target alive; give it again
		int hiddenFrame;                   // siege: first frame its last known spot was seen empty, -1 none
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
	bool IsSiegeTargetGone(SStrike& strike, int frame) const;
	void FollowTarget(CCircuitUnit* unit, SStrike& strike, int frame);
	void EndStrike(int unitId, const char* reason);
	int StrikersOn(int targetId) const;

	std::vector<int> vipIds;               // candidates in script order; dead ones pruned
	int vipId;                             // the escort target now, -1 none
	std::map<int, float> allowedStrikeDefs;
	float strikeRadius;
	int perTarget;
	int attackFrames;
	bool siege;                            // no escort: strike scouted roster targets anywhere
	springai::AIFloat3 home;               // siege: where a member with no target waits (x < 0: where it is)
	std::set<int> sentHome;                // siege: members whose standing order is the MOVE home
	bool fighterEscort;                    // guard only, fire at will, engine guard responses kept
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
