---
name: convention-cpp
description: 'Write or review CircuitAI native C++ mechanisms, Recoil callback and script bindings, task ownership, spatial indexes and performance-sensitive code. Use for native AI changes; verify behavior preservation, callback threading, resource lifetime and measured costs against the deployed BAR/Recoil pins.'
metadata:
  version: '1.1.0'
---

# CircuitAI C++ conventions

When changing commander control, use the [playtest skill](../playtest/SKILL.md)
for focused scenarios, event completion, strict verdicts and final regression.
Pin source, DLL, debug symbols and matching active data before games. Include
damage-triggered decisions as well as scheduled updates when attributing cost;
do not sum nested phase timers as independent CPU. Tactical exposure windows
must model impact arrival, reload and already airborne salvos, and every path
that can issue a D-gun order must share the same final safety admission check.

Read [intent](../../../rjm.bar.docs/projects/circuitai/intent.md), applicable decisions and known issues first.
Native code provides mechanisms; role priorities and tuning belong in active
`data/` script/JSON. Expose new controls through registered bindings; a public
C++ method alone is not script accessible. Never apply role policy globally by
changing a shared UnitDef to fix one role.

## Procedure

1. Trace the real owner from engine event through manager, task and unit action.
   Identify role gates, callbacks, engine source pin and generated wrapper ABI.
2. Follow local C++ conventions and configured language standard. Use RAII for
   owned resources, explicit borrowing, bounds-checked inputs and total cleanup.
   Prefer small dependency-free decision/geometry helpers for exact tests.
3. Preserve task handover, player control, carrier gadget ownership, retreat,
   destruction and reload semantics. Store unit IDs across callbacks; reacquire
   and validate units. Do not retain temporary wrapper objects or span storage.
4. Read the [performance engineering guide](../../../rjm.bar.docs/projects/circuitai/performance/engineering-guide.md)
   for callback complexity, index mutation, cache invalidation, VM allocation,
   synchronous command borrowing, multiplayer evidence and worker restrictions.
5. State complexity in terms of actual inputs, including mutation and memory.
   Comment the reason, invalidation contract and test pointer near an optimized
   path. Fixed-size footprint lookup may be O(1) in reservation count while
   candidate search remains linear; do not conflate them.
6. Keep optimizations exact: preserve command fields, failures, iteration/tie
   order and random draws. Do not suppress orders or change update frequency
   without separate behavioral authorization and combat evidence.
7. Measure same-input old/new kernels and serial equivalent engine windows.
   Separate component timing from FPS/APM/peer claims. Preserve regressions.
8. Run meaningful native tests, script API checks and actual runtime loading.
   Compile all supported experimental profiles when bindings change. Publish
   the matched stripped DLL, debug symbols and data to the development output
   required by AGENTS.md; keep the live installation untouched.

## Exact spatial optimization

- Preserve candidate **order**, not only membership: ties and floating-point
  sums observe z/x/insertion order. Compare to a frozen old implementation over
  mutation, clear/rebuild, overflow coordinates and reused IDs.
- For candidate scans, early exit belongs only in a pure existence query. A callback returning early
  does not stop its outer iterator. Preserve full traversal for scoring, sums,
  RNG and observable side effects. Sign-only numeric shortcuts require proven
  contribution domains and an exact exceptional-value fallback.
- Allocation reuse is not observation caching. Fresh legal friendly callbacks
  remain necessary without a lifecycle/version contract, including mutations
  between asks in the same frame. Bounded-ID ordering must retain duplicate and
  out-of-bound fallback behavior.
- Touched-cell storage must track all mutations and retain stable addresses.
  Include sparse overflow and allocation bounds; never clamp coordinates to fit
  an optimization. State average and worst-case complexity separately.
- Use `tools/run_ranged_performance_tests.sh` for D-221's ordered oracle.
  Enable `CIRCUIT_VERIFY_RANGED_QUERIES` / `CIRCUIT_VERIFY_RANGED_SNAPSHOT` in
  correctness games only, never timing games. See the maintenance guide for
  measurement limits and results; speedup figures are not timeless guarantees.

## Point-route and lifecycle indexes (D-243)

- A nonnegative-cost point Dijkstra may stop only when the requested endpoint
  is **settled**, not first discovered. Preserve the full-field overload for
  consumers of every distance. Keep heap tie order and strict relaxation; test
  ordered paths against the old full-field solver, including directed edges.
- Reused double-buffer addresses are not publication versions. Key prepared
  costs by exact terrain lifetime, threat publication and every cost parameter.
  Live obstacle/weapon overlays need fresh inputs. Generation wrap must clear
  stamps; query-local escape exceptions must not mutate cached blocked cells.
- O(1) definition counts require lifecycle writers before synchronous script
  callbacks: enqueue, target changes, repeat, direct death, dequeue, transfer,
  frame adoption and load. Remove stale keys without dereferencing them. Retain
  a live legacy-scan oracle for correctness runs, disabled for timings.
- Project formation offsets before MOVE reduction. Exact collinearity is not
  proof of equivalent combat steering: D-243 limits compaction to untargeted
  SEA transit, with depth/footprint validation and original combat waypoints.
  A retained queue must match current ownership, intent, options, surviving
  suffix, expiry and recovery state; an empty queue must recover immediately.
- See the [implementation and tests](../../../rjm.bar.docs/projects/circuitai/reviews/2026-10-08-serene-performance-implementation.md).

## Threading and callbacks

Default to engine callbacks and managers being owned by the simulation thread.
Existing path workers do not make arbitrary wrappers thread-safe. Workers use
owned immutable inputs and return versioned results; the owner checks freshness
before applying them. Never access an AngelScript context concurrently. Review
lock ownership and cancellation/lifetime before adding a worker.

## Review checklist

- Behavior and role scope are explicit, with opt-in controls for new mechanisms.
- Borrowed/owned lifetimes survive every early return and destruction path.
- Cache invalidation includes all writers, transfers and load reconstruction.
- Algorithmic, native-boundary, allocation and order costs are distinguished.
- Hot-path comments explain the reason and link reproducible evidence.
- Tests exercise overlap, empty/dead inputs, ties and mutation boundaries.
- No claim of whole-game improvement is based only on microbenchmarks.
