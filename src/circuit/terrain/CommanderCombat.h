#pragma once

#include <algorithm>
#include <cmath>
#include <optional>
#include <vector>

namespace circuit::commander {
// Pure geometry, used by the live controller and its differential tests.
// Contacts are caller-owned and freshly observed in engine query order. Candidate
// directions are bounded; every local contact participates in line scoring.
struct Point { float x=0, z=0; };
inline Point operator+(Point a, Point b) { return {a.x+b.x,a.z+b.z}; }
inline Point operator-(Point a, Point b) { return {a.x-b.x,a.z-b.z}; }
inline Point operator*(Point a, float s) { return {a.x*s,a.z*s}; }
inline float Dot(Point a, Point b) { return a.x*b.x+a.z*b.z; }
inline float Length(Point a) { return std::sqrt(Dot(a,a)); }
inline Point Normal(Point a) { const float n=Length(a); return n>0.001f?a*(1.f/n):Point{}; }
// Both sites must satisfy the same map/perimeter admission. D-314: the rear
// fallback can itself leave the map. O(1), no allocation or retained state;
// commander_combat_test covers every edge and preserves valid-site ordering.
template<typename Admit>
std::optional<Point> LineBuildSite(Point anchor,Point toThreat,float spacing,int count,Admit admit) {
    const Point lateral{-toThreat.z,toThreat.x};
    const float side=float((count+1)/2)*(count%2?1.f:-1.f);
    const Point candidate=anchor+lateral*(side*spacing)-toThreat*(spacing*.5f);
    if(admit(candidate)) return candidate;
    const Point rear=anchor-toThreat*(spacing*.5f);
    if(admit(rear)) return rear;
    return std::nullopt;
}
struct FallbackBoundary {
    // One value snapshot: another unit can relocate the shared base between
    // the commander's 1 Hz plans. Never pair this radius with that live base.
    // O(1), no allocations; replaced as a whole by PlanFallback. Regression:
    // commander_combat_test and the sixteen-AI dense fallback arena.
    Point anchor;
    float radius=0;
    bool Contains(Point point,float margin=0) const {
        const Point delta=point-anchor;
        return Dot(delta,delta)<=(radius+margin)*(radius+margin);
    }
};
struct Contact {
    int id=-1;
    Point pos, velocity; // elmos and elmos/second
    float radius=16, cost=0, health=1, damage=0;
    float height=0;
    bool blocker=false, friendly=false, targetable=true, reserved=false, stopAfter=false;
    bool t3=false; // D-294: tagged once by the observer (in-LOS T3 definition)
    int combatTier=0; // mobile combatant: 1/2/3; zero is not a defence target
};
// D-319: a higher tier preempts, an equal tier retains the current target.
// Remaining ties use distance then ID, independent of spatial query order.
inline bool PreferDefenceTarget(int tier,int id,float distance,int bestTier,int bestId,float bestDistance,int current) {
    if(tier!=bestTier) return tier>bestTier;
    if(id==current || bestId==current) return id==current;
    return distance==bestDistance?id<bestId:distance<bestDistance;
}
struct Line { float value=0; int kills=0, target=-1; bool blocked=false; Point direction; bool requiredHit=false; };
// Exposure counts impacts inside the decision window, not launches. Reload
// evidence also bounds salvos already in flight; beams use zero flight time.
inline float BeamIntensity(float distance,float range,float minimum) {
    return range>0.f?std::max(minimum,1.f-std::max(0.f,distance)/(2.f*range)):1.f;
}
inline float CollisionHits(float radius,float speed) {
    // noExplode projectiles apply damage every simulation frame inside the
    // target volume. Bound a central crossing, including the first contact.
    return 1.f+std::ceil(2.f*std::max(0.f,radius)*30.f/std::max(1.f,speed));
}
inline float ImpactVolleys(float seconds,float reload,float delay,float flight,float newVolleyRisk=1.f) {
    reload=std::max(.1f,reload); delay=std::max(0.f,delay);
    const float first=delay+flight;
    const float future=seconds>=first?(1.f+(seconds-first)/reload)*std::clamp(newVolleyRisk,0.f,1.f):0.f;
    if(delay<=0.f || flight<=0.f) return future;
    const float latest=flight-(reload-delay);
    const float low=std::max(0.f,std::ceil((latest-seconds)/reload));
    const float high=std::floor(latest/reload);
    return future+std::max(0.f,high-low+1.f);
}
struct ShotClaim { int team,owner,generation,target,until; float damage; };
class ShotClaims {
public:
    void Prune(int frame) {
        claims.erase(std::remove_if(claims.begin(),claims.end(),[frame](const auto& c){return c.until<frame;}),claims.end());
    }
    void Release(int team,int owner) {
        claims.erase(std::remove_if(claims.begin(),claims.end(),[=](const auto& c){return c.team==team && c.owner==owner;}),claims.end());
    }
    void Reserve(ShotClaim claim) { claims.push_back(claim); }
    float Reserved(int target,int team,int owner) const {
        float sum=0; for(const auto& c:claims)
            if(c.target==target && (c.team!=team || c.owner!=owner)) sum+=c.damage;
        return sum;
    }
private:
    // Shared ally-team lifetime, engine callback thread only. O(C*H) storage
    // for C pending commanders and H intersections; no enemy handles survive.
    std::vector<ShotClaim> claims;
};
inline float TravelSeconds(float distance,float speed,float acceleration,float turnRate,float turnRadians) {
    const float accelerationSeconds=acceleration>0?std::min(speed/(acceleration*900.f),2.f):0.f;
    const float turning=std::abs(turnRadians)*65536.f/(6.2831853f*std::max(1.f,turnRate)*30.f);
    return distance/std::max(1.f,speed)+accelerationSeconds*.5f+turning;
}
inline bool Intersects(Point delta,Point direction,float length,float radius) {
    const float t=Dot(delta,direction);
    const Point nearest=direction*std::clamp(t,0.f,length);
    return Dot(delta-nearest,delta-nearest)<=radius*radius;
}
// Closest relative position over a linear move, including a crossing screen.
// Endpoint-only tests miss scouts that force decloak halfway through a route.
inline float Separation(Point from,Point to,Point enemy,Point velocity,float seconds) {
    const Point start=enemy-from,delta=velocity*seconds-(to-from);
    const float square=Dot(delta,delta);
    const float t=square>0?std::clamp(-Dot(start,delta)/square,0.f,1.f):0.f;
    return Length(start+delta*t);
}
inline Line ScoreLine(const std::vector<Contact>& contacts, Point origin, Point direction,
        float length, float speed, float width, float killReward, float safetyWidth,int requiredId=-1) {
    Line result; result.direction=Normal(direction);
    if (Length(result.direction)<.5f) return result;
    float stop=length;
    // First pass finds the first real commander or friendly collision. Enemies
    // behind that obstruction cannot inflate an otherwise attractive shot.
    for(const auto& c:contacts) {
        if(!c.blocker && !c.friendly && !c.stopAfter) continue;
        const float along=Dot(c.pos-origin,result.direction);
        const Point predicted=c.pos+c.velocity*(std::max(0.f,along)/std::max(1.f,speed));
        const Point delta=predicted-origin;
        const float t=Dot(delta,result.direction);
        const float r=c.radius+width+(c.friendly?safetyWidth:0.f);
        if(Intersects(delta,result.direction,length,r)) {
            // A shield can absorb this shot: value its owner conservatively,
            // but do not promise penetration into the force behind it.
            stop=std::min(stop,std::max(0.f,c.stopAfter?t:t-r));
            if(c.friendly) result.blocked=true;
        }
    }
    // A friendly anywhere in the swept volume vetoes the shot, even if a
    // predicted enemy hit comes first: DGun pierces that enemy.
    if(result.blocked) return result;
    for(const auto& c:contacts) {
        if(c.blocker || c.friendly || !c.targetable || c.reserved) continue;
        const float along=Dot(c.pos-origin,result.direction);
        const Point delta=c.pos+c.velocity*(std::max(0.f,along)/std::max(1.f,speed))-origin;
        const float t=Dot(delta,result.direction), r=c.radius+width;
        if(t<0 || !Intersects(delta,result.direction,stop,r)) continue;
        if(c.id==requiredId) result.requiredHit=true;
        const float fraction=std::min(1.f,std::max(0.f,c.damage)/std::max(1.f,c.health));
        result.value+=c.cost*fraction;
        if(fraction>=1.f) { ++result.kills; result.value+=killReward; }
        if(result.target<0) result.target=c.id;
    }
    return result;
}
// D-293 fallback group. A seed is a capable attacker within reach of the
// commander; its group is every capable attacker within radius of the seed.
// O(S*A) for S seeds in reach and A locally observed attackers (both bounded
// by the commander's scan query). Ties keep the earlier seed in engine order.
struct Attacker { Point pos; float cost=0; };
struct Group { float metal=0; Point centre; int seed=-1; };
inline Group StrongestGroup(const std::vector<Attacker>& attackers, Point origin, float reach, float radius) {
    Group best;
    const float reach2=reach*reach, radius2=radius*radius;
    for(size_t i=0;i<attackers.size();++i) {
        const Point fromOrigin=attackers[i].pos-origin;
        if(Dot(fromOrigin,fromOrigin)>reach2) continue;
        float metal=0; Point weighted;
        for(const auto& a:attackers) {
            const Point d=a.pos-attackers[i].pos;
            if(Dot(d,d)>radius2) continue;
            const float cost=std::max(0.f,a.cost);
            metal+=cost; weighted=weighted+a.pos*cost;
        }
        if(metal>best.metal) {
            best.metal=metal; best.seed=int(i);
            best.centre=metal>0?weighted*(1.f/metal):attackers[i].pos;
        }
    }
    return best;
}
inline float Reserve(float shotCost, float shots, float stillCost, float movingCost,
                     float stillSeconds, float movingSeconds, float margin) {
    return std::max(0.f,shotCost)*std::max(1.f,shots)
        +std::max(0.f,stillCost)*std::max(0.f,stillSeconds)
        +std::max(0.f,movingCost)*std::max(0.f,movingSeconds)+std::max(0.f,margin);
}
inline float MinimumValue(float base, float aggression, float weight) {
    return base*std::clamp(1.f-aggression*weight,.25f,2.f);
}
inline bool Affordable(float energy,float cost) { return std::isfinite(energy) && energy>=cost; }
// Recoil GameHelper explosion falloff, using a conservative surface distance.
inline float BlastDamage(float damage,float radius,float edge,float surfaceDistance) {
    if(radius<=0 || surfaceDistance>radius) return 0;
    const float d=std::max(0.f,surfaceDistance), e=std::clamp(edge,0.f,1.f);
    return std::max(0.f,damage)*(e==1.f || d<1.f ? 1.f : (radius+.001f-d)/(radius+.001f-d*e));
}
inline bool Survivable(float health,float maximum,float damage,float reserve) {
    return std::isfinite(damage) && health-damage>=maximum*reserve;
}
}
