#!/usr/bin/env python3
import json
import os
import shutil
import sys
import time

SETTINGS = os.environ.get("CLAUDE_DANCE_SETTINGS") or os.path.expanduser("~/.claude/settings.json")
HOOK_DEFAULT = os.path.expanduser("~/.claude/claudance/clawd-hook.sh")

EVENTS = [
    ("SessionStart", "idle", False),
    ("UserPromptSubmit", "working", False),
    ("PostToolUse", "working", True),
    ("Notification", "waiting", False),
    ("Stop", "idle", False),
    ("SessionEnd", "end", False),
]


def is_clawd_group(group):
    if not isinstance(group, dict):
        return False
    for h in group.get("hooks", []):
        if isinstance(h, dict) and "clawd-hook.sh" in h.get("command", ""):
            return True
    return False


def main():
    hookpath = sys.argv[1] if len(sys.argv) > 1 else HOOK_DEFAULT

    if os.path.exists(SETTINGS):
        with open(SETTINGS) as f:
            try:
                settings = json.load(f)
            except json.JSONDecodeError as e:
                print(f"ERROR: {SETTINGS} is not valid JSON ({e}); aborting.", file=sys.stderr)
                sys.exit(1)
        backup = SETTINGS + ".clawd-backup-" + time.strftime("%Y%m%d-%H%M%S")
        shutil.copy2(SETTINGS, backup)
        print(f"  backed up settings -> {backup}")
    else:
        settings = {}
        print("  no existing settings.json; creating a new one")

    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        hooks = {}
    settings["hooks"] = hooks

    for event in list(hooks.keys()):
        groups = hooks.get(event)
        if not isinstance(groups, list):
            continue
        kept = [g for g in groups if not is_clawd_group(g)]
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]

    for event, state, needs_matcher in EVENTS:
        groups = hooks.get(event)
        if not isinstance(groups, list):
            groups = []
        group = {"hooks": [{"type": "command", "command": f'"{hookpath}" {state}'}]}
        if needs_matcher:
            group["matcher"] = ""
        groups.append(group)
        hooks[event] = groups

    settings_dir = os.path.dirname(SETTINGS)
    if settings_dir:
        os.makedirs(settings_dir, exist_ok=True)
    tmp = SETTINGS + ".tmp"
    with open(tmp, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    os.replace(tmp, SETTINGS)
    print(f"  installed Clawd hooks for: {', '.join(e for e, _, _ in EVENTS)}")


if __name__ == "__main__":
    main()
