// D-199 frozen reference from 195f5e7a; do not update to match the optimized code.
bool CanPlace(const CCircuitDef@ def)
    {
        if (def is null) return false;
        if (!HasBox()) return true;
        // the native probe walks the whole zone; it was asked for every option
        // of every builder every second (played: a 15 s freeze at a converter)
        const string key = def.GetName();
        int64 at = -100000; canPlaceAt.get(key, at);
        if (ai.frame - int(at) < int(Global::RoleSettings::Tech::LayoutCanPlaceMemoSeconds * SECOND)) { bool was = true; canPlaceWas.get(key, was); return was; }
        bool ok = false;
        for (int i = 0; i < ZoneCount() && !ok; ++i)
            if (aiTerrainMgr.CanPackNearGroup(ZoneAt(i), def, nanoGroup, facing, 0.0f, MinNanoDist(def))) ok = true;
        if (!ok) ok = true;   // the box grows when it is full (Place)
        canPlaceAt.set(key, int64(ai.frame)); canPlaceWas.set(key, ok);
        return ok;
    }
