/*
 * SupportTask.cpp
 *
 *  Created on: Jul 3, 2016
 *      Author: rlcevg
 */

#include "task/fighter/SupportTask.h"
#include "task/fighter/SquadTask.h"
#include "task/fighter/RangedWorld.h"
#include "module/MilitaryManager.h"
#include "setup/SetupManager.h"
#include "terrain/TerrainManager.h"
#include "terrain/path/PathFinder.h"
#include "terrain/path/QueryPathMulti.h"
#include "terrain/path/QueryPathSingle.h"
#include "unit/CircuitUnit.h"
#include "CircuitAI.h"
#include "spring/SpringUnit.h"
#include "util/Utils.h"

#include "AISCommands.h"

#include <algorithm>

namespace circuit {

using namespace springai;

CSupportTask::CSupportTask(ITaskModule* mgr)
		: IFighterTask(mgr, FightType::SUPPORT, 1.f)
{
	const AIFloat3& pos = manager->GetCircuit()->GetSetupManager()->GetBasePos();
	position = geom::get_radial_pos(pos, SQUARE_SIZE * 32);
}

CSupportTask::~CSupportTask()
{
}

void CSupportTask::RemoveAssignee(CCircuitUnit* unit)
{
	if (rangedEscort) {
		static_cast<CMilitaryManager*>(manager)->GetRangedWorld()->ReleaseEscort(unit->GetId());
		rangedEscort = false;
		++escortGeneration; escortPath.clear();
	}
	IFighterTask::RemoveAssignee(unit);
	if (units.empty()) {
		manager->AbortTask(this);
	}
}

void CSupportTask::Start(CCircuitUnit* unit)
{
	if (TryRangedEscort(unit)) return;
	if (State::DISENGAGE == state) {
		return;
	}

	CCircuitAI* circuit = manager->GetCircuit();
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	AIFloat3 pos = position;
	CTerrainManager::CorrectPosition(pos);
	AIFloat3 freePos = terrainMgr->FindBuildSite(unit->GetCircuitDef(), pos, 300.0f, UNIT_NO_FACING, true);
//	AIFloat3 freePos = terrainMgr->FindSpringBuildSite(unit->GetCircuitDef(), pos, 300.0f, UNIT_NO_FACING);
	pos = geom::is_valid(freePos) ? freePos : pos;

	TRY_UNIT(circuit, unit,
		unit->CmdFightTo(pos, UNIT_COMMAND_OPTION_RIGHT_MOUSE_KEY, circuit->GetLastFrame() + FRAMES_PER_SEC * 60);
		unit->CmdWantedSpeed(NO_SPEED_LIMIT);
	)
	state = State::DISENGAGE;  // Wait
}

bool CSupportTask::ForgetUnit(CCircuitUnit* unit)
{
	// This callback is broadcast for unrelated allies too.
	if (rangedEscort && units.count(unit)) {
		static_cast<CMilitaryManager*>(manager)->GetRangedWorld()->ReleaseEscort(unit->GetId());
		rangedEscort=false; ++escortGeneration; escortPath.clear();
	}
	return IFighterTask::ForgetUnit(unit);
}

void CSupportTask::Stop(bool done)
{
	escortLifetime.reset(); ++escortGeneration;
	if (rangedEscort) {
		auto world=static_cast<CMilitaryManager*>(manager)->GetRangedWorld();
		for (auto* unit:units) world->ReleaseEscort(unit->GetId());
	}
	rangedEscort=false; escortPath.clear();
	IFighterTask::Stop(done);
}

bool CSupportTask::TryRangedEscort(CCircuitUnit* unit)
{
	auto* military = static_cast<CMilitaryManager*>(manager);
	if (!military->IsSensorUnit(unit->GetCircuitDef())) return false;
	if (!military->HasRangedUnits()) {
		if (rangedEscort) {
			military->GetRangedWorld()->ReleaseEscort(unit->GetId());
			pathQueries.erase(unit); ++escortGeneration; escortPath.clear(); rangedEscort=false;
			TRY_UNIT(manager->GetCircuit(),unit,unit->CmdStop();)
		}
		return false;
	}
	auto world = military->GetRangedWorld();
	AIFloat3 dest;
	if (!world->Escort(unit, dest)) {
		if (rangedEscort) {
			pathQueries.erase(unit); rangedEscort=false; ++escortGeneration; escortPath.clear();
			TRY_UNIT(manager->GetCircuit(),unit,unit->CmdStop();)
		}
		return false;
	}
	// Artillery tasks are not ISquadTask. Retain support ownership instead of
	// adding them to FindCandidates and using its squad-only static_cast.
	auto* circuit = manager->GetCircuit();
	const auto pos=unit->GetPos(circuit->GetLastFrame());
	while (escortCursor<escortPath.size() && (pos.SqDistance2D(escortPath[escortCursor])<4096.f
		|| (escortCursor+1<escortPath.size() && pos.SqDistance2D(escortPath[escortCursor+1])<pos.SqDistance2D(escortPath[escortCursor])))) ++escortCursor;
	AIFloat3 from=pos;
	for (size_t i=escortCursor;i<escortPath.size();++i) {
		if (!world->Safe(from,escortPath[i],32.f,true)) {
			TRY_UNIT(circuit,unit,unit->CmdStop();)
			escortPath.clear(); pathQueries.erase(unit); ++escortGeneration; break;
		}
		from=escortPath[i];
	}
	if (pos.SqDistance2D(dest)<4096.f) {
		if (rangedEscort && circuit->GetUnitAPI()->GetCMDQueueSize(unit->GetId())>0) {
			TRY_UNIT(circuit,unit,unit->CmdStop();)
		}
		pathQueries.erase(unit); ++escortGeneration; escortPath.clear(); rangedEscort=true; return true;
	}
	if (rangedEscort && escortDestination.SqDistance2D(dest)<4096.f
		&& (pathQueries.count(unit) || circuit->GetUnitAPI()->GetCMDQueueSize(unit->GetId())>0)) return true;
	pathQueries.erase(unit); rangedEscort=true; escortDestination=dest;
	auto* finder=circuit->GetPathfinder();
	// The native path query requires at least one whole coarse-grid cell.
	auto query=finder->CreatePathSingleQuery(unit,circuit->GetThreatMap(),pos,dest,float(finder->GetSquareSize()));
	pathQueries[unit]=query;
	const unsigned version=++escortGeneration;
	const int id=unit->GetId();
	const std::weak_ptr<int> alive=escortLifetime;
	finder->RunQuery(circuit->GetScheduler().get(),query,[this,world,alive,version,id,dest](const IPathQuery* result) {
		if (alive.expired()) return;
		auto* query=static_cast<const CQueryPathSingle*>(result);
		auto* circuit=manager->GetCircuit();
		auto* unit=circuit->GetTeamUnit(id);
		if (!unit || unit->GetTask()!=this || !rangedEscort || version!=escortGeneration) return;
		auto path=query->GetPathInfo()->posPath;
		if (path.empty()) { pathQueries.erase(unit); return; }
		path.push_back(dest);
		AIFloat3 from=unit->GetPos(circuit->GetLastFrame());
		world->Refresh();
		for (const auto& p:path) {
			if (from.SqDistance2D(p)>16.f && !world->Safe(from,p,32.f,true)) {
				pathQueries.erase(unit); return;
			}
			from=p;
		}
		TRY_UNIT(circuit,unit,
			for (size_t i=0;i<path.size();++i) unit->CmdMoveTo(path[i],i?UNIT_COMMAND_OPTION_SHIFT_KEY:0);
		)
		escortPath=std::move(path); escortCursor=0;
		pathQueries.erase(unit);
	});
	return true;
}

/*
 * The squads this unit may join, most worth joining first.
 *
 * Every support unit walks to a squad and joins it outright, and until the
 * sensor cap this picked the nearest one every time - so on a map with one
 * forward squad, every mobile radar and jammer the factory ever made ended up
 * in it (27 radar bots behind a single sharpshooter). A sensor is rationed:
 * squads already at CMilitaryManager::SSensorInfo::maxPerSquad are dropped,
 * and what survives is ordered by squad value so the scarce escorts cover the
 * highest-tier squads first. The caller hands the best few to the pathfinder
 * and lets it choose the nearest of them, which keeps a sensor from crossing
 * the map to reach a marginally better squad.
 *
 * Non-sensor support units are unaffected: they get every candidate, in the
 * arbitrary order the task set yields, exactly as before.
 */
void CSupportTask::FindCandidates(CCircuitUnit* unit, const std::set<IFighterTask*>& tasks,
		std::vector<IFighterTask*>& outTasks) const
{
	CMilitaryManager* militaryMgr = static_cast<CMilitaryManager*>(manager);
	CCircuitAI* circuit = manager->GetCircuit();
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	const int frame = circuit->GetLastFrame();
	const bool isSensor = militaryMgr->IsSensorUnit(unit->GetCircuitDef());

	for (IFighterTask* candy : tasks) {
		ISquadTask* task = static_cast<ISquadTask*>(candy);
		CCircuitUnit* leader = task->GetLeader();
		if (leader == nullptr) {
			continue;
		}
		const AIFloat3& pos = leader->GetPos(frame);
		if (!terrainMgr->CanMoveToPos(unit->GetArea(), pos)) {
			continue;
		}
		if (!((unit->GetCircuitDef()->IsAmphibious() || unit->GetCircuitDef()->IsSurfer())
				&& (leader->GetCircuitDef()->IsAbleToDive() || leader->GetCircuitDef()->IsSurfer()))
			&& !(leader->GetCircuitDef()->IsSubmarine() && unit->GetCircuitDef()->IsSubmarine())
			&& !(/*leader->GetCircuitDef()->IsAbleToFly() && */unit->GetCircuitDef()->IsAbleToFly())
			&& !(leader->GetCircuitDef()->IsLander() && unit->GetCircuitDef()->IsLander())
			&& !(leader->GetCircuitDef()->IsFloater() && unit->GetCircuitDef()->IsFloater()))
		{
			continue;
		}
		if (isSensor && !militaryMgr->NeedsSensor(candy)) {
			continue;  // already escorted; a second adds no coverage
		}
		outTasks.push_back(candy);
	}

	if (!isSensor || outTasks.empty()) {
		return;
	}
	std::sort(outTasks.begin(), outTasks.end(),
			[militaryMgr](const IFighterTask* a, const IFighterTask* b) {
		return militaryMgr->GetSquadValue(a) > militaryMgr->GetSquadValue(b);
	});
	const size_t top = size_t(std::max(1, militaryMgr->GetSensorInfo().topCandidates));
	if (outTasks.size() > top) {
		outTasks.resize(top);
	}
}

void CSupportTask::Update()
{
	if (updCount++ % 8 != 0) {
		return;
	}

	CCircuitUnit* unit = *units.begin();
	if (unit->Blocker() != nullptr) {
		return;  // Do not interrupt current action
	}
	if (TryRangedEscort(unit)) return;

	const std::set<IFighterTask*>& tasksA = static_cast<CMilitaryManager*>(manager)->GetTasks(IFighterTask::FightType::ATTACK);
	const std::set<IFighterTask*>& tasksD = static_cast<CMilitaryManager*>(manager)->GetTasks(IFighterTask::FightType::DEFEND);
	const std::set<IFighterTask*>& tasks = tasksA.empty() ? tasksD : tasksA;
	if (tasks.empty()) {
		Start(unit);
		return;
	}

	CCircuitAI* circuit = manager->GetCircuit();
	const int frame = circuit->GetLastFrame();

	std::vector<IFighterTask*> candidates;
	FindCandidates(unit, tasks, candidates);
	if (candidates.empty()) {
		// For a sensor this is the normal "every squad already has one" case:
		// hold on the base ring instead of piling onto a covered squad.
		Start(unit);
		return;
	}
	urgentPositions.clear();
	urgentPositions.reserve(candidates.size());
	for (IFighterTask* candy : candidates) {
		urgentPositions.push_back(static_cast<ISquadTask*>(candy)->GetLeaderPos(frame));
	}

	if (!IsQueryReady(unit)) {
		return;
	}

	CPathFinder* pathfinder = circuit->GetPathfinder();
	const AIFloat3& startPos = unit->GetPos(frame);
	const float range = pathfinder->GetSquareSize();

	std::shared_ptr<IPathQuery> query = pathfinder->CreatePathMultiQuery(
			unit, circuit->GetThreatMap(),
			startPos, range, urgentPositions, nullptr, false, std::numeric_limits<float>::max(), true);
	pathQueries[unit] = query;

	// A legacy squad-join query can still be in flight when ranged guns appear
	// and this sensor switches to an escort route. Reject that old result using
	// the same ownership/generation contract as the new route, before touching
	// its borrowed unit pointer.
	const std::weak_ptr<int> alive=escortLifetime;
	const unsigned version=escortGeneration;
	const int id=unit->GetId();
	pathfinder->RunQuery(circuit->GetScheduler().get(), query, [this,alive,version,id](const IPathQuery* query) {
		if(alive.expired() || version!=escortGeneration) return;
		auto* unit=manager->GetCircuit()->GetTeamUnit(id);
		if(!unit || unit->GetTask()!=this) return;
		const auto pending=pathQueries.find(unit);
		if(pending==pathQueries.end() || pending->second.get()!=query) return;
		this->ApplyPath(static_cast<const CQueryPathMulti*>(query));
	});
}

void CSupportTask::ApplyPath(const CQueryPathMulti* query)
{
	const std::shared_ptr<CPathInfo>& pPath = query->GetPathInfo();
	CCircuitUnit* unit = query->GetUnit();

	if (pPath->posPath.empty()) {
		Start(unit);
		return;
	}

	const std::set<IFighterTask*>& tasksA = static_cast<CMilitaryManager*>(manager)->GetTasks(IFighterTask::FightType::ATTACK);
	const std::set<IFighterTask*>& tasksD = static_cast<CMilitaryManager*>(manager)->GetTasks(IFighterTask::FightType::DEFEND);
	const std::set<IFighterTask*>& tasks = tasksA.empty() ? tasksD : tasksA;
	if (tasks.empty()) {
		Start(unit);
		return;
	}

	CCircuitAI* circuit = manager->GetCircuit();
	const int frame = circuit->GetLastFrame();
	const AIFloat3& startPos = unit->GetPos(frame);
	const AIFloat3& endPos = pPath->posPath.back();
	if (startPos.SqDistance2D(endPos) < SQUARE(1000.f)) {
		// Re-filter rather than trust the list Update built: the walk took time,
		// and another sensor may have taken the slot meanwhile.
		std::vector<IFighterTask*> candidates;
		FindCandidates(unit, tasks, candidates);
		if (candidates.empty()) {
			Start(unit);
			return;
		}
		// FindCandidates has already ordered a sensor's list by squad value and
		// cut it to the best few, so nearest-of-those is nearest-of-the-best.
		IFighterTask* task = candidates.front();
		float minSqDist = std::numeric_limits<float>::max();
		for (IFighterTask* candy : candidates) {
			float sqDist = endPos.SqDistance2D(static_cast<ISquadTask*>(candy)->GetLeaderPos(frame));
			if (minSqDist > sqDist) {
				minSqDist = sqDist;
				task = candy;
			}
		}
		manager->AssignTask(unit, task);
//		manager->DoneTask(this);  // NOTE: RemoveAssignee will abort task
	} else {
		TRY_UNIT(circuit, unit,
			unit->CmdFightTo(endPos, UNIT_COMMAND_OPTION_RIGHT_MOUSE_KEY, frame + FRAMES_PER_SEC * 60);
		)
		state = State::ROAM;  // Not wait
	}
}

} // namespace circuit
