#include "../define.as"
#include "../types/start_spot.as"
#include "../types/map_config.as"

namespace CoastlinesDry {
	// NOTE: This map file intentionally holds only static data (start spots & MapConfig).
	// Role determination and factory selection occur in Main::AiMain using shared helpers.
	//
	// Source: BAR map-list export (popular16p pool), springName "Coastlines_Dry_V2.2.1".
	// MapConfig's first argument is matched as a case-sensitive PREFIX of the engine's map
	// name (MapConfig::CheckMatch, types/map_config.as), so the version suffix is dropped
	// here and "Coastlines_Dry" keeps matching when the map is revved.
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
	// landLocked heuristic: not yet surveyed on this map; every spot passes false. A future
	// pass may flag isolated starts that need hover/amphibious to break out.
	StartSpot@[] spots = {
		StartSpot(AIFloat3(1909, 0,  557), AiRole::FRONT, false), // P1  front
		StartSpot(AIFloat3(2026, 0, 1886), AiRole::FRONT, false), // P2  front
		StartSpot(AIFloat3(1561, 0, 3316), AiRole::FRONT, false), // P3  front
		StartSpot(AIFloat3( 845, 0, 3320), AiRole::TECH,  false), // P4  front/tech
		StartSpot(AIFloat3(1680, 0, 4357), AiRole::FRONT, false), // P5  front
		StartSpot(AIFloat3( 936, 0, 4416), AiRole::AIR,   false), // P6  air/front
		StartSpot(AIFloat3(1173, 0, 5540), AiRole::FRONT, false), // P7  front
		StartSpot(AIFloat3( 868, 0, 6970), AiRole::FRONT, false), // P8  front
		StartSpot(AIFloat3(8104, 0,  427), AiRole::FRONT, false), // P9  front
		StartSpot(AIFloat3(8097, 0, 1579), AiRole::FRONT, false), // P10 front
		StartSpot(AIFloat3(8289, 0, 3106), AiRole::FRONT, false), // P11 front
		StartSpot(AIFloat3(9106, 0, 2986), AiRole::TECH,  false), // P12 front/tech
		StartSpot(AIFloat3(8774, 0, 4507), AiRole::FRONT, false), // P13 front
		StartSpot(AIFloat3(9428, 0, 4256), AiRole::AIR,   false), // P14 air/front
		StartSpot(AIFloat3(9384, 0, 5618), AiRole::FRONT, false), // P15 front
		StartSpot(AIFloat3(9560, 0, 6952), AiRole::FRONT, false) // P16 front
	};

	// Base per-map unit limits
	dictionary mapUnitLimits; // add per-map unit restrictions here if needed

	MapConfig config = MakeConfig();
	MapConfig MakeConfig() {
		MapConfig result("Coastlines_Dry", mapUnitLimits, spots, getFactoryWeights());
		result.TechCompactEconomy = true;
		return result;
	}

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
