/*
 * RouteTask.cpp
 *
 * See RouteTask.h. Orders default to moves (CmdMoveTo) queued with SHIFT so the
 * engine walks the waypoints in order. Ordinary spam fires while travelling;
 * opt-in standoff units pause the route to hold weapon range during contact.
 * Specialist routes can finish with fight; patrol mode loops patrol points.
 */

#include "task/fighter/RouteTask.h"
#include "module/MilitaryManager.h"
#include "terrain/TerrainManager.h"
#include "terrain/RangedGeometry.h"
#include "unit/CircuitUnit.h"
#include "unit/enemy/EnemyUnit.h"
#include "CircuitAI.h"
#include "spring/SpringCallback.h"
#include "spring/CustomCommand.h"
#include "spring/SpringUnit.h"
#include "spring/SpringMap.h"
#include "task/RetreatTask.h"
#include "util/Utils.h"

#include "AISCommands.h"
#include "Sim/Units/CommandAI/Command.h"
#include "Log.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <limits>

namespace circuit {

using namespace springai;

CRouteTask::CRouteTask(ITaskModule* mgr)
		: IFighterTask(mgr, FightType::ROUTE, 1.f)
		, laneCount(1)
		, laneSpacing(0.f)
		, laneEndSpread(0.f)
		, laneDealt(0)
		, version(0)
		, dirty(false)
		, arriveRadius(SQUARE_SIZE * 32)
{
}

CRouteTask::~CRouteTask()
{
}

bool CRouteTask::CanAssignTo(CCircuitUnit* unit) const
{
	return true;  // script decides membership
}

void CRouteTask::AssignTo(CCircuitUnit* unit)
{
	IFighterTask::AssignTo(unit);
    hadAssignee = true;
	// Deal lanes from the centre outwards: 0, +1, -1, +2, -2 ... so a small
	// stream still straddles the line rather than drifting to one side.
	unsigned int slot;
    if (rowSpacing > 0.f && !freeFormationSlots.empty()) {
        slot = *freeFormationSlots.begin();
        freeFormationSlots.erase(freeFormationSlots.begin());
    } else {
        slot = laneDealt++;
    }
    // Reuse casualties' slots in O(log N), without shuffling survivors or
    // growing an arbitrarily deep formation after repeated reinforcements.
    if (rowSpacing > 0.f) formationSlots[unit] = slot;
	const unsigned int k = slot % std::max(1, laneCount);
	const int lane = (k == 0) ? 0 : (((k % 2) == 1) ? int((k + 1) / 2) : -int(k / 2));
	lanes[unit] = lane;
    rows[unit] = slot / std::max(1, laneCount);
}

void CRouteTask::RemoveAssignee(CCircuitUnit* unit)
{
    if (seaTarget >= 0) {
        // BAR accepts an ID-specific cancel, including pending out-of-range
        // targets. Do not cancel a player's replacement priority list.
        TRY_UNIT(manager->GetCircuit(), unit,
            float params[] = {float(seaTarget)};
            SendCustomCommand(manager->GetCircuit()->GetSkirmishAIId(), unit->GetId(), CMD_UNIT_CANCEL_TARGET, params);
        )
        unit->TrySetFireState(unit->GetCircuitDef()->GetFireState());
    }
	// The task belongs to a factory and outlives its units; script aborts it
	// when the factory is gone. Fighter tasks have no timeout, so an empty
	// route task simply idles in the update list.
	IFighterTask::RemoveAssignee(unit);
	lanes.erase(unit);
    rows.erase(unit);
    const auto slot = formationSlots.find(unit);
    if (slot != formationSlots.end()) {
        freeFormationSlots.insert(slot->second);
        formationSlots.erase(slot);
    }
	unitRoutes.erase(unit);
    unitArrival.erase(unit);
	issuing.erase(unit);
	lastIssue.erase(unit);
	retryUnits.erase(unit);
	engaging.erase(unit);
    issuedVersion.erase(unit);
    dispatches.erase(unit);
    issueTrace.erase(unit);
    if (holdPosition) unit->TrySetMoveState(unit->GetCircuitDef()->GetMoveState());
    if (ManagedControl() && hadAssignee && units.empty()) manager->AbortTask(this);
}

void CRouteTask::SetLanes(int count, float spacing, float endSpread)
{
	laneCount = std::max(1, count);
	laneSpacing = std::max(0.f, spacing);
	laneEndSpread = std::min(1.f, std::max(0.f, endSpread));
}

void CRouteTask::SetRowSpacing(float spacing)
{
    rowSpacing = std::isfinite(spacing) ? std::clamp(spacing, 0.f, 512.f) : 0.f;
}

void CRouteTask::SetTraversal(bool preserve, float radius, bool fight)
{
	preserveWaypoints = preserve;
	arriveRadius = std::isfinite(radius) ? std::clamp(radius, 16.f, 512.f) : 48.f;
	fightAtEnd = fight;
}

int CRouteTask::LaneOf(CCircuitUnit* unit) const
{
	auto it = lanes.find(unit);
	return (it == lanes.end()) ? 0 : it->second;
}

AIFloat3 CRouteTask::LanePoint(CCircuitUnit* unit, unsigned int idx) const
{
	const auto& route = RouteFor(unit);
	if (unitRoutes.count(unit)) return route[idx];
	const AIFloat3& p = route[idx];
	const int lane = LaneOf(unit);
	if (((lane == 0) && rowSpacing <= 0.f) || (laneSpacing <= 0.f) || (route.size() < 2)) {
		return p;
	}
	// Sideways is perpendicular to the leg arriving at this point (for the
	// first point, the leg leaving it), so the band follows the line's bends.
	const AIFloat3& a = route[(idx == 0) ? 0 : idx - 1];
	const AIFloat3& b = route[(idx == 0) ? 1 : idx];
	AIFloat3 dir(b.x - a.x, 0.f, b.z - a.z);
	const float len = std::sqrt(dir.x * dir.x + dir.z * dir.z);
	if (len < 1.f) {
		return p;
	}
	const float scale = (idx + 1 == route.size()) ? laneEndSpread : 1.f;
	const float off = laneSpacing * float(lane) * scale;
	const auto row = rows.find(unit);
    const float behind = row == rows.end() ? 0.f : rowSpacing * row->second;
    AIFloat3 out(p.x + (-dir.z / len) * off - dir.x / len * behind,
        p.y, p.z + (dir.x / len) * off - dir.z / len * behind);
	CTerrainManager::CorrectPosition(out);
	// Formation offsets can cross a coast even when the centre route is legal.
	// Both land spam and SEA collapse that member to the route instead of
	// issuing an unreachable cliff/coast order. This uses the existing movement
	// area lookup, not a new path query; aircraft have no restricted area.
	if (!manager->GetCircuit()->GetTerrainManager()->CanMoveToPos(unit->GetArea(), out)) return p;
	return out;
}

void CRouteTask::Start(CCircuitUnit* unit)
{
    if (holdPosition) unit->TrySetMoveState(CCircuitDef::MoveType::HOLD_POS);
	IssueRoute(unit, 0);
    if (seaTarget >= 0) IssuePriorityTarget(unit, seaTarget, navalTarget, landTarget);
}

void CRouteTask::Update()
{
	const bool changed = dirty;
	dirty = false;
	// The route changed, which means the destination changed: send everything
	// already in the air straight at the new one. Re-running the new lane from
	// its nearest waypoint would walk units backwards to pick the lane up,
	// and a spam unit's value is pressure and vision forward, not formation.
	// Units produced after this still get the full lane from Start().
	for (CCircuitUnit* unit : units) {
		CCircuitAI* circuit = manager->GetCircuit();
		CCircuitDef* def = unit->GetCircuitDef();
		CEnemyInfo* nearest = nullptr;
		float nearestSq = SQUARE(def->GetMaxRange() * 1.1f);
		if (def->GetStandoff() > 0.f && !(seaControl && holdPosition)) {
			const AIFloat3 here = unit->GetPos(circuit->GetLastFrame());
			for (const auto& kv : circuit->GetEnemyInfos()) {
				CEnemyInfo* enemy = kv.second;
				const CCircuitDef* edef = enemy->GetCircuitDef();
				if (enemy->IsHidden() || !enemy->IsInRadarOrLOS() || edef == nullptr
						|| !(edef->GetCategory() & def->GetTargetCategory())
						|| (!def->HasSurfToWater() && enemy->GetPos().y < -SQUARE_SIZE * 5)) continue;
				const float sq = here.SqDistance(enemy->GetPos());
				if (sq < nearestSq) { nearestSq = sq; nearest = enemy; }
			}
		}
		if (nearest != nullptr) {
			if (engaging.insert(unit).second) { // before Stop can cause an idle callback
				circuit->LOG("RANGE: %s(%i) pauses route at %.0f for weapon range %.0f",
						def->GetDef()->GetName(), unit->GetId(), std::sqrt(nearestSq), def->GetMaxRange());
			}
			if (unit->KeepWeaponRange(nearest, circuit->GetLastFrame() + FRAMES_PER_SEC * 10)) continue;
		}
		const bool resume = engaging.erase(unit) != 0;
		if (resume) circuit->LOG("RANGE: %s(%i) resumes specialist route", def->GetDef()->GetName(), unit->GetId());
        bool retry=retryUnits.count(unit) && circuit->GetLastFrame()-lastIssue[unit]>=FRAMES_PER_SEC;
        if (ManagedControl() && retry && circuit->GetCallback()->Unit_HasCommands(unit->GetId())) {
            // Idle events can describe an order just replaced by another
            // callback. Preserve that live queue; only repair an empty one.
            retryUnits.erase(unit);
            retry = false;
        }
        if (!changed && !resume && !retry) continue;
        if (ManagedControl() && !resume && !retry && issuedVersion.count(unit) && issuedVersion[unit] == version) continue;
        retryUnits.erase(unit);
        if (!changed && !resume && !ManagedControl() && IsAtEnd(unit)) continue;
		if (patrol) IssueRoute(unit, 0);
		else if (preserveWaypoints) IssueRoute(unit, NearestAheadIndex(unit));
		else IssueDirect(unit);
	}
}

void CRouteTask::OnUnitIdle(CCircuitUnit* unit)
{
	if (issuing.count(unit) != 0) return;
    // Idle notifications can arrive after an earlier callback installed the
    // same route. Only an exact live suffix owned by this task may absorb it;
    // STOP, expiry, foreign orders and changed intent still recover at once.
    auto* circuit = manager->GetCircuit();
    const auto previous = dispatches.find(unit);
    if (unit->GetTask() == this && previous != dispatches.end()
        && previous->second.version == version
        && circuit->GetUnitAPI()->HasRouteIntent(unit->GetId(), previous->second.commands, circuit->GetLastFrame())) return;
    // A rejected/zero-length waypoint can synchronously idle again. Bound
    // opt-in exact routes instead of filling the engine's command/event queues.
	if (engaging.count(unit) != 0) return;  // Update owns contact loss and lane resumption.
	if (patrol && !route.empty()) {
		if (ManagedControl()) { retryUnits.insert(unit); return; }
		IssueRoute(unit, 0);
		return;
	}
	if (route.empty() || IsAtEnd(unit)) {
		return;  // holding at the destination; weapons keep firing on their own
	}
    if (preserveWaypoints) { retryUnits.insert(unit); return; }
	// Stuck or the queue was cleared: continue from the nearest waypoint ahead
	IssueRoute(unit, NearestAheadIndex(unit));
}

void CRouteTask::OnUnitDamaged(CCircuitUnit* unit, CEnemyInfo* attacker)
{
    if (seaControl && !combatRetreat) return;
    if (seaControl && repairThreshold > 0.f && unit->GetHealthPercent() < repairThreshold) {
        // Opt-in task policy, never mutate a shared UnitDef retreat threshold.
        // Native retreat owns safe destination, repair, completion and return.
        auto* military = static_cast<CMilitaryManager*>(manager);
        military->AssignTask(unit, military->EnqueueRetreat());
        return;
    }
    if (seaControl) IFighterTask::OnUnitDamaged(unit, attacker);
	// No retreat: spam trades bodies for pressure.
}

void CRouteTask::SetRepairThreshold(float value)
{
    repairThreshold = std::isfinite(value) ? std::clamp(value, 0.f, .9f) : 0.f;
}

bool CRouteTask::SetSeaTarget(int id) { return SetPriorityTarget(id, false); }
bool CRouteTask::SetNavalTarget(int id) { return SetPriorityTarget(id, true); }

void CRouteTask::IssuePriorityTarget(CCircuitUnit* unit, int id, bool naval, bool land)
{
    auto* circuit = manager->GetCircuit();
    const auto* def = unit->GetCircuitDef();
    if (id >= 0) {
        const auto* enemy = circuit->GetEnemyInfo(id);
        if (enemy == nullptr || !enemy->IsInRadarOrLOS()) return;
        if (land) {
            if (!(def->HasSurfToLand() || def->HasSubToLand())) return;
        } else if (naval) {
            auto* targetDef = enemy->GetCircuitDef();
            const auto& p = enemy->GetPos();
            const bool submerged = targetDef != nullptr && targetDef->IsInWater(circuit->GetMap()->GetElevationAt(p.x,p.z),p.y);
            const bool waterWeapon = def->HasSurfToWater() || def->HasSubToWater();
            // Surface ships and floating factories are torpedo targets too.
            // Keep this in the opt-in naval path: dry coastal targets still
            // require a land weapon; a submerged target requires a water one.
            const bool waterTarget = circuit->GetMap()->GetElevationAt(p.x,p.z) < -8.f;
            if (submerged ? !waterWeapon : !(def->HasSurfToLand() || def->HasSubToLand()
                || (waterTarget && waterWeapon))) return;
        } else if (!def->HasSurfToAir()) return;
    }
    TRY_UNIT(circuit, unit,
        float params[] = {float(id >= 0 ? id : seaTarget)};
        SendCustomCommand(circuit->GetSkirmishAIId(), unit->GetId(), id >= 0 ? CMD_UNIT_SET_TARGET : CMD_UNIT_CANCEL_TARGET, params);
        unit->TrySetFireState(id >= 0 ? CCircuitDef::FireType::OPEN : def->GetFireState());
    )
}

bool CRouteTask::SetPriorityTarget(int id, bool naval)
{
    if (!seaControl) return false;
    auto* circuit = manager->GetCircuit();
    if (id >= 0) {
        const auto* enemy = circuit->GetEnemyInfo(id);
        if (enemy == nullptr || !enemy->IsInRadarOrLOS() || enemy->GetCircuitDef() == nullptr
            || enemy->GetCircuitDef()->IsAbleToFly() == naval) return false;
        const auto data = enemy->GetData()->GetData();
        if (data.losStatus & (SEnemyData::LosMask::HIDDEN | SEnemyData::LosMask::NEUTRAL
            | SEnemyData::LosMask::DYING | SEnemyData::LosMask::DEAD)) return false;
        if (data.IsIgnore() && (!enemy->GetCircuitDef()->IsIgnore()
            || enemy->GetUnit()->GetRulesParamFloat("ignoredByAI", 0.f) > 0.f)) return false;
    }
    if (id == seaTarget && naval == navalTarget && !landTarget) return true;
    // O(members) only on intent changes; new assignees receive the current
    // priority in Start. Cancel the old ID so out-of-range lists cannot grow.
    // Movement remains the route/formation, never an engine ATTACK chase.
    for (auto* unit : units) {
        if (seaTarget >= 0) IssuePriorityTarget(unit, -1, navalTarget, landTarget);
        if (id >= 0) IssuePriorityTarget(unit, id, naval);
    }
    seaTarget = id;
    navalTarget = naval;
    landTarget = false;
    return true;
}

bool CRouteTask::SetLandTarget(int id)
{
    // D-296: same validation and ID-specific cancel contract as the SEA path,
    // for a ground contact. O(members) only when the intent changes.
    auto* circuit = manager->GetCircuit();
    if (id >= 0) {
        const auto* enemy = circuit->GetEnemyInfo(id);
        if (enemy == nullptr || !enemy->IsInRadarOrLOS() || enemy->GetCircuitDef() == nullptr
            || enemy->GetCircuitDef()->IsAbleToFly()) return false;
        const auto data = enemy->GetData()->GetData();
        if (data.losStatus & (SEnemyData::LosMask::HIDDEN | SEnemyData::LosMask::NEUTRAL
            | SEnemyData::LosMask::DYING | SEnemyData::LosMask::DEAD)) return false;
        if (data.IsIgnore() && (!enemy->GetCircuitDef()->IsIgnore()
            || enemy->GetUnit()->GetRulesParamFloat("ignoredByAI", 0.f) > 0.f)) return false;
    }
    if (id == seaTarget && (id < 0 || landTarget)) return true;
    for (auto* unit : units) {
        if (seaTarget >= 0) IssuePriorityTarget(unit, -1, navalTarget, landTarget);
        if (id >= 0) IssuePriorityTarget(unit, id, false, true);
    }
    seaTarget = id;
    navalTarget = false;
    landTarget = id >= 0;
    return true;
}

void CRouteTask::SetRoute(std::vector<AIFloat3>&& waypoints)
{
    if (ManagedControl() && unitRoutes.empty() && waypoints.size() == route.size()
        && std::equal(route.begin(), route.end(), waypoints.begin(), [](const AIFloat3& a, const AIFloat3& b) {
            return a.x == b.x && a.y == b.y && a.z == b.z;
        })) return;
	unitRoutes.clear();
    unitArrival.clear();
	route = std::move(waypoints);
	++version;
	dirty = !route.empty();
	if (!route.empty()) {
		position = route.back();
	}
}

bool CRouteTask::IsAtEnd(CCircuitUnit* unit) const
{
	const auto& route = RouteFor(unit);
	if (route.empty()) {
		return true;
	}
	const int frame = manager->GetCircuit()->GetLastFrame();
	const auto it=unitArrival.find(unit);
    const float radius=it==unitArrival.end() ? arriveRadius : it->second;
    // SEA formation completion is relative to this member's lane/row, not
    // the cohort center. Otherwise an offset ship idles and requeues forever.
    const AIFloat3 goal=LanePoint(unit,route.size()-1);
    return unit->GetPos(frame).SqDistance2D(goal) < SQUARE(radius);
}

unsigned int CRouteTask::NearestAheadIndex(CCircuitUnit* unit) const
{
	const auto& route = RouteFor(unit);
	// Nearest waypoint, then the one after it unless it is the last: a unit
	// standing on waypoint k should head for k+1.
	if (route.empty()) {
		return 0;
	}
	const int frame = manager->GetCircuit()->GetLastFrame();
	const AIFloat3& pos = unit->GetPos(frame);
	unsigned int best = 0;
	float bestSq = std::numeric_limits<float>::max();
	for (unsigned int i = 0; i < route.size(); ++i) {
		const float sq = pos.SqDistance2D(route[i]);
		if (sq < bestSq) {
			bestSq = sq;
			best = i;
		}
	}
	if ((best + 1 < route.size()) && (bestSq < SQUARE(arriveRadius))) {
		++best;
	}
	return best;
}

void CRouteTask::IssueDirect(CCircuitUnit* unit)
{
	const auto& route = RouteFor(unit);
	if (route.empty()) {
		return;
	}
	CCircuitAI* circuit = manager->GetCircuit();
    // Direct refocus moves can synchronously generate idle too; use the same
    // dispatch guard as queued routes (not a time/APM limiter).
    if (!issuing.insert(unit).second) return;
    TraceIssue(unit,route.size()-1,true);
    lastIssue[unit] = circuit->GetLastFrame();
    auto& dispatch = dispatches[unit];
    const auto goal = LanePoint(unit, route.size() - 1);
    const int timeout = circuit->GetLastFrame() + FRAMES_PER_SEC * 600;
    dispatch.commands.clear(); dispatch.version = -1;
	TRY_UNIT(circuit, unit,
		unit->CmdWantedSpeed(NO_SPEED_LIMIT);
		unit->CmdMoveTo(goal, 0, timeout);
        dispatch.commands.push_back({CMD_MOVE,0,timeout,goal.x,goal.y,goal.z});
        dispatch.version = version;
	)
    issuing.erase(unit);
}

void CRouteTask::IssueRoute(CCircuitUnit* unit, unsigned int fromIdx)
{
    if (airControl && airTarget >= 0) {
        auto* circuit = manager->GetCircuit();
        auto* enemy = circuit->GetEnemyInfo(airTarget);
        if (enemy != nullptr && !enemy->IsHidden() && enemy->IsInRadarOrLOS()) {
            if (!issuing.insert(unit).second) return;
            TRY_UNIT(circuit, unit, unit->Attack(enemy, false, circuit->GetLastFrame() + FRAMES_PER_SEC * 3600, false);)
            issuing.erase(unit); issuedVersion[unit] = version; lastIssue[unit] = circuit->GetLastFrame();
            return;
        }
    }
	const auto& route = RouteFor(unit);
	if (route.empty()) {
		return;
	}
	CCircuitAI* circuit = manager->GetCircuit();
	if (!issuing.insert(unit).second) return;
	TraceIssue(unit,fromIdx,false);
	lastIssue[unit]=circuit->GetLastFrame();
	const int timeout = circuit->GetLastFrame() + FRAMES_PER_SEC * 600;
	// Project every ORIGINAL waypoint before reducing commands: projecting a
    // simplified fleet centerline changes offsets at turns and shallow coasts.
    // Only ordinary MOVE legs participate; joining endpoints, reversals and
    // all PATROL/FIGHT transitions retain their original dispatch path.
    if (!patrol && !fightAtEnd && fromIdx < route.size()) {
        std::vector<AIFloat3> projected;
        projected.reserve(route.size()-fromIdx);
        for (unsigned int i=fromIdx; i<route.size(); ++i) projected.push_back(LanePoint(unit,i));
        if (seaControl && compactMoves) CompactNavalPolyline(unit, projected);
        // Diagnostic only: correlate the exact dispatch-time policy with a
        // replay queue. A script census can precede dispatch and have changed
        // its combat/transit mode in between. No callbacks in ordinary play.
        static const bool traceGeometry = std::getenv("CIRCUIT_TRACE_ROUTE") != nullptr;
        if (traceGeometry && seaControl && route.size()-fromIdx >= 64) {
            circuit->LOG("[RouteGeometry] frame=%d unit=%d def=%s version=%d input=%u output=%u compact=%d target=%d",
                circuit->GetLastFrame(),unit->GetId(),unit->GetCircuitDef()->GetDef()->GetName(),version,
                unsigned(route.size()-fromIdx),unsigned(projected.size()),int(compactMoves),seaTarget);
        }
        auto& old = dispatches[unit];
        std::vector<routecommand::Command> commands;
        commands.reserve(projected.size());
        // A matching intent retains its ORIGINAL deadline, never silently
        // extends it. The live callback below still detects same-frame STOP,
        // command rejection, expiry, takeover and engine-internal detours.
        // A new raw path/version can reduce to exactly the same per-member
        // intent. Revalidate that intent and the live queue, then promote its
        // version; requiring the old version here would miss this useful case.
        bool same = old.version >= 0 && old.target == seaTarget && old.naval == navalTarget && old.hold == holdPosition
            && !retryUnits.count(unit) && !engaging.count(unit)
            && unit->GetTask() == this && !unit->IsDead();
        for (size_t i=0; i<projected.size(); ++i) {
            const auto& p=projected[i];
            routecommand::Command c{CMD_MOVE, i==0 ? 0 : UNIT_COMMAND_OPTION_SHIFT_KEY, timeout,p.x,p.y,p.z};
            commands.push_back(c);
        }
        const AIFloat3 here = unit->GetPos(circuit->GetLastFrame());
        size_t retainedCount = 0;
        same = same && routecommand::RemainingIntent(old.commands, commands,
            here.x, here.y, here.z, UNIT_COMMAND_OPTION_SHIFT_KEY, &retainedCount);
        // The engine must already have consumed any removed prefix. Otherwise
        // retaining it could preserve a bend the newly requested path removed.
        const std::vector<routecommand::Command> remaining = same
            ? std::vector<routecommand::Command>(old.commands.end()-retainedCount,old.commands.end())
            : std::vector<routecommand::Command>{};
        bool sent = false;
        TRY_UNIT(circuit, unit,
            unit->CmdWantedSpeed(NO_SPEED_LIMIT);
            if (same && circuit->GetUnitAPI()->HasRouteIntent(unit->GetId(),remaining,circuit->GetLastFrame())) {
                old.version = version;
                sent = true;
            } else {
                // Clear first: a partial/rejected dispatch cannot be claimed
                // as an authoritative queue on the next recovery attempt.
                old.commands.clear(); old.version = -1;
                for (const auto& c:commands) unit->CmdMoveTo({c.x,c.y,c.z},c.options,c.timeout);
                old.commands=std::move(commands); old.version=version; old.target=seaTarget; old.naval=navalTarget; old.hold=holdPosition;
                sent = true;
            }
        )
        issuing.erase(unit);
        if (sent) issuedVersion[unit]=version;
        return;
    }
	dispatches.erase(unit);
	TRY_UNIT(circuit, unit,
		unit->CmdWantedSpeed(NO_SPEED_LIMIT);
		for (unsigned int i = fromIdx; i < route.size(); ++i) {
			const short options = (i == fromIdx) ? 0 : UNIT_COMMAND_OPTION_SHIFT_KEY;
			if (patrol && i > fromIdx) unit->CmdPatrolTo(LanePoint(unit, i), options, timeout);
			else if (fightAtEnd && i + 1 == route.size()) unit->CmdFightTo(LanePoint(unit, i), options, timeout);
			else unit->CmdMoveTo(LanePoint(unit, i), options, timeout);
		}
	)
	issuing.erase(unit);
    if (ManagedControl()) issuedVersion[unit] = version;
}

void CRouteTask::CompactNavalPolyline(CCircuitUnit* unit, std::vector<AIFloat3>& points) const
{
    if (points.size()<3) return;
    const size_t originalCount=points.size();
    const AIFloat3 first=points.front(), last=points.back();
    const auto* terrain = manager->GetCircuit()->GetTerrainManager();
    const auto* movement = terrain->GetMobileType(unit->GetCircuitDef()->GetId());
    if (movement == nullptr || !movement->canFloat) return;
    // D-340: a ship's limit is its negative draft (-minWaterDepth). A hover's
    // maxElevation is positive (it can also cross land), which used to skip
    // compaction entirely: every hover route kept all its 64-elmo cells. For
    // hovers accept only an all-water corridor (elevation below 0), which a
    // hover can always cross; legs touching land keep their original points.
    const float elevationLimit = std::min(movement->maxElevation, 0.0f);
    const auto* area = terrain->GetAreaData();
    const int extent = std::max(unit->GetCircuitDef()->GetMoveXSize(),unit->GetCircuitDef()->GetMoveZSize())/2 + 1;
    const float width=CTerrainManager::GetTerrainWidth(), height=CTerrainManager::GetTerrainHeight();
    // Validate the union of adjacent projected legs once, not the growing
    // merged segment repeatedly (quadratic). Direct height-array reads on the
    // owner thread, sampled at terrain-square spacing across the footprint.
    // Maximum geometry drift is 1/16 elmo, smaller than the padded footprint
    // samples by two orders of magnitude. A fixed corridor prevents the
    // unbounded drift of a per-angle epsilon. tests/route_command_test.cpp.
    constexpr double roundingHalfCorridor = 1.0 / 32.0;
    ranged::CompactValidatedCorridorRoute(points, [&](const AIFloat3& a, const AIFloat3& b) {
        const int steps=std::max(1,int(std::ceil(std::sqrt(a.SqDistance2D(b))/SQUARE_SIZE)));
        for (int i=0; i<=steps; ++i) for (int dx=-extent; dx<=extent; ++dx) for (int dz=-extent; dz<=extent; ++dz) {
            const float x=a.x+(b.x-a.x)*i/steps+dx*SQUARE_SIZE, z=a.z+(b.z-a.z)*i/steps+dz*SQUARE_SIZE;
            if (x<0 || z<0 || x>=width || z>=height) return false;
            const float elevation=area->GetElevationAt(x,z);
            if (!std::isfinite(elevation) || elevation>elevationLimit) return false;
        }
        return true;
    }, roundingHalfCorridor);
    // Constant-cost live promise; the full corridor/failed-leg proof belongs
    // to the geometry tests, not a second per-ship terrain scan.
    if (points.empty() || points.size()>originalCount
        || points.front().SqDistance(first)!=0 || points.back().SqDistance(last)!=0)
        manager->GetCircuit()->LOG("[INVARIANT] INV-186 naval compaction changed route endpoints or grew the queue");
}

const std::vector<AIFloat3>& CRouteTask::RouteFor(CCircuitUnit* unit) const
{
    const auto it=unitRoutes.find(unit);
    return it==unitRoutes.end() ? route : it->second;
}

void CRouteTask::TraceIssue(CCircuitUnit* unit, unsigned int fromIndex, bool direct)
{
    // Opt-in diagnosis only: no state allocation/callback/log on normal runs.
    // Emit at most once per unit per game second, and only on a repeated
    // dispatch storm. This is an observation bound, NEVER an order rate limit.
    static const bool enabled=std::getenv("CIRCUIT_TRACE_ROUTE")!=nullptr;
    if (!enabled) return;
    auto* circuit=manager->GetCircuit();
    const int frame=circuit->GetLastFrame();
    auto& trace=issueTrace[unit];
    if (frame-trace.frame>=FRAMES_PER_SEC || trace.frame<0) { trace.frame=frame; trace.count=0; }
    if (++trace.count<3 || frame-trace.reported<FRAMES_PER_SEC) return;
    trace.reported=frame;
    const auto& path=RouteFor(unit);
    const auto here=unit->GetPos(frame), goal=LanePoint(unit,path.size()-1);
    const auto next=LanePoint(unit,std::min(fromIndex,unsigned(path.size()-1)));
    circuit->LOG("[RouteBurst] frame=%d unit=%d def=%s version=%d count=%d direct=%d from=%u points=%u pos=%.1f,%.1f next=%.1f,%.1f goal=%.1f,%.1f radius=%.1f commands=%d sea=%d preserve=%d",
        frame,unit->GetId(),unit->GetCircuitDef()->GetDef()->GetName(),version,trace.count,int(direct),fromIndex,unsigned(path.size()),
        here.x,here.z,next.x,next.z,goal.x,goal.z,arriveRadius,int(circuit->GetCallback()->Unit_HasCommands(unit->GetId())),int(seaControl),int(preserveWaypoints));
}

bool CRouteTask::SetUnitRoute(CCircuitUnit* unit, std::vector<AIFloat3>&& points, float radius)
{
    if (unit==nullptr || units.count(unit)==0 || points.empty() || !std::isfinite(radius)) return false;
    for (const auto& p:points) if (!std::isfinite(p.x) || !std::isfinite(p.y) || !std::isfinite(p.z)) return false;
    unitRoutes[unit]=std::move(points);
    unitArrival[unit]=std::clamp(radius,16.f,512.f);
    IssueRoute(unit,0);
    return true;
}

} // namespace circuit
