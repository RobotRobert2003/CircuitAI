// D-323: engine-free checks of the field analysis on a synthetic map: two
// land masses joined by an isthmus, a sea above it with a gentle west shore
// and a cliff east shore, a pond below it, one start box per side. Asserts the
// structural promises (every cell in one region, boundaries join two regions,
// avenues have spines), the expected theatres, the shore kinds, a choke on the
// isthmus, determinism across two runs, and the file header round trip.
//
//   x86_64-w64-mingw32-g++ -std=c++20 -O1 -Wall -Wextra -I src -I src/circuit tests/field_analysis_test.cpp
//       src/circuit/terrain/field/FieldAnalysis.cpp src/circuit/terrain/field/FieldEncode.cpp -o field_analysis_test.exe

#include "circuit/terrain/field/FieldAnalysis.h"
#include "circuit/terrain/field/FieldCorridors.h"
#include "circuit/terrain/field/FieldEncode.h"
#include "circuit/terrain/field/FieldGrid.h"
#include "circuit/terrain/field/FieldLandmarks.h"
#include "circuit/terrain/field/FieldSettings.h"
#include "json/json.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <map>
#include <stdexcept>
#include <vector>

using namespace circuit::field;

static void Require(bool value, const char* message)
{
	if (!value) throw std::runtime_error(message);
}

// 4096 x 3072 elmos: 512 x 384 height samples (8 elmo), 256 x 192 slope samples.
static SInput Synthetic()
{
	SInput in;
	in.mapName = "Synthetic Isthmus";
	in.mapWidth = 4096; in.mapHeight = 3072;
	in.heightStride = in.mapWidth / 8; in.heightRows = in.mapHeight / 8;
	in.slopeStride = in.mapWidth / 16; in.slopeRows = in.mapHeight / 16;
	in.height.assign((std::size_t)in.heightStride * in.heightRows, 0.f);
	in.slope.assign((std::size_t)in.slopeStride * in.slopeRows, 0.f);
	auto heightAt = [&](float x, float z) -> float {
		// Sea: z < 1100 across the whole width, 60 deep in the middle, shelving.
		// Land: z >= 1100. Isthmus: between x 1800..2300 the land is only z 1300..1800;
		// elsewhere land spans z 1100..3072. Pond: a 300x300 hole at (3200..3500, 2400..2700).
		const bool isthmusColumn = x >= 1800.f && x < 2300.f;
		if (z < 1100.f) {
			const float depth = 60.f * std::min(1.f, (1100.f - z) / 300.f);
			return -std::max(10.f, depth);
		}
		if (isthmusColumn && (z < 1300.f || z >= 1800.f)) return -40.f;   // water gaps either side of the bridge
		if (x >= 3200.f && x < 3500.f && z >= 2400.f && z < 2700.f) return -40.f;   // pond
		return 40.f;
	};
	for (int z = 0; z < in.heightRows; ++z) {
		for (int x = 0; x < in.heightStride; ++x) {
			in.height[(std::size_t)z * in.heightStride + x] = heightAt(x * 8.f + 4.f, z * 8.f + 4.f);
		}
	}
	// Shore slopes: the west half of the sea shore (x < 2048, z 1100..1180) is a
	// beach (10 degrees); the east half is a cliff (70 degrees). Everywhere else flat.
	for (int z = 0; z < in.slopeRows; ++z) {
		for (int x = 0; x < in.slopeStride; ++x) {
			const float ex = x * 16.f + 8.f, ez = z * 16.f + 8.f;
			float deg = 0.f;
			if (ez >= 1060.f && ez < 1200.f && !(ex >= 1800.f && ex < 2300.f)) deg = ex < 2048.f ? 10.f : 70.f;
			in.slope[(std::size_t)z * in.slopeStride + x] = SlopeValue(deg);
		}
	}
	SBoxInput west; west.allyTeam = 0; west.left = 200.f; west.right = 900.f; west.top = 1800.f; west.bottom = 2600.f;
	SBoxInput east; east.allyTeam = 1; east.left = 3200.f; east.right = 3900.f; east.top = 1400.f; east.bottom = 2200.f;
	in.boxes = {west, east};
	in.geos.push_back({600.f, 2000.f});
	in.clusters.push_back({3600.f, 1600.f, 6.f});
	// Part B1: four placed-in-game teams per side, wind 4-12, tidal 18
	for (int t = 0; t < 8; ++t) {
		STeamInput ti;
		ti.team = t; ti.allyTeam = t < 4 ? 0 : 1;
		in.teams.push_back(ti);
	}
	in.minWind = 4.f; in.maxWind = 12.f; in.tidal = 18.f;
	return in;
}

static SSettings MarkSettings()
{
	SSettings st;
	const char* ids[_OPENINGS_][3] = {{"armlab", "corlab", "leglab"}, {"armvp", "corvp", "legvp"}, {"armhp", "corhp", "leghp"},
		{"armsy", "corsy", "legsy"}, {"armap", "corap", "legap"}};
	for (int c = 0; c < _OPENINGS_; ++c) for (int f = 0; f < 3; ++f) st.marks.factories[c][f] = ids[c][f];
	st.marks.second[L_SEA] = "T2 shipyard";
	st.marks.metalScale = 1.f;   // the synthetic clusters are already in metal per second
	return st;
}

static int CountKind(const SModel& m, int theatreKind)
{
	int n = 0;
	for (const STheatre& t : m.theatres) if (t.kind == theatreKind) ++n;
	return n;
}

static int CountBoundary(const SModel& m, int kind)
{
	int n = 0;
	for (const SBoundary& b : m.boundaries) if (b.kind == kind) ++n;
	return n;
}

static void TestStructure()
{
	const SInput in = Synthetic();
	SSettings st;
	std::atomic<bool> cancel{false};
	auto m = Analyse(in, st, &cancel);
	for (const std::string& f : m->checkFailures) std::printf("field_analysis_test: check failed: %s\n", f.c_str());
	std::printf("field_analysis_test: %s\n", Summary(*m).c_str());
	Require(m->checkFailures.empty(), "internal checks pass");
	Require(m->gw == 128 && m->gh == 96, "grid is 128 x 96 cells");
	Require((int)m->regionOf.size() == m->gw * m->gh, "a region per cell");
	for (int r : m->regionOf) Require(r >= 0 && r < (int)m->regions.size(), "every cell has a valid region");
	// D-326: a ground class per cell; the synthetic map has sailable water, flat land and a steep shore
	Require((int)m->groundOf.size() == m->gw * m->gh, "a ground class per cell");
	{
		int deep = 0, flat = 0, hard = 0;
		for (unsigned char gnd : m->groundOf) {
			Require(gnd <= G_HARM, "every cell has a valid ground class");
			if (gnd == G_DEEP) ++deep; else if (gnd == G_FLAT) ++flat; else if (gnd == G_STEEP || gnd == G_CLIFF) ++hard;
		}
		Require(deep > 0 && flat > 0 && hard > 0, "ground classes: deep water, flat land and steep ground all present");
	}
	Require(CountKind(*m, T_LAND) == 1, "one land theatre (both halves joined by the isthmus)");
	// the north sea and the bay south of the isthmus both touch both sides: seas
	Require(CountKind(*m, T_SEA) == 2, "two seas");
	Require(CountKind(*m, T_POND) == 1, "one pond");
	Require(m->sides.size() == 2, "two sides");
	Require(m->regions.size() >= 3, "the land is cut into regions");
	Require(!m->chokes.empty(), "the isthmus gives at least one choke");
	Require(m->accessOf.size() == m->groundOf.size(), "access mask covers exactly the terrain grid");
	Require(CountBoundary(*m, B_RAMP) == 0, "flat watershed contacts are not ramps");
	bool qualifiedPassage = false;
	for (const SChoke& c : m->passages) if (c.qualified && (c.classMask & (1 << C_VEH))) {
		qualifiedPassage = true;
		Require(std::abs(std::hypot(c.endA.x-c.endB.x,c.endA.z-c.endB.z)-c.width)<1.f, "width matches fitted endpoints");
		Require(c.width > 350.f && c.width < 700.f, "known isthmus width is locally measured");
	}
	Require(qualifiedPassage, "real isthmus constriction remains qualified");
	bool isthmusChoke = false;
	for (const SChoke& c : m->chokes) {
		if (c.pos.x >= 1700.f && c.pos.x <= 2400.f && c.pos.z >= 1250.f && c.pos.z <= 1850.f) isthmusChoke = true;
	}
	Require(isthmusChoke, "a choke lies on the isthmus");
	for (const SBoundary& b : m->boundaries) {
		std::printf("  boundary %d kind=%d a=%d b=%d steep=%.0f width=%.0f mid=(%.0f,%.0f) mask=%d\n", b.id, b.kind, b.a, b.b,
			b.steepestDeg, b.width, b.line[b.line.size() / 2].x, b.line[b.line.size() / 2].z, b.classMask);
	}
	for (const SRegion& r : m->regions) {
		std::printf("  region %d theatre=%d(kind %d) cells=%d label=(%.0f,%.0f) meanH=%.0f\n", r.id, r.theatre,
			m->theatres[r.theatre].kind, r.cells, r.label.x, r.label.z, r.meanH);
	}
	Require(CountBoundary(*m, B_BEACH) >= 1, "the gentle west shore is a beach");
	Require(CountBoundary(*m, B_SHEER) >= 1, "the steep east shore is sheer");
	bool beachWest = true, sheerEast = true;
	for (const SBoundary& b : m->boundaries) {
		const float x = b.line[b.line.size() / 2].x, z = b.line[b.line.size() / 2].z;
		if (z > 1400.f) continue;   // only the north sea's shore carries the slope bands
		if (b.kind == B_BEACH && x > 2340.f) beachWest = false;   // the gap's east wall sits at x 2300
		if (b.kind == B_SHEER && x < 1800.f) sheerEast = false;
	}
	Require(beachWest && sheerEast, "shore kinds follow the slopes");
	Require(!m->landings.empty(), "beaches are landings");
	for (const SLanding& l : m->landings) {
		const bool sea = m->theatres[l.sea].kind == T_SEA;
		Require(l.side >= 0 && (sea ? l.rank >= 1 : l.rank == 0), "sea landings are ranked per side, pond shores are not");
	}
	Require(!m->avenues.empty(), "an avenue joins the two sides");
	for (const SAvenue& a : m->avenues) {
		Require(a.spine.size() >= 2, "avenue spine");
		Require(!a.regions.empty(), "avenue regions");
	}
	Require(!m->standoffs.empty(), "standoff contours in the sea");
	bool geo = false, metal = false, pond = false;
	for (const SKey& k : m->keys) { geo |= k.kind == K_GEO; metal |= k.kind == K_METAL; pond |= k.kind == K_POND; }
	Require(geo && metal && pond, "key terrain: geo, metal, pond");
	for (const STheatre& t : m->theatres) {
		if (t.kind == T_SEA) Require(t.holders == 3, "both sides hold each sea");
	}
	for (const SAvenue& a : m->avenues) {
		Require(a.spine.front().x < 1000.f && a.spine.back().x > 3000.f, "avenue spines run from the west box to the east box");
	}
	std::printf("field_analysis_test: %s\n", Summary(*m).c_str());
	std::printf("field_analysis_test: %.1f ms total\n", m->timings.totalMs);
}

static void TestDeterminismAndFile()
{
	const SInput in = Synthetic();
	SSettings st;
	auto a = Analyse(in, st, nullptr);
	auto b = Analyse(in, st, nullptr);
	Require(a->fingerprint == b->fingerprint, "same input, same fingerprint");
	Require(a->regionOf == b->regionOf, "same input, same regions");
	const std::string text = Encode(*a, st, 7, 120);
	SHeader h;
	Require(ParseHeader(text, h), "header parses");
	Require(h.format == kFileFormat && h.gw == a->gw && h.gh == a->gh && h.cell == a->cell, "header fields");
	Require(h.seq == 7 && h.frame == 120 && h.fingerprint == a->fingerprint && h.complete, "header seq, frame, fingerprint, trailer");
	Require(h.mapName == "Synthetic Isthmus", "header map name");
	Require(text.find("\ncells|") != std::string::npos, "cells record");
	Require(text.find("\nground|") != std::string::npos, "ground record");
	Require(text.find("\nlanding|") != std::string::npos, "landing record");
	Require(text.find("\navenue|") != std::string::npos, "avenue record");
	SHeader torn;
	Require(ParseHeader(text.substr(0, text.size() - 3), torn) && !torn.complete, "a torn file is incomplete");
	std::printf("field_analysis_test: file %zu bytes\n", text.size());
}

// Part B1: positions, territory, labels, openings and landmarks on the
// synthetic isthmus; predicted and script positions; the landmarks file.
static void TestMarks()
{
	const SInput in = Synthetic();
	const SSettings st = MarkSettings();
	auto m = Analyse(in, st, nullptr);
	for (const std::string& f : m->marksFailures) std::printf("field_analysis_test: marks check failed: %s\n", f.c_str());
	std::printf("field_analysis_test: %s\n", MarksSummary(*m).c_str());
	Require(m->marksBuilt && m->marksFailures.empty(), "marks: built, checks pass");
	Require(m->positions.size() == 8, "marks: one position per playing team");
	int perSide[2] = {0, 0}, air[2] = {0, 0}, tech[2] = {0, 0};
	std::map<std::pair<int, int>, int> seaPerSea;
	for (const SPosition& p : m->positions) {
		std::printf("  %s side=%d at (%.0f,%.0f) label=%s/%s share=%.2f opening=%s energy=%s veh=%.2f width=%.0f yard=%.0f geo=%.0f pond=%d island=%d cells=%d\n",
			p.name.c_str(), p.side, p.pos.x, p.pos.z, LabelName(p.label), SubLabelName(p.sub), p.frontShare, OpeningName(p.opening), EnergyName(p.energy),
			p.f.vehShare, p.f.openWidth, p.f.yardDist, p.f.geoDist, p.f.pondCells, p.f.island ? 1 : 0, p.f.cells);
		for (const std::string& r : p.reasons) std::printf("      why: %s\n", r.c_str());
		Require(p.side == 0 || p.side == 1, "marks: a position belongs to a side");
		Require(p.predicted, "marks: no script start, so every position is predicted");
		Require(p.f.cells > 0, "marks: every position has a territory");
		Require(!p.reasons.empty(), "marks: every opening has a reason");
		Require(p.label >= 0 && p.label < _LABELS_ && p.opening >= 0 && p.opening < _OPENINGS_, "marks: valid label and opening");
		Require(m->sideOf[p.cell] == p.side, "marks: a position stands on its own side");
		++perSide[p.side];
		if (p.label == L_AIR) ++air[p.side];
		if (p.label == L_TECH) ++tech[p.side];
		if (p.label == L_SEA) ++seaPerSea[{p.side, p.f.sea}];
		if (p.label == L_SEA) Require(p.opening == O_SHIP, "marks: a sea position with a yard site opens the shipyard");
		if (p.label == L_POND) Require(p.opening == O_VEH, "marks: a pond position opens the vehicle plant");
		if (p.label == L_AIR) Require(p.opening == O_AIR, "marks: the air position opens the air plant");
	}
	Require(perSide[0] == 4 && perSide[1] == 4, "marks: four positions per side");
	Require(air[0] == 1 && air[1] == 1, "marks: one air position per side");
	Require(tech[0] <= 1 && tech[1] <= 1, "marks: at most one tech per side");
	for (const auto& kv : seaPerSea) Require(kv.second <= 1, "marks: at most one sea position per sea per side");
	bool anySea = false;
	for (const SPosition& p : m->positions) anySea |= p.label == L_SEA;
	Require(anySea, "marks: the north sea gives a sea position");
	for (int c = 0; c < (int)m->posOf.size(); ++c) {
		const int p = m->posOf[c];
		Require(p >= 0 && p < (int)m->positions.size() && m->positions[p].side == m->sideOf[c], "marks: every cell belongs to a position of its side");
	}
	for (int s = 0; s < 2; ++s) {
		int expect = 1;
		for (const SPosition& p : m->positions) {
			if (p.side != s) continue;
			Require(p.n == expect, "marks: positions numbered from the rear");
			++expect;
		}
	}
	int kinds[_MARK_KINDS_] = {};
	for (const SMark& mk : m->marks) {
		std::printf("  mark %s/%s at (%.0f,%.0f) value=%.1f pos=%d ally=%d contested=%d labelled=%d: %s\n", MarkGroupName(mk.group), MarkKindName(mk.kind),
			mk.pos.x, mk.pos.z, mk.value, mk.position, mk.allyTeam, mk.contested ? 1 : 0, mk.labelled ? 1 : 0, mk.reason.c_str());
		Require(mk.kind >= 0 && mk.kind < _MARK_KINDS_ && !mk.reason.empty(), "marks: valid kind and reason");
		++kinds[mk.kind];
	}
	Require(kinds[MK_GEO] == 1 && kinds[MK_METAL] + kinds[MK_CENTRE] == 1, "marks: the geo and the metal cluster are marked");
	Require(kinds[MK_TIDAL] == 1, "marks: the pond is a tidal field");
	Require(kinds[MK_SEAZONE] >= 1, "marks: a contested sea gets a sea control zone");
	Require(kinds[MK_LANDING] >= 1, "marks: ranked sea landings are marked");
	Require(kinds[MK_CHOKE] + kinds[MK_KILL] >= 1, "marks: the isthmus choke is marked");
	Require(kinds[MK_ANTINUKE] >= 1, "marks: an anti-nuke district per side");
	// determinism and the file
	auto again = Analyse(in, st, nullptr);
	Require(again->marksFingerprint == m->marksFingerprint && again->posOf == m->posOf, "marks: same input, same marks");
	const std::string text = EncodeMarks(*m, st, 3, 90);
	Require(text.compare(0, 12, "barbmarks|1|") == 0, "marks file: header");
	Require(text.find("|" + std::to_string(m->fingerprint) + "|") != std::string::npos, "marks file: carries the field fingerprint");
	Require(text.find("\nfactory|bot|armlab|corlab|leglab\n") != std::string::npos, "marks file: factory ids from the settings");
	Require(text.find("\nposition|") != std::string::npos && text.find("\nopening|") != std::string::npos
		&& text.find("\nmark|") != std::string::npos && text.find("\nterritory|") != std::string::npos, "marks file: records");
	Require(text.size() > 8 && text.compare(text.size() - 6, 6, "end|3\n") == 0, "marks file: trailer");
	std::printf("field_analysis_test: marks file %zu bytes, marks %.1f ms\n", text.size(), m->timings.marksTotalMs);
	// the engine reports geo vents in a varying order: the marks must not depend on it
	SInput twoGeos = in;
	twoGeos.geos.push_back({3700.f, 1800.f});
	SInput swapped = twoGeos;
	std::reverse(swapped.geos.begin(), swapped.geos.end());
	Require(Analyse(twoGeos, st, nullptr)->marksFingerprint == Analyse(swapped, st, nullptr)->marksFingerprint, "marks: geo input order does not matter");
	// script starts are kept exactly; the remaining teams are predicted around them
	SInput placed = in;
	placed.teams[0].known = true; placed.teams[0].x = 500.f; placed.teams[0].z = 2400.f;
	placed.teams[5].known = true; placed.teams[5].x = 3700.f; placed.teams[5].z = 2000.f;
	auto mp = Analyse(placed, st, nullptr);
	int script = 0;
	for (const SPosition& p : mp->positions) {
		if (p.predicted) continue;
		++script;
		Require((p.pos.x == 500.f && p.pos.z == 2400.f) || (p.pos.x == 3700.f && p.pos.z == 2000.f), "marks: a script start is kept exactly");
	}
	Require(script == 2 && mp->positions.size() == 8, "marks: script starts plus predictions");
	// no team list: one position per side; disabled: nothing built and the terrain unchanged
	SInput none = in;
	none.teams.clear();
	auto mn = Analyse(none, st, nullptr);
	Require(mn->positions.size() == 2, "marks: no team list gives one position per side");
	SSettings off = st;
	off.marks.enabled = false;
	auto mo = Analyse(in, off, nullptr);
	Require(!mo->marksBuilt && mo->positions.empty() && mo->fingerprint == m->fingerprint, "marks: disabled leaves the terrain unchanged");
}

static void TestCancel()
{
	const SInput in = Synthetic();
	SSettings st;
	std::atomic<bool> cancel{true};
	bool thrown = false;
	try { Analyse(in, st, &cancel); } catch (const Cancelled&) { thrown = true; }
	Require(thrown, "a set cancel flag stops the analysis");
}

static void TestNoBoxes()
{
	SInput in = Synthetic();
	in.boxes.clear();
	SSettings st;
	auto m = Analyse(in, st, nullptr);
	Require(m->sides.size() == 2 && m->sides[0].allyTeam == -1, "no boxes: two synthetic sides");
	Require(m->checkFailures.empty(), "no boxes: checks pass");
}

// Replay mode: analyse a dumped input (field/input.bin written with
// field.json "dump_input": true) and print the summary and timings; with a
// second argument, also write the widget file. The map's real analysis can
// then be tuned without a game.
static int Replay(const char* dumpPath, const char* outPath, bool predict, const char* configPath)
{
	std::FILE* f = std::fopen(dumpPath, "rb");
	if (f == nullptr) { std::cerr << "cannot open " << dumpPath << "\n"; return 2; }
	std::vector<char> raw;
	char buf[65536];
	for (std::size_t got; (got = std::fread(buf, 1, sizeof(buf), f)) > 0;) raw.insert(raw.end(), buf, buf + got);
	std::fclose(f);
	std::size_t at = 0;
	auto getI = [&]() { int v = 0; if (at + 4 <= raw.size()) std::memcpy(&v, raw.data() + at, 4); at += 4; return v; };
	auto getF = [&]() { float v = 0.f; if (at + 4 <= raw.size()) std::memcpy(&v, raw.data() + at, 4); at += 4; return v; };
	const bool v2 = raw.size() >= 4 && std::memcmp(raw.data(), "FLD2", 4) == 0;
	if (raw.size() < 4 || (!v2 && std::memcmp(raw.data(), "FLD1", 4) != 0)) { std::cerr << "not a field dump\n"; return 2; }
	at = 4;
	SInput in;
	in.mapWidth = getI(); in.mapHeight = getI(); in.heightStride = getI(); in.heightRows = getI();
	in.slopeStride = getI(); in.slopeRows = getI(); in.waterHarmful = getI() != 0;
	const int boxes = getI(), geos = getI(), clusters = getI();
	const int heights = getI();
	in.height.resize(std::max(0, heights));
	for (int i = 0; i < heights; ++i) in.height[i] = getF();
	const int slopes = getI();
	in.slope.resize(std::max(0, slopes));
	for (int i = 0; i < slopes; ++i) in.slope[i] = getF();
	for (int i = 0; i < boxes; ++i) {
		SBoxInput b;
		b.allyTeam = getI(); b.left = getF(); b.right = getF(); b.top = getF(); b.bottom = getF();
		in.boxes.push_back(b);
	}
	for (int i = 0; i < geos; ++i) { SPoint p; p.x = getF(); p.z = getF(); in.geos.push_back(p); }
	for (int i = 0; i < clusters; ++i) { SClusterInput c; c.x = getF(); c.z = getF(); c.income = getF(); in.clusters.push_back(c); }
	const int nameLen = getI();
	if (nameLen > 0 && at + nameLen <= raw.size()) in.mapName.assign(raw.data() + at, nameLen);
	at += std::max(0, nameLen);
	if (v2) {
		in.minWind = getF(); in.maxWind = getF(); in.tidal = getF();
		const int teams = getI();
		for (int i = 0; i < teams && at < raw.size(); ++i) {
			STeamInput t;
			t.team = getI(); t.allyTeam = getI(); t.known = getI() != 0; t.x = getF(); t.z = getF();
			in.teams.push_back(t);
		}
	}
	SSettings st = MarkSettings();
	st.marks.metalScale = 0.001f;   // a real dump: the engine's spot values
	if (configPath != nullptr) {
		// the profile's field.json (comments allowed): the same reader as CFieldService
		std::ifstream cfg(configPath);
		Json::Value root;
		Json::Reader reader;
		if (!cfg || !reader.parse(cfg, root)) { std::cerr << "cannot read " << configPath << "\n"; return 2; }
		st.marks = SMarkSettings();
		ReadMarkSettings(root, st.marks);
	}
	std::vector<STeamInput> actual = in.teams;
	if (predict) for (STeamInput& t : in.teams) t.known = false;
	auto m = Analyse(in, st, nullptr);
	std::printf("%s\n%s\n", in.mapName.c_str(), Summary(*m).c_str());
	const STimings& t = m->timings;
	std::printf("timings ms: total=%.1f grid=%.1f mobility=%.1f sides=%.1f theatres=%.1f regions=%.1f boundaries=%.1f landings=%.1f avenues=%.1f key=%.1f\n",
		t.totalMs, t.gridMs, t.mobilityMs, t.sidesMs, t.theatresMs, t.regionsMs, t.boundariesMs, t.landingsMs, t.avenuesMs, t.keyMs);
	for (const STheatre& th : m->theatres) std::printf("theatre %d %s kind=%d cells=%d holders=%d\n", th.id, th.name.c_str(), th.kind, th.cells, th.holders);
	for (const SRegion& r : m->regions) {
		std::printf("region %d theatre=%d char=%d cells=%d medianW=%.0f meanH=%.0f label=(%.0f,%.0f)\n", r.id, r.theatre, r.character, r.cells, r.medianWidth, r.meanH, r.label.x, r.label.z);
	}
	for (const SChoke& c : m->chokes) std::printf("choke %d %d-%d at (%.0f,%.0f) width=%.0f\n", c.id, c.a, c.b, c.pos.x, c.pos.z, c.width);
	for (const SAvenue& a : m->avenues) std::printf("avenue %d %s length=%.0f regions=%zu\n", a.id, a.name.c_str(), a.length, a.regions.size());
	for (const SCorridor& c : m->corridors) std::printf("corridor %d cls=%d %s length=%.0f narrowest=%.0f at (%.0f,%.0f) mean=%.0f routes=%d specialist=%d vertices=%zu\n", c.id, c.cls, c.name.c_str(), c.length, c.narrowest, c.choke.x, c.choke.z, c.meanWidth, c.routes, c.specialist ? 1 : 0, c.centre.size());
	std::printf("corridors: %zu, obstacles: %zu, corridors_ms=%.1f\n", m->corridors.size(), m->obstacles.size(), m->timings.corridorsMs);
	for (const SLanding& l : m->landings) {
		if (l.rank <= 3) std::printf("landing %d kind=%d side=%d rank=%d width=%.0f inland=%.0f at (%.0f,%.0f)\n", l.id, l.kind, l.side, l.rank, l.width, l.inland, l.mid.x, l.mid.z);
	}
	for (const std::string& s : m->checkFailures) std::printf("CHECK FAILED: %s\n", s.c_str());
	if (m->marksBuilt) {
		std::printf("marks: %s (%.1f ms)\n", MarksSummary(*m).c_str(), m->timings.marksTotalMs);
		for (const SPosition& p : m->positions) {
			std::printf("position %s label=%s/%s share=%.2f opening=%s energy=%s veh=%.2f width=%.0f\n", p.name.c_str(), LabelName(p.label),
				SubLabelName(p.sub), p.frontShare, OpeningName(p.opening), EnergyName(p.energy), p.f.vehShare, p.f.openWidth);
		}
		for (const std::string& s : m->marksFailures) std::printf("MARKS CHECK FAILED: %s\n", s.c_str());
		if (predict) {
			// greedy nearest matching of predictions to the real starts, per ally team
			std::vector<char> used(actual.size(), 0);
			int within575 = 0, beyond1150 = 0, matched = 0;
			float worst = 0.f, sum = 0.f;
			for (const SPosition& p : m->positions) {
				int best = -1;
				float bestD = 1e30f;
				for (int i = 0; i < (int)actual.size(); ++i) {
					if (used[i] || !actual[i].known || (p.allyTeam >= 0 && actual[i].allyTeam != p.allyTeam)) continue;
					const float d = std::hypot(actual[i].x - p.pos.x, actual[i].z - p.pos.z);
					if (d < bestD) { bestD = d; best = i; }
				}
				if (best < 0) continue;
				used[best] = 1;
				++matched; sum += bestD; worst = std::max(worst, bestD);
				if (bestD <= 575.f) ++within575;
				if (bestD > 1150.f) ++beyond1150;
				std::printf("predict %s at (%.0f,%.0f) nearest real start (%.0f,%.0f) %.0f\n", p.name.c_str(), p.pos.x, p.pos.z, actual[best].x, actual[best].z, bestD);
			}
			std::printf("PREDICT %s matched=%d within575=%d beyond1150=%d mean=%.0f worst=%.0f\n", in.mapName.c_str(), matched, within575, beyond1150,
				matched > 0 ? sum / matched : 0.f, worst);
		}
	}
	if (outPath != nullptr) {
		const std::string text = Encode(*m, st, 1, 0);
		std::FILE* o = std::fopen(outPath, "wb");
		if (o != nullptr) { std::fwrite(text.data(), 1, text.size(), o); std::fclose(o); std::printf("wrote %s (%zu bytes)\n", outPath, text.size()); }
		if (m->marksBuilt) {
			const std::string marks = EncodeMarks(*m, st, 1, 0);
			const std::string marksPath = std::string(outPath) + ".marks";
			std::FILE* mo = std::fopen(marksPath.c_str(), "wb");
			if (mo != nullptr) { std::fwrite(marks.data(), 1, marks.size(), mo); std::fclose(mo); std::printf("wrote %s (%zu bytes)\n", marksPath.c_str(), marks.size()); }
		}
	}
	return m->checkFailures.empty() ? 0 : 1;
}

static void TestExperienceSemantics()
{
	auto in = Synthetic();
	for (int z=0;z<in.heightRows;++z) for (int x=0;x<in.heightStride;++x) {
		float& height=in.height[z*in.heightStride+x];
		if (height>0.f) height+=std::clamp((x*8.f-2050.f)*0.5f,0.f,128.f);
	}
	for (int z=0;z<in.slopeRows;++z) for (int x=0;x<in.slopeStride;++x)
		if (x*16>=2050 && x*16<=2500 && z*16>=1300 && z*16<1800)
			in.slope[z*in.slopeStride+x]=SlopeValue(10.f);
	auto m=Analyse(in,SSettings{},nullptr);
	Require(CountBoundary(*m,B_RAMP)>0,"a real local elevation transition remains a ramp");
	for (int mask:m->accessOf) if (mask & (1<<7))
		Require((mask & (1<<C_SHIP)) && (mask & (1<<C_SUB)),"deep draft is a subset of shallower naval access");
	const std::string file=Encode(*m,SSettings{},1,0);
	Require(file.find("experience|2|initial-map")!=std::string::npos,"experience capability exported");
	Require(file.find("access|")!=std::string::npos && file.find("site|")!=std::string::npos,"access surfaces and evidence sites exported");
	std::fill(in.height.begin(),in.height.end(),40.f);
	std::fill(in.slope.begin(),in.slope.end(),0.f);
	m=Analyse(in,SSettings{},nullptr);
	Require(CountBoundary(*m,B_RAMP)==0 && m->passages.empty(),"an open plain has no physical ramps or constrictions");
}


// D-358: the corridor planner. The isthmus gives one bot corridor whose centre
// crosses the bridge; a plain with two mesa columns gives three bot corridors
// (north, between the columns, south); the queries answer at the table's
// resolution; the same input gives the same table.
static SInput ObstacleField(bool columns = true)
{
	SInput in;
	in.mapName = "Synthetic Obstacle Field";
	in.mapWidth = 4096; in.mapHeight = 3072;
	in.heightStride = in.mapWidth / 8; in.heightRows = in.mapHeight / 8;
	in.slopeStride = in.mapWidth / 16; in.slopeRows = in.mapHeight / 16;
	in.height.assign((std::size_t)in.heightStride * in.heightRows, 40.f);
	in.slope.assign((std::size_t)in.slopeStride * in.slopeRows, 0.f);
	// two mesa columns at x 1700..2000 and 2300..2600 from z 600 to 2472, each with a
	// 600-elmo gap in the middle (z 1236..1836): open bands north and south of them
	auto mesa = [&](float x, float z) {
		const bool column = (x >= 1700.f && x < 2000.f) || (x >= 2300.f && x < 2600.f);
		return columns && column && z >= 600.f && z < 2472.f && !(z >= 1236.f && z < 1836.f);
	};
	for (int z = 0; z < in.slopeRows; ++z) for (int x = 0; x < in.slopeStride; ++x) {
		if (mesa(x * 16.f + 8.f, z * 16.f + 8.f)) in.slope[(std::size_t)z * in.slopeStride + x] = SlopeValue(75.f);
	}
	SBoxInput west; west.allyTeam = 0; west.left = 200.f; west.right = 900.f; west.top = 400.f; west.bottom = 2600.f;
	SBoxInput east; east.allyTeam = 1; east.left = 3200.f; east.right = 3900.f; east.top = 400.f; east.bottom = 2600.f;
	in.boxes = {west, east};
	for (int t = 0; t < 4; ++t) { STeamInput ti; ti.team = t; ti.allyTeam = t < 2 ? 0 : 1; in.teams.push_back(ti); }
	return in;
}

// Does the polyline pass through the rectangle? Sampled every 16 elmos along
// each segment: the centre is simplified, so a straight run across the
// rectangle may have no vertex inside it.
static bool PolylineVisits(const Polyline& line, float x0, float x1, float z0, float z1)
{
	for (std::size_t i = 1; i < line.size(); ++i) {
		const SPoint& a = line[i - 1]; const SPoint& b = line[i];
		const float len = std::hypot(b.x - a.x, b.z - a.z);
		const int steps = std::max(1, (int)(len / 16.f));
		for (int k = 0; k <= steps; ++k) {
			const float t = (float)k / steps, x = a.x + (b.x - a.x) * t, z = a.z + (b.z - a.z) * t;
			if (x >= x0 && x < x1 && z >= z0 && z < z1) return true;
		}
	}
	return false;
}

static int CorridorCount(const SModel& m, int cls)
{
	int n = 0;
	for (const SCorridor& c : m.corridors) if (c.cls == cls) ++n;
	return n;
}
// Passages: lanes of one passage (D-360) count once.
static int PassageCount(const SModel& m, int cls)
{
	int n = 0;
	for (const SCorridor& c : m.corridors) if (c.cls == cls && c.lane == 0) ++n;
	return n;
}

static void TestCorridors()
{
	SSettings st;
	// the isthmus: every land class crosses by the bridge, ships have no corridor between the land boxes
	{
		const SInput in = Synthetic();
		auto m = Analyse(in, st, nullptr);
		for (const std::string& f : m->checkFailures) std::printf("field_analysis_test: check failed: %s\n", f.c_str());
		Require(m->checkFailures.empty(), "corridor checks pass on the isthmus");
		Require(CorridorCount(*m, C_BOT) >= 1, "the isthmus has a bot corridor");
		const SCorridor* bridge = nullptr;
		for (const SCorridor& c : m->corridors) if (c.cls == C_BOT && !c.specialist) { bridge = &c; break; }
		Require(bridge != nullptr, "a bot corridor wide enough for a formation");
		Require(PolylineVisits(bridge->centre, 1800.f, 2300.f, 1300.f, 1800.f), "the bot corridor's centre crosses the bridge");
		Require(bridge->narrowest > 0.f && bridge->narrowest <= 600.f, "the narrowest point is the bridge's width (500 elmos of land)");
		Require(bridge->choke.x >= 1700.f && bridge->choke.x < 2400.f, "the choke lies on the bridge");
		Require(bridge->length > 2000.f, "the corridor runs from box to box");
		Require(bridge->width.size() == bridge->centre.size(), "a width per centre vertex");
		Require(CorridorAt(*m, C_BOT, 500.f, 2200.f) == bridge->id, "the west box's land belongs to the bridge corridor");
		Require(CorridorAt(*m, C_BOT, 2048.f, 500.f, 0) == -1, "sea cells belong to no bot corridor");
		Require(CorridorAt(*m, C_SHIP, 2048.f, 500.f) == -1, "no ship corridor between two land boxes");
		float d = 0.f;
		const float pw = CorridorProgress(*bridge, 500.f, 2200.f, &d), pe = CorridorProgress(*bridge, 3600.f, 1800.f, &d);
		Require(pw < 0.35f && pe > 0.65f, "progress runs from side 0 (west) to side 1 (east)");
		Require(CorridorProgressFrom(*bridge, 1, 500.f, 2200.f) > 0.65f, "seen from side 1 the west end is far");
		const SPoint mid = CorridorPoint(*bridge, 0.5f);
		Require(mid.x > 1200.f && mid.x < 3000.f, "the midpoint lies in the middle third");
		const auto ordered = CorridorsOrdered(*m, C_BOT, {500.f, 2200.f}, {3600.f, 1800.f}, 0.f);
		Require(!ordered.empty() && ordered.front() == bridge->id, "the ordered list names the bridge");
		// D-359: the approach legs are routed over the corridor's open cells
		int v = -1;
		const auto leg = RouteToCentre(*m, C_BOT, {300.f, 2900.f}, *bridge, &v);
		Require(!leg.empty() && v >= 0 && v < (int)bridge->centre.size(), "a route from the west box's far corner reaches a centre vertex");
		for (const SPoint& p : leg) Require(CorridorAt(*m, C_BOT, p.x, p.z, 0) >= 0, "every leg point stands on open ground");
		for (std::size_t i = 1; i < leg.size(); ++i) {
			const int cx = (int)(leg[i].x / m->cell), cz = (int)(leg[i].z / m->cell);
			Require(m->clearanceOf[C_BOT][(std::size_t)cz * m->gw + cx] > 0, "a leg keeps off cells with a closed 16-elmo quarter after its first");
		}
		for (std::size_t i = 1; i < leg.size(); ++i) {
			const float len = std::hypot(leg[i].x - leg[i - 1].x, leg[i].z - leg[i - 1].z);
			const int steps = std::max(1, (int)(len / 16.f));
			for (int k = 0; k <= steps; ++k) {
				const float t = (float)k / steps;
				Require(CorridorAt(*m, C_BOT, leg[i - 1].x + (leg[i].x - leg[i - 1].x) * t, leg[i - 1].z + (leg[i].z - leg[i - 1].z) * t, 0) >= 0,
					"no leg segment crosses closed ground");
			}
		}
		const SPoint reached = bridge->centre[(std::size_t)v];
		Require(std::hypot(leg.back().x - reached.x, leg.back().z - reached.z) <= 1.5f * 32.f, "the leg ends at the vertex it reached");
		int none = -1;
		Require(RouteToCentre(*m, C_BOT, {2048.f, 300.f}, *bridge, &none, 2).empty() && none == -1, "from the open sea, far from land, no route");
		Require(RouteToCentre(*m, C_SHIP, {300.f, 2900.f}, *bridge, &none).empty(), "a ship has no route to a bot corridor");
		const std::string text = Encode(*m, st, 1, 1);
		Require(text.find("\ncorridor|") != std::string::npos, "corridor record");
        Require(text.find("\ncorridorcells|1|") != std::string::npos, "bot ownership raster exported");
        Require(text.find("\nclearance|1|") != std::string::npos, "bot conservative clearance exported");
		Require(Summary(*m).find("corridors") != std::string::npos, "summary counts corridors");
	}
	// the open field (D-360): one passage about 2,700 elmos wide holds lanes side by side
	{
		const SInput in = ObstacleField(false);
		auto m = Analyse(in, st, nullptr);
		for (const std::string& f : m->checkFailures) std::printf("field_analysis_test: check failed: %s\n", f.c_str());
		Require(m->checkFailures.empty(), "corridor checks pass on the open field");
		const auto ordered = CorridorsOrdered(*m, C_BOT, {500.f, 1536.f}, {3600.f, 1536.f}, 0.f);
		Require(ordered.size() == (std::size_t)st.laneMax, "the open field holds lane_max bot lanes");
		for (std::size_t i = 0; i < ordered.size(); ++i) {
			const SCorridor& c = m->corridors[ordered[i]];
			Require(c.lanes == st.laneMax && c.extent > 2 * st.laneSpacing, "every lane records its passage's lane count and extent");
			Require(c.name.find(" lane ") != std::string::npos, "a lane is named after its passage");
			if (i > 0) {
				const SPoint a = CorridorPoint(m->corridors[ordered[i - 1]], 0.5f), b = CorridorPoint(c, 0.5f);
				Require(std::abs(b.z - a.z) >= 0.5f * st.laneSpacing, "lanes are at least half a spacing apart");
			}
			for (const SPoint& p : c.centre) Require(CorridorAt(*m, C_BOT, p.x, p.z, 0) == c.id, "a lane's centre runs over its own cells");
		}
		SSettings one = st; one.laneMax = 1;
		Require(CorridorCount(*Analyse(in, one, nullptr), C_BOT) == 1, "lane_max 1 keeps one lane per passage");
	}
	// the obstacle field: three bot corridors at the default wall share, ordered north to south on a west-east axis
	{
		const SInput in = ObstacleField();
		auto m = Analyse(in, st, nullptr);
		for (const std::string& f : m->checkFailures) std::printf("field_analysis_test: check failed: %s\n", f.c_str());
		Require(m->checkFailures.empty(), "corridor checks pass on the obstacle field");
		std::printf("field_analysis_test: obstacle field: %s\n", Summary(*m).c_str());
		Require(!m->obstacles.empty(), "the mesa columns are obstacles");
		const int bots = CorridorCount(*m, C_BOT);
		Require(bots == 3, "two mesa columns give three bot corridors (north, the gap, south)");
		const auto ordered = CorridorsOrdered(*m, C_BOT, {500.f, 1536.f}, {3600.f, 1536.f}, 0.f);
		Require(ordered.size() == 3, "all three are wide enough");
		const SCorridor& north = m->corridors[ordered[0]];
		const SCorridor& gap = m->corridors[ordered[1]];
		const SCorridor& south = m->corridors[ordered[2]];
		Require(CorridorPoint(north, 0.5f).z < 700.f && CorridorPoint(south, 0.5f).z >= 2372.f, "the outer corridors pass outside the columns");
		Require(CorridorPoint(gap, 0.5f).z >= 1200.f && CorridorPoint(gap, 0.5f).z < 1900.f, "the middle corridor threads the gap");
		Require(gap.narrowest > 400.f && gap.narrowest < 700.f, "the gap corridor's narrowest point is the 600-elmo gap");
		Require(CorridorAt(*m, C_BOT, 2150.f, 1536.f) == gap.id, "the cell between the columns belongs to the gap corridor");
		Require(CorridorAt(*m, C_BOT, 2150.f, 400.f) == north.id, "north of the columns is the north corridor");
		Require(CorridorCount(*m, C_VEH) == 3, "vehicles see the same three corridors");
		SSettings merged = st; merged.seamBlocked = 0.9f;
		auto one = Analyse(in, merged, nullptr);
		Require(PassageCount(*one, C_BOT) == 1, "a wall share nothing reaches merges every route into one passage");
		Require(CorridorCount(*one, C_BOT) >= 2, "that passage, as wide as the map, holds lanes side by side");
		auto again = Analyse(in, st, nullptr);
		Require(again->fingerprint == m->fingerprint && again->corridorOf[C_BOT] == m->corridorOf[C_BOT], "the table is a function of its inputs");
	}
	// the fine passability itself: one 16-elmo sample a cell, the movedef limits
	{
		SFinePass fine;
		std::vector<float> slope = {0.f, SlopeValue(30.f), SlopeValue(45.f), 0.f};
		std::vector<float> height(4 * 2 * 2, 10.f);
		for (int i = 0; i < 4; ++i) height[i] = height[i + 8] = -30.f;   // cells 0 and 1: deep water (-30)
		FinePassability(slope, 4, 1, height, 8, 2, false, fine);
		Require(fine.g.gw == 4 && fine.g.gh == 1, "one 16-elmo cell per slope sample");
		Require(!fine.Pass(C_VEH, 0) && fine.Pass(C_HOVER, 0) && fine.Pass(C_SHIP, 0) && fine.Pass(C_AMPH, 0), "30 deep: ships, hovers and amphibious, no vehicle");
		Require(!fine.Pass(C_VEH, 2) && fine.Pass(C_BOT, 2) && !fine.Pass(C_HOVER, 2) && fine.Pass(C_ALLT, 2), "45 degrees: bots and all-terrain only");
		Require(fine.Pass(C_VEH, 3) && fine.Pass(C_BOT, 3) && !fine.Pass(C_SHIP, 3), "flat land: every land class, no ship");
		SFinePass lava;
		FinePassability(slope, 4, 1, height, 8, 2, true, lava);
		Require(!lava.Pass(C_AMPH, 0) && lava.Pass(C_HOVER, 0) && lava.Pass(C_SHIP, 0), "harmful water: no amphibious, hovers still float");
	}
	std::printf("field_analysis_test: corridors ok\n");
}

int main(int argc, char** argv)
{
	if (argc > 1) {
		// <input.bin> [out.txt] [--predict] [--config field.json]: --predict hides the
		// script starts; --config reads the landmark levers from a field.json
		bool predict = false;
		const char* out = nullptr;
		const char* config = nullptr;
		for (int i = 2; i < argc; ++i) {
			if (std::strcmp(argv[i], "--predict") == 0) predict = true;
			else if (std::strcmp(argv[i], "--config") == 0 && i + 1 < argc) config = argv[++i];
			else out = argv[i];
		}
		return Replay(argv[1], out, predict, config);
	}
	try {
		TestStructure();
		TestExperienceSemantics();
		TestDeterminismAndFile();
		TestCancel();
		TestNoBoxes();
		TestMarks();
		TestCorridors();
	} catch (const std::exception& e) {
		std::cerr << "field_analysis_test FAILED: " << e.what() << "\n";
		return 1;
	}
	std::cout << "field_analysis_test passed\n";
	return 0;
}
