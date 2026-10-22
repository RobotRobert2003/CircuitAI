/*
 * SpringCallback.cpp
 *
 *  Created on: Nov 8, 2019
 *      Author: rlcevg
 */

#include "spring/SpringCallback.h"
#include "spring/ResurrectionClaim.h"
#include "Sim/Units/CommandAI/Command.h"

#include "util/Defines.h"

#include "SSkirmishAICallback.h"	// "direct" C API
#include "WrappUnit.h"

namespace circuit {

using namespace springai;

int COOAICallback::Unit_Maximum() const { return sAICallback->Unit_getMax(skirmishAIId); }
int COOAICallback::Unit_Team(int unitId) const { return sAICallback->Unit_getTeam(skirmishAIId, unitId); }

bool COOAICallback::Unit_ResurrectionClaim(int unitId, int frame, ResurrectionClaim& claim) const
{
    // Read only the active command, with no generated command wrappers or
    // persistent cache. A human ally can replace a command within this frame.
    if (sAICallback->Unit_getCurrentCommands(skirmishAIId, unitId) <= 0
        || sAICallback->Unit_CurrentCommand_getId(skirmishAIId, unitId, 0) != CMD_RESURRECT
        || sAICallback->Unit_CurrentCommand_getTimeOut(skirmishAIId, unitId, 0) < frame) return false;
    float parameters[5];
    const int count = sAICallback->Unit_CurrentCommand_getParams(skirmishAIId, unitId, 0, parameters, 5);
    return claim.Decode(parameters, count, sAICallback->Unit_getMax(skirmishAIId));
}

COOAICallback::COOAICallback(OOAICallback* clb)
		: sAICallback(nullptr)
		, callback(clb)
		, skirmishAIId(callback->GetSkirmishAIId())
{
	unitIds.resize(MAX_UNITS);
	units.resize(MAX_UNITS);
}

COOAICallback::~COOAICallback()
{
}

void COOAICallback::Init(const struct SSkirmishAICallback* clb)
{
	sAICallback = clb;
}

int COOAICallback::GetEnemyTeamSize() const
{
	return sAICallback->getEnemyTeams(skirmishAIId, nullptr, -1) - 1;  // -1 for Gaia team :(
}

const std::vector<Unit*>& COOAICallback::GetFriendlyUnits()
{
	unitIds.resize(MAX_UNITS);
	int size = sAICallback->getFriendlyUnits(skirmishAIId, unitIds.data(), MAX_UNITS);

	units.resize(size);
	for (int i = 0; i < size; ++i) {
		units[i] = WrappUnit::GetInstance(skirmishAIId, unitIds[i]);
	}

	return units;
}

const std::vector<Unit*>& COOAICallback::GetFriendlyUnitsIn(const AIFloat3& pos, float radius, bool spherical)
{
	float pos_posF3[3];
	pos.LoadInto(pos_posF3);
	unitIds.resize(MAX_UNITS);
	int size = sAICallback->getFriendlyUnitsIn(skirmishAIId, pos_posF3, radius, spherical, unitIds.data(), MAX_UNITS);

	units.resize(size);
	for (int i = 0; i < size; ++i) {
		units[i] = WrappUnit::GetInstance(skirmishAIId, unitIds[i]);
	}

	return units;
}

bool COOAICallback::IsFriendlyUnitsIn(const AIFloat3& pos, float radius, bool spherical) const
{
	float pos_posF3[3];
	pos.LoadInto(pos_posF3);
	int size = sAICallback->getFriendlyUnitsIn(skirmishAIId, pos_posF3, radius, spherical, nullptr, -1);
	return size > 0;
}

const std::vector<int>& COOAICallback::GetFriendlyUnitIdsIn(const springai::AIFloat3& pos, float radius, bool spherical)
{
	float pos_posF3[3];
	pos.LoadInto(pos_posF3);
    const auto result=queriedUnitIds.Read(MAX_UNITS,[&](int* output,int capacity) {
        return sAICallback->getFriendlyUnitsIn(skirmishAIId,pos_posF3,radius,spherical,output,capacity);
    });
    // Preserve this API's shared-vector lifetime and exact engine order.
    // Copy only K local results, rather than zeroing MAX_UNITS every query.
    unitIds.assign(result.begin(),result.end());
	return unitIds;
}

const std::vector<Unit*>& COOAICallback::GetEnemyUnits()
{
	unitIds.resize(MAX_UNITS);
	int size = sAICallback->getEnemyUnits(skirmishAIId, unitIds.data(), MAX_UNITS);

	units.resize(size);
	for (int i = 0; i < size; ++i) {
		units[i] = WrappUnit::GetInstance(skirmishAIId, unitIds[i]);
	}

	return units;
}

const std::vector<Unit*>& COOAICallback::GetEnemyUnitsIn(const AIFloat3& pos, float radius, bool spherical)
{
	float pos_posF3[3];
	pos.LoadInto(pos_posF3);
	unitIds.resize(MAX_UNITS);
	int size = sAICallback->getEnemyUnitsIn(skirmishAIId, pos_posF3, radius, spherical, unitIds.data(), MAX_UNITS);

	units.resize(size);
	for (int i = 0; i < size; ++i) {
		units[i] = WrappUnit::GetInstance(skirmishAIId, unitIds[i]);
	}

	return units;
}

bool COOAICallback::IsEnemyUnitsIn(const AIFloat3& pos, float radius, bool spherical) const
{
	float pos_posF3[3];
	pos.LoadInto(pos_posF3);
	int size = sAICallback->getEnemyUnitsIn(skirmishAIId, pos_posF3, radius, spherical, nullptr, -1);
	return size > 0;
}

const std::vector<int>& COOAICallback::GetEnemyUnitIdsIn(const AIFloat3& pos, float radius, bool spherical)
{
	float pos_posF3[3];
	pos.LoadInto(pos_posF3);
    // Commander observation asks this every three frames. As for friendly
    // local queries, retain the bounded callback buffer and copy only the K
    // results instead of zero-filling MAX_UNITS on every ask. Preserve engine
    // order and this shared-vector lifetime; callback_buffer_test covers the
    // reusable storage contract across empty/full queries and size changes.
    const auto result=queriedUnitIds.Read(MAX_UNITS,[&](int* output,int capacity) {
        return sAICallback->getEnemyUnitsIn(skirmishAIId,pos_posF3,radius,spherical,output,capacity);
    });
    unitIds.assign(result.begin(),result.end());
	return unitIds;
}

const std::vector<Unit*>& COOAICallback::GetNeutralUnits()
{
	unitIds.resize(MAX_UNITS);
	int size = sAICallback->getNeutralUnits(skirmishAIId, unitIds.data(), MAX_UNITS);

	units.resize(size);
	for (int i = 0; i < size; ++i) {
		units[i] = WrappUnit::GetInstance(skirmishAIId, unitIds[i]);
	}

	return units;
}

const std::vector<Unit*>& COOAICallback::GetNeutralUnitsIn(const AIFloat3& pos, float radius, bool spherical)
{
	float pos_posF3[3];
	pos.LoadInto(pos_posF3);
	unitIds.resize(MAX_UNITS);
	int size = sAICallback->getNeutralUnitsIn(skirmishAIId, pos_posF3, radius, spherical, unitIds.data(), MAX_UNITS);

	units.resize(size);
	for (int i = 0; i < size; ++i) {
		units[i] = WrappUnit::GetInstance(skirmishAIId, unitIds[i]);
	}

	return units;
}

bool COOAICallback::IsNeutralUnitsIn(const AIFloat3& pos, float radius, bool spherical) const
{
	float pos_posF3[3];
	pos.LoadInto(pos_posF3);
	int size = sAICallback->getNeutralUnitsIn(skirmishAIId, pos_posF3, radius, spherical, nullptr, -1);
	return size > 0;
}

bool COOAICallback::IsFeatures() const
{
	int size = sAICallback->getFeatures(skirmishAIId, nullptr, -1);
	return size > 0;
}

bool COOAICallback::IsFeaturesIn(const AIFloat3& pos, float radius, bool spherical) const
{
	float pos_posF3[3];
	pos.LoadInto(pos_posF3);
	int size = sAICallback->getFeaturesIn(skirmishAIId, pos_posF3, radius, spherical, nullptr, -1);
	return size > 0;
}

int COOAICallback::Unit_GetDefId(int unitId) const
{
	return sAICallback->Unit_getDef(skirmishAIId, unitId);
}

bool COOAICallback::Unit_HasCommands(int unitId) const
{
	return sAICallback->Unit_getCurrentCommands(skirmishAIId, unitId) > 0;
}

int COOAICallback::Feature_ResurrectDef(int featureId) const
{
	return sAICallback->Feature_getResurrectDef(skirmishAIId, featureId);
}

bool COOAICallback::Feature_IsResurrectable(int featureId) const
{
	return sAICallback->Feature_getResurrectDef(skirmishAIId, featureId) != -1;
}

bool COOAICallback::UnitDef_HasYardMap(int unitDefId) const
{
	return sAICallback->UnitDef_getYardMap(skirmishAIId, unitDefId, UNIT_FACING_SOUTH, nullptr, -1) > 0;
}

} // namespace circuit
