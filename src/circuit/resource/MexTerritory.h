#pragma once

// D-352: mex ownership by theatre. Engine-free rules over numbers the manager
// extracts from its terrain fields, so every rule is unit-testable
// (tests/mex_territory_test.cpp) and the same on every allied AI.
//
//   mex_territory::Resolve  one spot: theatre mask, rule, owner, race times
//   (D-358) the lane partition is the field's corridor table
//                           (terrain/field/FieldCorridors.h); MexOwnership.cpp maps it
//
// Nothing here reads engine state, threat, time of day or per-AI data: the
// inputs are broadcast roster claims, start boxes and the terrain grid, so
// two allies with the same roster compute the same owner for every spot.
// See ../../../../rjm.bar.docs/projects/circuitai/mex-theatres-proposal.md.

#include "resource/MexNavigation.h"
#include "terrain/field/FieldCorridors.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
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

// D-387: capture for the owner. Ownership names who receives a spot's new
// extractor, not who may build it: any builder takes a spot another allied
// claimant owns, then gives the finished extractor to that claimant.
// owner: the spot's resolved owner team (-1 nobody, -2 an ally whose team is
// unknown). Returns the recipient, or -1 when the builder keeps the extractor
// (unowned, its own, an unknown ally, or capture switched off).
inline int CaptureFor(bool enabled, int owner, int ownTeam) {
    return (enabled && owner >= 0 && owner != ownTeam) ? owner : -1;
}
}  // namespace circuit::mex_territory

// D-358: the lane partition is the field's corridor table. A lane is one
// corridor of the claimants' ground class; a start belongs to the corridor
// owning its cell (nearest open cell within a few cells); a metal cluster is a
// lane cluster when its centre lies within bandRadius of that corridor's
// centre line, and forward when its progress from our side passes the
// midpoint. Deterministic: the table is a function of the map, the starts
// come in team-id order. O(starts + clusters x corridor vertices).
namespace circuit::mex_lanes {
using mex_navigation::Unreachable;
struct Lane {
    int corridor = -1;               // index into SModel::corridors
    std::vector<int> members;        // indices into the start list
    float width = Unreachable;       // the corridor's narrowest point, elmos
};
struct Partition {
    std::vector<Lane> lanes;
    std::vector<int> startLane;      // per start: its lane, -1 when none
    std::vector<int> clusterLane;    // per cluster: its lane, -1 when none
    std::vector<char> clusterForward;// per cluster: past the midpoint seen from our side
};
inline Partition FromCorridors(const field::SModel& m, int cls, int side,
        const std::vector<std::pair<float, float>>& starts,
        const std::vector<std::pair<float, float>>& clusterCentres, float bandRadius) {
    Partition out;
    out.startLane.assign(starts.size(), -1);
    std::vector<int> laneOf(m.corridors.size(), -1);
    for (std::size_t c = 0; c < m.corridors.size(); ++c) {
        if (m.corridors[c].cls != cls || m.corridors[c].specialist) continue;
        Lane lane; lane.corridor = int(c); lane.width = m.corridors[c].narrowest;
        laneOf[c] = int(out.lanes.size());
        out.lanes.push_back(std::move(lane));
    }
    for (std::size_t s = 0; s < starts.size(); ++s) {
        const int corridor = field::CorridorAt(m, cls, starts[s].first, starts[s].second, 6);
        if (corridor < 0 || laneOf[corridor] < 0) continue;
        out.startLane[s] = laneOf[corridor];
        out.lanes[laneOf[corridor]].members.push_back(int(s));
    }
    out.clusterLane.assign(clusterCentres.size(), -1);
    out.clusterForward.assign(clusterCentres.size(), 0);
    for (std::size_t k = 0; k < clusterCentres.size(); ++k) {
        const int corridor = field::CorridorAt(m, cls, clusterCentres[k].first, clusterCentres[k].second, 6);
        if (corridor < 0 || laneOf[corridor] < 0) continue;
        float distance = 0.f;
        const float progress = field::CorridorProgressFrom(m.corridors[corridor], side, clusterCentres[k].first, clusterCentres[k].second, &distance);
        if (distance > bandRadius) continue;
        out.clusterLane[k] = laneOf[corridor];
        out.clusterForward[k] = progress > 0.5f ? 1 : 0;
    }
    return out;
}
}  // namespace circuit::mex_lanes
