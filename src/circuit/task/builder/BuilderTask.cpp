/*
 * BuilderTask.cpp
 *
 *  Created on: Sep 11, 2014
 *      Author: rlcevg
 */

#include "task/builder/BuilderTask.h"
#include "task/DormantTaskChain.h"
#include "terrain/ReservationClaim.h"
#include "task/builder/BuildChain.h"
#include "task/builder/DefenceTask.h"  // Only for static_cast<CBDefenceTask*>
#include "task/RetreatTask.h"
#include "map/ThreatMap.h"
#include "map/InfluenceMap.h"
#include "module/EconomyManager.h"
#include "module/BuilderManager.h"
#include "module/MilitaryManager.h"
#include "resource/MetalManager.h"
#include "resource/EnergyGrid.h"
#include "setup/SetupManager.h"
#include "terrain/TerrainManager.h"
#include "terrain/path/PathFinder.h"
#include "terrain/path/QueryPathSingle.h"
#include "unit/action/DGunAction.h"
#include "unit/action/CaptureAction.h"
#include "unit/action/FightAction.h"
#include "unit/action/MoveAction.h"
#include "CircuitAI.h"
#include "util/Utils.h"

#include "spring/SpringCallback.h"
#include "spring/SpringMap.h"
#include "spring/SpringUnit.h"
#include "Sim/Units/CommandAI/Command.h"

#include "AISCommands.h"
#include "Log.h"

#include <climits>
#include <cmath>

namespace circuit {

using namespace springai;

IBuilderTask::BuildName IBuilderTask::buildNames = {
	{"factory", IBuilderTask::BuildType::FACTORY},
	{"nano",    IBuilderTask::BuildType::NANO},
	{"store",   IBuilderTask::BuildType::STORE},
	{"pylon",   IBuilderTask::BuildType::PYLON},
	{"energy",  IBuilderTask::BuildType::ENERGY},
	{"geo",     IBuilderTask::BuildType::GEO},
	{"defence", IBuilderTask::BuildType::DEFENCE},
	{"bunker",  IBuilderTask::BuildType::BUNKER},
	{"big_gun", IBuilderTask::BuildType::BIG_GUN},
	{"radar",   IBuilderTask::BuildType::RADAR},
	{"sonar",   IBuilderTask::BuildType::SONAR},
	{"convert", IBuilderTask::BuildType::CONVERT},
	{"mex",     IBuilderTask::BuildType::MEX},
	{"mexup",   IBuilderTask::BuildType::MEXUP},
};

IBuilderTask::IBuilderTask(ITaskModule* mgr, Priority priority,
						   CCircuitDef* buildDef, const AIFloat3& position,
						   Type type, BuildType buildType, SResource cost, float shake, int timeout)
		: IUnitTask(mgr, priority, type, timeout)
		, buildType(buildType)
		, position(position)
		, shake(shake)
		, buildDef(buildDef)
		, canAutoAbort(true)
		, buildPower({0.f, 0.f})
		, cost(cost)
		, target(nullptr)
		, buildPos(-RgtVector)
		, facing(UNIT_NO_FACING)
		, reservationId(-1)
		, pinnedReservation(-1)
		, pinRequired(false)
		, pinFailed(false)
		, layoutOwned(false)
		, nextTask(nullptr)
		, initiator(nullptr)
		, buildFails(0)
		, unitIt(units.end())
{
	CEconomyManager* economyMgr = manager->GetCircuit()->GetEconomyManager();
	savedIncome.metal = economyMgr->GetAvgMetalIncome();
	savedIncome.energy = economyMgr->GetAvgEnergyIncome();
}

IBuilderTask::IBuilderTask(ITaskModule* mgr, Type type, BuildType buildType)
		: IUnitTask(mgr, type)
		, buildType(buildType)
		, position(-RgtVector)
		, shake(0.f)
		, buildDef(nullptr)
		, canAutoAbort(true)
		, buildPower({0.f, 0.f})
		, cost({0.f, 0.f})
		, target(nullptr)
		, buildPos(-RgtVector)
		, facing(UNIT_NO_FACING)
		, reservationId(-1)
		, pinnedReservation(-1)
		, pinRequired(false)
		, pinFailed(false)
		, layoutOwned(false)
		, nextTask(nullptr)
		, initiator(nullptr)
		, savedIncome({0.f, 0.f})
		, buildFails(0)
		, unitIt(units.end())
{
}

IBuilderTask::~IBuilderTask()
{
	ReleaseDormantTaskChain(nextTask);
}

bool IBuilderTask::CanAssignTo(CCircuitUnit* unit) const
{
    const auto health = constructionHealth.find(unit);
    if (health != constructionHealth.end() && manager->GetCircuit()->GetLastFrame() < health->second.retryAfter) return false;
	// can unit build at all
	const CCircuitDef* cdef = unit->GetCircuitDef();
	if (((target == nullptr) || !cdef->IsAbleToAssist() || unit->IsAttrSolo()) && !cdef->CanBuild(buildDef)) {
		return false;
	}
	// is extra buildpower required?
	CEconomyManager* economyMgr = manager->GetCircuit()->GetEconomyManager();
	if (buildType == BuildType::MEXUP && economyMgr->IsMexNavigationEnabled()
			&& !economyMgr->CanReachMex(unit, position)) return false;
	if (cost.metal < buildPower.metal * buildDef->GetGoalBuildTime(economyMgr->GetAvgMetalIncome())) {  // upper metal bound
		return false;
	}
	// energy income check
	if ((target == nullptr) && economyMgr->IsEnergyStalling() && !economyMgr->IsEnoughEnergy(this, cdef, 0.8f)) {  // lower energy bound
		return false;
	}
	// solo/initiator check
	return !unit->IsAttrSolo() || (initiator == unit) || ((initiator == nullptr) && (target == nullptr));
}

void IBuilderTask::AssignTo(CCircuitUnit* unit)
{
	IUnitTask::AssignTo(unit);

	CCircuitAI* circuit = manager->GetCircuit();
	ShowAssignee(unit);
	if (!geom::is_valid(position)) {
		position = unit->GetPos(circuit->GetLastFrame());
	}
	if (initiator == nullptr) {  // unit->IsAttrSolo()
		initiator = unit;
	}

	if (unit->HasDGun()) {
		const float range = std::max(unit->GetDGunRange(), unit->GetCircuitDef()->GetLosRadius());
		unit->PushDGunAct(new CDGunAction(unit, range));
	}
	if (unit->GetCircuitDef()->IsAbleToCapture()) {
		unit->PushBack(new CCaptureAction(unit, 500.f));
	}

	// NOTE: only for unit->GetCircuitDef()->IsMobile()
	int squareSize = circuit->GetPathfinder()->GetSquareSize();
	CCircuitDef* cdef = unit->GetCircuitDef();
	ITravelAction* travelAction;
	if (cdef->IsAttrSiege()) {
		travelAction = new CFightAction(unit, squareSize);
	} else {
		travelAction = new CMoveAction(unit, squareSize);
	}
	unit->PushTravelAct(travelAction);
	travelAction->StateWait();
	unit->SetAllowedToJump(cdef->IsAbleToJump() && cdef->IsAttrJump());
}

void IBuilderTask::RemoveAssignee(CCircuitUnit* unit)
{
	if ((units.find(unit) == unitIt) && (unitIt != units.end())) {
		++unitIt;
	}
	if (initiator == unit) {
		initiator = nullptr;
	}

	if (IsExperimental() && (buildDef != nullptr) && (unit->GetCircuitDef() != nullptr)) {
		// D-070 diagnostics: who leaves which order, and with what left
		CCircuitAI* circuit = manager->GetCircuit();
		const AIFloat3& p = unit->GetPos(circuit->GetLastFrame());
		circuit->LOG("EXP: leave: %s(%i) off %s at (%.0f, %.0f), site (%.0f, %.0f), %i other(s) left, target %s, fails %i",
				unit->GetCircuitDef()->GetDef()->GetName(), unit->GetId(), buildDef->GetDef()->GetName(), p.x, p.z,
				GetPosition().x, GetPosition().z, int(units.size()) - 1, (target != nullptr) ? "yes" : "no", buildFails);
	}
	constructionHealth.erase(unit);
	IUnitTask::RemoveAssignee(unit);
	traveled.erase(unit);
	executors.erase(unit);
	engaged.erase(unit);
	approaching.erase(unit);

	HideAssignee(unit);
}

void IBuilderTask::Start(CCircuitUnit* unit)
{
	Update(unit);
}

void IBuilderTask::Update()
{
	decltype(traveled) tmpTraveled = traveled;
	for (CCircuitUnit* unit : tmpTraveled) {
		if (IsExperimental() && (engaged.find(unit) != engaged.end())) {
			continue;  // D-064: its command stands
		}
		if (!Execute(unit)) {
			return;
		}
		if (IsExperimental()) {
			engaged.insert(unit);
		}
	}
	traveled.clear();

	CCircuitUnit* unit = GetNextAssignee();
	if (unit == nullptr) {
		return;
	}

	Update(unit);
}

void IBuilderTask::Stop(bool done)
{
	constructionHealth.clear();
	IUnitTask::Stop(done);
	// D-117 crash (owner's game, build101, F25307): IUnitTask::Stop clears
	// `units`, and unitIt was left on a freed node; a stopped task stays listed
	// until the update loop drops it, so ForgetUnitEverywhere (a turret dying)
	// then read and advanced the dangling iterator
	unitIt = units.end();
	traveled.clear();
	executors.clear();
	engaged.clear();
	approaching.clear();

	CEconomyManager* economyMgr = manager->GetCircuit()->GetEconomyManager();
	if ((buildDef != nullptr) && !economyMgr->IsIgnorePull(this)) {
		manager->DelMetalPull(buildPower.metal);
	}
	economyMgr->CorrectResourcePull(buildPower.metal, buildPower.energy);
}

void IBuilderTask::Finish()
{
	CCircuitAI* circuit = manager->GetCircuit();
	CBuilderManager* builderMgr = circuit->GetBuilderManager();
	if (buildDef != nullptr) {
		SBuildChain* chain = builderMgr->GetBuildChain(buildType, buildDef);
		if (chain != nullptr) {
			ExecuteChain(chain);
		}

		const int buildDelay = circuit->GetEconomyManager()->GetBuildDelay();
		if (buildDelay > 0) {
			IUnitTask* task = builderMgr->Enqueue(TaskB::Wait(buildDelay));
			decltype(units) tmpUnits = units;
			for (CCircuitUnit* unit : tmpUnits) {
				manager->AssignTask(unit, task);
			}
		}
	}

	// Advance queue
	if (nextTask != nullptr) {
		builderMgr->ActivateTask(nextTask);
		nextTask = nullptr;
	}
}

void IBuilderTask::Cancel()
{
	if ((target == nullptr) && geom::is_valid(buildPos)) {
		SetBuildPos(-RgtVector);
	}
	if ((target == nullptr) && (reservationId >= 0)) {
		// Never started: the planned site goes back on hold for the next task.
		manager->GetCircuit()->GetTerrainManager()->RestoreReservation(reservationId);
		reservationId = -1;
	} else if ((target == nullptr) && pinRequired && (pinnedReservation >= 0)) {
		manager->GetCircuit()->GetTerrainManager()->UnclaimReservation(pinnedReservation);
	}

	// Destructor will take care of the nextTask queue
}

bool IBuilderTask::Execute(CCircuitUnit* unit)
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
	if (TryBuildCachedSite(unit)) return true;

	// FIXME: Move to Reevaluate
	circuit->GetThreatMap()->SetThreatType(unit);
	// FIXME: Replace const 1000.f with build time?
	if (circuit->IsAllyAware() && (cost.metal > 1000.f)) {
		circuit->UpdateFriendlyUnits();
		const float dist = std::min(cost.metal, 1000.f);
		auto& friendlies = circuit->GetCallback()->GetFriendlyUnitsIn(position, dist);
		CAllyUnit* alu = FindSameAlly(unit, friendlies);
		utils::free(friendlies);
		if (alu != nullptr) {
			TRY_UNIT(circuit, unit,
				unit->CmdRepair(alu, UNIT_CMD_OPTION, CmdTimeout(frame));
			)
			return true;
		}
	}

	if (AdoptStandingFrame(unit)) return true;
	// Alter/randomize position
	AIFloat3 pos = (shake > .0f) ? geom::get_near_pos(position, shake) : position;
	CTerrainManager::CorrectPosition(pos);

	const float searchRadius = 200 * SQUARE_SIZE;
	FindBuildSite(unit, pos, searchRadius);

	if (geom::is_valid(buildPos)) {
		TRY_UNIT(circuit, unit,
			unit->CmdBuild(buildDef, buildPos, facing, 0, CmdTimeout(frame));
		)
	} else if (pinFailed) {
		circuit->LOG("RESERVE: aborting %s task after required slot %i failed",
				buildDef->GetDef()->GetName(), pinnedReservation);
		manager->AbortTask(this);
		return false;
	} else {
		if (geom::is_in_range(circuit->GetSetupManager()->GetBasePos(), position, searchRadius)) {  // base must be full
			circuit->GetSetupManager()->FindNewBase(unit);
		}

		// Fallback to Guard/Assist/Patrol
		manager->FallbackTask(unit);
		return false;
	}
	return true;
}

// Generic and nano execution must apply the same fresh allied-layout and
// engine checks before reusing a cached footprint. This adds no inventory scan.
bool IBuilderTask::TryBuildCachedSite(CCircuitUnit* unit)
{
    CCircuitAI* circuit = manager->GetCircuit();
    if (!geom::is_valid(buildPos)
        || !circuit->GetBuilderManager()->IsBuildPositionAllowed(buildDef, buildPos)
        || circuit->GetTerrainManager()->IsAllyLayoutBlocked(buildDef, buildPos, facing)
        || !circuit->GetMap()->IsPossibleToBuildAt(buildDef->GetDef(), buildPos, facing)) return false;
    TRY_UNIT(circuit, unit,
        unit->CmdBuild(buildDef, buildPos, facing, 0, CmdTimeout(circuit->GetLastFrame()));
    )
    return true;
}

// Only after cached-site rejection or eligible recovery; never a per-tick scan.
bool IBuilderTask::AdoptStandingFrame(CCircuitUnit* unit)
{
    if ((!IsExperimental() && !layoutOwned && !manager->GetCircuit()->GetBuilderManager()->IsConstructionRecoveryEnabled())
        || !buildDef || !geom::is_valid(buildPos)) return false;
    CCircuitAI* circuit = manager->GetCircuit();
    for (const auto& kv : circuit->GetTeamUnits()) {
        CCircuitUnit* frame = kv.second;
        if (!frame || frame->IsDead() || frame->IsFinished() || frame->GetCircuitDef() != buildDef
            || !IsEqualBuildPos(frame)) continue;
        UpdateTarget(frame);
        static_cast<CBuilderManager*>(manager)->MarkUnfinishedUnit(frame, this);
        circuit->LOG("BUILD_RECOVERY: adopt builder=%i frame=%i slot=%i", unit->GetId(), frame->GetId(), pinnedReservation);
        return true;
    }
    return false;
}

void IBuilderTask::RecoverConstruction(CCircuitUnit* unit, int retryFrames, int releaseFrames)
{
    if (isDead || unit->IsDead() || unit->GetTask() != this || units.count(unit) == 0
        || !buildDef || buildType >= BuildType::REPAIR) return;
    auto& observation = constructionHealth[unit];
    CCircuitAI* circuit = manager->GetCircuit();
    const int frame = circuit->GetLastFrame();
    // Queue presence protects resource-stalled frames. Pending paths, waits
    // and moving detours must not be mistaken for a missing engine command.
    construction::Progress progress{true, unit->IsWaiting(), IsQueryReady(unit),
        circuit->GetCallback()->Unit_HasCommands(unit->GetId()), false};
    if (progress.waiting || !progress.pathReady || (target && progress.commands)) {
        // Healthy framed construction is the common case. Avoid position,
        // velocity, economy and current-command callbacks for this entire path.
        observation.stationarySince = -1;
        observation.Observe(frame, false, retryFrames, releaseFrames);
        return;
    }
    progress.moving = unit->GetUnit()->GetVel().SqLength2D() >= 1e-3f;
    const auto& pos = unit->GetPos(frame);
    const bool stationary = observation.StalledCommand(frame, pos.x, pos.z,
        !target && progress.commands && !progress.waiting && progress.pathReady,
        2 * releaseFrames);
    bool stalled = false;
    if (stationary) {
        // Require a retry interval's construction resources, not the whole
        // project cost (a T2 lab can cost more than the base's storage capacity).
        // Do not infer failure from zero resource use: resource-starved frames
        // and native reclaim/terraform/wait commands must remain untouched.
        CEconomyManager* economy = circuit->GetEconomyManager();
        const int cmd = circuit->GetUnitAPI()->GetCMD(unit->GetId());
        stalled = (cmd == -buildDef->GetId() || cmd == CMD_MOVE)
            && construction::CanStart(economy->GetMetalCur(), economy->GetEnergyCur(),
                cost.metal, cost.energy, buildDef->GetBuildTime(), unit->GetWorkerTime(),
                float(retryFrames) / FRAMES_PER_SEC);
    }
    const auto action = observation.Observe(frame, progress.MissingCommand() || stalled, retryFrames, releaseFrames);
    if (action == construction::Recovery::NONE) return;
    if (!target && AdoptStandingFrame(unit)) { constructionHealth.erase(unit); return; }
    circuit->LOG("BUILD_RECOVERY: team=%i builder=%i def=%s state=%i slot=%i target=%i action=%s failureFrames=%i reason=%s",
        circuit->GetTeamId(), unit->GetId(), buildDef->GetDef()->GetName(), int(unit->GetTaskState()),
        reservationId >= 0 ? reservationId : pinnedReservation, target ? target->GetId() : -1,
        action == construction::Recovery::RETRY ? "retry" : "release", frame - observation.emptySince,
        stalled ? "funded-unstarted-no-progress" : "missing-command");
    if (action == construction::Recovery::RETRY) {
        engaged.erase(unit); approaching.erase(unit); traveled.erase(unit);
        // Re-use safe approach/path and frame ownership. In legacy compact
        // mode a finished travel action otherwise prevents Start doing work.
        if (target || (geom::is_valid(buildPos) && circuit->GetTerrainManager()->CanReachAtSafe(
                unit, buildPos, unit->GetCircuitDef()->GetBuildDistance()))) {
            if (IsExperimental()) Update(unit);
            else Execute(unit);
        } else {
            if (unit->GetTravelAct()) unit->GetTravelAct()->StateWait();
            Update(unit);
        }
        return; // Execute may have aborted this task; never read it afterwards.
    }
    // A failed worker is not a failed shared project. Keep frames and other
    // assignees; retire only an unstarted site no worker can safely use.
    RemoveAssignee(unit);
    if (unit->GetTask() == this) circuit->LOG("[INVARIANT] INV-174 lost construction assignment retained after recovery builder=%i",unit->GetId());
    constructionHealth[unit].retryAfter = frame + releaseFrames;
    if (isDead) return;
    bool validSite = true, reachable = true;
    if (!target && units.empty()) {
        validSite = !geom::is_valid(buildPos)
            || circuit->GetMap()->IsPossibleToBuildAt(buildDef->GetDef(),buildPos,facing);
        reachable = false;
        if (validSite) for (CCircuitUnit* candidate : circuit->GetBuilderManager()->GetWorkers()) {
            if (candidate == unit || candidate->IsDead() || !candidate->GetCircuitDef()->CanBuild(buildDef)) continue;
            if (circuit->GetTerrainManager()->CanReachAtSafe(candidate, GetPosition(), candidate->GetCircuitDef()->GetBuildDistance())) {
                reachable = true; break;
            }
        }
    }
    if (construction::RetireUnstarted(target != nullptr, !units.empty(), validSite, reachable)) manager->AbortTask(this);
}

void IBuilderTask::OnUnitIdle(CCircuitUnit* unit)
{
	engaged.erase(unit);  // D-064: the engine finished or dropped the command; a new one is due
	if (IsExperimental() && (buildDef != nullptr)) {
		CCircuitAI* circuit = manager->GetCircuit();
		const AIFloat3& upos = unit->GetPos(circuit->GetLastFrame());
		const bool arrived = (approaching.erase(unit) > 0);
		circuit->LOG("EXP: idle: %s(%i) on %s at (%.0f, %.0f), site (%.0f, %.0f), target %s, fails %i%s",
				unit->GetCircuitDef()->GetDef()->GetName(), unit->GetId(), buildDef->GetDef()->GetName(),
				upos.x, upos.z, GetPosition().x, GetPosition().z, (target != nullptr) ? "yes" : "no", buildFails + 1,
				arrived ? " (arrived at the approach point)" : "");
		if (arrived) {
			// The walk to the approach point ended: now the construction command,
			// from inside the range. Not a failure.
			if (Execute(unit)) {
				engaged.insert(unit);
			}
			return;
		}
		// The engine dropped the command while the unit was outside the range
		// (its own goal on the circle was blocked): walk to a free point first.
		const float dist = std::sqrt(upos.SqDistance2D(GetPosition()));
		if ((dist > EngageRange(unit)) && Approach(unit)) {
			return;
		}
	}
	if (++buildFails <= 2) {  // Workaround due to engine's ability randomly disregard orders
		if (Execute(unit) && IsExperimental()) {
			engaged.insert(unit);
		}
	} else if (buildFails <= TASK_RETRIES) {
		RemoveAssignee(unit);
	} else if (target == nullptr) {
		manager->AbortTask(this);
		manager->GetCircuit()->GetTerrainManager()->AddBlocker(buildDef, buildPos, facing);  // FIXME: Remove blocker on timer? Or when air con appears
	}
}

void IBuilderTask::OnUnitDamaged(CCircuitUnit* unit, CEnemyInfo* attacker)
{
	CCircuitAI* circuit = manager->GetCircuit();
	const int frame = circuit->GetLastFrame();
	CCircuitDef* cdef = unit->GetCircuitDef();
	const float healthPerc = unit->GetHealthPercent();
	if ((healthPerc > cdef->GetRetreat()) && !unit->IsDisarmed(frame)) {
		if (healthPerc < cdef->GetSelfDHP()) {
			unit->CmdSelfD(true);
		}
		return;
	}

	CRetreatTask* task = manager->EnqueueRetreat();
	manager->AssignTask(unit, task);

	if (canAutoAbort && (target == nullptr)) {
		manager->AbortTask(this);  // Doesn't call RemoveAssignee
	}
}

void IBuilderTask::OnUnitDestroyed(CCircuitUnit* unit, CEnemyInfo* attacker)
{
	RemoveAssignee(unit);
	// NOTE: AbortTask usually does not call RemoveAssignee for each unit
	if (canAutoAbort && ((target == nullptr) || units.empty()) && !unit->IsMorphing()) {
		manager->AbortTask(this);
	}
}

void IBuilderTask::OnTravelEnd(CCircuitUnit* unit)
{
	traveled.insert(unit);
}

void IBuilderTask::Activate()
{
	lastTouched = manager->GetCircuit()->GetLastFrame();
}

void IBuilderTask::Deactivate()
{
	lastTouched = -1;
}

void IBuilderTask::SetBuildPos(const AIFloat3& pos)
{
	CTerrainManager* terrainMgr = manager->GetCircuit()->GetTerrainManager();
	if (geom::is_valid(buildPos)) {
		terrainMgr->DelBlocker(buildDef, buildPos, facing);
	}
	if (geom::is_valid(pos)) {
		buildPos = CTerrainManager::Pos2BuildPos(buildDef, pos, facing);
		terrainMgr->AddBlocker(buildDef, buildPos, facing);
	} else {
		buildPos = pos;
	}
}

void IBuilderTask::SetTarget(CCircuitUnit* unit)
{
	CCircuitAI* circuit = manager->GetCircuit();
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	if (geom::is_valid(buildPos)) {
		terrainMgr->DelBlocker(buildDef, buildPos, facing);
	}
	target = unit;
	if ((unit != nullptr) && (reservationId >= 0)) {
		terrainMgr->FinishReservation(reservationId, unit->GetId());  // the structure exists; the plan is met
		reservationId = -1;
	}
	if (unit != nullptr) {
		facing = unit->GetUnit()->GetBuildingFacing();
		buildDef = unit->GetCircuitDef();
		buildPos = unit->GetPos(circuit->GetLastFrame()) + buildDef->GetMidPosOffset(facing);
	} else {
		buildPos = -RgtVector;
	}
	if (geom::is_valid(buildPos)) {
		terrainMgr->AddBlocker(buildDef, buildPos, facing);
	}
}

void IBuilderTask::UpdateTarget(CCircuitUnit* unit)
{
	// NOTE: unit->GetPos() may differ from buildPos
	SetTarget(unit);

	CCircuitAI* circuit = manager->GetCircuit();
	int frame = circuit->GetLastFrame() + FRAMES_PER_SEC * 60;
	for (CCircuitUnit* ass : units) {
		TRY_UNIT(circuit, ass,
			ass->CmdRepair(unit, UNIT_CMD_OPTION, frame);
		)
	}
}

bool IBuilderTask::IsEqualBuildPos(CCircuitUnit* unit) const
{
	AIFloat3 pos = unit->GetPos(manager->GetCircuit()->GetLastFrame());
	pos += unit->GetCircuitDef()->GetMidPosOffset(unit->GetUnit()->GetBuildingFacing());
	// NOTE: Unit's position is affected by collisionVolumeOffsets, and there is no way to retrieve it.
	//       Hence absurdly large error slack, @see factoryship.lua
	return geom::is_equal_pos(pos, buildPos, SQUARE_SIZE * 2);
}

CCircuitUnit* IBuilderTask::GetNextAssignee()
{
	if (units.empty()) {
		return nullptr;
	}
	if (unitIt == units.end()) {
		unitIt = units.begin();
	}
	CCircuitUnit* unit = *unitIt;
	++unitIt;
	return unit;
}

void IBuilderTask::Update(CCircuitUnit* unit)
{
	if (IsExperimental() && (target != nullptr) && (engaged.find(unit) != engaged.end())
		&& !manager->GetCircuit()->GetEconomyManager()->IsEnergyEmpty())
	{
		// (only a builder that already holds its command: a builder just
		// assigned to a standing frame still needs Execute below - played:
		// every builder idled five minutes on a full bank)
		// D-074 (owner's rule): construction has begun; the builder is not
		// re-evaluated, moved or re-pathed until it ends, unless energy is
		// empty. Played: the in-range re-evaluation moved the commander off
		// the first lab's held exit cone every five seconds ("obstructed"),
		// each move dropping the build command.
		return;
	}
	if (!Reevaluate(unit)) {
		return;
	}
	if (IsExperimental()) {
		// D-064: in range, or near enough for the engine to walk the last leg
		// itself, the command is given now; no AI waypoints past the range.
		if (TryEngage(unit) || (units.find(unit) == units.end())) {
			return;
		}
	}
	// D-114 crash (role-swap playtest, build97, F36014): a unit can be listed by
	// a task with no travel action (CCircuitUnit::ClearAct on leaving another
	// task wipes it; a role switch aborts and reassigns many at once). No travel
	// action: nothing to walk, as FighterTask already assumes.
	ITravelAction* travelAct = unit->GetTravelAct();
	if ((travelAct != nullptr) && !travelAct->IsFinished()) {
		UpdatePath(unit);  // Execute(unit) within OnTravelEnd
	}
}

/*
 * Experimental build mode (D-064, doc/experimental-build.md)
 */
bool IBuilderTask::IsExperimental() const
{
	const CBuilderManager* builderMgr = dynamic_cast<const CBuilderManager*>(manager);
	return (builderMgr != nullptr) && builderMgr->IsExperimentalBuild();
}

float IBuilderTask::EngageRange(CCircuitUnit* unit)
{
	// The engine's rule (Recoil BuilderCAI::GetBuildRange / MoveInBuildRange):
	// in range when |builder - site| <= buildDistance + modelRadius(buildee);
	// its own move goal is 0.9 of that. The same numbers, so the AI never
	// asks for a step the engine would not take.
	float radius = 0.f;
	if (target != nullptr) {
		radius = target->GetCircuitDef()->GetRadius();
	} else if (buildDef != nullptr) {
		radius = buildDef->GetRadius();
	}
	return (unit->GetCircuitDef()->GetBuildDistance() + radius) * 0.9f;
}

int IBuilderTask::CmdTimeout(int frame) const
{
	// A construction command that the engine drops after 60 s restarts the
	// nanolathe on every retry; in the mode the AI's task timeout is the limit.
	return IsExperimental() ? INT_MAX : frame + FRAMES_PER_SEC * 60;
}

bool IBuilderTask::Approach(CCircuitUnit* unit)
{
	// Flying builders can stop outside a ground approach disc because altitude
	// contributes to engine build range. Opt-in lets the engine's build command
	// choose their final position; existing ground/TECH approach stays unchanged.
	const auto* builderMgr = dynamic_cast<const CBuilderManager*>(manager);
	if ((builderMgr != nullptr) && builderMgr->IsExperimentalAirDirect()
		&& unit->GetCircuitDef()->IsAbleToFly()) return false;
	CCircuitAI* circuit = manager->GetCircuit();
	if (!geom::is_valid(GetPosition())) {
		return false;
	}
	// Inside the engine's range with a margin, on ground no structure holds.
	const AIFloat3 ap = circuit->GetTerrainManager()->FindApproachPoint(unit, GetPosition(), EngageRange(unit) - SQUARE_SIZE * 2);
	if (!geom::is_valid(ap)) {
		return false;
	}
	ITravelAction* travelAct = unit->GetTravelAct();
	if ((travelAct != nullptr) && !travelAct->IsFinished()) {
		travelAct->StateFinish();
	}
	TRY_UNIT(circuit, unit,
		unit->CmdMoveTo(ap, 0, INT_MAX);
	)
	engaged.erase(unit);
	approaching.insert(unit);
	const AIFloat3& upos = unit->GetPos(circuit->GetLastFrame());
	circuit->LOG("EXP: approach: %s(%i) at (%.0f, %.0f) walks to (%.0f, %.0f), %.0f from the %s site (%.0f, %.0f)",
			unit->GetCircuitDef()->GetDef()->GetName(), unit->GetId(), upos.x, upos.z, ap.x, ap.z,
			std::sqrt(ap.SqDistance2D(GetPosition())), (buildDef != nullptr) ? buildDef->GetDef()->GetName() : "task",
			GetPosition().x, GetPosition().z);
	return true;
}

bool IBuilderTask::TryEngage(CCircuitUnit* unit)
{
	if ((engaged.find(unit) != engaged.end()) || (approaching.find(unit) != approaching.end())) {
		return true;
	}
	CCircuitAI* circuit = manager->GetCircuit();
	const AIFloat3& pos = unit->GetPos(circuit->GetLastFrame());
	const float dist = std::sqrt(pos.SqDistance2D(GetPosition()));
	if (dist > EngageRange(unit)) {
		const CBuilderManager* builderMgr = static_cast<const CBuilderManager*>(manager);
		if (dist > builderMgr->GetExperimentalDirectRange()) {
			return false;  // far: the AI path (threat-aware) brings it to the range
		}
		circuit->GetThreatMap()->SetThreatType(unit);
		if (circuit->GetThreatMap()->GetThreatAt(GetPosition()) >= THREAT_MIN) {
			return false;  // the last leg is not safe to walk blind
		}
		// Our own approach point, not the engine's: a free, walkable point on
		// the range circle. The command follows when the walk ends.
		if (Approach(unit)) {
			return true;
		}
	}
	ITravelAction* travelAct = unit->GetTravelAct();
	if ((travelAct != nullptr) && !travelAct->IsFinished()) {
		travelAct->StateFinish();  // no more waypoints; the engine walks into range
	}
	if (!Execute(unit)) {
		return false;  // no site, fallback or abort: the unit is no longer ours to path
	}
	engaged.insert(unit);
	return true;
}

bool IBuilderTask::Reevaluate(CCircuitUnit* unit)
{
	CCircuitAI* circuit = manager->GetCircuit();

	// FIXME: Replace const 1000.0f with build time?
	CEconomyManager* ecoMgr = circuit->GetEconomyManager();
	// D-066: the experimental sequence owns its orders; native's income-drop
	// abort (a >1000-metal build dropped when average income falls under 60 %
	// of what it was at order time) fired right after TECH's opening and
	// threw the commander off its lab, which the sequence then re-ordered.
	if (!IsExperimental() && canAutoAbort
		&& (target == nullptr)
		&& (cost.metal > 1000.f)
		&& (((ecoMgr->GetAvgMetalIncome() < savedIncome.metal * 0.6f) && (ecoMgr->GetAvgMetalIncome() * 2.0f < ecoMgr->GetMetalPull()))
			|| ((ecoMgr->GetAvgEnergyIncome() < savedIncome.energy * 0.6f) && (ecoMgr->GetAvgEnergyIncome() * 2.0f < ecoMgr->GetEnergyPull())))
		)
	{
		manager->AbortTask(this);
		return false;
	}

	/*
	 * Reassign task if required
	 */
	const int frame = circuit->GetLastFrame();
	CCircuitDef* cdef = unit->GetCircuitDef();
	const AIFloat3& pos = unit->GetPos(frame);
	const float buildRangeExt = IsExperimental()
			? EngageRange(unit)
			: cdef->GetBuildDistance() + circuit->GetPathfinder()->GetSquareSize();
	if (geom::is_in_range(pos, GetPosition(), buildRangeExt)
		&& (circuit->GetInflMap()->GetInfluenceAt(pos) > -INFL_EPS))
	{
//		if (unit->GetCircuitDef()->IsRoleComm()) {  // FIXME: or any other builder-attacker
//			if (circuit->GetInflMap()->GetEnemyInflAt(circuit->GetSetupManager()->GetBasePos()) < INFL_EPS) {
//				return true;
//			}
//		} else {
//			return true;
//		}

		// NOTE: helps with obstructed factory, but not with blocked building plan.
		//       @see CTerrainManager::CheckObstruct and its issues.
		if ((cdef->GetMobileId() >= 0) && circuit->GetTerrainManager()->IsObstruct(pos)) {
			if ((unit->GetTaskFrame() + FRAMES_PER_SEC * 5 < frame) && (unit->GetUnit()->GetVel().SqLength2D() < 1e-3f)) {
				unit->SetTaskFrame(frame);  // re-use taskFrame
				TRY_UNIT(circuit, unit,
					AIFloat3 awayPos = geom::get_radial_pos(pos, 64.f);
					CTerrainManager::CorrectPosition(awayPos);
					unit->CmdMoveTo(awayPos, UNIT_CMD_OPTION, frame + FRAMES_PER_SEC * 60);
				)
			}
			return true;
		}

		if ((buildType != BuildType::GUARD)
			&& ((executors.size() < 2) || !unit->IsAttrBase()))
		{
			if (cdef->IsRoleComm()) {
				return true;
			}
			bool prio = true;
			switch (buildType) {
				case BuildType::ENERGY:
				case BuildType::GEO:
					prio = ecoMgr->IsEnergyStalling() || !ecoMgr->IsMetalEmpty();
					break;
				case BuildType::CONVERT:
				case BuildType::MEX:
				case BuildType::MEXUP:
					prio = !ecoMgr->IsEnergyStalling() || ecoMgr->IsMetalEmpty();
					break;
				default: break;
			}
			TRY_UNIT(circuit, unit,
				unit->CmdBARPriority(prio ? 1.f : 0.f);
				// D-070: not in the experimental system. The wait made the builder
				// idle, each idle counted as a build failure, and the third threw
				// the builder off its order (played: the first lab and the opening
				// solars took minutes whenever energy was empty). The sequence
				// manages energy itself; a slow build beats an abandoned one.
				if (!IsExperimental() && ((unit->GetTravelAct() == nullptr) || unit->GetTravelAct()->IsFinished())) {
					unit->CmdWait(ecoMgr->IsEnergyEmpty() && (buildType != BuildType::ENERGY) && (buildType != BuildType::GEO)
							&& (buildType != BuildType::STORE) && (buildType != BuildType::RECLAIM));
				}
			)
			return true;
		}
	} else {
		// Remove wait if unit was pushed away from build position
		TRY_UNIT(circuit, unit,
			unit->CmdWait(false);
		)
	}
	if (unit->IsAttrNoDisrupt()) {
		return true;
	}
	HideAssignee(unit);
	IUnitTask* task = manager->MakeTask(unit);
	// D-114 crash (owner's game, build94, F43291): MakeTask runs the script's
	// policy for this unit, and a rule can drop THIS task (land.recall aborts a
	// forward job). The unit is then no longer ours; carrying on used its cleared
	// travel action in Approach. The unit stays with the idle task, which assigns
	// it on a later update: assigning it here started the new task at once, whose
	// own re-evaluation dropped it again, recursing until the stack overflowed
	// (build96 playtest, F73809, 6066 recalls in one frame).
	if (IsDead() || (units.find(unit) == units.end())) {
		ShowAssignee(unit);  // RemoveAssignee hid it again: one Hide stands, as for any unit that left
		manager->DiscardUnusedTask(task);
		return false;
	}
	ShowAssignee(unit);
	if ((task != nullptr)
		&& ((task->GetType() != IUnitTask::Type::BUILDER)
			|| (static_cast<IBuilderTask*>(task)->GetBuildType() != buildType)))
	{
		manager->AssignTask(unit, task);
		return false;
	}
	// Same kind of work as the current task: keep the current one. The task
	// just made for this re-evaluation is not used by anyone.
	manager->DiscardUnusedTask(task);
	return true;
}

void IBuilderTask::UpdatePath(CCircuitUnit* unit)
{
	CCircuitAI* circuit = manager->GetCircuit();
	// TODO: Check IsForceUpdate, shield charge and retreat

	CCircuitDef* cdef = unit->GetCircuitDef();
	const float range = IsExperimental() ? EngageRange(unit) : cdef->GetBuildDistance();  // D-064: the goal is the range circle
	const AIFloat3& endPos = GetPosition();
	if (canAutoAbort && (target == nullptr)
		&& !circuit->GetTerrainManager()->CanReachAtSafe(unit, endPos, range, cdef->GetPower()))
	{
		manager->AbortTask(this);
		return;
	}

	const AIFloat3& startPos = unit->GetPos(circuit->GetLastFrame());
	const AIFloat3& basePos = circuit->GetSetupManager()->GetBasePos();
	const float baseDefRange = circuit->GetMilitaryManager()->GetBaseDefRange();

	if (geom::is_in_range(startPos, endPos, range)
		|| (geom::is_in_range(basePos, startPos, baseDefRange)
			&& (geom::is_in_range(basePos, endPos, baseDefRange))))
	{
		if (unit->GetTravelAct() != nullptr) {
			unit->GetTravelAct()->StateFinish();
		}
		return;
	}

	if (!IsQueryReady(unit)) {
		return;
	}

	CPathFinder* pathfinder = circuit->GetPathfinder();
	std::shared_ptr<IPathQuery> query = pathfinder->CreatePathSingleQuery(
			unit, circuit->GetThreatMap(),
			startPos, endPos, range, nullptr, cdef->GetPower() * 0.1f);
	pathQueries[unit] = query;

	pathfinder->RunQuery(circuit->GetScheduler().get(), query, [this](const IPathQuery* query) {
		this->ApplyPath(static_cast<const CQueryPathSingle*>(query));
	});
}

void IBuilderTask::ApplyPath(const CQueryPathSingle* query)
{
	const std::shared_ptr<CPathInfo>& pPath = query->GetPathInfo();
	CCircuitUnit* unit = query->GetUnit();

	ITravelAction* travelAct = unit->GetTravelAct();
	if (travelAct == nullptr) {
		return;  // it left the task (or lost its actions) while the path was computed
	}
	if (pPath->path.size() > 2) {
		travelAct->SetPath(pPath);
	} else {
		travelAct->StateFinish();
	}
}

void IBuilderTask::HideAssignee(CCircuitUnit* unit)
{
	CEconomyManager* economyMgr = manager->GetCircuit()->GetEconomyManager();
	if (buildDef == nullptr) {
		const float buildSpeed = unit->GetBuildSpeed();
		buildPower.metal -= buildSpeed;
		buildPower.energy -= buildSpeed * economyMgr->GetEcoEM();
	} else {
		const float buildTime = buildDef->GetBuildTime() / unit->GetWorkerTime();
		const float metalRequire = buildDef->GetCostM() / buildTime;
		const float energyRequire = buildDef->GetCostE() / buildTime;
		buildPower.metal -= metalRequire;
		buildPower.energy -= energyRequire;
		if (!economyMgr->IsIgnorePull(this)) {
			manager->DelMetalPull(metalRequire);
		}
	}
}

void IBuilderTask::ShowAssignee(CCircuitUnit* unit)
{
	CEconomyManager* economyMgr = manager->GetCircuit()->GetEconomyManager();
	if (buildDef == nullptr) {
		const float buildSpeed = unit->GetBuildSpeed();
		buildPower.metal += buildSpeed;
		buildPower.energy += buildSpeed * economyMgr->GetEcoEM();
	} else {
		const float buildTime = buildDef->GetBuildTime() / unit->GetWorkerTime();
		const float metalRequire = buildDef->GetCostM() / buildTime;
		const float energyRequire = buildDef->GetCostE() / buildTime;
		buildPower.metal += metalRequire;
		buildPower.energy += energyRequire;
		if (!economyMgr->IsIgnorePull(this)) {
			manager->AddMetalPull(metalRequire);
		}
	}
}

CAllyUnit* IBuilderTask::FindSameAlly(CCircuitUnit* builder, const std::vector<Unit*>& friendlies)
{
	CCircuitAI* circuit = manager->GetCircuit();
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	const int frame = circuit->GetLastFrame();

	for (Unit* au : friendlies) {
		CAllyUnit* alu = circuit->GetFriendlyUnit(au);
		if (alu == nullptr) {
			continue;
		}
		if ((*alu->GetCircuitDef() == *buildDef) && au->IsBeingBuilt()) {
			const AIFloat3& pos = alu->GetPos(frame);
			if (terrainMgr->CanReachAtSafe(builder, pos, builder->GetCircuitDef()->GetBuildDistance())) {
				return alu;
			}
		}
	}
	return nullptr;
}

void IBuilderTask::FindBuildSite(CCircuitUnit* builder, const AIFloat3& pos, float searchRadius)
{
	FindFacing(pos);

	CTerrainManager* terrainMgr = manager->GetCircuit()->GetTerrainManager();
	CTerrainManager::TerrainPredicate predicate = [this, terrainMgr, builder](const AIFloat3& p) {
		return manager->GetCircuit()->GetBuilderManager()->IsBuildPositionAllowed(buildDef, p)
            && terrainMgr->CanReachAtSafe(builder, p, builder->GetCircuitDef()->GetBuildDistance());
	};
	if (reservationId >= 0) {
		// A retry: the slot served before is handed back before another search,
		// else it stays consumed with no structure on it (CR-010).
		SetBuildPos(-RgtVector);
		terrainMgr->RestoreReservation(reservationId);
		reservationId = -1;
	}
	if (pinRequired && (pinnedReservation < 0)) {
		pinFailed = true;
		SetBuildPos(-RgtVector);
		return;
	}
	terrainMgr->BeginReservedSearch(pinnedReservation, pinRequired);
	const AIFloat3 bp = terrainMgr->FindBuildSite(buildDef, pos, searchRadius, facing, predicate);
	TakeReservation(terrainMgr);
	pinFailed = pinRequired && (reservationId < 0);
	SetBuildPos(bp);
}

bool IBuilderTask::PinReservation(int id)
{
	CTerrainManager* terrainMgr = manager->GetCircuit()->GetTerrainManager();
	// Positional mex construction marks its footprint in the constructor. A
	// field module transfers that footprint back to its persistent slot before
	// claiming it; otherwise FindReservedSite drops our own slot as ground taken.
	if (buildType == BuildType::MEX && target == nullptr
		&& manager->GetCircuit()->GetEconomyManager()->IsMetalMap()
		&& terrainMgr->GetReservationState(id) == 0 && geom::is_valid(buildPos)
		&& buildPos.SqDistance2D(terrainMgr->GetReservationPos(id)) < 1.f) {
		SetBuildPos(-RgtVector);
		terrainMgr->RestoreReservation(id);
	}
	pinRequired = true;
	layoutOwned = true;
	// Factory activation may already have claimed a default site before the
	// script pins its chosen site. Preserve ownership on failure; release the
	// previous claim on successful replacement, and accept re-pinning our own ID.
	pinFailed = !reservation::ReplaceClaim(pinnedReservation, id,
		[terrainMgr](int slot) { return terrainMgr->ClaimReservation(slot); },
		[terrainMgr](int slot) { terrainMgr->UnclaimReservation(slot); });
	return !pinFailed;
}

void IBuilderTask::TakeReservation(CTerrainManager* terrainMgr)
{
	const int rid = terrainMgr->TakeReservedId();
	if (rid < 0) {
		return;
	}
	reservationId = rid;
	layoutOwned = true;
	const int rf = terrainMgr->TakeReservedFacing();
	if (rf >= 0) {
		facing = rf;  // the plan's facing, not the map-edge default
	}
}

void IBuilderTask::FindFacing(const springai::AIFloat3& pos)
{
	CTerrainManager* terrainMgr = manager->GetCircuit()->GetTerrainManager();

//	facing = UNIT_NO_FACING;
	float terWidth = terrainMgr->GetTerrainWidth();
	float terHeight = terrainMgr->GetTerrainHeight();
	if (std::fabs(terWidth - 2 * pos.x) > std::fabs(terHeight - 2 * pos.z)) {
		facing = (2 * pos.x > terWidth) ? UNIT_FACING_WEST : UNIT_FACING_EAST;
	} else {
		facing = (2 * pos.z > terHeight) ? UNIT_FACING_NORTH : UNIT_FACING_SOUTH;
	}
}

void IBuilderTask::ExecuteChain(SBuildChain* chain)
{
	assert(chain != nullptr);
	CCircuitAI* circuit = manager->GetCircuit();

	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	if (terrainMgr->IsZoneAlly(buildPos)) {  // ally mex upgrade or energy base collides with ally
		return;
	}

	if (chain->energy > 0.f && !circuit->GetBuilderManager()->SuppressEconomyChain(BuildType::ENERGY)) {
		float energyMake;
		CCircuitDef* energyDef = circuit->GetEconomyManager()->GetLowEnergy(buildPos, energyMake);
		if (energyDef != nullptr) {
			bool isValid = (circuit->GetEconomyManager()->GetAvgEnergyIncome() < chain->energy);
			if (isValid && chain->isMexEngy) {
				int index = circuit->GetMetalManager()->FindNearestSpot(buildPos);
				isValid = (index >= 0) && (circuit->GetMetalManager()->GetSpots()[index].income * buildDef->GetExtractsM() > energyMake * 0.8f);
			}
			if (isValid) {
				circuit->GetBuilderManager()->Enqueue(TaskB::Common(IBuilderTask::BuildType::ENERGY,
						IBuilderTask::Priority::NORMAL, energyDef, buildPos, SQUARE_SIZE * 8.0f, true));
			}
		}
	}

	if (chain->isPylon) {
		bool foundPylon = false;
		CEconomyManager* economyMgr = circuit->GetEconomyManager();
		CCircuitDef* pylonDef = economyMgr->GetPylonDef();
		if (pylonDef->IsAvailable(circuit->GetLastFrame())) {
			float ourRange = economyMgr->GetEnergyGrid()->GetPylonRange(buildDef->GetId());
			float pylonRange = economyMgr->GetPylonRange();
			float radius = pylonRange + ourRange;
			const int frame = circuit->GetLastFrame();
			circuit->UpdateFriendlyUnits();
			auto& units = circuit->GetCallback()->GetFriendlyUnitsIn(buildPos, radius);
			for (Unit* u : units) {
				CAllyUnit* p = circuit->GetFriendlyUnit(u);
				if (p == nullptr) {
					continue;
				}
				// NOTE: Is SqDistance2D necessary? Or must subtract model radius of pylon from "radius" variable
				//        @see rts/Sim/Misc/QaudField.cpp
				//        ...CQuadField::GetUnitsExact(const float3& pos, float radius, bool spherical)
				//        const float totRad = radius + u->radius; -- suspicious
				if ((*p->GetCircuitDef() == *pylonDef) && (geom::is_in_range(buildPos, p->GetPos(frame), radius))) {
					foundPylon = true;
					break;
				}
			}
			utils::free(units);
			if (!foundPylon) {
				AIFloat3 pos = buildPos;
				CMetalManager* metalMgr = circuit->GetMetalManager();
				int index = metalMgr->FindNearestCluster(pos);
				if (index >= 0) {
					const AIFloat3& clPos = metalMgr->GetClusters()[index].position;
					AIFloat3 dir = clPos - pos;
					float dist = ourRange /*+ pylonRange*/ + pylonRange * 1.8f;
					if (dir.SqLength2D() < dist * dist) {
						pos = (pos /*+ dir.Normalize2D() * (ourRange - pylonRange)*/ + clPos) * 0.5f;
					} else {
						pos += dir.Normalize2D() * (ourRange + pylonRange) * 0.9f;
					}
				}
				circuit->GetBuilderManager()->Enqueue(TaskB::Pylon(IBuilderTask::Priority::HIGH, pylonDef, pos, nullptr, 1.0f));
			}
		}
	}

	if (chain->isPorc) {
		circuit->GetMilitaryManager()->MakeDefence(buildPos);
	}

	if (chain->isTerra) {
		if (circuit->GetEconomyManager()->GetAvgMetalIncome() > 10) {
			circuit->GetBuilderManager()->Enqueue(TaskB::Terraform(IBuilderTask::Priority::HIGH, target));
		}
	}

	if (!chain->hub.empty()) {
		// TODO: Implement BuildWait action - semaphore for group of tasks / task's queue
		// FIXME: Using builder's def because MaxSlope is not provided by engine's interface for buildings!
		//        and CTerrainManager::CanBuildAt returns false in many cases
		CCircuitDef* bdef = units.empty() ? circuit->GetSetupManager()->GetCommChoice() : (*this->units.begin())->GetCircuitDef();
		CBuilderManager* builderMgr = circuit->GetBuilderManager();
		CEnemyManager* enemyMgr = circuit->GetEnemyManager();

		for (auto& queue : chain->hub) {
			IBuilderTask* parent = nullptr;

			for (const SBuildInfo& bi : queue) {
				// The script-owned layout cannot adopt unreserved economy orders.
				// Do not publish an infinite-timeout hub child which will count as
				// an in-flight prerequisite forever. Defence/other chains and all
				// roles without the recovery/layout opt-in retain their old policy.
				if (builderMgr->SuppressEconomyChain(bi.buildType)) continue;
				if (!bi.cdef->IsAvailable(circuit->GetLastFrame())
					|| !terrainMgr->GetImmobileTypeById(bi.cdef->GetImmobileId())->typeUsable)
				{
					continue;
				}
				bool isValid = true;
				switch (bi.condition) {
					case SBuildInfo::Condition::AIR: {
						isValid = bi.cdef->GetCostM() < enemyMgr->GetEnemyCost(ROLE_TYPE(AIR));
						if (bi.value < 0.f) {  // -1.f == false
							isValid = !isValid;
						}
					} break;
					case SBuildInfo::Condition::ENERGY: {
						CEconomyManager* ecoMgr = circuit->GetEconomyManager();
						// isValid = !ecoMgr->IsEnergyStalling() && (ecoMgr->GetAvgEnergyIncome() > ecoMgr->GetEnergyPull() + bi.cdef->GetUpkeepE());
						isValid = !ecoMgr->IsEnergyStalling() && ecoMgr->IsEnergyFull();
						if (bi.value < 0.f) {  // -1.f == false
							isValid = !isValid;
						}
					} break;
					case SBuildInfo::Condition::WIND: {
						CEconomyManager* ecoMgr = circuit->GetEconomyManager();
						isValid = ecoMgr->IsEnergyStalling() || (ecoMgr->GetAvgEnergyIncome() < ecoMgr->GetEnergyPull() + bi.cdef->GetUpkeepE());
						float avgWind = (circuit->GetMap()->GetMaxWind() + circuit->GetMap()->GetMinWind()) * 0.5f;
						isValid = isValid && (avgWind >= bi.value);
					} break;
					case SBuildInfo::Condition::M_INC_GR: {
						isValid = circuit->GetEconomyManager()->GetAvgMetalIncome() > bi.value;
					} break;
					case SBuildInfo::Condition::M_INC_LS: {
						isValid = circuit->GetEconomyManager()->GetAvgMetalIncome() < bi.value;
					} break;
					case SBuildInfo::Condition::SENSOR: {
						std::function<bool (CCircuitDef*)> isSensor;
						if (bi.cdef->IsRadar()) {
							isSensor = [](CCircuitDef* cdef) { return cdef->IsRadar(); };
						} else if (bi.cdef->IsSonar()) {
							isSensor = [](CCircuitDef* cdef) { return cdef->IsSonar(); };
						} else {
							isValid = false;
							break;
						}
						COOAICallback* clb = circuit->GetCallback();
						const auto& friendlies = clb->GetFriendlyUnitIdsIn(buildPos, bi.value);
						for (int auId : friendlies) {
							CCircuitDef::Id defId = clb->Unit_GetDefId(auId);
							if (isSensor(circuit->GetCircuitDef(defId))) {
								isValid = false;
								break;
							}
						}
					} break;
					case SBuildInfo::Condition::CHANCE: {
						isValid = rand() < bi.value * RAND_MAX;
					} break;
					case SBuildInfo::Condition::ALWAYS:
					default: break;
				}
				if (!isValid) {
					continue;
				}

				AIFloat3 offset = bi.offset;
				if (bi.direction != SBuildInfo::Direction::NONE) {
					switch (facing) {
						default:
						case UNIT_FACING_SOUTH:
							break;
						case UNIT_FACING_EAST:
							offset = AIFloat3(offset.z, 0.f, -offset.x);
							break;
						case UNIT_FACING_NORTH:
							offset = AIFloat3(-offset.x, 0.f, -offset.z);
							break;
						case UNIT_FACING_WEST:
							offset = AIFloat3(-offset.z, 0.f, offset.x);
							break;
					}
				}
				AIFloat3 pos = buildPos + offset;
				CTerrainManager::CorrectPosition(pos);
				pos = terrainMgr->GetBuildPosition(bdef, pos);

				IBuilderTask* task = builderMgr->Enqueue(TaskB::Common(bi.buildType, bi.priority, bi.cdef, pos, 0.f, parent == nullptr, 0));
				if (parent == nullptr) {
					parent = task;
				} else {
					parent->SetNextTask(task);
					parent = parent->GetNextTask();
				}

				if (IBuilderTask::BuildType::DEFENCE == bi.buildType) {
					circuit->GetMilitaryManager()->ProcessHubDefence(static_cast<CBDefenceTask*>(task));
				}
			}
		}
	}
}

#define SERIALIZE(stream, func)	\
	utils::binary_##func(stream, positionF3);			\
	utils::binary_##func(stream, shake);				\
	utils::binary_##func(stream, bdefId);				\
	utils::binary_##func(stream, canAutoAbort);			\
	utils::binary_##func(stream, cost.metal);			\
	utils::binary_##func(stream, cost.energy);			\
	utils::binary_##func(stream, targetId);				\
	utils::binary_##func(stream, buildPosF3);			\
	utils::binary_##func(stream, facing);				\
	utils::binary_##func(stream, savedIncome.metal);	\
	utils::binary_##func(stream, savedIncome.energy);	\
	utils::binary_##func(stream, buildFails);			\
	utils::binary_##func(stream, reservationId);		\
	utils::binary_##func(stream, pinnedReservation);	\
	utils::binary_##func(stream, pinRequired);			\
	utils::binary_##func(stream, pinFailed);			\
	utils::binary_##func(stream, layoutOwned);

bool IBuilderTask::Load(std::istream& is)
{
	CCircuitDef::Id bdefId;
	CCircuitUnit::Id targetId;
	float positionF3[3];
	float buildPosF3[3];

	IUnitTask::Load(is);
	SERIALIZE(is, read)

	CCircuitAI* circuit = manager->GetCircuit();
	buildDef = circuit->GetCircuitDefSafe(bdefId);
	target = circuit->GetTeamUnit(targetId);
	position = AIFloat3(positionF3);
	buildPos = AIFloat3(buildPosF3);

	if ((target == nullptr) && (buildDef != nullptr) && geom::is_valid(buildPos)) {
		circuit->GetTerrainManager()->AddBlocker(buildDef, buildPos, facing);
	}
	if ((target != nullptr) && (buildType != BuildType::REPAIR) && (buildType != BuildType::RECLAIM)) {
		circuit->GetBuilderManager()->MarkUnfinishedUnit(target, this);
	}
#ifdef DEBUG_SAVELOAD
	manager->GetCircuit()->LOG("%s | position=%f,%f,%f | shake=%f | bdefId=%i | costM=%f | costE=%f | targetId=%i | buildPos=%f,%f,%f | facing=%i | savedIncomeM=%f | savedIncomeE=%f | buildFails=%i | buildDef=%p | target=%p",
			__PRETTY_FUNCTION__, position.x, position.y, position.z, shake, bdefId, cost.metal, cost.energy, targetId, buildPos.x, buildPos.y, buildPos.z, facing, savedIncome.metal, savedIncome.energy, buildFails, buildDef, target);
#endif
	return true;
}

void IBuilderTask::Save(std::ostream& os) const
{
	CCircuitDef::Id bdefId = (buildDef != nullptr) ? buildDef->GetId() : -1;
	CCircuitUnit::Id targetId = (target != nullptr) ? target->GetId() : -1;
	float positionF3[3];
	float buildPosF3[3];
	position.LoadInto(positionF3);
	buildPos.LoadInto(buildPosF3);

	IUnitTask::Save(os);
	SERIALIZE(os, write)
#ifdef DEBUG_SAVELOAD
	manager->GetCircuit()->LOG("%s | positionF3=%f,%f,%f | shake=%f | bdefId=%i | costM=%f | costE=%f | targetId=%i | buildPosF3=%f,%f,%f | facing=%i | savedIncomeM=%f | savedIncomeE=%f | buildFails=%i",
			__PRETTY_FUNCTION__, positionF3[0], positionF3[1], positionF3[2], shake, bdefId, cost.metal, cost.energy, targetId, buildPosF3[0], buildPosF3[1], buildPosF3[2], facing, savedIncome.metal, savedIncome.energy, buildFails);
#endif
}

#ifdef DEBUG_VIS
void IBuilderTask::Log()
{
	IUnitTask::Log();
	CCircuitAI* circuit = manager->GetCircuit();
	circuit->LOG("buildType: %i", buildType);
	circuit->GetDrawer()->AddPoint(GetPosition(), (buildDef != nullptr) ? buildDef->GetDef()->GetName() : "task");
}
#endif

} // namespace circuit
