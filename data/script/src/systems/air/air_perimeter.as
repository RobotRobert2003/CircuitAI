#include "../../helpers/math/air_perimeter_math.as"

// Geometry belongs to one AIR instance. Fixed sectors retain their native patrol
// tasks. O(vertices*samples) cached LOS reads, plus O(sectors) corridor checks;
// corridor cost depends on crossed threat cells and known AA, not fighter count.
// Stable routes produce no orders (CRouteTask::SetRoute exact equality). Regression:
// air-perimeter arena and tests/air_perimeter_math_tests.as. Reset owns invalidation.
namespace AirPerimeter {
    array<float> advances, previousAdvances;
    array<AIFloat3> vertices;
    float lastProgress = -1;
    AIFloat3 lastAnchor;
    bool lastAxis = false;
    float lastDirection = 0;
    float span = 0;
    int plannedFrame = -100000;
    float Inset() {
        // CorridorThreat rejects capsules extending beyond the map. Keep the
        // whole capsule inside, otherwise edge sectors falsely retreat forever.
        return AirPerimeterMath::SafeInset(Global::RoleSettings::Air::ScreenMapInset,
            Global::RoleSettings::Air::ScreenThreatPadding);
    }

    AIFloat3 Point(bool alongX, float direction, float origin, float advance, float cross) {
        const float inset = Inset();
        const float extent = alongX ? float(AiTerrainWidth()) : float(AiTerrainHeight());
        const float forward = AirPerimeterMath::Bound(origin+direction*advance,inset,extent-inset);
        return alongX ? AIFloat3(forward,0,cross) : AIFloat3(cross,0,forward);
    }
    void Plan(const AIFloat3 &in anchor, const AIFloat3 &in enemy, int fighters, int cells) {
        const bool alongX = abs(enemy.x-anchor.x) >= abs(enemy.z-anchor.z);
        const float origin = alongX ? anchor.x : anchor.z;
        const float direction = (alongX ? enemy.x-anchor.x : enemy.z-anchor.z) >= 0 ? 1.0f : -1.0f;
        const float crossAnchor = alongX ? anchor.z : anchor.x;
        const float extent = alongX ? float(AiTerrainHeight()) : float(AiTerrainWidth());
        const int strength = AiMin(Global::RoleSettings::Air::ScreenFullFighters,fighters/4*4);
        const float progress = ProductionMath::Progress(strength,4,Global::RoleSettings::Air::ScreenFullFighters);
        const float distance = abs(alongX ? enemy.x-anchor.x : enemy.z-anchor.z);
        const float limit = AiMax(0.0f,distance*.5f-Global::RoleSettings::Air::ScreenFrontSetback);
        const float rear = AiMin(limit,Global::RoleSettings::Air::ScreenRearAdvance);
        const int samples = AiMax(1,AiMin(64,Global::RoleSettings::Air::ScreenVisibilitySamples));
        const bool same = vertices.length()==uint(cells+1) && progress==lastProgress && alongX==lastAxis
            && direction==lastDirection && MapHelpers::SqDist(anchor,lastAnchor)<1;
        // Birth callbacks may ask several times in one response interval. A new
        // member of an unchanged sector uses its existing patrol; contacts are
        // still reconsidered by AirScreen at the normal interception cadence.
        if (same && ai.frame-plannedFrame<Global::RoleSettings::Air::InterceptUpdateSeconds*SECOND) return;
        plannedFrame=ai.frame;
        advances.resize(cells+1); vertices.resize(cells+1); previousAdvances.resize(cells+1);
        for (int index=0;index<=cells;++index) {
            previousAdvances[index]=advances[index];
            const float cross = AirPerimeterMath::CrossCoordinate(crossAnchor,extent,
                Inset(),Global::RoleSettings::Air::ScreenRearWidth,progress,float(index)/cells);
            float visible = rear;
            // Read the existing legal ally LOS publication, not unit callbacks
            // or spectator visibility. Radius zero is a single cached grid cell.
            for (int sample=1;progress>0 && sample<=samples;++sample) {
                const float advance = rear+(limit-rear)*float(sample)/samples;
                const AIFloat3 point = Point(alongX,direction,origin,advance,cross);
                if (AirHome::Friendly(point) && aiTerrainMgr.IsAreaVisible(point,0)) visible=advance;
            }
            float wanted = rear+(AiMax(rear,visible-Global::RoleSettings::Air::ScreenFogSetback)-rear)*progress;
            wanted = AirPerimeterMath::StableAdvance(advances[index],wanted,
                Global::RoleSettings::Air::ScreenAdvanceHysteresis,same);
            advances[index]=wanted;
            vertices[index]=Point(alongX,direction,origin,wanted,cross);
        }
        // Test final patrol corridors, not just endpoints. Known AA can force
        // immediate retreat even while sight-history retains the forward line.
        // Shared vertices keep the wall joined; pull both ends of a threatened
        // sector back before committing routes. Never dispatch trial positions.
        const float retreatStep=AiMax(128.0f,Global::RoleSettings::Air::ScreenDangerRetreatStep);
        // Each repair strictly reduces one of a finite number of vertex depths.
        // Recheck the preceding segment when a shared endpoint moves: otherwise
        // bending away from AA in one sector can drag its neighbour across AA.
        const int repairBudget=(cells+1)*(2+int((limit+Global::RoleSettings::Air::ScreenRearAdvance)/retreatStep))*3;
        int sector=0;
        for (int check=0;sector<cells && check<repairBudget;++check) {
            if (aiBattle.AirThreatAlong(vertices[sector],vertices[sector+1],
                Global::RoleSettings::Air::ScreenThreatPadding)<1.0f) { ++sector; continue; }
            // Prefer the previous contour when only a proposed advance is unsafe.
            // Otherwise changing LOS samples shift the retreat grid's origin and
            // churn safe patrols even against stationary AA. Reuse O(vertices)
            // scratch; validate the retained corridor again before accepting it.
            // Regression: unsafe-advance math test and air-perimeter-safety arena.
            float first=AirPerimeterMath::RejectUnsafeAdvance(previousAdvances[sector],advances[sector],same);
            float second=AirPerimeterMath::RejectUnsafeAdvance(previousAdvances[sector+1],advances[sector+1],same);
            if (first==advances[sector] && second==advances[sector+1]) {
                first=AiMax(-Global::RoleSettings::Air::ScreenRearAdvance,advances[sector]-retreatStep);
                second=AiMax(-Global::RoleSettings::Air::ScreenRearAdvance,advances[sector+1]-retreatStep);
            }
            // An AA-covered home has no safe rear solution; retain home defense
            // rather than cycling forever. Interception still owns live threats.
            if (first==advances[sector] && second==advances[sector+1]) { ++sector; continue; }
            advances[sector]=first; advances[sector+1]=second;
            vertices[sector]=Point(alongX,direction,origin,first,alongX ? vertices[sector].z : vertices[sector].x);
            vertices[sector+1]=Point(alongX,direction,origin,second,alongX ? vertices[sector+1].z : vertices[sector+1].x);
            sector=AiMax(0,sector-1);
        }
        span=abs(alongX ? vertices[cells].z-vertices[0].z : vertices[cells].x-vertices[0].x);
        lastProgress=progress; lastAnchor=anchor; lastAxis=alongX; lastDirection=direction;
    }
    void Reset() { advances.resize(0); previousAdvances.resize(0); vertices.resize(0); lastProgress=-1; plannedFrame=-100000; }
}
