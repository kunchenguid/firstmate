#!/usr/bin/env bash
# A cleanup that retires a task record while the watcher's pane sweep is already
# working through the inventory it took must not cost a supervisor turn, and must
# not leave that endpoint's watcher markers behind (bin/fm-watch.sh,
# bin/fm-watch-key-lib.sh). Shared fixtures live in tests/watch-triage-helpers.sh.
#
# Origin: on 2026-11-10 a freed endpoint delivered one `stale:` notification
# immediately after its own task's cleanup. state/.watch-deliveries.log's final
# row recorded it directly after the row for that task's completion signal, no
# state/<id>.meta named the endpoint, state/.watch-triage.log had no
# classification row absorbing it, and the durable wake queue was already empty
# with no acknowledgement pending - so it was delivered, and it cost one
# supervisor turn for work that was cleaned up and gone.
#
# The sweep enumerates its endpoints from the task records once per cycle
# (recorded_windows in bin/fm-watch.sh), so a record removed mid-cycle leaves the
# rest of that cycle classifying an endpoint that is no longer this home's. These
# cases inject that retirement at the two points a real cleanup can land: while
# the sweep is capturing the pane, and while it is classifying the capture.
#
# Both directions are pinned, because a guard that only proved the quiet
# direction would be indistinguishable from deleting stale detection: the control
# lane keeps the record standing and must still deliver the very same wake.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-endpoint-retirement-tests)
mkdir -p "$TMP_ROOT/crew-state-bin"
FM_CREW_STATE_BIN=$(make_fake_crew_state "$TMP_ROOT/crew-state-bin")
export FM_CREW_STATE_BIN

CASE_WINDOW="test:fm-freed"

# One endpoint stably stale at its recorded hash, with a non-terminal status and
# no provably-working verdict: the population surface_nonterminal_stale owns, and
# the shape that delivered the 2026-11-10 notification. Echoes the case directory.
make_stale_endpoint_case() {  # <name>
  local dir state capture_file key
  dir=$(make_case "$1"); state="$dir/state"
  capture_file="$dir/pane.txt"
  printf 'idle prompt, finished' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$CASE_WINDOW" > "$state/freed.meta"
  printf 'working: implementing\n' > "$state/freed.status"
  # Primed so the signal scan does not pre-empt the stale path, exactly as the
  # suite this fixture is modeled on does.
  printf '%s' "$(seen_sig "$state/freed.status")" > "$state/.seen-freed_status"
  key=$(watch_window_key "$CASE_WINDOW")
  printf '%s' "$(hash_text "idle prompt, finished")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' "$dir"
}

# Install a fake tmux that retires <meta> while serving capture-pane, modeling a
# cleanup that removed the task record during the sweep's slowest step. The stock
# fake is kept and delegated to, so every other tmux surface is unchanged.
retire_meta_on_capture() {  # <case-dir> <meta>
  local dir=$1 meta=$2
  mv "$dir/fakebin/tmux" "$dir/fakebin/tmux-stock"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = capture-pane ] && [ -n "${FM_TEST_RETIRE_META:-}" ]; then
  rm -f "$FM_TEST_RETIRE_META"
fi
exec "$0-stock" "$@"
SH
  chmod +x "$dir/fakebin/tmux"
  printf '%s\n' "$meta" > "$dir/retire-meta.path"
}

# Install a fake fm-crew-state.sh that retires <meta> on a current-state read,
# modeling a cleanup that landed after the capture and before the classification
# finished - the window the per-route guard closes and the earlier one cannot see.
retire_meta_on_classification() {  # <case-dir> <meta>
  local dir=$1 meta=$2
  mv "$dir/fakebin/fm-crew-state.sh" "$dir/fakebin/fm-crew-state-stock.sh"
  cat > "$dir/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_TEST_RETIRE_META:-}" ] || rm -f "$FM_TEST_RETIRE_META"
exec "${0%.sh}-stock.sh" "$@"
SH
  chmod +x "$dir/fakebin/fm-crew-state.sh"
  printf '%s\n' "$meta" > "$dir/retire-meta.path"
}

# Run one watcher round for a case in the background and set ROUND_PID. The
# watcher must stay a child of THIS shell, so this is a launcher rather than a
# command substitution the caller captures a pid from.
ROUND_PID=''
launch_stale_round() {  # <case-dir>
  local dir=$1 state="$1/state" fakebin="$1/fakebin"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$CASE_WINDOW" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_TEST_RETIRE_META="$(cat "$dir/retire-meta.path" 2>/dev/null || true)" \
    FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch.out" &
  ROUND_PID=$!
}

# Count this endpoint's durable stale rows, through the queue's own field layout.
queued_stale_rows() {  # <state> <window>
  awk -F '\t' -v w="$2" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
    "$1/.wake-queue" 2>/dev/null || echo 0
}

# Every per-endpoint marker the shared family list names for this endpoint, so a
# case asserts against the production enumeration rather than its own copy of it.
endpoint_marker_paths() {  # <state>
  watcher_endpoint_markers "$1" "$CASE_WINDOW"
}

assert_endpoint_markers_gone() {  # <state> <label>
  local state=$1 label=$2 marker
  while IFS= read -r marker; do
    [ -n "$marker" ] || continue
    [ ! -e "$marker" ] || fail "$label: a retired endpoint kept $marker"
  done < <(endpoint_marker_paths "$state")
}

# --- the control lane: a recorded endpoint still alarms -----------------------
# Without this, every quiet assertion below would also pass on a watcher that
# simply stopped detecting stale panes.
test_control_lane_still_surfaces_a_recorded_endpoint() {
  local dir state out drain_out key
  dir=$(make_stale_endpoint_case control-recorded); state="$dir/state"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  key=$(watch_window_key "$CASE_WINDOW")

  launch_stale_round "$dir"
  wait_for_exit "$ROUND_PID" 100 || { reap "$ROUND_PID"; fail "control lane: the watcher did not surface a recorded stale endpoint" ; }
  grep -Fx "stale: $CASE_WINDOW" "$out" >/dev/null || fail "control lane: no stale wake was printed: $(cat "$out")"
  [ "$(queued_stale_rows "$state" "$CASE_WINDOW")" = 1 ] || fail "control lane: the stale wake was not queued"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$(hash_text "idle prompt, finished")" ] \
    || fail "control lane: the stale suppressor was not advanced on surface"
  ack_stopped_cycle "$state" || fail "control lane: could not acknowledge the intentional stop"
  pass "a recorded stale endpoint with no declared wait still surfaces at once (control lane for the retirement guards)"
}

# --- the record goes while the sweep is capturing the pane --------------------
test_no_wake_when_the_record_is_retired_during_the_capture() {
  local dir state label
  dir=$(make_stale_endpoint_case retired-during-capture); state="$dir/state"
  label="retired during capture"
  retire_meta_on_capture "$dir" "$state/freed.meta"

  launch_stale_round "$dir"
  # Two whole poll cycles, so a wake that is merely late still fails the case.
  wait_poll_cycle "$state" "$ROUND_PID" || { reap "$ROUND_PID"; fail "$label: the watcher exited instead of absorbing: $(cat "$dir/watch.out")" ; }
  wait_poll_cycle "$state" "$ROUND_PID" || { reap "$ROUND_PID"; fail "$label: the watcher exited on a later cycle: $(cat "$dir/watch.out")" ; }
  [ "$(queued_stale_rows "$state" "$CASE_WINDOW")" = 0 ] \
    || { reap "$ROUND_PID"; fail "$label: a stale wake was queued for an endpoint with no task record" ; }
  [ ! -s "$dir/watch.out" ] || { reap "$ROUND_PID"; fail "$label: the watcher printed a wake: $(cat "$dir/watch.out")" ; }
  assert_endpoint_markers_gone "$state" "$label"
  grep -Fq "retired the watcher markers of an endpoint no task record names: $CASE_WINDOW" "$state/.watch-triage.log" \
    || { reap "$ROUND_PID"; fail "$label: the retirement was not recorded in the triage log" ; }
  reap "$ROUND_PID"
  pass "a cleanup that retires a task record during the pane capture leaves no queued wake and no watcher markers for that endpoint"
}

# --- the record goes while the sweep is classifying the capture ---------------
test_no_wake_when_the_record_is_retired_during_classification() {
  local dir state label
  dir=$(make_stale_endpoint_case retired-during-classification); state="$dir/state"
  label="retired during classification"
  retire_meta_on_classification "$dir" "$state/freed.meta"

  launch_stale_round "$dir"
  wait_poll_cycle "$state" "$ROUND_PID" || { reap "$ROUND_PID"; fail "$label: the watcher exited instead of absorbing: $(cat "$dir/watch.out")" ; }
  wait_poll_cycle "$state" "$ROUND_PID" || { reap "$ROUND_PID"; fail "$label: the watcher exited on a later cycle: $(cat "$dir/watch.out")" ; }
  [ "$(queued_stale_rows "$state" "$CASE_WINDOW")" = 0 ] \
    || { reap "$ROUND_PID"; fail "$label: a stale wake was queued for an endpoint whose record went mid-classification" ; }
  [ ! -s "$dir/watch.out" ] || { reap "$ROUND_PID"; fail "$label: the watcher printed a wake: $(cat "$dir/watch.out")" ; }
  assert_endpoint_markers_gone "$state" "$label"
  reap "$ROUND_PID"
  pass "a cleanup that retires a task record mid-classification is caught at the delivery route, not only before it"
}

# --- legacy orphans stay inert ------------------------------------------------
# The v3 key rotation left every pre-existing marker permanently inert. This fix
# reconciles a freed endpoint's family, so it must not become the thing that
# starts matching those orphans again: the family list is derived from
# window_key, so it can only ever name a v3 path.
test_retirement_never_touches_legacy_orphans() {
  local dir state label legacy_key marker before after
  local -a legacy_list=()
  dir=$(make_stale_endpoint_case legacy-orphans); state="$dir/state"
  label="legacy orphans"
  legacy_key=$(printf '%s' "$CASE_WINDOW" | tr ':/.' '___')
  retire_meta_on_capture "$dir" "$state/freed.meta"

  for marker in hash count stale stale-since paused paused-resurfaced; do
    legacy_list+=("$state/.$marker-$legacy_key")
    printf 'legacy-orphan\n' > "$state/.$marker-$legacy_key"
  done
  # A legacy .stale- orphan holding the CURRENT pane hash is the sharpest form of
  # the risk: a fix that matched it would read this endpoint as already
  # classified and silently absorb it, or retire the orphan as its own.
  printf '%s' "$(hash_text "idle prompt, finished")" > "$state/.stale-$legacy_key"
  before=$(cksum < <(cat "${legacy_list[@]}"))

  # The shared list itself must be v3-only, or every assertion below is about a
  # list that could reach a legacy suffix on some other endpoint.
  while IFS= read -r marker; do
    case "$marker" in
      *-v3.*) ;;
      *) fail "$label: the family list named a non-v3 path: $marker" ;;
    esac
  done < <(endpoint_marker_paths "$state")

  launch_stale_round "$dir"
  wait_poll_cycle "$state" "$ROUND_PID" || { reap "$ROUND_PID"; fail "$label: the watcher exited instead of absorbing: $(cat "$dir/watch.out")" ; }
  [ "$(queued_stale_rows "$state" "$CASE_WINDOW")" = 0 ] \
    || { reap "$ROUND_PID"; fail "$label: a legacy orphan drove a stale wake" ; }
  assert_endpoint_markers_gone "$state" "$label"
  reap "$ROUND_PID"

  for marker in "${legacy_list[@]}"; do
    [ -e "$marker" ] || fail "$label: retirement removed the legacy orphan $marker"
  done
  after=$(cksum < <(cat "${legacy_list[@]}"))
  [ "$before" = "$after" ] || fail "$label: a legacy orphan's bytes changed"
  pass "retiring a freed endpoint drops its v3 family and leaves every legacy orphan inert and untouched"
}

fm_test_run \
  test_control_lane_still_surfaces_a_recorded_endpoint \
  test_no_wake_when_the_record_is_retired_during_the_capture \
  test_no_wake_when_the_record_is_retired_during_classification \
  test_retirement_never_touches_legacy_orphans
