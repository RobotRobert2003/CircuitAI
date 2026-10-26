/*
 * RetreatTask.cpp
 *
 *  Created on: Jan 18, 2015
 *      Author: rlcevg
 */

#include "task/RetreatTask.h"
#include "map/ThreatMap.h"
#include "map/InfluenceMap.h"
#include "module/BuilderManager.h"
#include "module/CommanderControl.h"
#include "module/EconomyManager.h"
#include "module/FactoryManager.h"
#include "resource/MetalManager.h"
#include "setup/SetupManager.h"
#include "terrain/path/PathFinder.h"
#include "terrain/path/QueryPathSingle.h"
#include "terrain/path/QueryCostMap.h"
#include "terrain/TerrainManager.h"
#include "unit/action/DGunAction.h"
#include "unit/action/MoveAction.h"
#include "unit/action/FightAction.h"
#include "CircuitAI.h"
#include "util/Utils.h"

#include "AISCommands.h"
#include <cmath>

namespace circuit {

using namespace springai;

CRetreatTask::CRetreatTask(ITaskModule* mgr, int timeout)
		: IUnitTask(mgr, Priority::NORMAL, Type::RETREAT, timeout)
		, repairer(nullptr)
{
}

CRetreatTask::~CRetreatTask()
{
}

void CRetreatTask::ClearRelease()
{
	costQuery = nullptr;
	IUnitTask::ClearRelease();
}

void CRetreatTask::AssignTo(CCircuitUnit* unit)
{
	IUnitTask::AssignTo(unit);

	if (unit->HasDGun()) {
		unit->PushDGunAct(new CDGunAction(unit, unit->GetDGunRange() * 0.9f));
	}

	CCircuitAI* circuit = manager->GetCircuit();
	CCircuitDef* cdef = unit->GetCircuitDef();
	TRY_UNIT(circuit, unit,
		unit->CmdSetFireState(cdef->IsAttrRetHold() ? CCircuitDef::FireType::HOLD : CCircuitDef::FireType::OPEN);
	)
	if (cdef->IsAttrBoost()) {
		unit->SetTaskFrame(circuit->GetLastFrame());  // avoid UnitIdle on find_pad
		const int frame = circuit->GetLastFrame() + FRAMES_PER_SEC * 60;
		TRY_UNIT(circuit, unit,
			if (cdef->IsPlane()) {
				unit->CmdFindPad(frame);
			}
			unit->CmdManualFire(UNIT_COMMAND_OPTION_ALT_KEY, frame);
		)
		return;
	}

	int squareSize = circuit->GetPathfinder()->GetSquareSize();
	ITravelAction* travelAction;
	if (cdef->IsAttrRetFight()) {
		travelAction = new CFightAction(unit, squareSize);
	} else {
		travelAction = new CMoveAction(unit, squareSize);
	}
	unit->PushTravelAct(travelAction);
	unit->SetAllowedToJump(cdef->IsAbleToJump() && !cdef->IsAttrNoJump());

	if (unit->GetCircuitDef()->IsAbleToCloak()) {
		TRY_UNIT(manager->GetCircuit(), unit,
			// An energy retreat must let the reserve refill, rather than
            // repeatedly spending each regenerated tick on an unfunded cloak.
            unit->CmdCloak(!circuit->GetCommanderControl()->EnergyRetreat(unit));
			// Opted-in precision retreat must not decloak on return fire.
			unit->CmdSetFireState((cdef->IsAttrRanged() && cdef->IsAttrRetHold())
                || (circuit->GetCommanderControl() && circuit->GetCommanderControl()->RetreatCloakFunded(unit))
				? CCircuitDef::FireType::HOLD : CCircuitDef::FireType::RETURN);
		)
	}

	// Mobile repair
	if (!cdef->IsAbleToFly() && !unit->IsAttrNoRepair()) {
		circuit->GetBuilderManager()->Enqueue(TaskB::Repair(IBuilderTask::Priority::HIGH, unit));
	}
}

void CRetreatTask::RemoveAssignee(CCircuitUnit* unit)
{
	holdPathed.erase(unit);  // before the base call can finish this task
	IUnitTask::RemoveAssignee(unit);
	if (units.empty()) {
		manager->DoneTask(this);
	}

	TRY_UNIT(manager->GetCircuit(), unit,
		unit->CmdSetFireState(unit->GetCircuitDef()->GetFireState());
	)
}

bool CRetreatTask::HoldInJam(CCircuitUnit* unit)
{
    auto* circuit=manager->GetCircuit();
    if(!circuit->GetCommanderControl()->Jammed(unit)) return false;
    // Also veto a completed asynchronous path: coverage may have appeared
    // since the request. Finish the travel action before it can emit a MOVE.
    auto* travel=unit->GetTravelAct();
    if(travel && !travel->IsFinished()) {
        TRY_UNIT(circuit,unit,unit->CmdStop();)
        travel->StateFinish();
    }
    state=State::REGROUP;
    return true;
}

void CRetreatTask::Start(CCircuitUnit* unit)
{
    if(HoldInJam(unit)) return;
	if (unit->GetTravelAct() == nullptr) {
		return;
	}
	CCircuitAI* circuit = manager->GetCircuit();
	AIFloat3 commanderStation;
	const bool commanderFallback = circuit->GetCommanderControl()
		&& circuit->GetCommanderControl()->RetreatStation(unit, commanderStation);
	if (unit->GetTravelAct()->IsFinished()) {
		// D-346: waiting at a forward repair point that has become threatened
		// or expired: resume the ordinary retreat to the haven.
		const bool holdLost = unit->GetRetreatHoldUntil() >= 0 && !HoldValid(unit, circuit->GetLastFrame());
		if (!holdLost && (!commanderFallback || unit->GetPos(circuit->GetLastFrame()).SqDistance2D(commanderStation) <= SQUARE(64.f))) return;
		unit->GetTravelAct()->StateActivate();
	}

	if (!IsQueryReady(unit)) {
		return;
	}

	const int frame = circuit->GetLastFrame();
	CPathFinder* pathfinder = circuit->GetPathfinder();
	const AIFloat3& startPos = unit->GetPos(frame);
	AIFloat3 endPos;
	float range;

	if (unit->GetTravelAct()->GetPath() == nullptr) {
		std::shared_ptr<CPathInfo> pPath = std::make_shared<CPathInfo>();
		pPath->PushPos(startPos, pathfinder);
		unit->GetTravelAct()->SetPath(pPath);
	}

	bool isNoEndPos = true;
    if (commanderFallback) { endPos = commanderStation; range = 64.f; isNoEndPos = false; }
    // D-346: a forward repair point outside enemy reach. Valid only while
    // unexpired, reachable and no more threatened than here; otherwise it is
    // dropped and the ordinary stage/repairer/haven rules apply. O(1).
    if (isNoEndPos && HoldValid(unit, frame)) {
        endPos = unit->GetRetreatHold(); range = HOLD_RADIUS; isNoEndPos = false;
        // Same hold as the active path: keep travelling, no new query/orders.
        auto it = holdPathed.find(unit);
        if (it != holdPathed.end() && it->second.SqDistance2D(endPos) <= SQUARE(HOLD_REPATH)
            && unit->GetTravelAct()->GetPath() != nullptr && !unit->GetTravelAct()->IsFinished()) {
            return;
        }
        holdPathed[unit] = endPos;
    } else {
        holdPathed.erase(unit);
    }
    // D-268: a script may nominate a short withdrawal stage, not replace the
    // repair destination. Constant work per route request; no fleet scan here.
    // Expiry, anchor ownership/movement, reachability and current threat are
    // checked on the engine thread. Arrival consumes the stage permanently
    // until policy publishes a new one after this retreat has finished.
    if (isNoEndPos && unit->GetRetreatAnchor() >= 0) {
        CCircuitUnit* anchor = circuit->GetTeamUnit(unit->GetRetreatAnchor());
        const AIFloat3& waypoint = unit->GetRetreatWaypoint();
        constexpr float arrivalRadius = 128.f;
        constexpr float maximumAnchorMovement = 512.f;
        const bool valid = frame < unit->GetRetreatWaypointUntil() && anchor != nullptr
            && geom::is_valid(waypoint) && std::isfinite(waypoint.x) && std::isfinite(waypoint.z)
            && waypoint.x >= 0.f && waypoint.z >= 0.f
            && waypoint.x < CTerrainManager::GetTerrainWidth() && waypoint.z < CTerrainManager::GetTerrainHeight()
            && anchor->GetPos(frame).SqDistance2D(waypoint) <= SQUARE(maximumAnchorMovement)
            && startPos.SqDistance2D(waypoint) > SQUARE(arrivalRadius)
            && circuit->GetTerrainManager()->CanReachAt(unit, waypoint, arrivalRadius)
            && circuit->GetThreatMap()->GetThreatAt(unit, waypoint) <= circuit->GetThreatMap()->GetThreatAt(unit, startPos);
        if (valid) { endPos = waypoint; range = arrivalRadius; isNoEndPos = false; }
        else unit->ClearRetreatWaypoint();
    }
	if (isNoEndPos && repairer != nullptr) {
		endPos = repairer->GetPos(frame);
		isNoEndPos = circuit->GetInflMap()->GetInfluenceAt(endPos) < INFL_EPS;
		if (!isNoEndPos) {
			range = pathfinder->GetSquareSize();
		}
	}
	if (isNoEndPos) {
		CFactoryManager* factoryMgr = circuit->GetFactoryManager();
		endPos = factoryMgr->GetClosestHaven(unit);
		if (!geom::is_valid(endPos)) {
			endPos = circuit->GetSetupManager()->GetBasePos();

			// Check home safety, find new one otherwise
			if (circuit->GetInflMap()->GetInfluenceAt(endPos) < INFL_SAFE) {
				circuit->GetSetupManager()->FindNewBase(unit);
				endPos = circuit->GetSetupManager()->GetBasePos();
			}
		}
		range = factoryMgr->GetAssistRange() * 0.6f + pathfinder->GetSquareSize();
	}

//	const float minThreat = circuit->GetThreatMap()->GetUnitThreat(unit) * 0.125f;
	std::shared_ptr<IPathQuery> query = pathfinder->CreatePathSingleQuery(
			unit, circuit->GetThreatMap(),
			startPos, endPos, range/*, nullptr, minThreat*/);
	pathQueries[unit] = query;

	pathfinder->RunQuery(circuit->GetScheduler().get(), query, [this](const IPathQuery* query) {
		this->ApplyPath(static_cast<const CQueryPathSingle*>(query));
	});
}

void CRetreatTask::Update()
{
	CCircuitAI* circuit = manager->GetCircuit();
	const int frame = circuit->GetLastFrame();
	bool isExecute = (++updCount % 2 == 0);
	auto assignees = units;
	for (CCircuitUnit* unit : assignees) {
        if(HoldInJam(unit)) continue;
		const float healthPerc = unit->GetHealthPercent();
		bool isRepaired = unit->HasShield()
				? (healthPerc > 0.98f) && unit->IsShieldCharged(circuit->GetSetupManager()->GetFullShield())
				: healthPerc > 0.98f;

		CCircuitDef* cdef = unit->GetCircuitDef();
		if(circuit->GetCommanderControl()->EnergyRetreat(unit)
            || circuit->GetCommanderControl()->HealthRetreat(unit)) {
            Start(unit);continue;
        }
		if (isRepaired && !unit->IsDisarmed(frame)) {
			Recovered(unit);
		} else if (unit->IsForceUpdate(frame) || isExecute) {
			Start(unit);
		} else if ((circuit->GetBindedRole(cdef->GetMainRole()) == ROLE_TYPE(BUILDER))
			&& (!cdef->IsRoleComm() || (healthPerc >= cdef->GetRetreat()))
			&& (circuit->GetInflMap()->GetEnemyInflAt(unit->GetPos(frame)) < INFL_EPS))
		{
			Recovered(unit);
		}
	}
}

void CRetreatTask::Finish()
{
	Cancel();
}

void CRetreatTask::Cancel()
{
	if (repairer != nullptr) {
		IUnitTask* repairerTask = repairer->GetTask();
		repairerTask->GetManager()->AbortTask(repairerTask);
	}
}

bool CRetreatTask::HoldValid(CCircuitUnit* unit, int frame)
{
	CCircuitAI* circuit = manager->GetCircuit();
	const AIFloat3& hold = unit->GetRetreatHold();
	const bool valid = frame < unit->GetRetreatHoldUntil()
		&& geom::is_valid(hold) && std::isfinite(hold.x) && std::isfinite(hold.z)
		&& hold.x >= 0.f && hold.z >= 0.f
		&& hold.x < CTerrainManager::GetTerrainWidth() && hold.z < CTerrainManager::GetTerrainHeight()
		&& circuit->GetTerrainManager()->CanReachAt(unit, hold, HOLD_RADIUS)
		&& circuit->GetThreatMap()->GetThreatAt(unit, hold) <= circuit->GetThreatMap()->GetThreatAt(unit, unit->GetPos(frame));
	if (!valid) unit->ClearRetreatHold();
	return valid;
}

void CRetreatTask::OnUnitIdle(CCircuitUnit* unit)
{
    if(HoldInJam(unit)) return;
	CCircuitAI* circuit = manager->GetCircuit();
	const int frame = circuit->GetLastFrame();
	// D-346: at the forward repair point, wait there (idle heal plus the
	// mobile repair task) until Update sees the unit repaired. If the point
	// is no longer valid (threatened, expired), fall through to the haven.
	if (unit->GetRetreatHoldUntil() >= 0) {
		if (unit->GetPos(frame).SqDistance2D(unit->GetRetreatHold()) <= SQUARE(HOLD_RADIUS) && HoldValid(unit, frame)) {
			if (unit->GetTravelAct() != nullptr) unit->GetTravelAct()->StateFinish();
			return;
		}
		if (HoldValid(unit, frame)) { Start(unit); return; }
	}
    AIFloat3 commanderStation;
    if (circuit->GetCommanderControl() && circuit->GetCommanderControl()->RetreatStation(unit, commanderStation)) {
        // Reaching repair range is not reaching safety from the T3. Keep the
        // existing route owner; do not patrol back toward the threatened haven.
        if (unit->GetPos(frame).SqDistance2D(commanderStation)>SQUARE(64.f)) Start(unit);
        else {
            if (unit->GetTravelAct()) unit->GetTravelAct()->StateFinish();
            state=State::REGROUP;
        }
        return;
    }
    // Idle can arrive while the first asynchronous route is pending. Preserve
    // that request; only arrival/expiry/failed validation consumes the stage.
    if (unit->GetRetreatAnchor() >= 0) {
        constexpr float arrivalRadius = 128.f;
        if (unit->GetTravelAct() != nullptr && !unit->GetTravelAct()->IsFinished()
            && frame < unit->GetRetreatWaypointUntil()
            && unit->GetPos(frame).SqDistance2D(unit->GetRetreatWaypoint()) > SQUARE(arrivalRadius)) {
            Start(unit);
            if (unit->GetRetreatAnchor() >= 0) return;
        }
        unit->ClearRetreatWaypoint();
    }

	CCircuitDef* cdef = unit->GetCircuitDef();
	if (cdef->IsAbleToFly()) {
		// NOTE: unit considered idle after boost and find_pad
		if (State::REGROUP == state) {
			state = State::ROAM;
			return;
		}
		if (unit->GetTravelAct() != nullptr) {
			unit->GetTravelAct()->StateFinish();
		}

		unit->SetTaskFrame(frame);  // avoid UnitIdle on find_pad
		TRY_UNIT(circuit, unit,
			unit->CmdFindPad(frame + FRAMES_PER_SEC * 60);
		)
		state = State::REGROUP;
		return;
	}

	CFactoryManager* factoryMgr = circuit->GetFactoryManager();
	AIFloat3 haven = (repairer != nullptr) ? repairer->GetPos(frame) : factoryMgr->GetClosestHaven(unit);
	if (!geom::is_valid(haven)) {
		haven = circuit->GetSetupManager()->GetBasePos();
	}

	const float maxDist = factoryMgr->GetAssistRange();
	const AIFloat3& unitPos = unit->GetPos(frame);
	if (unitPos.SqDistance2D(haven) > SQUARE(maxDist)) {
		// TODO: push MoveAction into unit? to avoid enemy fire
		TRY_UNIT(circuit, unit,
			unit->CmdMoveTo(haven, UNIT_COMMAND_OPTION_RIGHT_MOUSE_KEY, frame + FRAMES_PER_SEC * 1);
		)
		// TODO: Add fail counter?
	} else {
		if ((circuit->GetBindedRole(cdef->GetMainRole()) == ROLE_TYPE(BUILDER))
			&& (circuit->GetBuilderManager()->GetWorkerCount() <= 2))
		{
			Recovered(unit);
			return;
		}

		// TODO: push WaitAction into unit
		if (/*cdef->GetDef()->IsAbleToAssist() || */cdef->IsAbleToRepair()) {
			AIFloat3 pos = unitPos;
			if (unit->GetUnit()->IsCloaked()) {
				pos += AIFloat3(SQUARE_SIZE * 2, 0, SQUARE_SIZE * 2);  // don't move, but assist if required
				CTerrainManager::CorrectPosition(pos);
			} else {
				const float size = SQUARE_SIZE * 16;
				CTerrainManager* terrainMgr = circuit->GetTerrainManager();
				float centerX = terrainMgr->GetTerrainWidth() / 2;
				float centerZ = terrainMgr->GetTerrainHeight() / 2;
				pos.x += (pos.x > centerX) ? size : -size;
				pos.z += (pos.z > centerZ) ? size : -size;
				AIFloat3 oldPos = pos;
				CTerrainManager::CorrectPosition(pos);
				if (oldPos.SqDistance2D(pos) > SQUARE_SIZE * SQUARE_SIZE) {
					pos = unitPos;
					pos.x += (pos.x > centerX) ? -size : size;
					pos.z += (pos.z > centerZ) ? -size : size;
				}
				CTerrainManager::TerrainPredicate predicate = [unitPos](const AIFloat3& p) {
					return unitPos.SqDistance2D(p) > SQUARE(SQUARE_SIZE * 8);
				};
				AIFloat3 freePos = terrainMgr->FindBuildSite(cdef, pos, maxDist, UNIT_NO_FACING, predicate, true);
//				AIFloat3 freePos = terrainMgr->FindSpringBuildSite(cdef, pos, maxDist, UNIT_NO_FACING, predicate);
				pos = geom::is_valid(freePos) ? freePos : pos;
			}
			TRY_UNIT(circuit, unit,
//				unit->CmdPriority(0);
				unit->CmdPatrolTo(pos);
			)
		}

		if (unit->GetTravelAct() != nullptr) {
			unit->GetTravelAct()->StateFinish();
		}
		state = State::REGROUP;
	}
}

void CRetreatTask::OnUnitDamaged(CCircuitUnit* unit, CEnemyInfo* attacker)
{
    if(HoldInJam(unit)) return;
	if (State::REGROUP != state) {
		return;
	}
	state = State::ROAM;

	if (unit->GetTravelAct() == nullptr) {
		// NOTE: IsAttrBoost units don't get travel action on AssignTo
		int squareSize = manager->GetCircuit()->GetPathfinder()->GetSquareSize();
		CCircuitDef* cdef = unit->GetCircuitDef();
		ITravelAction* travelAction;
		if (cdef->IsAttrRetFight()) {
			travelAction = new CFightAction(unit, squareSize);
		} else {
			travelAction = new CMoveAction(unit, squareSize);
		}
		unit->PushTravelAct(travelAction);
		unit->SetAllowedToJump(cdef->IsAbleToJump() && !cdef->IsAttrNoJump());
	}
	unit->GetTravelAct()->StateActivate();

	Start(unit);
}

void CRetreatTask::OnUnitDestroyed(CCircuitUnit* unit, CEnemyInfo* attacker)
{
	RemoveAssignee(unit);
}

void CRetreatTask::CheckRepairer(CCircuitUnit* newRep)
{
	CCircuitUnit* unit = *units.begin();
	if (unit->GetCircuitDef()->IsRoleComm()) {
		return;
	}

	if ((costQuery != nullptr) && (costQuery->GetState() != IPathQuery::State::READY)) {  // not ready
		return;
	}

	CCircuitAI* circuit = manager->GetCircuit();
	const AIFloat3& startPos = unit->GetPos(circuit->GetLastFrame());

	CPathFinder* pathfinder = circuit->GetPathfinder();
	costQuery = pathfinder->CreateCostMapQuery(
			unit, circuit->GetThreatMap(), startPos);

	CCircuitUnit::Id newRepId = newRep->GetId();
	pathfinder->RunQuery(circuit->GetScheduler().get(), costQuery, [this, newRepId](const IPathQuery* query) {
		CCircuitUnit* newRep = this->ValidateNewRepairer(query, newRepId);
		if (newRep != nullptr) {
			this->ApplyCostMap(static_cast<const CQueryCostMap*>(query), newRep);
		}
	});
}

void CRetreatTask::Dead()
{
	costQuery = nullptr;
	IUnitTask::Dead();
}

void CRetreatTask::Recovered(CCircuitUnit* unit)
{
	TRY_UNIT(manager->GetCircuit(), unit,
		if (unit->GetCircuitDef()->IsAbleToCloak()
			&& unit->GetCircuitDef()->GetCloakCost() > manager->GetCircuit()->GetEconomyManager()->GetAvgEnergyIncome() * 0.1f)
		{
			unit->CmdCloak(manager->GetCircuit()->GetCommanderControl()->FogCloak(unit));
		}
		unit->CmdSetFireState(unit->GetCircuitDef()->GetFireState());
	)

	RemoveAssignee(unit);
}

void CRetreatTask::ApplyPath(const CQueryPathSingle* query)
{
	const std::shared_ptr<CPathInfo>& pPath = query->GetPathInfo();
	CCircuitUnit* unit = query->GetUnit();
    if(HoldInJam(unit)) return;

	if (pPath->posPath.empty()) {
		pPath->PushPos(query->GetEndPos(), manager->GetCircuit()->GetPathfinder());
	}
	unit->GetTravelAct()->SetPath(pPath);
}

CCircuitUnit* CRetreatTask::ValidateNewRepairer(const IPathQuery* query, int newRepId) const
{
	CCircuitUnit* newRep = manager->GetCircuit()->GetTeamUnit(newRepId);
	if (newRep == nullptr) {
		return nullptr;
	}
	if (newRep->GetTask()->GetType() != IUnitTask::Type::BUILDER) {
		return nullptr;
	}
	IBuilderTask* taskB = static_cast<IBuilderTask*>(newRep->GetTask());
	if ((taskB->GetBuildType() != IBuilderTask::BuildType::REPAIR) || (taskB->GetTarget() != query->GetUnit())) {
		return nullptr;
	}
	return newRep;
}

void CRetreatTask::ApplyCostMap(const CQueryCostMap* query, CCircuitUnit* newRep)
{
	CCircuitAI* circuit = manager->GetCircuit();
	const int frame = circuit->GetLastFrame();
	CPathFinder* pathfinder = circuit->GetPathfinder();
	CCircuitUnit* unit = query->GetUnit();
	AIFloat3 endPos;
	float range;

	bool isRepairer = (repairer != nullptr);
	if (isRepairer) {
		endPos = repairer->GetPos(frame);
		range = pathfinder->GetSquareSize();
	} else {
		CFactoryManager* factoryMgr = circuit->GetFactoryManager();
		endPos = factoryMgr->GetClosestHaven(unit);
		if (!geom::is_valid(endPos)) {
			endPos = circuit->GetSetupManager()->GetBasePos();
		}
		range = factoryMgr->GetAssistRange() * 0.6f + pathfinder->GetSquareSize();
	}

	float prevCost = query->GetCostAt(endPos, range);
	if (isRepairer && repairer->GetCircuitDef()->IsMobile()) {
		prevCost /= 2;
	}

	endPos = unit->GetPos(frame);
	float nextCost = query->GetCostAt(endPos, range);
	if (unit->GetCircuitDef()->IsMobile()) {
		nextCost /= 2;
	}

	if (prevCost > nextCost) {
		SetRepairer(newRep);
	}
}

} // namespace circuit
