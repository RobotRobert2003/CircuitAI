---
name: troubleshoot-bar-logs
description: 'Read Beyond All Reason runtime logs and related diagnostic artifacts to investigate CircuitAI/BARb crashes, AI misbehaviour, desyncs, and startup failures. Use when a game log, infolog, crash stacktrace, or replay needs analysis. Covers safe handling of multi-hundred-megabyte logs, locating crash stacktraces, symbolising SkirmishAI.dll offsets, filtering AI log noise, and the full set of BAR diagnostic sources.'
metadata:
  version: '1.1.0'
  compatibility: 'Windows BAR install (portable layout under %LOCALAPPDATA%). Symbolising requires the matching unstripped SkirmishAI.dll or .dbg from a local build.'
---

# Troubleshoot BAR Logs

## When to Use

For CPU/APM investigations read the repository
[performance evidence guide](../../../rjm.bar.docs/projects/circuitai/performance/engineering-guide.md).
Keep inclusive versus exclusive phase timing separate, record unit populations
and game/content/build pins, and distinguish AI orders from Lua gadget orders.
Do not infer network packets or whole-game FPS improvements from order counts
or a microbenchmark. Preserve failed original verdicts and compare serial runs.

- A crash stacktrace mentioning `SkirmishAI.dll` needs investigating.
- The AI misbehaves in game and the run log may explain it.
- A match desynced, failed to start, or the launcher failed to update.
- You need to correlate an in-game observation with AI decision logging.

## Locations

Never hard-code a username. The install is portable and lives under
`%LOCALAPPDATA%`. In Git Bash convert it once (`xargs` and unquoted globs
strip its backslashes):

```bash
BAR="$(cygpath -u "$LOCALAPPDATA")/Programs/Beyond-All-Reason/data"
```

Local playtests (`skills/playtest`) log in their own write dir, not
the install: the live game in `<dir>/infolog.txt` (deleted at each launch),
one game per `<dir>/runs/<stamp>/infolog.txt`. Their AI is
`Skirmish AI <BARb playtest-test>`; the installed build is
`<SMRTBARb-stable>`.

| Path | What it holds |
| --- | --- |
| `$BAR/infolog.txt` | **Every game since the client started**, not just the last: cut at the last game with `N=$(grep -n '\[Game::Load\]\[1\]' "$L" \| tail -1 \| cut -d: -f1); tail -n +$N "$L"`. |
| `$BAR/log/<YYYYMMDDHHMMSS>_infolog.txt` | Archived runs (`RotateLogFiles = 1` in `springsettings.cfg`). |
| `$BAR/demos/*.sdfz` | Replays. Deterministic re-run of a crashed match. |
| `$BAR/_script.txt` | Last game's setup: teams, allyteams, AI instances, mod options. |
| `$BAR/ClientGameState-*.txt` | Desync dumps (`minFrame`, `maxFrame`, `randSeed`, `initSeed`). |
| `$BAR/launcher-logs/spring-launcher-*.log` | Download, update and install failures (pre-engine). |
| `$BAR/chatLogs/` | Per-player and battleroom chat. |
| `$BAR/Saves/` | Save games (`.ssf` + `.lua`). |
| `$BAR/springsettings.cfg` | Engine config, including log sections and rotation. |

If the install is somewhere unusual, the log states the truth on line ~4:

```bash
grep -m1 "FindWriteableDataDir" "$BAR/infolog.txt"
```

BAR does **not** write `.dmp` crash dumps. The stacktrace in the log is all
there is.

## Size Discipline (read this first)

These logs get very large. A single observed archive was **252 MB /
1.70 million lines**, and the archive directory held **219 files totalling
1.1 GB**.

The saving grace: in an AI-heavy run, **99.7% of lines were CircuitAI's own
`:::AI LOG` output** — 1,695,964 of 1,700,340. Engine content was ~4,400
lines, of which **9** were errors.

So:

- **Never** `cat`, `Read`, or tail-with-large-N an infolog blind.
- Scanning is cheap; reading is expensive. `wc -l` over 252 MB took 0.115 s.
  `grep -c` and `grep -n` are similarly cheap. Spend them freely.
- Always establish size first, then extract a narrow window by line number.

```bash
LOG="$BAR/infolog.txt"
ls -la "$LOG"; wc -l < "$LOG"          # size before anything else
```

## Procedure

### 1. Pick the right file

`infolog.txt` holds every game since the client started: cut at the last
`[Game::Load][1]` for the latest. After a client restart the evidence is in
`log/`. Pick archives by order or content, never by time arithmetic (the
names have run ahead of the files' times):

```bash
ls -t "$BAR/log" | head -5
grep -l 'MAP_NAME: <map>' "$BAR"/log/*_infolog.txt
```

### 2. Locate the incident by line number, never by reading through

```bash
grep -n "has crashed\|Exception Address\|Stacktrace for\|Error:" "$LOG" | head -20
```

Useful markers:

| Marker | Meaning |
| --- | --- |
| `has crashed` | Engine caught a fatal signal. |
| `This stacktrace indicates a problem with a skirmish AI` | Fault was inside an AI DLL. |
| `Exception: Access violation (0xc0000005)` | Null/bad pointer dereference. |
| `Exception Address:` | Absolute PC. Subtract the module base for an RVA. |
| `[f=NNNNNN]` | Sim frame. Correlates engine and AI lines. |

Then read a bounded window around the hit:

```bash
sed -n '1698400,1698520p' "$LOG"
```

### 3. Read the tail for clean shutdowns

The most valuable content is usually at the end, but bound it:

```bash
tail -200 "$LOG"
```

A log ending in `[Chobby]` lobby chatter means the session returned to the
menu — the incident, if any, is earlier.

### 4. Filter the AI noise

CircuitAI lines are emitted by `GenericHelpers::LogUtil`
(`data/script/src/helpers/common/generic_helpers.as`) in this shape:

```text
:::AI LOG:S:<skirmishAIId>:T:<teamId>:F:<frame>:L::<message>
:::AI LOG:S:<skirmishAIId>:T:<teamId>:F:<frame>:L::R:<role>:<message>
```

Many AI instances interleave, so always pin the instance before reading:

```bash
grep -v ":::AI LOG" "$LOG" | tail -100          # engine-only view
grep ":::AI LOG:S:12:" "$LOG" | tail -100       # one AI instance
grep -n "\[f=0019423\]" "$LOG" | head           # everything in one frame
```

Map `S:`/`T:` numbers to actual players and AIs via `$BAR/_script.txt`.

Volume is controlled by `const uint LOG_LEVEL` in
`data/script/src/define.as`; `LogUtil` emits only when `LOG_LEVEL >= level`.
Lower it before long runs, raise it when instrumenting a specific problem.
Changing it needs no rebuild — AngelScript loads at runtime — but the
**deployed** script tree must be refreshed, not just the repo copy.

### 5. Symbolise a SkirmishAI crash

Stack frame offsets are **module-relative (RVA)**, already bracketed in the
log. Confirm with the header: `Exception Address` minus the `SkirmishAI`
module base equals the frame-0 RVA.

First prove the binary matches, or the symbols are fiction:

```bash
md5sum "<deployed>/SkirmishAI.dll" "<build>/install/AI/Skirmish/BARb/stable/SkirmishAI.dll"
```

Then resolve `VA = ImageBase + RVA` (read `ImageBase` from the binary) using
the cross-toolchain inside the Recoil build container:

```bash
x86_64-w64-mingw32-objdump -p <dbg> | grep -i ImageBase
x86_64-w64-mingw32-addr2line -f -C -i -p -e <dbg> <VA>
```

When the guilty pointer is ambiguous, disassemble around the faulting address
— the instruction and its operand register identify the exact expression:

```bash
x86_64-w64-mingw32-objdump -d --start-address=<VA-0x40> --stop-address=<VA+0x20> <unstripped.dll>
```

`FramePtr` values such as `0x7` are normal for optimised builds and do not by
themselves indicate stack corruption; a stack that unwinds into a coherent
call chain is intact.

### 6. Reproduce

`$BAR/demos/*.sdfz` replays are named
`<date>_<map>_<engine version>.sdfz`. Match the engine version to the crashed
run before trusting a replay to reproduce.

## Checklist

- [ ] Size established (`wc -l`) before any read.
- [ ] Correct file chosen — the last game in `infolog.txt`, or a `log/` archive by order or content.
- [ ] Incident located by `grep -n`, then read as a bounded window.
- [ ] AI noise filtered, or a single `S:`/`T:` instance pinned.
- [ ] Binary identity proven by hash before symbolising.
- [ ] Frame numbers used to correlate engine and AI lines.
- [ ] Conclusions state what is proven from the log versus inferred.

## Related

- `skills/convention-angelscript/SKILL.md` for script-side fixes.
- `../rjm.bar.docs/projects/circuitai/TRUSTED_REFERENCE_REPOSITORIES.md` for the engine and game sources.
