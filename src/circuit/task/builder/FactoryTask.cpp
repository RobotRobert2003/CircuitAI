/*
 * FactoryTask.cpp
 *
 *  Created on: Jan 30, 2015
 *      Author: rlcevg
 */

#include "task/builder/FactoryTask.h"
#include "module/BuilderManager.h"
#include "module/FactoryManager.h"
#include "scheduler/Scheduler.h"
#include "terrain/TerrainManager.h"
#include "CircuitAI.h"
#include "util/Utils.h"

#include "spring/SpringMap.h"

#include "AISCommands.h"
#include "map/ThreatMap.h"
#include "Log.h"

namespace circuit {

using namespace springai;

static int opposite[] = {
	UNIT_FACING_NORTH,
	UNIT_FACING_WEST,
	UNIT_FACING_SOUTH,
	UNIT_FACING_EAST
};

CBFactoryTask::CBFactoryTask(ITaskModule* mgr, Priority priority,
							 CCircuitDef* buildDef, CCircuitDef* reprDef, const AIFloat3& position,
							 SResource cost, float shake, bool isPlop, int timeout)
		: IBuilderTask(mgr, priority, buildDef, position, Type::BUILDER, BuildType::FACTORY, cost, shake, timeout)
		, reprDef(reprDef)
		, isPlop(isPlop)
{
	manager->GetCircuit()->GetFactoryManager()->AddFactory(buildDef);
}

CBFactoryTask::CBFactoryTask(ITaskModule* mgr)
		: IBuilderTask(mgr, Type::BUILDER, BuildType::FACTORY)
		, reprDef(nullptr)
		, isPlop(false)
{
}

CBFactoryTask::~CBFactoryTask()
{
}

void CBFactoryTask::Start(CCircuitUnit* unit)
{
	if (isPlop) {
		Execute(unit);
	} else {
		IBuilderTask::Start(unit);
	}
}

void CBFactoryTask::Update()
{
	if (!isPlop) {
		IBuilderTask::Update();
	}
}

void CBFactoryTask::Cancel()
{
	IBuilderTask::Cancel();

	if (target == nullptr) {
		manager->GetCircuit()->GetFactoryManager()->DelFactory(buildDef);
	}
}

void CBFactoryTask::Activate()
{
	CCircuitAI* circuit = manager->GetCircuit();
	CFactoryManager* factoryMgr = circuit->GetFactoryManager();
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	const bool isProductionFactory = factoryMgr->GetFactoryDef(buildDef) != nullptr;
	if (!IsLayoutOwned() && terrainMgr->IsLayoutEnabled() && isProductionFactory && buildDef->IsLander()) {
		const int reservation = terrainMgr->AcquireFactoryReservation(buildDef);
		if ((reservation < 0) || !PinReservation(reservation)) {
			RequireReservation();
		}
	}
	factoryMgr->ApplySwitchFrame();
	IBuilderTask::Activate();
}

void CBFactoryTask::FindBuildSite(CCircuitUnit* builder, const AIFloat3& pos, float searchRadius)
{
	CCircuitAI* circuit = manager->GetCircuit();
	CMap* map = circuit->GetMap();
	CTerrainManager* terrainMgr = circuit->GetTerrainManager();
	// A served slot is kept across retries (D-055): the fixed-facing return
	// below used to move a lab back to the shaken anchor on a second Execute.
	if ((reservationId >= 0) && geom::is_valid(buildPos) && map->IsPossibleToBuildAt(buildDef->GetDef(), buildPos, facing)) {
		return;
	}
	// D-104 (owner's rule): every factory, whoever ordered it, stands flush
	// against the construction turrets once one stands; an order that already
	// has its layout slot (pinned) keeps it
	if (preferredFacing < 0 && terrainMgr->IsLayoutEnabled() && !pinRequired && (pinnedReservation < 0) && (reservationId < 0)) {
		const int flushId = terrainMgr->PackFactoryFlush(buildDef, pos);
		if ((flushId >= 0) && !PinReservation(flushId)) {
			terrainMgr->ReleaseReservation(flushId);
			pinRequired = false;
			pinnedReservation = -1;
			pinFailed = false;
		}
	}
	// While a slot for this def is planned, the search runs so it is served.
	const bool planned = terrainMgr->IsLayoutEnabled() && (terrainMgr->GetReservationCount(buildDef) > 0);
	if (preferredFacing < 0 && !pinRequired && !planned && (facing != UNIT_NO_FACING) && map->IsPossibleToBuildAt(buildDef->GetDef(), pos, facing)) {
		SetBuildPos(pos);
		return;
	}
	if (reservationId >= 0) {
		// The served slot is no longer possible: hand it back before searching
		// again, else it stays consumed with no structure on it (CR-010).
		SetBuildPos(-RgtVector);
		terrainMgr->RestoreReservation(reservationId);
		reservationId = -1;
	}

	if (preferredFacing >= 0) facing = preferredFacing;
	else FindFacing(pos);

	CTerrainManager::TerrainPredicate predicate;
	if (reprDef == nullptr) {
		predicate = [terrainMgr, builder](const AIFloat3& p) {
			return terrainMgr->CanReachAtSafe(builder, p, builder->GetCircuitDef()->GetBuildDistance());
		};
	} else {
		CCircuitDef* reprDef = this->reprDef;
		predicate = [terrainMgr, builder, reprDef](const AIFloat3& p) {
			return terrainMgr->CanReachAtSafe(builder, p, builder->GetCircuitDef()->GetBuildDistance())
					&& terrainMgr->CanBeBuiltAt(reprDef, p);
		};
	}
	const float testSize = std::max(buildDef->GetDef()->GetXSize(), buildDef->GetDef()->GetZSize()) * SQUARE_SIZE;
	int rejectedAccess = 0, rejectedExit = 0;
	auto checkFacing = [this, map, terrainMgr, testSize, &predicate, &pos, searchRadius, &rejectedAccess, &rejectedExit]() {
		if (pinRequired && (pinnedReservation < 0)) {
			pinFailed = true;
			return false;
		}
		// Only this opt-in opening search filters unpinned reservations by
		// facing. Otherwise a west-facing berth could be accepted during the
		// south-facing pass, with its exit tested in the wrong direction.
		terrainMgr->BeginReservedSearch(pinnedReservation, pinRequired,
            preferredFacing >= 0 && !pinRequired ? facing : -1);
        // For the script-opted-in opening yard, test its exit inside the
        // candidate predicate. Rejecting only the first returned footprint
        // used to switch facing even when a later forward site was usable.
        CTerrainManager::TerrainPredicate sitePredicate = [this, map, testSize, &predicate, &rejectedAccess, &rejectedExit](const AIFloat3& p) {
            if (!predicate(p)) { ++rejectedAccess; return false; }
            if (preferredFacing < 0 || pinRequired) return true;
            AIFloat3 mouth = p;
            switch (facing) {
                case UNIT_FACING_EAST: mouth.x += testSize; break;
                case UNIT_FACING_NORTH: mouth.z -= testSize; break;
                case UNIT_FACING_WEST: mouth.x -= testSize; break;
                default: mouth.z += testSize; break;
            }
            if (!map->IsPossibleToBuildAt(buildDef->GetDef(), mouth, facing)) { ++rejectedExit; return false; }
            return true;
        };
		AIFloat3 bp = terrainMgr->FindBuildSite(buildDef, pos, searchRadius, facing, sitePredicate);
		if (!geom::is_valid(bp)) {
			pinFailed = pinRequired;
			return false;
		}
		TakeReservation(terrainMgr);  // a reserved factory site carries its own facing
		pinFailed = pinRequired && (reservationId < 0);
		if (reservationId >= 0) {
			// A planned slot: its exit cone is planned too. The front test below
			// used to refuse it for a rock in front, and the slot stayed consumed
			// while the lab went to the spiral (D-055).
			SetBuildPos(bp);
			return true;
		}

		// decides if a factory should face the opposite direction due to bad terrain
		AIFloat3 posOffset = bp;
		switch (facing) {
			default:
			case UNIT_FACING_SOUTH: {  // z++
				posOffset.z += testSize;
			} break;
			case UNIT_FACING_EAST: {  // x++
				posOffset.x += testSize;
			} break;
			case UNIT_FACING_NORTH: {  // z--
				posOffset.z -= testSize;
			} break;
			case UNIT_FACING_WEST: {  // x--
				posOffset.x -= testSize;
			} break;
		}
		if (map->IsPossibleToBuildAt(buildDef->GetDef(), posOffset, facing)) {
			SetBuildPos(bp);
			return true;
		}
		return false;
	};

	auto trySites = [this, &checkFacing, &rejectedAccess, &rejectedExit]() {
        if (preferredFacing >= 0) {
            // Script opts in only the first SEA yard. Each facing searches
            // its entire candidate disc before trying the next; opposite last.
            // Existing pinned plans and other roles retain their exact policy.
            for (int offset : {0, 1, 3, 2}) {
                facing = (preferredFacing + offset) % 4;
                if (!checkFacing()) continue;
                manager->GetCircuit()->LOG("SEA_OPENING: preferred=%i actual=%i fallback=%i reason=%s accessRejected=%i exitRejected=%i slot=%i site=(%.0f,%.0f)",
                    preferredFacing, facing, int(facing != preferredFacing),
                    facing == preferredFacing ? "preferred-site-valid" : "earlier-facing-no-reachable-buildable-exit",
                    rejectedAccess, rejectedExit, reservationId, buildPos.x, buildPos.z);
                return true;
            }
            return false;
        }
		if (checkFacing()) {
			return true;
		}
		facing = opposite[facing];
		if (checkFacing()) {
			return true;
		}
		++facing %= 4;
		if (checkFacing()) {
			return true;
		}
		facing = opposite[facing];
		return checkFacing();
	};

	if (trySites() || (reprDef == nullptr)) {
		return;
	}

	// The representer predicate rejects every sector whose terrain area for the
	// factory's units is below CTerrainData's "usable" threshold (16% of the map).
	// That is the right filter for a factory the native chooser picked, because
	// CFactoryData::GetFactoryToBuild applies the same test before choosing. The
	// AngelScript SelectFactoryHandler bypasses that chooser and may deliberately
	// place a lab on a land-locked start - e.g. the TECH start spots on Tundra
	// Continents are small islands where the role techs with a bot lab and leaves
	// with amphibious units. Without this fallback no site is ever accepted, the
	// task is cancelled, and CEconomyManager::UpdateFactoryTasks re-picks the same
	// factory every cycle for the whole game (seen as one "FactoryWeightedSelect
	// chose=leglab" line every 240 frames and no lab ever built).
	// Retry with builder reach only; CTerrainManager::FindBuildSite still enforces
	// the map's own buildability of the footprint.
	circuit->LOG("CBFactoryTask: no site for %s in a usable %s area near (%.0f, %.0f); retrying without the area check",
			buildDef->GetDef()->GetName(), reprDef->GetDef()->GetName(), pos.x, pos.z);
	predicate = [terrainMgr, builder](const AIFloat3& p) {
		return terrainMgr->CanReachAtSafe(builder, p, builder->GetCircuitDef()->GetBuildDistance());
	};
	if (preferredFacing >= 0) facing = preferredFacing;
	else FindFacing(pos);
	if (trySites()) {
		circuit->LOG("CBFactoryTask: fallback site for %s at (%.0f, %.0f) facing %i",
				buildDef->GetDef()->GetName(), buildPos.x, buildPos.z, facing);
		return;
	}
	// Still nothing: report which gate rejects the search origin itself, so a
	// map where e.g. every shipyard site fails can be diagnosed from the log.
	const float buildDist = builder->GetCircuitDef()->GetBuildDistance();
	circuit->LOG("CBFactoryTask: no site for %s at all | origin (%.0f, %.0f) elev %.0f | canBuildHere=%i reach=%i threat=%.1f "
			"enginePossible=%i mobileId=%i immobileId=%i builder=%s radius=%.0f",
			buildDef->GetDef()->GetName(), pos.x, pos.z, map->GetElevationAt(pos.x, pos.z),
			int(terrainMgr->CanBeBuiltAt(buildDef, pos)), int(terrainMgr->CanReachAt(builder, pos, buildDist)),
			circuit->GetThreatMap()->GetBuilderThreatAt(pos), int(map->IsPossibleToBuildAt(buildDef->GetDef(), pos, facing)),
			int(buildDef->GetMobileId()), int(buildDef->GetImmobileId()), builder->GetCircuitDef()->GetDef()->GetName(), searchRadius);
}

#define SERIALIZE(stream, func)	\
	utils::binary_##func(stream, reprDefId);		\
	utils::binary_##func(stream, isPlop);

bool CBFactoryTask::Load(std::istream& is)
{
	CCircuitDef::Id reprDefId;

	IBuilderTask::Load(is);
	SERIALIZE(is, read)

	CCircuitAI* circuit = manager->GetCircuit();
	reprDef = circuit->GetCircuitDefSafe(reprDefId);

	circuit->GetFactoryManager()->AddFactory(buildDef);
	Activate();  // circuit->GetFactoryManager()->ApplySwitchFrame();
#ifdef DEBUG_SAVELOAD
	manager->GetCircuit()->LOG("%s | reprDefId=%i | isPlop=%i | lastTouched=%i", __PRETTY_FUNCTION__, reprDefId, isPlop, lastTouched);
#endif
	return true;
}

void CBFactoryTask::Save(std::ostream& os) const
{
	CCircuitDef::Id reprDefId = (reprDef != nullptr) ? reprDef->GetId() : -1;

	IBuilderTask::Save(os);
	SERIALIZE(os, write)
#ifdef DEBUG_SAVELOAD
	manager->GetCircuit()->LOG("%s | reprDefId=%i | isPlop=%i", __PRETTY_FUNCTION__, reprDefId, isPlop);
#endif
}

} // namespace circuit
