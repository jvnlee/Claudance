#!/bin/sh

dir="$HOME/.claude/claudance/sessions"
ev="$1"

payload=$(cat 2>/dev/null)

sid=$(printf '%s' "$payload" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -n 's/.*"\([^"]*\)"$/\1/p')

sid=$(printf '%s' "$sid" | tr -cd 'A-Za-z0-9._-')
[ -z "$sid" ] && sid="default"

f="$dir/$sid.json"

case "$ev" in
  end)
    rm -f "$f" 2>/dev/null
    ;;
  working|idle|waiting)
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null
    tmp="$f.$$.tmp"
    printf '{"state":"%s","ts":%s}\n' "$ev" "$(date +%s)" > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null
    ;;
  *)
    :
    ;;
esac

exit 0
