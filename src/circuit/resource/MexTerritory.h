#pragma once

// D-352: mex ownership by theatre. Engine-free rules over numbers the manager
// extracts from its terrain fields, so every rule is unit-testable
// (tests/mex_territory_test.cpp) and the same on every allied AI.
//
//   mex_territory::Resolve  one spot: theatre mask, rule, owner, race times
//   mex_lanes::Build        the deterministic lane partition from the ground
//                           distance fields of both sides and the metal clusters
//
// Nothing here reads engine state, threat, time of day or per-AI data: the
// inputs are broadcast roster claims, start boxes and the terrain grid, so
// two allies with the same roster compute the same owner for every spot.
// See ../../../../rjm.bar.docs/projects/circuitai/mex-theatres-proposal.md.

#include "resource/MexNavigation.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <queue>
#include <utility>
#include <vector>

namespace circuit::mex_territory {
using mex_navigation::Unreachable;

enum Theatre : int { LAND = 1, NAVAL = 2, HOVER = 4, AIR = 8 };
enum class Rule : int {
    NONE = 0,        // no claimant can own it: front-line ground, anyone may build
    HOME,            // rule 1: inside a claimant's home radius
    SEA,             // rule 3: a SEA claimant's ships reach it
    LANE,            // rule 2 refinement: a lane cluster, the lane's members
    LAND_WALK,       // rule 2: nearest claimant by ground walk (D-322)
    FORWARD,         // a lane cluster past the midpoint: enemy ground during the window
    RACE_SECURED,    // rule 4: a claimant is secure before the enemy can arrive
    RACE_CONTESTED,  // rule 4: a claimant's combat class holds it first
    RACE_AIR,        // rule 4: only aircraft reach it, so the AIR claimant owns it
    OPEN_LAND,       // after the window: nearest start by horizontal distance (D-072)
    OPEN_CLASS       // after the window: nearest claimant whose class has a stance
};
inline const char* RuleName(Rule r) {
    switch (r) {
        case Rule::HOME: return "home"; case Rule::SEA: return "sea"; case Rule::LANE: return "lane";
        case Rule::LAND_WALK: return "walk"; case Rule::FORWARD: return "forward";
        case Rule::RACE_SECURED: return "secured"; case Rule::RACE_CONTESTED: return "contested";
        case Rule::RACE_AIR: return "air"; case Rule::OPEN_LAND: return "open-land";
        case Rule::OPEN_CLASS: return "open-class"; default: return "none";
    }
}

// One claimant's view of one spot. Distances are terrain-field stance
// distances in elmos (Unreachable when no legal construction stance of that
// class is reached); readiness is an absolute frame from the roster.
struct Entrant {
    int team = -1;
    int kind = LAND;                       // Theatre bit of the constructor class
    float groundDistance = Unreachable;    // ground class (LAND bit); Unreachable: no walk
    float startDistance2D = Unreachable;   // horizontal start-to-spot distance (home, D-072)
    float classDistance = Unreachable;     // own class stance distance (kind NAVAL/HOVER/AIR)
    float classSpeed = 0.f;                // elmos per second
    int readyFrame = 0;                    // first constructor of the class exists
    float secureSeconds = 0.f;             // lead needed after arriving to hold the ground
    float combatDistance = Unreachable;    // combat class stance distance
    float combatSpeed = 0.f;
    int combatReadyFrame = 0;
    bool laneSpots = false;                // may claim lane clusters (FRONT, SUPPORT)
    int lane = -1;                         // lane this claimant's route belongs to
};
struct Inputs {
    std::vector<Entrant> entrants;         // in team-id order
    float enemySeconds = Unreachable;      // earliest enemy arrival of any class, seconds (the secured test)
    float enemyCombatSeconds = Unreachable;// earliest enemy arrival of a combat class (the contested test);
                                           // a constructor landing first does not hold the ground
    float homeRadius = 900.f;
    int lane = -1;                         // the spot's cluster lane, -1 none
    int corridor = -1;                     // D-357: the FRONT team whose published coverage corridor holds the spot, -1 none
    bool corridorForward = false;          // the spot lies past the corridor's midpoint
    bool forward = false;                  // the cluster lies past its lane's midpoint
    bool window = true;                    // the land window (MexOwnershipSeconds) still runs
    bool theatreWindow = true;             // the sea/race window (MexTheatreSeconds) still runs
    float framesPerSecond = 30.f;
};
struct Result {
    int mask = AIR;
    Rule rule = Rule::NONE;
    int owner = -1;
    float arriveSeconds = Unreachable, secureSeconds = Unreachable, enemySeconds = Unreachable;
};

inline int Mask(const std::vector<Entrant>& entrants) {
    int mask = AIR;
    for (const auto& e : entrants) {
        if (std::isfinite(e.groundDistance)) mask |= LAND;
        if ((e.kind == NAVAL || e.kind == HOVER) && std::isfinite(e.classDistance)) mask |= e.kind;
    }
    return mask;
}

// Seconds until the claimant's constructor of its own class stands at the spot.
inline float Arrive(const Entrant& e, float fps) {
    if (!std::isfinite(e.classDistance) || !(e.classSpeed > 0.f)) return Unreachable;
    return float(std::max(0, e.readyFrame)) / fps + e.classDistance / e.classSpeed;
}
inline float Combat(const Entrant& e, float fps) {
    if (!std::isfinite(e.combatDistance) || !(e.combatSpeed > 0.f)) return Unreachable;
    return float(std::max(0, e.combatReadyFrame)) / fps + e.combatDistance / e.combatSpeed;
}

// The four rules in order (home, sea, land with the lane refinement, race),
// then the post-window openings. Ties go to the lower team id, as D-322.
inline Result Resolve(const Inputs& in) {
    Result out;
    out.mask = Mask(in.entrants);
    out.enemySeconds = in.enemySeconds;
    const float fps = in.framesPerSecond > 0.f ? in.framesPerSecond : 30.f;
    const auto nearest = [&](auto distance, auto eligible) {
        int owner = -1; float best = Unreachable;
        for (const auto& e : in.entrants) {
            if (!eligible(e)) continue;
            const float d = distance(e);
            if (mex_navigation::Better(d, e.team, best, owner)) { best = d; owner = e.team; }
        }
        return owner;
    };
    const auto ground = [](const Entrant& e) { return e.groundDistance; };
    const auto cls = [](const Entrant& e) { return e.classDistance; };
    // 1. Home: the land spots around a commander belong to that seat, SEA included.
    if (in.window && (out.mask & LAND)) {
        const int home = nearest(ground, [&](const Entrant& e) {
            return std::isfinite(e.groundDistance) && e.startDistance2D <= in.homeRadius; });
        if (home >= 0) { out.rule = Rule::HOME; out.owner = home; return out; }
    }
    // 3. Sea: water a SEA claimant's ships reach is that claimant's by sailing distance.
    if (in.theatreWindow && (out.mask & NAVAL)) {
        const int sea = nearest(cls, [](const Entrant& e) { return e.kind == NAVAL; });
        if (sea >= 0) { out.rule = Rule::SEA; out.owner = sea; return out; }
    }
    // 2. Land: a lane cluster goes to the lane's members; the rest by walk.
    // After the land window: the horizontal start split (D-072).
    if (out.mask & LAND) {
        if (!in.window) {
            out.rule = Rule::OPEN_LAND;
            out.owner = nearest([](const Entrant& e) { return e.startDistance2D; }, [](const Entrant&) { return true; });
            return out;
        }
        // D-357: a published FRONT corridor is that seat's lane: its clusters go to
        // it (a lane-spot claimant) ahead of the ground partition; past its
        // midpoint they are enemy ground during the window, as the partition's.
        if (in.corridor >= 0) {
            bool member = false;
            for (const auto& c : in.entrants) if (c.team == in.corridor && c.laneSpots) member = true;
            if (member && in.corridorForward) { out.rule = Rule::FORWARD; out.owner = -1; return out; }
            if (member) { out.rule = Rule::LANE; out.owner = in.corridor; return out; }
        }
        if (in.lane >= 0 && in.forward) { out.rule = Rule::FORWARD; out.owner = -1; return out; }
        if (in.lane >= 0) {
            int member = nearest(ground, [&](const Entrant& e) { return e.lane == in.lane && e.laneSpots; });
            if (member < 0) member = nearest(ground, [&](const Entrant& e) { return e.lane == in.lane; });
            if (member >= 0) { out.rule = Rule::LANE; out.owner = member; return out; }
        }
        out.rule = Rule::LAND_WALK;
        out.owner = nearest(ground, [](const Entrant&) { return true; });
        return out;
    }
    // After the theatre window: the nearest claimant whose class stands there.
    if (!in.theatreWindow) {
        out.rule = Rule::OPEN_CLASS;
        out.owner = nearest(cls, [](const Entrant& e) { return e.kind != LAND; });
        if (out.owner < 0) out.rule = Rule::NONE;
        return out;
    }
    // 4. Race among the classes that reach it (hover, air; naval without a SEA
    // claimant cannot occur: the NAVAL bit is defined by a naval claimant's reach).
    int owner = -1; float bestArrive = Unreachable;
    bool anyGround = false;
    for (const auto& e : in.entrants) {
        if (e.kind == LAND) continue;
        const float arrive = Arrive(e, fps);
        if (!std::isfinite(arrive)) continue;
        if (e.kind != AIR) anyGround = true;
        const float secure = arrive + std::max(0.f, e.secureSeconds);
        if (secure <= in.enemySeconds && mex_navigation::Better(arrive, e.team, bestArrive, owner)) {
            bestArrive = arrive; owner = e.team; out.secureSeconds = secure;
        }
    }
    if (owner >= 0) { out.rule = Rule::RACE_SECURED; out.owner = owner; out.arriveSeconds = bestArrive; return out; }
    // Contested: whoever's combat class is there before the enemy holds it; AIR never does.
    int holder = -1; float bestCombat = Unreachable, holderArrive = Unreachable;
    for (const auto& e : in.entrants) {
        if (e.kind == LAND || e.kind == AIR) continue;
        const float combat = Combat(e, fps);
        if (!std::isfinite(combat) || combat >= in.enemyCombatSeconds) continue;
        const float arrive = Arrive(e, fps);
        const bool better = combat < bestCombat
            || (combat == bestCombat && (arrive < holderArrive || (arrive == holderArrive && e.team < holder)));
        if (better) { bestCombat = combat; holder = e.team; holderArrive = arrive; }
    }
    if (holder >= 0) {
        out.rule = Rule::RACE_CONTESTED; out.owner = holder; out.arriveSeconds = holderArrive;
        out.secureSeconds = bestCombat;
        return out;
    }
    // Only aircraft reach it: the sole entrant owns it; its own rule weighs live threat.
    if (!anyGround) {
        const int air = nearest([&](const Entrant& e) { return Arrive(e, fps); },
                                [](const Entrant& e) { return e.kind == AIR; });
        if (air >= 0) {
            out.rule = Rule::RACE_AIR; out.owner = air;
            for (const auto& e : in.entrants) if (e.team == air) out.arriveSeconds = Arrive(e, fps);
            return out;
        }
    }
    out.rule = Rule::NONE; out.owner = -1;
    return out;
}

// Income per second of waiting: the meta's claim order (proposal 3.2.2).
inline float Value(float income, float readyFrame, float distance, float speed, float mexBuildSeconds, float fps) {
    if (!(income > 0.f) || !std::isfinite(distance) || !(speed > 0.f)) return 0.f;
    const float seconds = std::max(0.f, readyFrame) / (fps > 0.f ? fps : 30.f) + distance / speed + std::max(0.f, mexBuildSeconds);
    return seconds > 0.f ? income / seconds : income;
}
// Several SEA seats on one body (Glacial Gap): a plain sailing-distance
// Voronoi hands the most central seat the whole sea (44 / 4 / 0 in the first
// played build), so sea spots are dealt out in rounds: each naval claimant, in
// team-id order, takes its nearest unassigned spot until none remain. Shares
// differ by at most one and every seat's share is the water nearest its yard.
// candidates[i]: the naval claimants that reach spot i as (team, sailing
// distance), any order. Returns the owner per spot (-1 when nobody reaches it).
inline std::vector<int> BalanceSea(const std::vector<std::vector<std::pair<int, float>>>& candidates) {
    std::vector<int> owner(candidates.size(), -1);
    std::vector<int> teams;
    for (const auto& c : candidates) for (const auto& [team, d] : c) if (std::isfinite(d)) teams.push_back(team);
    std::sort(teams.begin(), teams.end());
    teams.erase(std::unique(teams.begin(), teams.end()), teams.end());
    std::size_t assigned = 0;
    while (assigned < candidates.size()) {
        bool progress = false;
        for (int team : teams) {
            int best = -1; float bestDistance = Unreachable;
            for (std::size_t i = 0; i < candidates.size(); ++i) {
                if (owner[i] >= 0) continue;
                for (const auto& [t, d] : candidates[i]) {
                    if (t == team && std::isfinite(d) && (d < bestDistance || (d == bestDistance && int(i) < best))) { bestDistance = d; best = int(i); }
                }
            }
            if (best >= 0) { owner[best] = team; ++assigned; progress = true; }
        }
        if (!progress) break;
    }
    return owner;
}
}  // namespace circuit::mex_territory

namespace circuit::mex_lanes {
using mex_navigation::Unreachable;

struct Settings {
    float mergeRadius = 450.f;   // a route joins a lane when this close to its spine
    float mergeShare = 0.6f;     // for this share of its cells
    float bandRadius = 1200.f;   // a cluster this close to a spine is a lane cluster
};
struct Lane {
    std::vector<int> spine;      // cells from the founding start to the enemy source
    std::vector<int> members;    // indices into the start list
    int midpoint = -1;           // first spine cell where our distance exceeds the enemy's
    int choke = -1;              // narrowest spine cell in the middle third
    float width = Unreachable;   // clearance at the choke, elmos
};
struct Partition {
    std::vector<Lane> lanes;
    std::vector<int> startLane;      // per start: its lane, -1 when it has no route
    std::vector<int> clusterLane;    // per cluster: its lane, -1 when none
    std::vector<char> clusterForward;// per cluster: past its lane's midpoint
};

// Distance to the nearest impassable or border cell, four-neighbour BFS in
// cells; O(G). The lane solver's Clearance does the same over its own grid.
template<class Passable>
std::vector<int> Clearance(int width, int height, Passable passable) {
    std::vector<int> out(std::size_t(width) * height, -1);
    std::queue<int> pending;
    for (int z = 0; z < height; ++z) for (int x = 0; x < width; ++x) {
        const int i = z * width + x;
        if (!passable(i)) { out[i] = 0; pending.push(i); continue; }
        if (x == 0 || z == 0 || x == width - 1 || z == height - 1) { out[i] = 1; pending.push(i); }
    }
    while (!pending.empty()) {
        const int i = pending.front(); pending.pop();
        const int x = i % width, z = i / width;
        const int next[4] = { x > 0 ? i - 1 : -1, x < width - 1 ? i + 1 : -1, z > 0 ? i - width : -1, z < height - 1 ? i + width : -1 };
        for (int n : next) if (n >= 0 && out[n] < 0) { out[n] = out[i] + 1; pending.push(n); }
    }
    return out;
}

// Steepest descent of the enemy field from a start cell to an enemy source
// (a cell at distance 0). Ties go to the lower cell index, so the route is a
// function of the grid alone. Empty when the start cannot reach the enemy.
template<class Passable>
std::vector<int> Route(int width, int height, int start, const std::vector<float>& enemy, Passable passable) {
    std::vector<int> route;
    if (start < 0 || start >= width * height || !std::isfinite(enemy[start])) return route;
    int cell = start;
    route.push_back(cell);
    const std::size_t limit = std::size_t(width) * height;
    while (enemy[cell] > 0.f && route.size() < limit) {
        const int x = cell % width, z = cell / width;
        int best = -1; float bestValue = enemy[cell];
        for (int dz = -1; dz <= 1; ++dz) for (int dx = -1; dx <= 1; ++dx) {
            const int nx = x + dx, nz = z + dz;
            if ((!dx && !dz) || nx < 0 || nz < 0 || nx >= width || nz >= height) continue;
            const int next = nz * width + nx;
            if (!passable(next) || (dx && dz && (!passable(z*width+nx) || !passable(nz*width+x)))) continue;
            if (enemy[next] < bestValue || (enemy[next] == bestValue && best >= 0 && next < best)) { bestValue = enemy[next]; best = next; }
        }
        if (best < 0) break;
        cell = best;
        route.push_back(cell);
    }
    return route;
}

// The partition: one route per start in the given (team-id) order, merged by
// proximity, each lane with its midpoint and choke, each cluster assigned whole.
// enemy/ours: multi-source fields from the enemy sources and from every start.
template<class Passable>
Partition Build(int width, int height, float pitch, const std::vector<int>& starts,
        const std::vector<float>& enemy, const std::vector<float>& ours, Passable passable,
        const std::vector<std::pair<float, float>>& clusterCentres, const std::vector<int>& clusterCells,
        const Settings& settings) {
    Partition out;
    out.startLane.assign(starts.size(), -1);
    const auto centre = [&](int cell) {
        return std::pair<float, float>{ (float(cell % width) + 0.5f) * pitch, (float(cell / width) + 0.5f) * pitch }; };
    const auto distance2D = [](std::pair<float, float> a, std::pair<float, float> b) {
        return std::sqrt((a.first - b.first) * (a.first - b.first) + (a.second - b.second) * (a.second - b.second)); };
    const auto nearSpine = [&](const Lane& lane, std::pair<float, float> p, float radius) {
        for (int c : lane.spine) if (distance2D(centre(c), p) <= radius) return true;
        return false; };
    for (std::size_t s = 0; s < starts.size(); ++s) {
        const auto route = Route(width, height, starts[s], enemy, passable);
        if (route.size() < 2) continue;
        int joined = -1;
        for (std::size_t l = 0; l < out.lanes.size() && joined < 0; ++l) {
            std::size_t close = 0;  // not "near": a Windows macro in the engine headers
            for (int c : route) if (nearSpine(out.lanes[l], centre(c), settings.mergeRadius)) ++close;
            if (float(close) >= settings.mergeShare * float(route.size())) joined = int(l);
        }
        if (joined < 0) { Lane lane; lane.spine = route; out.lanes.push_back(std::move(lane)); joined = int(out.lanes.size()) - 1; }
        out.lanes[joined].members.push_back(int(s));
        out.startLane[s] = joined;
    }
    const auto clearance = Clearance(width, height, passable);
    for (auto& lane : out.lanes) {
        for (std::size_t i = 0; i < lane.spine.size(); ++i) {
            const int c = lane.spine[i];
            if (std::isfinite(ours[c]) && std::isfinite(enemy[c]) && ours[c] >= enemy[c]) { lane.midpoint = c; break; }
        }
        if (lane.midpoint < 0) lane.midpoint = lane.spine.back();
        const std::size_t n = lane.spine.size();
        int best = -1;
        for (std::size_t i = n / 3; i <= 2 * n / 3 && i < n; ++i) {
            const int c = lane.spine[i];
            if (best < 0 || clearance[c] < clearance[best]) best = c;
        }
        lane.choke = best < 0 ? lane.midpoint : best;
        lane.width = lane.choke >= 0 ? float(clearance[lane.choke]) * pitch : Unreachable;
    }
    out.clusterLane.assign(clusterCentres.size(), -1);
    out.clusterForward.assign(clusterCentres.size(), 0);
    for (std::size_t c = 0; c < clusterCentres.size(); ++c) {
        int best = -1; float bestDistance = settings.bandRadius;
        for (std::size_t l = 0; l < out.lanes.size(); ++l) {
            for (int cell : out.lanes[l].spine) {
                const float d = distance2D(centre(cell), clusterCentres[c]);
                if (d < bestDistance || (d == bestDistance && best >= 0 && int(l) < best)) { bestDistance = d; best = int(l); }
            }
        }
        out.clusterLane[c] = best;
        if (best < 0) continue;
        const int cell = c < clusterCells.size() ? clusterCells[c] : -1;
        if (cell >= 0 && cell < width * height && std::isfinite(ours[cell]) && std::isfinite(enemy[cell]) && ours[cell] > enemy[cell])
            out.clusterForward[c] = 1;
    }
    return out;
}
}  // namespace circuit::mex_lanes
