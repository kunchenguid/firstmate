#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq programs are literal
# Keep Claude Code off Fable for every session that reads this config dir's user settings. Sonnet is allowed. Every Fable
# form ends on Haiku or is refused, never on another model:
#   env.ANTHROPIC_DEFAULT_FABLE_MODEL = claude-haiku-5-5
#     the fable alias (--model fable, agent "model: fable") resolves to Haiku;
#   hooks.UserPromptSubmit and hooks.PreToolUse (Agent|Task) run refuse-model.sh
#     a full id such as claude-fable-5-1 (--model, ANTHROPIC_MODEL, settings "model", an Agent call's model) is refused
#     before any request is sent.
# An earlier version also mapped env.ANTHROPIC_DEFAULT_SONNET_MODEL to Haiku; install.sh and --restore delete that key
# when it still holds claude-haiku-5-5, so a reinstall upgrades an old install.
# refuse-model.sh is copied to ${XDG_DATA_HOME:-~/.local/share}/fm-claude-model-guard. Settings are edited at key level with a
# backup; only these keys are printed, never the file, other keys, or credentials (never read or touched).
# Not covered: a launch with --setting-sources that leaves out "user" (fm-live-lab.sh's primary uses project,local); user
# settings do not load there at all.
# Usage: install.sh [--dry-run] [--restore] [--config-dir <dir>]   (default ${CLAUDE_CONFIG_DIR:-~/.claude})
# --restore removes exactly the guard's keys and hook entries when they still hold the values above.
set -euo pipefail
DRY=0 RESTORE=0 DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY=1 ;;
    --restore) RESTORE=1 ;;
    --config-dir) DIR=${2:?--config-dir needs a path}; shift ;;
    *) echo "usage: install.sh [--dry-run] [--restore] [--config-dir <dir>]" >&2; exit 2 ;;
  esac
  shift
done
[ -d "$DIR" ] || { echo "install.sh: no Claude config dir at $DIR" >&2; exit 1; }
F=$DIR/settings.json
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/fm-claude-model-guard
HOOK=$DEST/refuse-model.sh
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
{ [ -s "$F" ] && cat "$F" || echo '{}'; } > "$TMP/old.json"
jq -e 'type == "object"' "$TMP/old.json" >/dev/null || { echo "install.sh: $F is not a JSON object; nothing changed" >&2; exit 1; }

H=claude-haiku-5-5
stale='if .env.ANTHROPIC_DEFAULT_SONNET_MODEL == $h then del(.env.ANTHROPIC_DEFAULT_SONNET_MODEL) else . end'
drop='map(select(any(.hooks[]?; .command == $c) | not))'
if [ "$RESTORE" -eq 1 ]; then
  jq --arg h "$H" --arg c "$HOOK" "
    $stale
    | if .env.ANTHROPIC_DEFAULT_FABLE_MODEL == \$h then del(.env.ANTHROPIC_DEFAULT_FABLE_MODEL) else . end
    | if .hooks.UserPromptSubmit then .hooks.UserPromptSubmit |= $drop else . end
    | if .hooks.PreToolUse then .hooks.PreToolUse |= $drop else . end" "$TMP/old.json" > "$TMP/new.json"
else
  jq --arg h "$H" --arg c "$HOOK" "
    $stale
    | .env.ANTHROPIC_DEFAULT_FABLE_MODEL = \$h
    | .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // [] | $drop) + [{hooks: [{type: \"command\", command: \$c}]}])
    | .hooks.PreToolUse = ((.hooks.PreToolUse // [] | $drop) + [{matcher: \"Agent|Task\", hooks: [{type: \"command\", command: \$c}]}])" \
    "$TMP/old.json" > "$TMP/new.json"
fi

view='{ANTHROPIC_DEFAULT_SONNET_MODEL: .env.ANTHROPIC_DEFAULT_SONNET_MODEL, ANTHROPIC_DEFAULT_FABLE_MODEL: .env.ANTHROPIC_DEFAULT_FABLE_MODEL,
  guard_hooks: [.hooks // {} | to_entries[] | select(any(.value[]?.hooks[]?; .command == $c)) | .key]}'
hook_ok=1
[ "$RESTORE" -eq 1 ] || cmp -s "$(dirname "${BASH_SOURCE[0]}")/refuse-model.sh" "$HOOK" || hook_ok=0
if [ "$hook_ok" -eq 1 ] && jq -e --slurpfile o "$TMP/old.json" '. == $o[0]' "$TMP/new.json" >/dev/null; then
  echo "unchanged: $F $(jq -c --arg c "$HOOK" "$view" "$TMP/new.json")"
  exit 0
fi
[ "$hook_ok" -eq 1 ] || echo "$HOOK: install from $(dirname "${BASH_SOURCE[0]}")/refuse-model.sh"
echo "$F: $(jq -c --arg c "$HOOK" "$view" "$TMP/old.json") -> $(jq -c --arg c "$HOOK" "$view" "$TMP/new.json")"
[ "$DRY" -eq 0 ] || { echo "dry run: nothing written"; exit 0; }
[ "$hook_ok" -eq 1 ] || { mkdir -p "$DEST"; install -m 755 "$(dirname "${BASH_SOURCE[0]}")/refuse-model.sh" "$HOOK"; }
STAMP=$(date +%s)
cp "$TMP/new.json" "$F.tmp-$STAMP"
if [ -e "$F" ]; then
  cp -p "$F" "$F.bak-claude-model-guard-$STAMP" && chmod --reference="$F" "$F.tmp-$STAMP"
  echo "backup: $F.bak-claude-model-guard-$STAMP"
fi
mv "$F.tmp-$STAMP" "$F"
echo "written: $F"
