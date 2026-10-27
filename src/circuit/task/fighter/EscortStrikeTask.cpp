/*
 * EscortStrikeTask.cpp
 *
 * See EscortStrikeTask.h.
 */

#include "task/fighter/EscortStrikeTask.h"
#include "task/fighter/EscortStrikeRules.h"
#include "module/MilitaryManager.h"
#include "unit/CircuitUnit.h"
#include "unit/CircuitDef.h"
#include "unit/CircuitWDef.h"
#include "unit/enemy/EnemyUnit.h"
#include "CircuitAI.h"
#include "util/Utils.h"

#include "AISCommands.h"
#include "Log.h"
#include "UnitDef.h"
#include "Unit.h"
#include "Command.h"
#include "Sim/Units/CommandAI/Command.h"

#include <algorithm>
#include <climits>
#include <cmath>

namespace circuit {

using namespace springai;

// Shortest gap between two orders to one member: absorbs an idle storm and a
// vip swap landing in the same second; the next task update retries.
#define ESCORT_ORDER_GAP	(FRAMES_PER_SEC / 2)
// Siege: a target's spot seen empty this long means the target no longer exists.
#define SIEGE_HIDDEN_FRAMES	(FRAMES_PER_SEC * 3)

CEscortStrikeTask::CEscortStrikeTask(ITaskModule* mgr)
		: IFighterTask(mgr, FightType::GUARD, 1.f)
		, vipId(-1)
		, strikeRadius(600.f)
		, perTarget(2)
		, attackFrames(FRAMES_PER_SEC * 45)
		, siege(false)
		, home(-1.f, 0.f, -1.f)
		, fighterEscort(false)
		, strikesIssued(0)
		, shotsFired(0)
		, targetsDestroyed(0)
		, nextGuardCheck(0)
{
}

CEscortStrikeTask::~CEscortStrikeTask()
{
}

bool CEscortStrikeTask::CanAssignTo(CCircuitUnit* unit) const
{
	return unit->GetCircuitDef()->IsAbleToFly();  // script decides membership beyond that
}

void CEscortStrikeTask::AssignTo(CCircuitUnit* unit)
{
	IFighterTask::AssignTo(unit);
	guarding[unit->GetId()] = -1;
}

void CEscortStrikeTask::RemoveAssignee(CCircuitUnit* unit)
{
	const int id = unit->GetId();
	strikes.erase(id); guarding.erase(id); lastOrder.erase(id); fired.erase(id); sentHome.erase(id);
	IFighterTask::RemoveAssignee(unit);
	if (!unit->IsDead()) {
		// Back to the def's own states for whatever task takes it next.
		unit->TrySetFireState(unit->GetCircuitDef()->GetFireState());
		unit->TrySetMoveState(unit->GetCircuitDef()->GetMoveState());
		unit->TrySetIdleMode(1);
	}
	if (units.empty()) {
		manager->AbortTask(this);  // nothing left to escort with; leave the task sets
	}
}

bool CEscortStrikeTask::ForgetUnit(CCircuitUnit* unit)
{
	const int id = unit->GetId();
	strikes.erase(id); guarding.erase(id); lastOrder.erase(id); fired.erase(id); sentHome.erase(id);
	return IFighterTask::ForgetUnit(unit);
}

void CEscortStrikeTask::Start(CCircuitUnit* unit)
{
	// Fly while waiting; hold fire so a nuclear payload never drops on an
	// incidental contact. An explicit ATTACK still fires (as in CAirWaveTask).
	// Hold position too: the engine's air GUARD (CAirCAI::ExecuteGuard) pushes
	// an internal ATTACK on whatever last shot the guarded bomber (flak, a
	// fighter), whatever the fire state, unless the move state is HOLDPOS and
	// the attacker is outside the weapon's reach (2026-10-25: Liches left the
	// guard for the flak that shot their bomber and died without firing).
	unit->TrySetIdleMode(0);
	if (fighterEscort) {
		// Fighters: the engine's air GUARD answers whatever shoots the vip; that is the job.
		unit->TrySetFireState(unit->GetCircuitDef()->GetFireState());
		unit->TrySetMoveState(unit->GetCircuitDef()->GetMoveState());
	} else {
		unit->TrySetFireState(CCircuitDef::FireType::HOLD);
		unit->TrySetMoveState(CCircuitDef::MoveType::HOLD_POS);
	}
	const int frame = manager->GetCircuit()->GetLastFrame();
	CCircuitUnit* vip = ResolveVip(frame);
	if (vip != nullptr) {
		GuardVip(unit, vip, frame);
	}
}

void CEscortStrikeTask::AddEscortTarget(int unitId)
{
	if (unitId < 0 || std::find(vipIds.begin(), vipIds.end(), unitId) != vipIds.end()) return;
	vipIds.push_back(unitId);
}

void CEscortStrikeTask::AllowStrikeDef(CCircuitDef* def, float priority)
{
	if (def != nullptr && std::isfinite(priority) && priority > 0.f) {
		allowedStrikeDefs[def->GetId()] = priority;
	}
}

void CEscortStrikeTask::SetStrikePolicy(float radius, int targetCap, int attackSeconds)
{
	if (!std::isfinite(radius)) return;
	strikeRadius = std::clamp(radius, 0.f, 10000.f);
	perTarget = targetCap;
	attackFrames = std::clamp(attackSeconds, 1, 3600) * FRAMES_PER_SEC;
}

/*
 * The vip stays while it lives. When it is gone, the living candidate nearest
 * the members takes over: O(candidates) team-unit lookups, only on a swap.
 */
CCircuitUnit* CEscortStrikeTask::ResolveVip(int frame)
{
	CCircuitAI* circuit = manager->GetCircuit();
	if (vipId >= 0) {
		CCircuitUnit* vip = circuit->GetTeamUnit(vipId);
		if (vip != nullptr && !vip->IsDead()) return vip;
	}
	AIFloat3 centre;
	int members = 0;
	for (CCircuitUnit* unit : units) {
		if (unit->IsDead()) continue;
		centre += unit->GetPos(frame);
		++members;
	}
	if (members > 0) centre /= float(members);
	const int previous = vipId;
	CCircuitUnit* best = nullptr;
	float bestDistance = 0.f;
	for (auto it = vipIds.begin(); it != vipIds.end(); ) {
		CCircuitUnit* candidate = circuit->GetTeamUnit(*it);
		if (candidate == nullptr || candidate->IsDead()) {
			it = vipIds.erase(it);  // dead escort targets never come back
			continue;
		}
		const float distance = (members > 0) ? centre.SqDistance2D(candidate->GetPos(frame)) : 0.f;
		if (best == nullptr || distance < bestDistance) {
			best = candidate; bestDistance = distance;
		}
		++it;
	}
	vipId = (best != nullptr) ? best->GetId() : -1;
	if (vipId != previous) {
		circuit->LOG("ESCORT: team=%i vip %i -> %i members=%zu candidates=%zu", circuit->GetTeamId(), previous, vipId,
				units.size(), vipIds.size());
	}
	return best;
}

void CEscortStrikeTask::GuardVip(CCircuitUnit* unit, CCircuitUnit* vip, int frame)
{
	const int id = unit->GetId();
	auto last = lastOrder.find(id);
	const int lastFrame = (last != lastOrder.end()) ? last->second : INT_MIN / 2;
	auto guard = guarding.find(id);
	const int current = (guard != guarding.end()) ? guard->second : -1;
	if (!escort_strike::NeedsGuardOrder(current, vip->GetId(), lastFrame, frame, ESCORT_ORDER_GAP)) return;
	if (unit->IsDead() || vip->IsDead()) return;
	CCircuitAI* circuit = manager->GetCircuit();
	TRY_UNIT(circuit, unit,
		unit->GetUnit()->Guard(vip->GetUnit());
	)
	guarding[id] = vip->GetId();
	lastOrder[id] = frame;
}

/*
 * Once a second: a guarding member whose queue the engine fronted with its own
 * ATTACK (the guard's response to the bomber's attacker, within weapon reach)
 * gets its GUARD again, so only a roster target in sight breaks the guard.
 * O(members) command reads; the wrapper vectors are freed at once.
 */
void CEscortStrikeTask::CheckGuards(CCircuitUnit* vip, int frame)
{
	CCircuitAI* circuit = manager->GetCircuit();
	for (CCircuitUnit* unit : units) {
		const int id = unit->GetId();
		if (unit->IsDead() || strikes.count(id) != 0) continue;
		auto guard = guarding.find(id);
		if (guard == guarding.end() || guard->second != vip->GetId()) continue;
		int front = -1;
		TRY_UNIT(circuit, unit,
			std::vector<springai::Command*> commands = unit->GetUnit()->GetCurrentCommands();
			if (!commands.empty()) front = commands.front()->GetId();
			utils::free_clear(commands);
		)
		if (front != CMD_ATTACK) continue;
		circuit->LOG("ESCORT: team=%i guard broken unit=%i by engine attack: guard vip=%i again", circuit->GetTeamId(), id,
				vip->GetId());
		guard->second = -1;
		GuardVip(unit, vip, frame);  // rate-limited; otherwise the next update
	}
}

/*
 * One pass over the known enemies per update, before any member looks: keeps
 * only allowed defs that a striker could take. O(enemies); the per-member pick
 * below is O(members x candidates), and candidates are a handful of roster defs.
 */
void CEscortStrikeTask::CollectCandidates()
{
	candidates.clear();
	if (allowedStrikeDefs.empty() || (!siege && strikeRadius <= 0.f)) return;
	CCircuitAI* circuit = manager->GetCircuit();
	for (const auto& entry : circuit->GetEnemyInfos()) {
		CEnemyInfo* enemy = entry.second;
		const CEnemyUnit* data = enemy->GetData();
		CCircuitDef* def = enemy->GetCircuitDef();
		if (def == nullptr || enemy->GetUnit() == nullptr || data->IsFake() || data->IsDead() || data->IsDying()
			|| enemy->IsHidden()) continue;
		const auto priority = allowedStrikeDefs.find(def->GetId());
		if (priority == allowedStrikeDefs.end()) continue;
		if (enemy->GetPos().y < -SQUARE_SIZE * 5) continue;  // deep underwater
		candidates.push_back({enemy, priority->second});
	}
}

int CEscortStrikeTask::StrikersOn(int targetId) const
{
	int count = 0;
	for (const auto& strike : strikes) if (strike.second.targetId == targetId) ++count;
	return count;
}

bool CEscortStrikeTask::TryStrike(CCircuitUnit* unit, int frame)
{
	if (candidates.empty() || unit->IsDead()) return false;
	const int id = unit->GetId();
	auto last = lastOrder.find(id);
	if (last != lastOrder.end() && !escort_strike::OrderAllowed(last->second, frame, ESCORT_ORDER_GAP)) return false;
	const AIFloat3& pos = unit->GetPos(frame);
	CEnemyInfo* best = nullptr;
	float bestPriority = 0.f, bestDistance = 0.f;
	int bestId = -1;
	for (const SCandidate& candidate : candidates) {
		CEnemyInfo* enemy = candidate.enemy;
		const float distance = pos.SqDistance2D(enemy->GetPos());
		// Siege: a known def means the unit was seen at least once (radar alone carries no def).
		if (siege ? !escort_strike::SiegeCandidate(candidate.priority, enemy->GetCircuitDef() != nullptr)
			: !escort_strike::StrikeCandidate(candidate.priority, enemy->IsInLOS(), distance, strikeRadius)) continue;
		const int enemyId = enemy->GetId();
		if (!escort_strike::HasStrikeRoom(StrikersOn(enemyId), perTarget)) continue;
		if (escort_strike::BetterStrike(candidate.priority, distance, enemyId, bestPriority, bestDistance, bestId)) {
			best = enemy; bestPriority = candidate.priority; bestDistance = distance; bestId = enemyId;
		}
	}
	if (best == nullptr) return false;
	CCircuitAI* circuit = manager->GetCircuit();
	// In sight (always, outside siege): take the unit itself. A siege target out
	// of sight: bomb its last known spot, as a Juno does.
	const bool ground = !best->IsInLOS();
	if (ground) {
		TRY_UNIT(circuit, unit,
			unit->CmdAttackGround(best->GetPos(), UNIT_COMMAND_OPTION_RIGHT_MOUSE_KEY, frame + attackFrames);
		)
	} else {
		unit->Attack(best, false, frame + attackFrames, false);
	}
	strikes[id] = {bestId, frame + attackFrames, false, ground, best->GetPos(), false, -1};
	guarding[id] = -1;  // the ATTACK replaced the GUARD
	sentHome.erase(id);
	lastOrder[id] = frame;
	++strikesIssued;
	circuit->LOG("ESCORT: team=%i strike unit=%i target=%s(%i) priority=%.1f distance=%.0f radius=%.0f vip=%i los=%i strikers=%i siege=%i at=%.0f,%.0f",
			circuit->GetTeamId(), id, best->GetCircuitDef()->GetDef()->GetName(), bestId, bestPriority, std::sqrt(bestDistance),
			strikeRadius, vipId, int(best->IsInLOS()), StrikersOn(bestId), int(siege), best->GetPos().x, best->GetPos().z);
	return true;
}

/*
 * Once per strike per update: O(1) enemy lookup, an order only when the target
 * leaves or re-enters sight (never twice inside ESCORT_ORDER_GAP).
 */
void CEscortStrikeTask::FollowTarget(CCircuitUnit* unit, SStrike& strike, int frame)
{
	CCircuitAI* circuit = manager->GetCircuit();
	CEnemyInfo* target = circuit->GetEnemyInfo(strike.targetId);
	if (target == nullptr || target->GetUnit() == nullptr || unit->IsDead()) return;
	const bool visible = target->IsInLOS();
	if (visible) {
		strike.lastSeen = target->GetPos();
	}
	// Siege: a finished or expired order on a living target is given again.
	const bool toGround = strike.reissue ? !visible : escort_strike::NeedsGroundStrike(strike.ground, visible);
	if (!toGround && !strike.reissue && !escort_strike::NeedsUnitStrike(strike.ground, visible)) return;
	const int id = unit->GetId();
	auto last = lastOrder.find(id);
	if (last != lastOrder.end() && !escort_strike::OrderAllowed(last->second, frame, ESCORT_ORDER_GAP)) return;
	if (strike.reissue) {
		strike.until = frame + attackFrames;
		strike.reissue = false;
	}
	if (toGround) {
		// Out of sight: bomb where it was last seen, not a radar dot or an engine guess.
		TRY_UNIT(circuit, unit,
			unit->CmdAttackGround(strike.lastSeen, UNIT_COMMAND_OPTION_RIGHT_MOUSE_KEY, strike.until);
		)
	} else {
		unit->Attack(target, false, strike.until, false);
	}
	strike.ground = toGround;
	lastOrder[id] = frame;
	circuit->LOG("ESCORT: team=%i strike follow unit=%i target=%i %s at=%.0f,%.0f", circuit->GetTeamId(), id,
			strike.targetId, toGround ? "ground (out of sight)" : "unit (in sight)", strike.lastSeen.x, strike.lastSeen.z);
}

/*
 * Dead, dying or forgotten. A target out of sight (even one whose last seen
 * spot is in sight and empty: hidden) is not gone: the strike bombs that spot
 * (FollowTarget) and ends on idle or timeout.
 */
bool CEscortStrikeTask::IsTargetGone(int targetId) const
{
	CEnemyInfo* target = manager->GetCircuit()->GetEnemyInfo(targetId);
	if (target == nullptr || target->GetUnit() == nullptr) return true;
	const CEnemyUnit* data = target->GetData();
	return data->IsDead() || data->IsDying();
}

/*
 * Siege: its last known spot in sight and empty for SIEGE_HIDDEN_FRAMES means it no
 * longer exists there. One frame of it is not enough: the flag is set between the
 * target leaving and re-entering sight (2026-10-27 retest: a geo flagged, struck
 * 22 frames later). O(1) per strike per update.
 */
bool CEscortStrikeTask::IsSiegeTargetGone(SStrike& strike, int frame) const
{
	if (IsTargetGone(strike.targetId)) return true;
	CEnemyInfo* target = manager->GetCircuit()->GetEnemyInfo(strike.targetId);
	if (!target->GetData()->IsHidden()) {
		strike.hiddenFrame = -1;
		return false;
	}
	if (strike.hiddenFrame < 0) strike.hiddenFrame = frame;
	return frame - strike.hiddenFrame >= SIEGE_HIDDEN_FRAMES;
}

void CEscortStrikeTask::EndStrike(int unitId, const char* reason)
{
	auto it = strikes.find(unitId);
	if (it == strikes.end()) return;
	CCircuitAI* circuit = manager->GetCircuit();
	const bool gone = IsTargetGone(it->second.targetId);
	if (gone && it->second.fired) ++targetsDestroyed;
	circuit->LOG("ESCORT: team=%i strike over unit=%i target=%i reason=%s fired=%i targetGone=%i ground=%i",
			circuit->GetTeamId(), unitId, it->second.targetId, reason, int(it->second.fired), int(gone),
			int(it->second.ground));
	strikes.erase(it);
	guarding[unitId] = -1;  // rejoin the escort
}

void CEscortStrikeTask::Update()
{
	CCircuitAI* circuit = manager->GetCircuit();
	const int frame = circuit->GetLastFrame();
	if (units.empty()) return;

	// Settle strikes whose target is gone or whose order expired.
	std::vector<int> over;
	for (auto& strike : strikes) {
		const bool gone = siege ? IsSiegeTargetGone(strike.second, frame) : IsTargetGone(strike.second.targetId);
		if (siege) {
			if (escort_strike::SiegeStrikeOver(gone)) {
				over.push_back(strike.first);
			} else if (frame >= strike.second.until) {
				strike.second.reissue = true;  // same target, fresh order (FollowTarget)
			}
		} else if (escort_strike::StrikeOver(gone, frame, strike.second.until)) {
			over.push_back(strike.first);
		}
	}
	for (int unitId : over) {
		EndStrike(unitId, (!siege && frame >= strikes[unitId].until) ? "timeout" : "target gone");
	}
	// Standing strikes follow their target in and out of sight.
	for (auto& strike : strikes) {
		CCircuitUnit* striker = circuit->GetTeamUnit(strike.first);
		if (striker != nullptr && units.count(striker) != 0) {
			FollowTarget(striker, strike.second, frame);
		}
	}

	CCircuitUnit* vip = ResolveVip(frame);
	if (vip != nullptr && !fighterEscort && frame >= nextGuardCheck) {
		nextGuardCheck = frame + FRAMES_PER_SEC;
		CheckGuards(vip, frame);
	}
	if (strikes.size() < units.size()) {
		CollectCandidates();
	}
	// Members may leave below (no escort left, script hooks); walk a copy.
	const std::vector<CCircuitUnit*> members(units.begin(), units.end());
	for (CCircuitUnit* unit : members) {
		if (IsDead()) return;
		if (units.count(unit) == 0 || unit->IsDead() || strikes.count(unit->GetId()) != 0) continue;
		if (TryStrike(unit, frame)) continue;
		if (vip != nullptr) {
			GuardVip(unit, vip, frame);
		} else if (siege) {
			// No scouted target: fly home once and wait there, not over the enemy base
			// (2026-10-27 test: Liches hovering where their target died were shot down).
			const int id = unit->GetId();
			auto last = lastOrder.find(id);
			if (home.x >= 0.f && sentHome.count(id) == 0
				&& (last == lastOrder.end() || escort_strike::OrderAllowed(last->second, frame, ESCORT_ORDER_GAP))) {
				TRY_UNIT(circuit, unit,
					unit->CmdMoveTo(home);
				)
				sentHome.insert(id);
				lastOrder[id] = frame;
				circuit->LOG("ESCORT: team=%i siege unit=%i no scouted target: home %.0f,%.0f", circuit->GetTeamId(), id, home.x, home.z);
			}
			continue;
		} else {
			// No escort target alive: the raid is over for this member. Hand it
			// to the idle task (ITaskModule::AssignTask(unit) would only add a
			// second task without leaving this one); idle asks script, which
			// stages it at home for the next wave (AirLiches::MakeTask).
			circuit->LOG("ESCORT: team=%i release unit=%i: no escort target left", circuit->GetTeamId(), unit->GetId());
			RemoveAssignee(unit);
		}
	}
	candidates.clear();  // enemy handles must not outlive this update
}

void CEscortStrikeTask::OnUnitIdle(CCircuitUnit* unit)
{
	IFighterTask::OnUnitIdle(unit);
	const int id = unit->GetId();
	// The ATTACK finished (target dead) or the GUARD ended (vip dead). Either
	// way the standing order is gone; the next update re-issues one, once.
	auto strike = strikes.find(id);
	if (strike != strikes.end() && siege && !IsTargetGone(strike->second.targetId)) {
		strike->second.reissue = true;  // siege keeps its target while it exists
		return;
	}
	if (strike != strikes.end()) {
		EndStrike(id, "idle");
	} else {
		guarding[id] = -1;
	}
	const int frame = manager->GetCircuit()->GetLastFrame();
	CCircuitUnit* vip = ResolveVip(frame);
	if (vip != nullptr) {
		GuardVip(unit, vip, frame);  // rate-limited; otherwise Update retries
	}
}

void CEscortStrikeTask::OnUnitDamaged(CCircuitUnit* unit, CEnemyInfo* attacker)
{
	// Committed: no retreat, no scatter (as CAirWaveTask).
}

void CEscortStrikeTask::OnUnitDestroyed(CCircuitUnit* unit, CEnemyInfo* attacker)
{
	CCircuitAI* circuit = manager->GetCircuit();
	const int id = unit->GetId();
	auto strike = strikes.find(id);
	circuit->LOG("ESCORT: team=%i lost unit=%i fired=%i striking=%i target=%i", circuit->GetTeamId(), id,
			int(fired.count(id) != 0), int(strike != strikes.end()), (strike != strikes.end()) ? strike->second.targetId : -1);
	IFighterTask::OnUnitDestroyed(unit, attacker);
}

void CEscortStrikeTask::OnWeaponFired(CCircuitUnit* unit, int weaponDefId)
{
	auto strike = strikes.find(unit->GetId());
	if (strike == strikes.end() || strike->second.fired) return;
	CWeaponDef* weapon = manager->GetCircuit()->GetWeaponDef(weaponDefId);
	if (weapon == nullptr || weapon->IsParalyzer() || weapon->GetDamage() <= 0.f) return;
	strike->second.fired = true;
	fired.insert(unit->GetId());
	++shotsFired;
	CCircuitAI* circuit = manager->GetCircuit();
	circuit->LOG("ESCORT: team=%i fired unit=%i target=%i weapon=%i", circuit->GetTeamId(), unit->GetId(),
			strike->second.targetId, weaponDefId);
}

} // namespace circuit
