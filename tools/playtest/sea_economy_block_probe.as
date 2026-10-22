// Supplied demand only. Production placement/funding/assistance are unmodified.
namespace SeaBlockProbe {
    bool seeded=false, announced=false;
    void Tick() {
        if (ai.teamId!=0 || ai.frame<10*SECOND) return;
        if (!seeded) {
            seeded=true;
            WidgetLink::Send("denseprobe","give|armsy|5824|10736|1");
            WidgetLink::Send("denseprobe","give|armamsub|6600|10736|1");
            WidgetLink::Send("denseprobe","give|armcs|6100|10500|4");
            WidgetLink::Send("denseprobe","give|armacsub|6150|10800|4");
            WidgetLink::Send("denseprobe","camera|6200|11000");
            ai.GetCircuitDef("armcroc").maxThisUnit=100;
            ai.GetCircuitDef("armuwfus").maxThisUnit=10;
            ai.GetCircuitDef("armuwmmm").maxThisUnit=30;
            Global::RoleSettings::Sea::MaxSupportPerBerth=8;
        }
        if (!announced && SeaEcoLayout::blocks.length()>0) {
            SeaEcoLayout::Block@ b=SeaEcoLayout::blocks[0];
            const AIFloat3 fusion=aiTerrainMgr.GetReservationPos(b.fusion);
            WidgetLink::Send("seablock","plan|"+b.centre.x+"|"+b.centre.z+"|"+b.harbor.x+"|"+b.harbor.z
                +"|"+fusion.x+"|"+fusion.z+"|"+SeaEcoLayout::direction);
            announced=true;
        }
        if (announced && ai.frame%(30*SECOND)<SECOND) {
            SeaEcoLayout::Block@ b=SeaEcoLayout::blocks[0];
            CCircuitDef@ d=ai.GetCircuitDef("armuwfus");
            GenericHelpers::LogUtil("[SeaBlockProbe] fusion available="+d.IsAvailable(ai.frame)+" have="+SeaEconomy::Have(d)
                +" state="+aiTerrainMgr.GetReservationState(b.fusion)+" groupTotal="+aiTerrainMgr.GetGroupCount(b.group,false)
                +" groupFree="+aiTerrainMgr.GetGroupCount(b.group,true)+" nanos="+ai.GetCircuitDef("armnanotcplat").count,1);
        }
    }
    IUnitTask@ MakeTask(CCircuitUnit@ u) {
        if (ai.teamId!=0 || !seeded || UnitHelpers::IsCommander(u.circuitDef)) return SeaBuild::Wait();
        IBuilderTask@ current=cast<IBuilderTask>(u.task);
        if (current !is null && !current.IsDead() && current.GetBuildType()<int(Task::BuildType::REPAIR)) return current;
        SeaEconomy::Tick();
        if (!u.circuitDef.IsMobile()) return SeaBuild::Assist(u);
        IUnitTask@ task=SeaBuild::Resume(u); if (task !is null) return task;
        @task=SeaEcoLayout::Support(u); if (task !is null) return task;
        @task=SeaBuild::Support(u); if (task !is null) return task;
        const array<string> names={"armfmkr","armuwmmm","armuwfus"};
        const array<int> counts={12,8,1};
        for (uint i=0;i<names.length();++i) {
            CCircuitDef@ d=ai.GetCircuitDef(names[i]);
            if (u.circuitDef.CanBuild(d) && SeaEconomy::Have(d)<counts[i]) {
                @task=SeaBuild::Place(u,names[i],i==2 ? Task::BuildType::ENERGY : Task::BuildType::CONVERT);
                if (task !is null) return task;
            }
        }
        @task=SeaBuild::Assist(u); return task is null ? SeaBuild::Wait() : task;
    }
    IUnitTask@ Produce(CCircuitUnit@ factory) {
        if (!SeaEconomy::SupportedFactory(factory.circuitDef)) return aiFactoryMgr.DefaultMakeTask(factory);
        if (ai.teamId!=0 || ai.frame<30*SECOND) return aiFactoryMgr.Enqueue(TaskS::Wait(false,SECOND));
        CCircuitDef@ product=ai.GetCircuitDef(factory.circuitDef.GetName()=="armsy" ? "armroy" : "armcroc");
        // A second finite production wave exercises factory support after the
        // shared constructors finish the initial economy investment.
        const int demand=ai.frame<6*60*SECOND ? 3 : 6;
        if (product.count>=demand) return aiFactoryMgr.Enqueue(TaskS::Wait(false,SECOND));
        return SeaFactories::Recruit(factory,product,Task::RecruitType::FIREPOWER);
    }
}
