#!/usr/bin/env python3
"""Copy the LuaUI widgets in this folder into the local BAR install.

Usage:
  python tools/widgets/deploy_widgets.py              copy every *.lua here
  python tools/widgets/deploy_widgets.py --if-newer   copy only the ones newer than the installed copy
  python tools/widgets/deploy_widgets.py --quiet      say nothing unless something was copied

The destination is the game's LuaUI/Widgets folder under %LOCALAPPDATA%
(override with BAR_DATA_DIR). When it does not exist nothing happens, so the
script is safe to run on a machine without the game. This is an owner-invoked
deployment utility; no coding-agent hook runs it. Agents stage test widgets in
isolated playtest directories and follow the deployment rules in AGENTS.md.
"""
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def data_dir():
    override = os.environ.get("BAR_DATA_DIR")
    if override:
        return override
    local = os.environ.get("LOCALAPPDATA")
    if not local:
        return None
    return os.path.join(local, "Programs", "Beyond-All-Reason", "data")


def main(argv):
    if_newer = "--if-newer" in argv
    quiet = "--quiet" in argv
    base = data_dir()
    if not base:
        if not quiet:
            print("deploy_widgets: LOCALAPPDATA is not set; nothing copied")
        return 0
    dest = os.path.join(base, "LuaUI", "Widgets")
    if not os.path.isdir(dest):
        if not quiet:
            print("deploy_widgets: no game install at %s; nothing copied" % dest)
        return 0
    copied = 0
    for name in sorted(os.listdir(HERE)):
        if not name.endswith(".lua"):
            continue
        src = os.path.join(HERE, name)
        dst = os.path.join(dest, name)
        if if_newer and os.path.exists(dst) and os.path.getmtime(dst) >= os.path.getmtime(src):
            continue
        shutil.copy2(src, dst)
        copied += 1
        print("deploy_widgets: %s -> %s" % (name, dst))
    if copied == 0 and not quiet:
        print("deploy_widgets: nothing to copy")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
