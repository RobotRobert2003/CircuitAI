# SMRTBARb changes for Centrifugal's next build

Audience: Centrifugal, or an AI agent working in Centrifugal's SMRTBARb tree.
Author: Barscrewl, prepared 2026-10-16.
Scope: `experimental_balanced` only. Script and JSON only; `SkirmishAI.dll` is unchanged.

## How to use this file (agent instructions)

1. Baseline is **Cent's distribution 10-14-26-04** (commit `c1a53ff` in `Barscrewl/SMRTBARb`).
   Every "before" value below is that package. If your tree differs, apply the *intent*
   (the deltas) rather than overwriting whole rows.
2. Our source of truth is branch `claude/project-thread-r2tjbv` of `Barscrewl/SMRTBARb`.
   The commits to port are listed per section. `git cherry-pick` works on a tree close to
   10-14-26-04; otherwise apply the snippets by hand.
3. Note: our copy of branch `cent-2026-10-14-04` already carries the first two opener commits
   (`ed1441b`, `a32e225`) on top of your package. The raid-threshold follow-up (`0cbf3ac`) and
   all the factory weight changes are not on it.
4. **Line endings.** `factory.json`, `factory_leg.json`, `behaviour*.json`, `main.as`,
   `front.as` and `settings/roles/front.as` are CRLF in our tree. Edit byte-wise and keep CRLF;
   a text-mode round trip rewrites every line and turns a small change into a whole-file conflict.
5. `factory*.json` and `behaviour*.json` allow `//` comments and trailing commas; use a tolerant
   parser if you validate them.
6. Keep each `unit` array and every `tierN` row the same length. Adding a unit means appending to
   `unit` **and** to every tier row of every section (`land`, `water`, `air`) of that factory.

Summary of what you are porting:

| # | Change | Files | Our commits |
|---|--------|-------|-------------|
| 1 | FRONT vehicle opener: 50% of games tanks (Incisor / Alaris) in raid squads, 50% your scout-rush opener | `main.as`, `roles/front/front.as`, `settings/roles/front.as`, `behaviour.json`, `behaviour_leg.json` | `ed1441b`, `a32e225` |
| 2 | Tank opener raid threshold scales with the tank's metal cost vs the Blitz | `main.as`, `roles/front/front.as`, `settings/roles/front.as` | `0cbf3ac` |
| 3 | Factory weights: Thanatos, Belcher, Inferno, Skuttle, Bedbug, Tumbleweed, spy bots, Gremlin | `factory.json`, `factory_leg.json` | `a08cae6`, `573e76a`, `d797204` |

---

## 1. FRONT vehicle opener: 50% tanks, 50% scout rush

### What it does

FRONT's first T1 vehicle plant queues `ScoutRushCount` (1) + `RaiderOpenerCount` (10) of the
side's T1 vehicle scout: Blitz (`armflash`) for Armada, Rascal (`corfav`) for Cortex, Wheelie
(`legscout`) for Legion. The Blitz has only the `raider` role, so the native military manager
holds them in a RAID defend task until the squad's power reaches `quota.raid.min`
(FRONT's `MilitaryRaidMinPowerVehicles`, 40) and then they raid together. Rascals and Wheelies are
scouts and wander out one at a time.

New: once per game, on the first opener ask, FRONT rolls `VehicleTankOpenerChance`
(0.5 in `experimental_balanced`). On a win, a Cortex FRONT builds Incisors (`corgator`) and a
Legion FRONT builds Alaris (`leghades`) instead, with the same counts, priorities and raid quotas
as the Blitz opener. On a loss it keeps your opener. Armada is unaffected (it already opens with
Blitzes).

### 1a. Setting (`stable/script/src/settings/roles/front.as`)

Add next to `RaiderOpenerCount` inside `namespace Front`. Default 0 keeps the feature off for
every profile except the one that turns it on.

```angelscript
            // Misc Logic Settings
            int RaiderOpenerCount = 10;
            // VehicleTankOpenerChance (owner, 2026-10-15): chance per game that a Cortex or Legion FRONT's
            // vehicle-plant opener (ScoutRushCount + RaiderOpenerCount units) is Incisors (corgator) or
            // Alaris (leghades) instead of Rascals (corfav) or Wheelies (legscout), so they gather into raid
            // squads like Armada's Blitzes (armflash) do. Rolled once per game. 0: off (Cent's openers).
            float VehicleTankOpenerChance = 0.0f;
```

### 1b. Turn it on (`stable/script/experimental_balanced/main.as`)

At the end of the block in `namespace Main` where the other `Global::RoleSettings::Front::*`
overrides are set:

```angelscript
		// FRONT (owner, 2026-10-15): half the games a Cortex or Legion FRONT opens its vehicle plant with Incisors or
		// Alaris that gather into raid squads, as Armada's Blitzes do, in place of Rascals or Wheelies
		// (src/settings/roles/front.as VehicleTankOpenerChance, 0 there)
		Global::RoleSettings::Front::VehicleTankOpenerChance = 0.5f;
```

### 1c. The roll and unit swap (`stable/script/src/roles/front/front.as`)

Add after `int g_frontScoutRushFactoryId = -1;` in `namespace RoleFront`:

```angelscript
    // Vehicle tank opener roll (Front::VehicleTankOpenerChance): -1 not rolled yet, 0 no, 1 yes
    int g_frontVehicleTankOpener = -1;

    // The unit FRONT's one-time vehicle-plant openers (scout rush and raider opener) build. Armada's
    // opener is already the Blitz; on a won roll Cortex and Legion use their Blitz counterparts.
    string Front_OpenerUnit(const string &in factoryName, const string &in side, const string &in defaultName)
    {
        if (!UnitHelpers::IsT1VehicleLab(factoryName)) return defaultName;
        string tank = "";
        if (side == "cortex") tank = "corgator";       // Incisor
        else if (side == "legion") tank = "leghades";  // Alaris
        if (tank == "") return defaultName;
        if (g_frontVehicleTankOpener < 0) {
            float p = AiMax(0.0f, AiMin(Global::RoleSettings::Front::VehicleTankOpenerChance, 1.0f));
            array<float>@ w = array<float>(2);
            w[0] = 1.0f - p;
            w[1] = p;
            g_frontVehicleTankOpener = (p > 0.0f && AiDice(w) == 1) ? 1 : 0;
            GenericHelpers::LogUtil("[FRONT] Vehicle opener roll (chance " + p + "): " +
                (g_frontVehicleTankOpener == 1 ? tank + " raid squads" : defaultName + " (Cent's)"), 1);
        }
        if (g_frontVehicleTankOpener != 1) return defaultName;
        CCircuitDef@ d = ai.GetCircuitDef(tank);
        if (d is null || !d.IsAvailable(ai.frame)) return defaultName;
        return tank;
    }
```

Then route both openers through it. In `Front_TryScoutRush`:

```angelscript
        string scoutName = UnitHelpers::GetFrontT1ScoutForFactory(factoryName, side);
        scoutName = Front_OpenerUnit(factoryName, side, scoutName);   // NEW
        if (scoutName == "") { g_frontScoutRushFinished = true; return null; }
```

In `Front_TryT1RaiderOpener`:

```angelscript
        string raiderName = UnitHelpers::GetFrontT1RaiderForFactory(factoryName, side);
        raiderName = Front_OpenerUnit(factoryName, side, raiderName);  // NEW
        if (raiderName == "") {
            g_frontRaiderOpenerDone = true;
            return null;
        }
```

The log level is 1 (commit `a32e225`) so the roll is visible in a normal infolog.

### 1d. Drop the `scout` attribute from Incisor and Alaris (behaviour JSON)

The native loader matches `attribute` strings against role names first, so `"scout"` in
`attribute` becomes a real added scout role. With it, the first `quota.scout` (2) tanks go off
as lone scouts instead of joining the raid squad. Make them match `armflash`.
This affects Incisors/Alaris for every role, not only FRONT.

`stable/config/experimental_balanced/behaviour.json`:

```jsonc
			"corgator": {
				"role": ["raider"],
				"attribute": ["spam"],          // was ["scout", "spam"]
				"threat": {"air": 0.0, "surf": 0.0, "water": 0.0, "default": 0.0},
				"power": 1.0
			},
```

`stable/config/experimental_balanced/behaviour_leg.json`:

```jsonc
			"leghades": {
				"role": ["raider"],
				"attribute": ["spam"],          // was ["scout", "spam"]
				"threat": {"air": 0.0, "surf": 0.0, "water": 0.0, "default": 0.0},
				"power": 1.0
			},
```

---

## 2. Tank opener: raid threshold scaled by metal cost

### Why

Played on All That Glitters (2026-10-16): a Legion FRONT won the roll and had 10 Alaris parked at
home. The vehicle raid threshold (40) was tuned for 10 Blitzes, and an Alaris costs 65 metal
against the Blitz's 110, so 10 of them never reached the threshold. On a won roll the threshold
becomes `base x tank.costM / blitz.costM`, never above the base:
Alaris 40 x 65/110 = **23.6**; Incisor costs more than a Blitz so Cortex stays at **40**.
Headless test (30 min, roll forced): no script errors, Legion FRONTs logged 23.6364, Cortex 40.

### 2a. Setting (`stable/script/src/settings/roles/front.as`)

```angelscript
            // Owner (2026-10-16): on a won tank-opener roll the vehicle raid threshold scales with the
            // tank's metal cost against the Blitz's (roles/front/front.as Front_RaidMinVehicles). Off here.
            bool TankOpenerRaidMinByCost = false;
```

### 2b. Turn it on (`stable/script/experimental_balanced/main.as`)

```angelscript
		// FRONT (owner, 2026-10-16): Alaris openers leave as a squad of 10 like the Blitzes (the vehicle raid
		// threshold scales by the tank's cost against the Blitz's; src/settings/roles/front.as, off there)
		Global::RoleSettings::Front::TankOpenerRaidMinByCost = true;
```

### 2c. The helper and its three call sites (`stable/script/src/roles/front/front.as`)

Add after `g_frontVehicleTankOpener` (it reads that flag):

```angelscript
    // Owner (2026-10-16): the vehicle raid squad threshold (Front::MilitaryRaidMinPowerVehicles, 40)
    // was set for 10 Blitzes. On a won tank-opener roll it scales by the tank's metal cost against the
    // Blitz's (never above the base), so the 10 opener tanks leave together as the Blitzes do. Played:
    // a Legion FRONT's 10 Alaris (65 metal against the Blitz's 110) sat at home. Incisors cost more
    // than Blitzes, so Cortex keeps 40. Front::TankOpenerRaidMinByCost (experimental_balanced).
    float Front_RaidMinVehicles()
    {
        const float base = Global::RoleSettings::Front::MilitaryRaidMinPowerVehicles;
        if (g_frontVehicleTankOpener != 1 || !Global::RoleSettings::Front::TankOpenerRaidMinByCost) return base;
        const string side = Global::AISettings::Side;
        CCircuitDef@ tank = ai.GetCircuitDef(side == "cortex" ? "corgator" : side == "legion" ? "leghades" : "");
        CCircuitDef@ blitz = ai.GetCircuitDef("armflash");
        if (tank is null || blitz is null || blitz.costM <= 0.0f) return base;
        return AiMin(base, base * tank.costM / blitz.costM);
    }
```

Call site 1, inside `Front_OpenerUnit`, right after the roll's log line (the vehicle lab may have
already applied the thresholds before the roll happened):

```angelscript
            g_frontVehicleTankOpener = (p > 0.0f && AiDice(w) == 1) ? 1 : 0;
            GenericHelpers::LogUtil("[FRONT] Vehicle opener roll (chance " + p + "): " +
                (g_frontVehicleTankOpener == 1 ? tank + " raid squads" : defaultName + " (Cent's)"), 1);
            if (g_frontVehicleTankOpener == 1 && g_frontVehicleThresholdsApplied) {
                aiMilitaryMgr.quota.raid.min = Front_RaidMinVehicles();
                GenericHelpers::LogUtil("[FRONT] Vehicle raid squad threshold " + aiMilitaryMgr.quota.raid.min
                    + " for " + tank + " (base " + Global::RoleSettings::Front::MilitaryRaidMinPowerVehicles + ")", 1);
            }
```

Call site 2, where the vehicle-lab thresholds are first applied:

```angelscript
        if (!g_frontVehicleThresholdsApplied && factoryName != "" && UnitHelpers::IsT1VehicleLab(factoryName)) {
            aiMilitaryMgr.quota.scout = Global::RoleSettings::Front::MilitaryScoutCapVehicles;
            aiMilitaryMgr.quota.attack = Global::RoleSettings::Front::MilitaryAttackThresholdVehicles;
            aiMilitaryMgr.quota.raid.min = Front_RaidMinVehicles();   // was MilitaryRaidMinPowerVehicles
            aiMilitaryMgr.quota.raid.avg = Global::RoleSettings::Front::MilitaryRaidAvgPowerVehicles;
```

Call site 3, where the base thresholds are recomputed (the `baseRaidMin` ternary near the top
of `namespace RoleFront`):

```angelscript
            float baseRaidMin = g_frontVehicleThresholdsApplied
                ? Front_RaidMinVehicles()                                   // was MilitaryRaidMinPowerVehicles
                : Global::RoleSettings::Front::MilitaryRaidMinPowerBots;
```

### Verify sections 1 and 2

In the infolog of a game with a Cortex or Legion FRONT on a vehicle start:

```
[FRONT] Vehicle opener roll (chance 0.5): leghades raid squads
[FRONT] Vehicle raid squad threshold 23.6364 for leghades (base 40)
```

or, on a lost roll, `... : corfav (Cent's)`. Over many games the split should be about 50/50.

---

## 3. Factory unit weights

Each value is the build weight in that factory's tier row. Unless noted, the rest of the row is
unchanged. Sections 3a to 3e give the **final rows** to paste; the tables give Cent 10-14-26-04
→ ours so you can apply deltas instead if your rows have moved.

### Change list

| Unit | Name | Factory | File | Change |
|------|------|---------|------|--------|
| `leghrk` | Thanatos | `legalab` | `factory_leg.json` | +0.10 in tiers 1-5 (0.21/0.31/0.20/0.20/0.20 → 0.31/0.41/0.30/0.30/0.30) |
| `legbart` | Belcher | `legalab` | `factory_leg.json` | +0.05 in tiers 1-2 (0.10 → 0.15) |
| `legstr`, `legshot`, `leginc`, `legsrail` | (donors) | `legalab` | `factory_leg.json` | donors for the above: legstr t1 0.31→0.16, t2 0.11→0.06; legshot t2 0.30→0.20; leginc t3 0.40→0.30, t4 0.50→0.40; legsrail t5 0.30→0.20 |
| `legaspy` | Legion spy bot | `legalab` | `factory_leg.json` | 0.01 → 0.05 in every tier |
| `leginf` | Inferno | `legavp` | `factory_leg.json` | tier3 0.15→0.35, tier4 0.05→0.25, tier5 0.00→0.20 |
| `legaskirmtank`, `legaheattank` | (donors) | `legavp` | `factory_leg.json` | donors: legaskirmtank t3 0.27→0.22; legaheattank t4 0.20→0.15, t5 0.35→0.30 |
| `corsktl` | Skuttle | `coralab` | `factory.json` | land 0.00/0.02 → 0.04/0.06; air 0.01/0.03 → 0.05/0.07 |
| `corspy` | Cortex spy bot | `coralab` | `factory.json` | land 0.01/0.05 → 0.05/0.09; air 0.01/0.05 → 0.05/0.09 |
| `corroach` | Bedbug | `coralab` | `factory.json` | **new unit**, appended at 0.02 in every row |
| `corpyro`, `cortermite` | (donors) | `coralab` | `factory.json` | donors: corpyro land 0.52/0.41→0.50/0.39, air t0 0.34→0.32; cortermite air t1 0.21→0.19 |
| `armspy` | Armada spy bot | `armalab` | `factory.json` | **new unit**, appended at 0.04 in every land and water row |
| `armvader` | Tumbleweed | `armalab` | `factory.json` | +0.02 in every land and water row |
| `armgremlin` | Gremlin | `armavp` | `factory.json` | 0.01 → 0.05 in every land and air row |

Thanatos, Belcher and Skuttle changes keep the row total (taken from donors). The spy bots,
Gremlin, Tumbleweed, Bedbug and Inferno rows rise slightly in total; weights are relative, so
that only dilutes the rest of the row a little.

### 3a. `legalab` (Thanatos, Belcher, spy bot) — `factory_leg.json`

```jsonc
    "legalab": {
        "income_tier": [55, 75, 100, 125, 150],
//Metal Cost           410          310         750         165         99          75          360         600         550         300             900         450         2300        60              755         330         650
        "unit":      [ "legack",    "legaceb",  "legdecom", "legaspy",  "legaradk", "legajamk", "legstr",   "leghrk",   "legbart",  "leginfestor",  "legsrail", "legshot",  "leginc",   "legsnapper",   "legamph",  "legadvaabot"],                                                                                                                     
        "land": {                                                                      // 10                                                        
            "tier0": [ 0.05,        0.02,       0.00,       0.05,       0.00,       0.00,       0.61,       0.01,       0.00,       0.00,           0.00,       0.30,       0.00,       0.00,           0.00,       0.00],
            "tier1": [ 0.05,        0.02,       0.00,       0.05,       0.00,       0.00,       0.16,       0.31,       0.15,       0.00,           0.00,       0.30,       0.00,       0.00,           0.00,       0.00],
            "tier2": [ 0.05,        0.02,       0.00,       0.05,       0.00,       0.00,       0.06,       0.41,       0.15,       0.00,           0.10,       0.20,       0.00,       0.00,           0.00,       0.00],
            "tier3": [ 0.05,        0.02,       0.00,       0.05,       0.00,       0.00,       0.00,       0.30,       0.00,       0.00,           0.30,       0.00,       0.30,       0.00,           0.00,       0.00],
            "tier4": [ 0.05,        0.02,       0.00,       0.05,       0.01,       0.01,       0.00,       0.30,       0.00,       0.00,           0.20,       0.00,       0.40,       0.00,           0.00,       0.00],
            "tier5": [ 0.05,        0.02,       0.00,       0.05,       0.01,       0.01,       0.00,       0.30,       0.00,       0.00,           0.20,       0.00,       0.40,       0.00,           0.00,       0.00]
        },
        // "importance", "require_energy" and "caretaker" unchanged (omitted here)
    },
```

### 3b. `legavp` (Inferno) — `factory_leg.json`

```jsonc
    "legavp": {
        "income_tier": [55, 75, 100, 125, 150],
//Metal Cost            530         200         125         105         250         450                 920         1500        400             460             1700        1250            470         1250
        "unit":      [  "legacv",   "legafcv",  "legavrad", "legavjam", "legmrv",   "legaskirmtank",    "legavroc", "legmed",   "legvcarry",    "legamcluster", "leginf",   "legaheattank", "legvflak", "legfloat"],
        "land": {                                               // 8
            "tier0": [  0.25,       0.15,       0.01,       0.01,       0.32,       0.45,               0.10,       0.00,       0.00,           0.00,           0.00,       0.00,           0.05,       0.00],
            "tier1": [  0.25,       0.15,       0.01,       0.01,       0.00,       0.55,               0.10,       0.00,       0.00,           0.10,           0.00,       0.00,           0.05,       0.00],
            "tier2": [  0.25,       0.15,       0.01,       0.01,       0.00,       0.47,               0.10,       0.00,       0.00,           0.30,           0.00,       0.00,           0.05,       0.00],
            "tier3": [  0.25,       0.15,       0.01,       0.01,       0.00,       0.22,               0.15,       0.10,       0.10,           0.10,           0.35,       0.00,           0.05,       0.00],
            "tier4": [  0.25,       0.15,       0.01,       0.01,       0.00,       0.00,               0.12,       0.15,       0.10,           0.20,           0.25,       0.15,           0.05,       0.00],
            "tier5": [  0.25,       0.15,       0.01,       0.01,       0.00,       0.00,               0.12,       0.15,       0.00,           0.20,           0.20,       0.30,           0.05,       0.00]
        },
        // "importance", "require_energy" and "caretaker" unchanged (omitted here)
    },
```

### 3c. `coralab` (Skuttle, spy bot, Bedbug) — `factory.json`

Note the new trailing `"corroach"` in `unit` and the extra column in every row.

```jsonc
    "coralab": {
        "income_tier": [40],
        "unit":      ["corack", "cortermite", "corpyro", "corsumo", "corcan", "corfast", "cormort", "corhrk", "coraak", "cormando", "corsktl", "corvoyr", "coramph", "corspy", "corroach"],
        "land": {
            "tier0": [ 0.01,     0.01,         0.50,      0.01,      0.13,     0.02,      0.15,      0.07,     0.01,     0.00,       0.04,      0.04,      0.02,      0.05, 0.02],
            "tier1": [ 0.02,     0.05,         0.39,      0.14,      0.05,     0.02,      0.07,      0.09,     0.02,     0.01,       0.06,      0.03,      0.02,      0.09, 0.02]
        },
        "air": {
            "tier0": [ 0.01,     0.18,         0.32,      0.01,      0.07,     0.02,      0.12,      0.05,     0.12,     0.02,       0.05,      0.02,      0.02,      0.05, 0.02],
            "tier1": [ 0.02,     0.19,         0.15,      0.14,      0.05,     0.02,      0.07,      0.04,     0.14,     0.04,       0.07,      0.02,      0.02,      0.09, 0.02]
        },
        // "importance", "require_energy" and "caretaker" unchanged (omitted here)
    },
```

### 3d. `armalab` (spy bot, Tumbleweed) — `factory.json`

Note the new trailing `"armspy"` in `unit` and the extra column in every row.

```jsonc
    "armalab": {
        "income_tier": [1, 30, 60, 80],
        "unit":      ["armack", "armfark", "armfast", "armzeus", "armfboy", "armmav", "armfido", "armaak", "armscab",   "armmark", "armaser", "armspid", "armsptk", "armsnipe", "armvader", "armamph", "armspy"],
        "land": {               
            "tier0": [ 0.25,     0.15,       0.20,      0.00,     0.00,     0.10,      0.50,      0.00,     0.00,       0.01,       0.01,       0.05,      0.05,      0.00,     0.02,       0.00,   0.04],
            "tier1": [ 0.25,     0.15,       0.10,      0.15,     0.05,     0.30,      0.45,      0.00,     0.00,       0.01,       0.01,       0.05,      0.05,      0.00,     0.22,       0.00,   0.04],
            "tier2": [ 0.25,     0.15,       0.30,      0.20,     0.15,     0.15,      0.40,      0.03,     0.01,       0.01,       0.01,       0.05,      0.05,      0.20,     0.12,       0.00,   0.04],          
            "tier3": [ 0.35,     0.15,       0.20,      0.20,     0.30,     0.00,      0.15,      0.03,     0.01,       0.01,       0.01,       0.05,      0.05,      0.20,     0.02,       0.00,   0.04],
            "tier4": [ 0.35,     0.15,       0.20,      0.20,     0.30,     0.00,      0.15,      0.03,     0.01,       0.01,       0.01,       0.05,      0.05,      0.20,     0.02,       0.00,   0.04]           
        "water": {                
            "tier0": [ 0.25,     0.15,       0.30,      0.00,     0.03,     0.07,      0.50,      0.00,     0.00,       0.01,       0.01,       0.05,      0.05,      0.00,     0.02,       0.00,   0.04],
            "tier1": [ 0.25,     0.15,       0.35,      0.15,     0.03,     0.07,      0.40,      0.01,     0.00,       0.01,       0.01,       0.05,      0.05,      0.00,     0.52,       0.10,   0.04],
            "tier2": [ 0.25,     0.15,       0.50,      0.15,     0.05,     0.07,      0.20,      0.01,     0.01,       0.01,       0.01,       0.05,      0.05,      0.05,     1.02,       0.10,   0.04],
            "tier3": [ 0.35,     0.15,       0.15,      0.10,     0.12,     0.05,      0.10,      0.01,     0.01,       0.01,       0.01,       0.00,      0.05,      0.10,     1.02,       0.10,   0.04],
            "tier4": [ 0.35,     0.15,       0.15,      0.10,     0.12,     0.05,      0.10,      0.01,     0.01,       0.01,       0.01,       0.00,      0.02,      0.10,     1.02,       0.10,   0.04]
        },
        // "importance", "require_energy" and "caretaker" unchanged (omitted here)
    },
```

### 3e. `armavp` (Gremlin) — `factory.json`

```jsonc
    "armavp": {
        "income_tier": [40,100],
        "unit":      ["armacv", "armlatnk", "armbull", "armmanni", "armmart", "armmerl", "armyork", "armseer", "armgremlin"],
        "land": {
            "tier0": [ 0.55,     0.22,       0.16,      0.00,       0.00,      0.03,      0.00,      0.03,      0.05],
            "tier1": [ 0.30,     0.10,       0.31,      0.18,       0.06,      0.03,      0.00,      0.01,      0.05],
            "tier2": [ 0.30,     0.01,       0.05,      0.50,       0.06,      0.03,      0.40,      0.01,      0.05]
        },
        "air": {
            "tier0": [ 0.50,     0.12,       0.04,      0.02,       0.02,      0.01,      0.26,      0.02,      0.05],
            "tier1": [ 0.33,     0.06,       0.19,      0.06,       0.05,      0.03,      0.26,      0.01,      0.05],
            "tier2": [ 0.33,     0.06,       0.19,      0.06,       0.05,      0.03,      0.70,      0.01,      0.05]
        },
        // "importance", "require_energy" and "caretaker" unchanged (omitted here)
    },
```

### Verify section 3

- Every `tierN` row length equals its factory's `unit` length (15 for `coralab`, 17 for
  `armalab`, 16 for `legalab`, 14 for `legavp`, 9 for `armavp`).
- The profile loads with no `factory` parse error in the infolog.
- Over a few games, Legion T2 bot labs put out visibly more Thanatos, Legion T2 vehicle plants
  build Infernos from tier 3, and each side's T2 bot lab (and Armada's T2 vehicle plant) puts
  out the odd spy bot or Gremlin.

---

## Reference: commits in `Barscrewl/SMRTBARb`

| Commit | Subject |
|--------|---------|
| `ed1441b` | FRONT vehicle opener: Incisors or Alaris half the games, gathered into raid squads like Armada's Blitzes |
| `a32e225` | FRONT vehicle opener roll: log at level 1 so it shows in the infolog |
| `0cbf3ac` | FRONT tank opener: the vehicle raid threshold scales with the tank's cost |
| `a08cae6` | Factory weights: Inferno, Skuttle, Bedbug, Tumbleweed, spy units and Gremlin (re-port of your 10-09-02 values that 10-14 dropped) |
| `573e76a` | Build more Thanatos, Belchers, Infernos and Skuttles |
| `d797204` | More spy bots and Gremlins |

All on branch `claude/project-thread-r2tjbv`.
