# t3rush gantry test

Headless 8v8 games, all 16 slots SMRTBARb (`experimental_balanced`), one game per map,
each AI team on a random +50..+70 bonus. Measures when and how each TECH's T3 gantry
goes up. Set the profile's roll-1 weights to T3 rush 1.0 first, or most TECHs will not
build one.

- `gantry_t3_watch.lua`: a LuaUI widget (spectator, full view) that logs `[GTest]`
  lines for every gantry: placement (game time, the team's metal income), finish,
  finished construction turrets within 600 elmos at the finish, the time after the
  finish to 14 and to 20 of them, and the first unit the gantry finishes. It emits
  `[GTest] ALL_T3_DONE` once every TECH has its first T3 unit out (or is dead); the
  game stops there, or at `--minutes`.
- `run.py`: stages each map with `playtest.py`, rolls and records the bonuses
  (`bonus.json`), launches and watches the game. It queues behind other headless test
  engines for up to 20 minutes and drops to Idle priority while the owner's BAR client
  is in a game.
- `parse.py`: reads each map's infolog into `RESULTS.md` (the table, speed achieved,
  and the waiting lines of every TECH gantry placed above +175) and writes
  `<map>/gantry-waits.txt` with each TECH's `[TECH][Gantry]`/`[GantryScale]`/
  `[T3Rush]`/gantry order lines.

## Run

    python tools/playtest/gantry_t3/run.py --dll <copy of SkirmishAI.dll> --out <dir> [--maps glitters,hotlips,proving,saltreef]
    python tools/playtest/gantry_t3/parse.py --out <dir>

Pass a copy of the DLL without its `.dbg` beside it (staging symbols needs the symbol
store). The AI scripts come from this checkout's `data/`.

`--game` must be the game the lobby plays. It defaults to the newest byar:test rapid
tag. Never take it from `data\_script.txt`: that file is only rewritten when the lobby
hosts a game, and a stale one (test-31450) crashed the armcom script at spawn ("piece
not found: hatcosmeticpoint"), so every Armada AI held its build orders and built
nothing for the whole game. In the infolog, check that no `hatcosmeticpoint` error appears
and that the Armada teams' income rises.

`RESULTS.md` here is the 2026-10-26 run (scripts 266ccf01, DLL 2d47892a, test-31723).
