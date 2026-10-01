#!/usr/bin/env bash
# Live Herdr submit-confirmation guard (live-harness-optin family).
#
# Herdr's native agent_status can stay idle for a whole landed Claude turn, and
# a busy-queued Enter can keep proven pending text visible. A stub cannot prove
# either signal. This guard launches real Claude Code in an isolated Herdr lab
# and requires fm_backend_herdr_send_text_submit to report empty for a landed
# idle steer. It then requires the same submit path to prove and submit a
# typed /exit slash command behind the command popup Claude renders below the
# composer (the fm-control exit breakage on 2.1.283) and verifies the agent
# actually exited. It fails naming the harness and version rather than
# degrading quietly.
#
# Run explicitly with FM_HERDR_SUBMIT_CONFIRM_LIVE=1 after a Herdr or Claude
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Herdr submit confirmation" entry.
# FM_HERDR_EXIT_CONFIRM_ONLY=1 selects a token-free control guard instead:
# direct Bash background work exercises submitted and already-open exit modals
# through real fm-control. It never approves trust or changes permission mode.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

if [ "${FM_HERDR_EXIT_CONFIRM_ONLY:-0}" = 1 ]; then
  fm_live_gate default-on FM_HERDR_SUBMIT_CONFIRM_LIVE herdr jq claude
else
  fm_live_gate opt-in FM_HERDR_SUBMIT_CONFIRM_LIVE herdr jq claude
fi

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
if [ "${FM_HERDR_EXIT_CONFIRM_ONLY:-0}" = 1 ]; then
  "$LAB_HELPER" viewer start "$SESSION" || fail "could not attach owned lab viewer for styled composer proof"
fi
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

CLAUDE_LAUNCH="claude --settings '{\"feedbackDrafts\":\"off\"}'"
if [ "${FM_HERDR_EXIT_CONFIRM_ONLY:-0}" != 1 ]; then
  CLAUDE_LAUNCH="CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'"
fi
lab pane run "$PANE" "$CLAUDE_LAUNCH" >/dev/null \
  || fail "could not launch Claude Code ($VERSION) in the isolated Herdr pane"

idle=0
trusted=0
i=0
while [ "$i" -lt 60 ]; do
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  case "$screen" in
    *'bypass permissions on'*|*'shift+tab to cycle'*)
      # The composer footer means Claude is past any folder-trust prompt. Herdr
      # can report the agent idle while that prompt is still up, so the wait
      # keys off the rendered composer rather than the native status alone.
      st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
      case "$st" in idle|done) idle=1; break ;; esac
      ;;
    *'Yes, I trust this folder'*)
      # A fresh checkout path stops on Claude's folder-trust prompt, which the
      # pre-send proof would read as a non-empty composer. Accept it once and
      # keep waiting for a real idle composer; the accepted dialog stays in the
      # viewport. The prompt preselects "No, exit", so move to "Yes" before
      # confirming; a bare Enter quits Claude.
      [ "${FM_HERDR_EXIT_CONFIRM_ONLY:-0}" != 1 ] \
        || fail "Claude Code ($VERSION): workspace trust is not granted; token-free guard refuses to approve it"
      if [ "$trusted" = 0 ]; then
        trusted=1
        lab pane send-keys "$PANE" down enter >/dev/null \
          || fail "could not accept Claude's folder-trust prompt"
      fi
      ;;
  esac
  i=$((i + 1))
  sleep 1
done
[ "$idle" = 1 ] || fail "Claude Code ($VERSION) on $HERDR_VER never rendered an idle composer in the lab pane"

# Token-free lifecycle mode uses Claude's direct Bash composer, never a model
# prompt, and never changes approval or trust settings. It exercises both a
# newly submitted /exit and a modal left open by a prior attempt.
if [ "${FM_HERDR_EXIT_CONFIRM_ONLY:-0}" = 1 ]; then
  LAB_HOME="$TMP_ROOT/control-home"
  mkdir -p "$LAB_HOME/state" "$LAB_HOME/data/labexit"
  {
    printf 'window=%s\nendpoint_task_id=labexit\nworktree=%s\nproject=%s\n' "$TARGET" "$ROOT" "$ROOT"
    printf 'harness=claude\nkind=ship\nmode=local-only\nyolo=off\nbackend=herdr\n'
    printf 'herdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' \
      "$SESSION" "$(printf '%s' "$WS_JSON" | jq -r '.result.workspace.workspace_id')" \
      "$(printf '%s' "$WS_JSON" | jq -r '.result.tab.tab_id')" "$PANE"
  } > "$LAB_HOME/state/labexit.meta"
  for scenario in submitted existing; do
    if [ "$scenario" = existing ]; then
      lab pane run "$PANE" "$CLAUDE_LAUNCH" >/dev/null || fail "could not restart Claude in same lab pane"
    fi
    # The fresh lab has no user draft. Startup placeholder styling can be
    # absent on Herdr, so don't use a delivery guard to block the fixture's
    # direct Bash setup. The production exit still proves an empty composer.
    if [ "$scenario" = existing ]; then
      ready=0
      for ((i=0; i<60; i++)); do
        screen=$(lab pane read "$PANE" --source visible)
        case "$screen" in *'shift+tab to cycle'*) ready=1; break ;; esac
        sleep 0.5
      done
      [ "$ready" = 1 ] || fail "Claude Code ($VERSION): restarted lab did not render its composer"
    fi
    lab pane run "$PANE" '!sleep 90' >/dev/null || fail "could not start direct Bash work"
    running=0
    for ((i=0; i<30; i++)); do
      screen=$(lab pane read "$PANE" --source visible)
      case "$screen" in *'ctrl+b to run in background'*) running=1; break ;; esac
      sleep 0.2
    done
    [ "$running" = 1 ] || fail "Claude Code ($VERSION): direct Bash task never rendered"
    lab pane send-keys "$PANE" ctrl+b >/dev/null || fail "could not background direct Bash task"
    ready=0
    for ((i=0; i<30; i++)); do
      if [ "$(fm_backend_herdr_composer_state "$TARGET")" = empty ]; then ready=1; break; fi
      sleep 0.2
    done
    [ "$ready" = 1 ] || fail "Claude Code ($VERSION): background work did not leave an empty composer"
    if [ "$scenario" = existing ]; then
      # Unlike pane run's immediate Enter, use the existing payload proof
      # and settle budget so the slash popup can finish rendering first.
      verdict=$(fm_backend_herdr_send_text_submit "$TARGET" /exit 1 0.5 1.2)
      [ "$verdict" != send-failed ] || fail "could not prove and submit prior exit command"
      supported=0
      # shellcheck source=bin/fm-control-lib.sh
      . "$ROOT/bin/fm-control-lib.sh"
      for ((i=0; i<30; i++)); do
        screen=$(lab pane read "$PANE" --source visible)
        if [ "$(fm_control_exit_confirmation claude "$screen")" = stop ]; then supported=1; break; fi
        sleep 0.2
      done
      [ "$supported" = 1 ] || fail "Claude Code ($VERSION): expected exact stop dialog never rendered; viewport: $screen"
    fi
    out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LAB_HOME" FM_CONTROL_EXIT_WAIT=10 "$ROOT/bin/fm-control.sh" labexit exit 2>&1) \
      || fail "Claude Code ($VERSION) on $HERDR_VER: $scenario control exit failed: $out"
    [ "$(fm_backend_herdr_agent_state "$TARGET")" = dead ] \
      || fail "Claude Code ($VERSION): $scenario exit did not prove agent gone"
    [ "$(fm_backend_herdr_current_path "$TARGET")" = "$ROOT" ] \
      || fail "$scenario exit changed the worktree"
    pass "live Claude exit confirmation: $scenario /exit stops tasks and proves agent gone on the same endpoint and worktree ($VERSION; $HERDR_VER)"
  done
  exit 0
fi

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

# Away-mode digests start with U+2063, which Claude's composer read-back drops.
# The pre-Enter proof must still accept the rest of the payload.
# shellcheck source=bin/fm-operational-input.sh
. "$ROOT/bin/fm-operational-input.sh"
i=0
while [ "$i" -lt 45 ]; do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in idle|done) break ;; esac
  i=$((i + 1))
  sleep 1
done
OP_TOKEN="FMHERDROPPONG$$_$RANDOM"
op_text=
fm_operational_input_encode away-supervisor "Reply with exactly $OP_TOKEN and nothing else." op_text \
  || fail "could not encode an away-supervisor payload"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$op_text" 3 0.4 0.4) \
  || fail "send_text_submit failed to run an operational payload against Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a landed U+2063 operational payload must confirm empty, got '$verdict'"
landed=0
i=0
while [ "$i" -lt 45 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  occurrences=$(printf '%s\n' "$screen" | grep -F -c "$OP_TOKEN" || true)
  if [ "$occurrences" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: operational submit reported '$verdict' but the expected reply never rendered"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER submits a U+2063 away-supervisor payload whose read-back drops the mark"

# The fm-control exit regression: a typed slash command (/exit) makes Claude
# Code 2.1.283 render its command popup between the composer and the pane
# bottom, which pushed the composer above the old bounded proof read - the
# typed command was judged unsent, cleared, and never submitted. The viewport
# capture must prove the typed /exit and submit it; Claude must actually
# exit. This scenario runs last because it ends the lab's Claude process.
i=0
while [ "$i" -lt 45 ]; do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in idle|done) break ;; esac
  i=$((i + 1))
  sleep 1
done
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" '/exit' 3 0.4 1.2) \
  || fail "send_text_submit failed to run the /exit submission against Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" != send-failed ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a typed /exit behind its command popup was judged unsent and cleared instead of submitted"
exited=0
i=0
while [ "$i" -lt 30 ]; do
  if ! lab agent get "$PANE" >/dev/null 2>&1; then exited=1; break; fi
  i=$((i + 1))
  sleep 1
done
[ "$exited" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the /exit submission reported '$verdict' but the agent never exited"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER proves and submits a typed /exit behind its command popup"

[ "$CHECKED" -gt 0 ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 checked no harness"
