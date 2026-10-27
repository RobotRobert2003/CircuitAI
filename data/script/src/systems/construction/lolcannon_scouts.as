#include "../../global.as"
#include "../../task.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/spatial/map_helpers.as"
#include "../../helpers/units/unit_helpers.as"

/*
TECH's own lolcannon scouts (owner 2026-10-27), for a map with no AIR: a
request (team/lolcannon_recon.as) orders T1 scouts from our T1 air plants and
radar planes from our T2 ones; each plane, once finished, flies to its own
point spread round the area and on to the far edge (LolCannonRecon::Route),
then is let go. One package at a time: a request while one is still being
built retargets the planes still to come; a package that cannot finish lapses
after PackageSeconds.
With no plant to make them (a TECH often has none), TECH builds them: a T1
air plant for the T1 scouts; for the radar planes a T2 air plant, which only
an air constructor builds, so first one T1 air constructor from the T1 plant.
One order of each at a time, a plant still being built counts as there.
*/
namespace LolCannonScouts {
    const array<string> T1_DEFS = { "armpeep", "corfink", "legfig" };
    const array<string> RADAR_DEFS = { "armawac", "corawac", "legwhisper" };
    const int PackageSeconds = 600;     // time for the plants too
    const int OrderSeconds = 20;
    const int FlightSeconds = 240;

    AIFloat3 target(-1, 0, -1);
    float spread = 0.0f;
    array<int> wanted = { 0, 0 }, sent = { 0, 0 };
    int since = -1, nextOrder = 0;
    array<IUnitTask@> ordersT1, ordersRadar;
    IUnitTask@ plantT1, plantT2, airCon;
    dictionary flights, ends, deadlines;   // unit id -> its route task, the route's end, when it is let go

    int Kind(const string &in name)
    {
        if (T1_DEFS.find(name) >= 0) return 0;
        if (RADAR_DEFS.find(name) >= 0) return 1;
        return -1;
    }

    bool Busy()
    {
        return target.x >= 0.0f && since >= 0 && ai.frame - since < PackageSeconds * SECOND
            && (sent[0] < wanted[0] || sent[1] < wanted[1]);
    }

    void Request(int t1, int radar, const AIFloat3 &in at, float sp)
    {
        if (at.x < 0.0f) return;
        const bool busy = Busy();
        target = at;
        spread = sp;
        if (busy) {
            GenericHelpers::LogUtil("[LolCannon][Scouts] package retargeted to (" + int(at.x) + "," + int(at.z) + "); "
                + sent[0] + "/" + wanted[0] + " T1 and " + sent[1] + "/" + wanted[1] + " radar sent", 1);
            return;
        }
        wanted[0] = AiMax(0, t1); wanted[1] = AiMax(0, radar);
        sent[0] = 0; sent[1] = 0;
        since = ai.frame;
        nextOrder = 0;
        GenericHelpers::LogUtil("[LolCannon][Scouts] no AIR: TECH builds " + wanted[0] + " T1 scouts and " + wanted[1]
            + " radar planes for (" + int(at.x) + "," + int(at.z) + ")", 1);
    }

    int Alive(array<IUnitTask@>@ tasks)
    {
        for (int i = int(tasks.length()) - 1; i >= 0; --i)
            if (tasks[i] is null || tasks[i].IsDead()) tasks.removeAt(i);
        return int(tasks.length());
    }

    // Every OrderSeconds: a plant ordered for a kind still missing that no plant
    // of ours (finished or not) makes. The planes themselves come from Produce.
    void Order()
    {
        if (ai.frame < nextOrder) return;
        nextOrder = ai.frame + OrderSeconds * SECOND;
        array<bool> plant = { false, false };
        array<string>@ all = Factory::allFactories.getKeys();
        for (uint i = 0; i < all.length(); ++i) {
            CCircuitUnit@ f = null;
            if (!Factory::allFactories.get(all[i], @f) || f is null || f.circuitDef is null) continue;
            for (uint n = 0; n < T1_DEFS.length(); ++n) {
                CCircuitDef@ a = ai.GetCircuitDef(T1_DEFS[n]), b = ai.GetCircuitDef(RADAR_DEFS[n]);
                if (a !is null && f.circuitDef.CanBuild(a)) plant[0] = true;
                if (b !is null && f.circuitDef.CanBuild(b)) plant[1] = true;
            }
        }
        GenericHelpers::LogUtil("[LolCannon][Scouts] package: " + sent[0] + "/" + wanted[0] + " T1 (" + Alive(ordersT1) + " in production"
            + (plant[0] ? "" : ", no plant") + "), " + sent[1] + "/" + wanted[1] + " radar (" + Alive(ordersRadar) + " in production"
            + (plant[1] ? "" : ", no plant") + ")", 1);
        for (int kind = 0; kind < 2; ++kind)
            if (sent[kind] < wanted[kind] && !plant[kind]) OrderPlant(kind, plant[0]);
    }

    // Factory AiMakeTask (TECH): an idle finished plant that makes a kind still
    // missing builds one (b3: recruits queued from the tick were never taken up
    // by TECH's plants, whose handler only takes pending recruits for gantries).
    IUnitTask@ Produce(CCircuitUnit@ f)
    {
        if (Global::AISettings::Role != AiRole::TECH || f is null || f.circuitDef is null || !Busy() || f.GetBuildProgress() < 1.0f) return null;
        for (int kind = 1; kind >= 0; --kind) {   // the radar planes first: the slower ones
            array<IUnitTask@>@ orders = ordersT1;
            array<string> names = T1_DEFS;
            if (kind == 1) { @orders = ordersRadar; names = RADAR_DEFS; }
            if (wanted[kind] - sent[kind] - Alive(orders) <= 0) continue;
            for (uint n = 0; n < names.length(); ++n) {
                CCircuitDef@ d = ai.GetCircuitDef(names[n]);
                if (d is null || !f.circuitDef.CanBuild(d)) continue;
                if (d.maxThisUnit <= d.count + 1) d.maxThisUnit = d.count + 2;
                if (!d.IsAvailable(ai.frame)) continue;
                IUnitTask@ r = aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::FIREPOWER, Task::Priority::HIGH, d, f.GetPos(ai.frame), 64.0f));
                if (r is null) continue;
                orders.insertLast(r);
                return r;
            }
        }
        return null;
    }

    void Uncap(CCircuitDef@ d)
    {
        if (d !is null && d.maxThisUnit <= d.count) d.maxThisUnit = d.count + 1;
    }

    bool Pending(IUnitTask@ t) { return t !is null && !t.IsDead(); }

    void OrderPlant(int kind, bool hasT1Plant)
    {
        const string side = Global::AISettings::Side;
        const AIFloat3 at = Factory::GetPreferredFactoryPos();
        if (kind == 0 || !hasT1Plant) {
            if (Pending(plantT1)) return;
            Uncap(ai.GetCircuitDef(UnitHelpers::GetT1AirPlantForSide(side)));
            @plantT1 = Builder::EnqueueT1AirFactory(side, at, SQUARE_SIZE * 24, 120 * SECOND, Task::Priority::HIGH);
            GenericHelpers::LogUtil("[LolCannon][Scouts] no air plant: T1 air plant ordered " + (plantT1 is null ? "no (cooldown or unavailable)" : "yes"), 1);
            return;
        }
        if (Pending(plantT2)) return;
        CCircuitDef@ con = ai.GetCircuitDef(UnitHelpers::GetT1AirConstructorNameForSide(side));
        if (con !is null && con.count == 0 && !Pending(airCon)) {
            array<string>@ keys = Factory::allFactories.getKeys();
            for (uint i = 0; i < keys.length(); ++i) {
                CCircuitUnit@ f = null;
                if (!Factory::allFactories.get(keys[i], @f) || f is null || f.circuitDef is null || f.GetBuildProgress() < 1.0f
                    || !f.circuitDef.CanBuild(con)) continue;
                Uncap(con);
                @airCon = aiFactoryMgr.Enqueue(TaskS::Recruit(Task::RecruitType::BUILDPOWER, Task::Priority::HIGH, con, f.GetPos(ai.frame), 64.0f));
                break;
            }
        }
        Uncap(ai.GetCircuitDef(UnitHelpers::GetT2AirPlantForSide(side)));
        @plantT2 = Builder::EnqueueT2AirPlant(side, at, SQUARE_SIZE * 20, 300 * SECOND);
        GenericHelpers::LogUtil("[LolCannon][Scouts] no T2 air plant: ordered " + (plantT2 is null ? "no (cooldown or unavailable)" : "yes")
            + "; air constructors " + (con is null ? 0 : con.count) + (Pending(airCon) ? " (one ordered)" : ""), 1);
    }

    // Military AiMakeTask (TECH): a finished plane of a package still short flies its route.
    IUnitTask@ MilitaryTask(CCircuitUnit@ u)
    {
        if (Global::AISettings::Role != AiRole::TECH || u is null || u.circuitDef is null || !Busy() || u.GetBuildProgress() < 1.0f) return null;
        const int kind = Kind(u.circuitDef.GetName());
        if (kind < 0 || sent[kind] >= wanted[kind] || flights.exists("" + u.id)) return null;
        const int index = sent[0] + sent[1], total = wanted[0] + wanted[1];
        array<AIFloat3>@ route = LolCannonRecon::Route(u.GetPos(ai.frame), target, index, total, spread);
        CRouteTask@ task = cast<CRouteTask>(aiMilitaryMgr.Enqueue(TaskF::Route()));
        if (task is null) return null;
        task.SetAirControl(true);
        task.SetTraversal(true, 256, false);
        task.SetRoute(route);
        u.SetFireState(0);
        ++sent[kind];
        const AIFloat3 end = route[route.length() - 1];
        flights.set("" + u.id, @task);
        ends.set("" + u.id, end);
        deadlines.set("" + u.id, ai.frame + FlightSeconds * SECOND);
        GenericHelpers::LogUtil("[LolCannon][Scouts] unit=" + u.id + " def=" + u.circuitDef.GetName() + " to (" + int(route[0].x) + ","
            + int(route[0].z) + ")" + (route.length() > 1 ? " then (" + int(end.x) + "," + int(end.z) + ")" : "") + "; "
            + sent[0] + "/" + wanted[0] + " T1, " + sent[1] + "/" + wanted[1] + " radar sent", 1);
        return task;
    }

    // From LolCannon::Tick (1 s): orders while a package is short; planes at their
    // route's end, or out FlightSeconds, are let go.
    void Tick()
    {
        if (Global::AISettings::Role != AiRole::TECH) return;
        if (Busy()) Order();
        array<string>@ ids = flights.getKeys();
        for (uint i = 0; i < ids.length(); ++i) {
            CCircuitUnit@ u = ai.GetTeamUnit(parseInt(ids[i]));
            CRouteTask@ task; flights.get(ids[i], @task);
            AIFloat3 end; ends.get(ids[i], end);
            int deadline = 0; deadlines.get(ids[i], deadline);
            const bool on = u !is null && task !is null && !task.IsDead() && u.task is task;
            if (on && ai.frame < deadline && MapHelpers::SqDist(u.GetPos(ai.frame), end) > 256.0f * 256.0f) continue;
            if (on) u.SetFireState(u.circuitDef.GetFireState());
            flights.delete(ids[i]); ends.delete(ids[i]); deadlines.delete(ids[i]);
            if (task !is null && !task.IsDead()) task.Abort();
        }
    }
}
