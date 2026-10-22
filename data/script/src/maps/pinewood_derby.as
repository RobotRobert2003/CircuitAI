#include "../define.as"
#include "../types/start_spot.as"
#include "../types/map_config.as"

namespace PinewoodDerby {
	// 2v2 anchors in the official west/east 20% start boxes (6144 x 3072).
	// The archive supplies only the northwest/southeast defaults; the other
	// two anchors cover the southwest/northeast starting metal clusters.
	// These select AI roles; they do not override player-selected starts.
	StartSpot@[] spots = {
		StartSpot(AIFloat3(600, 0, 700), AiRole::FRONT, false),
		StartSpot(AIFloat3(500, 0, 2350), AiRole::FRONT, false),
		StartSpot(AIFloat3(5600, 0, 450), AiRole::FRONT, false),
		StartSpot(AIFloat3(5500, 0, 2500), AiRole::FRONT, false)
	};

	dictionary getMapUnitLimits() {
		dictionary limits;
		return limits;
	}

	MapConfig config = MapConfig("Pinewood_Derby", getMapUnitLimits(), spots);
}
