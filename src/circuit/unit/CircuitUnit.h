/*
 * CircuitUnit.h
 *
 *  Created on: Sep 2, 2014
 *      Author: rlcevg
 */

#ifndef SRC_CIRCUIT_UNIT_CIRCUITUNIT_H_
#define SRC_CIRCUIT_UNIT_CIRCUITUNIT_H_

#include "unit/ally/AllyUnit.h"
#include "unit/CircuitDef.h"
#include "util/ActionList.h"
#include "util/Defines.h"

namespace springai {
	class Command;
	class Weapon;
}

namespace terrain {
	struct SArea;
}

namespace circuit {

#define TRY_UNIT(c, u, x)	try { x } catch (const std::exception& e) { c->Garbage(u, e.what()); }

#define UNIT_CMD_OPTION				0

#define CMD_ATTACK_GROUND			20
#define CMD_RETREAT_ZONE			10001
#define CMD_ORBIT					13923
#define CMD_ORBIT_DRAW				13924
#define CMD_CLOAK_SHIELD			31101
#define CMD_RAW_MOVE				31109
#define CMD_MORPH_UPGRADE_INTERNAL	31207
#define CMD_UPGRADE_STOP			31208
#define CMD_MORPH					31210
#define CMD_MORPH_STOP				32210
#define CMD_FIND_PAD				33411
#define CMD_PRIORITY				34220
#define CMD_MISC_PRIORITY			34221
#define CMD_RETREAT					34223
#define CMD_UNIT_SET_TARGET			34923
#define CMD_UNIT_CANCEL_TARGET		34924
#define CMD_ONECLICK_WEAPON			35000
#define CMD_WANT_CLOAK				37382
#define CMD_DONT_FIRE_AT_RADAR		38372
#define CMD_JUMP					38521
#define CMD_AIR_MANUALFIRE			38571
#define CMD_WANTED_SPEED			38825
#define CMD_AIR_STRAFE				39381
#define CMD_TERRAFORM_INTERNAL		39801

// FIXME: BA
#define CMD_AUTOMEX				31143
#define CMD_BAR_PRIORITY		34571
#define CMD_LAND_AT_AIRBASE		35430
// FIXME: BA

class CEnemyInfo;
class CWeaponDef;
class ITaskModule;
class CDGunAction;
class ITravelAction;

class CCircuitUnit final: public CAllyUnit, public CActionList {
public:
	friend class CInitScript;

	enum class ETaskState: char {NONE = 0, ASSIGN, START, TRAVEL, EXECUTE, STOP};

	CCircuitUnit(const CCircuitUnit& that) = delete;
	CCircuitUnit& operator=(const CCircuitUnit&) = delete;
	CCircuitUnit(CCircuitAI* circuit, Id unitId, springai::Unit* unit, CCircuitDef* cdef);
	virtual ~CCircuitUnit();

	void SetTask(IUnitTask* task);
	void SetTaskFrame(int frame) { taskFrame = frame; }
	int GetTaskFrame() const { return taskFrame; }

    // Optional script-owned withdrawal waypoint. No engine order is emitted;
    // RetreatTask validates and consumes it before ordinary repair routing.
    // IDs avoid retaining a destroyed/transferred screen unit. Default is off.
    void SetRetreatWaypoint(const springai::AIFloat3& position, int anchor, int until) {
        retreatWaypoint = position; retreatAnchor = anchor; retreatWaypointUntil = until;
    }
    const springai::AIFloat3& GetRetreatWaypoint() const { return retreatWaypoint; }
    int GetRetreatAnchor() const { return retreatAnchor; }
    int GetRetreatWaypointUntil() const { return retreatWaypointUntil; }
    void ClearRetreatWaypoint() { retreatAnchor = -1; retreatWaypointUntil = -1; }
    // D-346: a script-nominated forward repair point (outside enemy reach plus
    // a buffer). While valid, a RETREAT task ends there and waits to be healed
    // instead of travelling to the base. Native code revalidates expiry,
    // reachability and threat on every retreat step.
    void SetRetreatHold(const springai::AIFloat3& position, int until) { retreatHold = position; retreatHoldUntil = until; }
    const springai::AIFloat3& GetRetreatHold() const { return retreatHold; }
    int GetRetreatHoldUntil() const { return retreatHoldUntil; }
    void ClearRetreatHold() { retreatHoldUntil = -1; }

	void SetManager(ITaskModule* mgr) { manager = mgr; }
	ITaskModule* GetManager() const { return manager; }

	void SetArea(terrain::SArea* area) { this->area = area; }
	terrain::SArea* GetArea() const { return area; }

	void ClearAct();
	void PushDGunAct(CDGunAction* action);
	CDGunAction* GetDGunAct() const { return dgunAct; }
	void PushTravelAct(ITravelAction* action);
	ITravelAction* GetTravelAct() const { return travelAct; }

	void SetIsFinished() { isFinished = true; }
	bool IsFinished() const { return isFinished; }
	int GetProducerId() const { return producerId; }
	int GetProductionFrame() const { return productionFrame; }
	bool IsProductionEnabled() const { return productionEnabled; }
	void SetProductionEnabled(bool value) { productionEnabled = value; }
	void SetProducerId(int value, int frame) { producerId = value; productionFrame = frame; }

	void SetAllowedToJump(bool value) { isAllowedToJump = value; }
	bool IsAllowedToJump() const { return isAllowedToJump; }

	bool IsMoveFailed(int frame);
	bool IsStuck() const { return isStuck; }

	void ForceUpdate(int frame);
	bool IsForceUpdate(int frame);

	void SetIsDead() { isDead = true; }
	bool IsDead() const { return isDead; }
    void MarkDestroying() { destroying = true; }
    bool IsDestroying() const { return destroying; }

	void SetDamagedFrame(int frame) { damagedFrame = frame; }
	int GetDamagedFrame() const { return damagedFrame; }

	bool HasDGun() const { return dgun != nullptr; }
	bool HasWeapon() const { return weapon != nullptr; }
	bool HasShield() const { return shield != nullptr; }
	void ManualFire(CEnemyInfo* target, int timeout);
	bool IsDGunHigh() const;
	bool IsDisarmed(int frame);
	bool IsWeaponReady(int frame);
	bool IsDGunReady(int frame, float energy);
    int GetDGunReloadFrame() const;
    int GetRequestedFireState() const { return requestedFire; }
    int GetRequestedMoveState() const { return requestedMove; }
	bool IsShieldCharged(float percent);
	bool IsJumpReady();
	bool IsJumping();
	bool IsInvisible();
	float GetDamage();
	float GetShieldPower();
	float GetBuildSpeed();
	float GetWorkerTime();
	float GetDGunRange();
	float GetHealthPercent();

	springai::Command* GetCurrentCommand() const { return command; }

	void CmdRemove(std::vector<float>&& params, short options = 0);
	void CmdMoveTo(const springai::AIFloat3& pos, short options = 0, int timeout = INT_MAX);
	void CmdJumpTo(const springai::AIFloat3& pos, short options = 0, int timeout = INT_MAX);
	void CmdFightTo(const springai::AIFloat3& pos, short options = 0, int timeout = INT_MAX);
	void CmdPatrolTo(const springai::AIFloat3& pos, short options = 0, int timeout = INT_MAX);
	void CmdAttackGround(const springai::AIFloat3& pos, short options = 0, int timeout = INT_MAX);
	void CmdWantedSpeed(float speed = NO_SPEED_LIMIT);
	void CmdStop(short options = 0, int timeout = INT_MAX);
	void CmdSetTarget(CEnemyInfo* enemy);
	void ClearPriorityTarget();
	// BAR SET_TARGET on behalf of a task. Held back, but remembered, while a
	// commander target owns the unit's priority list; restored on its release.
	void SendTaskTarget(int targetId);
	void CancelTaskTarget(int targetId);
	// Owner 2026-10-25 unit-count throttle (util/LagLoad.h). False drops the
	// order; orders in the same frame as the last accepted one always pass.
	bool LagAllowMove();
	bool LagAllowTarget();
	bool LagAllowTurret();
	bool LagIdleBuilder();
	// Commander snipe (D-352): a scouted enemy commander in range replaces the
	// priority list; the unit keeps its move and other orders. -1 releases.
	void SetCommanderTarget(int commId, int frame);
	int GetCommanderTarget() const { return commanderTarget; }
	// A task's ATTACK on anything but the locked commander is withheld.
	bool IsCommanderLocked(const CEnemyInfo* enemy) const;
	void CmdCloak(bool state, bool force = false);  // force: skip the same-state resend filter
	void CmdFireAtRadar(bool state);
	void CmdFindPad(int timeout = INT_MAX);
	void CmdManualFire(short options = 0, int timeout = INT_MAX);
	void CmdAirManualFire(const springai::AIFloat3& pos, short options = 0, int timeout = INT_MAX);
	void CmdPriority(float value);
	void CmdMiscPriority(float value);
	void CmdAirStrafe(float value);
	void CmdBARPriority(float value);
	void SetBuildPriorityOverride(int value);
	void CmdTerraform(std::vector<float>&& params);
	void CmdSelfD(bool state);
	bool IsInSelfD() const { return isSelfD; }
	void CmdWait(bool state);
	void RemoveWait();
	bool IsWaiting() const;
	// Cargo. The C++ wrapper has had these since the ABI gained them; nothing
	// wrapped them here, which is why CircuitDef.h notes transport as "not
	// implemented". Used by CFerryTask; see doc/transport-ferry.md.
	void CmdLoadUnits(const std::vector<CCircuitUnit*>& cargo, short options = 0, int timeout = INT_MAX);
	void CmdLoadUnitsInArea(const springai::AIFloat3& pos, float radius, short options = 0, int timeout = INT_MAX);
	void CmdUnloadUnit(const springai::AIFloat3& pos, CCircuitUnit* cargo, short options = 0, int timeout = INT_MAX);
	void CmdUnloadUnitsInArea(const springai::AIFloat3& pos, float radius, short options = 0, int timeout = INT_MAX);
	void CmdRepair(CAllyUnit* target, short options = 0, int timeout = INT_MAX);
	void CmdBuild(CCircuitDef* buildDef, const springai::AIFloat3& buildPos, int facing, short options = 0, int timeout = INT_MAX);
	void CmdReclaimEnemy(CEnemyInfo* enemy, short options = 0, int timeout = INT_MAX);
	void CmdReclaimUnit(CAllyUnit* toReclaim, short options = 0, int timeout = INT_MAX);
	void CmdReclaimInArea(const springai::AIFloat3& pos, float radius, short options = 0, int timeout = INT_MAX);
	void CmdResurrectInArea(const springai::AIFloat3& pos, float radius, short options = 0, int timeout = INT_MAX);
	void CmdSetFireState(CCircuitDef::FireT state);
	void TrySetFireState(CCircuitDef::FireT state);  // safe CmdSetFireState
    void TrySetIdleMode(int mode); // 0 fly, 1 land; aircraft only
	void CmdSetMoveState(CCircuitDef::MoveT state);
	void TrySetMoveState(CCircuitDef::MoveT state);  // safe CmdSetMoveState

	void Attack(CEnemyInfo* enemy, bool isGround, int timeout, bool queueFight = true);
	bool KeepWeaponRange(CEnemyInfo* enemy, int timeout);
	void Attack(const springai::AIFloat3& position, CEnemyInfo* enemy, bool isGround, bool isStatic, int timeout);
	void Attack(const springai::AIFloat3& position, CEnemyInfo* enemy, int tile, bool isGround, bool isStatic, int timeout);
	void Guard(CCircuitUnit* target, int timeout);
	void Gather(const springai::AIFloat3& groupPos, int timeout);

	void Morph();
	void StopMorph();
	bool IsUpgradable();
	void Upgrade();
	void StopUpgrade();
	bool IsMorphing() const { return isMorphing; }

	void SetTaskState(ETaskState value) { taskState = value; }
	ETaskState GetTaskState() const { return taskState; }

	Id GetUnitIdReclaim() const;

	void ClearTarget() { target = nullptr; }
	CEnemyInfo* GetTarget() const { return target; }
	int GetTargetTile() const { return targetTile; }

	// NOTE: Attributes are save-load unfriendly.
	//       Setter (script) is responsible for save/load attributes
	void AddAttribute(CCircuitDef::AttrType type) { attr |= CCircuitDef::GetMask(static_cast<CCircuitDef::AttrT>(type)); }
	void DelAttribute(CCircuitDef::AttrType type) { attr &= ~CCircuitDef::GetMask(static_cast<CCircuitDef::AttrT>(type)); }
	void TglAttribute(CCircuitDef::AttrType type) { attr ^= CCircuitDef::GetMask(static_cast<CCircuitDef::AttrT>(type)); }
	bool IsAttrAny(CCircuitDef::AttrM value) const { return (attr & value) != 0; }
	bool IsAttrSolo()      const { return attr & CCircuitDef::AttrMask::SOLO; }
	bool IsAttrBase()      const { return attr & CCircuitDef::AttrMask::BASE; }
	bool IsAttrNoRepair()  const { return attr & CCircuitDef::AttrMask::NO_REPAIR; }
	bool IsAttrNoDisrupt() const { return attr & CCircuitDef::AttrMask::NO_DISRUPT; }

private:
	int producerId = -1; // creation event only; persistent policy membership is script-owned
	int productionFrame = -1; // unknown on adopted units; never infer it from completion
	bool productionEnabled = true; // script-owned lifecycle admission; O(1) at command boundary
	// NOTE: taskFrame assigned on task change and OnUnitIdle to workaround idle spam.
	//       Proper fix: do not issue any commands OnUnitIdle, delay them until next frame?
	int taskFrame;
	ETaskState taskState;
	ITaskModule* manager;
	terrain::SArea* area;  // = nullptr if a unit flies

	CDGunAction* dgunAct;
    int requestedFire=CCircuitDef::FireType::OPEN, requestedMove=CCircuitDef::MoveType::MANEUVRE;
    // Owner 2026-10-24: the last fire/move/cloak state we actually sent, and
    // when. The same value is not resent within STATE_RESEND_FRAMES (commander
    // hand-overs resent all three every ~2 s, Darkside 2026-10-23).
    int sentFire=-1, sentMove=-1, sentCloak=-1;
    int sentFireFrame=-100000, sentMoveFrame=-100000, sentCloakFrame=-100000;
    bool RepeatState(int& sent, int& sentFrame, int value);
    int commMoveFrame=-100000; // owner 2026-10-24: last new commander MOVE
    int lagMoveFrame=-100000, lagTargetFrame=-100000, lagTurretFrame=-100000; // owner 2026-10-25
	ITravelAction* travelAct;

	int moveFails;
	int failFrame;
	int damagedFrame;
	int execFrame;  // TODO: Replace by CExecuteAction?
	int disarmFrame;
	int ammoFrame;

	float priority;
	float requestedPriority = -1.f;
	int buildPriorityOverride = -1;

	// ---- Bit fields ---- BEGIN
	bool isDead : 1;
	bool isStuck : 1;
	bool isFinished : 1;
	bool isDisarmed : 1;
	bool isWeaponReady : 1;
	bool isMorphing : 1;
	bool isSelfD : 1;
	bool isAllowedToJump : 1;
	// ---- Bit fields ---- END

	springai::Command* command;  // current top command
	CWeaponDef* dgunDef;
	springai::Weapon* dgun;
	springai::Weapon* weapon;  // main weapon
	springai::Weapon* shield;

	CEnemyInfo* target;
	int targetTile;
	int priorityTarget = -1; // ID only: never retain a dead enemy wrapper.
	int taskTarget = -1;      // last SET_TARGET a task asked for (any path)
	int commanderTarget = -1; // D-352 commander lock; owns BAR's priority list
	int commanderFrame = -1;  // frame the commander SET_TARGET was last sent
    bool destroying = false; // set before destruction callbacks; IsDead keeps its existing unregister semantics
    springai::AIFloat3 retreatWaypoint;
    int retreatAnchor = -1;
    int retreatWaypointUntil = -1;
    springai::AIFloat3 retreatHold;
    int retreatHoldUntil = -1;

	CCircuitDef::AttrM attr;

#ifdef DEBUG_VIS
public:
	void Log();
#endif
};

} // namespace circuit

#endif // SRC_CIRCUIT_UNIT_CIRCUITUNIT_H_
