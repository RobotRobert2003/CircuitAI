// D-345: SEA lanes for the widget. Calculation only: no unit, task or route
// owner reads these lanes yet. The owner wants to see them before they are
// used for route planning.
#include "../presentation/widget_link.as"
#include "../world/lanes.as"

/******************************************************************************

SEA LANES

One lane per finished naval factory (T1/T2 shipyard, underwater gantry) this
SEA AI owns:
    factory exit mouth -> closest last known enemy on the same water body
    (optional) -> final destination
The final destination is the water next to the nearest enemy start on the same
water body (kind 0). When no enemy start touches this sea it is a landing
beach near the nearest enemy start, for hovers and amphibious units (kind 1):
the water edge, then the land cell.

Published as the widget state key "sealanes" (WidgetLink::SetState, the D-300
state file LuaUI/Config/BARb/state/team<N>.txt, same as "layout"):
    barb|sealanes|<team>|<allyTeam>|1;<frame>[;<lane>]...
    <lane> = <factoryId>,<kind>,<contact point index or -1>,x,z,x,z,...
The widget draws each lane in the owning team's colour.

Cost: one factory per LaneTickSeconds, each refreshed every
LaneRefreshSeconds or sooner when its nearest contact moves LaneContactMove.
One refresh = one O(contacts) pass plus at most two native naval terrain
routes (GetTerrainRoute, the same cached Dijkstra SEA already uses). Final
destinations are searched once per (water body, enemy start) and cached:
at most StartWaterRings x 16 or BeachRings x 24 height samples. The payload is
rebuilt only when a lane changes; the native store skips unchanged values.

******************************************************************************/
namespace SeaLanes {
    bool Enabled = true;
    int LaneTickSeconds = 1;
    int LaneRefreshSeconds = 20;
    float LaneContactMove = 400.0f;
    int StartWaterRings = 12;        // x 128 elmos from an enemy start
    int BeachRings = 21;             // x 192 elmos from an enemy start
    float BeachMaxGrade = 0.3f;

    class Lane {
        int factory = -1, kind = 0, contact = -1, frame = -1;
        AIFloat3 contactPos = AIFloat3(-1, 0, -1);
        array<AIFloat3> points;
    }
    array<Lane@> lanes;
    dictionary finals;               // "<body>:<x>:<z>" -> "kind,x,z,lx,lz"
    int cursor = 0, nextTick = 0;
    string published;

    bool NavalFactory(CCircuitUnit@ u) {
        if (u is null || u.circuitDef is null || u.GetBuildProgress() < 1) return false;
        const string name = u.circuitDef.GetName();
        return UnitHelpers::IsT1Shipyard(name) || UnitHelpers::IsT2Shipyard(name) || UnitHelpers::IsWaterGantry(name);
    }
    // D-350: the factory opening, the middle of its front edge (the footprint
    // depth along the facing is X for east/west-facing buildings).
    float HalfDepth(CCircuitUnit@ u, int f) {
        return float((f == 1 || f == 3) ? u.circuitDef.GetFootprintX() : u.circuitDef.GetFootprintZ()) * 4.0f;
    }
    AIFloat3 Opening(CCircuitUnit@ u) {
        const int f = aiTerrainMgr.GetBuildingFacing(u);
        return LayoutHelpers::Offset(u.GetPos(ai.frame), f, 0, HalfDepth(u, f) + 8.0f);
    }
    AIFloat3 Mouth(CCircuitUnit@ u) {
        const AIFloat3 p = u.GetPos(ai.frame);
        const int f = aiTerrainMgr.GetBuildingFacing(u);
        const float half = HalfDepth(u, f);
        for (float along = half + 192.0f; along >= 32.0f; along -= 64.0f) {
            const AIFloat3 q = LayoutHelpers::Offset(p, f, 0, along);
            if (aiBattle.Height(q) < -8.0f) return q;
        }
        return p;
    }
    // Cached final destination for one water body and one enemy start.
    // Returns kind (0 sea, 1 beach, -1 none); `water` is the sea end, `land`
    // the beach's land cell (kind 1 only).
    int Final(int body, const AIFloat3 &in start, AIFloat3 &out water, AIFloat3 &out land) {
        const string key = "" + body + ":" + int(start.x) + ":" + int(start.z);
        string cached;
        if (!finals.get(key, cached)) {
            cached = "-1,0,0,0,0";
            bool found = false;
            for (int r = 0; r <= StartWaterRings && !found; ++r) {
                for (int k = 0; k < 16 && !found; ++k) {
                    const float a = float(k) * 6.2831853f / 16.0f, d = float(r) * 128.0f;
                    const AIFloat3 q(start.x + cos(a) * d, 0, start.z + sin(a) * d);
                    if (q.x < 0 || q.z < 0 || q.x >= AiTerrainWidth() || q.z >= AiTerrainHeight()) continue;
                    if (aiBattle.Height(q) < -8.0f && aiBattle.WaterBody(q, false) == body) {
                        cached = "0," + int(q.x) + "," + int(q.z) + ",0,0"; found = true;
                    }
                }
            }
            for (int r = 1; r <= BeachRings && !found; ++r) {
                for (int k = 0; k < 24 && !found; ++k) {
                    const float a = float(k) * 6.2831853f / 24.0f, d = float(r) * 192.0f;
                    const AIFloat3 dir(cos(a), 0, sin(a));
                    const AIFloat3 p(start.x + dir.x * d, 0, start.z + dir.z * d);
                    const AIFloat3 q = p + dir * 96.0f;
                    if (q.x < 0 || q.z < 0 || q.x >= AiTerrainWidth() || q.z >= AiTerrainHeight()) continue;
                    const float hp = aiBattle.Height(p), hq = aiBattle.Height(q);
                    if (hp < 0 || hq >= -8.0f || aiBattle.WaterBody(q, false) != body) continue;
                    if ((hp - hq) / 96.0f > BeachMaxGrade) continue;
                    cached = "1," + int(q.x) + "," + int(q.z) + "," + int(p.x) + "," + int(p.z); found = true;
                }
            }
            finals.set(key, cached);
        }
        array<string>@ f = cached.split(",");
        water = AIFloat3(parseFloat(f[1]), 0, parseFloat(f[2]));
        land = AIFloat3(parseFloat(f[3]), 0, parseFloat(f[4]));
        return int(parseInt(f[0]));
    }
    // Drop collinear interior points of the 64-elmo grid route.
    void Append(array<AIFloat3> &inout dest, const array<AIFloat3>@ route) {
        if (route is null) return;
        for (uint i = 0; i < route.length(); ++i) {
            const AIFloat3 p = route[i];
            const uint n = dest.length();
            if (n >= 2) {
                const AIFloat3 a = dest[n - 2], b = dest[n - 1];
                const float cross = (b.x - a.x) * (p.z - b.z) - (b.z - a.z) * (p.x - b.x);
                if (abs(cross) < 1.0f) { dest[n - 1] = p; continue; }
            }
            if (n >= 1 && MapHelpers::SqDist(dest[n - 1], p) < 1.0f) continue;
            dest.insertLast(p);
        }
    }
    void Compute(Lane@ lane, CCircuitUnit@ factory) {
        const AIFloat3 mouth = Mouth(factory);
        const int body = aiBattle.WaterBody(mouth, false);
        lane.frame = ai.frame; lane.points.resize(0); lane.contact = -1; lane.kind = -1;
        if (body < 0) return;
        // Closest last known enemy on this water body (live or remembered).
        float best = 1e30f; AIFloat3 contact(-1, 0, -1);
        const int contacts = aiBattle.GetSeaForceCount();
        for (int i = 0; i < contacts; ++i) {
            if ((aiBattle.GetSeaForceFlags(i) & 1) != 0 || aiBattle.GetSeaForceBody(i) != body) continue;
            const AIFloat3 p = aiBattle.GetSeaForcePos(i);
            const float d = MapHelpers::SqDist(mouth, p);
            if (d < best) { best = d; contact = p; }
        }
        // Final: the nearest enemy start with water on this sea, else a beach.
        array<AIFloat3> starts = Lanes::EnemyStarts();
        int kind = -1; float bestStart = 1e30f; AIFloat3 water, land;
        for (int pass = 0; pass < 2 && kind < 0; ++pass) {
            for (uint i = 0; i < starts.length(); ++i) {
                AIFloat3 w, l;
                const int k = Final(body, starts[i], w, l);
                if (k != pass) continue;
                const float d = MapHelpers::SqDist(mouth, w);
                if (d < bestStart) { bestStart = d; kind = k; water = w; land = l; }
            }
        }
        // Drawn from the factory opening; routed from the first open water
        // beyond it (the route search needs a navigable start).
        lane.points.insertLast(Opening(factory));
        if (MapHelpers::SqDist(lane.points[0], mouth) > 16.0f * 16.0f) lane.points.insertLast(mouth);
        AIFloat3 from = mouth;
        if (contact.x >= 0) {
            Append(lane.points, aiBattle.GetTerrainRoute(from, contact, 5, 10, 1, 3, 1000000));
            lane.contact = int(lane.points.length()) - 1;
            from = contact;
        }
        lane.contactPos = contact;
        if (kind >= 0) {
            Append(lane.points, aiBattle.GetTerrainRoute(from, water, 5, 10, 1, 3, 1000000));
            if (kind == 1) lane.points.insertLast(land);
        }
        lane.kind = kind;
    }
    string Encode() {
        string text = "1;" + ai.frame;
        for (uint i = 0; i < lanes.length(); ++i) {
            Lane@ l = lanes[i];
            if (l.points.length() < 2) continue;
            text += ";" + l.factory + "," + l.kind + "," + l.contact;
            for (uint j = 0; j < l.points.length(); ++j) text += "," + int(l.points[j].x) + "," + int(l.points[j].z);
        }
        return text;
    }
    void Tick() {
        if (!Enabled || ai.frame < nextTick) return;
        nextTick = ai.frame + LaneTickSeconds * SECOND;
        // Factory set: own finished naval factories (SeaEconomy keeps the ids).
        array<int> ids;
        for (uint i = 0; i < SeaEconomy::productionFactories.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(SeaEconomy::productionFactories[i]);
            if (NavalFactory(u)) ids.insertLast(u.id);
        }
        bool changed = false;
        for (int i = int(lanes.length()) - 1; i >= 0; --i)
            if (ids.find(lanes[uint(i)].factory) < 0) { lanes.removeAt(uint(i)); changed = true; }
        for (uint i = 0; i < ids.length(); ++i) {
            bool known = false;
            for (uint j = 0; j < lanes.length(); ++j) if (lanes[j].factory == ids[i]) { known = true; break; }
            if (!known) { Lane l; l.factory = ids[i]; lanes.insertLast(l); }
        }
        if (lanes.length() > 0) {
            // One factory per tick, round-robin; only a due lane is recomputed.
            Lane@ l = lanes[uint(cursor++) % lanes.length()];
            CCircuitUnit@ u = ai.GetTeamUnit(l.factory);
            bool due = l.frame < 0 || ai.frame - l.frame >= LaneRefreshSeconds * SECOND;
            if (!due && u !is null) {
                // The nearest contact moved: refresh early (one O(contacts) pass).
                const AIFloat3 mouth = Mouth(u); const int body = aiBattle.WaterBody(mouth, false);
                float best = 1e30f; AIFloat3 contact(-1, 0, -1);
                const int contacts = aiBattle.GetSeaForceCount();
                for (int i = 0; i < contacts; ++i) {
                    if ((aiBattle.GetSeaForceFlags(i) & 1) != 0 || aiBattle.GetSeaForceBody(i) != body) continue;
                    const AIFloat3 p = aiBattle.GetSeaForcePos(i); const float d = MapHelpers::SqDist(mouth, p);
                    if (d < best) { best = d; contact = p; }
                }
                due = (contact.x < 0) != (l.contactPos.x < 0)
                    || (contact.x >= 0 && MapHelpers::SqDist(contact, l.contactPos) > LaneContactMove * LaneContactMove);
            }
            if (due && u !is null) { Compute(l, u); changed = true; }
        }
        if (!changed) return;
        const string text = Encode();
        if (text == published) return;
        published = text;
        WidgetLink::SetState("sealanes", WidgetLink::Line("sealanes", text));
    }
}
