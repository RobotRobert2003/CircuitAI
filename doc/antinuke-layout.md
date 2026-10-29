# TECH and AIR first antinuke

Both experimental builders admit their first antinuke from 600 seconds at
10-second minimum income of at least 100 metal/sec and 2,000 energy/sec.
This is an eligibility gate, not a promise that a particular map/opening earns
that income by ten minutes. A capable T2 constructor is also required.

TECH reserves a reusable native zone slot beside its production/economy nanos,
before economy structures pack the remaining land. Compact groups use the same
packing API. A no-box layout searches beside an actual nano instead. AIR reserves
a persistent footprint outside its first production campus, within planned nano
reach and interceptor coverage of its home core. An unclaimed AIR pad follows
an unused campus when that campus relocates. Reservations survive task failure
and unit destruction through the existing native claim/zone lifecycle.

The first antinuke rule precedes discretionary growth. Nearby nanos prioritize
its frame over ordinary production/reclaim. Once construction finishes they
resume normal work. Native stockpiling is unchanged: construction completion
and the first interceptor being ready are separate events (90 seconds apart
in these runs). Existing later TECH income-scaled antinukes remain unchanged.

## Cost and lifetime

An existing pad costs a native integer/state lookup, without a unit census or
terrain search. Failed placement retries at most once per ten seconds. AIR's
initial search is bounded to 384 candidate points against at most 20 first-bay
nano pins; engine build tests follow the geometry filters. TECH uses native
group packing; the cramped fallback scans owned units once per retry, chooses
the closest nano, and tests at most 72 points. Nano assistance checks use a
single reservation-unit lookup and squared distance when those nanos ask for
work. No new per-frame polling loop or repeated broadcast was introduced.

## Verification, 2026-10-28 PDT

Source base: 40f68820. Existing 14b802dd DLL, SHA-256 prefix 1db81b038dfd16c7.
Engine recoil_2026.07.04, BAR test-31740-57a02af, experimental_balanced,
both AIs +50, ai_incomemultiplier=1, dynamiccheats=0, requested speed 20x.

Evidence and full limitations: `C:\Users\artib\BAR\antinuke-timing\report.md`.
The repeatable runner is `tools/playtest/run_antinuke_timing.py`.

| Defender | Start | Complete | First interceptor | Enemy launch | Interceptor launched |
| --- | --- | --- | --- | --- | --- |
| TECH Cortex | 10:16 | 11:07 | 12:38 | 12:30 | 12:39 |
| TECH Legion | 10:30 | 11:09 | 12:39 | 12:48 | 12:48 |
| AIR Armada | 10:19 | 10:54 | 12:24 | 14:05 | 14:05 |

These are controlled-income tests, not natural opening benchmarks. The fixture
supplies fusion/converter income at nine minutes and physical enemy scouts at
12/14 minutes, preserving normal LOS and autonomous nuclear target selection.
Ground raids are suppressed in staged test scripts only; workers, scouts and
fighters remain. TECH Cortex's earlier final run used the same income fixture
without the supplied scout; its native scout found a target independently.
All three timing runs pass their declared timing checks and have no script
errors. AIR Armada and TECH Legion also assert a completed nano is in range;
Cortex's observer measured 171 units to its nearest completed nano (reach 480).
Enemy missile and friendly interceptor projectiles were observed in all three.
Those observations do not independently prove every nuclear explosion was
prevented; no damage-outcome assertion was installed.

The natural Supreme Isthmus openings missed the 12-minute goal because they
did not sustain the income gate. AIR also attacked the opposing economy.
Keep those failures; do not present supplied income as natural performance.
The previous AIR policy in a matching supplied fixture first placed its
antinuke at 16:15 and finished at 17:45.

Measured simulation speed was 16.2x AIR, 18.7x Legion and 19.4x Cortex. The
unmodified AIR control ran at 18.0x. Populations and combat diverged, so these
are representative integration speeds, not same-state CPU/FPS comparisons.
No full performance clearance is claimed.

Static script API validation passed (394 members, zero findings). The playtest
harness suite ran 247 tests: 239 passed, one skipped, seven could not run because
this Python environment lacks lupa/openskill. Initial restricted-environment
failures and the subsequent dependency-only failure are preserved in the kit.

The timing checks do not waive unrelated invariant warnings. Supplied scouts
trigger INV-010 (the AI sees a combat unit created below its normal production
gate); supplied income and natural late-game behavior also logged economy/
formation invariants. Full-game regression clearance, rendered verification,
foreign-builder gifts, save/load, pad destruction/replacement, cramped maps,
metal-map special dispatch and all role/faction combinations remain unverified.
The canonical sibling rjm.bar.docs checkout named by AGENTS.md was absent here;
these decisions and open verification limits are retained here and in the kit.

No live deployment or GitHub push was requested or performed.
