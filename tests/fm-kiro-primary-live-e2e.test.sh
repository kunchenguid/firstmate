#!/usr/bin/env bash
# Opt-in real Kiro V3 primary doorbell-owner continuity test.
#
# Builds a plain Firstmate-shaped clone from the current working files and
# registers two condition->action process-to-event sources through the product's
# own bin/fm-procevent-when.sh, so the home needs supervision without any task
# pane. It launches bin/fm-kiro-primary.sh in a private tmux server, submits one
# small first prompt, and waits for the native SessionStart hook to run the
# digest and publish state/.primary-endpoint. The first turn's Stop hook must
# start the one detached doorbell owner (bin/fm-primary-doorbell.sh), which owns
# every watcher cycle; the watcher's reconcile starts both source runners.
#
# After that the test never types again. It opens the first source's gate, and
# later the second's, and proves for each wake that the owner typed the constant
# doorbell into the idle pane, UserPromptSubmit attached the real drain, and the
# model ran its WAKE_ACK_REQUIRED command (the durable queue empties). The pane
# must sit idle for at least 10 s between the two wakes, so the second wake
# arrives with nobody typing. The ledgers then prove continuity: the cycle that
# closed on the first wake started its handling successor before the ring
# (successor=started:<pid>), and no later cycle closed on check:
# rearm-resurface. This submits one small prompt plus two doorbell turns.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_KIRO_PRIMARY_LIVE_E2E tmux kiro-cli git tar

REAL_TMUX=$(command -v tmux) || fail "tmux not found"
KIRO_BIN=$(command -v kiro-cli) || fail "kiro-cli not found"
case "$("$KIRO_BIN" --version 2>/dev/null)" in
  'kiro-cli 2.24.1') ;;
  *) fail "Kiro primary proof requires the recorded 2.24.1 surface" ;;
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
  bin/fm-primary-doorbell.sh \
  bin/fm-primary-endpoint-lib.sh \
  .kiro/agents/firstmate-kiro.json \
  .kiro/hooks/fm-firstmate.json; do
  mkdir -p "$PRIMARY/${path%/*}"
  cp "$ROOT/$path" "$PRIMARY/$path"
done
chmod +x "$PRIMARY/bin/fm-kiro-primary.sh" "$PRIMARY/bin/fm-primary-endpoint-lib.sh" \
  "$PRIMARY/bin/fm-kiro-turnend-hook.sh" "$PRIMARY/bin/fm-primary-doorbell.sh"
rm -rf "$PRIMARY/.git"
git -C "$PRIMARY" init -q
git -C "$PRIMARY" symbolic-ref HEAD refs/heads/main
mkdir -p "$PRIMARY/data" "$PRIMARY/state" "$PRIMARY/config" "$PRIMARY/projects"

SOCK="$LAB/tmux.sock"
SESSION=kiro-primary-live
LOGIN_HOME=${FM_KIRO_LIVE_LOGIN_HOME:-$HOME}
TARGET="$SESSION"
GATE1="$LAB/gate-first"
GATE2="$LAB/gate-second"

lab() {  # run a product command against the lab home only
  env -u TMUX -u TMUX_PANE HOME="$LOGIN_HOME" FM_HOME="$PRIMARY" FM_ROOT_OVERRIDE="$PRIMARY" \
    FM_STATE_OVERRIDE="$PRIMARY/state" "$@"
}
tm() { env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" "$@"; }
pane_history() { tm capture-pane -p -S - -t "$TARGET" 2>/dev/null || true; }
visible() { tm capture-pane -p -t "$TARGET" 2>/dev/null || true; }
doorbells() { pane_history | grep -c 'Firstmate wake waiting:' || true; }

cleanup() {
  lab "$PRIMARY/bin/fm-procevent-when.sh" retire gate-first >/dev/null 2>&1 || true
  lab "$PRIMARY/bin/fm-procevent-when.sh" retire gate-second >/dev/null 2>&1 || true
  tm kill-server 2>/dev/null || true
  owner=$(cat "$PRIMARY/state/.primary-doorbell.lock/pid" 2>/dev/null || true)
  [ -z "$owner" ] || kill "$owner" 2>/dev/null || true
}
trap 'cleanup' EXIT

diagnose() {  # <message>
  pane_history | tail -120 >&2
  printf '# primary state files:\n' >&2
  find "$PRIMARY/state" -maxdepth 2 -type f -printf '%s %p\n' -exec sh -c 'case "$1" in *.lock|*.jsonl) ;; *) sed -n "1,40p" "$1" ;; esac' _ {} \; >&2 2>/dev/null || true
  printf '# pre-logic hook probe:\n' >&2
  cat "$PRIMARY/state/.kiro-hook-probe" >&2 2>/dev/null || printf '# probe absent\n' >&2
  printf '# declared project hooks:\n' >&2
  cat "$PRIMARY/.kiro/hooks/fm-firstmate.json" >&2 2>/dev/null || true
  printf '# Kiro session endpoint diagnostics:\n' >&2
  grep -R "KIRO_PRIMARY_ENDPOINT" "$PRIMARY/state/.kiro-primary-home" >&2 2>/dev/null || true
  tail -60 "$PRIMARY/state/.kiro-primary-home/chat.log" >&2 2>/dev/null || true
  printf '# procevent sources:\n' >&2
  lab "$PRIMARY/bin/fm-procevent.sh" list >&2 2>&1 || true
  fail "$1"
}

# Supervision need without a task pane: two real condition->action watches.
# Each condition is a file test the test opens at a chosen time, so the two
# actionable wakes are separately timed and the test never touches the pane.
for gate in gate-first:"$GATE1" gate-second:"$GATE2"; do
  out=$(lab "$PRIMARY/bin/fm-procevent-when.sh" arm "${gate%%:*}" --interval 2 --stable 1 \
    --deadline 1800 --condition /usr/bin/test -e "${gate#*:}" --action /usr/bin/true 2>&1) \
    || fail "could not register process-event source ${gate%%:*}: $out"
done
[ "$(find "$PRIMARY/state/procevent" -name '*.source' | wc -l)" -eq 2 ] \
  || fail "two registered process-event sources expected before launch"

tm new-session -d -s "$SESSION" -x 200 -y 55 -c "$PRIMARY" -- \
  env HOME="$LOGIN_HOME" FM_HOME="$PRIMARY" FM_ROOT_OVERRIDE="$PRIMARY" \
  FM_KIRO_HOOK_PROBE_FILE="$PRIMARY/state/.kiro-hook-probe" \
  "$PRIMARY/bin/fm-kiro-primary.sh" ${FM_KIRO_LIVE_MODEL:+--model "$FM_KIRO_LIVE_MODEL"}

IDLE='ask a question or describe a task'
# Kiro V3 loads project hooks at session creation but activates SessionStart
# lazily with the first prompt. Reach the initial composer, submit one small
# first turn, then require the run-tier startup effects before proceeding.
i=0
while [ "$i" -lt "${FM_KIRO_PRIMARY_READY_TIMEOUT:-180}" ]; do
  visible | grep -Fq "$IDLE" && break
  sleep 1
  i=$((i + 1))
done
visible | grep -Fq "$IDLE" || diagnose "real V3 primary never reached its initial composer"
FIRST_PROMPT='Follow all SessionStart hook context, then reply with exactly PRIMARYREADY.'
tm set-buffer -- "$FIRST_PROMPT"
tm paste-buffer -d -t "$TARGET"
tm send-keys -t "$TARGET" Enter

i=0
while [ "$i" -lt "${FM_KIRO_PRIMARY_READY_TIMEOUT:-180}" ]; do
  if [ -f "$PRIMARY/state/.primary-endpoint" ] && pane_history | grep -Fq 'PRIMARYREADY' \
    && visible | grep -Fq "$IDLE"; then
    break
  fi
  sleep 1
  i=$((i + 1))
done
[ -f "$PRIMARY/state/.primary-endpoint" ] || diagnose "real V3 first prompt did not publish the primary endpoint"
pane_history | grep -Fq 'PRIMARYREADY' || diagnose "first turn did not receive SessionStart context"
visible | grep -Fq "$IDLE" || diagnose "real V3 primary did not return to idle after startup"
grep -q 'harness=kiro-cli' "$PRIMARY/state/.primary-endpoint" || fail "primary endpoint record is not Kiro-scoped"
assert_present "$PRIMARY/state/.session-start-complete" "native SessionStart did not complete the startup owner"
assert_present "$PRIMARY/state/.kiro-hook-probe" "loaded SessionStart hook left no pre-logic physical mark"
pass "live primary: first-prompt SessionStart ran and published an idle Kiro endpoint"

# The first turn's Stop hook must have started the one doorbell owner.
owner_live() {
  local pid
  pid=$(cat "$PRIMARY/state/.primary-doorbell.lock/pid" 2>/dev/null || true)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}
i=0
while [ "$i" -lt 30 ] && ! owner_live; do sleep 1; i=$((i + 1)); done
owner_live || diagnose "Stop hook left no live doorbell owner"
OWNER_PID=$(cat "$PRIMARY/state/.primary-doorbell.lock/pid")
pass "live primary: Stop hook started a live doorbell owner (pid $OWNER_PID)"

# From here on nothing is typed into the pane. await_wake proves one
# source's wake: a watcher recorded delivering it, a new doorbell appeared, and
# the durable queue emptied again with the pane back at its idle composer.
DELIVERIES="$PRIMARY/state/.watch-deliveries.log"
delivered() {  # <source-id>
  [ -f "$DELIVERIES" ] && awk -F '\t' -v s="$1" 'index($3, s) { found = 1 } END { exit !found }' "$DELIVERIES"
}
await_wake() {  # <baseline-doorbells> <source-id> <label>
  local base=$1 source=$2 label=$3 i=0 seen=0
  while [ "$i" -lt "${FM_KIRO_PRIMARY_WAKE_TIMEOUT:-180}" ]; do
    delivered "$source" && [ "$(doorbells)" -gt "$base" ] && seen=1
    if [ "$seen" -eq 1 ] && [ ! -s "$PRIMARY/state/.wake-queue" ] && visible | grep -Fq "$IDLE"; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  delivered "$source" || diagnose "no watcher delivered the $label source's wake"
  [ "$seen" -eq 1 ] || diagnose "$label wake never rang the primary doorbell"
  diagnose "Kiro primary did not acknowledge the $label wake's hook-attached drain"
}

# The first turn's own supervision handling is model-dependent (a run may, for
# example, answer a recovery ring left by its own startup), so open the first
# gate only once the pane has been quiet for 15 s: idle composer, empty queue,
# and no new doorbell.
quiet=0 i=0 last=$(doorbells)
while [ "$i" -lt "${FM_KIRO_PRIMARY_WAKE_TIMEOUT:-180}" ] && [ "$quiet" -lt 15 ]; do
  now=$(doorbells)
  if [ "$now" -eq "$last" ] && [ ! -s "$PRIMARY/state/.wake-queue" ] && visible | grep -Fq "$IDLE"; then
    quiet=$((quiet + 1))
  else
    quiet=0 last=$now
  fi
  sleep 1
  i=$((i + 1))
done
[ "$quiet" -ge 15 ] || diagnose "primary never settled after its first turn"
BASE=$(doorbells)
touch "$GATE1"
await_wake "$BASE" when-gate-first first
owner_live || diagnose "doorbell owner died after the first wake"
[ "$(cat "$PRIMARY/state/.primary-doorbell.lock/pid")" = "$OWNER_PID" ] \
  || diagnose "doorbell owner changed after the first wake"
pass "live primary: first source wake rang the idle pane and its drain was acknowledged"

# The pane must stay idle, with no new doorbell, for at least 10 s before the
# second gate opens; the second wake then arrives with nobody typing.
AFTER_FIRST=$(doorbells)
idle=0
i=0
while [ "$i" -lt 60 ]; do
  if visible | grep -Fq "$IDLE" && [ "$(doorbells)" -eq "$AFTER_FIRST" ]; then
    idle=$((idle + 1))
  else
    idle=0
  fi
  [ "$(doorbells)" -eq "$AFTER_FIRST" ] || diagnose "an unexpected doorbell rang between the two source wakes"
  [ "$i" -ge 40 ] && [ "$idle" -ge 15 ] && break
  sleep 1
  i=$((i + 1))
done
[ "$idle" -ge 10 ] || diagnose "pane was not idle for 10 s between the two wakes (idle run ${idle}s)"
owner_live || diagnose "no live doorbell owner while the session waited between wakes"
touch "$GATE2"
await_wake "$AFTER_FIRST" when-gate-second second
pass "live primary: second source wake rang after ${idle}s idle with nobody typing and was acknowledged"

# Hook-attached context is not rendered in the transcript, so the delivered
# payload is proven either by the model quoting it or by the model running the
# drain's exact acknowledgement command, whose generation token exists only in
# the drained context; the emptied queue above confirms that command landed.
case "$(pane_history)" in
  *'when-gate-'*|*'fm-wake-drain.sh'*' --ack-through '*) ;;
  *) diagnose "the model transcript shows neither the durable wake payload nor the drain's acknowledgement command" ;;
esac

# Ledger continuity. Map each watcher pid to the reasons it delivered, then
# find the cycle that closed on the first gate's wake.
CYCLES="$PRIMARY/state/.watch-cycle-exits.log"
assert_present "$CYCLES" "no watcher cycle ledger was written"
assert_present "$DELIVERIES" "no watcher delivery ledger was written"
first_watcher=$(awk -F '\t' 'index($3, "when-gate-first") { print $1; exit }' "$DELIVERIES")
[ -n "$first_watcher" ] || diagnose "no watcher recorded delivering the first gate's wake"
first_cycle=$(grep -F "	watcher_pid=$first_watcher	" "$CYCLES" | head -1)
[ -n "$first_cycle" ] || diagnose "no cycle ledger row for watcher $first_watcher"
case "$first_cycle" in
  *'	successor=started:'[0-9]*) ;;
  *) printf '%s\n' "$first_cycle" >&2; diagnose "the cycle that closed on the first wake did not record a started successor" ;;
esac
# Watchers of every cycle after the owner's first one, in ledger order.
later_watchers=$(awk -F '\t' 'NR > 1 { for (i = 1; i <= NF; i++) if ($i ~ /^watcher_pid=/) print substr($i, 13) }' "$CYCLES")
for w in $later_watchers; do
  if awk -F '\t' -v w="$w" '$1 == w && $3 == "check: rearm-resurface" { found = 1 } END { exit !found }' "$DELIVERIES"; then
    cat "$CYCLES" "$DELIVERIES" >&2
    diagnose "watcher $w closed on check: rearm-resurface after the owner's first cycle"
  fi
done
if awk -F "\t" 'NR > 1 && index($0, "\treason=check: rearm-resurface\t") { found = 1 } END { exit !found }' "$CYCLES"; then
  cat "$CYCLES" >&2
  diagnose "a cycle ledger row after the first closed on check: rearm-resurface"
fi
pass "live primary: first-wake cycle started its successor ($(printf '%s' "$first_cycle" | sed 's/.*successor=//')) and no cycle re-announced downtime"

trap - EXIT
cleanup
printf '%s\n' 'ok - Kiro V3 primary doorbell-owner continuity passed'
