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

// Part B1 (landmarks): a playing team from the start script. `known` is set
// when the script carries its start position (fixed or chosen-before-game
// starts, the playtest harness); otherwise the position is predicted.
struct STeamInput {
	int team = -1, allyTeam = -1;
	bool known = false;
	float x = 0.f, z = 0.f;
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
	// Part B1: every playing team of the game (not this AI's view of it), the
	// map's wind range and tidal strength. Nothing about the owner AI enters.
	std::vector<STeamInput> teams;
	float minWind = 0.f, maxWind = 0.f, tidal = 0.f;
};

// Part B1: the opening factory classes, mapped to a factory id per faction by
// field.json "openings.factories" (no factory id lives in C++).
enum Opening : int { O_BOT = 0, O_VEH, O_HOVER, O_SHIP, O_AIR, _OPENINGS_ };
// The game's own position words (maps-metadata, Build Atlas), not AiRole.
enum PosLabel : int { L_FRONT = 0, L_SEA, L_ISLAND, L_POND, L_GEO, L_AIR, L_TECH, L_FRONT_TECH, _LABELS_ };
enum PosSub : int { S_NONE = 0, S_BEACH_SEA, S_GEO_SEA, S_SUICIDE_FRONT };
enum Energy : int { E_SOLAR = 0, E_WIND, E_TIDAL };
enum MarkGroup : int { MG_ECONOMY = 0, MG_LAND, MG_SEA, MG_LATE };
enum MarkKind : int {
	MK_METAL = 0, MK_CENTRE, MK_GEO, MK_TIDAL,
	MK_CHOKE, MK_KILL, MK_RADAR, MK_PERCH, MK_FORWARD,
	MK_YARD, MK_SEAZONE, MK_STRAIT, MK_LANDING, MK_EMERGE, MK_COASTFIRE, MK_SEAPLANE, MK_ISLAND,
	MK_LRPC, MK_ANTINUKE, _MARK_KINDS_
};

// Part B1 levers (field.json "positions", "labels", "openings", "landmarks").
// Fractions are shares of a side's largest travel cost to the contact line;
// distances are elmos; every value has a JSON key of the same meaning.
struct SMarkSettings {
	bool enabled = true;
	// positions
	float walkRadius = 750.f, minSpacing = 350.f;
	int kmedoidsRounds = 10, siteStep = 4;
	float geoWeight = 3.f, areaWeight = 0.02f;
	float metalScale = 0.001f;   // spot value to T1 metal per second (armmex/cormex/legmex extractsmetal)
	// labels
	float seaYardReach = 1600.f, yardDepth = 30.f, yardClear = 320.f, geoReach = 900.f, seaShareMin = 0.4f, seaFullShare = 0.9f;
	int pondMinCells = 40;
	float islandBaseArea = 1000000.f;
	float rearFraction = 0.5f, geoShareMin = 0.2f;
	int airPerSide = 1, techPerSide = 1, seaPerSea = 1, airMinPositions = 3, techMinPositions = 3;
	float frontTechMetal = 12.f, techAreaWeight = 2.f;
	// openings
	float vehShare = 0.6f, openWidth = 640.f, vehMapScale = 14000.f;
	float windMin = 7.f, tidalMargin = 1.f;
	std::string factories[_OPENINGS_][3];   // [class][armada, cortex, legion]
	std::string second[_LABELS_];           // the step after the factory, per label
	// landmarks
	float contestDistance = 600.f, killReach = 1400.f, radarFrontShare = 0.5f;
	float perchRange = 1250.f, forwardIncome = 4.f, forwardShareMax = 0.6f;
	float artilleryShipRange = 1550.f, lrpcRange = 4650.f, antinukeCoverage = 2000.f;
	int labelsPerKind = 3, lrpcPerSide = 2, antinukePerSide = 2, coastTargets = 3;
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
	SMarkSettings marks;
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

// Part B1: one position per playing team, both sides.
struct SFeatures {
	int cells = 0;
	float ground[8] = {0, 0, 0, 0, 0, 0, 0, 0};   // share per Ground class (G_HARM folded into water)
	float openWidth = 0.f, vehShare = 0.f, metal = 0.f;
	int clusters = 0, geos = 0, geoNear = -1;   // geoNear: the nearest geo vent on the own side (index into the input)
	float geoDist = -1.f;
	int sea = -1;                 // the contested sea (T_SEA) the territory holds, or one with a yard within reach; -1 none
	int seaCells = 0;             // that sea's cells inside the territory
	SPoint yard{-1.f, -1.f};
	float yardDist = -1.f;
	int pondCells = 0, assaultRank = 0;
	bool island = false;
	bool hoverAvenue = false, landAvenue = false;
	float landArea = 0.f;         // flat buildable elmo² inside the territory
};

struct SPosition {
	int index = 0, side = -1, allyTeam = -1, n = 0, rearRank = 0, cell = -1;
	std::string name;
	SPoint pos;
	bool predicted = true;
	int label = L_FRONT, sub = S_NONE;
	float frontShare = 1.f;       // travel cost to the contact line / the side's largest
	SFeatures f;
	int opening = O_BOT;
	std::vector<int> fallbacks;
	int energy = E_SOLAR;
	std::vector<std::string> reasons;
};

struct SMark {
	int id = 0, group = MG_ECONOMY, kind = MK_METAL, position = -1, allyTeam = -1;
	SPoint pos;
	float value = 0.f;
	bool contested = false, labelled = false;
	int phaseFrom = 0, phaseTo = -1;   // game minutes, -1 = open
	std::string reason;
	Polyline line;
};

struct STimings {
	double gridMs = 0, mobilityMs = 0, sidesMs = 0, theatresMs = 0, regionsMs = 0,
		   boundariesMs = 0, landingsMs = 0, avenuesMs = 0, keyMs = 0, totalMs = 0;
	double positionsMs = 0, territoryMs = 0, labelsMs = 0, marksMs = 0, marksTotalMs = 0;
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
	// Part B1 (landmarks.txt); empty when field.json disables it
	bool marksBuilt = false;
	std::vector<SPosition> positions;
	std::vector<SMark> marks;
	std::vector<int> posOf;             // per cell, position index or -1
	float minWind = 0.f, maxWind = 0.f, tidal = 0.f, mapDiagonal = 0.f;
	std::uint64_t marksFingerprint = 0;
	std::vector<std::string> marksFailures;
	STimings timings;
};

struct Cancelled final : std::exception {
	const char* what() const noexcept override { return "field analysis cancelled"; }
};

} // namespace circuit::field

#endif // SRC_CIRCUIT_TERRAIN_FIELD_FIELDTYPES_H_
