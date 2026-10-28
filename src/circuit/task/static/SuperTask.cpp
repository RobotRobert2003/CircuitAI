/*
 * SuperTask.cpp
 *
 *  Created on: Aug 12, 2016
 *      Author: rlcevg
 */

#include "task/static/SuperTask.h"
#include "task/fighter/SquadTask.h"
#include "map/InfluenceMap.h"
#include "map/MapManager.h"
#include "module/MilitaryManager.h"
#include "terrain/TerrainManager.h"
#include "unit/enemy/EnemyManager.h"
#include "unit/enemy/EnemyUnit.h"
#include "unit/ally/AllyTeam.h"
#include "unit/ally/AllyUnit.h"
#include "Command.h"
#include "Sim/Units/CommandAI/Command.h"
#include "task/static/StrategicTargeting.h"
#include "task/static/TierTargeting.h"
#include "unit/CircuitUnit.h"
#include "unit/CircuitWDef.h"

#define SMILEY_RADIUS	400.f  // D-124: the face over a nuke's target
#define SMILEY_DEDUPE	(FRAMES_PER_SEC * 5)  // D-124: the stockpile watch draws only if the event did not within this
#define SMILEY_DEDUPE_EVENT	(FRAMES_PER_SEC * 1)  // D-124: two launch signals this close are one launch
#include "CircuitAI.h"
#include "util/Utils.h"
#include "spring/SpringCallback.h"
#include "WeaponMount.h"
#include "WeaponDef.h"

#include "spring/SpringMap.h"

#include "AISCommands.h"
#include "Lua.h"
#include "Log.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <format>
#include <limits>
#include <vector>

namespace circuit {

using namespace springai;

#define TARGET_DELAY	(FRAMES_PER_SEC * 10)

CSuperTask::CSuperTask(ITaskModule* mgr)
		: IFighterTask(mgr, IFighterTask::FightType::SUPER, 1.f)
		, targetFrame(0)
		, targetPos(-RgtVector)
		, isTargetOverride(false)
		, stockSinceFrame(-1)
{
}

CSuperTask::~CSuperTask()
{
}

bool CSuperTask::CanAssignTo(CCircuitUnit* unit) const
{
	return false;
}

void CSuperTask::RemoveAssignee(CCircuitUnit* unit)
{
	manager->GetCircuit()->GetAllyTeam()->GetPulseClaims().ReleasePending(unit->GetId());
	IFighterTask::RemoveAssignee(unit);
	if (units.empty()) {
		manager->AbortTask(this);
	}
}

void CSuperTask::Start(CCircuitUnit* unit)
{
	const int frame = manager->GetCircuit()->GetLastFrame();
	targetFrame = frame - TARGET_DELAY;
	position = unit->GetPos(frame);
}

void CSuperTask::Update()
{
	if (units.empty()) {  // never expected: RemoveAssignee aborts the task on its last unit
		manager->AbortTask(this);
		return;
	}
	CCircuitAI* circuit = manager->GetCircuit();
	const int frame = circuit->GetLastFrame();
	CCircuitUnit* unit = *units.begin();

	// D-124 (owner): a nuclear missile launched: a smiley face on the map over
	// the target. The weapon-fired event is the hook (CCircuitAI::WeaponFired);
	// this stockpile watch is its safety net and draws only when the event did
	// not in the last SMILEY_DEDUPE frames
	if (IsNukeSilo(unit->GetCircuitDef()) || IsPulse(unit->GetCircuitDef())) {
		const int stock = unit->GetUnit()->GetStockpile();
		if ((lastStock >= 0) && (stock < lastStock) && state == State::ENGAGE
			&& strategic::Valid({targetPos.x, targetPos.z}) && (frame - lastStrategicLaunch > SMILEY_DEDUPE)) {
			OnLaunch(unit, "stockpile drop");
		}
		lastStock = stock;
	}

	if (unit->Blocker() != nullptr) {
		return;  // Do not interrupt current action
	}

	if (!tierByDef.empty()) {
		UpdateTiered(unit);
		return;
	}

	CCircuitDef* cdef = unit->GetCircuitDef();
	if (cdef->IsHoldFire()) {
		if (targetFrame + (cdef->GetReloadTime() + TARGET_DELAY) > frame) {
			if ((State::ENGAGE == state) && (targetFrame + TARGET_DELAY <= frame)) {
				TRY_UNIT(circuit, unit,
					unit->CmdStop();
				)
				state = State::ROAM;
			}
			return;
		}
	} else if (targetFrame + TARGET_DELAY > frame) {
		return;
	}

	if (isTargetOverride) {
		ExecuteAttack(unit);
		return;
	}

	CMilitaryManager* policyMgr = circuit->GetMilitaryManager();
	const bool isPulse = IsPulse(cdef);
	const CWeaponDef* empWd = cdef->GetWeaponDef();
	const bool isEmp = !isPulse && policyMgr->GetEmpInfo().isEnabled
			&& cdef->IsRespRoleAny(policyMgr->GetEmpInfo().empRole)
			&& (empWd != nullptr) && empWd->IsParalyzer();
	if (isPulse || isEmp) {
		if (isPulse && unit->GetUnit()->GetStockpile() <= 0) {
			circuit->GetAllyTeam()->GetPulseClaims().ReleasePending(unit->GetId());
			targetFrame = frame;
			return;
		}
		if (isPulse) {
			// Observe allied ground orders too, including human-controlled Junos.
			// This only reads their commands; it never takes control of them.
			const auto& policy = policyMgr->GetPulseInfo();
			for (const auto& [id, ally] : circuit->GetAllyTeam()->GetFriendlyUnits()) {
				if (id == unit->GetId() || ally->GetCircuitDef() == nullptr || !IsPulse(ally->GetCircuitDef())) continue;
				auto commands = ally->GetUnit()->GetCurrentCommands();
				if (!commands.empty() && commands.front()->GetId() == CMD_ATTACK) {
					const auto params = commands.front()->GetParams();
					if (params.size() >= 3) circuit->GetAllyTeam()->GetPulseClaims().Add(id, {params[0], params[2]},
						ally->GetCircuitDef()->GetAoe(), frame, policy.pendingFrames, true);
				}
				utils::free_clear(commands);
			}
		}
		// Neither weapon falls back to the group scan: spending the stockpile on
		// the richest enemy blob, which one cannot damage and the other cannot
		// hold, is worse than waiting for a target that works.
		// A known jammer or radar always wins: its position is certain, so a
		// target deep behind the line is still worth the shot. Only when nothing
		// is known does the weapon fall back to inferring one from a radar hole.
		const bool hasTarget = isPulse
				? (SelectPulseTarget(unit, cdef) || SelectSuspectedJammer(unit, cdef) || SelectFogTarget(unit, cdef))
				: SelectEmpTarget(unit, cdef);
		if (hasTarget) {
			ExecuteAttack(unit);
		} else {
			TRY_UNIT(circuit, unit,
				unit->CmdStop();
			)
			SetTarget(nullptr);
			targetFrame = frame;
		}
		return;
	}
	if (IsNukeSilo(cdef)) {
		if (SelectNuclearTarget(unit, cdef)) ExecuteAttack(unit);
		else {
			TRY_UNIT(circuit, unit, unit->CmdStop();)
			SetTarget(nullptr);
			targetFrame = frame;
		}
		return;
	}

	const float mapDiag = std::sqrt(SQUARE(float(CTerrainManager::GetTerrainWidth())) + SQUARE(float(CTerrainManager::GetTerrainHeight())));
	const bool isRegional = (cdef->GetMaxRange() < mapDiag);

	// A stockpiled launcher whose range does not cover the map - Perdition
	// (2300), Catalyst (2250) - cannot be aimed by the group scan below. Enemy
	// groups are k-means cells, 1 + sqrt(N) of them for the whole map, and a
	// cell's centroid is almost never within 2300 of a static that sits in one
	// of our clusters: every logged tick read inRange=0 while the enemy stood
	// inside reach. Scan units instead, as EMP and Juno do, and value the aim
	// point by the metal inside the blast. The shot is still subject to the
	// stockpile floor, so it is not thrown at a lone scout.
	if (cdef->IsAttrStock() && isRegional && (empWd != nullptr)) {
		const float floor = StockedShotFloor(unit, cdef, frame, empWd->GetCostMShot());
		if (SelectLauncherTarget(unit, cdef, floor)) {
			ExecuteAttack(unit);
		} else {
			TRY_UNIT(circuit, unit,
				unit->CmdStop();
			)
			SetTarget(nullptr);
			targetFrame = frame;
		}
		return;
	}

	CInfluenceMap* inflMap = circuit->GetInflMap();
	CMilitaryManager* militaryMgr = circuit->GetMilitaryManager();
	const float maxSqRange = SQUARE(cdef->GetMaxRange());
	const float sqAoe = SQUARE(cdef->GetAoe() * 1.25f);
	float cost = 0.f;
	int groupIdx = -1;
	const std::array<const std::set<IFighterTask*>*, 3> avoidTasks = {  // NOTE: ISquadTask only
		&militaryMgr->GetTasks(IFighterTask::FightType::ATTACK),
		&militaryMgr->GetTasks(IFighterTask::FightType::AH),
		&militaryMgr->GetTasks(IFighterTask::FightType::AA),
	};
	// A super weapon whose range does not cover the map - EMP silo (~3650), tactical
	// missile launchers (~2300), T2 LRPCs (~4650-4950) and, on large maps, the endgame
	// LRPCs (~5750-6100) - is a regional weapon: it is built as a cluster defence and
	// its targets are the enemy pushes into our own clusters, which sit in *our*
	// influence. Requiring enemy-dominated ground (influence <= -INFL_EPS) there
	// rejects every group it can reach, so the EMP filled its stockpile and never
	// fired and the LRPCs were left to engine auto-targeting, while the map-range
	// Junos (32000) and nukes (72000) worked. For regional weapons require only enemy
	// presence at the group; the own-squad exclusion and cost floor below still apply.
	// Map-range weapons keep the strict rule so they are never spent on the front line.
	int inRange = 0, rejInfl = 0, rejSquad = 0, rejIgnore = 0;
	auto isTargetValid = [&avoidTasks, frame, sqAoe, inflMap, circuit, isRegional, &rejInfl, &rejSquad, &rejIgnore](const CEnemyManager::SEnemyGroup& group) {
		// Ally influence and own tasks avoidance
		if (isRegional) {
			if (inflMap->GetEnemyInflAt(group.pos) <= INFL_EPS) {
				++rejInfl;
				return false;
			}
		} else if (inflMap->GetInfluenceAt(group.pos) > -INFL_EPS) {
			++rejInfl;
			return false;
		}
		for (const std::set<IFighterTask*>* tasks : avoidTasks) {
			for (const IFighterTask* task : *tasks) {
				const AIFloat3& leaderPos = static_cast<const ISquadTask*>(task)->GetLeaderPos(frame);
				if (leaderPos.SqDistance2D(group.pos) < sqAoe) {
					++rejSquad;
					return false;
				}
			}
		}
		for (const ICoreUnit::Id eId : group.units) {
			CEnemyInfo* enemy = circuit->GetEnemyInfo(eId);
			if (enemy == nullptr) {
				continue;
			}
			CCircuitDef* edef = enemy->GetCircuitDef();
			// NOTE: groups are created by leader, ignore flags could be different
			if ((edef == nullptr) || !circuit->GetCircuitDef(edef->GetId())->IsIgnore()) {
				return true;
			}
		}
		++rejIgnore;
		return false;
	};

	const std::vector<CEnemyManager::SEnemyGroup>& groups = circuit->GetEnemyManager()->GetEnemyGroups();
	if (cdef->IsHoldFire() || (State::ROAM == state)) {
		for (unsigned i = 0; i < groups.size(); ++i) {
			const CEnemyManager::SEnemyGroup& group = groups[i];
			if ((cost >= group.cost) || (position.SqDistance2D(group.pos) >= maxSqRange)) {
				continue;
			}
			++inRange;
			if (isTargetValid(group)) {
				cost = group.cost;
				groupIdx = i;
			}
		}
	} else {
		// TODO: Use WeaponDef::GetTurnRate() for turn-delay weight
		const AIFloat3& targetVec = (targetPos - position).Normalize2D();
		for (unsigned i = 0; i < groups.size(); ++i) {
			const CEnemyManager::SEnemyGroup& group = groups[i];
			if (position.SqDistance2D(group.pos) >= maxSqRange) {
				continue;
			}
			++inRange;
			const AIFloat3& newVec = (group.pos - position).Normalize2D();
			const float angleMod = M_PI / (2.f * (std::acos(targetVec.dot2D(newVec)) + 1e-2f));
			if (cost >= group.cost * angleMod) {
				continue;
			}
			if (isTargetValid(group)) {
				cost = group.cost;
				groupIdx = i;
			}
		}
	}
	// NOTE: for a stockpile weapon CWeaponDef::GetCostM() is the per-second
	//       stockpiling rate, not the cost of a shot; comparing it against a
	//       group's absolute metal cost left Juno with a ~2.7 metal floor.
	const float maxCost = cdef->IsAttrStock()
			? StockedShotFloor(unit, cdef, frame, cdef->GetWeaponDef()->GetCostMShot())
			: cdef->GetCostM() * 0.01f;

	if ((groupIdx < 0) || (cost < maxCost)) {
		// Diagnostic for a super weapon that never fires: which gate rejected every
		// reachable group. Once a minute per unit (Update runs every TARGET_DELAY);
		// for stockpiled launchers only while a shot is stocked.
		if (((frame / TARGET_DELAY) % 6 == 0)
			&& (!cdef->IsAttrStock() || (unit->GetUnit()->GetStockpile() > 0)))
		{
			circuit->LOG("SUPER %s(%i): no target | range=%.0f regional=%i groups=%zu inRange=%i rejInfl=%i rejSquad=%i rejIgnore=%i bestCost=%.0f minCost=%.0f",
					cdef->GetDef()->GetName(), unit->GetId(), cdef->GetMaxRange(), int(isRegional), groups.size(),
					inRange, rejInfl, rejSquad, rejIgnore, cost, maxCost);
		}
		TRY_UNIT(circuit, unit,
			unit->CmdStop();
		)
		SetTarget(nullptr);
		targetFrame = frame;
		return;
	}

	const AIFloat3& grPos = groups[groupIdx].pos;
	CEnemyInfo* bestTarget = nullptr;
	if (cdef->IsAttrStock()) {
		float minSqDist = std::numeric_limits<float>::max();
		for (const ICoreUnit::Id eId : groups[groupIdx].units) {
			CEnemyInfo* enemy = circuit->GetEnemyInfo(eId);
			if (enemy == nullptr) {
				continue;
			}
			CCircuitDef* edef = enemy->GetCircuitDef();
			// NOTE: groups are created by leader, ignore flags could be different
			if ((edef != nullptr) && circuit->GetCircuitDef(edef->GetId())->IsIgnore()) {
				continue;
			}
			const float sqDist = grPos.SqDistance2D(enemy->GetPos());
			if ((minSqDist > sqDist) && (position.SqDistance2D(enemy->GetPos()) < maxSqRange)) {
				minSqDist = sqDist;
				bestTarget = enemy;
			}
		}
	} else {
		float maxCost = 0.f;
		for (const ICoreUnit::Id eId : groups[groupIdx].units) {
			CEnemyInfo* enemy = circuit->GetEnemyInfo(eId);
			if (enemy == nullptr) {
				continue;
			}
			CCircuitDef* edef = enemy->GetCircuitDef();
			// NOTE: groups are created by leader, ignore flags could be different
			if ((edef != nullptr) && circuit->GetCircuitDef(edef->GetId())->IsIgnore()) {
				continue;
			}
			if ((maxCost < enemy->GetCost()) && (position.SqDistance2D(enemy->GetPos()) < maxSqRange)) {
				maxCost = enemy->GetCost();
				bestTarget = enemy;
			}
		}
	}
	SetTarget(bestTarget);
	if (GetTarget() != nullptr) {
		targetPos = GetTarget()->GetPos();
		targetPos.y = circuit->GetMap()->GetElevationAt(targetPos.x, targetPos.z);

		ExecuteAttack(unit);
	}
}

/*
 * Shared area-target selection. See the header for the contract.
 *
 * Differences from the generic super-weapon scan, all deliberate:
 *  - no influence gate. The best targets for these weapons are often on ground
 *    we hold: a jamming push into our own base, a minefield on our expansion.
 *  - no own-squad exclusion. Neither weapon can damage our units.
 *  - mobile targets are shot at their last known position while it is fresher
 *    than mobileMaxAge, which is the only way to hit a mobile jammer at all:
 *    it hides the very radar that would track it.
 *  - it attacks the ground, not a unit, because the kill or stun is by area and
 *    the target may no longer be visible.
 */
bool CSuperTask::SelectAreaTarget(CCircuitUnit* unit, CCircuitDef* cdef, const char* tag,
		float sqAoe, int minTargets, int mobileMaxAge, const TClassify& classify, float minValue, bool avoidFriendly,
		bool allEnemies, bool pulseClaims, bool nuclearHistory)
{
	CCircuitAI* circuit = manager->GetCircuit();
	const int frame = circuit->GetLastFrame();
	const float maxSqRange = SQUARE(cdef->GetMaxRange());

	struct SAreaCand {
		springai::AIFloat3 pos;
		int rank;
		float value;
	};
	std::vector<SAreaCand> cands;
	int rejRange = 0, rejStale = 0, rejClass = 0, rejFriendly = 0;

	const auto* enemies = circuit->GetEnemyManager();
	for (const auto* pool : {&enemies->GetHostileDatas(), allEnemies ? &enemies->GetPeaceDatas() : nullptr}) {
	if (pool == nullptr) continue;
	for (const SEnemyData& e : *pool) {
		if (e.IsFake() || e.IsDead() || e.IsDying() || e.IsIgnore()) {
			continue;
		}
		CCircuitDef* edef = e.cdef;
		if (edef == nullptr) {
			continue;
		}
		int rank = 0;
		float value = 0.f;
		if (!classify(e, edef, rank, value)) {
			++rejClass;
			continue;
		}
		if (edef->IsMobile() && !e.IsInRadarOrLOS()) {
			CEnemyInfo* info = circuit->GetEnemyInfo(e.id);
			const int lastSeen = (info == nullptr) ? -1 : info->GetData()->GetLastSeen();
			if ((lastSeen < 0) || (frame - lastSeen > mobileMaxAge)) {
				++rejStale;
				continue;
			}
		}
		if (position.SqDistance2D(e.pos) >= maxSqRange) {
			++rejRange;
			continue;
		}
		if ((pulseClaims || nuclearHistory) && !CanAimStrategic(unit, e.pos)) continue;
		if (avoidFriendly) {
			// A damaging blast on our own units is never worth it, whatever the
			// enemy value inside it (CR-005). The engine query is per candidate;
			// candidates are the hostiles in range, a few dozen at most.
			auto& friendlies = circuit->GetCallback()->GetFriendlyUnitsIn(e.pos, std::sqrt(sqAoe));
			const bool hit = !friendlies.empty();
			utils::free(friendlies);
			if (hit) {
				++rejFriendly;
				continue;
			}
		}
		cands.push_back({e.pos, rank, value});
	}
	}

	int bestRank = std::numeric_limits<int>::max();
	float bestValue = 0.f;
	int bestCount = 0;
	int bestIdx = -1;
	for (unsigned i = 0; i < cands.size(); ++i) {
		int rank = std::numeric_limits<int>::max();
		float value = 0.f;
		int count = 0;
		for (unsigned j = 0; j < cands.size(); ++j) {
			if (cands[i].pos.SqDistance2D(cands[j].pos) >= sqAoe) {
				continue;
			}
			rank = std::min(rank, cands[j].rank);
			value += cands[j].value;
			++count;
		}
		if (count < minTargets) {
			continue;
		}
		if ((rank < bestRank) || ((rank == bestRank) && (value > bestValue))) {
			bestRank = rank;
			bestValue = value;
			bestCount = count;
			bestIdx = int(i);
		}
	}

	if ((bestIdx >= 0) && (bestValue < minValue)) {
		bestIdx = -1;  // the richest aim point is not worth the shot yet; see StockedShotFloor
	}
	if (bestIdx < 0) {
		if ((frame / TARGET_DELAY) % 6 == 0) {
			circuit->LOG("%s %s(%i): no target | range=%.0f candidates=%zu rejClass=%i rejRange=%i rejStale=%i minTargets=%i bestValue=%.0f minValue=%.0f",
					tag, cdef->GetDef()->GetName(), unit->GetId(), cdef->GetMaxRange(),
					cands.size(), rejClass, rejRange, rejStale, minTargets, bestValue, minValue);
		}
		return false;
	}

	SetTarget(nullptr);  // area effect at a position, possibly of a unit we can no longer see
	const bool isMoved = (targetPos.SqDistance2D(cands[bestIdx].pos) > SQUARE(1.f));
	targetPos = cands[bestIdx].pos;
	targetPos.y = circuit->GetMap()->GetElevationAt(targetPos.x, targetPos.z);
	if (isMoved) {  // Update runs every TARGET_DELAY: only log a new aim point
		circuit->LOG("%s %s(%i): rank=%i targets=%i value=%.0f at (%i,%i)",
				tag, cdef->GetDef()->GetName(), unit->GetId(), bestRank, bestCount, bestValue,
				int(targetPos.x), int(targetPos.z));
	}
	return true;
}

/*
 * A stockpiled shot is already paid for. The longer it waits, the less a
 * target has to be worth; with several stocked, any target at all. Shared by
 * the group scan (nukes, Junos without a pulse block) and the launcher scan.
 */
float CSuperTask::StockedShotFloor(CCircuitUnit* unit, CCircuitDef* cdef, int frame, float shotCost)
{
	const int stock = unit->GetUnit()->GetStockpile();
	if (stock <= 0) {
		stockSinceFrame = -1;
		return shotCost;
	}
	if (stockSinceFrame < 0) {
		stockSinceFrame = frame;
	}
	const CMilitaryManager::SStockInfo& st = manager->GetCircuit()->GetMilitaryManager()->GetStockInfo();
	float fraction = 1.f;
	if (st.patienceSeconds > 0.f) {
		fraction -= float(frame - stockSinceFrame) / (st.patienceSeconds * FRAMES_PER_SEC);
	}
	if ((st.fullFireCount > 0) && (stock >= st.fullFireCount)) {
		fraction = 0.f;
	}
	return shotCost * std::max(st.minFraction, fraction);
}

/*
 * Tactical launchers (Perdition napalm, Catalyst tactical nuke) do plain area
 * damage, so the worth of an aim point is the metal inside the blast. Every
 * hostile the weapon's target category allows is a candidate - a napalm
 * missile cannot hit aircraft - and the best aim point is the densest clump,
 * structures first only when configured. The floor passed in keeps the shot
 * for something worth its cost until patience runs out.
 */
bool CSuperTask::SelectLauncherTarget(CCircuitUnit* unit, CCircuitDef* cdef, float minValue)
{
	const CMilitaryManager::SStockInfo& st = manager->GetCircuit()->GetMilitaryManager()->GetStockInfo();
	const int canTargetCat = cdef->GetTargetCategory();
	return SelectAreaTarget(unit, cdef, "LAUNCHER", SQUARE(cdef->GetAoe()),
			st.launcherMinTargets, st.launcherMobileMaxAge,
			[&st, canTargetCat](const SEnemyData& e, CCircuitDef* edef, int& rank, float& value) {
		if ((canTargetCat & edef->GetCategory()) == 0) {
			return false;  // outside the weapon's target category (aircraft for napalm)
		}
		rank = (st.launcherStructuresFirst && !edef->IsMobile()) ? 0 : 1;
		value = e.cost;
		return true;
	}, minValue, /*avoidFriendly*/ true);
}

/*
 * Pulse weapons (Juno) do 1 damage: their effect is a Lua gadget that deletes
 * defs flagged juno_kill / juno_deny / mine inside the blast. Ranking enemy
 * groups by metal cost therefore aims them at armies they cannot touch, so
 * they select the highest-priority sensor / EW class in range instead.
 */
bool CSuperTask::SelectPulseTarget(CCircuitUnit* unit, CCircuitDef* cdef)
{
	const CMilitaryManager::SPulseInfo& pulse = manager->GetCircuit()->GetMilitaryManager()->GetPulseInfo();
	return SelectAreaTarget(unit, cdef, "PULSE", SQUARE(cdef->GetAoe()),
			pulse.minTargets, pulse.mobileMaxAge,
			[&pulse](const SEnemyData& e, CCircuitDef* edef, int& rank, float& value) {
		const auto cls = pulse.targetClasses.find(edef->GetId());
		if (cls == pulse.targetClasses.end()) return false;
		const int r = pulse.rank[cls->second];
		if (r < 0) {
			return false;  // class excluded by config
		}
		rank = r;
		value = e.cost;
		return true;
	}, 0.f, false, true, true);
}

bool CSuperTask::IsPulse(CCircuitDef* cdef) const
{
	const auto& p = manager->GetCircuit()->GetMilitaryManager()->GetPulseInfo();
	return p.isEnabled && (cdef->IsRespRoleAny(p.pulseRole) || p.unitDefs.count(cdef->GetId()) != 0);
}

bool CSuperTask::CanAimStrategic(CCircuitUnit* unit, const AIFloat3& pos) const
{
	CCircuitAI* circuit = manager->GetCircuit();
	if (!strategic::Valid({pos.x, pos.z}) || pos.x >= CTerrainManager::GetTerrainWidth() || pos.z >= CTerrainManager::GetTerrainHeight()) return false;
	const int frame = circuit->GetLastFrame();
	if (IsPulse(unit->GetCircuitDef())) return !circuit->GetAllyTeam()->GetPulseClaims().Blocked({pos.x, pos.z}, unit->GetId(), frame, false);
	if (IsNukeSilo(unit->GetCircuitDef())) {
		const strategic::Overnuke& over = circuit->GetMilitaryManager()->GetOvernuke();
		if (over.Covers({pos.x, pos.z})) return true;  // the overnuke target: every silo, every shot
		return !over.Done({pos.x, pos.z}, frame)
			&& !circuit->GetAllyTeam()->GetNuclearHistory().Blocked({pos.x, pos.z}, unit->GetId(), frame, true);
	}
	return true;
}

int CSuperTask::CountNukeSilos() const
{
	int count = 0;
	for (const IFighterTask* task : manager->GetCircuit()->GetMilitaryManager()->GetTasks(IFighterTask::FightType::SUPER)) {
		const auto& assignees = task->GetAssignees();
		if (!assignees.empty() && IsNukeSilo((*assignees.begin())->GetCircuitDef())) ++count;
	}
	return count;
}

/*
 * Overnuke (owner 2026-10-28). With nuclear.overnuke_silos finished silos or
 * more, the best aim point the scan finds becomes the target of every silo for
 * a roll of overnuke_min..overnuke_max launches (CSuperTask::OnLaunch counts
 * them), then the next best; a target with no known structure left in the blast
 * ends early. A silo that cannot reach the target picks its own as before.
 */
bool CSuperTask::SelectNuclearTarget(CCircuitUnit* unit, CCircuitDef* cdef)
{
	CCircuitAI* circuit = manager->GetCircuit();
	const int frame = circuit->GetLastFrame();
	const auto& policy = circuit->GetMilitaryManager()->GetNuclearInfo();
	const float floor = StockedShotFloor(unit, cdef, frame, cdef->GetWeaponDef()->GetCostMShot());
	auto scan = [&]() {
		return SelectAreaTarget(unit, cdef, "NUCLEAR", SQUARE(cdef->GetAoe()), 1, 0,
			[&policy](const SEnemyData& e, CCircuitDef* d, int& rank, float& value) {
				if (!strategic::NuclearTarget(d->IsMobile(), true, policy.structuresOnly)) return false;
				rank = 0; value = e.cost; return true;
			}, floor, true, true, false, true);
	};
	strategic::Overnuke& over = circuit->GetMilitaryManager()->GetOvernuke();
	const int silos = CountNukeSilos();
	if ((policy.overnukeSilos <= 0) || (silos < policy.overnukeSilos)) {
		if (over.Active()) {
			circuit->LOG("NUKE: overnuke ends at %i of %i launches: %i silos left", over.Fired(), over.Goal(), silos);
			over.End(frame, policy.repeatFrames);
		}
		return scan();
	}
	if (over.Active()) {
		const AIFloat3 at(over.Pos().x, 0.f, over.Pos().z);
		bool structure = false;
		const auto* enemies = circuit->GetEnemyManager();
		for (const auto* pool : {&enemies->GetHostileDatas(), &enemies->GetPeaceDatas()}) for (const auto& e : *pool) {
			if (!e.IsFake() && !e.IsDead() && !e.IsDying() && !e.IsIgnore() && (e.cdef != nullptr)
				&& strategic::NuclearTarget(e.cdef->IsMobile(), true, policy.structuresOnly)
				&& (at.SqDistance2D(e.pos) < SQUARE(over.Radius()))) { structure = true; break; }
		}
		if (!structure) {
			circuit->LOG("NUKE: overnuke at (%.0f, %.0f) ends at %i of %i launches: no target left there",
					at.x, at.z, over.Fired(), over.Goal());
			over.End(frame, policy.repeatFrames);
		} else if (position.SqDistance2D(at) < SQUARE(cdef->GetMaxRange())) {
			SetTarget(nullptr);
			targetPos = at;
			targetPos.y = circuit->GetMap()->GetElevationAt(at.x, at.z);
			return true;
		} else {
			return scan();  // out of this silo's reach: its own target
		}
	}
	if (!scan()) return false;
	const int roll = policy.overnukeMin + rand() % (policy.overnukeMax - policy.overnukeMin + 1);
	over.Begin({targetPos.x, targetPos.z}, (policy.repeatRadius > 0.f) ? policy.repeatRadius : cdef->GetAoe(), roll);
	circuit->LOG("NUKE: overnuke with %i silos at (%.0f, %.0f): %i launches", silos, targetPos.x, targetPos.z, roll);
	return true;
}

bool CSuperTask::SelectFogTarget(CCircuitUnit* unit, CCircuitDef* cdef)
{
	CCircuitAI* circuit = manager->GetCircuit();
	const auto& policy = circuit->GetMilitaryManager()->GetPulseInfo();
	if (!policy.scatter) return false;
	const auto* map = circuit->GetMapManager();
	AIFloat3 best(-1.f, 0.f, -1.f);
	float bestScore = -1.f;
	const float width = CTerrainManager::GetTerrainWidth(), height = CTerrainManager::GetTerrainHeight();
	const float step = std::max(policy.scatterStep, std::sqrt(width * height / 4096.f));
	const auto& enemy = circuit->GetEnemyManager()->GetEnemyPos(); // known-contact aggregate, never hidden units
	for (float z = step / 2; z < height; z += step) for (float x = step / 2; x < width; x += step) {
		const AIFloat3 edge(x, 0.f, z);
		if (!map->IsInLOS(edge)) continue;
		for (int k = 0; k < 8; ++k) {
			const float angle = float(k) * float(M_PI) / 4.f;
			const AIFloat3 boundaryPos(x + std::cos(angle) * step, 0.f, z + std::sin(angle) * step);
			AIFloat3 p(x + std::cos(angle) * (step + policy.scatterDepth), 0.f, z + std::sin(angle) * (step + policy.scatterDepth));
			if (boundaryPos.x < 0 || boundaryPos.z < 0 || boundaryPos.x >= width || boundaryPos.z >= height || !CanAimStrategic(unit, p)
				|| map->IsInLOS(boundaryPos) || map->IsInLOS(p) || position.SqDistance2D(p) >= SQUARE(cdef->GetMaxRange())) continue;
			if (p.SqDistance2D(enemy) >= edge.SqDistance2D(enemy)) continue; // enemy-facing fog, not the back of our base
			// Stable rotation prevents repeatedly favoring the same equal-valued edge.
			const unsigned hash = unsigned(x) * 73856093u ^ unsigned(z) * 19349663u ^ unsigned(unit->GetId()) ^ unsigned(lastStrategicLaunch);
			const float score = 1.f / (1.f + std::sqrt(p.SqDistance2D(enemy)) / step)
				+ circuit->GetInflMap()->GetEnemyInflAt(p) + float(hash % 1000) * 0.0001f;
			if (score > bestScore) { best = p; bestScore = score; }
		}
	}
	if (best.x < 0.f) return false;
	SetTarget(nullptr); targetPos = best;
	targetPos.y = circuit->GetMap()->GetElevationAt(best.x, best.z);
	circuit->LOG("PULSE %s(%i): fog scatter at (%i,%i)", cdef->GetDef()->GetName(), unit->GetId(), int(best.x), int(best.z));
	return true;
}

/*
 * Fallback when no jammer or radar is known: find the hole one is making.
 *
 * A jammer sits inside its own radardistancejam bubble (360-760 in BAR) and
 * hides itself along with everything near it, so it is a *known* target only
 * where we have LOS - which in practice means a unit is already standing next
 * to it. The useful evidence is therefore negative: ground that we cover with
 * radar, cannot see, believe the enemy holds, and read no contacts from.
 *
 * Probes are seeded from known enemy contacts and thrown outward one jam
 * radius, so the search follows the front and the recently contested ground
 * rather than sweeping the map. Each probe must satisfy:
 *
 *   in our radar coverage  - otherwise "no contact" only means "not looking"
 *   not in our LOS         - with eyes on it we would see the units directly
 *   enemy influence        - the enemy operates here; empty rear ground is not
 *                            evidence of anything
 *   no contact within holeRadius - the hole itself
 *
 * The pulse AoE (1400) is wider than the widest jam radius, so aiming at the
 * hole tends to catch whatever made it. Each shot that removes a jammer turns
 * its pocket into contacts, which moves the next hole further along the line:
 * the weapon walks the front instead of stalling on it.
 */
bool CSuperTask::SelectSuspectedJammer(CCircuitUnit* unit, CCircuitDef* cdef)
{
	CCircuitAI* circuit = manager->GetCircuit();
	const CMilitaryManager::SPulseInfo& pulse = circuit->GetMilitaryManager()->GetPulseInfo();
	if (!pulse.suspectJammer) {
		return false;
	}
	CMapManager* mapMgr = circuit->GetMapManager();
	CInfluenceMap* inflMap = circuit->GetInflMap();
	const float maxSqRange = SQUARE(cdef->GetMaxRange());
	const float sqHole = SQUARE(pulse.holeRadius);

	const std::vector<SEnemyData>& enemies = circuit->GetEnemyManager()->GetHostileDatas();
	AIFloat3 bestPos(-1.f, 0.f, 0.f);
	float bestScore = 0.f;
	int probed = 0, rejRadar = 0, rejLos = 0, rejInfl = 0, rejOccupied = 0;

	for (const SEnemyData& seed : enemies) {
		if (seed.IsFake() || seed.IsDead() || seed.IsDying()) {
			continue;
		}
		for (int i = 0; i < pulse.holeProbes; ++i) {
			const float angle = (2.f * float(M_PI) * float(i)) / float(pulse.holeProbes);
			AIFloat3 probe(seed.pos.x + std::cos(angle) * pulse.holeProbeRadius, 0.f,
					seed.pos.z + std::sin(angle) * pulse.holeProbeRadius);
			CTerrainManager::CorrectPosition(probe);
			probe.y = circuit->GetMap()->GetElevationAt(probe.x, probe.z);
			if (!CanAimStrategic(unit, probe)) continue;
			if (position.SqDistance2D(probe) >= maxSqRange) {
				continue;
			}
			++probed;

			if (!mapMgr->IsInRadar(probe)) {
				++rejRadar;  // not looking there: silence means nothing
				continue;
			}
			if (mapMgr->IsInLOS(probe)) {
				++rejLos;    // we can see it; absence of contacts is real
				continue;
			}
			const float infl = inflMap->GetEnemyInflAt(probe);
			if (infl < pulse.holeMinEnemyInfl) {
				++rejInfl;   // empty rear ground, not a front
				continue;
			}
			// The hole: nothing known inside a jam radius of the probe.
			bool occupied = false;
			for (const SEnemyData& other : enemies) {
				if (other.IsFake() || other.IsDead() || other.IsDying()) {
					continue;
				}
				if (probe.SqDistance2D(other.pos) < sqHole) {
					occupied = true;
					break;
				}
			}
			if (occupied) {
				++rejOccupied;
				continue;
			}
			// Rank by how strongly we believe the enemy is here.
			if (bestScore < infl) {
				bestScore = infl;
				bestPos = probe;
			}
		}
	}

	if (bestScore <= 0.f) {
		if ((circuit->GetLastFrame() / TARGET_DELAY) % 6 == 0) {
			circuit->LOG("PULSE %s(%i): no suspected jammer | probes=%i rejRadar=%i rejLos=%i rejInfl=%i rejOccupied=%i",
					cdef->GetDef()->GetName(), unit->GetId(), probed, rejRadar, rejLos, rejInfl, rejOccupied);
		}
		return false;
	}

	SetTarget(nullptr);
	const bool isMoved = (targetPos.SqDistance2D(bestPos) > SQUARE(1.f));
	targetPos = bestPos;
	targetPos.y = circuit->GetMap()->GetElevationAt(targetPos.x, targetPos.z);
	if (isMoved) {
		circuit->LOG("PULSE %s(%i): suspected jammer, radar hole at (%i,%i) enemyInfl=%.3f (probes=%i)",
				cdef->GetDef()->GetName(), unit->GetId(),
				int(targetPos.x), int(targetPos.z), bestScore, probed);
	}
	return true;
}

/*
 * EMP weapons deal no health damage. A shot is worth firing only if it lands a
 * stun, and whether it does is arithmetic, not a property of the target's cost:
 *
 *   effective = paralyzeDamage * paralyzemultiplier * salvo
 *   stunned   iff effective > maxHealth
 *   seconds   = declineRate * (min(effective / maxHealth, cap) - 1)
 *   cap       = 1 + paralyzeTime / declineRate
 *
 * (Recoil CUnit::DoDamage with modrules.paralyze.paralyzeOnMaxHealth.) So a
 * Titan at 69 000 health shrugs off one 50 000 shot despite multiplier 1.0,
 * while every strategic structure in the game is a full-length stun - and
 * unit_paralyze_damage_limit.lua caps mobiles at 20 s but not buildings, which
 * is why structures rank first. Anti-nuke is the one class ranked above raw
 * value: stunning it is what lets a nuke through, and the EMP missile itself
 * carries no `targetable`, so the anti-nuke cannot intercept it. Static shield
 * generators come next (owner, 2026-10-20), then large structures, then the rest.
 */
bool CSuperTask::SelectEmpTarget(CCircuitUnit* unit, CCircuitDef* cdef)
{
	CMilitaryManager* militaryMgr = manager->GetCircuit()->GetMilitaryManager();
	const CMilitaryManager::SEmpInfo& emp = militaryMgr->GetEmpInfo();
	const CWeaponDef* wd = cdef->GetWeaponDef();
	if ((wd == nullptr) || !wd->IsParalyzer()) {
		return false;
	}
	const float shot = wd->GetParalyzeDamage() * float(militaryMgr->GetEmpSalvoSize());
	const float decline = 1.f / emp.declineRate;
	const float cap = 1.f + wd->GetParalyzeTime() * decline;

	return SelectAreaTarget(unit, cdef, "EMP", SQUARE(cdef->GetAoe()),
			emp.minTargets, emp.mobileMaxAge,
			[&emp, shot, decline, cap](const SEnemyData& e, CCircuitDef* edef, int& rank, float& value) {
		// BAR's EMPABLE is SURFACE and paralyzemultiplier != 0, so one bit rejects
		// aircraft, submerged units and every immune def at once.
		if ((edef->GetCategory() & emp.empableFlag) == 0) {
			return false;
		}
		const float health = edef->GetHealth();
		const float effective = shot * edef->GetParalyzeMult();
		if ((health <= 0.f) || (effective <= health)) {
			return false;  // cannot be stunned by the shots we can land
		}
		const float stun = (std::min(effective / health, cap) - 1.f) / decline;
		if (stun < emp.minStunSeconds) {
			return false;  // too brief to be worth the shot
		}
		const bool isMobile = edef->IsMobile();
		if (!isMobile && edef->IsRespRoleAny(emp.antiNukeRole)) {
			rank = 0;
		} else if (!isMobile && emp.shieldsSecond && (edef->GetMaxShield() > 0.f)) {
			// A static plasma deflector (Armada/Cortex gate and floating gate,
			// Legion deflector and T3 shield): stunned, it drops its bubble and
			// the porc and artillery it covers are open to everything else.
			rank = 1;
		} else if (!isMobile && (!emp.structuresFirst || e.cost >= emp.structuresFirstMinCost)) {
			rank = 2;  // a large structure: LRPC, bastion, silo, AFUS, gantry
		} else {
			// Everything else - cheap structures and every mobile - by cost.
			// A target that cannot be stunned was already rejected above, so
			// "highest metal cost except EMP-immune" is what this rank is.
			rank = 3;
		}
		// Value is metal: it floats Ragnarok, AFUS, gantry and silo above a cheap
		// turret without any of them needing to be tagged.
		value = e.cost;
		return true;
	// Unarmed enemies (anti-nuke, shields, AFUS, gantries) live in the peace
	// pool, not the hostile one: without allEnemies the silo never saw any of
	// the structures its ranking is for and only ever shot armed units.
	}, 0.f, false, true);
}

bool CSuperTask::IsNukeSilo(CCircuitDef* cdef)
{
	const std::string name = cdef->GetDef()->GetName();
	return (name == "armsilo") || (name == "corsilo") || (name == "legsilo");
}

AIFloat3 CSuperTask::GetAimPos() const
{
	if (!isTargetOverride && (GetTarget() != nullptr)) {
		return GetTarget()->GetPos();
	}
	return targetPos;
}

void CSuperTask::OnLaunch(CCircuitUnit* unit, const char* how)
{
	CCircuitAI* circuit = manager->GetCircuit();
	const int frame = circuit->GetLastFrame();
	CCircuitDef* d = unit->GetCircuitDef();
	CountTierShot(unit, frame);
	const bool nuke = IsNukeSilo(d), pulse = IsPulse(d);
	if (!nuke && !pulse) return;
	if (frame - lastStrategicLaunch <= SMILEY_DEDUPE_EVENT) return;
	const AIFloat3 aim = GetAimPos();
	if (!CanAimStrategic(unit, aim)) circuit->LOG("[INVARIANT] INV-095 strategic launch violates target-area exclusion: unit=%i", unit->GetId());
	lastStrategicLaunch = frame;
	if (nuke) {
		const auto& policy = circuit->GetMilitaryManager()->GetNuclearInfo();
		circuit->GetAllyTeam()->GetNuclearHistory().Add(unit->GetId(), {aim.x, aim.z},
			policy.repeatRadius > 0.f ? policy.repeatRadius : d->GetAoe(), frame, policy.repeatFrames, false);
		strategic::Overnuke& over = circuit->GetMilitaryManager()->GetOvernuke();
		const int scouts = over.Scouts();
		if (over.Count({aim.x, aim.z}, frame, policy.repeatFrames, policy.overnukeScoutEvery)) {
			circuit->LOG("NUKE: overnuke launch %i of %i from %s(%i)%s", over.Fired(), over.Goal(),
					d->GetDef()->GetName(), unit->GetId(), (over.Scouts() > scouts) ? ": scouts asked" : "");
		}
	} else {
		const auto& policy = circuit->GetMilitaryManager()->GetPulseInfo();
		circuit->GetAllyTeam()->GetPulseClaims().Add(unit->GetId(), {aim.x, aim.z}, d->GetAoe(), frame, policy.coverageFrames, false);
		circuit->LOG("PULSE: launched from %s(%i) at (%.0f, %.0f) (%s)", d->GetDef()->GetName(), unit->GetId(), aim.x, aim.z, how);
	}
	// Attack-ground persists after launch; stop it before another stocked shot
	// can fire without passing the updated ledger. Keep the aim for event users.
	TRY_UNIT(circuit, unit, unit->CmdStop();)
	SetTarget(nullptr); targetPos = aim; isTargetOverride = false; state = State::ROAM;
	if (!nuke) return;
	if (frame - lastSmileyFrame <= SMILEY_DEDUPE_EVENT) {
		return;  // one smiley a launch
	}
	const AIFloat3 at = GetAimPos();
	if (!geom::is_valid(at)) {
		circuit->LOG("NUKE: launched from %s(%i) (%s) with no aim known: no smiley (D-124)", unit->GetCircuitDef()->GetDef()->GetName(), unit->GetId(), how);
		return;
	}
	lastSmileyFrame = frame;
	circuit->LOG("NUKE: launched from %s(%i) at (%.0f, %.0f) (%s): a smiley on the target (D-124)",
			unit->GetCircuitDef()->GetDef()->GetName(), unit->GetId(), at.x, at.z, how);
	circuit->DrawSmiley(at, SMILEY_RADIUS);
}

void CSuperTask::SetTargetTier(const CCircuitDef* edef, int tier)
{
	if (edef == nullptr) return;
	if (tier > 0) tierByDef[edef->GetId()] = tier;
	else tierByDef.erase(edef->GetId());
}

/*
 * Tiered fire (lolcannons, owner 2026-10-26). One pass over the enemy datas
 * (hostile and peaceful: an advanced fusion is unarmed) every
 * tierRetargetFrames, at once when the target under fire is gone: O(enemies)
 * with one hash lookup each, per lolcannon, so a few hundred lookups every two
 * seconds for the one or two an AI owns. Mobile roster units count only while
 * in radar or LOS; structures also at their remembered position. Orders: one
 * attack on a new target, else one every 30 s before the 60 s order timeout,
 * or when a target seen only as ground comes into sight. No roster unit in
 * range: one stop, then nothing, and the script's hold fire keeps the engine
 * from spending the gun on spam.
 */
void CSuperTask::UpdateTiered(CCircuitUnit* unit)
{
	CCircuitAI* circuit = manager->GetCircuit();
	const int frame = circuit->GetLastFrame();
	if ((tierTargetId >= 0) && (circuit->GetEnemyInfo(tierTargetId) == nullptr)) {
		targetFrame = frame - tierRetargetFrames;  // the target is gone: the next one now
	}
	if ((tierAreaMax > 1) && (tierDwellShots <= 0) && !tierAreas.empty()
		&& (frame - tierRotation.since >= tierDwellFrames))
	{
		targetFrame = frame - tierRetargetFrames;  // the dwell is up: the next area now
	}
	if (targetFrame + tierRetargetFrames > frame) {
		return;
	}
	targetFrame = frame;

	const bool byArea = (tierAreaMax > 1);
	std::vector<tier::Candidate> candidates;
	std::vector<const SEnemyData*> candidateDatas;
	CCircuitDef* cdef = unit->GetCircuitDef();
	const float maxSqRange = SQUARE(cdef->GetMaxRange());
	const int canTargetCat = cdef->GetTargetCategory();
	tier::Candidate best{-1, 0, 0.f, 0.f};
	const SEnemyData* bestData = nullptr;
	const auto* enemies = circuit->GetEnemyManager();
	for (const auto* pool : {&enemies->GetHostileDatas(), &enemies->GetPeaceDatas()}) {
		for (const SEnemyData& e : *pool) {
			if (e.IsFake() || e.IsDead() || e.IsDying() || e.IsIgnore() || (e.cdef == nullptr)) {
				continue;
			}
			const auto it = tierByDef.find(e.cdef->GetId());
			if ((it == tierByDef.end()) || (!byArea && (bestData != nullptr) && (it->second > best.tier))) {
				continue;
			}
			if (((canTargetCat & e.cdef->GetCategory()) == 0) || (e.cdef->IsMobile() && !e.IsInRadarOrLOS())) {
				continue;
			}
			const float sqDist = position.SqDistance2D(e.pos);
			if (sqDist >= maxSqRange) {
				continue;
			}
			const tier::Candidate c{e.id, it->second, e.cost, sqDist, e.pos.x, e.pos.z};
			if (byArea) {
				candidates.push_back(c);
				candidateDatas.push_back(&e);
				continue;
			}
			if (tier::Better(c, (bestData == nullptr) ? nullptr : &best, tierTargetId)) {
				best = c;
				bestData = &e;
			}
		}
	}
	if (byArea) {
		const int pick = PickTierArea(unit, candidates);
		if (pick >= 0) {
			best = candidates[pick];
			bestData = candidateDatas[pick];
		}
	}

	if (bestData == nullptr) {
		if ((tierTargetId >= 0) || (State::ENGAGE == state)) {
			TRY_UNIT(circuit, unit,
				unit->CmdStop();
			)
			circuit->LOG("TIER: team=%i %s(%i): no roster target in range (%.0f); holding fire",
					circuit->GetTeamId(), cdef->GetDef()->GetName(), unit->GetId(), cdef->GetMaxRange());
		}
		tierTargetId = -1;
		SetTarget(nullptr);
		state = State::ROAM;
		return;
	}

	CEnemyInfo* info = circuit->GetEnemyInfo(bestData->id);
	const bool onUnit = (info != nullptr) && info->IsInRadarOrLOS() && !circuit->IsCheating();
	const bool isNew = (bestData->id != tierTargetId);
	if (!isNew && (State::ENGAGE == state) && (onUnit == tierOrderOnUnit)
		&& (frame - tierOrderFrame < FRAMES_PER_SEC * 30))
	{
		return;  // still on it
	}
	if (isNew) {
		circuit->LOG("TIER: team=%i frame=%i %s(%i): tier %i %s(%i) cost=%.0f at (%i,%i), %.0f away%s",
				circuit->GetTeamId(), frame, cdef->GetDef()->GetName(), unit->GetId(), best.tier, bestData->cdef->GetDef()->GetName(), bestData->id,
				bestData->cost, int(bestData->pos.x), int(bestData->pos.z), std::sqrt(best.sqDist), onUnit ? "" : " (last seen)");
	}
	tierTargetId = bestData->id;
	isTargetOverride = false;
	SetTarget(info);
	targetPos = bestData->pos;
	targetPos.y = circuit->GetMap()->GetElevationAt(targetPos.x, targetPos.z);
	ExecuteAttack(unit);
	tierOrderFrame = frame;
	tierOrderOnUnit = onUnit;
}

void CSuperTask::SetTierRotation(int areas, int dwellFrames, int dwellShots, float radius)
{
	tierAreaMax = std::max(1, areas);
	tierDwellFrames = std::max(1, dwellFrames);
	tierDwellShots = std::max(0, dwellShots);
	tierAreaRadius = std::max(1.f, radius);
	tier::Restart(tierRotation, manager->GetCircuit()->GetLastFrame());
}

AIFloat3 CSuperTask::GetTierAreaPos(int i) const
{
	if (!ValidArea(i)) return -RgtVector;
	return AIFloat3(tierAreas[i].x, 0.f, tierAreas[i].z);
}

/*
 * The area rotation (owner 2026-10-27): rank the areas, restart at the top when
 * fresh scouting changed the top one (TopChanged), else move on once the dwell
 * is up. One log line, with the whole ranking, whenever the area changes.
 */
int CSuperTask::PickTierArea(CCircuitUnit* unit, const std::vector<tier::Candidate>& candidates)
{
	CCircuitAI* circuit = manager->GetCircuit();
	const int frame = circuit->GetLastFrame();
	tierAreas = tier::BuildAreas(candidates, tierAreaRadius, tierTargetId, size_t(tierAreaMax));
	tierAreaTargets.clear();
	for (const tier::Area& a : tierAreas) tierAreaTargets.push_back(candidates[a.aim].id);
	tierSeenNow.clear();
	for (const tier::Candidate& c : candidates) tierSeenNow.insert(c.id);
	// "Seen" spans TIER_SEEN_FRAMES (a3: commanders flickering in and out of
	// radar restarted the rotation 19 times in 29): the old top still counts
	// while it lives and was a candidate that recently; only a target new for
	// that long is fresh news.
	constexpr int TIER_SEEN_FRAMES = FRAMES_PER_SEC * 30;
	auto seenLately = [this, frame](int id) {
		const auto it = tierLastSeen.find(id);
		return (it != tierLastSeen.end()) && (frame - it->second <= TIER_SEEN_FRAMES);
	};
	const int oldTop = tierRotation.topId;
	const bool oldTopStill = (tierSeenNow.count(oldTop) > 0)
		|| ((oldTop >= 0) && (circuit->GetEnemyInfo(oldTop) != nullptr) && seenLately(oldTop));
	const int top = tierAreas.empty() ? -1 : tierAreas[0].seedId;
	const bool topSeenBefore = seenLately(top);
	for (const tier::Candidate& c : candidates) tierLastSeen[c.id] = frame;
	for (auto it = tierLastSeen.begin(); it != tierLastSeen.end();) {
		if (frame - it->second > TIER_SEEN_FRAMES) it = tierLastSeen.erase(it); else ++it;
	}
	const int oldIndex = tierRotation.index;
	const char* why = nullptr;
	if (tier::TopChanged(oldTop, top, oldTopStill, topSeenBefore)) {
		tier::Restart(tierRotation, frame);
		why = "the top area changed";
	} else if (tier::Advance(tierRotation, int(tierAreas.size()), frame, tierDwellFrames, tierDwellShots)) {
		why = (tierRotation.index == 0) ? "back to the top" : "next area";
	}
	tierRotation.topId = top;
	if (tierAreas.empty()) {
		return -1;
	}
	if ((why != nullptr) || (oldIndex != tierRotation.index)) {
		std::string ranking;
		for (size_t i = 0; i < tierAreas.size(); ++i) {
			const tier::Area& a = tierAreas[i];
			ranking += std::format("{}#{} t{} {:.0f}m ({},{})", i ? "; " : "", i + 1, a.tier, a.metal, int(a.x), int(a.z));
		}
		circuit->LOG("TIER: team=%i frame=%i %s(%i): area %i of %i (%s): %s",
				circuit->GetTeamId(), frame, unit->GetCircuitDef()->GetDef()->GetName(), unit->GetId(),
				tierRotation.index + 1, int(tierAreas.size()), (why != nullptr) ? why : "fewer areas", ranking.c_str());
	}
	return tierAreas[tierRotation.index].aim;
}

void CSuperTask::CountTierShot(CCircuitUnit* unit, int frame)
{
	if (tierByDef.empty() || (tierAreaMax <= 1) || (tierDwellShots <= 0)) return;
	// A salvo raises one event per projectile: shots closer than the main
	// weapon's salvo plus half its reload are one shot. The def's own reload
	// time is its quickest weapon's (b3: the Starfall moved on after 1-7 s).
	if (tierShotGap < 0) {
		float reload = 0.f, salvo = 0.f;
		auto mounts = unit->GetCircuitDef()->GetDef()->GetWeaponMounts();
		for (springai::WeaponMount* mount : mounts) {
			springai::WeaponDef* wd = mount->GetWeaponDef();
			if (wd->GetReload() > reload) {
				reload = wd->GetReload();
				salvo = wd->GetSalvoDelay() * std::max(0, wd->GetSalvoSize() - 1);
			}
			delete wd;
			delete mount;
		}
		tierShotGap = std::max(FRAMES_PER_SEC / 2, int((salvo + reload * 0.5f) * FRAMES_PER_SEC));
		manager->GetCircuit()->LOG("TIER: %s(%i): one shot = fire events within %i frames (reload %.1f s, salvo %.1f s)",
				unit->GetCircuitDef()->GetDef()->GetName(), unit->GetId(), tierShotGap, reload, salvo);
	}
	if (frame - tierShotFrame < tierShotGap) return;
	tierShotFrame = frame;
	if (++tierRotation.shots >= tierDwellShots) {
		targetFrame = frame - tierRetargetFrames;  // the next area at the next update
	}
}

void CSuperTask::SetTargetPos(const AIFloat3& pos)
{
	SetTarget(nullptr);
	targetFrame = 0;
	isTargetOverride = geom::is_valid(pos);
	if (isTargetOverride) {
		targetPos = pos;
		targetPos.y = manager->GetCircuit()->GetMap()->GetElevationAt(pos.x, pos.z);
	}
}

void CSuperTask::ExecuteAttack(CCircuitUnit* unit)
{
	CCircuitAI* circuit = manager->GetCircuit();
	const int frame = circuit->GetLastFrame();
	CCircuitDef* d = unit->GetCircuitDef();
	const bool nuke = IsNukeSilo(d), pulse = IsPulse(d);
	bool valid = CanAimStrategic(unit, targetPos);
	if (nuke && circuit->GetMilitaryManager()->GetNuclearInfo().structuresOnly) {
		bool structure = false;
		const auto* enemies = circuit->GetEnemyManager();
		for (const auto* pool : {&enemies->GetHostileDatas(), &enemies->GetPeaceDatas()}) for (const auto& e : *pool) {
			if (!e.IsFake() && !e.IsDead() && !e.IsDying() && !e.IsIgnore() && e.cdef != nullptr
				&& !e.cdef->IsMobile() && targetPos.SqDistance2D(e.pos) < SQUARE(d->GetAoe())) { structure = true; break; }
		}
		valid = valid && structure;
	}
	if (nuke && valid) {
		auto& allies = circuit->GetCallback()->GetFriendlyUnitsIn(targetPos, d->GetAoe());
		valid = allies.empty();
		utils::free(allies);
	}
	if ((nuke || pulse) && !valid) {
		TRY_UNIT(circuit, unit, unit->CmdStop();)
		circuit->GetAllyTeam()->GetPulseClaims().ReleasePending(unit->GetId());
		SetTarget(nullptr); isTargetOverride = false; targetFrame = frame; state = State::ROAM;
		return;
	}
	if (pulse && unit->GetUnit()->GetStockpile() > 0) {
		const auto& policy = circuit->GetMilitaryManager()->GetPulseInfo();
		circuit->GetAllyTeam()->GetPulseClaims().Add(unit->GetId(), {targetPos.x, targetPos.z}, d->GetAoe(), frame, policy.pendingFrames, true);
	}

	bool isFiring = !unit->GetCircuitDef()->IsAttrStock() || (unit->GetUnit()->GetStockpile() > 0);
	std::string cmd = isFiring ? "ai_super_fire:" : "ai_super_intention:";
	cmd += std::format("{}/{}/{}", unit->GetId(), int(targetPos.x), int(targetPos.z));
	circuit->GetLua()->CallRules(cmd.c_str(), cmd.size());

	TRY_UNIT(circuit, unit,
		if (!isTargetOverride && (GetTarget() != nullptr)
			&& GetTarget()->IsInRadarOrLOS() && !circuit->IsCheating())
		{
			unit->GetUnit()->Attack(GetTarget()->GetUnit(), UNIT_COMMAND_OPTION_RIGHT_MOUSE_KEY, frame + FRAMES_PER_SEC * 60);
		} else {
			unit->CmdAttackGround(targetPos, UNIT_COMMAND_OPTION_RIGHT_MOUSE_KEY, frame + FRAMES_PER_SEC * 60);
		}
	)
	targetFrame = frame;
	state = State::ENGAGE;
}

} // namespace circuit
