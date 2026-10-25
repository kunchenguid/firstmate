#!/usr/bin/env bash
# Install or update the fleet delete guard for this user and register its watcher check in one firstmate home.
# Idempotent: rerun it to update. Usage: install.sh [--dry-run] <fm-home>
set -euo pipefail
DRY=0
[ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ "$#" -eq 1 ] && [ -x "$1/bin/fm-check-register.sh" ] || { echo "usage: install.sh [--dry-run] <fm-home>" >&2; exit 2; }
FMH=$(cd "$1" && pwd -P)
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-delete-guard
STAMP=$(date +%s)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
# Every Claude config folder: ~/.claude and each Claude account folder in the muxr registry the account pool launches
# workers with (CLAUDE_CONFIG_DIR), whose settings.json replaces ~/.claude's. Rerun after adding an account.
REG=${FM_CLAUDE_ACCOUNTS_REGISTRY:-$HOME/.muxr/plans/accounts-v1.json}
CLAUDE_DIRS=$( { echo "$HOME/.claude"; [ ! -e "$REG" ] || jq -r '.accounts[] | select(.provider == "claude") | .folder' "$REG" || echo "warning: cannot read $REG; only ~/.claude is covered" >&2; } | awk '!seen[$0]++')

# put <target> <candidate> [jq-path]: replace target with candidate after a backup; prints the diff (JSON: only jq-path).
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
  if [ -e "$target" ]; then cp -p "$target" "$target.bak-delete-guard-$STAMP" && cp -p "$target" "$target.tmp-$STAMP"; fi
  cat "$new" > "$target.tmp-$STAMP" && mv "$target.tmp-$STAMP" "$target"
}

# hook <settings.json> <runtime>: merge one PreToolUse Bash entry, dropping any older guard entry.
# Not Codex: upstream launches Codex crewmates with hooks off, and a new user hook trips its trust modal.
hook() {
  local file=$1 cmd="node '$DEST/guard.mjs' --runtime $2"
  [ -d "$(dirname "$file")" ] || { echo "skipped: $file (runtime not installed)"; return; }
  # shellcheck disable=SC2016 # $cmd is a jq variable
  { [ -s "$file" ] && cat "$file" || echo '{}'; } | jq --arg cmd "$cmd" '
    .hooks.PreToolUse = ([.hooks.PreToolUse[]? | .hooks |= map(select((.command // "") | contains("fm-delete-guard/guard.mjs") | not)) | select(.hooks | length > 0)]
      + [{matcher: "Bash", hooks: [{type: "command", command: $cmd, timeout: 10}]}])' > "$TMP/$2.json"
  put "$file" "$TMP/$2.json" .hooks.PreToolUse
}

cp "$SRC/guard.mjs" "$TMP/guard.mjs"
printf '%s\n' "$FMH" > "$TMP/home"
for f in guard.mjs home; do put "$DEST/$f" "$TMP/$f"; done
put "$DEST/check.sh" "$SRC/check.sh"
[ "$DRY" -eq 1 ] || chmod 755 "$DEST/check.sh"

for a in pi-extension.ts opencode-plugin.js; do sed "s|__GUARD__|$DEST/guard.mjs|" "$SRC/$a" > "$TMP/$a"; done
if [ -d "$HOME/.pi/agent" ]; then put "$HOME/.pi/agent/extensions/fm-rm-guard.ts" "$TMP/pi-extension.ts"; else echo "skipped: pi (not installed)"; fi
if [ -d "$HOME/.config/opencode" ]; then put "$HOME/.config/opencode/plugins/fm-delete-guard.js" "$TMP/opencode-plugin.js"; else echo "skipped: opencode (not installed)"; fi
while read -r d; do hook "$d/settings.json" claude; done <<<"$CLAUDE_DIRS"

printf '#!/usr/bin/env bash\nexec %q %q\n' "$DEST/check.sh" "$FMH" > "$TMP/check"
put "$FMH/state/delete-guard.check.sh" "$TMP/check"
[ "$DRY" -eq 0 ] || { echo "dry run: nothing written; would run $FMH/bin/fm-check-register.sh delete-guard"; exit 0; }
chmod 700 "$FMH/state/delete-guard.check.sh" && FM_HOME="$FMH" "$FMH/bin/fm-check-register.sh" delete-guard
