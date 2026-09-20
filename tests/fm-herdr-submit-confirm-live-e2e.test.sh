#!/usr/bin/env bash
# Live Herdr submit-confirmation guard (live-harness-optin family).
#
# Herdr's native agent_status can stay idle for a whole landed Claude turn, and
# a busy-queued Enter can keep proven pending text visible. A stub cannot prove
# either signal. This guard launches real Claude Code in an isolated Herdr lab
# and requires fm_backend_herdr_send_text_submit to report empty for a landed
# idle steer. A second leg proves the Muse native-idle route the same way: a
# Muse pane registers a native idle agent that flips to working for a landed
# turn, while its idle composer reads unknown, so the composer fallback could
# never confirm the delivery. It fails naming the harness and version rather
# than degrading quietly.
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

fm_live_gate opt-in FM_HERDR_SUBMIT_CONFIRM_LIVE herdr jq claude

MUSE_AVAILABLE=0
if command -v muse >/dev/null 2>&1; then MUSE_AVAILABLE=1; fi
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

# --- Muse leg: the native-idle route --------------------------------------
# A Muse pane registers a native `muse` agent after a few seconds of delayed
# registration, reads idle at rest, and flips to working for a landed turn.
# Its idle composer reads unknown (a lone separator rule below the
# placeholder row trips the shared classifier's pi-separator staleness
# rule), so only the native busy transition can confirm the delivery. The
# echo provider spends no model tokens; the reply still proves the turn
# completed. No visual spinner text is asserted anywhere below.
if [ "$MUSE_AVAILABLE" = 1 ]; then
  MUSE_WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-submitlive-muse --no-focus) \
    || fail "could not create the isolated Muse submit-confirm workspace"
  MUSE_PANE=$(printf '%s' "$MUSE_WS_JSON" | jq -er '.result.root_pane.pane_id') \
    || fail "Muse workspace create did not return a pane id"
  MUSE_TARGET="$SESSION:$MUSE_PANE"
  MUSE_VERSION=$(PATH="$ORIGINAL_PATH" muse --version 2>/dev/null | head -1 || printf 'version-unknown')

  lab pane run "$MUSE_PANE" "muse --provider echo --yolo" >/dev/null \
    || fail "could not launch Muse ($MUSE_VERSION) in the isolated Herdr pane"

  muse_idle=0
  i=0
  while [ "$i" -lt 45 ]; do
    muse_agent=$(lab agent get "$MUSE_PANE" 2>/dev/null | jq -r '.result.agent.agent // empty')
    muse_st=$(lab agent get "$MUSE_PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
    case "$muse_st" in
      idle|done) [ "$muse_agent" = muse ] && { muse_idle=1; break; } ;;
    esac
    i=$((i + 1))
    sleep 1
  done
  [ "$muse_idle" = 1 ] || fail "Muse ($MUSE_VERSION) on $HERDR_VER never registered a native idle muse agent in the lab pane"

  MUSE_TRACE="$TMP_ROOT/muse-submit.trace"
  : > "$MUSE_TRACE"
  eval "$(declare -f fm_backend_herdr_wait_for_working | sed '1s/fm_backend_herdr_wait_for_working/fm_live_original_wait_for_working/')"
  eval "$(declare -f fm_backend_herdr_composer_state | sed '1s/fm_backend_herdr_composer_state/fm_live_original_composer_state/')"
  fm_backend_herdr_wait_for_working() {
    local result rc
    result=$(fm_live_original_wait_for_working "$@")
    rc=$?
    printf 'native-wait %s %s\n' "$rc" "$result" >> "$MUSE_TRACE"
    printf '%s' "$result"
    return "$rc"
  }
  fm_backend_herdr_composer_state() {
    printf 'composer-fallback\n' >> "$MUSE_TRACE"
    fm_live_original_composer_state "$@"
  }

  MUSE_TOKEN="FMMUSEPONG$$_$RANDOM"
  muse_verdict=$(fm_backend_herdr_send_text_submit "$MUSE_TARGET" "Reply with exactly $MUSE_TOKEN and nothing else." 3 0.4 0.4) \
    || fail "send_text_submit failed to run against Muse ($MUSE_VERSION) on $HERDR_VER"
  CHECKED=$((CHECKED + 1))
  [ "$muse_verdict" = empty ] \
    || fail "Muse ($MUSE_VERSION) on $HERDR_VER: a landed idle steer must confirm empty, got '$muse_verdict'"

  [ "$(cat "$MUSE_TRACE")" = 'native-wait 0 busy' ] \
    || fail "Muse ($MUSE_VERSION) on $HERDR_VER: submit must confirm native busy without composer fallback; trace: $(cat "$MUSE_TRACE")"

  # Confirm the instruction reached Muse exactly once, not merely that the
  # composer cleared. The flattened token count is the exactly-once signal:
  # one submitted prompt plus one echo reply. The reply marker is matched on
  # the flattened screen so a wrapped reply row still counts; no single
  # vendor string is load-bearing and no spinner text is asserted.
  muse_landed=0
  i=0
  muse_screen=''
  while [ "$i" -lt 45 ]; do
    muse_screen=$(lab pane read "$MUSE_PANE" --source recent --lines 200 2>/dev/null || true)
    muse_flat=$(printf '%s' "$muse_screen" | tr '\n' ' ')
    muse_occurrences=$(printf '%s' "$muse_flat" | grep -F -o "$MUSE_TOKEN" | wc -l | tr -d ' ')
    muse_replies=$(printf '%s' "$muse_flat" | grep -F -c "echo:" || true)
    if [ "$muse_occurrences" = 2 ] && [ "$muse_replies" -ge 1 ]; then
      muse_landed=1
      break
    fi
    i=$((i + 1))
    sleep 1
  done
  if [ "$muse_landed" != 1 ]; then
    printf '# Muse pane tail at failure:\n' >&2
    printf '%s\n' "$muse_screen" | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
    fail "Muse ($MUSE_VERSION) on $HERDR_VER: submit reported '$muse_verdict' but one prompt plus one echo reply never both rendered (occurrences: ${muse_occurrences:-0})"
  fi
  pass "live Herdr submit confirm: Muse ($MUSE_VERSION) on $HERDR_VER reports empty and renders one submitted prompt plus its reply in isolated session $SESSION"
else
  printf '# harness absent, not verified here: muse (native-idle leg not exercised)\n'
fi

[ "$CHECKED" -gt 0 ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 checked no harness"
