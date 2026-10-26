// Staged-only physical obstruction, adoption and capacity observer.
namespace AirClusterProbe {
    const bool controlled = true;
    int blocked = -1, cluster = -1, sampled = -100000;
    bool relocated = false;
    dictionary centeredPlans;
    void CheckCentered()
    {
        // Observe reserved coordinates only: no placement or construction orders.
        if (Global::RoleSettings::Air::CenteredT2FactorySupport) {
            for (uint b = 0; b < AirLayout::bays.length(); ++b) {
                AirLayout::Bay@ bay = AirLayout::bays[b];
                if (bay.cluster < 0 || !UnitHelpers::IsT2AircraftPlant(bay.defName)) continue;
                // Called synchronously after atomic planning, before gameplay can
                // obstruct or release pins. Relocation creates a new slot ID.
                const string planKey = "" + bay.slot;
                if (centeredPlans.exists(planKey)) continue;
                const AIFloat3 axis = AirLayout::Offset(bay.centre, bay.facing, 0.0f, 1.0f);
                int rear = 0, front = 0;
                for (uint n = 0; n < bay.nanos.length(); ++n) {
                    const AIFloat3 p = aiTerrainMgr.GetReservationPos(bay.nanos[n]);
                    const float projection = (p.x - bay.centre.x) * (axis.x - bay.centre.x)
                        + (p.z - bay.centre.z) * (axis.z - bay.centre.z);
                    if (projection < 0.0f) ++rear; else if (projection > 0.0f) ++front;
                }
                GenericHelpers::LogUtil("[AirClusterProbe] " + ((rear == 9 && front == 11) || (rear == 11 && front == 9) ? "PASS" : "FAIL")
                    + " centered bay=" + bay.key + " rear=" + rear + " front=" + front, 1);
                centeredPlans.set(planKey, true);
            }
        }
    }
    void Tick()
    {
        if (ai.teamId != 0 || !AirEconomy::Active()) return;
        if (controlled && blocked < 0 && ai.frame >= 15 * SECOND) {
            for (uint b = 0; b < AirLayout::bays.length(); ++b) {
                AirLayout::Bay@ bay = AirLayout::bays[b];
                if (bay.cluster < 0 || bay.started || aiTerrainMgr.GetReservationState(bay.slot) != 0) continue;
                blocked = bay.slot; cluster = bay.cluster;
                const AIFloat3 p = aiTerrainMgr.GetReservationPos(blocked);
                WidgetLink::Send("layoutprobe", "block|" + p.x + "|" + p.z);
                GenericHelpers::LogUtil("[AirClusterProbe] blocker requested cluster=" + cluster, 1);
                break;
            }
        }
        if (controlled && !relocated && blocked >= 0 && ai.frame >= 25 * SECOND) {
            for (uint b = 0; b < AirLayout::bays.length(); ++b) {
                if (AirLayout::bays[b].cluster != cluster) continue;
                AirLayout::Bay@ bay = AirLayout::Activate(AirLayout::bays[b]);
                if (bay !is null && bay.slot != blocked && aiTerrainMgr.GetReservationState(blocked) < 0) {
                    relocated = true;
                    GenericHelpers::LogUtil("[AirClusterProbe] PASS whole unused cluster relocated", 1);
                }
                break;
            }
        }
        if (ai.frame - sampled < 30 * SECOND) return;
        sampled = ai.frame;
        for (uint i = 0; i < AirBuild::projects.length(); ++i) {
            IBuilderTask@ task = cast<IBuilderTask>(AirBuild::projects[i]);
            if (task is null || !AirBuild::IsReactor(task.buildDef)) continue;
            GenericHelpers::LogUtil("[AirClusterProbe] reactorProject dead=" + task.IsDead() + " kind=" + task.GetBuildType()
                + " target=" + (task.target is null ? -1 : task.target.id) + " pin=" + AiTaskReservationId(task)
                + " def=" + task.buildDef.GetName(), 1);
        }
        const int count = aiTerrainMgr.GetLayoutInt("air.clusters", 0);
        for (int c = 0; c < count; ++c) {
            int members = 0, support = 0;
            for (uint b = 0; b < AirLayout::bays.length(); ++b) {
                if (AirLayout::bays[b].cluster != c) continue;
                ++members; support += int(AirLayout::bays[b].nanos.length());
            }
            GenericHelpers::LogUtil("[AirClusterProbe] " + (members == 6 ? "PASS" : "FAIL") + " membership cluster=" + c + " labs=" + members + " support=" + support, 1);
        }
        const string side = Global::AISettings::Side;
        GenericHelpers::LogUtil("[AirClusterProbe] economy t1=" + AirEconomy::t1 + " t2=" + AirEconomy::t2
            + " afus=" + AirEconomy::CompletedAfus() + " wind=" + AirEconomy::Count(UnitHelpers::GetWindNameForSide(side))
            + " M=" + AirEconomy::metal + " E=" + AirEconomy::energy, 1);
    }
}
