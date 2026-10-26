#pragma once
#include "terrain/CommanderCombat.h"
#include <algorithm>
#include <cmath>
#include <vector>

namespace circuit { namespace commander {
// A synchronous local snapshot. Build exposed union arcs once (O(J^2 log J),
// O(J^2) worst-case storage); terrain candidates do no engine callbacks.
// Duplicate/contained circles and overlapping arcs are covered by the unit test.
class JammerCoverage {
public:
    struct Disc { Point center; float radius; };
    explicit JammerCoverage(std::vector<Disc> input={}):discs(std::move(input)) {
        constexpr float tau=6.28318530718f;
        std::vector<std::pair<float,float>> covered;
        for(size_t i=0;i<discs.size();++i) {
            const auto& a=discs[i];
            if(a.radius<=0) continue;
            covered.clear(); bool contained=false;
            for(size_t j=0;j<discs.size();++j) {
                if(i==j) continue;
                const auto& b=discs[j];
                const Point delta=b.center-a.center;
                const float distance=Length(delta);
                if(distance+a.radius<=b.radius) {
                    if(distance>0 || a.radius<b.radius || j<i) {contained=true;break;}
                    continue;
                }
                if(distance>=a.radius+b.radius || distance+b.radius<=a.radius || distance<=0) continue;
                float angle=std::atan2(delta.z,delta.x); if(angle<0) angle+=tau;
                const float half=std::acos(std::clamp((distance*distance+a.radius*a.radius-b.radius*b.radius)
                    /(2.f*distance*a.radius),-1.f,1.f));
                const float lo=angle-half,hi=angle+half;
                if(lo<0) {covered.emplace_back(0,hi);covered.emplace_back(lo+tau,tau);}
                else if(hi>tau) {covered.emplace_back(lo,tau);covered.emplace_back(0,hi-tau);}
                else covered.emplace_back(lo,hi);
            }
            if(contained) continue;
            std::sort(covered.begin(),covered.end());
            float end=0;
            for(const auto& interval:covered) {
                if(interval.first>end) arcs.push_back({a,end,interval.first});
                end=std::max(end,interval.second);
            }
            if(end<tau) arcs.push_back({a,end,tau});
        }
    }
    bool NearUnjammed(Point p,float margin) const {
        bool inside=false;
        for(const auto& d:discs) if(Length(p-d.center)<d.radius) {inside=true;break;}
        if(!inside) return true;
        constexpr float tau=6.28318530718f;
        for(const auto& a:arcs) {
            const Point delta=p-a.disc.center;
            float angle=std::atan2(delta.z,delta.x); if(angle<0) angle+=tau;
            if(angle>=a.lo && angle<=a.hi && std::abs(Length(delta)-a.disc.radius)<=margin) return true;
            for(float end:{a.lo,a.hi}) {
                const Point edge=a.disc.center+Point{std::cos(end),std::sin(end)}*a.disc.radius;
                if(Length(p-edge)<=margin) return true;
            }
        }
        return false;
    }
private:
    struct Arc { Disc disc; float lo,hi; };
    std::vector<Disc> discs;
    std::vector<Arc> arcs;
};
}}
