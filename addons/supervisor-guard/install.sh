#!/usr/bin/env bash
# Install or update the supervisor-work guard for this user and one firstmate home.
# Idempotent: rerun it to update. Usage: install.sh [--dry-run] <fm-home>
# Copies the three guard files to ${XDG_DATA_HOME:-$HOME/.local/share}/fm-supervisor-guard,
# records the home, and merges one PreToolUse Bash hook into ~/.claude/settings.json.
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -f "$1/bin/fm-primary-scope-lib.sh" ] && [ -f "$1/bin/fm-arm-command-policy.mjs" ] \
  || { echo "usage: install.sh [--dry-run] <fm-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-supervisor-guard
SETTINGS=$HOME/.claude/settings.json
STAMP=$(date +%s)
TMP=$(mktemp -d)
on_exit() {
  rm -rf -- "$TMP"
}
trap on_exit EXIT

# put <target> <candidate> [jq-path]: replace target with candidate after a backup;
# prints the diff (JSON: only jq-path). Dry run prints and writes nothing.
put() {
  local target=$1 new=$2 view=${3:-} old="$TMP/old"
  if [ -e "$target" ] && cmp -s "$target" "$new"; then echo "unchanged: $target"; return; fi
  if [ -n "$view" ]; then
    jq "$view" "$target" > "$old" 2>/dev/null || : > "$old"
    diff -u --label "$target (before) $view" --label "$target (after) $view" "$old" <(jq "$view" "$new") || true
  else
    diff -u --label "$target (before)" --label "$target (after)" "$target" "$new" 2>/dev/null || [ -e "$target" ] || echo "new: $target"
  fi
  [ "$DRY" -eq 0 ] || return 0
  mkdir -p "$(dirname "$target")"
  if [ -e "$target" ]; then cp -p "$target" "$target.bak-supervisor-guard-$STAMP"; fi
  cat "$new" > "$target.tmp-$STAMP" && mv "$target.tmp-$STAMP" "$target"
}

# The hook runs only in a Claude session: Grok sets GROK_AGENT or GROK_HOOK_EVENT,
# and the guard is registered for Claude alone.
HOOK="$DEST/fm-supervisor-work-pretool-check.sh"
CMD="[ -z \"\${GROK_AGENT:-}\${GROK_HOOK_EVENT:-}\" ] || exit 0; exec '$HOOK'"
[ -s "$SETTINGS" ] && cat "$SETTINGS" > "$TMP/before.json" || echo '{}' > "$TMP/before.json"
# shellcheck disable=SC2016 # $cmd is a jq variable
jq --arg cmd "$CMD" '
  .hooks.PreToolUse = ([.hooks.PreToolUse[]? | .hooks |= map(select((.command // "") | contains("fm-supervisor-work-pretool-check.sh") | not)) | select(.hooks | length > 0)]
    + [{matcher: "Bash", hooks: [{type: "command", command: $cmd, timeout: 10}]}])' "$TMP/before.json" > "$TMP/settings.json"
put "$SETTINGS" "$TMP/settings.json" .hooks.PreToolUse

for f in fm-supervisor-work-pretool-check.sh fm-supervisor-work-decide.mjs fm-supervisor-work-command-policy.mjs; do
  cp "$SRC/bin/$f" "$TMP/$f"
  put "$DEST/$f" "$TMP/$f"
  [ "$DRY" -eq 1 ] || chmod 755 "$DEST/$f"
done
{ [ ! -f "$DEST/home" ] || cat "$DEST/home"; printf '%s\n' "$FMH"; } | awk 'NF && !seen[$0]++' > "$TMP/home"
put "$DEST/home" "$TMP/home"
[ "$DRY" -eq 0 ] || echo "dry run: nothing written"
