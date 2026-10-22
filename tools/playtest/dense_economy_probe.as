// Supplied placement/support fixture. Injected only into staged test data.
namespace DenseProbe {
    bool seeded=false;
    bool checkedOccupiedTidal=false;
    bool supportCase=false; // replaced by runner
    array<string> targets;
    void Tick() {
        if (ai.teamId!=0 || ai.frame<10*SECOND) return;
        const bool air=Global::AISettings::Role==AiRole::AIR;
        if (!seeded) {
            if (air) AirEcoLayout::PlanAhead();
            if (air && AirEcoLayout::modules.length()==0) return;
            seeded=true;
            if (air) {
                targets={"armmmkr"};
                const AIFloat3 p=aiTerrainMgr.GetReservationPos(AirEcoLayout::modules[0].slots[1]);
                WidgetLink::Send("denseprobe","give|armaca|"+(p.x+180)+"|"+p.z+"|8");
                WidgetLink::Send("denseprobe","camera|"+p.x+"|"+p.z);
            } else if (supportCase) {
                WidgetLink::Send("denseprobe","give|armsy|900|4300|1");
                WidgetLink::Send("denseprobe","give|armamsub|1700|4300|1");
                WidgetLink::Send("denseprobe","give|armcs|1350|4200|4");
                WidgetLink::Send("denseprobe","camera|1300|4300");
            } else {
                targets={"armtide","armfmkr","armuwmmm"};
                WidgetLink::Send("denseprobe","give|armcs|1000|4500|1");
                WidgetLink::Send("denseprobe","give|armacsub|1300|4500|4");
                WidgetLink::Send("denseprobe","camera|1240|4300");
            }
        }
        if (!air && !supportCase) for (uint i=0; i<targets.length(); ++i) {
            int found=0;
            for (uint j=0; j<SeaLayout::patches.length(); ++j) if (SeaLayout::patches[j].name==targets[i]
                && SeaLayout::patches[j].slots.length()>0) ++found;
            if (found<(i==0 ? 2 : 1)) {
                // Exercise two narrow fallback rows explicitly. The normal
                // tidal policy now reserves larger blocks regardless of count.
                SeaLayout::PlanPatch(ai.GetCircuitDef(targets[i]),AIFloat3(1000+float(i)*240,0,4300),6,1000,AIFloat3(-1,0,-1),i==0);
                break;
            }
        }
        if (!air && !supportCase && !checkedOccupiedTidal) for (uint i=0;i<SeaLayout::patches.length();++i) {
            SeaLayout::Patch@ patch=SeaLayout::patches[i];
            if (patch.name!="armtide" || patch.slots.length()==0 || aiTerrainMgr.GetReservationState(patch.slots[0])!=3) continue;
            checkedOccupiedTidal=true;
            const int duplicate=aiTerrainMgr.ReservePackedBuilding(ai.GetCircuitDef(patch.name),
                aiTerrainMgr.GetReservationPos(patch.slots[0]),patch.facing);
            GenericHelpers::LogUtil("[DenseFixture] "+(duplicate<0 ? "PASS" : "FAIL")+" occupied tidal rejected",1);
            if (duplicate>=0) aiTerrainMgr.ReleasePersistentBuilding(duplicate);
            break;
        }
        if (supportCase && ai.frame%(30*SECOND)<SECOND) {
            for (uint i=0; i<SeaEconomy::productionFactories.length(); ++i) {
                CCircuitUnit@ yard=ai.GetTeamUnit(SeaEconomy::productionFactories[i]);
                if (yard !is null) GenericHelpers::LogUtil("[DenseProbe] yard="+yard.circuitDef.GetName()
                    +" task="+(yard.task is null ? -1 : yard.task.GetType())+" busy="+SeaEconomy::Busy(yard.id),1);
            }
        }
    }
    IUnitTask@ MakeTask(CCircuitUnit@ u) {
        if (ai.teamId!=0 || !seeded || UnitHelpers::IsCommander(u.circuitDef)) return SeaBuild::Wait();
        IBuilderTask@ current=cast<IBuilderTask>(u.task);
        if (current !is null && !current.IsDead() && current.GetBuildType()<int(Task::BuildType::REPAIR)) return current;
        if (supportCase) {
            SeaEconomy::Tick();
            IUnitTask@ t=u.circuitDef.IsMobile() ? SeaBuild::Support(u) : SeaBuild::Assist(u);
            return t is null ? SeaBuild::Wait() : t;
        }
        for (uint i=0; i<targets.length(); ++i) {
            CCircuitDef@ d=ai.GetCircuitDef(targets[i]);
            if (d is null || !u.circuitDef.CanBuild(d)) continue;
            const bool air=Global::AISettings::Role==AiRole::AIR;
            if (air) {
                // Only the first bank is built; do not turn a finite fixture into
                // unlimited converter expansion on the supplied metal bank.
                AirEcoLayout::Module@ m=AirEcoLayout::modules[0];
                for (uint s=1; s<m.slots.length(); ++s) if (aiTerrainMgr.GetReservationState(m.slots[s])==0) {
                    IUnitTask@ task=AirLayout::Pinned(Task::BuildType::CONVERT,Task::Priority::NORMAL,d,m.slots[s]);
                    if (task !is null) { m.started=true; AirEcoLayout::Save(m); return AirBuild::Record(task,"dense.fixture",u); }
                }
            } else for (uint p=0; p<SeaLayout::patches.length(); ++p) {
                SeaLayout::Patch@ patch=SeaLayout::patches[p]; if (patch.name!=targets[i]) continue;
                for (uint s=0; s<patch.slots.length(); ++s) if (aiTerrainMgr.GetReservationState(patch.slots[s])==0) {
                    IUnitTask@ task=SeaLayout::Pinned(d,patch.slots[s],i==0 ? Task::BuildType::ENERGY : Task::BuildType::CONVERT,
                        Task::Priority::NORMAL);
                    if (task !is null) { patch.active=true; SeaLayout::SavePatch(p); return task; }
                }
            }
        }
        return SeaBuild::Wait();
    }
    IUnitTask@ Produce(CCircuitUnit@ factory) {
        if (!SeaEconomy::SupportedFactory(factory.circuitDef)) return aiFactoryMgr.DefaultMakeTask(factory);
        if (ai.teamId!=0 || !supportCase || ai.frame<30*SECOND) return aiFactoryMgr.Enqueue(TaskS::Wait(false,SECOND));
        const string name=factory.circuitDef.GetName();
        CCircuitDef@ product=ai.GetCircuitDef(name=="armsy" ? "armroy" : "armpincer");
        if (ai.frame%(30*SECOND)<SECOND) GenericHelpers::LogUtil("[DenseProbe] produce factory="+name
            +" product="+product.GetName()+" available="+product.IsAvailable(ai.frame)+" canBuild="+factory.circuitDef.CanBuild(product),1);
        return SeaFactories::Recruit(factory,product,Task::RecruitType::FIREPOWER);
    }
}
