/*
 * FieldEncode.cpp
 *
 * D-323: see FieldEncode.h. One record per line, '|' separated; coordinates
 * in elmos rounded to integers; polylines as "x,z;x,z". Reserve once and
 * append; O(total bytes).
 */

#include "terrain/field/FieldEncode.h"
#include "terrain/field/FieldGrid.h"
#include "terrain/field/FieldLandmarks.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace circuit::field {

namespace {

void Num(std::string& out, float v)
{
	char buf[32];
	std::snprintf(buf, sizeof(buf), "%ld", std::lround(v));
	out += buf;
}

void Num(std::string& out, int v) { out += std::to_string(v); }

void Poly(std::string& out, const Polyline& line)
{
	for (std::size_t i = 0; i < line.size(); ++i) {
		if (i > 0) out += ';';
		Num(out, line[i].x); out += ','; Num(out, line[i].z);
	}
}

void Polys(std::string& out, const std::vector<Polyline>& lines)
{
	// several loops are joined with '/'; the widget splits on it
	for (std::size_t i = 0; i < lines.size(); ++i) {
		if (i > 0) out += '/';
		Poly(out, lines[i]);
	}
}

const char* TheatreName(int kind) { return kind == T_LAND ? "land" : (kind == T_SEA ? "sea" : "pond"); }

const char* CharacterName(int ch)
{
	switch (ch) {
		case R_PLAIN: return "plain"; case R_ROUGH: return "rough"; case R_PLATEAU: return "plateau";
		case R_VALLEY: return "valley"; case R_WATER: return "water"; case R_DEEP: return "deep";
		case R_COAST: return "coast"; case R_STRAIT: return "strait";
	}
	return "plain";
}

const char* BoundaryName(int kind)
{
	switch (kind) {
		case B_OPEN: return "open"; case B_RAMP: return "ramp"; case B_CLIMB: return "climb"; case B_CLIFF: return "cliff";
		case B_PASS: return "pass"; case B_FORD: return "ford"; case B_BEACH: return "beach"; case B_STEEP: return "steep";
		case B_SHEER: return "sheer"; case B_EDGE: return "edge";
	}
	return "open";
}

const char* KeyName(int kind)
{
	switch (kind) {
		case K_HIGH: return "high"; case K_GEO: return "geo"; case K_METAL: return "metal";
		case K_ISLAND: return "island"; case K_POND: return "pond";
	}
	return "geo";
}

std::string Clean(const std::string& s)
{
	std::string out = s;
	for (char& c : out) if (c == '|' || c == '\n' || c == '\r') c = ' ';
	return out;
}

} // namespace

std::string Encode(const SModel& m, const SSettings& st, std::uint64_t seq, int frame)
{
	std::string out;
	out.reserve(256 * 1024);
	const char* classNames[_CLASSES_] = {"vehicle", "bot", "amphibious", "hover", "all-terrain", "ship", "submarine"};
	const float classSlope[_CLASSES_] = {27.f, 54.f, 54.f, 33.f, 89.f, 0.f, 0.f};
	const float classMinDepth[_CLASSES_] = {-1.f, -1.f, -1.f, -1.f, -1.f, st.standoffDepths[0], st.standoffDepths[1]};
	const float classMaxDepth[_CLASSES_] = {20.f, 20.f, -1.f, -1.f, 20.f, -1.f, -1.f};

	out += "barbfield|" + std::to_string(kFileFormat) + "|" + Clean(m.mapName) + "|" + std::to_string(m.gw) + "|"
		+ std::to_string(m.gh) + "|" + std::to_string(m.cell) + "|" + std::to_string(seq) + "|" + std::to_string(frame)
		+ "|" + std::to_string(m.fingerprint) + "\n";
	{
		char buf[512];
		std::snprintf(buf, sizeof(buf), "settings|cell_size=%d;region_min_cells=%d;water_min_cells=%d;choke_fraction=%.2f;"
			"high_ground_rise=%.0f;beach_depth=%.0f;crossing_min_length=%d;landing_merge=%d;avenue_detour=%.2f;"
			"sea_reach=%.0f;pond_max_share=%.3f;standoff=%.0f,%.0f,%.0f\n",
			st.cellSize, st.regionMinCells, st.waterMinCells, st.chokeFraction, st.highGroundRise, st.beachDepth,
			st.crossingMinLength, st.landingMerge, st.avenueDetour, st.seaReach, st.pondMaxShare,
			st.standoffDepths[0], st.standoffDepths[1], st.standoffDepths[2]);
		out += buf;
	}
	for (int k = 0; k < _CLASSES_; ++k) {
		out += "class|"; Num(out, k); out += '|'; out += classNames[k]; out += '|'; Num(out, classSlope[k]); out += '|';
		Num(out, classMinDepth[k]); out += '|'; Num(out, classMaxDepth[k]); out += '|';
		Num(out, k == C_HOVER ? 1 : (k == C_AMPH ? 2 : (k >= C_SHIP ? 4 : 0))); out += '\n';
	}
	for (const STheatre& t : m.theatres) {
		out += "theatre|"; Num(out, t.id); out += '|'; out += TheatreName(t.kind); out += '|'; out += Clean(t.name); out += '|';
		Num(out, t.cells); out += '|'; Num(out, t.centre.x); out += '|'; Num(out, t.centre.z); out += '|'; Num(out, t.holders); out += '|';
		Polys(out, t.outline); out += '\n';
	}
	for (const SRegion& r : m.regions) {
		out += "region|"; Num(out, r.id); out += '|'; Num(out, r.theatre); out += '|'; out += CharacterName(r.character); out += '|';
		Num(out, r.cells); out += '|'; Num(out, r.medianWidth); out += '|'; Num(out, r.lowWidth); out += '|';
		Num(out, r.minH); out += '|'; Num(out, r.maxH); out += '|'; Num(out, r.label.x); out += '|'; Num(out, r.label.z); out += '|';
		Polys(out, r.outline); out += '\n';
	}
	for (const SBoundary& b : m.boundaries) {
		out += "boundary|"; Num(out, b.id); out += '|'; out += BoundaryName(b.kind); out += '|'; Num(out, b.a); out += '|'; Num(out, b.b); out += '|';
		Num(out, b.classMask); out += '|'; Num(out, b.width); out += '|'; Num(out, b.steepestDeg); out += '|'; Poly(out, b.line); out += '\n';
	}
	for (const SChoke& c : m.chokes) {
		out += "choke|"; Num(out, c.id); out += '|'; Num(out, c.a); out += '|'; Num(out, c.b); out += '|'; Num(out, c.pos.x); out += '|'; Num(out, c.pos.z); out += '|';
		char buf[64];
		std::snprintf(buf, sizeof(buf), "%.3f|%.3f|", c.dir.x, c.dir.z);
		out += buf; Num(out, c.width); out += '\n';
	}
	for (const SAvenue& a : m.avenues) {
		out += "avenue|"; Num(out, a.id); out += '|'; Num(out, a.cls); out += '|'; out += Clean(a.name); out += '|';
		Num(out, a.specialist ? 1 : 0); out += '|'; Num(out, a.length); out += '|';
		for (std::size_t i = 0; i < a.regions.size(); ++i) { if (i) out += ','; Num(out, a.regions[i]); }
		out += '|';
		for (std::size_t i = 0; i < a.crossings.size(); ++i) { if (i) out += ','; Num(out, a.crossings[i]); }
		out += '|';
		for (std::size_t i = 0; i < a.spine.size(); ++i) {
			if (i) out += ';';
			Num(out, a.spine[i].x); out += ','; Num(out, a.spine[i].z); out += ',';
			Num(out, i < a.spineWidth.size() ? a.spineWidth[i] : 0.f);
		}
		out += "|\n";   // outline: none in this slice (the widget fills the regions)
	}
	for (const SLanding& l : m.landings) {
		out += "landing|"; Num(out, l.id); out += '|'; out += (l.kind == B_BEACH ? "beach" : "steep"); out += '|';
		Num(out, l.sea); out += '|'; Num(out, l.region); out += '|';
		Num(out, l.side >= 0 && l.side < (int)m.sides.size() ? m.sides[l.side].allyTeam : -1); out += '|';
		Num(out, 0); out += '|'; Num(out, l.rank); out += '|'; Num(out, l.classMask); out += '|'; Num(out, l.width); out += '|';
		Num(out, l.inland); out += '|';
		Num(out, l.standoff[0]); out += ','; Num(out, l.standoff[1]); out += ','; Num(out, l.standoff[2]); out += "|-|";
		Poly(out, l.line); out += '\n';
	}
	for (const SStandoff& s : m.standoffs) {
		out += "standoff|"; Num(out, s.sea); out += '|'; Num(out, s.depth); out += '|'; Poly(out, s.line); out += '\n';
	}
	for (const SSide& s : m.sides) {
		out += "side|"; Num(out, s.allyTeam); out += '|'; Poly(out, s.box); out += '|'; Num(out, s.cells); out += '|';
		Num(out, s.label.x); out += '|'; Num(out, s.label.z); out += '\n';
	}
	for (const Polyline& line : m.contact) {
		out += "contact|"; Poly(out, line); out += '\n';
	}
	for (const SKey& k : m.keys) {
		out += "key|"; out += KeyName(k.kind); out += '|'; Num(out, k.pos.x); out += '|'; Num(out, k.pos.z); out += '|';
		Num(out, k.value); out += '|'; Num(out, k.region); out += '|';
		Num(out, k.side >= 0 && k.side < (int)m.sides.size() ? m.sides[k.side].allyTeam : -1); out += '|';
		if (k.avenue >= 0) Num(out, k.avenue); else out += '-';
		out += '\n';
	}
	out += "cells|" + RunLength(m.regionOf) + "\n";
	// D-326: ground class per cell, same run-length form as the region ids
	out += "ground|" + RunLength(std::vector<int>(m.groundOf.begin(), m.groundOf.end())) + "\n";
	out += "end|" + std::to_string(seq) + "\n";
	return out;
}

std::string Summary(const SModel& m)
{
	int land = 0, seas = 0, ponds = 0, assault = 0, crossings = 0, barriers = 0;
	for (const STheatre& t : m.theatres) { if (t.kind == T_LAND) ++land; else if (t.kind == T_SEA) ++seas; else ++ponds; }
	for (const SBoundary& b : m.boundaries) {
		if (b.kind == B_CLIFF || b.kind == B_SHEER) ++barriers;
		else if (b.kind != B_OPEN && b.kind != B_EDGE) ++crossings;
	}
	int sides = (int)m.sides.size();
	for (const SLanding& l : m.landings) if (sides >= 2 && l.rank == 1) ++assault;
	char buf[512];
	std::snprintf(buf, sizeof(buf), "%d theatres (%d land, %d seas, %d ponds), %d regions, %d crossings, %d barriers, %d chokes, "
		"%d landings (%d first-ranked), %d avenues, %d key terrain, %d sides",
		(int)m.theatres.size(), land, seas, ponds, (int)m.regions.size(), crossings, barriers, (int)m.chokes.size(),
		(int)m.landings.size(), assault, (int)m.avenues.size(), (int)m.keys.size(), sides);
	return buf;
}

namespace {

void Fixed(std::string& out, float v, int decimals)
{
	char buf[32];
	std::snprintf(buf, sizeof(buf), "%.*f", decimals, v);
	out += buf;
}

int Percent(float share) { return (int)std::lround(100.f * share); }

} // namespace

std::string EncodeMarks(const SModel& m, const SSettings& st, std::uint64_t seq, int frame)
{
	std::string out;
	out.reserve(64 * 1024);
	out += "barbmarks|" + std::to_string(kMarksFormat) + "|" + Clean(m.mapName) + "|" + std::to_string(m.fingerprint) + "|"
		+ std::to_string(m.marksFingerprint) + "|" + std::to_string(seq) + "|" + std::to_string(frame) + "\n";
	out += "env|"; Fixed(out, m.minWind, 1); out += '|'; Fixed(out, m.maxWind, 1); out += '|'; Fixed(out, m.tidal, 1); out += '|';
	Num(out, m.mapDiagonal); out += '\n';
	for (int c = 0; c < _OPENINGS_; ++c) {
		out += "factory|"; out += OpeningName(c);
		for (int f = 0; f < 3; ++f) {
			const std::string& id = st.marks.factories[c][f];
			out += '|'; out += id.empty() ? std::string("-") : Clean(id);
		}
		out += '\n';
	}
	for (const SPosition& p : m.positions) {
		out += "position|"; Num(out, p.index); out += '|'; out += Clean(p.name); out += '|'; Num(out, p.allyTeam); out += '|';
		Num(out, p.n); out += '|'; Num(out, p.pos.x); out += '|'; Num(out, p.pos.z); out += '|';
		out += p.predicted ? "predicted" : "script"; out += '|'; out += LabelName(p.label); out += '|'; out += SubLabelName(p.sub); out += '|';
		Num(out, Percent(p.frontShare)); out += '|'; Num(out, p.rearRank); out += '|'; Num(out, p.f.cells); out += '\n';
	}
	for (const SPosition& p : m.positions) {
		const SFeatures& f = p.f;
		out += "feature|"; Num(out, p.index); out += '|';
		const int order[7] = {G_DEEP, G_WATER, G_SHALLOW, G_FLAT, G_ROUGH, G_STEEP, G_CLIFF};
		for (int i = 0; i < 7; ++i) { if (i) out += ','; Num(out, Percent(f.ground[order[i]])); }
		out += '|'; Num(out, f.openWidth); out += '|'; Num(out, Percent(f.vehShare)); out += '|'; Fixed(out, f.metal, 1); out += '|';
		Num(out, f.clusters); out += '|'; Num(out, f.geos); out += '|'; Num(out, f.geoDist); out += '|'; Num(out, f.sea); out += '|';
		Num(out, f.yard.x); out += ','; Num(out, f.yard.z); out += '|'; Num(out, f.yardDist); out += '|'; Num(out, f.pondCells); out += '|';
		Num(out, f.assaultRank); out += '|'; Num(out, f.island ? 1 : 0); out += '\n';
	}
	for (const SPosition& p : m.positions) {
		out += "opening|"; Num(out, p.index); out += '|'; out += OpeningName(p.opening); out += '|';
		for (std::size_t i = 0; i < p.fallbacks.size(); ++i) { if (i) out += ','; out += OpeningName(p.fallbacks[i]); }
		out += '|'; out += EnergyName(p.energy); out += '|';
		const std::string& second = (p.label >= 0 && p.label < _LABELS_) ? st.marks.second[p.label] : std::string();
		out += second.empty() ? std::string("-") : Clean(second);
		out += '|';
		for (std::size_t i = 0; i < p.reasons.size(); ++i) {
			if (i) out += ';';
			std::string r = Clean(p.reasons[i]);
			for (char& ch : r) if (ch == ';') ch = ',';
			out += r;
		}
		out += '\n';
	}
	for (const SMark& mk : m.marks) {
		out += "mark|"; Num(out, mk.id); out += '|'; out += MarkGroupName(mk.group); out += '|'; out += MarkKindName(mk.kind); out += '|';
		Num(out, mk.pos.x); out += '|'; Num(out, mk.pos.z); out += '|'; Fixed(out, mk.value, 1); out += '|';
		Num(out, mk.position); out += '|'; Num(out, mk.allyTeam); out += '|'; Num(out, mk.contested ? 1 : 0); out += '|';
		Num(out, mk.phaseFrom); out += '|'; Num(out, mk.phaseTo); out += '|'; Num(out, mk.labelled ? 1 : 0); out += '|';
		out += Clean(mk.reason); out += '|';
		if (mk.line.empty()) out += '-'; else Poly(out, mk.line);
		out += '\n';
	}
	out += "territory|" + RunLength(m.posOf) + "\n";
	out += "end|" + std::to_string(seq) + "\n";
	return out;
}

std::string MarksSummary(const SModel& m)
{
	int labels[_LABELS_] = {0, 0, 0, 0, 0, 0, 0, 0};
	int kinds[_MARK_KINDS_] = {};
	for (const SPosition& p : m.positions) if (p.label >= 0 && p.label < _LABELS_) ++labels[p.label];
	for (const SMark& mk : m.marks) if (mk.kind >= 0 && mk.kind < _MARK_KINDS_) ++kinds[mk.kind];
	std::string out = std::to_string(m.positions.size()) + " positions (";
	bool first = true;
	for (int l = 0; l < _LABELS_; ++l) {
		if (labels[l] == 0) continue;
		if (!first) out += ", ";
		out += std::to_string(labels[l]) + " " + LabelName(l);
		first = false;
	}
	out += "), " + std::to_string(m.marks.size()) + " marks (";
	first = true;
	for (int k = 0; k < _MARK_KINDS_; ++k) {
		if (kinds[k] == 0) continue;
		if (!first) out += ", ";
		out += std::to_string(kinds[k]) + " " + MarkKindName(k);
		first = false;
	}
	out += ")";
	return out;
}

bool ParseHeader(const std::string& text, SHeader& out)
{
	out = SHeader();
	if (text.compare(0, 10, "barbfield|") != 0) return false;
	const std::size_t eol = text.find('\n');
	const std::string line = text.substr(0, eol == std::string::npos ? text.size() : eol);
	std::vector<std::string> f;
	std::size_t start = 0;
	for (;;) {
		const std::size_t bar = line.find('|', start);
		f.push_back(line.substr(start, bar == std::string::npos ? std::string::npos : bar - start));
		if (bar == std::string::npos) break;
		start = bar + 1;
	}
	if (f.size() < 9) return false;
	out.format = std::atoi(f[1].c_str());
	out.mapName = f[2];
	out.gw = std::atoi(f[3].c_str()); out.gh = std::atoi(f[4].c_str()); out.cell = std::atoi(f[5].c_str());
	out.seq = std::strtoull(f[6].c_str(), nullptr, 10); out.frame = std::atoi(f[7].c_str());
	out.fingerprint = std::strtoull(f[8].c_str(), nullptr, 10);
	const std::string trailer = "\nend|" + f[6] + "\n";
	out.complete = text.size() >= trailer.size() && text.compare(text.size() - trailer.size(), trailer.size(), trailer) == 0;
	return true;
}

} // namespace circuit::field
