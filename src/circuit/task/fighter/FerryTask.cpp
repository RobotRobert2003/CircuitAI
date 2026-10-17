/*
 * FerryTask.cpp
 *
 * See FerryTask.h.
 *
 * Every state carries a deadline. Transports in Spring fail to load for
 * reasons the AI cannot observe - capacity, unit mass, the cargo walking away
 * mid-approach - and there is no "am I carrying something" accessor in the C++
 * wrapper, so the load is verified positionally: a loaded unit's position
 * tracks its transport. Without deadlines a failed pick-up would hang the
 * transport for the rest of the game, which is strictly worse than the walk it
 * was meant to replace.
 */

#include "task/fighter/FerryTask.h"
#include "module/MilitaryManager.h"
#include "module/BuilderManager.h"
#include "task/builder/WaitTask.h"
#include "spring/SpringUnit.h"
#include "terrain/TerrainManager.h"
#include "terrain/BattleAnalysis.h"
#include "spring/SpringCallback.h"
#include "unit/CircuitUnit.h"
#include "unit/CircuitDef.h"
#include "unit/TransportUtils.h"
#include "CircuitAI.h"
#include "util/Utils.h"

#include "AISCommands.h"
#include "Sim/Units/CommandAI/Command.h"
#include "Command.h"
#include "UnitDef.h"
#include "Log.h"
#include "spring/SpringMap.h"

namespace circuit {

using namespace springai;

// Deadlines per state, in frames.
#define FERRY_TRAVEL_TIMEOUT	(FRAMES_PER_SEC * 90)
#define FERRY_LOAD_TIMEOUT		(FRAMES_PER_SEC * 20)
#define FERRY_UNLOAD_TIMEOUT	(FRAMES_PER_SEC * 45)  // D-110: an air transport descends and lands within this; 20 s cut every unload short
// A carried unit sits at the transport's own position in the horizontal
// plane - but so does a unit the transport is hovering over, about to load.
// 2D distance cannot tell those apart, and treating it as "loaded" made the
// task issue the flight to the drop one tick after issuing the load, which
// cancelled the load and flew the transport off empty (then reported a clean
// delivery, because the "landed" test was the same check inverted). What
// distinguishes the two is height: a loaded ground unit is lifted off the
// terrain, an unloaded one is on it. So the load and unload tests are on the
// cargo's height above ground, with the 2D proximity kept only as a sanity
// check on the load side.
#define FERRY_LOADED_DIST		(SQUARE_SIZE * 4)
// Any lift at all. An Atlas hovers low with its load until it is told to
// move; the old 24-elmo bar was never cleared, the load "did not take" and
// the cargo was given away hanging under the transport (D-056).
#define FERRY_LIFT_HEIGHT		(SQUARE_SIZE / 2)
#define FERRY_GROUND_TOLERANCE	1.f
#define FERRY_LANDED_TICKS		2
constexpr int FERRY_MISSING_UNLOAD_TICKS = 2;
#define FERRY_RISE				(SQUARE_SIZE * 2)  // D-112: aboard = risen this much above where the cargo stood
#define FERRY_RISE_GRACE		(FRAMES_PER_SEC * 4)  // D-112: time after the load for the cargo to rise
#define FERRY_UNLOAD_RADIUS		(SQUARE_SIZE * 32)  // D-110: the area unload's radius: the engine refuses an unload with no standing room for the cargo inside it (played: 96 at a teammate's start never found any)
// Close enough to the drop to issue the unload.
#define FERRY_DROP_DIST			(SQUARE_SIZE * 12)
// Recoil HoverAirMoveType::GetGoalRadius permits MOVE completion at 64 elmos.
// Advance intermediate points before that stop, using the same 96-elmo
// handoff as unloading. Every outgoing leg is still checked from the actual
// aircraft position; arrival tolerance never authorizes cutting an AA corner.
// Regression: run_heavy_front.py --mode turns --deliveries 2 (D-318).
constexpr float FERRY_WAYPOINT_DIST = FERRY_DROP_DIST;
#define FERRY_LOAD_RETRIES		2
#define FERRY_UNLOAD_RETRIES	2
// Landing-spot search around the drop; doubled per unload retry.
#define FERRY_LAND_SEARCH		(SQUARE_SIZE * 40)
// How long the cargo is parked once a run starts. Longer than any run: the
// script gives the unit away at the end of every path, which ends the wait.
// Longer than every state deadline of a run added up (travel 90 + 3 x load 20
// + travel 90 + 3 x unload 20 + dump 40 = 340 s) and renewed on each retry,
// so the cargo never takes build orders while the ferry still owns it (CR-024).
#define FERRY_HOLD_FRAMES		(FRAMES_PER_SEC * 600)

CFerryTask::CFerryTask(ITaskModule* mgr)
		: IFighterTask(mgr, FightType::FERRY, 1.f)
		, state_(EState::IDLE)
		, cargoId(-1)
		, dropPos(-RgtVector)
		, holdPos(-RgtVector)
		, stateFrame(0)
		, loadRetries(0)
		, unloadRetries(0)
		, landPos(-RgtVector)
{
}

CFerryTask::~CFerryTask()
{
}

bool CFerryTask::CanAssignTo(CCircuitUnit* unit) const
{
	// One transport per task: the sequence below tracks a single carrier.
	return units.empty() && (unit->GetCircuitDef() != nullptr) && unit->GetCircuitDef()->IsRoleTrans();
}

void CFerryTask::RemoveAssignee(CCircuitUnit* unit)
{
	IFighterTask::RemoveAssignee(unit);
	if (units.empty()) {
		// The transport died. Latch FAILED so script stops waiting on a run
		// that can no longer finish and falls back to walking the cargo.
		if ((state_ != EState::IDLE) && (state_ != EState::DONE)) {
			state_ = EState::FAILED;
		}
		manager->AbortTask(this);
	}
}

CCircuitUnit* CFerryTask::GetTransport() const
{
	return units.empty() ? nullptr : *units.begin();
}

CCircuitUnit* CFerryTask::GetCargo() const
{
	return (cargoId < 0) ? nullptr : manager->GetCircuit()->GetTeamUnit(cargoId);
}

bool CFerryTask::IsLifted(CCircuitUnit* cargo, int frame) const
{
	CCircuitAI* circuit = manager->GetCircuit();
	const AIFloat3& pos = cargo->GetPos(frame);
	const float ground = circuit->GetMap()->GetElevationAt(pos.x, pos.z);
	return (pos.y - ground) > FERRY_LIFT_HEIGHT;
}

// D-110 (played: a constructor standing on a raised factory pad read as lifted;
// the transport flew off empty, the unload never took and the run sat in
// DUMPING for the rest of the game, every queued run behind it): aboard means
// lifted AND under the transport in 2D. A unit left on a pad is left behind the
// moment the transport moves, so "following" is the test that cannot be fooled.
bool CFerryTask::IsAboard(CCircuitUnit* cargo, CCircuitUnit* transport, int frame) const
{
	if ((cargo == nullptr) || (transport == nullptr) || !IsLifted(cargo, frame)) {
		return false;
	}
	// D-112 (the owner's game: a gift constructor standing on a raised pad read as
	// aboard; the transport flew off with another unit and the gift was handed
	// over at base): the cargo must have risen from where it stood before the load
	const AIFloat3& cp = cargo->GetPos(frame);
	const float above = cp.y - manager->GetCircuit()->GetMap()->GetElevationAt(cp.x, cp.z);
	if ((baseLift >= 0.f) && (above < baseLift + FERRY_RISE)) {
		return false;
	}
	return cp.SqDistance2D(transport->GetPos(frame)) < SQUARE(FERRY_LOADED_DIST);
}

// D-110 diagnostic (played: every unload refused while the cargo was aboard):
// once per order, 2 s after it, what the transport is doing and where
void CFerryTask::ReportUnload(CCircuitUnit* transport, CCircuitUnit* cargo, int frame)
{
	// every 5 s of the state (was once): whether the transport descends, and
	// when its unload command goes and what replaces it
	if ((transport == nullptr) || (frame - reportedFrame < FRAMES_PER_SEC * 5) || (frame - stateFrame < FRAMES_PER_SEC * 2)) {
		return;
	}
	reportedFrame = frame;
	CCircuitAI* circuit = manager->GetCircuit();
	const AIFloat3& tp = transport->GetPos(frame);
	const float tAbove = tp.y - circuit->GetMap()->GetElevationAt(tp.x, tp.z);
	const int cmd = transport->GetCurrentCommand()->GetId();
	const int queue = circuit->GetUnitAPI()->GetCMDQueueSize(transport->GetId());
	circuit->LOG("FERRY: unload check | cargo=%i state=%i %is in, transport cmd=%i queue=%i (unload units=%i) at (%.0f, %.0f) %.0f above ground, %.0f from the spot (%.0f, %.0f); cargo aboard=%i",
			cargoId, int(state_), (frame - stateFrame) / FRAMES_PER_SEC, cmd, queue, CMD_UNLOAD_UNITS, tp.x, tp.z, tAbove, std::sqrt(tp.SqDistance2D(landPos)), landPos.x, landPos.z,
			(cargo != nullptr) && IsAboard(cargo, transport, frame) ? 1 : 0);
}

void CFerryTask::OnUnitDamaged(CCircuitUnit* unit, CEnemyInfo* attacker)
{
	if (InRun()) {
		return;  // D-110: the drop-off first
	}
	IFighterTask::OnUnitDamaged(unit, attacker);
}

void CFerryTask::Enter(EState next)
{
	state_ = next;
	stateFrame = manager->GetCircuit()->GetLastFrame();
	missingUnloadTicks = 0;
    landedTicks = 0;
}

bool CFerryTask::IsExpired(int frame) const
{
	int limit;
	switch (state_) {
		case EState::LOADING:	limit = FERRY_LOAD_TIMEOUT;		break;
		case EState::UNLOADING:	limit = FERRY_UNLOAD_TIMEOUT;	break;
		case EState::DUMPING:	limit = FERRY_UNLOAD_TIMEOUT * 2;	break;
		default:				limit = FERRY_TRAVEL_TIMEOUT;	break;
	}
	return (frame - stateFrame) > limit;
}

AIFloat3 CFerryTask::FindLandingSpot(CCircuitUnit* cargo, const AIFloat3& around, float radius) const
{
	CCircuitAI* circuit = manager->GetCircuit();
	if ((cargo == nullptr) || (cargo->GetCircuitDef()->GetDef() == nullptr)) {
		return around;
	}
	// D-091: FindClosestBuildSite with a mobile def ignored the buildings and
	// water around an ally's start and returned the same refused spot on every
	// retry (played: `dump retry 9 ... at (11488, 4720)`). Our search: the
	// cargo's move type reaches it, no structure covers it, and never a spot
	// the engine already refused.
	const AIFloat3 spot = circuit->GetTerrainManager()->FindDropSpot(cargo, around, radius, refusedDrops, SQUARE_SIZE * 8, maxSurfaceThreat, maxAirThreat);
	if (geom::is_valid(spot)) {
		return spot;
	}
	circuit->LOG("FERRY: no standing room for cargo %i within %.0f of (%.0f, %.0f)", cargoId, radius, around.x, around.z);
	if (maxSurfaceThreat >= 0.f || maxAirThreat >= 0.f) return -RgtVector;
	return around;
}

// D-091: the cargo stands on a factory's footprint (just rolled out, or parked
// there by HoldCargo's stop). yardPos is that factory's position.
bool CFerryTask::OnFactoryYard(CCircuitUnit* cargo, int frame)
{
	CCircuitAI* circuit = manager->GetCircuit();
	const AIFloat3& p = cargo->GetPos(frame);
	for (int id : circuit->GetCallback()->GetFriendlyUnitIdsIn(p, SQUARE_SIZE * 12, false)) {
		CCircuitUnit* u = circuit->GetTeamUnit(id);
		if ((u == nullptr) || (u == cargo) || u->GetCircuitDef()->IsMobile() || !u->GetCircuitDef()->IsBuilder()) {
			continue;
		}
		const AIFloat3& f = u->GetPos(frame);
		const float hx = u->GetCircuitDef()->GetDef()->GetXSize() * SQUARE_SIZE * 0.5f;
		const float hz = u->GetCircuitDef()->GetDef()->GetZSize() * SQUARE_SIZE * 0.5f;
		if ((std::fabs(p.x - f.x) <= hx) && (std::fabs(p.z - f.z) <= hz)) {
			yardPos = f;
			return true;
		}
	}
	return false;
}

void CFerryTask::HoldCargo(CCircuitUnit* cargo)
{
	CCircuitAI* circuit = manager->GetCircuit();
	CBuilderManager* builderMgr = circuit->GetBuilderManager();
	if (cargo != nullptr && cargo->GetManager() == circuit->GetMilitaryManager()) {
        auto* transport = GetTransport();
        if (transport == nullptr) return;
        auto* military = circuit->GetMilitaryManager();
        military->AssignTask(cargo, military->EnqueueCargoHold(transport->GetId()));
        TRY_UNIT(circuit, cargo, cargo->CmdStop();)
        return;
    }
	if ((cargo == nullptr) || (cargo->GetManager() != builderMgr)) {
		return;
	}
	IUnitTask* wait = builderMgr->Enqueue(TaskB::Wait(FERRY_HOLD_FRAMES));
	if (wait != nullptr) {
		CBWaitTask* hold = dynamic_cast<CBWaitTask*>(wait);
		if (hold != nullptr) {
			hold->SetHold(true);  // D-110: no retreat while the ferry owns it
		}
		builderMgr->AssignTask(cargo, wait);
	}
	TRY_UNIT(circuit, cargo,
		cargo->CmdStop();
	)
}

void CFerryTask::Fail(const char* why)
{
	CCircuitAI* circuit = manager->GetCircuit();
	const int frame = circuit->GetLastFrame();
	CCircuitUnit* transport = GetTransport();
	CCircuitUnit* cargo = GetCargo();
	// Still carrying it: set it down first. Giving a unit away while it hangs
	// under our transport is what the "transferred without delivery" report
	// was - the recipient owned a constructor it could not use and we kept
	// flying it around.
	if ((state_ != EState::DUMPING) && (transport != nullptr) && (cargo != nullptr) && IsAboard(cargo, transport, frame)) {
		landPos = FindLandingSpot(cargo, transport->GetPos(frame), FERRY_LAND_SEARCH * 3);
		if (!geom::is_valid(landPos)) landPos = FindLandingSpot(cargo, holdPos, FERRY_LAND_SEARCH * 3);
		if (!geom::is_valid(landPos)) { Enter(EState::DUMPING); GoTo(transport, holdPos); return; }
        if (routed) {
            circuit->LOG("FERRY: routed run failed (%s) | cargo=%i; safe recovery",why,cargoId);
            Enter(EState::DUMPING);
            GoTo(transport,landPos);
            return;
        }
		circuit->LOG("FERRY: run failed (%s) | cargo=%i state=%i; setting it down at (%.0f, %.0f)",
				why, cargoId, int(state_), landPos.x, landPos.z);
		TRY_UNIT(circuit, transport,
			transport->CmdUnloadUnitsInArea(landPos, FERRY_UNLOAD_RADIUS, 0, frame + FERRY_UNLOAD_TIMEOUT * 2);  // D-110
		)
		Enter(EState::DUMPING);
		return;
	}
	circuit->LOG("FERRY: run failed (%s) | cargo=%i state=%i", why, cargoId, int(state_));
	cargoId = -1;
	Enter(EState::FAILED);
	if ((transport != nullptr) && geom::is_valid(holdPos)) {
		GoTo(transport, holdPos);
	}
}

void CFerryTask::GoTo(CCircuitUnit* unit, const AIFloat3& pos)
{
	CCircuitAI* circuit = manager->GetCircuit();
    if (routed) {
        const int frame = circuit->GetLastFrame();
        auto* battle = circuit->GetBattle();
        const auto& here = unit->GetPos(frame);
        // Both an unsolved path and a newly unsafe corner consume the same
        // bounded recovery budget. This closure owns no heap state or cache.
        const auto blocked = [&]() {
            if (flightBlockedFrame<0) {
                flightBlockedFrame=frame;
                circuit->LOG("FERRY: route blocked | cargo=%i state=%i from=(%.0f, %.0f) goal=(%.0f, %.0f) origin-covered=%i",
                    cargoId,int(state_),here.x,here.z,pos.x,pos.z,
                    battle->AirThreatAlong(here,here,flightPadding)>maxAirThreat);
            }
            // Script chooses the wait; a covered origin needs KI-632's
            // separate escape rule. Recovery retains the cargo until unload.
            if (state_==EState::TO_DROP && frame-flightBlockedFrame>=flightBlockedTimeout
                && battle->AirThreatAlong(here,here,flightPadding)<=maxAirThreat) {
                Fail("blocked flight corridor"); return;
            }
            if (circuit->GetUnitAPI()->GetCMDQueueSize(unit->GetId())>0) unit->CmdStop();
        };
        const bool changed = flightGoal.SqDistance2D(pos) > SQUARE(16.f);
        if (changed) { flight.clear(); flightIndex=0; flightOrdered=false; flightRetry=-1; }
        // O(reached points), amortized over this owned route; no unit census or
        // extra scheduler. Adjacent reached points cannot consume extra ticks.
        while (!flight.empty() && flightIndex+1 < flight.size()
            && here.SqDistance2D(flight[flightIndex]) < SQUARE(FERRY_WAYPOINT_DIST)) {
            ++flightIndex; flightOrdered=false;
            if (state_==EState::TO_DROP) stateFrame=frame;
        }
        const bool unsafe = !flight.empty() && battle->AirThreatAlong(here,flight[flightIndex],flightPadding)>maxAirThreat;
        if (unsafe) { flight.clear(); flightOrdered=false; flightRetry=-1; }
        if (flight.empty()) {
            if (frame < flightRetry) return;
            flightRetry=frame+FRAMES_PER_SEC; // retry failed geometry, never delay live threat checks
            flight=battle->SafeAirRoute(here,pos,maxAirThreat,flightPadding);
            flightGoal=pos; flightIndex=0;
            if (flight.empty()) {
                // Cancel a now-unsafe live MOVE before waiting for a clear path.
                blocked(); return;
            }
            // A solve can start with an adjacent grid corner already reached.
            // Do not credit that as flight progress or restart its deadline.
            while (flightIndex+1<flight.size()
                && here.SqDistance2D(flight[flightIndex])<SQUARE(FERRY_WAYPOINT_DIST)) ++flightIndex;
            if (battle->AirThreatAlong(here,flight[flightIndex],flightPadding)>maxAirThreat) {
                flight.clear(); flightOrdered=false;
                blocked(); return;
            }
            if (flightBlockedFrame>=0) {
                circuit->LOG("FERRY: route resumed | cargo=%i blocked-frames=%i",cargoId,frame-flightBlockedFrame);
                flightBlockedFrame=-1;
            }
        }
        if (flightIndex+1<flight.size() && here.SqDistance2D(flight[flightIndex])<SQUARE(64.f)) {
            circuit->LOG("[INVARIANT] INV-224 cargo=%i intermediate flight point is already within engine MOVE completion radius",cargoId);
        }
        // Only retain this task's own live movement. Empty/interrupted queues
        // recover, and a new waypoint/AA publication is checked on every update.
        auto* command=unit->GetCurrentCommand();
        if (flightOrdered && unit->GetTask()==this && command->GetId()==CMD_MOVE
            && command->GetOptions()==0 && command->GetTimeOut()==flightExpiry && flightExpiry>frame
            && circuit->GetUnitAPI()->GetCMDQueueSize(unit->GetId())==1) {
            const auto params=command->GetParams();
            if (params.size()==3 && params[0]==flight[flightIndex].x
                && params[1]==flight[flightIndex].y && params[2]==flight[flightIndex].z) return;
        }
        flightExpiry=frame+FERRY_TRAVEL_TIMEOUT;
        TRY_UNIT(circuit,unit,
            unit->CmdMoveTo(flight[flightIndex],0,flightExpiry);
        )
        flightOrdered=true;
        return;
    }
	TRY_UNIT(circuit, unit,
		unit->CmdMoveTo(pos, 0, circuit->GetLastFrame() + FERRY_TRAVEL_TIMEOUT);
	)
}

void CFerryTask::FlyDrop(CCircuitUnit* unit)
{
    if (!routed || mission.empty()) { GoTo(unit,dropPos); return; }
    while (missionIndex+1<mission.size() && manager->GetCircuit()->GetBattle()
        ->AirThreatAlong(mission[missionIndex],mission[missionIndex],flightPadding)>maxAirThreat) ++missionIndex;
    while (missionIndex+1<mission.size() && unit->GetPos(manager->GetCircuit()->GetLastFrame())
        .SqDistance2D(mission[missionIndex])<SQUARE(FERRY_WAYPOINT_DIST)) {
        ++missionIndex;
        stateFrame=manager->GetCircuit()->GetLastFrame(); // progress on a long route
    }
    GoTo(unit,mission[missionIndex]);
}

bool CFerryTask::SetCargoRoute(int id, const std::vector<AIFloat3>& points,
        float surfaceThreat, float airThreat, float padding, float blockedSeconds)
{
    if (InRun() || points.empty() || points.size()>32 || !std::isfinite(padding)
        || padding<0.f || padding>512.f || !std::isfinite(surfaceThreat)
        || !std::isfinite(airThreat) || airThreat<0.f || airThreat>=1.f
        || !std::isfinite(blockedSeconds) || blockedSeconds<1.f || blockedSeconds>90.f) return false;
    for (const auto& point:points) {
        if (!std::isfinite(point.x) || !std::isfinite(point.y) || !std::isfinite(point.z)
            || point.x<0.f || point.z<0.f || point.x>=CTerrainManager::GetTerrainWidth()
            || point.z>=CTerrainManager::GetTerrainHeight()) return false;
    }
    auto* cargo=manager->GetCircuit()->GetTeamUnit(id);
    auto* aircraft=GetTransport();
    if (cargo==nullptr || aircraft==nullptr || !CanCarry(id)) return false;
    auto* battle=manager->GetCircuit()->GetBattle();
    auto previous=aircraft->GetPos(manager->GetCircuit()->GetLastFrame());
    const auto pickup=cargo->GetPos(manager->GetCircuit()->GetLastFrame());
    if (battle->SafeAirRoute(previous,pickup,airThreat,padding).empty()) return false;
    previous=pickup;
    std::vector<AIFloat3> accepted;
    for (size_t i=0;i<points.size();++i) {
        const auto& point=points[i];
        // An AA emplacement on a lane bend must not make that exact point a
        // compulsory stop. Preserve safe lane anchors; detour to the next one.
        if (i+1<points.size() && battle->AirThreatAlong(point,point,padding)>airThreat) continue;
        if (battle->SafeAirRoute(previous,point,airThreat,padding).empty()) return false;
        accepted.push_back(point);
        previous=point;
    }
    // Validate the complete mission before acquiring/holding the cargo.
    routed=true; flightPadding=padding; mission=std::move(accepted); missionIndex=0;
    flightBlockedTimeout=int(blockedSeconds*FRAMES_PER_SEC);
    flight.clear(); flightRetry=-1; flightOrdered=false; flightBlockedFrame=-1;
    return BeginCargo(id,points.back(),surfaceThreat,airThreat);
}

void CFerryTask::SetHoldPos(const AIFloat3& pos)
{
	holdPos = pos;
	if (state_ == EState::IDLE) {
		CCircuitUnit* transport = GetTransport();
		if ((transport != nullptr) && geom::is_valid(holdPos)) {
			GoTo(transport, holdPos);
		}
	}
}

bool CFerryTask::CanCarry(int id) const
{
    auto* cargo = manager->GetCircuit()->GetTeamUnit(id);
    auto* transport = GetTransport();
    if (cargo == nullptr || transport == nullptr || cargo == transport || cargo->GetUnit()->IsBeingBuilt()) return false;
    auto* task = cargo->GetTask();
    if (task != nullptr && (task->GetType() == IUnitTask::Type::PLAYER || task->IsExternalControlled())) return false;
    auto* load = cargo->GetCircuitDef()->GetDef();
    auto* carrier = transport->GetCircuitDef()->GetDef();
    // Definition-level preflight, once per dispatch. Recoil uses footprint
    // scale 2 for transport size. Lua restrictions and dynamic mass can still
    // refuse loading; the existing load deadline is the authoritative fallback.
    return transport::CanCarry(carrier, load);
}

bool CFerryTask::SetCargo(int id, const AIFloat3& pos, float surfaceThreat, float airThreat)
{
    if (InRun() || manager->GetCircuit()->GetTeamUnit(id)==nullptr || !geom::is_valid(pos) || !CanCarry(id)) return false;
    routed=false; mission.clear(); flight.clear(); flightOrdered=false;
    return BeginCargo(id,pos,surfaceThreat,airThreat);
}

bool CFerryTask::BeginCargo(int id, const AIFloat3& pos, float surfaceThreat, float airThreat)
{
	if ((state_ != EState::IDLE) && (state_ != EState::DONE) && (state_ != EState::FAILED)) {
		return false;  // a run is already in flight
	}
	CCircuitUnit* cargo = manager->GetCircuit()->GetTeamUnit(id);
	if ((cargo == nullptr) || !geom::is_valid(pos) || !CanCarry(id)) {
		return false;
	}
	cargoId = id;
	maxSurfaceThreat = surfaceThreat;
	maxAirThreat = airThreat;
	dropPos = pos;
	landPos = -RgtVector;
	baseLift = -1.f;  // D-112: measured when the load is issued
	loadDoneFrame = -1;
	loadRetries = 0;
	unloadRetries = 0;
	landedTicks = 0;
	groundTicks = 0;
	refusedDrops.clear();
	Enter(EState::TO_CARGO);
	HoldCargo(cargo);
	CCircuitUnit* transport = GetTransport();
	if (transport != nullptr) {
		GoTo(transport, cargo->GetPos(manager->GetCircuit()->GetLastFrame()));
	}
	return true;
}

void CFerryTask::Reset()
{
    if (routed && InRun() && GetTransport()!=nullptr && GetCargo()!=nullptr
        && IsAboard(GetCargo(),GetTransport(),manager->GetCircuit()->GetLastFrame())) {
        Fail("reset requested while carrying");
        return;
    }
	cargoId = -1;
	landPos = -RgtVector;
	unloadRetries = 0;
	baseLift = -1.f;
	loadDoneFrame = -1;
	Enter(EState::IDLE);
	CCircuitUnit* transport = GetTransport();
	if ((transport != nullptr) && geom::is_valid(holdPos)) {
		GoTo(transport, holdPos);
		// D-112: a unit still aboard (a failed run, a wrong load) is set down at
		// home, never carried off; an empty transport finishes this at once
		if (!routed) TRY_UNIT(manager->GetCircuit(), transport,
			transport->CmdUnloadUnitsInArea(holdPos, FERRY_UNLOAD_RADIUS, UNIT_COMMAND_OPTION_SHIFT_KEY, manager->GetCircuit()->GetLastFrame() + FERRY_TRAVEL_TIMEOUT * 2);
		)
	}
}

void CFerryTask::Start(CCircuitUnit* unit)
{
	if (geom::is_valid(holdPos)) {
		GoTo(unit, holdPos);
	}
}

void CFerryTask::OnUnitIdle(CCircuitUnit* unit)
{
	// Update() re-issues whatever the current state needs; going idle mid-run
	// is normal (a move order completes before the state advances).
}

void CFerryTask::Update()
{
	CCircuitAI* circuit = manager->GetCircuit();
	const int frame = circuit->GetLastFrame();
	CCircuitUnit* transport = GetTransport();
	if (transport == nullptr) {
		return;
	}

    if (routed && (state_==EState::IDLE || state_==EState::DONE || state_==EState::FAILED)
        && geom::is_valid(holdPos) && transport->GetPos(frame).SqDistance2D(holdPos)>SQUARE(64.f)) {
        GoTo(transport,holdPos);
    }

	switch (state_) {
		case EState::IDLE:
		case EState::DONE:
		case EState::FAILED: {
			return;  // waiting on script
		} break;

		case EState::TO_CARGO: {
			CCircuitUnit* cargo = GetCargo();
			if (cargo == nullptr) {
				Fail("cargo gone");
				return;
			}
			const AIFloat3& cPos = cargo->GetPos(frame);
			// D-091: a unit still being built, or still on its factory's yard, cannot
			// be loaded (played: the transport hovered at the lab trying to lift a
			// constructor that was not out yet); the transport waits beside it and the
			// cargo is walked off the yard first
			if (cargo->GetUnit()->IsBeingBuilt()) {
				stateFrame = frame;  // waiting on the factory is not a failure to reach
				GoTo(transport, cPos);
				return;
			}
			if (OnFactoryYard(cargo, frame)) {
				stateFrame = frame;
				float dx = cPos.x - yardPos.x, dz = cPos.z - yardPos.z;
				const float len = std::sqrt(dx * dx + dz * dz);
				if (len < 1.f) { dx = 0.f; dz = 1.f; } else { dx /= len; dz /= len; }
				const AIFloat3 away(cPos.x + dx * 160.f, cPos.y, cPos.z + dz * 160.f);
				const AIFloat3 out = circuit->GetTerrainManager()->FindDropSpot(cargo, away, 240.f, {}, 0.f);
				if (geom::is_valid(out) && circuit->GetTerrainManager()->CanMoveToPos(cargo->GetArea(), out)) {
					TRY_UNIT(circuit, cargo,
						cargo->CmdMoveTo(out, 0, frame + FRAMES_PER_SEC * 20);
					)
				}
				GoTo(transport, cPos);
				return;
			}
			if (transport->GetPos(frame).SqDistance2D(cPos) < SQUARE(FERRY_DROP_DIST)) {
				// D-091: only the load; the flight to the drop is ordered once the
				// cargo is seen lifted (played: a load the engine refused left the queued
				// move to fly the transport off empty)
				// D-112: where it stands now, so "aboard" means it rose from here
				baseLift = cPos.y - circuit->GetMap()->GetElevationAt(cPos.x, cPos.z);
				TRY_UNIT(circuit, transport,
					transport->CmdLoadUnits({cargo}, 0, frame + FERRY_LOAD_TIMEOUT);
				)
				Enter(EState::LOADING);
			} else if (IsExpired(frame)) {
				Fail("could not reach cargo");
			} else {
				GoTo(transport, cPos);  // the cargo may have moved
			}
		} break;

		case EState::LOADING: {
			CCircuitUnit* cargo = GetCargo();
			if (cargo == nullptr) {
				Fail("cargo gone while loading");
				return;
			}
			// D-110 (played: no delivery in any run; the cargo on a raised pad read
			// as lifted under the hovering transport, the flight order replaced
			// the load and the transport left empty): leave only once the engine
			// has finished the load command AND the cargo is aboard (lifted and
			// under the transport); a finished load without it aboard is a retry
			const bool loadPending = (frame - stateFrame < FRAMES_PER_SEC * 2)
				|| (transport->GetCurrentCommand()->GetId() == CMD_LOAD_UNITS);
			// D-112: the load command ends while the transport is still low; the
			// cargo rises as it climbs, so a finished load gets FERRY_RISE_GRACE to
			// show the cargo aboard before it counts as a failed load (played: every
			// run needed a retry, one gift failed three runs in a row)
			if (loadPending) {
				loadDoneFrame = -1;
			} else if (loadDoneFrame < 0) {
				loadDoneFrame = frame;
				// the load ended with the cargo under the transport: set off, so the
				// climb shows whether it is aboard (a loaded transport hovers low until
				// ordered); the load itself is over, so this order cannot cut it short
				if (cargo->GetPos(frame).SqDistance2D(transport->GetPos(frame)) < SQUARE(FERRY_LOADED_DIST)) {
					FlyDrop(transport);
				}
			}
			const bool inGrace = !loadPending && (frame - loadDoneFrame < FERRY_RISE_GRACE);
			if (!loadPending && IsAboard(cargo, transport, frame)) {
				circuit->LOG("FERRY: cargo %i aboard; flying to (%.0f, %.0f)", cargoId, dropPos.x, dropPos.z);
				loadDoneFrame = -1;
				Enter(EState::TO_DROP);
				FlyDrop(transport);
			} else if (inGrace && !IsExpired(frame)) {
				// waiting for the rise
			} else if (!loadPending || IsExpired(frame)) {
				loadDoneFrame = -1;
				if (++loadRetries > FERRY_LOAD_RETRIES) {
					Fail("load did not take");
				} else {
					circuit->LOG("FERRY: load retry %i for cargo %i (%s)", loadRetries, cargoId, loadPending ? "timed out" : "the load ended without it aboard");
					HoldCargo(cargo);  // renew the park (CR-024)
					Enter(EState::TO_CARGO);
				}
			}
		} break;

		case EState::TO_DROP: {
			if (GetCargo() == nullptr) {
				Fail("cargo lost in flight");
				return;
			}
			// D-091: never fly on without it: the cargo on the ground for two updates
			// means the load did not hold; back to it and load again
			if (unloadRetries == 0) {
				groundTicks = IsAboard(GetCargo(), transport, frame) ? 0 : (groundTicks + 1);   // D-110: following, not just lifted
				if (groundTicks >= 2) {
					groundTicks = 0;
					if (++loadRetries > FERRY_LOAD_RETRIES) {
						Fail("cargo not carried");
						return;
					}
					circuit->LOG("FERRY: cargo %i is not aboard; back to load it (retry %i)", cargoId, loadRetries);
					Enter(EState::TO_CARGO);
					GoTo(transport, GetCargo()->GetPos(frame));
					return;
				}
			}
			if (routed) {
                FlyDrop(transport);
                if (state_!=EState::TO_DROP) return; // blocked-route recovery now owns it
            }
			if ((!routed || missionIndex+1 >= mission.size()) && transport->GetPos(frame).SqDistance2D(dropPos) < SQUARE(FERRY_DROP_DIST)) {
				CCircuitUnit* cargo = GetCargo();
				if (!geom::is_valid(landPos)) {
					landPos = FindLandingSpot(cargo, dropPos, routed ? 64.f : FERRY_LAND_SEARCH);
					if (!geom::is_valid(landPos)) { Fail("no safe landing ground"); return; }
					if (landPos.SqDistance2D(dropPos) > SQUARE(SQUARE_SIZE * 2)) {
						circuit->LOG("FERRY: drop (%.0f, %.0f) is occupied; landing cargo %i at (%.0f, %.0f)",
								dropPos.x, dropPos.z, cargoId, landPos.x, landPos.z);
					}
				}
				// D-110: the area unload (what a player's unload order is): the engine
				// finds the room within the radius, where the exact spot often failed
				if (routed && circuit->GetBattle()->AirThreatAlong(transport->GetPos(frame),landPos,flightPadding)>maxAirThreat) {
                    Fail("landing approach became unsafe"); return;
                }
				TRY_UNIT(circuit, transport,
					transport->CmdUnloadUnitsInArea(landPos, routed ? 64.f : FERRY_UNLOAD_RADIUS, 0, frame + FERRY_UNLOAD_TIMEOUT);
				)
				Enter(EState::UNLOADING);
			} else if (IsExpired(frame)) {
				Fail("could not reach drop");
			}
		} break;

		case EState::UNLOADING: {
			CCircuitUnit* cargo = GetCargo();
			if (cargo == nullptr) {
				Fail("cargo gone while unloading");
				return;
			}
            if (routed && IsAboard(cargo,transport,frame)
                && circuit->GetBattle()->AirThreatAlong(transport->GetPos(frame),landPos,flightPadding)>maxAirThreat) {
                Fail("anti-air appeared during unload"); return;
            }
			ReportUnload(transport, cargo, frame);  // D-110 diagnostic
			// Landed when the cargo sits on the ground - exactly, for two
			// updates running. A hanging unit is never exactly on the ground,
			// and the engine does not detach a unit that changes team, so a
			// give one update early would leave it under our transport (D-056).
			// D-110: or not aboard any more (a raised drop spot is never exactly ground)
			// D-122 (the owner's game: the cargo was out at 7 s - "aboard=0", the
			// transport's queue empty - but it stood more than FERRY_LIFT_HEIGHT
			// above the terrain height (a pad, a ramp), so "not lifted" never held;
			// the run sat in UNLOADING 45 s a retry, the transport idle, the gift not
			// given): the engine has finished the unload (the transport's queue is
			// empty) and the cargo is not aboard (IsAboard: risen above where it
			// stood AND under the transport, D-110, D-112). The empty queue keeps a
			// cargo still attached in the descent from counting (D-056)
			const AIFloat3& cPos = cargo->GetPos(frame);
			const bool onGround = (cPos.y - circuit->GetMap()->GetElevationAt(cPos.x, cPos.z)) < FERRY_GROUND_TOLERANCE;
			const bool unloadOver = circuit->GetUnitAPI()->GetCMDQueueSize(transport->GetId()) == 0;
			const bool notAboard = !IsAboard(cargo, transport, frame);
			const bool landed = onGround || (!IsLifted(cargo, frame) && notAboard) || (unloadOver && notAboard);
			landedTicks = landed ? (landedTicks + 1) : 0;
			// Supreme reproduction: the engine rejected the area order immediately,
			// leaving cargo airborne and an empty queue for the entire 45 s timeout.
			// Reconcile two observations before retrying a different legal spot;
			// an active descent or detached cargo never takes this recovery branch.
			missingUnloadTicks = (unloadOver && !landed) ? missingUnloadTicks + 1 : 0;
			if (landedTicks >= FERRY_LANDED_TICKS) {
				circuit->LOG("FERRY: delivered cargo %i at (%.0f, %.0f)", cargoId, landPos.x, landPos.z);
				Enter(EState::DONE);
				// Head home without waiting for script: the run is over either
				// way, and the transport is the thing worth recovering.
				if (geom::is_valid(holdPos)) {
					GoTo(transport, holdPos);
				}
			} else if (IsExpired(frame) || missingUnloadTicks >= FERRY_MISSING_UNLOAD_TICKS) {
				if (++unloadRetries > FERRY_UNLOAD_RETRIES) {
					Fail("unload did not take");
				} else {
					// The spot was not clear after all (a unit walked onto it, the
					// engine disagreed). Widen the search from where we hover.
					refusedDrops.push_back(landPos);  // D-091: never this spot again
					landPos = FindLandingSpot(cargo, routed ? dropPos : transport->GetPos(frame), routed ? 96.f : FERRY_LAND_SEARCH * (unloadRetries + 1));
					if (!geom::is_valid(landPos)) { Fail("no safe retry ground"); return; }
					dropPos = landPos;
                    if (routed) { mission={landPos}; missionIndex=0; }
					circuit->LOG("FERRY: unload retry %i for cargo %i at (%.0f, %.0f)", unloadRetries, cargoId, landPos.x, landPos.z);
					Enter(EState::TO_DROP);
					GoTo(transport, landPos);
				}
			}
		} break;

		case EState::DUMPING: {
			CCircuitUnit* cargo = GetCargo();
            if (routed && cargo!=nullptr) {
                // A descending attached cargo can fall below IsAboard's lift
                // threshold. Do not cancel its unload and release ownership
                // then: wait for an empty engine queue and two observations,
                // just as normal delivery does. CMD_UNLOAD_UNIT is the engine's
                // internal child of our area unload, not a foreign command.
                const bool unloadOver=circuit->GetUnitAPI()->GetCMDQueueSize(transport->GetId())==0;
                landedTicks=(unloadOver && !IsAboard(cargo,transport,frame))?landedTicks+1:0;
                if (landedTicks>=FERRY_LANDED_TICKS) {
                    circuit->LOG("FERRY: cargo %i set down after a failed run (unload complete)",cargoId);
                    cargoId=-1; Enter(EState::FAILED);
                    if (geom::is_valid(holdPos)) GoTo(transport,holdPos);
                    return;
                }
                if (landedTicks>0) return; // reconcile release, never reissue an unload here
                if (!geom::is_valid(landPos) || IsExpired(frame)) {
                    landPos=FindLandingSpot(cargo,transport->GetPos(frame),FERRY_LAND_SEARCH*3);
                    if (!geom::is_valid(landPos)) landPos=FindLandingSpot(cargo,holdPos,FERRY_LAND_SEARCH*3);
                    Enter(EState::DUMPING);
                }
                if (!geom::is_valid(landPos)) { GoTo(transport,holdPos); return; }
                if (transport->GetPos(frame).SqDistance2D(landPos)>SQUARE(FERRY_DROP_DIST)) {
                    GoTo(transport,landPos); return;
                }
                if (circuit->GetBattle()->AirThreatAlong(transport->GetPos(frame),landPos,flightPadding)>maxAirThreat) {
                    landPos=-RgtVector; return;
                }
                const int command=transport->GetCurrentCommand()->GetId();
                if (command!=CMD_UNLOAD_UNITS && command!=CMD_UNLOAD_UNIT) {
                    TRY_UNIT(circuit,transport,
                        transport->CmdUnloadUnitsInArea(landPos,64.f,0,frame+FERRY_UNLOAD_TIMEOUT);
                    )
                }
                return;
            }
			ReportUnload(transport, cargo, frame);  // D-110 diagnostic
			if ((cargo == nullptr) || !IsAboard(cargo, transport, frame)) {
				circuit->LOG("FERRY: cargo %i set down after a failed run (%s)", cargoId, (cargo == nullptr) ? "gone" : "not aboard");
				cargoId = -1;
				Enter(EState::FAILED);
				if (geom::is_valid(holdPos)) {
					GoTo(transport, holdPos);
				}
			} else if (IsExpired(frame)) {
				// Still lifted: FAILED is never entered with live cargo under the
				// transport, since the script gives the cargo away on FAILED and
				// the engine does not detach a unit that changes team (CR-004).
				// Try a wider landing spot from wherever the transport hovers.
				++unloadRetries;
				refusedDrops.push_back(landPos);  // D-091
				landPos = FindLandingSpot(cargo, transport->GetPos(frame), FERRY_LAND_SEARCH * (unloadRetries + 1));
				if (!geom::is_valid(landPos)) { GoTo(transport, holdPos); Enter(EState::DUMPING); return; }
				circuit->LOG("FERRY: dump retry %i for cargo %i at (%.0f, %.0f); still lifted, not given", unloadRetries, cargoId, landPos.x, landPos.z);
				TRY_UNIT(circuit, transport,
					transport->CmdUnloadUnitsInArea(landPos, FERRY_UNLOAD_RADIUS, 0, frame + FERRY_UNLOAD_TIMEOUT * 2);  // D-110
				)
				Enter(EState::DUMPING);
			}
		} break;

		default: break;
	}
}

} // namespace circuit
