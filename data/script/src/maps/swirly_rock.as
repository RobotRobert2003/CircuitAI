#include "../define.as"
#include "../types/start_spot.as"
#include "../types/map_config.as"

namespace SwirlyRock {
	// NOTE: This map file intentionally holds only static data (start spots & MapConfig).
	// Role determination and factory selection now occur in Main::AiMain using shared helpers.

	// landLocked heuristic (initial): none flagged yet on this map; future pass may mark
	// isolated peninsulas requiring hover/amph first. Pass false for all for now.
    // Start positions sourced from resources/data/maps/all_that_glitters.yaml (springName: All That Glitters v2.2)
    // Role mapping: front->FRONT, air->AIR, tech->TECH
    // Owner 2026-10-28: AIR off the exposed central plateau. Two FRONTs hold the plateau's
    // west face (the middle pair of the maps JSON), AIR takes the east-edge spot, the north-west
    // FRONT moves to the 3-mex corner. The left side mirrors the right (x -> 12288 - x).
    StartSpot@[] spots = {
        StartSpot(AIFloat3( 1788, 0,   550), AiRole::FRONT, false),
        StartSpot(AIFloat3(  488, 0,  7600), AiRole::FRONT, false),
        StartSpot(AIFloat3( 2288, 0,  3500), AiRole::FRONT, false),
        StartSpot(AIFloat3(  788, 0,  3000), AiRole::TECH,  false),

        StartSpot(AIFloat3(  288, 0,  4800), AiRole::AIR,   false),
        StartSpot(AIFloat3( 3072, 0,  4382), AiRole::FRONT, false),
        StartSpot(AIFloat3( 3073, 0,  4937), AiRole::FRONT, false),
        StartSpot(AIFloat3( 1788, 0,  6200), AiRole::FRONT, false),

        StartSpot(AIFloat3(10500, 0,   550), AiRole::FRONT, false),
        StartSpot(AIFloat3(11800, 0,  7600), AiRole::FRONT, false),
        StartSpot(AIFloat3(10000, 0,  3500), AiRole::FRONT, false),
        StartSpot(AIFloat3(11500, 0,  3000), AiRole::TECH,  false),

        StartSpot(AIFloat3(12000, 0,  4800), AiRole::AIR,   false),
        StartSpot(AIFloat3( 9216, 0,  4382), AiRole::FRONT, false),
        StartSpot(AIFloat3( 9215, 0,  4937), AiRole::FRONT, false),
        StartSpot(AIFloat3(10500, 0,  6200), AiRole::FRONT, false)
    };

    // Base per-map unit limits
    dictionary mapUnitLimits; // add per-map unit restrictions here if needed

    MapConfig config = MapConfig("Swirly Rock", mapUnitLimits, spots, getFactoryWeights());

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
