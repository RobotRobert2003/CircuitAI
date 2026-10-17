# Port review: Cent's SMRTBARb 10-16-26-02

Prepared 2026-10-17 for Barscrewl. Branch `claude/project-thread-t11sez`: commit `8a93447` = Cent's package unchanged
(`BAR\SMRTBARb-10-16-26-02`, byte-identical to `Downloads\SMRTBARb TECH2.zip`). Its parent is `29d7697` (Cent's
10-16-26-01 import), so `git diff 29d7697 8a93447` is exactly what Cent changed since -01.
`docs/SMRTBARb-changes-for-Centrifugal.md` is the feature list we sent Cent on 2026-10-16 (same file as in Downloads).
The previous review, `PORT_REVIEW_10-16-26-01.md`, is on branch `claude/project-thread-518gdq`.

## Where the DLL comes from

| Check | Result |
|-------|--------|
| sha256 | `cdcfc8b6...` (8,622,416 bytes). -01 was `885eb6d0...`. |
| Strings from `145910e7` (`codex/tech-recovery-production-fixes`, e.g. `native.lost.`) | Present, so it is built on top of that commit. |
| New native API the -02 scripts call: `SetMexOwnership`, `SetMexAllyStart`, `SetCargoRoute(..., float = 90.0f)` (blocked seconds), `GetZoneCorner` | Present in the DLL. |
| New commander options: `front_recovery`, `front_mex_seconds`, `front_stall_seconds`, `afus_defence_radius`, `afus_def`; log `[CommanderFront] unit=%i enroute_mex`, `[CommanderBase] ... afus=%i ... concealed=%i`, "blocked flight corridor" | Present. |
| Any of the above on **any** branch or PR of `S3KCentrifugal/CircuitAI` (all 20 heads + PR refs fetched 2026-10-17 03:30 UTC) | **None.** Newest pushed commit is still `145910e7` (PR #15 head). |
| D-301 Thugs (`repairer_focus`), D-302 deploy idle INV-219 text, INV-220 radar (from `commander-thug-fixes`) | Not in the DLL. Cent's INV-219 now reads "commander deploy failed to release after stalled movement", his own version. |

**Conclusion:** the DLL was built from `codex/tech-recovery-production-fixes` (`145910e7`, itself `smrt-test 692cafe3`
+ one commit) **plus Cent's local, unpushed C++ commits**. It is not built from `smrt-test` or any other pushed branch.
We cannot rebuild it until Cent pushes that source. Our D-304 T3 cornered `GetPos` line (`12a4b401`) cannot be checked
from strings; assume it is missing and ask Cent to push, then rebuild with it on top.

## What Cent added in 10-16-26-02

All on in `experimental_balanced` through `main.as`; off elsewhere.

1. **FRONT commander picks up mexes while walking to the front** (`FrontMexSeconds = 1`, `FrontRecovery`,
   `front_stall_seconds` 10). This is the "commanders walk past metal spots" bug we found on 2026-10-17; Cent's DLL
   now has an `enroute_mex` step and a stalled-deploy release. **Check in one game before writing our own fix.**
2. **Early mex ownership by walking distance** (`MexOwnershipEnabled`, 600 s): native allocation of spots between
   allies by reachable distance from each commander; after 10 min any ally may take free spots. Replaces the old
   "nearest start owns the spot" rule that left commanders standing next to allied-owned mexes.
3. **TECH eco flak** (`eco_flak.as`, D-321): T2 flak ring around the eco layout, 1 per cluster once an adv fusion is
   up, more when air is seen nearby, 30 s cooldown, cap 15 per cluster. TECH's weapon and forward code skip areas it owns.
4. **AIR funded first T2 lab**: AIR may start its first T2 air plant when a 180 s forecast (75% of income) covers it,
   instead of waiting for the full income/bank gate; it takes nearby mexes while saving.
5. **Heavy delivery**: a blocked flight corridor gives up after 5 s (was 90); D-318 stops re-loading a cargo that
   already landed after a failed drop.
6. **Commander base defence near adv fusions** (`AfusDefenceRadius` = base radius).

## Features still missing (pending work not in the package)

Every script port below merges onto `8a93447` with no conflict (`git merge-tree` against
`claude/project-thread-518gdq` and `claude/project-thread-kttb0i`: only `SkirmishAI.dll` conflicts, keep Cent's).

| # | Feature | Our commit (on 518gdq unless noted) | Suggest |
|---|---------|-------------------------------------|---------|
| 1 | No Telchines from any role | `61f2520` | **Yes**, owner rule; Cent keeps dropping it. |
| 2 | Radar/jammer bots and vehicles capped at 5 | `040d5e8` | **Yes** |
| 3 | Gremlins scout like spy bots | `c640bd5` | **Yes** |
| 4 | Porc chain (Juno 4th, T2 flak 10th, Pit Bull/Scorpion/Chimera before 2nd Beamer/Twin Guard/Dragon's Jaw, LR radar, jammer) | `58a9028`, `ca7370a` | **Yes**. `build_chain*.json` only; separate from TECH eco flak's ring, so watch TECH flak counts in one game. |
| 5 | FRONT reclaims winds/solars after a fusion | `4bb77ae` | **Yes** |
| 6 | SUPPORT reclaims winds/solars after a fusion | `eb016e9` | **Yes** |
| 7 | Shared pinpointer pool (3 across allied SMRTBARbs) | `565f8ed` | **Yes** |
| 8 | TECH single roll: nuke 5%, T3 5%, heavy 90% | `5e1cfca` (kttb0i) | **Yes** if you still want the test weights; it is what is installed now. |
| 9 | AIR every 5th T2 unit a wave bomber, retake lost mexes | `92a20bf`, `ae4cf9f` | Later. Re-check against Cent's new AIR first-lab funding first. |
| 10 | FRONT construction turrets on T2 labs, gantry at maxed metal | `439bd93`, `631cf86`, PR #17 | Not yet (PR #17 still under test). |
| 11 | TECH converters at full bank / metal storage | `7c88feb` | Maybe. Headless h32 showed energy at 95%+ of storage in many samples, so it is wanted, but check Cent's converter priority first. |
| 12 | Front heavy delivery change (PR #14) | reverted `d670334` | **No**, per owner: keep Cent's front delivery. |

## Today's fixes: what to port onto this build

| Fix | Port? | Why |
|-----|-------|-----|
| Bismuth Valley P2/P10 SUPPORT | **Yes** (`7e52296`) | Map data only, tested. |
| Kings Assault SUPPORT on P4/P12 | **Yes** (`72020b4` + `6f8d8e4`) | Map data only. |
| Riverrun P4/P12 SUPPORT | **Ask owner** | Found uncommitted in BAR\SMRTBARb before this import (author unknown). Saved as `git stash@{0}` and `BAR\SMRTBARb-backup-2026-10-17-pre-10-16-26-02\riverrun-uncommitted.patch`. |
| Tyrannus / Dragon gate 175 | **Yes** (`4253381`) | |
| Nuke rush second silo call from 18 min, up to 8 (PR #15) | **Yes** (`fbd52f1`) | |
| D-304 T3 cornered `GetPos` (DLL) | **Yes, but needs Cent's source** | -02 DLL has unpushed C++; installing our `4b50be0` DLL would drop Cent's new native API and break the -02 scripts (`SetMexOwnership` etc.). |
| FRONT commander mex during deploy | **Wait** | Cent's -02 DLL has an en-route mex step (item 1 above). Test first; port our fix only if commanders still walk past spots. |
| TECH cage rescue (D-306b) | Maybe | Unchanged from the -01 review. |
| Bismuth TECH deadlock (fusion waits for 2 turrets, turret step "nothing to add") and TECH stalling at 5-6 T1 mexes (h32 report) | **Needs a fix** | Not addressed in -02 (Cent's TECH changes here are eco flak and heavy delivery only). Mex ownership (item 2) may help the mex count; re-run h32 on this build to see. |
