#include "../define.as"
#include "../types/start_spot.as"
#include "../types/map_config.as"

namespace BismuthValley {
	// NOTE: This map file intentionally holds only static data (start spots & MapConfig).
	// Role determination and factory selection occur in Main::AiMain using shared helpers.
	//
	// Source: BAR map-list export (popular16p pool), springName "Bismuth Valley v2.4.1".
	// MapConfig's first argument is matched as a case-sensitive PREFIX of the engine's map
	// name (MapConfig::CheckMatch, types/map_config.as), so the version suffix is dropped
	// here and "Bismuth Valley" keeps matching when the map is revved.
	//
	// Spawn layout: 16 points. P1-P8 are one team, P9-P16 the other, which lets the same
	// file serve both North-vs-South and South-vs-North. Coordinates are the exported
	// x / y pair fed in as AIFloat3(x, 0, y) -- the export's "y" is the map's z axis.
	//
	// Role mapping applied to the exported role strings:
	//   front                                          -> FRONT
	//   air, air/front                                 -> AIR
	//   tech, tech/air, air/tech, tech/front, front/tech -> TECH
	//   sea                                            -> SEA
	//   anything else / unlisted                       -> FRONT
	//
	// Local overrides of the export: P11 is the FRONT spot nearest (11000, 3000) - the
	// AIR spot P12 is nearer but exempt - and is moved onto that point as TECH. P3 is
	// its mirror: the spots mirror left-right about x = 6144 (each west/east pair sums
	// to ~12288, a 24-unit-wide map), so it sits at (1288, 3000), also TECH.
	//
	// landLocked heuristic: not yet surveyed on this map; every spot passes false. A future
	// pass may flag isolated starts that need hover/amphibious to break out.
	StartSpot@[] spots = {
		StartSpot(AIFloat3( 2226, 0,  276), AiRole::FRONT, false), // P1  front
		StartSpot(AIFloat3( 1603, 0, 1562), AiRole::FRONT,   false), // P2  front (2026-10-18 owner)
		StartSpot(AIFloat3( 1288, 0, 3000), AiRole::TECH,  false), // P3  tech (was front at 2367,2852; mirror of P11)
		StartSpot(AIFloat3( 1576, 0, 3978), AiRole::FRONT,   false), // P4  front (2026-10-18 owner)
		StartSpot(AIFloat3( 2147, 0, 4736), AiRole::AIR,     false), // P5  air (2026-10-18 owner)
		StartSpot(AIFloat3( 1814, 0, 5865), AiRole::FRONT, false), // P6  front
		StartSpot(AIFloat3( 2410, 0, 6918), AiRole::FRONT, false), // P7  front
		StartSpot(AIFloat3( 2095, 0, 7881), AiRole::FRONT, false), // P8  front
		StartSpot(AIFloat3(10042, 0,  352), AiRole::FRONT, false), // P9  front
		StartSpot(AIFloat3(10465, 0, 1572), AiRole::FRONT,   false), // P10 front (2026-10-18 owner)
		StartSpot(AIFloat3(11000, 0, 3000), AiRole::TECH,  false), // P11 tech (was front at 9946,2823)
		StartSpot(AIFloat3(10588, 0, 3928), AiRole::FRONT,   false), // P12 front (2026-10-18 owner)
		StartSpot(AIFloat3(10174, 0, 4876), AiRole::AIR,     false), // P13 air (2026-10-18 owner)
		StartSpot(AIFloat3(10496, 0, 5834), AiRole::FRONT, false), // P14 front
		StartSpot(AIFloat3( 9904, 0, 6719), AiRole::FRONT, false), // P15 front
		StartSpot(AIFloat3(10162, 0, 7867), AiRole::FRONT, false) // P16 front
	};

	// Base per-map unit limits
	dictionary mapUnitLimits; // add per-map unit restrictions here if needed

	MapConfig config = MapConfig("Bismuth Valley", mapUnitLimits, spots, getFactoryWeights());

	// Factory weights per role (higher weight = more likely).
	// Schema: role -> ( side -> (factory -> weight) )
	dictionary getFactoryWeights() {
		dictionary root; // role -> sideDict

		// FRONT role: side specific dictionaries
		dictionary frontArm; frontArm.set("armlab",2); frontArm.set("armvp",5);
		dictionary frontCor; frontCor.set("corlab",2); frontCor.set("corvp",5);
		dictionary frontLeg; frontLeg.set("leglab",2); frontLeg.set("legvp",5);
		dictionary frontRole; frontRole.set("armada", @frontArm); frontRole.set("cortex", @frontCor); frontRole.set("legion", @frontLeg);
		root.set("FRONT", @frontRole);

		// AIR role
		dictionary airArm; airArm.set("armap",3);
		dictionary airCor; airCor.set("corap",3);
		dictionary airLeg; airLeg.set("legap",3);
		dictionary airRole; airRole.set("armada", @airArm); airRole.set("cortex", @airCor); airRole.set("legion", @airLeg);
		root.set("AIR", @airRole);

		// SEA role
		dictionary seaArm; seaArm.set("armsy",4);
		dictionary seaCor; seaCor.set("corsy",4);
		dictionary seaLeg; seaLeg.set("legsy",4);
		dictionary seaRole; seaRole.set("armada", @seaArm); seaRole.set("cortex", @seaCor); seaRole.set("legion", @seaLeg);
		root.set("SEA", @seaRole);

		// TACTICAL role
		dictionary tacticalArm; tacticalArm.set("armhs",4); tacticalArm.set("armhp",4); tacticalArm.set("armsy",4);
		dictionary tacticalCor; tacticalCor.set("corhs",4); tacticalCor.set("corhp",4); tacticalCor.set("corsy",4);
		dictionary tacticalLeg; tacticalLeg.set("leghs",4); tacticalLeg.set("leghp",4); tacticalLeg.set("legsy",4);
		dictionary tacticalRole; tacticalRole.set("armada", @tacticalArm); tacticalRole.set("cortex", @tacticalCor); tacticalRole.set("legion", @tacticalLeg);
		root.set("TACTICAL", @tacticalRole);

		// TECH role
		dictionary techArm; techArm.set("armlab",4);
		dictionary techCor; techCor.set("corlab",4);
		dictionary techLeg; techLeg.set("leglab",4);
		dictionary techRole; techRole.set("armada", @techArm); techRole.set("cortex", @techCor); techRole.set("legion", @techLeg);
		root.set("TECH", @techRole);

		// SUPPORT role
		dictionary supportArm; supportArm.set("armlab",4);
		dictionary supportCor; supportCor.set("corlab",4);
		dictionary supportLeg; supportLeg.set("leglab",4);
		dictionary supportRole; supportRole.set("armada", @supportArm); supportRole.set("cortex", @supportCor); supportRole.set("legion", @supportLeg);
		root.set("SUPPORT", @supportRole);

		return root;
	}

}
