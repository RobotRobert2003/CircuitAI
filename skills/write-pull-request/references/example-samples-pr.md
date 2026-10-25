# Worked example: the commander lane batch with a sample per feature (PR #26)

The description below was opened against `smrt-test` on 2026-10-24 as
[S3KCentrifugal/CircuitAI#26](https://github.com/S3KCentrifugal/CircuitAI/pull/26).
One commit, 80 files, five decisions (D-353 to D-357). The owner first asked
for the body to be "not verbose, with code samples", then for "more code
samples, at least one per feature explaining how it works", and called the
result "a good looking PR". The owner then asked "Will the Fatboy focus
commander targeting in this branch? And is it mentioned in the PR?": the body
had named `commander_priority` in a cell and a JSON sample without one
sentence on what it does, and its row's Played status covered only the other
lever. The version below is the corrected one; the note on the Fatboy rows
shows the correction. The annotations in `> note:` blocks explain the shape;
they were not part of the PR. The tables and the lead follow
[the batch example](example-batch-pr.md); what this example adds is section 3
of the skill, the sample per feature, and the lever audit.

## Title

```text
Commander batch: screen-led lane push with corridor mex capture, coverage lanes, immediate T3 shots, Thug/Mace poke
```

## Body

```markdown
Five decisions on the FRONT commander and its lane, in one commit: immediate in-range T3 shots (D-353), one terrain-distributed coverage corridor per FRONT seat (D-354), the post-opener lane push with Thug/Mace poke and the Fatboy press (D-355), and the 2026-10-24 review of that change set: a screen-led push with a home phase and every threshold as a profile lever (D-356), and FRONT commanders that advance by capturing the mexes in their corridor (D-357). Profile `experimental_balanced`; legacy profiles untouched. Built and Checked throughout; Played in the supplied arenas, the 38-case commander suite and natural Glacial/Supreme games. Not played in a natural mixed-role game; the performance comparison is contended.
```

> note: the lead still names count, pattern, profile and verification state.
> "Contended" is said here, not discovered in the performance paragraph.

```markdown
### 🎖️ FRONT commander lane push

| | Fix | Status |
|---|---|---|
| **Follows its screen, not the map** | The anchor leads the furthest corridor combat unit by `front_push_ahead` (600) and holds without `front_push_screen` (1) screens; `front_distance` (6000) and the enemy stand-off cap it. | ✅ Played: push fixture reaches 5366 lane elmos; six commanders advance on Supreme |
| **Captures corridor mexes on the way** | Rung `mex_lane` first: open spots within lane half-width + reach, from 400 behind to 600 ahead, never beyond the anchor nor within `front_mex_enemy_home` (1100) of an enemy start; enemy extractors are reclaimed first; one LLT per `front_mex_turret_every` (3). | ✅ Played: 9 mexes in lane order (push), 34 mexes and 5 turrets (Comet), 23 (Supreme) |
| **Home when riots appear** | `front_push_home_riot` (500 observed riot metal) or `front_push_until_seconds` ends the push for the game. | ✅ Played: 3 of 6 FRONT commanders latched in the 20-minute Supreme game |
| **Corridor is its mex territory** | Each FRONT broadcasts its corridor; every ally's mex ownership gives those clusters to it during the land window. `coverage/claim` disables. | 🟡 Built, Checked: rule unit-tested; corridors received in every game; allied constructor effect not observed |
| **Only listed roles leave home** | `advance_roles` (FRONT, TACTICAL); SEA, AIR, TECH, SUPPORT stay home; INV-236 checks duty against role. | ✅ Played: no INV-236 in 50+ games |
| **Ladder order is policy** | `front_ladder` names the rungs; repairs and reclaims finish before the walk; off-lane offers are declined, never aborted. | ✅ Played: line-work fallback, 2 line turrets, line complete |
| **Immediate T3 shot** (D-353) | A clear, funded, in-range T3 is shot at once; approach queues are retained one second. | ✅ Played: hold-to-T3 fixture kills the Behemoth at 13534; T3 matrix identical to baseline |
```

> note: seven rows, so seven samples follow, in row order. Each Fix cell names
> its lever with the balanced value in brackets; the sample then shows the
> lever being read.

````markdown
**Screen-led anchor.** A pure rule in `terrain/CommanderCombat.h`, unit-tested: with no screen the base falls to `own - pushAhead`, so the commander waits; INV-234 re-derives `bound` in Deploy.

```cpp
inline PushAnchor LanePushAnchor(float own, float furthestScreen, int screens, int screensNeeded,
                                 float pushAhead, float frontDistance, float limit) {
    out.screened = screensNeeded <= 0 || screens >= screensNeeded;
    const float base = screensNeeded <= 0 ? std::max(own, furthestScreen)
                     : (out.screened ? furthestScreen : own - pushAhead);
    out.bound    = std::min(frontDistance, base + pushAhead);
    out.progress = std::max(0.f, std::min(limit, out.bound));   // limit = lane length - stand-off
}
```
````

> note: the purest form available: a header function with a unit test, not
> the 40-line census loop that calls it. The one comment explains the input
> the reader cannot see.

````markdown
**Corridor mex sweep.** `LaneMexWork` asks the economy for the next open spot through an `accept` predicate. The window's far edge is the push anchor, so the sweep never leads the front.

```cpp
// CommanderWork.cpp: one predicate per offer, not per frame
return [=](const AIFloat3& p) {
    if (battle->GetFrontLaneDistance(p) > width) return false;            // half-width + build reach
    if (enemyHome > 0 && battle->EnemyEndDistance(p) < enemyHome) return false;
    const float progress = battle->GetFrontLaneProgress(p);
    if (progress < lo || progress > hi) return false;                      // own-400 .. min(own+600, anchor)
    const bool enemyOnSpot = !clb->GetEnemyUnitIdsIn(p, 64.f, false).empty();
    return !enemyOnSpot || (capture && threat->GetThreatAt(unit, p) <= frontThreat);
};
task = economy->EnqueueMexWithin(unit, pos, radius, 0, true, {}, accept);
```
````

> note: the predicate beats the function that installs it. The trailing
> comments translate `lo`, `hi` and `width` into the lever values from the
> Fix cell. The last line shows where the predicate goes, so the reader knows
> the economy owns admission.

````markdown
**Home latch.** Once latched the lane has no front for this commander; the base rungs keep it busy.

```cpp
bool CCommanderControl::PushHome(CCircuitUnit* unit, State& s, int frame) {
    if (s.pushHome || options.frontPushAhead <= 0) return s.pushHome;
    const float riot = enemies->GetEnemyCost(ROLE_TYPE(RIOT));        // observed metal in riot hulls
    if (options.frontPushHomeRiot > 0 && riot >= options.frontPushHomeRiot) reason = "riot";
    ...
    s.pushHome = true;  // for the game
}
```
````

> note: `...` marks the dropped time rule and the log line. The sample keeps
> the latch's two facts: what trips it and that it never resets.

````markdown
**Corridor as territory.** The script thins the lane and sends `corridor|1|team|halfWidth|x,z,...` to the roster; every ally feeds it to native ownership, where it is rule 2 of the resolve.

```cpp
// resource/MexTerritory.h: a published FRONT corridor beats the ground partition
if (in.corridor >= 0) {
    for (const auto& c : in.entrants) if (c.team == in.corridor && c.laneSpots) member = true;
    if (member && in.corridorForward) { out.rule = Rule::FORWARD; out.owner = -1; return out; }
    if (member)                       { out.rule = Rule::LANE;    out.owner = in.corridor; return out; }
}
```
````

> note: the message grammar goes in the sentence, the rule goes in the block.
> The script encoder and the message handler are left out; the reader who
> needs them has the file name.

````markdown
**Advance roles.** Script sets two options from the list; native refuses the pair the script must never produce.

```angelscript
// commander_combat.as
array<string>@ roles = aiSetupMgr.ConfigString("commander/combat/advance_roles", "FRONT,TACTICAL").split(",");
Option("advance", front ? 1.f : 0.f);                                        // this role is in the list
aiBuilderMgr.SetCommanderCombatOption("front_duty", (role == int(AiRole::FRONT) && front) ? 1.f : 0.f);
```
```cpp
if (options.frontDuty && !options.advance) { LOG("[INVARIANT] INV-236 ..."); return false; }
```
````

> note: a rule that spans script and native gets two blocks under one bold
> name: the policy that sets the options, then the native invariant that
> refuses the illegal pair. No prose between them.

````markdown
**Ladder.** One comma list in `commander.json`; each name maps to a native work kind, unknown names log once.

```angelscript
IUnitTask@ Rung(CCircuitUnit@ unit, const string &in name, ...) {
    if (name == "mex_lane") return aiBuilderMgr.CommanderFrontWork(unit, WORK_MEX_LANE, laser, 0.f);
    if (name == "advance")  return aiBuilderMgr.CommanderFrontWork(unit, WORK_ADVANCE, null, 0.f);
    if (name == "line")     return aiBuilderMgr.CommanderFrontWork(unit, WORK_LINE, laser, 0.f);
    ...
}
for (uint i = 0; i < ladder.length(); ++i) { IUnitTask@ t = Rung(unit, ladder[i], ...); if (t !is null) return t; }
```
````

> note: three of eighteen rungs are enough to show the mapping; `...` stands
> for the rest. The final line shows the first-non-null walk that makes the
> list order the policy.

````markdown
**Immediate T3 shot.** Checked before the retry and decline gates, so a target walking into reach is never delayed by an earlier rejected approach.

```cpp
if (options.t3ImmediateShot > 0 && pos.y >= 0.f && !unit->GetDGunAct()
    && unit->IsDGunReady(frame, energyCur - reserve)) {
    const auto line = commander::ImmediateT3Line(contacts, P(pos), unit->GetDGunRange() - 12,
                                                 projectile, width, options.killReward, options.friendlyMargin);
    if (line.target >= 0) { ... EndT3(unit, s, frame, "immediate_shot"); }
}
```
````

````markdown
```json
"front_ladder": "mex_lane,line,repair_defence,repair_units,reclaim,mex_los,timed_laser,timed_aa,radar,advance,assist,factory,mex,radar_spacing,laser,base,hold,patrol",
"advance_roles": "FRONT,TACTICAL",
"front_push_screen": 1, "front_push_ahead": 600, "front_push_home_riot": 500,
"front_mex_behind": 400, "front_mex_ahead": 600, "front_mex_turret_every": 3, "front_mex_enemy_home": 1100
```
````

> note: the area closes with its levers and the balanced values, so every
> number the samples' comments mention has a key the owner can change.

```markdown
### 🗺️ Coverage lanes and land micro

| | Fix | Status |
|---|---|---|
| **One corridor per FRONT seat** (D-354) | Lateral seats over a native quantile route; attack filters and objective advance read `coverage.json` (`advance`, `range_slack`, `base_radius`, `defend_follows_lane`). | ✅ Played: Supreme, Comet and sea coverage fixtures |
| **Thug and Mace poke** (D-355) | Reload, health and force-ratio poke bands; balanced keeps automatic fire off after the outmatched trials failed. | ✅ Played: both mirror arenas |
| **Fatboy presses T1 statics** (D-355) | `press_static` (1): an armed static at or below that tech level counts only with its death blast, so the Fatboy walks into HLT range instead of around it. | ✅ Played: fatboy-hlt-press |
| **Fatboy prefers a commander in range** (D-355) | `commander_priority` (8) multiplies the shot score of an identified enemy commander after range, line and admission checks. It reorders targets the Fatboy can already hit; it never moves the Fatboy toward one, and a radar dot has no def so gets no bonus. Only the Fatboy enables it. | 🟡 Built, Checked: no fixture places a commander in front of a Fatboy |
```

> note: the first version was one row, "`press_static` with
> `commander_priority`", status Played. The press was played; the commander
> preference was not, and nothing said what it did. Two rows, each with the
> lever explained (including what it does not do) and its own status.

````markdown
**Coverage lanes.** The seat picks its enemy-side destination by lateral share; the published lane becomes the front position for attack leaders, with the advance distance from JSON.

```angelscript
// coverage_lanes.as: seat rank/count -> destination -> native lane + lane ends
const float share = (float(rank) + .5f) / float(count);
const int destination = AiMin(int(enemies.length()) - 1, int(share * float(enemies.length())));
if (!aiBattle.SetFrontLane(Route(from, to, a, b, cls, share, count), halfWidth)) return;
aiBattle.ClearLaneEnds(); aiBattle.AddAllyEnd(Global::Map::StartPos); /* + each enemy start */
```
```cpp
// MilitaryManager.cpp FillFrontPos: defend tasks opt in through coverage.json
if (battle->GetFrontLaneLength() > 0.f && (!defend || battle->FrontLaneDefendFollows())) {
    const auto goal = battle->GetFrontLaneGoal(unit->GetPos(frame), battle->GetFrontLaneAdvance());
    if (terrain->CanReachAt(unit, goal, 64)) { outPositions.push_back(goal); return; }
}
```
````

> note: the script half shows who computes the lane, the native half shows
> who consumes it. Together they answer "where does the army go now".

````markdown
**Poke.** The local metal ratio picks a regime; the regime picks how deep and how often a hull steps into range.

```cpp
// terrain/GroundCohort.h (pure, unit-tested)
inline Poke PokeRegime(float own, float hostile, float ratio) {
    if (Dominant(own, hostile, ratio)) return Poke::PRESS;       // deep band until poke_press_health
    if (hostile >= own * ratio)        return Poke::OUTMATCHED;  // one trade per poke_pause_seconds
    return Poke::EVEN;                                           // one trade per reload above poke_health
}
```
```json
"poke_in": 0.95, "poke_in_dominant": 0.90, "poke_out": 1.05, "poke_ratio": 1.5,
"poke_health": 0.8, "poke_press_health": 0.5, "poke_pause_seconds": 5, "fire_at_will": false
```
````

> note: each regime's comment names the lever that governs it, and the
> `json` block beneath gives those levers their values. The 60-line
> engagement loop that applies the regime is not shown.

````markdown
**Fatboy press.** An armed static at or below the `press_static` tech level counts only with its death blast, so the Fatboy walks into HLT range instead of around it.

```cpp
// task/fighter/RangedWorld.h
static bool  Pressed  (const Contact& c, float press) { return press > 0.f && c.armed && !c.mobile && c.tech <= press; }
static float HazardFor(const Contact& c, float press) { return Pressed(c, press) ? c.explosionRadius : c.hazardRadius; }
```

**Commander preference.** The last multiplier in both ranged shot scorers; everything before it decided whether the shot is legal at all.

```cpp
// task/fighter/RangedEngagement.cpp: value already carries hit, cost, hysteresis, evasion
if (c.def && c.def->IsEnemyRoleAny(CCircuitDef::COMM)) value *= policy.commanderPriority;   // identified def only
```
```json
"ranged": { "target_mode": "skirmish", "press_static": 1, "commander_priority": 8, ... }
```
````

> note: two one-line helpers carry the whole press rule; the eleven call sites
> that pass `press` through are not the mechanism. The commander line is one
> line, but it is the sample that answers "does it hunt commanders": its
> position after admission and its `c.def` guard say no, and the sentence
> above it says why that position matters.

````markdown
### 🧪 Harness
- Coverage probe cases apply `commander_overrides` to every team; `coverage_loss_teams` scopes the commander-loss error.
- New cases: front push, hold, hold-to-T3, Comet/Supreme/sea coverage, T3 immediate, Thug/Mace mirrors, Fatboy press; line-work pins its front at 700 and expects timed turrets by 5 min.
- Fixtures that walk a commander with no army override `front_push_screen` to 0.

```json
"commander_overrides": { "front_push_screen": 0, "front_standoff": 1100 },
"coverage_probe": true, "coverage_loss_teams": [0]
```
````

> note: the harness sample is a case fragment, the keys as a fixture uses
> them, not an excerpt of the runner or the widget.

```markdown
### 📈 Performance (serial b11 → b03, `--allow-lobby`, natural horizon 20 min)
| | baseline | candidate |
|---|---|---|
| population-16 commands | 120 / 120 | 120 / 120 |
| dense-16 commands per minute | 341 / 713 | 425 / 332 |
| natural Glacial | INV-008 at 4.4 min | INV-001 at 10.9 min |
| natural Supreme | 20 min | INV-234 at 3.8 min, fixed in b04..b07 |

The owner's lobby was open, so the record is contended; run-to-run spread exceeds any difference and no CPU, FPS or network claim is made. On the final build b07 (`cafb359a`) natural Glacial ran its full 20 minutes with no invariant line and Supreme 18 minutes to a pre-existing TECH invariant.

### 📚 Docs
Decisions D-353 to D-357, invariants INV-233 to INV-236, register KI-661 to KI-667, the review ledger `reviews/2026-10-24-lane-review-fixes.md` and the script API reference live in `rjm.bar.docs/projects/circuitai` (commit a70afaf, local). Checkers at zero: `check_invariants`, `check_script_api` (also against the published DLL), `check_field_isolation`, `check_role_docs`; `check_doc_links` reports 46 pre-existing broken benchmark links and none new.

### ⚠️ Limits
- `coverage-front-supreme` loses one of six commanders about half the time at the isthmus melee; a fixture exposure of the unscreened override, recorded under KI-666.
- `commander-front-hold-t3` is flaky on its 2500-elmo lane (KI-667).
- No natural mixed-role game played: corridor territory among allies and the riot home latch are unobserved (KI-667).
- The 38-case suite keeps the eight baseline failures (KI-604, KI-637) and one harness stop fault (KI-663).
- Fatboy `commander_priority` is Built and Checked only: the three Fatboy cases place statics and Ticks, none an enemy commander (D-355).

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01CGSeSNUiQzsh3BHsb8L8W9
```

> note: the performance table admits a measurement that found a regression
> (INV-234 at 3.8 min) and names the builds that fixed it, rather than
> showing only the final build. The limits list the fixtures that still fail
> and the game that was never played.

## Counts

| | |
|---|---|
| table rows | 11 across two areas |
| fenced blocks | 17: eleven samples (three of them paired script and native), two area lever blocks, one harness fragment |
| sample length | 1 to 9 lines each |
| words in all | about 2,000; prose outside the fences under 650 |

The first version of this body had two samples and 847 words. The owner asked
for a sample per feature; the samples were cut from the source with grep and
`sed -n` at the head, not written from the session's memory. The second
version named a lever it did not explain; the lever audit in the skill's
"Create or update" section exists so the third version is the first one next
time.
