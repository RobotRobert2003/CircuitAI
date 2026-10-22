// Test-only mutation oracle. The runner injects this into isolated staged data.
namespace CompoundPreflightProbe {
    int candidate = 0, compared = 0, accepted = 0, rejected = 0, failures = 0;
    bool done = false;
    void CheckUpgradeAdmission() {
        array<Id>@ owned = ai.GetOwnedUnitIds();
        CCircuitUnit@ worker = null;
        for (uint index = 0; index < owned.length(); ++index) {
            @worker = ai.GetTeamUnit(owned[index]);
            if (worker !is null && worker.circuitDef.IsMobile()) break;
        }
        CCircuitDef@ upgrade = ai.GetCircuitDef("cormoho");
        if (worker is null || upgrade is null) {
            GenericHelpers::LogUtil("[INVARIANT] UpgradeProbe missing fixture actor", 1);
            return;
        }
        AIFloat3 good = worker.GetPos(ai.frame);
        bool viable = false;
        for (int offset = 0; offset < 16 && !viable; ++offset) {
            good = worker.GetPos(ai.frame) + AIFloat3(float(offset % 4) * 32,0,float(offset / 4) * 32);
            viable = aiTerrainMgr.CanUpgradeTerrain(upgrade,good)
                && aiTerrainMgr.CanReachAtSafe(worker,good,worker.circuitDef.GetBuildDistance());
        }
        if (!viable) {
            GenericHelpers::LogUtil("[INVARIANT] UpgradeProbe no positive terrain control", 1);
            return;
        }
        const AIFloat3 bad(float(AiTerrainWidth()) + 100,0,good.z);
        array<Economy::MexTracker::MexInfo@> saved = Economy::MexTracker::myMexes;
        Economy::MexTracker::myMexes.resize(0);
        Economy::MexTracker::myMexes.insertLast(Economy::MexTracker::MexInfo(bad));
        Economy::MexTracker::myMexes.insertLast(Economy::MexTracker::MexInfo(good));
        const float radius = float(AiTerrainWidth()) * 2;
        const AIFloat3 legacy = Economy::MexTracker::GetNearestNonUpgradedMexInRange(bad,good,radius);
        const AIFloat3 admitted = Economy::MexTracker::GetNearestNonUpgradedMexInRange(bad,good,radius,worker,upgrade);
        const AIFloat3 stillRequired = Economy::MexTracker::GetNearestNonUpgradedMexInRange(bad,good,radius);
        const bool equal = MapHelpers::SqDist(legacy,bad) == 0 && MapHelpers::SqDist(admitted,good) == 0
            && MapHelpers::SqDist(stillRequired,bad) == 0;
        Economy::MexTracker::myMexes = saved;
        GenericHelpers::LogUtil(equal ? "[UpgradeProbe] PASS blocked candidate skipped; prerequisite unchanged"
            : "[INVARIANT] UpgradeProbe candidate/prerequisite mismatch", 1);
    }
    void Tick() {
        if (done || ai.teamId != 0 || ai.frame < 10 * SECOND) return;
        if (candidate == 0) {
            CheckUpgradeAdmission();
            CCircuitDef@ upgrade = ai.GetCircuitDef("legmoho");
            GenericHelpers::LogUtil("[UpgradeProbe] legmoho terrain at Glacial observed retry site="
                + (upgrade !is null && aiTerrainMgr.CanUpgradeTerrain(upgrade, AIFloat3(13840,0,976))), 1);
        }
        aiTerrainMgr.SetLayoutEnabled(true);
        const array<string> factories = {"armlab", "corlab", "leglab", "armalab", "coralab", "legalab"};
        const array<string> turrets = {"armnanotc", "cornanotc", "legnanotc"};
        // Sample facings, snapped offsets, terrain, occupied ground and edges.
        for (int work = 0; work < 32 && candidate < 1536; ++work, ++candidate) {
            const int facing = candidate % 4;
            CCircuitDef@ factory = ai.GetCircuitDef(factories[(candidate / 4) % 6]);
            CCircuitDef@ turret = ai.GetCircuitDef(turrets[(candidate / 4) % 3]);
            if (factory is null || turret is null) continue;
            const int sample = candidate / 24;
            const AIFloat3 position(Global::Map::StartPos.x + float(sample % 8 - 4) * 180.0f,
                0, Global::Map::StartPos.z + float(sample / 8 - 4) * 180.0f);
            if (!aiTerrainMgr.CanReserveBuilding(factory, position, facing)) continue;
            const bool expected = aiTerrainMgr.CanReserveNanoBlockAt(turret, factory, position, facing, 4, 3, 0);
            const int lab = aiTerrainMgr.ReserveBuilding(factory, position, facing, 0);
            if (lab < 0) continue;
            const int group = aiTerrainMgr.ReserveNanoBlockAt(turret, factory, position, facing, 4, 3, 0);
            const bool actual = group > 0 && aiTerrainMgr.CountGroupSlotsWithin(group, position, turret.GetBuildDistance()) > 0;
            ++compared;
            if (actual) ++accepted; else ++rejected;
            if (actual != expected) {
                ++failures;
                GenericHelpers::LogUtil("[INVARIANT] compound preflight differs candidate=" + candidate
                    + " expected=" + expected + " actual=" + actual, 1);
            }
            if (group > 0) {
                const int zone = aiTerrainMgr.GetGroupZone(group);
                aiTerrainMgr.ReleaseGroup(group);
                if (zone > 0) aiTerrainMgr.ReleaseZone(zone);
            }
            aiTerrainMgr.ReleaseReservation(lab);
        }
        if (candidate >= 1536) {
            done = true;
            GenericHelpers::LogUtil("[CompoundProbe] " + (failures == 0 && accepted > 0 && rejected > 0 ? "PASS" : "FAIL")
                + " compared=" + compared + " accepted=" + accepted + " rejected=" + rejected + " failures=" + failures, 1);
        }
    }
}
