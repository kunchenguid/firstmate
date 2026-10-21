#!/usr/bin/env bash
# tests/fm-watch-wedge-cap-unconfigured-parity.test.sh - the unconfigured-home
# parity proof for the wedge cap. FM_WEDGE_MAX_ESCALATIONS unset or 0 must leave
# the watcher's escalation ladder IDENTICAL to upstream main, including that a
# stuck pane still receives the demand-deep-inspection prompt. This drives ONE
# stuck-pane scenario twice - once against upstream main's bin/fm-watch.sh and
# once against this branch's - and asserts the same observable outcome on both.
#
# The scenario is the one route where an unconditional counter reset inside
# wedge_episode_end diverges from upstream on a live pane: the busy-pane ladder
# (a pane rendering one frame with a live foreground command and no completed
# turn) accumulates a consecutive-escalation count that neither upstream nor
# this branch resets, and the pane then going idle takes the hot non-terminal
# first-sight surface, whose pre-cap shape kept that count standing. Upstream
# shows escalation 3 with the demand-deep-inspection prompt on the re-wedge; a
# watcher that resets the counter at that surface restarts at 1 without it. The
# ladder continues to 4 afterwards, which is the rung the unchanged behaviour
# rests on.
#
# The baseline is read from git (origin/main), so the comparison tracks the main
# this branch targets rather than a frozen copy. A checkout without that ref
# fails loudly instead of skipping: the test is the proof, and a silent skip
# would be no proof at all.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

# The fixture root for make_case, which reads TMP_ROOT at call time.
# shellcheck disable=SC2034
TMP_ROOT=$(fm_test_tmproot fm-watch-wedge-cap-parity-tests)

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

# mark_status_seen <state> <status-file>: record the file's CURRENT complete
# snapshot as both reported and classified, so a status this case writes itself
# does not also raise a status-signal wake and mask which route the pane took.
mark_status_seen() {
  FM_STATE_OVERRIDE="$1" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2"
}

# upstream_tree <dest-dir>: materialise upstream main's own bin/ tree, so the
# baseline watcher runs against the libraries it was written for rather than
# this branch's. The comparison is then watcher-against-watcher, with nothing
# else differing.
upstream_tree() {  # <dest-dir>
  local dest=$1 ref
  # The baseline is read in a command substitution, so `fail` (which exits)
  # would end only the SUBSHELL and leave the caller with an empty baseline -
  # a silent skip, not a failure. Report here and return non-zero so the
  # caller's guard aborts the whole test with the specific reason.
  if ! ref=$(git -C "$ROOT" rev-parse --verify --quiet origin/main); then
    printf 'not ok - no origin/main ref in %s - the parity baseline cannot be resolved; fetch origin/main and re-run\n' "$ROOT" >&2
    return 1
  fi
  rm -rf "$dest"
  mkdir -p "$dest"
  if ! git -C "$ROOT" archive "$ref" bin | tar -x -C "$dest"; then
    printf 'not ok - could not extract upstream main bin/ tree (%s)\n' "$ref" >&2
    return 1
  fi
  printf '%s\n' "$dest/bin/fm-watch.sh"
}

backdate_meta() {  # <meta-file>: make the spawn record older than any BUSY_TURN bound
  touch -t 200001010000 "$1"
}

# The busy fixture is the triage suite's: a pi harness whose busy record names
# the pane's semantic state, so window_is_busy is decided by the record and the
# pane's rendered frame stays free to hold still. The idle flip applies the
# opposite verdict under the same armed generation.
record_pi_state() {  # <state-dir> <id> <busy|idle>
  local state=$1 id=$2 want=$3 gen event
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  case "$want" in
    busy) event=agent-start ;;
    *) event=agent-end ;;
  esac
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" "$want" --gen "$gen" \
    --source pi-ext --event "$event" >/dev/null
}

# The busy-pane environment: one frozen frame, a busy pi record, and an
# over-age spawn record, so the completed-turn bound owns the ladder and no
# poll reports a death. The busy route writes neither the stale suppressor nor
# the escalation counter, on either watcher, by both files' own design.
BUSY_ENV=(FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_BUSY_TURN_MAX_SECS=1)
IDLE_CREW='state: idle · source: none'

parity_run() {  # <dir> <watch> <label> <crew-state> <cap-assignment> [extra-env...]
  local dir=$1 watch=$2 label=$3 crew=$4 cap_assignment=$5
  shift 5
  local out pid
  local -a cap_args=()
  [ -n "$cap_assignment" ] && cap_args+=("$cap_assignment")
  out="$dir/watch.out"
  echo $(( $(date +%s) - 500 )) > "$dir/state/.stale-since-$PARITY_KEY"
  : > "$out"
  # The successor mode is what lets one watcher run carry a whole ladder: it
  # keeps the watcher in its poll loop instead of handing the wake to a
  # supervisor, so the next round's poll finds the pane still wedged and
  # continues the same episode. Both watchers are driven the same way, so the
  # comparison stays like-for-like.
  env \
    FM_FAKE_TMUX_WINDOW="$PARITY_WINDOW" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$dir/state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE="$crew" FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_STALE_ESCALATE_SECS=240 \
    PATH="$dir/fakebin:$PATH" "${cap_args[@]}" "$@" \
    bash "$watch" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || {
    reap "$pid"; fail "$label: watcher did not settle ($(basename "$(dirname "$watch")")): $(cat "$out")"
  }
  record_outcome "$dir" "$label" "$out"
}

# record_outcome <dir> <label> <out>: append this round's observable outcome to
# the trace - the escalation count and demand-deep-inspection marker the wake
# named, and whether the cap fired. Timestamps and window names are identical
# by construction, so the traces diff byte for byte.
record_outcome() {
  local dir=$1 label=$2 out=$3 esc inspect capped
  esc=$(sed -n 's/.*escalation \([0-9][0-9]*\).*/\1/p' "$out" | tail -1)
  [ -n "$esc" ] || esc=-
  if grep -F 'demand-deep-inspection' "$out" >/dev/null; then inspect=1; else inspect=0; fi
  if grep -F 'PERMANENTLY-WEDGED' "$out" >/dev/null; then capped=1; else capped=0; fi
  printf '%s esc=%s inspect=%s capped=%s\n' "$label" "$esc" "$inspect" "$capped" >> "$dir/trace"
}

# record_state <dir>: the on-disk wedge state after the scenario.
record_state() {
  local dir=$1 n marker
  n=$(cat "$dir/state/.wedge-escalations-$PARITY_KEY" 2>/dev/null || true)
  case "$n" in ''|*[!0-9]*) n=- ;; esac
  if [ -e "$dir/state/.wedge-permanent-$PARITY_KEY" ]; then marker=1; else marker=0; fi
  printf 'final counter=%s marker=%s\n' "$n" "$marker" >> "$dir/trace"
}

PARITY_WINDOW="test:fm-wedge-cap-parity"
PARITY_KEY=$(printf '%s' "$PARITY_WINDOW" | tr ':/.' '___')
# The unset-case trace the differential test drives against this branch's
# watcher; the value-shape cases compare their own trace against it.
PARITY_BRANCH_TRACE=

run_scenario() {  # <watch> <tag> [cap-env] [rounds]: drive the stuck-pane scenario
  local watch=$1 tag=$2 cap_env=${3-} rounds=${4-}
  local dir state statusf
  dir=$(make_case "wedge-cap-parity-$tag")
  state="$dir/state"
  statusf="$state/wedge-cap-parity.status"
  : > "$dir/trace"

  printf 'idle wedged content' > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$PARITY_WINDOW" > "$state/wedge-cap-parity.meta"
  record_pi_state "$state" wedge-cap-parity busy
  backdate_meta "$state/wedge-cap-parity.meta"
  printf 'working: still wedged\n' > "$statusf"
  mark_status_seen "$state" "$statusf"
  printf '%s' "$(hash_text 'idle wedged content')" > "$state/.hash-$PARITY_KEY"
  printf '1\n' > "$state/.count-$PARITY_KEY"

  # The busy-pane ladder climbs to 2 on the unchanged frame.
  parity_run "$dir" "$watch" busy-rung1 "$IDLE_CREW" "$cap_env" "${BUSY_ENV[@]}"
  parity_run "$dir" "$watch" busy-rung2 "$IDLE_CREW" "$cap_env" "${BUSY_ENV[@]}"
  # A short scenario stops here: the two rungs are all the caller needs.
  if [ -n "$rounds" ] && [ "$rounds" -le 2 ]; then
    record_state "$dir"
    printf '%s\n' "$dir/trace"
    return 0
  fi

  # The pane goes idle on the same render - the busy record flips, the frame
  # does not - so a genuine first sight takes the hot non-terminal surface, the
  # route whose pre-cap shape kept the count standing. Upstream leaves the
  # counter at 2; a watcher that resets it here restarts. The surface wakes
  # without an escalation count.
  record_pi_state "$state" wedge-cap-parity idle
  parity_run "$dir" "$watch" first-sight-surface "$IDLE_CREW" "$cap_env"

  # The re-wedge: THE discriminator. Upstream and this branch show escalation 3
  # with demand-deep-inspection; a counter-resetting watcher shows 1 without it.
  parity_run "$dir" "$watch" rung3-after-surface "$IDLE_CREW" "$cap_env"
  parity_run "$dir" "$watch" rung4 "$IDLE_CREW" "$cap_env"

  record_state "$dir"
  printf '%s\n' "$dir/trace"
}

test_unconfigured_ladder_matches_upstream_main() {
  local baseline candidate base_trace
  baseline=$(upstream_tree "$TMP_ROOT/upstream-main") || fail "could not materialise upstream main's bin/ tree for the parity baseline"
  candidate="$ROOT/bin/fm-watch.sh"
  base_trace=$(run_scenario "$baseline" upstream)
  PARITY_BRANCH_TRACE=$(run_scenario "$candidate" branch)
  local cand_trace=$PARITY_BRANCH_TRACE

  if ! diff -u "$base_trace" "$cand_trace" > "$TMP_ROOT/parity.diff"; then
    fail "unconfigured-home ladder diverged from upstream main:
--- upstream trace: $base_trace
--- branch trace:   $cand_trace
--- diff:
$(cat "$TMP_ROOT/parity.diff")"
  fi

  # The scenario itself must be the proof the maintainer asked for, not just a
  # pair of matching failures: the re-wedge after the first-sight surface
  # reaches escalation 3 with the demand-deep-inspection prompt on BOTH
  # watchers, the ladder continues to 4, and no round fires PERMANENTLY-WEDGED.
  grep -F 'rung3-after-surface esc=3 inspect=1 capped=0' "$cand_trace" >/dev/null \
    || fail "scenario did not reach escalation 3 with demand-deep-inspection after the first-sight surface: $(cat "$cand_trace")"
  grep -F 'rung4 esc=4 inspect=1 capped=0' "$cand_trace" >/dev/null \
    || fail "the ladder did not continue to escalation 4: $(cat "$cand_trace")"
  if grep -F 'capped=1' "$cand_trace" >/dev/null; then
    fail "unconfigured scenario fired PERMANENTLY-WEDGED: $(cat "$cand_trace")"
  fi
  grep -F 'final counter=4 marker=0' "$cand_trace" >/dev/null \
    || fail "scenario did not end at counter 4 with no cap marker: $(cat "$cand_trace")"
  pass "unconfigured-home wedge ladder is observably identical to upstream main across the busy ladder and the first-sight surface, and still reaches the demand-deep-inspection prompt"
}

test_unconfigured_ladder_matches_upstream_main

# Every value the normalization maps to "off" must behave EXACTLY like the
# unset case - including through the keep-count routes, since the cap-gated
# reset reads the normalized value. Each shape runs the same scenario against
# this branch's watcher and must produce the unset case's trace, which is the
# branch trace the differential test already drove. The out-of-range shape is
# the one a shell cannot compare: bash's test ERRORS on such a value and an
# errored comparison reads as false, so a value left unnormalized would count
# as CONFIGURED (its "is it 0" test errors false) and would reset the counter
# the unset case keeps - and its "at least the cap" test would never fire.
test_unconfigured_value_shapes_match_the_unset_case() {
  local canonical shape env_assignment shape_trace
  canonical=$PARITY_BRANCH_TRACE
  [ -n "$canonical" ] && [ -f "$canonical" ] \
    || fail "the unset-case trace from the differential test is missing: $canonical"
  for shape in zero empty negative garbage out-of-range; do
    case "$shape" in
      zero)     env_assignment='FM_WEDGE_MAX_ESCALATIONS=0' ;;
      empty)    env_assignment='FM_WEDGE_MAX_ESCALATIONS=' ;;
      negative) env_assignment='FM_WEDGE_MAX_ESCALATIONS=-3' ;;
      garbage)  env_assignment='FM_WEDGE_MAX_ESCALATIONS=garbage' ;;
      out-of-range) env_assignment='FM_WEDGE_MAX_ESCALATIONS=99999999999999999999' ;;
    esac
    shape_trace=$(run_scenario "$ROOT/bin/fm-watch.sh" "shape-$shape" "$env_assignment")
    if ! diff -u "$canonical" "$shape_trace" > "$TMP_ROOT/shape-$shape.diff"; then
      fail "FM_WEDGE_MAX_ESCALATIONS=$shape diverged from the unset case:
$(cat "$TMP_ROOT/shape-$shape.diff")"
    fi
    grep -F 'rung3-after-surface esc=3 inspect=1 capped=0' "$shape_trace" >/dev/null \
      || fail "shape $shape did not reach escalation 3 with demand-deep-inspection: $(cat "$shape_trace")"
    if grep -F 'capped=1' "$shape_trace" >/dev/null; then
      fail "shape $shape fired PERMANENTLY-WEDGED: $(cat "$shape_trace")"
    fi
    grep -F 'final counter=4 marker=0' "$shape_trace" >/dev/null \
      || fail "shape $shape did not end at counter 4 with no cap marker: $(cat "$shape_trace")"
  done
  pass "FM_WEDGE_MAX_ESCALATIONS at 0, empty, negative, non-numeric, and out-of-range all keep the unchanged ladder through the keep-count routes: 1 2 3 4 with demand-deep-inspection at 3, no PERMANENTLY-WEDGED, no cap marker, no crash"
}

test_unconfigured_value_shapes_match_the_unset_case

# The positive control: the same harness, the same scenario, and a cap that IS
# configured. If the environment never reached the watcher, this case would
# show the unset behaviour too and the shape cases above would prove nothing.
# A configured cap fires its terminal wake at its own threshold, so the
# difference here is what shows the harness really drives the setting.
test_configured_cap_is_delivered_to_the_watcher() {
  local trace
  trace=$(run_scenario "$ROOT/bin/fm-watch.sh" cap-configured 'FM_WEDGE_MAX_ESCALATIONS=2' 2)
  grep -F 'busy-rung2 esc=2 inspect=0 capped=1' "$trace" >/dev/null \
    || fail "a configured cap of 2 did not fire PERMANENTLY-WEDGED at its threshold, so the harness does not deliver the setting: $(cat "$trace")"
  grep -F 'final counter=- marker=1' "$trace" >/dev/null \
    || fail "a configured cap did not leave its window-scoped marker standing: $(cat "$trace")"
  pass "the harness really delivers FM_WEDGE_MAX_ESCALATIONS to the watcher: a configured cap of 2 fires PERMANENTLY-WEDGED at count 2 and leaves its marker standing, while every unconfigured value leaves the ladder untouched"
}

test_configured_cap_is_delivered_to_the_watcher
