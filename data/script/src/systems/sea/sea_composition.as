// Count baseline is separate from emergency coverage. Native pending counts
// own frame/task lifecycle; never maintain a second speculative hull counter.
namespace SeaComposition {
    // Enemy hover metal on the home water body (flag 512 contacts).
    float EnemyHoverMetal() {
        const int count=aiBattle.GetSeaForceCount();
        const int body=aiBattle.WaterBody(Global::Map::StartPos,false);
        float metal=0;
        for (int i=0;i<count;++i) {
            const int flags=aiBattle.GetSeaForceFlags(i);
            if ((flags&(1|8))!=0 || (flags&512)==0) continue;
            if (body>=0 && aiBattle.GetSeaForceBody(i)!=body) continue;
            metal+=aiBattle.GetSeaForceCost(i);
        }
        return metal;
    }
    // Known enemy submarine metal on the home water (flag 2, mobile).
    float EnemySubMetal() {
        const int count=aiBattle.GetSeaForceCount();
        const int body=aiBattle.WaterBody(Global::Map::StartPos,false);
        float metal=0;
        for (int i=0;i<count;++i) {
            const int flags=aiBattle.GetSeaForceFlags(i);
            if ((flags&(1|8))!=0 || (flags&2)==0) continue;
            if (body>=0 && aiBattle.GetSeaForceBody(i)!=body) continue;
            metal+=(flags&16)!=0 ? Global::RoleSettings::Sea::UnknownSubContactMetal : aiBattle.GetSeaForceCost(i);
        }
        return metal;
    }
    CCircuitDef@ Select(CCircuitUnit@ yard,const dictionary &in localCounts) {
        const string side=UnitHelpers::GetSideForUnitName(yard.circuitDef.GetName());
        const bool advanced=UnitHelpers::IsT2Shipyard(yard.circuitDef.GetName());
        array<string> names;
        if (advanced) names=side=="armada" ? Global::RoleSettings::Sea::ArmadaTierTwoComposition
            : side=="cortex" ? Global::RoleSettings::Sea::CortexTierTwoComposition : Global::RoleSettings::Sea::LegionTierTwoComposition;
        else names=side=="armada" ? Global::RoleSettings::Sea::ArmadaTierOneComposition
            : side=="cortex" ? Global::RoleSettings::Sea::CortexTierOneComposition : Global::RoleSettings::Sea::LegionTierOneComposition;
        // D-301: faction ratios from the naval meta review; the flat global
        // ratios remain the fallback when a profile empties the arrays.
        array<float> ratios=advanced
            ? (side=="armada" ? Global::RoleSettings::Sea::ArmadaTierTwoRatios : side=="cortex" ? Global::RoleSettings::Sea::CortexTierTwoRatios : Global::RoleSettings::Sea::LegionTierTwoRatios)
            : (side=="armada" ? Global::RoleSettings::Sea::ArmadaTierOneRatios : side=="cortex" ? Global::RoleSettings::Sea::CortexTierOneRatios : Global::RoleSettings::Sea::LegionTierOneRatios);
        if (ratios.length()!=3) {
            ratios.resize(3);
            ratios[0]=Global::RoleSettings::Sea::SubmarineCompositionRatio;
            ratios[1]=Global::RoleSettings::Sea::FrigateCompositionRatio;
            ratios[2]=Global::RoleSettings::Sea::DestroyerCompositionRatio;
        }
        if (ratios.length()==3 && names.length()==3 && !advanced
            && Global::RoleSettings::Sea::HoverBlindHulls.find(names[1])>=0) {
            // KI-611: one census pass per production ask (O(contacts)).
            const float hovers=EnemyHoverMetal();
            if (hovers>=Global::RoleSettings::Sea::HoverResponseMetal) {
                const float moved=ratios[1]*AiMax(0.0f,AiMin(1.0f,Global::RoleSettings::Sea::HoverResponseShare));
                ratios[1]-=moved; ratios[2]+=moved;
                GenericHelpers::LogUtil("[SEA][HoverResponse] hovers="+hovers+" screen="+ratios[1]+" gun="+ratios[2],2);
            }
        }
        if (names.length()!=ratios.length()) {
            Invariants::Violation("INV-185",side,"SEA composition must define submarine, screen and heavy hull");
            return null;
        }
        CCircuitDef@ selected=null; float best=-1e30f; int frigates=0, cruisers=0;
        for (uint i=0;i<names.length() && i<ratios.length();++i) {
            CCircuitDef@ definition=ai.GetCircuitDef(names[i]);
            if (definition is null) continue;
            const int count=DictIntOr(localCounts,""+definition.id)+aiFactoryMgr.GetPendingRecruitCount(definition);
            // D-301: AA scales with every combat hull, not the screen slot alone.
            frigates+=count;
            if (i==2) cruisers=count;
            if (!definition.IsAvailable(ai.frame) || !yard.circuitDef.CanBuild(definition)) continue;
            const float score=SeaMath::CompositionDeficit(count,ratios[i]);
            if (score>best) { best=score; @selected=definition; }
        }
        if (!advanced && side=="legion" && Global::RoleSettings::Sea::CapitalShips) {
            // D-301: Octeres is Legion's T1 shore artillery (960, cluster),
            // unique among the factions; build it once the water is held.
            CCircuitDef@ octeres=ai.GetCircuitDef("legnavyartyship");
            // Shore to Shore (s36): Octeres has no anti-sub weapon and enemy
            // subs sank them; no siege hull while subs are on the home water.
            const bool subsAbsent=EnemySubMetal()<Global::RoleSettings::Sea::SiegeMaxEnemySubMetal;
            const int wanted=SeaCombat::fleet<Global::RoleSettings::Sea::TierOneSiegeFleetMetal || !SeaEconomy::HoldingWater() || !subsAbsent ? 0
                : Global::RoleSettings::Sea::MaxTierOneSiegeShips;
            if (octeres !is null && octeres.IsAvailable(ai.frame) && yard.circuitDef.CanBuild(octeres)
                && DictIntOr(localCounts,""+octeres.id)+aiFactoryMgr.GetPendingRecruitCount(octeres)<wanted) {
                GenericHelpers::LogUtil("[SEA][Capital] siege legnavyartyship fleet="+SeaCombat::fleet,1);
                return octeres;
            }
        }
        if (advanced && Global::RoleSettings::Sea::CapitalShips) {
            // D-301 capital step: battleships stand behind the cruiser core;
            // shore-siege ships (outranging every land defence) come once the
            // fleet holds the water. Names are the faction's T2 hulls.
            CCircuitDef@ battleship=ai.GetCircuitDef(side=="armada" ? "armbats" : side=="cortex" ? "corbats" : "leganavybattleship");
            if (battleship !is null && battleship.IsAvailable(ai.frame) && yard.circuitDef.CanBuild(battleship)
                && DictIntOr(localCounts,""+battleship.id)+aiFactoryMgr.GetPendingRecruitCount(battleship)
                    <SeaMath::CapitalTarget(cruisers,Global::RoleSettings::Sea::CapitalAfterCruisers,
                        Global::RoleSettings::Sea::CruisersPerBattleship,Global::RoleSettings::Sea::MaxBattleships)) {
                GenericHelpers::LogUtil("[SEA][Capital] battleship "+battleship.GetName()+" cruisers="+cruisers,1);
                return battleship;
            }
            CCircuitDef@ siege=ai.GetCircuitDef(side=="armada" ? "armmship" : side=="cortex" ? "cormship" : "leganavymissileship");
            const int siegeWanted=SeaCombat::fleet<Global::RoleSettings::Sea::SiegeFleetMetal || !SeaEconomy::HoldingWater()
                || EnemySubMetal()>=Global::RoleSettings::Sea::SiegeMaxEnemySubMetal ? 0
                : AiMin(Global::RoleSettings::Sea::MaxSiegeShips,int(SeaCombat::fleet/AiMax(1.0f,Global::RoleSettings::Sea::SiegeShipFleetMetal)));
            if (siege !is null && siege.IsAvailable(ai.frame) && yard.circuitDef.CanBuild(siege)
                && DictIntOr(localCounts,""+siege.id)+aiFactoryMgr.GetPendingRecruitCount(siege)<siegeWanted) {
                GenericHelpers::LogUtil("[SEA][Capital] siege "+siege.GetName()+" fleet="+SeaCombat::fleet,1);
                return siege;
            }
        }
        const string antiAirName=advanced ? (side=="armada" ? "armaas" : side=="cortex" ? "corarch" : "leganavyaaship")
            : (side=="armada" ? "armpt" : side=="cortex" ? "corpt" : "legnavyaaship");
        CCircuitDef@ antiAir=ai.GetCircuitDef(antiAirName);
        const int perShip=AiMax(1,Global::RoleSettings::Sea::FrigatesPerAntiAirShip);
        if (advanced) {
            CCircuitDef@ frigate=ai.GetCircuitDef(side=="armada" ? "armpship" : side=="cortex" ? "corpship" : "legnavyfrigate");
            if (frigate !is null) frigates+=DictIntOr(localCounts,""+frigate.id)+aiFactoryMgr.GetPendingRecruitCount(frigate);
        }
        if (antiAir !is null && antiAir.IsAvailable(ai.frame) && yard.circuitDef.CanBuild(antiAir) && !SeaCombat::SmallBoatFull(antiAir)
            && DictIntOr(localCounts,""+antiAir.id)+aiFactoryMgr.GetPendingRecruitCount(antiAir)<(frigates+perShip-1)/perShip)
            return SeaCombat::NoteSmallBoat(antiAir);
        return selected;
    }
    class Batch { int yard=-1; array<IUnitTask@> tasks; }
    array<Batch@> batches;
    void CancelUnstarted(Batch@ batch) {
        for (uint i=0;i<batch.tasks.length();++i) {
            IUnitTask@ task=batch.tasks[i];
            if (task is null || task.IsDead()) continue;
            IBuilderTask@ build=cast<IBuilderTask>(task);
            if (build !is null && build.target is null && task.GetUnits().length()==0) task.Abort();
        }
    }
    void Prune() {
        // O(number of yards * bounded batch size) once per SEA census. Tasks
        // retain safe ref-counted handles; units are reacquired by ID.
        for (int i=int(batches.length())-1;i>=0;--i) {
            Batch@ batch=batches[i];
            CCircuitUnit@ yard=ai.GetTeamUnit(batch.yard);
            if (yard is null || !SeaCombat::Active() || SeaFactories::Hold(yard)) CancelUnstarted(batch);
            for (int j=int(batch.tasks.length())-1;j>=0;--j)
                if (batch.tasks[j] is null || batch.tasks[j].IsDead()) batch.tasks.removeAt(j);
            if (batch.tasks.length()==0) batches.removeAt(i);
        }
    }
    IUnitTask@ Pending(CCircuitUnit@ yard,bool cancel=false) {
        for (uint i=0;i<batches.length();++i) if (batches[i].yard==yard.id) {
            if (cancel) { CancelUnstarted(batches[i]); return null; }
            for (uint j=0;j<batches[i].tasks.length();++j) {
                IUnitTask@ task=batches[i].tasks[j];
                if (task !is null && !task.IsDead()) return task;
            }
        }
        return null;
    }
    IUnitTask@ Enqueue(CCircuitUnit@ yard,CCircuitDef@ definition) {
        Batch@ batch=Batch(); batch.yard=yard.id;
        const int count=AiMax(1,AiMin(12,Global::RoleSettings::Sea::FleetRecruitBatch));
        for (int i=0;i<count;++i) {
            IUnitTask@ task=SeaFactories::Recruit(yard,definition,Task::RecruitType::FIREPOWER);
            if (task is null) break;
            batch.tasks.insertLast(task);
        }
        if (batch.tasks.length()==0) return null;
        batches.insertLast(batch);
        GenericHelpers::LogUtil("[SEA][Batch] yard="+yard.id+" unit="+definition.GetName()+" count="+batch.tasks.length(),1);
        return batch.tasks[0];
    }
}
