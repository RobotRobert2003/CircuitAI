#pragma once
#include <limits>
#include "terrain/CommanderCombat.h"
namespace circuit::commander {
// Geometry only. Fixed 64-elmo probes bounded by the public map diagonal; no
// army scan. The caller supplies its owned territory predicate. Slots cover the
// end strips, unlike simply rounding the width down to a spacing multiple.
template<class Admit>
std::vector<Point> TerritoryLine(Point center, Point forward, float spacing, Admit admit, int maxSteps=128) {
    std::vector<Point> sites;
    if(spacing<=0 || !admit(center)) return sites;
    forward=Normal(forward);
    if(Length(forward)<.5f) return sites;
    const Point side{-forward.z,forward.x};
    float edges[2]={0,0};
    for(int sign=0;sign<2;++sign) {
        for(int i=1;i<=maxSteps;++i) {
            const float d=i*64.f;
            if(!admit(center+side*(sign?d:-d))) break;
            edges[sign]=d;
        }
    }
    sites.push_back(center);
    for(int sign=0;sign<2;++sign) {
        const float end=std::max(0.f,edges[sign]-32.f);
        const int count=int(std::ceil(end/spacing));
        for(int i=1;i<=count;++i) sites.push_back(center+side*((sign?1.f:-1.f)*end*i/count));
    }
    return sites;
}

inline bool EnemySideCover(Point mex,Point turret,Point forward,float range) {
    return Dot(turret-mex,Normal(forward))>32.f && Length(turret-mex)<=range;
}
// Nearest point to the target inside a single convex jam disc. Keeping the
// requested inset leaves room for movement resolution at the coverage edge.
inline Point JamFiringPoint(Point center,float radius,float inset,Point target) {
    const auto delta=target-center;
    return center+Normal(delta)*std::min(std::max(0.f,radius-inset),Length(delta));
}
struct CoverageSpan { float begin,end; };
inline bool TurretCoverage(Point turret,Point center,Point side,float range,CoverageSpan& out) {
    const auto delta=turret-center;
    const float across=Dot(delta,side);
    const float depth2=std::max(0.f,Dot(delta,delta)-across*across);
    if(depth2>range*range) return false;
    const float reach=std::sqrt(range*range-depth2);
    out={across-reach,across+reach};return true;
}
// Exact interval union on the planned cross-section. Existing off-line mex
// defenses contribute their real geometric reach; slot proximity alone both
// rejects useful coverage and can deadlock on a blocked duplicate turret.
inline float FirstCoverageGap(std::vector<CoverageSpan>& spans,float begin,float end) {
    std::sort(spans.begin(),spans.end(),[](const auto& a,const auto& b) { return a.begin<b.begin; });
    float covered=begin;
    for(const auto& span:spans) {
        if(span.end<covered) continue;
        if(span.begin>covered) return covered;
        covered=std::max(covered,span.end);
        if(covered>=end) return end;
    }
    return covered;
}
// spans were sorted by FirstCoverageGap. A short hole must be filled inside
// that hole, not by projecting the normal spacing into already covered ground.
inline float GapBuildOffset(const std::vector<CoverageSpan>& spans,float gap,float end,float advance) {
    float gapEnd=end;
    for(const auto& span:spans) if(span.begin>gap) {gapEnd=std::min(end,span.begin);break;}
    return std::min(gap+advance,(gap+gapEnd)*.5f);
}
// Sorted intervals from FirstCoverageGap. Select a nearby uncovered section,
// not the first hole at the far map edge. Midpoints avoid duplicating a turret
// exactly at an existing coverage boundary. O(L), no additional allocation.
inline float NearestCoverageGap(const std::vector<CoverageSpan>& spans,float begin,float end,float position) {
    float cursor=begin,best=end,distance=std::numeric_limits<float>::max();
    const auto consider=[&](float a,float b) {
        if(b<=a) return;
        const float inset=std::min(64.f,(b-a)*.5f);
        const float candidate=std::clamp(position,a+inset,b-inset);
        if(std::abs(candidate-position)<distance) {best=candidate;distance=std::abs(candidate-position);}
    };
    for(const auto& span:spans) {
        if(span.end<cursor) continue;
        consider(cursor,std::min(end,span.begin));
        cursor=std::max(cursor,span.end);
        if(cursor>=end) break;
    }
    consider(cursor,end);
    return best;
}
}
