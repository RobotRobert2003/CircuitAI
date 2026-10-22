// Isolated policy checks using real runtime UnitDefs; no construction claims.
namespace TechWeaponPolicyProbe {
    bool done=false;
    void Tick() {
        if (done || ai.teamId!=0 || ai.frame<30*SECOND) return;
        done=true;
        const string originalSide=Global::AISettings::Side;
        const int savedFrame=TechWeapons::frontSnapshotFrame;
        const AIFloat3 savedFront=TechWeapons::frontSnapshot;
        TechWeapons::frontSnapshotFrame=ai.frame;
        TechWeapons::frontSnapshot=AIFloat3(6144,0,6144);
        bool pass=!WallHelpers::Allowed(ai.GetCircuitDef("armdrag"),Global::Map::StartPos);
        const array<string> sides={"armada","cortex","legion"};
        const array<string> names={"armemp","cortron","legperdition"};
        const array<int> counts={1,1,3};
        for (uint side=0;side<sides.length();++side) {
            Global::AISettings::Side=sides[side];
            TechWeapons::WCluster cluster;
            cluster.kind=TechWeapons::KILL; cluster.pos=AIFloat3(6100,0,6100); cluster.dir=AIFloat3(1,0,0);
            TechWeapons::AddFactionSupport(cluster);
            int count=0;
            for (uint index=0;index<cluster.slots.length();++index) if (cluster.slots[index].role=="special") ++count;
            pass=pass && count==counts[side] && TechWeapons::Def("special") !is null && TechWeapons::UnitName("special")==names[side];
            TechWeapons::SortSlots(cluster);
            pass=pass && cluster.slots.length()>0 && !TechWeapons::IsWall(cluster.slots[0].role);
        }
        Global::AISettings::Side=originalSide;
        TechWeapons::WCluster waiting;
        waiting.slots.insertLast(TechWeapons::Slot("geoartillery",AIFloat3(6144,0,6144)));
        pass=pass && TechWeapons::PendingGeothermal(waiting);
        waiting.slots[0].standFrame=ai.frame;
        pass=pass && !TechWeapons::PendingGeothermal(waiting);
        const uint oldSites=TechFortifications::sites.length();
        TechFortifications::Lane(false); TechFortifications::Lane(true);
        pass=pass && TechFortifications::sites.length()==oldSites;
        TechWeapons::frontSnapshotFrame=savedFrame; TechWeapons::frontSnapshot=savedFront;
        GenericHelpers::LogUtil("[TechWeaponPolicy] "+(pass ? "PASS" : "FAIL")+" factions, home exclusion, gun-first ordering, geo fallback, no home lane walls",1);
    }
}
