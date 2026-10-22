/*
 * GeoTask.cpp
 *
 *  Created on: Jun 25, 2021
 *      Author: rlcevg
 */

#include "task/builder/GeoTask.h"
#include "module/TaskModule.h"
#include "module/EconomyManager.h"
#include "resource/EnergyManager.h"
#include "terrain/TerrainManager.h"
#include "unit/CircuitUnit.h"
#include "unit/ally/AllyUnit.h"
#include "CircuitAI.h"
#include "util/Utils.h"

#include "spring/SpringCallback.h"
#include "spring/SpringMap.h"

#include "AISCommands.h"

namespace circuit {

using namespace springai;

CBGeoTask::CBGeoTask(ITaskModule* mgr, Priority priority,
					 CCircuitDef* buildDef, int spotId, const AIFloat3& position,
					 SResource cost, int timeout)
		: IBuilderTask(mgr, priority, buildDef, position, Type::BUILDER, BuildType::GEO, cost, 0.f, timeout)
		, spotId(spotId)
{
	SetBuildPos(position);
	manager->GetCircuit()->GetEconomyManager()->SetOpenGeoSpot(spotId, false);
}

CBGeoTask::CBGeoTask(ITaskModule* mgr)
		: IBuilderTask(mgr, Type::BUILDER, BuildType::GEO)
		, spotId(-1)
{
}

CBGeoTask::~CBGeoTask()
{
}

void CBGeoTask::Cancel()
{
	if ((target == nullptr) && geom::is_valid(buildPos)) {
		if (spotId >= 0) {  // for broken Load
			manager->GetCircuit()->GetEconomyManager()->SetOpenGeoSpot(spotId, true);
		}
		IBuilderTask::SetBuildPos(-RgtVector);
	}
}

bool CBGeoTask::Execute(CCircuitUnit* unit)
{
	executors.insert(unit);

	CCircuitAI* circuit = manager->GetCircuit();
	TRY_UNIT(circuit, unit,
		unit->CmdPriority(ClampPriority());
	)

	const int frame = circuit->GetLastFrame();
    // A builder can arrive after another worker created the intended frame.
    // Reuse the normal recovery ownership mechanism rather than issuing a
    // second build over it. Adoption checks the exact requested definition.
    if (target == nullptr) AdoptStandingFrame(unit);
	if (target != nullptr) {
		TRY_UNIT(circuit, unit,
			unit->CmdRepair(target, UNIT_CMD_OPTION, CmdTimeout(frame));
		)
		return true;
	}
    // BAR transfers an upgraded geo to the owner of the geo underneath it.
    // Revalidate on execution, since ownership may change during travel.
    for (int id : circuit->GetCallback()->GetFriendlyUnitIdsIn(buildPos, 32.f, false)) {
        auto* friendly = circuit->GetFriendlyUnit(id);
        if (friendly && friendly->GetCircuitDef()->GetDef()->IsNeedGeo()
            && friendly->GetUnit()->GetTeam() != circuit->GetTeamId()) {
            manager->AbortTask(this);
            return false;
        }
    }
	if (!circuit->GetTerrainManager()->IsAllyLayoutBlocked(buildDef, buildPos, facing)
        && circuit->GetMap()->IsPossibleToBuildAt(buildDef->GetDef(), buildPos, facing)) {
		TRY_UNIT(circuit, unit,
			unit->CmdBuild(buildDef, buildPos, facing, 0, CmdTimeout(frame));
		)
	} else {
		// Fallback to Guard/Assist/Patrol
		manager->FallbackTask(unit);
		return false;
	}
	return true;
}

void CBGeoTask::SetBuildPos(const AIFloat3& pos)
{
	FindFacing(pos);
	IBuilderTask::SetBuildPos(pos);
}

#define SERIALIZE(stream, func)	\
	utils::binary_##func(stream, spotId);

bool CBGeoTask::Load(std::istream& is)
{
	IBuilderTask::Load(is);
	SERIALIZE(is, read)

	CCircuitAI* circuit = manager->GetCircuit();
	// TODO: Instead of IsSpotValid check IsPossibleToBuildAt
	if (circuit->GetEnergyManager()->IsSpotValid(spotId, GetPosition())) {
		spotId = -1;
#ifdef DEBUG_SAVELOAD
		manager->GetCircuit()->LOG("%s | spotId=%i", __PRETTY_FUNCTION__, spotId);
#endif
		return false;
	}
	circuit->GetEconomyManager()->SetOpenGeoSpot(spotId, false);
#ifdef DEBUG_SAVELOAD
	manager->GetCircuit()->LOG("%s | spotId=%i", __PRETTY_FUNCTION__, spotId);
#endif
	return true;
}

void CBGeoTask::Save(std::ostream& os) const
{
	IBuilderTask::Save(os);
	SERIALIZE(os, write)
}

} // namespace circuit
