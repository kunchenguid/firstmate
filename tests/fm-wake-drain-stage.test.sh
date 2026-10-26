#!/usr/bin/env bash
# tests/fm-wake-drain-stage.test.sh - the drain's staged presentation and its
# commit (bin/fm-wake-drain.sh --stage / --commit-stage, docs/watcher-continuity.md
# "Pre-drained wakes and the turn-end acknowledgement"). Portable: the real
# drain over a crafted queue and status logs, no harness. Pins that a staged
# presentation commits nothing a later drain would not present again (rows,
# the recovery episode, and the UNREAD STATUS cursor), that the acknowledgement
# that commits it consumes exactly what was staged, and that the cursor commit
# never moves backwards past a presentation made in between.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-stage-tests)

mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

drain() {  # <state> [args...]
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" "$DRAIN" "$@"
}

prime_cursor() {  # <state> <status-file>
  printf 'note: bootstrap cursor line\n' > "$2"
  drain "$1" >/dev/null 2>/dev/null || fail "bootstrap drain failed while priming the cursor"
}

receipt_field() {  # <receipt> <key>
  sed -n "s/^$2=//p" "$1" | head -n 1
}

marker() {  # <state>
  cat "$1/.watcher-down" 2>/dev/null || true
}

test_stage_presents_without_committing() {
  local dir state out receipt
  dir=$(make_case stage-no-commit)
  state="$dir/state"
  receipt="$state/receipt"
  prime_cursor "$state" "$state/t1.status"
  printf 'note: captain said hello\n' >> "$state/t1.status"
  append_wake "$state" check rearm "check: something queued"

  out=$(drain "$state" --stage "$receipt" 2>"$dir/stage.err") || fail "staged drain failed: $(cat "$dir/stage.err")"
  grep -F 'check: something queued' <<<"$out" >/dev/null || fail "the staged presentation must show the queued row: $out"
  grep -F 't1 note: captain said hello' <<<"$out" >/dev/null || fail "the staged presentation must show the unread status line: $out"
  [ ! -s "$dir/stage.err" ] || fail "a staged drain must print no WAKE_ACK_REQUIRED or notice: $(cat "$dir/stage.err")"
  [ -f "$receipt" ] || fail "the staged drain must write its receipt"
  [ "$(receipt_field "$receipt" ack_through)" = 1 ] || fail "the receipt must name the presented sequence: $(cat "$receipt")"
  [ -n "$(receipt_field "$receipt" recovery_generation)" ] || fail "the receipt must name the recovery generation: $(cat "$receipt")"
  grep -q "^status	t1	" "$receipt" || fail "the receipt must carry the staged status endpoint: $(cat "$receipt")"
  case "$(marker "$state")" in
    pending:downtime:*) ;;
    *) fail "a staged drain must leave the recovery episode in downtime, got: $(marker "$state")" ;;
  esac

  out=$(drain "$state" 2>/dev/null) || fail "plain drain after staging failed"
  grep -F 'check: something queued' <<<"$out" >/dev/null || fail "a plain drain after staging must still present the row: $out"
  grep -F 't1 note: captain said hello' <<<"$out" >/dev/null || fail "a plain drain after staging must still present the unread line: $out"
  pass "stage presents the wake and commits neither the rows, the episode, nor the status cursor"
}

test_commit_stage_consumes_exactly_what_was_staged() {
  local dir state out receipt gen
  dir=$(make_case stage-commit)
  state="$dir/state"
  receipt="$state/receipt"
  prime_cursor "$state" "$state/t1.status"
  printf 'note: captain said hello\n' >> "$state/t1.status"
  append_wake "$state" check rearm "check: something queued"
  drain "$state" --stage "$receipt" >/dev/null 2>&1 || fail "staged drain failed"
  gen=$(receipt_field "$receipt" recovery_generation)

  drain "$state" --ack-through 1 --recovery-generation "$gen" --commit-stage "$receipt" >/dev/null 2>"$dir/ack.err" \
    || fail "acknowledgement with --commit-stage failed: $(cat "$dir/ack.err")"
  [ ! -e "$receipt" ] || fail "the receipt must be removed once committed"
  [ ! -s "$state/.wake-queue" ] || fail "the acknowledged row must be consumed: $(cat "$state/.wake-queue")"
  case "$(marker "$state")" in
    acked:*) ;;
    *) fail "the episode must be acknowledged, got: $(marker "$state")" ;;
  esac
  out=$(drain "$state" 2>/dev/null) || fail "plain drain after commit failed"
  if grep -F 'captain said hello' <<<"$out" >/dev/null; then
    fail "a committed UNREAD STATUS line was presented again: $out"
  fi
  [ -z "$out" ] || fail "a plain drain after commit must present nothing, got: $out"
  pass "the acknowledgement commits the staged cursor and consumes the staged rows"
}

test_empty_queue_stage_commits_alone() {
  local dir state out receipt
  dir=$(make_case stage-empty-queue)
  state="$dir/state"
  receipt="$state/receipt"
  prime_cursor "$state" "$state/t1.status"
  printf 'note: unread with nothing queued\n' >> "$state/t1.status"

  out=$(drain "$state" --stage "$receipt" 2>/dev/null) || fail "staged drain on an empty queue failed"
  grep -F 'unread with nothing queued' <<<"$out" >/dev/null || fail "the staged presentation must show the unread line: $out"
  [ "$(receipt_field "$receipt" ack_through)" = 0 ] || fail "an empty queue stages ack_through=0: $(cat "$receipt")"
  [ -z "$(receipt_field "$receipt" recovery_generation)" ] || fail "no open episode means no generation to acknowledge: $(cat "$receipt")"

  drain "$state" --commit-stage "$receipt" >/dev/null 2>"$dir/commit.err" || fail "standalone --commit-stage failed: $(cat "$dir/commit.err")"
  [ ! -e "$receipt" ] || fail "the receipt must be removed once committed"
  out=$(drain "$state" 2>/dev/null) || fail "plain drain after standalone commit failed"
  [ -z "$out" ] || fail "the committed unread line was presented again: $out"
  pass "an empty-queue stage is committed alone and its unread lines are not replayed"
}

test_stage_with_nothing_to_present_prints_nothing() {
  local dir state out receipt
  dir=$(make_case stage-nothing)
  state="$dir/state"
  receipt="$state/receipt"
  prime_cursor "$state" "$state/t1.status"
  out=$(drain "$state" --stage "$receipt" 2>"$dir/stage.err") || fail "staged drain with nothing to present failed"
  [ -z "$out" ] || fail "nothing queued or unread must stage an empty presentation, got: $out"
  [ ! -s "$dir/stage.err" ] || fail "nothing to present must leave stderr empty: $(cat "$dir/stage.err")"
  [ -f "$receipt" ] || fail "a receipt is written even for an empty presentation"
  pass "a stage with nothing to present prints nothing and still writes its receipt"
}

test_stage_commit_never_moves_the_cursor_backwards() {
  local dir state out receipt
  dir=$(make_case stage-monotonic)
  state="$dir/state"
  receipt="$state/receipt"
  prime_cursor "$state" "$state/t1.status"
  printf 'note: first unread\n' >> "$state/t1.status"
  drain "$state" --stage "$receipt" >/dev/null 2>&1 || fail "staged drain failed"
  printf 'note: second unread, after staging\n' >> "$state/t1.status"
  out=$(drain "$state" 2>/dev/null) || fail "plain drain between stage and commit failed"
  grep -F 'second unread' <<<"$out" >/dev/null || fail "setup: the plain drain must present the later line: $out"

  drain "$state" --commit-stage "$receipt" >/dev/null 2>&1 || fail "commit after a later plain drain failed"
  out=$(drain "$state" 2>/dev/null) || fail "plain drain after commit failed"
  if grep -F 'second unread' <<<"$out" >/dev/null; then
    fail "committing an older stage moved the cursor backwards and replayed a later presentation: $out"
  fi
  pass "committing a stage never regresses a cursor a later drain advanced"
}

test_stage_leaves_an_announced_episode_for_the_commit() {
  local dir state receipt gen
  dir=$(make_case stage-episode-generation)
  state="$dir/state"
  receipt="$state/receipt"
  append_wake "$state" signal t1.status "signal: t1.status done: fixture"
  drain "$state" --stage "$receipt" >/dev/null 2>&1 || fail "staged drain failed"
  gen=$(receipt_field "$receipt" recovery_generation)
  [ "$(marker "$state")" = "pending:downtime:$gen" ] \
    || fail "the receipt's generation must be the untouched downtime episode: marker=$(marker "$state") receipt=$gen"
  drain "$state" --ack-through 1 --recovery-generation "$gen" --commit-stage "$receipt" >/dev/null 2>&1 \
    || fail "acknowledging the staged episode failed"
  [ "$(marker "$state")" = "acked:downtime:$gen" ] || fail "the staged episode must acknowledge by its generation: $(marker "$state")"
  pass "the staged receipt names the live episode and its acknowledgement retires it"
}

test_stage_refuses_a_branch_actor() {
  local dir state rc=0
  dir=$(make_case stage-branch-actor)
  state="$dir/state"
  FM_SUPERVISION_ACTOR=branch FM_STATE_OVERRIDE="$state" "$DRAIN" --stage "$state/receipt" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "a branch actor must not stage a main presentation, got $rc"
  [ ! -e "$state/receipt" ] || fail "a refused stage must write no receipt"
  pass "only the main actor stages a presentation"
}

test_stage_presents_without_committing
test_commit_stage_consumes_exactly_what_was_staged
test_empty_queue_stage_commits_alone
test_stage_with_nothing_to_present_prints_nothing
test_stage_commit_never_moves_the_cursor_backwards
test_stage_leaves_an_announced_episode_for_the_commit
test_stage_refuses_a_branch_actor
