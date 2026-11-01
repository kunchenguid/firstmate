#!/usr/bin/env bash
# Live guard for the vendor fact bin/fm-spawn.sh's bypass launch rests on:
# `skipDangerousModePermissionPrompt: true` carried in the `--settings` file
# suppresses Claude Code's Bypass Permissions accept dialog even under
# `--setting-sources ''`, the source list a task worker launches with.
#
# That empty list excludes the user scope where an operator's acceptance lands,
# so without the key every bypass worker parks on `No, exit` / `Yes, I accept`.
# A stub claude could only echo that assumption back, so this drives the
# INSTALLED binary interactively in an isolated tmux server against a scratch
# CLAUDE_CONFIG_DIR holding no credentials, and fails naming its version.
#
# It submits no prompt and holds no login, so it spends no model tokens and the
# gate is default-on wherever claude and tmux are installed (fm_live_gate).
# Two arms keep it from passing vacuously: the same launch without the key must
# still show the dialog, and the launch with it must reach the composer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CLAUDE_BYPASS_PROMPT_LIVE claude tmux

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -1)
[ -n "$CLAUDE_VERSION" ] || fail "installed claude did not answer --version"

SOCKET="fm-claude-bypass-$$"
cleanup_socket() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; fm_test_cleanup; }
trap cleanup_socket EXIT

LAB=$(fm_test_tmproot fm-claude-bypass-prompt-live)

# arm <name> <settings-json> prints the verdict for one interactive launch:
# dialog (the accept dialog is on screen), composer (the bypass-mode composer
# footer rendered with no dialog), or unknown (neither within the deadline).
arm() {
  local name=$1 settings=$2 dir="$LAB/$1" pane= verdict=unknown i
  mkdir -p "$dir/work" "$dir/config"
  # A scratch store with onboarding finished and the workspace already trusted,
  # so the bypass dialog is the only gate left between launch and composer.
  printf '{"hasCompletedOnboarding":true,"theme":"dark","projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' \
    "$dir/work" >"$dir/config/.claude.json"
  printf '{}\n' >"$dir/config/settings.json"
  printf '%s\n' "$settings" >"$dir/settings.json"
  tmux -L "$SOCKET" new-session -d -s "$name" -x 160 -y 45 -c "$dir/work" -- \
    env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDECODE \
    CLAUDE_CONFIG_DIR="$dir/config" \
    claude --dangerously-skip-permissions --settings "$dir/settings.json" --setting-sources ''
  for i in $(seq 1 60); do
    sleep 0.5
    pane=$(tmux -L "$SOCKET" capture-pane -p -t "$name" 2>/dev/null) || continue
    # Either dialog string carries a positive verdict, so one reworded line
    # cannot hide the dialog.
    if printf '%s\n' "$pane" | grep -qE 'Yes, I accept|Bypass Permissions mode'; then
      verdict=dialog
      break
    fi
    if printf '%s\n' "$pane" | grep -q 'bypass permissions on'; then
      # Settle and look again, so a dialog drawn after the first composer
      # frame still fails the treatment arm instead of passing it.
      sleep 3
      pane=$(tmux -L "$SOCKET" capture-pane -p -t "$name" 2>/dev/null) || pane=
      if printf '%s\n' "$pane" | grep -qE 'Yes, I accept|Bypass Permissions mode'; then
        verdict=dialog
      elif printf '%s\n' "$pane" | grep -q 'bypass permissions on'; then
        verdict=composer
      fi
      break
    fi
  done
  printf '%s\n' "$pane" >"$dir/pane.txt"
  tmux -L "$SOCKET" kill-session -t "$name" 2>/dev/null || true
  printf '%s\n' "$verdict"
}

POLICY='"feedbackDrafts":"off","attribution":{"commit":"","pr":"","sessionUrl":false}'

CONTROL=$(arm control "{$POLICY}")
[ "$CONTROL" = dialog ] \
  || fail "claude $CLAUDE_VERSION showed no Bypass Permissions dialog without the key (verdict $CONTROL), so this guard can no longer tell the fix apart: $(cat "$LAB/control/pane.txt")"

TREATMENT=$(arm treatment "{$POLICY,\"skipDangerousModePermissionPrompt\":true}")
[ "$TREATMENT" = composer ] \
  || fail "claude $CLAUDE_VERSION did not honor skipDangerousModePermissionPrompt from --settings under --setting-sources '' (verdict $TREATMENT): $(cat "$LAB/treatment/pane.txt")"

pass "claude $CLAUDE_VERSION skips the Bypass Permissions dialog when --settings carries skipDangerousModePermissionPrompt"
echo "all fm-claude-bypass-prompt-live-e2e tests passed"
