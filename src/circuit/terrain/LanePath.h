#pragma once
#include "terrain/LaneSolver.h"
#include <algorithm>
#include <limits>

namespace circuit::lane {
// AI-owned immutable publication between Set calls. O(P) projection and O(log P)
// sampling, no allocations on reads; P is the published polyline point count.
class Path {
public:
    struct Projection { float progress=0, distance=std::numeric_limits<float>::max(); };
    void Set(std::vector<Point> value) {
        points=std::move(value);lengths.assign(points.size(),0.f);
        for(std::size_t i=1;i<points.size();++i)lengths[i]=lengths[i-1]+points[i-1].distance2D(points[i]);
    }
    float Length() const {return lengths.empty()?0.f:lengths.back();}
    Projection Project(Point p) const {
        Projection best;
        for(std::size_t i=1;i<points.size();++i) {
            const auto a=points[i-1],b=points[i];const float dx=b.x-a.x,dz=b.z-a.z,sq=dx*dx+dz*dz;
            const float f=sq>0?std::clamp(((p.x-a.x)*dx+(p.z-a.z)*dz)/sq,0.f,1.f):0.f;
            const float distance=p.distance2D({a.x+f*dx,0,a.z+f*dz});
            if(distance<best.distance)best={lengths[i-1]+f*(lengths[i]-lengths[i-1]),distance};
        }
        return best;
    }
    Point At(float distance) const {
        if(points.empty())return {-1,0,-1};
        if(distance<=0)return points.front();
        if(distance>=Length())return points.back();
        const auto i=std::size_t(std::upper_bound(lengths.begin(),lengths.end(),distance)-lengths.begin());
        const float f=(distance-lengths[i-1])/std::max(.001f,lengths[i]-lengths[i-1]);
        const auto a=points[i-1],b=points[i];return {a.x+(b.x-a.x)*f,a.y+(b.y-a.y)*f,a.z+(b.z-a.z)*f};
    }
private:
    std::vector<Point> points;
    std::vector<float> lengths;
};
}
