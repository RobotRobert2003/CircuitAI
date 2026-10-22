/*
 * RouteTask.h
 *
 * A fighter task that owns a waypoint route; patrol traversal is opt-in.
 * Script (Spam:: in data/script/src/manager/spam.as) creates one per factory
 * with TaskF::Route(), sets the route with SetRoute() and assigns every unit
 * that factory produces. Units follow the queued waypoints, hold at the end,
 * never retreat, and are re-issued the route whenever it changes. Definitions
 * with a configured standoff fraction temporarily pause for range-controlled
 * combat, then resume their route without changing task ownership.
 */

#ifndef SRC_CIRCUIT_TASK_FIGHTER_ROUTETASK_H_
#define SRC_CIRCUIT_TASK_FIGHTER_ROUTETASK_H_

#include "task/fighter/FighterTask.h"
#include "spring/RouteCommand.h"

#include <map>
#include <vector>

namespace circuit {

class CRouteTask final: public IFighterTask {
public:
	CRouteTask(ITaskModule* mgr);
	virtual ~CRouteTask();

	virtual bool CanAssignTo(CCircuitUnit* unit) const override;
	virtual void AssignTo(CCircuitUnit* unit) override;
	virtual void RemoveAssignee(CCircuitUnit* unit) override;

	virtual void Start(CCircuitUnit* unit) override;
	virtual void Update() override;

	virtual void OnUnitIdle(CCircuitUnit* unit) override;
	virtual void OnUnitDamaged(CCircuitUnit* unit, CEnemyInfo* attacker) override;

	// Script hooks
	void SetRoute(std::vector<springai::AIFloat3>&& waypoints);
    // AIR opts into exact final-route deduplication and transient ownership.
    void SetAirControl(bool enabled) { airControl = enabled; }
    // SEA opts into the same exact route lifetime/queue preservation, with
    // terrain-checked lane offsets. Defaults leave every other role unchanged.
    void SetSeaControl(bool enabled) { seaControl = enabled; }
    void SetMoveCompaction(bool enabled) {
        if (compactMoves != enabled) { compactMoves = enabled; ++version; dirty = !route.empty(); }
    }
    bool SetSeaTarget(int id); // Existing aircraft-only contract.
    bool SetNavalTarget(int id); // Opt-in water target, priority fire without pursuit.
    // D-296: opt-in ground priority target (BAR SET_TARGET, OPEN fire) for a
    // land route raider; not gated on SEA control. -1 cancels. Validated
    // against a live, legally observed, non-flying contact.
    bool SetLandTarget(int id);
    int GetPriorityTarget() const { return seaTarget; }
    void SetRepairThreshold(float value);
    // Task-scoped policy: never leaks a SEA firing-line choice to another role.
    void SetCombatRetreat(bool enabled) { combatRetreat = enabled; }
    void SetAirTarget(int id) { if (airControl && airTarget != id) { airTarget = id; ++version; dirty = true; } }
    bool SetUnitRoute(CCircuitUnit* unit, std::vector<springai::AIFloat3>&& waypoints, float radius);
	/*
	 * Per-unit lane spread. The route is one line; each unit assigned to the
	 * task is dealt a lane - 0, +1, -1, +2, -2 ... - and follows the line
	 * offset sideways by `spacing` per lane, so a stream of spam units crosses
	 * the map as a band rather than a single file that one shell erases and
	 * that sees only what one unit sees. `endSpread` scales the offset at the
	 * last waypoint (0 = every lane converges on the same endpoint, 1 = the
	 * band stays full width to the end); the point of the run is the same
	 * backline, so this is kept small. `count` 1 disables the spread.
	 */
	void SetLanes(int count, float spacing, float endSpread);
    void SetRowSpacing(float spacing); // opt-in rows; legacy routes use zero
	void SetTraversal(bool preserveWaypoints, float radius, bool fightAtEnd);
    void SetHoldPosition(bool enabled) { holdPosition = enabled; }
	// Opt-in looping engine patrol; ordinary routes retain their traversal.
	void SetPatrol(bool enabled) { patrol = enabled; dirty = !route.empty(); }
	int GetRouteVersion() const { return version; }
	unsigned int GetRouteSize() const { return route.size(); }
	bool IsAtEnd(CCircuitUnit* unit) const;

private:
	void IssueRoute(CCircuitUnit* unit, unsigned int fromIdx);
	// One move straight to the end of the route, lane waypoints skipped.
	void IssueDirect(CCircuitUnit* unit);
	unsigned int NearestAheadIndex(CCircuitUnit* unit) const;
	// The route point `idx` as seen from `unit`'s lane.
	springai::AIFloat3 LanePoint(CCircuitUnit* unit, unsigned int idx) const;
	int LaneOf(CCircuitUnit* unit) const;

	std::vector<springai::AIFloat3> route;
    std::map<CCircuitUnit*, std::vector<springai::AIFloat3>> unitRoutes;
    std::map<CCircuitUnit*, float> unitArrival;
    std::set<CCircuitUnit*> issuing;
    std::set<CCircuitUnit*> retryUnits;
    std::map<CCircuitUnit*, int> lastIssue;
    const std::vector<springai::AIFloat3>& RouteFor(CCircuitUnit* unit) const;
	std::map<CCircuitUnit*, int> lanes;   // unit -> signed lane index
	std::set<CCircuitUnit*> engaging;  // temporarily paused for configured range micro
	int laneCount;
	float laneSpacing;
    float rowSpacing = 0.f;
    std::map<CCircuitUnit*, unsigned int> rows;
    std::map<CCircuitUnit*, unsigned int> formationSlots;
    std::set<unsigned int> freeFormationSlots;
	float laneEndSpread;
	unsigned int laneDealt;               // round-robin counter
	int version;
	bool dirty;
	float arriveRadius;
	bool preserveWaypoints = false;
	bool fightAtEnd = false;
	bool patrol = false;
    bool holdPosition = false;
    bool airControl = false;
    bool seaControl = false;
    bool compactMoves = false; // policy opt-in; other roles keep their commands
    void CompactNavalPolyline(CCircuitUnit* unit, std::vector<springai::AIFloat3>& points) const;
    struct Dispatch {
        std::vector<routecommand::Command> commands;
        int version = -1, target = -1;
        bool hold = false, naval = false;
    };
    std::map<CCircuitUnit*, Dispatch> dispatches;
    struct IssueTrace { int frame=-1, count=0, reported=-30; };
    std::map<CCircuitUnit*, IssueTrace> issueTrace;
    void TraceIssue(CCircuitUnit* unit, unsigned int fromIndex, bool direct);
    bool ManagedControl() const { return airControl || seaControl; }
    bool hadAssignee = false;
    int airTarget = -1;
    int seaTarget = -1;
    bool navalTarget = false;
    bool landTarget = false; // D-296: seaTarget is a ground target (SetLandTarget)
    float repairThreshold = 0.f;
    bool combatRetreat = true;
    bool SetPriorityTarget(int id, bool naval);
    void IssuePriorityTarget(CCircuitUnit* unit, int id, bool naval, bool land = false);
    std::map<CCircuitUnit*, int> issuedVersion;
};

} // namespace circuit

#endif // SRC_CIRCUIT_TASK_FIGHTER_ROUTETASK_H_
