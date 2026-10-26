// T3 gantry lag fallback (owner, 2026-10-26).
#include "../../define.as"
#include "../../unit.as"
#include "../../global.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/spatial/map_helpers.as"
#include "../combat/edge_lanes.as"

/******************************************************************************

GANTRY FALLBACK

Late-game host lag can hold the AI's orders back for seconds. Two fallbacks
keep a T3 gantry useful while its orders are late; with orders arriving on
time nothing changes.

  repeat   u.SetLagRepeat(true) (RecruitTask::ExecuteLagRepeat): the engine
           repeats the gantry's last product until the AI's next order
           arrives. Every order still picks the unit: a repeated copy of the
           same def is adopted, another def is cancelled (its metal comes
           back) unless already half built, and a wait order turns repeat off.
  route    the gantry's waypoints are the route of its nearest edge lane:
           EdgeLanes::RallyFor on the left and right lanes, the one whose
           first rally is closer to the gantry. A unit with no order of its
           own walks that lane; the AI's orders replace it as usual.

Applied from Factory::AiMakeTask, once per gantry (the route is retried at
most every RouteRetrySeconds until both team and enemy starts give one).

******************************************************************************/
namespace GantryFallback {
    const int RouteRetrySeconds = 60;
    dictionary armed;       // gantry id -> true once SetLagRepeat was sent
    dictionary routed;      // gantry id -> true once its route was sent
    dictionary routeTried;  // gantry id -> last frame a route was computed

    // The unit a gantry's route must suit: its side's signature experimental
    CCircuitDef@ RouteDef(CCircuitUnit@ g)
    {
        const string name = g.circuitDef.GetName();
        string side = "armada";
        if (name.findFirst("cor") == 0) side = "cortex";
        else if (name.findFirst("leg") == 0) side = "legion";
        const string unitName = UnitHelpers::GetGantrySignatureUnitForSide(side);
        return (unitName.length() == 0) ? null : ai.GetCircuitDef(unitName);
    }

    // The nearer edge lane's route from the gantry; empty when neither has one
    array<AIFloat3> NearestLane(CCircuitUnit@ g, int &out side)
    {
        side = 0;
        array<AIFloat3> best;
        CCircuitDef@ d = RouteDef(g);
        if (d is null) return best;
        const AIFloat3 from = g.GetPos(ai.frame);
        float bestSq = 1.0e30f;
        for (int s = -1; s <= 1; s += 2) {
            array<AIFloat3> r = EdgeLanes::RallyFor(d, from, s);
            if (r.length() == 0) continue;
            const float sq = MapHelpers::SqDist(from, r[0]);
            if (sq < bestSq) { bestSq = sq; best = r; side = s; }
        }
        return best;
    }

    void Arm(CCircuitUnit@ g)
    {
        if (g is null || g.circuitDef is null || !UnitHelpers::IsGantryLab(g.circuitDef.GetName())) return;
        if (g.GetBuildProgress() < 1.0f) return;
        const string key = "" + g.id;
        if (Global::Spam::GantryLagRepeat && !armed.exists(key)) {
            g.SetLagRepeat(true);
            armed.set(key, true);
            GenericHelpers::LogUtil("[GantryFallback] gantry " + g.id + " repeats its last product between orders", 1);
        }
        if (!Global::Spam::GantryLaneRoute || routed.exists(key)) return;
        int tried = -1;
        if (routeTried.get(key, tried) && ai.frame - tried < RouteRetrySeconds * SECOND) return;
        routeTried.set(key, ai.frame);
        int side = 0;
        array<AIFloat3> route = NearestLane(g, side);
        if (route.length() == 0) return;
        g.CmdFactoryRoute(route);
        routed.set(key, true);
        GenericHelpers::LogUtil("[GantryFallback] gantry " + g.id + " waypoints: the " + EdgeLanes::Name(side)
            + " edge lane, " + route.length() + " points" + Spam::RouteText(route), 1);
    }

    void Forget(CCircuitUnit@ g)
    {
        if (g is null) return;
        const string key = "" + g.id;
        armed.delete(key);
        routed.delete(key);
        routeTried.delete(key);
    }
}  // namespace GantryFallback
