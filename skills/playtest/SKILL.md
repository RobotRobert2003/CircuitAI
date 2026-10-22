---
name: playtest
description: 'Run a local BAR simulation with a fresh BARb build: stage, launch (headless or windowed), fast-forward with speed plans, take screenshots, stage test widgets, judge the log, stop. Use after a build to validate behaviour instead of asking the user to play. Log reading is handed to skills/troubleshoot-bar-logs.'
---

# Playtest: local simulations

## Choose the shortest sufficient run

Use `experimental_balanced` first. Run `python -m unittest discover -s
tools/playtest -p 'test_*.py'` after changing the harness. Start runtime work with
the relevant supplied arena, then a rendered behavior spot-check, then the full
affected regression matrix and serial performance comparisons at the end.

- `ranged_arena.py --mode fast --speed 20`: no automatic photos; headless is
  optional and requires the fixture's loaded/observer events. Keep actual VM
  load checks. Fast-forward changes wall time, not scenario wave timing.
- `--mode visual`: opt into arena photos or generic `--shots`; use this for
  evidence of movement, cloak, positioning and build handover. Camera waits are
  bounded and restore simulation speed on timeout.
- `run_full_match_performance.py --mode performance --speed 20`: constant
  requested speed, no screenshot slowdowns, balanced profile by default.
  `--native-phases` enables additional attribution in a separate run. Use the
  same mode, profiler flags and observation window for both builds. Record
  achieved speed; requested 20x is not evidence the engine sustained 20x.
- Full matches are not required after each small repair. Preserve their full
  horizons for final economy/late-game regression and performance evidence.

Checks may specify `complete_on` (`key`, `pattern`, `scope`) and
`completion_grace_seconds` (default 10). This exits only after the event, all
required expectations and the grace. Arena `completion_targets` waits until
every scheduled group has been submitted, pending spawns have finished and
those enemy types are gone. `completion_after_seconds` supplies an explicit
observation duration. Use both only when both conditions are intended. Keep
enough post-kill time to observe projectiles, death blasts and task handover.
Do not opt fixed-duration performance checks into early completion.

Population arenas may explicitly set `batch_spawn: true` to submit each wave
together instead of waiting for one UnitCreated round trip per unit. Match
callbacks to pending team/definition/position requests; require `fixture_ready`
and reject missing units or spawn timeouts. Use identical batching for both
pins. Dense commander controls prove 16 teams received nearby enemy contacts;
D-gun shooter counts are separate observations because safe lanes and faction
weapons differ. Do not require every commander to fire merely to measure its
combat decision cost. Preserve casualty/population differences in the report.

For commander work, `run_commander_regression.py` runs the correctness cases
serially using their declared horizons, saves each launcher log and checkpoints
the aggregate after every game. Use a fresh `--out` path. `--cases a,b` and
`--stop-on-failure` narrow an iteration; the default selection covers the full
commander correctness set. Run `t3_matrix.py` separately for the roster and
defence/shore variants. Its DGUN, LINE and HOLD outcomes require a living
observed commander and the post-event tail; LINE additionally requires position
and damage evidence. Distant artillery cases deliberately assert safe holding.

Staging seeds only bounded `ArchiveCache<number>.lua` metadata from the local
BAR cache into each game's private cache directory. Recoil still validates
archive paths, modification times and cache version. No cache is linked or
written back to BAR, and pathfinding state is not shared. Missing, unstable or
oversized metadata means a cold load. Keep `archive-cache-seed.json` receipts;
compare loading separately from simulation CPU. Use equivalent cache conditions
for paired runs. The runner refuses launches below 1.5 GiB free disk space.

Use `same_as` with named regex groups to bind a follow-up to the same actor and
target as an earlier expectation; `after_key` also checks temporal order.
`after_minute` proves a condition persisted beyond a memory/expiry boundary.
Do not replace a failed behavior check with a weaker log match. Correct fixture
preconditions separately, retain the failed run, and explain the correction.
The standard BAR observer currently depends on the pinned game's full damage
and command callbacks. Missing attribution or a blocked widget hook is a
fixture/compatibility failure, never evidence of zero damage or zero commands.

The watcher has separate `--startup-seconds` (120), `--stall-seconds` (60) and
`--shutdown-seconds` (6) limits. The lifecycle widget emits wall-clock heartbeats
so quiet gameplay still proves frame progress. Fail fast by default. Do not use
`--keep-going` for compile checks; retain it only for bounded failure diagnosis.
Check the archived `result.json`, subprocess status and tactical outcome: all
must pass. A kill never overrides a crash, invariant or missing observation.
For supplied arenas, also evaluate the numerical assertions through
`ranged_benchmark.summarize` (schema v10). The commander suite combines these
with the watcher verdict. A watcher PASS alone does not prove casualty, damage,
or response-time bounds. Early-completion analysis requires the archived check,
completion frame and survival tail; fixed performance windows remain fixed.
Retain launcher diagnostics for failures before a game report is created.
Commander batches stop after a missing archive (startup/staging failure), even
when collecting all tactical failures. Resolve the infrastructure problem and
resume the unplayed selection with a fresh output file; never count those rows
as played failures or successes. Reserve disk space for concurrent link outputs
before starting a batch, in addition to the per-launch 1.5 GiB guard.

For optimization work, apply the
[performance contracts](../../../rjm.bar.docs/projects/circuitai/performance/engineering-guide.md) and
use the [test definition index](../../../rjm.bar.docs/projects/circuitai/testing/README.md). Compare pinned
old/new inputs in serial games; changing populations or concurrent games cannot
establish a CPU/FPS gain. Keep raw verdicts, distinguish per-unit engine orders
from Lua orders and network packets, and report compilation failures separately
from played behavior. A static script API check does not compile all object
methods; the actual embedded VM load remains mandatory.

For ranged-query changes, run `tools/run_ranged_performance_tests.sh`, then
rendered fixtures with `CIRCUIT_VERIFY_RANGED_QUERIES=1` and
`CIRCUIT_VERIFY_RANGED_SNAPSHOT=1`. Both variables must be absent for timing;
the oracles intentionally repeat expensive legacy work. The ranged runner
records their presence in its pins. Compare the inclusive ranged-snapshot
parent after D-221's child phases were added; `full-match-summary-v2.json`
retains both inclusive and exclusive tables without overwriting v1 evidence.
Natural games with different surviving populations are integration evidence,
not exact same-state FPS comparisons. Keep camera/focus and speed-window limits
visible in the report. Do not close an upstream engine bottleneck because an
AI-only component benchmark improved.

For D-243 routes/economy, run the native differential suite and separate games
with `CIRCUIT_VERIFY_POINT_ROUTES=1`, `CIRCUIT_VERIFY_ECONOMY_INDEX=1` and staged
`Sea::VerifyPowerIndex=true`. The full-match runner's `--verify-indexes` enables
these and marks timings invalid. All three must be disabled for timing. Pin
the pre-change dirty-tree snapshot, not just HEAD. Keep the original failed
verdict when Glacial hits known TECH invariants, even if new index checks pass.
Use `sea-route-transit` for physical formation arrival and command comparisons;
it supplies a route and is not autonomous combat evidence. Same-seed large-fleet
outcomes can vary on the baseline, so casualties alone do not prove an exact
optimization changed tactics. Record the compaction setting and build identity.

Tool: `tools/playtest/playtest.py` (reference: `tools/playtest/README.md`).
It stages a DLL plus the repo's `data/` as `BARbTest/test` into its own
engine write dir, never the install, and stops only its own engine.
Widgets: [references/widgets.md](../../../rjm.bar.docs/projects/circuitai/skills/playtest/references/widgets.md). Reading logs and
crashes: [`skills/troubleshoot-bar-logs/SKILL.md`](../troubleshoot-bar-logs/SKILL.md)
(and `skills/ai-not-moving` when commanders stand still: apply it to
`<dir>/runs/<stamp>/infolog.txt`, prefix `Skirmish AI <BARb playtest-test>`;
a compile failure shows as `being removed from team 0` at f=59).

## 1. Pin the build

Retain build logs, symbols, data/source snapshots and validation output in the
external benchmark checkout, not the source tree. Resolve the location with
`python tools/playtest/benchmark_store.py validation` (honors
`CIRCUIT_BENCHMARK_REPO`), then use a named session directory beneath it as the
scratchpad below. A missing benchmark checkout is an error, not permission to
recreate local `build-validation/`. Test source and reusable runners stay here;
disposable native-test scratch may use the OS temporary directory.

First publish every completed build to the mandatory output
`C:\bardev\bar-RecoilEngine\build-amd64-windows\install\AI\Skirmish\BARb\stable`:
stripped DLL, matching debug symbols, and current `data/` contents together.
Verify API parity against that output. Scratch binaries and playtest staging
do not substitute for updating this directory; it is not the live game install.

After the build log's own `exit 0` (never before: a mid-build DLL is partial):
```bash
S=<session scratchpad dir>
D=/c/bardev/bar-RecoilEngine/build-amd64-windows/install/AI/Skirmish/BARb/stable
mkdir -p $S/builds/bNN && cp $D/SkirmishAI.dll $D/SkirmishAI.dbg $S/builds/bNN/
```
- Pass `--dll $S/builds/bNN/SkirmishAI.dll`. The default `--dll` is that
  install folder, which the next build rewrites in place.
- The `.dbg` must match the exact DLL, or crash frames symbolise wrongly.
- `--dll` is paired with the repo's *current* `data/`. For an older DLL,
  pass `--data <snapshot of data/ from its commit>`.
- `python tools/knowledge/check_script_api.py --dll <dll>` checks that the DLL
  registers everything the script uses.

## 2. Compile check first (after any script edit)

AngelScript compiles only when a game loads, and warnings are fatal. A
failure leaves every AI idle for the whole game.
```bash
python tools/playtest/playtest.py run --dir C:/bardev/barb-playtest-sim1 --dll <dll> \
  --roles TECH --headless --shots "" --speed 20 --minutes 1 --wall-minutes 6
grep -a ': ERR \+:\|: WARN :\|Lib exception\|SCRIPT CRASH' C:/bardev/barb-playtest-sim1/infolog.txt
grep -ac 'rules loaded' C:/bardev/barb-playtest-sim1/infolog.txt   # = the number of TECH AIs
```
- Ignore `(0, 0) : ERR  : Object {N}. GC cannot destroy` and `(0, 0) : WARN :
  There is an external reference`: that is teardown after
  `EOH::DestroySkirmishAI`.
- A real error names a `.as (row, col)`.
- `python tools/knowledge/check_script_api.py` catches unbound members, not
  unbound globals.

Recurring AngelScript errors:
- `in` and `out` are reserved words;
- there is no `max`/`min` or `SQUARE`: use `AiMax`/`AiMin` (int, float,
  AIFloat3) and `SQUARE_SIZE`;
- a handle assignment needs `@t = ...`;
- a bare `{...}` is not an argument: write `array<float> = {...}`;
- a `const CCircuitDef@` cannot be passed as `CCircuitDef@`;
- shadowed names and uninitialised locals are errors.

## 3. Launch

For new experiments follow [storage conventions](../../../rjm.bar.docs/projects/circuitai/test-storage.md).
AIR arenas and scorecard runs allocate a unique categorized write directory
when `--dir` is omitted. For the generic runner or a specialised preparer,
allocate one first and pass the returned path to every stage/run/watch/stop:

```bash
GAME_DIR=$(python tools/playtest/storage.py allocate --domain tech --area economy --scenario rush-afus --map supreme --kind benchmark)
```

Cases and checks are organized by domain and area. Legacy short check names
still work. Keep the printed `runs/<UTC-id>/` archive path, publish compact
evidence with `storage.py publish <archive> --screenshot <filename.png>`, and
rebuild discovery with `storage.py index`. Never rewrite an old verdict to make
the benchmark pass. The explicit legacy paths below remain supported for
reproducing old commands.

**Prune after every game (D-339).** The benchmark checkout must stay under
5 GB. When the verdict is read and the comparison evidence published, run
`python tools/playtest/prune_benchmarks.py --apply --path <game dir>`. It keeps
every result output (reports, verdicts, metric JSON, manifests, the game setup,
`telemetry.jsonl`, `system.json`) and deletes the raw inputs: infolog,
screenshots, replay, staged DLL/symbols/scripts and caches. Copy anything else
you still need (a log excerpt, a screenshot) into the published bundle first.
Pass `--keep <pin>` to protect a pin still in use. A dry run (no `--apply`)
shows what would go. Each run records its machine in `system.json` and
`result.json`'s `system`; compare timings only on matching hosts, since several
devices run tests.

```bash
python tools/playtest/playtest.py stop --dir C:/bardev/barb-playtest-simN   # always, first
python tools/playtest/playtest.py run --dir C:/bardev/barb-playtest-simN --dll <dll> \
  --map "Supreme Isthmus v1.7" --roles TECH --side legion \
  --speed 20 --minutes 45 --wall-minutes 60 --keep-going --headless --shots ""
```

**Running it**
- Launch through the available shell tool and retain its process/session handle.
  Poll that handle while doing independent work. Wait for
  `[playtest] report: <path>` and use that exact archive, never another run's
  newest folder. Do not assume a harness-specific background flag exists.
- Normal completion and handled exceptions run identity-checked cleanup in
  `finally`. Forced watcher termination can bypass it. Use
  `playtest.py stop --dir <exact-owned-dir>` before abandoning a run, or reattach
  with `playtest.py watch --dir <dir> --checks <same>
  --minutes <same> --keep-going --wall-minutes <N>` (`--no-stop` to only
  observe; without these it re-reads the log from the start and stops the
  game at once), or `stop`.
- To follow a live game, Monitor `tail -n0 -F <dir>/infolog.txt | grep -a
  --line-buffered -E '<tags>|Access violation|SCRIPT CRASH'` (no `( ... &)`
  wrapper; timeout 1800000, re-arm when it expires).
- Right after a launch, `<dir>/infolog.txt` is still the previous game's log,
  until `[playtest] engine pid` appears. TaskStop old watchers before
  relaunching on a dir.

**Parallel games**
- One `--dir C:/bardev/barb-playtest-simN` per concurrent game, and the same
  `--dir` for run, watch and stop.
- A second `run` on a live dir fails with `PermissionError` on the staged
  DLL, or with `ERROR: a playtest engine is already running`. Check the output
  for `ERROR:`, not only the exit code.

**Flags that matter**
- Select checks appropriate to the scenario. Keep normal iteration and final
  acceptance fail-fast. Use `--keep-going` only for bounded diagnosis after
  retaining the strict failure; it never converts an invariant into a pass.
- `--wall-minutes` always. The default (stop_minute x 1.5 + 4) cuts off slow
  16-AI or windowed games without saying so.
- `--roles TECH`: a fast TECH-vs-TECH 1v1. `--roles all` (the default) is 16
  AIs at about 1-2x whatever `--speed` says.
- `--others none` drops only the ally-side AIs; the enemies for each role
  still spawn. To avoid a TECH enemy, whose nuke often wipes team 0 at 23 to
  27 min, move its spot to the ally side (Supreme: `--ally-spots
  1,2,3,4,5,6,7,8,10`, not yet played) and check the `teams:` line in
  report.md.
- `--ai-option profile=<name>` picks the profile (default
  `experimental_balanced`, for every AI, prod too).
- For a game the owner watches: `--shots "" --no-stop --speed 1 --minutes 90
  --extra-widget tools/widgets/gui_barb_team_link.lua`. It still quits at
  minutes + 0.5; the owner is a spectator (sets roles, commands nothing) and
  must reopen the BARb window.

**Map, game, teams**
- The map, game and every modoption come from the lobby's last
  `_script.txt`: pin them with `--map`, `--game`, `--modoption`.
- `--map` must be the archive's internal name ("Supreme Isthmus v1.7", "All
  That Glitters v2.2.3", "Glacial Gap v1.1", "Tundra Continents v2.3.1").
  Otherwise the engine dies about 8 s in with `Dependent archive ... not
  found`. Look names up in `<dir>/cache/ArchiveCache*.lua`, and pass
  `--map-file data/script/src/maps/<file>.as` when the name does not reduce
  to one.
- Team 0 is always the AI under test (`--role`, `--side`). The spectating host
  is its own team at (64, 64) in ally team 2. Gaia is the last team.
- Team 0 starts on the map file's StartSpot, not where the owner started:
  compare `[Playtest] frame 1 team 0 ... start (x, z)` before claiming a
  repro (D-116: 77 elmos moved the lab).

**Settings**
- `--set KEY=VAL` edits only `Global::RoleSettings::Tech` int/float/bool/string
  lines in the staged `global.as`, pasted as literal AngelScript. Quote
  strings: `--set 'RushObjective="afus"'`.
- Settings that `data/config/*.json` overrides (all of `weapons.json` and
  `lanes.json`) need `--data <edited copy of data/>`. TECH rewrites
  `MaxT1Builders`, `MaxT2BotLabs` and `Minimum*ConstructorBots` at runtime, so
  `--set` on them does nothing.

## 4. Fast-forward

| Game | Game min per wall min (load 30-60 s extra) |
| --- | --- |
| 1v1 headless, `--speed 20` to `40` | about 8 to 16x |
| 1v1 windowed | lower, GPU-bound |
| 16 AIs | about 1 to 2x |

- `--speed` defaults to **1**: always pass it.
- `--speed-plan "20:20,34.6:1,36:20"` (minute:speed): 1x only where you watch.
  - Make the first entry equal `--speed`: a `0:X` entry lower than it is
    ignored at the start and then makes the first 1x window run at X.
  - Confirm the real rate with `grep -a "Speed set to" <dir>/infolog.txt`;
    the widget's `[Playtest] speed` line is only the request.
- `--slow-near-shots` means 1x from 0.3 min before each shot until 0.05 after.
  Shots closer than 0.5 min apart break it: use one `--speed-plan` window
  instead.
- AI map drawings (the intro, lanes, smileys) are paced in **real time**,
  while their holds are in game frames. Run at 1x across any drawing a shot or
  check depends on, and take the window from the `[Commands] map drawing`,
  `[Lanes] drawn` and `[Lanes] erased` frames of a previous run.
- A short fast check never sees a drawing finish.
- The intro rolls the credits in 5% of games, which delays everything after it.
- In a widget, send `setmaxspeed S`, `setminspeed S`, `setmaxspeed S`: that
  works in both directions (the engine keeps max at least min, and
  `GetGameSpeed` is stale until `Speed set to` arrives).

## 5. Screenshots (windowed only)

- Headless writes blank 187-byte PNGs but still logs `[Playtest] screenshot`.
  Omit `--headless` and check that PNGs are about 2-3 MB.
- `--shots "35@3200@3900:7200,35.3@14000@6144:6144"`: minute@height@x:z.
  - Without x:z the camera frames team 0's start.
  - `@14000@6144:6144` shows all of Supreme Isthmus.
  - `--shots ""` turns the camera off, when a widget drives its own.
  - The default is `1,3,6,10`.
  - An x:z shot echoes `at (-1, -1)`: ignore it.
- Aim at positions from the log (cluster, `RESERVE:`, choke lines), and time
  shots from a previous run's frames, at 1x.
- PNGs are `screen_<UTC time>.png`. Map them to game time by order against the
  `[Playtest] screenshot at X min` lines, or by the `[CBitmap::Save] saved`
  line's `[f=N]`.
- While live, read `<dir>/screenshots/`; afterwards `runs/<stamp>/`. Launch
  deletes the old ones.
- The host is a spectator (`specfullview`): shots show every team, and the
  AI's map strokes render white.
- The windowed game is live: tell the user not to click it. `requested by
  widget` or `Speed set to` lines they cause are user input.
- Inspect screenshots with the available image viewer and include the useful ones in updates to the user.

## 6. Widgets

Stage test widgets with `--extra-widget tools/playtest/widgets/<file>.lua`
(repeatable) on **every** run: staging deletes the dir's widgets.

Existing ones:

| Widget | What it does |
| --- | --- |
| `team_stats.lua` | [TeamStats] |
| `unit_census.lua` | [Census] |
| `build_area.lua` | [BuildArea], then `build_area.py` |
| `smiley_watch.lua` | full LOS at minute 20, screenshots each AI drawing |
| `gantry_watch.lua` | watches the gantry |
| `intro_test.lua` | intro timing |
| `draw_test.lua` | draws a test map drawing |
| `role_swap_test.lua` | switches roles |

Writing one: [references/widgets.md](../../../rjm.bar.docs/projects/circuitai/skills/playtest/references/widgets.md).

## 7. Judge and read

1. `<dir>/report.md` (`--print-report` prints it all): verdict, checks,
   timeline.
   - `skirmish AI None` means team 0 was never identified, so every AI-scoped
     check silently missed. Look for a compile failure or a `--role` mismatch.
   - The reason is only the category of the last failure; read `## Failures`
     for each one. It never names a crash.
   - `script errors` whose lines are all `(0, 0) : ERR  : Object {N}. GC
     cannot destroy` is an AI destroyed mid-game (a team wiped, a crash), not a
     compile error: find why with the greps below and `EOH::DestroySkirmishAI`.
2. Always grep the run's log:
   ```bash
   L=<dir>/runs/<stamp>/infolog.txt
   grep -a -c 'Access violation\|has crashed\|Fatal:' $L
   grep -a ': ERR \+:\|Lib exception\|failed handling event\|SCRIPT CRASH' $L | sort -u | head
   grep -a '\[INVARIANT\]' $L | sed 's/.*\[INVARIANT\] //' | cut -c1-8 | sort | uniq -c
   ```
3. Everything deeper (size discipline, markers, symbolising
   `SkirmishAI.dll [0x...]`) is in `skills/troubleshoot-bar-logs`. Playtest
   specifics:
   - **Symbols:** match the build by `staged.json`'s `dll_sha256_16` against
     `sha256sum builds/bNN/SkirmishAI.dll | cut -c1-16`, and symbolise with that
     `builds/bNN` `.dbg`: the staged one can be stale.
   - **Where:** live `<dir>/infolog.txt` (deleted at each launch); one game
     per `runs/<stamp>/infolog.txt`; the staged build in `<dir>/staged.json`.
   - **AI lines:** `Skirmish AI <BARb playtest-test>: :::AI LOG:S:<ai>:T:<team>:F:<frame>:L::<text>`.
     Filter one team with `grep -a ':::AI LOG:S:[0-9]*:T:0:'`.
   - **Native lines** (`EXP:`, `RESERVE:`, `LANES:`, `NUKE:`...) carry no
     team, so in a 1v1 both AIs interleave. Tell them apart by faction prefix
     or coordinates. (`--others prod` is ambiguous: three install folders
     share `SMRTBARb/stable`, and `using dir` names the wrong one.)
   - **Noise** to ignore: `AdvSky`, `corfast_dead`, `gui_pip ... CreateShader`,
     `Failed to load: tf_*.lua`, `Game-side script ... is missing`.
   - **Size:** logs reach 25 MB. Use `grep -c`, `-m`, `head`; never read a
     whole infolog.

## 8. Stop and clean up

- `python tools/playtest/playtest.py stop --dir <dir>` only.
  - It requests graceful exit and allows a bounded replay/log flush, then
    terminates only the verified engine handle if needed. The launch manifest
    binds PID, creation time and executable to the canonical write directory.
  - A numeric `playtest.pid` alone is never sufficient. Old manifests without
    creation identity are deliberately refused; inspect ownership rather than
    bypassing the check. Watch/run and supplied/full-match callers clean up on
    exceptions. Always retain equivalent finally cleanup in a new caller.
- Never `taskkill /IM spring.exe`: the user may be playing. Check with
  `tasklist //FI "IMAGENAME eq spring.exe"`, and read each engine's
  `--write-dir` via `Get-CimInstance Win32_Process`.
- A windowed engine that crashed stays alive in its crash handler: the
  progress frame stops advancing. `tail -c 1500 <dir>/infolog.txt`, then stop.
- `[QuitAction] user exited to system` after `[Playtest] end at ... quitting`
  is the widget's own quit.

## Checks files, benchmarks

- Commander correctness: `run_commander_regression.py --dll <pin>/SkirmishAI.dll
  --data <pin>/data --out <session>/regression.json --headless`. Use `--cases`
  for iteration; retain the complete case selection for final regression.
- Commander performance: `run_commander_performance.py --baseline <pin>
  --candidate <pin> --out <session>/performance.json --headless --attribution`.
  Run it with no other game/build active. AB/BA idle controls, dense combat,
  natural games and native attribution have different evidentiary value. The
  runner deliberately leaves performance review pending after checks pass.
  If the user explicitly keeps the BAR lobby open, `--allow-lobby` permits only
  a Spring `--menu` process and retains its load in every environment record.
  Other matches/builds still fail preflight. Report those timings as qualified,
  never as an uncontended comparison; do not close the user's lobby yourself.
  If existing invariants stop strict natural games before late-game coverage,
  retain those failures first. `--natural-only --keep-going` runs bounded
  diagnostic pairs to GameOver or the original horizon, preserving every FAIL.
  The standalone full-match runner also accepts `--keep-going`. These runs
  extend observation; they do not clear the invariant or replace strict tests.
  After a focused repair, `--arenas-only --attribution` repeats the fixed
  controls on the new pin without needlessly replaying strict natural games
  that already stop on known issues. Use the new pin for subsequent full
  natural diagnostics and identify all earlier-pin coverage explicitly.
- Population fixtures must log `fixture_ready` before their steady-state
  interval is used. Dense combat must report how many AI teams actually fired;
  sixteen declared starting positions alone do not prove sixteen active fights.
- Native iteration: `build_native_snapshot.py --session <session>/<build>
  --reuse <completed-pin> --jobs 4`. Content hashes preserve both safety for
  changed-but-older files and reuse for byte-identical restored headers. Keep
  the current object cache until the next snapshot has copied it. Retain DLL,
  matching symbols, source/data and logs; redundant `.full.dll` linker
  intermediates and superseded object caches are disposable after publication.

- `tools/playtest/checks/<name>.json`: `expect` (`key`, `pattern`,
  `by_minute`, `after_key`, `scope`), `forbid` (`key`, `pattern`,
  `after_minute`), `pass_on` (`key`, `pattern`), `complete_on` and `stop_minute`.
  Validate checks before launch. Watcher exceptions still trigger cleanup and
  retain `runner-error.json`; they must not be counted as played PASS results.
  - `expect` and `pass_on` default to scope `tech` (team 0's AI text after
    `:L::`). Widget and native lines need `"scope": "any"`.
  - `pass_on` only sets PASS; the game still plays on.
  - Keep a forbid on `: ERR\s+:` and one containing `INVARIANT`: the
    `check_invariants.py` tool requires it.
- Rush benchmarks: `SPEED=8 NOTE=... bash tools/playtest/bench_loop.sh t2 afus`
  (`DLL=` and `DIR=` pick the build and dir). It records each run itself;
  `benchmark.py record <run> --objective X` is only for a run launched by
  hand. Confirm a benchmark result once at `--speed 1`.

## Windows and Git Bash traps

- In a grep bracket, `[^\r]` excludes backslash and the letter r. Infologs are
  LF: use `.\{0,N\}` (or `grep -E '.{0,N}'`).
- `S:[0-9]:` misses AI ids 10-15: use `S:[0-9]*:`.
- Use `tail -n 3`: `tail -3 f1 f2` fails.
- Use `tasklist //FI`: a single slash gets path-mangled.
- Patch through a script file (heredocs mangle backslashes; files are CRLF),
  and chain the run after it with `&&`.
- Set `PYTHONIOENCODING=utf-8` for non-ASCII output.
- Never write under the BAR install.
