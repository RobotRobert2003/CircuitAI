#pragma once
#include "terrain/LaneSolver.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <queue>
#include <vector>

namespace circuit::lane {
// Publication-only supercover of the complete polyline, then the existing
// Chebyshev distance transform. O(crossed cells + grid cells), O(grid) memory.
// Owned by CBattleAnalysis; replaced on lane publication/clear. Hot consumers
// retain one grid lookup. Sparse centres must behave like dense routes.
// Regression: tests/lane_raster_test.cpp.
inline std::vector<float> CorridorDistances(const std::vector<Point>& points,
        int width, int height, float pitch) {
    if (width <= 0 || height <= 0 || !(pitch > 0) || points.size() < 2) return {};
    std::vector<float> distance(std::size_t(width) * height, std::numeric_limits<float>::max());
    std::queue<int> pending;
    const auto seed = [&](int x, int z) {
        if (x < 0 || z < 0 || x >= width || z >= height) return;
        const int c = z * width + x;
        if (distance[c] != 0) { distance[c] = 0; pending.push(c); }
    };
    for (std::size_t i = 1; i < points.size(); ++i) {
        const auto& a = points[i-1]; const auto& b = points[i];
        if (!std::isfinite(a.x) || !std::isfinite(a.z) || !std::isfinite(b.x) || !std::isfinite(b.z)) continue;
        int x = int(std::floor(a.x/pitch)), z = int(std::floor(a.z/pitch));
        const int ex = int(std::floor(b.x/pitch)), ez = int(std::floor(b.z/pitch));
        const double dx = double(b.x)-a.x, dz = double(b.z)-a.z;
        const int sx = dx > 0 ? 1 : dx < 0 ? -1 : 0, sz = dz > 0 ? 1 : dz < 0 ? -1 : 0;
        const double inf = std::numeric_limits<double>::infinity();
        const double tx = sx ? pitch/std::abs(dx) : inf, tz = sz ? pitch/std::abs(dz) : inf;
        double nx = sx ? (((sx>0?x+1:x)*double(pitch))-a.x)/dx : inf;
        double nz = sz ? (((sz>0?z+1:z)*double(pitch))-a.z)/dz : inf;
        seed(x,z);
        const int limit = std::abs(ex-x)+std::abs(ez-z)+2;
        for (int step=0; step<limit && (x!=ex || z!=ez); ++step) {
            if (nx < nz) { x+=sx; nx+=tx; }
            else if (nz < nx) { z+=sz; nz+=tz; }
            else { seed(x+sx,z); seed(x,z+sz); x+=sx; z+=sz; nx+=tx; nz+=tz; }
            seed(x,z);
        }
    }
    while (!pending.empty()) {
        const int c=pending.front(); pending.pop();
        const int x=c%width,z=c/width;
        for (int dz=-1;dz<=1;++dz) for (int dx=-1;dx<=1;++dx) {
            if ((!dx&&!dz) || x+dx<0 || z+dz<0 || x+dx>=width || z+dz>=height) continue;
            const int next=(z+dz)*width+x+dx;
            if (distance[next]>distance[c]+pitch) { distance[next]=distance[c]+pitch;pending.push(next); }
        }
    }
    return distance;
}
}
