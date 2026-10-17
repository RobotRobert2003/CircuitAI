/*
 * FerryTask.h
 *
 * Air transport ferry: carry one allied unit to a position and come home.
 *
 * A transport owns exactly one CFerryTask for its whole life. With no cargo
 * the task is a hold at `holdPos` - which is also what keeps a transport out
 * of the army, since ROLE_TYPE(TRANS) otherwise falls through to a Defend
 * task in CMilitaryManager::DefaultMakeTask. Script sets a cargo and a drop
 * position, the task sequences pick-up, flight and drop, and the transport
 * returns to `holdPos` on its own.
 *
 * Policy stays in script (Team::Ferry, data/script/src/manager/ferry.as):
 * which unit to carry, where to, and what to do once it lands. See
 * doc/transport-ferry.md.
 */

#ifndef SRC_CIRCUIT_TASK_FIGHTER_FERRYTASK_H_
#define SRC_CIRCUIT_TASK_FIGHTER_FERRYTASK_H_

#include "task/fighter/FighterTask.h"

namespace circuit {

class CFerryTask final: public IFighterTask {
public:
	/*
	 * DONE and FAILED are terminal and latched: script polls GetState(),
	 * acts once, and calls Reset() to return the transport to its hold.
	 * Nothing here retries by itself - a ferry that failed is a ferry whose
	 * caller should fall back to walking the unit.
	 */
	// DUMPING comes after FAILED so the script's state numbers keep: a failed
	// run whose cargo is still in the air first sets it down on the nearest
	// clear ground, then latches FAILED - script must never be handed a
	// constructor that is still inside the transport.
	enum class EState: char {IDLE = 0, TO_CARGO, LOADING, TO_DROP, UNLOADING, DONE, FAILED, DUMPING};

	CFerryTask(ITaskModule* mgr);
	virtual ~CFerryTask();

	virtual bool CanAssignTo(CCircuitUnit* unit) const override;
	virtual void RemoveAssignee(CCircuitUnit* unit) override;

	virtual void Start(CCircuitUnit* unit) override;
	virtual void Update() override;

	virtual void OnUnitIdle(CCircuitUnit* unit) override;
	// D-110: a run is never abandoned for a retreat (IFighterTask's default sends a
	// damaged unit with no target home)
	virtual void OnUnitDamaged(CCircuitUnit* unit, CEnemyInfo* attacker) override;
	bool IsAboard(CCircuitUnit* cargo, CCircuitUnit* transport, int frame) const;
	void ReportUnload(CCircuitUnit* transport, CCircuitUnit* cargo, int frame);  // D-110 diagnostic
	int reportedFrame = -1;
	float baseLift = -1.f;
	int loadDoneFrame = -1;  // D-112: the frame the engine finished the load command  // D-112: the cargo's height above ground when the load was issued (-1: not measured)
	bool InRun() const { return (state_ != EState::IDLE) && (state_ != EState::DONE) && (state_ != EState::FAILED); }

	// Script hooks
	void SetHoldPos(const springai::AIFloat3& pos);
	// Begin a run. Fails (returns false, state unchanged) when a run is
	// already in flight or the cargo id is not one of our units.
	bool SetCargo(int cargoId, const springai::AIFloat3& dropPos, float surfaceThreat = -1.f, float airThreat = -1.f);
	bool CanCarry(int cargoId) const;
    // Opt-in route mission. Old SetCargo callers retain direct ferry behavior.
    bool SetCargoRoute(int cargoId, const std::vector<springai::AIFloat3>& points,
        float surfaceThreat, float airThreat, float padding, float blockedSeconds = 90.f);
	int GetState() const { return int(state_); }
	int GetCargoId() const { return cargoId; }
	// Back to IDLE and home. Safe to call in any state; the cargo is released.
	void Reset();

private:
    bool BeginCargo(int id, const springai::AIFloat3& pos, float surfaceThreat, float airThreat);
	CCircuitUnit* GetTransport() const;
	CCircuitUnit* GetCargo() const;
	// Off the ground by more than FERRY_LIFT_HEIGHT: the only observable that
	// separates "carried" from "stood under the transport".
	bool IsLifted(CCircuitUnit* cargo, int frame) const;
	void GoTo(CCircuitUnit* unit, const springai::AIFloat3& pos);
    void FlyDrop(CCircuitUnit* unit);
    bool routed = false;
    float flightPadding = 0.f;
    std::vector<springai::AIFloat3> mission, flight;
    size_t missionIndex = 0, flightIndex = 0;
    springai::AIFloat3 flightGoal{-1.f, -1.f, -1.f};
    int flightRetry = -1;
    bool flightOrdered = false;
    int flightExpiry = -1;
    int flightBlockedFrame = -1; // diagnostic episode, cleared on a solved leg/new mission
    int flightBlockedTimeout = 90 * FRAMES_PER_SEC;
	// The engine refuses an unload onto occupied ground and says nothing; a
	// recipient's start position is its base. Ask the engine for the nearest
	// clear footprint for the cargo instead; `around` when it finds none.
	springai::AIFloat3 FindLandingSpot(CCircuitUnit* cargo, const springai::AIFloat3& around, float radius) const;
	// Park the cargo in a builder Wait so it stops taking build orders and
	// walking away from the pickup.
	void HoldCargo(CCircuitUnit* cargo);
	void Enter(EState next);
	bool IsExpired(int frame) const;
	void Fail(const char* why);

	EState state_;
	int cargoId;
    float maxSurfaceThreat = -1.f;
    float maxAirThreat = -1.f;
	springai::AIFloat3 dropPos;
	springai::AIFloat3 holdPos;
	int stateFrame;    // frame the current state was entered
	int loadRetries;
	int unloadRetries;
	int landedTicks = 0;  // consecutive updates the cargo was seen on the ground while unloading
	int missingUnloadTicks = 0; // empty carrier queue while cargo still follows it
	bool OnFactoryYard(CCircuitUnit* cargo, int frame);
	springai::AIFloat3 yardPos;
	int groundTicks = 0;  // D-091: consecutive updates the cargo was on the ground in flight to the drop
	std::vector<springai::AIFloat3> refusedDrops;  // D-091: landing spots the engine did not unload at
	springai::AIFloat3 landPos;  // where the unload was actually ordered
};

} // namespace circuit

#endif // SRC_CIRCUIT_TASK_FIGHTER_FERRYTASK_H_
