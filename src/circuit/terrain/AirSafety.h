#pragma once
#include <algorithm>
#include <cmath>
#include <limits>

namespace circuit::air {
inline bool IntersectsCircle(float ax,float az,float bx,float bz,float cx,float cz,float radius) {
    const float dx=bx-ax,dz=bz-az,len=dx*dx+dz*dz;
    const float t=len>.001f?std::clamp(((cx-ax)*dx+(cz-az)*dz)/len,0.f,1.f):0.f;
    const float ex=cx-ax-t*dx,ez=cz-az-t*dz;
    return ex*ex+ez*ez<=radius*radius;
}
// Conservative capsule rasterisation. Work scales with corridor length * width,
// not its diagonal bounding rectangle. Query every intersected threat-grid cell.
template<class Sample>
float CorridorThreat(float ax, float az, float bx, float bz, float padding,
    float width, float height, float cell, Sample sample)
{
    const float bad = std::numeric_limits<float>::infinity();
    if (!std::isfinite(ax) || !std::isfinite(az) || !std::isfinite(bx) || !std::isfinite(bz)
        || !std::isfinite(padding) || padding < 0 || padding > 2048 || cell <= 0
        || std::min(ax, bx) < padding || std::min(az, bz) < padding
        || std::max(ax, bx) + padding >= width || std::max(az, bz) + padding >= height) return bad;
    bool swap = std::abs(bz-az) > std::abs(bx-ax);
    if (swap) { std::swap(ax, az); std::swap(bx, bz); std::swap(width, height); }
    const float dx = bx-ax, dz = bz-az, lenSq = dx*dx+dz*dz;
    const float reach = padding + cell * .707107f;
    const int first = std::max(0, int(std::floor((std::min(ax,bx)-reach)/cell)));
    const int last = std::min(int(std::ceil(width/cell))-1, int((std::max(ax,bx)+reach)/cell));
    float worst = 0;
    for (int x = first; x <= last; ++x) {
        const float px = (x+.5f)*cell;
        const float t = std::abs(dx) > .001f ? std::clamp((px-ax)/dx,0.f,1.f) : 0.f;
        const float centre = az + t*dz;
        const float band = reach * 1.414214f + cell;
        const int bottom = std::max(0, int(std::floor((centre-band)/cell)));
        const int top = std::min(int(std::ceil(height/cell))-1, int((centre+band)/cell));
        for (int z = bottom; z <= top; ++z) {
            const float pz = (z+.5f)*cell;
            const float along = lenSq > .001f ? std::clamp(((px-ax)*dx+(pz-az)*dz)/lenSq,0.f,1.f) : 0.f;
            const float ex = px-ax-along*dx, ez = pz-az-along*dz;
            if (ex*ex+ez*ez > reach*reach) continue;
            const float v = swap ? sample(pz,px) : sample(px,pz);
            if (!std::isfinite(v)) return bad;
            worst = std::max(worst,v);
        }
    }
    return worst;
}
}
