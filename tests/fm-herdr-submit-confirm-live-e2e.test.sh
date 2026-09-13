#!/usr/bin/env bash
# Live Herdr submit-confirmation guard (live-harness-optin family).
#
# Herdr's native agent_status can stay idle for a whole landed Claude turn, and
# a busy-queued Enter can keep proven pending text visible. Muse can also leave
# the native probe unreadable while a bare U+27E9 composer proves its message
# landed. A stub cannot prove any of those signals. This guard launches real
# Claude Code and every runnable Muse Code in an isolated Herdr lab, requiring
# fm_backend_herdr_send_text_submit to report empty for each landed steer. It
# fails naming the harness and version rather than degrading quietly.
#
# Run explicitly with FM_HERDR_SUBMIT_CONFIRM_LIVE=1 after a Herdr, Claude, or
# Muse upgrade, and before trusting a refreshed
# docs/verification/runtime-backends.md "Herdr submit confirmation" entry.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

# Same quoting bin/fm-spawn.sh applies to the values it substitutes into a
# launch command, so a path holding spaces or quotes survives the pane shell.
shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_live_gate opt-in FM_HERDR_SUBMIT_CONFIRM_LIVE herdr jq claude

[ -x "$LAB_HELPER" ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name herdr-submit-confirm-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-submit-confirm-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
CHECKED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-submitlive --no-focus) \
  || fail "could not create the isolated submit-confirm workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null \
  || fail "could not launch Claude Code ($VERSION) in the isolated Herdr pane"

idle=0
i=0
while [ "$i" -lt 45 ]; do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in idle|done|blocked) idle=1; break ;; esac
  i=$((i + 1))
  sleep 1
done
[ "$idle" = 1 ] || fail "Claude Code ($VERSION) on $HERDR_VER never registered an idle agent in the lab pane"

TOKEN="FMHERDRPONG$$_$RANDOM"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "Reply with exactly $TOKEN and nothing else." 3 0.4 0.4) \
  || fail "send_text_submit failed to run against Claude Code ($VERSION) on $HERDR_VER"
CHECKED=1
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a landed idle steer must confirm empty, got '$verdict'"

# Confirm the instruction reached Claude, not merely that the composer cleared.
# The token occurs once in the submitted prompt and once in Claude's reply.
landed=0
i=0
screen=''
while [ "$i" -lt 45 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  occurrences=$(printf '%s\n' "$screen" | grep -F -c "$TOKEN" || true)
  if [ "$occurrences" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: submit reported '$verdict' but the expected reply never rendered"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER reports empty and renders the requested reply in isolated session $SESSION"

# Muse normally has no registered Herdr agent state, so this probes the exact
# fallback path that once reported a false unconfirmed send despite a visible
# Muse turn. The runnable-harness rule is deliberate: a Muse that fm-spawn
# itself would refuse to launch here is reported rather than fabricated as a
# pass, while a Muse that it would launch must prove its current renderer and
# send behavior before it can be trusted.
MUSE_BIN=$(PATH="$ORIGINAL_PATH" command -v muse 2>/dev/null || true)
# The credential this preflight proves is the one the launched pane consumes:
# the config and data homes are pinned into the launch command below from the
# same values checked here, exactly as bin/fm-spawn.sh pins what it checks, so
# a custom XDG root in this shell and a plain one in the Herdr daemon can never
# disagree about where the credential lives.
# The stored subscription credential is the only path accepted here, with no
# META_API_KEY escape: muse_credential_present's key branch can only prove a
# key inside a tmux worker session, so fm-spawn refuses an API-key-only host on
# every other backend and this guard must refuse it identically.
# An unauthenticated muse does not exit, it parks on an OAuth device-code
# prompt, so without this preflight the leg would steer a pane that never
# became Muse and then blame the send path for the missing reply.
MUSE_CONFIG_HOME=${XDG_CONFIG_HOME:-${HOME:-}/.config}
MUSE_DATA_HOME=${XDG_DATA_HOME:-${HOME:-}/.local/share}
MUSE_AUTH_FILE="$MUSE_CONFIG_HOME/muse/auth.json"
if [ -z "$MUSE_BIN" ]; then
  printf '# muse is not installed; Muse-on-Herdr submit confirmation was not verified here\n'
elif [ ! -s "$MUSE_AUTH_FILE" ]; then
  printf '# muse is installed but has no stored credential at %s, which is the only credential a Herdr pane can use; Muse-on-Herdr submit confirmation was not verified here\n' \
    "$MUSE_AUTH_FILE"
else
  MUSE_VERSION=$(PATH="$ORIGINAL_PATH" "$MUSE_BIN" --version 2>/dev/null | head -1 || printf 'version-unknown')
  MUSE_TAB_JSON=$(lab tab create --workspace "$(printf '%s' "$WS_JSON" | jq -er '.result.workspace.workspace_id')" --cwd "$ROOT" --label fm-submitlive-muse --no-focus) \
    || fail "could not create a Muse tab in the isolated Herdr workspace"
  MUSE_PANE=$(printf '%s' "$MUSE_TAB_JSON" | jq -er '.result.root_pane.pane_id') \
    || fail "Muse tab create did not return a pane id"
  MUSE_TARGET="$SESSION:$MUSE_PANE"
  # The launch shape here is bin/fm-spawn.sh's verified muse template minus its
  # positional brief, since this guard needs an idle composer to steer: the same
  # env -u marker scrub, the same XDG pins, the same absolute resolved binary,
  # and MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on as the privacy
  # control, which is the control used because the interactive TUI rejects exec
  # mode's --no-foreign-personal-context flag.
  MUSE_LAUNCH=$(printf 'env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on %s --yolo' \
    "$(shell_quote "$MUSE_CONFIG_HOME")" "$(shell_quote "$MUSE_DATA_HOME")" "$(shell_quote "$MUSE_BIN")")
  lab pane run "$MUSE_PANE" "$MUSE_LAUNCH" >/dev/null \
    || fail "could not launch Muse Code ($MUSE_VERSION) in the isolated Herdr pane"

  # An empty composer alone is not proof Muse is up: the shared classifier reads
  # a bare shell prompt row as empty too, so a pane that never became Muse would
  # be steered into its own shell. The process-level probe is what separates the
  # two, and only both signals together open the leg.
  muse_idle=0
  i=0
  muse_state=unread
  muse_process=unread
  while [ "$i" -lt 90 ]; do
    muse_process=$(fm_backend_herdr_pane_process_state "$SESSION" "$MUSE_PANE")
    if [ "$muse_process" = agent ]; then
      muse_state=$(fm_backend_herdr_composer_state "$MUSE_TARGET")
      [ "$muse_state" = empty ] && { muse_idle=1; break; }
    fi
    i=$((i + 1))
    sleep 1
  done
  [ "$muse_idle" = 1 ] \
    || fail "Muse Code ($MUSE_VERSION) on $HERDR_VER never reached a live agent process with a shared empty composer in the lab pane (last process state '$muse_process', last composer state '$muse_state')"

  MUSE_TOKEN="FMHERDRMUSE$$_$RANDOM"
  muse_verdict=$(fm_backend_herdr_send_text_submit "$MUSE_TARGET" "Reply with exactly $MUSE_TOKEN and nothing else." 3 0.4 0.4) \
    || fail "send_text_submit failed to run against Muse Code ($MUSE_VERSION) on $HERDR_VER"
  CHECKED=$((CHECKED + 1))
  [ "$muse_verdict" = empty ] \
    || fail "Muse Code ($MUSE_VERSION) on $HERDR_VER: a landed steer must confirm empty, got '$muse_verdict'"

  # Same two-occurrence rule as the Claude leg: the token must appear in the
  # submitted prompt and again in Muse's reply, so a merely cleared composer
  # cannot pass for a delivered instruction.
  muse_landed=0
  i=0
  while [ "$i" -lt 90 ]; do
    muse_screen=$(lab pane read "$MUSE_PANE" --source recent --lines 200 2>/dev/null || true)
    muse_occurrences=$(printf '%s\n' "$muse_screen" | grep -F -c "$MUSE_TOKEN" || true)
    if [ "$muse_occurrences" -ge 2 ]; then
      muse_landed=1
      break
    fi
    i=$((i + 1))
    sleep 1
  done
  [ "$muse_landed" = 1 ] \
    || fail "Muse Code ($MUSE_VERSION) on $HERDR_VER: submit reported '$muse_verdict' but the expected reply never rendered"
  pass "live Herdr submit confirm: Muse Code ($MUSE_VERSION) on $HERDR_VER reports empty and renders the requested reply in isolated session $SESSION"
fi

[ "$CHECKED" -gt 0 ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 checked no harness"
