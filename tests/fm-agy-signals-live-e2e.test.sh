#!/usr/bin/env bash
# Live drift guard for the Antigravity CLI adapter's vendor-controlled surface:
# process name, trust dialog, rendered busy/interrupt/composer behavior and guarded exit/relaunch.
# Opt-in because it submits real prompts (no echo provider exists for agy).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_AGY_SIGNALS_LIVE agy herdr jq

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGY_BIN=$(command -v agy 2>/dev/null || true)
LAB=
LAB_PROVISIONED=0
BASE_PATH=$PATH
LAB_HELPER="${FM_AGY_HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}"
LAB_HOME_HELPER="$ROOT/bin/fm-lab-home.sh"
SESSION=$("$LAB_HELPER" name agy-signals)
VERSION=$(agy --version 2>/dev/null | head -1)

# LAB_PROVISIONED is set before provisioning starts, so a provision that
# fails after creating its fleet-state tripwire is still torn down. A teardown
# failure is reported but does not strand the local lab directory.
cleanup() {
  local status=0
  if [ "$LAB_PROVISIONED" = 1 ]; then
    PATH=$BASE_PATH "$LAB_HELPER" teardown "$SESSION" || status=1
    LAB_PROVISIONED=0
  fi
  if [ -n "$LAB" ]; then
    if [ -f "$LAB/fm-home/.fm-lab-home" ]; then
      "$LAB_HOME_HELPER" teardown "$LAB/fm-home" || return 1
    fi
    chmod -R u+w "$LAB" || return 1
    rm -rf -- "$LAB"
  fi
  return "$status"
}
fail() { printf 'not ok - agy (%s): %s\n' "$VERSION" "$1" >&2; exit 1; }
pass() { printf 'ok - agy (%s): %s\n' "$VERSION" "$1"; }

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-signals.XXXXXX") || fail "could not create the isolated agy lab"
trap 'cleanup || exit 1' EXIT
FM_HOME=$("$LAB_HOME_HELPER" create "$LAB/fm-home") || fail "could not create a lab home"
export FM_HOME
LAB_PROVISIONED=1
"$LAB_HELPER" provision "$SESSION" || fail "could not provision the guarded Herdr lab"
WORKSPACE=$ROOT
AGY_HOME="$LAB/home"
mkdir -p "$AGY_HOME" "$LAB/shim" || fail "could not create the throwaway agy HOME"
[ -d "$HOME/.gemini" ] || fail "no ~/.gemini to stage for the throwaway agy HOME"
cp -R "$HOME/.gemini" "$AGY_HOME/.gemini" || fail "could not stage the throwaway agy credential copy"

# Route lifecycle subprocesses through the guarded helper, including probes
# without a session flag. Reject any foreign session; the helper owns isolation.
cat > "$LAB/shim/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --session) [ "$2" = "$FM_AGY_LAB_SESSION" ] || exit 1; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
HOME=$FM_AGY_OPERATOR_HOME PATH=$FM_AGY_BASE_PATH exec "$FM_AGY_LAB_HELPER" run "$FM_AGY_LAB_SESSION" "${args[@]}"
SH
chmod +x "$LAB/shim/herdr"
export FM_AGY_OPERATOR_HOME="$HOME"
export FM_AGY_LAB_SESSION="$SESSION" FM_AGY_LAB_HELPER="$LAB_HELPER" FM_AGY_BASE_PATH="$BASE_PATH"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
export PATH="$LAB/shim:$PATH" HERDR_SESSION="$SESSION"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
fm_backend_source herdr || fail "could not load the Herdr adapter"
# Provision and teardown run outside the shim to prevent recursion.
run() { PATH=$BASE_PATH "$LAB_HELPER" run "$SESSION" "$@"; }
created=$(run workspace create --cwd "$WORKSPACE" --label agy-signals) || fail "could not create the lab workspace"
PANE=$(printf '%s' "$created" | jq -r '.result.root_pane.pane_id')
TAB=$(printf '%s' "$created" | jq -r '.result.tab.tab_id')
WS=$(printf '%s' "$created" | jq -r '.result.workspace.workspace_id')
TARGET="$SESSION:$PANE"
capture() { run pane read "$PANE" --source visible --format text; }
send() { run pane send-text "$PANE" "$1" >/dev/null; }
keys() { run pane send-keys "$PANE" "$1" >/dev/null; }
control() {
  HOME="$AGY_HOME" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.2 \
    bash "$ROOT/bin/fm-control.sh" agy-live "$@" 2>&1
}
mkdir -p "$FM_HOME/data/agy-live"
printf '# Task\n## Captain\047s intent\nReply with exactly the sum of 12345 and 67890 and nothing else.\n\n## Firstmate spec\nDo not edit files or invoke tools; answer the arithmetic prompt only.\n' > "$FM_HOME/data/agy-live/brief.md"
common=$(git -C "$ROOT" rev-parse --git-common-dir)
common=$(cd "$ROOT" && cd "$common" && pwd -P) || fail "could not resolve the primary checkout"
[ "$ROOT" != "${common%/.git}" ] || fail "run the lifecycle guard from an isolated git worktree"
{
  printf 'window=%s\nendpoint_task_id=agy-live\nbackend=herdr\nharness=agy\nkind=scout\n' "$TARGET"
  printf 'mode=no-mistakes\nyolo=off\nmodel=gemini-3.8-flash-low\neffort=low\n'
  printf 'worktree=%s\nproject=%s\n' "$ROOT" "${common%/.git}"
  printf 'herdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' "$SESSION" "$WS" "$TAB" "$PANE"
} > "$FM_HOME/state/agy-live.meta"

# The launch prompt asks for a computed answer (12345+67890=80235) so the
# awaited token never appears in the echoed launch line itself, where a plain
# reply token would false-positive on the shell echo (including across terminal
# wrapped rows).
send \
  "HOME=\"$AGY_HOME\" $AGY_BIN --prompt-interactive \"Add 12345 and 67890. Reply with exactly the sum and nothing else\" --model gemini-3.8-flash-low --effort low --dangerously-skip-permissions" \
  || fail "could not type the agy launch line"
keys Enter \
  || fail "could not submit the agy launch line"

# A fresh workspace stops on the folder-trust dialog. Answer the preselected
# safe choice once it renders. The answer appends the workspace to
# trustedWorkspaces in the throwaway HOME's copy of the agy settings store.
screen=
for _ in $(seq 1 150); do
  screen=$(capture)
  case "$screen" in
    *"Do you trust the contents of this project?"*|*80235*|*80,235*) break ;;
  esac
  sleep 0.5
done
case "$screen" in
  *"Do you trust the contents of this project?"*)
    keys Enter \
      || fail "could not answer the agy trust dialog"
    ;;
esac

# The initial turn executes and its reply lands; the busy footer must render
# while it is in flight so the portable matcher has live text to prove.
# Trivial turns were observed taking one to two minutes (cold start plus model
# latency), so these windows are generous; the guard is opt-in.
for _ in $(seq 1 240); do
  screen=$(capture)
  if printf '%s' "$screen" | fm_busy_agy_tail_busy; then break; fi
  case "$screen" in *80235*|*80,235*) break ;; esac
  sleep 1
done
# A short arithmetic turn may finish between captures; the long turn below
# provides the required live busy proof even when this sample misses it.

for _ in $(seq 1 480); do
  screen=$(capture)
  case "$screen" in *80235*|*80,235*) break ;; esac
  sleep 0.5
done
reply=$(capture)
case "$reply" in
  *80235*|*80,235*) pass "the real agy worker processed its launch prompt" ;;
  *) fail "the real agy worker never answered its launch prompt" ;;
esac
# The reply can render while the turn is still finishing: the busy footer stays
# pinned until the idle composer replaces it, so wait for the settled idle row
# before asserting what the settled pane must not match. The wait itself
# refreshes $screen: the reply-wait loop above can legitimately break on a
# frame that still carries the pinned busy footer, and asserting on that stale
# frame would fail every run whose reply lands mid-turn.
idle_settled=
for _ in $(seq 1 120); do
  screen=$(capture)
  case "$screen" in *"? for shortcuts"*) idle_settled=1; break ;; esac
  sleep 0.5
done
[ -n "$idle_settled" ] || fail "the agy composer never settled to its idle footer after the reply"
# Scope to the visible tail the same way the owners do: mid-turn busy rows stay
# in scrollback after the turn settles and must not count as still busy.
printf '%s' "$screen" | grep -v '^[[:space:]]*$' | tail -12 | fm_busy_lines_match agy \
  && fail "harness=agy matched its own idle footer as busy" || true
printf '%s' "$screen" | fm_busy_agy_tail_busy \
  && fail "the settled agy footer still matches the busy signature" || true

# The dialog can outlive the turn it gated, so a still-rendered dialog must be
# dismissed before steering anything: typed text would land in it instead of
# the composer.
if case "$(capture)" in *"Do you trust the contents of this project?"*) true ;; *) false ;; esac; then
  keys Enter \
    || fail "could not dismiss the residual agy trust dialog"
  idle=
  for _ in $(seq 1 120); do
    case "$(capture)" in *"? for shortcuts"*) idle=1; break ;; esac
    sleep 0.5
  done
  [ -n "$idle" ] || fail "the agy composer never went idle after the trust answer"
fi

# Interrupt a genuinely long turn: poll until busy is observed, then send
# exactly one Escape and wait only for the Interrupted row it prints; a busy
# footer that merely disappears is not cancellation and no further Escape is
# sent, so a turn that survives one Escape fails this guard.
send \
  "Write a 1500-word essay on the history of glass" \
  || fail "could not type the long agy prompt"
keys Enter \
  || fail "could not submit the long agy prompt"
for _ in $(seq 1 100); do
  screen=$(capture)
  printf '%s' "$screen" | fm_busy_agy_tail_busy && break
  sleep 0.5
done
printf '%s' "$screen" | fm_busy_agy_tail_busy \
  || fail "the long agy turn never showed its busy footer"
pass "the real agy busy footer matches fm_busy_agy_tail_busy in flight"
keys Escape \
  || fail "could not send Escape to the real agy turn"
cancelled=
for _ in $(seq 1 120); do
  screen=$(capture)
  case "$screen" in *Interrupted*) cancelled=1; break ;; esac
  sleep 0.5
done
[ -n "$cancelled" ] || fail "a single Escape never cancelled the real agy turn"
pass "a single Escape cancels the real agy turn"

# A draft must refuse both verbs without modifying it or stopping the agent.
send "AGY_UNSUBMITTED_DRAFT" || fail "could not type the guarded draft"
for verb in exit relaunch; do
  rc=0
  if [ "$verb" = relaunch ]; then
    out=$(control relaunch --note "Keep the isolated copy intact") || rc=$?
  else
    out=$(control exit) || rc=$?
  fi
  [ "$rc" -ne 0 ] || fail "$verb accepted a nonempty composer"
  case "$out" in *"composer visibly holds pending text"*) ;; *) fail "$verb did not refuse on composer text: $out" ;; esac
  case "$(capture)" in *AGY_UNSUBMITTED_DRAFT*) ;; *) fail "$verb changed the draft" ;; esac
  [ "$(fm_backend_agent_state herdr "$TARGET")" = alive ] || fail "$verb stopped the draft-holding agent"
done
pass "exit and relaunch refuse a typed draft and preserve the agent"
keys ctrl+u || fail "could not clear the test draft"
for _ in $(seq 1 120); do
  [ "$(FM_COMPOSER_LIFECYCLE=1 fm_backend_composer_state herdr "$TARGET")" = empty ] && break
  sleep 0.5
done
[ "$(FM_COMPOSER_LIFECYCLE=1 fm_backend_composer_state herdr "$TARGET")" = empty ] || fail "idle composer did not classify empty"
[ "$(fm_backend_composer_state herdr "$TARGET")" = unknown ] || fail "idle composer proved empty outside a lifecycle read"
pass "the real idle composer classifies empty"
identity=$(fm_backend_herdr_composer_identity "$TARGET") || fail "native idle identity is unavailable"
case "$identity" in $'agy\tidle'|$'agy\tdone') ;; *) fail "native identity is not agy idle/done" ;; esac
screen=$(run pane read "$PANE" --source visible --format ansi) || fail "could not capture the idle composer"
[ "$(FM_COMPOSER_LIFECYCLE=1 fm_composer_classify_screen 'styled=1' "$screen")" = empty ] || fail "idle footer alone did not prove empty"
without_footer=$(printf '%s\n' "$screen" | sed '/? for shortcuts/d')
case "$without_footer" in *'? for shortcuts'*) fail "footer removal was vacuous" ;; esac
[ "$(FM_COMPOSER_LIFECYCLE=1 fm_composer_classify_screen 'styled=1' "$without_footer")" = unknown ] || fail "signal loss did not remove footer proof"
[ "$(FM_COMPOSER_LIFECYCLE=1 fm_composer_classify_screen $'styled=1\nidentity=1' "$without_footer" '' "$identity")" = empty ] || fail "native idle identity alone did not prove empty"
pass "native idle identity and rendered footer each independently prove the real composer empty"

out=$(control relaunch --note "Reply with exactly the requested sum; preserve the copy") || fail "idle relaunch failed: $out"
case "$out" in relaunched*) ;; *) fail "relaunch did not confirm replacement: $out" ;; esac
for _ in $(seq 1 480); do
  [ "$(FM_COMPOSER_LIFECYCLE=1 fm_backend_composer_state herdr "$TARGET")" = empty ] && break
  sleep 0.5
done
[ "$(FM_COMPOSER_LIFECYCLE=1 fm_backend_composer_state herdr "$TARGET")" = empty ] || fail "replacement never returned to an empty composer"
pass "fm-control relaunch replaces the idle agent in the same endpoint and worktree"
out=$(control exit) || fail "idle exit failed: $out"
case "$out" in stopped*) ;; *) fail "exit did not confirm the stopped agent: $out" ;; esac
[ "$(fm_backend_agent_state herdr "$TARGET")" = dead ] || fail "exit left the agent alive"
run pane get "$PANE" >/dev/null || fail "exit removed the endpoint"
pass "fm-control exit stops the idle agent and preserves the endpoint"
cleanup || fail "guarded lab teardown failed"
trap - EXIT
