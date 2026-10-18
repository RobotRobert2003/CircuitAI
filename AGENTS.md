# CircuitAI Agent Instructions

These instructions apply to the entire repository. `AGENTS.md` is the sole repository instruction entry point for every coding agent. Keep repository guidance in this open, harness-neutral format; do not add vendor-specific instruction routers, coding-agent settings, hooks, or discovery files. Reusable runbooks remain in the open Agent Skills format under `skills/`, with vendor-neutral discovery links under `.agents/skills/`. "Repository Map" below describes the files and folders this document names.

## Primary test profile

Use `experimental_balanced` as the primary profile for simulations and regression checks unless the user specifies otherwise. Run other profiles as compatibility coverage when shared code changes; do not substitute them for balanced-profile verification.

## Simulation iteration and lifecycle

Apply `skills/playtest/SKILL.md` before using or changing the simulation harness.
Start with focused checks and short supplied arenas; use `--mode fast` and a
high requested speed (normally 20). Use `--mode visual` explicitly for rendered
evidence, and `--mode performance` for constant-condition cost comparisons.
Record achieved speed, not only the requested multiplier. Run broader regression
and serial pinned before/after performance tests after the focused checks pass.

Functional scenarios may opt into `complete_on` plus a survival grace interval;
completion requires all scheduled waves and required observations. Never shorten
fixed performance windows or treat one early kill as completion of a multi-wave
test. Fail fast by default; `--keep-going` is a bounded diagnostic choice, not
the standard compile-check mode. Preserve original failures and launcher logs.
Always use the runner's identity-checked stop/cleanup, including on cancellation;
never kill all Spring processes or trust a numeric PID alone. Leave no owned
simulation idle after its result. See the playtest skill for watchdogs, observer
compatibility, evidence storage and the harness regression command.

## Performance requirements for every change

Commander correctness suites can be run with
`python tools/playtest/run_commander_regression.py --dll <pin>/SkirmishAI.dll --data <pin>/data --out <benchmark-session>/regression.json --headless`.
It validates the selected checks before launch, retains per-case diagnostics,
and requires process success, an archived PASS and the arena's numerical
assertions. A watcher PASS alone does not clear damage, casualty or response
time limits. Use `--cases` and
`--stop-on-failure` while iterating; run the complete suite, T3 matrix and
separate serial performance comparisons at the end. A suite entry is a
designed scenario, not evidence that it has passed.

For serial commander cost comparisons after correctness, use
`tools/playtest/run_commander_performance.py --baseline <pin> --candidate <pin> --out <benchmark-session>/performance.json --headless --attribution`.
It retains AB/BA supplied controls, full natural games and separate native
attribution. Review CPU, commands, populations and environment records before
making a performance claim; a successful runner exit is only correctness clearance.
Use `build_native_snapshot.py --reuse <completed-pin>` for iterative native
builds. Reuse validates source content, including restored headers, instead of
trusting file dates. Do not run timing comparisons alongside builds or games.
If the user explicitly keeps the BAR lobby open, `--allow-lobby` records that
exception without permitting another match/build. Qualify the measurements as
contended; do not describe them as uncontended performance clearance.

Treat performance as a design constraint for every runtime change, including
C++, AngelScript, JSON tuning, Lua widgets and cross-AI messaging. Review cost
before implementation and verify it before claiming completion. Read
`../rjm.bar.docs/projects/circuitai/performance/engineering-guide.md` before
adding or changing recurring work, not only when replacing an optimization.

- Budget for 16 AI instances and large late-game armies. Identify invocation
  frequency, collection sizes, worst-case work, allocations, engine callbacks,
  emitted commands and message volume. A cheap per-unit operation can become
  expensive when repeated per unit, per AI or per simulation frame.
- Prefer lifecycle-maintained indexes, bounded local queries, shared decision
  snapshots and allocation reuse over repeated full scans. Use constant-time
  lookups where appropriate, but state the real complexity, mutation cost and
  memory tradeoffs; do not label an entire search O(1) because one lookup is.
  Caches require explicit ownership, invalidation and lifetime contracts.
- Review command traffic as well as CPU time. Avoid redundant live orders only
  after validating task ownership, queue contents, target, options, expiry and
  recovery state. A formation or group controller does not necessarily reduce
  per-unit engine commands or network traffic. Review widget polling and relay
  fan-out with the same care as native and script loops.
- Preserve economy, combat efficacy and threat-response latency. Do not hide
  cost by adding APM caps, delaying reactions, reducing scouting or changing
  decision cadence without explicit authorization for that behavior change.
  Optimizations must preserve ordering, tie-breaking, random draws and task
  lifecycle semantics. Keep engine callbacks and mutable AI state on their
  supported thread; workers may use owned immutable snapshots only under a
  verified threading and result-validation contract.
- Comment non-obvious performance decisions near the implementation: why the
  approach is used, complexity variables, ownership, invalidation events and
  the relevant regression test. Keep detailed evidence in the external
  benchmark store and maintenance contracts in the engineering guide.
- Verify proportionately: documentation-only edits need no simulation; runtime
  changes need relevant correctness checks, and hot paths or new recurring
  work need representative before/after cost evidence using equivalent inputs.
  Use experimental_balanced primarily. Distinguish component CPU, allocations,
  commands, whole-game FPS and multiplayer traffic; report what was measured
  and any verification gaps. Never infer FPS or network improvements from
  asymptotic reasoning or a microbenchmark alone.

## Project Context

CircuitAI is a C++ Skirmish AI for the Recoil RTS engine. Native behavior is under `src/circuit/`. The primary, active AngelScript implementation and profiles are under the root `data/` tree: policy code is in `data/script/` and JSON behavior profiles are in `data/config/`. The parallel `data_sample/` tree contains sample AngelScript and configuration for reference only; it is not the implementation target. The C++ code is normally integrated into an engine checkout as a Skirmish AI and depends on Recoil's generated C++ AI wrapper.

Read `data/script/README.md` before changing AngelScript policy code. Apply `skills/convention-angelscript/SKILL.md` when writing or reviewing AngelScript; it defines version-compatible language, ownership, functional-style, safety, and performance practices. Read `../rjm.bar.docs/projects/circuitai/angelscript-references.md` for the current script loading model, callback contracts, registered C++ API, ownership rules, and practical usage examples. Use the shared knowledge base (`../rjm.bar.docs/knowledge/30-units/`, see "Game and Engine Knowledge Base") together with `../rjm.bar.docs/projects/circuitai/units.md` for the BAR base roster and `../rjm.bar.docs/projects/circuitai/extra_units.md` for the `experimentalextraunits` roster before changing UnitDef classifications, factory edges, or behavior properties. Read `../rjm.bar.docs/projects/circuitai/scripting/CHANGE_RECOMMENDATIONS.md` when investigating BAR compatibility or historical API drift. See `../rjm.bar.docs/projects/circuitai/TRUSTED_REFERENCE_REPOSITORIES.md` for the external-reference map.

For every AngelScript or profile change, inspect and modify `data/`. Use `data_sample/` only to understand examples or historical patterns, and do not implement, mirror, or apply the requested change there unless the user explicitly asks to update sample material.

Apply `skills/convention-cpp/SKILL.md` when writing or reviewing native C++;
it covers callback ownership, script levers and performance proof. Read
`../rjm.bar.docs/projects/circuitai/performance/engineering-guide.md` before replacing a recent optimization.

Read `../rjm.bar.docs/projects/circuitai/intent.md` before deciding **where** a behaviour belongs. It states
the goals this fork is aiming at and the rule that follows from them: C++ is
mechanism, AngelScript is policy, and a native change must leave an equivalent
lever in script or JSON rather than hardcoding a build order or a priority.

Record every problem you diagnose but do not fix in `../rjm.bar.docs/projects/circuitai/known-issues.md`, and
read that register before starting work so you do not re-diagnose something
already understood. Its "Maintaining this register" section is the full rule;
"Known Issues" below is the short form.

Record every non-obvious *decision* in `../rjm.bar.docs/projects/circuitai/decisions.md` — the call, the
reasoning, the alternative rejected, links to every file it touched, and how
far it has actually been verified. A deliberate non-change counts, and so does
a decision later found to be wrong: those are marked, never deleted. Read it
before reversing something that looks odd; several of these choices look wrong
until you know what they are working around. "Decisions" below is the short
form.

Do not create or update repository changelog entries automatically. Only when
the user explicitly requests a changelog, invoke
`skills/maintain-changelog/SKILL.md`.

When the user asks to open, update or describe a pull request, apply
`skills/write-pull-request/SKILL.md`: it sets the title, the per-area tables
with a verification column, the performance and docs lines, and the honesty
rules the description must meet.

Before searching for where something lives, read "Repository Map": it describes every file and folder referenced in this document, marks the active implementation against reference-only trees, and records which external paths are writable and which are read-only.

## Repository Map

Every path named anywhere in this document is described below, together with the
paths an agent needs in order to locate work without searching. Paths are
relative to the repository root unless shown as absolute or prefixed with
`../`. Read this section before searching: it identifies the authoritative
location for a change and separates the active implementation from
reference-only material.

### Agent instructions and skills

| Path | Description |
| --- | --- |
| `AGENTS.md` | This file. The sole, harness-neutral repository instruction entry point; links to shared documentation and reusable skills. |
| `skills/` | Repository skills in the Agent Skills format; one subdirectory per skill, each with a `SKILL.md`. |
| `skills/convention-angelscript/SKILL.md` | AngelScript conventions: version-compatible language subset, ownership, functional style, safety, performance. Apply when writing or reviewing AngelScript. |
| `skills/convention-cpp/SKILL.md` | Native CircuitAI/Recoil C++ conventions: task ownership, bindings, callback threading, exact optimization and evidence. Apply when writing or reviewing native AI code. |
| `../rjm.bar.docs/projects/circuitai/performance/engineering-guide.md` | Maintenance contracts for measured optimizations: complexity, invalidation, allocation, command and threading constraints. Read before changing optimized native or script paths. |
| `../rjm.bar.docs/projects/circuitai/testing/README.md`, `../rjm.bar.docs/projects/circuitai/testing/catalog.json`, `../rjm.bar.docs/projects/circuitai/testing/index/` | Generated categorized inventory of designed scenarios, checks, unit suites, validators and runner families; execution evidence stays in the benchmark catalog. Regenerate with `tools/knowledge/index_test_cases.py`. |
| `skills/convention-angelscript/references/` | Supporting detail for that skill: `idioms.md`, `performance-and-safety.md`, `version-compatibility.md`. |
| `skills/maintain-changelog/SKILL.md` | Changelog entry format, timestamping, and file layout. Opt-in: invoke only when the user explicitly asks for a changelog. |
| `skills/write-pull-request/SKILL.md` | Pull request title and description: short lead, one table per area with a Built / Checked / Symbolised / Played status column, performance and docs lines, open limits. Apply whenever the user asks to open or update a pull request. `references/example-batch-pr.md` is the annotated merged example. |
| `skills/troubleshoot-bar-logs/SKILL.md` | BAR runtime log investigation: size discipline, crash-marker search, AI log filtering, and symbolising `SkirmishAI.dll` stack offsets. |
| `.agents/skills/` | Symlinks that expose `skills/` to harnesses which discover skills under `.agents/` (`ai-not-moving`, `convention-angelscript`, `convention-cpp`, `maintain-changelog`, `playtest`, `troubleshoot-bar-logs`, `write-pull-request`). Add a symlink here when adding a skill. |

### External benchmark storage

Benchmark evidence, raw simulations and retained build validations belong to the writable sibling checkout
`../CircuitAI.benchmarks` (or `CIRCUIT_BENCHMARK_REPO`). See
[benchmark repository and migration](../rjm.bar.docs/projects/circuitai/benchmark-repository.md). Keep AI code,
test definitions and runners here; write new reports, ledgers and raw games to
the external store via `tools/playtest/benchmark_store.py`. The old local
`build-theatres` path may be an ignored compatibility junction; do not delete
it recursively. Raw artifacts remain Git-ignored and require separate backup.

Keep the source checkout focused on native code, active scripts/profiles, build
support and reproducible tests. Tests, fixtures, benchmark source, reusable
runners, CI, packaging, licenses, runbooks and small navigation documents are
intentional exceptions to the runtime-only rule. Detailed project documents
belong in `../rjm.bar.docs/projects/circuitai/`. Generated logs, reports, timing
output, pinned DLLs/symbols and source/data snapshots belong in the benchmark
checkout, even when created during compilation rather than a game.

Resolve `python tools/playtest/benchmark_store.py validation` before retaining
build-validation artifacts; it prints `../CircuitAI.benchmarks/build-validation`
or the configured equivalent and fails if the checkout is missing. Use a named
session/build subdirectory there. Do not recreate local `build-validation/` or
add a compatibility junction for it. Disposable unit-test scratch may use the
OS temporary directory. Required engine-integration build outputs are unchanged.

| Path | Description |
| --- | --- |
| `../rjm.bar.docs/projects/circuitai/benchmark-repository.md` | Ownership, setup, migration counts, preservation checks and raw-archive compatibility. |
| `tools/playtest/benchmark_store.py` | Configurable benchmark checkout, evidence and raw paths; historical reference resolution. |
| `tools/playtest/migrate_benchmark_repository.py` | Non-destructive migration inventory and verification utility. |
| `../CircuitAI.benchmarks/doc/images/` | Historical gameplay screenshots. |
| `../CircuitAI.benchmarks/build-theatres/` | Raw archives, replays, pinned binaries and local build caches. |
| `../CircuitAI.benchmarks/build-validation/` | Retained build/test logs, pinned DLLs and symbols, source/data snapshots and validation scratch; Git-ignored. Resolve through `benchmark_store.py validation`. |

### Active implementation - `data/`

This is the implementation target for every AngelScript and profile change.

| Path | Description |
| --- | --- |
| `data/` | The deployed AI data tree: engine metadata, JSON behaviour profiles, and AngelScript policy. |
| `data/AIInfo.lua` | Skirmish AI identity presented to the engine: name, version, interface. |
| `data/AIOptions.lua` | Player-visible options, including the `profile` list whose entries map to the profile directories below. See `../rjm.bar.docs/projects/circuitai/Profile.md` to add one. |
| `data/config/` | JSON behaviour profiles. Root-level files are the shared defaults; each profile directory overrides them with the fragments its `init.as` selects. |
| `data/config/behaviour.json` | Per-UnitDef behaviour defaults: roles, attributes, unit limits, threat values. |
| `data/config/block_map.json` | Structure placement and blocking geometry defaults. |
| `data/config/build_chain.json` | Build-chain rules: what a completed structure implies should follow it. |
| `data/config/commander.json` | Commander and dynamic-commander selection and loadout. |
| `data/config/economy.json` | Economy tuning: income targets, storage, conversion, and pull limits. |
| `data/config/weapons.json` | D-126: TECH's weapon-cluster settings (budget, income gates, counts, the super cannon's escort, analysis); overrides `Global::RoleSettings::Tech`. |
| `data/config/lanes.json` | D-127: lane settings (alternatives, merge radius, recalculation, drawing); overrides `Global::RoleSettings::Tech`. |
| `data/config/field.json` | D-323: the battlefield map analysis levers (grid, region and theatre minimums, the BWEM choke rule, slope and depth thresholds, avenue detour, publication); read natively by `CFieldService` from the first enabling AI's profile; listed in the experimental profiles' `init.as` fragment lists. |
| `data/config/factory.json` | Factory rosters, tiers, and production weights. |
| `data/config/response.json` | Threat-response tables mapping observed enemy composition to answers. |
| `data/config/easy/`, `data/config/medium/`, `data/config/hard/`, `data/config/hard_aggressive/` | Configuration for the legacy, native-driven difficulty profiles. Their behaviour comes from CircuitAI's native defaults plus this JSON rather than the shared role framework. |
| `data/config/experimental_balanced/`, `data/config/experimental_hard/`, `data/config/experimental_terrible/` | Configuration for the profiles driven by the shared AngelScript role framework. |
| `data/config/<profile>/*_leg.json` | Legion variant of a fragment, loaded only when the Legion mod option is active. |
| `data/config/<profile>/behaviour_extra_units.json` | Additional behaviour entries loaded when `experimentalextraunits` is active; see `../rjm.bar.docs/projects/circuitai/extra_units.md`. |
| `data/config/<profile>/behaviour_scav_units.json` | Additional behaviour entries loaded for Scavenger content. |
| `data/script/` | The AngelScript policy layer: role selection, manager tuning, task enqueueing, strategic state. |
| `data/script/README.md` | Authoritative description of script loading, profile structure, the shared foundation, and the experimental runtime sequence. **Read before changing AngelScript policy code.** |
| `../rjm.bar.docs/projects/circuitai/scripting/CHANGE_RECOMMENDATIONS.md` | Compatibility against the current C++ bindings and recommended migrations. Read when investigating BAR compatibility or historical API drift. |
| `../rjm.bar.docs/projects/circuitai/scripting/HOVER_FACTORY_IMPLEMENTATION.md` | Implementation notes for hover production; pairs with `../rjm.bar.docs/projects/circuitai/roles/hover.md`. |
| `data/script/<profile>/init.as` | Returns `SInitInfo`, initialises armour and category masks, and selects this profile's JSON fragments. |
| `data/script/<profile>/main.as` | Profile entry hooks. Empty or commented in the legacy profiles; in the experimental profiles it registers maps, strategy weights, factory tiers, profile tuning, periodic threat and cost updates, and Lua message handling. |
| `data/script/src/` | The shared AngelScript graph that the experimental profiles include through `src/setup.as`. |
| `data/script/src/common.as` | Shared initialisation data - armour definitions and categories - used by every profile `init.as`. |
| `data/script/src/define.as` | Script constants, aliases, masks, priorities, and random helpers expected by all modules. |
| `data/script/src/global.as` | Live shared state, strategy state and compatibility include entry for settings/defaults.as. Default tuning lives under settings/. |
| `data/script/src/settings/` | Explicit defaults.as include index; shared defaults under shared/ and one default file per role under roles/. Keep existing Global namespaces and mutable override semantics. |
| `data/script/src/setup.as` | Include root for the shared graph. `Setup::setupMap()` resolves map, start spot, faction, role, unit-limit overlays, and role delegates, and logs the deterministic startup snapshot. |
| `data/script/src/unit.as` | Unit lifecycle hooks reaching script from the native managers. |
| `data/script/src/task.as` | Task hooks: `AiMakeTask`, `AiTaskAdded`, `AiTaskRemoved`, and related policy. |
| `data/script/src/maps.as` | Map registration and lookup for the per-map configurations. |
| `data/script/src/maps/` | One file per supported map, plus `default_map_config.as` as the fallback. |
| `data/script/src/manager/` | Native callback adapters only: `builder.as`, `economy.as`, `factory.as`, `military.as`. Stateful gameplay capabilities belong in `systems/`; role selection and sequencing remain in `roles/`. |
| `data/script/src/systems/` | Stateful capabilities grouped into air, sea, amphibious, construction, production (with factory_configs), combat, team, world, presentation and diagnostics. See the script overview for navigation and ownership rules. |
| `data/script/src/roles/` | Role-specific folders (air, front, sea, support, tactical, tech), each with its role entry and existing supporting files. Operational capabilities remain in systems/. |
| `data/script/src/types/` | Script value types: `ai_role.as`, `building_type.as`, `map_config.as`, `profile_controller.as`, `role_config.as`, `start_spot.as`, `strategic_objectives.as`, `strategy.as`, `terrain.as`. |
| `data/script/src/helpers/` | Helpers organized by responsibility: `math/` (pure calculations), `construction/` (builder/economy/factory/guard policy), `spatial/` (territory/layout/map/walls), `combat/` (defense chains), `units/` (rosters/classification), `roles/` (roles and limits), `objectives/` (state and execution), `common/` (collections/logging/task names). Keep pure math independent of managers and engine callbacks. |
| `data/script/src/systems/team/sea_assist.as` | SEA donates one T1 construction ship to a TACTICAL ally at +50 metal income, and TACTICAL lifts its zero shipyard caps once it owns a sea constructor. |
| `data/script/src/systems/team/ferry.as` | Transport ferry policy: the AIR/TECH request protocol over `AiSendMessage`, and the donation hand-over. See `../rjm.bar.docs/projects/circuitai/transport-ferry.md`. |
| `data/script/src/helpers/construction/sea_constructor_helpers.as` | The naval economy ladder a construction ship runs (T2 shipyard, mex upgrades, naval converter, nanos, tidals; advanced converter and naval fusion for a T2 sub), parameterised by a `Settings` object so SEA and TACTICAL share one policy. See `../rjm.bar.docs/projects/circuitai/roles/sea.md` and `../rjm.bar.docs/projects/circuitai/roles/tactical.md`. |
| `data/script/src/helpers/spatial/layout_helpers.as` | Base-layout policy entry point and lane-facing selection; canonical footprint and slot geometry is native. See `../rjm.bar.docs/projects/circuitai/base-layout.md`. |
| `data/script/src/roles/tech/tech_build.as` | `TechBuild` (D-066): the acts of TECH's experimental build system - turrets, keep-current, the start factory on its slot, T1-lab reclaim, mex expansion, defence, native's queued repairs, assist, guard, wait - and `MakeTask`, which evaluates the rule table; never null. See `../rjm.bar.docs/projects/circuitai/roles/tech_build.md`. |
| `data/script/src/roles/tech/tech_weapons.as` | `TechWeapons` (D-126): TECH's weapon clusters - kill zones, air defence, artillery, long range, super cannon, coast - found at strategic defence points, re-ranked, income gated, budgeted; rows `weapons.cluster` and `weapons.super`. See `../rjm.bar.docs/projects/circuitai/roles/tech_weapons.md`. |
| `data/script/src/systems/world/lanes.as` | `Lanes` (D-127): lanes between both teams' starts per movement class, drawn after the intro, recalculated as the front moves, `BestLane` for attack planning. See `../rjm.bar.docs/projects/circuitai/roles/tech-lanes.md`. |
| `data/script/src/systems/world/water_theatres.as` | D-128: read-only pond/sea classification over native connected water bodies, start-based shore affiliation, terrain-tested advisory shipyard/tidal/seaplane sites. No placement or task changes. See `../rjm.bar.docs/projects/circuitai/roles/tech-lanes.md`. |
| `data/script/src/systems/world/strategic_sites.as` | D-129: advisory geothermal forward coverage, isolated dry-land islands and joined defend/assault beach fronts. All calculations remain AI-side; the BARb control widget only renders. |
| `data/script/src/roles/tech/tech_rules.as` | `TechRules` (D-067): TECH's whole builder sequence as one ordered table of `(key, who, when[], act)` rows over a context built once per ask; named predicates, `[Rule] <key>` trace. The T1-lab cases (opening, recover, spam) are three rows. See `../rjm.bar.docs/projects/circuitai/roles/tech_rules.md`. |
| `data/script/src/systems/construction/eco_planner.as` | `EcoPlanner` (D-058/D-063): TECH's one next-building function after the mex-first opening - energy draining, energy floating (converter), build power short or metal floating (turret), energy below target, storage - offering only what the turret box can hold and placing through `Layout::Place`. See `../rjm.bar.docs/projects/circuitai/eco-planner.md`. |
| `data/script/src/systems/construction/layout.as` | `Layout` (D-060/D-063): TECH's policy shell over native layout geometry. It chooses the factory-pair candidate, fits the turret box behind it (rows of invisible turrets reserved slot by slot on the flattest buildable rectangle), adopts named state after load, and packs every economy structure and turret against the turret rows (native `PackNearGroup`, `NextSlotAny`), pinned. See `../rjm.bar.docs/projects/circuitai/layout-design.md`. |
| `data/script/src/helpers/combat/porc_helpers.as` | Porcupine chain policy: reads the config-seeded chain through `aiMilitaryMgr.GetPorcChain`, appends the content-option tiers, and lets a role rewrite it. See `../rjm.bar.docs/projects/circuitai/porc-chain.md`. |

### Reference only - `data_sample/`

| Path | Description |
| --- | --- |
| `data_sample/` | Upstream sample AngelScript and JSON kept for reference and historical comparison. Mirrors the `data/` shape: `AIInfo.lua`, `AIOptions.lua`, `config/` (with `dev/`), and `script/` (`common.as`, `define.as`, `task.as`, `unit.as`, with `dev/`). Never implement, mirror, or apply a requested change here unless the user explicitly asks for sample maintenance. |

### Native C++ - `src/`

| Path | Description |
| --- | --- |
| `src/AIExport.cpp`, `src/AIExport.h` | Skirmish AI ABI entry points that the engine loads. |
| `src/circuit/CircuitAI.cpp`, `src/circuit/CircuitAI.h` | Top-level AI object: engine event dispatch, module ownership, lifecycle. |
| `src/circuit/module/` | Native managers - `BuilderManager`, `EconomyManager`, `FactoryManager`, `MilitaryManager` - over the `Module` and `TaskModule` bases. |
| `src/circuit/script/` | AngelScript integration and the registration surface: `InitScript`, `ModuleScript`, the per-manager `BuilderScript`, `EconomyScript`, `FactoryScript`, `MilitaryScript`, plus `Script.cpp` and `RefCounter.h`. **A native C++ method is not script-accessible unless it is registered here.** |
| `src/circuit/task/` | Task hierarchy: `UnitTask`, `IdleTask`, `NilTask`, `PlayerTask`, `RetreatTask`, plus the `builder/`, `common/`, `fighter/`, and `static/` task families. |
| `src/circuit/unit/` | `CircuitDef` (UnitDef wrapper and classification), `CircuitUnit`, `CircuitWDef` (weapon defs), `CoreUnit`, `FactoryData`, and the `action/`, `ally/`, `enemy/` subtrees. Classification and economy logic that reads BAR custom parameters lives here. |
| `src/circuit/map/` | `MapManager`, `ThreatMap`, `InfluenceMap`, `GridAnalyzer`. |
| `src/circuit/resource/` | Resource model: `MetalData`, `EnergyData`, `EnergyManager`, `EnergyGrid`, `EnergyLink`, `EnergyNode`, `GridLink`. |
| `src/circuit/terrain/` | `TerrainManager`, `TerrainData`, blocking-map geometry (`BlockingMap`, `BlockCircle`, `BlockMask`, `BlockRectangle`), `BaseLayoutGeometry.h` (dependency-free half-cell factory/module geometry), `BattleAnalysis` and `BattleLanes` (D-126, D-127: range with height, routes, chokes, heat, composition, water, beaches, lanes; bound as `aiBattle`), `FieldService` (D-323: the battlefield map analysis run once per process by the first AI whose profile enables `data/config/field.json`, owned by `CGameAttribute`, published once to `LuaUI/Config/BARb/field/map.txt` for the team-link widget; no manager or script reads it, enforced by `tools/knowledge/check_field_isolation.py`) over the engine-free core `field/` (`FieldTypes.h`, `FieldGrid.h`, `FieldAnalysis.*`: mobility and the per-cell ground class (D-326), sides, theatres, clearance-watershed regions, boundary runs, landings, standoff contours, avenues, key terrain; `FieldEncode.*`: the file grammar), and `path/` with `PathFinder`, `MicroPather`, `PathQuery`, `PathInfo`, and the cost and line query maps. |
| `src/circuit/setup/` | `SetupManager`, `SetupData`, `DefenceData`: start position, faction selection, and defence layout. |
| `src/circuit/scheduler/` | `Scheduler` and `SchedulerJob` for deferred and periodic work. |
| `src/circuit/spring/` | Adapters over Recoil's generated C++ AI wrapper: `SpringCallback`, `SpringEngine`, `SpringMap`, `SpringUnit`. |
| `src/circuit/util/` | Shared utilities: `Action` and `ActionList`, `AvailList`, `Container`, `Data`, `Defines.h`, `ExtAS.h`, `FileSystem.h`, `GameAttribute`, `DebugDrawer`, and math and geometry helpers. |
| `src/lib/` | Vendored third-party libraries: `angelscript/`, `asbind20/`, `json/`, `kdtree/`, `lemon/`, `triangulate/`. Do not edit unless the task explicitly targets them. |
| `src/lib/README.md` | Provenance and upstream source for each vendored library. |

### Documentation - `../rjm.bar.docs/projects/circuitai/`

| Path | Description |
| --- | --- |
| `../rjm.bar.docs/projects/circuitai/TRUSTED_REFERENCE_REPOSITORIES.md` | The external-reference map: how the read-only BAR and Recoil clones and the writable shared knowledge base inform work here. |
| `../rjm.bar.docs/projects/circuitai/angelscript-references.md` | The current script loading model, callback contracts, registered C++ API, ownership rules, and practical usage examples. Read before AngelScript work. |
| `../rjm.bar.docs/projects/circuitai/units.md` | Catalog of the 659 effective non-Scavenger BAR UnitDefs (215 Armada, 213 Cortex, 231 Legion). Use with the shared knowledge base before changing UnitDef classifications, factory edges, or behaviour properties. |
| `../rjm.bar.docs/projects/circuitai/extra_units.md` | Catalog of the 41 UnitDefs made player-buildable by BAR's `experimentalextraunits=true` option. |
| `../rjm.bar.docs/projects/circuitai/Profile.md` | How profiles are deployed and how to add a custom one, including the `AIOptions.lua` `profile` list and the `BARb/stable/` install layout. |
| `../rjm.bar.docs/projects/circuitai/run-multiple-bar-instances.md` | Stand-alone guide for running several BAR games at once on Windows with a separate `--write-dir` per copy; written for people without this repository's playtest tooling. |
| `../rjm.bar.docs/projects/circuitai/roles/README.md` | Index of the AngelScript role layer: the `RoleConfig` contract, the handler coverage matrix, cross-role findings, and the rule that keeps these documents current. |
| `../rjm.bar.docs/projects/circuitai/roles/{front,air,tech,sea,support,tactical}.md` | One reference per `AiRole`: registration, settings, init limits, decision flows, known defects. Each ends with a `<!-- source: ...; blob: ...; lines: ... -->` marker tying it to the script revision it describes. |
| `../rjm.bar.docs/projects/circuitai/roles/hover.md` | **Outstanding - not written yet**, though nine documents link to it. Intended as the deep reference for hover production: ownership, build decisions, the native contract, and the cause of hover production stalling once a T2 factory exists. Tracked as `KI-404` in `../rjm.bar.docs/projects/circuitai/known-issues.md`. |
| `../rjm.bar.docs/projects/circuitai/intent.md` | **Design intent**: the long-term goal of driving the AI from the game's mission/objective API, the short-term goal of playing like a strong player, and the rule that build orders and behaviour policy stay controllable from AngelScript. Read before deciding where a behaviour belongs. |
| `../rjm.bar.docs/projects/circuitai/porc-chain.md` | Static-defence ordering: the `porcupine` block in `build_chain.json`, per-role override through `RoleConfig::PorcChainHandler`, and the additive Extra Units / Scavenger tiers. |
| `../rjm.bar.docs/projects/circuitai/decisions.md` | **The decision record**: why changes were made, what was rejected, and how far each is verified. Links directly to every file a decision touched. Read before reversing anything surprising; add to it whenever you make a judgement call. |
| `../rjm.bar.docs/projects/circuitai/practice-invariants.md` | **The invariant practice (D-076)**: one lifecycle state per structure, every bug becomes an invariant with an in-game check, an actor matrix per object, play the fix. Enforced by `tools/knowledge/check_invariants.py` in the pre-commit hook. Read before fixing a behaviour bug. |
| `../rjm.bar.docs/projects/circuitai/invariants.md` | The register of `INV-nnn` promises the scripts check once a second and log as `[INVARIANT]`; every playtest check file forbids that line. |
| `../rjm.bar.docs/projects/circuitai/actor-matrix.md` | Per object (labs, frames, turret slots, mex spots, banks): every actor and the state it reads. Every TECH rule row must appear here. |
| `../rjm.bar.docs/projects/circuitai/known-issues.md` | **The register of diagnosed but unresolved problems**, one entry per issue with problem, proposed solution and verification. Read before starting work; add to it whenever you leave something unfixed. Indexes the deep-dive documents below rather than duplicating them. |
| `../rjm.bar.docs/projects/circuitai/transport-ferry.md` | The AIR-to-TECH transport ferry: the hand-over protocol, `CFerryTask`, and how a donated T2 constructor is flown instead of walked. |
| `../rjm.bar.docs/projects/circuitai/base-layout.md` | Current TECH layout architecture: JSON/script gating, native half-cell geometry, atomic factory clusters and full/half economy modules, exact pin lifecycle, save/load, and standalone tests. |
| `../rjm.bar.docs/projects/circuitai/reviews/2026-09-20-uncommitted-code-review.md` | The external review of the 2026-09-20 change set: 25 findings, verified accurate. |
| `../rjm.bar.docs/projects/circuitai/reviews/2026-09-20-code-review-fixes.md` | The fixes applied for D-059, one section per finding with before/after code, diagrams and screenshot placeholders. |
| `../rjm.bar.docs/projects/circuitai/reviews/2026-09-20-uncommitted-highlights.md` | The 100 highlights of the uncommitted change set as of 2026-09-20, grouped by area, with the state (what is built, deployed, played) and the loose ends. |
| `../rjm.bar.docs/projects/circuitai/reviews/2026-09-20-d062-review.md` | Review of the D-060 / D-062 economy and layout rebuild: what was verified, seven findings (R-1 the opener can hold the start factory for ever), recommendation. No code changed. |
| `../rjm.bar.docs/projects/circuitai/eco-planner.md` | The eco planner (D-058): the meta's numbers, the inputs, the function, worked openings, where each structure goes, settings. |
| `../rjm.bar.docs/projects/circuitai/experimental-build.md` | D-064: the experimental build mode - the engine's build-range rule quoted from Recoil, the goal-region theory (stop on the disc `0.9 (reach + model radius)`, one command per engagement, no command timeout, the engine walks the last leg inside 1,600 elmos), the alternatives rejected, settings, what to watch. TECH only. Not Played. |
| `../rjm.bar.docs/projects/circuitai/tech-eco-meta.md` | D-062: TECH's three-resource model, Supreme three-mex/six-wind opener, queued-aware storage, converter surplus rules, regional build power, compact recycling layout, and four-row Supreme profile. |
| `../rjm.bar.docs/projects/circuitai/layout-design.md` | D-060 and D-063: TECH's layout design - the exact factory pair with rear nano clusters and exits, the turret box (terrain-fitted rectangle, turret rows as invisible slots, economy packed nearest a turret within reach), ordered pins, atomic reservations, JSON/script gating and save/load adoption; the D-060 economy module kept as record. Not Played. |
| `../rjm.bar.docs/projects/circuitai/sensor-escort.md` | Mobile radar/jammer escort rationing: the one-per-squad cap, the squad-value ranking that orders it, and the `sensor` block in `behaviour.json`. |
| `../rjm.bar.docs/projects/circuitai/bomber-targeting.md` | Diagnosed but unfixed bomber-targeting investigation with a phased remediation plan. |
| `../rjm.bar.docs/projects/circuitai/t2-constructor-stall.md` | Diagnosed but unfixed T2 constructor stall after mex upgrades, with three options awaiting a decision. |
| `../rjm.bar.docs/projects/circuitai/juno-targets.md` | Juno target-priority policy: the four pulse target classes and their order, the `pulse` block in `behaviour.json`, `CSuperTask::SelectPulseTarget`, and what happens when nothing qualifies. Game mechanics live in the shared knowledge base. |
| `../rjm.bar.docs/projects/circuitai/emp-targets.md` | EMP target-priority policy: the stun-viability arithmetic, the rank order, the `emp` block in `behaviour.json`, `CSuperTask::SelectEmpTarget`, and what happens when nothing qualifies. Game mechanics live in the shared knowledge base. |
| `../rjm.bar.docs/projects/circuitai/start-position-control.md` | Research: how an AI could choose its start position without engine or game changes - the engine's `Game_sendStartPosition` path, why BAR discards it for AI teams (`AllowStartPosition`), BAR's `aiPlacedPosition` LuaRules message, and a proposal to broker it through the host widget. Proposal only. |
| `../rjm.bar.docs/projects/circuitai/air-wave-attacks.md` | AIR bomber waves: the income-scaled wave size, the line-abreast formation, the attack vector and the six attack methods (CARPET, FLANK, PINCER, STRIKE, DEEP, FEINT), `CAirWaveTask` and its script API. |
| `../rjm.bar.docs/projects/circuitai/launcher-targets.md` | Tactical launcher (Perdition, Catalyst) targeting: why the enemy-group scan never saw a target at 2300 range, `CSuperTask::SelectLauncherTarget`, the decaying stockpile floor, the `stockpile` block in `behaviour.json`, and who hands a super static its task. |
| `../rjm.bar.docs/projects/circuitai/knowledge/README.md` | Index of CircuitAI-specific knowledge and the pointer to the shared game knowledge base. |
| `../rjm.bar.docs/projects/circuitai/knowledge/90-agent-decision-guides/` | Agent decision guides tied to this AI's hooks: `90-decision-architecture.md`, `91-build-order-selection.md`, `92-response-tables.md`, `93-engagement-rules.md`, `94-economy-policies.md`, `95-open-questions.md`. |
| `../rjm.bar.docs/projects/circuitai/knowledge/barb-unit-config.md` | Generated: every reachable unit's roles, attributes, limits, threat, factory lists, and script references across all profiles, joined to the shared unit cache, plus the configuration gap lists. |
| `../rjm.bar.docs/projects/circuitai/knowledge/barb-status-by-topic.md` | Where this AI stands against each game-knowledge topic. |

### Tooling, build, and support

| Path | Description |
| --- | --- |
| `tools/knowledge/barb_report.py` | Regenerates `../rjm.bar.docs/projects/circuitai/knowledge/barb-unit-config.md`. Run `python tools/knowledge/barb_report.py` after profile or unit-cache changes. |
| `tools/knowledge/check_unit_helpers.py` | Validates every quoted unit id in `data/script/src` against the shared game cache (unknown, unreachable, wrong faction or tier, per-side branches) and reports combat-list coverage. Exit 1 on findings. |
| `tools/knowledge/check_doc_links.py` | Verifies that every relative Markdown link under `../rjm.bar.docs/projects/circuitai/`, `data/script/`, `skills/` and the root instruction files resolves to a file that exists. Exit 1 on findings. Run before finishing any documentation change. |
| `tools/knowledge/check_script_api.py` | Verifies every `aiXxx.Member` the AngelScript policy uses is registered in `src/circuit/script/*.cpp`, and with `--dll <installed SkirmishAI.dll>` that the registration strings are inside that binary and the file is a stripped ~7 MB build. Run before every launch; a script deployed ahead of its DLL leaves every AI standing at frame 0. |
| `skills/ai-not-moving/SKILL.md` | The runbook for "the commander does not move at game start": find the last game's `ERR` lines in `infolog.txt`, the message-to-cause table, script/DLL parity with the checker, the deploy rules (ship script and DLL together; never copy from the Recoil install dir mid-build), what to do when there are no `ERR` lines, where to record the case. |
| `tools/playtest/` | The playtest loop: stage a pinned DLL/data into an isolated write directory, launch, watch, archive the original checks/log/report and screenshots under `runs/<UTC-id>/`. Cases and checks are categorized by domain and area; old short names and explicit paths still resolve. AIR and scorecard runners allocate unique categorized directories by default. Doc: `tools/playtest/README.md`. |
| `tools/playtest/engine_process.py`, `tools/playtest/widgets/playtest_lifecycle.lua`, `tools/playtest/test_runner_lifecycle.py` | Identity-checked engine handles, wall-clock shutdown/heartbeat, and runner lifecycle/verdict regression tests. |
| `tools/playtest/run_commander_regression.py`, `tools/playtest/run_commander_performance.py` | Check-driven commander scenarios and serial pinned cost comparisons with full natural-game horizons. |
| `tools/playtest/build_native_snapshot.py`, `tools/playtest/test_build_native_snapshot.py` | Read-only engine integration against a pinned source snapshot, with content-validated compiler-cache reuse. |
| `tools/playtest/storage.py`, `tools/playtest/storage-aliases.json` | D-178: canonical case/check resolution with legacy aliases, unique game allocation, immutable result publication and benchmark indexing. New raw games use `../CircuitAI.benchmarks/build-theatres/games/<domain>/<area>/<scenario>/<map>/<UTC-id>/`; existing raw directories are retained. |
| `tools/playtest/cases/`, `tools/playtest/checks/` | Reusable scenario/check definitions under `<domain>/<area>/`. Never mix raw engine outputs with definitions. Naming rules are in each directory's README. |
| `../rjm.bar.docs/projects/circuitai/test-storage.md`, `../rjm.bar.docs/projects/circuitai/test-storage-moves.md`, `../rjm.bar.docs/projects/circuitai/test-storage-migration.json` | Storage conventions, linked migration inventory and one-time byte-preservation audit for the definition moves and historical benchmarks/images. |
| `../CircuitAI.benchmarks/doc/benchmarks/` | Benchmark discovery by gameplay domain; generated indices distinguish original evidence, views and revisions. New compact immutable bundles live under `records/<domain>/<area>/<scenario>/<date>/<UTC-id>/`. Existing ledgers and scorecard paths remain unchanged. |
| `data/script/src/roles/tech/tech_chain.as` | `TechChain` (D-070): TECH's rush chain - `Tech::RushObjective` (t2/fusion/afus/nuke/gantry/titan/eco/auto) becomes an ordered list of cumulative targets computed from the map's wind (the rush simulator's lines); the `chain.next` row executes it ahead of the economy rows; caps re-asserted in `Tick`. See `../rjm.bar.docs/projects/circuitai/roles/tech_chain.md`. |
| `tools/playtest/bench_loop.sh` | `SPEED=8 NOTE=... bash tools/playtest/bench_loop.sh t2 fusion afus nuke gantry titan`: one headless tech-versus-tech run per objective with `--set RushObjective`, each recorded by the tracker; `DLL=<path>` tests a specific DLL. |
| `tools/playtest/benchmark.py` | Turns a playtest run into a row of `../CircuitAI.benchmarks/doc/benchmarks/tech-rush.md` (milestone times from the widget's `[Playtest] finished` lines, income, best-so-far table). |
| `../CircuitAI.benchmarks/doc/benchmarks/tech-rush.md` | Generated by the tracker: the rush benchmark targets, floors, the best run per objective and every recorded run. |
| `skills/playtest/SKILL.md` | Running local simulations: pin the build, the compile check, launching (write dirs, flags, maps, teams, settings), fast-forwarding with speed plans, screenshots, test widgets, judging and reading the logs (handed to `skills/troubleshoot-bar-logs`), stopping, checks files, benchmarks, and the traps met in past runs. |
| `skills/playtest/references/widgets.md` | Writing a test widget for playtests: skeleton, tags, error detection, camera, cheats for targets, stroke counting, AI-to-widget messages, persisted widget config. |
| `tools/knowledge/check_role_docs.py` | Verifies `../rjm.bar.docs/projects/circuitai/roles/*.md` against `data/script/src/roles/*.as`: source marker (blob hash + line count), every role function and wired slot named, README matrix consistent. `--update` rewrites the markers after review. Exit 1 on findings. |
| `../rjm.bar.docs/projects/circuitai/spam-routes.md` | The economy-gated spam feature: `spam` attribute, `Global::Spam` settings, `Spam::` manager, native `CRouteTask`, focus and lane geometry. |
| `tools/widgets/gui_barb_team_link.lua` | LuaUI widget for the host machine, docked as a "Player / AI" tab strip on top of the bottom-right player-list stack; the AI tab opens a panel of the list's width above the strip, adding to the stack (D-061): Team and AI dropdown menus, then the selected AI's status, the runtime role selector, Query / Overlay / Query all, the event log. Displays what allied BARb instances mirror through `ai.CallUI` (`data/script/src/systems/presentation/widget_link.as`), including the team roster, orphan-rescue events, and `/barblayout` rendering of native layout zones and slot states. Copy into the BAR `LuaUI/Widgets` folder. |
| `tools/widgets/deploy_widgets.py` | Copies every `tools/widgets/*.lua` into the local BAR install. **For the owner to run**: the assistant never writes to the game install (2026-09-21). |
| `tools/playtest/checks/shared/terrain/theatres_supreme.json`, `tools/playtest/widgets/theatres_watch.lua` | D-128: Supreme Isthmus topology, no pond shipyard, friendly-pond opportunities, integrated player/all/off controls and strategic-site checks; stage the control widget plus watcher. |
| `tools/playtest/checks/shared/terrain/field_terrain.json`, `tools/playtest/checks/shared/terrain/field_supreme.json`, `tools/playtest/widgets/field_watch.lua` | D-323 / D-326: one `FIELD_PERF` per process, the team-link widget's Terrain view loaded from the field file with its ground classes, and a screenshot series (full map, dim sheet, blueprint mode, ground classes alone, each sea and pond, summits, the narrowest choke, the legend); `field_terrain.json` fits any map, `field_supreme.json` adds Supreme Isthmus counts. Stage the control widget plus watcher with `--mode visual --shots ""`. |
| `tests/field_analysis_test.cpp` | D-323: the field analysis on a synthetic isthmus map (theatres, shore kinds, a choke, landings, avenues, determinism, file header round trip); with a path argument it replays a dumped game input (`field.json` `dump_input`) and prints the summary. In `tools/run_native_tests.sh`. |
| `tools/knowledge/check_field_isolation.py` | D-323: fails when any native file outside the field service or any script outside `systems/presentation/` reads the field. Run after touching `src/circuit/` or `data/script/`. |
| `.githooks/pre-commit` | Refuses a commit that stages a role script without its document, and runs `check_role_docs.py` when either is staged. Enable with `git config core.hooksPath .githooks`. |
| `CMakeLists.txt` | Native build definition. Building requires integration into an engine checkout and Recoil's generated C++ AI wrapper. |
| `tests/CMakeLists.txt`, `tests/base_layout_geometry_test.cpp` | Standalone C++20 tests for dependency-free base-layout geometry; configure with `cmake -S tests -B build-layout-tests`. The root `CIRCUIT_BUILD_TESTS` option adds the same target when CircuitAI is configured by its engine parent. |
| `VERSION` | AI version string. |
| `platform/angelscript/jit/` | AngelScript JIT compiler sources (`as_jit.cpp`, `virtual_asm*`). Platform support, not policy. |
| `util/` | Development aids that are not shipped: `boost_log.sh`, `cpu_load.cpp`, `crash_test.py`, the `fibR.as` and `fibR.lua` benchmarks, `gdb.cmd` and `gdb.sh`, `head.script`, `tracy.txt`, `weight_normal.txt`. |
| `util/LuaRules/Gadgets/ai_chokepoint.lua`, `util/LuaRules/Gadgets/ai_dbg_map.lua` | In-game debug gadgets for visualising chokepoints and AI map data. |
| `Vagrantfile` | Vagrant build environment definition. |
| `CircuitAI.uxf` | UMLet class diagram of the native design. |
| `.cproject`, `.project` | Eclipse CDT project files. |
| `README.md` | Upstream build and run notes; self-marked as needing an update. |
| `LICENSE` | License text. |
| `BARB5_CHANGELOG.md` | Small navigation pointer to the historical BARb5 changelog in the documentation checkout. |
| `../rjm.bar.docs/projects/circuitai/changelog/YYYY/MM/DD/` | Date-partitioned changelog entries. Created only on explicit request, via `skills/maintain-changelog/SKILL.md`. |

### External paths

| Path | Access | Description |
| --- | --- | --- |
| `../rjm.bar.docs/` (`C:\bardev\rjm.bar.docs`) | writable | Shared game knowledge base for every project under `C:\bardev`, and the central source of game truth. See "Game and Engine Knowledge Base". |
| `../rjm.bar.docs/AGENTS.md` | writable | That repository's own agent instructions; follow them when writing there. |
| `../rjm.bar.docs/knowledge/README.md` | writable | Entry point for every game and engine question - search here first. |
| `../rjm.bar.docs/knowledge/30-units/<faction>/<id>.md` | writable | One page per unit, factions `armada`, `cortex`, `legion`; `39-unit-schema.md` defines the page shape. |
| `../rjm.bar.docs/knowledge/20-game-mechanics/20-lua-mechanics-catalog.md` | writable | Engine and Lua mechanics catalog, alongside `21-resources.md`, `22-tech-tiers.md`, `23-special-systems.md`, `24-game-modes-and-options.md`. |
| `../rjm.bar.docs/knowledge/` (remainder) | writable | `00-glossary.md`, `10-engine/`, `40-roles-and-counters/`, `50-economy/`, `60-tactics/`, `70-strategy/`, `80-theory/`, `appendix/`, `img/`. |
| `../rjm.bar.docs/tools/knowledge/extract.py` | writable | Refreshes the shared unit cache that `tools/knowledge/barb_report.py` joins against. |
| `C:\bardev\bar-Beyond-All-Reason` | **read-only** | BAR game clone: UnitDefs, WeaponDefs, MoveDefs, build menus, custom parameters, faction and mod options, Lua rules, models, unit scripts. |
| `C:\bardev\bar-Beyond-All-Reason\gamedata\unitdefs.lua` | **read-only** | Recursively loads `units/**/*.lua` and gates Legion, Scavenger, Raptor, and extra content on game and mod options. |
| `C:\bardev\bar-Beyond-All-Reason\gamedata\unitdefs_post.lua` | **read-only** | Normalises and transforms UnitDefs after loading. |
| `C:\bardev\bar-Beyond-All-Reason\gamedata\alldefs_post.lua` | **read-only** | Further post-processing that can alter build options and properties. |
| `C:\bardev\bar-Beyond-All-Reason\gamedata\unitDefRenames.lua` | **read-only** | Legacy-to-descriptive unit name mappings. This repository's configuration still uses legacy internal names. |
| `C:\bardev\bar-RecoilEngine` | **read-only** | Engine clone: Skirmish AI ABI, callbacks, events, commands, C++ wrapper generation, loading, engine integration. |
| `C:\bardev\bar-RecoilEngine\.gitmodules` | **read-only** | Declares `AI/Skirmish/BARb` and `AI/Skirmish/CircuitAI` as submodules. Verify the layout of any given checkout rather than assuming it. |
| `%LOCALAPPDATA%\Programs\Beyond-All-Reason\data\` | runtime | BAR's writeable data directory: `infolog.txt`, `log/`, `demos/`, `_script.txt`, `ClientGameState-*.txt`. See "Runtime Logs and Diagnostics". |

## Game and Engine Knowledge Base

Game knowledge that is not specific to this AI lives in the sibling
repository `C:\bardev\rjm.bar.docs` (relative: `../rjm.bar.docs`). It is the
central source of game truth for every project under `C:\bardev`: one page per
unit with thumbnails, engine and Lua mechanics, economy arithmetic, counters,
tactics, strategy and theory, all with provenance front-matter.

- For any question about the game or engine - a unit's stats or counters, a
  mechanic, a mod option, an economy number, how something is played - search
  `../rjm.bar.docs/knowledge/` **first**: start at `knowledge/README.md`,
  units at `knowledge/30-units/<faction>/<id>.md`, mechanics at
  `knowledge/20-game-mechanics/20-lua-mechanics-catalog.md`. Read the BAR or
  Recoil trees only when the knowledge base lacks the fact, and then record
  the fact there (it is writable; follow its `AGENTS.md`).
- Knowledge specific to CircuitAI stays in this repository:
  `../rjm.bar.docs/projects/circuitai/knowledge/README.md` indexes it (agent decision guides, the generated
  `barb-unit-config.md` joining our profiles to the shared unit cache, and
  `barb-status-by-topic.md`). Regenerate the join with
  `python tools/knowledge/barb_report.py` after profile or cache changes.
- Do not copy game facts into this repository; link or name the path in the
  knowledge base instead. Do not put AI-implementation detail into the
  knowledge base.

## Trusted Read-Only References

Two sibling repositories are authoritative local references:

| Repository | Path | Use |
| --- | --- | --- |
| Beyond All Reason game | `C:\bardev\bar-Beyond-All-Reason` | UnitDefs, WeaponDefs, MoveDefs, build menus, custom parameters, faction/mod options, Lua rules, models, and unit scripts |
| RecoilEngine | `C:\bardev\bar-RecoilEngine` | Skirmish AI ABI, callbacks, events, commands, C++ wrapper generation, loading, and engine integration |

Treat both paths as strictly read-only, even when a requested change appears to belong there.

- Never edit, create, delete, rename, format, or generate files in either tree.
- Never run builds, tests, package installation, code generation, formatters, checkout, reset, clean, submodule update, or other write-producing commands there.
- Limit commands with an external repository as their working directory to inspection such as file reads, directory listings, `git status`, `git log`, `git show`, `git diff`, `git grep`, and `git ls-files`.
- Put every requested implementation or documentation change in this CircuitAI repository. If an upstream change is needed, report it and identify its target file without applying it.
- Do not follow a path into an external tree and then write through it. Resolve links and repository boundaries before editing.

Recoil's `.gitmodules` declares `AI/Skirmish/BARb` and `AI/Skirmish/CircuitAI` as Git submodules. In the currently inspected checkout they are ordinary submodule worktree directories, not symbolic links. Do not assume another checkout has the same filesystem layout; verify it read-only when integration details matter.

## Source-of-Truth Routing

Use the narrowest authoritative source for a question:

- CircuitAI behavior, bindings, and configuration: this repository.
- Game and engine facts, mechanics, unit data and doctrine: `../rjm.bar.docs/knowledge/` first (see "Game and Engine Knowledge Base"), then the read-only BAR and Recoil trees for anything it lacks.
- Names and properties visible after BAR game-data loading: BAR's effective UnitDef pipeline, not a raw unit file alone.
- Engine callback availability or ABI behavior: Recoil's C interface and generated C++ wrapper inputs, not stale Spring documentation.
- AngelScript availability: registration code under `src/circuit/script/`. A native C++ method is not script-accessible unless it is registered.

For BAR compatibility work, account for this pipeline:

1. `gamedata/unitdefs.lua` recursively loads `units/**/*.lua` and gates Legion, Scavenger, Raptor, and extra content using game and mod options.
2. `gamedata/unitdefs_post.lua` normalizes and transforms definitions; `gamedata/alldefs_post.lua` and Scavenger post-processing can further alter build options and properties.
3. Invalid build options are removed when their target UnitDef is absent.
4. `gamedata/unitDefRenames.lua` records legacy-to-descriptive name mappings. CircuitAI configuration currently uses legacy internal names, so verify the actual runtime name before migrating identifiers.

When changing classification or economy logic, check BAR values used by CircuitAI, including `level`, `pylonrange`, `income_energy`, `energyconv_capacity`, `energyconv_efficiency`, `isairbase`, `canjump`, `jump_range`, `is_drone`, `dynamic_comm`, `iscommander`, and relevant weapon custom parameters. Treat optional-faction units as unavailable unless the corresponding BAR option makes them loadable.

## Engineering Workflow

- Start from the failing behavior, binding, profile, or configuration entry and trace to the code that controls it.
- Preserve existing C++ and AngelScript style and keep changes scoped.
- Make AngelScript and profile changes in `data/`, never `data_sample/`; the latter is reference-only unless the user explicitly requests sample maintenance.
- Do not edit vendored libraries under `src/lib/` unless the task explicitly targets them.
- A behaviour fix follows `../rjm.bar.docs/projects/circuitai/practice-invariants.md` (D-076): the state it changes lives in one owner (`Lifecycle` for structures) and every actor reads it there; the decision names its invariant (`**Invariant.**`), the script logs `[INVARIANT] INV-nnn` when it is broken, `../rjm.bar.docs/projects/circuitai/invariants.md` gets the row, `../rjm.bar.docs/projects/circuitai/actor-matrix.md` lists every actor on the object, and a played run is named. `python tools/knowledge/check_invariants.py` must exit 0; the pre-commit hook runs it.
- Any change under `data/script/src/roles/` must be reflected in the matching `../rjm.bar.docs/projects/circuitai/roles/<role>.md` in the same change (rules in `../rjm.bar.docs/projects/circuitai/roles/README.md`, "Keeping these documents current"), then `python tools/knowledge/check_role_docs.py --update` refreshes that document's source marker. A change to `types/ai_role.as` or `types/role_config.as` also updates `../rjm.bar.docs/projects/circuitai/roles/README.md`.
- Do not assume a generic AngelScript interface exposes derived-type members. Use registered casts and handle a null cast result.
- Do not infer a valid factory edge merely because both UnitDefs exist. Verify the builder's effective BAR `buildoptions` under the relevant mod options.
- Avoid changing the legacy profiles (`easy`, `medium`, `hard`, `hard_aggressive`) and the shared-framework profiles (`experimental_balanced`, `experimental_hard`, `experimental_terrible`) together unless the requirement explicitly spans them.
- When a change is scoped to one profile family, record the other family in `../rjm.bar.docs/projects/circuitai/known-issues.md` rather than leaving the gap undocumented.

## Native C++20

These instructions live at the repository root so one canonical rule set
covers every project-owned C++ directory. Apply them to new or modified code
in `src/AIExport.*` and `src/circuit/`. Apply the general portability and
safety rules to a project-owned utility only when the current task targets it.

- `src/lib/` is vendored. Do not modernize, restyle, or otherwise edit it
  unless the task explicitly targets that dependency; prefer an attributable
  upstream patch.
- `platform/angelscript/jit/` is platform and ABI support. Preserve its
  calling-convention, executable-memory, and architecture assumptions, and
  require targeted platform validation for any change there.
- `util/cpu_load.cpp` is a standalone development aid, not shipped AI code;
  do not impose engine-wrapper, task, or scheduler patterns on it.
- Apply these rules incrementally to lines and interfaces changed for the
  current task. Do not refactor, format, rename, or "modernize" unrelated C++
  merely to make old code conform.

### Language and portability

- CircuitAI's target is **C++20** (`CMakeLists.txt`), even though the current
  Recoil parent builds the engine as C++23. Do not use C++23 language or
  library features in CircuitAI code.
- Use standard C++20 rather than compiler extensions. Keep new code portable
  across the supported GCC/MinGW, Clang/AppleClang, and MSVC code paths; gate
  genuine OS, architecture, or ABI differences explicitly.
- Preserve the existing ABI at generated Recoil wrapper, C export, save-file,
  and AngelScript boundaries. Do not change enum widths, POD layout, field
  order, calling conventions, or serialized representation incidentally.
- Use fixed-width integer types when the width is part of an ABI, wire, or
  persistent format. Elsewhere, use the domain's existing type and make
  narrowing or signed/unsigned conversions explicit and range-checked.

### Ownership and lifetime

- Prefer values and RAII. Use `std::unique_ptr` for new sole ownership and
  `std::shared_ptr` only when ownership is genuinely shared.
- Treat an unannotated raw pointer as borrowed and nullable. Document any
  exceptional owning raw pointer required by a generated wrapper, intrusive
  AngelScript reference counting, or an existing manager/task ownership
  contract. Do not add ordinary bare `new`/`delete` pairs when ownership can
  be transferred immediately to an RAII owner.
- Do not mechanically wrap intrusive `IRefCounter` objects or manager-owned
  tasks in standard smart pointers; follow their existing `AddRef`/`Release`
  or enqueue/dequeue ownership contract.
- A unit, enemy, engine-wrapper object, or container element pointer can become
  invalid after destruction, transfer, callback dispatch, or container
  mutation. Store a stable ID across frames, queued work, and save/load, then
  resolve and null-check it at the point of use.
- Remove pointer-keyed bookkeeping while the pointee is still alive. Never
  dereference a raw pointer after erasing it from the structure that recorded
  its lifetime.

### Interfaces and type safety

- Make local values, parameters, and member functions `const` when mutation is
  not intended. Prefer references for mandatory synchronous objects and
  pointers for optional or reseatable objects.
- Initialize every value. Prefer scoped enums, `explicit` single-argument
  constructors, `override` on overrides, and `final` when extension is not
  supported. Consider `[[nodiscard]]` for new result/status APIs whose failure
  must be handled.
- Avoid C-style casts. Use the narrowest C++ cast that expresses the operation,
  and validate a downcast unless the surrounding type discriminator proves it.
  Reserve `reinterpret_cast` and `const_cast` for documented ABI or legacy API
  boundaries.
- Validate lower and upper bounds before indexing or converting signed values
  to unsigned values. Check divisors, normalize/clamp floating-point inputs
  before inverse trigonometry, and reject non-finite or invalid positions at
  engine boundaries.
- Include what a header uses so it can compile independently; forward-declare
  only when a complete type is unnecessary. A `.cpp` should include its own
  header first. Do not put `using namespace` directives in headers.

### Containers and algorithms

- Account for iterator, reference, span, and element-pointer invalidation on
  every mutation. Use the iterator returned by `erase`, snapshot keys/items
  when callbacks can mutate the source, and do not structurally mutate a
  container from a range loop unless the operation is proven safe.
- Use `find`/`contains` for lookup. Do not use `operator[]` when a missing key
  must not insert a value.
- Reserve container capacity when the final or maximum size is predictable.
  Do not retain pointers into a `vector` after growth, and do not call
  `reserve()` repeatedly before individual appends.
- Prefer a direct scan or standard algorithm when it is clearer and no slower;
  do not sort a collection merely to select one minimum or maximum.

### Tasks, callbacks, and concurrency

- Every task must have an explicit terminal lifecycle: completion,
  cancellation, timeout, destruction, and loss of the final assignee must
  remove it from manager/scheduler containers and produce the expected script
  callback exactly once.
- A queued lambda must not capture stack references. Capturing `this` or a raw
  pointer requires a documented guarantee that the object outlives the job,
  or an explicit cancellation/weak-lifetime mechanism.
- Worker jobs operate only on owned or immutable snapshots and return
  engine-facing effects to the main thread. Do not call generated engine
  wrappers, mutate module state, or invoke AngelScript from worker threads
  unless that exact API is documented as thread-safe.
- Preserve CircuitAI's scheduler shutdown ordering. A query's `weak_ptr`
  protects the query, not other raw objects captured by its completion
  callback.

### Engine, policy, and AngelScript boundaries

- C++ provides mechanism; AngelScript or JSON owns build orders, priorities,
  strategic thresholds, and other policy. If mechanism must be native because
  script lacks data or commands, expose a script/JSON lever rather than
  hardcoding the policy.
- Treat an AngelScript declaration string, C++ signature, calling convention,
  object flags, property offset, and handle annotation as one ABI contract.
  Use the overload-safe registration macro where needed and check every
  registration result.
- Preserve `@`, `@+`, `asOBJ_NOCOUNT`, intrusive reference-counting, and
  borrowed-lifetime semantics. A native method is not available to script
  until it is registered.
- Do not let exceptions escape a C export, generated engine callback, worker
  entry point, destructor, or AngelScript native-call boundary. Translate
  failures using the existing status, logging, cleanup, and exception-guard
  pattern.
- Issue commands only to a currently valid unit through the established
  guarded command path. Revalidate IDs and task ownership after callbacks that
  can destroy, transfer, or reassign units.

### Persistence, units, and performance

- When new state affects behavior after load, update `Save` and `Load`
  together or reconstruct the state deterministically before tasks resume.
  Serialize stable IDs and explicit fields, never pointers, padding, or whole
  polymorphic objects. Validate stream state, counts, IDs, and enum ranges
  before allocation or indexing, and version intentional format changes.
- Keep simulation frames, seconds, elmos/world units, map squares, grid cells,
  ordinary distances, and squared distances explicit in names and
  conversions. Use `FRAMES_PER_SEC` for simulation time; reserve
  `std::chrono` for wall-clock work.
- Prefer squared-distance comparisons when only ordering or a threshold is
  needed. Use existing map/geometry validity and correction helpers rather
  than duplicating coordinate rules.
- In per-frame, per-unit, and candidate-scan paths, avoid repeated allocation,
  deallocation, string formatting, logging, native lookups, and shared-pointer
  churn. Reuse buffers or cache snapshots only when ownership and invalidation
  are clear; profile before adding complex caches.

### C++ validation

- Run diagnostics for each edited C++ file and the smallest relevant existing
  checks. Build the CircuitAI target in a writable Recoil integration
  environment when native code changes; never build in the trusted read-only
  Recoil checkout.
- Treat warnings in changed code as defects even when the engine suppresses
  warnings for legacy Skirmish AI submodules. Run `git diff --check`.
- For a binding change, inspect every AngelScript caller, update
  `../rjm.bar.docs/projects/circuitai/angelscript-references.md`, and load each affected profile in BAR.
- For lifecycle, threading, save/load, targeting, or command changes, static
  compilation is insufficient: exercise the affected runtime path and record
  honestly whether it was Built, Checked, Symbolised, or Played.

Research basis: the
[C++ Core Guidelines](https://isocpp.github.io/CppCoreGuidelines/CppCoreGuidelines)
(used as gradual guidance, not a mandate to rewrite legacy code), CMake's
[`CXX_STANDARD`](https://cmake.org/cmake/help/latest/prop_tgt/CXX_STANDARD.html)
contract, the
[C++20 compiler support table](https://en.cppreference.com/w/cpp/compiler_support/20.html),
and the current CircuitAI/Recoil ownership, scheduler, wrapper, serialization,
and build contracts.

## Decisions

`../rjm.bar.docs/projects/circuitai/decisions.md` records why changes were made. `known-issues.md` says what
is still broken; this says what was chosen and what it cost.

- **Add an entry for any judgement a reader could reasonably question.** A
  rejected alternative, a trade accepted on purpose, a deliberate non-change,
  or a correction to an earlier decision. Routine work needs none.
- **Link every file the decision touched**, relatively, so
  `tools/knowledge/check_doc_links.py` validates it.
- **State verification honestly** using the record's own vocabulary — Built,
  Checked, Symbolised, Played. "It compiles" is not "it works", and most
  entries are not Played.
- **Never delete a decision that turned out wrong.** Mark it, link forward to
  the correction, and say what the wrong reasoning was. That is the part with
  lasting value.
- **Keep it in step with the register.** A decision that leaves something open
  links to its `KI-`; the `KI-` links back.

## Known Issues

`../rjm.bar.docs/projects/circuitai/known-issues.md` is the register of diagnosed but unresolved problems. It
is not a backlog of ideas: an entry exists because someone understood a problem
well enough to describe its cause and a concrete fix.

- **Read it before starting work.** It records what is already understood,
  including several features that are inert rather than broken, so you do not
  spend time re-diagnosing them.
- **Add an entry whenever you leave a problem unfixed.** That includes a defect
  found while doing something else, a feature discovered to be dead or
  disabled, a fix scoped to one profile family, and a fix applied but not yet
  verified in a game. If you understood it well enough to explain it in a
  summary, it is understood well enough to record.
- **Every entry needs problem, proposed solution and verification.** The
  proposed solution must carry enough detail to start work: the approach, the
  files to touch, and the traps. "Needs investigation" is not ready for the
  register.
- **Never delete an entry to shorten the list.** Remove one only when the issue
  is genuinely resolved, and say so in the commit message. IDs (`KI-<area><nn>`)
  are stable and never reused.
- **Keep locations current.** If your change moves code an entry points at,
  update that entry in the same change.
- **Prefer a pointer to a copy.** A problem large enough for its own document
  gets one and is listed in the register's "Indexed elsewhere" table with a
  one-line summary; do not duplicate its detail.

Report unverified work honestly: a change that compiles and passes the checker
scripts but has not been loaded in a game is not verified, and belongs in the
register until it has been.

## Runtime Logs and Diagnostics

Beyond All Reason writes its runtime log to the writeable data directory of the
local install. Do not hard-code a username; the layout is portable:

| Artifact | Path |
| --- | --- |
| Current run | `%LOCALAPPDATA%\Programs\Beyond-All-Reason\data\infolog.txt` |
| Archived runs | `%LOCALAPPDATA%\Programs\Beyond-All-Reason\data\log\<YYYYMMDDHHMMSS>_infolog.txt` |
| Replays, setup, desync dumps | `demos\`, `_script.txt`, `ClientGameState-*.txt` in the same data directory |

In Git Bash, `$LOCALAPPDATA` expands correctly. If the install is relocated,
the log records the authoritative directory on its `FindWriteableDataDir` line.

`infolog.txt` is overwritten on every launch, and `RotateLogFiles = 1` archives
the previous run under `log/`. These files are frequently hundreds of megabytes
and over a million lines, dominated by CircuitAI's own `:::AI LOG` output.
Never read one whole. Establish size, locate the incident with `grep -n`, then
read a bounded window. Apply `skills/troubleshoot-bar-logs/SKILL.md` when
investigating a crash, a runtime misbehaviour, a desync, or a startup failure;
it covers size discipline, crash-marker search, AI log filtering, and
symbolising `SkirmishAI.dll` stack offsets.

## Validation

Use the cheapest focused validation available in this repository, then broaden according to risk.

- Run diagnostics for edited C++ or AngelScript files.
- Use a focused rendered `--mode visual` run when validating movement, positioning, cloak or construction behavior; show relevant screenshots during that run and retain them. Fast automated checks and performance comparisons do not need screenshots or slow viewing windows. Headless runs require verified observer startup and coverage; missing observer events are a failure, not proof of success.
- For configuration changes, parse the changed JSON and check referenced UnitDef names/build edges against the effective BAR data pipeline.
- Use `git diff --check` before finishing.
- **Always publish completed builds to `C:\bardev\bar-RecoilEngine\build-amd64-windows\install\AI\Skirmish\BARb\stable`.** This is the required build output, not the live game installation. Stage the stripped `SkirmishAI.dll`, its matching `SkirmishAI.dbg`, and the current `data/` contents together. A scratch build, pinned playtest DLL or update archive does not replace this step. Verify script/DLL API parity there before reporting completion.
- The assistant never writes to the live BAR install (`%LOCALAPPDATA%\Programs\Beyond-All-Reason`): change and build only; the owner deploys the required build output above (script and DLL together). Before a launch the owner can run `python tools/knowledge/check_script_api.py --dll "<installed SkirmishAI.dll>"` (it only reads the DLL); see `skills/ai-not-moving/SKILL.md`.
- After touching `data/script/src/`, `tools/playtest/checks/`, `../rjm.bar.docs/projects/circuitai/invariants.md`, `../rjm.bar.docs/projects/circuitai/actor-matrix.md` or `../rjm.bar.docs/projects/circuitai/decisions.md`, run `python tools/knowledge/check_invariants.py`; it must exit 0.
- After touching `src/circuit/terrain/` layout code or `tests/`, run `bash tools/run_native_tests.sh` (the engine-free layout rules in `LayoutRanking.h` and `BaseLayoutGeometry.h`, compiled in the build container); it must exit 0. A new layout rule goes into `LayoutRanking.h` with a test named after the rule it guards (D-094).
- After touching any Markdown, run `python tools/knowledge/check_doc_links.py`; a link to a document that does not exist asserts an answer that is not there.
- After touching `data/script/src/roles/` or `../rjm.bar.docs/projects/circuitai/roles/`, run `python tools/knowledge/check_role_docs.py`; after touching unit id lists in `data/script/src`, run `python tools/knowledge/check_unit_helpers.py`. Both must exit 0.
- Runtime AngelScript changes require loading the affected profile in BAR because this repository has no standalone AngelScript compilation target.
- Native integration builds require Recoil's C++ AI wrapper. Never build inside the trusted read-only Recoil checkout; use a separate writable checkout/build environment or report that runtime validation remains pending.

Record validation performed and distinguish static checks from in-game or engine-runtime verification. When runtime verification remains pending, add or update the matching entry in `../rjm.bar.docs/projects/circuitai/known-issues.md` instead of leaving it only in a chat summary.
