# Commander command hierarchy and D-gun priority (analysis, nothing changed yet)

Prepared 2026-10-17 for Barscrewl. Source: Cent's newest **pushed** CircuitAI,
`S3KCentrifugal/CircuitAI` `codex/tech-recovery-production-fixes` `145910e7`
(`src/circuit/module/CommanderControl.cpp`, `CommanderT3.cpp`, `CommanderIntercept.cpp`,
`CommanderFallback.cpp`, `CommanderFront.cpp`, `CommanderWork.cpp`). The installed DLL (10-16-26-02)
is that commit plus Cent's **unpushed** C++ (FRONT recovery, en-route mex, detours, afus defence).
Evidence: last night's infolog (`BAR\lag-coastlines-2026-10-17-infolog.txt`, 4 games, 03:18-05:14 UTC).

## 1. Who gives the commander orders

| Source | When | How |
|--------|------|-----|
| Role scripts (FRONT/AIR/TECH/SUPPORT builder handlers, D-299 work ladder) | builder asks (idle / task done) | ordinary builder tasks |
| `CCommanderControl` (C++) | **every 3 frames per commander** (`Update`, line 405), and at once on damage (`Damaged`) | takes the unit with a `CCommanderTask`, then issues move / cloak / D-gun itself |
| Native retreat | low HP | `RETREAT` task |
| Player / external | any time | wins over everything |

`CCommanderControl` is the only place a D-gun is fired (`Fire`, `unit->DGunPosition`). Script cannot
fire it; script only sets the options in `config/experimental_balanced/commander.json`
(`commander.combat`) and `settings/shared/commander.as`.

## 2. De-facto priority inside one commander tick (`Tick`, CommanderControl.cpp:409)

1. `invalidated` (option change) -> abort, back to SUPPORT.
2. **Ownership guards**: player order, external control, enemy reclaim, morphing, being built,
   paralyzed, disarmed, transported -> hands the unit back, does nothing else.
3. Not owned and inside `retry` -> wait.
4. Airborne -> nothing.
5. `Observe`: enemies within `scan` (1000), their weapons/reload, friendlies; T3 out to
   `t3_hunt_leash` once a second.
6. **`Intercept` (T3 engagement, CommanderT3.cpp:130) - the first combat decision.** If it returns
   true the tick ends here.
7. Retreat fire state; 8. unseen-fire withdraw (shore only); 9. submerged-contact conceal.
10. **`Fallback`** (D-293 porc-line withdrawal from a strong group).
11. No enemy at all -> **`Deploy`** (FRONT walk to the front: the -02 detours live here) or resume work.
12. A pending shot: wait for it, time out after 30 frames.
13. **Ordinary D-gun lines** (non-T3): 5 stand points x up to 12 targets scored by `ScoreLine`
    (kills, value, friendly risk); fires only if `value >= min_value` (180) or emergency, D-gun ready
    and funded, and not endangered.
14. FRONT duty with no worthwhile shot -> `Deploy` again.
15. Escape / recover / retreat; 16. align or assess.

So a T3 is looked at first, but **inside `Intercept` survival and concealment outrank the shot**.

## 3. When a T3 in range is actually D-gunned (`Intercept`)

A target is the engaged T3, else the **nearest** in-LOS T3 within `t3_distance` (1000). One target at a
time. Before any shot it can be **declined** (handed to the fallback withdrawal) for:

| Reason | Condition |
|--------|-----------|
| `health` | commander HP below `t3_health` (20%) before the first shot |
| `unscreened` | not cloaked-and-safe, kill needs 3+ shots, under 300 metal of our units in the T3's reach |
| `funding` | energy < D-gun cost + moving-cloak upkeep x `escape_seconds` (4.3 s) |
| `detected` | **not "cloak-safe"** (any enemy within its decloak range + 32, **or any enemy radar covering the commander with no friendly jammer**) and still closing, or the exposure to every gun in range is not survivable |
| `no_hidden_station` | no reachable hidden waiting point and its current spot is not safe for 4.3 s |

Then it fires only if **all** of these hold (line 561):

- `requiredHit` - the lane hits this target;
- `confident` - crossing speed x flight time x 0.5 <= half the target's radius (**no shot at a unit
  crossing the lane**);
- `penetrates` - within D-gun range + radius - 24;
- `shotSafe` - incoming fire from **every** enemy in range during the shot + the T3's death blast
  leaves 20% HP;
- `surpriseStation` while cloaked - for `flank` plans the commander must be beside or behind the
  T3 (`front <= 0.5`), for `rear` behind it; only `hold` always passes;
- cloaked, or committed, or revealed-but-cleared.

After a kill the next T3 is a **new** engagement with 0 shots: the commander has just decloaked by
firing, so it fails `cloak-safe` and is declined as `detected` instead of firing again.

## 4. What happened with the Razorbacks (`armraz`)

From last night's log, 40 commander/Razorback engagements:

| Outcome | Count |
|---------|------:|
| declined `detected` | 619 |
| declined `funding` | 310 |
| waiting `position` (no shot) | 120 |
| `scout` (lost sight) | 58 |
| declined `no_hidden_station` | 31 |
| declined `health` | 14 |
| **fired** | **1** |

Plan for armraz: `approach=flank shots=1 commit=1 standoff ~200`. A Razorback dies to **one** D-gun,
yet the flank plan forbids a hidden shot until the commander is beside or behind it, the
`confident` rule forbids a shot at a Razorback walking across the lane, and every Razorback inside the
commander's decloak range or enemy radar makes it "detected". With four walking past in a column,
each one blocks the others: `detected` while they are close, `shotSafe` counts all four guns, and
after one shot the rest are declined. That matches what you saw: no shot until one bumped into it.

## 5. Detour orders (the lag)

The `[CommanderFront] unit=N detour` lines are new in the 10-16-26-02 DLL (0 in every earlier game,
6,700 / 5,800 / 18,500 in the three games since). One commander logged the same detour point every
3 frames (10 orders a second), i.e. every `Tick`. That code is in Cent's **unpushed** C++, so a
1-per-second throttle cannot be built until he pushes it. A local DLL from `145910e7` would drop his
new native functions and break the 10-16-26-02 scripts.

## 6. Proposed changes (for your decision)

Script / JSON now (no DLL):
- **S1.** `t3_profiles` in `experimental_balanced/commander.json`: `armraz` (and the other one-shot T3
  walkers) `approach: "hold"`: removes the flank/rear "be beside it first" gate.
- **S2.** Turn off FRONT commander recovery (`FrontRecovery`) in `main.as` until Cent fixes the
  detour rate (lag fix A).

DLL (needs Cent's pushed source, or Cent makes them):
- **D1. One-shot rule:** when the target dies to one D-gun (`remaining == 1`) and is inside
  `penetrates`, fire as soon as the lane hits it: skip `surpriseStation`, relax `confident`
  (the D-gun is volumetric along its flight), and count only that target's guns plus its death blast in
  `shotSafe`.
- **D2. Chain shots:** after a kill, a further one-shot T3 already inside range is fired at as a
  continuation (treated as committed), not declined as `detected`, while HP and energy allow.
- **D3. Funding priority:** keep energy for one D-gun ahead of cloak upkeep when a one-shot T3 is
  inside range (310 `funding` declines).
- **D4. Detour throttle:** re-issue a detour move at most once per second per commander, and only
  when the goal moved more than ~64 elmos.
