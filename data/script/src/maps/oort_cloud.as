#include "../define.as"
#include "../types/start_spot.as"
#include "../types/map_config.as"

namespace OortCloud {
	// NOTE: This map file intentionally holds only static data (start spots & MapConfig).
	// Role determination and factory selection now occur in Main::AiMain using shared helpers.

	// Oort Cloud (Oort_Cloud_V2, 12288 x 12288, a 4 x 4 grid of metal circles joined by bridges over void; metal map,
	// no mex spots, so the game places AIs with GuessTwo on a 768-elmo grid). Owner 2026-10-24: Team 2 (AIs) takes
	// the 8 circles of the two eastern columns, one spot per circle, north to south in pairs (owner
	// 2026-10-24 11:07: all FRONT; AIR/TECH earned 10 metal/s here). Spots sit on flat plateau GuessTwo grid points so
	// the start_boxes.json diamonds put each AI on its spot. P1-P8 = the mirror for Team 1 (humans).
	StartSpot@[] spots = {
		StartSpot(AIFloat3( 4592, 0,  1536), AiRole::FRONT, false), // P1
		StartSpot(AIFloat3( 2288, 0,  1536), AiRole::FRONT, false), // P2
		StartSpot(AIFloat3( 4592, 0,  4608), AiRole::FRONT, false), // P3
		StartSpot(AIFloat3( 2288, 0,  4608), AiRole::FRONT, false), // P4
		StartSpot(AIFloat3( 4592, 0,  7680), AiRole::FRONT, false), // P5
		StartSpot(AIFloat3( 2288, 0,  7680), AiRole::FRONT, false), // P6
		StartSpot(AIFloat3( 4592, 0,  9984), AiRole::FRONT, false), // P7
		StartSpot(AIFloat3( 1520, 0,  9984), AiRole::FRONT, false), // P8

		StartSpot(AIFloat3( 7696, 0,  1536), AiRole::FRONT, false), // P9
		StartSpot(AIFloat3(10000, 0,  1536), AiRole::FRONT, false), // P10
		StartSpot(AIFloat3( 7696, 0,  4608), AiRole::FRONT, false), // P11
		StartSpot(AIFloat3(10000, 0,  4608), AiRole::FRONT, false), // P12
		StartSpot(AIFloat3( 7696, 0,  7680), AiRole::FRONT, false), // P13
		StartSpot(AIFloat3(10000, 0,  7680), AiRole::FRONT, false), // P14
		StartSpot(AIFloat3( 7696, 0,  9984), AiRole::FRONT, false), // P15
		StartSpot(AIFloat3(10768, 0,  9984), AiRole::FRONT, false) // P16
	};

	// Base per-map unit limits
	dictionary mapUnitLimits; // add per-map unit restrictions here if needed

	MapConfig config = MapConfig("Oort_Cloud", mapUnitLimits, spots, getFactoryWeights());

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
