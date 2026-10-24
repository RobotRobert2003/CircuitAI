#include "../define.as"
#include "../types/start_spot.as"
#include "../types/map_config.as"

namespace FullMetalPlate {
	// NOTE: This map file intentionally holds only static data (start spots & MapConfig).
	// Role determination and factory selection now occur in Main::AiMain using shared helpers.

	// Full Metal Plate (12288 x 12288, the whole map is metal: no mex spots, so the game places AIs with GuessTwo
	// on a 768-elmo grid). Owner 2026-10-24: 7 FRONT + 1 SUPPORT per team, evenly spaced along the map box
	// (x 0-3072 / 9216-12288, full height) and centred across it; every spot sits on a GuessTwo grid point so
	// the start_boxes.json diamonds (Team 2) put each AI exactly on its spot. Team 1 = humans, mirrored roles.
	StartSpot@[] spots = {
		StartSpot(AIFloat3( 1536, 0,   768), AiRole::FRONT, false), // P1
		StartSpot(AIFloat3( 1536, 0,  2304), AiRole::FRONT, false), // P2
		StartSpot(AIFloat3( 1536, 0,  3840), AiRole::FRONT, false), // P3
		StartSpot(AIFloat3( 1536, 0,  5376), AiRole::SUPPORT, false), // P4
		StartSpot(AIFloat3( 1536, 0,  6912), AiRole::FRONT, false), // P5
		StartSpot(AIFloat3( 1536, 0,  8448), AiRole::FRONT, false), // P6
		StartSpot(AIFloat3( 1536, 0,  9984), AiRole::FRONT, false), // P7
		StartSpot(AIFloat3( 1536, 0, 11520), AiRole::FRONT, false), // P8

		StartSpot(AIFloat3(10752, 0,   768), AiRole::FRONT, false), // P9
		StartSpot(AIFloat3(10752, 0,  2304), AiRole::FRONT, false), // P10
		StartSpot(AIFloat3(10752, 0,  3840), AiRole::FRONT, false), // P11
		StartSpot(AIFloat3(10752, 0,  5376), AiRole::SUPPORT, false), // P12
		StartSpot(AIFloat3(10752, 0,  6912), AiRole::FRONT, false), // P13
		StartSpot(AIFloat3(10752, 0,  8448), AiRole::FRONT, false), // P14
		StartSpot(AIFloat3(10752, 0,  9984), AiRole::FRONT, false), // P15
		StartSpot(AIFloat3(10752, 0, 11520), AiRole::FRONT, false) // P16
	};

	// Base per-map unit limits
	dictionary mapUnitLimits; // add per-map unit restrictions here if needed

	MapConfig config = MapConfig("Full Metal Plate", mapUnitLimits, spots, getFactoryWeights());

	// (Replaced getMaxUnits() with mapUnitLimits dictionary above)

	// Example factory weights per role (higher weight = more likely).
	// New v2 schema: role -> ( side -> (factory -> weight) )
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

		// TECH role
		dictionary techArm; techArm.set("armlab",4);
		dictionary techCor; techCor.set("corlab",4);
		dictionary techLeg; techLeg.set("leglab",4);

		dictionary techRole; techRole.set("armada", @techArm); techRole.set("cortex", @techCor); techRole.set("legion", @techLeg);
		
		root.set("TECH", @techRole); 

		// SUPPORT roles
		dictionary frontTechHybridArm; frontTechHybridArm.set("armlab",4);
		dictionary frontTechHybridCor; frontTechHybridCor.set("corlab",4);
		dictionary frontTechHybridLeg; frontTechHybridLeg.set("leglab",4);

		dictionary frontTechHybridRole; frontTechHybridRole.set("armada", @frontTechHybridArm); frontTechHybridRole.set("cortex", @frontTechHybridCor); frontTechHybridRole.set("legion", @frontTechHybridLeg);

		root.set("SUPPORT", @frontTechHybridRole); // reuse

		return root;
	}

} 
