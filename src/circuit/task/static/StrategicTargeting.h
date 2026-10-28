#pragma once

#include <algorithm>
#include <cmath>
#include <vector>

// Engine-free target/claim rules. Callers supply all policy thresholds.
namespace circuit::strategic {
struct Point { float x, z; };
inline float DistanceSq(Point a, Point b) { return (a.x-b.x)*(a.x-b.x) + (a.z-b.z)*(a.z-b.z); }
inline bool Valid(Point p) { return std::isfinite(p.x) && std::isfinite(p.z) && p.x >= 0 && p.z >= 0; }
inline int SensorClass(bool jammer, bool radar, bool mobile, bool advanced)
{
    if (!jammer && !radar) return -1;
    if (mobile) return jammer ? 4 : 5;
    return jammer ? (advanced ? 0 : 1) : (advanced ? 2 : 3);
}
inline bool NuclearTarget(bool mobile, bool known, bool structuresOnly) { return known && (!structuresOnly || !mobile); }
struct Claim { int owner, expires; Point pos; float radius; bool pending; };
class Ledger {
public:
    bool Blocked(Point p, int owner, int frame, bool perOwner, bool ignoreOwnPending = true) const
    {
        return std::any_of(claims.begin(), claims.end(), [&](const Claim& c) {
            return c.expires > frame && (!perOwner || c.owner == owner)
                && !(ignoreOwnPending && c.pending && c.owner == owner)
                && DistanceSq(p, c.pos) <= c.radius*c.radius;
        });
    }
    void ReleasePending(int owner)
    {
        std::erase_if(claims, [=](const Claim& c) { return c.owner == owner && c.pending; });
    }
    void Add(int owner, Point pos, float radius, int frame, int duration, bool pending)
    {
        std::erase_if(claims, [=](const Claim& c) { return c.expires <= frame; });
        ReleasePending(owner);
        if (Valid(pos) && radius >= 0 && duration > 0) claims.push_back({owner, frame + duration, pos, radius, pending});
    }
    template<class Alive> void Prune(int frame, const Alive& alive)
    {
        std::erase_if(claims, [&](const Claim& c) { return c.expires <= frame || !alive(c.owner); });
    }
private:
    std::vector<Claim> claims;
};
// Overnuke (owner 2026-10-28): with enough silos every one of them fires at
// one target until `goal` launches have gone at it (the caller rolls 17-30),
// or no target is left there, then the next. Every `scoutEvery` launches it
// counts a scout request; finished targets go to `done` so none is picked again.
class Overnuke {
public:
    bool Active() const { return Valid(pos) && fired < goal; }
    bool Covers(Point p) const { return Active() && DistanceSq(p, pos) <= radius*radius; }
    void Begin(Point p, float r, int roll) { pos = p; radius = std::max(0.f, r); goal = std::max(1, roll); fired = 0; }
    // A launch at p. True when it counted against the target.
    bool Count(Point p, int frame, int duration, int scoutEvery)
    {
        if (!Covers(p)) return false;
        ++fired;
        if (scoutEvery > 0 && fired % scoutEvery == 0) ++scouts;
        if (fired >= goal) End(frame, duration);
        return true;
    }
    void End(int frame, int duration)
    {
        if (!Valid(pos)) return;
        if (fired < goal) goal = fired;
        done.Add(-1, pos, radius, frame, duration, false);
    }
    bool Done(Point p, int frame) const { return done.Blocked(p, -1, frame, false); }
    Point Pos() const { return pos; }
    float Radius() const { return radius; }
    int Fired() const { return fired; }
    int Goal() const { return goal; }
    int Scouts() const { return scouts; }  // every scout request so far, all targets
private:
    Point pos{-1.f, -1.f};
    float radius = 0.f;
    int goal = 0, fired = 0, scouts = 0;
    Ledger done;
};
}
