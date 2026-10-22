#include "../../define.as"

namespace ArtilleryPolicy {
    const array<string> ForbiddenT1 = {"armguard", "corpun", "legcluster"};
    const array<string> SuperCannons = {"armvulc", "corbuzz", "legstarfall"};
    dictionary celebrated;
    int lastCheckWarning = -100000;

    void Check()
    {
        for (uint i = 0; i < ForbiddenT1.length(); ++i) {
            CCircuitDef@ d = ai.GetCircuitDef(ForbiddenT1[i]);
            if (d !is null && d.IsBuildAllowed() && ai.frame - lastCheckWarning >= 60 * SECOND) {
                lastCheckWarning = ai.frame;
                const string invariant = "INV-069";
                AiLog("[INVARIANT] " + invariant + " T1 static artillery construction veto missing: " + ForbiddenT1[i]);
            }
        }
    }

    void Fired(CCircuitUnit@ unit, const AIFloat3& in aim)
    {
        if (unit is null || unit.circuitDef is null) return;
        const string name = unit.circuitDef.GetName();
        if (SuperCannons.find(name) < 0 || celebrated.exists("" + unit.id)) return;
        if (!aiSetupMgr.ConfigBool("weapons/celebration/enabled", true)) return;
        // The event proves a shot happened. A missing task aim falls back to
        // the firing cannon, never fabricates an enemy position.
        const AIFloat3 at = (aim.x >= 0.0f && aim.z >= 0.0f) ? aim : unit.GetPos(ai.frame);
        const float cap = AiMin(float(AiMin(AiTerrainWidth(), AiTerrainHeight())) * 0.2f,
            AiMax(40.0f, AiMin(500.0f, aiSetupMgr.ConfigFloat("weapons/celebration/letter_height", 220.0f))));
        const float x = AiMax(cap * 1.1f, AiMin(float(AiTerrainWidth()) - cap * 1.1f, at.x));
        const float z = AiMax(cap * 0.6f, AiMin(float(AiTerrainHeight()) - cap * 0.6f, at.z));
        celebrated.set("" + unit.id, true);
        // Lowercase l-o-l, doubled for legibility. Use the nuke's paced queue,
        // not the intro's erase list; sustained salvos enqueue this only once.
        for (int bold = 0; bold < 2; ++bold) {
            const float offset = float(bold) * cap * 0.025f;
            for (int side = -1; side <= 1; side += 2) {
                const float lx = x + float(side) * cap * 0.8f + offset;
                AiQueueLine(AIFloat3(lx, 0, z-cap*0.5f), AIFloat3(lx, 0, z+cap*0.5f));
                AiQueueLine(AIFloat3(lx, 0, z+cap*0.5f), AIFloat3(lx+cap*0.2f, 0, z+cap*0.5f));
            }
            for (int i = 0; i < 12; ++i) {
                const float a = float(i) * 6.2831853f / 12.0f, b = float(i+1) * 6.2831853f / 12.0f;
                AiQueueLine(AIFloat3(x+offset+cos(a)*cap*0.3f, 0, z+cap*0.2f+sin(a)*cap*0.3f),
                    AIFloat3(x+offset+cos(b)*cap*0.3f, 0, z+cap*0.2f+sin(b)*cap*0.3f));
            }
        }
        AiLog("[Artillery] " + name + " " + unit.id + " fired: lol at (" + int(x) + ", " + int(z) + "), 32 strokes");
    }

    void Removed(CCircuitUnit@ unit)
    {
        if (unit !is null) celebrated.delete("" + unit.id);
    }
}
