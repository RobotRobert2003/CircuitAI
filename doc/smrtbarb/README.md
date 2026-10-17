# Branch smrtbarb/all-changes-2026-10-17 (Barscrewl)

Everything in the SMRTBARb build Barscrewl runs (Barscrewl/SMRTBARb `claude/project-thread-t11sez`
`1c33595`), on top of Cent's newest pushed commit `145910e7` (`codex/tech-recovery-production-fixes`).
`data/` here equals that build's `stable/` file for file, except `AIInfo.lua` (kept as in this
repo) and the package-only files (`SkirmishAI.dll`, `FACTORY_PRODUCTION.md`,
`angelscript-references.md`).

## Commits, in order

1. `data:` Cent's own 10-16-26-02 package scripts/configs (not pushed by Cent before this branch).
2. Our script/config changes, one commit each, all `experimental_balanced` only:
   - Bismuth Valley P2/P10 to SUPPORT; Kings Assault SUPPORT on P4/P12 (2 commits)
   - Tyrannus / Dragon heavy air from 175 metal/s
   - TECH nuke rush: second silo call from 18 min, up to 8 silos
   - No Telchines from any role
   - Radar / jammer bots and vehicles capped at 5
   - Gremlins scout like spy bots
   - Porc chain (2 commits): Juno 4th, T2 flak 10th, Pit Bull / Scorpion / Chimera before the
     second Beamer / Twin Guard / Dragon's Jaw, long-range radar and jammer
   - FRONT and SUPPORT reclaim winds/solars after a fusion (2 commits)
   - Shared pinpointer pool (3 across allied SMRTBARbs)
   - TECH single roll: nuke 5%, T3 5%, heavy 90%
   - **Edge spam lanes** (`data/script/src/systems/combat/edge_lanes.as`, 2 commits): the two FRONTs
     furthest left/right of the team axis each build 2 construction turrets + a T1 bot lab and spam on
     repeat with a factory route: map edge at 1/3 toward the enemy, shift-move to the same edge at 2/3,
     shift-move to the far corner. Starts with a finished T2 factory and 65 metal income held 10 s.
     Every other FRONT is untouched (Cent's Spam owns all its lanes).
3. `src/`: D-304 T3 cornered test reads real ally positions (one line, `CommanderT3.cpp`).
4. These docs.

## Not in this branch

- The C++ behind Cent's 10-16-26-02 DLL (mex ownership, FRONT commander recovery / en-route mex /
  detours, afus defence, 6-argument `SetCargoRoute`). Cent has not pushed it. **The `data/` scripts
  call those native functions, so this branch's `src/` alone will not run them: build from Cent's
  10-16-26-02 C++ plus commit 3.**
- Reverted or held by the owner: PR #14 front heavy delivery, the D-304 fallback-porc half, D-301 /
  D-302 / D-305 (Thug fixes, on Cent's `commander-thug-fixes`), PR #17 FRONT eco gantry, AIR wave
  bomber / mex retake, TECH converters, TECH cage rescue.
- Proposed only, not made: commander D-gun priority and detour throttle (`COMMANDER_DGUN_PRIORITY.md`).

## Docs here

- `SMRTBARb-changes-for-Centrifugal.md`: the feature list sent to Cent on 2026-10-16.
- `PORT_REVIEW_10-16-26-02.md`: what each package has and lacks, and what was ported.
- `COMMANDER_DGUN_PRIORITY.md`: commander command hierarchy and D-gun analysis (2026-10-17).
