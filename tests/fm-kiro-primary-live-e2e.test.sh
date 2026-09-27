#!/usr/bin/env bash
# Opt-in real Kiro V3 primary continuity test.
#
# Builds a plain Firstmate-shaped clone from the current working files, launches
# bin/fm-kiro-primary.sh in a private tmux server, waits for the native
# SessionStart hook to run the digest and publish state/.primary-endpoint, then
# publishes one actionable row through the real watcher wake function. The
# background wake must type the constant doorbell, UserPromptSubmit must attach
# the real wake drain, and the model must run its WAKE_ACK_REQUIRED command.
# This submits one small prompt and is opt-in.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_KIRO_PRIMARY_LIVE_E2E tmux kiro-cli git tar

REAL_TMUX=$(command -v tmux) || fail "tmux not found"
KIRO_BIN=$(command -v kiro-cli) || fail "kiro-cli not found"
case "$("$KIRO_BIN" --version 2>/dev/null)" in
  'kiro-cli 2.22.1') ;;
  *) fail "Kiro primary proof requires the recorded 2.22.1 surface" ;;
esac

LAB=$(fm_test_tmproot fm-kiro-primary-live)
PRIMARY="$LAB/firstmate"
mkdir -p "$PRIMARY"
# Read the current working files, not HEAD, so this guard can verify a branch
# before commit. New files are copied explicitly because git ls-files does not
# list them yet.
git -C "$ROOT" ls-files -z | tar -C "$ROOT" --null -T - -cf - | tar -C "$PRIMARY" -xf -
for path in \
  bin/fm-kiro-lib.sh \
  bin/fm-kiro-primary.sh \
  bin/fm-primary-endpoint-lib.sh \
  .kiro/agents/firstmate-kiro.json \
  .kiro/hooks/fm-firstmate.json; do
  mkdir -p "$PRIMARY/${path%/*}"
  cp "$ROOT/$path" "$PRIMARY/$path"
done
chmod +x "$PRIMARY/bin/fm-kiro-primary.sh" "$PRIMARY/bin/fm-primary-endpoint-lib.sh" \
  "$PRIMARY/bin/fm-kiro-turnend-hook.sh"
rm -rf "$PRIMARY/.git"
git -C "$PRIMARY" init -q
git -C "$PRIMARY" symbolic-ref HEAD refs/heads/main
mkdir -p "$PRIMARY/data" "$PRIMARY/state" "$PRIMARY/config" "$PRIMARY/projects"

SOCK="$LAB/tmux.sock"
SESSION=kiro-primary-live
LOGIN_HOME=${FM_KIRO_LIVE_LOGIN_HOME:-$HOME}
cleanup() {
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null || true
}
trap 'cleanup' EXIT

env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" new-session -d -s "$SESSION" -x 200 -y 55 -c "$PRIMARY" -- \
  env HOME="$LOGIN_HOME" FM_HOME="$PRIMARY" FM_ROOT_OVERRIDE="$PRIMARY" \
  FM_KIRO_HOOK_PROBE_FILE="$PRIMARY/state/.kiro-hook-probe" \
  "$PRIMARY/bin/fm-kiro-primary.sh" ${FM_KIRO_LIVE_MODEL:+--model "$FM_KIRO_LIVE_MODEL"}

TARGET="$SESSION"
# Kiro V3 loads project hooks at session creation but activates SessionStart
# lazily with the first prompt. Reach the initial composer, submit one small
# first turn, then require the run-tier startup effects before proceeding.
i=0
while [ "$i" -lt "${FM_KIRO_PRIMARY_READY_TIMEOUT:-180}" ]; do
  screen=$(env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" capture-pane -p -S -200 -t "$TARGET" 2>/dev/null || true)
  printf '%s\n' "$screen" | grep -Fq 'ask a question or describe a task' && break
  sleep 1
  i=$((i + 1))
done
printf '%s\n' "$screen" | grep -Fq 'ask a question or describe a task'   || { printf '%s\n' "$screen" >&2; fail "real V3 primary never reached its initial composer"; }
FIRST_PROMPT='Follow all SessionStart hook context, then reply with exactly PRIMARYREADY.'
env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" set-buffer -- "$FIRST_PROMPT"
env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" paste-buffer -d -t "$TARGET"
env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" send-keys -t "$TARGET" Enter

i=0
while [ "$i" -lt "${FM_KIRO_PRIMARY_READY_TIMEOUT:-180}" ]; do
  screen=$(env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" capture-pane -p -S -240 -t "$TARGET" 2>/dev/null || true)
  if [ -f "$PRIMARY/state/.primary-endpoint" ]      && printf '%s\n' "$screen" | grep -Fq 'PRIMARYREADY'      && printf '%s\n' "$screen" | grep -Fq 'ask a question or describe a task'; then
    break
  fi
  sleep 1
  i=$((i + 1))
done
if [ ! -f "$PRIMARY/state/.primary-endpoint" ]; then
  printf '%s\n' "$screen" >&2
  printf '# primary state files:\n' >&2
  find "$PRIMARY/state" -maxdepth 2 -type f -printf '%s %p\n' -exec sh -c 'case "$1" in *.lock|*.jsonl) ;; *) sed -n "1,40p" "$1" ;; esac' _ {} \; >&2 2>/dev/null || true
  printf '# pre-logic hook probe:\n' >&2
  cat "$PRIMARY/state/.kiro-hook-probe" >&2 2>/dev/null || printf '# probe absent\n' >&2
  printf '# declared project hooks:\n' >&2
  cat "$PRIMARY/.kiro/hooks/fm-firstmate.json" >&2 2>/dev/null || true
  printf '# Kiro session endpoint diagnostics:\n' >&2
  grep -R "KIRO_PRIMARY_ENDPOINT" "$PRIMARY/state/.kiro-primary-home" >&2 2>/dev/null || true
  cat "$PRIMARY/state/.kiro-primary-home/chat.log" >&2 2>/dev/null || true
  fail "real V3 first prompt did not publish the primary endpoint"
fi
printf '%s\n' "$screen" | grep -Fq 'PRIMARYREADY'   || { printf '%s\n' "$screen" >&2; fail "first turn did not receive SessionStart context"; }
printf '%s\n' "$screen" | grep -Fq 'ask a question or describe a task'   || { printf '%s\n' "$screen" >&2; fail "real V3 primary did not return to idle after startup"; }
grep -q 'harness=kiro-cli' "$PRIMARY/state/.primary-endpoint"   || fail "primary endpoint record is not Kiro-scoped"
assert_present "$PRIMARY/state/.session-start-complete"   "native SessionStart did not complete the startup owner"
assert_present "$PRIMARY/state/.kiro-hook-probe"   "loaded SessionStart hook left no pre-logic physical mark"
pass "live primary: first-prompt SessionStart ran and published an idle Kiro endpoint"

SOCKET_PATH=$(env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" display-message -p '#{socket_path}')
WAKE_REASON='check: Kiro structural primary doorbell live proof; observe this context and acknowledge its durable row; no other action is required'
out=$(env -u TMUX_PANE HOME="$LOGIN_HOME" FM_HOME="$PRIMARY" FM_ROOT_OVERRIDE="$PRIMARY" \
  FM_STATE_OVERRIDE="$PRIMARY/state" TMUX="$SOCKET_PATH,$$,0" \
  bash -c ". \"\$1/bin/fm-push-transition-lib.sh\"; fm_wake_append check kiro-primary-live \"\$2\"; wake \"\$2\"" \
  _ "$PRIMARY" "$WAKE_REASON") || fail "real watcher wake publication failed: $out"
assert_contains "$out" "$WAKE_REASON" "watcher wake did not emit its reason"

# The queue must exist before delivery, then disappear only after the Kiro turn
# handles the hook-attached drain and runs its printed acknowledgement.
i=0; doorbell_seen=0
while [ "$i" -lt "${FM_KIRO_PRIMARY_WAKE_TIMEOUT:-180}" ]; do
  screen=$(env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" capture-pane -p -S -300 -t "$TARGET" 2>/dev/null || true)
  case "$screen" in *'Firstmate wake waiting:'*) doorbell_seen=1 ;; esac
  if [ "$doorbell_seen" -eq 1 ] && [ ! -s "$PRIMARY/state/.wake-queue" ]; then break; fi
  sleep 1
  i=$((i + 1))
done
[ "$doorbell_seen" -eq 1 ] \
  || { printf '%s\n' "$screen" >&2; fail "background watcher wake never rang the primary"; }
[ ! -s "$PRIMARY/state/.wake-queue" ] \
  || { printf '%s\n' "$screen" >&2; fail "Kiro primary did not acknowledge the hook-attached wake context"; }
# Hook-attached context is not rendered in the transcript, so the delivered
# payload is proven either by the model quoting it or by the model running the
# drain's exact acknowledgement command, whose generation token exists only in
# the drained context; the emptied queue above confirms that command landed.
case "$screen" in
  *'Kiro structural primary doorbell live proof'*|*'fm-wake-drain.sh'*' --ack-through '*) ;;
  *) printf '%s\n' "$screen" >&2; fail "the model transcript shows neither the durable wake payload nor the drain's acknowledgement command" ;;
esac
pass "live primary: watcher doorbell started a turn whose hook context was handled and acknowledged"

trap - EXIT
cleanup
printf '%s\n' 'ok - Kiro V3 primary structural continuity passed'
