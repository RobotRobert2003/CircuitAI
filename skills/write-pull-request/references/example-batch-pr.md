# Worked example: the behaviour fix batch (PR #9)

The description below was merged into `smrt-test` on 2026-10-14 as
[S3KCentrifugal/CircuitAI#9](https://github.com/S3KCentrifugal/CircuitAI/pull/9).
It covered 67 commits, 96 files and ten separate behaviour fixes, and the owner
accepted it without asking for changes to the write-up. The annotations in
`> note:` blocks explain why each part is shaped the way it is; they were not
part of the PR.

## Title

```text
Behaviour fix batch: TECH heavies/gantries/turrets/reclaim, AIR escorts/fusions, Legion build power, Fatboy/Starlight/scouts
```

> note: 118 characters, slightly over the budget, but every area is named so
> the reader knows the scope from the PR list alone. Unit names are the game's.

## Body

```markdown
## Behaviour fix batch (D-287 – D-298)

Ten owner-reported unit-behaviour issues, fixed as AngelScript policy with small native levers, each with an invariant, a playtest case and a decision record. All ten are verified in play on the published build. Primary profile `experimental_balanced`; legacy profiles untouched.
```

> note: the lead gives count, shared pattern, verification state, profile scope.
> A reader who stops here knows whether to merge.

```markdown
### 🏭 TECH
| | Fix | Status |
|---|---|---|
| **No late-game Marauders** | After a one-way "late" latch (20 min or 400 M/s), gantries build the terrain's heavy: Thor / Karganeth / Railtank on land, Titan / Juggernaut-class on maps with assault beaches. Per-faction, all settings. | ✅ Played: 10 Titans, 0 Marauders (Supreme); 8 Thors (Glitters) |
| **One gantry per 500 M/s** | `TechGantryScale` owns the target = ⌊income/500⌋ (cap 6, rising-only, hysteresis). Refusal reasons are logged; INV-199 names the blocking gate and the unit budget. | ✅ Played: target 1 → 2 → second gantry → income drop, no target 3 |
| **Turrets assist the factory** | One turret ladder: priority frames in reach → factory assist (guard / repair) → repair → wait. Energy-stall veto is an off-by-default lever. | ✅ Played: factory assist at 6.5 min (was 13.3), INV-200 silent |
| **Reclaim policy** | `TechReclaim::Allowed`: energy storage is never reclaimed (script + native protected-def set), any reclaim must fit the bank (defers, pauses the T2-lab retire), `[RECLAIM]` audit names the path. Heavy-rush lab protection kept. | ✅ Played: both reclaim checks pass |
```

> note: first column is the owner's own phrasing of the complaint, turned into
> the outcome. The Fix column names the lever (`TechGantryScale`, the veto) so
> the owner knows where to tune. Status carries a number and its baseline
> ("6.5 min (was 13.3)").

```markdown
### ✈️ AIR
| | Fix | Status |
|---|---|---|
| **Escorts scout after a wiped run** | When every launched bomber of an offensive run is dead, the surviving escorts (T1 + T2 fighters only) fan out across the enemy rear on spaced, AA-avoiding points, then return to the screen. | ✅ Played: wipe → fan → scout → return in both arenas (AA sector avoided) |
| **Fusions honour the base layout** | Ordinary fusion is a layout-module kind (reserved ahead, saved, 45 s field-site fallback logged). | ✅ Played: every fusion on a module in a 16-AI game |

### 🛠️ SUPPORT (Legion)
| | Fix | Status |
|---|---|---|
| **No Infestor build power** | Removed from the lab lottery, `limit: 0`; combat batches counted by role. SUPPORT uses constructors, the combat engineer and construction turrets. | ✅ Played: 0 Infestors (baseline built 2) |

### ⚔️ Land units
| | Fix | Status |
|---|---|---|
| **Fatboys ignore Ticks** | Ranged policy `avoid_categories` (GROUNDSCOUT) + `evasion_limit`. Radar dots stay valid blind-fire targets (artillery + radar pair by design); only identified Ticks and dots moving too fast to hit are skipped. | ✅ Played: 0 Tick shots (baseline fired at 52 s); blind fire at LLT radar dots within 1 s of detection |
| **Starlights help attacking allies** | `assist_radius`: with no legal shot, advance behind an allied screen to a safe firing site on an allied-engaged contact; target hysteresis stops retarget churn. | ✅ Played: both assist arenas pass; INV-206 32 → 0 |
| **Scouts raid the backline** | `ScoutRaid` (non-spam scouts): mex / wind / nano targets in the rear, hazard-aware routes on the shared lane grid, radar dots painted as hazards, wrap-around replans, 6 raiders, 2 solves/s. | ✅ Played: 10 / 10 / 9 economy kills (Armada / Cortex / Legion) with 3 / 0 / 1 raiders lost, detouring around an LLT line |
```

> note: the Fatboy row records the owner's review correction in the open
> ("Radar dots stay valid blind-fire targets"). The first draft had said "no
> blind shots at radar dots"; the owner objected, the rule was changed, and
> the row was rewritten to say what the shipped rule is and why.

```markdown
### 🧪 Harness
- Watcher stops a **decided game** (one AI alliance left) instead of running to `stop_minute`; `--play-decided`, `--stop-when-met`.
- Arena runners no longer pin a stale game archive; arena widgets use real `widget:` callins (BAR's sandbox dropped the old hooks).
- 26 new cases / checks / widgets (gantry, heavy choice, turret assist, reclaim, Legion build power, escort scouting, fusion module, Fatboy, Starlight, scout raid).
```

> note: bullets, not a table, because harness changes have no play status.
> The first bullet answers a complaint the owner made during the work
> ("one side won some time ago and the game is still ongoing").

```markdown
### 📈 Performance (natural 8v8, Supreme Isthmus, 16 AIs, 33 shared windows)
| | baseline | published build |
|---|---|---|
| AI mean ms/frame | 2.14 | 1.93 |
| AI p99 ms | 9.01 | 8.28 |
| sim speed | 4.42× | 5.02× |
| mean ms per 1000 units | 2.55 | 2.30 |

One intermediate build regressed to 2.30 (raid-route grid rebuilt on every crater); fixed by routing on the shared lane grid. Natural games vary; same-state exactness is not claimed. Eight matches were run across the intermediate builds (one regressed and was fixed); the tabled run is the published build (`28f176dd`, DLL `92fd8709…`), zero script errors.
```

> note: the method is in the heading, the regression found on the way is
> admitted, the limits of natural-game comparison are stated, and the measured
> build is pinned. This is the only place a commit hash appears.

```markdown
### 📚 Docs
Decisions D-287–D-298, invariants INV-198–INV-213, known issues KI-572–KI-597, role docs and bindings in `rjm.bar.docs` (branch `circuitai-docs-reconstructed`). `check_invariants`, `check_role_docs`, `check_script_api` all at 0 findings.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_0173iZpzxf1bXNjNPYWunCoZ
```

> note: ranges rather than lists; the docs branch is named because it is not
> in this repository's diff. No Limits section was written because the open
> known issues were already inside the KI range named here; a stricter
> application of the skill would have added a three-bullet Limits section
> naming KI-597 (spam lanes fill the unit limit), KI-599 (nanos are never raid
> targets) and the pending owner decision D-291. Do that next time.

## What the two contrasting descriptions got wrong

**PR #2 (ranged land combat).** Correct and honest, but five screens of prose.
Every number sat inside a sentence ("AI time rose from 0.129329 to 0.198573
ms/frame and median sampled FPS fell from 341 to 282"), so the reader had to
parse paragraphs to find the verdict. Links pointed at a commit-pinned
`doc/` tree that later moved. A table and a limits section would have carried
the same content in a quarter of the space.

**PRs #5 to #8 (role refactors).** Title only, no body. The merger had to read
the diff to learn whether anything was played. A refactor PR still needs the
lead, a Checked status (which checkers, which counts) and a limits line saying
no behaviour change was intended and how that was confirmed.
