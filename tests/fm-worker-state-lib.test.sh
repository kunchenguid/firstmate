#!/usr/bin/env bash
# Behavior tests for bin/fm-worker-state-lib.sh - the one computed
# worker-state projection that bin/fm-crew-state.sh and bin/fm-peek.sh both
# render, instead of each independently re-deriving a worker's state.
#
# bin/fm-crew-state.test.sh already pins every branch of the reconciliation
# logic itself (moved here verbatim), so these cases stay narrowly focused on
# what this workstream actually adds:
#   (a) the record carries a source and a computed_at instant for every state
#   (b) fm_worker_state_render_line renders exactly the documented line
#   (c) bin/fm-crew-state.sh and bin/fm-peek.sh, called independently for the
#       SAME worker at the SAME instant, report byte-identical state and
#       source - they cannot structurally disagree, because both render the
#       one function's output rather than two separate computations
#   (d) bin/fm-peek.sh's projection call skips the live pane/busy probe
#       (it is about to make that exact live capture itself), so peeking a
#       no-run worker never doubles a live backend round-trip
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-worker-state-lib.sh"

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
PEEK="$ROOT/bin/fm-peek.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-state-lib)
fm_git_identity fmtest fmtest@example.invalid

new_case() {  # <name> -> echoes case dir with an empty state/
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s\n' "$d"
}

make_repo_on_branch() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
}

# A fake tmux that answers display-message/capture-pane and appends one line
# per invocation to $FM_FAKE_TMUX_LOG, so a test can count exactly how many
# live probes a script made.
make_fake_tmux() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_TMUX_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane)
    if [ "${FM_FAKE_BUSY:-0}" = 1 ]; then printf 'work in progress\nesc to interrupt\n'
    else printf 'all quiet\n> \n'; fi ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# --- (a) the record carries source and computed_at for every state ---------

test_record_carries_source_and_computed_at() {
  local d record
  d=$(new_case no-meta)
  record=$(FM_STATE_OVERRIDE="$d/state" fm_worker_state_project missing-id)
  assert_contains "$record" $'\nstate=unknown' "an id with no meta projects state=unknown"
  assert_contains "$record" $'\nsource=none' "an id with no meta projects source=none"
  case "$record" in
    *$'\ncomputed_at='????-??-??T??:??:??Z*) : ;;
    *) fail "record is missing a UTC ISO-8601 computed_at instant"$'\n'"--- record ---"$'\n'"$record" ;;
  esac
  pass "fm_worker_state_project: every record carries its source and a computed_at instant"
}

# --- (b) fm_worker_state_render_line renders the documented line exactly ---

test_render_line_matches_documented_shape() {
  local record out
  record=$'id=feat-x\nstate=working\nsource=pane\ndetail=harness busy (claude-hook)\ncomputed_at=2026-01-01T00:00:00Z'
  out=$(fm_worker_state_render_line "$record")
  [ "$out" = "state: working · source: pane · harness busy (claude-hook)" ] \
    || fail "render_line did not match the documented shape, got '$out'"
  pass "fm_worker_state_render_line: renders the documented state/source/detail line"
}

test_render_line_omits_empty_detail() {
  local record out
  record=$'id=feat-y\nstate=unknown\nsource=none\ndetail=\ncomputed_at=2026-01-01T00:00:00Z'
  out=$(fm_worker_state_render_line "$record")
  [ "$out" = "state: unknown · source: none" ] \
    || fail "render_line should omit an empty detail, got '$out'"
  pass "fm_worker_state_render_line: omits an empty detail field"
}

# --- (c) fm-crew-state.sh and fm-peek.sh cannot structurally disagree ------

test_crew_state_and_peek_report_byte_identical_lines() {
  local d fb tmux_log crew_out peek_err peek_annotation gen
  d=$(new_case agree); fb=$(make_fake_tmux "$d")
  make_repo_on_branch "$d/wt" fm/feat-agree
  fm_write_meta "$d/state/feat-agree.meta" "window=fm:fm-feat-agree" "worktree=$d/wt" "kind=scout" "harness=claude"
  tmux_log="$d/tmux.log"; : > "$tmux_log"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-agree)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-agree busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit

  crew_out=$(PATH="$fb:$PATH" FM_STATE_OVERRIDE="$d/state" FM_FAKE_TMUX_LOG="$tmux_log" "$CREW_STATE" feat-agree)
  # fm-guard.sh (called unconditionally by fm-peek.sh) reads the REAL
  # firstmate home's own tangle/watcher state and can print its own unrelated
  # multi-line banner to stderr alongside the annotation - isolate the one
  # line this test actually cares about instead of coupling to guard silence.
  peek_err=$(PATH="$fb:$PATH" FM_STATE_OVERRIDE="$d/state" FM_FAKE_TMUX_LOG="$tmux_log" "$PEEK" feat-agree 5 2>&1 1>/dev/null)
  peek_annotation=$(printf '%s\n' "$peek_err" | grep '^state: ')

  assert_contains "$crew_out" "state: working" "sanity: crew-state should read the armed busy record as working"
  [ -n "$peek_annotation" ] || fail "fm-peek printed no state annotation to stderr"$'\n'"--- stderr ---"$'\n'"$peek_err"
  [ "$peek_annotation" = "$crew_out" ] \
    || fail "peek's annotation and crew-state's line disagree for the same worker at the same instant"$'\n'"crew-state: $crew_out"$'\n'"peek:       $peek_annotation"
  pass "fm-crew-state.sh and fm-peek.sh render byte-identical state/source lines for the same worker"
}

# --- (d) peek's projection skips the live probe it is about to make itself -

test_peek_skips_the_live_probe_crew_state_still_makes() {
  local d fb crew_log peek_log crew_out peek_out
  d=$(new_case skip-live); fb=$(make_fake_tmux "$d")
  make_repo_on_branch "$d/wt" fm/feat-skiplive
  fm_write_meta "$d/state/feat-skiplive.meta" "window=fm:fm-feat-skiplive" "worktree=$d/wt" "kind=scout" "harness=claude"
  # No busy record and no no-mistakes run: crew-state's ONLY remaining signal
  # is a live pane_readable + busy check.
  crew_log="$d/crew-tmux.log"; : > "$crew_log"
  crew_out=$(PATH="$fb:$PATH" FM_STATE_OVERRIDE="$d/state" FM_FAKE_TMUX_LOG="$crew_log" "$CREW_STATE" feat-skiplive)
  assert_contains "$crew_out" "source: pane" "crew-state falls back to a live pane readability check with no other signal"
  [ "$(wc -l < "$crew_log" | tr -d ' ')" = 1 ] \
    || fail "crew-state should make exactly 1 live tmux call (the readability probe; the busy verdict is a record-file read with no record present), got:"$'\n'"$(cat "$crew_log")"

  peek_log="$d/peek-tmux.log"; : > "$peek_log"
  peek_out=$(PATH="$fb:$PATH" FM_STATE_OVERRIDE="$d/state" FM_FAKE_TMUX_LOG="$peek_log" "$PEEK" feat-skiplive 5 1>/dev/null 2>&1; cat "$peek_log")
  [ "$(wc -l < "$peek_log" | tr -d ' ')" = 1 ] \
    || fail "peek should make exactly 1 live tmux call (its own raw capture only, no duplicate probe), got:"$'\n'"$peek_out"
  pass "fm-peek.sh's annotation skips the live probe it is about to make itself as its own raw capture"
}

test_record_carries_source_and_computed_at
test_render_line_matches_documented_shape
test_render_line_omits_empty_detail
test_crew_state_and_peek_report_byte_identical_lines
test_peek_skips_the_live_probe_crew_state_still_makes

echo "all fm-worker-state-lib tests passed"
