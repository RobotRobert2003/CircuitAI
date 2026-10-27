# Anti-spam arena

Tests `systems/combat/anti_spam.as` (owner, 2026-10-27): the AIs spot a stream of
spam units on one lane and hold it with guns, Dragon's teeth, 2-4 construction
turrets and parked anti-spam units. Sized from the 2026-10-27 Nuclear Winter Bar
game, where PPBUCKER beat the AIs with Grunts down an edge lane.

- `anti_spam_arena.lua`: LuaUI widget. The viewer *plays* the spam team (not a
  spectator), turns cheats and global LOS on, spawns each configured wave with
  `give` at its spawn point and fight-moves it along its route. It keeps score:
  per parked unit, gun and turret its kills before death and the heals it got
  (repair sessions by our construction turrets and the hit points they restored),
  spam spawned / killed / breached (inside `breach_radius` of an AI start), and
  the AI's losses. `[AntiSpamStats] summary` every 60 s and at the end.
- `LuaUI/Config/anti_spam_arena.lua` (staged next to the widget):

      return {
        spam_team = 0,            -- the viewer's team
        end_minute = 40,
        breach_radius = 1500,
        ai_starts = { {x, z}, ... },
        waves = {
          { minute = 8,  unit = "corak", count = 30, spawn = {x, z}, route = { {x, z}, {x, z}, ... } },
          { minute = 8,  unit = "armpw", count = 10, spawn = {x, z}, route = { ... } },
          ...
        },
      }

  Wave sizes and minutes come from the replay census (Grunts finished per minute
  and how many broke through), the route from the lane the Grunts walked.

## Variants

- `natural`: normal start resources, the replay's own wave timing. Shows whether
  the AIs spot the stream and build the lane in time with what they have.
- `rich`: start metal 10000 / energy 20000 and waves from minute 12, so T2 and
  T3 factories stand and the parked roster (Razorback, Incinerator, Mammoth,
  Demon, Prometheus; Phalanx, Hoplite, Welder, Gunslinger, Jaguar, Centurion)
  gets used.
- Baseline: the same config with `Global::AntiSpam::Enabled = false` in
  `experimental_balanced/main.as`.

Judge from the AI log as well: `[AntiSpam] spam detected`, `spam lane seen`,
`holding lane`, `orders`, `park unit=`, `nano ... repairs`, `factory ... makes`.
