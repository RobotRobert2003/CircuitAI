#include "terrain/LaneSolver.h"

#include <algorithm>
#include <limits>
#include <queue>
#include <map>

namespace circuit::lane {
std::uint64_t Fingerprint(const std::vector<Route>& routes) {
    std::uint64_t hash = 14695981039346656037ull;
    auto add = [&](int v) { hash ^= static_cast<std::uint32_t>(v); hash *= 1099511628211ull; };
    for (const auto& route : routes) {
        add(route.cls); add(route.mask); add(route.ascent); add(route.descent);
        add(static_cast<int>(route.cells.size()));
        for (int cell : route.cells) add(cell);
    }
    return hash;
}
static constexpr int NB[8][2] = {{1,0},{-1,0},{0,1},{0,-1},{1,1},{1,-1},{-1,1},{-1,-1}};
Solver::Solver(const Terrain& t, Settings settings, const std::atomic<bool>* cancel)
    : Settings(settings), gw(t.gw), gh(t.gh), cellSize(t.cellSize), height(t.height),
      surfaceSlope(t.surfaceSlope), edges(t.edges), pass(t.pass), body8(t.body8), cancel(cancel)
{
    if (gw <= 0 || gh <= 0 || cellSize <= 0 || gw > std::numeric_limits<int>::max()/gh
        || gw > std::numeric_limits<int>::max()/cellSize || gh > std::numeric_limits<int>::max()/cellSize)
        throw std::invalid_argument("lane terrain dimensions");
    const auto n = static_cast<std::size_t>(gw)*gh;
    if (height.size()!=n || surfaceSlope.size()!=n || body8.size()!=n || (!edges.empty() && edges.size()!=n))
        throw std::invalid_argument("lane terrain snapshot size");
    for (const auto& p : pass) if (p.size()!=n) throw std::invalid_argument("lane passability snapshot size");
}
void Solver::CheckCancelled() const { if (cancel && cancel->load(std::memory_order_relaxed)) throw Cancelled(); }
int Solver::Cell(const Point& p) const {
    return std::clamp(int(p.z/cellSize),0,gh-1)*gw + std::clamp(int(p.x/cellSize),0,gw-1);
}
Point Solver::CellPos(int c) const { return Point((c%gw+0.5f)*cellSize, height[c], (c/gw+0.5f)*cellSize); }
void Solver::Clearance(int gw, int gh, const std::vector<char>& passable, std::vector<int>& clr)
{
	const int N = gw * gh;
	clr.assign(N, std::numeric_limits<int>::max());
	std::queue<int> q;
	for (int c = 0; c < N; ++c) {
		if (!passable[c]) {
			clr[c] = 0;
			q.push(c);
		}
	}
	while (!q.empty()) {
		const int c = q.front();
		q.pop();
		const int cx = c % gw, cz = c / gw;
		for (const auto& d : NB) {
			const int nx = cx + d[0], nz = cz + d[1];
			if ((nx < 0) || (nz < 0) || (nx >= gw) || (nz >= gh)) {
				continue;
			}
			const int n = nz * gw + nx;
			if (clr[n] > clr[c] + 1) {
				clr[n] = clr[c] + 1;
				q.push(n);
			}
		}
	}
	for (int c = 0; c < N; ++c) {   // the map edge bounds a corridor too
		const int cx = c % gw, cz = c / gw;
		const int edge = std::min(std::min(cx, gw - 1 - cx), std::min(cz, gh - 1 - cz)) + 1;
		clr[c] = std::min(clr[c], edge);
	}
}

// the nearest cell of this class to pos, within 40 cells (2560 elmos); -1 when none
int Solver::Snap(const Point& pos, int cls) const
{
	const int c0 = Cell(pos);
	if (pass[cls][c0]) {
		return c0;
	}
	const int x0 = c0 % gw, z0 = c0 / gw;
	for (int r = 1; r <= 40; ++r) {
		int best = -1;
		int bestD = std::numeric_limits<int>::max();
		for (int z = z0 - r; z <= z0 + r; ++z) {
			for (int x = x0 - r; x <= x0 + r; ++x) {
				if ((std::abs(x - x0) != r) && (std::abs(z - z0) != r)) {
					continue;   // the ring only
				}
				if ((x < 0) || (z < 0) || (x >= gw) || (z >= gh)) {
					continue;
				}
				const int c = z * gw + x;
				const int d = (x - x0) * (x - x0) + (z - z0) * (z - z0);
				if (pass[cls][c] && (d < bestD)) {
					bestD = d;
					best = c;
				}
			}
		}
		if (best >= 0) {
			return best;
		}
	}
	return -1;
}

void SearchWorkspace::Begin(std::size_t size)
{
    if (stamps.size() != size) { stamps.assign(size, 0); generation = 0; }
    if (++generation == 0) { std::fill(stamps.begin(), stamps.end(), 0); generation = 1; }
    heap.clear();
}

std::vector<int> Solver::PointRoute(const Point& from, const Point& to, int cls, const Grid& threat,
        float landCost, float waterCost, float threatWeight, float maxWaterThreat, const std::vector<char>* obstacles,
        PointWorkspace* workspace, std::uint64_t threatVersion) const
{
    auto inside = [this](const Point& p) {
        return std::isfinite(p.x) && std::isfinite(p.z) && p.x >= 0 && p.z >= 0
            && p.x < gw * cellSize && p.z < gh * cellSize;
    };
    if (!inside(from) || !inside(to) || cls < 0 || cls >= _LANE_CLASSES_
        || threat.size() != height.size() || (obstacles != nullptr && obstacles->size()!=height.size())
        || !std::isfinite(landCost) || landCost <= 0
        || !std::isfinite(waterCost) || waterCost <= 0 || !std::isfinite(threatWeight) || threatWeight < 0
        || !std::isfinite(maxWaterThreat) || maxWaterThreat < 0) return {};
    const int origin = Cell(from), goal = Cell(to);
    if (!pass[cls][origin] || !pass[cls][goal]) return {};
    PointWorkspace local;
    auto& ws = workspace == nullptr ? local : *workspace;
    auto& penalty = ws.penalty;
    auto& blocked = ws.blocked;
    auto& distance = ws.distance;
    auto& previous = ws.previous;
    if (threatVersion == 0 || obstacles != nullptr || ws.version != threatVersion
        || ws.terrain != &height || ws.threat != &threat || penalty.size() != height.size()
        || ws.landCost != landCost || ws.waterCost != waterCost || ws.weight != threatWeight || ws.ceiling != maxWaterThreat
        || ws.surfaceWeight != mountainSurfaceWeight) {
      ws.routes.clear(); ws.routeOrder.clear(); ws.nextRoute = 0;
      ws.surfaceWeight = mountainSurfaceWeight;
      penalty.resize(height.size()); blocked.resize(height.size());
      for (size_t c = 0; c < height.size(); ++c) {
        const float value = std::isfinite(threat[c]) ? std::max(0.f, threat[c]) : 1e9f;
        blocked[c] = (height[c] < 0 && value > maxWaterThreat) || (obstacles != nullptr && (*obstacles)[c]);
        penalty[c] = std::min(1e8f, (height[c] < 0 ? waterCost : landCost) + value * threatWeight);
      }
      ws.version = obstacles == nullptr ? threatVersion : 0;
      ws.terrain = &height; ws.threat = &threat;
      ws.landCost = landCost; ws.waterCost = waterCost; ws.weight = threatWeight; ws.ceiling = maxWaterThreat;
    }
    // Allow escape from a newly threatened starting cell, but not entry into a threatened goal.
    // Do not mutate cached blocked cells: an escape exception belongs to this
    // query only, including corner checks and origin==goal.
    if (goal != origin && blocked[goal]) return {};
    // The solver observes grid cells, not sub-cell coordinates. Reuse only an
    // identical directed query under the exact immutable terrain/cost epoch.
    // This skips a search, never samples threats less often or changes ties.
    // Lookup O(log K), returned path copy O(P), bounded O(K*P) storage. The
    // caller retains terrain lifetime; dynamic overlays bypass this cache.
    const bool reusable = threatVersion != 0 && obstacles == nullptr;
    const std::array<int,3> key{origin,goal,cls};
    if (reusable) {
        const auto found = ws.routes.find(key);
        if (found != ws.routes.end()) return found->second;
    }
    const auto retain = [&](const std::vector<int>& path) {
        if (!reusable) return;
        if (ws.routes.size() == PointWorkspace::maximumCachedRoutes) {
            ws.routes.erase(ws.routeOrder[ws.nextRoute]);
            ws.routeOrder[ws.nextRoute] = key;
            ws.nextRoute = (ws.nextRoute + 1) % PointWorkspace::maximumCachedRoutes;
        } else ws.routeOrder.push_back(key);
        ws.routes.emplace(key,path);
    };
    std::vector<int> result;
    DijkstraMulti({goal}, penalty, cls, nullptr, distance, previous, true, 0.f, &blocked,
        0.f, true, nullptr, origin, &ws.search, origin);
    if (!ws.search.Seen(origin) || distance[origin] == std::numeric_limits<float>::max()) { retain(result); return {}; }
    int at = origin;
    for (size_t step = 0; step < height.size(); ++step) {
        result.push_back(at);
        if (at == goal) { retain(result); return result; }
        at = previous[at];
        if (at < 0) break;
    }
    return {};
}

void Solver::DijkstraMulti(const std::vector<int>& starts, const Grid& penalty, int cls, const Grid* extra,
		Grid& dist, std::vector<int>& prev, bool reverse, float gradeWeight, const std::vector<char>* blocked, float cliffWeight, bool preferShelf,
		const Grid* initialCost, int terminal, SearchWorkspace* workspace, int escape) const
{
    CheckCancelled();
    ++searches;
	const int N = gw * gh;
    if (workspace != nullptr) {
        workspace->Begin(N); dist.resize(N); prev.resize(N);
    } else {
        dist.assign(N, std::numeric_limits<float>::max()); prev.assign(N, -1);
    }
	const auto touch = [&](int c) {
        if (workspace != nullptr && !workspace->Seen(c)) {
            workspace->stamps[c] = workspace->generation;
            dist[c] = std::numeric_limits<float>::max(); prev[c] = -1;
        }
    };
    const auto isBlocked = [&](int c) { return c != escape && blocked != nullptr && (*blocked)[c]; };
	using QE = std::pair<float, int>;
    std::vector<QE> localHeap;
    auto& q = workspace == nullptr ? localHeap : workspace->heap;
    const auto push = [&](QE e) { q.push_back(e); std::push_heap(q.begin(), q.end(), std::greater<QE>()); };
	for (int s : starts) {
        touch(s);
		dist[s] = initialCost == nullptr ? 0.f : (*initialCost)[s];
		push({dist[s], s});
	}
	const std::vector<char>& p = pass[cls];
	while (!q.empty()) {
        std::pop_heap(q.begin(), q.end(), std::greater<QE>());
		const QE e = q.back();
		q.pop_back();
		const int c = e.second;
		if (e.first > dist[c]) {
			continue;
		}
        if ((++expanded & 1023) == 0) CheckCancelled();
        // Only point queries set terminal. Settle, do not stop on discovery:
        // every predecessor is now final with the legacy strict-< tie rule.
        if (c == terminal) break;
		const int cx = c % gw, cz = c / gw;
		for (const auto& d : NB) {
			const int nx = cx + d[0], nz = cz + d[1];
			if ((nx < 0) || (nz < 0) || (nx >= gw) || (nz >= gh)) {
				continue;
			}
			const int n = nz * gw + nx;
			if (!p[n] || isBlocked(n)) {
				continue;
			}
            const int direction = int(&d - NB);
            const int opposite = direction < 4 ? (direction ^ 1) : (7 - direction + 4);
            if (!edges.empty() && !(edges[reverse ? n : c] & (1u << (reverse ? opposite : direction)))) continue;
			// A coarse diagonal must not slip through two blocked corners.
			if (d[0] != 0 && d[1] != 0 && (!p[cz * gw + nx] || !p[nz * gw + cx]
				|| isBlocked(cz * gw + nx) || isBlocked(nz * gw + cx))) {
				continue;
			}
			const float step = cellSize * ((d[0] != 0 && d[1] != 0) ? 1.4142f : 1.f);
			// uphill slows a ground army (GroundMoveMath: 1 / (1 + slope * slopeMod)); air and water flat
			// This is a reverse search: the army travels n -> c.
			const float delta = reverse ? height[c] - height[n] : height[n] - height[c];
			const float rise = ((cls == L_AIR) || (cls == L_NAVAL)) ? 0.f : std::max(0.f, delta) / step;
			float w = (step * (1.f + 2.f * rise) + gradeWeight * delta * delta / step) * penalty[n];
			if (cls == L_ALLTERRAIN && preferShelf) {
				// Constant-height travel across a cliff face is not flat ground.
				// Use engine surface slope as well as longitudinal route grade.
				const float slope = (surfaceSlope[c] + surfaceSlope[n]) * 0.5f;
				w *= 1.f + mountainSurfaceWeight * slope / std::max(0.1f, 1.f - slope);
			}
			if (!pass[L_BOT][c] || !pass[L_BOT][n]) {
				w /= 1.f + cliffWeight * std::min(8.f, std::max(0.f, -delta / step));
			}
			if (extra != nullptr) {
				w *= (*extra)[n];
			}
            touch(n);
			if (dist[c] + w < dist[n]) {
				dist[n] = dist[c] + w;
				prev[n] = c;
				push({dist[n], n});
			}
		}
	}
}

bool Solver::BuildCliffCrossing(int peak, const std::vector<int>& region, int origin,
		const std::vector<int>& targets, int enemy, const Grid& surfCost, float budget)
{
	if (cliffPreference <= 0.f) return false;
	const int N = gw * gh;
	Grid uniform(N, 1.f), traverse;
	Grid shelf(N, 1.f);
	for (int c : region) {
		// peak was already selected inside the tolerance band. Subtracting the
		// tolerance a second time made low valley contours effectively free.
		shelf[c] += mountainHeightWeight * std::max(0.f, height[peak] - height[c])
			/ std::max(cellSize * 1.f, height[peak] - height[origin]);
	}
	std::vector<int> prevTraverse;
	std::vector<char> blocked(N, 1);
	for (int c : region) blocked[c] = 0;
	DijkstraMulti({peak}, shelf, L_ALLTERRAIN, &surfCost, traverse, prevTraverse, false, mountainGradeWeight, &blocked);
	struct Leg { int gate; float cost, quality; std::vector<int> path; };
	std::vector<Leg> legs[2];
	for (int side = 0; side < 2; ++side) {
		Grid down;
		std::vector<int> prevDown, visited(N, -1);
		const std::vector<int> ends = side == 0 ? std::vector<int>{origin} : targets;
		std::vector<char> endpointBlocked(N, 1);
		const Point from = CellPos(side == 0 ? enemy : origin);
		for (int end : ends) {
			const Point to = CellPos(end);
			const float dx = to.x-from.x, dz = to.z-from.z, span = dx*dx+dz*dz;
			if (span < 1.f) continue;
			for (int c = 0; c < N; ++c) {
				const Point pos = CellPos(c);
				if (((pos.x-from.x)*dx+(pos.z-from.z)*dz)/span >= cliffMinProgress) endpointBlocked[c] = 0;
			}
		}
		// Endpoint legs must stay at their end. Otherwise the cheapest "ascent"
		// can run through the whole valley and climb at the opposite end, or
		// double back through the shelf and invalidate every candidate pair.
		DijkstraMulti(ends, uniform, L_ALLTERRAIN, &surfCost, down, prevDown,
			true, 0.f, &endpointBlocked, cliffPreference, false);
		float bestQuality = 0.f;
		for (int c : region) {
			if (!pass[cliffApproachClass][c] || traverse[c] == std::numeric_limits<float>::max()
				|| down[c] == std::numeric_limits<float>::max()) continue;
			int end = c;
			while (prevDown[end] >= 0) end = prevDown[end];
			if (height[c] < height[end] + (height[peak] - height[end]) * cliffHeightFraction) continue;
			const Point from = CellPos(side == 0 ? enemy : origin), to = CellPos(end), pos = CellPos(c);
			const float dx = to.x-from.x, dz = to.z-from.z, span = dx*dx+dz*dz;
			if (span < 1.f || ((pos.x-from.x)*dx+(pos.z-from.z)*dz)/span < cliffMinProgress) continue;
			float run = 0.f, totalDrop = 0.f, quality = 0.f;
			bool cliff = false, landed = false;
			for (int a = c, b = prevDown[a]; b >= 0; a = b, b = prevDown[a]) {
				const float step = CellPos(a).distance2D(CellPos(b));
				const float drop = std::max(0.f, height[a]-height[b]);
				run += step;
				totalDrop += drop;
				if (!pass[L_BOT][a] || !pass[L_BOT][b]) {
					quality += drop * std::min(8.f, drop / step);
					if (run <= cliffMaxRun && drop > 0.f) cliff = true;
				}
				if (run <= cliffMaxRun && cliff && height[c]-height[b] >= cliffMinDrop && pass[L_BOT][b]) landed = true;
			}
			if (!landed || totalDrop <= 0.f) continue;
			quality = totalDrop > 0.f ? quality / totalDrop : 0.f;
			std::vector<int> path;
			for (int a = c; a >= 0; a = prevTraverse[a]) path.push_back(a);
			std::reverse(path.begin(), path.end());
			for (int b = prevDown[c]; b >= 0; b = prevDown[b]) path.push_back(b);
			bool loop = false;
			float travel = 0.f;
			for (size_t i = 0; i < path.size(); ++i) {
				const int b = path[i];
				if (visited[b] == c) { loop = true; break; }
				visited[b] = c;
				if (i > 0) {
					const int a = path[i-1];
					const float rise = side == 0 ? height[a]-height[b] : height[b]-height[a];
					travel += (CellPos(a).distance2D(CellPos(b)) + 2.f*std::max(0.f,rise)) * surfCost[side == 0 ? a : b];
				}
			}
			if (loop || travel > budget) continue;
			bestQuality = std::max(bestQuality, quality);
			legs[side].push_back({c, traverse[c]+down[c], quality, std::move(path)});
		}
		auto& choices = legs[side];
		choices.erase(std::remove_if(choices.begin(), choices.end(), [&](const Leg& l) {
			return l.quality < bestQuality * (1.f-cliffQualityTolerance);
		}), choices.end());
		std::sort(choices.begin(), choices.end(), [](const Leg& a, const Leg& b) {
			return a.cost == b.cost ? a.gate < b.gate : a.cost < b.cost;
		});
		if (choices.empty()) return false;
		if (choices.size() > 16) choices.resize(16); // bounded pair search; fallback remains available
	}
	float bestCost = std::numeric_limits<float>::max();
	SLane best;
	for (const Leg& home : legs[0]) for (const Leg& away : legs[1]) {
		if (home.cost + away.cost >= bestCost) continue;
		std::vector<int> path(home.path.rbegin(), home.path.rend());
		path.insert(path.end(), away.path.begin()+1, away.path.end());
		std::vector<char> visited(N, 0);
		float travel = 0.f;
		int mask = (1 << _LANE_CLASSES_) - 1;
		bool loop = false;
		for (size_t i = 0; i < path.size(); ++i) {
			const int b = path[i];
			if (visited[b]) { loop = true; break; }
			visited[b] = 1;
			for (int k = 0; k < _LANE_CLASSES_; ++k) if (!pass[k][b]) mask &= ~(1 << k);
			if (i > 0) {
				const int a = path[i-1];
				travel += (CellPos(a).distance2D(CellPos(b)) + 2.f*std::max(0.f,height[b]-height[a])) * surfCost[b];
			}
		}
		if (loop || travel > budget || (mask & (1 << L_BOT))) continue;
		bestCost = home.cost + away.cost;
		best.cls = L_ALLTERRAIN; best.mask = mask; best.heat = 1;
		best.ascent = home.gate; best.descent = away.gate;
		best.cliffQuality[0] = home.quality; best.cliffQuality[1] = away.quality;
		best.cells = std::move(path);
	}
	if (bestCost == std::numeric_limits<float>::max()) return false;
	lanes.push_back(std::move(best));
	return true;
}

bool Solver::BuildShelfCrossing(int peak, const std::vector<int>& region, int origin,
		const std::vector<int>& targets, int enemy, const Grid& surfCost, float budget)
{
	const int N = gw * gh;
	Grid uniform(N, 1.f), cost[2];
	std::vector<int> prev[2];
	std::vector<char> endBand[2];
	for (int side = 0; side < 2; ++side) {
		const std::vector<int> ends = side == 0 ? std::vector<int>{origin} : targets;
		endBand[side].assign(N, 1);
		const Point from = CellPos(side == 0 ? enemy : origin);
		for (int end : ends) {
			const Point to = CellPos(end);
			const float dx = to.x-from.x, dz = to.z-from.z, span = dx*dx+dz*dz;
			if (span < 1.f) continue;
			for (int c = 0; c < N; ++c) {
				const Point p = CellPos(c);
				if (((p.x-from.x)*dx+(p.z-from.z)*dz)/span >= cliffMinProgress) endBand[side][c] = 0;
			}
		}
		DijkstraMulti(ends, uniform, L_ALLTERRAIN, &surfCost, cost[side], prev[side],
			true, 0.f, &endBand[side], cliffPreference, false);
	}
	// The shelf is a connected upper band, not a single point to touch. A
	// weighted multi-source search chooses both gates without a peak hairpin.
	const float floor = std::max(height[origin] + (height[peak]-height[origin]) * cliffHeightFraction,
		height[peak] - mountainPeakTolerance);
	std::vector<char> blocked(N, 1);
	std::vector<int> starts;
	for (int c : region) {
		blocked[c] = 0;
		// Narrow saddles can separate otherwise continuous upper shelves.
		// Permit adjacent land cells; elevation remains a cost, not a wall.
		for (const auto& d : NB) {
			const int x = c % gw+d[0], z = c / gw+d[1];
			if (x >= 0 && z >= 0 && x < gw && z < gh && pass[L_ALLTERRAIN][z*gw+x]) blocked[z*gw+x] = 0;
		}
	}
	for (int c = 0; c < N; ++c) {
		if (blocked[c]) continue;
		uniform[c] += mountainHeightWeight * std::max(0.f, height[peak]-height[c])
			/ std::max(float(cellSize), height[peak]-floor);
		if (height[c] >= floor && !endBand[0][c] && pass[cliffApproachClass][c]
			&& cost[0][c] < std::numeric_limits<float>::max()) starts.push_back(c);
	}
	if (starts.empty()) return false;
	Grid crossing;
	std::vector<int> prevCrossing;
	DijkstraMulti(starts, uniform, L_ALLTERRAIN, &surfCost, crossing, prevCrossing,
		false, mountainGradeWeight, &blocked, 0.f, true, &cost[0]);
	float bestCost = std::numeric_limits<float>::max();
	SLane best;
	for (int c : region) {
		if (blocked[c] || height[c] < floor || endBand[1][c] || !pass[cliffApproachClass][c]
			|| crossing[c] == std::numeric_limits<float>::max() || cost[1][c] == std::numeric_limits<float>::max()
			|| crossing[c]+cost[1][c] >= bestCost) continue;
		std::vector<int> middle;
		for (int a = c; a >= 0; a = prevCrossing[a]) middle.push_back(a);
		std::reverse(middle.begin(), middle.end());
		std::vector<int> path;
		for (int a = middle.front(); a >= 0; a = prev[0][a]) path.push_back(a);
		std::reverse(path.begin(), path.end());
		path.insert(path.end(), middle.begin()+1, middle.end());
		for (int a = prev[1][c]; a >= 0; a = prev[1][a]) path.push_back(a);
		std::vector<char> visited(N, 0);
		bool loop = false;
		float travel = 0.f;
		int mask = (1 << _LANE_CLASSES_) - 1;
		for (size_t i = 0; i < path.size(); ++i) {
			const int b = path[i];
			if (visited[b]) { loop = true; break; }
			visited[b] = 1;
			for (int k = 0; k < _LANE_CLASSES_; ++k) if (!pass[k][b]) mask &= ~(1 << k);
			if (i > 0) {
				const int a = path[i-1];
				travel += (CellPos(a).distance2D(CellPos(b))+2.f*std::max(0.f,height[b]-height[a])) * surfCost[b];
			}
		}
		if (loop || travel > budget || (mask & (1 << L_BOT))) continue;
		bestCost = crossing[c]+cost[1][c];
		best.cls = L_ALLTERRAIN; best.mask = mask; best.heat = 1; best.cells = std::move(path);
	}
	if (bestCost == std::numeric_limits<float>::max()) return false;
	lanes.push_back(std::move(best));
	return true;
}

std::vector<Route> Solver::Run(const Request& request)
{
    CheckCancelled();
    static_cast<Settings&>(*this) = request.settings;
    const auto& allyEnds = request.allyEnds;
    const auto& enemyEnds = request.enemyEnds;
    const int alternatives = std::clamp(request.alternatives, 1, 8);
    const int highGroundRoutes = std::clamp(request.highGroundRoutes, 0, 16);
    const float mergeRadius = request.mergeRadius, specialistBias = request.specialistBias;
    const float highGroundRise = request.highGroundRise, highGroundDetour = request.highGroundDetour;
    lanes.clear();
    const int N = gw * gh;
    if (request.airThreat.size() != height.size() || request.surfThreat.size() != height.size())
        throw std::invalid_argument("lane threat snapshot size");
    const int mr = std::max(1, int(mergeRadius / cellSize));
    Grid airCost(N, 1.f), surfCost(N, 1.f);
    for (int c = 0; c < N; ++c) {
        airCost[c] += request.threatWeight * std::clamp(request.airThreat[c], 0.f, 1000.f) / 100.f;
        surfCost[c] += request.threatWeight * std::clamp(request.surfThreat[c], 0.f, 1000.f) / 100.f;
    }
	// naval: a start point in every body of ship water near a start (Supreme
	// Isthmus has two seas; the nearest water alone missed them)
	auto perBody = [this](const Point& pos) {
		std::map<int, std::pair<int, int>> best;   // body -> (squared cells, cell)
		const int r = 100;   // 6400 elmos
		const int x0 = Cell(pos) % gw, z0 = Cell(pos) / gw;
		for (int z = std::max(0, z0 - r); z <= std::min(gh - 1, z0 + r); ++z) {
			for (int x = std::max(0, x0 - r); x <= std::min(gw - 1, x0 + r); ++x) {
				const int c = z * gw + x;
				const int b = body8[c];
				if (b < 0) {
					continue;
				}
				const int d = (x - x0) * (x - x0) + (z - z0) * (z - z0);
				auto it = best.find(b);
				if ((it == best.end()) || (d < it->second.first)) {
					best[b] = std::make_pair(d, c);
				}
			}
		}
		std::vector<int> cells;
		for (const auto& kv : best) {
			cells.push_back(kv.second.second);
		}
		return cells;
	};

	for (int cls = 0; cls < _LANE_CLASSES_; ++cls) {
		std::vector<int> starts;
		for (const Point& e : enemyEnds) {
			if (cls == L_NAVAL) {
				for (int s : perBody(e)) {
					starts.push_back(s);
				}
				continue;
			}
			const int s = Snap(e, cls);
			if (s >= 0) {
				starts.push_back(s);
			}
		}
		if (starts.empty()) {
			continue;
		}
		const Grid* extra = (cls == L_AIR) ? &airCost : &surfCost;
		Grid penalty(N, 1.f), dist;
		// Script controls how strongly specialist exploration seeks cliff flanks.
		// The ordinary first path is retained; later alternatives prefer terrain
		// inaccessible to ordinary bots, without introducing map-specific routes.
		std::vector<int> prev;
		for (int it = 0; it < std::max(1, alternatives); ++it) {
			if (cls == L_ALLTERRAIN && it == 1) {
				const float bias = std::isfinite(specialistBias) ? std::clamp(specialistBias, 1.f, 8.f) : 1.f;
				for (int c = 0; c < N; ++c) if (pass[L_BOT][c]) penalty[c] *= bias;
			}
			DijkstraMulti(starts, penalty, cls, extra, dist, prev);
			std::vector<int> ours;
			for (const Point& a : allyEnds) {
				if (cls == L_NAVAL) {
					for (int s : perBody(a)) {
						ours.push_back(s);
					}
				} else {
					ours.push_back(Snap(a, cls));
				}
			}
			for (int ac : ours) {
				if ((ac < 0) || (dist[ac] == std::numeric_limits<float>::max())) {
					continue;
				}
				std::vector<int> path;
				for (int c = ac; c >= 0; c = prev[c]) {
					path.push_back(c);   // our end first: the tree is rooted at the enemy
				}
				if (path.size() < 6) {
					continue;
				}
				int mask = (1 << _LANE_CLASSES_) - 1;
				for (int c : path) {
					for (int k = 0; k < _LANE_CLASSES_; ++k) if (!pass[k][c]) mask &= ~(1 << k);
				}
				for (int c : path) {   // the next pass looks for another way
					penalty[c] *= 4.f;
					const int cx = c % gw, cz = c / gw;
					for (const auto& d : NB) {
						const int nx = cx + d[0], nz = cz + d[1];
						if ((nx >= 0) && (nz >= 0) && (nx < gw) && (nz < gh)) {
							penalty[nz * gw + nx] *= 1.5f;
						}
					}
				}
				// merge: mostly inside a lane already found (any class) -> the same lane
				int bestLane = -1;
				float bestShare = 0.f;
				for (int l = 0; l < (int)lanes.size(); ++l) {
					// merge within a domain: ground lanes (land, bot, amphibious, hover,
					// all-terrain) with each other; naval with naval; air with air
					auto domain = [](int k) { return (k == L_NAVAL) ? 1 : ((k == L_AIR) ? 2 : 0); };
					if (domain(lanes[l].cls) != domain(cls)) {
						continue;
					}
					// Nearby paths with different capabilities are tactically distinct.
					// In particular, never erase a cliff crossing because its approach
					// shares the valley route for most of its length.
					if (lanes[l].mask != mask) continue;
					int in = 0;
					for (int c : path) {
						in += lanes[l].zone[c];
					}
					const float share = float(in) / path.size();
					if (share > bestShare) {
						bestShare = share;
						bestLane = l;
					}
				}
				if ((bestLane >= 0) && (bestShare >= 0.6f)) {
					++lanes[bestLane].heat;
					continue;
				}
				SLane lane;
				lane.cls = cls;
				if (cls <= L_ALLTERRAIN) {
					for (int k = 0; k <= L_ALLTERRAIN; ++k) if (mask & (1 << k)) { lane.cls = k; break; }
				}
				lane.mask = mask;
				lane.cells = path;
				lane.heat = 1;
				lane.zone.assign(N, 0);
				for (int c : path) {
					const int cx = c % gw, cz = c / gw;
					for (int z = std::max(0, cz - mr); z <= std::min(gh - 1, cz + mr); ++z) {
						for (int x = std::max(0, cx - mr); x <= std::min(gw - 1, cx + mr); ++x) {
							lane.zone[z * gw + x] = 1;
						}
					}
				}
				lanes.push_back(std::move(lane));
			}
		}
	}

	// Major elevated components are tactical objectives in their own right.
	// A shortest-route penalty search alone never visits a distant mountain.
	// Explore one summit crossing per connected high-ground component, entirely
	// from terrain and script-provided rise/detour/count limits (no map names).
	if (!allyEnds.empty() && !enemyEnds.empty() && highGroundRoutes > 0) {
		const int origin = Snap(allyEnds.front(), L_ALLTERRAIN);
		std::vector<int> targets;
		for (const auto& p : enemyEnds) { const int c = Snap(p, L_ALLTERRAIN); if (c >= 0) targets.push_back(c); }
		if (origin >= 0 && !targets.empty()) {
			Grid uniform(N, 1.f), fromUs, toEnemy;
			std::vector<int> prevUs, prevEnemy;
			DijkstraMulti({origin}, uniform, L_ALLTERRAIN, &surfCost, fromUs, prevUs, false);
			DijkstraMulti(targets, uniform, L_ALLTERRAIN, &surfCost, toEnemy, prevEnemy);
			// Policy scores must not inflate the physical detour allowance.
			Grid physical;
			std::vector<int> prevPhysical;
			DijkstraMulti(targets, uniform, L_ALLTERRAIN, &surfCost, physical, prevPhysical,
				true, 0.f, nullptr, 0.f, false);
			Grid approach, approachBase;
			std::vector<int> prevApproach;
			if (cliffApproachClass >= L_LAND && cliffApproachClass < L_ALLTERRAIN && pass[cliffApproachClass][origin]) {
				DijkstraMulti({origin}, uniform, cliffApproachClass, &surfCost, approachBase, prevApproach, false);
				DijkstraMulti({origin}, uniform, cliffApproachClass, &surfCost, approach, prevApproach, false, mountainGradeWeight);
			}
			const float base = physical[origin];
			const float rise = std::isfinite(highGroundRise) ? std::max(0.f, highGroundRise) : 128.f;
			const float detour = std::isfinite(highGroundDetour) ? std::clamp(highGroundDetour, 1.f, 8.f) : 3.f;
			const float threshold = height[origin] + rise;
			std::vector<char> seen(N, 0);
			std::vector<int> anchors;
			int descents = 0;
			for (int seed = 0; seed < N; ++seed) {
				if (seen[seed] || !pass[L_ALLTERRAIN][seed] || height[seed] < threshold) continue;
				std::vector<int> region{seed}; seen[seed] = 1;
				int anchor = -1;
				for (size_t i = 0; i < region.size(); ++i) {
					const int c = region[i], x = c % gw, z = c / gw;
					const bool reachable = fromUs[c] != std::numeric_limits<float>::max() && toEnemy[c] != std::numeric_limits<float>::max();
					if (reachable && fromUs[c] + toEnemy[c] <= base * detour
						&& (anchor < 0 || height[c] > height[anchor]
							|| (height[c] == height[anchor] && fromUs[c] + toEnemy[c] < fromUs[anchor] + toEnemy[anchor]))) anchor = c;
					for (int j = 0; j < 4; ++j) {
						const int nx = x + NB[j][0], nz = z + NB[j][1];
						if (nx < 0 || nz < 0 || nx >= gw || nz >= gh) continue;
						const int n = nz * gw + nx;
						if (!seen[n] && pass[L_ALLTERRAIN][n] && height[n] >= threshold) { seen[n] = 1; region.push_back(n); }
					}
				}
				if (anchor >= 0 && region.size() >= 16) {
					// Cross the upper half of the component with the least cost;
					// climbing to the absolute summit can mean a needless map-edge detour.
					const float crest = (height[anchor] + threshold) * 0.5f;
					// Reach the highest accessible elevation band, then traverse its
					// component smoothly before committing to a destination-side drop.
					int peak = -1;
					if (!approach.empty() && descents < std::clamp(highGroundRoutes, 0, 8)) {
						for (int c : region) {
							if (approachBase[c] != std::numeric_limits<float>::max()
								&& toEnemy[c] != std::numeric_limits<float>::max()
								&& approachBase[c] + toEnemy[c] <= base * detour
								&& (peak < 0 || height[c] > height[peak])) peak = c;
						}
					}
					if (peak >= 0 && height[peak] >= crest) {
						const float peakFloor = std::max(crest, height[peak] - mountainPeakTolerance);
						for (int c : region) {
							if (height[c] >= peakFloor && approachBase[c] != std::numeric_limits<float>::max()
								&& toEnemy[c] != std::numeric_limits<float>::max()
								&& approachBase[c] + toEnemy[c] <= base * detour
								&& approach[c] + toEnemy[c] < approach[peak] + toEnemy[peak]) peak = c;
						}
						int enemy = peak;
						while (prevEnemy[enemy] >= 0) enemy = prevEnemy[enemy];
						if (BuildCliffCrossing(peak, region, origin, targets, enemy, surfCost, base * detour)) {
							++descents;
							continue;
						}
						// Some ridges have ramps or shallow cliffs at their ends. Still
						// cross the shelf between both outer gates rather than following
						// a valley approach that reaches the mountain only at the far end.
						if (mountainSurfaceWeight > 0.f && BuildShelfCrossing(anchor, region, origin,
								targets, enemy, surfCost, base * detour)) {
							++descents;
							continue;
						}
						std::vector<int> head;
						for (int c = peak; c >= 0; c = prevApproach[c]) head.push_back(c);
						std::reverse(head.begin(), head.end());
						std::vector<char> blocked(N, 1);
						for (int c : region) blocked[c] = 0;
						for (int c : head) if (c != peak) blocked[c] = 1;
						Grid traverse;
						std::vector<int> prevTraverse;
						DijkstraMulti({peak}, uniform, L_ALLTERRAIN, &surfCost, traverse, prevTraverse, false, mountainGradeWeight, &blocked);
						int descent = -1;
						float bestCost = std::numeric_limits<float>::max();
						std::vector<int> bestPath, visited(N, -1);
						for (int c : region) {
							if (!pass[cliffApproachClass][c] || traverse[c] == std::numeric_limits<float>::max()
								|| toEnemy[c] == std::numeric_limits<float>::max()) continue;
							const float cost = traverse[c] + toEnemy[c];
							if (cost >= bestCost) continue;
							int target = c;
							while (prevEnemy[target] >= 0) target = prevEnemy[target];
							const Point start = CellPos(origin), end = CellPos(target), pos = CellPos(c);
							const float dx = end.x-start.x, dz = end.z-start.z, distanceSq = dx*dx + dz*dz;
							if (distanceSq < 1.f || ((pos.x-start.x)*dx + (pos.z-start.z)*dz) / distanceSq < cliffMinProgress) continue;
							float run = 0.f;
							bool cliff = false, landed = false;
							for (int a = c, b = prevEnemy[a]; b >= 0; a = b, b = prevEnemy[a]) {
								run += CellPos(a).distance2D(CellPos(b));
								if (run > cliffMaxRun) break;
								if ((!pass[L_BOT][a] || !pass[L_BOT][b]) && height[b] < height[a]) cliff = true;
								if (cliff && height[c]-height[b] >= cliffMinDrop && pass[L_BOT][b]) { landed = true; break; }
							}
							if (!landed) continue;
							std::vector<int> path;
							for (int a = c; a != peak && a >= 0; a = prevTraverse[a]) path.push_back(a);
							std::reverse(path.begin(), path.end());
							path.insert(path.begin(), head.begin(), head.end());
							for (int b = prevEnemy[c]; b >= 0; b = prevEnemy[b]) path.push_back(b);
							bool loop = false;
							float travelCost = 0.f;
							for (size_t i = 0; i < path.size(); ++i) {
								const int b = path[i];
								if (visited[b] == c) { loop = true; break; }
								visited[b] = c;
								if (i > 0) {
									const int a = path[i-1];
									travelCost += (CellPos(a).distance2D(CellPos(b)) + 2.f * std::max(0.f, height[b]-height[a])) * surfCost[b];
								}
							}
							if (loop || travelCost > base * detour || path.size() < 6) continue;
							descent = c; bestCost = cost; bestPath = std::move(path);
						}
						if (descent >= 0) {
							int mask = (1 << _LANE_CLASSES_) - 1;
							for (int c : bestPath) for (int k = 0; k < _LANE_CLASSES_; ++k) if (!pass[k][c]) mask &= ~(1 << k);
							SLane lane; lane.cls = L_ALLTERRAIN; lane.mask = mask;
							lane.cells = std::move(bestPath); lane.heat = 1; lane.descent = descent;
							lanes.push_back(std::move(lane)); ++descents;
							continue;
						}
					}
					for (int c : region) {
						if (height[c] >= crest && fromUs[c] != std::numeric_limits<float>::max()
							&& toEnemy[c] != std::numeric_limits<float>::max()
							&& fromUs[c] + toEnemy[c] < fromUs[anchor] + toEnemy[anchor]) anchor = c;
					}
					anchors.push_back(anchor);
				}
			}
			std::sort(anchors.begin(), anchors.end(), [this](int a, int b) { return height[a] == height[b] ? a < b : height[a] > height[b]; });
			int added = 0;
			for (int anchor : anchors) {
				if (added >= std::clamp(highGroundRoutes, 0, 8)) break;
				std::vector<int> path;
				for (int c = anchor; c >= 0; c = prevUs[c]) path.push_back(c);
				std::reverse(path.begin(), path.end());
				for (int c = prevEnemy[anchor]; c >= 0; c = prevEnemy[c]) path.push_back(c);
				// Reject an out-and-back summit visit: this must be a through route.
				std::vector<char> visited(N, 0);
				bool loop = false;
				int mask = (1 << _LANE_CLASSES_) - 1;
				for (int c : path) {
					if (visited[c]) { loop = true; break; }
					visited[c] = 1;
					for (int k = 0; k < _LANE_CLASSES_; ++k) if (!pass[k][c]) mask &= ~(1 << k);
				}
				if (loop || (mask & (1 << L_BOT)) || path.size() < 6) continue;
				bool duplicate = false;
				for (const auto& l : lanes) {
					if (l.cls != L_ALLTERRAIN) continue;
					int overlap = 0;
					for (int c : path) for (int other : l.cells) {
						if (std::abs(c % gw - other % gw) <= mr && std::abs(c / gw - other / gw) <= mr) { ++overlap; break; }
					}
					if (float(overlap) / path.size() >= 0.8f) { duplicate = true; break; }
				}
				if (duplicate) continue;
				SLane l; l.cls = L_ALLTERRAIN; l.mask = mask; l.cells = std::move(path); l.heat = 1;
				lanes.push_back(std::move(l)); ++added;
			}
		}
	}

    // Movement capability is not tactical value. A few steep cells or an
    // isolated summit must not create a strategic specialist lane. Apply the
    // same test to ordinary alternatives and every mountain-route generator.
    lanes.erase(std::remove_if(lanes.begin(), lanes.end(), [&](Route& l) {
        l.mountainQualified = l.cls == L_ALLTERRAIN && HasMountainTraverse(l, highGroundRise);
        return l.cls == L_ALLTERRAIN && !l.mountainQualified;
    }), lanes.end());

	// the lanes' measures
	for (SLane& l : lanes) {
		l.length = 0.f;
		l.width = std::numeric_limits<float>::max();
		l.choke = l.cells.front();
		float thrSum = 0.f;
		l.front = -1.f;
		for (size_t i = 0; i < l.cells.size(); ++i) {
			const int c = l.cells[i];
			const Point p = CellPos(c);
			if (i > 0) {
				l.length += p.distance2D(CellPos(l.cells[i - 1]));
			}
			if ((l.cls != L_AIR) && (i > l.cells.size() / 5) && (i < l.cells.size() * 4 / 5)) {
				// Measure the whole cross-section, not twice the nearest wall:
				// shortest paths hug coastlines even on a broad open approach.
				const Point before = CellPos(l.cells[i > 4 ? i - 4 : 0]);
				const Point after = CellPos(l.cells[std::min(i + 4, l.cells.size() - 1)]);
				const float dx = after.x - before.x, dz = after.z - before.z;
				const float len = std::sqrt(dx * dx + dz * dz);
				if (len < 1.f) continue;
				const float nx = -dz / len, nz = dx / len, step = cellSize * 0.5f;
				auto extent = [&](float sign) {
					float d = step;
					for (int k = 1; k <= 2 * (gw + gh); ++k, d += step) {
						const float x = p.x + nx * d * sign, z = p.z + nz * d * sign;
						if (x < 0.f || z < 0.f || x >= gw * cellSize || z >= gh * cellSize) break;
						if (!pass[l.cls][int(z / cellSize) * gw + int(x / cellSize)]) break;
					}
					return d;
				};
				const float left = extent(-1.f), right = extent(1.f);
				const float w = left + right;
				if (w < l.width) {
					l.width = w;
					const float offset = (right - left) * 0.5f;
					l.choke = Cell(Point(p.x + nx * offset, 0.f, p.z + nz * offset));
				}
			}
			const float th = std::max(0.f, (l.cls == L_AIR) ? request.airThreat[c] : request.surfThreat[c]);
			thrSum += th;
			if ((l.front < 0.f) && (th > 1.f)) {
				l.front = float(i) / std::max<size_t>(1, l.cells.size() - 1);
			}
		}
		if (l.width == std::numeric_limits<float>::max()) {
			l.width = 0.f;
		}
		l.threat = thrSum / std::max<size_t>(1, l.cells.size());
		l.zone.clear();
		l.zone.shrink_to_fit();
	}
	return std::move(lanes);
}


} // namespace circuit::lane

// Require real progress along one connected elevated component, not a sum of
// unrelated hills. Projection measures progress toward the opposite endpoint;
// a long sideways excursion or repeated visit cannot manufacture a flank.
bool circuit::lane::Solver::HasMountainTraverse(const Route& route, float rise) const
{
    if (route.cells.size() < 2 || (route.mask & (1 << L_BOT))) return false;
    const Point a = CellPos(route.cells.front()), b = CellPos(route.cells.back());
    const float distance = a.distance2D(b);
    if (distance < 1.f) return false;
    const float required = std::max(specialistMinSpan, distance * specialistSpanFraction);
    const float floor = std::max(a.y, b.y) + std::max(0.f, rise);
    const float dx = (b.x-a.x)/distance, dz = (b.z-a.z)/distance;
    std::vector<int> visited(height.size(), -1);
    for (int seed : route.cells) {
        if (visited[seed] >= 0 || height[seed] < floor) continue;
        CheckCancelled();
        std::vector<int> component{seed}; visited[seed] = seed;
        for (size_t i = 0; i < component.size(); ++i) {
            const int c = component[i], x = c % gw, z = c / gw;
            for (int j = 0; j < 4; ++j) {
                const int nx = x + NB[j][0], nz = z + NB[j][1];
                if (nx < 0 || nz < 0 || nx >= gw || nz >= gh) continue;
                const int n = nz*gw+nx;
                if (visited[n] < 0 && pass[L_ALLTERRAIN][n] && height[n] >= floor) {
                    visited[n] = seed; component.push_back(n);
                }
            }
        }
        // Visiting both ends of a ridge via the valley is not traversing it.
        // Require one uninterrupted segment of the route on this component.
        float lo = distance, hi = 0.f;
        for (int c : route.cells) {
            if (visited[c] != seed) { lo = distance; hi = 0.f; continue; }
            const Point p = CellPos(c);
            const float progress = std::clamp((p.x-a.x)*dx + (p.z-a.z)*dz, 0.f, distance);
            lo = std::min(lo, progress); hi = std::max(hi, progress);
            if (hi-lo >= required) return true;
        }
    }
    return false;
}
