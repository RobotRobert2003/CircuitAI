/*
 * FieldAnalysis.cpp
 *
 * D-323: see FieldAnalysis.h. Stage order: grid, mobility, sides, theatres,
 * regions (clearance watershed), boundaries, landings and standoff lines,
 * avenues, key terrain, checks. Every stage is O(N) or O(N log N) in the
 * cells (Supreme Isthmus: 147,456) except the avenue searches, which run over
 * the region graph (hundreds of nodes). The cancel flag is tested between
 * stages. No engine, no circuit, no shared mutable state: the worker owns
 * everything it touches.
 */

#include "terrain/field/FieldAnalysis.h"
#include "terrain/field/FieldGrid.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <functional>
#include <map>
#include <numeric>
#include <queue>
#include <set>
#include <unordered_map>
#include <unordered_set>
#ifdef FIELD_DEBUG
#include <cstdio>
#endif

namespace circuit::field {

float SlopeDegrees(float oneMinusCos)
{
	const float c = std::clamp(1.f - oneMinusCos, -1.f, 1.f);
	return std::acos(c) * 180.f / 3.14159265f;
}

float SlopeValue(float degrees)
{
	return 1.f - std::cos(degrees * 3.14159265f / 180.f);
}

namespace {

using Clock = std::chrono::steady_clock;

double Ms(Clock::time_point since)
{
	return std::chrono::duration<double, std::milli>(Clock::now() - since).count();
}

template<typename T>
int Count(const std::vector<T>& v) { return static_cast<int>(v.size()); }

struct SContact {
	int a = 0, b = 0, cell = 0, clr = 0;
};

struct SEdge {
	int cellA = 0, cellB = 0;   // cellB = -1 beyond the map edge
	SSegment seg;
};

struct SPairInfo {
	std::vector<SEdge> edges;
};

class Context final {
public:
	Context(const SInput& in, const SSettings& st, const std::atomic<bool>* cancel, SModel& m)
		: in(in), st(st), cancel(cancel), m(m) {}

	void Run();

private:
	void Check() const {
		if (cancel != nullptr && cancel->load(std::memory_order_relaxed)) throw Cancelled();
	}
	void BuildGrid();
	void BuildMobility();
	void BuildSides();
	void BuildTheatres();
	void BuildRegions();
	void BuildBoundaries();
	void BuildLandings();
	void BuildAvenues();
	void BuildKeyTerrain();
	void Finish();

	// helpers
	SPoint Centre(int c) const { return {(g.X(c) + 0.5f) * cell, (g.Z(c) + 0.5f) * cell}; }
	std::int64_t CornerKey(int x, int z) const { return (std::int64_t)z * (g.gw + 1) + x; }
	SSegment CornerSegment(int x0, int z0, int x1, int z1) const {
		SSegment s;
		s.ka = CornerKey(x0, z0); s.kb = CornerKey(x1, z1);
		s.a = {x0 * (float)cell, z0 * (float)cell}; s.b = {x1 * (float)cell, z1 * (float)cell};
		return s;
	}
	// the edge between cell c and its E (dir 0) or S (dir 1) neighbour
	SSegment SharedEdge(int c, int dir) const {
		const int x = g.X(c), z = g.Z(c);
		return (dir == 0) ? CornerSegment(x + 1, z, x + 1, z + 1) : CornerSegment(x, z + 1, x + 1, z + 1);
	}
	std::vector<Polyline> Outline(const std::function<bool(int)>& inside) const;
	void Watershed(const std::vector<char>& iterate, const std::vector<int>& clr, int minCells,
				   std::vector<int>& label, std::vector<SContact>& contacts, int& regionCount);
	float SlopeAt(float ex, float ez) const;
	unsigned char BestGround(int c) const {
		unsigned char best = NO_GO;
		for (int k = 0; k < kGroundClasses; ++k) best = std::max(best, mob[k][c]);
		return best;
	}
	void Dijkstra(const std::vector<int>& seeds, const std::vector<int>& seedSide,
				  std::vector<float>& dist, std::vector<int>& side) const;
	std::string Compass(float x, float z) const;
	int TheatreKind(int cell) const { return (theatreOf[cell] >= 0) ? m.theatres[theatreOf[cell]].kind : T_LAND; }
	bool IsWater(int cell) const { return TheatreKind(cell) != T_LAND; }

	const SInput& in;
	const SSettings& st;
	const std::atomic<bool>* cancel;
	SModel& m;

	SGridShape g;
	int cell = 32;
	std::vector<float> hMean, hMin, hMax, sMax;
	std::vector<float> sPass;   // the cell's second steepest 16-elmo slope sample (D-328: what a unit threads through)
	std::vector<unsigned char> mob[_CLASSES_];
	std::vector<char> landMask, waterMask, walkMask;
	std::vector<int> theatreOf;
	std::vector<int> sideOf;
	std::vector<float> sideDist;
	std::vector<std::vector<float>> boxDist;      // per side, cells
	std::vector<std::vector<int>> sideSeeds;      // per side
	bool syntheticSides = false;
	std::vector<int> landClr, walkClr, waterClr;  // chamfer thirds: to water, to unwalkable, to non-water
	std::vector<int> regionOf;
	std::vector<SPoint> regionCentroid;
	std::set<std::pair<int, int>> chokePairs;
	std::vector<float> regionRise;
	std::vector<std::vector<int>> regionClassOk;  // [cls][region] count of passable cells
	std::vector<int> regionCells;
	struct SRock { SPoint centre; int cells; };
	std::vector<SRock> rocks;                     // land too small for a theatre
};

// ---------------------------------------------------------------- grid

void Context::BuildGrid()
{
	cell = std::max(16, st.cellSize);
	g.gw = std::max(1, in.mapWidth / cell);
	g.gh = std::max(1, in.mapHeight / cell);
	m.gw = g.gw; m.gh = g.gh; m.cell = cell; m.mapName = in.mapName;
	const int n = g.Size();
	hMean.assign(n, 0.f); hMin.assign(n, 0.f); hMax.assign(n, 0.f); sMax.assign(n, 0.f); sPass.assign(n, 0.f);
	std::vector<float> samples;
	samples.reserve(16);
	const int hs = std::max(1, cell / 8), ss = std::max(1, cell / 16);
	const int hw = std::max(1, in.heightStride), hh = std::max(1, in.heightRows);
	const int sw = std::max(1, in.slopeStride), sh = std::max(1, in.slopeRows);
	for (int z = 0; z < g.gh; ++z) {
		for (int x = 0; x < g.gw; ++x) {
			const int c = g.Index(x, z);
			float sum = 0.f, lo = 1e9f, hi = -1e9f;
			int count = 0;
			for (int j = 0; j < hs; ++j) {
				const int hz = std::min(hh - 1, z * hs + j);
				for (int i = 0; i < hs; ++i) {
					const int hx = std::min(hw - 1, x * hs + i);
					const std::size_t idx = (std::size_t)hz * hw + hx;
					const float v = idx < in.height.size() ? in.height[idx] : 0.f;
					sum += v; lo = std::min(lo, v); hi = std::max(hi, v); ++count;
				}
			}
			hMean[c] = count > 0 ? sum / count : 0.f; hMin[c] = lo; hMax[c] = hi;
			float s = 0.f;
			samples.clear();
			for (int j = 0; j < ss; ++j) {
				const int sz = std::min(sh - 1, z * ss + j);
				for (int i = 0; i < ss; ++i) {
					const int sx = std::min(sw - 1, x * ss + i);
					const std::size_t idx = (std::size_t)sz * sw + sx;
					const float v = idx < in.slope.size() ? in.slope[idx] : 0.f;
					s = std::max(s, v);
					samples.push_back(v);
				}
			}
			sMax[c] = s;
			// D-328: the engine paths over its own 16-elmo squares, so a unit threads a cell
			// through its gentler squares. The cell passes unless two of its four squares
			// are too steep (the second steepest sample): the steepest sample made every
			// narrow ramp a cliff (KI-645), the second least steep opened real summits
			// (the survey lost 18 confirmed ones on Glacial Gap).
			std::sort(samples.begin(), samples.end());
			const std::size_t pick = samples.size() >= 3 ? samples.size() - 2 : (samples.size() >= 2 ? 1 : 0);
			sPass[c] = samples.empty() ? 0.f : samples[pick];
		}
	}
}

float Context::SlopeAt(float ex, float ez) const
{
	if (in.slope.empty()) return 0.f;
	const int sx = std::clamp((int)(ex / 16.f), 0, in.slopeStride - 1);
	const int sz = std::clamp((int)(ez / 16.f), 0, in.slopeRows - 1);
	const std::size_t idx = (std::size_t)sz * in.slopeStride + sx;
	return idx < in.slope.size() ? in.slope[idx] : 0.f;
}

// ---------------------------------------------------------------- mobility

void Context::BuildMobility()
{
	const int n = g.Size();
	const float limit[kGroundClasses] = {SlopeValue(27.f), SlopeValue(54.f), SlopeValue(54.f), SlopeValue(33.f), SlopeValue(89.f)};
	constexpr float kWade = 20.f;
	const std::size_t cells = static_cast<std::size_t>(std::max(0, n));   // the size type the compiler can prove non-negative
	for (int k = 0; k < _CLASSES_; ++k) mob[k].assign(cells, NO_GO);
	for (int c = 0; c < n; ++c) {
		const float depth = -hMean[c];
		const float s = sPass[c];   // D-328: passable when a chain of 16-elmo squares is, not when every square is
		for (int k = 0; k < kGroundClasses; ++k) {
			unsigned char v;
			if (s > limit[k]) v = NO_GO;
			else if (s > 0.8f * limit[k]) v = SLOW_GO;
			else v = GO;
			if (k == C_HOVER) {
				if (depth > 0.f) v = GO;   // on the surface, the seabed slope does not matter
			} else if (k == C_AMPH) {
				if (in.waterHarmful && depth > 0.f) v = NO_GO;
			} else {
				if (depth > kWade || (in.waterHarmful && depth > 0.f)) v = NO_GO;
				else if (depth > 0.f && v == GO) v = SLOW_GO;   // wading
			}
			mob[k][c] = v;
		}
		mob[C_SHIP][c] = (hMax[c] <= -st.standoffDepths[0]) ? GO : (hMean[c] <= -st.standoffDepths[0] ? SLOW_GO : NO_GO);
		mob[C_SUB][c] = (hMax[c] <= -st.standoffDepths[1]) ? GO : (hMean[c] <= -st.standoffDepths[1] ? SLOW_GO : NO_GO);
	}
	// Land is everything ships cannot sail (cliffs and plateau tops included: a
	// cliff-ringed plateau is a region of the land mass bounded by cliffs, not a
	// land mass of its own); walkMask is the bot-passable part of it, which the
	// clearance field and the region watershed are built on.
	landMask.assign(cells, 0); waterMask.assign(cells, 0); walkMask.assign(cells, 0);
	for (int c = 0; c < n; ++c) {
		waterMask[c] = (mob[C_SHIP][c] == GO) ? 1 : 0;
		landMask[c] = waterMask[c] ? 0 : 1;
		walkMask[c] = (mob[C_BOT][c] != NO_GO && !waterMask[c]) ? 1 : 0;
	}
	// D-326: the per-cell ground class the terrain view draws, read straight off
	// the masks above so the picture and the analysis cannot disagree. O(cells).
	m.groundOf.assign(cells, G_FLAT);
	for (int c = 0; c < n; ++c) {
		const float depth = -hMean[c];
		unsigned char gnd;
		if (depth > 0.f && in.waterHarmful) gnd = G_HARM;
		else if (waterMask[c]) gnd = G_DEEP;
		else if (depth > 0.f) gnd = (depth > kWade) ? G_WATER : G_SHALLOW;
		else if (mob[C_VEH][c] == GO) gnd = G_FLAT;
		else if (mob[C_VEH][c] == SLOW_GO) gnd = G_ROUGH;
		else if (mob[C_BOT][c] != NO_GO) gnd = G_STEEP;
		else gnd = G_CLIFF;
		m.groundOf[c] = gnd;
	}
}

// ---------------------------------------------------------------- sides

static bool PointInPolygon(const Polyline& poly, float x, float z)
{
	bool inside = false;
	const int n = (int)poly.size();
	for (int i = 0, j = n - 1; i < n; j = i++) {
		const SPoint& a = poly[i];
		const SPoint& b = poly[j];
		if (((a.z > z) != (b.z > z)) && (x < (b.x - a.x) * (z - a.z) / (b.z - a.z + 1e-9f) + a.x)) inside = !inside;
	}
	return inside;
}

void Context::Dijkstra(const std::vector<int>& seeds, const std::vector<int>& seedSide,
					   std::vector<float>& dist, std::vector<int>& side) const
{
	const int n = g.Size();
	dist.assign(n, 1e30f);
	side.assign(n, -1);
	using Item = std::pair<float, int>;
	std::priority_queue<Item, std::vector<Item>, std::greater<Item>> pq;
	for (int i = 0; i < Count(seeds); ++i) {
		const int c = seeds[i];
		if (dist[c] > 0.f) {
			dist[c] = 0.f; side[c] = seedSide[i];
			pq.emplace(0.f, c);
		}
	}
	while (!pq.empty()) {
		const auto [d, c] = pq.top();
		pq.pop();
		if (d > dist[c]) continue;
		const int x = g.X(c), z = g.Z(c);
		for (int k = 0; k < 8; ++k) {
			const int nx = x + kDx[k], nz = z + kDz[k];
			if (!g.Inside(nx, nz)) continue;
			const int nc = g.Index(nx, nz);
			const unsigned char mb = BestGround(nc);
			const float base = (mb == GO) ? 1.f : (mb == SLOW_GO ? 2.f : 8.f);
			const float nd = d + base * (k < 4 ? 1.f : 1.41421356f);
			if (nd < dist[nc] || (nd == dist[nc] && side[c] < side[nc])) {
				dist[nc] = nd; side[nc] = side[c];
				pq.emplace(nd, nc);
			}
		}
	}
}

void Context::BuildSides()
{
	const int n = g.Size();
	std::vector<int> seeds, seedSide;
	std::vector<SBoxInput> boxes = in.boxes;
	std::sort(boxes.begin(), boxes.end(), [](const SBoxInput& a, const SBoxInput& b) { return a.allyTeam < b.allyTeam; });
	syntheticSides = boxes.size() < 2;
	if (syntheticSides) {
		// No usable boxes: halve the map along its longest axis so every record
		// still has a side. Marked by the sides' ally team -1.
		boxes.clear();
		const bool wide = in.mapWidth >= in.mapHeight;
		for (int s = 0; s < 2; ++s) {
			SBoxInput b;
			b.allyTeam = -1;
			b.left = wide && s == 1 ? in.mapWidth * 0.75f : 0.f;
			b.right = wide ? (s == 0 ? in.mapWidth * 0.25f : (float)in.mapWidth) : (float)in.mapWidth;
			b.top = !wide && s == 1 ? in.mapHeight * 0.75f : 0.f;
			b.bottom = !wide ? (s == 0 ? in.mapHeight * 0.25f : (float)in.mapHeight) : (float)in.mapHeight;
			boxes.push_back(b);
		}
	}
	sideSeeds.assign(boxes.size(), {});
	m.sides.clear();
	for (int s = 0; s < Count(boxes); ++s) {
		const SBoxInput& b = boxes[s];
		for (int c = 0; c < n; ++c) {
			const SPoint p = Centre(c);
			bool inside = false;
			if (b.polys.empty()) {
				inside = p.x >= b.left && p.x <= b.right && p.z >= b.top && p.z <= b.bottom;
			} else {
				for (const Polyline& poly : b.polys) if (PointInPolygon(poly, p.x, p.z)) { inside = true; break; }
			}
			if (inside) sideSeeds[s].push_back(c);
		}
		if (sideSeeds[s].empty()) {
			const int cx = std::clamp((int)((b.left + b.right) * 0.5f / cell), 0, g.gw - 1);
			const int cz = std::clamp((int)((b.top + b.bottom) * 0.5f / cell), 0, g.gh - 1);
			sideSeeds[s].push_back(g.Index(cx, cz));
		}
		SSide side;
		side.allyTeam = b.allyTeam;
		if (b.polys.empty()) {
			side.box = {{b.left, b.top}, {b.right, b.top}, {b.right, b.bottom}, {b.left, b.bottom}, {b.left, b.top}};
		} else {
			side.box = b.polys.front();
			if (!side.box.empty()) side.box.push_back(side.box.front());
		}
		float lx = 0.f, lz = 0.f;
		for (int c : sideSeeds[s]) { lx += Centre(c).x; lz += Centre(c).z; }
		side.label = {lx / sideSeeds[s].size(), lz / sideSeeds[s].size()};
		m.sides.push_back(side);
		for (int c : sideSeeds[s]) { seeds.push_back(c); seedSide.push_back(s); }
	}
	Dijkstra(seeds, seedSide, sideDist, sideOf);
	for (int c = 0; c < n; ++c) ++m.sides[sideOf[c]].cells;
	boxDist.assign(boxes.size(), {});
	for (int s = 0; s < Count(boxes); ++s) {
		std::vector<int> one(sideSeeds[s].size(), s), tmp;
		Dijkstra(sideSeeds[s], one, boxDist[s], tmp);
	}
	// contact line: edges between different sides
	std::vector<SSegment> segs;
	for (int c = 0; c < n; ++c) {
		const int x = g.X(c), z = g.Z(c);
		if (x + 1 < g.gw && sideOf[c] != sideOf[c + 1]) segs.push_back(SharedEdge(c, 0));
		if (z + 1 < g.gh && sideOf[c] != sideOf[c + g.gw]) segs.push_back(SharedEdge(c, 1));
	}
	for (Polyline& line : ChainSegments(segs)) m.contact.push_back(Simplify(line, 0.6f * cell));
}

// ---------------------------------------------------------------- theatres

std::string Context::Compass(float x, float z) const
{
	const float fx = x / in.mapWidth, fz = z / in.mapHeight;
	std::string ns = fz < 1.f / 3.f ? "North" : (fz > 2.f / 3.f ? "South" : "");
	std::string ew = fx < 1.f / 3.f ? "West" : (fx > 2.f / 3.f ? "East" : "");
	if (ns.empty() && ew.empty()) return "Central";
	if (ns.empty()) return ew;
	if (ew.empty()) return ns;
	return ns + "-" + ew;
}

std::vector<Polyline> Context::Outline(const std::function<bool(int)>& inside) const
{
	std::vector<SSegment> segs;
	for (int c = 0; c < g.Size(); ++c) {
		if (!inside(c)) continue;
		const int x = g.X(c), z = g.Z(c);
		if (x + 1 >= g.gw || !inside(c + 1)) segs.push_back(CornerSegment(x + 1, z, x + 1, z + 1));
		if (x == 0 || !inside(c - 1)) segs.push_back(CornerSegment(x, z, x, z + 1));
		if (z + 1 >= g.gh || !inside(c + g.gw)) segs.push_back(CornerSegment(x, z + 1, x + 1, z + 1));
		if (z == 0 || !inside(c - g.gw)) segs.push_back(CornerSegment(x, z, x + 1, z));
	}
	std::vector<Polyline> out;
	for (Polyline& line : ChainSegments(segs)) out.push_back(Simplify(line, 0.6f * cell));
	return out;
}

void Context::BuildTheatres()
{
	const int n = g.Size();
	theatreOf.assign(n, -1);
	m.theatres.clear();
	auto flood = [&](const std::vector<char>& mask, int kind, int minCells, int neighbours) {
		std::vector<int> stack;
		for (int start = 0; start < n; ++start) {
			if (!mask[start] || theatreOf[start] != -1) continue;
			const int id = Count(m.theatres);
			std::vector<int> members;
			stack.push_back(start);
			theatreOf[start] = id;
			while (!stack.empty()) {
				const int c = stack.back();
				stack.pop_back();
				members.push_back(c);
				const int x = g.X(c), z = g.Z(c);
				for (int k = 0; k < neighbours; ++k) {
					const int nx = x + kDx[k], nz = z + kDz[k];
					if (!g.Inside(nx, nz)) continue;
					const int nc = g.Index(nx, nz);
					if (mask[nc] && theatreOf[nc] == -1) { theatreOf[nc] = id; stack.push_back(nc); }
				}
			}
			if (Count(members) < minCells) {
				for (int c : members) theatreOf[c] = -2;   // noise: assigned to the nearest theatre below
				if (kind == T_LAND && Count(members) >= st.regionMinCells) {
					// a rock: too small for a theatre, still worth a marker
					float cx = 0.f, cz = 0.f;
					for (int c : members) { cx += Centre(c).x; cz += Centre(c).z; }
					rocks.push_back({{cx / members.size(), cz / members.size()}, Count(members)});
				}
				continue;
			}
			STheatre t;
			t.id = id; t.kind = kind; t.cells = Count(members);
			float cx = 0.f, cz = 0.f;
			for (int c : members) { cx += Centre(c).x; cz += Centre(c).z; }
			t.centre = {cx / members.size(), cz / members.size()};
			m.theatres.push_back(t);
		}
	};
	// a land theatre needs room for an outpost (four regions' worth); smaller
	// land is a rock marker and joins the water around it
	flood(landMask, T_LAND, 4 * st.regionMinCells, 8);
	flood(waterMask, T_SEA, st.waterMinCells, 4);
	// every remaining cell joins the nearest theatre (cliff tops, shallows, noise):
	// first a land theatre for cells above water level and a water theatre for
	// cells below it, so a cliff above the sea belongs to the land it stands on
	// and its shore is classified from its slope; then whatever is left.
	{
		std::vector<int> queue;
		queue.reserve(n);
		for (int c = 0; c < n; ++c) if (theatreOf[c] < 0) theatreOf[c] = -1;
		for (int pass = 0; pass < 2; ++pass) {
			queue.clear();
			for (int c = 0; c < n; ++c) if (theatreOf[c] >= 0) queue.push_back(c);
			std::size_t head = 0;
			while (head < queue.size()) {
				const int c = queue[head++];
				const int x = g.X(c), z = g.Z(c);
				const bool fromLand = m.theatres[theatreOf[c]].kind == T_LAND;
				for (int k = 0; k < 8; ++k) {
					const int nx = x + kDx[k], nz = z + kDz[k];
					if (!g.Inside(nx, nz)) continue;
					const int nc = g.Index(nx, nz);
					if (theatreOf[nc] != -1) continue;
					if (pass == 0 && fromLand != (hMean[nc] >= 0.f)) continue;
					theatreOf[nc] = theatreOf[c];
					queue.push_back(nc);
				}
			}
		}
		if (m.theatres.empty()) {   // a map with no walkable land and no sailable water: one theatre
			STheatre t;
			t.id = 0; t.kind = T_LAND; t.cells = n; t.centre = {in.mapWidth * 0.5f, in.mapHeight * 0.5f};
			m.theatres.push_back(t);
			std::fill(theatreOf.begin(), theatreOf.end(), 0);
		}
	}
	for (STheatre& t : m.theatres) t.cells = 0;
	for (int c = 0; c < n; ++c) ++m.theatres[theatreOf[c]].cells;
	for (int s = 0; s < Count(sideSeeds); ++s) for (int c : sideSeeds[s]) m.theatres[theatreOf[c]].hasBox = true;
	// seas and ponds, holders
	const float reachCells = st.seaReach > 0.f ? st.seaReach / cell : 0.2f * std::hypot((float)g.gw, (float)g.gh);
	for (STheatre& t : m.theatres) {
		if (t.kind == T_LAND) continue;
		std::set<int> shoreSides;
		for (int c = 0; c < n; ++c) {
			if (theatreOf[c] != t.id) continue;
			const int x = g.X(c), z = g.Z(c);
			for (int k = 0; k < 4; ++k) {
				const int nx = x + kDx[k], nz = z + kDz[k];
				if (!g.Inside(nx, nz)) continue;
				const int nc = g.Index(nx, nz);
				if (theatreOf[nc] != t.id && m.theatres[theatreOf[nc]].kind == T_LAND) shoreSides.insert(sideOf[nc]);
			}
		}
		const bool small = t.cells <= st.pondMaxShare * n;
		const bool oneSided = Count(m.sides) >= 2 && shoreSides.size() <= 1;
		t.kind = (small || oneSided) ? T_POND : T_SEA;
		for (int s = 0; s < Count(boxDist); ++s) {
			float best = 1e30f;
			for (int c = 0; c < n; ++c) if (theatreOf[c] == t.id) best = std::min(best, boxDist[s][c]);
			if (best <= reachCells) t.holders |= (1 << s);
		}
	}
	std::map<std::string, int> names;
	for (STheatre& t : m.theatres) {
		std::string base = Compass(t.centre.x, t.centre.z) + (t.kind == T_LAND ? " Land" : (t.kind == T_SEA ? " Sea" : " Pond"));
		const int seen = ++names[base];
		t.name = seen == 1 ? base : base + " " + std::to_string(seen);
		const int id = t.id;
		t.outline = Outline([&](int c) { return theatreOf[c] == id; });
	}
}

// ---------------------------------------------------------------- regions

void Context::Watershed(const std::vector<char>& iterate, const std::vector<int>& clr, int minCells,
						std::vector<int>& label, std::vector<SContact>& contacts, int& regionCount)
{
	const int n = g.Size();
	int maxClr = 0;
	for (int c = 0; c < n; ++c) if (iterate[c]) maxClr = std::max(maxClr, clr[c]);
	std::vector<std::vector<int>> buckets(maxClr + 1);
	for (int c = 0; c < n; ++c) if (iterate[c]) buckets[clr[c]].push_back(c);
	std::vector<int> parent, seedClr, size;
	auto root = [&](int a) {
		while (parent[a] != a) { parent[a] = parent[parent[a]]; a = parent[a]; }
		return a;
	};
	int neighbours[8];
	for (int b = maxClr; b >= 0; --b) {
		for (int c : buckets[b]) {
			const int x = g.X(c), z = g.Z(c);
			int count = 0;
			for (int k = 0; k < 8; ++k) {
				const int nx = x + kDx[k], nz = z + kDz[k];
				if (!g.Inside(nx, nz)) continue;
				const int nc = g.Index(nx, nz);
				if (label[nc] < 0 || theatreOf[nc] != theatreOf[c]) continue;
				const int r = root(label[nc]);
				bool dup = false;
				for (int i = 0; i < count; ++i) if (neighbours[i] == r) { dup = true; break; }
				if (!dup) neighbours[count++] = r;
			}
			if (count == 0) {
				const int id = Count(parent);
				parent.push_back(id); seedClr.push_back(clr[c]); size.push_back(1);
				label[c] = id;
				continue;
			}
			int main = neighbours[0];
			for (int i = 1; i < count; ++i) {
				const int r = neighbours[i];
				if (seedClr[r] > seedClr[main] || (seedClr[r] == seedClr[main] && r < main)) main = r;
			}
			for (int i = 0; i < count; ++i) {
				const int r = neighbours[i];
				if (r == main) continue;
				const int narrow = std::min(seedClr[main], seedClr[r]);
				const bool keep = clr[c] < st.chokeFraction * narrow && size[main] >= minCells && size[r] >= minCells;
#ifdef FIELD_DEBUG
				if (size[main] >= 500 && size[r] >= 500) {
					std::printf("watershed: contact clr=%d seeds=%d/%d sizes=%d/%d -> %s at (%d,%d)\n", clr[c], seedClr[main], seedClr[r],
						size[main], size[r], keep ? "keep" : "merge", g.X(c), g.Z(c));
				}
#endif
				if (keep) {
					contacts.push_back({main, r, c, clr[c]});
				} else {
					parent[r] = main;
					size[main] += size[r];
				}
			}
			label[c] = main;
			++size[main];
		}
	}
	// final roots, then merge regions below minCells into the neighbour they touch
	// most. Only this pass's cells (`iterate`) are relabelled: an earlier pass's
	// labels are already final ids.
	for (int c = 0; c < n; ++c) if (iterate[c] && label[c] >= 0) label[c] = root(label[c]);
	std::vector<int> finalSize(parent.size(), 0);
	for (int c = 0; c < n; ++c) if (iterate[c] && label[c] >= 0) ++finalSize[label[c]];
	std::map<std::pair<int, int>, int> touch;
	for (int c = 0; c < n; ++c) {
		if (!iterate[c] || label[c] < 0) continue;
		const int x = g.X(c), z = g.Z(c);
		for (int k = 0; k < 2; ++k) {
			const int nx = x + kDx[k], nz = z + kDz[k];
			if (!g.Inside(nx, nz)) continue;
			const int nc = g.Index(nx, nz);
			if (!iterate[nc] || label[nc] < 0 || label[nc] == label[c] || theatreOf[nc] != theatreOf[c]) continue;
			++touch[{std::min(label[c], label[nc]), std::max(label[c], label[nc])}];
		}
	}
	std::vector<int> order;
	for (int r = 0; r < Count(parent); ++r) if (finalSize[r] > 0 && finalSize[r] < minCells) order.push_back(r);
	std::sort(order.begin(), order.end(), [&](int a, int b) { return finalSize[a] != finalSize[b] ? finalSize[a] < finalSize[b] : a < b; });
	for (int r : order) {
		int best = -1, bestTouch = 0;
		for (const auto& kv : touch) {
			if (kv.first.first != r && kv.first.second != r) continue;
			const int other = root(kv.first.first == r ? kv.first.second : kv.first.first);
			if (other == root(r)) continue;
			if (kv.second > bestTouch || (kv.second == bestTouch && other < best)) { bestTouch = kv.second; best = other; }
		}
		if (best >= 0) { parent[root(r)] = best; finalSize[best] += finalSize[root(r)]; }
	}
	for (int c = 0; c < n; ++c) if (iterate[c] && label[c] >= 0) label[c] = root(label[c]);
	for (SContact& ct : contacts) { ct.a = root(ct.a); ct.b = root(ct.b); }
	// compact ids in order of first appearance, after the earlier passes' ids
	std::vector<int> compact(parent.size(), -1);
	int next = regionCount;
	for (int c = 0; c < n; ++c) {
		if (!iterate[c] || label[c] < 0) continue;
		if (compact[label[c]] < 0) compact[label[c]] = next++;
		label[c] = compact[label[c]];
	}
	for (SContact& ct : contacts) { ct.a = compact[ct.a]; ct.b = compact[ct.b]; }
	regionCount = next;
}

void Context::BuildRegions()
{
	const int n = g.Size();
	// Two clearance fields. The land cut uses the distance to water and the map
	// edge, so the shape of the land mass decides the chokes (an isthmus is
	// narrow relative to the lands it joins) and the small cliffs scattered over
	// a plain cannot cap the clearance everywhere. The walkable clearance (to
	// anything bots cannot cross) gives widths and spine widths.
	ChamferDistance(g, landMask, landClr);
	ChamferDistance(g, walkMask, walkClr);
	ChamferDistance(g, waterMask, waterClr);
	regionOf.assign(n, -1);
	std::vector<char> landCells(n, 0), waterCells(n, 0);
	for (int c = 0; c < n; ++c) {
		if (IsWater(c)) waterCells[c] = 1; else landCells[c] = 1;
	}
	int regionCount = 0;
	std::vector<SContact> contacts;
	Watershed(landCells, landClr, st.regionMinCells, regionOf, contacts, regionCount);
	Check();
	std::vector<SContact> waterContacts;
	Watershed(waterCells, waterClr, st.waterMinCells, regionOf, waterContacts, regionCount);
	contacts.insert(contacts.end(), waterContacts.begin(), waterContacts.end());
	Check();
	// Ground bots cannot walk between (cliff rings) splits a land region into
	// walkable components: the largest keeps the region, every other one at
	// least regionMinCells big becomes a region of its own (a plateau top, a
	// sunken floor), bounded by the cliff. A plateau with a ramp stays joined.
	{
		std::vector<int> comp(n, -1), compRegion, compSize;
		std::vector<int> stack;
		for (int start = 0; start < n; ++start) {
			if (!walkMask[start] || comp[start] >= 0) continue;
			const int id = Count(compSize);
			compRegion.push_back(regionOf[start]); compSize.push_back(0);
			stack.push_back(start); comp[start] = id;
			while (!stack.empty()) {
				const int c = stack.back();
				stack.pop_back();
				++compSize[id];
				const int x = g.X(c), z = g.Z(c);
				for (int k = 0; k < 8; ++k) {
					const int nx = x + kDx[k], nz = z + kDz[k];
					if (!g.Inside(nx, nz)) continue;
					const int nc = g.Index(nx, nz);
					if (walkMask[nc] && comp[nc] < 0 && regionOf[nc] == regionOf[c]) { comp[nc] = id; stack.push_back(nc); }
				}
			}
		}
		std::vector<int> largest(regionCount, -1);
		for (int id = 0; id < Count(compSize); ++id) {
			int& best = largest[compRegion[id]];
			if (best < 0 || compSize[id] > compSize[best]) best = id;
		}
		std::vector<int> newId(compSize.size(), -1);
		for (int id = 0; id < Count(compSize); ++id) {
			if (id != largest[compRegion[id]] && compSize[id] >= st.regionMinCells) newId[id] = regionCount++;
		}
		for (int c = 0; c < n; ++c) if (comp[c] >= 0 && newId[comp[c]] >= 0) regionOf[c] = newId[comp[c]];
		Check();
	}
	m.regions.assign(regionCount, SRegion());
	regionCentroid.assign(regionCount, SPoint());
	regionCells.assign(regionCount, 0);
	std::vector<std::vector<int>> clrs(regionCount);
	std::vector<double> sumH(regionCount, 0.0), cx(regionCount, 0.0), cz(regionCount, 0.0);
	std::vector<int> veh(regionCount, 0), deep(regionCount, 0), shallow(regionCount, 0);
	for (int r = 0; r < regionCount; ++r) { m.regions[r].id = r; m.regions[r].minH = 1e9f; m.regions[r].maxH = -1e9f; }
	for (int c = 0; c < n; ++c) {
		const int r = regionOf[c];
		SRegion& reg = m.regions[r];
		reg.theatre = theatreOf[c];
		++regionCells[r];
		sumH[r] += hMean[c]; cx[r] += Centre(c).x; cz[r] += Centre(c).z;
		reg.minH = std::min(reg.minH, hMin[c]); reg.maxH = std::max(reg.maxH, hMax[c]);
		if (mob[C_VEH][c] == GO) ++veh[r];
		if (hMean[c] <= -st.standoffDepths[2]) ++deep[r];
		if (hMean[c] > -20.f) ++shallow[r];
		clrs[r].push_back(IsWater(c) ? waterClr[c] : walkClr[c]);
	}
	for (int r = 0; r < regionCount; ++r) {
		SRegion& reg = m.regions[r];
		reg.cells = regionCells[r];
		reg.meanH = (float)(sumH[r] / std::max(1, reg.cells));
		regionCentroid[r] = {(float)(cx[r] / std::max(1, reg.cells)), (float)(cz[r] / std::max(1, reg.cells))};
		reg.vehFraction = (float)veh[r] / std::max(1, reg.cells);
		reg.deepFraction = (float)deep[r] / std::max(1, reg.cells);
		reg.shallowFraction = (float)shallow[r] / std::max(1, reg.cells);
		std::vector<int>& v = clrs[r];
		if (!v.empty()) {
			std::nth_element(v.begin(), v.begin() + v.size() / 2, v.end());
			reg.medianWidth = 2.f * v[v.size() / 2] / 3.f * cell;
			std::nth_element(v.begin(), v.begin() + v.size() / 4, v.end());
			reg.lowWidth = 2.f * v[v.size() / 4] / 3.f * cell;
		}
		m.theatres[reg.theatre].regions.push_back(r);
	}
	// label point: the cell deepest inside its region (BFS from the region boundary)
	{
		std::vector<int> depth(n, -1), queue;
		queue.reserve(n);
		for (int c = 0; c < n; ++c) {
			const int x = g.X(c), z = g.Z(c);
			bool edge = x == 0 || z == 0 || x + 1 == g.gw || z + 1 == g.gh;
			for (int k = 0; k < 4 && !edge; ++k) {
				const int nc = g.Index(x + kDx[k], z + kDz[k]);
				edge = regionOf[nc] != regionOf[c];
			}
			if (edge) { depth[c] = 0; queue.push_back(c); }
		}
		std::size_t head = 0;
		while (head < queue.size()) {
			const int c = queue[head++];
			const int x = g.X(c), z = g.Z(c);
			for (int k = 0; k < 4; ++k) {
				const int nx = x + kDx[k], nz = z + kDz[k];
				if (!g.Inside(nx, nz)) continue;
				const int nc = g.Index(nx, nz);
				if (depth[nc] < 0 && regionOf[nc] == regionOf[c]) { depth[nc] = depth[c] + 1; queue.push_back(nc); }
			}
		}
		std::vector<int> best(regionCount, -1);
		for (int c = 0; c < n; ++c) {
			const int r = regionOf[c];
			if (best[r] < 0 || depth[c] > depth[best[r]]) best[r] = c;
		}
		for (int r = 0; r < regionCount; ++r) {
			m.regions[r].labelCell = best[r];
			m.regions[r].label = best[r] >= 0 ? Centre(best[r]) : regionCentroid[r];
		}
	}
	// chokes: the widest contact per region pair
	std::map<std::pair<int, int>, SContact> bestContact;
	for (const SContact& ct : contacts) {
		if (ct.a == ct.b || ct.a < 0 || ct.b < 0) continue;
		const auto key = std::make_pair(std::min(ct.a, ct.b), std::max(ct.a, ct.b));
		auto it = bestContact.find(key);
		if (it == bestContact.end() || ct.clr > it->second.clr || (ct.clr == it->second.clr && ct.cell < it->second.cell)) bestContact[key] = ct;
	}
	for (const auto& kv : bestContact) {
		SChoke ch;
		ch.id = Count(m.chokes); ch.a = kv.first.first; ch.b = kv.first.second; ch.cell = kv.second.cell;
		ch.pos = Centre(ch.cell);
		ch.width = 2.f * kv.second.clr / 3.f * cell;
		const SPoint& pa = regionCentroid[ch.a];
		const SPoint& pb = regionCentroid[ch.b];
		const float dx = pb.x - pa.x, dz = pb.z - pa.z, len = std::hypot(dx, dz);
		ch.dir = len > 1e-3f ? SPoint{dx / len, dz / len} : SPoint{1.f, 0.f};
		m.chokes.push_back(ch);
		chokePairs.insert(kv.first);
	}
	for (SRegion& reg : m.regions) {
		const int id = reg.id;
		reg.outline = Outline([&](int c) { return regionOf[c] == id; });
	}
	regionClassOk.assign(kGroundClasses, std::vector<int>(regionCount, 0));
	for (int c = 0; c < n; ++c) {
		for (int k = 0; k < kGroundClasses; ++k) if (mob[k][c] != NO_GO) ++regionClassOk[k][regionOf[c]];
	}
}

// ---------------------------------------------------------------- boundaries

void Context::BuildBoundaries()
{
	const int n = g.Size();
	std::map<std::pair<int, int>, SPairInfo> pairs;
	for (int c = 0; c < n; ++c) {
		const int x = g.X(c), z = g.Z(c);
		for (int dir = 0; dir < 2; ++dir) {
			const int nx = x + kDx[dir], nz = z + kDz[dir];
			SEdge e;
			e.cellA = c;
			if (!g.Inside(nx, nz)) {
				e.cellB = -1;
				e.seg = SharedEdge(c, dir);
				pairs[{regionOf[c], -1}].edges.push_back(e);
				continue;
			}
			const int nc = g.Index(nx, nz);
			if (regionOf[nc] == regionOf[c]) continue;
			e.cellB = nc;
			e.seg = SharedEdge(c, dir);
			if (regionOf[c] > regionOf[nc]) std::swap(e.cellA, e.cellB);
			pairs[{std::min(regionOf[c], regionOf[nc]), std::max(regionOf[c], regionOf[nc])}].edges.push_back(e);
		}
		if (x == 0) { SEdge e; e.cellA = c; e.cellB = -1; e.seg = CornerSegment(0, z, 0, z + 1); pairs[{regionOf[c], -1}].edges.push_back(e); }
		if (z == 0) { SEdge e; e.cellA = c; e.cellB = -1; e.seg = CornerSegment(x, 0, x + 1, 0); pairs[{regionOf[c], -1}].edges.push_back(e); }
	}
	const int regionCount = Count(m.regions);
	std::vector<double> neighbourH(regionCount, -1e9), neighbourW(regionCount, 1e9);   // highest and lowest land neighbour mean
	std::vector<char> hasNeighbour(regionCount, 0);
	const int beachCells = std::max(1, (int)std::lround(st.beachDepth / cell));
	auto percentile = [](std::vector<float>& v, float p) {
		if (v.empty()) return 0.f;
		const std::size_t k = std::min(v.size() - 1, (std::size_t)(p * v.size()));
		std::nth_element(v.begin(), v.begin() + k, v.end());
		return v[k];
	};
	// Each edge is measured on its own (slope across it, who can cross it), then
	// the edges of a region pair are grouped by slope band and chained, so one
	// shore can carry a beach run next to a sheer run.
	auto emit = [&](int a, int b, int kind, int classMask, float steep, bool choke,
					const std::vector<SEdge>& edges, const std::vector<int>& members) {
		std::vector<SSegment> segs;
		segs.reserve(members.size());
		for (int i : members) segs.push_back(edges[i].seg);
		for (Polyline& line : ChainSegments(segs)) {
			SBoundary bd;
			bd.id = Count(m.boundaries); bd.kind = kind; bd.a = a; bd.b = b; bd.classMask = classMask;
			bd.steepestDeg = steep; bd.choke = choke;
			bd.width = PolylineLength(line);
			// the cells either side of the middle edge, for landings and the inspector
			const SPoint mid = line[line.size() / 2];
			int bestEdge = members.empty() ? -1 : members.front();
			float bestD = 1e30f;
			for (int i : members) {
				const SPoint em{(edges[i].seg.a.x + edges[i].seg.b.x) * 0.5f, (edges[i].seg.a.z + edges[i].seg.b.z) * 0.5f};
				const float d = std::hypot(em.x - mid.x, em.z - mid.z);
				if (d < bestD) { bestD = d; bestEdge = i; }
			}
			bd.midCellA = bestEdge >= 0 ? edges[bestEdge].cellA : -1;
			bd.midCellB = bestEdge >= 0 ? edges[bestEdge].cellB : -1;
			bd.line = Simplify(line, 0.6f * cell);
			m.boundaries.push_back(std::move(bd));
		}
	};
	for (auto& kv : pairs) {
		const int a = kv.first.first, b = kv.first.second;
		std::vector<SEdge>& edges = kv.second.edges;
		std::vector<int> all(edges.size());
		std::iota(all.begin(), all.end(), 0);
		if (b < 0) {
			emit(a, b, B_EDGE, 0, 0.f, false, edges, all);
			continue;
		}
		const bool waterA = m.theatres[m.regions[a].theatre].kind != T_LAND;
		const bool waterB = m.theatres[m.regions[b].theatre].kind != T_LAND;
		const bool shore = waterA != waterB;
		const int total = Count(edges);
		const bool choke = chokePairs.count(kv.first) > 0;
		std::vector<float> slopeDeg(total, 0.f);
		std::vector<int> passMask(total, 0), band(total, 0);
		std::vector<char> landOk(total, 1), wade(total, 1);
		for (int i = 0; i < total; ++i) {
			const SEdge& e = edges[i];
			const int ca = e.cellA, cb = e.cellB;
			const SPoint mid{(e.seg.a.x + e.seg.b.x) * 0.5f, (e.seg.a.z + e.seg.b.z) * 0.5f};
			const bool vertical = e.seg.a.x == e.seg.b.x;
			// D-328: the cells' passable samples, so a border a unit threads is not a cliff
			float s = std::max(sPass[ca], sPass[cb]);
			s = std::max(s, std::max(SlopeAt(mid.x + (vertical ? 8.f : 0.f), mid.z + (vertical ? 0.f : 8.f)),
									 SlopeAt(mid.x - (vertical ? 8.f : 0.f), mid.z - (vertical ? 0.f : 8.f))));
			if (shore) {
				// the slope a landing unit climbs, measured inland from the water
				const int land = waterA ? cb : ca, water = waterA ? ca : cb;
				const int dx = g.X(land) - g.X(water), dz = g.Z(land) - g.Z(water);
				int x = g.X(land), z = g.Z(land);
				for (int k = 0; k < beachCells && g.Inside(x, z); ++k, x += dx, z += dz) {
					const int lc = g.Index(x, z);
					if (IsWater(lc)) break;
					s = std::max(s, sPass[lc]);
				}
				landOk[i] = BestGround(land) != NO_GO;
				wade[i] = -hMean[water] <= 20.f;
			}
			slopeDeg[i] = SlopeDegrees(s);
			for (int k = 0; k < kGroundClasses; ++k) if (mob[k][ca] != NO_GO && mob[k][cb] != NO_GO) passMask[i] |= (1 << k);
			if (shore) band[i] = (!landOk[i] || slopeDeg[i] > 54.f) ? 2 : (slopeDeg[i] > 33.f ? 1 : 0);
			else band[i] = slopeDeg[i] > 54.f ? 2 : (slopeDeg[i] > 27.f ? 1 : 0);
		}
		if (!waterA && !waterB) {
			// a plateau is higher than every land neighbour, a valley lower than
			// every one; a plain beside a plateau is neither
			neighbourH[a] = std::max(neighbourH[a], (double)m.regions[b].meanH); neighbourW[a] = std::min(neighbourW[a], (double)m.regions[b].meanH);
			neighbourH[b] = std::max(neighbourH[b], (double)m.regions[a].meanH); neighbourW[b] = std::min(neighbourW[b], (double)m.regions[a].meanH);
			hasNeighbour[a] = hasNeighbour[b] = 1;
		}
		for (int bandId = 0; bandId < 3; ++bandId) {
			std::vector<int> members;
			for (int i = 0; i < total; ++i) if (band[i] == bandId) members.push_back(i);
			if (members.empty()) continue;
			std::vector<float> slopes;
			int passable[kGroundClasses] = {0, 0, 0, 0, 0};
			int wadeable = 0;
			for (int i : members) {
				slopes.push_back(slopeDeg[i]);
				for (int k = 0; k < kGroundClasses; ++k) if (passMask[i] & (1 << k)) ++passable[k];
				if (wade[i]) ++wadeable;
			}
			const float steep = percentile(slopes, 0.9f);
			const int n = Count(members);
			int classMask = 0, kind = B_OPEN;
			for (int k = 0; k < kGroundClasses; ++k) if (passable[k] * 2 >= n) classMask |= (1 << k);
			if (!shore && !waterA) {
				const bool botIn = classMask & (1 << C_BOT), vehIn = classMask & (1 << C_VEH);
				if (bandId == 2) kind = B_CLIFF;
				else if (botIn && !vehIn && (m.regions[a].vehFraction >= 0.5f || m.regions[b].vehFraction >= 0.5f)) kind = B_PASS;
				else if (bandId == 1) kind = B_CLIMB;
				else kind = choke ? B_RAMP : B_OPEN;
			} else if (shore) {
				const bool wd = wadeable * 2 >= n;
				if (bandId == 2) { kind = B_SHEER; classMask = 0; }
				else if (bandId == 1) { kind = B_STEEP; classMask = (1 << C_AMPH) | (wd ? (1 << C_BOT) | (1 << C_ALLT) : 0); }
				else {
					kind = B_BEACH;
					classMask = (1 << C_HOVER) | (1 << C_AMPH) | (wd ? (1 << C_BOT) | (1 << C_ALLT) : 0);
					if (steep <= 27.f && wd && (passable[C_VEH] * 2 >= n)) classMask |= (1 << C_VEH);
				}
			} else {
				kind = B_OPEN;   // water to water: a strait boundary, drawn through its choke
				classMask = (1 << C_HOVER) | (1 << C_AMPH) | (1 << C_SHIP) | (1 << C_SUB);
			}
			emit(a, b, kind, classMask, steep, choke, edges, members);
		}
	}
	// character
	regionRise.assign(regionCount, 0.f);
	std::vector<float> waterWidths;
	for (const SRegion& reg : m.regions) if (m.theatres[reg.theatre].kind != T_LAND) waterWidths.push_back(reg.medianWidth);
	const float waterMedian = percentile(waterWidths, 0.5f);
	std::vector<int> waterNeighbours(regionCount, 0);
	for (const SBoundary& bd : m.boundaries) {
		if (bd.b < 0) continue;
		if (m.regions[bd.a].theatre == m.regions[bd.b].theatre && m.theatres[m.regions[bd.a].theatre].kind != T_LAND) {
			++waterNeighbours[bd.a]; ++waterNeighbours[bd.b];
		}
	}
	for (SRegion& reg : m.regions) {
		if (m.theatres[reg.theatre].kind == T_LAND) {
			reg.character = reg.vehFraction >= 0.6f ? R_PLAIN : R_ROUGH;
			if (hasNeighbour[reg.id]) {
				const float above = reg.meanH - (float)neighbourH[reg.id];   // over the highest neighbour
				const float below = (float)neighbourW[reg.id] - reg.meanH;   // under the lowest neighbour
				if (above >= st.highGroundRise) { reg.character = R_PLATEAU; regionRise[reg.id] = above; }
				else if (below >= st.highGroundRise) { reg.character = R_VALLEY; regionRise[reg.id] = -below; }
			}
		} else {
			reg.character = R_WATER;
			if (reg.deepFraction >= 0.6f) reg.character = R_DEEP;
			else if (reg.shallowFraction >= 0.6f) reg.character = R_COAST;
			if (waterNeighbours[reg.id] >= 2 && reg.medianWidth <= 0.5f * waterMedian) reg.character = R_STRAIT;
		}
	}
}

// ---------------------------------------------------------------- landings

void Context::BuildLandings()
{
	const int n = g.Size();
	constexpr int kWindow = 48;
	for (const SBoundary& bd : m.boundaries) {
		if (bd.kind != B_BEACH && bd.kind != B_STEEP) continue;
		const bool waterA = IsWater(bd.midCellA);
		const int land = waterA ? bd.midCellB : bd.midCellA;
		const int water = waterA ? bd.midCellA : bd.midCellB;
		if (land < 0 || water < 0) continue;
		SLanding ld;
		ld.id = Count(m.landings); ld.kind = bd.kind; ld.sea = theatreOf[water];
		ld.region = regionOf[land]; ld.side = sideOf[land]; ld.classMask = bd.classMask;
		ld.width = bd.width;
		ld.inland = (ld.side >= 0 && ld.side < Count(boxDist)) ? boxDist[ld.side][land] * cell : -1.f;
		ld.line = bd.line;
		ld.mid = bd.line[bd.line.size() / 2];
		const int wx = g.X(water), wz = g.Z(water);
		for (int k = 0; k < 3; ++k) {
			float best = -1.f;
			for (int z = std::max(0, wz - kWindow); z <= std::min(g.gh - 1, wz + kWindow); ++z) {
				for (int x = std::max(0, wx - kWindow); x <= std::min(g.gw - 1, wx + kWindow); ++x) {
					const int c = g.Index(x, z);
					if (theatreOf[c] != ld.sea || hMean[c] > -st.standoffDepths[k]) continue;
					const float d = std::hypot((float)(x - wx), (float)(z - wz)) * cell;
					if (best < 0.f || d < best) best = d;
				}
			}
			ld.standoff[k] = best;
		}
		m.landings.push_back(std::move(ld));
	}
	// rank per side: the shortest way inland to that side's box first, then the widest
	std::vector<int> order(m.landings.size());
	std::iota(order.begin(), order.end(), 0);
	std::sort(order.begin(), order.end(), [&](int x, int y) {
		const SLanding& a = m.landings[x];
		const SLanding& b = m.landings[y];
		if (a.side != b.side) return a.side < b.side;
		if (a.inland != b.inland) return a.inland < b.inland;
		if (a.width != b.width) return a.width > b.width;
		return x < y;
	});
	// Only sea landings are ranked: a pond lies inside the land it is in, so its
	// shore is no way in from the water (rank 0, kept for the drawing).
	int side = -2, rank = 0;
	for (int i : order) {
		if (m.landings[i].side != side) { side = m.landings[i].side; rank = 0; }
		const bool sea = m.landings[i].sea >= 0 && m.theatres[m.landings[i].sea].kind == T_SEA;
		m.landings[i].rank = sea ? ++rank : 0;
	}
	// standoff contours per depth over sea and pond cells
	for (int k = 0; k < 3; ++k) {
		const float depth = st.standoffDepths[k];
		auto inside = [&](int c) { return IsWater(c); };
		std::vector<SSegment> segs = Contour(g, hMean, -depth, inside);
		for (Polyline& line : ChainSegments(segs)) {
			for (SPoint& p : line) { p.x *= cell; p.z *= cell; }
			SStandoff so;
			so.depth = depth;
			const int cx = std::clamp((int)(line.front().x / cell), 0, g.gw - 1);
			const int cz = std::clamp((int)(line.front().z / cell), 0, g.gh - 1);
			so.sea = theatreOf[g.Index(cx, cz)];
			so.line = Simplify(line, 0.4f * cell);
			m.standoffs.push_back(std::move(so));
		}
	}
	(void)n;
}

// ---------------------------------------------------------------- avenues

void Context::BuildAvenues()
{
	if (Count(m.sides) < 2 || m.regions.empty()) return;
	const int regionCount = Count(m.regions);
	std::vector<char> source(regionCount, 0), target(regionCount, 0);
	for (int c : sideSeeds[0]) source[regionOf[c]] = 1;
	for (int c : sideSeeds[1]) target[regionOf[c]] = 1;
	struct GraphEdge { int to, boundary; float cost; };
	const char* className[kGroundClasses] = {"vehicle", "bot", "amphibious", "hover", "all-terrain"};
	std::set<std::vector<int>> seen;
	for (int cls = 0; cls < kGroundClasses; ++cls) {
		std::vector<char> ok(regionCount, 0);
		for (int r = 0; r < regionCount; ++r) ok[r] = regionClassOk[cls][r] * 2 >= m.regions[r].cells;
		std::vector<std::vector<GraphEdge>> adj(regionCount);
		for (const SBoundary& bd : m.boundaries) {
			if (bd.b < 0 || !(bd.classMask & (1 << cls)) || !ok[bd.a] || !ok[bd.b]) continue;
			const SPoint mid = bd.line[bd.line.size() / 2];
			const SPoint& la = m.regions[bd.a].label;
			const SPoint& lb = m.regions[bd.b].label;
			const float cost = std::hypot(mid.x - la.x, mid.z - la.z) + std::hypot(mid.x - lb.x, mid.z - lb.z);
			adj[bd.a].push_back({bd.b, bd.id, cost});
			adj[bd.b].push_back({bd.a, bd.id, cost});
		}
		std::unordered_set<int> usedBoundary;
		float firstCost = -1.f;
		for (int found = 0; found < st.avenueMax; ++found) {
			std::vector<float> dist(regionCount, 1e30f);
			std::vector<int> prev(regionCount, -1), prevEdge(regionCount, -1);
			using Item = std::pair<float, int>;
			std::priority_queue<Item, std::vector<Item>, std::greater<Item>> pq;
			for (int r = 0; r < regionCount; ++r) if (source[r] && ok[r]) { dist[r] = 0.f; pq.emplace(0.f, r); }
			int goal = -1;
			while (!pq.empty()) {
				const auto [d, r] = pq.top();
				pq.pop();
				if (d > dist[r]) continue;
				if (target[r]) { goal = r; break; }
				for (const GraphEdge& e : adj[r]) {
					if (usedBoundary.count(e.boundary)) continue;
					const float nd = d + e.cost;
					if (nd < dist[e.to]) { dist[e.to] = nd; prev[e.to] = r; prevEdge[e.to] = e.boundary; pq.emplace(nd, e.to); }
				}
			}
			if (goal < 0) break;
			if (firstCost < 0.f) firstCost = std::max(dist[goal], 1.f);
			else if (dist[goal] > st.avenueDetour * firstCost) break;
			SAvenue av;
			av.cls = cls;
			for (int r = goal; r >= 0; r = prev[r]) {
				av.regions.push_back(r);
				if (prevEdge[r] >= 0) av.crossings.push_back(prevEdge[r]);
			}
			std::reverse(av.regions.begin(), av.regions.end());
			std::reverse(av.crossings.begin(), av.crossings.end());
			for (int b : av.crossings) usedBoundary.insert(b);
			if (!seen.insert(av.regions).second) continue;   // a less capable class already owns this route
			// the spine runs from our side's box to the enemy's, through every
			// region label and crossing on the way
			auto widthAt = [&](const SPoint& p) {
				const int cx = std::clamp((int)(p.x / cell), 0, g.gw - 1);
				const int cz = std::clamp((int)(p.z / cell), 0, g.gh - 1);
				const int c = g.Index(cx, cz);
				return 2.f * std::max(walkClr[c], waterClr[c]) / 3.f * cell;
			};
			av.spine.push_back(m.sides[0].label);
			av.spineWidth.push_back(widthAt(m.sides[0].label));
			for (int i = 0; i < Count(av.regions); ++i) {
				const SRegion& reg = m.regions[av.regions[i]];
				av.spine.push_back(reg.label);
				const int lc = reg.labelCell >= 0 ? reg.labelCell : 0;
				av.spineWidth.push_back(2.f * std::max(walkClr[lc], waterClr[lc]) / 3.f * cell);
				if (i < Count(av.crossings)) {
					const SBoundary& bd = m.boundaries[av.crossings[i]];
					av.spine.push_back(bd.line[bd.line.size() / 2]);
					av.spineWidth.push_back(bd.width);
				}
			}
			av.spine.push_back(m.sides[1].label);
			av.spineWidth.push_back(widthAt(m.sides[1].label));
			av.length = PolylineLength(av.spine);
			av.specialist = cls == C_HOVER || cls == C_ALLT;
			const SPoint& mid = av.spine[av.spine.size() / 2];
			av.name = Compass(mid.x, mid.z) + " avenue (" + className[cls] + ")";
			av.id = Count(m.avenues);
			m.avenues.push_back(std::move(av));
		}
		Check();
	}
}

// ---------------------------------------------------------------- key terrain

void Context::BuildKeyTerrain()
{
	auto cellAt = [&](float x, float z) {
		const int cx = std::clamp((int)(x / cell), 0, g.gw - 1);
		const int cz = std::clamp((int)(z / cell), 0, g.gh - 1);
		return g.Index(cx, cz);
	};
	auto avenueOf = [&](int region) {
		for (const SAvenue& av : m.avenues) for (int r : av.regions) if (r == region) return av.id;
		return -1;
	};
	for (const SPoint& p : in.geos) {
		const int c = cellAt(p.x, p.z);
		SKey k;
		k.kind = K_GEO; k.pos = p; k.value = 1.f; k.region = regionOf[c]; k.side = sideOf[c]; k.avenue = avenueOf(k.region);
		m.keys.push_back(k);
	}
	for (const SClusterInput& cl : in.clusters) {
		const int c = cellAt(cl.x, cl.z);
		SKey k;
		k.kind = K_METAL; k.pos = {cl.x, cl.z}; k.value = cl.income; k.region = regionOf[c]; k.side = sideOf[c]; k.avenue = avenueOf(k.region);
		m.keys.push_back(k);
	}
	for (const SRegion& reg : m.regions) {
		if (reg.character != R_PLATEAU) continue;
		SKey k;
		k.kind = K_HIGH; k.pos = reg.label; k.value = regionRise[reg.id]; k.region = reg.id;
		k.side = reg.labelCell >= 0 ? sideOf[reg.labelCell] : -1; k.avenue = avenueOf(reg.id);
		m.keys.push_back(k);
	}
	for (const STheatre& t : m.theatres) {
		if (t.kind == T_LAND && !t.hasBox) {
			SKey k;
			k.kind = K_ISLAND; k.pos = t.centre; k.value = (float)t.cells;
			const int c = cellAt(t.centre.x, t.centre.z);
			k.region = regionOf[c]; k.side = sideOf[c];
			m.keys.push_back(k);
		} else if (t.kind == T_POND) {
			SKey k;
			k.kind = K_POND; k.pos = t.centre; k.value = (float)t.cells;
			const int c = cellAt(t.centre.x, t.centre.z);
			k.region = regionOf[c]; k.side = sideOf[c];
			m.keys.push_back(k);
		}
	}
	for (const SRock& rock : rocks) {
		SKey k;
		k.kind = K_ISLAND; k.pos = rock.centre; k.value = (float)rock.cells;
		const int c = cellAt(rock.centre.x, rock.centre.z);
		k.region = regionOf[c]; k.side = sideOf[c];
		m.keys.push_back(k);
	}
}

// ---------------------------------------------------------------- finish

void Context::Finish()
{
	m.regionOf = regionOf;
	m.sideOf = sideOf;
	std::uint64_t h = 1469598103934665603ULL;
	h = Fnv1a(h, regionOf.data(), regionOf.size() * sizeof(int));
	h = Fnv1a(h, m.groundOf.data(), m.groundOf.size());
	const int counts[] = {Count(m.theatres), Count(m.regions), Count(m.boundaries), Count(m.chokes), Count(m.avenues), Count(m.landings)};
	h = Fnv1a(h, counts, sizeof(counts));
	m.fingerprint = h;
	for (int c = 0; c < g.Size(); ++c) {
		if (regionOf[c] < 0) { m.checkFailures.push_back("a cell belongs to no region"); break; }
	}
	for (const SBoundary& bd : m.boundaries) {
		if (bd.b >= 0 && bd.a == bd.b) { m.checkFailures.push_back("a boundary joins a region to itself"); break; }
	}
	for (const SAvenue& av : m.avenues) {
		if (av.spine.size() < 2) { m.checkFailures.push_back("an avenue has no spine"); break; }
	}
}

void Context::Run()
{
	const auto t0 = Clock::now();
	auto stage = [&](double& slot, void (Context::*fn)()) {
		const auto s = Clock::now();
		(this->*fn)();
		slot = Ms(s);
		Check();
	};
	stage(m.timings.gridMs, &Context::BuildGrid);
	stage(m.timings.mobilityMs, &Context::BuildMobility);
	stage(m.timings.sidesMs, &Context::BuildSides);
	stage(m.timings.theatresMs, &Context::BuildTheatres);
	stage(m.timings.regionsMs, &Context::BuildRegions);
	stage(m.timings.boundariesMs, &Context::BuildBoundaries);
	stage(m.timings.landingsMs, &Context::BuildLandings);
	stage(m.timings.avenuesMs, &Context::BuildAvenues);
	stage(m.timings.keyMs, &Context::BuildKeyTerrain);
	Finish();
	m.timings.totalMs = Ms(t0);
}

} // namespace

std::shared_ptr<SModel> Analyse(const SInput& input, const SSettings& settings, const std::atomic<bool>* cancel)
{
	auto model = std::make_shared<SModel>();
	Context ctx(input, settings, cancel, *model);
	ctx.Run();
	return model;
}

} // namespace circuit::field
