#pragma once
#include <algorithm>
#include <cmath>
#include <vector>

namespace circuit::visibility {
// Distance to unseen cell rectangles, including holes inside visible terrain.
// Clipping excludes off-map space. Borrow the owner's current LOS snapshot:
// O((radius/cellSize)^2) cells, no allocation/callback/cache. See fog_proximity_test.
inline bool NearFog(const std::vector<int>& los, int width, int cellSize,
                    float x, float z, float radius) {
    if (width <= 0 || cellSize <= 0 || los.empty() || los.size()%width != 0
        || !std::isfinite(x) || !std::isfinite(z) || !std::isfinite(radius) || radius < 0) return false;
    const int height = int(los.size()/width);
    if (x < 0 || z < 0 || x >= width*cellSize || z >= height*cellSize) return false;
    const int x0 = std::max(0, int(std::max(0.f, x-radius)/cellSize)-1);
    const int z0 = std::max(0, int(std::max(0.f, z-radius)/cellSize)-1);
    const int x1 = int(std::min(float(width-1), (x+radius)/cellSize));
    const int z1 = int(std::min(float(height-1), (z+radius)/cellSize));
    for (int row=z0; row<=z1; ++row) for (int col=x0; col<=x1; ++col) {
        if (los[row*width+col] > 0) continue;
        const float dx = std::max({float(col*cellSize)-x, 0.f, x-float((col+1)*cellSize)});
        const float dz = std::max({float(row*cellSize)-z, 0.f, z-float((row+1)*cellSize)});
        if (dx*dx+dz*dz <= radius*radius) return true;
    }
    return false;
}
}
