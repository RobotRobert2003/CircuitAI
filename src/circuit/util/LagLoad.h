#ifndef CIRCUIT_UTIL_LAGLOAD_H
#define CIRCUIT_UTIL_LAGLOAD_H

#include "util/Defines.h"

#include <algorithm>

namespace circuit {
namespace lagload {

// Owner 2026-10-25: one load level for every SMRTBARb in this process (they
// all run on the host's client). Entrenched Plains lagged at 2,344 AI units,
// Esker Creek at 1,887. The throttle starts at 1,500 AI units and is full at
// 3,500: 10 s between new move orders and between attack-target changes for
// T1/T2 units, 5 s between new construction turret orders. Mortars reach 5 s
// between target changes at 2,300 and 10 s at 3,500. Commanders, T3 and
// factories (gantry included) are never throttled here.
// Plain counters on the engine thread; one recompute per second, one log line
// per minute.
struct State {
	int frame = -1;
	int minute = -1;
	int aiUnits = 0;
	int enemyUnits = 0;  // known (seen or on radar) by the logging AI
	float level = 0.f;   // 0 at START_UNITS, 1 at FULL_UNITS
	int moveFloor = 0;   // frames
	int targetFloor = 0;
	int mortarFloor = 0;
	int turretFloor = 0;
	unsigned moves = 0, movesDropped = 0;
	unsigned targets = 0, targetsDropped = 0;
	unsigned turret = 0, turretDropped = 0;
	unsigned other = 0;
};

constexpr int START_UNITS = 1500;
constexpr int MORTAR_MID_UNITS = 2300;
constexpr int FULL_UNITS = 3500;

inline State& Get() { static State state; return state; }

inline void SetUnits(State& s, int aiUnits)
{
	s.aiUnits = aiUnits;
	s.level = std::clamp(float(aiUnits - START_UNITS) / float(FULL_UNITS - START_UNITS), 0.f, 1.f);
	s.moveFloor = int(s.level * 10.f * FRAMES_PER_SEC);
	s.targetFloor = s.moveFloor;
	s.turretFloor = int(s.level * 5.f * FRAMES_PER_SEC);
	float mortar;
	if (aiUnits <= START_UNITS) {
		mortar = 0.f;
	} else if (aiUnits <= MORTAR_MID_UNITS) {
		mortar = 5.f * float(aiUnits - START_UNITS) / float(MORTAR_MID_UNITS - START_UNITS);
	} else {
		mortar = std::min(10.f, 5.f + 5.f * float(aiUnits - MORTAR_MID_UNITS) / float(FULL_UNITS - MORTAR_MID_UNITS));
	}
	s.mortarFloor = int(mortar * FRAMES_PER_SEC);
}

} // namespace lagload
} // namespace circuit

#endif // CIRCUIT_UTIL_LAGLOAD_H
