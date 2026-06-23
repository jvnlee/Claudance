#!/usr/bin/env python3
import json
import os
import shutil
import sys
import time

SETTINGS = os.environ.get("CLAUDE_DANCE_SETTINGS") or os.path.expanduser("~/.claude/settings.json")


def is_clawd_group(group):
    if not isinstance(group, dict):
        return False
    for h in group.get("hooks", []):
        if isinstance(h, dict) and "clawd-hook.sh" in h.get("command", ""):
            return True
    return False


def main():
    if not os.path.exists(SETTINGS):
        print("  no settings.json; nothing to do")
        return
    with open(SETTINGS) as f:
        try:
            settings = json.load(f)
        except json.JSONDecodeError as e:
            print(f"ERROR: {SETTINGS} is not valid JSON ({e}); aborting.", file=sys.stderr)
            sys.exit(1)

    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        print("  no hooks present; nothing to do")
        return

    backup = SETTINGS + ".clawd-backup-" + time.strftime("%Y%m%d-%H%M%S")
    shutil.copy2(SETTINGS, backup)
    print(f"  backed up settings -> {backup}")

    removed = 0
    for event in list(hooks.keys()):
        groups = hooks.get(event)
        if not isinstance(groups, list):
            continue
        kept = [g for g in groups if not is_clawd_group(g)]
        removed += len(groups) - len(kept)
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]

    if not hooks:
        del settings["hooks"]

    tmp = SETTINGS + ".tmp"
    with open(tmp, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    os.replace(tmp, SETTINGS)
    print(f"  removed {removed} Clawd hook entr{'y' if removed == 1 else 'ies'}")


if __name__ == "__main__":
    main()
