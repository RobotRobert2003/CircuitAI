#!/usr/bin/env python
"""Playtest: launch a BAR skirmish with the freshly built BARb, watch its log, stop it.

    python tools/playtest/playtest.py run   [--roles TECH,FRONT] [--minutes 12] [--speed 3]
    python tools/playtest/playtest.py stage      # copy the build + script tree into the playtest dir
    python tools/playtest/playtest.py launch     # start the engine on the staged game (no watching)
    python tools/playtest/playtest.py watch      # follow the log of a running game and judge it
    python tools/playtest/playtest.py stop       # kill the playtest engine (never the user's own game)

Nothing here writes under the BAR install. The engine runs with its own
write directory (default C:\\bardev\\barb-playtest): the AI under test is
staged there as BARbTest/test, the start script, settings, the camera
widget, the infolog and the screenshots all live there. The install is read
for the engine, the game archives, the maps and the last lobby script
(modoptions template) only.

Doc: tools/playtest/README.md. Skill: skills/playtest/SKILL.md.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
import storage
import engine_process
from symbol_store import stage_symbols

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
LOCALAPPDATA = Path(os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData" / "Local")))
# read-only; BAR_DATA_DIR overrides it for a machine-wide install (e.g. C:\Program Files\Beyond-All-Reason\data)
BAR_DATA = Path(os.environ.get("BAR_DATA_DIR") or (LOCALAPPDATA / "Programs" / "Beyond-All-Reason" / "data"))
BUILD_AI = Path(r"C:\bardev\bar-RecoilEngine\build-amd64-windows\install\AI\Skirmish\BARb\stable")
DEFAULT_DIR = Path(r"C:\bardev\barb-playtest")
AI_SHORT = "BARbTest"
AI_VERSION = "test"
PROD_AI_SHORT = "SMRTBARb"
PROD_AI_VERSION = "stable"
FPS = 30
_engines = {}  # owned handles, keyed by canonical write-dir; closed after watch/stop
ROLE_INT = {"FRONT": 0, "AIR": 1, "TECH": 2, "SEA": 3, "SUPPORT": 4, "TACTICAL": 5}
SIDES = ["armada", "cortex", "legion"]


def log(msg):
    print("[playtest] " + msg, flush=True)


def die(msg, code=2):
    log("ERROR: " + msg)
    sys.exit(code)


# --------------------------------------------------------------------------- reading the install

def read_prod_script():
    """The lobby's last start script: game type, map and the modoptions block."""
    p = BAR_DATA / "_script.txt"
    if not p.exists():
        return {}, {}
    txt = p.read_text(encoding="utf-8", errors="replace")
    top = {}
    for key in ("gametype", "mapname"):
        m = re.search(r"^\s*%s\s*=\s*(.+?);\s*$" % key, txt, re.M | re.I)
        if m:
            top[key] = m.group(1).strip()
    mod = {}
    m = re.search(r"\[modoptions\]\s*\{(.*?)\}", txt, re.S | re.I)
    if m:
        for line in m.group(1).splitlines():
            line = line.strip()
            if "=" in line and line.endswith(";"):
                k, v = line[:-1].split("=", 1)
                mod[k.strip()] = v.strip()
    return top, mod


def latest_game_version():
    """The newest 'byar:test' rapid tag, the game the lobby plays."""
    for repo in (BAR_DATA / "rapid").glob("*/byar/versions.gz"):
        try:
            import gzip
            data = gzip.open(repo).read().decode("utf-8", "replace")
        except Exception:
            continue
        tests = [l for l in data.splitlines() if l.startswith("byar:test,")]
        if tests:
            return tests[-1].split(",")[-1]
    return None


def engine_dir(name=None):
    root = BAR_DATA / "engine"
    if name:
        d = root / name
        if not (d / "spring.exe").exists():
            die("engine %s has no spring.exe" % d)
        return d
    # the engine the lobby used last, from the infolog header
    info = BAR_DATA / "infolog.txt"
    if info.exists():
        with open(info, "r", encoding="utf-8", errors="replace") as f:
            head = f.read(20000)
        m = re.search(r"engine/([^/\"]+)/springsettings\.cfg", head)
        if m and (root / m.group(1) / "spring.exe").exists():
            return root / m.group(1)
    cands = [d for d in root.iterdir() if (d / "spring.exe").exists()]
    if not cands:
        die("no engine with spring.exe under %s" % root)
    return max(cands, key=lambda d: d.stat().st_mtime)


def map_file_for(map_name, override=None):
    if override:
        return Path(override)
    base = re.sub(r"\s+v?[\d.]+$", "", map_name.strip(), flags=re.I).lower().replace(" ", "_")
    p = REPO / "data" / "script" / "src" / "maps" / (base + ".as")
    if not p.exists():
        die("no AI map file for '%s' (looked for %s); pass --map-file" % (map_name, p))
    return p


def map_spots(map_name, override=None):
    """Start spots as the AI's map file lists them: [(x, z, ROLE), ...] in file order."""
    p = map_file_for(map_name, override)
    txt = p.read_text(encoding="utf-8", errors="replace")
    spots = re.findall(r"StartSpot\(\s*AIFloat3\(\s*([\d.]+)\s*,\s*[\d.]+\s*,\s*([\d.]+)\s*\)\s*,\s*AiRole::(\w+)", txt)
    if not spots:
        die("no StartSpot entries in %s" % p)
    return [(float(x), float(z), role) for x, z, role in spots]


def map_archive_present(map_name):
    stem = map_name.lower().replace(" ", "_")
    return any((BAR_DATA / "maps").glob(stem + "*.sd*"))


# --------------------------------------------------------------------------- staging

def sha16(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()[:16]


def seed_archive_cache(source, directory):
    """Copy stable scanner metadata; the engine still validates paths/mtimes.

    No shared writable cache or pathfinder state. Missing/unstable metadata is
    simply a cold load. Bound reads and retain a receipt for paired timing runs.
    """
    receipt = []
    for path in sorted(Path(source).glob('ArchiveCache*.lua')):
        if not re.fullmatch(r'ArchiveCache\d+\.lua', path.name):
            continue
        target = Path(directory) / 'cache' / path.name
        temporary = target.with_name(target.name + '.seed')
        if target.exists():
            continue
        try:
            before = path.stat()
            if before.st_size > 16 * 1024 * 1024:
                continue
            data = path.read_bytes()
            after = path.stat()
            if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns) or len(data) != before.st_size:
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary.write_bytes(data)
            temporary.replace(target)
            receipt.append({'name': path.name, 'source': str(path), 'bytes': len(data),
                            'sha256': hashlib.sha256(data).hexdigest()})
        except OSError:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass
            continue  # cache reuse is optional; staging/engine errors remain fatal
    (Path(directory) / 'archive-cache-seed.json').write_text(json.dumps(receipt, indent=2) + '\n')
    return receipt


OPPONENT_SHORT = "BARbBase"
OPPONENT_VERSION = "base"


def stage_opponent(d, dll, data):
    """A second, pinned build of this AI for head-to-head runs: 'prod' teams
    play it. Staged in the write directory only, never the BAR install."""
    dst = d / "AI" / "Skirmish" / OPPONENT_SHORT / OPPONENT_VERSION
    dst.mkdir(parents=True, exist_ok=True)
    if not dll.exists():
        die("no opponent DLL at %s" % dll)
    shutil.copy2(dll, dst / "SkirmishAI.dll")
    for sub in ("config", "script"):
        if (dst / sub).exists():
            shutil.rmtree(dst / sub)
        shutil.copytree(data / sub, dst / sub, ignore=shutil.ignore_patterns("__pycache__"))
    shutil.copy2(data / "AIOptions.lua", dst / "AIOptions.lua")
    info = (data / "AIInfo.lua").read_text(encoding="utf-8")
    info, n1 = re.subn(r"value\s*=\s*'[^']*',(\s*-- AI name - !This comment is used for parsing!)",
                       "value  = '%s',\\1" % OPPONENT_SHORT, info)
    info, n2 = re.subn(r"value\s*=\s*'[^']*',(\s*-- AI version - !This comment is used for parsing!)",
                       "value  = '%s',\\1" % OPPONENT_VERSION, info)
    if n1 != 1 or n2 != 1:
        die("opponent AIInfo.lua markers not found")
    (dst / "AIInfo.lua").write_text(info, encoding="utf-8")
    log("staged opponent %s/%s from %s" % (OPPONENT_SHORT, OPPONENT_VERSION, dll))


def stage(args):
    stage_started = time.monotonic()
    if not str(args.dir).strip():
        die("empty playtest directory; benchmark allocation must succeed before staging")
    d = Path(args.dir)
    if d.resolve() == REPO.resolve() or d.resolve() in REPO.resolve().parents:
        die("playtest write directory cannot be the source checkout or its parent")
    if getattr(args, 'headless', False):
        args.shots = ''
    d.mkdir(parents=True, exist_ok=True)
    seed_archive_cache(BAR_DATA / 'cache', d)
    ai_dst = d / "AI" / "Skirmish" / AI_SHORT / AI_VERSION
    ai_dst.mkdir(parents=True, exist_ok=True)

    dll_src = Path(args.dll) if args.dll else BUILD_AI / "SkirmishAI.dll"
    if not dll_src.exists():
        die("no DLL at %s (build first)" % dll_src)
    if dll_src.stat().st_size > 50 * (1 << 20):
        die("%s is %d bytes: an unstripped mid-build copy, wait for the build" % (dll_src, dll_src.stat().st_size))
    shutil.copy2(dll_src, ai_dst / "SkirmishAI.dll")
    dbg = dll_src.with_suffix(".dbg")
    if dbg.exists():
        stage_symbols(dbg, ai_dst / "SkirmishAI.dbg")

    data_src = Path(args.data) if args.data else REPO / "data"
    for sub in ("config", "script"):
        if (ai_dst / sub).exists():
            shutil.rmtree(ai_dst / sub)
        shutil.copytree(data_src / sub, ai_dst / sub, ignore=shutil.ignore_patterns("__pycache__"))
    shutil.copy2(data_src / "AIOptions.lua", ai_dst / "AIOptions.lua")
    # Apply only to the staged copy; supports both current and pinned old layouts.
    from script_settings import apply_override
    for expression in (args.set or []):
        try:
            setting = apply_override(ai_dst / "script/src", expression)
        except ValueError as error:
            die(str(error))
        log("set " + setting)

    info = (data_src / "AIInfo.lua").read_text(encoding="utf-8")
    info, n1 = re.subn(r"value\s*=\s*'[^']*',(\s*-- AI name - !This comment is used for parsing!)",
                       "value  = '%s',\\1" % AI_SHORT, info)
    info, n2 = re.subn(r"value\s*=\s*'[^']*',(\s*-- AI version - !This comment is used for parsing!)",
                       "value  = '%s',\\1" % AI_VERSION, info)
    if n1 != 1 or n2 != 1:
        die("AIInfo.lua markers not found (shortName %d, version %d)" % (n1, n2))
    info = info.replace("value  = 'BARbarIAn'", "value  = 'BARb playtest'")
    (ai_dst / "AIInfo.lua").write_text(info, encoding="utf-8")
    if getattr(args, "opponent_dll", None):
        stage_opponent(d, Path(args.opponent_dll), Path(args.opponent_data or (REPO / "data")))

    # settings: the user's, read once, with the playtest overrides on top
    prod_cfg = BAR_DATA / "springsettings.cfg"
    lines = prod_cfg.read_text(encoding="utf-8", errors="replace").splitlines() if prod_cfg.exists() else []
    overrides = {
        "SpringData": str(BAR_DATA).replace("/", "\\"),
        "Fullscreen": "0",
        "WindowBorderless": "0",
        "XResolutionWindowed": str(args.width),
        "YResolutionWindowed": str(args.height),
        "XResolution": str(args.width),
        "YResolution": str(args.height),
        "WindowPosX": "0",
        "WindowPosY": "0",
        "LogFlush": "1",
    }
    if getattr(args, "lean_render", False):
        # Local test output only. Never alter the player's installation settings.
        overrides.update({"CompressTextures":"0", "MSAALevel":"0", "Shadows":"-1",
                          "Water":"0", "GrassDetail":"0", "GroundDetail":"60",
                          "CubeTexSizeReflection":"128", "CubeTexGenerateMipMaps":"0",
                          "VSync":"0", "VSyncGame":"0", "IdleFpsDivider":"0", "ThreadPinPolicy":"0"})
    if args.headless:
        # Concurrent headless engines otherwise choose the same preferred main
        # core. Let the OS schedule these isolated test threads independently.
        overrides["ThreadPinPolicy"] = "0"
    out = []
    seen = set()
    for line in lines:
        m = re.match(r"\s*(\w+)\s*=", line)
        if m and m.group(1) in overrides:
            out.append("%s = %s" % (m.group(1), overrides[m.group(1)]))
            seen.add(m.group(1))
        else:
            out.append(line)
    for k, v in overrides.items():
        if k not in seen:
            out.append("%s = %s" % (k, v))
    (d / "springsettings.cfg").write_text("\n".join(out) + "\n", encoding="utf-8")

    # the camera / screenshot / speed / end widget
    wdir = d / "LuaUI" / "Widgets"
    wdir.mkdir(parents=True, exist_ok=True)
    # only this run's widgets: an --extra-widget from an earlier run stayed in the
    # write dir and ran again (played: an old draw test drew over the intro test)
    for old in wdir.glob("*.lua"):
        old.unlink()
    shots = []
    for tok in (args.shots or "").split(","):
        tok = tok.strip()
        if not tok:
            continue
        # minute[@height[@x:z]]: x:z points the camera at a map position instead of the start
        parts = tok.split("@")
        minute = parts[0]
        height = parts[1] if len(parts) > 1 and parts[1] else ""
        focus = ""
        if len(parts) > 2 and ":" in parts[2]:
            fx, _, fz = parts[2].partition(":")
            focus = ", x = %s, z = %s" % (float(fx), float(fz))
        shots.append("{ minute = %s, height = %s%s }" % (float(minute), float(height) if height else args.cam_height, focus))
    # owner: fast-forward, and slow down near what the test watches. --speed-plan
    # "minute:speed,...": each speed from its minute on; --slow-near-shots: speed 1
    # from SLOW_LEAD minutes before each screenshot to just after it, --speed between
    plan = []
    for tok in (getattr(args, "speed_plan", None) or "").split(","):
        tok = tok.strip()
        if tok:
            m, _, s = tok.partition(":")
            plan.append((float(m), float(s)))
    if getattr(args, "slow_near_shots", False):
        lead = 0.3
        for tok in (args.shots or "").split(","):
            tok = tok.strip()
            if tok:
                m = float(tok.split("@")[0])
                plan.append((max(0.0, m - lead), 1.0))
                plan.append((m + 0.05, float(args.speed)))
    plan.sort()
    planLua = ", ".join("{ minute = %s, speed = %s }" % (m, s) for m, s in plan)
    cfg = ("{ role = %r, team = %d, speed = %s, end_minute = %s, forcestart = true, "
           "log_prefix = '[Playtest]', shots = { %s }, speed_plan = { %s } }") % (
        args.role, 0, float(args.speed), float(args.minutes) + 0.5, ", ".join(shots), planLua)
    tpl = (HERE / "widgets" / "playtest_camera.lua").read_text(encoding="utf-8")
    (wdir / "playtest_camera.lua").write_text(tpl.replace("__CFG__", cfg), encoding="utf-8")
    shutil.copy2(HERE / 'widgets' / 'playtest_lifecycle.lua', wdir / 'playtest_lifecycle.lua')
    # extra widgets under test (e.g. tools/widgets/gui_barb_team_link.lua), staged into
    # the playtest's own write dir only, never the live game's
    for extra in (args.extra_widget or []):
        src = Path(extra)
        (wdir / src.name).write_text(src.read_text(encoding="utf-8"), encoding="utf-8")
        log("staged widget %s" % src.name)

    (d / "screenshots").mkdir(exist_ok=True)
    manifest = {
        "staged": dt.datetime.now().isoformat(timespec="seconds"),
        "staging_seconds": time.monotonic() - stage_started,
        "dll": str(dll_src), "dll_sha256_16": sha16(dll_src), "dll_bytes": dll_src.stat().st_size,
        "data": str(data_src), "ai": "%s/%s" % (AI_SHORT, AI_VERSION),
        "mode": getattr(args, 'mode', 'fast'), "requested_speed": float(args.speed),
    }
    (d / "staged.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    log("staged %s (%s, %d bytes) + %s into %s" % (dll_src.name, manifest["dll_sha256_16"], manifest["dll_bytes"], data_src, ai_dst))
    return manifest


# --------------------------------------------------------------------------- the start script

def choose_teams(args, spots):
    """Teams in script order: team 0 is the AI under test on its role's spot."""
    n = len(spots)
    half = n // 2
    west = list(range(0, half))
    east = list(range(half, n))
    if args.ally_spots:
        west = [int(t) - 1 for t in re.split(r"[,\s]+", args.ally_spots.strip()) if t]
        east = [i for i in range(n) if i not in west]
    want = None if args.roles.lower() == "all" else {r.strip().upper() for r in args.roles.split(",")}
    if want is not None:
        want.add(args.role.upper())

    def pick(indices, role):
        return [i for i in indices if spots[i][2] == role]

    tech = pick(west, args.role.upper())
    if not tech:
        die("no %s spot on the ally side of the map file" % args.role)
    teams = []  # (spot index, allyteam, ai kind, side)
    teams.append((tech[0], 0, "test", args.side))
    others = "test" if args.others == "test" else ("prod" if args.others == "prod" else None)
    k = 0
    for ally, indices in ((0, west), (1, east)):
        for i in indices:
            if i == tech[0]:
                continue
            role = spots[i][2]
            if want is not None and role not in want:
                continue
            if ally == 0 and others is None:
                continue
            kind = others if ally == 0 else (others or "test")
            side = SIDES[k % len(SIDES)]
            k += 1
            teams.append((i, ally, kind, side))
    if not any(t[1] == 1 for t in teams):
        # the game ends at once with nobody to fight: keep one enemy
        j = east[0]
        teams.append((j, 1, others or "test", "armada"))
    return teams


COLOURS = ["0.2 0.6 1.0", "1.0 0.5 0.1", "0.3 0.9 0.3", "0.9 0.3 0.9", "0.9 0.9 0.2", "0.4 0.9 0.9",
           "0.9 0.4 0.4", "0.6 0.6 0.6", "0.1 0.3 0.8", "0.8 0.3 0.0", "0.1 0.6 0.1", "0.6 0.1 0.6",
           "0.7 0.7 0.0", "0.0 0.6 0.6", "0.6 0.0 0.0", "0.3 0.3 0.3"]


def write_script(args, d):
    top, mod = read_prod_script()
    game = args.game or top.get("gametype") or latest_game_version()
    if not game:
        die("no game version: pass --game 'Beyond All Reason test-...'")
    map_name = args.map or top.get("mapname") or "Supreme Isthmus v1.7"
    if not map_name:
        die("no map: pass --map")
    if not map_archive_present(map_name):
        die("no archive for '%s' under %s/maps; install the exact map version before launching" % (map_name, BAR_DATA))
    spots = map_spots(map_name, args.map_file)
    teams = choose_teams(args, spots)

    mod = {k: v for k, v in mod.items() if not k.startswith("mapmetadata_")}
    now = dt.datetime.now()
    # Legion is on in every playtest (owner's rule), the map stays what the lobby last played (Supreme Isthmus)
    # zero bonus is the benchmark baseline (D-072): the AI income multiplier is 1 and every team's handicap 0
    # unless --bonus asks for a handicap on team 0
    mod.update({"allowuserwidgets": "1", "experimentallegionfaction": "1", "ai_incomemultiplier": "1", "date_year": str(now.year), "date_month": "%02d" % now.month,
                "date_day": "%02d" % now.day, "date_hour": "%02d" % now.hour})
    for kv in args.modoption or []:
        k, _, v = kv.partition("=")
        mod[k.strip()] = v.strip()

    ai_opts = {}
    for kv in args.ai_option or []:
        k, _, v = kv.partition("=")
        ai_opts[k.strip()] = v.strip()

    L = ["[GAME]", "{",
         "\tGameType=%s;" % game, "\tMapName=%s;" % map_name,
         "\tStartPosType=3;", "\tIsHost=1;", "\tHostIP=127.0.0.1;", "\tHostPort=0;",
         "\tMyPlayerName=Playtest;", "\tNumPlayers=1;", "\tGameStartDelay=0;", "\tNoHelperAIs=0;",
         "\t[MODOPTIONS]", "\t{"]
    for k in sorted(mod):
        L.append("\t\t%s=%s;" % (k, mod[k]))
    # The spectator gets a team of its own in a third allyteam. BAR's game_end
    # gadget treats every AI hosted by an inactive player as uncontrolled and
    # wipes out that player's allyteam (except in 1v1); the local client is
    # inactive until it has finished loading, so a spectator sharing allyteam
    # 0 with the AIs killed the whole west side at frame 1. Its own team spawns
    # a commander that BAR kills at once (a team whose players all spectate).
    spec_team = len(teams)
    L += ["\t}", "\t[ALLYTEAM0] { NumAllies=0; }", "\t[ALLYTEAM1] { NumAllies=0; }", "\t[ALLYTEAM2] { NumAllies=0; }",
          "\t[PLAYER0] { Name=Playtest; Spectator=1; Team=%d; IsFromDemo=0; Rank=0; }" % spec_team,
          "\t[TEAM%d] { AllyTeam=2; TeamLeader=0; Side=armada; RgbColor=0.5 0.5 0.5; StartPosX=64; StartPosZ=64; Handicap=0; }" % spec_team]
    for t, (si, ally, kind, side) in enumerate(teams):
        x, z, role = spots[si]
        L += ["\t[TEAM%d]" % t, "\t{", "\t\tAllyTeam=%d;" % ally, "\t\tTeamLeader=0;",
              "\t\tSide=%s;" % side, "\t\tRgbColor=%s;" % COLOURS[t % len(COLOURS)],
              "\t\tStartPosX=%d;" % int(x), "\t\tStartPosZ=%d;" % int(z), "\t\tHandicap=%d;" % (int(args.bonus) if (t == 0 and args.bonus) else 0), "\t}"]
        # --prod-ai names an installed opponent (e.g. stock BARb) that keeps its
        # own default options: the test build's AI options are not passed to it.
        prod_ai = getattr(args, "prod_ai", None)
        opponent = getattr(args, "opponent_dll", None)
        if kind == "test":
            short, ver = AI_SHORT, AI_VERSION
        elif opponent:
            short, ver = OPPONENT_SHORT, OPPONENT_VERSION
        else:
            short, ver = prod_ai or PROD_AI_SHORT, getattr(args, "prod_version", None) or PROD_AI_VERSION
        L += ["\t[AI%d]" % t, "\t{", "\t\tShortName=%s;" % short, "\t\tVersion=%s;" % ver,
              "\t\tName=%s-%s-%d;" % (short, role.lower(), t), "\t\tTeam=%d;" % t, "\t\tHost=0;", "\t\tIsFromDemo=0;"]
        if ai_opts and (kind == "test" or opponent or not prod_ai):
            L.append("\t\t[OPTIONS] { %s }" % " ".join("%s=%s;" % kv for kv in ai_opts.items()))
        L += ["\t}"]
    L += ["}", ""]
    (d / "script.txt").write_text("\n".join(L), encoding="utf-8")
    plan = [{"team": t, "spot": si + 1, "x": spots[si][0], "z": spots[si][1], "role": spots[si][2],
             "ally": ally, "ai": kind, "side": side} for t, (si, ally, kind, side) in enumerate(teams)]
    (d / "teams.json").write_text(json.dumps({"game": game, "map": map_name, "teams": plan}, indent=2), encoding="utf-8")
    log("script: %s on %s, %d AIs (%s under test as team 0 on spot P%d, %s)" % (
        game, map_name, len(teams), args.role, teams[0][0] + 1, args.side))
    return plan


# --------------------------------------------------------------------------- the engine process

def pid_file(d):
    return Path(d) / "playtest.pid"


def launch(args):
    # The engine starts in its own directory; keep all writable output in the
    # explicitly selected test directory even when the caller used a relative path.
    d = Path(args.dir).resolve()
    if not (d / "script.txt").exists() or not (d / "AI" / "Skirmish" / AI_SHORT / AI_VERSION / "SkirmishAI.dll").exists():
        die("nothing staged in %s: run 'stage' first" % d)
    # Recoil refuses a write drive with <=1024 MiB free. Reject before spawning
    # and leave some room for the retained log/replay; never delete evidence.
    if shutil.disk_usage(d).free < 1536 * 1024 * 1024:
        die("less than 1.5 GiB free on playtest drive; reclaim redundant build caches before launching: %s" % d)
    existing = running_pids(d)
    if existing:
        die("a playtest engine is already running (pids %s): 'stop' it first" % existing)
    eng = engine_dir(args.engine)
    exe = eng / ("spring-headless.exe" if getattr(args, "headless", False) else "spring.exe")
    storage.capture_inputs(d, exe)
    storage.capture_system(d, exe)  # host specs: results from different devices are not one cohort
    # a fresh infolog per run; the previous one is kept with its run
    info = d / "infolog.txt"
    if info.exists():
        try:
            info.unlink()
        except OSError:
            pass
    for old in (d / "screenshots").glob("*.png"):
        try:
            old.unlink()
        except OSError:
            pass
    cmd = [str(exe), "--write-dir", str(d), str(d / "script.txt")]
    (d / 'playtest-stop.txt').unlink(missing_ok=True)
    log("launch: " + " ".join(cmd))
    proc = subprocess.Popen(cmd, cwd=str(eng), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0))
    handle = None
    try:
        handle = engine_process.EngineProcess(proc.pid)
        record = dict(handle.identity(d), engine=str(eng), command=cmd,
                      at=dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"))
        (d / "launched.json").write_text(json.dumps(record), encoding="utf-8")
        _engines[engine_process.canonical(d)] = handle
        pid_file(d).write_text(str(proc.pid), encoding="utf-8")
    except BaseException:
        proc.kill()  # Popen still owns this exact child handle
        proc.wait()
        if handle is not None: handle.close()
        raise
    log("engine pid %d, engine %s" % (proc.pid, eng.name))
    return proc.pid


def running_pids(d):
    """Engine processes started on this write dir, and no other spring.exe."""
    needle = str(Path(d).resolve()).replace("/", "\\").lower()
    ps = ("Get-CimInstance Win32_Process -Filter \"Name='spring.exe' or Name='spring-headless.exe'\" | "
          "ForEach-Object { \"$($_.ProcessId)|$($_.CommandLine)\" }")
    try:
        out = subprocess.run(["powershell", "-NoProfile", "-Command", ps], capture_output=True, text=True,
                             timeout=5, check=True).stdout
    except (OSError, subprocess.SubprocessError) as error:
        raise RuntimeError("Engine inventory unavailable; not evidence of exit") from error
    # the exact write dir: "--write-dir <dir>" followed by a space, a quote or the
    # end (a plain substring test matched C:\bardev\barb-playtest inside
    # C:\bardev\barb-playtest-sim1, so one run's stop killed parallel runs)
    pat = re.compile(r'--write-dir\s+"?' + re.escape(needle) + r'\\?"?(\s|$)')
    pids = []
    for line in out.splitlines():
        pid, _, cl = line.partition("|")
        if pat.search(cl.lower()) and pid.strip().isdigit():
            pids.append(int(pid))
    return pids


def owned_engine(d):
    key = engine_process.canonical(d)
    if key not in _engines:
        manifest = Path(d) / 'launched.json'
        if not manifest.exists():
            return None
        _engines[key] = engine_process.attach(json.loads(manifest.read_text()), d)
    return _engines[key]


def engine_alive(d):
    # Old archived logs can still be judged with --no-stop; live supervision
    # uses a retained handle and never polls PowerShell in the watch loop.
    process = owned_engine(d)
    return process.alive() if process else False


def request_stop(d):
    (Path(d) / 'playtest-stop.txt').write_text('stop\n', encoding='ascii')


def stop(args, quiet=False):
    d = Path(args.dir)
    process = owned_engine(d)
    pf = pid_file(d)
    killed = []
    if process:
        try:
            if process.alive():
                request_stop(d)
                deadline = time.monotonic() + float(getattr(args, 'shutdown_seconds', 6))
                while process.alive() and time.monotonic() < deadline:
                    time.sleep(.1)
                if process.alive():
                    process.terminate()
                killed.append(process.pid)
        finally:
            process.close()
            _engines[engine_process.canonical(d)] = None
    pf.unlink(missing_ok=True)
    if not quiet:
        log("stopped %s" % (killed if killed else "nothing (no playtest engine running)"))
    return killed


# --------------------------------------------------------------------------- watching the log

FRAME_RE = re.compile(r"\[f=(-?\d+)\]")
AI_RE = re.compile(r":::AI LOG:S:(\d+):T:(\d+):F:(-?\d+):L::(.*)$")
DETAILS_RE = re.compile(r"\[GameDetails\] skirmishAI=(\d+) team=(\d+) .*? role=(\d+)")
TIMELINE_RE = re.compile(r"\[Rule\] |\[Eco\] next|\[TECH\]\[Build\]|\[TECH\]\[Opening\]|\[TECH\]\[Factory\]|\[TECH\]\[Labs\]|\[Layout\]|\[Team\]\[Roster\]|\[Playtest\]|\[AIR\]|\[AirWave\]|\[Ferry\]")
NATIVE_RE = re.compile(r"Skirmish AI <[^>]*>: (EXP: |RESERVE: |BUILDER: |CBFactoryTask: )")


def load_checks(path):
    try:
        p = storage.resolve_definition(path, 'checks')
    except (ValueError, FileNotFoundError):
        die("no checks file %s" % path)
    return json.loads(p.read_text(encoding="utf-8")), p


def validate_checks(path):
    checks, _ = load_checks(path)
    keys = {e['key'] for e in checks.get('expect', [])}
    for item in checks.get('expect', []) + checks.get('forbid', []) + [checks[k] for k in ('pass_on', 'complete_on') if k in checks]:
        if not item.get('key'):raise ValueError('Every check needs a key')
        re.compile(item['pattern'])
        if item.get('after_key') and item['after_key'] not in keys:
            raise ValueError('Unknown predecessor: ' + item['after_key'])
        if item.get('same_as'):
            previous=next((e for e in checks.get('expect', []) if e['key']==item['same_as']),None)
            if previous is None:raise ValueError('Unknown binding: '+item['same_as'])
            names=set(re.compile(previous['pattern']).groupindex)
            if not names or not names.issubset(re.compile(item['pattern']).groupindex):
                raise ValueError('same_as needs the predecessor named groups: '+item['key'])
    return checks


def watch(args):
    try:
        return _watch(args)
    except BaseException as error:
        d = Path(args.dir)
        if d.exists():
            failure=json.dumps({'error': repr(error), 'verdict': 'FAIL'},indent=2)
            (d / 'runner-error.json').write_text(failure)
            archive=d/'runs'/storage.run_id();archive.mkdir(parents=True,exist_ok=False)
            (archive/'runner-error.json').write_text(failure)
            report='# Playtest report: FAIL\n\nRunner exception: '+repr(error)+'\n'
            (archive/'report.md').write_text(report)
            (d/'report.md').write_text(report)
            for name in ('infolog.txt','staged.json','launched.json','teams.json'):
                if (d/name).exists():shutil.copy2(d/name,archive/name)
        raise
    finally:
        if not args.no_stop:
            stop(args, quiet=True)


def _watch(args):
    d = Path(args.dir)
    checks, checks_path = load_checks(args.checks)
    checks_bytes = checks_path.read_bytes()
    stop_minute = float(args.minutes) if args.minutes else float(checks.get("stop_minute", 12))
    stop_frame = int(stop_minute * 60 * FPS)
    info = d / "infolog.txt"
    launched = json.loads((d / "launched.json").read_text()) if (d / "launched.json").exists() else {}
    role_int = ROLE_INT.get(args.role.upper(), 2)

    expects = [dict(e, seen=None) for e in checks.get("expect", [])]
    forbids = list(checks.get("forbid", []))
    pass_on = checks.get("pass_on")
    complete_on = checks.get('complete_on')
    complete_frame = None
    grace_frames = int(float(checks.get('completion_grace_seconds', 10)) * FPS)
    if complete_on:
        complete_on = dict(complete_on, re=re.compile(complete_on['pattern']))
    for e in expects:
        e["re"] = re.compile(e["pattern"])
    for f in forbids:
        f["re"] = re.compile(f["pattern"])
    if pass_on:
        pass_on["re"] = re.compile(pass_on["pattern"])

    frame = 0
    sid = None            # skirmish AI id of the team under test
    failures = []
    timeline = []
    native = []
    errors = []
    widget_loaded = False
    verdict = None
    reason = ""
    decided_frame = None
    decided_text = ""
    started = time.time()
    first_progress = None
    last_frame_time = started
    wall_limit = float(args.wall_minutes) * 60 if args.wall_minutes else (stop_minute * 90 + 240)
    pos = 0
    buf = ""
    last_report = 0
    last_progress = time.time()
    shutdown_started = None
    startup_seconds = float(getattr(args, 'startup_seconds', 120))
    stall_seconds = float(getattr(args, 'stall_seconds', 60))

    def minute(fr):
        return fr / (60.0 * FPS)

    def scope_ok(scope, this_sid):
        if scope in (None, "tech", "test"):
            return sid is not None and this_sid == sid
        return True

    while True:
        if info.exists():
            with open(info, "r", encoding="utf-8", errors="replace") as f:
                f.seek(pos)
                chunk = f.read()
                pos = f.tell()
            buf += chunk
            lines = buf.split("\n")
            buf = lines.pop()
            for line in lines:
                line = line.rstrip("\r")
                fm = FRAME_RE.search(line)
                event_frame = int(fm.group(1)) if fm else frame
                if fm:
                    if int(fm.group(1)) > frame:
                        last_progress = time.time()
                        last_frame_time = last_progress
                        if first_progress is None:first_progress=(event_frame,last_progress)
                    frame = max(frame, event_frame)
                if "[Playtest] widget loaded" in line:
                    widget_loaded = True
                if decided_frame is None and "[Playtest] decided:" in line:
                    decided_frame = event_frame
                    decided_text = line.split("decided: ", 1)[-1][:120]
                if re.search(r": ERR\s+:|SCRIPT CRASH|Lib exception|Access violation|has crashed|Fatal:", line) or "Fix compilation errors" in line:
                    errors.append(line)
                    verdict, reason = 'FAIL', 'script/engine error'
                am = AI_RE.search(line)
                this_sid = None
                text = line
                if am:
                    this_sid = int(am.group(1))
                    text = am.group(4)
                    if sid is None:
                        dm = DETAILS_RE.search(text)
                        if dm and int(dm.group(2)) == 0 and int(dm.group(3)) == role_int:
                            sid = int(dm.group(1))
                            log("team 0 is skirmish AI %d (%s)" % (sid, args.role))
                    if sid is not None and this_sid == sid and TIMELINE_RE.search(text):
                        timeline.append((frame, text))
                elif NATIVE_RE.search(line):
                    native.append((frame, line.split(">: ", 1)[-1]))
                if "[Playtest]" in line and not am:
                    timeline.append((frame, line.split("] ", 1)[-1] if "] " in line else line))
                for fb in forbids:
                    if fb.get("after_minute") and minute(frame) < float(fb["after_minute"]):
                        continue
                    if fb["re"].search(text if am else line) and scope_ok(fb.get("scope", "any"), this_sid):
                        failures.append("forbid '%s' hit at %.1f min: %s" % (fb["key"], minute(frame), (text if am else line)[-200:]))
                        verdict = "FAIL"
                        reason = "forbidden line"
                for e in expects:
                    matched = e['re'].search(text if am else line) if e['seen'] is None else None
                    if matched and scope_ok(e.get("scope", "tech"), this_sid):
                        if e.get('after_minute') is not None and minute(event_frame)<float(e['after_minute']):continue
                        if e.get('same_as'):
                            previous=next((o for o in expects if o['key']==e['same_as']),None)
                            bound=previous.get('bindings',{}) if previous else {}
                            if not bound or any(matched.groupdict().get(k)!=v for k,v in bound.items()):continue
                        # Judge the event frame, not when its buffered log batch
                        # was polled. A late match must not erase a deadline miss.
                        if e.get("by_minute") is not None and minute(event_frame) > float(e["by_minute"]):
                            continue
                        e["seen"] = (event_frame, (text if am else line)[-200:])
                        e['bindings']=matched.groupdict()
                        if e.get("after_key"):
                            other = next((o for o in expects if o["key"] == e["after_key"]), None)
                            if other is None or other["seen"] is None or other["seen"][0] is None or other["seen"][0] > event_frame:
                                failures.append("'%s' came before '%s' (%.1f min)" % (e["key"], e["after_key"], minute(event_frame)))
                                verdict = "FAIL"
                                reason = "order"
                if pass_on and pass_on["re"].search(text if am else line) and scope_ok(pass_on.get("scope", "tech"), this_sid):
                    verdict = verdict or "PASS"
                    reason = reason or "pass_on '%s'" % pass_on["key"]
                if complete_on and complete_frame is None and complete_on['re'].search(text if am else line) and scope_ok(complete_on.get('scope', 'any'), this_sid):
                    complete_frame = event_frame
        # deadlines
        for e in expects:
            if e["seen"] is None and e.get("by_minute") is not None and minute(frame) > float(e["by_minute"]):
                failures.append("'%s' not seen by %.1f min" % (e["key"], float(e["by_minute"])))
                e["seen"] = (None, "missed")
                verdict = "FAIL"
                reason = "deadline"
        alive = engine_alive(d)
        if (time.time() - last_report) > 5:
            last_report = time.time()
            log("%.1f min, frame %d, %d timeline lines, %d failures%s" % (minute(frame), frame, len(timeline), len(failures),
                                                                        "" if sid is not None else ", team 0 not identified yet"))
        finished = verdict == 'FAIL' and not args.keep_going
        if complete_frame is not None and frame >= complete_frame + grace_frames and all(e['seen'] and e['seen'][0] is not None for e in expects):
            verdict = verdict or 'PASS'
            reason = reason or 'scenario complete with survival grace'
            finished = True
        if frame >= stop_frame:
            verdict = verdict or "PASS"
            reason = reason or "reached %.0f min" % stop_minute
            finished = True
        # A decided game (one ally team left with living units, reported once a
        # minute by playtest_camera.lua) is not worth playing to stop_minute:
        # nothing the AI does after that is evidence. --play-decided keeps the
        # old behaviour for fixtures that need the loser's side to stay dead.
        if decided_frame is not None and not getattr(args, 'play_decided', False):
            verdict = verdict or "PASS"
            reason = reason or "game decided at %.1f min (%s)" % (minute(decided_frame), decided_text)
            finished = True
        if getattr(args, 'stop_when_met', False) and expects and all(e["seen"] is not None and e["seen"][0] is not None for e in expects):
            verdict = verdict or "PASS"
            reason = reason or "all expectations met at %.1f min" % minute(frame)
            finished = True
        if not alive:
            # The engine can flush its final seconds while running_pids polls.
            # Consume that tail before deciding an accelerated run ended early.
            if info.exists() and info.stat().st_size > pos:
                continue
            verdict = verdict or ("FAIL" if frame < stop_frame and not finished else "PASS")
            reason = reason or ("engine exited before the game started" if frame == 0
                                else "engine exited at %.1f min" % minute(frame))
            break
        if time.time() - started > wall_limit:
            verdict, reason = 'FAIL', 'wall clock limit'
            finished = True
        if not shutdown_started and ((frame <= 0 and time.time() - started > startup_seconds) or
                                     (frame > 0 and time.time() - last_progress > stall_seconds)):
            verdict, reason = 'FAIL', 'startup timeout' if frame <= 0 else 'simulation progress timeout'
            finished = True
        if finished and shutdown_started is None:
            if args.no_stop:
                break
            shutdown_started = time.time()
            request_stop(d)
        if shutdown_started is not None and time.time() - shutdown_started >= float(getattr(args, 'shutdown_seconds', 6)):
            stop(argparse.Namespace(dir=str(d), shutdown_seconds=0), quiet=True)
            # Re-read the flushed tail before final verdict/archive.
            continue
        time.sleep(float(args.poll))

    missing = [e["key"] for e in expects if e["seen"] is None or e["seen"][0] is None]
    if verdict == "PASS" and missing:
        verdict = "FAIL"
        reason = "expected lines never seen: " + ", ".join(missing)
    if verdict is None:
        verdict = "FAIL"
    if errors:
        verdict = "FAIL"
        reason = "script errors"

    if not args.no_stop:
        stop(args, quiet=True)

    # the report
    run_dir = d / "runs" / storage.run_id()
    run_dir.mkdir(parents=True, exist_ok=False)
    shots = sorted((d / "screenshots").glob("*.png"))
    for s in shots:
        shutil.copy2(s, run_dir / s.name)
    if info.exists():
        shutil.copy2(info, run_dir / "infolog.txt")
    staged = json.loads((d / "staged.json").read_text()) if (d / "staged.json").exists() else {}
    teams = json.loads((d / "teams.json").read_text()) if (d / "teams.json").exists() else {}
    R = ["# Playtest report: %s" % verdict, "",
         "- Verdict: **%s** (%s)" % (verdict, reason),
         "- Game time reached: %.1f min (frame %d); wall %.0f s" % (minute(frame), frame, time.time() - started),
         "- DLL: %s (%s); AI %s; staged %s" % (staged.get("dll"), staged.get("dll_sha256_16"), staged.get("ai"), staged.get("staged")),
         "- Map: %s; game: %s; teams: %s" % (teams.get("map"), teams.get("game"),
                                            ", ".join("%d=%s/%s/%s" % (t["team"], t["role"], t["side"], t["ai"]) for t in teams.get("teams", []))),
         "- Team 0 (under test): skirmish AI %s, role %s" % (sid, args.role),
         "- Checks: %s; widget loaded: %s" % (checks_path.name, "yes" if widget_loaded else "not seen in log"),
         "- Log: %s" % (run_dir / "infolog.txt"), ""]
    R += ["## Checks", "", "| Check | Result | Line |", "| --- | --- | --- |"]
    for e in expects:
        if e["seen"] and e["seen"][0] is not None:
            R.append("| expect `%s` | seen at %.1f min | `%s` |" % (e["key"], minute(e["seen"][0]), e["seen"][1].replace("|", "/")))
        else:
            R.append("| expect `%s` | **missing**%s | |" % (e["key"], (" (by %s min)" % e["by_minute"]) if e.get("by_minute") else ""))
    for fb in forbids:
        hits = [f for f in failures if f.startswith("forbid '%s'" % fb["key"])]
        R.append("| forbid `%s` | %s | %s |" % (fb["key"], ("**hit**" if hits else "clean"), ("`%s`" % hits[0].split(": ", 1)[-1].replace("|", "/")) if hits else ""))
    if failures:
        R += ["", "## Failures", ""] + ["- " + f for f in failures]
    if errors:
        R += ["", "## Script errors", "", "```"] + errors[:20] + ["```"]
    R += ["", "## Screenshots", ""] + (["- %s" % (run_dir / s.name) for s in shots] or ["- none"])
    R += ["", "## Timeline (team 0)", "", "```"]
    R += ["%6.2f  %s" % (minute(fr), t[:220]) for fr, t in timeline[:args.timeline_lines]]
    if len(timeline) > args.timeline_lines:
        R.append("... %d more" % (len(timeline) - args.timeline_lines))
    R += ["```", "", "## Native lines (all AIs, first %d)" % 120, "", "```"]
    R += ["%6.2f  %s" % (minute(fr), t[:220]) for fr, t in native[:120]]
    R += ["```", ""]
    report = "\n".join(R)
    (run_dir / "report.md").write_text(report, encoding="utf-8")
    (d / "report.md").write_text(report, encoding="utf-8")
    timings = {'wall_seconds': time.time() - started, 'simulation_seconds': frame / FPS,
               'staging_seconds': staged.get('staging_seconds'),
               'complete_frame': complete_frame, 'shutdown_seconds': time.time() - shutdown_started if shutdown_started else None,
               'mode': staged.get('mode',getattr(args, 'mode', 'fast')),
               'requested_speed': staged.get('requested_speed'),
               'startup_seconds': first_progress[1]-started if first_progress else None,
               'achieved_simulation_speed': ((frame-first_progress[0])/FPS/(last_frame_time-first_progress[1])
                    if first_progress and last_frame_time>first_progress[1] else None)}
    (run_dir / 'runner-timing.json').write_text(json.dumps(timings, indent=2))
    storage.archive_metadata(d, run_dir, checks_bytes, verdict, reason, frame, not args.no_stop)
    print(report if args.print_report else "\n".join(R[:9 + len(expects) + len(forbids) + 4]))
    log("report: %s" % (run_dir / "report.md"))
    return 0 if verdict == "PASS" else 1


# --------------------------------------------------------------------------- main

def add_common(p):
    p.add_argument("--dir", default=str(DEFAULT_DIR), help="the engine's write directory for playtests")
    p.add_argument("--role", default="TECH", help="the role under test (team 0 takes its spot on the ally side)")


def add_stage_args(p):
    p.add_argument("--dll", help="SkirmishAI.dll to test (default: the docker build's install copy)")
    p.add_argument("--data", help="AI data dir with config/ script/ AIOptions.lua AIInfo.lua (default: the repo's data/)")
    p.add_argument("--set", action="append", help='override a role setting (Key=value means Tech; Air.Key=value selects Air) in the staged script, e.g. --set RushObjective=\'"afus"\'')
    p.add_argument("--mode", choices=['fast', 'visual', 'performance'], default='fast')
    p.add_argument("--speed", default="20", help="requested speed; achieved simulation speed is recorded separately")
    p.add_argument("--speed-plan", help="speed changes during the game, 'minute:speed,...' (e.g. '0:20,14:1,16:20')")
    p.add_argument("--slow-near-shots", action="store_true", help="speed 1 from 0.3 min before each screenshot until just after it, --speed between")
    p.add_argument("--minutes", default=None, help="game minutes to play (default: the checks file's stop_minute)")
    p.add_argument("--shots", default="", help="opt-in screenshot minutes (visual mode), optionally @height@x:z")
    p.add_argument("--cam-height", default="2200", help="overhead camera height for screenshots")
    p.add_argument("--width", default="1920")
    p.add_argument("--height", default="1080")


def add_script_args(p):
    p.add_argument("--map", help="map name as the lobby shows it (default: the last lobby script's)")
    p.add_argument("--map-file", help="the AI map file with the StartSpot table (default: derived from the map name)")
    p.add_argument("--game", help="game archive name (default: the last lobby script's, else the newest byar:test)")
    p.add_argument("--roles", default="all", help="roles to field on both sides, e.g. TECH,FRONT; 'all' = every spot")
    p.add_argument("--others", default="test", choices=["test", "prod", "none"],
                   help="the other AIs: this build (test), the deployed SMRTBARb (prod), or enemies only (none)")
    p.add_argument("--prod-ai", help="ShortName of the installed AI used for 'prod' teams (e.g. BARb for stock); it gets no test AI options")
    p.add_argument("--prod-version", help="version of --prod-ai (default stable)")
    p.add_argument("--opponent-dll", help="head-to-head: 'prod' teams play this pinned build of the AI (staged as BARbBase/base)")
    p.add_argument("--opponent-data", help="data/ for --opponent-dll (default: the repo's data/)")
    p.add_argument("--side", default="cortex", choices=SIDES, help="the side of the AI under test")
    p.add_argument("--ally-spots", help="1-based spot numbers of the ally side, e.g. '1,2,3,4,5,6,7,8' (default: first half)")
    p.add_argument("--modoption", action="append", help="key=value override in [MODOPTIONS]")
    p.add_argument("--ai-option", action="append", help="key=value in every test AI's [OPTIONS], e.g. profile=experimental_hard")
    p.add_argument("--engine", help="engine folder name under the install's engine/ (default: the one the lobby used last)")
    p.add_argument("--bonus", default=None, help="handicap percent for team 0 only (e.g. 50); benchmarks run at 0")
    p.add_argument("--extra-widget", action="append", help="an extra LuaUI widget to stage into the playtest write dir (repeatable)")
    p.add_argument("--lean-render", action="store_true", help="reduce graphics memory in this isolated write directory")
    p.add_argument("--headless", action="store_true", help="spring-headless.exe: no window; widgets, speed and [Playtest] lines still work; screenshots are blank 187-byte PNGs")


def add_watch_args(p):
    p.add_argument("--checks", default="tech_opening", help="checks file (name under tools/playtest/checks or a path)")
    p.add_argument("--poll", default="1.0")
    p.add_argument("--wall-minutes", default=None)
    p.add_argument("--keep-going", action="store_true", help="do not stop at the first failure")
    p.add_argument("--no-stop", action="store_true", help="leave the game running after the verdict")
    p.add_argument("--play-decided", action="store_true", help="keep playing after one ally team is left alive (default: stop, the rest is not evidence)")
    p.add_argument("--stop-when-met", action="store_true", help="stop as soon as every expect line has been seen (forbids after that point are not observed)")
    p.add_argument("--print-report", action="store_true")
    p.add_argument("--timeline-lines", type=int, default=400)
    p.add_argument('--startup-seconds', type=float, default=120)
    p.add_argument('--stall-seconds', type=float, default=60)
    p.add_argument('--shutdown-seconds', type=float, default=6)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("stage"); add_common(p); add_stage_args(p); add_script_args(p)
    p = sub.add_parser("launch"); add_common(p); add_script_args(p)
    p = sub.add_parser("watch"); add_common(p); add_watch_args(p); p.add_argument("--minutes", default=None)
    p = sub.add_parser("stop"); add_common(p)
    p = sub.add_parser("run"); add_common(p); add_stage_args(p); add_script_args(p); add_watch_args(p)
    args = ap.parse_args()
    if args.cmd in ('watch', 'run'):
        validate_checks(args.checks)  # invalid checks must never leave a launched engine

    if args.cmd == "stop":
        stop(args)
        return 0
    if args.cmd in ("stage", "run"):
        if args.minutes is None:
            checks, _ = load_checks(args.checks) if hasattr(args, "checks") else ({}, None)
            args.minutes = str(checks.get("stop_minute", 12))
        stage(args)
        write_script(args, Path(args.dir))
        if args.cmd == "stage":
            return 0
    if args.cmd in ("launch", "run"):
        launch(args)
        if args.cmd == "launch":
            return 0
    return watch(args)


if __name__ == "__main__":
    sys.exit(main())
