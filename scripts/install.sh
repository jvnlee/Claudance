#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="$HOME/.claude/claudance"

echo "==> 1/4  Installing hook script to $SUPPORT"
mkdir -p "$SUPPORT/sessions"
cp "$ROOT/hooks/clawd-hook.sh" "$SUPPORT/clawd-hook.sh"
chmod +x "$SUPPORT/clawd-hook.sh"

echo "==> 2/4  Merging hooks into ~/.claude/settings.json"
python3 "$ROOT/scripts/install_hooks.py" "$SUPPORT/clawd-hook.sh"

echo "==> 3/4  Rendering the app icon"
"$ROOT/scripts/make_icon.sh"

echo "==> 4/4  Building the app"
"$ROOT/scripts/build_app.sh"

cat <<EOF

Installed.

Launch it now:
    open "$ROOT/dist/Claudance.app"

Optional — move it to Applications so it's always available:
    cp -R "$ROOT/dist/Claudance.app" /Applications/ && open /Applications/Claudance.app

Clawd will appear in your menu bar. It dances while Claude Code is working,
sways while a session is idle, waves when a session needs you, and rests when no
session is running. Running Claude Code sessions pick up the new hooks within a
few seconds — no restart needed.

To remove everything later:  scripts/uninstall.sh
EOF
