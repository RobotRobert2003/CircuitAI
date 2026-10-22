// Staged only. Independent rectangle audit, plus actual native reservation calls.
namespace LayoutResourceProbe {
    bool checked = false;
    int nextCheck = 0;
    array<int> temporaryZones;
    void Check(bool ok, const string &in label)
    {
        GenericHelpers::LogUtil("[LayoutResource] " + (ok ? "PASS " : "FAIL ") + label + " team=" + ai.teamId, 1);
    }
    void Message(const string &in message, int fromTeamId)
    {
        array<string>@ p = message.split("|");
        if (p.length() != 4 || p[0] != "resourceprobe" || fromTeamId == ai.teamId) return;
        CCircuitDef@ resource = ai.GetCircuitDef(p[1] == "metal" ? "armmex" : "armgeo");
        const AIFloat3 pos(parseFloat(p[2]), 0.0f, parseFloat(p[3]));
        Check(aiTerrainMgr.IsAllyLayoutBlocked(ai.GetCircuitDef("armsolar"), pos, 0), "foreign envelope observed");
        if (p[1] == "field") {
            Check(aiTerrainMgr.IsAllyLayoutBlocked(ai.GetCircuitDef("armmex"), pos, 0), "metal field respects ally cluster");
            return;
        }
        Check(!aiTerrainMgr.IsAllyLayoutBlocked(resource, pos, 0), "foreign resource cutout " + p[1]);
        CCircuitDef@ advanced = ai.GetCircuitDef(p[1] == "metal" ? "armmoho" : "armageo");
        Check(!aiTerrainMgr.IsAllyLayoutBlocked(advanced, pos, 0), "foreign advanced resource cutout " + p[1]);
    }
    void Tick()
    {
        if (ai.frame < 450 || !aiTerrainMgr.IsLayoutEnabled()) return;
        // AiSendMessage delivers asynchronously. Keep the test envelopes until
        // the next slow tick so receivers prove the exception against live zones.
        for (uint i = 0; i < temporaryZones.length(); ++i) aiTerrainMgr.ReleaseZone(temporaryZones[i]);
        temporaryZones.resize(0);
        if (checked && ai.frame < nextCheck) return;
        nextCheck = ai.frame + 150;
        array<string>@ rows = aiTerrainMgr.DescribeLayout().split(";");
        array<AIFloat3> sites;
        array<float> widths, depths;
        int metals = 0, geos = 0;
        bool sentMetal = false, sentGeo = false;
        for (uint i = 0; i < rows.length(); ++i) {
            array<string>@ f = rows[i].split(":");
            if (f.length() < 8 || f[0] != "resource") continue;
            const AIFloat3 pos(parseFloat(f[2]), 0.0f, parseFloat(f[3]));
            sites.insertLast(pos); widths.insertLast(parseFloat(f[5])); depths.insertLast(parseFloat(f[6]));
            if (f[1] == "metal") ++metals; else ++geos;
            if (!checked) {
                // A zone can surround a node; its actual plot must remain a
                // cutout accessible to the matching resource building only.
                Check(aiTerrainMgr.IsResourceAreaBlocked(pos, 0, 128.0f, 128.0f), "candidate detects " + f[1]);
                const bool sent = f[1] == "metal" ? sentMetal : sentGeo;
                const int zone = sent ? 0 : aiTerrainMgr.ReserveZone(pos, 0, 128.0f, 128.0f, false);
                CCircuitDef@ ordinary = ai.GetCircuitDef("armsolar");
                Check(!aiTerrainMgr.CanReserveBuilding(ordinary, pos, 0), "resource rejects ordinary slot " + f[1]);
                const int slot = aiTerrainMgr.ReserveBuilding(ordinary, pos, 0);
                Check(slot < 0, "resource rejects reserve " + f[1]);
                if (slot >= 0) aiTerrainMgr.ReleaseReservation(slot);
                CCircuitDef@ resource = ai.GetCircuitDef(f[1] == "metal" ? "armmex" : "armgeo");
                Check(!aiTerrainMgr.IsAllyLayoutBlocked(resource, pos, 0), "resource access " + f[1]);
                if (zone > 0) {
                    AiSendMessage("resourceprobe|" + f[1] + "|" + pos.x + "|" + pos.z);
                    temporaryZones.insertLast(zone);
                    if (f[1] == "metal") sentMetal = true; else sentGeo = true;
                }
            }
        }
        if (!checked) {
            Check(aiEconomyMgr.IsMetalMap() ? metals == 0 : metals > 0, "metal map exception");
            Check(geos == ai.GetGeoSpotCount(), "geothermal sites retained");
            if (aiEconomyMgr.IsMetalMap()) {
                bool free = false;
                for (int x = 256; x < AiTerrainWidth() && !free; x += 512) {
                    const int id = aiTerrainMgr.ReserveZone(AIFloat3(float(x), 0.0f, 512.0f), 0, 64.0f, 64.0f, false);
                    if (id > 0) {
                        temporaryZones.insertLast(id);
                        AiSendMessage("resourceprobe|field|" + x + "|512");
                        free = true;
                    }
                }
                Check(free, "metal field accepts ordinary zone");
            }
        }
        int overlaps = 0;
        for (uint i = 0; i < rows.length(); ++i) {
            array<string>@ f = rows[i].split(":");
            if (f.length() < 8 || f[0] != "slot") continue;
            const float x = parseFloat(f[2]), z = parseFloat(f[3]);
            const float w = parseFloat(f[5]), d = parseFloat(f[6]);
            for (uint j = 0; j < sites.length(); ++j) {
                const float dx = x > sites[j].x ? x - sites[j].x : sites[j].x - x;
                const float dz = z > sites[j].z ? z - sites[j].z : sites[j].z - z;
                if (dx * 2.0f < w + widths[j] && dz * 2.0f < d + depths[j]) ++overlaps;
            }
        }
        if (overlaps > 0) Check(false, "INV-172 resource overlap count=" + overlaps);
        else if (!checked || ai.frame >= 8 * MINUTE) Check(true, "resource audit");
        checked = true;
    }
}
