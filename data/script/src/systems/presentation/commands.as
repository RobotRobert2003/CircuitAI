// Commands from the local LuaUI widget (Spring.SendSkirmishAIMessage -> Main::AiLuaMessage).
#include "../../define.as"
#include "../../global.as"
#include "../../types/ai_role.as"
#include "../../types/role_config.as"
#include "../../helpers/common/generic_helpers.as"
#include "../../helpers/units/unit_helpers.as"
#include "../../helpers/roles/limits_helpers.as"
#include "../team/roster.as"
#include "widget_link.as"
#include "../construction/layout.as"
#include "../../helpers/combat/porc_helpers.as"
#include "../../helpers/spatial/layout_helpers.as"
#include "glyphs.as"
#include "../combat/aggression.as"

/******************************************************************************

WIDGET COMMANDS

Spring.SendSkirmishAIMessage(teamId, text) from unsynced Lua reaches this
instance as Main::AiLuaMessage(text) only when the AI runs on that machine
(CEngineOutHandler::SendLuaMessages walks the local skirmish AIs), so this is a
host-side console, never a network protocol. Lines are "barb|<command>|...":

    barb|query|<teamId>             answer with our roster line (WidgetLink topic "roster")
    barb|setrole|<teamId>|<ROLE>    switch this instance to ROLE at runtime
    barb|draw|<teamId>|commander    draw an Armada commander's outline across the map centre (map lines)
    barb|draw|<teamId>|credits      draw the credits (the contributors) across the map centre
    barb|draw|<teamId>|clear        erase every line this instance drew

The automatic match-start intro is disabled by default (IntroEnabled). Its
title, commander, warning and credits remain available through the draw commands.

Every command names the team it is meant for and is ignored by any other
instance: the engine already routes Spring.SendSkirmishAIMessage(teamId, ...)
to that team's AIs only, but a widget that hosts two ally teams in one process
must never be able to steer the wrong one through a broadcast (teamId -1).

RUNTIME ROLE SWITCH

A role is a RoleConfig of delegates that every native hook looks up on each
call through Global::profileController.RoleCfg, plus whatever its InitHandler
did to unit definitions at startup: maxThisUnit caps, SetIgnore flags and main
roles of factory defs. Switching therefore is:

  1. DefState::Restore  put every CCircuitDef back to the caps / ignore / main
                        role it had before the first InitHandler ran (snapshot
                        taken in Setup just before RoleConfigs::ApplyStartLimits)
  2. rebind             Global::AISettings::Role / RoleCfg and
                        Global::profileController.RoleCfg to the new RoleConfig
  3. init               RoleConfigs::ApplyStartLimits runs the new InitHandler
                        (quotas, ally range, caps, attributes, module inits)
  4. limits             merged map + role unit limits recomputed for the new role
  5. announce           roster re-announced so allies and the widget learn it

Everything touched is script-side data or engine-owned per-def values the roles
already write during normal play; no native object is created or destroyed, so
a switch cannot leave a dangling pointer. Units keep their current tasks and
pick up the new role's decisions as they ask for the next one. Role-local
progress flags (e.g. TECH's one-way eco thresholds) keep their values; that is
accepted, a switched-in role behaves as if those gates were already passed.
Switches are rate limited by SwitchCooldownFrames.

******************************************************************************/
namespace Commands {
    const string Prefix = "barb|";
    const int SwitchCooldownFrames = 10 * SECOND;
    int lastSwitchFrame = -1000000;

    // The native manager settings a role's InitHandler may change: captured once
    // at Setup, restored before the next role's InitHandler runs (CR-007).
    namespace NativeState {
        bool taken = false;
        float reclEnergyEff;
        bool assistNanoEnabled;
        float assistNanoIncomeMod;
        bool holdStartFactory;
        bool experimentalBuild;
        bool recoverConstruction;
        float experimentalDirectRange;
        float experimentalSearchRadius;
        bool autoStorageEnabled;
        bool reclaimOldConvertersAlways;
        uint quotaScout;
        float quotaAttack;
        float quotaAttackWait;
        float quotaAttackScale;
        float raidMin;
        float raidAvg;
        int porcMode;
        float porcBudgetMod;
        int porcAllyAA;
        void Snapshot()
        {
            if (taken) return;
            reclEnergyEff = aiEconomyMgr.reclEnergyEff;
            assistNanoEnabled = aiEconomyMgr.assistNanoEnabled;
            assistNanoIncomeMod = aiEconomyMgr.assistNanoIncomeMod;
            holdStartFactory = aiEconomyMgr.holdStartFactory;
            experimentalBuild = aiBuilderMgr.experimentalBuild;
            recoverConstruction = aiBuilderMgr.recoverConstruction;
            experimentalDirectRange = aiBuilderMgr.experimentalDirectRange;
            experimentalSearchRadius = aiBuilderMgr.experimentalSearchRadius;
            autoStorageEnabled = aiEconomyMgr.autoStorageEnabled;
            reclaimOldConvertersAlways = aiEconomyMgr.reclaimOldConvertersAlways;
            quotaScout = aiMilitaryMgr.quota.scout;
            quotaAttack = aiMilitaryMgr.quota.attack;
            quotaAttackWait = aiMilitaryMgr.quota.attackWait;
            quotaAttackScale = aiMilitaryMgr.quota.attackScale;
            raidMin = aiMilitaryMgr.quota.raid.min;
            raidAvg = aiMilitaryMgr.quota.raid.avg;
            porcMode = aiMilitaryMgr.porcMode;
            porcBudgetMod = aiMilitaryMgr.porcBudgetMod;
            porcAllyAA = aiMilitaryMgr.porcAllyAA;
            taken = true;
            GenericHelpers::LogUtil("[Commands] Native manager state snapshot taken", 3);
        }
        void Restore()
        {
            if (!taken) return;
            aiEconomyMgr.reclEnergyEff = reclEnergyEff;
            aiEconomyMgr.assistNanoEnabled = assistNanoEnabled;
            aiEconomyMgr.assistNanoIncomeMod = assistNanoIncomeMod;
            aiEconomyMgr.holdStartFactory = holdStartFactory;
            aiBuilderMgr.experimentalBuild = experimentalBuild;
            aiBuilderMgr.recoverConstruction = recoverConstruction;
            aiBuilderMgr.experimentalDirectRange = experimentalDirectRange;
            aiBuilderMgr.experimentalSearchRadius = experimentalSearchRadius;
            aiEconomyMgr.autoStorageEnabled = autoStorageEnabled;
            aiEconomyMgr.reclaimOldConvertersAlways = reclaimOldConvertersAlways;
            aiMilitaryMgr.quota.scout = quotaScout;
            aiMilitaryMgr.quota.attack = quotaAttack;
            aiMilitaryMgr.quota.attackWait = quotaAttackWait;
            aiMilitaryMgr.quota.attackScale = quotaAttackScale;
            aiMilitaryMgr.quota.raid.min = raidMin;
            aiMilitaryMgr.quota.raid.avg = raidAvg;
            aiMilitaryMgr.porcMode = porcMode;
            aiMilitaryMgr.porcBudgetMod = porcBudgetMod;
            aiMilitaryMgr.porcAllyAA = porcAllyAA;
            GenericHelpers::LogUtil("[Commands] Native manager state restored", 2);
        }
    }

    namespace DefState {
        bool taken = false;
        array<int> maxThis;
        array<bool> ignore;
        array<int> mainRole;

        // Setup calls this once, before any role InitHandler runs.
        void Snapshot()
        {
            if (taken) return;
            const int count = ai.GetDefCount();
            maxThis.resize(count + 1);
            ignore.resize(count + 1);
            mainRole.resize(count + 1);
            for (int id = 1; id <= count; ++id) {
                CCircuitDef@ d = ai.GetCircuitDef(Id(id));
                if (d is null) continue;
                maxThis[id] = d.maxThisUnit;
                ignore[id] = d.IsIgnore();
                mainRole[id] = int(d.GetMainRole());
            }
            taken = true;
            GenericHelpers::LogUtil("[Commands] Def state snapshot taken for " + count + " defs", 3);
        }

        void Restore()
        {
            if (!taken) return;
            const int count = ai.GetDefCount();
            int changed = 0;
            for (int id = 1; id <= count && id < int(maxThis.length()); ++id) {
                CCircuitDef@ d = ai.GetCircuitDef(Id(id));
                if (d is null) continue;
                if (d.maxThisUnit != maxThis[id]) { d.maxThisUnit = maxThis[id]; ++changed; }
                if (d.IsIgnore() != ignore[id]) { d.SetIgnore(ignore[id]); ++changed; }
                if (int(d.GetMainRole()) != mainRole[id]) { d.SetMainRole(Type(mainRole[id])); ++changed; }
            }
            GenericHelpers::LogUtil("[Commands] Def state restored, " + changed + " value(s) reverted", 2);
        }
    }

    // Returns true when the line was a command for us.
    bool Handle(const string &in data)
    {
        if (data.length() < Prefix.length() || data.substr(0, Prefix.length()) != Prefix) return false;
        array<string>@ parts = data.split("|");
        if (parts.length() < 3) return false;
        const string cmd = parts[1];
        // UI sends canonical decimal IDs. Prefix parsing would accept junk
        // such as "0bad" as team zero, including for the aggression control.
        if (parts[2] != "" + ai.teamId) {
            GenericHelpers::LogUtil("[Commands] Ignored command addressed to team " + parts[2] + ": " + data, 3);
            return true;
        }

        if (cmd == "theatres") { Lanes::RequestOverlay(parts.length() > 3 && parts[3] == "refresh"); return true; }
        if (cmd == "query") {
            Aggression::Announce();
            if (Team::Roster::IsReady()) {
                WidgetLink::Send("roster", "self|" + Team::Roster::Encode());
            } else {
                WidgetLink::Send("role", "?|not ready");
            }
            return true;
        }
        if (cmd == "setrole" && parts.length() >= 4) {
            SwitchRole(parts[3]);
            return true;
        }
        if (cmd == "aggression" && parts.length() == 4) {
            Aggression::SetDelta(parts[3]);
            return true;
        }
        // barb|draw|<team>|commander|clear : map drawing from the AI (owner's request, 2026-09-26)
        if (cmd == "draw" && parts.length() >= 4) {
            Draw(parts[3]);
            return true;
        }
        // barb|layout|<team>|on|off : push the planned base to the widget's overlay (D-053)
        if (cmd == "layout" && parts.length() >= 4) {
            WidgetLink::SetLayoutOverlay(parts[3] != "off", parts[3] == "on");
            return true;
        }
        GenericHelpers::LogUtil("[Commands] Unknown command: " + data, 2);
        return true;
    }

    // ---------------------------------------------------------------- map drawing
    // The AI's own map lines (Drawer::AddLine, as a player's map drawing: allies
    // and spectators see them). The engine erases a line whose START lies within
    // 100 elmos of an erase point (CInMapDrawModel::EraseNear), so every start is
    // kept and erased exactly: clear removes these lines and nothing else.
    // D-118: everything goes through the native queue (AiQueueLine / AiQueueErase),
    // which sends at most 20 items per batch, batches 100 ms of real time apart:
    // the game server drops a player's map-draw messages once more than 25 came
    // under 50 ms apart (played: 80 lines in one frame showed 25).
    // Text is lettering, not map pings: the outlines of BAR's typeface (Exo 2 Bold,
    // tools/draw/make_glyphs.py -> manager/glyphs.as), drawn as strokes with a
    // small repeatable wobble for a hand-drawn look.
    array<AIFloat3> drawnStarts;
    bool drawQueued = false;

    void QLine(const AIFloat3& in a, const AIFloat3& in b)
    {
        AiQueueLine(a, b);
        drawnStarts.insertLast(a);
        drawQueued = true;
    }

    // From Main::AiUpdate: logs the end of a drawing, then the intro's next step
    void DrawTick()
    {
        WidgetLink::LayoutTick();
        if (drawQueued && AiDrawQueueSize() == 0) {
            drawQueued = false;
            GenericHelpers::LogUtil("[Commands] map drawing complete: " + drawnStarts.length() + " stroke(s) on the map", 1);
            WidgetLink::Send("draw", "done|" + drawnStarts.length());
        }
        IntroTick();
    }

    // ---------------------------------------------------------------- the intro
    // Owner's request (2026-09-26): at game start the commander drawing with
    // "Do not spec cheat!" beneath it stays IntroHoldSeconds once drawn, is erased,
    // then a credits screen naming the contributors stays IntroHoldSeconds and is
    // erased. One instance draws it (skirmish AI 0), or every AI would. Map marks
    // made by a spectating host are seen by spectators; by a playing host, by its
    // allies and by spectators.
    bool IntroEnabled = false; // Keep the artwork and manual commands; skip the match-start intro.
    const int IntroStartFrame = 3 * SECOND;
    const int IntroHoldSeconds = 10;
    const int IntroCreditsPercent = 5;   // owner: the credits in 5% of games, rolled once a game
    int introStage = 0;   // 0 waiting, 1 drawing the commander, 2 holding, 3 erasing, 4 drawing the credits, 5 holding, 6 erasing, 7 done
    int introHoldUntil = 0;
    void IntroTick()
    {
        if (ai.skirmishAIId == 0 && (introStage >= 7 || !IntroEnabled) && AiIntroDoneFrame() < 0)
            AiMarkIntroDone(ai.frame);   // D-127: the other AIs draw their lanes after it
        if (!IntroEnabled || ai.skirmishAIId != 0 || introStage >= 7) return;
        const bool drawn = AiDrawQueueSize() == 0 && !drawQueued, erased = AiDrawQueueSize() == 0;
        switch (introStage) {
        case 0:
            if (ai.frame < IntroStartFrame) return;
            Draw("commander");
            introStage = 1;
            break;
        case 1:
            if (!drawn) return;
            introHoldUntil = ai.frame + IntroHoldSeconds * SECOND;
            introStage = 2;
            break;
        case 2:
            if (ai.frame < introHoldUntil) return;
            Draw("clear");
            introStage = 3;
            break;
        case 3:
            if (!erased) return;
            {
                const int roll = AiRandom(0, 99);
                if (roll >= IntroCreditsPercent) {
                    GenericHelpers::LogUtil("[Commands] intro done: the commander shown and erased; no credits this game (roll " + roll
                        + ", shown under " + IntroCreditsPercent + ")", 1);
                    introStage = 7;
                    break;
                }
                GenericHelpers::LogUtil("[Commands] the credits this game (roll " + roll + ", shown under " + IntroCreditsPercent + ")", 1);
            }
            Draw("credits");
            introStage = 4;
            break;
        case 4:
            if (!drawn) return;
            introHoldUntil = ai.frame + IntroHoldSeconds * SECOND;
            introStage = 5;
            break;
        case 5:
            if (ai.frame < introHoldUntil) return;
            Draw("clear");
            introStage = 6;
            break;
        case 6:
            if (!erased) return;
            introStage = 7;
            GenericHelpers::LogUtil("[Commands] intro done: the commander and the credits shown and erased", 1);
            break;
        }
    }

    // ---------------------------------------------------------------- lettering
    // A small, repeatable wobble (a hash of the point and a seed), so the same
    // text looks hand-drawn and its strokes' starts are known for the erase
    float Wobble(float x, float z, int seed)
    {
        const int h = (int(x * 7.0f) * 73856093) ^ (int(z * 11.0f) * 19349663) ^ (seed * 83492791);
        return float((h & 1023) - 512) / 512.0f;   // -1 .. 1
    }
    float TextWidthUnits(const string &in text)
    {
        float w = 0.0f;
        for (uint i = 0; i < text.length(); ++i) {
            const int g = Glyphs::CHARS.findFirst(text.substr(i, 1));
            if (g >= 0) w += float(Glyphs::DATA[Glyphs::START[g]]);
            else w += 300.0f;   // a space, or a character the table lacks
        }
        return w;
    }
    // `text` centred on (cx, baseline z), or starting at cx when `left`; cap height
    // `cap` elmos; returns its strokes.
    // `bold` parallel strokes each (owner: the text was hard to read): map lines
    // have one width (and the sender's colour), so a bold line is two side by side,
    // TextBoldOffset of the cap height apart
    const float TextBoldOffset = 0.035f;
    int DrawText(const string &in text, float cx, float baseZ, float cap, int seed, int bold = 2, bool left = false)
    {
        const float k = cap / 1000.0f;
        const float wob = cap * 0.018f;
        const float off = cap * TextBoldOffset;
        float x = left ? cx : cx - TextWidthUnits(text) * k * 0.5f;
        int strokes = 0;
        for (uint i = 0; i < text.length(); ++i) {
            const int g = Glyphs::CHARS.findFirst(text.substr(i, 1));
            if (g < 0) { x += 300.0f * k; continue; }
            int at = Glyphs::START[g];
            const float adv = float(Glyphs::DATA[at++]) * k;
            while (Glyphs::DATA[at] >= 0) {
                const int n = Glyphs::DATA[at++];
                AIFloat3 prev;
                for (int p = 0; p < n; ++p) {
                    const float px = x + float(Glyphs::DATA[at]) * k, pz = baseZ + float(Glyphs::DATA[at + 1]) * k;
                    at += 2;
                    const AIFloat3 q(px + Wobble(px, pz, seed) * wob, 0.0f, pz + Wobble(pz, px, seed + 1) * wob);
                    if (p > 0) {
                        // across the stroke: the unit normal, the copies spread around the line
                        const float dx = q.x - prev.x, dz = q.z - prev.z;
                        const float len = sqrt(dx * dx + dz * dz);
                        const float nx = (len > 0.0f) ? -dz / len : 0.0f, nz = (len > 0.0f) ? dx / len : 0.0f;
                        for (int b = 0; b < bold; ++b) {
                            const float s = (float(b) - float(bold - 1) * 0.5f) * off;
                            QLine(AIFloat3(prev.x + nx * s, 0.0f, prev.z + nz * s), AIFloat3(q.x + nx * s, 0.0f, q.z + nz * s));
                            ++strokes;
                        }
                    }
                    prev = q;
                }
            }
            x += adv;
        }
        return strokes;
    }
    // the cap height that fits `text` within `maxWidth` elmos, at most `cap`
    float FitCap(const string &in text, float cap, float maxWidth)
    {
        const float units = TextWidthUnits(text);
        if (units <= 0.0f) return cap;
        const float fit = maxWidth / units * 1000.0f;
        return (fit < cap) ? fit : cap;
    }

    // An Armada commander, front view, in a 100 x 134 box (y down, so north is
    // up on the map): polylines as x, y pairs, -1 ends one
    const array<float> COMMANDER = {
        40,8, 60,8, 64,14, 64,24, 58,28, 42,28, 36,24, 36,14, 40,8, -1,           // helmet
        40,16, 60,16, 58,21, 42,21, 40,16, -1,                                     // visor
        46,28, 46,32, -1, 54,28, 54,32, -1,                                        // neck
        30,32, 70,32, 72,50, 64,70, 36,70, 28,50, 30,32, -1,                       // torso
        42,40, 50,54, 58,40, -1, 46,48, 54,48, -1,                                 // chest chevron
        14,30, 30,30, 32,42, 14,44, 10,38, 14,30, -1,                              // shoulder (its right)
        70,30, 86,30, 90,38, 86,44, 68,42, 70,30, -1,                              // shoulder (its left)
        14,44, 22,44, 22,66, 14,66, 14,44, -1,                                     // nano-lathe arm
        12,66, 24,66, 24,74, 12,74, 12,66, -1, 18,74, 18,84, -1,                   // lathe and its beam
        78,44, 86,44, 86,60, 78,60, 78,44, -1,                                     // D-gun arm
        74,60, 92,60, 92,72, 74,72, 74,60, -1,                                     // D-gun body
        80,72, 86,72, 86,98, 80,98, 80,72, -1,                                     // D-gun barrel
        78,98, 88,98, 88,102, 78,102, 78,98, -1,                                   // muzzle
        36,70, 64,70, 66,78, 34,78, 36,70, -1,                                     // hips
        34,78, 48,78, 46,112, 36,112, 34,78, -1, 34,94, 48,94, -1,                 // leg and knee
        52,78, 66,78, 64,112, 54,112, 52,78, -1, 52,94, 66,94, -1,                 // leg and knee
        30,112, 50,112, 52,122, 28,122, 30,112, -1,                                // foot
        50,112, 70,112, 72,122, 48,122, 50,112, -1                                 // foot
    };

    // the queue's pace (items a batch, ms between batches; the server's flood guard
    // drops a player's map-draw messages once more than 25 came under 50 ms apart,
    // and under load it reads several batches at once: played at 10 fps, batches of
    // 20 lost strokes). Batches of 8 stay under 25 even three at a time: the
    // commander at a hand's pace (~60 strokes a second), the credits and every
    // erase ~120 a second.
    const int DrawHandBatch = 4, DrawHandMs = 55;
    const int DrawFastBatch = 8, DrawFastMs = 55;
    // owner: the credits at double the pace (16 a batch; played with intro_test)
    const int DrawCreditsBatch = 16, DrawCreditsMs = 55;
    const string TITLE = "SMRTBARb";   // owner: the title above the commander
    const string WARNING = "Do not spec cheat!";
    const string CREDITS_TITLE = "Contributors";
    const array<string> CREDITS = { "Lamer", "Centrifugal", "Felnious", "BarscrewlSports", "RobotRobert03", "ManBearPig", "iOS_Client" };

    void Draw(const string &in what)
    {
        if (what == "clear") {
            // what is still queued is never sent; what was sent is erased, paced
            AiDrawQueueClear();
            AiDrawPace(DrawFastBatch, DrawFastMs);
            // one erase a 50-elmo cell: every start in it lies within the engine's
            // 100-elmo erase radius of the first (the bold pairs share one)
            dictionary cells;
            int erases = 0;
            for (uint i = 0; i < drawnStarts.length(); ++i) {
                const string key = int(drawnStarts[i].x / 50.0f) + "_" + int(drawnStarts[i].z / 50.0f);
                if (cells.exists(key)) continue;
                cells.set(key, true);
                AiQueueErase(drawnStarts[i]);
                ++erases;
            }
            GenericHelpers::LogUtil("[Commands] map drawing: clearing " + drawnStarts.length() + " stroke(s) with " + erases + " erase(s)", 1);
            WidgetLink::Send("draw", "clear|" + drawnStarts.length());
            drawnStarts.resize(0);
            drawQueued = false;
            return;
        }
        if (what == "credits") {
            AiDrawPace(DrawCreditsBatch, DrawCreditsMs);
            DrawCredits();
            return;
        }
        if (what != "commander") {
            WidgetLink::Send("draw", "refused|unknown drawing " + what);
            return;
        }
        // owner: drawn a little slower, like a hand drawing it, a touch faster than one
        AiDrawPace(DrawHandBatch, DrawHandMs);
        // the title above, the commander 75% of the map's shorter side tall (less
        // when the three would not fit the map's height), the warning beneath it,
        // the whole centred on the map
        const float w = float(AiTerrainWidth()), h = float(AiTerrainHeight());
        const float side = (w < h) ? w : h;
        const float titleCap = FitCap(TITLE, side * 0.09f, w * 0.85f);
        const float cap = FitCap(WARNING, side * 0.07f, w * 0.85f);
        float scale = side * 0.75f / 134.0f;
        const float room = (h * 0.94f - titleCap * 1.6f - cap * 1.6f) / 122.0f;
        if (room < scale) scale = room;
        const float total = titleCap * 1.6f + 122.0f * scale + cap * 1.6f;
        const float top = h * 0.5f - total * 0.5f;
        const int title = DrawText(TITLE, w * 0.5f, top + titleCap, titleCap, 5);
        const float ox = w * 0.5f - 50.0f * scale, oz = top + titleCap * 1.6f;
        int lines = 0;
        bool have = false;
        AIFloat3 prev;
        for (uint i = 0; i < COMMANDER.length(); ) {
            if (COMMANDER[i] < 0.0f) { have = false; ++i; continue; }
            const AIFloat3 p(ox + COMMANDER[i] * scale, 0.0f, oz + COMMANDER[i + 1] * scale);
            i += 2;
            if (have) { QLine(prev, p); ++lines; }
            prev = p;
            have = true;
        }
        const int text = DrawText(WARNING, w * 0.5f, oz + 122.0f * scale + cap * 1.6f, cap, 7);
        GenericHelpers::LogUtil("[Commands] map drawing: \"" + TITLE + "\" (" + title + " strokes), an Armada commander (" + lines + " strokes, " + int(122.0f * scale) + " elmos tall) and \""
            + WARNING + "\" (" + text + " strokes, cap " + int(cap) + " elmos), centred at (" + int(w * 0.5f) + ", " + int(h * 0.5f) + ")", 1);
        WidgetLink::Send("draw", "commander|" + (title + lines + text));
    }

    // The credits (owner's layout): the top left of the map in the default view
    // (north up), left-aligned: "Contributors" underlined, one name a line beneath
    void DrawCredits()
    {
        const float w = float(AiTerrainWidth()), h = float(AiTerrainHeight());
        const float side = (w < h) ? w : h;
        const float left = w * 0.05f, top = h * 0.05f;
        const float maxWidth = w * 0.6f;
        const float titleCap = FitCap(CREDITS_TITLE, side * 0.08f, maxWidth);
        const float titleBase = top + titleCap;
        int strokes = DrawText(CREDITS_TITLE, left, titleBase, titleCap, 11, 2, true);
        // the underline, the title's width, a little below its baseline
        const float titleWidth = TextWidthUnits(CREDITS_TITLE) * titleCap / 1000.0f;
        const float lineZ = titleBase + titleCap * 0.35f;
        QLine(AIFloat3(left, 0.0f, lineZ), AIFloat3(left + titleWidth, 0.0f, lineZ));
        QLine(AIFloat3(left, 0.0f, lineZ + titleCap * TextBoldOffset), AIFloat3(left + titleWidth, 0.0f, lineZ + titleCap * TextBoldOffset));
        strokes += 2;
        // the names: one size for all, the widest fitting, 1.7 caps apart
        float nameCap = side * 0.05f;
        for (uint i = 0; i < CREDITS.length(); ++i) {
            const float c = FitCap(CREDITS[i], nameCap, maxWidth);
            if (c < nameCap) nameCap = c;
        }
        float z = lineZ + titleCap * 0.4f;
        for (uint i = 0; i < CREDITS.length(); ++i) {
            z += nameCap * 1.7f;
            strokes += DrawText(CREDITS[i], left, z, nameCap, 13 + int(i), 2, true);
        }
        GenericHelpers::LogUtil("[Commands] map drawing: the credits (" + CREDITS.length() + " contributors, " + strokes + " strokes) queued, top left", 1);
        WidgetLink::Send("draw", "credits|" + strokes);
    }

    void _Reply(const string &in roleName, const string &in status)
    {
        WidgetLink::Send("role", roleName + "|" + status);
    }

    void SwitchRole(const string &in roleName)
    {
        const string current = Team::Roster::RoleName(Global::AISettings::Role);
        if (!Global::Map::MapResolved || Global::profileController is null) {
            _Reply(current, "refused: not initialised yet");
            return;
        }
        const AiRole role = Team::Roster::RoleFromName(roleName);
        if (Team::Roster::RoleName(role) != roleName) {
            _Reply(current, "refused: unknown role " + roleName);
            return;
        }
        if (role == Global::AISettings::Role) {
            _Reply(current, "already " + current);
            return;
        }
        if (ai.frame - lastSwitchFrame < SwitchCooldownFrames) {
            _Reply(current, "refused: cooldown");
            return;
        }
        RoleConfig@ cfg = RoleConfigs::Get(role);
        if (cfg is null) {
            _Reply(current, "refused: no RoleConfig registered for " + roleName);
            return;
        }
        if (!DefState::taken) {
            _Reply(current, "refused: no def snapshot (setup incomplete)");
            return;
        }

        GenericHelpers::LogUtil("[Commands] Role switch " + current + " -> " + roleName + " requested by widget", 1);
        // Leave: the old role's layout (reservations, zones, the native flag)
        // and the native manager settings its InitHandler changed (CR-007).
        if (Global::AISettings::Role == AiRole::AIR) AirBuild::Leave();
        if (Global::AISettings::Role == AiRole::SEA) SeaBuild::Leave();
        if (Global::AISettings::Role == AiRole::TECH) TechChain::LeaveNukeOpening();
        aiBuilderMgr.ClearBuildRadii();
        aiBuilderMgr.ClearReclaimProtected();   // D-290: the incoming role's InitHandler sets its own
        if (Global::AISettings::Role == AiRole::SUPPORT) {
            TechChain::active = false;
            TechChain::done = false;
            TechChain::objective = "eco";
        }
        if (Global::AISettings::Role == AiRole::FRONT) FrontOpener::Close();
        // Layout reset clears named native state. Keep the one-time opener
        // markers through role changes so a later reload cannot repeat it.
        const bool openerScoutQueued = FrontOpener::WasQueued("scout");
        const bool openerBatchQueued = FrontOpener::WasQueued("batch");
        Layout::OnRoleLeave();
        if (openerScoutQueued) FrontOpener::MarkQueued("scout");
        if (openerBatchQueued) FrontOpener::MarkQueued("batch");
        TechWeapons::OnRoleLeave();   // D-126
        EcoFlak::Clear();
        Lanes::OnRoleLeave();         // D-127
        NativeState::Restore();
        DefState::Restore();

        Global::AISettings::Role = role;
        Global::Map::StartRole = role;
        @Global::AISettings::RoleCfg = cfg;
        @Global::profileController.RoleCfg = cfg;
        RoleConfigs::ApplyStartLimits();   // runs the incoming InitHandler

        dictionary@ merged = LimitsHelpers::ComputeAndStoreMergedUnitLimits(Global::Map::Config, role);
        UnitHelpers::ApplyUnitLimits(merged);

        // Enter: the incoming role's porc chain and layout plan, as Setup does.
        PorcHelpers::ApplyForRole();
        LayoutHelpers::ApplyForRole();

        lastSwitchFrame = ai.frame;
        Team::Roster::Reannounce();
        GenericHelpers::LogUtil("[Commands] Role switch complete: now " + roleName, 1);
        _Reply(roleName, "ok");
    }
}  // namespace Commands
