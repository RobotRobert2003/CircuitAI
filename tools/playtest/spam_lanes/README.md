# Spam lane test

Headless 8v8 games, all 16 slots SMRTBARb (`experimental_balanced`, the map file's roles,
every team on one bonus), one game per map. Shows the spam lanes the AIs planned (edge
lanes, pump lanes, T3 gantry routes) and the paths their units actually walked.

- `lane_trail_watch.lua`: a LuaUI widget (spectator, full view) that samples every T1 spam
  unit and every unit a T3 gantry finishes every 5 game seconds, and logs one
  `[LaneTrail]` line per unit (its walked points) when it dies, when the game ends, or at
  `--minutes`; then `[LaneTrail] END`.
- `run.py`: stages each map with `playtest.py`, launches and watches the game. It waits for
  other headless test engines and drops to Idle priority while the owner's BAR client is in
  a game (the gantry_t3 helpers).
- `parse.py`: `RESULTS.md` in the output directory: per lane, the planned waypoints, the
  units that joined it (`[SpamJoin]`), how many reached each waypoint in order (within
  `--radius`), and the furthest unit's walked path.
- `plot.py`: `<map>_lanes.png` per game: walkable ground from the map's heightmap, each
  lane's planned route (triangle the far corner, diamond the mid-edge point, star the final
  corner) and up to 25 of its units' trails. Needs numpy, matplotlib and py7zr.

## Run

    python tools/playtest/spam_lanes/run.py --dll <copy of SkirmishAI.dll> --out <dir> --maps "Thermal Shock v1.1,Forge v2.3"
    python tools/playtest/spam_lanes/parse.py --out <dir>
    python -I tools/playtest/spam_lanes/plot.py --out <dir>

Pump lanes are rebuilt during the game without a full waypoint line, so their planned
route is the first one the lab logged; the plot rings the AI's latest rim end, corner,
mid and home points.

`RESULTS.md` here is the 2026-10-26 run (return leg along the enemy back edge, DLL
434d1bc1 = c0fec5d1, test-31732): Thermal Shock, Entrenched Plains V2, Stronghold, Ice
Scream, Hotlips Remake, 35 min, +60.
