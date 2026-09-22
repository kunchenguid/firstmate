#!/usr/bin/env bash
# tests/fm-unblock-doorbell-herdr-live-e2e.test.sh - the live proof of the
# skipped-doorbell recovery (live-harness-optin family).
#
# The 2026-09-20 incident (maker home, Herdr backend, Claude harness): a
# doorbell line sat in a worker's composer with its Enter swallowed, every
# later steer's ring skipped to protect that text, and the only remaining rung
# was a relaunch that risks the worker's conversation and unlanded work.
#
# A unit test cannot demonstrate that bug: the composer shapes, the submit
# confirmation, and the interrupt/submit behavior of a REAL harness are exactly
# what decides whether the recovery works. So this guard drives a real Claude
# Code worker on real Herdr through the complete incident arc and its recovery:
#
#   1. A real doorbell line is typed into the worker's composer WITHOUT
#      submitting it - the exact stuck state the incident left behind.
#   2. A real fm-send steer records durably but its doorbell SKIPS, and the
#      worker receives nothing.
#   3. The control plane's unblock verb submits the stuck doorbell text with a
#      VERIFIED Enter, and the SAME previously-skipped steer lands: the worker
#      reads the inbox records and acknowledges them with the mv.
#
# No relaunch is performed; the agent keeps running throughout.
#
# Run explicitly with FM_UNBLOCK_DOORBELL_LIVE=1 after a Herdr or Claude
# upgrade, and before trusting a refreshed
# docs/verification/runtime-backends.md "Skipped-doorbell recovery" entry.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_UNBLOCK_DOORBELL_LIVE herdr jq claude

[ -x "$LAB_HELPER" ] || fail "FM_UNBLOCK_DOORBELL_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name unblock-doorbell-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-unblock-doorbell-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
ACTED="$TMP_ROOT/acted-marker"
ACTED2="$TMP_ROOT/acted-marker-2"
mkdir -p "$FAKEBIN" "$HOME_DIR/state"

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
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-unblocklive --no-focus) \
  || fail "could not create the isolated unblock-live workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

# Claude Code gates a folder it has never opened behind an interactive
# workspace-trust dialog whose cursor sits on "No, exit", and this guard must
# never answer it - a real spawn does not either; bin/fm-claude-trust.sh
# pre-registers the trust in the store the launched agent reads. A checkout the
# operator has never opened by hand (every no-mistakes gate worktree, for one)
# therefore needs that registration in an isolated store, so forward an
# explicitly set CLAUDE_CONFIG_DIR onto the launch exactly as bin/fm-spawn.sh
# forwards it. Unset, the launch is byte-for-byte what it always was.
CLAUDE_ENV=
[ -n "${CLAUDE_CONFIG_DIR:-}" ] && CLAUDE_ENV="CLAUDE_CONFIG_DIR='$CLAUDE_CONFIG_DIR' "

lab pane run "$PANE" "${CLAUDE_ENV}CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null \
  || fail "could not launch Claude Code ($VERSION) in the isolated Herdr pane"

idle=0
i=0
while [ "$i" -lt 60 ]; do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in idle|done|blocked) idle=1; break ;; esac
  i=$((i + 1))
  sleep 1
done
[ "$idle" = 1 ] || fail "Claude Code ($VERSION) on $HERDR_VER never registered an idle agent in the lab pane"

# Wait for a steerable composer; dismiss one non-trust startup modal exactly as
# the doorbell live guard does (never Enter, which could accept an upgrade).
dismissed=0
i=0
while [ "$i" -lt 60 ]; do
  st=$(fm_backend_herdr_composer_state "$TARGET")
  [ "$st" = empty ] && break
  if [ "$dismissed" = 0 ] && [ "$i" -ge 20 ]; then
    screen=$(fm_backend_herdr_capture "$TARGET" 40 2>/dev/null || true)
    if ! printf '%s\n' "$screen" | grep -qi 'trust'; then
      lab pane send-keys "$PANE" escape >/dev/null 2>&1 || true
    fi
    dismissed=1
  fi
  i=$((i + 1))
  sleep 1
done
st=$(fm_backend_herdr_composer_state "$TARGET")
[ "$st" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER never showed an empty composer before the arc (verdict '$st')"

# The task record firstmate will steer: an ordinary ship on this backend.
PANE_JSON=$(lab pane get "$PANE") || fail "could not read the lab pane's identity"
WORKSPACE_ID=$(printf '%s' "$PANE_JSON" | jq -er '.result.pane.workspace_id') \
  || fail "pane get did not report a workspace id"
TAB_ID=$(printf '%s' "$PANE_JSON" | jq -er '.result.pane.tab_id') \
  || fail "pane get did not report a tab id"
TASK=unblock-live
{
  echo "window=$TARGET"
  echo "endpoint_task_id=$TASK"
  echo "worktree=$ROOT"
  echo "project=$ROOT"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE"
} > "$HOME_DIR/state/$TASK.meta"

# 1. The incident state: a real doorbell line typed but never submitted.
REC1=$(fm_task_inbox_write "$HOME_DIR/state" "$TASK" \
  "Firstmate live check: run exactly this shell command now: touch $ACTED - then follow the mv instruction you were given for this message. Reply with one short line.") \
  || fail "could not write the first inbox record"
DOORBELL=$(fm_task_inbox_doorbell_line "$REC1") \
  || fail "could not derive the doorbell line"
fm_backend_herdr_send_literal "$TARGET" "$DOORBELL" \
  || fail "could not type the doorbell line into the live composer"
i=0
while [ "$i" -lt 20 ]; do
  st=$(fm_backend_herdr_composer_state "$TARGET")
  [ "$st" = pending ] && break
  i=$((i + 1))
  sleep 0.5
done
[ "$st" = pending ] \
  || fail "the live composer never read pending after the unsubmitted doorbell (verdict '$st')"

# 2. A steer whose doorbell must skip on the pending text.
SEND_ERR="$TMP_ROOT/send.err"
if ! env FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" \
  "$ROOT/bin/fm-send.sh" "$TASK" \
  "Also run exactly this shell command now: touch $ACTED2 - then follow the mv instruction you were given for this message." \
  >/dev/null 2> "$SEND_ERR"; then
  fail "fm-send should succeed while its doorbell skips: $(cat "$SEND_ERR")"
fi
grep -qF 'doorbell skipped' "$SEND_ERR" \
  || fail "fm-send did not report the skipped doorbell: $(cat "$SEND_ERR")"
REC2="$HOME_DIR/state/$TASK.inbox/002.msg"
[ -f "$REC2" ] || fail "the skipped steer did not leave its durable record"
sleep 5
[ ! -e "$ACTED" ] && [ ! -e "$ACTED2" ] \
  || fail "the worker acted on a steer whose doorbell never landed"
[ -f "$REC1" ] && [ -f "$REC2" ] \
  || fail "the unhandled records did not stay durable while the doorbell skipped"
pass "live arc step 1-2: Claude Code ($VERSION) on $HERDR_VER holds the unsubmitted doorbell, and a later steer skips its ring durably"

# 3. The recovery: submit the stuck doorbell text with a verified Enter; the
#    SAME skipped steer must land and be acknowledged, with no relaunch.
OUT=$(env FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" \
  FM_CONTROL_POLL=0.5 "$ROOT/bin/fm-control.sh" "$TASK" unblock 2>&1) \
  || fail "unblock failed against Claude Code ($VERSION) on $HERDR_VER: $OUT"
# The re-ring types into a pane the submit just made busy, so a real harness
# may land it (rang), leave it in the composer (skipped), or render a screen the
# classifier cannot read either way (unproven); all three are observed outcomes.
# What may never appear is failed or none - the record is unhandled and the
# keystrokes must reach the pane - and the acknowledgement wait below proves the
# steer itself landed either way.
case "$OUT" in
  "unblocked $TASK harness=claude backend=herdr composer=submitted ring=rang"*) : ;;
  "unblocked $TASK harness=claude backend=herdr composer=submitted ring=skipped"*) : ;;
  "unblocked $TASK harness=claude backend=herdr composer=submitted ring=unproven"*) : ;;
  *) fail "unblock should report a verified submit and an observed ring outcome, got: $OUT" ;;
esac
case "$OUT" in
  *"ring=rang"*)
    st=$(fm_backend_herdr_composer_state "$TARGET")
    [ "$st" = empty ] \
      || fail "a ring reported as rang left text in the live composer (verdict '$st')"
    ;;
esac

HANDLED1="$HOME_DIR/state/$TASK.inbox/handled/001.msg"
HANDLED2="$HOME_DIR/state/$TASK.inbox/handled/002.msg"
landed=0
i=0
while [ "$i" -lt 120 ]; do
  [ -f "$HANDLED1" ] && [ -f "$HANDLED2" ] && [ -e "$ACTED" ] && [ -e "$ACTED2" ] && { landed=1; break; }
  i=$((i + 1))
  sleep 1
done
if [ "$landed" != 1 ]; then
  fm_backend_herdr_capture "$TARGET" 60 2>/dev/null | grep '[^[:space:]]' | tail -12 | sed 's/^/#   /' >&2
  fail "the previously skipped steer never landed after the recovery (acted1=$([ -e "$ACTED" ] && echo yes || echo no) acted2=$([ -e "$ACTED2" ] && echo yes || echo no) acked1=$([ -f "$HANDLED1" ] && echo yes || echo no) acked2=$([ -f "$HANDLED2" ] && echo yes || echo no))"
fi
pass "live Herdr unblock recovery: Claude Code ($VERSION) on $HERDR_VER - the stuck doorbell was submitted, the same skipped steer landed, and the worker acknowledged it, with no relaunch"
