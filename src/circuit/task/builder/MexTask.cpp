/*
 * MexTask.cpp
 *
 *  Created on: Jan 31, 2015
 *      Author: rlcevg
 */

#include "task/builder/MexTask.h"
#include "module/EconomyManager.h"
#include "module/BuilderManager.h"
#include "module/MilitaryManager.h"
#include "resource/MetalManager.h"
#include "terrain/TerrainManager.h"
#include "CircuitAI.h"
#include "util/Utils.h"

#include "spring/SpringCallback.h"
#include "spring/SpringMap.h"

#include "AISCommands.h"
#include "Log.h"
#include <cstdlib>

namespace circuit {

using namespace springai;

CBMexTask::CBMexTask(ITaskModule* mgr, Priority priority,
					 CCircuitDef* buildDef, int spotId, const AIFloat3& position,
					 SResource cost, int timeout)
		: IBuilderTask(mgr, priority, buildDef, position, Type::BUILDER, BuildType::MEX, cost, 0.f, timeout)
		, spotId(spotId)
		, blockCount(0)
{
	SetBuildPos(position);
	if (spotId == metal_field::SiteTagV1) {
		if (!manager->GetCircuit()->GetEconomyManager()->ClaimFieldSite(fieldKey, buildDef, buildPos)) fieldKey = 0;
		ignoreAlly = true; // field service already validates ownership and full footprints
	}
	manager->GetCircuit()->GetEconomyManager()->SetOpenMexSpot(spotId, false);
}

CBMexTask::CBMexTask(ITaskModule* mgr)
		: IBuilderTask(mgr, Type::BUILDER, BuildType::MEX)
		, spotId(-1)
		, blockCount(0)
{
}

CBMexTask::~CBMexTask()
{
}

bool CBMexTask::CanAssignTo(CCircuitUnit* unit) const
{
	auto* economy = manager->GetCircuit()->GetEconomyManager();
	if (economy->IsMexNavigationEnabled() && (!economy->CanReachMex(unit, buildPos)
			|| (target == nullptr && !economy->IsOwnSpot(buildPos)))) return false;
	// can unit build at all
	const CCircuitDef* cdef = unit->GetCircuitDef();
	if (((target == nullptr) || !cdef->IsAbleToAssist() || unit->IsAttrSolo()) && !cdef->CanBuild(buildDef)) {
		return false;
	}
	// is extra buildpower required?
	CCircuitAI* circuit = manager->GetCircuit();
	CEconomyManager* economyMgr = circuit->GetEconomyManager();
	if (cost.metal < buildPower.metal * buildDef->GetGoalBuildTime(economyMgr->GetAvgMetalIncome())) {  // upper metal bound
		return false;
	}
	// energy income check
	if ((target == nullptr) && !economyMgr->IsEnoughEnergyIncome(buildDef, cdef)
		&& !economyMgr->IsEnoughEnergy(this, cdef, 0.8f))  // lower energy bound
	{
		return false;
	}
	// solo/initiator check
	if (unit->IsAttrSolo() && (initiator != unit) && ((initiator != nullptr) || (target != nullptr))) {
		return false;
	}

	if (unit->GetCircuitDef()->IsAttacker()) {
		return true;
	}
	CMilitaryManager* militaryMgr = circuit->GetMilitaryManager();
	if ((militaryMgr->GetGuardTaskNum() == 0) || (circuit->GetLastFrame() > militaryMgr->GetGuardFrame())) {
		return true;
	}
	int cluster = circuit->GetMetalManager()->FindNearestCluster(buildPos);
	if ((cluster < 0) || militaryMgr->HasDefence(cluster)) {
		return true;
	}
	IUnitTask* guard = militaryMgr->GetGuardTask(unit);
	return (guard != nullptr) && !guard->GetAssignees().empty();
}

void CBMexTask::Stop(bool done)
{
	IBuilderTask::Stop(done);
	if (fieldKey != 0) manager->GetCircuit()->GetEconomyManager()->ReleaseFieldSite(fieldKey);
	fieldKey = 0;
}

void CBMexTask::Cancel()
{
	if (spotId == metal_field::SiteTagV1) {
		// Field mexes can own persistent layout pins. The legacy spot-only
		// cleanup below never returned served/claimed pins after cancellation.
		IBuilderTask::Cancel();
		return;
	}
	if ((target == nullptr) && geom::is_valid(buildPos)) {
		CCircuitAI* circuit = manager->GetCircuit();
		if (spotId >= 0) {  // for broken Load
			circuit->GetMetalManager()->SetOpenSpot(spotId, true);
			circuit->GetEconomyManager()->SetOpenMexSpot(spotId, true);
		}
		IBuilderTask::SetBuildPos(-RgtVector);
	}
}

bool CBMexTask::Execute(CCircuitUnit* unit)
{
	executors.insert(unit);

	CCircuitAI* circuit = manager->GetCircuit();
	TRY_UNIT(circuit, unit,
		unit->CmdPriority(ClampPriority());
	)

	const int frame = circuit->GetLastFrame();
	if (target != nullptr) {
		TRY_UNIT(circuit, unit,
			unit->CmdRepair(target, UNIT_CMD_OPTION, CmdTimeout(frame));
		)
		return true;
	}
	// Recheck unstarted work at the command boundary: roster/terrain can change
	// after selection, and explicit script-created tasks may bypass selectors.
	// Keep an existing frame productive; abort returns the claim through Cancel.
	auto* admission = circuit->GetEconomyManager();
	if (admission->IsMexNavigationEnabled()
			&& (!admission->IsOwnSpot(buildPos) || !admission->CanReachMex(unit, buildPos))) {
		// This unstarted task owns only its local spot claim. Do not reopen
		// the shared occupancy bit if an ally has since built on the spot.
		if (spotId >= 0) { admission->SetOpenMexSpot(spotId, true); spotId = -1; }
		manager->AbortTask(this);
		return false;
	}
	CMetalManager* metalMgr = circuit->GetMetalManager();
	CEconomyManager* economyMgr = circuit->GetEconomyManager();
	if (spotId == metal_field::SiteTagV1 && pinRequired && reservationId < 0) {
		FindBuildSite(unit, position, 0.f);
		if (pinFailed || reservationId < 0) { manager->AbortTask(this); return false; }
	}
	if (!circuit->GetTerrainManager()->IsAllyLayoutBlocked(buildDef, buildPos, facing)
        && circuit->GetMap()->IsPossibleToBuildAt(buildDef->GetDef(), buildPos, facing)) {
		if ((spotId == metal_field::SiteTagV1) ? economyMgr->OwnsFieldSite(fieldKey)
			: ((State::ENGAGE == state) || metalMgr->IsOpenSpot(spotId))) {
			state = State::ENGAGE;  // isFirstTry = false
//			metalMgr->SetOpenSpot(index, false);
			TRY_UNIT(circuit, unit,
				unit->CmdBuild(buildDef, buildPos, facing, 0, CmdTimeout(frame));
			)
			return true;
		} else {
			economyMgr->SetOpenMexSpot(spotId, true);
		}
	} else {
		if (spotId == metal_field::SiteTagV1) { manager->AbortTask(this); return false; }
		metalMgr->SetOpenSpot(spotId, true);
		economyMgr->SetOpenMexSpot(spotId, true);
		if (!CheckLandBlock(unit)) {
			// Fallback to Guard/Assist/Patrol
			manager->FallbackTask(unit);
			return false;
		}
	}
	return true;
}

bool CBMexTask::Reevaluate(CCircuitUnit* unit)
{
	CCircuitAI* circuit = manager->GetCircuit();
	// The ally-zone abort below dropped TECH's opening mexes mid-construction
	// as allies' first structures were marked (D-063 follow-up); a home order
	// is exempt.
	if (circuit->IsAllyAware() && !ignoreAlly) {
		auto closeTask = [this, circuit]() {
			circuit->GetEconomyManager()->SetOpenMexSpot(spotId, true);
			spotId = -1;  // no ownership: valid spot zero belongs to someone else
			manager->AbortTask(this);
			return false;
		};
		if (!circuit->GetEconomyManager()->IsMexNavigationEnabled()
				&& circuit->GetTerrainManager()->IsZoneAlly(buildPos)) {
			static const bool trace = std::getenv("CIRCUIT_BUILD_TRACE") != nullptr;
			if (trace) circuit->LOG("MEX_REJECT: team=%d worker=%d reason=ally-zone pos=%.0f,%.0f", circuit->GetTeamId(),unit->GetId(),buildPos.x,buildPos.z);
			return closeTask();
		}
		auto& ids = circuit->GetCallback()->GetFriendlyUnitIdsIn(buildPos, buildDef->GetExtrRangeM(), false);
		for (ICoreUnit::Id id : ids) {
			CAllyUnit* au = circuit->GetFriendlyUnit(id);
			if ((au != nullptr) && au->GetCircuitDef()->IsMex()
				&& (au->GetUnit()->GetTeam() != circuit->GetTeamId()))
			{
				static const bool trace = std::getenv("CIRCUIT_BUILD_TRACE") != nullptr;
				if (trace) circuit->LOG("MEX_REJECT: team=%d worker=%d reason=ally-mex owner=%d pos=%.0f,%.0f", circuit->GetTeamId(),unit->GetId(),au->GetUnit()->GetTeam(),buildPos.x,buildPos.z);
				return closeTask();
			}
		}
	}
	return IBuilderTask::Reevaluate(unit);
}

void CBMexTask::OnUnitIdle(CCircuitUnit* unit)
{
	if ((target == nullptr) && (State::ENGAGE == state)) {
		const bool isBlocked = manager->GetCircuit()->GetTerrainManager()->IsWaterSector(buildPos)
				? CheckWaterBlock(unit)
				: CheckLandBlock(unit);
		if (isBlocked) {
			return;
		}
	}

	IBuilderTask::OnUnitIdle(unit);
}

void CBMexTask::SetBuildPos(const AIFloat3& pos)
{
	FindFacing(pos);
	// NOTE: May require replacing IBuilderTask::SetBuildPos(pos); and saving raw pos in buildPos
	// because cmd_mex_denier.lua can't into multiples of 16
	// Downside is MexUpTask would also require changes.
	IBuilderTask::SetBuildPos(pos);
}

bool CBMexTask::CheckLandBlock(CCircuitUnit* unit)
{
	/*
	 * Check if unit is idle because of enemy mex ahead and build turret if so.
	 */
	if (blockCount > 2) {
		return false;
	}
	CCircuitAI* circuit = manager->GetCircuit();

	const float range = unit->GetCircuitDef()->GetLosRadius();
	const int frame = circuit->GetLastFrame();
	const AIFloat3& pos = unit->GetPos(frame);
	const float sqPosDist = buildPos.SqDistance2D(pos);
	if (sqPosDist > SQUARE(range + 200.0f)) {
		return false;
	}
	++blockCount;

	COOAICallback* clb = circuit->GetCallback();
	bool isNeutral = false;
	auto& neutrals = clb->GetNeutralUnitsIn(buildPos, SQUARE_SIZE * 8);
	for (Unit* n : neutrals) {
		CCircuitDef* ndef = circuit->GetCircuitDefSafe(clb->Unit_GetDefId(n->GetUnitId()));
		if ((ndef == nullptr) || ndef->IsReclaimable()) {
			isNeutral = true;
			state = State::REGROUP;
			TRY_UNIT(circuit, unit,
				unit->GetUnit()->ReclaimUnit(n);
			);
			break;
		}
	}
	utils::free(neutrals);
	if (isNeutral) {
		return true;
	}

	CEnemyInfo* enemy = nullptr;
	auto& enemies = clb->GetEnemyUnitIdsIn(buildPos, SQUARE_SIZE * 8);
	for (ICoreUnit::Id enemyId : enemies) {
		CEnemyInfo* e = circuit->GetEnemyInfo(enemyId);
		if (e == nullptr) {
			continue;
		}
		CCircuitDef* edef = e->GetCircuitDef();
		if ((edef == nullptr) || edef->IsReclaimable()) {
			enemy = e;
			break;
		}
	}

	if (enemy != nullptr) {
		state = State::REGROUP;
		TRY_UNIT(circuit, unit,
			unit->CmdReclaimEnemy(enemy);
		);
		return true;
	}

	bool blocked = sqPosDist < SQUARE(unit->GetCircuitDef()->GetBuildDistance() + SQUARE_SIZE);
	if (blocked && clb->IsFriendlyUnitsIn(buildPos, SQUARE_SIZE * 8)) {
		blocked = false;
	}
	if (blocked) {
		AIFloat3 dir = (buildPos - pos).Normalize2D();
		const float step = unit->GetCircuitDef()->GetBuildDistance() / 4;
		TRY_UNIT(circuit, unit,
			unit->CmdMoveTo(pos + dir * step);
			for (int i = 2; i < 4; ++i) {
				AIFloat3 newPos = pos + dir * (step * i);
				unit->CmdMoveTo(newPos, UNIT_COMMAND_OPTION_SHIFT_KEY);
			}
			unit->CmdBuild(buildDef, buildPos, facing, UNIT_COMMAND_OPTION_SHIFT_KEY, CmdTimeout(frame));
		);
		return true;
	}

	return false;
}

bool CBMexTask::CheckWaterBlock(CCircuitUnit* unit)
{
	/*
	 * Check if unit is idle because of enemy mex ahead and build turret if so.
	 */
	CCircuitAI* circuit = manager->GetCircuit();
	CCircuitDef* def = circuit->GetMilitaryManager()->GetLowSonar(unit);
	if (def == nullptr) {
		return false;
	}

	const float range = def->GetSonarRadius();
	const float testRange = range + 200.0f;  // 200 elmos
	const AIFloat3& pos = unit->GetPos(circuit->GetLastFrame());
	const float sqPosDist = buildPos.SqDistance2D(pos);
	if (sqPosDist > SQUARE(testRange)) {
		return false;
	}

	COOAICallback* clb = circuit->GetCallback();
	bool blocked = sqPosDist < SQUARE(unit->GetCircuitDef()->GetBuildDistance() + SQUARE_SIZE);
	if (blocked && clb->IsFriendlyUnitsIn(buildPos, SQUARE_SIZE)) {
		blocked = false;
	}
	if (!blocked && clb->IsEnemyUnitsIn(buildPos, SQUARE_SIZE)) {
		blocked = true;
	}
	if (!blocked) {
		return false;
	}

	// TODO: send sonar scout to position
	CBuilderManager* builderMgr = circuit->GetBuilderManager();
	IBuilderTask* task = nullptr;
	const float qdist = SQUARE(200.0f);  // 200 elmos
	// TODO: Push tasks into bgi::rtree
	for (IBuilderTask* t : builderMgr->GetTasks(IBuilderTask::BuildType::DEFENCE)) {
		if (pos.SqDistance2D(t->GetTaskPos()) < qdist) {
			task = t;
			break;
		}
	}
	if (task == nullptr) {
//		AIFloat3 newPos = AIFloat3(buildPos - (buildPos - pos).Normalize2D() * (unit->GetCircuitDef()->GetBuildDistance() * 0.9f));
//		CTerrainManager::CorrectPosition(newPos);
		task = builderMgr->Enqueue(TaskB::Common(IBuilderTask::BuildType::DEFENCE,
								   IBuilderTask::Priority::NOW, def, pos/*newPos*/, 0.f, true));
	}
	manager->AssignTask(unit, task);
	return true;
}

#define SERIALIZE(stream, func)	\
	utils::binary_##func(stream, spotId);

bool CBMexTask::Load(std::istream& is)
{
	const bool baseValid = IBuilderTask::Load(is);
	SERIALIZE(is, read)

	CCircuitAI* circuit = manager->GetCircuit();
	if (spotId == metal_field::SiteTagV1) {
		utils::binary_read(is, fieldKey);
		ignoreAlly = true;
		return baseValid && bool(is) && circuit->GetEconomyManager()->ClaimFieldSite(fieldKey, buildDef, buildPos);
	}
	if (!circuit->GetMetalManager()->IsSpotValid(spotId, GetPosition())) {
		spotId = -1;
#ifdef DEBUG_SAVELOAD
		manager->GetCircuit()->LOG("%s | spotId=%i", __PRETTY_FUNCTION__, spotId);
#endif
		return false;
	}
	circuit->GetEconomyManager()->SetOpenMexSpot(spotId, false);
#ifdef DEBUG_SAVELOAD
	manager->GetCircuit()->LOG("%s | spotId=%i", __PRETTY_FUNCTION__, spotId);
#endif
	return true;
}

void CBMexTask::Save(std::ostream& os) const
{
	IBuilderTask::Save(os);
	SERIALIZE(os, write)
	if (spotId == metal_field::SiteTagV1) utils::binary_write(os, fieldKey);
#ifdef DEBUG_SAVELOAD
	manager->GetCircuit()->LOG("%s | spotId=%i", __PRETTY_FUNCTION__, spotId);
#endif
}

} // namespace circuit
