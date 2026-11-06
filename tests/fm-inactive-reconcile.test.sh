#!/usr/bin/env bash
# Behavioral coverage for bounded inactive terminal-outcome reconciliation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$ROOT/bin/fm-nm-run-lib.sh"

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
  # Mirrors bin/fm-crew-state.sh's one canonical line, including the source and
  # detail fields a terminal outcome must take its PR identity from.
  cat > "$fake/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: %s · source: %s%s\n' "${FM_FAKE_CREW_STATE:-unknown}" \
  "${FM_FAKE_CREW_SOURCE:-fake}" "${FM_FAKE_CREW_DETAIL:+ · $FM_FAKE_CREW_DETAIL}"
SH
  cat > "$fake/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) [ -z "${FM_FAKE_PANE_CMD:-}" ] || printf 'fm-%s\n' "${FM_FAKE_TASK_ID:?}" ;;
  display-message)
    case "$*" in
      *pane_tty*) ;;
      *pane_current_command*) printf '%s\n' "${FM_FAKE_PANE_CMD:-zsh}" ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane) printf 'idle\n> \n' ;;
esac
SH
  local tool
  for tool in gh gh-axi curl; do
    cat > "$fake/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "${FM_FORGE_LOG:?}"
if [ "$(basename "$0")" = gh ] && [ "${GH_HOST:-}" = example.test ]; then
  case " $* " in
    *' --json baseRefName '*)
      [ "${FM_FAKE_BASE_FAIL:-0}" = 0 ] || exit 1
      printf '%s\n' "${FM_FAKE_PR_BASE-main}"; exit 0 ;;
  esac
fi
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
  printf 'example.test\n' > "$MAIN/config/github-hosts"
  printf 'example.test\n' > "$MATE/config/github-hosts"
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
    'harness=codex' 'kind=ship' 'mode=no-mistakes' 'yolo=off' 'expected_base=main' \
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
    FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_CREW_STATE_BIN="${FM_TEST_CREW_STATE_BIN:-$WORLD/fakebin/fm-crew-state.sh}" \
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

arm_claude_busy() { # <home> <id> <busy|idle>
  local home=$1 id=$2 state=$3
  sed 's/^harness=.*/harness=claude/' "$home/state/$id.meta" > "$home/state/$id.meta.new"
  mv "$home/state/$id.meta.new" "$home/state/$id.meta"
  printf 'g1\n' > "$home/state/$id.busy-gen"
  printf 'v1 gen=g1 seq=1 state=%s source=claude-hook event=test ts=%s\n' "$state" "$(date +%s)" > "$home/state/$id.busy-state"
}

run_live_child() { # <world> <busy|idle> <spawn-epoch-offset> [rewrite-meta]
  local status_epoch=$(( $(date +%s) - 600 ))
  make_world "$1"
  write_child "$MAIN" child "done[at=$status_epoch]: PR https://example.test/owner/repo/pull/1 checks green" "s$((status_epoch + $3)).1.1"
  arm_claude_busy "$MAIN" child "$2"
  age "$MAIN/state/child.meta" "$MAIN/state/child.status"
  [ -z "${4:-}" ] || set_mtime "$(( $(date +%s) - 90 ))" "$MAIN/state/child.meta"
  FM_FAKE_CREW_STATE='done' FM_FAKE_PANE_CMD=claude FM_FAKE_TASK_ID=child run_reconcile "$MAIN" --startup
}

assert_withheld() {
  [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "$1: terminal outcome record written"
  ! grep -q inactive-outcome: "$MAIN/state/.wake-queue" 2>/dev/null || fail "$1: supervisor woke"
}

test_busy_agent_withholds_terminal_outcome() {
  run_live_child busy-agent busy -10
  assert_withheld "busy agent"
  pass "busy agent withholds the terminal outcome"
}

test_relaunched_idle_agent_withholds_terminal_outcome() {
  run_live_child relaunched-agent idle 10
  assert_withheld "relaunched agent"
  pass "idle agent on a newer incarnation withholds the terminal outcome"
}

test_idle_finished_agent_keeps_terminal_outcome() {
  run_live_child idle-agent idle -10
  [ "$(outcome_count "$MAIN" pending)" = 1 ] || fail "idle finished agent lost its terminal outcome"
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "idle finished agent did not wake the supervisor"
  pass "idle finished agent keeps the terminal outcome"
}

test_idle_agent_with_rewritten_meta_keeps_terminal_outcome() {
  run_live_child rewritten-meta idle -10 rewrite
  [ "$(outcome_count "$MAIN" pending)" = 1 ] || fail "rewritten meta withheld the terminal outcome"
  pass "idle finished agent with rewritten meta keeps the terminal outcome"
}

test_dead_agent_keeps_terminal_outcome() {
  make_world dead-agent; write_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  FM_FAKE_CREW_STATE='done' FM_FAKE_PANE_CMD=zsh FM_FAKE_TASK_ID=child run_reconcile "$MAIN" --startup
  [ "$(outcome_count "$MAIN" pending)" = 1 ] || fail "dead agent lost its terminal outcome"
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "dead agent did not wake the supervisor"
  pass "dead agent keeps the terminal outcome"
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

# Local readiness is recorded by the real ledger pass while it owns metadata.
test_local_done_head_is_pinned_before_parent_delivery() {
  local project worker sha
  make_world local-done-head
  bind_secondmate local
  project="$MATE/projects/local"
  worker="$WORLD/worker"
  fm_git_worktree "$project" "$worker" fm/child
  git -C "$worker" commit -q --allow-empty -m approved
  sha=$(git -C "$worker" rev-parse HEAD)
  fm_write_meta "$MATE/state/child.meta" \
    "window=firstmate:fm-child" "worktree=$worker" "project=$project" \
    'harness=codex' 'kind=ship' 'mode=local-only' 'yolo=off' 'spawn_gen=local-one'
  printf 'done: approved local work\n' > "$MATE/state/child.status"
  FM_FAKE_CREW_STATE=busy run_reconcile "$MATE"
  [ "$(sed -n 's/^local_done_head=//p' "$MATE/state/child.meta")" = "$sha" ] \
    || fail 'the ledger scan did not pin the local done head'
  [ "$(outcome_count "$MATE" reported)" = 1 ] || fail 'local done report was not delivered'
  grep -Fq 'child child done: approved local work' "$MAIN/state/mate.status" \
    || fail 'the parent did not receive the local done report'
  run_report "$MATE" child || fail 'repeated locked report failed'
  [ "$(outcome_count "$MATE" reported)" = 1 ] || fail 'the same done report was delivered twice'
  git -C "$worker" commit -q --allow-empty -m later
  printf 'done: later local work\n' >> "$MATE/state/child.status"
  FM_FAKE_CREW_STATE=busy run_reconcile "$MATE"
  [ "$(sed -n 's/^local_done_head=//p' "$MATE/state/child.meta")" = "$sha" ] \
    || fail 'a later head replaced the first readiness pin'
  [ "$(outcome_count "$MATE" reported)" = 1 ] || fail 'an unapproved later head was reported'
  pass 'inactive reconciliation pins local readiness under its existing lock before one parent delivery'
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

# Unreadable destination proof must refuse only that child's
# readiness. A later child with matching live proof must still reach the parent
# in the same scan, even when the earlier forge CLI never returns.
test_stalled_base_read_does_not_starve_later_ledger_outcomes() {
  local id url
  make_world stalled-base-ledger; bind_secondmate local
  for id in a-hung b-ready; do
    url="https://github.com/owner/repo/pull/1"
    [ "$id" != b-ready ] || url="https://github.com/owner/repo/pull/2"
    write_child "$MATE" "$id" "done: PR $url checks green"
  done
  cat > "$WORLD/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FORGE_LOG:?}"
case "${3:-}" in
  https://github.com/owner/repo/pull/1) exec sleep 60 ;;
  https://github.com/owner/repo/pull/2) printf 'main\n' ;;
  *) exit 97 ;;
esac
SH
  chmod +x "$WORLD/fakebin/gh"

  FM_FAKE_CREW_STATE=unknown run_reconcile "$MATE"
  grep -Fq 'child-outcome-b-ready-done' "$MAIN/state/mate.status" 2>/dev/null \
    || fail 'a hung base lookup starved a later ready child in the same scan'
  ! grep -Fq 'child-outcome-a-hung-done' "$MAIN/state/mate.status" \
    || fail 'a child with unavailable destination proof was reported done'
  [ "$(outcome_count "$MATE" reported)" = 1 ] \
    || fail 'a hung child acquired a readiness receipt'
  grep -Fq 'pr view https://github.com/owner/repo/pull/1 --json baseRefName' "$WORLD/forge.log" \
    || fail 'the regression never reached the hanging forge lookup'
  pass 'a hung destination lookup refuses that child without starving the next ledger report'
}

# Several individually bounded destination reads can exhaust the whole scan.
# Repeated polls must resume beyond them instead of starting at the first hang.
test_several_stalled_base_reads_resume_before_later_ledger_outcomes() {
  local id number=0 attempt
  make_world several-stalled-bases; bind_secondmate local
  write_child "$MATE" 0-dead 'working: stopped before writing an outcome'
  for id in a-hung b-hung c-hung z-ready; do
    number=$((number + 1))
    write_child "$MATE" "$id" "done: PR https://github.com/owner/repo/pull/$number checks green"
  done
  cat > "$WORLD/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FORGE_LOG:?}"
case "${3:-}" in
  https://github.com/owner/repo/pull/1|https://github.com/owner/repo/pull/2|https://github.com/owner/repo/pull/3) exec sleep 30 ;;
  https://github.com/owner/repo/pull/4) printf 'main\n' ;;
  *) exit 97 ;;
esac
SH
  chmod +x "$WORLD/fakebin/gh"

  for attempt in 1 2 3 4 5; do
    FM_INACTIVE_RECONCILE_BUDGET_SECS=2 FM_FAKE_CREW_STATE=failed run_reconcile "$MATE"
    grep -Fq 'inactive-outcome-mate-0-dead-failed' "$MAIN/state/mate.status" 2>/dev/null \
      || fail "hung ledger reads starved the due inactive outcome on poll $attempt"
    [ -f "$MATE/state/.inactive-outcome-reconcile" ] \
      || fail 'hung ledger reads prevented the inactive cadence marker'
    grep -Fq 'child-outcome-z-ready-done' "$MAIN/state/mate.status" 2>/dev/null && break
  done
  grep -Fq 'child-outcome-z-ready-done' "$MAIN/state/mate.status" 2>/dev/null \
    || fail 'several hung destination reads starved the healthy child across bounded retries'
  for id in a-hung b-hung c-hung; do
    ! grep -Fq "child-outcome-$id-done" "$MAIN/state/mate.status" \
      || fail "a timed-out child was reported ready: $id"
  done
  [ "$(grep -Fc 'inactive-outcome-mate-0-dead-failed' "$MAIN/state/mate.status")" = 1 ] \
    || fail 'ledger retries duplicated the inactive outcome'
  [ "$(outcome_count "$MATE" reported)" = 2 ] \
    || fail 'timed-out destination reads acquired readiness receipts'
  [ "$(outcome_count "$MATE" pending)" = 0 ] \
    || fail 'timed-out destination reads acquired pending receipts'
  for number in 1 2 3; do
    grep -Fq "pr view https://github.com/owner/repo/pull/$number --json baseRefName" "$WORLD/forge.log" \
      || fail "the regression never reached hung destination $number"
  done
  pass 'hung destinations refuse readiness while inactive and ledger outcomes both progress'
}

test_readiness_deadline_owns_forge_processes_on_both_paths() {
  local timer route tools_bin tool tool_path mechanism home id number attempt pid state deadline url running started elapsed
  command -v perl >/dev/null 2>&1 || { fail 'readiness deadline regression requires perl'; return; }
  for timer in normal perl; do
    for route in ledger cadence; do
      make_world "deadline-$timer-$route"
      home=$MAIN
      if [ "$route" = ledger ]; then
        bind_secondmate local
        home=$MATE
      fi
      tools_bin="$WORLD/tools-bin"
      mkdir -p "$tools_bin"
      for tool in perl bash sh env sleep git dirname basename mkdir mktemp chmod mv rm rmdir cat grep tail cut tr sed stat date wc head sort find awk readlink id ps shasum sha256sum cksum touch ln uname cmp realpath jq; do
        tool_path=$(type -P "$tool" 2>/dev/null) || continue
        ln -s "$tool_path" "$tools_bin/$tool"
      done
      if [ "$timer" = normal ]; then
        for tool in timeout gtimeout; do
          tool_path=$(type -P "$tool" 2>/dev/null) || continue
          ln -s "$tool_path" "$tools_bin/$tool"
        done
      fi
      mechanism=$(PATH="$tools_bin" bash -c '. "$1"; fm_timeout_mechanism' _ "$ROOT/bin/fm-timeout-lib.sh")
      case "$timer:$mechanism" in
        perl:perl|normal:timeout|normal:gtimeout) ;;
        *) fail "readiness deadline regression could not select $timer timeout: $mechanism" ;;
      esac
      number=0
      for id in a-hung b-hung z-ready; do
        number=$((number + 1))
        write_child "$home" "$id" "done: PR https://github.com/owner/repo/pull/$number checks green"
        sed 's/^mode=no-mistakes$/mode=direct-PR/' "$home/state/$id.meta" > "$home/state/$id.meta.tmp"
        mv "$home/state/$id.meta.tmp" "$home/state/$id.meta"
        age "$home/state/$id.meta"
      done
      cat > "$WORLD/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s %s %s\n' "$$" "${FM_READ_DEADLINE:-0}" "${3:-}" >> "${FM_FORGE_PIDS:?}"
case "${3:-}" in
  https://github.com/owner/repo/pull/1|https://github.com/owner/repo/pull/2) exec sleep 30 ;;
  https://github.com/owner/repo/pull/3) printf 'main\n' ;;
  *) exit 97 ;;
esac
SH
      if [ "$route" = cadence ]; then
        cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
exec 2>>"${FM_FORGE_PIDS}.crew"
. "${FM_TEST_DOD_LIB%/*}/fm-timeout-lib.sh"
. "$FM_TEST_DOD_LIB"
meta="$FM_STATE_OVERRIDE/$1.meta"
value() { sed -n "s/^$1=//p" "$meta"; }
line=$(cat "$FM_STATE_OVERRIDE/$1.status")
if reason=$(fm_dod_accept_ship_done "$(value kind)" "$(value mode)" "$(value worktree)" \
    "$(value project)" "$line" "$FM_STATE_OVERRIDE" "$1" "$meta"); then
  printf 'state: done · source: status-log · %s\n' "$(status_line_note "$line")"
else
  printf '%s: %s\n' "$1" "$reason" >&2
  printf 'state: blocked · source: status-log · %s\n' "$reason"
fi
SH
      fi
      chmod +x "$WORLD/fakebin/"*
      for attempt in 1 2 3 4; do
        : > "$WORLD/forge.pids"
        started=$(fm_nm_now_ms)
        PATH="$tools_bin" FM_FORGE_PIDS="$WORLD/forge.pids" FM_TEST_DOD_LIB="$ROOT/bin/fm-dod-lib.sh" \
          FM_INACTIVE_RECONCILE_BUDGET_SECS=3 FM_FAKE_CREW_STATE=unknown \
          run_reconcile "$home" --startup
        elapsed=$(( $(fm_nm_now_ms) - started ))
        [ "$elapsed" -le 4000 ] || fail "$timer/$route scan exceeded budget plus backstop: ${elapsed}ms"
        running=0
        [ -s "$WORLD/forge.pids" ] \
          || fail "$timer/$route poll $attempt never started a forge read: $(cat "$WORLD/forge.pids.crew" 2>/dev/null)"
        while read -r pid deadline url; do
          printf '%s\n' "$url" >> "$WORLD/visited"
          [ "$deadline" -gt 0 ] && [ "$(fm_nm_now_ms)" -le "$((deadline + 2000))" ] \
            || fail "$timer/$route scan exceeded its read deadline"
          state=$(ps -p "$pid" -o stat= 2>/dev/null || true)
          case "$state" in
            ''|*Z*) ;;
            *) running=1; reap "$pid" ;;
          esac
        done < "$WORLD/forge.pids"
        [ "$running" = 0 ] || fail "$timer/$route left a forge process alive past the scan"
        if [ "$route" = ledger ]; then
          grep -Fq 'child-outcome-z-ready-done' "$MAIN/state/mate.status" 2>/dev/null && break
        else
          grep -Fq 'child=z-ready state=done' "$MAIN/state/.wake-queue" 2>/dev/null && break
        fi
      done
      for number in 1 2; do
        grep -Fxq "https://github.com/owner/repo/pull/$number" "$WORLD/visited" \
          || fail "$timer/$route never reached hung child $number"
      done
      if [ "$route" = ledger ]; then
        grep -Fq 'child-outcome-z-ready-done' "$MAIN/state/mate.status" 2>/dev/null \
          || fail "$timer ledger reads starved the healthy later child"
        [ "$(outcome_count "$home" reported)" = 1 ] \
          || fail "$timer ledger reads reported a hung child"
      else
        grep -Fq 'child=z-ready state=done' "$MAIN/state/.wake-queue" 2>/dev/null \
          || fail "$timer cadence reads starved the healthy later child"
        [ "$(outcome_count "$home" pending)" = 1 ] \
          || fail "$timer cadence reads reported a hung child"
      fi
    done
  done
  pass 'ledger and cadence readiness share deadlines without surviving forge processes'
}

test_deadline_truncated_run_read_has_no_verdict() {
  local generation out rc=0
  make_world truncated-run-read
  write_child "$MAIN" child 'done: implemented the change'
  sed 's/^harness=codex$/harness=claude/' "$MAIN/state/child.meta" > "$MAIN/state/child.meta.tmp"
  mv "$MAIN/state/child.meta.tmp" "$MAIN/state/child.meta"
  age "$MAIN/state/child.meta"
  generation=$("$ROOT/bin/fm-busy-event.sh" arm "$MAIN/state" child)
  "$ROOT/bin/fm-busy-event.sh" apply "$MAIN/state" child idle --gen "$generation" \
    --source claude-hook --event stop
  cat > "$WORLD/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${FM_STALL_RUN_READ:-0}" = 1 ]; then
  printf '%s\n' "$*" >> "$FM_RUN_READ_LOG"
  sleep 5
fi
exit 1
SH
  cat > "$WORLD/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'fm-child\n' ;;
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'idle\n> \n' ;;
esac
SH
  chmod +x "$WORLD/fakebin/"*
  out=$(PATH="$WORLD/fakebin:$PATH" FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" \
    FM_CONFIG_OVERRIDE="$MAIN/config" FM_READ_DEADLINE='' \
    "$ROOT/bin/fm-crew-state.sh" child)
  case "$out" in 'state: done '*) ;; *) fail "ordinary idle handoff no longer reads done: $out" ;; esac
  out=$(PATH="$WORLD/fakebin:$PATH" FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" \
    FM_CONFIG_OVERRIDE="$MAIN/config" FM_READ_DEADLINE="$(( $(fm_nm_now_ms) + 2000 ))" \
    FM_STALL_RUN_READ=1 FM_RUN_READ_LOG="$WORLD/run.calls" \
    "$ROOT/bin/fm-crew-state.sh" child) || rc=$?
  [ "$rc" = 124 ] || fail "deadline-truncated crew-state lost its timeout status: $rc $out"
  case "$out" in 'state: unknown '*) ;; *) fail "deadline-truncated crew-state emitted a verdict: $out" ;; esac
  FM_TEST_CREW_STATE_BIN="$ROOT/bin/fm-crew-state.sh" FM_INACTIVE_RECONCILE_BUDGET_SECS=2 \
    FM_STALL_RUN_READ=1 FM_RUN_READ_LOG="$WORLD/run.calls" run_reconcile "$MAIN" --startup
  [ -s "$WORLD/run.calls" ] || fail 'the truncated-run regression never read the pipeline'
  [ "$(outcome_count "$MAIN" pending)" = 0 ] && [ "$(outcome_count "$MAIN" reported)" = 0 ] \
    || fail 'a deadline-truncated run read acquired a terminal record'
  ! grep -Fq 'inactive-outcome:' "$MAIN/state/.wake-queue" 2>/dev/null \
    || fail 'a deadline-truncated run read queued a terminal wake'
  pass 'deadline-truncated run reads return unknown and create no terminal outcome'
}

# Exhaust ledger proof with a real stalled process, then measure the real
# crew-state command. A clock frozen at a whole-second boundary cannot prove
# that the forced visit gets a full second rather than the next clock tick.
test_forced_cadence_visit_keeps_floor_after_ledger_deadline() {
  local branch head out mode started elapsed deadline rc
  for mode in failed stalled; do
  make_world "forced-cadence-floor-$mode"; bind_secondmate local
  write_child "$MATE" 0-cadence 'working: awaiting the pipeline result'
  write_child "$MATE" a-ledger 'done: PR https://github.com/owner/repo/pull/1 checks green'
  branch=$(git -C "$MATE/projects/0-cadence" symbolic-ref --short HEAD)
  head=$(git -C "$MATE/projects/0-cadence" rev-parse HEAD)
  cat > "$WORLD/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf 'ledger-read\n' >> "$FM_FORGE_LOG"
exec sleep 30
SH
  cat > "$WORLD/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "$#" = 1 ] && [ "$1" = axi ]; then
  if [ "${FM_FLOOR_STALL:-0}" = 1 ]; then
    printf 'run-read\n' >> "$FM_FLOOR_CALLS"
    exec sleep 5
  fi
  [ "${FM_FLOOR_DELAY:-0}" = 0 ] || sleep "$FM_FLOOR_DELAY"
  printf 'current_branch: %s\ncount: 1 of 1 total\nruns[1]{id,branch,status,head,pr}:\n' "$FM_FLOOR_BRANCH"
  printf '  01RUN,%s,failed,%s,""\n' "$FM_FLOOR_BRANCH" "$FM_FLOOR_HEAD"
else
  cat <<EOF
run:
  id: "01RUN"
  branch: $FM_FLOOR_BRANCH
  status: failed
  head: "$FM_FLOOR_HEAD"
  pr: ""
  findings: none
outcome: failed
EOF
fi
SH
  cat > "$WORLD/fakebin/measured-crew-state" <<'SH'
#!/usr/bin/env bash
. "$FM_FLOOR_LIB"
started=$(fm_nm_now_ms)
rc=0
"${FM_FLOOR_LIB%/*}/fm-crew-state.sh" "$@" || rc=$?
printf '%s %s %s %s\n' "$started" "$(fm_nm_now_ms)" "$FM_READ_DEADLINE" "$rc" > "$FM_FLOOR_MEASURE"
exit "$rc"
SH
  chmod +x "$WORLD/fakebin/"*
  out=$(PATH="$WORLD/fakebin:$PATH" FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" \
    FM_CONFIG_OVERRIDE="$MATE/config" FM_READ_DEADLINE='' \
    FM_FLOOR_BRANCH="$branch" FM_FLOOR_HEAD="$head" \
    "$ROOT/bin/fm-crew-state.sh" 0-cadence)
  case "$out" in
    'state: failed · source: run-step'*) ;;
    *) fail "the floor fixture did not supply a known failed run: $out" ;;
  esac
  # Start away from the next whole-second tick to expose the old fractional
  # floor. Every clock in the scan and crew-state continues advancing normally.
  while :; do
    started=$(fm_nm_now_ms)
    [ "$((started % 1000))" -ge 600 ] && [ "$((started % 1000))" -le 650 ] && break
    sleep 0.01
  done
  FM_TEST_CREW_STATE_BIN="$WORLD/fakebin/measured-crew-state" FM_INACTIVE_RECONCILE_BUDGET_SECS=3 \
    FM_FLOOR_LIB="$ROOT/bin/fm-nm-run-lib.sh" FM_FLOOR_MEASURE="$WORLD/measure" \
    FM_FLOOR_CALLS="$WORLD/run.calls" FM_FLOOR_STALL="$([ "$mode" = stalled ] && printf 1 || printf 0)" \
    FM_FLOOR_DELAY=0.6 \
    FM_FLOOR_BRANCH="$branch" FM_FLOOR_HEAD="$head" run_reconcile "$MATE" --startup
  grep -Fxq ledger-read "$WORLD/forge.log" || fail 'the floor regression never exhausted ledger proof'
  [ -s "$WORLD/measure" ] || fail 'the forced first cadence visit never completed its measured real crew-state read'
  [ ! -e "$MATE/state/.meta-0-cadence.lock" ] || fail 'the forced first cadence visit retained its metadata lock after cleanup'
  read -r started elapsed deadline rc < "$WORLD/measure"
  elapsed=$((elapsed - started))
  [ "$((deadline - started))" -ge 900 ] \
    || fail 'the forced first cadence visit inherited less than a full second of real budget'
  if [ "$mode" = stalled ]; then
    grep -Fxq run-read "$WORLD/run.calls" || fail 'the floor regression never stalled a run read'
    [ "$rc" = 124 ] && [ "$elapsed" -ge 900 ] \
      || fail "the forced first cadence visit lost its one-second real-time floor: ${elapsed}ms rc=$rc"
    [ "$(outcome_count "$MATE" reported)" = 0 ] \
      || fail 'the floor regression reported a deadline-truncated read'
  else
    grep -Fq 'inactive-outcome-mate-0-cadence-failed' "$MAIN/state/mate.status" 2>/dev/null \
      || fail 'the forced first cadence visit lost its one-second floor after the ledger deadline'
    [ "$(outcome_count "$MATE" reported)" = 1 ] \
      || fail 'the floor regression reported an unproved ledger child'
  fi
  done
  pass 'the forced first cadence visit preserves a measured full-second floor after real stalled ledger proof'
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
  grep -Fq 'gh pr view https://example.test/owner/repo/pull/1 --json baseRefName' "$WORLD/forge.log" \
    || fail 'ledger delivery did not verify its destination'
  [ "$(wc -l < "$WORLD/forge.log" | tr -d ' ')" = 1 ] \
    || fail 'ledger delivery invoked a forge command beyond its destination check'
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
  [ ! -e "$MAIN/state/.meta-a.lock" ] || fail "stalled state reader left its child's metadata lock behind"

  write_child "$MAIN" b 'done: green'
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 run_reconcile "$MAIN" --startup
  grep -Fq 'child=b state=done' "$MAIN/state/.wake-queue" \
    || fail "next bounded scan did not resume with the following child"
  pass "stalled state reads are bounded without starving later children"
}

test_stalled_liveness_read_is_bounded_and_scan_progresses() {
  local started elapsed
  make_world bounded-liveness
  write_child "$MAIN" a 'working: liveness read will stall'
  age "$MAIN/state/a.meta" "$MAIN/state/a.status"
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = a ]; then
  sleep 1
  printf 'state: failed · source: fake\n'
else
  printf 'state: done · source: fake\n'
fi
SH
  cat > "$WORLD/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
[ ! -e "$(dirname "$0")/stall" ] || sleep 30
SH
  : > "$WORLD/fakebin/stall"
  chmod +x "$WORLD/fakebin/fm-crew-state.sh" "$WORLD/fakebin/tmux"

  started=$(date +%s)
  FM_INACTIVE_RECONCILE_BUDGET_SECS=2 run_reconcile "$MAIN" --startup
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -le 4 ] || fail "stalled liveness read exceeded aggregate scan budget (${elapsed}s)"

  rm -f "$WORLD/fakebin/stall"
  write_child "$MAIN" b 'done: green'
  FM_INACTIVE_RECONCILE_BUDGET_SECS=2 run_reconcile "$MAIN" --startup
  grep -Fq 'child=b state=done' "$MAIN/state/.wake-queue" \
    || fail "next bounded scan did not resume with the following child"
  pass "stalled liveness reads are bounded without starving later children"
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

# --- a terminal outcome must be established from its own source --------------
# Regression family for the 2026-08-27 false failure report. The reader's
# terminal state was promoted into a captain-facing outcome together with a PR
# taken from an OLDER record, so one queued record was wrong twice: the work had
# not failed, and the pull request named was not the one the current run opened.

queued_payload() { # <home> <key-prefix>
  grep -F "$2" "$1/state/.wake-queue" 2>/dev/null | tail -1
}

# wake_count above reports an empty string when the queue file does not exist at
# all, which is the same fact as a zero count for these cases.
assert_nothing_queued() { # <home> <key-prefix> <message>
  case "$(wake_count "$1" "$2")" in
    ''|0) ;;
    *) fail "$3: $(queued_payload "$1" "$2")" ;;
  esac
}

# The exact shape that reached the captain: the current run opened no pull
# request at all, so the record must name none rather than borrowing the task's
# previously recorded one.
test_terminal_outcome_never_names_a_pr_the_run_did_not_open() {
  local payload
  make_world outcome-pr-absent; write_child "$MAIN" child 'working: still validating'
  FM_FAKE_CREW_STATE='failed' FM_FAKE_CREW_SOURCE='run-step' FM_FAKE_CREW_DETAIL='run failed' \
    run_reconcile "$MAIN" --startup
  payload=$(queued_payload "$MAIN" 'inactive-outcome:')
  [ -n "$payload" ] || fail "no terminal outcome was queued"
  case "$payload" in
    *'pull/1'*) fail "the terminal outcome named a pull request the run never opened: $payload" ;;
  esac
  pass "a terminal outcome names no pull request when its run opened none"
}

# When the run DID open one, that identity wins over the older recorded PR.
test_run_step_destination_has_one_publication_boundary() {
  make_world run-destination-emitter
  write_child "$MAIN" child 'working: still validating'
  # The real emitter's destination matrix lives in fm-crew-state.test.sh.
  # A consumer must deliver its proved result without another network read.
  FM_FAKE_BASE_FAIL=1 FM_FAKE_CREW_STATE='done' FM_FAKE_CREW_SOURCE='run-step' \
    FM_FAKE_CREW_DETAIL='checks green: PR ready for review · pr=https://example.test/owner/repo/pull/42' \
    run_reconcile "$MAIN" --startup
  [ -n "$(queued_payload "$MAIN" 'inactive-outcome:')" ] || fail 'proved run-step result was not delivered'
  [ ! -s "$WORLD/forge.log" ] || fail 'run-step consumer repeated the emitter destination read'
  pass 'inactive run-step delivery trusts the single proved publication boundary'
}

test_terminal_outcome_takes_the_pr_its_run_opened() {
  local payload
  make_world outcome-pr-current; write_child "$MAIN" child 'working: still validating'
  FM_FAKE_CREW_STATE='done' FM_FAKE_CREW_SOURCE='run-step' \
    FM_FAKE_CREW_DETAIL='checks green: PR ready for review · pr=https://example.test/owner/repo/pull/42' \
    run_reconcile "$MAIN" --startup
  payload=$(queued_payload "$MAIN" 'inactive-outcome:')
  [ -n "$payload" ] || fail "no terminal outcome was queued"
  case "$payload" in
    *'pr=https://example.test/owner/repo/pull/42'*) ;;
    *) fail "the terminal outcome did not name the run's own pull request: $payload" ;;
  esac
  case "$payload" in
    *'pull/1 '*|*'pull/1') fail "the terminal outcome kept the older recorded pull request: $payload" ;;
  esac
  pass "a terminal outcome names the pull request its own run opened"
}

# A state-log-sourced terminal state keeps taking its PR from that same line.
test_status_log_sourced_outcome_keeps_its_own_pr() {
  local payload
  make_world outcome-pr-log
  write_child "$MAIN" child 'done: PR https://github.com/owner/repo/pull/7 checks green'
  FM_FAKE_CREW_STATE='done' FM_FAKE_CREW_SOURCE='status-log' \
    FM_FAKE_CREW_DETAIL='PR https://github.com/owner/repo/pull/7 checks green' \
    run_reconcile "$MAIN" --startup
  payload=$(queued_payload "$MAIN" 'inactive-outcome:')
  [ -n "$payload" ] || fail "no terminal outcome was queued"
  case "$payload" in
    *'pr=https://github.com/owner/repo/pull/7'*) ;;
    *) fail "the terminal outcome dropped the pull request its own record named: $payload" ;;
  esac
  pass "a status-log sourced outcome keeps the pull request that record named"
}

# Every supported forge's ready report keeps its review link: a GitLab merge
# request and a Gerrit change reported in their own ready shapes.
test_status_log_outcome_keeps_gitlab_and_gerrit_reviews() {
  local payload name url detail
  for name in gitlab gerrit; do
    case "$name" in
      gitlab)
        url='https://gitlab.example/group/sub/project/-/merge_requests/8'
        detail="PR $url checks green"
        ;;
      gerrit)
        url='https://gerrit.example/c/group/project/+/4201'
        detail="PR $url published for review"
        ;;
    esac
    make_world "outcome-pr-log-$name"
    write_child "$MAIN" child "done: $detail"
    FM_FAKE_CREW_STATE='done' FM_FAKE_CREW_SOURCE='status-log' \
      FM_FAKE_CREW_DETAIL="$detail" run_reconcile "$MAIN" --startup
    payload=$(queued_payload "$MAIN" 'inactive-outcome:')
    [ -n "$payload" ] || fail "no terminal outcome was queued for $name"
    case "$payload" in
      *"pr=$url"*) ;;
      *) fail "the $name terminal outcome dropped its review link: $payload" ;;
    esac
  done
  pass "a status-log outcome keeps GitLab and Gerrit review links"
}

# A status-log outcome without its own PR carries none. An earlier working line
# and the task metadata deliberately name different PRs so either provenance
# violation is visible.
test_status_log_outcome_never_borrows_an_earlier_pr() {
  local payload
  make_world outcome-pr-log-absent
  write_child "$MAIN" child 'working: PR https://example.test/owner/repo/pull/55 still validating'
  printf 'done: implementation complete\n' >> "$MAIN/state/child.status"
  age "$MAIN/state/child.status"
  FM_FAKE_CREW_STATE='done' FM_FAKE_CREW_SOURCE='status-log' \
    FM_FAKE_CREW_DETAIL='implementation complete' run_reconcile "$MAIN" --startup
  payload=$(queued_payload "$MAIN" 'inactive-outcome:')
  [ -n "$payload" ] || fail "no terminal outcome was queued"
  case "$payload" in
    *'pr='*) fail "the terminal outcome borrowed a pull request from another record: $payload" ;;
  esac
  pass "a status-log outcome without its own pull request carries none"
}

test_status_log_outcome_never_borrows_the_fresh_last_line_pr() {
  local payload
  make_world outcome-pr-log-fresh-line
  write_child "$MAIN" child 'done: implementation complete'
  printf 'working: PR https://example.test/owner/repo/pull/55 resumed\n' >> "$MAIN/state/child.status"
  age "$MAIN/state/child.status"
  FM_FAKE_CREW_STATE='done' FM_FAKE_CREW_SOURCE='status-log' \
    FM_FAKE_CREW_DETAIL='implementation complete' run_reconcile "$MAIN" --startup
  payload=$(queued_payload "$MAIN" 'inactive-outcome:')
  [ -n "$payload" ] || fail "no terminal outcome was queued"
  case "$payload" in
    *'pr='*) fail "the terminal outcome borrowed a pull request from the corroboration line: $payload" ;;
  esac
  pass "a status-log outcome takes no pull request from another line"
}

# Prose is not a delivery claim: a terminal line that merely mentions pull
# requests names none of them as the delivery, so the abandoned one is never
# reported to the captain.
test_status_log_outcome_never_claims_a_mentioned_pr() {
  local payload note
  make_world outcome-pr-log-prose
  note='closed https://example.test/owner/repo/pull/12, shipped instead as https://example.test/owner/repo/pull/34'
  write_child "$MAIN" child "done: $note"
  FM_FAKE_CREW_STATE='done' FM_FAKE_CREW_SOURCE='status-log' \
    FM_FAKE_CREW_DETAIL="$note" run_reconcile "$MAIN" --startup
  payload=$(queued_payload "$MAIN" 'inactive-outcome:')
  [ -n "$payload" ] || fail "no terminal outcome was queued"
  case "$payload" in
    *'pr='*) fail "the terminal outcome claimed a pull request only mentioned in prose: $payload" ;;
  esac
  pass "a status-log outcome never claims a pull request mentioned in prose"
}

# A scout never delivers a pull request, so it never carries one - the same rule
# the ledger-first path applies through pr_for_task. Its ready-signal-shaped
# terminal line must therefore still produce an outcome that names no PR.
test_scout_outcome_carries_no_pull_request() {
  local payload
  make_world outcome-scout-pr
  write_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/7 checks green'
  awk '{ sub(/^kind=ship$/, "kind=scout"); print }' "$MAIN/state/child.meta" \
    > "$MAIN/state/child.meta.tmp" && mv "$MAIN/state/child.meta.tmp" "$MAIN/state/child.meta"
  age "$MAIN/state/child.meta"
  FM_FAKE_CREW_STATE='done' FM_FAKE_CREW_SOURCE='status-log' \
    FM_FAKE_CREW_DETAIL='PR https://example.test/owner/repo/pull/7 checks green' \
    run_reconcile "$MAIN" --startup
  payload=$(queued_payload "$MAIN" 'inactive-outcome:')
  [ -n "$payload" ] || fail "no terminal outcome was queued for the scout"
  case "$payload" in
    *'pr='*) fail "a scout's terminal outcome claimed a pull request: $payload" ;;
  esac
  pass "a scout's terminal outcome carries no pull request"
}

# The independent captain protection, for the one source where the two records
# are comparable: the reader read the crew's own STATUS LOG, and the crew's last
# self-declared word disagrees with what that read reported, so nothing is
# manufactured for presentation. Ordinary supervision still owns it. Re-pointed
# from a run-step state: a run-step state is the pipeline's own record and no
# longer answers to the crew's prose.
test_contradicted_failure_is_not_promoted_for_presentation() {
  make_world outcome-contradicted
  write_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  FM_FAKE_CREW_STATE='failed' FM_FAKE_CREW_SOURCE='status-log' FM_FAKE_CREW_DETAIL='the build broke' \
    run_reconcile "$MAIN" --startup
  assert_nothing_queued "$MAIN" 'inactive-outcome:' "a contradicted failure was queued for the captain"
  [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "a contradicted failure minted a durable record"
  pass "a failure the crew's own last word contradicts is never presented"
}

# The mirror direction: a success the crew's own last word calls a failure is
# equally unsafe to present. Re-pointed to a status-log state for the same
# reason as its sibling above. This also subsumes the removed
# test_crew_prose_cannot_forge_the_ordering_field: the ordering field it forged
# no longer exists, so a status-log note carrying any prose at all now reaches
# this same guard and cannot switch it off.
test_contradicted_success_is_not_promoted_for_presentation() {
  make_world outcome-contradicted-done
  write_child "$MAIN" child 'failed: the build broke'
  FM_FAKE_CREW_STATE='done' FM_FAKE_CREW_SOURCE='status-log' FM_FAKE_CREW_DETAIL='implementation complete' \
    run_reconcile "$MAIN" --startup
  assert_nothing_queued "$MAIN" 'inactive-outcome:' "a contradicted success was queued for the captain"
  pass "a success the crew's own last word contradicts is never presented"
}

# The routine ship shape, and the reason this whole path exists: the crew
# declares implementation done, firstmate then starts the validation run, the
# run FAILS, and the crew goes silent without appending `failed:`. The reader
# reports that failure from the pipeline's own run step, which outranks the
# crew's earlier word, so the captain must still be told - a failure reaching
# nobody is the harm this path exists to remove.
test_run_step_failure_is_not_suppressed_by_the_crews_own_word() {
  local payload
  make_world outcome-mid-run-done
  write_child "$MAIN" child 'done: implementation complete'
  FM_FAKE_CREW_STATE='failed' FM_FAKE_CREW_SOURCE='run-step' FM_FAKE_CREW_DETAIL='run failed' \
    run_reconcile "$MAIN" --startup
  payload=$(queued_payload "$MAIN" 'inactive-outcome:')
  [ -n "$payload" ] || fail "a run-step failure behind the crew's own done line was dropped"
  [ "$(outcome_count "$MAIN" pending)" = 1 ] \
    || fail "no durable terminal outcome was minted for the failure"
  pass "a run-step failure is not suppressed by the crew's own earlier word"
}

# The mirror shape the branch is named for: a stale `paused:` line and a real
# run failure reported from the run step.
test_stale_pause_does_not_suppress_the_failure() {
  make_world outcome-stale-pause
  write_child "$MAIN" child 'paused: waiting on the pipeline'
  FM_FAKE_CREW_STATE='failed' FM_FAKE_CREW_SOURCE='run-step' FM_FAKE_CREW_DETAIL='run failed' \
    run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] \
    || fail "a failure behind a stale pause line was dropped"
  pass "a stale pause line does not suppress the failure that followed it"
}

# Direction guard: a crew that simply stopped mid-work has no self-declared
# outcome to contradict the reader, so a genuine failure still reaches the
# captain. Hiding real failures is equally wrong.
test_uncontradicted_failure_is_still_presented() {
  make_world outcome-genuine; write_child "$MAIN" child 'working: implementing'
  FM_FAKE_CREW_STATE='failed' FM_FAKE_CREW_SOURCE='run-step' FM_FAKE_CREW_DETAIL='run failed' \
    run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] \
    || fail "a genuine failure was not queued for the captain"
  pass "a genuine, uncontradicted failure still reaches the captain"
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

test_legacy_ledger_reports_missing_base_once() {
  local route target note index
  for route in local remote; do
    index=0
    for note in 'PR https://github.com/o/r/pull/1' 'PR #1' \
      'opened https://github.com/o/r/pull/1' 'implementation complete'; do
      index=$((index + 1))
      make_world "legacy-ledger-base-$route-$index"; bind_secondmate "$route"
      write_child "$MATE" child "done: $note"
      FM_TEST_META_EXPECTED_BASE='' fm_write_meta "$MATE/state/child.meta" \
        "worktree=$MATE/projects/child" "project=$MATE/projects/child" \
        'kind=ship' 'mode=direct-PR' 'pr=https://github.com/o/r/pull/1'
      run_report "$MATE" child || fail 'legacy ledger refusal could not be delivered'
      run_report "$MATE" child || fail 'second legacy ledger visit failed'
      target="$MAIN/state/mate.status"
      [ "$route" != remote ] || target="$MATE/state/parent-replies.status"
      assert_grep 'task child merge/readiness refused' "$target" 'parent did not receive the refusal'
      grep -Eq '^blocked( \[[^]]*\])*: ' "$target" || fail 'parent refusal was not a blocked event'
      assert_grep 'bin/fm-pr-check.sh recovery steps' "$target" 'parent refusal lost its recovery pointer'
      [ "$(grep -c 'task child merge/readiness refused' "$target")" = 1 ] \
        || fail 'legacy ledger repeated the recovery notice'
      assert_no_regex '^done' "$target" 'legacy ledger claimed readiness without destination proof'
      [ "$(outcome_count "$MATE" reported)" = 0 ] || fail 'legacy refusal became a terminal outcome'
      [ ! -s "$WORLD/forge.log" ] || fail 'missing task destination triggered a forge lookup'
    done
  done
  pass 'legacy terminal ledgers report missing-base refusal once on either parent route'
}

test_legacy_ledger_reports_missing_base_once
test_main_direct_terminal_presentation_receipt
test_busy_agent_withholds_terminal_outcome
test_relaunched_idle_agent_withholds_terminal_outcome
test_idle_finished_agent_keeps_terminal_outcome
test_idle_agent_with_rewritten_meta_keeps_terminal_outcome
test_dead_agent_keeps_terminal_outcome
test_branch_ack_retires_inactive_outcome_receipt
test_unpushed_ci_ready_done_is_not_published
test_local_done_head_is_pinned_before_parent_delivery
test_delivered_ledger_done_skips_git_gate
test_local_secondmate_delivers_terminal_ledger_line
test_secondmate_multiline_terminal_outcome_is_delivered_once
test_secondmate_unterminated_prose_reports_run_outcome
test_inactive_receipt_ignores_later_status_prose
test_busy_child_does_not_starve_later_ledger_outcomes
test_stalled_base_read_does_not_starve_later_ledger_outcomes
test_several_stalled_base_reads_resume_before_later_ledger_outcomes
test_readiness_deadline_owns_forge_processes_on_both_paths
test_deadline_truncated_run_read_has_no_verdict
test_forced_cadence_visit_keeps_floor_after_ledger_deadline
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
test_stalled_liveness_read_is_bounded_and_scan_progresses
test_full_scan_budget_includes_wake_lock_wait
test_notice_recovery_does_not_duplicate_wake
test_missing_parent_binding_names_itself
test_reconciliation_never_calls_forge
test_reconciliation_sets_no_forge_mode_for_state_read
test_terminal_outcome_never_names_a_pr_the_run_did_not_open
test_run_step_destination_has_one_publication_boundary
test_terminal_outcome_takes_the_pr_its_run_opened
test_status_log_sourced_outcome_keeps_its_own_pr
test_status_log_outcome_keeps_gitlab_and_gerrit_reviews
test_status_log_outcome_never_borrows_an_earlier_pr
test_status_log_outcome_never_borrows_the_fresh_last_line_pr
test_status_log_outcome_never_claims_a_mentioned_pr
test_scout_outcome_carries_no_pull_request
test_contradicted_failure_is_not_promoted_for_presentation
test_contradicted_success_is_not_promoted_for_presentation
test_run_step_failure_is_not_suppressed_by_the_crews_own_word
test_stale_pause_does_not_suppress_the_failure
test_uncontradicted_failure_is_still_presented

echo "all inactive reconciliation tests passed"
