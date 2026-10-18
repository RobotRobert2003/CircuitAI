#include "../define.as"
#include "../types/start_spot.as"
#include "../types/map_config.as"

namespace Forge {
	// NOTE: This map file intentionally holds only static data (start spots & MapConfig).
	// Role determination and factory selection now occur in Main::AiMain using shared helpers.

	// landLocked heuristic (initial): none flagged yet on this map; future pass may mark
	// isolated peninsulas requiring hover/amph first. Pass false for all for now.
	// Start spots = the lobby maps JSON spawn points P1-P16 (2026-10-18); owner: P6 and P14 are TECH.
	StartSpot@[] spots = {
		StartSpot(AIFloat3( 2137, 0, 1545), AiRole::FRONT, false), // P1
		StartSpot(AIFloat3( 2347, 0, 2722), AiRole::FRONT, false), // P2
		StartSpot(AIFloat3(  451, 0, 3453), AiRole::AIR, false), // P3
		StartSpot(AIFloat3( 2018, 0, 4108), AiRole::FRONT, false), // P4
		StartSpot(AIFloat3( 1997, 0, 5212), AiRole::FRONT, false), // P5
		StartSpot(AIFloat3(  317, 0, 6091), AiRole::TECH, false), // P6 (lobby JSON: front)
		StartSpot(AIFloat3( 2368, 0, 6535), AiRole::FRONT, false), // P7
		StartSpot(AIFloat3( 2111, 0, 7630), AiRole::FRONT, false), // P8

		StartSpot(AIFloat3( 7095, 0, 7604), AiRole::FRONT, false), // P9
		StartSpot(AIFloat3( 6929, 0, 6517), AiRole::FRONT, false), // P10
		StartSpot(AIFloat3( 8887, 0, 6005), AiRole::AIR, false), // P11
		StartSpot(AIFloat3( 7205, 0, 5179), AiRole::FRONT, false), // P12
		StartSpot(AIFloat3( 7190, 0, 4100), AiRole::FRONT, false), // P13
		StartSpot(AIFloat3( 8795, 0, 3495), AiRole::TECH, false), // P14 (lobby JSON: front)
		StartSpot(AIFloat3( 6890, 0, 2669), AiRole::FRONT, false), // P15
		StartSpot(AIFloat3( 7074, 0, 1552), AiRole::FRONT, false) // P16
	};

	// Base per-map unit limits
	dictionary mapUnitLimits; // add per-map unit restrictions here if needed

	MapConfig config = MapConfig("Forge", mapUnitLimits, spots, getFactoryWeights());

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
