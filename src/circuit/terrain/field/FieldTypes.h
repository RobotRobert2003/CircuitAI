/*
 * FieldTypes.h
 *
 * D-323: the battlefield map analysis ("field"). Engine-free value types:
 * the input snapshot one AI captures on the main thread, the settings from
 * data/config/field.json, and the published model every AI in the process
 * reads (owned by CGameAttribute through CFieldService). Nothing here
 * references the engine, a circuit or a thread; FieldAnalysis.cpp turns an
 * SInput into an SModel on a worker and FieldEncode.cpp writes the widget
 * file. Design: rjm.bar.docs/projects/circuitai/battlefield-analysis-implementation.md.
 */

#ifndef SRC_CIRCUIT_TERRAIN_FIELD_FIELDTYPES_H_
#define SRC_CIRCUIT_TERRAIN_FIELD_FIELDTYPES_H_

#include <cstdint>
#include <exception>
#include <string>
#include <vector>

namespace circuit::field {

// Movement class families (gamedata/movedefs.lua slope and depth limits).
// Order is least capable first for avenue naming (D-127 rule).
enum Class : int { C_VEH = 0, C_BOT, C_AMPH, C_HOVER, C_ALLT, C_SHIP, C_SUB, _CLASSES_ };
constexpr int kGroundClasses = C_ALLT + 1;   // C_VEH .. C_ALLT

enum Mobility : unsigned char { NO_GO = 0, SLOW_GO = 1, GO = 2 };

enum TheatreKind : int { T_LAND = 0, T_SEA, T_POND };
enum Character : int { R_PLAIN = 0, R_ROUGH, R_PLATEAU, R_VALLEY, R_WATER, R_DEEP, R_COAST, R_STRAIT };
enum BoundaryKind : int { B_OPEN = 0, B_RAMP, B_CLIMB, B_CLIFF, B_PASS, B_FORD, B_BEACH, B_STEEP, B_SHEER, B_EDGE };
enum KeyKind : int { K_HIGH = 0, K_GEO, K_METAL, K_ISLAND, K_POND };
// D-326: the ground class of one cell for the terrain view, from the same
// movedef limits as the mobility masks. Water first (deep: ships sail it;
// water: hovers and amphibious only; shallow: land units wade it), then land
// by the least capable class that can use it (flat: vehicles; rough: vehicles
// slowed; steep: bots and amphibious; cliff: all-terrain or nobody); harm is
// any water on a map whose water hurts (lava, acid).
enum Ground : unsigned char { G_DEEP = 0, G_WATER, G_SHALLOW, G_FLAT, G_ROUGH, G_STEEP, G_CLIFF, G_HARM };

struct SPoint {
	float x = 0.f, z = 0.f;
};
using Polyline = std::vector<SPoint>;

struct SBoxInput {
	int allyTeam = -1;
	float left = 0.f, right = 0.f, top = 0.f, bottom = 0.f;   // elmos; polys may be empty
	std::vector<Polyline> polys;
};

struct SClusterInput {
	float x = 0.f, z = 0.f, income = 0.f;
};

// Everything the analysis reads. Captured once by the owner AI (FieldService).
struct SInput {
	std::string mapName;
	int mapWidth = 0, mapHeight = 0;     // elmos
	std::vector<float> height;           // engine height map, 8-elmo samples, row major
	int heightStride = 0, heightRows = 0;
	std::vector<float> slope;            // engine slope map, 16-elmo samples, 1 - cos(angle)
	int slopeStride = 0, slopeRows = 0;
	bool waterHarmful = false;
	std::vector<SBoxInput> boxes;        // one per ally team with a start box
	std::vector<SPoint> geos;
	std::vector<SClusterInput> clusters;
};

struct SSettings {
	int cellSize = 32;
	int regionMinCells = 24;
	int waterMinCells = 16;
	float chokeFraction = 0.8f;   // BWEM: keep two areas apart when their contact is under 80% of the narrower seed clearance
	float highGroundRise = 128.f;
	float beachDepth = 160.f;
	int crossingMinLength = 2;
	int landingMerge = 2;
	float avenueDetour = 1.5f;
	int avenueMax = 6;
	float seaReach = 0.f;              // elmos; 0 = a fifth of the map diagonal
	float pondMaxShare = 0.025f;
	float standoffDepths[3] = {8.f, 15.f, 30.f};
};

struct STheatre {
	int id = 0, kind = T_LAND, cells = 0, holders = 0;   // holders: bit per side index
	std::string name;
	SPoint centre;
	std::vector<Polyline> outline;
	std::vector<int> regions;
	bool hasBox = false;
};

struct SRegion {
	int id = 0, theatre = 0, character = R_PLAIN, cells = 0;
	float medianWidth = 0.f, lowWidth = 0.f, minH = 0.f, maxH = 0.f, meanH = 0.f;
	float vehFraction = 0.f, deepFraction = 0.f, shallowFraction = 0.f;
	SPoint label;
	int labelCell = -1;
	std::vector<Polyline> outline;
};

struct SBoundary {
	int id = 0, kind = B_OPEN, a = -1, b = -1, classMask = 0;
	float width = 0.f, steepestDeg = 0.f;
	bool choke = false;
	Polyline line;
	int midCellA = -1, midCellB = -1;   // the cells either side of the middle edge
};

struct SChoke {
	int id = 0, a = -1, b = -1, cell = -1;
	SPoint pos, dir;
	float width = 0.f;
};

struct SAvenue {
	int id = 0, cls = C_VEH;
	bool specialist = false;
	std::string name;
	float length = 0.f;
	std::vector<int> regions, crossings;
	Polyline spine;
	std::vector<float> spineWidth;
};

struct SLanding {
	int id = 0, kind = B_BEACH, sea = -1, region = -1, side = -1, rank = 0, classMask = 0;
	float width = 0.f, inland = 0.f;
	float standoff[3] = {-1.f, -1.f, -1.f};
	SPoint mid;
	Polyline line;
};

struct SStandoff {
	int sea = -1;
	float depth = 0.f;
	Polyline line;
};

struct SSide {
	int allyTeam = -1, cells = 0;
	Polyline box;
	SPoint label;
};

struct SKey {
	int kind = K_GEO, region = -1, side = -1, avenue = -1;
	SPoint pos;
	float value = 0.f;
};

struct STimings {
	double gridMs = 0, mobilityMs = 0, sidesMs = 0, theatresMs = 0, regionsMs = 0,
		   boundariesMs = 0, landingsMs = 0, avenuesMs = 0, keyMs = 0, totalMs = 0;
};

struct SModel {
	std::string mapName;
	int gw = 0, gh = 0, cell = 32;
	std::vector<STheatre> theatres;
	std::vector<SRegion> regions;
	std::vector<SBoundary> boundaries;
	std::vector<SChoke> chokes;
	std::vector<SAvenue> avenues;
	std::vector<SLanding> landings;
	std::vector<SStandoff> standoffs;
	std::vector<SSide> sides;           // index = side index; allyTeam inside
	std::vector<Polyline> contact;
	std::vector<SKey> keys;
	std::vector<int> regionOf;          // per cell
	std::vector<int> sideOf;            // per cell, side index
	std::vector<unsigned char> groundOf;   // per cell, Ground (D-326)
	std::uint64_t fingerprint = 0;
	std::vector<std::string> checkFailures;
	STimings timings;
};

struct Cancelled final : std::exception {
	const char* what() const noexcept override { return "field analysis cancelled"; }
};

} // namespace circuit::field

#endif // SRC_CIRCUIT_TERRAIN_FIELD_FIELDTYPES_H_
