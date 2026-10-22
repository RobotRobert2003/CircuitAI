// Mirror of team coordination events to a local LuaUI widget.
#include "../../define.as"
#include "../../helpers/common/generic_helpers.as"

/******************************************************************************

WIDGET LINK

D-300. BAR's user-widget sandbox (BAR PRs #9547/#9658/#9660) stopped every
ai.CallUI message from reaching a user widget: RecvSkirmishAIMessage is an
engine callin the widget handler does not forward, and the getfenv(0) hook the
widget used (D-113) now lands in its own table. Widget -> AI still works.

So AI -> widget is now a state file the native side writes a short while after
changes (CWidgetState, src/circuit/util/WidgetState.h):
    <writeDir>/LuaUI/Config/BARb/state/team<N>.txt
and the host's widget polls it. It is eventually consistent (about 0.5-3 s of
wall time plus the widget's poll), local only like CallUI was, and never
reaches gadgets, other AIs or other players.

Every published line keeps the old wire form
"barb|<topic>|<senderTeamId>|<senderAllyTeamId>|<payload>", so the widget feeds
it to the same handler. Topics are split by how the widget uses them:
    state (latest value per key, rewritten only when it changes)
        roster      key "roster" (self) and "roster.<team>" (allies we relay)
        aggression  key "aggression"
        layout      key "layout": the planned base for the overlay, whole
                    (no 3000-byte chunks), only while the widget holds a lease
    events (bounded ring of the latest 64, with increasing ids)
        role (command replies), orphan, donation, ferry, spam, seaassist, draw
Lanes ("barbtheatre", lanes.as) are deliberately NOT mirrored: their payload is
large and recalculated often. They still use ai.CallUI and stay unavailable
under the sandbox (KI-617).
D-345: SEA lanes (sea_lanes.as) ARE published, as the state key "sealanes":
one compact line per factory, rebuilt only when a lane is recomputed.

tools/widgets/gui_barb_team_link.lua is the widget that displays them.

******************************************************************************/
namespace WidgetLink {
    bool Enabled = true;
    const string Prefix = "barb|";
    // Wall-clock coalescing of file writes (CWidgetState): write once changes
    // have been quiet for QuietMs, or MaxDelayMs after the first unwritten one.
    int QuietMs = 500;
    int MaxDelayMs = 3000;
    bool timingSent = false;

    string Line(const string &in topic, const string &in payload)
    {
        return Prefix + topic + "|" + ai.teamId + "|" + ai.allyTeamId + "|" + payload;
    }
    void Timing()
    {
        if (timingSent) return;
        timingSent = true;
        ai.SetWidgetStateTiming(QuietMs, MaxDelayMs);
    }
    void SetState(const string &in key, const string &in line)
    {
        if (!Enabled) return;
        Timing();
        ai.SetWidgetState(key, line);
    }

    void Send(const string &in topic, const string &in payload)
    {
        if (!Enabled) return;
        Timing();
        const string line = Line(topic, payload);
        if (topic == "roster") {
            // "self|roster|1|<team>|..." or "ally|roster|1|<team>|..."
            if (payload.findFirst("ally|") == 0) {
                array<string>@ f = payload.split("|");
                if (f.length() > 3) ai.SetWidgetState("roster." + f[3], line);
            } else {
                ai.SetWidgetState("roster", line);
            }
        } else if (topic == "aggression") {
            ai.SetWidgetState("aggression", line);
        } else {
            ai.PushWidgetEvent(line);
        }
    }
    // Local observation only: one feed for every role using native layouts.
    // Stop all serialization when hidden; renew the lease from the UI so a
    // removed widget cannot leave a permanent background polling workload.
    bool layoutOverlay = false;
    int layoutUntil = -1, layoutFrame = -1;
    string layoutLast;
    void SetLayoutOverlay(bool on, bool refresh = true)
    {
        const bool starting = on && !layoutOverlay;
        layoutOverlay = on;
        layoutUntil = ai.frame + 45 * SECOND;
        if (!on) { layoutLast = ""; layoutFrame = -1; SetState("layout", ""); return; }
        if (starting) { layoutLast = ""; layoutFrame = -1; }
        LayoutTick(starting || refresh);
    }
    void LayoutTick(bool force = false)
    {
        if (!layoutOverlay) return;
        if (ai.frame > layoutUntil) { SetLayoutOverlay(false); return; }
        if (!force && layoutFrame >= 0 && ai.frame - layoutFrame < 4 * SECOND) return;
        layoutFrame = ai.frame;
        const string snapshot = aiTerrainMgr.IsLayoutEnabled() ? aiTerrainMgr.DescribeLayout() : "";
        if (!force && snapshot == layoutLast) return;
        layoutLast = snapshot;
        // The native store skips an unchanged value, so a forced refresh of the
        // same plan costs no file write.
        SetState("layout", Line("layout", snapshot.length() == 0 ? "none" : snapshot));
    }
}
