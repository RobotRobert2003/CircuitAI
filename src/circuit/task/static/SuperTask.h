/*
 * SuperTask.h
 *
 *  Created on: Aug 12, 2016
 *      Author: rlcevg
 */

#ifndef SRC_CIRCUIT_TASK_STATIC_SUPERTASK_H_
#define SRC_CIRCUIT_TASK_STATIC_SUPERTASK_H_

#include "task/fighter/FighterTask.h"
#include "task/static/TierTargeting.h"

#include <algorithm>
#include <functional>
#include <unordered_map>

namespace circuit {

class CCircuitDef;
struct SEnemyData;

class CSuperTask final: public IFighterTask {
public:
	CSuperTask(ITaskModule* mgr);
	virtual ~CSuperTask();

	virtual bool CanAssignTo(CCircuitUnit* unit) const override;
	virtual void RemoveAssignee(CCircuitUnit* unit) override;

	virtual void Start(CCircuitUnit* unit) override;
	virtual void Update() override;

	// Script hooks
	void SetTargetPos(const springai::AIFloat3& pos);
	// Tiered fire (lolcannons, owner 2026-10-26): once any def has a tier the
	// task fires only at roster defs in range, best tier first (TierTargeting.h),
	// and otherwise stops; the script holds the unit's fire so the engine never
	// picks a target of its own. tier <= 0 takes a def off the roster.
	void SetTargetTier(const CCircuitDef* edef, int tier);
	void SetTierRetarget(int frames) { tierRetargetFrames = std::max(1, frames); }
	int GetTierTargetId() const { return tierTargetId; }
	int GetTierCount() const { return int(tierByDef.size()); }
	// Area rotation (owner 2026-10-27): with areas > 0 the roster targets in range
	// are grouped into at most `areas` areas (radius round each area's best target)
	// and the fire moves on from one area to the next after dwellFrames (> 0) or
	// shotsPerArea shots (> 0), back to the best area after the last; it starts
	// over at the best area whenever the highest-rated target changes.
	void SetTierRotation(int areas, int dwellFrames, int shotsPerArea, float radius);
	int GetTierAreaCount() const { return int(tierAreaList.size()); }
	springai::AIFloat3 GetTierAreaPos(int i) const;
	int GetTierAreaTargetId(int i) const;
	int GetTierAreaIndex() const { return tierAreaList.empty() ? -1 : tierRot.index; }
	// a shot seen (the weapon-fired event): counts toward shotsPerArea
	void OnTierShot(CCircuitUnit* unit);

private:
	void ExecuteAttack(CCircuitUnit* unit);
	/*
	 * Area-effect target selection shared by the weapons whose worth is not the
	 * metal of the enemy group they hit: Juno deletes only flagged defs, EMP only
	 * paralyses what it can hold. The classifier decides whether an enemy is a
	 * candidate at all and at what rank; everything else - last known positions,
	 * range, aim-point scoring, the hold-fire path - is common.
	 *
	 * Classifier: returns true for a candidate, and fills rank (lower fires
	 * first) and value (tie-break inside a rank).
	 */
	using TClassify = std::function<bool (const SEnemyData&, CCircuitDef*, int&, float&)>;
	// minValue: the best aim point must sum to at least this, else no target.
	// avoidFriendly: an aim point whose blast holds one of our own units is
	// rejected (damaging weapons: Perdition, Catalyst). EMP and Juno do no damage.
	bool SelectAreaTarget(CCircuitUnit* unit, CCircuitDef* cdef, const char* tag,
			float sqAoe, int minTargets, int mobileMaxAge, const TClassify& classify,
			float minValue = 0.f, bool avoidFriendly = false, bool allEnemies = false,
			bool pulseClaims = false, bool nuclearHistory = false);
	bool IsPulse(CCircuitDef* cdef) const;
	bool SelectNuclearTarget(CCircuitUnit* unit, CCircuitDef* cdef);
	bool SelectFogTarget(CCircuitUnit* unit, CCircuitDef* cdef);
	bool CanAimStrategic(CCircuitUnit* unit, const springai::AIFloat3& pos) const;
	// Tactical launchers (Perdition, Catalyst): the richest blast in range.
	bool SelectLauncherTarget(CCircuitUnit* unit, CCircuitDef* cdef, float minValue);
	// The metal a target must be worth for a stockpiled shot; decays while the
	// shot waits (CMilitaryManager::SStockInfo).
	float StockedShotFloor(CCircuitUnit* unit, CCircuitDef* cdef, int frame, float shotCost);
	// Juno: the highest-priority sensor/EW target in range.
	bool SelectPulseTarget(CCircuitUnit* unit, CCircuitDef* cdef);
	// Juno fallback: ground we cover with radar but read nothing from, which
	// is where a jammer that hides itself from radar has to be.
	bool SelectSuspectedJammer(CCircuitUnit* unit, CCircuitDef* cdef);
	// EMP: the most valuable target the shot can actually hold, structures first.
	bool SelectEmpTarget(CCircuitUnit* unit, CCircuitDef* cdef);
	// Tiered fire: the roster scan and the order; see SetTargetTier.
	void UpdateTiered(CCircuitUnit* unit);

	int targetFrame;
	int lastStock = -1;  // D-124: a nuke silo's stockpile at the last update: a drop is a launch
public:
	// D-124: where the silo aims: the attacked unit, else the aimed ground
	springai::AIFloat3 GetAimPos() const;
	static bool IsNukeSilo(CCircuitDef* cdef);
	// D-124: a launch seen (the weapon-fired event, or a stockpile drop): the
	// smiley over the aim, once per launch
	void OnLaunch(CCircuitUnit* unit, const char* how);
	int lastSmileyFrame = -1000000;
private:
	springai::AIFloat3 targetPos;
	bool isTargetOverride;
	int stockSinceFrame;  // first frame a shot has been waiting; -1 while the tube is empty
	int lastStrategicLaunch = -1000000;
	// Tiered fire. tierByDef: def id -> tier, set once per weapon by the script.
	std::unordered_map<int, int> tierByDef;
	int tierRetargetFrames = 60;      // a roster scan at most this often while a target lives
	int tierTargetId = -1;            // the enemy under fire, -1 none
	int tierOrderFrame = -1000000;    // the last attack order, re-issued before its timeout
	bool tierOrderOnUnit = false;     // that order was on the unit (else on its ground)
	int tierAreas = 0;                // area rotation: 0 off
	int tierDwellFrames = 0;
	int tierShotsPerArea = 0;
	float tierAreaRadius = 600.f;
	int tierLastShotFrame = -1000000;
	std::vector<tier::Area> tierAreaList;
	tier::Rotation tierRot;
};

} // namespace circuit

#endif // SRC_CIRCUIT_TASK_STATIC_SUPERTASK_H_
