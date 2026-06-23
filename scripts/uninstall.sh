#!/bin/bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Removing hooks from ~/.claude/settings.json"
python3 "$ROOT/scripts/uninstall_hooks.py" || echo "    WARNING: settings.json was not updated (malformed JSON?); remove the clawd-hook.sh entries by hand."

echo "==> Quitting the app if it's running"
osascript -e 'tell application "Claudance" to quit' 2>/dev/null \
    || pkill -x Claudance 2>/dev/null || true

echo "==> Removing support files (~/.claude/claudance)"
rm -rf "$HOME/.claude/claudance"

echo "==> Removing app bundles"
rm -rf "$ROOT/dist/Claudance.app" 2>/dev/null || true
rm -rf "/Applications/Claudance.app" 2>/dev/null || true

echo "Done. (settings.json .clawd-backup-* files were left untouched.)"
