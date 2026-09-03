#!/usr/bin/env bash
# Behavioral coverage for bounded inactive terminal-outcome reconciliation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-done-claim-lib.sh"

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
  local home=$1 option=${2:-}
  PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" \
    FM_FORGE_LOG="$WORLD/forge.log" "$RECON" scan ${option:+"$option"}
}

# The teardown-side entry point: deliver one child's terminal ledger line for a
# caller holding its meta lock.
run_report() { # <home> <child>
  local home=$1 child=$2
  PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" \
    FM_FORGE_LOG="$WORLD/forge.log" "$RECON" report "$child"
}

wake_count() { # <home> <key prefix>
  grep -c "$2" "$1/state/.wake-queue" 2>/dev/null || true
}

outcome_count() { # <home> <suffix>
  find "$1/state/terminal-outcomes" -type f -name "*.$2" 2>/dev/null | wc -l | tr -d ' '
}

reported_outcome_key() { # <home> <id> <state>
  local home=$1 id=$2 state=$3 record key
  for record in "$home/state/terminal-outcomes"/*.reported; do
    [ -f "$record" ] || continue
    grep -Fxq "task_id=$id" "$record" || continue
    grep -Fxq "state=$state" "$record" || continue
    key=$(sed -n 's/^outcome_key=//p' "$record")
    case "$key" in
      "child-outcome-$id-$state-"[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) printf '%s\n' "$key"; return 0 ;;
    esac
  done
  return 1
}

prime_seen() { # <state> <status>
  FM_STATE_OVERRIDE="$1" bash -c '
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2"
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

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

# A secondmate delivers a child's terminal ledger line to the parent on the
# very next poll, from the ledger alone: no current-state read, no inactive
# cadence, and no line appended by the mate model. The delivery carries the
# child's note, recorded PR, delivery mode, and merge posture, happens once,
# and takes the outcome away from the inactive path so it is never reported
# twice.
test_local_secondmate_delivers_terminal_ledger_line() {
  local expected key
  make_world local; bind_secondmate local
  write_child "$MATE" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  key=$(reported_outcome_key "$MATE" child 'done') || fail "ledger receipt did not retain its collision-resistant key"
  expected="blocked [key=$key]: child child done: PR https://example.test/owner/repo/pull/1 checks green pr=https://example.test/owner/repo/pull/1 mode=no-mistakes yolo=off claim=unverified"
  grep -Fxq "$expected" "$MAIN/state/mate.status" \
    || fail "secondmate did not deliver the child's ledger line on a plain poll: $(cat "$MAIN/state/mate.status" 2>/dev/null)"
  [ "$(outcome_count "$MATE" reported)" = 1 ] || fail "ledger delivery receipt was not durable"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  [ "$(grep -c 'child-outcome-child-done' "$MAIN/state/mate.status")" = 1 ] \
    || fail "a second poll delivered the same ledger line again"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup
  ! grep -q 'inactive-outcome-' "$MAIN/state/mate.status" \
    || fail "the inactive path reported a child the ledger delivery already owned"
  [ "$(outcome_count "$MATE" reported)" = 1 ] || fail "the inactive path minted a second receipt"
  pass "secondmate delivers a child's terminal ledger line once, on the next poll, from the ledger alone"
}

# The parent's durable supervision record must never say a child is done on the
# child's own assertion. The ledger path is the delivering path in a secondmate
# home, so it applies the same rule report_to_parent does: a terminal claim
# nothing has established reaches the parent as a blocker naming the claim
# state, and the same claim with a matching verified verdict reaches it as done.
test_ledger_delivery_downgrades_an_unestablished_claim() {
  local claim hash key
  claim='done: pr=https://example.test/owner/repo/pull/1 head=00112233445566778899aabbccddeeff00112233 - shipped'

  make_world ledger-unverified; bind_secondmate local
  write_child "$MATE" child "$claim"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  key=$(reported_outcome_key "$MATE" child 'done') || fail "ledger receipt did not retain its key"
  grep -q "^blocked \[key=$key\]: child child done: " "$MAIN/state/mate.status" \
    || fail "an unestablished claim did not reach the parent as a blocker: $(cat "$MAIN/state/mate.status" 2>/dev/null)"
  grep -q "^done \[key=$key\]" "$MAIN/state/mate.status" \
    && fail "an unestablished claim reached the parent's record as done"
  grep -Fq 'claim=unverified' "$MAIN/state/mate.status" \
    || fail "the downgraded line did not name the claim state"

  make_world ledger-verified; bind_secondmate local
  write_child "$MATE" child "$claim"
  hash=$(fm_done_claim_hash "$claim") || fail "could not compute the claim identity"
  printf 'fm-done-verdict-v1\nverified\n%s\n%s\nPR at the claimed head\n' \
    "$hash" "$(date +%s)" > "$MATE/state/child.done-verdict"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  key=$(reported_outcome_key "$MATE" child 'done') || fail "established ledger receipt key missing"
  grep -q "^done \[key=$key\]: child child done: " "$MAIN/state/mate.status" \
    || fail "an established claim was not delivered as done: $(cat "$MAIN/state/mate.status" 2>/dev/null)"
  grep -Fq 'claim=' "$MAIN/state/mate.status" \
    && fail "an established claim was annotated as if it were not"

  pass "ledger delivery publishes an unestablished done claim as a blocker and an established one as done"
}

# A report about an UNSETTLED state must never be retired as though it were
# settled. A claim published upward as unverified is corrected when the verifier
# later establishes it, because the verdict is part of the event's identity and
# not only of its wording - while a verdict that has not moved is still the same
# event and stays deduplicated.
test_a_later_established_claim_corrects_the_parents_record() {
  local claim hash
  claim='done: pr=https://example.test/owner/repo/pull/1 head=00112233445566778899aabbccddeeff00112233 - shipped'
  make_world ledger-corrects; bind_secondmate local
  write_child "$MATE" child "$claim"

  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  grep -q '^blocked \[key=child-outcome-child-done-' "$MAIN/state/mate.status" \
    || fail "an unestablished claim did not reach the parent as a blocker: $(cat "$MAIN/state/mate.status" 2>/dev/null)"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  [ "$(grep -c 'child-outcome-child-done-' "$MAIN/state/mate.status")" = 1 ] \
    || fail "an unchanged verdict was reported twice"

  hash=$(fm_done_claim_hash "$claim") || fail "could not compute the claim identity"
  printf 'fm-done-verdict-v1\nverified\n%s\n%s\nPR at the claimed head\n' \
    "$hash" "$(date +%s)" > "$MATE/state/child.done-verdict"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  grep -q '^done \[key=child-outcome-child-done-' "$MAIN/state/mate.status" \
    || fail "an established claim never corrected the parent's blocked record: $(cat "$MAIN/state/mate.status" 2>/dev/null)"

  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  [ "$(grep -c '^done \[key=child-outcome-child-done-' "$MAIN/state/mate.status")" = 1 ] \
    || fail "the corrected line was republished on a later poll"
  pass "a claim established after it was reported unverified corrects the parent's record once"
}

# Both upward delivery paths must agree with the rest of the fleet about what a
# terminal outcome is. A routed phase closing with `done [key=<slug>]` - the
# shape bin/fm-brief.sh instructs - is one sub-event finishing, so it must not be
# delivered upward as the child's completion by the ledger path, and it must not
# make the crew-state backstop stand down as though the outcome were already
# owned. The unkeyed control keeps both halves honest.
test_a_keyed_phase_close_is_not_the_childs_terminal_outcome() {
  make_world keyed-ledger; bind_secondmate local
  write_child "$MATE" child 'done [key=docs]: that routed phase landed'
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  ! grep -q 'child-outcome-child-' "$MAIN/state/mate.status" 2>/dev/null \
    || fail "a closed routed phase was delivered upward as the child's outcome: $(cat "$MAIN/state/mate.status" 2>/dev/null)"

  # The backstop must still see this child, because the ledger path does not own
  # an outcome the child never stated.
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup
  grep -q 'inactive-outcome-' "$MAIN/state/mate.status" \
    || fail "the crew-state backstop stood down for a child whose ledger states no outcome: $(cat "$MAIN/state/mate.status" 2>/dev/null)"

  make_world unkeyed-ledger; bind_secondmate local
  write_child "$MATE" child 'failed: the work did not land'
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  grep -q '^failed \[key=child-outcome-child-failed-' "$MAIN/state/mate.status" \
    || fail "the child's own terminal line was not delivered upward: $(cat "$MAIN/state/mate.status" 2>/dev/null)"
  pass "a closed routed phase is neither delivered as the child's outcome nor allowed to silence the backstop"
}

# A busy child cannot keep later ledger outcomes from being visited, and is
# retried on the next poll after its lifecycle lock becomes available.
test_busy_child_does_not_starve_later_ledger_outcomes() {
  local holder i delivered=0
  make_world busy-ledger; bind_secondmate local
  write_child "$MATE" a-busy 'done: busy child finished'
  write_child "$MATE" b-ready 'done: later child finished'
  printf 'epoch=%s\ncursor=\n' "$(date +%s)" > "$MATE/state/.inactive-outcome-reconcile"
  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    lock=$(fm_meta_lock_path "$FM_STATE_OVERRIDE/a-busy.meta")
    fm_lock_acquire_wait "$lock"
    : > "$2/busy-lock-held"
    while [ ! -e "$2/release-busy-lock" ]; do sleep 0.05; done
    fm_lock_release "$lock"
  ' _ "$ROOT" "$WORLD" &
  holder=$!
  i=0
  while [ "$i" -lt 40 ] && [ ! -e "$WORLD/busy-lock-held" ]; do sleep 0.05; i=$((i + 1)); done
  if [ -e "$WORLD/busy-lock-held" ]; then
    FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
    grep -Fq 'child-outcome-b-ready-done' "$MAIN/state/mate.status" 2>/dev/null && delivered=1
  fi
  : > "$WORLD/release-busy-lock"
  reap "$holder"
  [ "$delivered" -eq 1 ] \
    || fail "a busy early child starved a later terminal ledger outcome"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  grep -Fq 'child-outcome-a-busy-done' "$MAIN/state/mate.status" \
    || fail "the skipped busy child was not retried on the next poll"
  pass "busy child locks do not starve later ledger outcomes"
}

# A scout's done line carries its report pointer, a failed line is delivered
# under the failed verb, and a later terminal line after recovery is a new
# delivery rather than a suppressed duplicate.
test_secondmate_ledger_delivery_carries_report_and_failure() {
  local scout_key boom_key replaced_key
  make_world ledger-shapes; bind_secondmate local
  write_child "$MATE" scout 'done: report written'
  mkdir -p "$MATE/data/scout"
  printf '# findings\n' > "$MATE/data/scout/report.md"
  write_child "$MATE" boom 'failed: build broke'
  write_child "$MATE" replaced-pr $'working: old PR https://example.test/owner/repo/pull/11\ndone: replacement PR https://example.test/owner/repo/pull/22'
  awk '$0 !~ /^pr=/' "$MATE/state/replaced-pr.meta" > "$MATE/state/replaced-pr.meta.tmp"
  mv "$MATE/state/replaced-pr.meta.tmp" "$MATE/state/replaced-pr.meta"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  scout_key=$(reported_outcome_key "$MATE" scout 'done') || fail "scout receipt key missing"
  boom_key=$(reported_outcome_key "$MATE" boom failed) || fail "failed receipt key missing"
  replaced_key=$(reported_outcome_key "$MATE" replaced-pr 'done') || fail "replacement PR receipt key missing"
  grep -Fxq "blocked [key=$scout_key]: child scout done: report written pr=https://example.test/owner/repo/pull/1 mode=no-mistakes yolo=off report=data/scout/report.md claim=unverified" \
    "$MAIN/state/mate.status" || fail "scout delivery lost its report pointer: $(cat "$MAIN/state/mate.status")"
  grep -Fxq "failed [key=$boom_key]: child boom failed: build broke pr=https://example.test/owner/repo/pull/1 mode=no-mistakes yolo=off" \
    "$MAIN/state/mate.status" || fail "failed line was not delivered under the failed verb: $(cat "$MAIN/state/mate.status")"
  grep -Fxq "blocked [key=$replaced_key]: child replaced-pr done: replacement PR https://example.test/owner/repo/pull/22 pr=https://example.test/owner/repo/pull/22 mode=no-mistakes yolo=off claim=unverified" \
    "$MAIN/state/mate.status" || fail "ledger fallback did not prefer the terminal line PR: $(cat "$MAIN/state/mate.status")"
  printf 'working: retrying\ndone: fixed on retry\n' >> "$MATE/state/boom.status"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  boom_key=$(reported_outcome_key "$MATE" boom 'done') || fail "recovered receipt key missing"
  grep -Fq "blocked [key=$boom_key]: child boom done: fixed on retry" "$MAIN/state/mate.status" \
    || fail "a new terminal line after recovery was not delivered"
  [ "$(grep -c 'child-outcome-boom-' "$MAIN/state/mate.status")" = 2 ] \
    || fail "recovery delivered the wrong number of lines: $(cat "$MAIN/state/mate.status")"
  pass "ledger delivery carries the report pointer, the failed verb, and each new terminal line"
}

# If a terminal ledger line lands while the authoritative state read is in
# flight, the ledger path remains the single owner on the next poll.
test_terminal_line_during_state_read_yields_to_ledger_delivery() {
  make_world state-ledger-race; bind_secondmate local
  write_child "$MATE" child 'working: finishing now'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'done: completed during state read\n' >> "$FM_STATE_OVERRIDE/$1.status"
printf 'state: done · source: fake\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  run_reconcile "$MATE" --startup
  [ ! -e "$MAIN/state/mate.status" ] \
    || ! grep -q 'inactive-outcome-' "$MAIN/state/mate.status" \
    || fail "inactive reconciliation claimed an outcome whose terminal ledger arrived during state read"
  run_reconcile "$MATE"
  [ "$(grep -c 'child-outcome-child-done-' "$MAIN/state/mate.status")" = 1 ] \
    || fail "the next ledger pass did not deliver the raced terminal line exactly once"
  ! grep -q 'inactive-outcome-' "$MAIN/state/mate.status" \
    || fail "one raced terminal event was reported by both reconciliation paths"
  pass "terminal lines arriving during state reads remain ledger-owned"
}

# A terminal append can land after the inactive path's final ledger read but
# before its already-selected outcome is observed on the next poll. The receipt
# store reconciles that ledger event with the fallback delivery, while a later
# same-state completion remains independently deliverable.
test_terminal_line_after_inactive_delivery_is_not_reported_twice() {
  make_world inactive-ledger-race; bind_secondmate local
  write_child "$MATE" child 'working: finishing now'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup
  [ "$(grep -c 'inactive-outcome-mate-child-done' "$MAIN/state/mate.status")" = 1 ] \
    || fail "inactive fallback did not publish exactly once"

  printf 'done: completion landed after reconciliation\n' >> "$MATE/state/child.status"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE"
  [ "$(wc -l < "$MAIN/state/mate.status" | tr -d ' ')" = 1 ] \
    || fail "one completion was published by both inactive and ledger paths: $(cat "$MAIN/state/mate.status")"
  [ "$(outcome_count "$MATE" reported)" = 2 ] \
    || fail "the raced ledger event was not durably reconciled with the fallback receipt"

  printf 'working: retrying after completion\ndone: completed again\n' >> "$MATE/state/child.status"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE"
  [ "$(wc -l < "$MAIN/state/mate.status" | tr -d ' ')" = 2 ] \
    || fail "the inactive claim suppressed a later same-state terminal event: $(cat "$MAIN/state/mate.status")"
  grep -Fq 'child child done: completed again' "$MAIN/state/mate.status" \
    || fail "the later same-state terminal event was not delivered"
  pass "inactive and ledger paths reconcile one raced completion without hiding later events"
}

# An intervening progress line means the next terminal line is a new completion,
# not a late ledger rendering of the inactive fallback.
test_progress_after_inactive_delivery_starts_a_new_event() {
  make_world inactive-recovery; bind_secondmate local
  write_child "$MATE" child 'working: first attempt finishing'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup
  printf 'working: retry started\ndone: retry completed\n' >> "$MATE/state/child.status"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE"
  [ "$(wc -l < "$MAIN/state/mate.status" | tr -d ' ')" = 2 ] \
    || fail "an intervening progress event did not separate two completions: $(cat "$MAIN/state/mate.status")"
  grep -Fq 'child child done: retry completed' "$MAIN/state/mate.status" \
    || fail "the completion after recovery was not delivered"
  pass "progress after an inactive fallback starts a distinct terminal event"
}

# Receipt identity covers the complete terminal ledger line even when the
# captain-facing rendering truncates two long notes to the same text.
test_long_terminal_lines_have_distinct_receipts() {
  local prefix
  make_world long-ledger; bind_secondmate local
  prefix=$(awk 'BEGIN { for (i = 0; i < 1300; i++) printf "a" }')
  write_child "$MATE" child "failed: ${prefix}one"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  printf 'failed: %stwo\n' "$prefix" >> "$MATE/state/child.status"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  [ "$(outcome_count "$MATE" reported)" = 2 ] \
    || fail "distinct complete ledger lines collided in the receipt store"
  [ "$(grep -c 'child-outcome-child-failed-' "$MAIN/state/mate.status")" = 2 ] \
    || fail "distinct complete ledger lines collapsed into one parent delivery"
  pass "complete long ledger lines retain distinct receipt identities"
}

# A line still being appended has no trailing newline yet and must wait.
test_secondmate_partial_ledger_line_waits_for_newline() {
  local key
  make_world partial; bind_secondmate local
  write_child "$MATE" child 'working: nearly there'
  printf 'done: half writ' >> "$MATE/state/child.status"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  [ ! -e "$MAIN/state/mate.status" ] || ! grep -q 'child-outcome-' "$MAIN/state/mate.status" \
    || fail "an unterminated ledger line was delivered: $(cat "$MAIN/state/mate.status")"
  printf 'ten\n' >> "$MATE/state/child.status"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  key=$(reported_outcome_key "$MATE" child 'done') || fail "completed ledger receipt key missing"
  grep -Fq "blocked [key=$key]: child child done: half written" "$MAIN/state/mate.status" \
    || fail "the completed line was not delivered once its newline landed"
  pass "a ledger line still being appended waits for its newline"
}

# The remote route delivers the same line into this home's parent-replies
# input, once.
test_secondmate_remote_route_ledger_delivery() {
  make_world remote-ledger; bind_secondmate remote
  write_child "$MATE" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  [ "$(grep -c 'child-outcome-child-done' "$MATE/state/parent-replies.status")" = 1 ] \
    || fail "remote ledger delivery was not once-only: $(cat "$MATE/state/parent-replies.status" 2>/dev/null)"
  pass "the remote route carries a child's ledger line once"
}

# `report <child>` is the teardown-side delivery: it delivers or says nothing
# is owed with 0, and returns non-zero only when the channel cannot be written.
test_report_subcommand_delivers_and_refuses() {
  local rc key
  make_world report; bind_secondmate local
  write_child "$MATE" child 'done: final word'
  run_report "$MATE" child || fail "report refused a deliverable ledger line"
  key=$(reported_outcome_key "$MATE" child 'done') || fail "report receipt key missing"
  grep -Fq "blocked [key=$key]: child child done: final word" "$MAIN/state/mate.status" \
    || fail "report did not deliver the child's final line"
  run_report "$MATE" child || fail "report did not treat an already delivered line as owed nothing"
  write_child "$MATE" quiet 'working: nothing terminal'
  run_report "$MATE" quiet || fail "report refused a child that owes nothing"
  printf 'schema=fm-secondmate-parent.v1\nroute=invalid\n' > "$MATE/.fm-secondmate-parent"
  write_child "$MATE" stuck 'failed: cannot reach anyone'
  rc=0
  run_report "$MATE" stuck >/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "report claimed delivery through an unusable parent binding"
  [ "$(wake_count "$MATE" 'inactive-reconcile:')" = 1 ] || fail "undeliverable report did not queue its notice"
  write_child "$MAIN" child 'done: main home child'
  run_report "$MAIN" child || fail "report failed in a main home"
  [ ! -e "$MAIN/state/parent-replies.status" ] || fail "a main home wrote a parent reply"
  pass "report delivers a child's final line, owes nothing twice, and refuses only an unwritable channel"
}

# Teardown calls report while holding the child's metadata lock. A concurrent
# scan may hold the scan lock while waiting for that metadata lock, so report
# must not wait for the scan lock in the opposite order.
test_report_avoids_scan_meta_lock_inversion() {
  local holder scan_pid report_pid i completed=0
  make_world report-lock-order; bind_secondmate local
  write_child "$MATE" child 'done: final word'
  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    lock=$(fm_meta_lock_path "$FM_STATE_OVERRIDE/child.meta")
    fm_lock_acquire_wait "$lock"
    : > "$2/meta-held"
    while [ ! -e "$2/release-meta" ]; do sleep 0.05; done
    fm_lock_release "$lock"
  ' _ "$ROOT" "$WORLD" &
  holder=$!
  i=0
  while [ "$i" -lt 40 ] && [ ! -e "$WORLD/meta-held" ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$WORLD/meta-held" ] || { reap "$holder"; fail "metadata lock holder did not start"; }

  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE" --startup &
  scan_pid=$!
  i=0
  while [ "$i" -lt 40 ] && [ ! -e "$MATE/state/.inactive-outcome-reconcile.lock" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$MATE/state/.inactive-outcome-reconcile.lock" ] \
    || { : > "$WORLD/release-meta"; reap "$holder"; reap "$scan_pid"; fail "scan lock holder did not start"; }

  (run_report "$MATE" child && : > "$WORLD/report-complete") &
  report_pid=$!
  i=0
  while [ "$i" -lt 40 ] && [ ! -e "$WORLD/report-complete" ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$WORLD/report-complete" ] && completed=1
  : > "$WORLD/release-meta"
  reap "$holder"
  reap "$report_pid"
  reap "$scan_pid"
  [ "$completed" -eq 1 ] || fail "report deadlocked behind a scan waiting for the caller's metadata lock"
  pass "report preserves teardown's metadata-before-scan lock order"
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
    [ "$(wake_count "$MATE" 'inactive-reconcile-diagnostic:invalid-secondmate-home')" = 1 ] \
      || fail "$kind secondmate marker diagnostic was not durably queued"
    ! grep -Fq 'inactive-outcome:' "$MATE/state/.wake-queue" 2>/dev/null \
      || fail "$kind secondmate marker routed a captain presentation wake"
    [ -f "$MATE/state/child.meta" ] && [ -f "$MATE/state/child.status" ] \
      || fail "$kind secondmate marker lost the terminal obligation"
  done
  pass "invalid secondmate markers block routing and surface the obligation"
}

# A remote child route writes the existing mirror input once even across restarts.
test_remote_parent_reply_is_idempotent() {
  make_world remote; bind_secondmate remote; write_child "$MATE" child 'working: quiet since'
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
  write_child "$MATE" child 'working: quiet since' spawn-one
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  rm -f "$MATE/state/child.meta" "$MATE/state/child.status" "$MATE/state/child.turn-ended"
  write_child "$MATE" child 'working: quiet since' spawn-two
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
  write_child "$MATE" child 'working: quiet since' spawn-old
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
  write_child "$MATE" child 'working: quiet since' spawn-old
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

# The real watcher poll in a secondmate home delivers a child's terminal ledger
# line to the parent channel on its first cycle, with no line appended by the
# mate and no wake needed in the mate home for it.
test_watcher_poll_delivers_child_ledger_line_to_parent() {
  local pid i key
  make_world watcher-ledger; bind_secondmate local
  write_child "$MATE" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  prime_seen "$MATE/state" "$MATE/state/child.status"
  PATH="$WORLD/fakebin:$PATH" FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" FM_DATA_OVERRIDE="$MATE/data" \
    FM_CONFIG_OVERRIDE="$MATE/config" FM_INACTIVE_RECONCILE_SECS=60 \
    FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" FM_FORGE_LOG="$WORLD/forge.log" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_FAKE_CREW_STATE='unknown' "$WATCH" > "$WORLD/mate-watch.out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    kill -0 "$pid" 2>/dev/null || break
    grep -q 'child-outcome-child-done' "$MAIN/state/mate.status" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  reap "$pid"
  key=$(reported_outcome_key "$MATE" child 'done') || fail "watcher ledger receipt key missing"
  grep -Fxq "blocked [key=$key]: child child done: PR https://example.test/owner/repo/pull/1 checks green pr=https://example.test/owner/repo/pull/1 mode=no-mistakes yolo=off claim=unverified" \
    "$MAIN/state/mate.status" \
    || fail "the watcher poll did not deliver the child's ledger line to the parent: $(cat "$MAIN/state/mate.status" 2>/dev/null; cat "$WORLD/mate-watch.out")"
  [ ! -s "$WORLD/forge.log" ] || fail "ledger delivery invoked a forge command"
  pass "the real watcher poll delivers a child's terminal ledger line to the parent channel"
}

# A stalled authoritative state read consumes only the aggregate scan budget.
# The durable scan position lets the next invocation reach the following child.
test_stalled_state_read_is_bounded_and_scan_progresses() {
  local started elapsed
  make_world bounded
  write_child "$MAIN" a 'working: state read will stall'
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

  write_child "$MAIN" b 'done: green'
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 run_reconcile "$MAIN" --startup
  grep -Fq 'child=b state=done' "$MAIN/state/.wake-queue" \
    || fail "next bounded scan did not resume with the following child"
  pass "stalled state reads are bounded without starving later children"
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
  # fires one second after the budget; the bound proves the scan cannot ride
  # the 30-second lock hold.
  [ "$elapsed" -le 4 ] || fail "wake lock wait exceeded aggregate scan budget (${elapsed}s)"
  pass "aggregate scan budget includes durable wake operations"
}

# A secondmate home seeded without its parent binding cannot report ANY terminal
# outcome upward, and every later one fails for the same reason. The diagnostic
# has to name the binding, or three weeks of identical failures read as three
# weeks of unrelated report failures.
test_missing_parent_binding_names_itself() {
  local out
  make_world missing-binding
  printf 'mate\n' > "$MATE/.fm-secondmate-home"
  write_child "$MATE" child 'done: PR merged'
  write_child "$MATE" quiet 'working: quiet since'
  out=$(FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup)
  case "$out" in
    *"actionable: child outcome needs parent report: child=child"*".fm-secondmate-parent"*) ;;
    *) fail "a missing parent binding did not name itself for a ledger delivery: $out" ;;
  esac
  case "$out" in
    *"actionable: inactive terminal outcome needs parent report: child=quiet"*".fm-secondmate-parent"*) ;;
    *) fail "a missing parent binding did not name itself for an inactive report: $out" ;;
  esac
  [ "$(outcome_count "$MATE" reported)" = 0 ] \
    || fail "an outcome that never reached a parent was recorded as reported"
  pass "a secondmate home with no parent binding names the missing binding instead of failing quietly"
}

test_notice_recovery_does_not_duplicate_wake() {
  local record err seq generation
  make_world notice-recovery; bind_secondmate remote
  printf 'schema=fm-secondmate-parent.v1\nroute=invalid\n' > "$MATE/.fm-secondmate-parent"
  write_child "$MATE" child 'working: quiet since'
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

# Forge command shims fail loudly. A successful scan proves this path never uses
# them while reconciling a local terminal outcome.
test_reconciliation_never_calls_forge() {
  make_world forge; write_child "$MAIN" child 'done: green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ ! -s "$WORLD/forge.log" ] || fail "reconciliation invoked a forge command: $(cat "$WORLD/forge.log")"
  pass "reconciliation makes zero forge or PR API calls"
}

test_main_direct_terminal_presentation_receipt
test_local_secondmate_delivers_terminal_ledger_line
test_ledger_delivery_downgrades_an_unestablished_claim
test_a_later_established_claim_corrects_the_parents_record
test_a_keyed_phase_close_is_not_the_childs_terminal_outcome
test_busy_child_does_not_starve_later_ledger_outcomes
test_secondmate_ledger_delivery_carries_report_and_failure
test_terminal_line_during_state_read_yields_to_ledger_delivery
test_terminal_line_after_inactive_delivery_is_not_reported_twice
test_progress_after_inactive_delivery_starts_a_new_event
test_long_terminal_lines_have_distinct_receipts
test_secondmate_partial_ledger_line_waits_for_newline
test_secondmate_remote_route_ledger_delivery
test_report_subcommand_delivers_and_refuses
test_report_avoids_scan_meta_lock_inversion
test_local_secondmate_rejects_relative_parent_home
test_invalid_secondmate_marker_blocks_routing
test_remote_parent_reply_is_idempotent
test_reused_task_id_reports_each_incarnation
test_legacy_metadata_rewrite_keeps_receipt_identity
test_relaunch_cannot_replace_metadata_during_state_snapshot
test_heartbeat_cap_does_not_delay_reconciliation
test_scan_marker_replaces_symlink_safely
test_nonterminal_and_captain_held_states_do_not_report
test_watcher_hook_and_idle_secondmate_exemption
test_watcher_poll_delivers_child_ledger_line_to_parent
test_stalled_state_read_is_bounded_and_scan_progresses
test_full_scan_budget_includes_wake_lock_wait
test_notice_recovery_does_not_duplicate_wake
test_missing_parent_binding_names_itself
test_reconciliation_never_calls_forge

echo "all inactive reconciliation tests passed"
