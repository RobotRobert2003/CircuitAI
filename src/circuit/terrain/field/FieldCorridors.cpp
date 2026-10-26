/*
 * FieldCorridors.cpp
 *
 * D-358: see FieldCorridors.h. Stage order per class: fine passability (shared
 * with every router), clearance, obstacles, candidate routes, corridor classes
 * by obstacle separation, ownership, centre lines, records. Deterministic:
 * every tie goes to the lower cell or corridor index.
 */

#include "terrain/field/FieldCorridors.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <limits>
#include <numeric>
#include <queue>
#include <string>
#ifdef FIELD_DEBUG
#include <cstdio>
#define CORRIDOR_TRACE(...) std::fprintf(stderr, __VA_ARGS__)
#else
#define CORRIDOR_TRACE(...) do {} while (0)
#endif

namespace circuit::field {

// ---------------------------------------------------------------- passability

void FinePassability(const std::vector<float>& slope, int slopeStride, int slopeRows,
					 const std::vector<float>& height, int heightStride, int heightRows,
					 bool waterHarmful, SFinePass& out)
{
	out.g.gw = std::max(1, slopeStride);
	out.g.gh = std::max(1, slopeRows);
	const int n = out.g.Size();
	for (int k = 0; k < _CLASSES_; ++k) out.pass[k].assign(n, 0);
	out.hMean.assign(n, 0.f);
	out.hMax.assign(n, 0.f);
	const int hw = std::max(1, heightStride), hh = std::max(1, heightRows);
	const float limit[kGroundClasses] = {kSlopeTank, kSlopeBot, kSlopeBot, kSlopeHover, kSlopeAllTerrain};
	for (int z = 0; z < out.g.gh; ++z) {
		for (int x = 0; x < out.g.gw; ++x) {
			const int c = out.g.Index(x, z);
			// the four 8-elmo height samples under the 16-elmo slope sample
			float sum = 0.f, hi = -1e9f;
			int count = 0;
			for (int j = 0; j < 2; ++j) {
				const int hz = std::min(hh - 1, z * 2 + j);
				for (int i = 0; i < 2; ++i) {
					const int hx = std::min(hw - 1, x * 2 + i);
					const std::size_t idx = (std::size_t)hz * hw + hx;
					const float v = idx < height.size() ? height[idx] : 0.f;
					sum += v; hi = std::max(hi, v); ++count;
				}
			}
			const float mean = count > 0 ? sum / count : 0.f;
			out.hMean[c] = mean; out.hMax[c] = hi;
			const std::size_t si = (std::size_t)z * slopeStride + x;
			const float s = si < slope.size() ? slope[si] : 0.f;
			const float depth = -mean;
			const bool water = depth > 0.f;
			const bool harm = waterHarmful && water;
			const bool wadable = depth <= kWadeDepth && !harm;
			for (int k = 0; k < kGroundClasses; ++k) {
				bool ok = s <= limit[k];
				if (k == C_HOVER) ok = water || ok;             // hovers float over any water, lava included
				else if (k == C_AMPH) ok = harm ? false : (water || ok);   // amphibious: any safe water, bot slopes on land, never lava
				else ok = ok && wadable;                        // land classes stop 20 deep
				out.pass[k][c] = ok ? 1 : 0;
			}
			out.pass[C_SHIP][c] = hi <= -kShipDepth ? 1 : 0;
			out.pass[C_SUB][c] = hi <= -kSubDepth ? 1 : 0;
		}
	}
}

namespace {

constexpr int kNbx[8] = {1, -1, 0, 0, 1, 1, -1, -1};
constexpr int kNbz[8] = {0, 0, 1, -1, 1, -1, 1, -1};
constexpr float kSqrt2 = 1.41421356f;
constexpr float kInf = std::numeric_limits<float>::max();
constexpr double kInfD = std::numeric_limits<double>::max();
constexpr double kSqrt2D = 1.4142135623730951;

// Tunables of the planner that are not levers in field.json, named here so
// they can be read, tweaked and shared (the levers are SSettings).
constexpr float kRoutePenalty = 3.f;           // D-358: cost multiplier around a found route before the next search
constexpr float kRoutePenaltyCap = 1e4f;       // D-358: the penalty's ceiling, so a late route is still cheapest where open
constexpr float kWidthPerClearance = 32.f / 3.f;   // elmos of width per clearance unit (thirds of a 16-elmo cell, both sides)
constexpr std::size_t kChokeMarginShare = 5;   // the choke is sought outside the first and last fifth of the centre
constexpr float kCentreSimplifyShare = 0.6f;   // Simplify tolerance of a centre line, as a share of a field cell
constexpr int kProgressBins = 16;              // D-360: progress bins for a passage's lateral extent
constexpr std::size_t kBinMinCells = 8;        // D-360: cells a bin needs before it counts
constexpr std::size_t kExtentLowPercentile = 5, kExtentHighPercentile = 95;   // D-360: the bin's spread
constexpr float kLaneHalfSpacingShare = 0.5f;  // D-360: the narrowest extent must hold this share of a spacing per lane
constexpr float kBandMinSpan = 1e-3f;          // D-360: a band's smallest lateral span, elmos (division guard)
constexpr int kEdgeUnitsPerClearance = 2;      // D-360: a field-cell third is two 16-elmo thirds
constexpr float kOutOfBandCost = 8.f;          // D-360: a lane's step outside its band, inside its passage
constexpr float kLegEdgeCost = 8.f;            // D-362: a leg's step on a cell with a closed 16-elmo quarter
constexpr float kLegClearanceWeight = 12.f;    // D-362: a leg's step costs 1 + weight / (clearance + 1)

const char* ClassName(int cls)
{
	switch (cls) {
		case C_VEH: return "vehicle"; case C_BOT: return "bot"; case C_AMPH: return "amphibious";
		case C_HOVER: return "hover"; case C_ALLT: return "all-terrain"; case C_SHIP: return "ship";
		case C_SUB: return "submarine"; default: return "?";
	}
}

std::string Compass(float x, float z, int mapWidth, int mapHeight)
{
	const float fx = x / std::max(1, mapWidth), fz = z / std::max(1, mapHeight);
	std::string ns = fz < 1.f / 3.f ? "North" : (fz > 2.f / 3.f ? "South" : "");
	std::string ew = fx < 1.f / 3.f ? "West" : (fx > 2.f / 3.f ? "East" : "");
	if (ns.empty() && ew.empty()) return "Central";
	if (ns.empty()) return ew;
	if (ew.empty()) return ns;
	return ns + "-" + ew;
}

// Dijkstra on the field grid over `open` cells, eight neighbours without
// corner cutting, edge cost = step length x the mean of the two cells'
// `cost`. Stops at the first goal reached and returns the path from a source
// to it (empty when none). O(N log N).
// Distances are doubles and a relaxation must strictly improve: with float
// sums near the penalty cap an equal-distance tie could point `prev` at a
// cell of the same distance and close a cycle (the first test build looped
// in the path walk until bad_alloc). Ties are resolved by the heap's
// (distance, cell) order, which is deterministic.
struct Search {
	const SGridShape& g;
	const std::vector<char>& open;
	std::vector<double> dist;
	std::vector<int> prev;
	explicit Search(const SGridShape& g, const std::vector<char>& open) : g(g), open(open) {}
	std::vector<int> Run(const std::vector<int>& sources, const std::vector<char>& goal, const std::vector<float>& cost, int* reached = nullptr)
	{
		const int n = g.Size();
		dist.assign(n, kInfD);
		prev.assign(n, -1);
		using Item = std::pair<double, int>;
		std::priority_queue<Item, std::vector<Item>, std::greater<Item>> pq;
		for (int s : sources) {
			if (s < 0 || s >= n || !open[s] || dist[s] == 0.0) continue;
			dist[s] = 0.0;
			pq.emplace(0.0, s);
		}
		int found = -1;
		while (!pq.empty()) {
			const auto [d, c] = pq.top();
			pq.pop();
			if (d > dist[c]) continue;
			if (goal[c]) { found = c; break; }
			const int x = g.X(c), z = g.Z(c);
			for (int k = 0; k < 8; ++k) {
				const int nx = x + kNbx[k], nz = z + kNbz[k];
				if (!g.Inside(nx, nz)) continue;
				const int nc = g.Index(nx, nz);
				if (!open[nc]) continue;
				if (k >= 4 && (!open[g.Index(x, nz)] || !open[g.Index(nx, z)])) continue;
				const double nd = d + (k < 4 ? 1.0 : kSqrt2D) * 0.5 * (double(cost[c]) + double(cost[nc]));
				if (nd < dist[nc]) {
					dist[nc] = nd; prev[nc] = c;
					pq.emplace(nd, nc);
				}
			}
		}
		if (reached) *reached = found;
		std::vector<int> path;
		for (int c = found; c >= 0; c = prev[c]) path.push_back(c);
		std::reverse(path.begin(), path.end());
		return path;
	}
};

float PathLength(const SGridShape& g, const std::vector<int>& path, float cell)
{
	float length = 0.f;
	for (std::size_t i = 1; i < path.size(); ++i) {
		const int dx = std::abs(g.X(path[i]) - g.X(path[i - 1])), dz = std::abs(g.Z(path[i]) - g.Z(path[i - 1]));
		length += (dx && dz) ? kSqrt2 * cell : cell;
	}
	return length;
}

// Even-odd scanline fill of a polygon given in fine-grid cell units (vertex =
// cell centre), into `inside` (fine grid), bounded by the polygon's rows.
void FillPolygon(const SGridShape& fg, const std::vector<std::pair<float, float>>& poly, std::vector<char>& inside, int& z0, int& z1)
{
	std::fill(inside.begin(), inside.end(), 0);
	z0 = fg.gh; z1 = -1;
	if (poly.size() < 3) return;
	float lo = 1e9f, hi = -1e9f;
	for (const auto& p : poly) { lo = std::min(lo, p.second); hi = std::max(hi, p.second); }
	z0 = std::max(0, (int)std::floor(lo)); z1 = std::min(fg.gh - 1, (int)std::ceil(hi));
	std::vector<float> xs;
	for (int z = z0; z <= z1; ++z) {
		const float zc = z + 0.5f;
		xs.clear();
		for (std::size_t i = 0, j = poly.size() - 1; i < poly.size(); j = i++) {
			const auto& a = poly[i]; const auto& b = poly[j];
			if ((a.second > zc) != (b.second > zc)) {
				xs.push_back(a.first + (zc - a.second) * (b.first - a.first) / (b.second - a.second));
			}
		}
		std::sort(xs.begin(), xs.end());
		for (std::size_t i = 0; i + 1 < xs.size(); i += 2) {
			const int xa = std::max(0, (int)std::ceil(xs[i] - 0.5f)), xb = std::min(fg.gw - 1, (int)std::floor(xs[i + 1] - 0.5f));
			for (int x = xa; x <= xb; ++x) inside[fg.Index(x, z)] = 1;
		}
	}
}

} // namespace

// ---------------------------------------------------------------- the planner

void BuildCorridors(const SInput& in, const SCorridorContext& ctx, const SSettings& st,
					const std::atomic<bool>* cancel, SModel& m)
{
	auto check = [&]() { if (cancel != nullptr && cancel->load(std::memory_order_relaxed)) throw Cancelled(); };
	m.obstacles.clear();
	m.corridors.clear();
	for (int k = 0; k < _CLASSES_; ++k) { m.corridorOf[k].clear(); m.clearanceOf[k].clear(); }
	if (ctx.sideSeeds == nullptr || ctx.sideSeeds->size() < 2 || ctx.cell <= 0) return;
	const SGridShape g = ctx.g;
	const int n = g.Size();
	const float cell = (float)ctx.cell;
	SFinePass fine;
	FinePassability(in.slope, in.slopeStride, in.slopeRows, in.height, in.heightStride, in.heightRows, in.waterHarmful, fine);
	const SGridShape fg = fine.g;
	const int n16 = fg.Size();
	const int ratio = std::max(1, ctx.cell / 16);
	// fine cell -> field cell
	auto coarseOf = [&](int fc) { return g.Index(std::min(g.gw - 1, fg.X(fc) / ratio), std::min(g.gh - 1, fg.Z(fc) / ratio)); };
	const SPoint axisFrom = ctx.sideLabel[0], axisTo = ctx.sideLabel[1];
	const float axLen = std::max(1.f, std::hypot(axisTo.x - axisFrom.x, axisTo.z - axisFrom.z));
	const float ax = (axisTo.x - axisFrom.x) / axLen, az = (axisTo.z - axisFrom.z) / axLen;
	auto forwardOf = [&](float x, float z) { return (x - axisFrom.x) * ax + (z - axisFrom.z) * az; };
	auto sidewaysOf = [&](float x, float z) { return -(x - axisFrom.x) * az + (z - axisFrom.z) * ax; };
	auto centreOf = [&](int c) { return SPoint{(g.X(c) + 0.5f) * cell, (g.Z(c) + 0.5f) * cell}; };
	const int obstacleMin = std::max(1, (int)(st.obstacleMinShare * n16));
	const int band = std::max(1, (int)std::lround(st.corridorBand / cell));
	const int classes[] = {C_VEH, C_BOT, C_AMPH, C_HOVER, C_ALLT, C_SHIP};

	std::vector<char> open(n), goal(n), free(n), fineMask(n16), kept16(n16), inside(n16);
	std::vector<int> clr16, clr(n), clrMin(n), comp(n16);
	std::vector<float> cost(n), unit(n, 1.f);
	std::vector<std::int16_t> owner(n);
	std::vector<char> seamBins, blockedBins;

	for (int cls : classes) {
		check();
		CORRIDOR_TRACE("corridors: class %d n=%d n16=%d ratio=%d\n", cls, n, n16, ratio);
		const auto& pass = fine.pass[cls];
		// 1. open field cells (any fine cell open) and clearance (fine, then the best per field cell)
		std::fill(open.begin(), open.end(), 0);
		for (int fc = 0; fc < n16; ++fc) { fineMask[fc] = pass[fc]; if (pass[fc]) open[coarseOf(fc)] = 1; }
		ChamferDistance(fg, fineMask, clr16);
		std::fill(clr.begin(), clr.end(), 0);
		std::fill(clrMin.begin(), clrMin.end(), 255);
		for (int fc = 0; fc < n16; ++fc) { int& v = clr[coarseOf(fc)]; v = std::max(v, clr16[fc]); int& w = clrMin[coarseOf(fc)]; w = std::min(w, clr16[fc]); }
		// 2. obstacles: closed fine components (4-connected) of at least obstacleMin cells
		std::fill(comp.begin(), comp.end(), -1);
		std::fill(kept16.begin(), kept16.end(), 0);
		std::vector<int> compSize;
		std::vector<SPoint> compCentre;
		std::vector<int> stack;
		for (int fc = 0; fc < n16; ++fc) {
			if (pass[fc] || comp[fc] >= 0) continue;
			const int id = (int)compSize.size();
			int cells = 0;
			double sx = 0.0, sz = 0.0;
			stack.assign(1, fc);
			comp[fc] = id;
			while (!stack.empty()) {
				const int c = stack.back(); stack.pop_back();
				++cells; sx += fg.X(c); sz += fg.Z(c);
				const int x = fg.X(c), z = fg.Z(c);
				for (int k = 0; k < 4; ++k) {
					const int nx = x + kNbx[k], nz = z + kNbz[k];
					if (!fg.Inside(nx, nz)) continue;
					const int nc = fg.Index(nx, nz);
					if (pass[nc] || comp[nc] >= 0) continue;
					comp[nc] = id;
					stack.push_back(nc);
				}
			}
			compSize.push_back(cells);
			compCentre.push_back({(float)(sx / cells + 0.5) * 16.f, (float)(sz / cells + 0.5) * 16.f});
		}
		for (std::size_t id = 0; id < compSize.size(); ++id) {
			if (compSize[id] < obstacleMin) continue;
			SObstacle o;
			o.id = (int)m.obstacles.size(); o.cls = cls; o.cells = compSize[id]; o.centre = compCentre[id];
			m.obstacles.push_back(o);
		}
		for (int fc = 0; fc < n16; ++fc) kept16[fc] = comp[fc] >= 0 && compSize[comp[fc]] >= obstacleMin;
		CORRIDOR_TRACE("corridors: obstacles done (%zu)\n", m.obstacles.size());
		// 3. the two sides' seeds on open cells
		std::vector<int> seedsA, seedsB;
		for (int c : (*ctx.sideSeeds)[0]) if (c >= 0 && c < n && open[c]) seedsA.push_back(c);
		for (int c : (*ctx.sideSeeds)[1]) if (c >= 0 && c < n && open[c]) seedsB.push_back(c);
		if (seedsA.empty() || seedsB.empty()) continue;
		std::fill(goal.begin(), goal.end(), 0);
		for (int c : seedsB) goal[c] = 1;
		// 4. candidate routes by the penalty method
		CORRIDOR_TRACE("corridors: seeds %zu/%zu\n", seedsA.size(), seedsB.size());
		std::fill(cost.begin(), cost.end(), 1.f);
		Search search(g, open);
		std::vector<std::vector<int>> routes;
		float first = -1.f;
		for (int it = 0; it < std::max(1, st.corridorMax); ++it) {
			check();
			std::vector<int> path = search.Run(seedsA, goal, cost);
			CORRIDOR_TRACE("corridors: route %d cells %zu\n", it, path.size());
			if (path.size() < 2) break;
			const float length = PathLength(g, path, cell);
			if (first < 0.f) first = std::max(length, cell);
			else if (length > st.corridorDetour * first) break;
			for (int c : path) {
				const int x = g.X(c), z = g.Z(c);
				for (int dz = -band; dz <= band; ++dz) for (int dx = -band; dx <= band; ++dx) {
					if (g.Inside(x + dx, z + dz)) cost[g.Index(x + dx, z + dz)] *= kRoutePenalty;
				}
			}
			// the penalty grows without bound otherwise; cap it so a late route is still cheapest where open
			for (float& v : cost) v = std::min(v, kRoutePenaltyCap);
			routes.push_back(std::move(path));
		}
		CORRIDOR_TRACE("corridors: routes %zu\n", routes.size());
		if (routes.empty()) continue;
		// 5. lateral order and the wall test between neighbours
		std::vector<float> lateral(routes.size(), 0.f);
		for (std::size_t r = 0; r < routes.size(); ++r) {
			double sum = 0.0;
			for (int c : routes[r]) { const SPoint p = centreOf(c); sum += sidewaysOf(p.x, p.z); }
			lateral[r] = (float)(sum / std::max<std::size_t>(1, routes[r].size()));
		}
		std::vector<int> order(routes.size());
		std::iota(order.begin(), order.end(), 0);
		std::sort(order.begin(), order.end(), [&](int a, int b) { return lateral[a] != lateral[b] ? lateral[a] < lateral[b] : a < b; });
		std::vector<int> group(routes.size(), -1);
		int groups = 0;
		const int binCount = std::max(1, (int)std::ceil((in.mapWidth + in.mapHeight) / 16.f)) + 2;
		seamBins.assign(binCount, 0); blockedBins.assign(binCount, 0);
		auto wall = [&](const std::vector<int>& a, const std::vector<int>& b) {
			std::vector<std::pair<float, float>> poly;
			poly.reserve(a.size() + b.size());
			const float half = ratio * 0.5f;
			for (int c : a) poly.emplace_back(g.X(c) * ratio + half, g.Z(c) * ratio + half);
			for (auto it = b.rbegin(); it != b.rend(); ++it) poly.emplace_back(g.X(*it) * ratio + half, g.Z(*it) * ratio + half);
			int z0, z1;
			FillPolygon(fg, poly, inside, z0, z1);
			std::fill(seamBins.begin(), seamBins.end(), 0);
			std::fill(blockedBins.begin(), blockedBins.end(), 0);
			int seam = 0, blocked = 0;
			for (int z = std::max(0, z0); z <= z1 && z < fg.gh; ++z) {
				for (int x = 0; x < fg.gw; ++x) {
					const int fc = fg.Index(x, z);
					if (!inside[fc]) continue;
					const int bin = std::clamp((int)(forwardOf((x + 0.5f) * 16.f, (z + 0.5f) * 16.f) / 16.f) + binCount / 2, 0, binCount - 1);
					if (!seamBins[bin]) { seamBins[bin] = 1; ++seam; }
					if (kept16[fc] && !blockedBins[bin]) { blockedBins[bin] = 1; ++blocked; }
				}
			}
			return seam > 0 && (float)blocked >= st.seamBlocked * (float)seam;
		};
		for (std::size_t i = 0; i < order.size(); ++i) {
			if (i == 0 || wall(routes[order[i - 1]], routes[order[i]])) group[order[i]] = groups++;
			else group[order[i]] = group[order[i - 1]];
		}
		CORRIDOR_TRACE("corridors: groups %d\n", groups);
		// 6. ownership: the nearest route's group over the open cells
		{
			std::vector<int> sources;
			std::vector<int> sourceGroup(n, -1);
			for (std::size_t r = 0; r < routes.size(); ++r) for (int c : routes[r]) {
				if (sourceGroup[c] < 0 || group[r] < sourceGroup[c]) sourceGroup[c] = group[r];
			}
			for (int c = 0; c < n; ++c) if (sourceGroup[c] >= 0) sources.push_back(c);
			std::fill(owner.begin(), owner.end(), (std::int16_t)-1);
			using Item = std::pair<double, int>;
			std::vector<double> dist(n, kInfD);
			std::priority_queue<Item, std::vector<Item>, std::greater<Item>> pq;
			for (int s : sources) { dist[s] = 0.0; owner[s] = (std::int16_t)sourceGroup[s]; pq.emplace(0.0, s); }
			while (!pq.empty()) {
				const auto [d, c] = pq.top();
				pq.pop();
				if (d > dist[c]) continue;
				const int x = g.X(c), z = g.Z(c);
				for (int k = 0; k < 8; ++k) {
					const int nx = x + kNbx[k], nz = z + kNbz[k];
					if (!g.Inside(nx, nz)) continue;
					const int nc = g.Index(nx, nz);
					if (!open[nc]) continue;
					const double nd = d + (k < 4 ? 1.0 : kSqrt2D);
					if (nd < dist[nc] || (nd == dist[nc] && owner[c] < owner[nc])) { dist[nc] = nd; owner[nc] = owner[c]; pq.emplace(nd, nc); }
				}
			}
		}
		CORRIDOR_TRACE("corridors: ownership done\n");
		// 7. centre line, lanes and records per group (a passage)
		const int firstId = (int)m.corridors.size();
		std::vector<std::int16_t> laneOwner(n, (std::int16_t)-1);   // cell -> record index within this class
		int records = 0;
		// a record from a centre path over the group's cells
		auto makeRecord = [&](const std::vector<int>& path, int routeCount, int lane, int lanes) {
			SCorridor cr;
			cr.id = (int)m.corridors.size(); cr.cls = cls; cr.routes = routeCount; cr.lane = lane; cr.lanes = lanes;
			// width profile along the full path, the narrowest in the middle 60 percent
			std::vector<float> widthFull(path.size());
			for (std::size_t i = 0; i < path.size(); ++i) widthFull[i] = clr[path[i]] * kWidthPerClearance;
			const std::size_t lo = path.size() / kChokeMarginShare, hi = std::max(lo + 1, path.size() - path.size() / kChokeMarginShare);
			std::size_t best = lo;
			for (std::size_t i = lo; i < hi && i < path.size(); ++i) if (widthFull[i] < widthFull[best]) best = i;
			cr.narrowest = widthFull.empty() ? 0.f : widthFull[best];
			cr.choke = centreOf(path[best]);
			cr.length = PathLength(g, path, cell);
			double meanW = 0.0;
			for (float w : widthFull) meanW += w;
			cr.meanWidth = widthFull.empty() ? 0.f : (float)(meanW / widthFull.size());
			cr.specialist = cr.narrowest < st.footprintWidth;
			Polyline full;
			full.reserve(path.size());
			for (int c : path) full.push_back(centreOf(c));
			cr.centre = Simplify(full, kCentreSimplifyShare * cell);
			cr.width.reserve(cr.centre.size());
			for (const SPoint& p : cr.centre) {
				const int c = g.Index(std::clamp((int)(p.x / cell), 0, g.gw - 1), std::clamp((int)(p.z / cell), 0, g.gh - 1));
				cr.width.push_back(clr[c] * kWidthPerClearance);
			}
			// the choke's vertex in the simplified centre: the nearest vertex
			float bestD = 1e30f;
			for (std::size_t i = 0; i < cr.centre.size(); ++i) {
				const float d = std::hypot(cr.centre[i].x - cr.choke.x, cr.centre[i].z - cr.choke.z);
				if (d < bestD) { bestD = d; cr.chokeIndex = (int)i; }
			}
			const SPoint mid = CorridorPoint(cr, 0.5f);
			cr.lateral = sidewaysOf(mid.x, mid.z);
			cr.name = Compass(mid.x, mid.z, in.mapWidth, in.mapHeight) + " corridor (" + ClassName(cls) + ")";
			if (lanes > 1) cr.name += " lane " + std::to_string(lane + 1) + " of " + std::to_string(lanes);
			return cr;
		};
		for (int gi = 0; gi < groups; ++gi) {
			check();
			int firstRoute = -1, routeCount = 0;
			for (std::size_t r = 0; r < routes.size(); ++r) if (group[r] == gi) { ++routeCount; if (firstRoute < 0) firstRoute = (int)r; }
			std::fill(free.begin(), free.end(), 0);
			for (int c = 0; c < n; ++c) free[c] = open[c] && owner[c] == gi;
			for (std::size_t r = 0; r < routes.size(); ++r) if (group[r] == gi) for (int c : routes[r]) free[c] = 1;
			std::vector<int> a, b;
			for (int c : seedsA) if (free[c]) a.push_back(c);
			for (int c : seedsB) if (free[c]) b.push_back(c);
			if (a.empty()) a.push_back(routes[firstRoute].front());
			if (b.empty()) b.push_back(routes[firstRoute].back());
			std::fill(goal.begin(), goal.end(), 0);
			for (int c : b) goal[c] = 1;
			for (int c = 0; c < n; ++c) cost[c] = 1.f / (float)(clr[c] + 1);
			Search centreSearch(g, free);
			std::vector<int> path = centreSearch.Run(a, goal, cost);
			if (path.size() < 2) path = routes[firstRoute];
			SCorridor whole = makeRecord(path, routeCount, 0, 1);
			// D-360: lanes side by side inside a wide passage. Every cell of the
			// passage is projected onto the centre (progress, signed offset); the
			// lateral extent is the median over 16 progress bins of the 5..95
			// percentile spread; the passage holds round(extent / lane_spacing)
			// lanes, at most (narrowest extent away from the start bins) / (lane_spacing
			// / 2) so two lanes never share one choke, at most lane_max. Each lane is the max-clearance path inside
			// its lateral band (clearance capped by the distance to the band's edge,
			// so the lane sits mid-band), the band limits interpolated between bin
			// centres; outside its band, still inside the passage, a cell costs eight
			// times more, so a lane detours only where a rock forces it. O(cells x
			// centre vertices) for the projection and one search per lane, once per
			// process; the open field test guards the count and the spacing.
			int k = 1;
			std::vector<std::vector<int>> lanePaths;
			std::vector<int> bandOf;
			if (st.laneMax > 1 && st.laneSpacing > 0.f && whole.centre.size() >= 2) {
				const Polyline& line = whole.centre;
				std::vector<float> cum(line.size(), 0.f);
				for (std::size_t i = 1; i < line.size(); ++i) cum[i] = cum[i - 1] + std::hypot(line[i].x - line[i - 1].x, line[i].z - line[i - 1].z);
				const float total = cum.back();
				std::vector<std::vector<float>> bins(kProgressBins);
				std::vector<float> prog(n, -1.f), off(n, 0.f);
				if (total > 0.f) {
					for (int c = 0; c < n; ++c) {
						if (!(open[c] && owner[c] == gi)) continue;
						const SPoint p = centreOf(c);
						float bestD2 = 1e30f, at = 0.f, sgn = 1.f;
						for (std::size_t i = 1; i < line.size(); ++i) {
							const SPoint& s0 = line[i - 1]; const SPoint& s1 = line[i];
							const float dx = s1.x - s0.x, dz = s1.z - s0.z, len2 = dx * dx + dz * dz;
							const float u = len2 > 0.f ? std::clamp(((p.x - s0.x) * dx + (p.z - s0.z) * dz) / len2, 0.f, 1.f) : 0.f;
							const float px = s0.x + dx * u - p.x, pz = s0.z + dz * u - p.z, d2 = px * px + pz * pz;
							if (d2 < bestD2) {
								bestD2 = d2; at = cum[i - 1] + std::sqrt(len2) * u;
								sgn = (dx * (p.z - s0.z) - dz * (p.x - s0.x)) >= 0.f ? 1.f : -1.f;
							}
						}
						prog[c] = at; off[c] = sgn * std::sqrt(bestD2);
						bins[std::clamp((int)(at / total * kProgressBins), 0, kProgressBins - 1)].push_back(off[c]);
					}
					std::vector<float> lo(kProgressBins, 0.f), hi(kProgressBins, 0.f), ext;
					std::vector<int> good;
					float narrow = 1e30f;   // the passage's narrowest lateral extent away from the start bins
					for (int i = 0; i < kProgressBins; ++i) {
						auto& v = bins[i];
						if (v.size() < kBinMinCells) continue;
						std::sort(v.begin(), v.end());
						lo[i] = v[v.size() * kExtentLowPercentile / 100]; hi[i] = v[std::min(v.size() - 1, v.size() * kExtentHighPercentile / 100)];
						ext.push_back(hi[i] - lo[i]); good.push_back(i);
						if (i > 0 && i + 1 < kProgressBins) narrow = std::min(narrow, hi[i] - lo[i]);
					}
					if (!ext.empty()) {
						std::sort(ext.begin(), ext.end());
						whole.extent = ext[ext.size() / 2];
						if (narrow > 1e29f) narrow = ext.front();
						// the cap is the passage's own narrowest extent, not the clearance at the
						// choke: on a plain dotted with rocks the choke reads as the gap between two
						// rocks (587 on Glitters' middle, 2,300 wide) and would hold the plain to one lane
						const int byExtent = (int)std::lround(whole.extent / st.laneSpacing);
						const int byNarrow = (int)(narrow / (kLaneHalfSpacingShare * st.laneSpacing));
						k = std::clamp(std::min(byExtent, byNarrow), 1, st.laneMax);
					}
					if (k > 1) {
						auto limitAt = [&](float at, const std::vector<float>& val) {
							if (good.size() == 1) return val[good[0]];
							const float x = at / total * kProgressBins - 0.5f;
							std::size_t j = 0;
							while (j + 1 < good.size() && (float)good[j + 1] <= x) ++j;
							const int g0 = good[std::min(j, good.size() - 2)], g1 = good[std::min(j + 1, good.size() - 1)];
							const float t = std::clamp((x - g0) / std::max(1.f, (float)(g1 - g0)), 0.f, 1.f);
							return val[g0] + (val[g1] - val[g0]) * t;
						};
						bandOf.assign(n, -1);
						std::vector<std::vector<int>> bandCells(k);
						for (int c = 0; c < n; ++c) {
							if (prog[c] < 0.f) continue;
							const float l = limitAt(prog[c], lo), h = limitAt(prog[c], hi);
							const int bi = std::clamp((int)((off[c] - l) / std::max(kBandMinSpan, h - l) * k), 0, k - 1);
							bandOf[c] = bi; bandCells[bi].push_back(c);
						}
						std::vector<char> bandMask(n);
						std::vector<int> edge;
						std::vector<float> laneCost(n);
						const float firstBin = total / kProgressBins, lastBin = total - total / kProgressBins;
						bool ok = true;
						for (int bi = 0; bi < k && ok; ++bi) {
							std::fill(bandMask.begin(), bandMask.end(), 0);
							for (int c : bandCells[bi]) bandMask[c] = 1;
							ChamferDistance(g, bandMask, edge);   // thirds of a field cell: two clearance units each
							for (int c = 0; c < n; ++c) laneCost[c] = bandMask[c] ? 1.f / (float)(std::min(clr[c], edge[c] * kEdgeUnitsPerClearance) + 1) : kOutOfBandCost;
							std::vector<int> src, dst;
							for (int c : bandCells[bi]) { if (prog[c] <= firstBin) src.push_back(c); if (prog[c] >= lastBin) dst.push_back(c); }
							if (src.empty()) for (int c = 0; c < n; ++c) if (prog[c] >= 0.f && prog[c] <= firstBin) src.push_back(c);
							if (dst.empty()) for (int c = 0; c < n; ++c) if (prog[c] >= lastBin) dst.push_back(c);
							std::fill(goal.begin(), goal.end(), 0);
							for (int c : dst) goal[c] = 1;
							Search laneSearch(g, free);
							std::vector<int> lanePath = laneSearch.Run(src, goal, laneCost);
							if (lanePath.size() < 2) ok = false; else lanePaths.push_back(std::move(lanePath));
						}
						if (!ok) { lanePaths.clear(); k = 1; }
					}
				}
			}
			CORRIDOR_TRACE("corridors: group %d extent %.0f narrowest %.0f lanes %d\n", gi, whole.extent, whole.narrowest, k);
			if (k == 1) {
				for (int c = 0; c < n; ++c) if (open[c] && owner[c] == gi) laneOwner[c] = (std::int16_t)records;
				m.corridors.push_back(std::move(whole));
				++records;
			} else {
				for (int c = 0; c < n; ++c) if (bandOf[c] >= 0) laneOwner[c] = (std::int16_t)(records + bandOf[c]);
				for (int bi = 0; bi < k; ++bi) {
					SCorridor lane = makeRecord(lanePaths[(std::size_t)bi], routeCount, bi, k);
					lane.extent = whole.extent;
					m.corridors.push_back(std::move(lane));
					++records;
				}
			}
		}
		// 8. the class's ownership raster, corridor ids global
		auto& table = m.corridorOf[cls];
		table.assign(n, (std::int16_t)-1);
		for (int c = 0; c < n; ++c) if (open[c] && laneOwner[c] >= 0) table[c] = (std::int16_t)(firstId + laneOwner[c]);
		auto& safe = m.clearanceOf[cls];
		safe.assign(n, 0);
		for (int c = 0; c < n; ++c) if (open[c]) safe[c] = (unsigned char)std::clamp(clrMin[c], 0, 255);
	}
	(void)ctx.hMean;
}


std::vector<SPoint> RouteToCentre(const SModel& m, int cls, SPoint from, const SCorridor& c, int* vertex, int snapCells)
{
	if (vertex) *vertex = -1;
	if (cls < 0 || cls >= _CLASSES_ || m.gw <= 0 || m.gh <= 0 || m.cell <= 0 || c.centre.empty()) return {};
	const auto& owner = m.corridorOf[cls];
	SGridShape g; g.gw = m.gw; g.gh = m.gh;
	const int n = g.Size();
	if ((int)owner.size() != n) return {};
	std::vector<char> open(n, 0);
	for (int i = 0; i < n; ++i) open[i] = owner[i] >= 0 ? 1 : 0;
	// the source: the nearest open cell to the point within the snap window
	const int fx = std::clamp((int)(from.x / m.cell), 0, g.gw - 1), fz = std::clamp((int)(from.z / m.cell), 0, g.gh - 1);
	int source = -1, bestD = 1 << 30;
	snapCells = std::clamp(snapCells, 0, 8 * kLegSnapCells);
	for (int dz = -snapCells; dz <= snapCells; ++dz) {
		for (int dx = -snapCells; dx <= snapCells; ++dx) {
			const int x = fx + dx, z = fz + dz;
			if (!g.Inside(x, z) || !open[g.Index(x, z)]) continue;
			const int d = dx * dx + dz * dz;
			if (d < bestD) { bestD = d; source = g.Index(x, z); }
		}
	}
	if (source < 0) return {};
	// the goals: the cells of the centre vertices (the first vertex in a cell names it)
	std::vector<char> goal(n, 0);
	std::vector<int> vertexOf(n, -1);
	for (std::size_t i = 0; i < c.centre.size(); ++i) {
		const int x = std::clamp((int)(c.centre[i].x / m.cell), 0, g.gw - 1), z = std::clamp((int)(c.centre[i].z / m.cell), 0, g.gh - 1);
		const int cell = g.Index(x, z);
		if (!open[cell]) continue;
		goal[cell] = 1;
		if (vertexOf[cell] < 0) vertexOf[cell] = (int)i;
	}
	// D-362: a leg pays for closeness to closed ground. A cell with a closed
	// 16-elmo quarter (clearance 0) costs eight steps, so it is crossed only when
	// nothing else joins the start to the corridor; otherwise 1 + 12 / (clearance
	// + 1): four at one fine cell from an edge, under 1.5 beyond two field cells.
	std::vector<float> cost(n, 1.f);
	const auto& safe = m.clearanceOf[cls];
	if ((int)safe.size() == n) for (int i = 0; i < n; ++i) cost[i] = safe[i] == 0 ? kLegEdgeCost : 1.f + kLegClearanceWeight / (float)(safe[i] + 1);
	Search search(g, open);
	int reached = -1;
	const std::vector<int> path = search.Run({source}, goal, cost, &reached);
	if (reached < 0 || path.empty()) return {};
	if (vertex) *vertex = vertexOf[reached];
	// cell centres; collinear interior cells dropped (grid steps make long straight runs)
	std::vector<SPoint> out;
	out.reserve(path.size());
	for (std::size_t i = 0; i < path.size(); ++i) {
		const int x = g.X(path[i]), z = g.Z(path[i]);
		if (i > 0 && i + 1 < path.size()) {
			const int px = g.X(path[i - 1]), pz = g.Z(path[i - 1]), nx = g.X(path[i + 1]), nz = g.Z(path[i + 1]);
			if ((x - px) * (nz - z) - (z - pz) * (nx - x) == 0) continue;
		}
		out.push_back({(x + 0.5f) * m.cell, (z + 0.5f) * m.cell});
	}
	return out;
}

} // namespace circuit::field
