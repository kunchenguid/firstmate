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
#   (e) the same skip-live flag also reaches the herdr-native busy check, the
#       remote-secondmate state check, and the grok fallback capture - not
#       just pane_readable - so none of those three live round trips doubles
#       up with peek's own capture either
#   (f) a caller that also supplies a precaptured tail alongside skip-live
#       recovers a recordless, log-less grok worker's real state from that
#       text instead of leaving it unknown
#   (g) bin/fm-peek.sh actually wires (f) end to end: its own raw capture is
#       what the projection annotation reads, so peek and crew-state cannot
#       structurally disagree even in that recordless/log-less case, and
#       peek still makes exactly one live call and prints an unchanged raw
#       capture on stdout
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

test_skip_live_grok_falls_back_to_status_log() {
  local d fb record_live record_skip
  d=$(new_case skip-live-grok-status); fb=$(make_fake_tmux "$d")
  make_repo_on_branch "$d/wt" fm/feat-grokstatus
  fm_write_meta "$d/state/feat-grokstatus.meta" "window=fm:fm-feat-grokstatus" "worktree=$d/wt" "kind=scout" "harness=grok"
  printf 'working: implementing the fix\n' > "$d/state/feat-grokstatus.status"

  # Without skip-live, grok's own live tail capture runs, finds no busy
  # signature (make_fake_tmux's default idle text), and the idle verdict
  # falls through to the status log's working verb.
  record_live=$(PATH="$fb:$PATH" FM_STATE_OVERRIDE="$d/state" fm_worker_state_project feat-grokstatus 0)
  assert_contains "$record_live" $'\nstate=working' "sanity: without skip-live, grok's idle tail falls through to the status log"
  assert_contains "$record_live" $'\nsource=status-log' "sanity: without skip-live, the status log is the answering tier"

  # With skip-live (fm-peek.sh), the grok arm cannot make its own live capture
  # and fm_busy_classify reports `unknown live-probe-skipped` - a deliberate
  # non-answer, not a genuine "tried and failed" unknown. It must fall through
  # to the exact same status-log tier rather than being treated as an
  # authoritative pane-tier unknown, or peek and crew-state would structurally
  # disagree about this worker's state.
  record_skip=$(PATH="$fb:$PATH" FM_STATE_OVERRIDE="$d/state" fm_worker_state_project feat-grokstatus 1)
  assert_contains "$record_skip" $'\nstate=working' "skip-live grok falls through unknown live-probe-skipped to the status log"
  assert_contains "$record_skip" $'\nsource=status-log' "skip-live grok's answering tier matches crew-state's, not a premature pane unknown"

  pass "skip-live grok's deliberately-skipped probe falls through to the status-log tier instead of masking it as unknown"
}

# --- (e) skip-live also gates the herdr-native, remote-secondmate, and grok
#         fallback live paths, not just pane_readable ------------------------

test_skip_live_skips_herdr_native_busy_probe() {
  local d call_log record
  d=$(new_case skip-live-herdr)
  make_repo_on_branch "$d/wt" fm/feat-herdr
  fm_write_meta "$d/state/feat-herdr.meta" "worktree=$d/wt" "kind=scout" "harness=claude" "backend=herdr" "window=s:p"
  call_log="$d/herdr-busy.log"; : > "$call_log"
  # pane_readable's own herdr-backed live probe (a separate call this same
  # skip-live flag already gates) must succeed for either call below to reach
  # crew_busy_verdict at all.
  # shellcheck disable=SC2329 # invoked indirectly through pane_readable
  fm_backend_capture() { return 0; }
  # shellcheck disable=SC2329 # invoked indirectly through fm_worker_state_project -> fm_busy_classify
  fm_backend_busy_state() { printf '%s\n' "$*" >> "$call_log"; printf 'busy'; }

  record=$(FM_STATE_OVERRIDE="$d/state" fm_worker_state_project feat-herdr 1)
  [ "$(wc -l < "$call_log" | tr -d ' ')" = 0 ] \
    || fail "skip-live must not call the herdr-native busy-state check, got:"$'\n'"$(cat "$call_log")"
  assert_contains "$record" $'\nsource=pane' "skip-live still emits a pane-tier record with no other signal"

  record=$(FM_STATE_OVERRIDE="$d/state" fm_worker_state_project feat-herdr 0)
  [ "$(wc -l < "$call_log" | tr -d ' ')" = 1 ] \
    || fail "sanity: without skip-live, the herdr-native busy-state check should fire exactly once, got:"$'\n'"$(cat "$call_log")"
  unset -f fm_backend_capture fm_backend_busy_state
  pass "skip-live also skips fm_busy_classify's herdr-native busy-state round trip"
}

test_skip_live_skips_remote_secondmate_state_probe() {
  local d ssh_log record_live record_skip
  d=$(new_case skip-live-remote)
  mkdir -p "$d/data" "$d/fakebin"
  fm_write_meta "$d/state/rsm.meta" \
    "worktree=/remote/home/never-locally-present" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate" \
    "remote_host=remote-mac" \
    "remote_root=/remote/root" \
    "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:w1:p1"
  cat > "$d/data/secondmates.md" <<EOF
- rsm - remote test domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-08-02)
EOF
  cat > "$d/fakebin/fake-ssh" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
[ -z "${FM_FAKE_SSH_LOG:-}" ] || printf 'call\n' >> "$FM_FAKE_SSH_LOG"
printf 'alive\n'
exit 0
SH
  chmod +x "$d/fakebin/fake-ssh"

  ssh_log="$d/ssh-live.log"; : > "$ssh_log"
  record_live=$(FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" FM_SSH_BIN="$d/fakebin/fake-ssh" \
    FM_FAKE_SSH_LOG="$ssh_log" fm_worker_state_project rsm 0)
  [ "$(wc -l < "$ssh_log" | tr -d ' ')" = 1 ] \
    || fail "sanity: without skip-live, the remote-secondmate state round trip should fire exactly once, got:"$'\n'"$(cat "$ssh_log")"
  assert_contains "$record_live" $'\nsource=remote-endpoint' "sanity: a live alive verdict with no log reads remote-endpoint"

  ssh_log="$d/ssh-skip.log"; : > "$ssh_log"
  record_skip=$(FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" FM_SSH_BIN="$d/fakebin/fake-ssh" \
    FM_FAKE_SSH_LOG="$ssh_log" fm_worker_state_project rsm 1)
  [ "$(wc -l < "$ssh_log" | tr -d ' ')" = 0 ] \
    || fail "skip-live must not make the remote-secondmate state round trip, got:"$'\n'"$(cat "$ssh_log")"
  assert_contains "$record_skip" $'\nsource=remote-endpoint' "skip-live remote falls back to remote-endpoint source without a live probe"
  pass "skip-live also skips fm_worker_state_project's remote-secondmate state round trip"
}

test_skip_live_skips_grok_fallback_capture() {
  local d capture_log out
  d=$(new_case skip-live-grok)
  capture_log="$d/grok-capture.log"; : > "$capture_log"
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify
  fm_backend_capture() { printf '%s\n' "$*" >> "$capture_log"; printf 'Ctrl+c:cancel\n'; }

  out=$(fm_busy_classify tmux w1 grok t1 "$d/state" '' 1)
  [ "$out" = "unknown live-probe-skipped" ] \
    || fail "skip-live grok arm with no pre-captured tail must report unknown live-probe-skipped, got '$out'"
  [ "$(wc -l < "$capture_log" | tr -d ' ')" = 0 ] \
    || fail "skip-live must not make the grok fallback live capture, got:"$'\n'"$(cat "$capture_log")"

  out=$(fm_busy_classify tmux w1 grok t1 "$d/state")
  [ "$out" = "busy grok-regex" ] \
    || fail "sanity: without skip-live, the grok arm should fall back to its own live capture, got '$out'"
  [ "$(wc -l < "$capture_log" | tr -d ' ')" = 1 ] \
    || fail "sanity: without skip-live exactly 1 live capture call should be made, got:"$'\n'"$(cat "$capture_log")"
  unset -f fm_backend_capture
  pass "skip-live also skips fm_busy_classify's grok fallback live capture"
}

test_skip_live_grok_with_no_status_log_reports_skipped_pane_provenance() {
  local d fb capture_log record_live record_skip
  d=$(new_case skip-live-grok-nolog); fb=$(make_fake_tmux "$d")
  make_repo_on_branch "$d/wt" fm/feat-groknolog
  fm_write_meta "$d/state/feat-groknolog.meta" "window=fm:fm-feat-groknolog" "worktree=$d/wt" "kind=scout" "harness=grok"
  # No busy record, no no-mistakes run, and (unlike
  # test_skip_live_grok_falls_back_to_status_log) no status log either: for a
  # recordless grok worker the live pane tail is the ONLY source of truth, so
  # this is the case the skip-live/status-log fallback above cannot answer
  # WITHOUT a precaptured tail (see
  # test_skip_live_grok_precaptured_tail_resolves_no_status_log below for the
  # case where the caller supplies one, as bin/fm-peek.sh now does).
  capture_log="$d/grok-capture.log"; : > "$capture_log"
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify
  fm_backend_capture() { printf '%s\n' "$*" >> "$capture_log"; printf 'Ctrl+c:cancel\n'; }

  # Sanity: without skip-live, crew-state's own live tail capture sees the
  # busy signature and reports working from the pane tier.
  record_live=$(PATH="$fb:$PATH" FM_STATE_OVERRIDE="$d/state" fm_worker_state_project feat-groknolog 0)
  assert_contains "$record_live" $'\nstate=working' "sanity: without skip-live, grok's busy tail reports working"
  assert_contains "$record_live" $'\nsource=pane' "sanity: without skip-live, the pane tier answers"

  # With skip-live and no precaptured tail, the grok arm never makes its own
  # capture and there is no status log to fall back to, so the projection
  # cannot recover the true state. It must still report source=pane with a
  # detail naming the skipped probe - never source=none, which would claim no
  # source existed at all rather than one that was deliberately not read.
  record_skip=$(PATH="$fb:$PATH" FM_STATE_OVERRIDE="$d/state" fm_worker_state_project feat-groknolog 1)
  assert_contains "$record_skip" $'\nstate=unknown' "skip-live grok with no status log cannot recover the true state"
  assert_contains "$record_skip" $'\nsource=pane' "skip-live grok's unresolved unknown still carries pane provenance, not source=none"
  assert_contains "$record_skip" "skipped" "skip-live grok's detail names the skipped live probe rather than a generic no-source message"
  [ "$(wc -l < "$capture_log" | tr -d ' ')" = 1 ] \
    || fail "skip-live must still make exactly the sanity call above and no more, got:"$'\n'"$(cat "$capture_log")"

  unset -f fm_backend_capture
  pass "skip-live grok with no corroborating status log reports unknown with pane provenance, not source=none"
}

# --- (f) a precaptured tail lets skip-live recover the case (e) above cannot -

test_skip_live_grok_precaptured_tail_resolves_no_status_log() {
  local d fb capture_log record_skip
  d=$(new_case skip-live-grok-precaptured); fb=$(make_fake_tmux "$d")
  make_repo_on_branch "$d/wt" fm/feat-grokprecap
  fm_write_meta "$d/state/feat-grokprecap.meta" "window=fm:fm-feat-grokprecap" "worktree=$d/wt" "kind=scout" "harness=grok"
  # Same unrecoverable setup as the no-precaptured-tail case above (no record,
  # no run, no status log) - the only difference is the caller (bin/fm-peek.sh)
  # already made its own live capture and passes it through as the third
  # argument instead of leaving the grok arm to skip the check.
  capture_log="$d/grok-capture.log"; : > "$capture_log"
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify if this fires, the tail was NOT reused
  fm_backend_capture() { printf '%s\n' "$*" >> "$capture_log"; printf 'Ctrl+c:cancel\n'; }

  record_skip=$(PATH="$fb:$PATH" FM_STATE_OVERRIDE="$d/state" fm_worker_state_project feat-grokprecap 1 $'thinking...\nCtrl+c:cancel')
  assert_contains "$record_skip" $'\nstate=working' "a precaptured busy tail resolves the same state a live tail would have"
  assert_contains "$record_skip" $'\nsource=pane' "the precaptured tail still answers from the pane tier"
  [ "$(wc -l < "$capture_log" | tr -d ' ')" = 0 ] \
    || fail "a precaptured tail must not trigger the grok arm's own fallback live capture, got:"$'\n'"$(cat "$capture_log")"

  unset -f fm_backend_capture
  pass "a precaptured tail lets skip-live recover a recordless grok worker's true state without a second live capture"
}

# --- (g) end to end: bin/fm-peek.sh actually reuses its own raw capture -----

# A fake tmux whose capture-pane answers with Grok's default busy signature
# ("Ctrl+c:cancel") rather than make_fake_tmux's generic busy text, so a real
# fm-peek.sh/fm-crew-state.sh invocation exercises the grok tail-busy check.
make_fake_tmux_grok() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_TMUX_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'thinking...\nCtrl+c:cancel\n' ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

test_peek_reuses_its_own_capture_to_resolve_recordless_grok_worker() {
  local d fb tmux_log crew_out peek_err peek_out peek_annotation
  d=$(new_case peek-grok-precaptured); fb=$(make_fake_tmux_grok "$d")
  make_repo_on_branch "$d/wt" fm/feat-grokpeek
  fm_write_meta "$d/state/feat-grokpeek.meta" "window=fm:fm-feat-grokpeek" "worktree=$d/wt" "kind=scout" "harness=grok"
  # No busy record, no no-mistakes run, no status log: the live pane tail is
  # the only source of truth, exactly the case
  # test_skip_live_grok_with_no_status_log_reports_skipped_pane_provenance
  # documents as unrecoverable when no precaptured tail is available.

  tmux_log="$d/crew-tmux.log"; : > "$tmux_log"
  crew_out=$(PATH="$fb:$PATH" FM_STATE_OVERRIDE="$d/state" FM_FAKE_TMUX_LOG="$tmux_log" "$CREW_STATE" feat-grokpeek)
  assert_contains "$crew_out" "state: working" "sanity: crew-state's own live tail capture sees the grok busy signature"
  assert_contains "$crew_out" "source: pane" "sanity: crew-state answers from the pane tier"

  tmux_log="$d/peek-tmux.log"; : > "$tmux_log"
  peek_out=$(PATH="$fb:$PATH" FM_STATE_OVERRIDE="$d/state" FM_FAKE_TMUX_LOG="$tmux_log" "$PEEK" feat-grokpeek 5 2>"$d/peek.err")
  peek_err=$(cat "$d/peek.err")
  peek_annotation=$(printf '%s\n' "$peek_err" | grep '^state: ')

  [ "$peek_annotation" = "$crew_out" ] \
    || fail "peek's annotation should reuse its own raw capture to resolve the same state crew-state reports, not report unknown"$'\n'"crew-state: $crew_out"$'\n'"peek:       $peek_annotation"
  [ "$peek_out" = "$(printf 'thinking...\nCtrl+c:cancel')" ] \
    || fail "peek's stdout must stay the exact raw pane capture regardless of the projection annotation, got '$peek_out'"
  [ "$(wc -l < "$tmux_log" | tr -d ' ')" = 1 ] \
    || fail "peek should make exactly 1 live tmux call (its own raw capture, reused for the projection), got:"$'\n'"$(cat "$tmux_log")"

  pass "fm-peek.sh reuses its own raw capture to resolve a recordless grok worker's state instead of leaving it unknown"
}

test_record_carries_source_and_computed_at
test_render_line_matches_documented_shape
test_render_line_omits_empty_detail
test_crew_state_and_peek_report_byte_identical_lines
test_peek_skips_the_live_probe_crew_state_still_makes
test_skip_live_grok_falls_back_to_status_log
test_skip_live_grok_with_no_status_log_reports_skipped_pane_provenance
test_skip_live_grok_precaptured_tail_resolves_no_status_log
test_skip_live_skips_herdr_native_busy_probe
test_skip_live_skips_remote_secondmate_state_probe
test_skip_live_skips_grok_fallback_capture
test_peek_reuses_its_own_capture_to_resolve_recordless_grok_worker

echo "all fm-worker-state-lib tests passed"
