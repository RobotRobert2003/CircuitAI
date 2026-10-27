// Pure lolcannon rules (systems/construction/lolcannon.as): no engine callbacks,
// scans or orders.
namespace LolCannonMath {
    // Radius of site ring k round an enemy start: just inside the cannon's range,
    // range - marginMin first, stepping inwards; -1 past range - marginMax.
    float RingRadius(float range, float marginMin, float marginMax, float step, int k)
    {
        if (k < 0 || range <= 0.0f) return -1.0f;
        const float r = range - marginMin - float(k) * (step > 1.0f ? step : 1.0f);
        return (r < range - marginMax || r <= 0.0f) ? -1.0f : r;
    }
    // Metal gate of cannon k (0 = the first): the listed gates, then one more cannon
    // every extraStep metal/s past the last of them (owner 2026-10-27); -1 none.
    float GateFor(int built, const array<float>@ metalGates, float extraStep)
    {
        if (metalGates is null || built < 0 || metalGates.length() == 0) return -1.0f;
        const int n = int(metalGates.length());
        if (built < n) return metalGates[built];
        return (extraStep > 0.0f) ? metalGates[n - 1] + float(built - n + 1) * extraStep : -1.0f;
    }
    // Cannon k (0 = the first) may start: its metal gate and the energy gate.
    bool GateOpen(int built, float metal, float energy, const array<float>@ metalGates, float minEnergy, float extraStep)
    {
        const float gate = GateFor(built, metalGates, extraStep);
        return gate >= 0.0f && metal >= gate && energy >= minEnergy;
    }
    // How far the site rings move out from the enemy start at back-off level `level`.
    float BackShift(int level, float step)
    {
        return (level > 0 && step > 0.0f) ? float(level) * step : 0.0f;
    }
    // Back-off level after `fails` failures, one level per `per`, at most `maxLevel`.
    int BackLevel(int fails, int per, int maxLevel)
    {
        if (fails <= 0 || per <= 0 || maxLevel <= 0) return 0;
        const int l = fails / per;
        return l > maxLevel ? maxLevel : l;
    }
    // Native facing (SOUTH 0 +z, EAST 1 +x, NORTH 2 -z, WEST 3 -x) nearest a direction.
    int Facing(float dx, float dz)
    {
        if ((dx < 0.0f ? -dx : dx) > (dz < 0.0f ? -dz : dz)) return (dx > 0.0f) ? 1 : 3;
        return (dz > 0.0f) ? 0 : 2;
    }
    // Grid pitch of a footprint given in 16-elmo cells (CCircuitDef::GetFootprintX,
    // Layout::Across/Along): its full extent, at least one cell.
    float Pitch(int cells)
    {
        return float(cells < 1 ? 1 : cells) * 16.0f;
    }
    // Offset of column/row i of n, centred on 0.
    float Offset(int i, int n, float pitch)
    {
        return (float(i) - float(n - 1) * 0.5f) * pitch;
    }
    // Rows of a strip `cols` wide holding `count`.
    int Rows(int count, int cols)
    {
        if (count <= 0) return 0;
        if (cols < 1) cols = 1;
        return (count + cols - 1) / cols;
    }
    // Row (or column) i of n in centre-out order: n 6 gives 2, 3, 1, 4, 0, 5. Spare
    // slots round a block are tried after the ones nearest the cannon's middle.
    int CentreOut(int i, int n)
    {
        if (n <= 0 || i < 0 || i >= n) return -1;
        const int mid = (n - 1) / 2;
        return (i % 2 == 0) ? mid - i / 2 : mid + (i + 1) / 2;
    }
    // Crew kind a free air constructor joins: 0 starter, 1 air crew, 2 storage crew,
    // -1 none. T2 constructors fill the starter, then the storage crew, then the
    // air crew; a T1 one only the air crew.
    int CrewFor(bool t2, int starter, int store, int storeWanted, int air, int airWanted)
    {
        if (t2 && starter < 1) return 0;
        if (t2 && store < storeWanted) return 2;
        if (air < airWanted) return 1;
        return -1;
    }
}
