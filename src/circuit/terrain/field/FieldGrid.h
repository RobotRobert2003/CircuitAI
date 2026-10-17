/*
 * FieldGrid.h
 *
 * D-323: grid helpers for the field analysis. Header-only, engine-free, used
 * by FieldAnalysis.cpp and the native tests. Everything is O(N) in the cells
 * or O(S log S) in the segments it is given; nothing allocates per call
 * beyond its result.
 */

#ifndef SRC_CIRCUIT_TERRAIN_FIELD_FIELDGRID_H_
#define SRC_CIRCUIT_TERRAIN_FIELD_FIELDGRID_H_

#include "terrain/field/FieldTypes.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <unordered_map>
#include <vector>

namespace circuit::field {

// 8-neighbour offsets, E S W N first (the 4-neighbours), then the diagonals.
constexpr int kDx[8] = {1, 0, -1, 0, 1, -1, -1, 1};
constexpr int kDz[8] = {0, 1, 0, -1, 1, 1, -1, -1};

struct SGridShape {
	int gw = 0, gh = 0;
	int Size() const { return gw * gh; }
	bool Inside(int x, int z) const { return x >= 0 && z >= 0 && x < gw && z < gh; }
	int Index(int x, int z) const { return z * gw + x; }
	int X(int c) const { return c % gw; }
	int Z(int c) const { return c / gw; }
};

// Chamfer 3-4 distance to the nearest cell outside the mask (or the map edge),
// in thirds of a cell. Mask cells get >= 3; others 0. Two passes, O(N).
inline void ChamferDistance(const SGridShape& g, const std::vector<char>& mask, std::vector<int>& out)
{
	const int n = g.Size();
	constexpr int kFar = 1 << 28;
	out.assign(n, 0);
	for (int c = 0; c < n; ++c) {
		out[c] = mask[c] ? kFar : 0;
	}
	auto relax = [&](int c, int x, int z, int dx, int dz, int w) {
		const int nx = x + dx, nz = z + dz;
		const int v = g.Inside(nx, nz) ? out[g.Index(nx, nz)] + w : w;   // beyond the edge is distance 0
		if (v < out[c]) out[c] = v;
	};
	for (int z = 0; z < g.gh; ++z) {
		for (int x = 0; x < g.gw; ++x) {
			const int c = g.Index(x, z);
			if (out[c] == 0) continue;
			relax(c, x, z, -1, 0, 3); relax(c, x, z, 0, -1, 3);
			relax(c, x, z, -1, -1, 4); relax(c, x, z, 1, -1, 4);
		}
	}
	for (int z = g.gh - 1; z >= 0; --z) {
		for (int x = g.gw - 1; x >= 0; --x) {
			const int c = g.Index(x, z);
			if (out[c] == 0) continue;
			relax(c, x, z, 1, 0, 3); relax(c, x, z, 0, 1, 3);
			relax(c, x, z, 1, 1, 4); relax(c, x, z, -1, 1, 4);
		}
	}
}

// A segment between two keyed points (grid corners or quantised contour points).
struct SSegment {
	std::int64_t ka = 0, kb = 0;
	SPoint a, b;
};

// Join segments into polylines: open chains first (from degree-1 points), then
// loops. Chains stop at points with more than two segments so a junction never
// produces a wrong turn. O(S log S) through the hash map; deterministic.
inline std::vector<Polyline> ChainSegments(const std::vector<SSegment>& segs)
{
	std::vector<Polyline> out;
	if (segs.empty()) return out;
	std::unordered_map<std::int64_t, std::vector<int>> at;
	at.reserve(segs.size() * 2);
	for (int i = 0; i < (int)segs.size(); ++i) {
		at[segs[i].ka].push_back(i);
		at[segs[i].kb].push_back(i);
	}
	std::vector<char> used(segs.size(), 0);
	auto other = [&](int s, std::int64_t k) { return segs[s].ka == k ? segs[s].kb : segs[s].ka; };
	auto pointOf = [&](int s, std::int64_t k) { return segs[s].ka == k ? segs[s].a : segs[s].b; };
	auto nextFrom = [&](std::int64_t k, int& found) -> bool {
		const auto it = at.find(k);
		if (it == at.end()) return false;
		int count = 0, cand = -1;
		for (int s : it->second) if (!used[s]) { ++count; cand = s; }
		if (count != 1) return false;   // end, or a junction
		found = cand;
		return true;
	};
	auto walk = [&](int start) {
		Polyline line;
		std::int64_t k = segs[start].ka;
		line.push_back(segs[start].a);
		line.push_back(segs[start].b);
		used[start] = 1;
		k = segs[start].kb;
		int s;
		while (nextFrom(k, s)) {
			used[s] = 1;
			k = other(s, k);
			line.push_back(pointOf(s, k));
			if (k == segs[start].ka) break;   // closed
		}
		// extend backwards from the start point for open chains
		k = segs[start].ka;
		if (line.front().x != line.back().x || line.front().z != line.back().z) {
			Polyline back;
			while (nextFrom(k, s)) {
				used[s] = 1;
				k = other(s, k);
				back.push_back(pointOf(s, k));
			}
			if (!back.empty()) {
				std::reverse(back.begin(), back.end());
				back.insert(back.end(), line.begin(), line.end());
				line.swap(back);
			}
		}
		out.push_back(std::move(line));
	};
	// Open chains first, started from degree-1 points, so loops do not swallow them.
	for (int i = 0; i < (int)segs.size(); ++i) {
		if (used[i]) continue;
		auto degree = [&](std::int64_t k) {
			int d = 0;
			for (int s : at[k]) if (!used[s]) ++d;
			return d;
		};
		if (degree(segs[i].ka) == 1 || degree(segs[i].kb) == 1) walk(i);
	}
	for (int i = 0; i < (int)segs.size(); ++i) {
		if (!used[i]) walk(i);
	}
	return out;
}

// Douglas-Peucker simplification with tolerance in the polyline's units.
inline Polyline Simplify(const Polyline& line, float tolerance)
{
	if (line.size() < 3) return line;
	std::vector<char> keep(line.size(), 0);
	keep.front() = keep.back() = 1;
	std::vector<std::pair<int, int>> stack;
	stack.emplace_back(0, (int)line.size() - 1);
	const float tol2 = tolerance * tolerance;
	while (!stack.empty()) {
		const auto [i0, i1] = stack.back();
		stack.pop_back();
		if (i1 - i0 < 2) continue;
		const SPoint& p0 = line[i0];
		const SPoint& p1 = line[i1];
		const float dx = p1.x - p0.x, dz = p1.z - p0.z;
		const float len2 = dx * dx + dz * dz;
		float best = -1.f;
		int bestI = -1;
		for (int i = i0 + 1; i < i1; ++i) {
			const float ex = line[i].x - p0.x, ez = line[i].z - p0.z;
			float d2;
			if (len2 <= 1e-6f) {
				d2 = ex * ex + ez * ez;
			} else {
				const float t = std::clamp((ex * dx + ez * dz) / len2, 0.f, 1.f);
				const float px = ex - t * dx, pz = ez - t * dz;
				d2 = px * px + pz * pz;
			}
			if (d2 > best) { best = d2; bestI = i; }
		}
		if (best > tol2 && bestI >= 0) {
			keep[bestI] = 1;
			stack.emplace_back(i0, bestI);
			stack.emplace_back(bestI, i1);
		}
	}
	Polyline out;
	out.reserve(line.size());
	for (std::size_t i = 0; i < line.size(); ++i) if (keep[i]) out.push_back(line[i]);
	return out;
}

inline float PolylineLength(const Polyline& line)
{
	float len = 0.f;
	for (std::size_t i = 1; i < line.size(); ++i) {
		len += std::hypot(line[i].x - line[i - 1].x, line[i].z - line[i - 1].z);
	}
	return len;
}

// Marching squares over cell-centre values: segments where value crosses
// `level`, restricted to squares whose four cells all pass `inside`. Points
// are in cell units (centre of cell (x, z) = (x + 0.5, z + 0.5)) and keyed on
// an eighth of a cell so ChainSegments can join them.
template<typename Inside>
inline std::vector<SSegment> Contour(const SGridShape& g, const std::vector<float>& value, float level, Inside inside)
{
	std::vector<SSegment> segs;
	auto key = [](float x, float z) {
		return (std::int64_t)std::lround(x * 8.f) * 4000000LL + (std::int64_t)std::lround(z * 8.f);
	};
	auto make = [&](SPoint a, SPoint b) {
		SSegment s;
		s.a = a; s.b = b; s.ka = key(a.x, a.z); s.kb = key(b.x, b.z);
		if (s.ka != s.kb) segs.push_back(s);
	};
	for (int z = 0; z + 1 < g.gh; ++z) {
		for (int x = 0; x + 1 < g.gw; ++x) {
			const int c00 = g.Index(x, z), c10 = c00 + 1, c01 = c00 + g.gw, c11 = c01 + 1;
			if (!inside(c00) || !inside(c10) || !inside(c01) || !inside(c11)) continue;
			const float v00 = value[c00], v10 = value[c10], v01 = value[c01], v11 = value[c11];
			const float cx = x + 0.5f, cz = z + 0.5f;
			SPoint pts[4];
			int n = 0;
			auto cross = [&](float va, float vb, float ax, float az, float bx, float bz) {
				if ((va < level) == (vb < level)) return;
				const float t = (vb == va) ? 0.5f : std::clamp((level - va) / (vb - va), 0.f, 1.f);
				pts[n++] = {ax + (bx - ax) * t, az + (bz - az) * t};
			};
			cross(v00, v10, cx, cz, cx + 1, cz);           // top
			cross(v10, v11, cx + 1, cz, cx + 1, cz + 1);   // right
			cross(v11, v01, cx + 1, cz + 1, cx, cz + 1);   // bottom
			cross(v01, v00, cx, cz + 1, cx, cz);           // left
			if (n == 2) {
				make(pts[0], pts[1]);
			} else if (n == 4) {
				const float centre = 0.25f * (v00 + v10 + v01 + v11);
				if ((centre < level) == (v00 < level)) { make(pts[0], pts[3]); make(pts[1], pts[2]); }
				else { make(pts[0], pts[1]); make(pts[2], pts[3]); }
			}
		}
	}
	return segs;
}

// Run-length encoding of a per-cell id grid: "id*count;id*count;...".
inline std::string RunLength(const std::vector<int>& ids)
{
	std::string out;
	out.reserve(ids.size() / 8);
	std::size_t i = 0;
	while (i < ids.size()) {
		std::size_t j = i + 1;
		while (j < ids.size() && ids[j] == ids[i]) ++j;
		if (!out.empty()) out += ';';
		out += std::to_string(ids[i]);
		out += '*';
		out += std::to_string(j - i);
		i = j;
	}
	return out;
}

inline std::uint64_t Fnv1a(std::uint64_t h, const void* data, std::size_t bytes)
{
	const unsigned char* p = static_cast<const unsigned char*>(data);
	for (std::size_t i = 0; i < bytes; ++i) {
		h ^= p[i];
		h *= 1099511628211ULL;
	}
	return h;
}

} // namespace circuit::field

#endif // SRC_CIRCUIT_TERRAIN_FIELD_FIELDGRID_H_
