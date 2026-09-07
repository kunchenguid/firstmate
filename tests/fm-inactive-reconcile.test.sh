#!/usr/bin/env bash
# Behavioral coverage for bounded inactive terminal-outcome reconciliation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECON="$ROOT/bin/fm-inactive-reconcile.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-inactive-reconcile)

set_mtime() { # <epoch> <path>
  local epoch=$1 path=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$path"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$path"
  fi
}

age() { # <path>...
  local path now
  now=$(( $(date +%s) - 120 ))
  for path in "$@"; do set_mtime "$now" "$path"; done
}

make_tools() { # <world>
  local world=$1 fake
  fake="$world/fakebin"
  mkdir -p "$fake"
  cat > "$fake/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: %s · source: fake\n' "${FM_FAKE_CREW_STATE:-unknown}"
SH
  cat > "$fake/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'idle\n> \n' ;;
esac
SH
  local tool
  for tool in gh gh-axi curl; do
    cat > "$fake/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0")" >> "${FM_FORGE_LOG:?}"
exit 97
SH
  done
  chmod +x "$fake"/*
}

make_world() { # <name>
  WORLD="$TMP_ROOT/$1"
  MAIN="$WORLD/main"
  MATE="$WORLD/mate"
  mkdir -p "$WORLD/root" "$MAIN"/{state,data,config,projects} "$MATE"/{state,data,config,projects,bin}
  : > "$MATE/AGENTS.md"
  make_tools "$WORLD"
  : > "$WORLD/forge.log"
}

bind_secondmate() { # <local|remote>
  local route=$1
  printf 'mate\n' > "$MATE/.fm-secondmate-home"
  if [ "$route" = local ]; then
    cat > "$MATE/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$MAIN
EOF
  else
    cat > "$MATE/.fm-secondmate-parent" <<'EOF'
schema=fm-secondmate-parent.v1
route=remote
EOF
  fi
}

write_child() { # <home> <id> <status> [spawn-gen]
  local home=$1 id=$2 status=$3 spawn_gen=${4:-s${BASHPID:-$$}.$RANDOM}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$home/projects/$id" "project=alpha" \
    'harness=codex' 'kind=ship' 'mode=no-mistakes' 'yolo=off' \
    "spawn_gen=$spawn_gen" 'pr=https://example.test/owner/repo/pull/1'
  printf '%s\n' "$status" > "$home/state/$id.status"
  : > "$home/state/$id.turn-ended"
  age "$home/state/$id.meta" "$home/state/$id.status" "$home/state/$id.turn-ended"
}

write_mate_meta() {
  fm_write_secondmate_meta "$MAIN/state/mate.meta" "$MATE"
  printf 'working: delegated scope\n' > "$MAIN/state/mate.status"
  age "$MAIN/state/mate.meta" "$MAIN/state/mate.status"
}

run_reconcile() { # <home> [--startup]
  local home=$1 option=${2:-} crew_state_bin
  crew_state_bin=${FM_INACTIVE_CREW_STATE_BIN:-$WORLD/fakebin/fm-crew-state.sh}
  PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_CREW_STATE_BIN="$crew_state_bin" \
    FM_PAUSE_RESURFACE_SECS="${FM_PAUSE_RESURFACE_SECS:-3600}" \
    FM_FORGE_LOG="$WORLD/forge.log" "$RECON" scan ${option:+"$option"}
}

wake_count() { # <home> <key prefix>
  grep -c "$2" "$1/state/.wake-queue" 2>/dev/null || true
}

scan_cursor() {
  sed -n 's/^cursor=//p' "$1/state/.inactive-outcome-reconcile" 2>/dev/null | tail -1
}

scan_active_cursor() {
  sed -n 's/^active_cursor=//p' "$1/state/.inactive-outcome-reconcile" 2>/dev/null | tail -1
}

stale_row_count() { # <home>
  awk -F '\t' '$3 == "stale" { n++ } END { print n + 0 }' "$1/state/.wake-queue" 2>/dev/null \
    || printf '0\n'
}

outcome_count() { # <home> <suffix>
  find "$1/state/terminal-outcomes" -type f -name "*.$2" 2>/dev/null | wc -l | tr -d ' '
}

prime_seen() { # <state> <status>
  local state=$1 status=$2 sig
  if [ "$(uname)" = Darwin ]; then sig=$(stat -f '%z:%Fm' "$status"); else sig=$(stat -c '%s:%Y' "$status"); fi
  printf '%s' "$sig" > "$state/.seen-$(basename "$status" | tr '.' '_')"
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

ack_wakes() { # <home>
  local home=$1 err seq generation
  err="$WORLD/drain.err"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DRAIN" >/dev/null 2> "$err" || return 1
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$generation" ] || return 1
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DRAIN" \
    --ack-through "$seq" --recovery-generation "$generation"
}

# The main retains a terminal presentation receipt until the corresponding wake
# is handled and acknowledged.
test_main_direct_terminal_presentation_receipt() {
  local err seq generation
  make_world main-direct; write_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "main did not queue terminal presentation"
  [ "$(outcome_count "$MAIN" pending)" = 1 ] || fail "main did not retain presentation receipt"

  err="$WORLD/drain.err"
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$DRAIN" >/dev/null 2> "$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$generation" ] || fail "main presentation did not require durable acknowledgement"
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$DRAIN" --ack-through "$seq" --recovery-generation "$generation"
  [ "$(outcome_count "$MAIN" presented)" = 1 ] || fail "acknowledged presentation did not receive its own receipt"
  pass "main direct terminal presentation has a durable receipt"
}

# A secondmate independently reports a genuinely terminal inactive child.
test_local_secondmate_reports_terminal_child() {
  make_world local; bind_secondmate local; write_child "$MATE" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup
  grep -Fq 'done [key=inactive-outcome-mate-child-done]:' "$MAIN/state/mate.status" \
    || fail "secondmate did not append its durable parent report"
  [ "$(outcome_count "$MATE" reported)" = 1 ] || fail "secondmate report receipt was not durable"
  pass "secondmate reports its own inactive terminal child"
}

test_local_secondmate_rejects_relative_parent_home() {
  make_world relative-parent; bind_secondmate local
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=relative-parent\n' \
    > "$MATE/.fm-secondmate-parent"
  write_child "$MATE" child 'failed: terminal'
  (cd "$WORLD" && FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup)
  [ ! -e "$WORLD/relative-parent/state/mate.status" ] \
    || fail "relative parent home received a false durable report"
  [ "$(outcome_count "$MATE" reported)" = 0 ] \
    || fail "relative parent route was recorded as reported"
  [ "$(outcome_count "$MATE" pending)" = 1 ] \
    || fail "failed relative parent route did not retain its pending receipt"
  [ "$(wake_count "$MATE" 'inactive-reconcile:')" = 1 ] \
    || fail "failed relative parent route did not surface a recovery notice"
  pass "relative local parent homes fail closed"
}

# A present invalid identity marker cannot turn a secondmate home into a main
# home. The original child state remains available after the routing alarm.
test_invalid_secondmate_marker_blocks_routing() {
  local kind out target
  for kind in malformed symlink; do
    make_world "invalid-marker-$kind"
    write_child "$MATE" child 'failed: terminal'
    if [ "$kind" = malformed ]; then
      printf '../main\n' > "$MATE/.fm-secondmate-home"
    else
      target="$WORLD/marker-target"
      printf 'mate\n' > "$target"
      ln -s "$target" "$MATE/.fm-secondmate-home"
    fi

    out=$(FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup)
    printf '%s\n' "$out" | grep -Fq 'inactive terminal outcomes remain unreconciled: invalid .fm-secondmate-home marker' \
      || fail "$kind secondmate marker did not surface the blocked terminal obligation"
    [ "$(outcome_count "$MATE" pending)" = 0 ] \
      || fail "$kind secondmate marker created a main-home pending receipt"
    ! grep -Fq 'inactive-outcome:' "$MATE/state/.wake-queue" 2>/dev/null \
      || fail "$kind secondmate marker routed a captain presentation wake"
    [ -f "$MATE/state/child.meta" ] && [ -f "$MATE/state/child.status" ] \
      || fail "$kind secondmate marker lost the terminal obligation"
  done
  pass "invalid secondmate markers block routing and surface the obligation"
}

# A remote child route writes the existing mirror input once even across restarts.
test_remote_parent_reply_is_idempotent() {
  make_world remote; bind_secondmate remote; write_child "$MATE" child 'done: green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup
  [ "$(grep -c 'inactive-outcome-mate-child-done' "$MATE/state/parent-replies.status")" = 1 ] \
    || fail "remote parent reply was not restart-idempotent"
  [ "$(outcome_count "$MATE" reported)" = 1 ] || fail "remote parent report receipt missing"
  pass "remote parent-replies mirror input is durable and idempotent"
}

# Reusing a task id creates a separate receipt for the new spawned worker even
# when its terminal state and status text match the retired worker exactly.
test_reused_task_id_reports_each_incarnation() {
  make_world reused-id; bind_secondmate remote
  write_child "$MATE" child 'failed: terminal' spawn-one
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  rm -f "$MATE/state/child.meta" "$MATE/state/child.status" "$MATE/state/child.turn-ended"
  write_child "$MATE" child 'failed: terminal' spawn-two
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  [ "$(outcome_count "$MATE" reported)" = 2 ] \
    || fail "reused task id collided with the retired incarnation receipt"
  [ "$(grep -c 'inactive-outcome-mate-child-failed' "$MATE/state/parent-replies.status")" = 2 ] \
    || fail "reused task id did not produce an independent parent report"
  pass "reused task ids retain per-incarnation terminal receipts"
}

# Legacy metadata has no generation, so its stable per-spawn temp root preserves
# the same receipt identity across supported atomic metadata rewrites.
test_legacy_metadata_rewrite_keeps_receipt_identity() {
  local meta tmp
  make_world legacy-rewrite; bind_secondmate remote
  write_child "$MATE" child 'failed: terminal' spawn-old
  meta="$MATE/state/child.meta"
  tmp="$MATE/state/.child.meta.legacy"
  awk '$0 !~ /^spawn_gen=/' "$meta" > "$tmp"
  printf 'tasktmp=/tmp/fm-child\n' >> "$tmp"
  mv "$tmp" "$meta"
  age "$meta"

  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  awk '{ print }' "$meta" > "$tmp"
  mv "$tmp" "$meta"
  age "$meta"
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup

  [ "$(outcome_count "$MATE" reported)" = 1 ] \
    || fail "legacy metadata rewrite changed the terminal receipt identity"
  [ "$(grep -c 'inactive-outcome-mate-child-failed' "$MATE/state/parent-replies.status")" = 1 ] \
    || fail "legacy metadata rewrite duplicated the parent report"
  pass "legacy metadata rewrites preserve terminal receipt identity"
}

# Reconciliation snapshots terminal state and incarnation under the same task
# lifecycle lock used by relaunch metadata publication.
test_relaunch_cannot_replace_metadata_during_state_snapshot() {
  local recon_pid update_pid record i
  make_world relaunch-race; bind_secondmate remote
  write_child "$MATE" child 'failed: terminal' spawn-old
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
: > "${FM_RACE_WORLD:?}/state-started"
while [ ! -e "$FM_RACE_WORLD/state-release" ]; do sleep 0.05; done
printf 'state: failed · source: fake\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"

  FM_RACE_WORLD="$WORLD" run_reconcile "$MATE" --startup &
  recon_pid=$!
  i=0
  while [ "$i" -lt 40 ] && [ ! -e "$WORLD/state-started" ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$WORLD/state-started" ] || fail "reconciliation did not begin its state snapshot"

  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    meta="$FM_STATE_OVERRIDE/child.meta"
    lock=$(fm_meta_lock_path "$meta")
    fm_lock_acquire_wait "$lock"
    awk '\''{ sub(/^spawn_gen=.*/, "spawn_gen=spawn-new"); print }'\'' "$meta" > "$meta.tmp"
    mv "$meta.tmp" "$meta"
    printf "working: replacement active\n" > "$FM_STATE_OVERRIDE/child.status"
    : > "$2/meta-updated"
    fm_lock_release "$lock"
  ' _ "$ROOT" "$WORLD" &
  update_pid=$!
  i=0
  while [ "$i" -lt 10 ] && [ ! -e "$WORLD/meta-updated" ]; do sleep 0.05; i=$((i + 1)); done
  : > "$WORLD/state-release"
  wait "$recon_pid" || fail "reconciliation failed during relaunch race"
  wait "$update_pid" || fail "metadata replacement failed during relaunch race"

  record=$(find "$MATE/state/terminal-outcomes" -type f -name '*.reported' | head -1)
  [ -n "$record" ] || fail "terminal snapshot did not produce a receipt"
  grep -Fxq 'incarnation=spawn-old' "$record" \
    || fail "terminal result was attributed to replacement metadata"
  pass "relaunch cannot replace metadata during terminal snapshot"
}

# Heartbeat backoff state is deliberately irrelevant to the independent cadence.
test_heartbeat_cap_does_not_delay_reconciliation() {
  make_world heartbeat; write_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  printf '12\n' > "$MAIN/state/.heartbeat-streak"
  : > "$MAIN/state/.last-heartbeat"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "heartbeat cap suppressed inactive terminal reconciliation"
  pass "terminal reconciliation ignores heartbeat backoff state"
}

# Only authoritative terminal states qualify. A captain-held item is excluded too.
test_scan_marker_replaces_symlink_safely() {
  make_world marker; write_child "$MAIN" child 'done: green'
  printf 'preserve me\n' > "$MAIN/state/marker-target"
  ln -s marker-target "$MAIN/state/.inactive-outcome-reconcile"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(cat "$MAIN/state/marker-target")" = 'preserve me' ] \
    || fail "scan marker symlink overwrote its target"
  [ ! -L "$MAIN/state/.inactive-outcome-reconcile" ] \
    || fail "scan marker remained a symlink"
  pass "scan marker replaces a symlink without overwriting its target"
}

test_nonterminal_and_captain_held_states_do_not_report() {
  local state
  for state in working paused parked unknown; do
    make_world "nonterminal-$state"; write_child "$MAIN" child 'working: still active'
    FM_FAKE_CREW_STATE="$state" run_reconcile "$MAIN" --startup
    [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "$state produced a terminal outcome"
  done
  make_world captain-held; write_child "$MAIN" child 'captain-held: awaiting captain'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "captain-held item was reconciled"
  pass "nonterminal and captain-held workers remain outside inactive terminal reporting"
}

test_post_completion_pause_does_not_report_terminal_outcome() {
  make_world post-completion-pause
  write_child "$MAIN" child 'paused: waiting on an external dependency'
  printf 'done: shipped\npaused: waiting on an external dependency\n' > "$MAIN/state/child.status"
  age "$MAIN/state/child.status"
  FM_INACTIVE_CREW_STATE_BIN="$ROOT/bin/fm-crew-state.sh" run_reconcile "$MAIN" --startup
  [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "post-completion pause created a terminal outcome record"
  ! grep -Fq 'inactive-outcome:' "$MAIN/state/.wake-queue" 2>/dev/null \
    || fail "post-completion pause created an inactive terminal wake"
  pass "post-completion pauses remain outside inactive terminal reporting"
}

# The actual watcher poll invokes the helper, while an idle secondmate remains
# exempt from wedge escalation and emits no false wake.
test_watcher_hook_and_idle_secondmate_exemption() {
  local out pid i
  make_world watcher; write_child "$MAIN" child 'done: green'; prime_seen "$MAIN/state" "$MAIN/state/child.status"
  out="$WORLD/watch.out"
  PATH="$WORLD/fakebin:$PATH" FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" \
    FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" \
    FM_FORGE_LOG="$WORLD/forge.log" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_FAKE_CREW_STATE='done' "$WATCH" > "$out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 40 ]; do
    kill -0 "$pid" 2>/dev/null || break
    [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  wait "$pid" 2>/dev/null || true
  grep -Fq 'check: inactive-outcome' "$out" || fail "watcher did not surface its reconciliation result"

  make_world idle-secondmate; bind_secondmate local; write_mate_meta; prime_seen "$MAIN/state" "$MAIN/state/mate.status"
  PATH="$WORLD/fakebin:$PATH" FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$WORLD/idle.out" 2>&1 &
  pid=$!; sleep 2; kill -0 "$pid" 2>/dev/null || fail "idle secondmate watcher exited unexpectedly"; reap "$pid"
  grep -F 'stale:' "$WORLD/idle.out" >/dev/null && fail "idle secondmate was treated as a wedge"
  [ ! -s "$MAIN/state/.wake-queue" ] || fail "idle secondmate emitted a false wake"
  pass "watcher hook wakes for terminal loss and preserves idle secondmate exemption"
}

# A stalled authoritative state read consumes only the aggregate scan budget.
# The durable scan position lets the next invocation reach the following child.
test_stalled_state_read_is_bounded_and_scan_progresses() {
  local started elapsed
  make_world bounded
  write_child "$MAIN" a 'needs-decision [key=state-read]: state read will stall'
  printf 'working [key=implementation]: independent work remains active\n' \
    >> "$MAIN/state/a.status"
  age "$MAIN/state/a.meta" "$MAIN/state/a.status" "$MAIN/state/a.turn-ended"
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = a ]; then
  sleep 30
else
  printf 'state: done · source: fake\n'
fi
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"

  started=$(date +%s)
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 run_reconcile "$MAIN" --startup
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -le 3 ] || fail "stalled state read exceeded aggregate scan budget (${elapsed}s)"
  [ "$(wake_count "$MAIN" 'a.status')" = 1 ] \
    || fail "a stalled terminal-state read skipped the local decision backstop"

  write_child "$MAIN" b 'done: green'
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 run_reconcile "$MAIN" --startup
  grep -Fq 'child=b state=done' "$MAIN/state/.wake-queue" \
    || fail "next bounded scan did not resume with the following child"
  pass "stalled state reads are bounded without starving later children"
}

test_complete_child_check_is_bounded() {
  local holder i
  make_world bounded-child
  write_child "$MAIN" child 'working: lock holder blocks the complete check'
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" bash -c '
    . "$1"
    lock=$(fm_meta_lock_path "$2")
    fm_lock_acquire_wait "$lock"
    : > "$3"
    sleep 30
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$MAIN/state/child.meta" "$WORLD/lock-ready" &
  holder=$!
  i=0
  while [ "$i" -lt 30 ] && [ ! -e "$WORLD/lock-ready" ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$WORLD/lock-ready" ] || fail "meta lock holder did not start"
  FM_INACTIVE_RECONCILE_BUDGET_SECS=2 run_reconcile "$MAIN" --startup
  reap "$holder"
  awk -F '\t' '$3 == "check" && $4 == "inactive-reconcile-budget" { found = 1 } END { exit(found ? 0 : 1) }' "$MAIN/state/.wake-queue" \
    || fail "a complete child-check timeout was not routed as a capacity check"
  [ "$(stale_row_count "$MAIN")" = 0 ] || fail "a complete child-check timeout was routed as a crew wedge"
  pass "the complete per-child due-work check is process-bounded"
}

test_short_state_read_defers_instead_of_skipping_a_child() {
  make_world short-state-read
  write_child "$MAIN" a 'working: slow but healthy'
  write_child "$MAIN" b 'working: state read will stall'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  a) sleep 1.1; printf 'state: working · source: fake\n' ;;
  b) sleep 30 ;;
esac
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"

  FM_INACTIVE_RECONCILE_BUDGET_SECS=3 run_reconcile "$MAIN" --startup
  [ "$(scan_active_cursor "$MAIN")" = a ] \
    || fail "a short state-read timeout skipped the child: cursor=$(scan_active_cursor "$MAIN")"

  FM_INACTIVE_RECONCILE_BUDGET_SECS=3 run_reconcile "$MAIN" --startup
  [ "$(scan_active_cursor "$MAIN")" = b ] \
    || fail "the deferred child was not retried with a full share: cursor=$(scan_active_cursor "$MAIN")"
  pass "a short state-read timeout defers the child"
}

test_progress_wake_only_reports_measured_duration() {
  local now
  make_world progress-duration
  write_child "$MAIN" child 'working: running validation'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: unknown · source: status-log\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  now=$(date +%s)
  FM_INACTIVE_RECONCILE_NOW="$now" run_reconcile "$MAIN" --startup
  grep -Fq 'no meaningful progress since first observation; no timestamped progress event' "$MAIN/state/.wake-queue" \
    || fail "an untimestamped phase did not state its observation basis"
  grep -Eq 'no meaningful progress for [0-9]+s' "$MAIN/state/.wake-queue" \
    && fail "an untimestamped phase reported an unmeasured duration"
  pass "untimestamped progress does not invent a duration"
}

test_full_scan_budget_includes_wake_lock_wait() {
  local holder started elapsed i
  make_world wake-lock; write_child "$MAIN" child 'done: green'
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
    : > "$2"
    sleep 30
  ' _ "$ROOT" "$WORLD/lock-ready" &
  holder=$!
  i=0
  while [ "$i" -lt 30 ] && [ ! -e "$WORLD/lock-ready" ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$WORLD/lock-ready" ] || fail "wake lock holder did not start"

  started=$(date +%s)
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  elapsed=$(( $(date +%s) - started ))
  reap "$holder"
  # The unbounded wake-lock wait is ended by the process-group backstop, which
  # fires two seconds after the budget; the bound proves the scan cannot ride
  # the 30-second lock hold.
  [ "$elapsed" -le 4 ] || fail "wake lock wait exceeded aggregate scan budget (${elapsed}s)"
  pass "aggregate scan budget includes durable wake operations"
}

test_notice_recovery_does_not_duplicate_wake() {
  local record err seq generation
  make_world notice-recovery; bind_secondmate remote
  printf 'schema=fm-secondmate-parent.v1\nroute=invalid\n' > "$MATE/.fm-secondmate-parent"
  write_child "$MATE" child 'failed: terminal'
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  [ "$(wake_count "$MATE" 'inactive-reconcile:')" = 1 ] || fail "parent-report failure did not queue one notice"

  record=$(find "$MATE/state/terminal-outcomes" -type f -name '*.pending' | head -1)
  awk '{ sub(/^notice_emitted=1$/, "notice_emitted=0"); print }' "$record" > "$record.tmp"
  mv "$record.tmp" "$record"
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  [ "$(wake_count "$MATE" 'inactive-reconcile:')" = 1 ] || fail "recovery duplicated an already queued notice"

  err="$WORLD/drain.err"
  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" "$DRAIN" >/dev/null 2> "$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" "$DRAIN" --ack-through "$seq" --recovery-generation "$generation"
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  [ "$(wake_count "$MATE" 'inactive-reconcile:')" = 0 ] || fail "acknowledged notice was emitted again"
  pass "notice recovery remains idempotent across queue acknowledgement"
}

test_quiet_active_scan_does_not_read_current_state() {
  local now
  make_world quiet-active
  now=$(date +%s)
  write_child "$MAIN" child "working [at=$now]: implementation is under way"
  touch "$MAIN/state/child.meta" "$MAIN/state/child.status" "$MAIN/state/child.turn-ended"
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FM_STATE_READ_LOG:?}"
printf 'state: working · source: run-step\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  FM_STATE_READ_LOG="$WORLD/state-reads" FM_INACTIVE_RECONCILE_NOW="$now" \
    FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ ! -s "$WORLD/state-reads" ] || fail "quiet active scan read current state before work was due"
  [ ! -s "$MAIN/state/.wake-queue" ] || fail "quiet active scan woke supervision"
  pass "quiet active scans use local evidence without a current-state/model read"
}

# Driven through the real bin/fm-crew-state.sh: a trailing off-contract `note:`
# line is exactly what makes its verdict inconclusive, so a stubbed verdict here
# would assert a pairing the production reader never emits for this log.
test_overdue_active_work_ignores_chatter() {
  local t0
  make_world overdue-chatter
  t0=$(( $(date +%s) - 100 ))
  write_child "$MAIN" child "working: implementation is under way"
  mkdir -p "$MAIN/projects/child"
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$1" >> "\${FM_STATE_READ_LOG:?}"
exec "$ROOT/bin/fm-crew-state.sh" "\$@"
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  set_mtime "$t0" "$MAIN/state/child.meta"
  set_mtime "$t0" "$MAIN/state/child.turn-ended"
  printf 'note: routine check-in chatter\n' >> "$MAIN/state/child.status"
  set_mtime $((t0 + 55)) "$MAIN/state/child.status"
  FM_STATE_READ_LOG="$WORLD/state-reads" FM_INACTIVE_RECONCILE_NOW=$((t0 + 70)) \
    FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  grep -Fq 'active work has no meaningful progress' "$MAIN/state/.wake-queue" \
    || fail "chatter reset the meaningful-progress due clock"
  [ "$(grep -c 'child$' "$WORLD/state-reads" 2>/dev/null || true)" = 1 ] \
    || fail "overdue intervention performed more than one bounded current-state read: $(cat "$WORLD/state-reads" 2>/dev/null || true)"

  pass "overdue active work surfaces through a targeted wake despite chatter"
}

# A done or failed current-state verdict is a terminal outcome, not work that
# stopped making progress, so the terminal path owns it and no stale is queued.
test_terminal_verdict_is_not_surfaced_as_missing_progress() {
  make_world terminal-verdict
  write_child "$MAIN" child 'working: implementation is under way'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: done · source: run-step\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) run_reconcile "$MAIN" --startup
  [ "$(stale_row_count "$MAIN")" = 0 ] \
    || fail "a terminal verdict was surfaced as missing progress: $(cat "$MAIN/state/.wake-queue")"
  [ "$(outcome_count "$MAIN" pending)" = 1 ] \
    || fail "the terminal-outcome path did not own the done verdict"
  pass "a terminal current-state verdict is left to the terminal-outcome path"
}

# A cold cursor left by a dead watcher still anchors a rotating sweep. Even when
# that sweep is truncated before it wraps, the children at or before the cursor
# must still be reached rather than waiting out another whole interval.
test_cold_cursor_sweep_still_wraps_after_a_truncation() {
  make_world cold-cursor
  write_child "$MAIN" a 'done: green'
  write_child "$MAIN" b 'working: quietly under way'
  # Keep c outside the priority candidate set so its stalled authoritative
  # state read exercises the ordinary resumable pass and its terminal backstop.
  write_child "$MAIN" c 'note: state read will stall'
  write_child "$MAIN" d 'done: green'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" != c ] || sleep 30
case "$1" in
  a|d) printf 'state: done · source: fake\n' ;;
  *)   printf 'state: working · source: run-step\n' ;;
esac
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  printf 'epoch=1\ncursor=b\n' > "$MAIN/state/.inactive-outcome-reconcile"
  set_mtime "$(( $(date +%s) - 600 ))" "$MAIN/state/.inactive-outcome-reconcile"

  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 run_reconcile "$MAIN"
  grep -Fq 'child=a state=done' "$MAIN/state/.wake-queue" \
    || fail "the ordinary-pass timeout suppressed the earlier terminal outcome"
  run_reconcile "$MAIN"
  grep -Fq 'child=a state=done' "$MAIN/state/.wake-queue" \
    || fail "the resumed sweep dropped its outstanding wrap segment: $(cat "$MAIN/state/.wake-queue" 2>/dev/null)"
  pass "a truncated cold-cursor sweep still wraps back over its earlier children"
}

# A terminal-status pass preserves outcomes on both sides of its cursor while
# retaining the independent active continuation that exhausted the budget.
test_terminal_pass_preserves_active_continuation() {
  make_world wrap-at-origin
  write_child "$MAIN" a 'done: green'
  # A keyed working phase is required for active-candidate evidence.
  # An unkeyed working line is not an open activity, so the stall never joins the active pass.
  write_child "$MAIN" b 'working [key=implementation]: state read will stall'
  write_child "$MAIN" c 'done: green'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FM_STATE_READ_LOG:?}"
[ "$1" != b ] || sleep 30
printf 'state: done · source: fake\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  : > "$WORLD/state-reads"
  # A cold cursor at b anchors the sweep: the after segment covers c, then the
  # wrap runs a and truncates on b, which is the wrap's own upper bound.
  printf 'epoch=1\ncursor=b\n' > "$MAIN/state/.inactive-outcome-reconcile"
  set_mtime "$(( $(date +%s) - 600 ))" "$MAIN/state/.inactive-outcome-reconcile"
  FM_STATE_READ_LOG="$WORLD/state-reads" FM_INACTIVE_RECONCILE_BUDGET_SECS=2 run_reconcile "$MAIN"
  grep -Fq 'child=a state=done' "$MAIN/state/.wake-queue" \
    || fail "the sweep never reached its wrap segment: $(cat "$MAIN/state/.wake-queue" 2>/dev/null)"
  [ "$(scan_cursor "$MAIN")" = b ] \
    || fail "the wrap did not truncate on the origin child: cursor=$(scan_cursor "$MAIN")"

  FM_STATE_READ_LOG="$WORLD/state-reads" run_reconcile "$MAIN"
  [ "$(scan_active_cursor "$MAIN")" = b ] \
    || fail "the terminal pass lost the active continuation: active_cursor=$(scan_active_cursor "$MAIN")"
  pass "terminal passes preserve their active continuation"
}

test_terminal_pass_reaches_a_wrapped_origin() {
  make_world empty-wrap-cursor
  write_child "$MAIN" a 'working: state read will stall'
  write_child "$MAIN" b 'done: green'
  write_child "$MAIN" c 'working: slow but healthy'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  a) sleep 30 ;;
  b) printf 'state: done · source: fake\n' ;;
  c) sleep 1.1; printf 'state: working · source: fake\n' ;;
esac
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  printf 'epoch=1\ncursor=b\n' > "$MAIN/state/.inactive-outcome-reconcile"
  set_mtime "$(( $(date +%s) - 600 ))" "$MAIN/state/.inactive-outcome-reconcile"

  FM_INACTIVE_RECONCILE_BUDGET_SECS=4 run_reconcile "$MAIN"
  grep -Fq 'child=b state=done' "$MAIN/state/.wake-queue" \
    || fail "the terminal pass stranded the wrapped origin child"
  FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$RECON" pending \
    || fail "the terminal pass lost the active continuation"
  pass "terminal passes reach wrapped origins without stranding active work"
}

# `--help` renders this script's own contract block; a truncated render is the
# defect, and it shows up as output that stops mid-sentence.
test_help_renders_the_whole_contract_block() {
  local out last
  out=$("$RECON" --help) || fail "--help exited non-zero"
  [ -n "$out" ] || fail "--help printed nothing"
  last=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)
  case "$last" in
    *.) : ;;
    *) fail "--help output stops mid-sentence: $last" ;;
  esac
  pass "--help renders a complete contract block"
}

# A garbled or failed current-state verdict is not evidence either way, so it
# must be absorbed rather than parsed into a state/source pair and surfaced.
test_unreadable_current_state_is_absorbed() {
  make_world garbled-state
  write_child "$MAIN" child 'working: implementation is under way'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'error: worktree probe failed\n'
exit 1
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) run_reconcile "$MAIN" --startup
  [ "$(stale_row_count "$MAIN")" = 0 ] \
    || fail "a garbled current-state verdict was surfaced as a wedge: $(cat "$MAIN/state/.wake-queue")"
  [ "$(outcome_count "$MAIN" pending)" = 0 ] \
    || fail "a garbled current-state verdict produced a terminal outcome"
  pass "an unreadable current-state verdict is absorbed instead of parsed"
}

# A live attributed run or a busy pane is the evidence crew_absorb_class calls
# provably working. Overdue status evidence alone must not surface it.
test_provably_working_evidence_is_not_overdue() {
  local now src
  for src in run-step pane; do
    make_world "liveness-$src"
    write_child "$MAIN" child 'working: implementation is under way'
    touch "$MAIN/state/child.meta" "$MAIN/state/child.status" "$MAIN/state/child.turn-ended"
    cat > "$WORLD/fakebin/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
printf 'state: working · source: $src\n'
SH
    chmod +x "$WORLD/fakebin/fm-crew-state.sh"
    now=$(date +%s)
    FM_INACTIVE_RECONCILE_NOW="$now" run_reconcile "$MAIN" --startup
    FM_INACTIVE_RECONCILE_NOW=$((now + 600)) run_reconcile "$MAIN" --startup
    [ "$(stale_row_count "$MAIN")" = 0 ] \
      || fail "source=$src liveness was surfaced as overdue work: $(cat "$MAIN/state/.wake-queue")"
  done
  pass "a live run or busy pane is absorbed instead of surfaced as overdue"
}

test_unresolved_decision_is_routed_once_and_survives_restart() {
  make_world active-decision
  write_child "$MAIN" child 'needs-decision [key=api-shape]: choose the API shape'
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 1 ] || fail "unresolved decision was not routed to the owning task"
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 1 ] || fail "restart duplicated an unresolved decision wake"
  grep -Fq 'unresolved decisions' "$MAIN/state/.wake-queue" \
    || fail "decision wake omitted its folded-set marker"
  pass "unresolved decisions route durably without an automatic answer or storm"
}

test_resolved_decision_reopens_as_a_new_obligation() {
  local now payload decision
  make_world decision-reopen
  now=$(date +%s)
  write_child "$MAIN" child 'needs-decision [key=api]: choose X'
  FM_INACTIVE_RECONCILE_NOW="$now" FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  payload=$(awk -F '\t' '$3 == "signal" { print $5 }' "$MAIN/state/.wake-queue")
  [ -n "$payload" ] || fail "the initial decision was not routed"
  ack_wakes "$MAIN" || fail "the initial decision wake could not be acknowledged"
  printf 'resolved [key=api]: answered\n' >> "$MAIN/state/child.status"
  decision=$(PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" bash -c '. "$1"; classify_signal "${2#signal: }" "$3"' _ "$ROOT/bin/fm-supervise-daemon.sh" "$payload" "$MAIN/state")
  case "$decision" in escalate\|*) fail "a resolved decision was escalated from stale durable state" ;; esac
  FM_INACTIVE_RECONCILE_NOW=$((now + 1)) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  printf 'needs-decision [key=api]: choose X\n' >> "$MAIN/state/child.status"
  FM_INACTIVE_RECONCILE_NOW=$((now + 2)) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 1 ] || fail "an identical reopened decision was suppressed"
  pass "resolved decisions clear their alert generation before reopening"
}

test_open_decision_does_not_suppress_overdue_progress() {
  make_world decision-and-progress
  write_child "$MAIN" child 'needs-decision [key=api]: choose the API'
  printf 'working [key=impl]: implementation continues independently\n' >> "$MAIN/state/child.status"
  age "$MAIN/state/child.meta" "$MAIN/state/child.status" "$MAIN/state/child.turn-ended"
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: working · source: status-log\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 1 ] \
    || fail "open decision did not produce its signal"
  [ "$(stale_row_count "$MAIN")" = 1 ] \
    || fail "open decision suppressed the independent overdue progress check"
  pass "decision and progress obligations retain independent alerts"
}

test_fresh_lane_does_not_hide_an_overdue_independent_lane() {
  local now old fresh
  make_world independent-progress-lanes
  now=$(date +%s)
  old=$((now - 120))
  fresh=$((now - 10))
  write_child "$MAIN" child "working [key=impl] [at=$old]: implementation continues"
  printf 'working [key=docs] [at=%s]: documentation starts\n' "$fresh" >> "$MAIN/state/child.status"
  printf 'resolved [key=other] [at=%s]: unrelated decision closed\n' "$fresh" >> "$MAIN/state/child.status"
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: unknown · source: status-log\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  FM_INACTIVE_RECONCILE_NOW="$now" run_reconcile "$MAIN" --startup
  [ "$(stale_row_count "$MAIN")" = 1 ] || fail "a fresh lane hid overdue independent work"
  grep -Fq 'no meaningful progress for 120s' "$MAIN/state/.wake-queue" \
    || fail "the stale wake did not use the overdue lane's measured age"
  pass "fresh independent activity does not reset an overdue lane"
}

test_fresh_progress_is_not_aged_from_task_creation() {
  local old now
  make_world fresh-progress
  write_child "$MAIN" child 'working [key=old]: earlier phase'
  old=$(( $(date +%s) - 1000 ))
  now=$(date +%s)
  set_mtime "$old" "$MAIN/state/child.meta" "$MAIN/state/child.turn-ended"
  printf 'working [key=old] [at=%s]: fresh meaningful phase\n' "$now" >> "$MAIN/state/child.status"
  FM_INACTIVE_RECONCILE_NOW="$now" FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(stale_row_count "$MAIN")" = 0 ] \
    || fail "fresh progress was aged from task creation"
  printf 'resolved [key=api] [at=%s]: unrelated decision closed\n' "$((now + 1))" >> "$MAIN/state/child.status"
  FM_INACTIVE_RECONCILE_NOW="$((now + 1))" FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(stale_row_count "$MAIN")" = 0 ] \
    || fail "a fresh unrelated resolution aged independent work"
  pass "fresh progress and bookkeeping resolutions anchor to their event epochs"
}

test_decision_backstop_commits_the_watcher_generation() {
  local actor out pid i
  for actor in main away; do
    make_world "decision-generation-$actor"
    write_child "$MAIN" child 'needs-decision [key=api-shape]: choose the API shape'
    [ "$actor" != away ] || : > "$MAIN/state/.afk"
    out="$WORLD/first-watch.out"
    PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$MAIN" \
      FM_STATE_OVERRIDE="$MAIN/state" FM_INACTIVE_RECONCILE_SECS=60 \
      FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" FM_POLL=1 \
      FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$WATCH" > "$out" 2>&1 &
    pid=$!
    i=0
    while [ "$i" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
    wait "$pid" || fail "$actor decision watcher did not exit through its first wake: $(cat "$out")"
    grep -Fq 'signal: ' "$out" || fail "$actor decision backstop emitted no signal wake: $(cat "$out")"
    [ "$(wake_count "$MAIN" 'child.status')" = 1 ] \
      || fail "$actor decision backstop did not queue exactly one wake"
    ack_wakes "$MAIN" || fail "$actor decision wake could not be acknowledged"

    out="$WORLD/second-watch.out"
    PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$MAIN" \
      FM_STATE_OVERRIDE="$MAIN/state" FM_INACTIVE_RECONCILE_SECS=60 \
      FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" FM_POLL=1 \
      FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$out" 2>&1 &
    pid=$!
    sleep 3
    kill -0 "$pid" 2>/dev/null \
      || fail "$actor re-arm duplicated the handled decision: $(cat "$out")"
    reap "$pid"
    [ "$(wake_count "$MAIN" 'child.status')" = 0 ] \
      || fail "$actor re-arm queued a duplicate handled decision"
  done
  pass "decision backstop commits the watcher generation for main and away ownership"
}

test_decision_realert_preserves_an_independent_turn_end() {
  local now out pid i
  make_world decision-independent-turn
  write_child "$MAIN" child 'needs-decision [key=api-shape]: choose the API shape'
  now=$(date +%s)
  FM_PAUSE_RESURFACE_SECS=60 FM_INACTIVE_RECONCILE_NOW="$now" \
    FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  ack_wakes "$MAIN" || fail "initial decision wake could not be acknowledged"
  prime_seen "$MAIN/state" "$MAIN/state/child.turn-ended"
  printf 'finished another execution turn\n' >> "$MAIN/state/child.turn-ended"
  FM_PAUSE_RESURFACE_SECS=60 FM_INACTIVE_RECONCILE_NOW=$((now + 60)) \
    FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  ack_wakes "$MAIN" || fail "decision re-alert could not be acknowledged"

  out="$WORLD/watch.out"
  PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$MAIN" \
    FM_STATE_OVERRIDE="$MAIN/state" FM_INACTIVE_RECONCILE_SECS=60 \
    FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" FM_POLL=30 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    reap "$pid"
    fail "decision re-alert consumed the independent turn-end generation: $(cat "$out")"
  fi
  wait "$pid" || fail "turn-end watcher failed: $(cat "$out")"
  grep -Fq 'child.turn-ended' "$out" \
    || fail "independent turn-end did not retain its faster signal path: $(cat "$out")"
  pass "decision re-alert leaves independent turn-end signals pending"
}

test_declared_wait_and_parent_boundary_are_respected() {
  make_world active-boundaries
  write_child "$MAIN" child 'paused: waiting for upstream release'
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ ! -s "$MAIN/state/.wake-queue" ] || fail "declared external wait was treated as overdue work"
  bind_secondmate local
  write_mate_meta
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ ! -e "$MAIN/state/active-management/mate" ] \
    || fail "main took active management of a registered secondmate"
  pass "declared waits and the main/secondmate ownership boundary remain intact"
}

# The watcher's own stale row and this due-work path name the same task by its
# backend target, so a task already queued for intervention is never queued a
# second time for a branch or away drain to act on twice.
test_active_intervention_does_not_duplicate_an_existing_wake() {
  local now
  make_world no-duplicate
  fm_write_meta "$MAIN/state/child.meta" \
    'window=firstmate:fm-child' 'backend=orca' 'terminal=orca:child-endpoint' \
    'endpoint_task_id=child' "worktree=$MAIN/projects/child" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=no-mistakes' 'yolo=off' 'spawn_gen=s1'
  printf 'working: implementation is under way\n' > "$MAIN/state/child.status"
  : > "$MAIN/state/child.turn-ended"
  age "$MAIN/state/child.meta" "$MAIN/state/child.status" "$MAIN/state/child.turn-ended"
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: working · source: status-log\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  FM_STATE_OVERRIDE="$MAIN/state" bash -c '. "$1"; fm_wake_append stale "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" 'orca:child-endpoint' 'stale: orca:child-endpoint' \
    || fail "could not seed the watcher's own stale row"

  now=$(date +%s)
  FM_INACTIVE_RECONCILE_NOW="$now" run_reconcile "$MAIN" --startup
  [ "$(stale_row_count "$MAIN")" = 1 ] \
    || fail "due-work intervention duplicated a queued stale row: $(cat "$MAIN/state/.wake-queue")"

  rm -f "$MAIN/state/.wake-queue"
  rm -rf "$MAIN/state/active-management"
  FM_INACTIVE_RECONCILE_NOW="$now" run_reconcile "$MAIN" --startup
  [ "$(stale_row_count "$MAIN")" = 1 ] || fail "due-work intervention queued no stale row of its own"
  awk -F '\t' '$3 == "stale" { print $4 }' "$MAIN/state/.wake-queue" \
    | grep -Fxq 'orca:child-endpoint' \
    || fail "due-work stale row was not keyed by the backend target: $(cat "$MAIN/state/.wake-queue")"
  pass "due-work intervention keys by backend target and never duplicates a queued row"
}

# A decision the per-wake path already surfaced is a handled fact: the due-work
# scan starts its re-surface clock instead of waking the captain again, while a
# decision no wake path ever surfaced is queued on the first scan that sees it.
test_already_surfaced_decision_is_not_re_alerted_immediately() {
  local now
  local FM_PAUSE_RESURFACE_SECS=120
  make_world surfaced-decision
  write_child "$MAIN" child 'needs-decision [key=api-shape]: choose the API shape'
  STATE="$MAIN/state" bash -c '. "$1"; . "$2"; mark_surfaced "$3"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$ROOT/bin/fm-push-transition-lib.sh" \
    "$MAIN/state/child.status" || fail "could not record the per-wake surfaced marker"
  [ -s "$MAIN/state/.hb-surfaced-child" ] || fail "the surfaced marker was not written"

  : > "$MAIN/state/.wake-queue"
  now=$(date +%s)
  FM_INACTIVE_RECONCILE_NOW="$now" FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 0 ] \
    || fail "an already-surfaced decision was immediately re-alerted: $(cat "$MAIN/state/.wake-queue")"
  FM_INACTIVE_RECONCILE_NOW=$((now + 119)) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 0 ] \
    || fail "the re-surface clock did not hold for its interval"
  FM_INACTIVE_RECONCILE_NOW=$((now + 120)) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 1 ] \
    || fail "an unresolved decision was suppressed past its re-surface interval"

  # A decision no wake path surfaced has no marker and must not wait.
  make_world unsurfaced-decision
  write_child "$MAIN" child 'needs-decision [key=api-shape]: choose the API shape'
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 1 ] \
    || fail "a never-surfaced decision was delayed by the re-surface clock"
  pass "an already-surfaced decision starts the re-surface clock instead of re-waking"
}

test_surfaced_decision_stays_deduped_through_chatter() {
  local now
  local FM_PAUSE_RESURFACE_SECS=120
  make_world surfaced-decision-chatter
  write_child "$MAIN" child 'needs-decision [key=api-shape]: choose the API shape'
  STATE="$MAIN/state" bash -c '. "$1"; . "$2"; mark_surfaced "$3"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$ROOT/bin/fm-push-transition-lib.sh" \
    "$MAIN/state/child.status" || fail "could not record the surfaced decision"
  printf 'note: continuing unrelated work\n' >> "$MAIN/state/child.status"
  : > "$MAIN/state/.wake-queue"
  now=$(date +%s)
  FM_INACTIVE_RECONCILE_NOW="$now" FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 0 ] \
    || fail "chatter duplicated an already surfaced decision: $(cat "$MAIN/state/.wake-queue")"
  FM_INACTIVE_RECONCILE_NOW=$((now + 120)) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 1 ] \
    || fail "the still-open decision did not re-surface on its cadence"
  pass "decision receipts survive unrelated status chatter"
}

test_away_completion_does_not_receipt_a_buried_decision() {
  local now
  make_world away-completion-buried-decision
  write_child "$MAIN" child 'needs-decision [key=api-shape]: choose the API shape'
  printf 'done [key=implementation]: delivered independent work\n' >> "$MAIN/state/child.status"
  : > "$MAIN/state/.afk"
  STATE="$MAIN/state" bash -c '. "$1"; . "$2"; mark_surfaced "$3" away' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$ROOT/bin/fm-push-transition-lib.sh" \
    "$MAIN/state/child.status" || fail "could not record the away completion"

  FM_STATE_OVERRIDE="$MAIN/state" bash -c '. "$1"; fm_wake_append signal "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" child.status "signal: $MAIN/state/child.status" \
    || fail "could not enqueue the away completion signal"
  now=$(date +%s)
  FM_INACTIVE_RECONCILE_NOW="$now" FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 1 ] \
    || fail "the scan duplicated the still-pending away completion signal"
  : > "$MAIN/state/.wake-queue"
  FM_INACTIVE_RECONCILE_NOW=$((now + 1)) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 1 ] \
    || fail "the buried unresolved decision was suppressed after an away completion: $(cat "$MAIN/state/.wake-queue")"
  pass "away completion does not suppress a buried unresolved decision"
}

test_main_completion_receipts_a_buried_decision() {
  local now
  make_world main-completion-buried-decision
  write_child "$MAIN" child 'needs-decision [key=api-shape]: choose the API shape'
  printf 'done [key=implementation]: delivered independent work\n' >> "$MAIN/state/child.status"
  STATE="$MAIN/state" bash -c '. "$1"; . "$2"; mark_surfaced "$3" main' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$ROOT/bin/fm-push-transition-lib.sh" \
    "$MAIN/state/child.status" || fail "could not record the main completion"
  FM_STATE_OVERRIDE="$MAIN/state" bash -c '. "$1"; fm_wake_append signal "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" child.status "signal: $MAIN/state/child.status" \
    || fail "could not enqueue the main completion signal"
  now=$(date +%s)
  FM_INACTIVE_RECONCILE_NOW="$now" FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  : > "$MAIN/state/.wake-queue"
  FM_INACTIVE_RECONCILE_NOW=$((now + 1)) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 0 ] \
    || fail "a main-presented buried decision re-alerted after its completion signal: $(cat "$MAIN/state/.wake-queue")"
  pass "main completion receipts a buried unresolved decision"
}

test_away_push_transition_does_not_receipt_buried_decision() {
  local now record
  make_world away-push-buried-decision
  write_child "$MAIN" child 'needs-decision [key=api-shape]: choose the API shape'
  printf 'done [key=implementation]: delivered independent work\n' >> "$MAIN/state/child.status"
  : > "$MAIN/state/.afk"
  record=$(FM_STATE_OVERRIDE="$MAIN/state" bash -c '. "$1"; fm_transition_record "$2" "$3" "$4" "$5" "$6"' _ \
    "$ROOT/bin/fm-transition-lib.sh" fm-child ignored working blocked codex)
  STATE="$MAIN/state" bash -c '. "$1"; . "$2"; wake() { return 0; }; handle_push_transition herdr "$3" "$4"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$ROOT/bin/fm-push-transition-lib.sh" firstmate "$record" \
    || fail "could not deliver the away push transition"
  : > "$MAIN/state/.wake-queue"
  now=$(date +%s)
  FM_INACTIVE_RECONCILE_NOW="$now" FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 1 ] \
    || fail "an away push transition suppressed a buried unresolved decision: $(cat "$MAIN/state/.wake-queue")"
  pass "away push transitions do not receipt buried unresolved decisions"
}

# The durable state/active-management/<task> record, not the live queue, is what
# holds the alert clock once a drain has acknowledged the row and supervision has
# restarted - and it must not suppress the obligation past its re-alert interval.
test_alert_clock_survives_drain_acknowledgement() {
  local now err seq generation
  local FM_PAUSE_RESURFACE_SECS=120
  make_world alert-clock
  write_child "$MAIN" child 'needs-decision [key=api-shape]: choose the API shape'
  now=$(date +%s)
  FM_INACTIVE_RECONCILE_NOW="$now" FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 1 ] || fail "unresolved decision was not routed"

  err="$WORLD/drain.err"
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$DRAIN" >/dev/null 2> "$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$DRAIN" --ack-through "$seq" --recovery-generation "$generation"
  [ "$(wake_count "$MAIN" 'child.status')" = 0 ] || fail "acknowledgement did not consume the routed row"

  FM_INACTIVE_RECONCILE_NOW=$((now + 60)) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 0 ] \
    || fail "an answered-once decision re-alerted on the scan cadence instead of the re-surface cadence"
  FM_INACTIVE_RECONCILE_NOW=$((now + 119)) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 0 ] \
    || fail "the durable alert clock did not survive acknowledgement and restart"
  FM_INACTIVE_RECONCILE_NOW=$((now + 120)) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 1 ] \
    || fail "an unresolved obligation stayed suppressed past its re-surface interval"
  pass "the decision alert clock survives acknowledgement and re-surfaces on the fleet cadence"
}

test_progress_alert_clock_uses_resurface_cadence() {
  local now
  local FM_PAUSE_RESURFACE_SECS=120
  make_world progress-alert-clock
  write_child "$MAIN" child 'working [key=impl]: implementation continues'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: unknown · source: status-log\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  now=$(date +%s)
  FM_INACTIVE_RECONCILE_NOW="$now" run_reconcile "$MAIN" --startup
  [ "$(stale_row_count "$MAIN")" = 1 ] || fail "overdue work was not routed"
  ack_wakes "$MAIN" || fail "the overdue-progress wake could not be acknowledged"
  FM_INACTIVE_RECONCILE_NOW=$((now + 60)) run_reconcile "$MAIN" --startup
  [ "$(stale_row_count "$MAIN")" = 0 ] || fail "an unchanged lane re-alerted on the scan cadence"
  FM_INACTIVE_RECONCILE_NOW=$((now + 120)) run_reconcile "$MAIN" --startup
  [ "$(stale_row_count "$MAIN")" = 1 ] || fail "an unchanged lane stayed suppressed past the re-surface interval"
  pass "progress alerts use the fleet re-surface cadence"
}

# An incomplete active-priority check must retain its continuation without
# delaying an independent terminal outcome.
test_active_timeout_preserves_terminal_outcome_path() {
  make_world active-timeout-terminal
  write_child "$MAIN" a 'working: state read will stall'
  write_child "$MAIN" b 'done: green'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FM_STATE_READ_LOG:?}"
if [ "$1" = a ]; then sleep 30; else printf 'state: done · source: fake\n'; fi
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  : > "$WORLD/state-reads"
  FM_STATE_READ_LOG="$WORLD/state-reads" FM_INACTIVE_RECONCILE_BUDGET_SECS=1 \
    run_reconcile "$MAIN" --startup
  grep -Fq 'child=b state=done' "$MAIN/state/.wake-queue" \
    || fail "an active-priority timeout suppressed an independent terminal outcome"
  FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$RECON" pending \
    || fail "an active-priority timeout lost its continuation"
  pass "active-priority timeouts preserve independent terminal outcomes"
}

test_completed_sweep_cadence_is_anchored_to_its_start() {
  local now marker reads
  make_world sweep-start-cadence
  write_child "$MAIN" child 'done: green'
  : > "$WORLD/state-reads"
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FM_STATE_READ_LOG:?}"
printf 'state: done · source: fake\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  now=$(date +%s)
  marker="$MAIN/state/.inactive-outcome-reconcile"
  printf 'epoch=%s\nstarted_epoch=%s\ncursor=\norigin=\n' \
    "$((now - 1))" "$((now - 60))" > "$marker"
  set_mtime "$((now - 1))" "$marker"
  FM_STATE_READ_LOG="$WORLD/state-reads" FM_INACTIVE_RECONCILE_NOW="$now" run_reconcile "$MAIN"
  reads=$(wc -l < "$WORLD/state-reads")
  [ "$reads" -eq 1 ] \
    || fail "completion time extended the sweep cadence: $(cat "$WORLD/state-reads")"
  pass "completed sweep cadence remains anchored to the sweep start"
}

test_mixed_terminal_and_active_output_preserves_terminal_priority() {
  local out pid i
  make_world mixed-terminal-active
  write_child "$MAIN" active 'working: implementation is overdue'
  write_child "$MAIN" terminal 'done: green'
  prime_seen "$MAIN/state" "$MAIN/state/active.status"
  prime_seen "$MAIN/state" "$MAIN/state/terminal.status"
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  active) printf 'state: unknown · source: status-log\n' ;;
  terminal) printf 'state: done · source: fake\n' ;;
esac
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  out="$WORLD/watch.out"
  PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$MAIN" \
    FM_STATE_OVERRIDE="$MAIN/state" FM_INACTIVE_RECONCILE_SECS=60 \
    FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" FM_POLL=1 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  wait "$pid" || fail "mixed-output watcher failed: $(cat "$out")"
  grep -Fq 'check: inactive-outcome' "$out" \
    || fail "mixed output delayed the terminal wake reason: $(cat "$out")"
  [ "$(stale_row_count "$MAIN")" = 1 ] || fail "mixed scan lost its active row"
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "mixed scan lost its terminal row"
  pass "mixed terminal and active output preserves terminal wake priority"
}

# status_line_verb ignores leading whitespace when it folds an event, so the
# cheap pre-fold guards must too: an indented event is a real event.
test_indented_status_events_are_not_skipped() {
  local now
  make_world indented-decision
  write_child "$MAIN" child '  needs-decision [key=api-shape]: choose the API shape'
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 1 ] \
    || fail "an indented needs-decision received no due-work check"

  make_world indented-working
  write_child "$MAIN" child '  working: implementation is under way'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: working · source: status-log\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  now=$(date +%s)
  FM_INACTIVE_RECONCILE_NOW="$now" run_reconcile "$MAIN" --startup
  [ "$(stale_row_count "$MAIN")" = 1 ] \
    || fail "an indented working phase received no due-work check"
  pass "indented status events are folded like any other"
}

test_decision_wake_is_actionable_to_the_away_classifier() {
  local payload decision
  make_world away-decision
  write_child "$MAIN" child 'needs-decision [key=api-shape]: choose the API shape'
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  payload=$(awk -F '\t' '$3 == "signal" { print $5 }' "$MAIN/state/.wake-queue")
  [ -n "$payload" ] || fail "unresolved decision queued no signal row"
  decision=$(PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$MAIN" \
    FM_STATE_OVERRIDE="$MAIN/state" bash -c '. "$1"; classify_signal "${2#signal: }" "$3"' _ \
    "$ROOT/bin/fm-supervise-daemon.sh" "$payload" "$MAIN/state")
  case "$decision" in
    escalate\|*) : ;;
    *) fail "away mode self-handled an unresolved decision instead of escalating: $decision" ;;
  esac

  make_world away-decision-buried
  write_child "$MAIN" child 'needs-decision [key=api-shape]: choose the API shape'
  printf 'needs-decision [key=release-shape]: choose the release shape\n' \
    >> "$MAIN/state/child.status"
  printf 'working [key=impl]: continuing on the rest while blocked on api-shape\n' \
    >> "$MAIN/state/child.status"
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  payload=$(awk -F '\t' '$3 == "signal" { print $5 }' "$MAIN/state/.wake-queue" 2>/dev/null || true)
  [ -n "$payload" ] || fail "buried unresolved decision queued no signal row"
  decision=$(PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$MAIN" \
    FM_STATE_OVERRIDE="$MAIN/state" bash -c '. "$1"; classify_signal "${2#signal: }" "$3"' _ \
    "$ROOT/bin/fm-supervise-daemon.sh" "$payload" "$MAIN/state")
  case "$decision" in
    escalate\|*2\ unresolved\ decisions*) : ;;
    *) fail "away mode dropped a buried unresolved decision: $decision" ;;
  esac
  pass "decision wakes remain actionable after later status appends"
}

test_captain_held_key_does_not_mute_other_lanes() {
  local payload
  make_world captain-held-lane
  write_child "$MAIN" child 'needs-decision [key=api]: choose the API shape'
  printf 'working [key=impl]: implementation continues\n' >> "$MAIN/state/child.status"
  printf 'captain-held [key=other]: tracked by backlog-9\n' >> "$MAIN/state/child.status"
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: working · source: status-log\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) run_reconcile "$MAIN" --startup
  payload=$(awk -F '\t' '$3 == "signal" { print $5 }' "$MAIN/state/.wake-queue" 2>/dev/null || true)
  case "$payload" in *'unresolved decisions count=1'*) : ;; *) fail "a held key muted an unrelated open decision" ;; esac
  [ "$(stale_row_count "$MAIN")" = 1 ] || fail "a held key muted an independent overdue working lane"
  pass "captain holds remain scoped to their own key"
}

test_away_decision_realert_is_not_self_handled() {
  local payload decision
  make_world away-decision-realert
  write_child "$MAIN" child 'needs-decision [key=api-shape]: choose the API shape'
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  payload=$(awk -F '\t' '$3 == "signal" { print $5 }' "$MAIN/state/.wake-queue" 2>/dev/null || true)
  [ -n "$payload" ] || fail "unresolved decision queued no signal row"
  decision=$(PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" bash -c '
    . "$1"
    arg="${2#signal: }"
    classify_signal "$arg" "$3" >/dev/null
    mark_escalated_seen signal "$arg" "$3"
    classify_signal "$arg" "$3"' _ "$ROOT/bin/fm-supervise-daemon.sh" "$payload" "$MAIN/state")
  case "$decision" in escalate\|*'unresolved decisions'*) : ;; *) fail "away mode self-handled an unresolved decision re-alert" ;; esac
  pass "away decision re-alerts survive status-line deduplication"
}

test_cadence_cap_and_budget_continuation_bound_each_child() {
  local out status pid i reads id now
  make_world cadence-cap
  status=0
  out=$(PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$MAIN" \
    FM_STATE_OVERRIDE="$MAIN/state" FM_INACTIVE_RECONCILE_SECS=601 \
    FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" "$RECON" scan 2>&1) || status=$?
  [ "$status" -eq 2 ] || fail "cadence above ten minutes was accepted: status=$status output=$out"

  make_world budget-continuation
  : > "$WORLD/state-reads"
  for i in a b c; do
    write_child "$MAIN" "$i" 'working: bounded state read'
    prime_seen "$MAIN/state" "$MAIN/state/$i.status"
    prime_seen "$MAIN/state" "$MAIN/state/$i.turn-ended"
  done
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FM_STATE_READ_LOG:?}"
sleep 30
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$MAIN" \
    FM_STATE_OVERRIDE="$MAIN/state" FM_INACTIVE_RECONCILE_SECS=60 \
    FM_INACTIVE_RECONCILE_BUDGET_SECS=1 FM_STATE_READ_LOG="$WORLD/state-reads" \
    FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" FM_POLL=30 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$WORLD/watch.out" 2>&1 &
  pid=$!
  i=0
  reads=0
  while [ "$i" -lt 80 ]; do
    reads=$(wc -l < "$WORLD/state-reads")
    [ "$reads" -ge 3 ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  reap "$pid"
  [ "$reads" -ge 3 ] \
    || fail "truncated sweep slept for the 30-second poll instead of checking every child: $(cat "$WORLD/watch.out")"

  make_world over-capacity
  write_child "$MAIN" achild 'done: PR https://example.test/owner/repo/pull/1 checks green'
  for i in $(seq 1 26); do
    id=$(printf 'child%02d' "$i")
    fm_write_meta "$MAIN/state/$id.meta" \
      "window=firstmate:fm-$id" "worktree=$MAIN/projects/$id" 'project=alpha' \
      'harness=codex' 'kind=ship' 'mode=no-mistakes' 'yolo=off' "spawn_gen=$i"
    {
      printf 'needs-decision [key=gate%s]: historical gate\n' "$id"
      printf 'resolved [key=gate%s]: closed\n' "$id"
      printf 'working [key=%s]: active due-work\n' "$id"
    } > "$MAIN/state/$id.status"
  done
  write_child "$MAIN" zpartial 'note: ordinary chatter'
  printf 'note: %*s\n' 70000 '' | tr ' ' x > "$MAIN/state/zpartial.status"
  now=$(date +%s)
  FM_PAUSE_RESURFACE_SECS=3600 FM_INACTIVE_RECONCILE_NOW="$now" FM_FAKE_CREW_STATE='done' \
    run_reconcile "$MAIN" --startup
  awk -F '\t' '$3 == "check" && $4 == "inactive-reconcile-capacity" { found = 1 } END { exit(found ? 0 : 1) }' \
    "$MAIN/state/.wake-queue" \
    || fail "an over-capacity home silently claimed the ten-minute bound"
  touch "$MAIN/state/.last-watcher-beat"
  bash -c '. "$1"; fm_supervision_unhealthy "$2" 300' _ \
    "$ROOT/bin/fm-supervision-lib.sh" "$MAIN/state" \
    || fail "an over-capacity home remained supervision-healthy"
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "an over-capacity home stopped reconciling terminal outcomes"
  ack_wakes "$MAIN" || fail "the capacity wake could not be acknowledged"
  FM_PAUSE_RESURFACE_SECS=3600 FM_INACTIVE_RECONCILE_NOW=$((now + 600)) \
    run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-reconcile-capacity')" = 0 ] \
    || fail "capacity evidence re-alerted on the scan cadence"
  FM_PAUSE_RESURFACE_SECS=3600 FM_INACTIVE_RECONCILE_NOW=$((now + 3600)) \
    run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-reconcile-capacity')" = 1 ] \
    || fail "capacity evidence did not re-alert on the unresolved-obligation cadence"
  rm -f "$MAIN/state/child01.meta" "$MAIN/state/child02.meta"
  FM_PAUSE_RESURFACE_SECS=3600 FM_INACTIVE_RECONCILE_NOW=$((now + 3601)) \
    run_reconcile "$MAIN" --startup
  if bash -c '. "$1"; fm_supervision_unhealthy "$2" 300' _ \
    "$ROOT/bin/fm-supervision-lib.sh" "$MAIN/state"; then
    fail "capacity recovery remained supervision-unhealthy"
  fi
  pass "ten-minute cadence is capped and truncated sweeps continue immediately"
}

test_declared_waits_do_not_exhaust_due_work_capacity() {
  local id out
  make_world declared-wait-capacity
  for id in $(seq 1 26); do
    if [ "$id" -le 13 ]; then
      write_child "$MAIN" "paused$id" "working [key=wait$id]: preparing dependency"
      printf 'paused [key=wait%s]: waiting on upstream\n' "$id" >> "$MAIN/state/paused$id.status"
    else
      write_child "$MAIN" "held$id" "working [key=hold$id]: preparing backlog transfer"
      printf 'captain-held [key=hold%s]: tracked by backlog-%s\n' "$id" "$id" >> "$MAIN/state/held$id.status"
    fi
  done
  FM_FAKE_CREW_STATE=unknown run_reconcile "$MAIN" --startup
  [ ! -e "$MAIN/state/.inactive-reconcile-capacity" ] \
    || fail "declared waits falsely exhausted due-work capacity"
  touch "$MAIN/state/.last-watcher-beat"
  out=$(FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" \
    FM_SUPERVISION_MODEL=autoarm FM_GUARD_GRACE=300 "$ROOT/bin/fm-guard.sh" 2>&1)
  [ -z "$out" ] || fail "declared waits degraded healthy supervision: $out"
  pass "declared waits do not exhaust due-work capacity"
}

test_active_due_work_precedes_declared_wait_reconciliation() {
  local id
  make_world active-priority
  : > "$WORLD/state-reads"
  for id in $(seq -w 1 26); do
    write_child "$MAIN" "paused$id" "working [key=wait$id]: preparing dependency"
    printf 'paused [key=wait%s]: waiting on upstream\n' "$id" >> "$MAIN/state/paused$id.status"
  done
  write_child "$MAIN" zactive 'working [key=impl]: active due-work'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FM_STATE_READ_LOG:?}"
if [ "$1" = zactive ]; then
  printf 'state: unknown · source: fake\n'
else
  sleep 30
fi
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  # Leave time for both bounded phases: candidate evidence reserves one quarter
  # of this budget and zactive's state read proves the priority pass follows it.
  FM_INACTIVE_RECONCILE_BUDGET_SECS=8 FM_STATE_READ_LOG="$WORLD/state-reads" \
    run_reconcile "$MAIN" --startup
  grep -Fxq zactive "$WORLD/state-reads" \
    || fail "active due work waited behind declared-wait reconciliation"
  [ ! -e "$MAIN/state/.inactive-reconcile-capacity" ] \
    || fail "declared waits exhausted active due-work capacity"
  pass "active due work precedes declared-wait reconciliation"
}

test_unbounded_candidate_evidence_is_partial_and_non_escalating() {
  local i started elapsed
  make_world candidate-evidence-bound
  write_child "$MAIN" paused 'working [key=wait]: preparing dependency'
  for i in $(seq 1 4000); do
    printf 'working [key=wait]: historical work %s\n' "$i"
    printf 'paused [key=wait]: waiting on upstream %s\n' "$i"
  done > "$MAIN/state/paused.status"
  write_child "$MAIN" zactive 'working [key=impl]: active due-work'
  started=$(date +%s)
  FM_INACTIVE_RECONCILE_BUDGET_SECS=4 run_reconcile "$MAIN" --startup
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -le 4 ] \
    || fail "candidate evidence exceeded its bounded per-task work (${elapsed}s)"
  [ ! -e "$MAIN/state/.inactive-reconcile-capacity" ] \
    || fail "partial candidate evidence falsely degraded supervision"
  [ -f "$MAIN/state/.inactive-reconcile-partial" ] \
    || fail "partial candidate evidence was not represented durably"
  touch "$MAIN/state/.last-watcher-beat"
  if bash -c '. "$1"; fm_supervision_unhealthy "$2" 300' _ \
    "$ROOT/bin/fm-supervision-lib.sh" "$MAIN/state"; then
    fail "partial candidate evidence degraded healthy supervision"
  fi
  pass "unbounded candidate evidence is partial and non-escalating"
}

test_partial_candidate_remains_in_resumable_regular_sweep() {
  make_world partial-candidate-regular-sweep
  write_child "$MAIN" partial 'working [key=implementation]: active work'
  {
    printf 'working [key=implementation]: active work\n'
    printf 'note: %*s\n' 70000 '' | tr ' ' x
  } > "$MAIN/state/partial.status"
  age "$MAIN/state/partial.status"
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FM_STATE_READ_LOG:?}"
printf 'state: unknown · source: fake\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  FM_INACTIVE_RECONCILE_BUDGET_SECS=4 FM_STATE_READ_LOG="$WORLD/state-reads" \
    run_reconcile "$MAIN" --startup
  grep -Fxq partial "$WORLD/state-reads" \
    || fail "a partial candidate was skipped instead of receiving its resumable state read"
  pass "partial candidate remains in the resumable regular sweep"
}

test_empty_active_set_clears_the_continuation() {
  local now
  make_world empty-active-continuation
  write_child "$MAIN" child 'working [key=implementation]: active work'
  now=$(date +%s)
  cat > "$MAIN/state/.inactive-outcome-reconcile" <<EOF
epoch=$now
started_epoch=$now
cursor=
origin=
active_cursor=child
EOF
  printf 'done [key=implementation]: delivered\n' > "$MAIN/state/child.status"
  FM_INACTIVE_RECONCILE_NOW="$now" FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  if FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$RECON" pending; then
    fail "an empty active set left the watcher continuation pending"
  fi
  pass "an empty active set clears its continuation"
}

test_legacy_hot_cursor_runs_its_wrap_segment() {
  local id
  make_world legacy-hot-cursor
  : > "$WORLD/state-reads"
  for id in a b c; do
    write_child "$MAIN" "$id" 'done: green'
  done
  printf 'epoch=%s\ncursor=b\n' "$(date +%s)" > "$MAIN/state/.inactive-outcome-reconcile"
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FM_STATE_READ_LOG:?}"
printf 'state: done · source: fake\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  FM_STATE_READ_LOG="$WORLD/state-reads" run_reconcile "$MAIN"
  for id in a b c; do
    grep -Fxq "$id" "$WORLD/state-reads" \
      || fail "legacy hot cursor omitted child $id from its rotating sweep"
  done
  pass "legacy hot cursors resume as complete rotating sweeps"
}

# A secondmate home applies the same bounded pass to its own direct children, so
# the evidence reaches the actor that owns it instead of being stranded or
# duplicated by the parent's lane.
test_secondmate_active_evidence_reaches_its_owning_actor() {
  make_world routed-active
  bind_secondmate local
  write_mate_meta
  write_child "$MATE" mate-child 'needs-decision [key=scope]: which module first'
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) FM_FAKE_CREW_STATE=working run_reconcile "$MATE" --startup
  [ "$(wake_count "$MATE" 'mate-child.status')" = 1 ] \
    || fail "secondmate evidence never reached its own supervision queue"
  [ ! -s "$MAIN/state/.wake-queue" ] || fail "secondmate evidence was queued into the parent's lane"
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) FM_FAKE_CREW_STATE=working run_reconcile "$MATE" --startup
  [ "$(wake_count "$MATE" 'mate-child.status')" = 1 ] || fail "a rescan duplicated the routed report"
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ ! -s "$MAIN/state/.wake-queue" ] || fail "the parent duplicated the secondmate's routed report"
  pass "secondmate active-management evidence routes once to its owning actor"
}

# Forge command shims fail loudly. A successful scan proves this path never uses
# them while reconciling a local terminal outcome.
test_reconciliation_never_calls_forge() {
  make_world forge; write_child "$MAIN" child 'done: green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ ! -s "$WORLD/forge.log" ] || fail "reconciliation invoked a forge command: $(cat "$WORLD/forge.log")"
  pass "reconciliation makes zero forge or PR API calls"
}

test_main_direct_terminal_presentation_receipt
test_local_secondmate_reports_terminal_child
test_local_secondmate_rejects_relative_parent_home
test_invalid_secondmate_marker_blocks_routing
test_remote_parent_reply_is_idempotent
test_reused_task_id_reports_each_incarnation
test_legacy_metadata_rewrite_keeps_receipt_identity
test_relaunch_cannot_replace_metadata_during_state_snapshot
test_heartbeat_cap_does_not_delay_reconciliation
test_scan_marker_replaces_symlink_safely
test_nonterminal_and_captain_held_states_do_not_report
test_post_completion_pause_does_not_report_terminal_outcome
test_watcher_hook_and_idle_secondmate_exemption
test_stalled_state_read_is_bounded_and_scan_progresses
test_complete_child_check_is_bounded
test_short_state_read_defers_instead_of_skipping_a_child
test_progress_wake_only_reports_measured_duration
test_full_scan_budget_includes_wake_lock_wait
test_notice_recovery_does_not_duplicate_wake
test_quiet_active_scan_does_not_read_current_state
test_overdue_active_work_ignores_chatter
test_provably_working_evidence_is_not_overdue
test_unreadable_current_state_is_absorbed
test_terminal_verdict_is_not_surfaced_as_missing_progress
test_cold_cursor_sweep_still_wraps_after_a_truncation
test_terminal_pass_preserves_active_continuation
test_terminal_pass_reaches_a_wrapped_origin
test_help_renders_the_whole_contract_block
test_indented_status_events_are_not_skipped
test_unresolved_decision_is_routed_once_and_survives_restart
test_resolved_decision_reopens_as_a_new_obligation
test_open_decision_does_not_suppress_overdue_progress
test_fresh_lane_does_not_hide_an_overdue_independent_lane
test_fresh_progress_is_not_aged_from_task_creation
test_decision_backstop_commits_the_watcher_generation
test_decision_realert_preserves_an_independent_turn_end
test_alert_clock_survives_drain_acknowledgement
test_progress_alert_clock_uses_resurface_cadence
test_already_surfaced_decision_is_not_re_alerted_immediately
test_surfaced_decision_stays_deduped_through_chatter
test_away_completion_does_not_receipt_a_buried_decision
test_main_completion_receipts_a_buried_decision
test_away_push_transition_does_not_receipt_buried_decision
test_active_timeout_preserves_terminal_outcome_path
test_completed_sweep_cadence_is_anchored_to_its_start
test_mixed_terminal_and_active_output_preserves_terminal_priority
test_decision_wake_is_actionable_to_the_away_classifier
test_captain_held_key_does_not_mute_other_lanes
test_away_decision_realert_is_not_self_handled
test_cadence_cap_and_budget_continuation_bound_each_child
test_declared_waits_do_not_exhaust_due_work_capacity
test_active_due_work_precedes_declared_wait_reconciliation
test_unbounded_candidate_evidence_is_partial_and_non_escalating
test_partial_candidate_remains_in_resumable_regular_sweep
test_empty_active_set_clears_the_continuation
test_legacy_hot_cursor_runs_its_wrap_segment
test_secondmate_active_evidence_reaches_its_owning_actor
test_declared_wait_and_parent_boundary_are_respected
test_active_intervention_does_not_duplicate_an_existing_wake
test_reconciliation_never_calls_forge

echo "all inactive reconciliation tests passed"
