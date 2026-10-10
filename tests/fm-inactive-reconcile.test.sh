#!/usr/bin/env bash
# Behavioral coverage for bounded inactive terminal-outcome reconciliation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECON="$ROOT/bin/fm-inactive-reconcile.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
GRANT="$ROOT/bin/fm-wake-grant.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-inactive-reconcile)
fm_git_identity fmtest fmtest@example.invalid

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
  local home=$1 id=$2 status=$3 spawn_gen=${4:-s${BASHPID:-$$}.$RANDOM} sha
  mkdir -p "$home/projects/$id"
  git -C "$home/projects/$id" init -q
  git -C "$home/projects/$id" commit -q --allow-empty -m init
  sha=$(git -C "$home/projects/$id" rev-parse HEAD)
  git -C "$home/projects/$id" update-ref refs/remotes/origin/main "$sha"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$home/projects/$id" "project=$home/projects/$id" \
    'harness=codex' 'kind=ship' 'mode=no-mistakes' 'yolo=off' \
    "spawn_gen=$spawn_gen" 'pr=https://example.test/owner/repo/pull/1' \
    "pr_head=$sha"
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

# Away-posture regression: a branch-actor drain that consumes an
# inactive-outcome check row must retire its terminal-outcome receipt exactly
# like a main ack does. The 2026-09-25 away window on the supervision host
# consumed the queue row but left the .pending receipt, so every later cadence
# scan republished the same fingerprint - the 1,734-escalation flood.
test_branch_ack_retires_inactive_outcome_receipt() {
  local err seq generation
  make_world branch-ack
  write_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "scan did not queue the terminal presentation"
  [ "$(outcome_count "$MAIN" pending)" = 1 ] || fail "scan did not retain a presentation receipt"

  # The same grant the branch dispatch publishes for this row in the away
  # posture (check rows become branch-eligible), with this test's own live
  # process as the recorded grant owner.
  seq=$(awk -F '\t' '$4 ~ /^inactive-outcome:/ { print $2 }' "$MAIN/state/.wake-queue" | tail -1)
  case "$seq" in ''|*[!0-9]*) fail "the queued inactive-outcome row had no sequence" ;; esac
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$GRANT" activate "$$" branch-ack \
    || fail "branch owner activation failed"
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$GRANT" publish branch-ack "$seq" \
    || fail "branch grant publication failed"

  err="$WORLD/branch-drain.err"
  FM_SUPERVISION_ACTOR=branch FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" \
    FM_CONFIG_OVERRIDE="$MAIN/config" "$DRAIN" >/dev/null 2> "$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$generation" ] \
    || { cat "$err"; fail "branch presentation did not require durable acknowledgement"; }
  FM_SUPERVISION_ACTOR=branch FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" \
    FM_CONFIG_OVERRIDE="$MAIN/config" "$DRAIN" --ack-through "$seq" --recovery-generation "$generation" \
    || fail "branch acknowledgement failed"

  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 0 ] || fail "branch acknowledgement left its check row queued"
  [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "branch acknowledgement left the terminal-outcome receipt pending"
  [ "$(outcome_count "$MAIN" presented)" = 1 ] || fail "branch acknowledgement never recorded the presentation receipt"

  # The flood's shape: with the receipt retired, later cadence scans must not
  # republish the same unchanged fingerprint.
  local cycle
  for cycle in 1 2 3; do
    age "$MAIN/state/.inactive-outcome-reconcile"
    FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN"
    [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 0 ] \
      || fail "unchanged inactive outcome re-queued on cadence scan $cycle after its branch acknowledgement"
  done
  pass "a branch-actor acknowledgement retires the inactive-outcome receipt and later scans stay quiet"
}

# An unpushed CI-ready ship done: is not a parent-facing ready signal. The
# ledger pass reads the child's line before any PR is recorded for it, so the
# gate tests the worker copy's HEAD.
test_unpushed_ci_ready_done_is_not_published() {
  make_world unpushed-ready; bind_secondmate local
  write_child "$MATE" child 'done: PR https://example.test/owner/repo/pull/1 checks green, risk low'
  git -C "$MATE/projects/child" commit -q --allow-empty -m 'only in the copy'
  grep -v '^pr=\|^pr_head=' "$MATE/state/child.meta" > "$MATE/state/child.meta.tmp"
  mv "$MATE/state/child.meta.tmp" "$MATE/state/child.meta"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  [ ! -s "$MAIN/state/mate.status" ] || fail "unpushed CI-ready done: was published upstream"
  [ "$(outcome_count "$MATE" reported)" = 0 ] || fail "unpushed CI-ready done: left a delivery receipt"
  pass "unpushed CI-ready ship done: is not published upstream"
}

# The ledger pass runs on every poll, so a ship done: already delivered does
# not pay for the git reachability check again.
test_delivered_ledger_done_skips_git_gate() {
  local real_git
  make_world gate-once; bind_secondmate local
  write_child "$MATE" child 'done: PR https://example.test/owner/repo/pull/2 checks green'
  real_git=$(command -v git)
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\nexec %q "$@"\n' \
    "$WORLD/git.log" "$real_git" > "$WORLD/fakebin/git"
  chmod +x "$WORLD/fakebin/git"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  [ "$(outcome_count "$MATE" reported)" = 1 ] || fail "pushed CI-ready done: was not delivered"
  [ -s "$WORLD/git.log" ] || fail "first delivery did not test the named head"
  : > "$WORLD/git.log"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  [ ! -s "$WORLD/git.log" ] || fail "a poll after delivery re-ran the git gate: $(cat "$WORLD/git.log")"
  [ "$(grep -c 'child-outcome-child-done' "$MAIN/state/mate.status")" = 1 ] \
    || fail "the delivered done: was published again"
  pass "a delivered ship done: skips the git gate on later polls"
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
  expected="done [key=$key]: child child done: PR https://example.test/owner/repo/pull/1 checks green pr=https://example.test/owner/repo/pull/1 mode=no-mistakes yolo=off"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fxq "$expected" \
    || fail "secondmate did not deliver the child's ledger line on a plain poll: $(cat "$MAIN/state/mate.status" 2>/dev/null)"
  [ "$(outcome_count "$MATE" reported)" = 1 ] || fail "ledger delivery receipt was not durable"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  [ "$(grep -c 'child-outcome-child-done' "$MAIN/state/mate.status")" = 1 ] \
    || fail "a second poll delivered the same ledger line again"
  printf 'Report at /tmp/report.md\n' >> "$MATE/state/child.status"
  age "$MATE/state/child.status"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup
  ! grep -q 'inactive-outcome-' "$MAIN/state/mate.status" \
    || fail "the inactive path reported a child the ledger delivery already owned"
  [ "$(outcome_count "$MATE" reported)" = 1 ] || fail "the inactive path minted a second receipt"
  pass "secondmate delivers a child's terminal ledger line once, on the next poll, from the ledger alone"
}

# A terminal record written as a multi-line block belongs to the ledger path
# whether the block lands before or during the state read: it is delivered once,
# under the ledger's own outcome key, and the inactive fallback stays out of it.
test_secondmate_multiline_terminal_outcome_is_delivered_once() {
  local terminal timing key
  for terminal in 'done' failed; do
    for timing in before during; do
      make_world "multiline-$terminal-$timing"; bind_secondmate local
      write_child "$MATE" child 'working: finishing validation'
      if [ "$timing" = before ]; then
        printf '%s: validation finished\nSee the report for details.\n\n' "$terminal" >> "$MATE/state/child.status"
        age "$MATE/state/child.status"
      else
        cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s: validation finished\nSee the report for details.\n\n' "$FM_FAKE_CREW_STATE" >> "$FM_STATE_OVERRIDE/$1.status"
printf 'state: %s · source: fake\n' "$FM_FAKE_CREW_STATE"
SH
      fi
      FM_FAKE_CREW_STATE="$terminal" run_reconcile "$MATE" --startup
      age "$MATE/state/child.status"
      FM_FAKE_CREW_STATE="$terminal" run_reconcile "$MATE" --startup
      run_report "$MATE" child
      key=$(reported_outcome_key "$MATE" child "$terminal") \
        || fail "$terminal with trailing prose arriving $timing state read was not owned by the ledger"
      sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" \
        | grep -Fq "$terminal [key=$key]: child child $terminal: validation finished" \
        || fail "$terminal with trailing prose arriving $timing state read was lost: $(cat "$MAIN/state/mate.status" 2>/dev/null)"
      [ "$(wc -l < "$MAIN/state/mate.status" | tr -d ' ')" = 1 ] \
        || fail "$terminal with trailing prose arriving $timing state read was delivered twice"
      [ "$(outcome_count "$MATE" reported)" = 1 ] \
        || fail "multiline $terminal outcome did not retain exactly one receipt"
    done
  done
  pass "multiline terminal outcomes are reported once before or during a state read"
}

# A child that dies mid-prose cannot hide an outcome its run already proves: an
# unterminated continuation line states no terminal event, so the inactive
# fallback still reports the attributed failure upward.
test_secondmate_unterminated_prose_reports_run_outcome() {
  make_world unterminated-prose; bind_secondmate local
  write_child "$MATE" child 'working: compiling'
  printf 'Still going' >> "$MATE/state/child.status"
  age "$MATE/state/child.status"
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" \
    | grep -Fq "failed [key=inactive-outcome-mate-child-failed]: inactive terminal child=child" \
    || fail "an unterminated prose line withheld a proven failure: $(cat "$MAIN/state/mate.status" 2>/dev/null)"
  [ "$(outcome_count "$MATE" reported)" = 1 ] || fail "the fallback report did not retain its receipt"
  age "$MATE/state/child.status"
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  [ "$(wc -l < "$MAIN/state/mate.status" | tr -d ' ')" = 1 ] \
    || fail "the proven failure was reported twice"
  pass "an unterminated continuation line does not withhold a proven child outcome"
}

# A persistent child that keeps appending routine prose after one terminal
# outcome does not mint a fresh parent event per sentence: the inactive receipt
# identity binds the incarnation, task, terminal state, and PR only, never the
# child's last status line.
test_inactive_receipt_ignores_later_status_prose() {
  make_world prose-after-outcome; bind_secondmate local
  write_child "$MATE" child 'working: quiet since'
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  [ "$(grep -c 'inactive-outcome-mate-child-failed' "$MAIN/state/mate.status")" = 1 ] \
    || fail "inactive fallback did not publish exactly once"
  printf 'working: tidying up after the run\n' >> "$MATE/state/child.status"
  age "$MATE/state/child.status"
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  printf 'working: still tidying\n' >> "$MATE/state/child.status"
  age "$MATE/state/child.status"
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  [ "$(wc -l < "$MAIN/state/mate.status" | tr -d ' ')" = 1 ] \
    || fail "changed status prose minted a duplicate parent event: $(cat "$MAIN/state/mate.status")"
  [ "$(outcome_count "$MATE" reported)" = 1 ] \
    || fail "changed status prose created a second terminal receipt"
  pass "later status prose does not change the inactive terminal receipt identity"
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
  write_child "$MATE" replaced-pr $'working: old PR https://example.test/owner/repo/pull/11\ndone: PR https://example.test/owner/repo/pull/22'
  awk '$0 !~ /^pr=/' "$MATE/state/replaced-pr.meta" > "$MATE/state/replaced-pr.meta.tmp"
  mv "$MATE/state/replaced-pr.meta.tmp" "$MATE/state/replaced-pr.meta"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  scout_key=$(reported_outcome_key "$MATE" scout 'done') || fail "scout receipt key missing"
  boom_key=$(reported_outcome_key "$MATE" boom failed) || fail "failed receipt key missing"
  replaced_key=$(reported_outcome_key "$MATE" replaced-pr 'done') || fail "replacement PR receipt key missing"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fxq "done [key=$scout_key]: child scout done: report written pr=https://example.test/owner/repo/pull/1 mode=no-mistakes yolo=off report=data/scout/report.md" \
    || fail "scout delivery lost its report pointer: $(cat "$MAIN/state/mate.status")"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fxq "failed [key=$boom_key]: child boom failed: build broke pr=https://example.test/owner/repo/pull/1 mode=no-mistakes yolo=off" \
    || fail "failed line was not delivered under the failed verb: $(cat "$MAIN/state/mate.status")"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fxq "done [key=$replaced_key]: child replaced-pr done: PR https://example.test/owner/repo/pull/22 pr=https://example.test/owner/repo/pull/22 mode=no-mistakes yolo=off" \
    || fail "ledger fallback did not prefer the terminal ready line PR: $(cat "$MAIN/state/mate.status")"
  printf 'working: retrying\ndone: fixed on retry\n' >> "$MATE/state/boom.status"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  boom_key=$(reported_outcome_key "$MATE" boom 'done') || fail "recovered receipt key missing"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fq "done [key=$boom_key]: child boom done: fixed on retry" \
    || fail "a new terminal line after recovery was not delivered"
  [ "$(grep -c 'child-outcome-boom-' "$MAIN/state/mate.status")" = 2 ] \
    || fail "recovery delivered the wrong number of lines: $(cat "$MAIN/state/mate.status")"
  pass "ledger delivery carries the report pointer, the failed verb, and each new terminal line"
}

# A PR URL a worker only ever mentioned in prose is never claimed as the
# task's delivered PR: without a recorded PR, only a terminal line in the
# ready-signal shape carries one, and a scout never carries one at all.
test_pr_field_requires_recorded_pr_or_ready_signal_line() {
  local id prose_key ready_key stamped_key placeholder_key scout_key
  make_world pr-provenance; bind_secondmate local
  write_child "$MATE" prose $'working: context in https://example.test/other/repo/pull/33\ndone: cleanup finished'
  write_child "$MATE" ready 'done: PR https://example.test/owner/repo/pull/44 checks green'
  write_child "$MATE" stamped 'done [at=1788576000]: PR https://example.test/owner/repo/pull/66 checks green'
  write_child "$MATE" placeholder 'done [at=<epoch>]: PR https://example.test/owner/repo/pull/77 checks green'
  write_child "$MATE" lookout 'done: PR https://example.test/owner/repo/pull/55'
  for id in prose ready stamped placeholder; do
    awk '$0 !~ /^pr=/' "$MATE/state/$id.meta" > "$MATE/state/$id.meta.tmp"
    mv "$MATE/state/$id.meta.tmp" "$MATE/state/$id.meta"
  done
  awk '{ sub(/^kind=ship$/, "kind=scout"); print }' "$MATE/state/lookout.meta" \
    > "$MATE/state/lookout.meta.tmp"
  mv "$MATE/state/lookout.meta.tmp" "$MATE/state/lookout.meta"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  prose_key=$(reported_outcome_key "$MATE" prose 'done') || fail "prose receipt key missing"
  ready_key=$(reported_outcome_key "$MATE" ready 'done') || fail "ready receipt key missing"
  stamped_key=$(reported_outcome_key "$MATE" stamped 'done') || fail "stamped ready receipt key missing"
  placeholder_key=$(reported_outcome_key "$MATE" placeholder 'done') \
    || fail "unsubstituted-stamp ready receipt key missing"
  scout_key=$(reported_outcome_key "$MATE" lookout 'done') || fail "scout receipt key missing"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fxq "done [key=$prose_key]: child prose done: cleanup finished mode=no-mistakes yolo=off" \
    || fail "a PR mentioned only in prose was claimed as the delivery: $(cat "$MAIN/state/mate.status")"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fxq "done [key=$ready_key]: child ready done: PR https://example.test/owner/repo/pull/44 checks green pr=https://example.test/owner/repo/pull/44 mode=no-mistakes yolo=off" \
    || fail "a ready-signal terminal line did not carry its PR: $(cat "$MAIN/state/mate.status")"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fxq "done [key=$stamped_key]: child stamped done: PR https://example.test/owner/repo/pull/66 checks green pr=https://example.test/owner/repo/pull/66 mode=no-mistakes yolo=off" \
    || fail "a stamped ready-signal terminal line did not carry its PR: $(cat "$MAIN/state/mate.status")"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fxq "done [key=$placeholder_key]: child placeholder done: PR https://example.test/owner/repo/pull/77 checks green pr=https://example.test/owner/repo/pull/77 mode=no-mistakes yolo=off" \
    || fail "a ready-signal line whose stamp was left unsubstituted lost its PR: $(cat "$MAIN/state/mate.status")"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fxq "done [key=$scout_key]: child lookout done: PR https://example.test/owner/repo/pull/55 mode=no-mistakes yolo=off" \
    || fail "a scout's ready-looking line carried a PR claim: $(cat "$MAIN/state/mate.status")"
  pass "pr= requires the recorded PR or a ready-signal terminal line, whatever its stamp, and never a scout"
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
  age "$MATE/state/child.status"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup
  [ ! -s "$MAIN/state/mate.status" ] \
    || fail "an unterminated ledger line was delivered: $(cat "$MAIN/state/mate.status")"
  printf 'ten\n' >> "$MATE/state/child.status"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  key=$(reported_outcome_key "$MATE" child 'done') || fail "completed ledger receipt key missing"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fq "done [key=$key]: child child done: half written" \
    || fail "the completed line was not delivered once its newline landed"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup
  [ "$(wc -l < "$MAIN/state/mate.status" | tr -d ' ')" = 1 ] \
    || fail "completing the partial line delivered the outcome twice"
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

# A ship done: the gate accepted stays owed while its parent write is pending.
# Teardown removes the worktree before `report`, so the retry delivers that
# line instead of re-testing a copy that no longer exists.
test_pending_ledger_done_is_delivered_after_worktree_removal() {
  local key
  make_world pending-retry; bind_secondmate local
  write_child "$MATE" child 'done: PR https://example.test/owner/repo/pull/2 checks green'
  cp "$MATE/.fm-secondmate-parent" "$WORLD/parent-binding"
  printf 'schema=fm-secondmate-parent.v1\nroute=invalid\n' > "$MATE/.fm-secondmate-parent"
  FM_FAKE_CREW_STATE='unknown' run_reconcile "$MATE"
  [ "$(outcome_count "$MATE" pending)" = 1 ] || fail "failed parent write did not leave a pending delivery"
  rm -rf "$MATE/projects/child"
  cp "$WORLD/parent-binding" "$MATE/.fm-secondmate-parent"
  run_report "$MATE" child || fail "report refused the pending delivery"
  key=$(reported_outcome_key "$MATE" child 'done') || fail "pending delivery was dropped instead of reported"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fq "done [key=$key]: child child done: PR https://example.test/owner/repo/pull/2 checks green" \
    || fail "report did not deliver the pending done after the worktree was removed"
  pass "a pending ship done: is delivered by report after teardown removed the worktree"
}

# `report <child>` is the teardown-side delivery: it delivers or says nothing
# is owed with 0, and returns non-zero only when the channel cannot be written.
test_report_subcommand_delivers_and_refuses() {
  local rc key
  make_world report; bind_secondmate local
  write_child "$MATE" child 'done: final word'
  run_report "$MATE" child || fail "report refused a deliverable ledger line"
  key=$(reported_outcome_key "$MATE" child 'done') || fail "report receipt key missing"
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fq "done [key=$key]: child child done: final word" \
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
  sed -E 's/ \[at=[0-9]+\]//' "$MAIN/state/mate.status" | grep -Fxq "done [key=$key]: child child done: PR https://example.test/owner/repo/pull/1 checks green pr=https://example.test/owner/repo/pull/1 mode=no-mistakes yolo=off" \
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

test_reconciliation_sets_no_forge_mode_for_state_read() {
  make_world no-forge-env; write_child "$MAIN" child 'working: quiet since'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_CREW_STATE_NO_FORGE:-}" > "${FM_NO_FORGE_LOG:?}"
printf 'state: done · source: fake\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  export FM_NO_FORGE_LOG="$WORLD/no-forge.log"
  run_reconcile "$MAIN" --startup
  unset FM_NO_FORGE_LOG
  assert_grep '1' "$WORLD/no-forge.log" "inactive reconciliation did not set crew-state no-forge mode"
  pass "reconciliation state reads set no-forge mode"
}

test_main_direct_terminal_presentation_receipt
test_branch_ack_retires_inactive_outcome_receipt
test_unpushed_ci_ready_done_is_not_published
test_delivered_ledger_done_skips_git_gate
test_local_secondmate_delivers_terminal_ledger_line
test_secondmate_multiline_terminal_outcome_is_delivered_once
test_secondmate_unterminated_prose_reports_run_outcome
test_inactive_receipt_ignores_later_status_prose
test_busy_child_does_not_starve_later_ledger_outcomes
test_secondmate_ledger_delivery_carries_report_and_failure
test_pr_field_requires_recorded_pr_or_ready_signal_line
test_terminal_line_during_state_read_yields_to_ledger_delivery
test_terminal_line_after_inactive_delivery_is_not_reported_twice
test_progress_after_inactive_delivery_starts_a_new_event
test_long_terminal_lines_have_distinct_receipts
test_secondmate_partial_ledger_line_waits_for_newline
test_secondmate_remote_route_ledger_delivery
test_report_subcommand_delivers_and_refuses
test_pending_ledger_done_is_delivered_after_worktree_removal
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
test_reconciliation_sets_no_forge_mode_for_state_read

# Idle-after-handoff records. The clock is the reconcile override, so a stamped
# completion can be old while file mtimes stay in the future and the slower
# terminal cadence does not also call current-state.
HANDOFF_NOW=1700000180
HANDOFF_OLD=1700000000
HANDOFF_CONT=1700000160
HANDOFF_YOUNG=1700000100

handoff_field() { # <record> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-
}

handoff_wake_count() { # <home>
  local n
  n=$(grep -c 'handoff-idle-' "$1/state/.wake-queue" 2>/dev/null || true)
  printf '%s\n' "${n:-0}"
}

one_record() { # <home> <task>
  local record found=
  for record in "$1/state/handoff-continuations"/*.record; do
    [ -f "$record" ] || continue
    [ "$(handoff_field "$record" task_id)" = "$2" ] || continue
    if [ -n "$found" ]; then
      return 2
    fi
    found=$record
  done
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

records_for() { # <home> <task>
  local record
  for record in "$1/state/handoff-continuations"/*.record; do
    [ -f "$record" ] || continue
    [ "$(handoff_field "$record" task_id)" = "$2" ] || continue
    printf '%s\n' "$record"
  done
}

records_for_count() { # <home> <task>
  records_for "$1" "$2" | wc -l | tr -d ' '
}

drop_handoff_wakes() { # <home>
  local queue="$1/state/.wake-queue"
  [ -f "$queue" ] || return 0
  grep -v 'handoff-idle-' "$queue" > "$queue.kept" || true
  mv "$queue.kept" "$queue"
}

set_record_field() { # <record> <key> <value>
  awk -v key="$2" -v value="$3" '
    index($0, key "=") == 1 { print key "=" value; next }
    { print }
  ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

install_handoff_fakes() {
  local tool
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$WORLD/crew-state.log"
printf 'state: %s · source: %s%s\n' "\${FM_FAKE_CREW_STATE:-unknown}" "\${FM_FAKE_CREW_SOURCE:-fake}" "\${FM_FAKE_CREW_DETAIL:+ · \$FM_FAKE_CREW_DETAIL}"
EOF
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  for tool in no-mistakes fm-send; do
    cat > "$WORLD/fakebin/$tool" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0")" >> "${FM_FORGE_LOG:?}"
exit 97
EOF
    chmod +x "$WORLD/fakebin/$tool"
  done
}

scan_handoff() { # <home>
  FM_INACTIVE_RECONCILE_NOW=$HANDOFF_NOW FM_HANDOFF_IDLE_SECS=180 run_reconcile "$1"
}

test_handoff_idle_records_the_episode_and_alerts_once() {
  local name home record fp8 key line
  line="needs-validation [at=$HANDOFF_OLD]: committed c118078, 706 tests"
  make_world handoff-alert
  install_handoff_fakes
  mkdir -p "$WORLD/harbor"/{state,data,config,projects} "$WORLD/keel"/{state,data,config,projects}
  : > "$WORLD/crew-state.log"
  for name in main harbor keel; do
    if [ "$name" = main ]; then
      home=$MAIN
    else
      home="$WORLD/$name"
      printf '%s\n' "$name" > "$home/.fm-secondmate-home"
    fi
    write_child "$home" intake "$line" "inc-$name-1"
    scan_handoff "$home"
    record=$(one_record "$home" intake) || fail "$name: handoff record missing"
    [ "$(handoff_field "$record" schema)" = fm-handoff-continuation.v1 ] \
      || fail "$name: record schema drifted: $(cat "$record")"
    [ "$(handoff_field "$record" incarnation)" = "inc-$name-1" ] \
      || fail "$name: record lost the incarnation"
    [ "$(handoff_field "$record" completion_line)" = "$line" ] \
      || fail "$name: record changed the completion line"
    [ "$(handoff_field "$record" observed_epoch)" = "$HANDOFF_OLD" ] \
      || fail "$name: record did not keep the completion stamp"
    [ "$(handoff_field "$record" bound_secs)" = 180 ] || fail "$name: record bound was not 180"
    [ "$(handoff_field "$record" alerted)" = 1 ] || fail "$name: the alert was not recorded"
    [ -n "$(handoff_field "$record" last_alert_epoch)" ] || fail "$name: alert time was not recorded"
    [ -z "$(handoff_field "$record" cleared_epoch)" ] || fail "$name: the alert cleared the episode"
    fp8=$(basename "$record" .record)
    key="handoff-idle-intake-${fp8:0:8}"
    grep -Fq "$key" "$home/state/.wake-queue" || fail "$name: wake key $key missing"
    grep -Fq "check: handoff idle: task=intake still needs a supervisor continuation after 180s" \
      "$home/state/.wake-queue" || fail "$name: wake payload drifted"
    [ "$(handoff_wake_count "$home")" = 1 ] || fail "$name: first scan queued more than one handoff check"
    grep -Fxq "$fp8" "$home/state/handoff-continuations/intake.open" \
      || fail "$name: the open marker was not written at first observation"

    scan_handoff "$home"
    [ "$(handoff_wake_count "$home")" = 1 ] || fail "$name: a queued check was sent again"
    [ "$(records_for_count "$home" intake)" = 1 ] || fail "$name: a rescan minted a second episode"

    drop_handoff_wakes "$home"
    scan_handoff "$home"
    [ "$(handoff_wake_count "$home")" = 0 ] \
      || fail "$name: a consumed check was requeued inside the bound"
    [ -f "$home/state/handoff-continuations/intake.open" ] \
      || fail "$name: consuming the check retired the episode"

    set_record_field "$record" last_alert_epoch 1
    scan_handoff "$home"
    [ "$(handoff_wake_count "$home")" = 1 ] \
      || fail "$name: an elapsed bound after a consumed check did not requeue"
    [ "$(records_for_count "$home" intake)" = 1 ] || fail "$name: the requeue minted a second episode"
  done

  write_child "$MAIN" quiet "needs-validation [at=$HANDOFF_YOUNG]: committed c118078, 706 tests" inc-quiet-1
  scan_handoff "$MAIN"
  record=$(one_record "$MAIN" quiet) || fail "a young handoff was not recorded"
  [ "$(handoff_field "$record" alerted)" = 0 ] || fail "a young handoff alerted before the bound"
  [ -f "$MAIN/state/handoff-continuations/quiet.open" ] \
    || fail "a young handoff did not get its marker at first observation"
  grep -q 'handoff-idle-quiet-' "$MAIN/state/.wake-queue" \
    && fail "a young handoff queued a check"
  grep -qx quiet "$WORLD/crew-state.log" \
    || fail "current state was not read before the handoff bound"
  [ ! -s "$WORLD/forge.log" ] || fail "handoff reconciliation invoked a forge or send command: $(cat "$WORLD/forge.log")"
  pass "an idle handoff is one durable episode per home, alerted once until its check is consumed and the bound elapses again"
}

test_handoff_idle_records_early_attributed_continuation_latency() {
  local home record saved_now=$HANDOFF_NOW
  make_world handoff-early-continuation
  install_handoff_fakes
  home=$MAIN
  write_child "$home" intake "needs-validation [at=$HANDOFF_OLD]: committed c118078, 706 tests" inc-early-1
  HANDOFF_NOW=$HANDOFF_OLD
  FM_FAKE_CREW_SOURCE=fake FM_FAKE_CREW_STATE=working scan_handoff "$home"
  record=$(one_record "$home" intake) || fail "the young handoff was not recorded"
  [ -z "$(handoff_field "$record" cleared_epoch)" ] \
    || fail "a young handoff without continuation evidence cleared"
  [ "$(handoff_field "$record" alerted)" = 0 ] \
    || fail "a young handoff without continuation evidence alerted"

  HANDOFF_NOW=$((HANDOFF_OLD + 69))
  FM_FAKE_CREW_SOURCE=run-step FM_FAKE_CREW_STATE=working scan_handoff "$home"
  HANDOFF_NOW=$saved_now
  [ "$(handoff_field "$record" clear_reason)" = run-step ] \
    || fail "an attributed validation run did not clear the handoff"
  [ "$(handoff_field "$record" latency_secs)" = 69 ] \
    || fail "early continuation latency was not recorded at first observation"
  [ "$(handoff_wake_count "$home")" = 0 ] \
    || fail "an early attributed continuation queued an idle alert"
  [ ! -e "$home/state/handoff-continuations/intake.open" ] \
    || fail "an early attributed continuation left the handoff open"
  pass "an attributed validation run clears a young handoff with observed latency"
}

test_handoff_idle_rejects_terminal_run_step_evidence() {
  local home state record
  for state in failed 'done'; do
    make_world "handoff-terminal-run-step-$state"
    install_handoff_fakes
    home=$MAIN
    write_child "$home" intake "needs-validation [at=$HANDOFF_OLD]: committed c118078, 706 tests" "inc-terminal-run-step-$state"
    FM_FAKE_CREW_SOURCE=run-step FM_FAKE_CREW_STATE=$state scan_handoff "$home"
    record=$(one_record "$home" intake) || fail "$state run-step did not retain the handoff record"
    [ -z "$(handoff_field "$record" cleared_epoch)" ] \
      || fail "$state run-step cleared a handoff without active continuation"
    [ -f "$home/state/handoff-continuations/intake.open" ] \
      || fail "$state run-step retired the handoff marker"
  done
  pass "failed and completed run-step states do not clear handoffs"
}

test_handoff_idle_accepts_verified_parked_run_step_waits() {
  local home wait record
  for wait in awaiting_approval fix_review review; do
    make_world "handoff-parked-run-step-$wait"
    install_handoff_fakes
    home=$MAIN
    write_child "$home" intake "needs-validation [at=$HANDOFF_OLD]: committed c118078, 706 tests" "inc-parked-run-step-$wait"
    FM_FAKE_CREW_SOURCE=run-step FM_FAKE_CREW_STATE=parked FM_FAKE_CREW_DETAIL="parked at $wait" scan_handoff "$home"
    record=$(one_record "$home" intake) || fail "$wait parked run-step did not retain the handoff record"
    [ "$(handoff_field "$record" clear_reason)" = run-step ] || fail "$wait parked run-step did not clear the handoff as continuation"
    [ "$(handoff_wake_count "$home")" = 0 ] || fail "$wait parked run-step queued an idle alert"
    [ ! -e "$home/state/handoff-continuations/intake.open" ] || fail "$wait parked run-step retained the handoff marker"
  done
  pass "verified parked approval, fix-review, and gate waits clear handoffs"
}

test_handoff_idle_fails_closed_when_continuation_predicate_is_unreadable() {
  local home rc lock
  make_world handoff-unreadable-continuation
  install_handoff_fakes
  home=$MAIN
  write_child "$home" intake $'needs-validation [at=1700000000]: committed c118078, 706 tests\nworking [at=1700000160]: validation started\nneeds-decision [at=1700000161]: held for a decision' inc-unreadable-1
  cat > "$WORLD/fakebin/node" <<'EOF'
#!/usr/bin/env bash
exit 98
EOF
  chmod +x "$WORLD/fakebin/node"
  rc=0
  scan_handoff "$home" || rc=$?
  [ "$rc" -ne 0 ] || fail "an unreadable continuation predicate let the scan succeed"
  lock=$(FM_STATE_OVERRIDE="$home/state" bash -c '. "$1"; fm_meta_lock_path "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state/intake.meta") \
    || fail "could not resolve the task lock"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_lock_try_acquire "$2" || exit 1
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" \
    || fail "the failed continuation read left the task lock held"
  pass "an unreadable continuation predicate fails the scan after releasing its task lock"
}

test_handoff_idle_generic_line_does_not_read_the_predicate() {
  local home record rc fp
  make_world handoff-generic-no-predicate
  install_handoff_fakes
  home=$MAIN
  write_child "$home" intake $'needs-validation [at=1700000000]: committed c118078, 706 tests\nworking [at=1700000160]: validation started\npaused [at=1700000161]: still waiting' inc-generic-1
  cat > "$WORLD/fakebin/node" <<'EOF'
#!/usr/bin/env bash
exit 98
EOF
  chmod +x "$WORLD/fakebin/node"
  rc=0
  scan_handoff "$home" || rc=$?
  [ "$rc" -eq 0 ] || fail "a generic status line required the continuation predicate: rc=$rc"
  record=$(one_record "$home" intake) || fail "the handoff was not recorded"
  [ -z "$(handoff_field "$record" cleared_epoch)" ] \
    || fail "a generic status line cleared the handoff"
  fp=$(basename "$record" .record)
  grep -Fxq "$fp" "$home/state/handoff-continuations/intake.open" \
    || fail "a generic status line retired the open handoff marker"
  pass "a generic working or paused line leaves the handoff open without reading the continuation predicate"
}

test_handoff_idle_survives_a_replaced_status_log() {
  local home record fp8 key
  make_world handoff-replaced-status
  install_handoff_fakes
  home=$MAIN
  write_child "$home" intake "needs-validation [at=$HANDOFF_OLD]: committed c118078, 706 tests" inc-replaced-1
  scan_handoff "$home"
  record=$(one_record "$home" intake) || fail "the original handoff was not recorded"
  fp8=$(basename "$record" .record)
  key="handoff-idle-intake-${fp8:0:8}"
  printf '%s\n' "working [at=$HANDOFF_CONT]: status log replaced" > "$home/state/intake.status"
  scan_handoff "$home"
  [ -f "$record" ] || fail "a replaced status log removed the durable handoff record"
  [ -z "$(handoff_field "$record" cleared_epoch)" ] \
    || fail "a generic replacement status cleared the handoff"
  grep -Fxq "$fp8" "$home/state/handoff-continuations/intake.open" \
    || fail "a replaced status log retired the open handoff marker"
  grep -Fq "$key" "$home/state/.wake-queue" \
    || fail "a replaced status log retired the idle alert"
  FM_FAKE_CREW_SOURCE=run-step FM_FAKE_CREW_STATE=working scan_handoff "$home"
  [ "$(handoff_field "$record" clear_reason)" = run-step ] \
    || fail "attributed continuation did not clear the retained handoff"
  [ ! -e "$home/state/handoff-continuations/intake.open" ] \
    || fail "positive continuation left the retained handoff open"
  pass "a replaced status log preserves a handoff until attributed continuation"
}

test_handoff_idle_replay_keeps_later_completion_open() {
  local home first second record first_record='' second_record='' fp8 key
  make_world handoff-replay-order
  install_handoff_fakes
  home=$MAIN
  first="needs-validation [at=$HANDOFF_OLD]: committed c118078, 706 tests"
  second="needs-validation [at=$HANDOFF_OLD]: committed c118079, 707 tests"
  write_child "$home" intake "$first" inc-replay-1
  printf '%s\n%s\n%s\n' \
    "$first" \
    "needs-decision [at=$HANDOFF_CONT] [key=hold]: an explicit hold" \
    "$second" \
    > "$home/state/intake.status"
  scan_handoff "$home"
  while IFS= read -r record; do
    case "$(handoff_field "$record" completion_line)" in
      "$first") first_record=$record ;;
      "$second") second_record=$record ;;
    esac
  done < <(records_for "$home" intake)
  [ -n "$first_record" ] || fail "the earlier completion was not recorded"
  [ -n "$second_record" ] || fail "the later completion was not recorded"
  [ "$(handoff_field "$first_record" clear_reason)" = status:needs-decision ] \
    || fail "the explicit hold did not clear the earlier completion"
  [ -z "$(handoff_field "$second_record" cleared_epoch)" ] \
    || fail "the first replay scan cleared the later completion"

  scan_handoff "$home"
  [ -z "$(handoff_field "$second_record" cleared_epoch)" ] \
    || fail "a historical hold cleared the later completion on replay"
  fp8=$(basename "$second_record" .record)
  key="handoff-idle-intake-${fp8:0:8}"
  grep -Fxq "$fp8" "$home/state/handoff-continuations/intake.open" \
    || fail "a replayed hold retired the later completion marker"
  grep -Fq "$key" "$home/state/.wake-queue" \
    || fail "the later completion did not remain eligible for an idle alert"
  pass "status replay clears only completions pending at the continuation line"
}

test_handoff_idle_records_repeated_identical_completions() {
  local home completion record first_record='' second_record='' fp8 key
  make_world handoff-repeated-completion
  install_handoff_fakes
  home=$MAIN
  completion="needs-validation [at=$HANDOFF_OLD]: committed c118078, 706 tests"
  write_child "$home" intake "$completion" inc-repeated-1
  printf '%s\n%s\n' \
    "$completion" \
    "needs-decision [at=$HANDOFF_CONT] [key=hold]: an explicit hold" \
    > "$home/state/intake.status"
  scan_handoff "$home"
  printf '%s\n' "$completion" >> "$home/state/intake.status"
  scan_handoff "$home"

  while IFS= read -r record; do
    if [ -z "$(handoff_field "$record" cleared_epoch)" ]; then
      second_record=$record
    else
      first_record=$record
    fi
  done < <(records_for "$home" intake)
  [ "$(records_for_count "$home" intake)" = 2 ] \
    || fail "two identical completion events did not keep separate records"
  [ -n "$first_record" ] || fail "the held completion record was missing"
  [ "$(handoff_field "$first_record" clear_reason)" = status:needs-decision ] \
    || fail "the explicit hold did not clear the first completion"
  [ -n "$second_record" ] || fail "the repeated completion did not create an open record"
  [ -z "$(handoff_field "$second_record" cleared_epoch)" ] \
    || fail "the repeated completion inherited the earlier clear"
  fp8=$(basename "$second_record" .record)
  key="handoff-idle-intake-${fp8:0:8}"
  grep -Fxq "$fp8" "$home/state/handoff-continuations/intake.open" \
    || fail "the repeated completion did not own the open marker"
  grep -Fq "$key" "$home/state/.wake-queue" \
    || fail "the repeated completion did not receive an idle alert"
  pass "each identical completion occurrence retains its own handoff"
}

test_handoff_idle_keeps_new_event_after_duplicate_compaction() {
  local home note first second third record saved_now=$HANDOFF_NOW
  make_world handoff-compacted-event-identity
  install_handoff_fakes
  home=$MAIN
  note="committed c118078, 706 tests"
  first="needs-validation [at=$HANDOFF_OLD] [event=11111111111111111111111111111111]: $note"
  second="needs-validation [at=$HANDOFF_OLD] [event=22222222222222222222222222222222]: $note"
  third="needs-validation [at=$HANDOFF_OLD] [event=33333333333333333333333333333333]: $note"
  write_child "$home" intake "$first"$'\n'"$second" inc-compacted-event-identity-1
  HANDOFF_NOW=$HANDOFF_OLD
  scan_handoff "$home"
  HANDOFF_NOW=$saved_now
  printf '%s\n' "$second" > "$home/state/intake.status"
  scan_handoff "$home"
  printf '%s\n' "$third" >> "$home/state/intake.status"
  scan_handoff "$home"
  [ "$(records_for_count "$home" intake)" = 3 ] \
    || fail "a new event after duplicate compaction reused an older handoff record"
  while IFS= read -r record; do
    case "$(handoff_field "$record" completion_event_id)" in
      11111111111111111111111111111111|22222222222222222222222222222222|33333333333333333333333333333333) ;;
      *) fail "a handoff record lost its event identity" ;;
    esac
  done < <(records_for "$home" intake)
  [ "$(handoff_wake_count "$home")" = 3 ] \
    || fail "the new event after duplicate compaction did not receive its own idle check"
  pass "a new event after duplicate compaction keeps its own handoff"
}

test_handoff_idle_reconciles_a_compacted_completion() {
  local home completion record fp8 key
  make_world handoff-compacted-completion
  install_handoff_fakes
  home=$MAIN
  completion="needs-validation [at=$HANDOFF_OLD]: committed c118078, 706 tests"
  write_child "$home" intake $'working [at=1699999999]: preparing validation\n'"$completion" inc-compacted-1
  scan_handoff "$home"
  record=$(one_record "$home" intake) || fail "the original compactable handoff was not recorded"
  fp8=$(basename "$record" .record)
  key="handoff-idle-intake-${fp8:0:8}"
  printf '%s\n' "$completion" > "$home/state/intake.status"
  scan_handoff "$home"
  [ "$(records_for_count "$home" intake)" = 1 ] \
    || fail "compaction created a duplicate handoff record"
  [ -f "$record" ] || fail "compaction replaced the original handoff record"
  grep -Fxq "$fp8" "$home/state/handoff-continuations/intake.open" \
    || fail "compaction changed the open handoff marker"
  [ "$(handoff_wake_count "$home")" = 1 ] \
    || fail "compaction created a second idle handoff check"
  grep -Fq "$key" "$home/state/.wake-queue" \
    || fail "compaction retired the original idle handoff check"
  pass "a compacted completion keeps one durable handoff episode"
}

test_handoff_idle_distinguishes_compacted_long_completions() {
  local home prefix common first second first_record second_record record display
  make_world handoff-compacted-long-completions
  install_handoff_fakes
  home=$MAIN
  prefix="needs-validation [at=$HANDOFF_OLD]: committed "
  common=$(printf '%*s' 1300 '' | tr ' ' x)
  first="${prefix}${common}A"
  second="${prefix}${common}B"
  write_child "$home" intake "$first" inc-compacted-long-1
  scan_handoff "$home"
  first_record=$(one_record "$home" intake) || fail "the first long completion was not recorded"
  printf '%s\n' "$second" > "$home/state/intake.status"
  scan_handoff "$home"
  [ "$(records_for_count "$home" intake)" = 2 ] \
    || fail "compacted long completions sharing a display field collapsed into one record"
  second_record=
  while IFS= read -r record; do
    [ "$record" = "$first_record" ] || second_record=$record
  done < <(records_for "$home" intake)
  [ -n "$second_record" ] || fail "the later long completion did not create its own record"
  display=$(handoff_field "$first_record" completion_line)
  [ "${#display}" = 1200 ] || fail "the bounded completion display changed length"
  [ "$display" = "$(handoff_field "$second_record" completion_line)" ] \
    || fail "the fixture did not retain the same bounded display for both completions"
  [ "$(handoff_field "$first_record" completion_digest)" != "$(handoff_field "$second_record" completion_digest)" ] \
    || fail "distinct full completion lines shared a durable digest"
  [ "$(handoff_wake_count "$home")" = 2 ] \
    || fail "the later long completion did not receive its own idle alert"
  pass "compaction keeps distinct long completion handoffs separate"
}

test_handoff_idle_compacted_duplicate_hold_clears_pending() {
  local home completion record saved_now=$HANDOFF_NOW
  make_world handoff-compacted-duplicates
  install_handoff_fakes
  home=$MAIN
  completion="needs-validation [at=$HANDOFF_OLD]: committed c118078, 706 tests"
  write_child "$home" intake $'working [at=1699999999]: preparing validation\n'"$completion"$'\n'"$completion" inc-compacted-duplicates-1
  HANDOFF_NOW=$HANDOFF_OLD
  scan_handoff "$home"
  HANDOFF_NOW=$saved_now
  [ "$(records_for_count "$home" intake)" = 2 ] \
    || fail "identical completions did not retain separate pending records"
  printf '%s\n%s\n' \
    "$completion" \
    "needs-decision [at=$HANDOFF_CONT] [key=hold]: an explicit hold" \
    > "$home/state/intake.status"
  scan_handoff "$home"
  while IFS= read -r record; do
    [ -n "$(handoff_field "$record" cleared_epoch)" ] \
      || fail "the compacted hold did not clear every earlier identical completion"
    [ "$(handoff_field "$record" clear_reason)" = status:needs-decision ] \
      || fail "the compacted hold recorded the wrong continuation reason"
  done < <(records_for "$home" intake)
  [ ! -e "$home/state/handoff-continuations/intake.open" ] \
    || fail "the compacted hold left the task handoff marker open"
  [ "$(handoff_wake_count "$home")" = 0 ] \
    || fail "the compacted hold queued a false idle handoff check"
  pass "a compacted hold clears pending identical handoffs"
}

test_handoff_idle_compacted_distinct_hold_clears_earlier() {
  local home record first second saved_now=$HANDOFF_NOW
  make_world handoff-compacted-distinct
  install_handoff_fakes
  home=$MAIN
  first="needs-validation [at=$HANDOFF_OLD]: commit A"
  second="needs-validation [at=$HANDOFF_CONT]: commit B"
  write_child "$home" intake "$first"$'\n'"$second" inc-compacted-distinct-1
  HANDOFF_NOW=$HANDOFF_OLD
  scan_handoff "$home"
  HANDOFF_NOW=$saved_now
  [ "$(records_for_count "$home" intake)" = 2 ] \
    || fail "distinct completions did not retain separate pending records"
  printf '%s\n%s\n' \
    "$second" \
    "needs-decision [at=$HANDOFF_NOW] [key=hold]: an explicit hold" \
    > "$home/state/intake.status"
  scan_handoff "$home"
  while IFS= read -r record; do
    [ -n "$(handoff_field "$record" cleared_epoch)" ] \
      || fail "the compacted hold did not clear both distinct completions"
    [ "$(handoff_field "$record" clear_reason)" = status:needs-decision ] \
      || fail "the compacted hold recorded the wrong continuation reason"
  done < <(records_for "$home" intake)
  [ ! -e "$home/state/handoff-continuations/intake.open" ] \
    || fail "the compacted hold left the task handoff marker open"
  [ "$(handoff_wake_count "$home")" = 0 ] \
    || fail "the compacted hold queued a false idle handoff check"
  pass "a compacted hold clears an earlier distinct completion"
}

test_handoff_idle_compacted_duplicate_hold_without_prefix_clears_pending() {
  local home completion record saved_now=$HANDOFF_NOW
  make_world handoff-compacted-duplicates-without-prefix
  install_handoff_fakes
  home=$MAIN
  completion="needs-validation [at=$HANDOFF_OLD]: committed c118078, 706 tests"
  write_child "$home" intake "$completion"$'\n'"$completion" inc-compacted-duplicates-without-prefix-1
  HANDOFF_NOW=$HANDOFF_OLD
  scan_handoff "$home"
  HANDOFF_NOW=$saved_now
  [ "$(records_for_count "$home" intake)" = 2 ] \
    || fail "identical completions without a prefix did not retain separate records"
  printf '%s\n%s\n' \
    "$completion" \
    "needs-decision [at=$HANDOFF_CONT] [key=hold]: an explicit hold" \
    > "$home/state/intake.status"
  scan_handoff "$home"
  while IFS= read -r record; do
    [ -n "$(handoff_field "$record" cleared_epoch)" ] \
      || fail "the no-prefix compacted hold did not clear every pending completion"
  done < <(records_for "$home" intake)
  [ ! -e "$home/state/handoff-continuations/intake.open" ] \
    || fail "the no-prefix compacted hold left the task handoff marker open"
  [ "$(handoff_wake_count "$home")" = 0 ] \
    || fail "the no-prefix compacted hold queued a false idle handoff check"
  pass "a no-prefix compacted hold clears pending identical handoffs"
}

test_handoff_idle_cursor_reaches_later_tasks_after_budget_exhaustion() {
  local home real_date record fp8 id
  make_world handoff-cursor
  install_handoff_fakes
  home=$MAIN
  for id in a b c; do
    write_child "$home" "$id" "needs-validation [at=$HANDOFF_OLD]: committed $id" "inc-$id-1"
  done
  real_date=$(command -v date)
  printf '100\n' > "$WORLD/handoff-clock"
  cat > "$WORLD/fakebin/date" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = +%s ]; then
  cat "\${FM_HANDOFF_CLOCK:?}"
else
  exec "$real_date" "\$@"
fi
EOF
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FM_HANDOFF_CREW_LOG:?}"
case "$1" in
  a|b)
    now=$(cat "${FM_HANDOFF_CLOCK:?}")
    printf '%s\n' "$((now + 5))" > "${FM_HANDOFF_CLOCK:?}"
    ;;
esac
printf 'state: working · source: fake\n'
EOF
  chmod +x "$WORLD/fakebin/date" "$WORLD/fakebin/fm-crew-state.sh"
  : > "$WORLD/handoff-crew.log"
  FM_HANDOFF_CLOCK="$WORLD/handoff-clock" FM_HANDOFF_CREW_LOG="$WORLD/handoff-crew.log" \
    FM_INACTIVE_RECONCILE_BUDGET_SECS=10 scan_handoff "$home"
  [ "$(records_for_count "$home" c)" = 0 ] \
    || fail "the later handoff was reached before the simulated budget was exhausted"
  [ "$(handoff_field "$home/state/handoff-continuations/.cursor" cursor)" = a ] \
    || fail "the exhausted handoff pass did not persist the last visited task"
  FM_HANDOFF_CLOCK="$WORLD/handoff-clock" FM_HANDOFF_CREW_LOG="$WORLD/handoff-crew.log" \
    FM_INACTIVE_RECONCILE_BUDGET_SECS=10 scan_handoff "$home"
  record=$(one_record "$home" c) || fail "the later handoff was starved after a bounded scan"
  fp8=$(basename "$record" .record)
  grep -Fq "handoff-idle-c-${fp8:0:8}" "$home/state/.wake-queue" \
    || fail "the later handoff did not receive its idle check"
  [ -z "$(handoff_field "$home/state/handoff-continuations/.cursor" cursor)" ] \
    || fail "the handoff cursor remained after a complete traversal"
  pass "a bounded handoff scan resumes after its durable cursor"
}

test_handoff_reserves_time_for_a_terminal_outcome() {
  local home real_date clock_start
  make_world handoff-terminal-reserve
  install_handoff_fakes
  home=$MAIN
  for id in a b c; do
    write_child "$home" "$id" "needs-validation [at=$HANDOFF_OLD]: committed $id" "inc-$id-1"
  done
  write_child "$home" terminal 'done: green' inc-terminal-1
  real_date=$(command -v date)
  clock_start=$(date +%s)
  printf '%s\n' "$clock_start" > "$WORLD/handoff-clock"
  printf 'epoch=%s\ncursor=c\n' "$clock_start" > "$home/state/.inactive-outcome-reconcile"
  cat > "$WORLD/fakebin/date" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = +%s ]; then
  cat "\${FM_HANDOFF_CLOCK:?}"
else
  exec "$real_date" "\$@"
fi
EOF
  cat > "$WORLD/fakebin/timeout" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -k ] || exit 2
shift 2
seconds=$1
shift
id=${!#}
if [ "$id" = terminal ] && [ "$seconds" -lt 5 ]; then
  exit 124
fi
exec "$@"
EOF
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  a|b|c)
    now=$(cat "${FM_HANDOFF_CLOCK:?}")
    printf '%s\n' "$((now + 5))" > "${FM_HANDOFF_CLOCK:?}"
    printf 'state: working · source: fake\n'
    ;;
  terminal) printf 'state: done · source: fake\n' ;;
  *) printf 'state: working · source: fake\n' ;;
esac
EOF
  chmod +x "$WORLD/fakebin/date" "$WORLD/fakebin/timeout" "$WORLD/fakebin/fm-crew-state.sh"
  FM_HANDOFF_CLOCK="$WORLD/handoff-clock" FM_INACTIVE_RECONCILE_BUDGET_SECS=10 \
    run_reconcile "$home" --startup
  grep -Fq 'child=terminal state=done' "$home/state/.wake-queue" \
    || fail "a slow handoff pass starved the terminal outcome"
  pass "handoff reconciliation reserves a bounded terminal-outcome read"
}

test_handoff_idle_clears_only_on_continuation() {
  local home record before after verb uncleared
  local completion="needs-validation [at=$HANDOFF_OLD]: committed c118078, 706 tests"
  make_world handoff-clear
  install_handoff_fakes
  home=$MAIN
  write_child "$home" intake "$completion" inc-clear-1
  mkdir -p "$home/state/intake.inbox" "$home/state/terminal-outcomes"
  printf 'doorbell\n' > "$home/state/intake.inbox/001.msg"
  printf 'task_id=intake\nstate=done\n' > "$home/state/terminal-outcomes/old.reported"
  printf '%s\n' '{"verdict":"routine","summary":"implementation done"}' > "$home/state/branch-outcomes.jsonl"
  printf '%s\n%s\n%s\n' \
    "$completion" \
    "note [at=$HANDOFF_CONT]: parent already has the receipt" \
    "resolved [at=$HANDOFF_CONT]: closed a different question" \
    > "$home/state/intake.status"
  scan_handoff "$home"
  record=$(one_record "$home" intake) || fail "noise retired the handoff before any continuation"
  [ -z "$(handoff_field "$record" cleared_epoch)" ] \
    || fail "a note, resolve, inbox, receipt, or routine outcome cleared the handoff"
  [ -f "$home/state/handoff-continuations/intake.open" ] || fail "an open handoff lost its marker"

  fp8=$(basename "$record" .record)
  key="handoff-idle-intake-${fp8:0:8}"
  printf '%s\n' "working [at=$HANDOFF_CONT]: validation started" >> "$home/state/intake.status"
  printf '%s\n' "paused [at=$HANDOFF_CONT]: waiting on a review" >> "$home/state/intake.status"
  scan_handoff "$home"
  [ -z "$(handoff_field "$record" cleared_epoch)" ] \
    || fail "a generic working or paused line cleared the handoff: $(cat "$record")"
  [ -f "$home/state/handoff-continuations/intake.open" ] \
    || fail "a generic working or paused line retired the open marker"
  grep -Fq "$key" "$home/state/.wake-queue" \
    || fail "a generic working or paused line retired the idle alert"

  printf '%s\n' "needs-decision [at=$HANDOFF_CONT] [key=hold]: an explicit hold" >> "$home/state/intake.status"
  scan_handoff "$home"
  [ "$(handoff_field "$record" clear_reason)" = "status:needs-decision" ] \
    || fail "an explicit hold did not clear the handoff: $(cat "$record")"
  [ "$(handoff_field "$record" latency_secs)" = $((HANDOFF_CONT - HANDOFF_OLD)) ] \
    || fail "latency was not the continuation stamp minus the completion"
  [ "$(handoff_field "$record" cleared_epoch)" = "$HANDOFF_NOW" ] \
    || fail "clear time was not the reconcile clock"
  [ ! -e "$home/state/handoff-continuations/intake.open" ] || fail "a cleared handoff left its marker"

  before=$(handoff_field "$record" cleared_epoch)
  printf '%s\n' "$completion" > "$home/state/intake.status"
  scan_handoff "$home"
  after=$(handoff_field "$record" cleared_epoch)
  [ "$before" = "$after" ] || fail "the same completion line reopened a cleared episode"
  [ ! -e "$home/state/handoff-continuations/intake.open" ] || fail "a cleared episode recreated its marker"
  [ "$(records_for_count "$home" intake)" = 1 ] || fail "a rescan minted a second episode for the same completion"

  write_child "$home" paused "$completion" inc-paused-1
  printf '%s\n%s\n' "$completion" "paused [at=$HANDOFF_CONT]: waiting on a review" > "$home/state/paused.status"
  scan_handoff "$home"
  record=$(one_record "$home" paused) || fail "a paused follow-up dropped the handoff record"
  [ -z "$(handoff_field "$record" cleared_epoch)" ] \
    || fail "a generic paused line cleared the handoff: $(cat "$record")"
  [ -f "$home/state/handoff-continuations/paused.open" ] \
    || fail "a generic paused line retired the open marker"

  for verb in needs-decision blocked captain-held; do
    write_child "$home" "$verb" "$completion" "inc-$verb-1"
    printf '%s\n%s\n' "$completion" "$verb [at=$HANDOFF_CONT]: continued" > "$home/state/$verb.status"
    scan_handoff "$home"
    record=$(one_record "$home" "$verb") || fail "$verb did not keep a record"
    [ "$(handoff_field "$record" clear_reason)" = "status:$verb" ] \
      || fail "$verb did not clear the handoff: $(cat "$record")"
    [ "$(handoff_field "$record" latency_secs)" = $((HANDOFF_CONT - HANDOFF_OLD)) ] \
      || fail "$verb latency was wrong"
  done

  write_child "$home" final "$completion" inc-final-1
  printf '%s\n%s\n' "$completion" \
    "done [at=$HANDOFF_CONT]: PR https://example.test/owner/repo/pull/1 checks green" \
    > "$home/state/final.status"
  scan_handoff "$home"
  record=$(one_record "$home" final) || fail "a ci-ready follow-up left no record of the handoff it closed"
  [ "$(handoff_field "$record" clear_reason)" = "status:done" ] \
    || fail "a ci-ready done did not clear the earlier handoff"

  write_child "$home" pair "$completion" inc-pair-1
  printf '%s\n%s\n' \
    "$completion" \
    "done [at=$HANDOFF_OLD]: committed cc38b3d, 707 tests" \
    > "$home/state/pair.status"
  scan_handoff "$home"
  [ "$(records_for_count "$home" pair)" = 2 ] || fail "two handoffs collapsed into one episode"
  [ -f "$home/state/handoff-continuations/pair.open" ] || fail "two open handoffs left no marker"
  FM_FAKE_CREW_SOURCE=run-step FM_FAKE_CREW_STATE=working scan_handoff "$home"
  uncleared=0
  while IFS= read -r record; do
    [ "$(handoff_field "$record" clear_reason)" = run-step ] || uncleared=1
    [ "$(handoff_field "$record" latency_secs)" = $((HANDOFF_NOW - HANDOFF_OLD)) ] || uncleared=1
  done < <(records_for "$home" pair)
  [ "$uncleared" -eq 0 ] || fail "an active pipeline did not clear every open handoff for the task"
  [ ! -e "$home/state/handoff-continuations/pair.open" ] || fail "a pipeline clear left the marker"

  write_child "$home" review "$completion" inc-review-1
  printf '%s\n%s\n' "$completion" "working [at=$HANDOFF_CONT]: validation started" > "$home/state/review.status"
  FM_FAKE_CREW_SOURCE=run-step FM_FAKE_CREW_STATE='working · review (running)' scan_handoff "$home"
  record=$(one_record "$home" review) || fail "a started review dropped the handoff record"
  [ "$(handoff_field "$record" clear_reason)" = review-started ] \
    || fail "an acknowledged started review did not clear the handoff: $(cat "$record")"
  [ ! -e "$home/state/handoff-continuations/review.open" ] || fail "a started review left the marker"

  write_child "$home" pane "$completion" inc-pane-1
  FM_FAKE_CREW_SOURCE=pane FM_FAKE_CREW_STATE=working scan_handoff "$home"
  record=$(one_record "$home" pane) || fail "pane evidence dropped the handoff record"
  [ -z "$(handoff_field "$record" cleared_epoch)" ] \
    || fail "a busy pane cleared a handoff that has not continued"

  write_child "$home" plain 'needs-validation: committed c118078, 706 tests' inc-plain-1
  scan_handoff "$home"
  record=$(one_record "$home" plain) || fail "an unstamped handoff was not recorded"
  [ "$(handoff_field "$record" observed_epoch)" = "$HANDOFF_NOW" ] \
    || fail "an unstamped handoff did not use the first-seen clock"
  before=$(cksum "$record")
  scan_handoff "$home"
  after=$(cksum "$record")
  [ "$before" = "$after" ] || fail "a rescan changed the identity of the same unstamped handoff"
  [ ! -s "$WORLD/forge.log" ] || fail "a continuation scan invoked a forge or send command"
  pass "a handoff clears on continuation evidence, and a generic working or paused line does not"
}

test_handoff_ignores_an_unterminated_completion_line() {
  local home record
  local completion="needs-validation [at=$HANDOFF_OLD]: committed c118078, 706 tests"
  make_world handoff-partial
  install_handoff_fakes
  home=$MAIN
  write_child "$home" intake "$completion" inc-partial-1
  printf '%s' "$completion" > "$home/state/intake.status"
  scan_handoff "$home"
  [ "$(records_for_count "$home" intake)" = 0 ] \
    || fail "an unterminated needs-validation line opened a handoff episode"
  printf '\n' >> "$home/state/intake.status"
  scan_handoff "$home"
  record=$(one_record "$home" intake) || fail "finishing the line did not record the handoff"
  printf '%s' "needs-validation [at=$HANDOFF_OLD]: committed c118078, 706 tests more" >> "$home/state/intake.status"
  scan_handoff "$home"
  [ "$(records_for_count "$home" intake)" = 1 ] \
    || fail "a second unterminated line minted another episode"
  [ "$(handoff_field "$record" completion_line)" = "$completion" ] \
    || fail "the partial suffix changed the recorded completion"
  pass "an unterminated status line is not a handoff, and finishing it records one episode"
}

test_handoff_idle_skips_final_deliveries_and_secondmates() {
  local home id line
  local plain="done [at=$HANDOFF_OLD]: committed c118078, 706 tests"
  make_world handoff-skip
  install_handoff_fakes
  home=$MAIN
  mkdir -p "$WORLD/harbor-home"

  write_child "$home" ship-ready \
    "done [at=$HANDOFF_OLD]: PR https://example.test/owner/repo/pull/1 checks green" inc-ready-1
  write_child "$home" ship-published \
    "done [at=$HANDOFF_OLD]: PR https://example.test/owner/repo/pull/1 published for review" inc-published-1
  write_child "$home" ship-mergeable \
    "done [at=$HANDOFF_OLD]: PR https://example.test/o/r/pull/153 open, green, mergeable" inc-mergeable-1
  write_child "$home" ship-mentioned \
    "done [at=$HANDOFF_OLD]: PR https://example.test/o/r/pull/3 revision landed" inc-mentioned-1
  write_child "$home" ship-empty "$plain" inc-empty-1
  awk '$0 !~ /^mode=/ { print }' "$home/state/ship-empty.meta" > "$home/state/ship-empty.meta.tmp"
  mv "$home/state/ship-empty.meta.tmp" "$home/state/ship-empty.meta"
  write_child "$home" ship-validation \
    "needs-validation [at=$HANDOFF_OLD]: PR https://example.test/o/r/pull/3 committed c118078, 706 tests" \
    inc-validation-1
  write_child "$home" ship-failed \
    "failed [at=$HANDOFF_OLD]: PR https://example.test/o/r/pull/3 broke" inc-failed-1
  write_child "$home" ship-scout \
    "done [at=$HANDOFF_OLD]: PR https://example.test/o/r/pull/3 revision complete and a recheck is next" \
    inc-scout-1
  awk '$0 ~ /^kind=/ { print "kind=scout"; next } { print }' \
    "$home/state/ship-scout.meta" > "$home/state/ship-scout.meta.tmp"
  mv "$home/state/ship-scout.meta.tmp" "$home/state/ship-scout.meta"
  fm_write_secondmate_meta "$home/state/harbor.meta" "$WORLD/harbor-home"
  printf '%s\n' "needs-validation [at=$HANDOFF_OLD]: committed c118078, 706 tests" > "$home/state/harbor.status"
  write_child "$home" keel "$plain" inc-keel-1

  scan_handoff "$home"
  for id in ship-ready ship-published harbor; do
    [ "$(records_for_count "$home" "$id")" = 0 ] || fail "$id opened a handoff episode"
  done
  for id in ship-empty ship-validation ship-failed ship-scout ship-mergeable ship-mentioned keel; do
    [ "$(records_for_count "$home" "$id")" = 1 ] || fail "$id did not open a handoff episode"
    [ -z "$(handoff_field "$(one_record "$home" "$id")" cleared_epoch)" ] || fail "$id was cleared without a continuation"
  done
  pass "canonical final deliveries and a secondmate record stay off the handoff path; validation, failure, scout, and nonfinal done reports stay on it"
}

test_handoff_idle_requires_canonical_delivery_for_every_mode() {
  local home mode id completion record candidate url
  make_world handoff-canonical-delivery
  install_handoff_fakes
  home=$MAIN
  completion="needs-validation [at=$HANDOFF_OLD]: committed c118078, 706 tests"
  url="https://github.com/owner/repo/pull/1"
  for mode in no-mistakes direct-PR local-only; do
    id="delivery-${mode}"
    write_child "$home" "$id" "$completion" "inc-${mode}-1"
    awk -v mode="$mode" -v url="$url" '
      /^mode=/ { print "mode=" mode; next }
      /^pr=/ { print "pr=" url; next }
      { print }
    ' "$home/state/$id.meta" > "$home/state/$id.meta.tmp"
    mv "$home/state/$id.meta.tmp" "$home/state/$id.meta"
    printf '%s\n' "done [at=$HANDOFF_CONT]: shipped" >> "$home/state/$id.status"
  done
  scan_handoff "$home"
  for mode in no-mistakes direct-PR local-only; do
    id="delivery-${mode}"
    record=
    while IFS= read -r candidate; do
      [ "$(handoff_field "$candidate" completion_line)" = "$completion" ] && record=$candidate
    done < <(records_for "$home" "$id")
    [ -n "$record" ] || fail "$mode: validation completion was not recorded"
    [ -z "$(handoff_field "$record" cleared_epoch)" ] \
      || fail "$mode: unverified done cleared the validation completion"
    [ -f "$home/state/handoff-continuations/$id.open" ] \
      || fail "$mode: unverified done retired the open handoff"
  done

  for mode in no-mistakes direct-PR local-only; do
    id="delivery-${mode}"
    case "$mode" in
      no-mistakes) ;;
      *)
        printf '%s\n' \
          fm-pr-poll-merge-notified-v1 github github.com owner/repo 1 \
          > "$home/state/$id.pr-poll-merge-notified"
        chmod 600 "$home/state/$id.pr-poll-merge-notified"
        ;;
    esac
    printf '%s\n' "done [at=$HANDOFF_CONT]: PR $url checks green" >> "$home/state/$id.status"
  done
  scan_handoff "$home"
  for mode in no-mistakes direct-PR local-only; do
    id="delivery-${mode}"
    record=
    while IFS= read -r candidate; do
      [ "$(handoff_field "$candidate" completion_line)" = "$completion" ] && record=$candidate
    done < <(records_for "$home" "$id")
    [ "$(handoff_field "$record" clear_reason)" = status:done ] \
      || fail "$mode: canonical delivery did not clear the validation completion"
    [ ! -e "$home/state/handoff-continuations/$id.open" ] \
      || fail "$mode: canonical delivery left the validation handoff open"
  done
  pass "only canonical delivery clears handoffs across delivery modes"
}

test_handoff_idle_rejects_a_bare_pr_as_final_delivery() {
  local home completion record fp8 key
  completion="needs-validation [at=$HANDOFF_OLD]: committed c118078, 706 tests"
  make_world handoff-bare-pr
  install_handoff_fakes
  home=$MAIN
  write_child "$home" intake "$completion" inc-bare-pr-1
  scan_handoff "$home"
  record=$(one_record "$home" intake) || fail "the validation handoff was not recorded"
  fp8=$(basename "$record" .record)
  key="handoff-idle-intake-${fp8:0:8}"
  grep -Fq "$key" "$home/state/.wake-queue" || fail "the validation handoff did not queue its idle alert"

  printf '%s\n' "done [at=$HANDOFF_CONT]: PR https://example.test/o/r/pull/9 revision landed" >> "$home/state/intake.status"
  scan_handoff "$home"
  [ -z "$(handoff_field "$record" cleared_epoch)" ] \
    || fail "a bare PR report cleared the validation handoff"
  grep -Fq "$key" "$home/state/.wake-queue" \
    || fail "a bare PR report retired the validation idle alert"
  pass "a bare PR report remains a validation handoff rather than final delivery"
}

test_handoff_idle_rejects_an_unverified_green_followup() {
  local home completion record fp8 key
  completion="needs-validation [at=$HANDOFF_OLD]: committed c118078, 706 tests"
  make_world handoff-unverified-green
  install_handoff_fakes
  home=$MAIN
  write_child "$home" intake "$completion" inc-unverified-green-1
  scan_handoff "$home"
  record=$(one_record "$home" intake) || fail "the validation handoff was not recorded"
  fp8=$(basename "$record" .record)
  key="handoff-idle-intake-${fp8:0:8}"
  awk '$0 !~ /^pr_head=/ { print }' "$home/state/intake.meta" > "$home/state/intake.meta.tmp"
  mv "$home/state/intake.meta.tmp" "$home/state/intake.meta"
  printf '%s\n' "done [at=$HANDOFF_CONT]: PR https://example.test/owner/repo/pull/1 checks green" >> "$home/state/intake.status"
  scan_handoff "$home"
  [ -z "$(handoff_field "$record" cleared_epoch)" ] \
    || fail "an unverified green report cleared the validation handoff"
  grep -Fq "$key" "$home/state/.wake-queue" \
    || fail "an unverified green report retired the validation idle alert"
  pass "an unverified green report remains a validation handoff"
}

test_handoff_idle_uses_only_positional_status_timestamps() {
  local home record
  make_world handoff-timestamp
  install_handoff_fakes
  home=$MAIN
  write_child "$home" stamped \
    "needs-validation [at=$HANDOFF_YOUNG]: compared [at=1] output" inc-stamped-1
  write_child "$home" unstamped \
    "needs-validation: compared [at=1] output" inc-unstamped-1
  scan_handoff "$home"
  record=$(one_record "$home" stamped) || fail "the stamped handoff was not recorded"
  [ "$(handoff_field "$record" observed_epoch)" = "$HANDOFF_YOUNG" ] \
    || fail "a timestamp in note prose replaced the event timestamp"
  [ "$(handoff_field "$record" alerted)" = 0 ] \
    || fail "a timestamp in note prose triggered an early idle alert"
  record=$(one_record "$home" unstamped) || fail "the unstamped handoff was not recorded"
  [ "$(handoff_field "$record" observed_epoch)" = "$HANDOFF_NOW" ] \
    || fail "a timestamp in note prose stamped an unstamped event"
  [ "$(handoff_field "$record" alerted)" = 0 ] \
    || fail "a timestamp in note prose triggered an early alert for an unstamped event"
  pass "only a positional event timestamp controls handoff timing"
}

test_parent_publication_does_not_clear_local_continuation() {
  local harbor keel
  make_world parent-pub
  install_handoff_fakes
  bind_secondmate local
  write_child "$MATE" harbor \
    "needs-validation [at=$HANDOFF_OLD]: committed c118078, 706 tests" inc-harbor-1
  write_child "$MATE" keel \
    "done [at=$HANDOFF_OLD]: committed cc38b3d, 707 tests" inc-keel-1
  scan_handoff "$MATE"
  scan_handoff "$MATE"
  harbor=$(one_record "$MATE" harbor) || fail "the validation handoff was not recorded in the secondmate home"
  keel=$(one_record "$MATE" keel) || fail "the legacy done handoff was not recorded in the secondmate home"
  [ -z "$(handoff_field "$harbor" cleared_epoch)" ] || fail "publishing cleared the validation handoff"
  [ -z "$(handoff_field "$keel" cleared_epoch)" ] || fail "publishing the legacy done cleared its local continuation"
  grep -q 'child-outcome-keel-done' "$MAIN/state/mate.status" \
    || fail "the legacy done was not published to the parent: $(cat "$MAIN/state/mate.status" 2>/dev/null)"
  if grep -q 'needs-validation' "$MAIN/state/mate.status" 2>/dev/null; then
    fail "the validation handoff was published as a parent terminal line: $(cat "$MAIN/state/mate.status")"
  fi
  if grep -q 'child-outcome-harbor' "$MAIN/state/mate.status" 2>/dev/null; then
    fail "the validation handoff got a parent outcome key"
  fi
  [ ! -s "$WORLD/forge.log" ] || fail "parent publication invoked a forge or send command"
  pass "a parent publication leaves the local continuation open, and a validation handoff is not a parent terminal line"
}

test_handoff_directory_symlink_fails_the_scan() {
  local rc
  make_world handoff-symlink
  mkdir -p "$WORLD/elsewhere"
  ln -s "$WORLD/elsewhere" "$MAIN/state/handoff-continuations"
  rc=0
  scan_handoff "$MAIN" || rc=$?
  [ "$rc" -ne 0 ] || fail "a symlinked handoff directory was accepted"
  [ -z "$(find "$WORLD/elsewhere" -type f)" ] \
    || fail "the scan followed the handoff symlink"
  pass "a symlinked handoff directory fails the scan without being followed"
}

test_handoff_idle_bound_refuses_out_of_range() {
  local value rc err
  err="$TMP_ROOT/handoff-bound.err"
  for value in 0 1801 abc; do
    rc=0
    FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$TMP_ROOT/bound-state" FM_HANDOFF_IDLE_SECS="$value" \
      "$RECON" scan >/dev/null 2>"$err" || rc=$?
    [ "$rc" -eq 2 ] || fail "FM_HANDOFF_IDLE_SECS=$value exited $rc: $(cat "$err" 2>/dev/null)"
    grep -q 'FM_HANDOFF_IDLE_SECS' "$err" || fail "the refusal did not name the bound: $(cat "$err" 2>/dev/null)"
  done
  pass "the handoff bound accepts only a whole number from 1 to 1800"
}

test_handoff_idle_records_the_episode_and_alerts_once
test_handoff_idle_records_early_attributed_continuation_latency
test_handoff_idle_rejects_terminal_run_step_evidence
test_handoff_idle_accepts_verified_parked_run_step_waits
test_handoff_idle_clears_only_on_continuation
test_handoff_idle_skips_final_deliveries_and_secondmates
test_handoff_idle_requires_canonical_delivery_for_every_mode
test_handoff_idle_rejects_a_bare_pr_as_final_delivery
test_handoff_idle_rejects_an_unverified_green_followup
test_handoff_idle_uses_only_positional_status_timestamps
test_handoff_ignores_an_unterminated_completion_line
test_handoff_idle_fails_closed_when_continuation_predicate_is_unreadable
test_handoff_idle_generic_line_does_not_read_the_predicate
test_handoff_idle_survives_a_replaced_status_log
test_handoff_idle_replay_keeps_later_completion_open
test_handoff_idle_records_repeated_identical_completions
test_handoff_idle_keeps_new_event_after_duplicate_compaction
test_handoff_idle_reconciles_a_compacted_completion
test_handoff_idle_distinguishes_compacted_long_completions
test_handoff_idle_compacted_duplicate_hold_clears_pending
test_handoff_idle_compacted_distinct_hold_clears_earlier
test_handoff_idle_compacted_duplicate_hold_without_prefix_clears_pending
test_handoff_idle_cursor_reaches_later_tasks_after_budget_exhaustion
test_handoff_reserves_time_for_a_terminal_outcome
test_parent_publication_does_not_clear_local_continuation
test_handoff_directory_symlink_fails_the_scan
test_handoff_idle_bound_refuses_out_of_range

echo "all inactive reconciliation tests passed"
