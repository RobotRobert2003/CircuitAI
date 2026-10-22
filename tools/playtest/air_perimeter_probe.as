// Supplied arena only. Compatible with pre-change pins; no gameplay decisions.
namespace AirPerimeterProbe {
    int frame=-100000;
    void Tick() {
        if (ai.frame-frame<10*SECOND) return;
        frame=ai.frame;
        int fighters=0,wall=0,ground=0,committed=0;
        const AIFloat3 anchor=AirScreen::Anchor(), enemy=AirScreen::Enemy(anchor);
        const bool advanceAlongX=abs(enemy.x-anchor.x)>=abs(enemy.z-anchor.z);
        float minimumCross=1.0e20f, maximumCross=-1.0e20f;
        array<Id>@ owned=ai.GetOwnedUnitIds();
        for (uint index=0;index<owned.length();++index) {
            CCircuitUnit@ unit=ai.GetTeamUnit(owned[index]);
            if (unit is null || !AirScreen::IsFighter(unit.circuitDef)) continue;
            ++fighters;
            if (AirOperations::Committed(unit.id)) ++committed;
            if (unit.task !is null && unit.task is AirBaseResponse::groups[2]) ++ground;
            CRouteTask@ route;
            if (AirScreen::routes.get(""+unit.id,@route) && route !is null && unit.task is route) {
                ++wall;
                const AIFloat3 position=unit.GetPos(ai.frame);
                const float cross=advanceAlongX ? position.z : position.x;
                minimumCross=AiMin(minimumCross,cross); maximumCross=AiMax(maximumCross,cross);
            }
        }
        AiLog("[AirPerimeterProbe] frame="+ai.frame+" team="+ai.teamId+" fighters="+fighters
            +" wall="+wall+" ground="+ground+" committed="+committed+" available="+AirOperations::AvailableFighters()
            +" physical_span="+(wall>0 ? maximumCross-minimumCross : 0.0f));
        for (uint index=0;index<AirScreen::groups.length();++index) {
            CRouteTask@ route=AirScreen::groups[index];
            if (route is null || route.IsDead()) continue;
            AiLog("[AirPerimeterSector] frame="+ai.frame+" team="+ai.teamId+" sector="+index
                +" version="+route.GetRouteVersion()+" points="+route.GetRouteSize());
        }
    }
}
