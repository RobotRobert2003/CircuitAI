/*
 * MapManager.cpp
 *
 *  Created on: Dec 21, 2019
 *      Author: rlcevg
 */

#include "map/MapManager.h"
#include "map/ThreatMap.h"
#include "map/InfluenceMap.h"
#include "CircuitAI.h"

#include "spring/SpringCallback.h"
#include "spring/SpringMap.h"

#include "Mod.h"

namespace circuit {

using namespace springai;

CMapManager::CMapManager(CCircuitAI* circuit, float decloakRadius)
		: circuit(circuit)
{
	CMap* map = circuit->GetMap();
	int mapWidth = map->GetWidth();
	Mod* mod = circuit->GetCallback()->GetMod();
	int losMipLevel = mod->GetLosMipLevel();
	int radarMipLevel = mod->GetRadarMipLevel();
	delete mod;

	map->GetRadarMap(radarMap);
	radarWidth = mapWidth >> radarMipLevel;
	map->GetSonarMap(sonarMap);
	radarResConv = SQUARE_SIZE << radarMipLevel;
	map->GetLosMap(losMap);
	losWidth = mapWidth >> losMipLevel;
	losResConv = SQUARE_SIZE << losMipLevel;

	threatMap = new CThreatMap(this, decloakRadius);
	inflMap = new CInfluenceMap(this);
}

CMapManager::~CMapManager()
{
	delete threatMap;
	delete inflMap;
}

void CMapManager::InitMaps()
{
	threatMap->ReadConfig();
	inflMap->ReadConfig();
}

void CMapManager::PrepareUpdate()
{
	circuit->GetMap()->GetRadarMap(radarMap);
	circuit->GetMap()->GetSonarMap(sonarMap);
	circuit->GetMap()->GetLosMap(losMap);
}

void CMapManager::EnqueueUpdate()
{
	threatMap->EnqueueUpdate();
	inflMap->EnqueueUpdate();
}

bool CMapManager::IsUpdating() const
{
	return threatMap->IsUpdating() || inflMap->IsUpdating();
}

bool CMapManager::HostileInLOS(CEnemyUnit* enemy)
{
	if (enemy->IsHidden()) {
		return false;
	}

	if (enemy->NotInRadarAndLOS() && IsInLOS(enemy->GetPos())) {
		enemy->SetHidden();
		return false;
	}

	if (enemy->IsInLOS()) {
		threatMap->SetEnemyUnitThreat(enemy);
	}

	return true;
}

bool CMapManager::PeaceInLOS(CEnemyUnit* enemy)
{
	if (enemy->IsHidden()) {
		return false;
	}

	if (enemy->NotInRadarAndLOS() && IsInLOS(enemy->GetPos())) {
		enemy->SetHidden();
		return false;
	}

	return true;
}

bool CMapManager::IsSuddenThreat(CEnemyUnit* enemy) const
{
	// NOTE: CCircuitAI::EnemyEnterLOS calls this *before* allyTeam->EnemyEnterLOS
	//       identifies the unit, so an enemy that was previously known only by
	//       radar still has no CCircuitDef here. Dereferencing it faulted at the
	//       first contacts of a game (access violation, f=181 on Eight Horses).
	//       An unidentified contact cannot be judged mobile; treat the radar-loss
	//       case as sudden, which is what the check is reaching for anyway.
	if (!enemy->IsKnown(circuit->GetLastFrame())) {
		return true;
	}
	if (enemy->IsInRadar()) {
		return false;
	}
	CCircuitDef* edef = enemy->GetCircuitDef();
	return (edef == nullptr) || edef->IsMobile();
}

bool CMapManager::EnemyEnterLOS(CEnemyUnit* enemy)
{
	// Possible cases:
	// (1) Unknown enemy that has been detected for the first time
	// (2) Unknown enemy that was only in radar enters LOS
	// (3) Known enemy that already was in LOS enters again

	const bool wasKnown = enemy->IsKnown(circuit->GetLastFrame());
	enemy->SetInLOS();

	if (!enemy->IsAttacker()) {
		if (enemy->GetInfluence() > .0f) {  // (2)
			// threat prediction failed when enemy was unknown
			if (enemy->IsHidden()) {
				enemy->ClearHidden();
			}
			hostileUnits.erase(enemy->GetId());
			peaceUnits[enemy->GetId()] = enemy;
			enemy->ClearThreat();
			threatMap->SetEnemyUnitRange(enemy);
		} else if (peaceUnits.find(enemy->GetId()) == peaceUnits.end()) {
			peaceUnits[enemy->GetId()] = enemy;
			threatMap->SetEnemyUnitRange(enemy);
		} else if (enemy->IsHidden()) {
			enemy->ClearHidden();
		}

		enemy->UpdateInRadarData(enemy->GetUnit()->GetPos());
		enemy->UpdateInLosData();
		enemy->SetKnown(circuit->GetLastFrame());

		return !wasKnown;
	}

	if (hostileUnits.find(enemy->GetId()) == hostileUnits.end()) {
		hostileUnits[enemy->GetId()] = enemy;
	} else if (enemy->IsHidden()) {
		enemy->ClearHidden();
	}

	enemy->UpdateInRadarData(enemy->GetUnit()->GetPos());
	enemy->UpdateInLosData();
	threatMap->SetEnemyUnitRange(enemy);
	threatMap->SetEnemyUnitThreat(enemy);
	enemy->SetKnown(circuit->GetLastFrame());

	return !wasKnown;
}

void CMapManager::EnemyLeaveLOS(CEnemyUnit* enemy)
{
	enemy->ClearInLOS();
}

void CMapManager::EnemyEnterRadar(CEnemyUnit* enemy)
{
	// Possible cases:
	// (1) Unknown enemy wanders at radars
	// (2) Known enemy that once was in los wandering at radar
	// (3) EnemyEnterRadar invoked right after EnemyEnterLOS in area with no radar

	enemy->SetLastSeen(-1);
	enemy->SetInRadar();

	if (enemy->IsInLOS()) {  // (3)
		return;
	}

	if (!enemy->IsAttacker()) {  // (2)
		if (enemy->IsHidden()) {
			enemy->ClearHidden();
		}

		enemy->UpdateInRadarData(enemy->GetUnit()->GetPos());

		return;
	}

	bool isNew = false;
	auto it = hostileUnits.find(enemy->GetId());
	if (it == hostileUnits.end()) {  // (1)
		std::tie(it, isNew) = hostileUnits.emplace(enemy->GetId(), enemy);
	} else if (enemy->IsHidden()) {
		enemy->ClearHidden();
	}

	enemy->UpdateInRadarData(enemy->GetUnit()->GetPos());
	if (isNew) {  // unknown enemy enters radar for the first time
		threatMap->NewEnemy(enemy);
	}
}

void CMapManager::EnemyLeaveRadar(CEnemyUnit* enemy)
{
	enemy->SetLastSeen(circuit->GetLastFrame());
	enemy->ClearInRadar();
}

bool CMapManager::EnemyDestroyed(CEnemyUnit* enemy)
{
	const bool isKnown = enemy->IsKnown(circuit->GetLastFrame());

	auto it = hostileUnits.find(enemy->GetId());
	if (it == hostileUnits.end()) {
		peaceUnits.erase(enemy->GetId());
		return isKnown;
	}

	hostileUnits.erase(it);
	return isKnown;
}

void CMapManager::AddFakeEnemy(CEnemyFake* enemy)
{
	enemyFakes.insert(enemy);
	threatMap->SetEnemyUnitRange(enemy);
	threatMap->SetEnemyUnitThreat(enemy);
}

void CMapManager::DelFakeEnemy(CEnemyFake* enemy)
{
	enemyFakes.erase(enemy);
}

/*
 * Radar coverage of our ally team at this position. Note this is coverage, not
 * detection: a unit inside an enemy jammer's radardistancejam (360-760 in BAR)
 * produces no contact even here, which is exactly the inference a pulse weapon
 * uses to find a jammer it can never see on radar.
 */
bool CMapManager::IsInRadar(const AIFloat3& pos) const
{
	// Underwater needs sonar rather than radar (Mod->GetRequireSonarUnderWater).
	const IntVec& map = (pos.y < -SQUARE_SIZE * 5) ? sonarMap : radarMap;
	if (map.empty()) {
		return false;
	}
	const int x = (int)pos.x / radarResConv;
	const int z = (int)pos.z / radarResConv;
	const int idx = z * radarWidth + x;
	if ((idx < 0) || (idx >= int(map.size()))) {
		return false;
	}
	return map[idx] > 0;
}

bool CMapManager::IsInLOS(const AIFloat3& pos) const
{
	// res = 1 << Mod->GetLosMipLevel();
	// the value for the full resolution position (x, z) is at index ((z * width + x) / res)
	// the last value, bottom right, is at index (width/res * height/res - 1)

	// FIXME: @see rts/Sim/Objects/SolidObject.cpp CSolidObject::UpdatePhysicalState
	//        for proper "underwater" implementation
	if (pos.y < -SQUARE_SIZE * 5) {  // Mod->GetRequireSonarUnderWater() = true
		const int x = (int)pos.x / radarResConv;
		const int z = (int)pos.z / radarResConv;
		if (sonarMap[z * radarWidth + x] <= 0) {
			return false;
		}
	}
	// convert from world coordinates to losmap coordinates
	const int x = (int)pos.x / losResConv;
	const int z = (int)pos.z / losResConv;
	return losMap[z * losWidth + x] > 0;
}

bool CMapManager::IsAreaInLOS(const AIFloat3& pos, float radius) const
{
	// Exact cached LOS-cell rectangle, not circular UnitDef sight estimates or
	// unseen-enemy queries. Called only at opt-in placement admission. O(cells
	// in the requested area), no engine callbacks, allocations or map copies.
	if (!std::isfinite(pos.x) || !std::isfinite(pos.z) || !std::isfinite(radius)
	    || radius < 0 || radius > 2048 || losResConv <= 0 || losWidth <= 0 || losMap.empty()) return false;
	const int height=int(losMap.size())/losWidth;
	if (pos.x-radius < 0 || pos.z-radius < 0 || pos.x+radius >= losWidth*losResConv
	    || pos.z+radius >= height*losResConv) return false;
	const int x1=int(pos.x-radius)/losResConv, x2=int(pos.x+radius)/losResConv;
	const int z1=int(pos.z-radius)/losResConv, z2=int(pos.z+radius)/losResConv;
	for (int z=z1; z<=z2; ++z) for (int x=x1; x<=x2; ++x)
		if (losMap[z*losWidth+x]<=0) return false;
	return true;
}

} // namespace circuit
