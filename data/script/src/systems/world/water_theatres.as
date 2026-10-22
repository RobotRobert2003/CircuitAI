// Read-only water theatre survey. No reservations, tasks or unit-cap changes.
// Reuses CBattleAnalysis' four-connected, conservative 8-deep water components.
#include "../../helpers/units/unit_helpers.as"

namespace WaterTheatres {
    class Body {
        int id = -1;
        array<int> cells;
        array<int> shore;
        AIFloat3 centre;
        float area = 0.0f;
        bool pond = false;
        bool shared = false;
        bool friendly = false;
        AIFloat3 yard(-1.0f, 0.0f, -1.0f);
        AIFloat3 tidal(-1.0f, 0.0f, -1.0f);
        AIFloat3 plane(-1.0f, 0.0f, -1.0f);
        int facing = 0;
    }
    array<Body@> bodies;
    array<int> grid;
    int width = 0, height = 0;
    const int CELL = 64; // matches the existing native analysis grid
    float pondShare = 0.025f;
    float territoryRatio = 0.8f;
    float minTidal = 10.0f;
    float siteRadius = 6400.0f;
    int minCells = 16;

    AIFloat3 Pos(int c) { return AIFloat3(float(c % width) * CELL + CELL * 0.5f, 0.0f, float(c / width) * CELL + CELL * 0.5f); }
    int At(int x, int z) {
        if (x < 0 || z < 0 || x >= width || z >= height) return -1;
        return grid[z * width + x];
    }
    float Distance(const AIFloat3& in p, const array<AIFloat3>& in starts) {
        float d = 1e20f;
        for (uint i = 0; i < starts.length(); ++i) {
            const float v = p.distance2D(starts[i]);
            if (v < d) d = v;
        }
        return d;
    }
    void Survey() {
        if (width > 0) return;
        pondShare = aiSetupMgr.ConfigFloat("lanes/pond_max_map_share", pondShare);
        territoryRatio = aiSetupMgr.ConfigFloat("lanes/water_territory_ratio", territoryRatio);
        minTidal = aiSetupMgr.ConfigFloat("lanes/pond_min_tidal", minTidal);
        siteRadius = aiSetupMgr.ConfigFloat("lanes/water_site_radius", siteRadius);
        minCells = aiSetupMgr.ConfigInt("lanes/water_min_cells", minCells);
        pondShare = AiMax(0.0f, AiMin(0.25f, pondShare));
        territoryRatio = AiMax(0.1f, AiMin(0.99f, territoryRatio));
        minCells = AiMax(1, minCells);
        width = AiMax(1, AiTerrainWidth() / CELL);
        height = AiMax(1, AiTerrainHeight() / CELL);
        grid.resize(width * height);
        for (int c = 0; c < width * height; ++c) {
            const int id = aiBattle.WaterBody(Pos(c), false);
            grid[c] = id;
            if (id < 0) continue;
            while (int(bodies.length()) <= id) { Body@ b = Body(); b.id = int(bodies.length()); bodies.insertLast(b); }
            bodies[id].cells.insertLast(c);
            bodies[id].centre = bodies[id].centre + Pos(c);
        }
        for (uint i = 0; i < bodies.length(); ++i) {
            Body@ b = bodies[i];
            if (b.cells.length() == 0) continue;
            b.centre = b.centre / float(b.cells.length());
            float nearest = 1e20f;
            AIFloat3 label = b.centre;
            for (uint j = 0; j < b.cells.length(); ++j) {
                const int c = b.cells[j], x = c % width, z = c / width;
                const float d = Pos(c).distance2D(b.centre);
                if (d < nearest) { nearest = d; label = Pos(c); }
                if (At(x-1,z) != b.id || At(x+1,z) != b.id || At(x,z-1) != b.id || At(x,z+1) != b.id) b.shore.insertLast(c);
            }
            b.centre = label; // actual water, even for a crescent-shaped sea
            b.area = float(b.cells.length()) * CELL * CELL;
            b.pond = float(b.cells.length()) <= float(width * height) * pondShare;
        }
    }
    // A clear 320-elmo exit corridor in the same navigable body. Diagnostic only.
    bool ExitClear(const AIFloat3& in p, int body, int facing) {
        int dx = 0, dz = 0;
        if (facing == 0) dz = 1;
        else if (facing == 1) dx = 1;
        else if (facing == 2) dz = -1;
        else dx = -1;
        const int x = int(p.x) / CELL, z = int(p.z) / CELL;
        for (int a = 0; a <= 5; ++a)
            for (int s = -1; s <= 1; ++s)
                if (At(x + dx*a - dz*s, z + dz*a + dx*s) != body) return false;
        return true;
    }
    AIFloat3 Site(Body@ b, const CCircuitDef@ def, bool naval, const array<AIFloat3>& in ours,
                  const array<AIFloat3>& in theirs, int& out facing) {
        facing = 0;
        if (def is null || ours.length() == 0 || theirs.length() == 0) return AIFloat3(-1.0f,0.0f,-1.0f);
        // Rank cheap tests first; at most 32 candidates reach the native footprint test.
        array<int> candidates;
        array<float> scores;
        for (uint j = 0; j < b.cells.length(); ++j) {
            const int c = b.cells[j], x = c % width, z = c / width;
            if ((x % 2) != 0 || (z % 2) != 0) continue;
            const AIFloat3 p = Pos(c);
            const float own = Distance(p, ours), enemy = Distance(p, theirs);
            if (own > siteRadius || own >= enemy * territoryRatio) continue;
            if (naval && (At(x-1,z) != b.id || At(x+1,z) != b.id || At(x,z-1) != b.id || At(x,z+1) != b.id)) continue;
            const float score = own + AiMax(0.0f, aiBattle.SurfThreat(p)) * 100.0f;
            uint k = 0;
            while (k < scores.length() && scores[k] <= score) ++k;
            if (k >= 32) continue;
            scores.insertAt(k, score); candidates.insertAt(k, c);
            if (scores.length() > 32) { scores.removeLast(); candidates.removeLast(); }
        }
        for (uint j = 0; j < candidates.length(); ++j) {
            const AIFloat3 p = Pos(candidates[j]);
            for (int f = 0; f < 4; ++f) {
                if (naval && !ExitClear(p, b.id, f)) continue;
                // Zero-sized sampling rectangle = one existing terrain-manager build test.
                // BuildableFraction reads terrain, blocking and engine feasibility; it reserves nothing.
                if (aiTerrainMgr.BuildableFraction(def, p, 0.0f, 0.0f, f) < 1.0f) continue;
                facing = f;
                return p;
            }
        }
        return AIFloat3(-1.0f,0.0f,-1.0f);
    }
    void Analyse(const array<AIFloat3>& in ours, const array<AIFloat3>& in theirs) {
        Survey();
        const string side = Global::AISettings::Side;
        const CCircuitDef@ yardDef = ai.GetCircuitDef(UnitHelpers::GetT1ShipyardForSide(side));
        const CCircuitDef@ tideDef = ai.GetCircuitDef(UnitHelpers::GetTidalNameForSide(side));
        const CCircuitDef@ planeDef = ai.GetCircuitDef(UnitHelpers::GetSeaplanePlatformNameForSide(side));
        int ponds = 0, seas = 0, yards = 0;
        for (uint i = 0; i < bodies.length(); ++i) {
            Body@ b = bodies[i];
            if (int(b.cells.length()) < minCells) continue;
            int own = 0, enemy = 0;
            if (ours.length() > 0 && theirs.length() > 0) {
                for (uint j = 0; j < b.shore.length(); ++j) {
                    const AIFloat3 p = Pos(b.shore[j]);
                    const float a = Distance(p, ours), e = Distance(p, theirs);
                    if (a < e * territoryRatio) ++own;
                    if (e < a * territoryRatio) ++enemy;
                }
            }
            const int shoreGate = AiMax(4, int(b.shore.length() / 20));
            b.shared = own >= shoreGate && enemy >= shoreGate;
            b.friendly = own >= shoreGate && enemy == 0;
            b.yard = AIFloat3(-1.0f,0.0f,-1.0f);
            b.tidal = b.yard; b.plane = b.yard;
            int facing = 0;
            // Size alone never makes a sea a useful naval theatre.
            if (!b.pond && b.shared) { b.yard = Site(b, yardDef, true, ours, theirs, facing); b.facing = facing; }
            if (b.pond && b.friendly) {
                if (ai.GetTidalStrength() >= minTidal && ai.GetTidalStrength() > 0.0f) b.tidal = Site(b, tideDef, false, ours, theirs, facing);
                b.plane = Site(b, planeDef, false, ours, theirs, facing);
            }
            if (b.pond) ++ponds; else ++seas;
            if (b.yard.x >= 0.0f) ++yards;
            GenericHelpers::LogUtil("[Theatres] body " + b.id + " " + (b.pond ? "POND" : "SEA")
                + " area " + int(b.area) + " shores " + own + "/" + enemy
                + " shared=" + b.shared + " friendly=" + b.friendly + " yard=" + (b.yard.x >= 0.0f)
                + " tidal=" + (b.tidal.x >= 0.0f) + " seaplane=" + (b.plane.x >= 0.0f), 1);
        }
        GenericHelpers::LogUtil("[Theatres] survey: " + ponds + " ponds, " + seas + " seas; " + yards
            + " shipyard candidates; tidal " + ai.GetTidalStrength() + " E/s; advisory only", 1);
    }
}
