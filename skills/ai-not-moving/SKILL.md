---
name: ai-not-moving
description: Diagnose and fix "the commander does not move at game start" for the BARb AI - almost always an AngelScript compile error or a script/DLL API mismatch; find the ERR lines, fix, redeploy script and DLL together, prove parity with the checker.
---

# The AI does not move at game start

Use this the moment the owner reports commanders standing still at start,
"the AI is broken", or units doing nothing from frame 0. Do not guess at
economy logic first: nine times out of ten the script never compiled, so no
policy ran at all.

## 1. Read the log, latest game only

```bash
L="$LOCALAPPDATA/Programs/Beyond-All-Reason/data/infolog.txt"
N=$(grep -n "Load script:.*main.as" "$L" | tail -1 | cut -d: -f1)
tail -n +$N "$L" > /tmp/game.log
grep -n " ERR " /tmp/game.log | head
```

`infolog.txt` holds every game since the last restart of the client; the
`Load script` line of the *last* game is the boundary. Each `ERR` line names
`file (line, column) : ERR  : message` (two spaces after ERR; grep for `ERR\s+:`). No `ERR` lines and still no movement:
go to step 4.

## 2. Map the message to its cause

| Message | Cause | Fix |
| --- | --- | --- |
| `No matching symbol 'Foo'` on `aiXxxMgr.Foo` | the script calls a native member the installed DLL does not register: script deployed ahead of its DLL, or the DLL is older than the source | build the DLL that registers it and tell the owner both must be deployed together; then step 3 |
| `Expected '(' ... Instead found reserved keyword 'out'` / `'in'` | `out`/`in` used as an identifier (`string out = ...`) | rename the variable (`opts`, `why`) |
| `No conversion from 'const CCircuitDef@' to 'CCircuitDef@'` | a `u.circuitDef` (const handle) passed to a non-const parameter | take `const CCircuitDef@` in the callee |
| `Both expressions must have the same type` in `a ? "x" : b` | a ternary mixing a literal and a `string`, or two handle types | write it as `if`/`else` |
| `No matching signatures to 'TaskB::...'` | a task constructor's argument order or count changed | check `data/script/src/task.as` |
| `'X' is not declared` | a function or setting renamed on one side only | grep the whole `data/script/src` for the old name |
| an `ERR` inside `main.as` includes | an `#include` path moved | fix the path; the include tree is `experimental_*/main.as` -> `src/...` |
| many `No matching symbol` at once, and the installed DLL's size or hash differs from the last build (e.g. 7.04 MB `15e244d5` instead of 7.2 MB) | the install was replaced under us - the BAR launcher/updater or a manual copy restored an older `SkirmishAI.dll` | `ls -la` and `sha256sum` the installed DLL before anything else; tell the owner which build is in the install and which one the script needs; do not touch the folder |

There is no offline AngelScript compiler for this project (KI-402); the
game is the compiler. The checker in step 3 catches the API class before a
launch.

## 3. Prove script/DLL parity before redeploying

```bash
python tools/knowledge/check_script_api.py
python tools/knowledge/check_script_api.py --dll "$LOCALAPPDATA/Programs/Beyond-All-Reason/data/engine/recoil_2026.07.04/AI/Skirmish/SMRTBARb/stable/SkirmishAI.dll"
```

The first run compares every `aiXxx.Member` used under `data/script` with
the registrations in `src/circuit/script/*.cpp`; the second checks that the
registration strings the script relies on are inside the *installed* DLL and
that the DLL is a stripped ~7 MB build (a 300 MB file is an unstripped or
mid-build copy and must not be shipped). Both must print `0 finding(s)`
before a launch.

**The assistant does not deploy (owner's rule, 2026-09-21).** Fix the
source, run the docker build, report the output path
(`build-amd64-windows/install/AI/Skirmish/BARb/stable/`), size and sha256,
and stop; the owner copies it in. Never write, move or restore anything
under `%LOCALAPPDATA%\Programs\Beyond-All-Reason`. Rules the owner's deploy
should keep, which this check verifies after the fact:

- **Script and DLL ship together.** A script that uses a new native member
  compiles only against the DLL that registers it.
- **Never copy from the Recoil install dir while a build runs.** The DLL is
  re-linked in place; wait for the build script's `exit 0`, then check size
  (about 7 MB) and sha256.

## 4. No ERR lines

- Check the AI actually loaded: `grep -n "Skirmish AI <SMRTBARb" /tmp/game.log | head`
  and that `:::AI LOG:` lines exist for the TECH team. None: the DLL failed
  to load (wrong engine folder, a crash at init - see `AGENTS.md` for the
  `.dbg` symbolising steps).
- Opening lines present but no orders: `grep -n "\[TECH\]\[Opening\]\|\[Eco\] next\|RESERVE:" /tmp/game.log | head -40`
  and read `../rjm.bar.docs/projects/circuitai/known-issues.md` KI-409 / KI-410 for the played-behaviour
  checklists.
- A single role stuck while others move: that role's `Init` threw at
  runtime - AngelScript runtime exceptions are logged as `Exception` lines,
  grep for them.

## 5. Record it

Every occurrence goes into `../rjm.bar.docs/projects/circuitai/known-issues.md` KI-402's history line
(date, cause, fix) so the table above grows with real cases; a new cause
gets a row in step 2.
