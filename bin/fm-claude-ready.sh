#!/usr/bin/env bash
# Report whether this machine has accepted Claude Code's bypass-permissions
# confirmation, so a spawn can refuse before allocating a worker that would
# stop on a dialog firstmate cannot answer.
#
# Usage: fm-claude-ready.sh check [<project>]
#   <project>  optional project root whose .claude settings also count
# Prints one line naming the evidence it found; refuses loudly otherwise.
#
# WHY THIS EXISTS. Launching with --dangerously-skip-permissions does not by
# itself get a worker to its brief. Claude Code shows a separate once-per-
# machine confirmation before it will run in bypass mode. That dialog renders
# with the selection on "No, exit", and firstmate's key plane carries only
# Enter, Escape and C-c with no arrow navigation, so firstmate cannot accept
# it - a sent Enter ends the session instead. A worker that meets it sits
# there until the watcher reports it wedged and an operator relaunches the
# task on another runtime. That prerequisite is attended, so the only useful
# thing firstmate can do about it is establish it BEFORE dispatch.
#
# This is separate from workspace trust, which is per-path and is
# pre-registered by bin/fm-claude-trust.sh. Both gates must be clear.
#
# THE SIGNAL. Claude Code skips that confirmation for a session started in
# bypass mode when `skipDangerousModePermissionPrompt` is set in the settings
# chain it reads, and accepting the dialog is what records it. The check reads
# the same files Claude does - managed settings, this user's settings, and the
# project's own settings - and treats a `true` anywhere in that chain as the
# acceptance. Nothing is ever written here; provisioning stays attended.
#
# If a future Claude release records the acceptance somewhere else, this
# refuses a machine that is in fact ready rather than passing one that is not.
# That refusal names the installed Claude version so the change is visible
# rather than silent, and FM_CLAUDE_BYPASS_READY=1 declares readiness for one
# invocation while the check is brought back in line with the release.
set -u

unset CDPATH

SCRIPT_NAME=$(basename "${BASH_SOURCE[0]}")
refuse() { printf '%s: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 1; }

[ "${1:-}" = check ] || { printf 'usage: %s check [<project>]\n' "$SCRIPT_NAME" >&2; exit 2; }
PROJECT=${2:-}

if [ "${FM_CLAUDE_BYPASS_READY:-}" = 1 ]; then
  echo "ready: declared by FM_CLAUDE_BYPASS_READY"
  exit 0
fi

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1 || true)
[ -n "$CLAUDE_VERSION" ] || CLAUDE_VERSION="unknown version"

case ${CLAUDE_CONFIG_DIR:-} in
  '') USER_SETTINGS_DIR="${HOME:-}/.claude" ;;
  /*) USER_SETTINGS_DIR="$CLAUDE_CONFIG_DIR" ;;
  *) refuse "CLAUDE_CONFIG_DIR '$CLAUDE_CONFIG_DIR' is a relative path, so the settings the worker reads cannot be located; set it to an absolute path" ;;
esac

# Claude's own precedence puts managed settings above the user's, but this only
# asks whether ANY of them records the acceptance, so order does not matter.
SETTINGS_FILES=(
  "/Library/Application Support/ClaudeCode/managed-settings.json"
  "/etc/claude-code/managed-settings.json"
  "$USER_SETTINGS_DIR/settings.json"
)
if [ -n "$PROJECT" ]; then
  SETTINGS_FILES+=("$PROJECT/.claude/settings.json" "$PROJECT/.claude/settings.local.json")
fi

# node reads the settings, matching bin/fm-claude-trust.sh's own store access:
# a hand-rolled JSON scan would accept the key inside a comment or a string.
command -v node >/dev/null 2>&1 \
  || refuse "node is required to read Claude's settings and was not found on PATH"

for settings in "${SETTINGS_FILES[@]}"; do
  [ -f "$settings" ] && [ -r "$settings" ] || continue
  if node - "$settings" <<'NODE'
const fs = require("node:fs");
let parsed;
try {
  parsed = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
} catch {
  process.exit(1);
}
process.exit(parsed && parsed.skipDangerousModePermissionPrompt === true ? 0 : 1);
NODE
  then
    echo "ready: bypass-permissions confirmation accepted ($settings)"
    exit 0
  fi
done

refuse "this machine has not accepted Claude Code's bypass-permissions confirmation ($CLAUDE_VERSION), which firstmate cannot answer for a worker; run 'claude --dangerously-skip-permissions' once in a terminal and accept it, then re-run the spawn"
