#!/usr/bin/env bash
# tests/fm-watch-triage.test.sh - the always-on wake triage built into
# bin/fm-watch.sh and the shared classifier (bin/fm-classify-lib.sh). The watcher
# now absorbs the benign majority of wakes in bash and exits ONLY on an actionable
# wake, so firstmate's LLM re-arms once per actionable event instead of once per
# wake. These tests cover the classifier predicates as pure functions, then drive
# a real fm-watch.sh subprocess to assert the behavioral contract:
# provably-working no-verb wakes absorbed (no exit, no queue entry, suppressor
# advanced, beacon fresh), stopped-crew no-verb wakes surfaced (queue + exit),
# provably-working stale panes absorbed-then-escalated past the threshold,
# terminal-looking stale status lines overridden by an active run, the heartbeat
# backstop fail-safe, and afk coherence (no double-triage while the away-mode
# daemon owns supervision).
#
# Daemon-side classification/injection lives in fm-daemon.test.sh; watcher/lock
# liveness in fm-watcher-lock.test.sh; the durable-queue safety matrix in
# fm-wake-queue.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-triage-tests)

ack_stopped_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-cycle-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

# Common watcher knobs: tight poll/grace, no check or heartbeat cadence unless a
# test overrides them, so a test only exercises the path it targets. FM_CREW_STATE_BIN
# points at the case's hermetic fake fm-crew-state.sh (installed by make_case) so the
# absorb-only-when-provably-working triage reads a canned verdict; a test fixes that
# verdict via FM_FAKE_CREW_STATE in its environment before calling watch_bg.
watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$out" &
}

# Wait up to <limit> 0.1s ticks while <pid> stays alive; 0 if still alive, 1 if it died.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

wait_numeric_file() {
  local file=$1 limit=${2:-30} i=0 value
  while [ "$i" -lt "$limit" ]; do
    value=$(cat "$file" 2>/dev/null || true)
    case "$value" in
      ''|*[!0-9]*) ;;
      *) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Portable mtime in epoch seconds. Platform-detected, never the `stat -f || stat -c`
# fallback (which writes a partial filesystem dump on Linux; see fm-watch.sh).
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# Set <file>'s mtime to exactly <epoch> seconds, for aging a busy-turn marker by
# a precise amount (touch -t takes a local-time stamp, not an epoch, on both
# platforms, so convert via BSD `date -r` or GNU `date -d @`).
set_mtime() {  # <epoch> <file>
  local epoch=$1 f=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$f"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$f"
  fi
}

# Signature a primed .seen-* marker must hold so the per-poll signal scan does not
# fire on a pre-existing status (mirrors fm-watch.sh's stat_sig exactly).
seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

# Prime <file>'s .seen-* suppressor to its CURRENT signature, so the per-poll
# no-verb signal scan (which watches every *.turn-ended for a size:mtime change)
# treats a just-created or just-backdated turn-ended marker as already seen.
# Busy-turn-age fixtures create/backdate turn-ended directly (there is no real
# harness touching it), so without this the marker's own first sighting would
# fire an unrelated "signal:" wake and mask the busy-turn-age assertion under
# test. Call again after any further touch/set_mtime on the same file.
prime_turnend_seen() {  # <file>
  local f=$1 base
  base=$(basename "$f" | tr '.' '_')
  printf '%s' "$(seen_sig "$f")" > "$(dirname "$f")/.seen-$base"
}

record_pi_busy() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" \
    --source pi-ext --event agent-start
}

# Same semantic busy-state channel as record_pi_busy, for either verdict. Lets a
# test flip a pane between busy and idle WITHOUT touching its rendered content,
# so the pane hash can stay fixed across the flip - the shape a real backend
# reports when an agent starts or dies behind an unchanged screen.
record_pi_state() {  # <state-dir> <id> <busy|idle>
  local state=$1 id=$2 want=$3 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" "$want" --gen "$gen" \
    --source pi-ext --event "test-$want"
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# --- pure classifier predicates (fm-classify-lib.sh) ------------------------

test_signal_reason_is_actionable_classifier() {
  local dir state
  dir=$(make_case classify-signal); state="$dir/state"
  printf 'working: step 1\nworking: step 2\n' > "$state/a.status"
  signal_reason_is_actionable "$state/a.status" && fail "benign working: signal classified actionable"
  printf 'working: x\nneeds-decision: pick A or B\n' > "$state/b.status"
  signal_reason_is_actionable "$state/b.status" || fail "captain-relevant signal classified benign"
  : > "$state/c.turn-ended"
  signal_reason_is_actionable "$state/c.turn-ended" && fail "a bare turn-ended marker classified actionable"
  # Coalesced batch: one benign + one captain-relevant -> actionable.
  signal_reason_is_actionable "$state/a.status" "$state/b.status" || fail "coalesced benign+actionable not actionable"
  # A failure and a merge result are captain-relevant and must always wake.
  printf 'failed: build broke on main\n' > "$state/d.status"
  signal_reason_is_actionable "$state/d.status" || fail "a failed: line was not actionable"
  printf 'merged\n' > "$state/e.status"
  signal_reason_is_actionable "$state/e.status" || fail "a legacy merged line was not actionable"
  pass "signal_reason_is_actionable: benign absorbed, captain verbs and coalesced batches surfaced"
}

test_stale_is_terminal_classifier() {
  local dir state
  dir=$(make_case classify-stale); state="$dir/state"
  printf 'done: ready in branch fm/x\n' > "$state/term.status"
  stale_is_terminal "sess:fm-term" "$state" || fail "terminal stale status not classified terminal"
  fm_write_meta "$state/herdr-term.meta" "window=default:w1:p2" "backend=herdr"
  printf 'done: ready in branch fm/herdr\n' > "$state/herdr-term.status"
  stale_is_terminal "default:w1:p2" "$state" || fail "terminal herdr stale status not resolved through metadata"
  printf 'working: compiling\n' > "$state/nonterm.status"
  stale_is_terminal "sess:fm-nonterm" "$state" && fail "non-terminal stale classified terminal"
  stale_is_terminal "sess:fm-missing" "$state" && fail "stale with no status classified terminal"
  pass "stale_is_terminal: terminal status surfaces, non-terminal and no-status are benign"
}

test_scan_captain_relevant_statuses_classifier() {
  local dir state out
  dir=$(make_case classify-scan); state="$dir/state"
  printf 'working: a\n' > "$state/one.status"
  printf 'blocked: no perms\n' > "$state/two.status"
  printf 'done: PR https://x/y/pull/1\n' > "$state/three.status"
  out=$(scan_captain_relevant_statuses "$state")
  printf '%s' "$out" | grep -F "two.status" >/dev/null || fail "scan missed a blocked: status"
  printf '%s' "$out" | grep -F "three.status" >/dev/null || fail "scan missed a done: status"
  printf '%s' "$out" | grep -F "one.status" >/dev/null && fail "scan surfaced a benign working: status"
  pass "scan_captain_relevant_statuses lists only captain-relevant statuses"
}

test_classifier_primitives() {
  local dir state open activity
  dir=$(make_case classify-primitives); state="$dir/state"
  printf 'working: a\n\ndone: b\n\n' > "$state/x.status"
  [ "$(last_status_line "$state/x.status")" = "done: b" ] || fail "last_status_line did not return the last non-blank line"
  status_is_captain_relevant "done: b" || fail "done: not recognized as captain-relevant"
  status_is_captain_relevant "needs-decision [key=q1]: b" || fail "keyed needs-decision not recognized as captain-relevant"
  status_is_captain_relevant "working: b" && fail "working: wrongly recognized as captain-relevant"
  # Incident regression: free-text "merged" inside a nonterminal working: line must
  # not become captain-relevant (AFK false-terminal path).
  status_is_captain_relevant \
    "working: stage 2 setup complete on PR #74 exact source branch rebased onto merged #76; task dates preserved" \
    && fail "working: ... merged #N wrongly recognized as captain-relevant"
  status_is_captain_relevant "working: rebased onto predecessor #76" \
    && fail "working: predecessor prose wrongly recognized as captain-relevant"
  status_is_captain_relevant "working: PR ready checks green merged ready in branch" \
    && fail "working: free-text tokens wrongly recognized as captain-relevant"
  status_is_captain_relevant "done: PR https://x/pull/76 checks green" \
    || fail "genuine done: checks green not captain-relevant"
  status_is_terminal_verb "done: PR https://x/pull/76 checks green" \
    || fail "done: not a terminal verb"
  status_is_terminal_verb "working: rebased onto merged #76" \
    && fail "working: wrongly classed as terminal verb"
  status_is_captain_relevant "merged" || fail "legacy bare merged free-text not captain-relevant"
  status_is_captain_relevant "PR ready https://x/pull/2" \
    || fail "legacy bare PR ready free-text not captain-relevant"
  [ "$(window_to_task "sess:fm-fix-login-k3")" = "fix-login-k3" ] || fail "window_to_task did not strip session+fm- prefix"
  fm_write_meta "$state/herdr-task.meta" "window=default:w1:p2" "backend=herdr"
  [ "$(window_to_task "default:w1:p2" "$state")" = "herdr-task" ] || fail "window_to_task did not resolve opaque backend target through metadata"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "custom-verb: x" || fail "FM_CAPTAIN_RE override not honored"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "done: x" && fail "FM_CAPTAIN_RE override did not replace the default verb set"
  FM_CAPTAIN_RE='merged|custom-verb:' status_is_captain_relevant "working: rebased onto merged #76" \
    && fail "FM_CAPTAIN_RE override bypassed working: suppression"
  FM_CAPTAIN_RE='checks green|custom-verb:' status_is_captain_relevant "paused: checks green pending approval" \
    && fail "FM_CAPTAIN_RE override bypassed paused: suppression"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "custom-verb: x" \
    || fail "nonterminal suppression weakened custom bare-line behavior"
  printf 'needs-decision: should docs mention [key=prose]?\nneeds-decision [key=q1]: real choice\nresolved: docs still mention [key=q1]\nneeds-decision [key=bad key]: malformed\n' > "$state/keys.status"
  open=$(status_open_decisions "$state/keys.status")
  printf '%s' "$open" | grep -F $'q1\t' >/dev/null \
    || fail "a key token in resolved note prose closed the keyed decision"
  printf '%s' "$open" | grep -F $'prose\t' >/dev/null \
    && fail "a key token in note prose changed the decision key"
  printf '%s' "$open" | grep -F $'bad key\t' >/dev/null \
    && fail "an invalid key slug entered the open-decision set"
  cat > "$state/activity.status" <<'EOF'
working [key=phase7]: Phase 7 started
working [key=phase6]: Phase 6 started
working [key=legal]: reviewing legal dependency
done [key=phase6]: Phase 6 completed
resolved [key=phase7]: Phase 7 completed and moved to Done
paused [key=legal]: awaiting external counsel
resolved [key=legal]: legal item returned to the queue
working [key=phase8]: Phase 8 started
EOF
  activity=$(status_open_activities "$state/activity.status")
  printf '%s' "$activity" | grep -F $'phase8\tworking\tPhase 8 started' >/dev/null \
    || fail "the current keyed working phase was not retained"
  printf '%s' "$activity" | grep -F $'phase7\t' >/dev/null \
    && fail "a keyed resolved event did not close the older working phase"
  printf '%s' "$activity" | grep -F $'phase6\t' >/dev/null \
    && fail "a same-key terminal event did not supersede the older working phase"
  printf '%s' "$activity" | grep -F $'legal\t' >/dev/null \
    && fail "a keyed resolved event did not close the declared pause"
  printf 'working: legacy start\ndone: legacy completion\n' > "$state/legacy-activity.status"
  [ -z "$(status_open_activities "$state/legacy-activity.status")" ] \
    || fail "a legacy terminal event did not supersede the default working phase"
  pass "classifier primitives: keyed decisions and activity phases, captain relevance, window-to-task, and overrides"
}

# crew_is_provably_working: the absorb-only-when-provably-working predicate. It is
# benign (absorb) ONLY when fm-crew-state.sh reports the crew as working from an
# actively-running pipeline step (source run-step) or a busy pane (source pane);
# everything else - a stale working: status-log line, a finished/parked/failed run,
# an unknown/torn-down crew, or an empty id - is NOT provable, so it surfaces. The
# fake fm-crew-state.sh (FM_CREW_STATE_BIN) returns a canned verdict per case.
test_crew_is_provably_working_classifier() {
  local dir fakebin
  dir=$(make_case provably-working); fakebin="$dir/fakebin"
  # Point the predicate at this case's hermetic fake and drive its verdict per case.
  # export marks the var for the fake subprocess; it is unset again at the end so it
  # cannot leak into a later test (every behavioral test sets its own verdict anyway).
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  crew_is_provably_working a || fail "active run-step not treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  crew_is_provably_working a || fail "busy pane not treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling'
  ! crew_is_provably_working a || fail "stale status-log working: treated as provably working"
  FM_FAKE_CREW_STATE='state: done · source: run-step · checks green'
  ! crew_is_provably_working a || fail "finished run treated as provably working"
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review'
  ! crew_is_provably_working a || fail "parked run treated as provably working"
  FM_FAKE_CREW_STATE='state: failed · source: run-step · run failed'
  ! crew_is_provably_working a || fail "failed run treated as provably working"
  FM_FAKE_CREW_STATE='state: unknown · source: none · worktree gone'
  ! crew_is_provably_working a || fail "unknown crew treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: run-step · x'
  ! crew_is_provably_working "" || fail "empty id treated as provably working"
  unset FM_FAKE_CREW_STATE
  pass "crew_is_provably_working: only working+run-step/pane is provable; idle/finished/parked/failed/unknown surface"
}

# status_is_paused: the shared pause verb test both consumers read (so neither
# hardcodes the literal). Matches only the verb before the first colon, so a reason
# that merely mentions "paused" does not false-match, and a genuine blocker stays a
# blocker.
test_status_is_paused_classifier() {
  status_is_paused 'paused: holding for the upstream release' || fail "paused verb not recognized"
  status_is_paused '  paused:   waiting on a rate-limit reset' || fail "leading-space paused verb not recognized"
  status_is_paused 'blocked: the build is paused upstream' && fail "a blocked line mentioning paused false-matched"
  status_is_paused 'working: paused the animation loop' && fail "a working line mentioning paused false-matched"
  status_is_paused 'done: shipped' && fail "done classified as paused"
  status_is_paused '' && fail "empty line classified as paused"
  # A pause is deliberately NOT captain-relevant: it is a stop-nagging signal, not
  # work to keep surfacing.
  status_is_captain_relevant 'paused: holding for the upstream release' && fail "paused is captain-relevant (should not be)"
  status_is_paused_or_captain_held 'paused: holding for the upstream release' \
    || fail "declared pause not recognized by the bounded-idle classifier"
  status_is_paused_or_captain_held 'captain-held [key=route]: tracked by task-decision-route' \
    || fail "captain-held transfer not recognized by the bounded-idle classifier"
  status_is_paused_or_captain_held 'resolved [key=route]: captain answered' \
    && fail "resolved decision remained classed as captain-held"
  pass "status_is_paused: only the leading paused verb matches, and paused is not captain-relevant"
}

# crew_absorb_class: the single fm-crew-state.sh read that returns BOTH absorb
# reasons - working (active run/busy pane), paused (declared external wait), or none
# (surface it) - so the watcher's stale path gets both for one bounded call.
# crew_is_paused delegates to it exactly as crew_is_provably_working does.
test_crew_absorb_class_classifier() {
  local dir fakebin
  dir=$(make_case absorb-class); fakebin="$dir/fakebin"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  [ "$(crew_absorb_class a)" = working ] || fail "active run-step not classed working"
  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  [ "$(crew_absorb_class a)" = working ] || fail "busy pane not classed working"
  FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting upstream'
  [ "$(crew_absorb_class a)" = paused ] || fail "declared pause not classed paused"
  crew_is_paused a || fail "crew_is_paused did not recognize a paused verdict"
  ! crew_is_provably_working a || fail "a paused crew was treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling'
  [ "$(crew_absorb_class a)" = none ] || fail "stale working: status-log classed absorbable"
  FM_FAKE_CREW_STATE='state: unknown · source: none · worktree gone'
  [ "$(crew_absorb_class a)" = none ] || fail "unknown crew classed absorbable"
  ! crew_is_paused a || fail "unknown crew classed paused"
  [ "$(crew_absorb_class "")" = none ] || fail "empty id not classed none"
  unset FM_FAKE_CREW_STATE
  pass "crew_absorb_class: working/paused/none from one read; crew_is_paused and crew_is_provably_working agree"
}

# signal_crew_provably_working: a no-verb "signal:" wake is benign ONLY when EVERY
# task it references is provably working; if any crew has stopped, or no task can be
# resolved, it surfaces. Files map to ids by stripping .status / .turn-ended.
test_signal_crew_provably_working_classifier() {
  local dir fakebin state
  dir=$(make_case signal-provably-working); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE_a='state: working · source: run-step · running'
  export FM_FAKE_CREW_STATE_b='state: done · source: run-step · run passed'
  signal_crew_provably_working "$state/a.status" "$state/a.turn-ended" \
    || fail "a single provably-working crew (status+turn-end) was not benign"
  ! signal_crew_provably_working "$state/a.status" "$state/b.turn-ended" \
    || fail "a coalesced batch including a stopped crew was treated as benign"
  ! signal_crew_provably_working "$state/b.turn-ended" \
    || fail "a stopped crew's bare turn-end was treated as benign"
  ! signal_crew_provably_working "$state/a.meta" \
    || fail "a non-signal file resolved to a benign verdict"
  ! signal_crew_provably_working \
    || fail "an empty signal file list was treated as benign"
  unset FM_FAKE_CREW_STATE_a FM_FAKE_CREW_STATE_b
  pass "signal_crew_provably_working: benign only when every referenced crew is provably working"
}

test_secondmate_status_signal_never_absorbed_classifier() {
  local dir fakebin state
  dir=$(make_case secondmate-signal-classify); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  # Even PROVABLY working, a secondmate's .status signal is its routed-reply
  # channel and must surface; its bare turn-ended keeps the ordinary absorb.
  export FM_FAKE_CREW_STATE_sm='state: working · source: run-step · running'
  printf 'kind=secondmate\n' > "$state/sm.meta"
  printf 'working: routed reply for the parent\n' > "$state/sm.status"
  ! signal_crew_provably_working "$state/sm.status" \
    || fail "a working secondmate's status signal was treated as absorbable"
  signal_crew_provably_working "$state/sm.turn-ended" \
    || fail "a working secondmate's bare turn-end lost its ordinary absorb"
  # An ordinary crewmate with the same verdict stays absorbable: the rule is
  # keyed on recorded kind, not on task naming or content guessing.
  export FM_FAKE_CREW_STATE_crew='state: working · source: run-step · running'
  printf 'kind=ship\n' > "$state/crew.meta"
  printf 'working: progress\n' > "$state/crew.status"
  signal_crew_provably_working "$state/crew.status" \
    || fail "the secondmate rule leaked onto an ordinary crewmate status"
  unset FM_FAKE_CREW_STATE_sm FM_FAKE_CREW_STATE_crew
  pass "a secondmate's status signal is never absorbed as provably working; crewmates are unaffected"
}

# --- benign wakes are absorbed ONLY when the crew is provably working ---------

test_provably_working_signal_absorbed() {
  local dir state fakebin out status_file pid
  dir=$(make_case provably-working-signal); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # The crew's pipeline is in an actively-running step: positive evidence it is
  # still working, so a no-verb working: signal is absorbed (the original low-churn
  # case during a long validation).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a working: signal whose crew is provably working (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "provably-working signal printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "provably-working signal enqueued a durable wake record"
  [ -s "$state/.seen-task_status" ] || fail "provably-working signal did not advance its .seen-* suppressor"
  [ -e "$state/.last-watcher-beat" ] || fail "watcher beacon was not touched while absorbing"
  reap "$pid"
  pass "a no-verb signal whose crew is provably working is absorbed (no exit, no queue, suppressor advanced, beacon present)"
}

test_turn_ended_provably_working_absorbed() {
  local dir state fakebin out pid
  dir=$(make_case turn-ended-working); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  : > "$state/task.turn-ended"
  # A busy pane is the second form of positive evidence (covers a queued
  # continuation right after the turn-end).
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a turn-end whose crew is provably working (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "provably-working turn-end printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "provably-working turn-end enqueued a durable wake record"
  reap "$pid"
  pass "a bare turn-end whose crew is provably working (busy pane) is absorbed"
}

# --- a no-verb signal whose crew is NOT provably working SURFACES -------------
# This is the swallowed-finish fix: a crew that finished (or stopped and waits)
# reports its final turn-end with no captain-relevant status and no running
# pipeline, so the wake must surface instead of being absorbed.

test_turn_ended_not_working_surfaced() {
  local dir state fakebin out drain_out pid
  dir=$(make_case turn-ended-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  : > "$state/task.turn-ended"
  # No running pipeline, no busy pane: the crew has stopped (e.g. it finished via
  # an interactive menu and wrote no done: status). Default unknown verdict.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a turn-end whose crew is not provably working"
  grep -F "signal: $state/task.turn-ended" "$out" >/dev/null || fail "watcher did not print the surfaced turn-end signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/task.turn-ended" >/dev/null || fail "surfaced turn-end was not queued"
  pass "a bare turn-end whose crew is not provably working is surfaced (the swallowed-finish fix)"
}

test_working_note_not_working_surfaced() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case working-note-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # A non-no-mistakes crew (no run) whose pane went idle: fm-crew-state falls back
  # to the stale working: status-log line. That is NOT positive evidence, so the
  # wake must surface - these users must never be left hanging.
  export FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling step 2'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a working: note whose crew has no running pipeline and an idle pane"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the surfaced working: signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced working: note failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "surfaced working: note was not queued"
  [ -s "$state/.seen-task_status" ] || fail "surfaced working: note did not advance its .seen-* suppressor"
  pass "a no-verb working: note whose crew is idle with no running pipeline is surfaced"
}

test_secondmate_status_note_surfaced_despite_busy_agent() {
  local dir state fakebin out drain_out pid
  dir=$(make_case secondmate-note-surfaced); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  printf 'kind=secondmate\n' > "$state/mate.meta"
  printf 'working: routed reply landed in the parent stream\n' > "$state/mate.status"
  # Busy evidence that would absorb an ordinary crewmate's no-verb note must
  # not absorb a secondmate's: its status stream is the routed-reply channel.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · running'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher absorbed a busy secondmate's routed status note"
  grep -F "signal: $state/mate.status" "$out" >/dev/null \
    || fail "watcher did not print the surfaced secondmate note"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced note failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/mate.status" >/dev/null \
    || fail "surfaced secondmate note was not queued"
  pass "a secondmate's status note surfaces even while its own agent is busy"
}

test_self_announced_close_does_not_rewake_but_next_note_does() {
  local dir state fakebin out status_file pid rc
  dir=$(make_case self-close-quiet); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'needs-decision [key=k1]: pick one\n' > "$status_file"
  prime_status_seen "$state" "$status_file" || fail "could not prime the announced baseline"
  # The home's own bookkeeping close, written through the guarded
  # self-announced append this home's answerers use.
  rc=0
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_wake_status_append_self_announced "$2" "$3" "resolved [key=k1]: answered: closed by this home"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state" "$status_file" || rc=$?
  [ "$rc" -eq 0 ] || fail "the bookkeeping close was not self-announced (rc=$rc)"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · idle worker'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "the home's own bookkeeping close re-woke its own watcher: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "self-announced close printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "self-announced close enqueued a durable wake"; }
  # A later, different note on the SAME task still wakes: dedup is keyed on the
  # exact announced bytes, never on task identity.
  printf 'needs-decision [key=k2]: a genuinely new decision\n' >> "$status_file"
  wait_for_exit "$pid" 40 || fail "a later different note after a self-announced close was swallowed"
  grep -F "signal: $status_file" "$out" >/dev/null \
    || fail "the later note did not surface as a signal"
  pass "a self-announced close never wakes its own home, and the next real note still does"
}

# --- actionable wakes are surfaced (queue + exit) ---------------------------

test_actionable_signal_surfaced() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case actionable-signal); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: setup\nneeds-decision: pick A or B\n' > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit for an actionable needs-decision signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the actionable signal reason"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the actionable signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "actionable signal was not queued"
  [ -s "$state/.hb-surfaced-task" ] || fail "actionable signal did not record the surfaced marker"
  pass "captain-relevant signal is surfaced (queue + exit) and marked surfaced"
}

test_terminal_stale_surfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-done"
  printf 'finished, awaiting review' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/done.meta"
  printf 'done: PR https://example.test/pr/3\n' > "$state/done.status"
  sig=$(seen_sig "$state/done.status"); printf '%s' "$sig" > "$state/.seen-done_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "finished, awaiting review")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not exit for a stale pane on a terminal status"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the terminal stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the terminal stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "terminal stale was not queued"
  pass "a stale pane sitting on a terminal status is surfaced (queue + exit)"
}

# --- stale pane, STALE terminal status overridden by an active run: absorbed ---
# Regression for the 2026-07 herdr false-surface incidents: a crew's own status
# log gets no new entry once firstmate hands it to a no-mistakes validation
# (AGENTS.md's sparse status-reporting contract), so the log keeps showing its
# pre-validation "done:" line as the LAST line for the run's entire (possibly
# many-minutes) duration. stale_is_terminal alone has no run-step awareness and
# would treat that leftover as still-current every time the pane goes quiet,
# immediately surfacing a crew that is actively validating. crew_is_provably_working
# must get a chance to override a captain-relevant-but-stale status line, exactly
# as it already does for a plain non-terminal one.
test_stale_terminal_status_overridden_by_active_run() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale-overridden); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-validating"
  printf 'no-mistakes axi run: validating...' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/validating.meta"
  # The crew reported done BEFORE firstmate triggered no-mistakes validation;
  # this line never gets superseded by a newer status-log entry while the
  # pipeline itself runs.
  printf 'done: implementation complete, ready to validate\n' > "$state/validating.status"
  sig=$(seen_sig "$state/validating.status"); printf '%s' "$sig" > "$state/.seen-validating_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "no-mistakes axi run: validating...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Phase A: a high escalation threshold means the first sighting is absorbed,
  # not surfaced, despite the captain-relevant "done:" status-log line.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a stale terminal-looking status the run-step overrides (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the overridden stale terminal status printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "the overridden stale terminal status enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on absorb"
  [ -s "$state/.stale-since-$key" ] || fail "stale-since escalation timer was not recorded on absorb"
  [ ! -e "$state/.hb-surfaced-validating" ] || fail "an absorbed wake must not mark the status line as surfaced"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A watcher stop"

  # Phase B: backdate the idle timer past the threshold; the run genuinely
  # wedges and the next poll escalates exactly like the non-terminal case.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not escalate an overridden stale terminal status past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  unset FM_FAKE_CREW_STATE
  pass "a stale terminal-looking status is overridden and absorbed while a run is actively working, then wedge-escalated"
}

# --- non-terminal stale, crew provably working: absorbed, then wedge-escalated ---
# A provably-working crew (an actively-running pipeline) legitimately sits on a
# static pane (e.g. waiting on CI), so a non-terminal stale is absorbed and only
# the wedge timer eventually escalates it - the low-churn behavior preserved.

test_nonterminal_stale_provably_working_absorbed_then_escalated() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-stale-working); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-quiet"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/quiet.meta"
  # Non-terminal status, and prime .seen-* so the signal scan does not pre-empt
  # the stale path.
  printf 'working: still compiling\n' > "$state/quiet.status"
  sig=$(seen_sig "$state/quiet.status"); printf '%s' "$sig" > "$state/.seen-quiet_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The crew's pipeline is actively running: a static pane is normal (waiting on CI).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · ci running'

  # Phase A: a high escalation threshold means the first sighting is absorbed.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a fresh provably-working non-terminal stale (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "fresh provably-working stale printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "fresh provably-working stale enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on absorb"
  [ -s "$state/.stale-since-$key" ] || fail "stale-since escalation timer was not recorded on absorb"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A watcher stop"

  # Phase B: backdate the idle timer past the threshold; the next run escalates.
  # (The subsequent-sight timer path does not re-read the crew state.)
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not escalate a provably-working non-terminal stale past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  [ ! -e "$state/.stale-since-$key" ] || fail "stale-since timer was not cleared after escalation"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the wedge escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "wedge escalation was not queued"
  pass "provably-working non-terminal stale is absorbed on first sight, then wedge-escalated past the threshold"
}

# --- non-terminal stale, crew NOT provably working: surfaced immediately ------
# The key requirement: a crew with no running pipeline that has gone quiet (and is
# not busy) has stopped - it may be done via interactive menus, waiting, or wedged.
# It must surface at once, never wait out the wedge timer, so these users (a
# non-no-mistakes crew, or any crew with no running pipeline) are never left hanging.

test_nonterminal_stale_not_working_surfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-stale-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-stopped"
  printf 'idle prompt, finished' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stopped.meta"
  # Non-terminal status (the crew never wrote a captain-relevant verb), .seen-*
  # primed so the signal scan does not pre-empt the stale path.
  printf 'working: implementing\n' > "$state/stopped.status"
  sig=$(seen_sig "$state/stopped.status"); printf '%s' "$sig" > "$state/.seen-stopped_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt, finished")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # No running pipeline; the pane is idle. NOT provably working.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  # Even with a high wedge threshold, a not-provably-working stale surfaces at once.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not surface a not-provably-working non-terminal stale at once"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the immediate stale wake"
  grep -F "possible wedge" "$out" >/dev/null && fail "an immediate stopped-crew stale was mislabeled a wedge"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not advanced on surface"
  [ ! -e "$state/.stale-since-$key" ] || fail "stale-since timer should not be set when surfacing immediately"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the immediate stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "immediate stale wake was not queued"
  pass "a not-provably-working non-terminal stale is surfaced immediately (never left to wait out the timer)"
}

# --- non-terminal stale, crew DECLARED a pause: absorbed, re-surfaced on a long
#     cadence, never wedge-escalated ------------------------------------------
# The live 2026-07-09/10 case: a crew intentionally held awaiting an upstream tool
# release (paused: ...) whose idle pane tripped repeated possible-wedge escalations
# all day. With the paused verb, its stale is absorbed like a working crew but never
# uses the wedge timer; it re-surfaces once past PAUSE_RESURFACE_SECS (anchored on
# the pause's own status-file age, so a churny idle pane cannot reset the cadence)
# for a recheck, so a forgotten pause cannot rot invisibly.
test_nonterminal_stale_paused_absorbed_then_resurfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid back statusf
  dir=$(make_case nonterminal-stale-paused); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-held"
  printf 'idle, holding for upstream' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/held.meta"
  statusf="$state/held.status"
  # A DECLARED pause (not captain-relevant), .seen-* primed so the signal scan does
  # not pre-empt the stale path.
  printf 'paused: holding for the upstream tool release\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle, holding for upstream")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # crew_absorb_class reads the declared pause from fm-crew-state.sh.
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · holding for the upstream tool release'

  # Phase A: a fresh pause (status file just written) under a high re-surface
  # threshold is absorbed - no wake, no wedge timer.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a fresh declared pause (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "fresh paused stale printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "fresh paused stale enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on paused absorb"
  [ -e "$state/.paused-$key" ] || fail "paused flag not recorded on absorb"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused absorb must not start the wedge timer"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional paused phase-A stop"

  # Phase B: age the pause past the (now normal) threshold by backdating its
  # status file, re-prime .seen-* to the new signature so the signal scan stays
  # quiet, and confirm it re-surfaces as a paused recheck - never a wedge.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  : > "$out"
  printf 'idle, holding for upstream (token 2)' > "$capture_file"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not re-surface a declared pause past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "re-surface did not print a stale wake"
  grep -F "awaiting external" "$out" >/dev/null || fail "re-surface was not labeled a paused/awaiting-external recheck"
  grep -F "possible wedge" "$out" >/dev/null && fail "a declared pause was mislabeled a possible wedge"
  [ -e "$state/.paused-resurfaced-$key" ] || fail "the paused re-surface throttle marker was not recorded"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused re-surface must not use the wedge timer"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the paused re-surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "paused re-surface was not queued"
  pass "a declared pause is absorbed on first sight, then re-surfaced as a recheck past the threshold, never wedge-escalated"
}

# A captain-held crew can leave a stable backend endpoint after its agent exits.
# fm-crew-state then authoritatively reports stopped rather than paused, but the
# confirmed-dead agent plus the declared wait or captain-held transfer must retain
# bounded pause handling.
# A still-live agent at an external-decision gate is the disconfirming case: it
# must surface once, while the unchanged hash must not append the same wake on
# every watcher re-arm.
test_exited_declared_pause_is_bounded_but_live_gate_surfaces() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back round wakes bare
  dir=$(make_case exited-declared-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window="test:fm-held"
  printf 'idle bare shell after agent exit\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf 'paused: held per captain while an external decision is pending\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle bare shell after agent exit")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  round=1
  while [ "$round" -le 6 ]; do
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
    pid=$!
    if wait_live "$pid" 15; then reap "$pid"; else wait "$pid" || fail "dead-agent watcher round $round failed"; fi
    round=$((round + 1))
  done
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.wake-queue")
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.wake-queue")
  [ "$wakes" -le 1 ] || fail "dead-agent declared pause flooded $wakes stale wakes across six unchanged polls"
  [ "$bare" -eq 0 ] || fail "dead-agent declared pause surfaced as $bare bare stopped-crew wakes"
  grep -F "awaiting external" "$state/.wake-queue" >/dev/null \
    || fail "dead-agent declared pause did not use the bounded paused recheck"

  dir=$(make_case exited-captain-held); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window="test:fm-held"
  printf 'idle bare shell after captain-held transfer\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held.meta"
  printf 'captain-held [key=route]: tracked by held-decision-route\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle bare shell after captain-held transfer")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "captain-held dead-agent pane did not re-surface on the bounded cadence"
  grep -F "awaiting external" "$state/.wake-queue" >/dev/null \
    || fail "captain-held dead-agent pane surfaced as a stopped crew"

  dir=$(make_case alive-decision-gate); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/gate.status"
  window="test:fm-gate"
  printf 'idle external-decision gate\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/gate.meta"
  printf 'paused: waiting at an active external-decision gate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-gate_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle external-decision gate")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  # First sight must surface promptly so a live external-decision gate is not
  # hidden behind the pause cadence.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting at an active external-decision gate' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "live external-decision gate did not surface immediately"
  ack_stopped_cycle "$state" || fail "could not acknowledge the immediate external-decision surface"

  # Re-arm with the stale timer already beyond the wedge threshold. This is the
  # exact unchanged-hash fallback after the immediate surface: it must retain
  # the pause cadence and discard any residual wedge timer instead of emitting
  # a second possible-wedge wake.
  printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting at an active external-decision gate' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"
    fail "live external-decision gate escalated on the wedge timer after its immediate surface: $(cat "$out")"
  fi
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "live external-decision gate lost its pause cadence marker"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "live external-decision gate retained the wedge timer"; }
  reap "$pid"
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.wake-queue")
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.wake-queue")
  [ "$wakes" -eq 0 ] || fail "acknowledged external-decision surface replayed $wakes wakes"
  [ "$bare" -eq 0 ] || fail "acknowledged external-decision bare stale remained queued"
  pass "exited declared-pause and captain-held panes use bounded pause cadence while a live decision gate still surfaces once"
}

test_secondmate_paused_resurfaces_in_normal_mode() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back
  dir=$(make_case secondmate-paused-resurface); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-held.status"
  window="test:fm-secondmate-held"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-held.meta"
  printf 'paused: awaiting the upstream release\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-secondmate-held_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream release'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not re-surface a paused secondmate"
  grep -F "stale: $window" "$out" >/dev/null || fail "paused secondmate did not emit a stale recheck"
  grep -F "awaiting external" "$out" >/dev/null || fail "paused secondmate recheck omitted its external-wait reason"
  grep -F "possible wedge" "$out" >/dev/null && fail "paused secondmate was mislabeled a wedge"
  unset FM_FAKE_CREW_STATE
  pass "a declared paused secondmate re-surfaces on the bounded normal-mode cadence"
}

test_secondmate_nonpaused_stale_remains_suppressed() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid
  dir=$(make_case secondmate-stale-suppressed); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-working.status"
  window="test:fm-secondmate-working"
  printf 'idle while the parent supervises\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-working.meta"
  printf 'working: the parent supervises this secondmate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-secondmate-working_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle while the parent supervises")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher surfaced an ordinary secondmate stale pane: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "ordinary secondmate stale pane printed a wake reason: $(cat "$out")"; }
  reap "$pid"
  pass "a non-paused secondmate retains normal stale suppression"
}

test_secondmate_unpause_clears_pause_tracking() {
  local dir state fakebin out statusf window key pid
  dir=$(make_case secondmate-unpause-clears); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; statusf="$state/secondmate-resumed.status"; window="test:fm-secondmate-resumed"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-resumed.meta"
  printf 'working: upstream landed\n' > "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-secondmate-resumed_status"
  key=${window//:/_}
  key=${key//\//_}
  key=${key//./_}
  : > "$state/.paused-$key"
  : > "$state/.paused-rechecked-$key"
  : > "$state/.paused-resurfaced-$key"
  : > "$state/.stale-$key"
  : > "$state/.stale-since-$key"
  : > "$state/.wedge-escalations-$key"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_live "$pid" 20 || fail "watcher exited while reconciling a resumed secondmate: $(cat "$out")"
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "resumed secondmate retained the pause marker"; }
  [ ! -e "$state/.stale-$key" ] || { reap "$pid"; fail "resumed secondmate retained stale tracking"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "resumed secondmate retained wedge tracking"; }
  reap "$pid"
  pass "a resumed secondmate clears pause and stale tracking before stale exemption"
}

test_nonterminal_stale_pause_transitions_reclassify_unchanged_hash() {
  local dir state fakebin out capture_file window key pane_hash sig pid i
  dir=$(make_case nonterminal-stale-pause-transition); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-transition"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/transition.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/transition.status"
  sig=$(seen_sig "$state/transition.status"); printf '%s' "$sig" > "$state/.seen-transition_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream release'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    [ -e "$state/.paused-$key" ] && [ ! -e "$state/.stale-since-$key" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "a stale hash that entered pause was wedge-escalated: $(cat "$out")"; }
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "unchanged stale hash did not enter paused mode"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "pause transition retained its wedge timer"; }
  wait_live "$pid" 30 || { reap "$pid"; fail "a stale hash that entered pause was wedge-escalated: $(cat "$out")"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional entered-pause watcher stop"

  printf 'working: upstream landed, resuming\n' > "$state/transition.status"
  sig=$(seen_sig "$state/transition.status"); printf '%s' "$sig" > "$state/.seen-transition_status"
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    [ ! -e "$state/.paused-$key" ] && [ -s "$state/.stale-since-$key" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "a stale hash that left pause did not resume wedge tracking: $(cat "$out")"; }
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "unchanged stale hash retained paused mode after resume"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "unchanged stale hash did not restart wedge tracking after resume"; }
  wait_live "$pid" 30 || { reap "$pid"; fail "a stale hash that left pause did not resume wedge tracking: $(cat "$out")"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "unchanged stale hashes reclassify when a crew enters or leaves pause"
}

test_nonterminal_paused_rechecks_authoritative_state() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-paused-recheck); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-pause-recheck"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/pause-recheck.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/pause-recheck.status"
  sig=$(seen_sig "$state/pause-recheck.status"); printf '%s' "$sig" > "$state/.seen-pause-recheck_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "an active run behind a declared pause surfaced instead of resuming wedge tracking: $(cat "$out")"
  fi
  [ ! -e "$state/.paused-$key" ] || { reap "$pid"; fail "authoritative active run retained paused mode"; }
  [ -s "$state/.stale-since-$key" ] || { reap "$pid"; fail "authoritative active run did not resume wedge tracking"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a declared pause is periodically rechecked against authoritative active-run state"
}

test_paused_authoritative_working_preserves_wedge_timer() {
  local dir state fakebin out capture_file window key pane_hash sig pid since
  dir=$(make_case paused-working-preserves-wedge-timer); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-paused-working"
  printf 'idle awaiting external\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/paused-working.meta"
  printf 'paused: awaiting the upstream release\n' > "$state/paused-working.status"
  sig=$(seen_sig "$state/paused-working.status"); printf '%s' "$sig" > "$state/.seen-paused-working_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle awaiting external")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$state/.paused-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "authoritative working state did not start wedge tracking"; }
  since=$(cat "$state/.stale-since-$key")
  sleep 2
  [ "$(cat "$state/.stale-since-$key" 2>/dev/null || true)" = "$since" ] \
    || { reap "$pid"; fail "repeat authoritative working recheck reset the wedge timer"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional authoritative-working stop"

  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "authoritative working state did not wedge-escalate past the threshold"
  grep -F "possible wedge" "$out" >/dev/null || fail "authoritative working wedge escalation omitted its reason"
  [ ! -e "$state/.stale-since-$key" ] || fail "wedge timer remained after authoritative working escalation"
  unset FM_FAKE_CREW_STATE
  pass "a paused status overridden by authoritative working preserves its wedge timer and escalates"
}

# --- consecutive wedge escalations on the same pane demand deep inspection ----
# Root cause of the PR #252 incident's ~20 minutes of unnoticed green: each
# wedge escalation fires, gets classified as "still validating" one poll later
# (the timer restarts, see wedge_timer_check), and repeats forever on a pane
# that never changes. A single escalation reason looks identical every round,
# so nothing in the payload itself signals "this has now happened N times in a
# row" - that judgment call was left entirely to the supervisor noticing the
# repetition on its own. This is the safety-net fix: past
# FM_WEDGE_DEMAND_INSPECT_COUNT consecutive escalations on the SAME pane, the
# wake reason itself carries a "demand-deep-inspection" marker.

test_wedge_escalation_marks_demand_deep_inspection_after_threshold() {
  local dir state fakebin out capture_file window key pane_hash sig pid n
  dir=$(make_case wedge-escalation); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedged"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedged.meta"
  printf 'working: still monitoring ci\n' > "$state/wedged.status"
  sig=$(seen_sig "$state/wedged.status"); printf '%s' "$sig" > "$state/.seen-wedged_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The crew's pipeline is actively running: a static pane is normal (waiting on CI).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Priming round: first sighting of this stale hash classifies and absorbs it
  # (establishing .stale-$key and starting the wedge timer) without going
  # through wedge_timer_check at all - mirrors the existing wedge tests' Phase A.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited on the priming round (should absorb): $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional wedge priming stop"

  n=1
  while [ "$n" -le 3 ]; do
    # Backdate the wedge timer past the threshold before each round, mirroring
    # the existing wedge-escalation tests' Phase B (the subsequent-sight timer
    # path does not re-read the crew state).
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 40 || fail "watcher did not escalate on consecutive wedge round $n: $(cat "$out")"
    grep -F "escalation $n" "$out" >/dev/null || fail "round $n did not report escalation count $n: $(cat "$out")"
    if [ "$n" -lt 3 ]; then
      grep -F "demand-deep-inspection" "$out" >/dev/null && fail "round $n escalated to demand-deep-inspection before the threshold: $(cat "$out")"
    else
      grep -F "demand-deep-inspection" "$out" >/dev/null || fail "round $n (threshold) did not demand deep inspection: $(cat "$out")"
    fi
    ack_stopped_cycle "$state" || fail "could not acknowledge wedge escalation round $n"
    n=$((n + 1))
  done
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 3 ] || fail "escalation counter did not persist across consecutive rounds"
  unset FM_FAKE_CREW_STATE
  pass "consecutive wedge escalations on the same pane accumulate and demand deep inspection at the threshold"
}

test_wedge_escalation_resets_when_pane_becomes_active() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case wedge-escalation-reset); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-wedged-reset"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedged-reset.meta"
  printf 'working: still monitoring ci\n' > "$state/wedged-reset.status"
  sig=$(seen_sig "$state/wedged-reset.status"); printf '%s' "$sig" > "$state/.seen-wedged-reset_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Pre-seed one escalation as if a prior wedge round already fired.
  printf '1\n' > "$state/.wedge-escalations-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # The pane content changes (the crew is active again): the hash no longer
  # matches, so the watcher resets escalation bookkeeping instead of escalating.
  printf 'new output, crew active again' > "$capture_file"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited on a fresh (changed) pane hash: $(cat "$out")"
  fi
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a changed pane hash did not reset the wedge-escalation counter"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a pane becoming active again resets the consecutive wedge-escalation counter"
}

# --- busy pane duration bound: a completed-turn age gate on top of busy -----
# 2026-07 hibit-agent-focus-nonsteal-r1 incident: a busy pane (herdr "working"
# and/or the harness's rendered busy footer) is unconditional, unbounded proof
# of liveness in every existing classifier, so a genuinely hung foreground tool
# call behind a busy signature ran undetected for 25h. BUSY_TURN_MAX_SECS bounds
# how long a busy pane may run with no completed turn (state/<id>.turn-ended, or
# the task's spawn record before any turn completes); past the bound the SAME
# wedge_timer_check already used for a provably-working non-busy stale takes
# over, so escalation reuses the identical stale reason, escalation counter, and
# demand-deep-inspection marker - never an automatic interrupt or restart.

test_busy_pane_below_turn_age_bound_is_absorbed() {
  local dir state fakebin out capture_file window key sig pid
  dir=$(make_case busy-below-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-fresh"
  printf 'Working... (12.3s)' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-fresh.meta"
  record_pi_busy "$state" busy-fresh
  printf 'working: setup complete\n' > "$state/busy-fresh.status"
  sig=$(seen_sig "$state/busy-fresh.status"); printf '%s' "$sig" > "$state/.seen-busy-fresh_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  touch "$state/busy-fresh.turn-ended"
  prime_turnend_seen "$state/busy-fresh.turn-ended"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=999 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "a busy pane below the turn-age bound was escalated: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a busy pane below the turn-age bound printed a wake reason"
  [ ! -e "$state/.stale-since-$key" ] || fail "a busy pane below the turn-age bound started a wedge timer"
  reap "$pid"
  pass "a busy worker below the turn-age bound remains working with no escalation"
}

test_busy_pane_stable_hash_escalates_past_turn_age_bound() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case busy-stable-hash-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-stable"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-stable.meta"
  record_pi_busy "$state" busy-stable
  printf 'working: setup complete\n' > "$state/busy-stable.status"
  sig=$(seen_sig "$state/busy-stable.status"); printf '%s' "$sig" > "$state/.seen-busy-stable_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # No completed turn ever recorded for this task: age the spawn record itself.
  touch -t 200001010000 "$state/busy-stable.meta"

  # Phase A: past the bound, the stable-hash busy pane is absorbed but starts
  # the wedge timer (mirrors the existing provably-working-stale Phase A/B).
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "a stable-hash busy pane past the turn-age bound escalated before the wedge threshold: $(cat "$out")"
  fi
  [ -s "$state/.stale-since-$key" ] || fail "a stable-hash busy pane past the turn-age bound did not start a wedge timer"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional stable-hash phase-A stop"

  # Phase B: backdate the wedge timer past the threshold; the next poll escalates.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a stable-hash busy pane did not wedge-escalate past the turn-age bound"
  grep -F "stale: $window" "$out" >/dev/null || fail "busy turn-age escalation did not print the stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "busy turn-age escalation did not flag a possible wedge"
  pass "a busy worker with a stable pane hash still escalates once its completed-turn age reaches the bound"
}

# Regression fixture for the incident's actual masking condition: Pi's rendered
# elapsed-time footer changes every poll, so the pane hash never repeats and the
# watcher always takes the "new hash" branch, never the stable-hash one above.
test_busy_pane_changing_hash_escalates_past_turn_age_bound() {
  local dir state fakebin out capture_file window key pid
  dir=$(make_case busy-changing-hash-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-ticking"
  printf 'Working... (3600.1s)' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-ticking.meta"
  record_pi_busy "$state" busy-ticking
  printf 'working: setup complete\n' > "$state/busy-ticking.status"
  sig=$(seen_sig "$state/busy-ticking.status"); printf '%s' "$sig" > "$state/.seen-busy-ticking_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  touch -t 200001010000 "$state/busy-ticking.meta"
  # No pre-seeded .hash-<key>: with a real ticking elapsed footer, every poll
  # lands here (h != prev) - the reproduction's actual masking condition.

  # Phase A: first sight past the bound absorbs and starts the wedge timer,
  # without ever needing the "genuinely stale" hash-match path.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "a changing-hash busy pane past the turn-age bound escalated before the wedge threshold: $(cat "$out")"
  fi
  [ -s "$state/.stale-since-$key" ] || fail "a changing-hash busy pane past the turn-age bound did not start a wedge timer"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional changing-hash phase-A stop"

  # Phase B: another tick (still a fresh, never-before-seen hash) plus a
  # backdated wedge timer escalates exactly as the stable-hash case does.
  printf 'Working... (3601.2s)' > "$capture_file"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "a changing-hash busy pane did not wedge-escalate past the turn-age bound"
  grep -F "stale: $window" "$out" >/dev/null || fail "busy turn-age escalation (changing hash) did not print the stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "busy turn-age escalation (changing hash) did not flag a possible wedge"
  pass "a busy worker whose pane hash changes every poll still escalates once its completed-turn age reaches the bound"
}

test_busy_pane_turn_end_touch_resets_age() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case busy-turn-end-resets-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-reset"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-reset.meta"
  record_pi_busy "$state" busy-reset
  printf 'working: setup complete\n' > "$state/busy-reset.status"
  sig=$(seen_sig "$state/busy-reset.status"); printf '%s' "$sig" > "$state/.seen-busy-reset_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # A wedge is already mid-escalation, as if several over-age polls already ran.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '1\n' > "$state/.wedge-escalations-$key"
  # The worker's most recent turn just completed: touching turn-ended resets age.
  touch "$state/busy-reset.turn-ended"
  prime_turnend_seen "$state/busy-reset.turn-ended"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=3600 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "a freshly completed turn on a busy pane was still escalated: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a freshly completed turn on a busy pane printed a wake reason"
  [ ! -e "$state/.stale-since-$key" ] || fail "a freshly completed turn did not clear the wedge timer"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a freshly completed turn did not clear the escalation counter"
  reap "$pid"
  pass "touching a busy worker's completed-turn marker resets the age and prevents an old-age escalation"
}

test_busy_pane_repeated_escalation_reaches_demand_deep_inspection() {
  local dir state fakebin out capture_file window key pane_hash sig pid n
  dir=$(make_case busy-turn-age-demand-inspect); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-demand-inspect"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-demand.meta"
  record_pi_busy "$state" busy-demand
  printf 'working: setup complete\n' > "$state/busy-demand.status"
  sig=$(seen_sig "$state/busy-demand.status"); printf '%s' "$sig" > "$state/.seen-busy-demand_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  touch -t 200001010000 "$state/busy-demand.turn-ended"
  prime_turnend_seen "$state/busy-demand.turn-ended"

  # Priming round: first sighting past the turn-age bound absorbs and starts
  # the wedge timer, mirroring the existing provably-working wedge tests.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "priming round for busy turn-age escalation was not absorbed: $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional busy-wedge priming stop"

  n=1
  while [ "$n" -le 3 ]; do
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
      FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 40 || fail "busy turn-age escalation round $n did not escalate: $(cat "$out")"
    grep -F "escalation $n" "$out" >/dev/null || fail "busy turn-age round $n did not report escalation count $n: $(cat "$out")"
    if [ "$n" -lt 3 ]; then
      grep -F "demand-deep-inspection" "$out" >/dev/null && fail "busy turn-age round $n escalated to demand-deep-inspection before the threshold: $(cat "$out")"
    else
      grep -F "demand-deep-inspection" "$out" >/dev/null || fail "busy turn-age round $n (threshold) did not demand deep inspection: $(cat "$out")"
    fi
    ack_stopped_cycle "$state" || fail "could not acknowledge busy turn-age escalation round $n"
    n=$((n + 1))
  done
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 3 ] || fail "busy turn-age escalation counter did not persist across consecutive rounds"
  pass "repeated busy turn-age escalations reuse the existing escalation counter and demand deep inspection at the threshold"
}

# Behavioral proof that the production default (no FM_BUSY_TURN_MAX_SECS override
# anywhere in this env) is 3600s: a completed turn 5 minutes old must not start a
# wedge timer, while one 66 minutes old must - bracketing the default around 3600
# without waiting a literal hour.
test_busy_pane_default_turn_age_bound_is_3600s() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case busy-default-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window="test:fm-busy-default"
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/busy-default.meta"
  record_pi_busy "$state" busy-default
  printf 'working: setup complete\n' > "$state/busy-default.status"
  sig=$(seen_sig "$state/busy-default.status"); printf '%s' "$sig" > "$state/.seen-busy-default_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  set_mtime $(( $(date +%s) - 300 )) "$state/busy-default.turn-ended"
  prime_turnend_seen "$state/busy-default.turn-ended"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "a 5-minute-old completed turn tripped the default busy-turn-age bound: $(cat "$out")"
  fi
  [ ! -e "$state/.stale-since-$key" ] || fail "a 5-minute-old completed turn started a wedge timer under the default bound"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional five-minute-bound stop"

  set_mtime $(( $(date +%s) - 4000 )) "$state/busy-default.turn-ended"
  prime_turnend_seen "$state/busy-default.turn-ended"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "a 66-minute-old completed turn escalated before the wedge threshold under the default bound: $(cat "$out")"
  fi
  [ -s "$state/.stale-since-$key" ] || fail "a 66-minute-old completed turn did not start a wedge timer under the default bound (default is not 3600s)"
  reap "$pid"
  pass "the production default busy-turn-age bound is 3600s (5min under does not wedge, 66min over does)"
}

test_nonterminal_stale_repairs_missing_or_corrupt_timer() {
  local dir state fakebin out capture_file window key pane_hash sig pid since
  dir=$(make_case nonterminal-stale-timer-repair); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-quiet-timer"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/quiet-timer.meta"
  printf 'working: still compiling\n' > "$state/quiet-timer.status"
  sig=$(seen_sig "$state/quiet-timer.status"); printf '%s' "$sig" > "$state/.seen-quiet-timer_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "matching stale suppressor with missing timer did not initialize stale-since"; }
  if ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    fail "watcher exited while repairing a missing stale-since timer: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "missing stale-since repair enqueued a wake"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional missing-timer repair stop"

  printf 'corrupt\n' > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_numeric_file "$state/.stale-since-$key" 30 || { reap "$pid"; fail "matching stale suppressor with corrupt timer did not repair stale-since"; }
  since=$(cat "$state/.stale-since-$key" 2>/dev/null || true)
  [ "$since" != "corrupt" ] || { reap "$pid"; fail "corrupt stale-since value was left in place"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "corrupt stale-since repair enqueued a wake"; }
  reap "$pid"
  pass "matching non-terminal stale suppressors repair missing or corrupt stale-since timers"
}

# --- triage debug log stays size capped -------------------------------------

test_triage_log_size_cap_accepts_spaced_wc_counts() {
  local dir state fakebin out status_file pid lines i
  dir=$(make_case triage-log-spaced-wc); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  i=1
  while [ "$i" -le 3000 ]; do
    printf 'old line %04d\n' "$i" >> "$state/.watch-triage.log"
    i=$((i + 1))
  done
  cat > "$fakebin/wc" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "-c" ]; then
  printf '   999999\n'
  exit 0
fi
exit 127
SH
  chmod +x "$fakebin/wc"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # Provably working so the no-verb signal is absorbed (which is what writes the
  # triage log line under test).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_TRIAGE_LOG_MAX_BYTES=1 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a benign signal while testing log capping: $(cat "$out")"
  fi
  i=0
  while [ "$i" -lt 30 ]; do
    lines=$(awk 'END { print NR + 0 }' "$state/.watch-triage.log")
    [ "$lines" -le 2000 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$lines" -le 2000 ] || { reap "$pid"; fail "triage log was not capped when wc emitted a spaced byte count (lines=$lines)"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "benign signal enqueued a wake while testing log capping"; }
  reap "$pid"
  pass "triage log capping handles wc byte counts with leading spaces"
}

# --- process-event delivery -------------------------------------------------
# A durably captured process-event result publishes an ordinary `check` wake on
# the durable queue. The watcher must deliver that queued wake proactively -
# print an actionable reason and exit into the same rewake path every other
# actionable wake uses - rather than leaving it to be found by a manual drain.

# Run the runner against a case home. FM_ROOT_OVERRIDE (exported by the shared
# wake harness to keep the drain's tangle check inert) would otherwise point the
# runner at a root with no installed adapters, and the claim root must stay
# inside the case so nothing here can observe a real home's source ownership.
pe_case() {  # <dir> <command>...
  local dir=$1
  shift
  (unset FM_ROOT_OVERRIDE
   FM_PROCEVENT_CLAIM_ROOT="$dir/claims" FM_HOME="$dir" "$ROOT/bin/fm-procevent.sh" "$@")
}

# Capture one real process-event result into <dir>'s home, then retire the
# source so the fixture holds exactly the reported end state: one durably
# captured, unhandled, queued result and no remaining poll work.
seed_captured_procevent_result() {  # <dir>
  local dir=$1 i=0
  pe_case "$dir" register lavish delivery-src -- \
    /bin/sh -c 'printf "session:\n  file: /a.html\n  status: waiting\n"' >/dev/null || return 1
  pe_case "$dir" reconcile >/dev/null || return 1
  while [ "$i" -lt 100 ]; do
    [ -s "$dir/state/.wake-queue" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  pe_case "$dir" retire delivery-src >/dev/null || return 1
  [ -s "$dir/state/.wake-queue" ]
}

# The watcher, scoped by FM_HOME rather than FM_STATE_OVERRIDE, so the
# per-cycle reconcile it launches resolves the same home's state.
procevent_watch_bg() {  # <dir> <out>
  local dir=$1 out=$2
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
}

test_procevent_captured_result_surfaces_proactively() {
  local dir state out drain_out pid beacon_age
  dir=$(make_case procevent-delivery); state="$dir/state"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  seed_captured_procevent_result "$dir" || fail "the fixture captured no process-event result"
  grep -F "procevent lavish delivery-src 1" "$state/.wake-queue" >/dev/null \
    || fail "the captured result was never published to the durable queue"

  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 \
    || fail "a healthy watcher never surfaced a durably captured process-event result: $(cat "$out")"
  grep -F "check:" "$out" >/dev/null \
    || fail "the process-event wake was not reported as an actionable check: $(cat "$out")"
  grep -F "procevent:delivery-src:1" "$out" >/dev/null \
    || fail "the actionable reason did not name the queued result: $(cat "$out")"
  beacon_age=$(FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_path_age "$2"' _ "$ROOT" "$state/.last-watcher-beat")
  [ "$beacon_age" -lt 60 ] || fail "the surfacing watcher was not a healthy one (beacon age ${beacon_age}s)"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the process-event wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "procevent lavish delivery-src 1" >/dev/null \
    || fail "the process-event result was not queued for the drain that follows the wake"
  pass "a captured process-event result wakes a healthy watcher proactively, with no manual drain"
}

test_procevent_unacknowledged_result_redrains_until_handled() {
  local dir state out replay_out replay_err pid before after sequence generation
  dir=$(make_case procevent-redrain); state="$dir/state"
  out="$dir/watch.out"; replay_out="$dir/replay.out"; replay_err="$dir/replay.err"
  seed_captured_procevent_result "$dir" || fail "the fixture captured no process-event result"

  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "the first proactive wake never happened: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "drain after the first process-event wake failed"

  # An interrupted handler leaves the captured result durable. The successor
  # must re-surface it through recovery, then its drain must print the same row.
  : > "$out"
  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 \
    || fail "an unacknowledged process-event result was not re-surfaced on re-arm: $(cat "$out")"
  grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || fail "the successor did not report recovery for the unacknowledged result: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$replay_out" 2> "$replay_err" \
    || fail "the successor could not re-drain the unacknowledged process-event result"
  grep "$(printf '\tcheck\t')" "$replay_out" | grep -F 'procevent lavish delivery-src 1' >/dev/null \
    || fail "the successor drain did not re-print the durable process-event row"

  pe_case "$dir" handled delivery-src 1 >/dev/null || fail "could not acknowledge the captured result"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$replay_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$replay_err")
  [ -n "$sequence" ] && [ -n "$generation" ] \
    || fail "the replay drain omitted its post-handling acknowledgement boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "completed process-event handling could not acknowledge the replay"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledged process-event replay remained durable"

  before=$(awk 'END { print NR + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  : > "$out"
  procevent_watch_bg "$dir" "$out"
  pid=$!
  if ! wait_live "$pid" 40; then
    fail "a handled process-event result woke the watcher: $(cat "$out")"
  fi
  reap "$pid"
  after=$(awk 'END { print NR + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$after" = "$before" ] || fail "a handled result was announced again ($before -> $after queued records)"
  pass "an unacknowledged process-event result re-drains until handling is acknowledged"
}

test_procevent_marker_keys_are_injective() {
  local dir state out pid marker_count
  dir=$(make_case procevent-marker-identity); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:a.b:1" "check: procevent fixture a.b 1"
  append_wake "$state" check "procevent:a_b:1" "check: procevent fixture a_b 1"
  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "colliding-looking process-event keys were not surfaced"
  grep -F "procevent:a.b:1" "$out" >/dev/null || fail "the dotted queue key was suppressed"
  grep -F "procevent:a_b:1" "$out" >/dev/null || fail "the underscored queue key was suppressed"
  marker_count=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | awk 'END { print NR + 0 }')
  [ "$marker_count" = 2 ] || fail "distinct queue keys produced $marker_count seen markers"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "marker identity fixture drain failed"
  pass "complete process-event queue keys map to distinct seen markers"
}

install_marker_mv_fault() {  # <dir>
  local dir=$1
  REAL_MV=$(command -v mv)
  export REAL_MV
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
dest=${!#}
case "$dest" in
  */.seen-procevent-*)
    case "${FM_MARKER_MV_MODE:-}" in
      pause)
        printf '1\n' > "$FM_MARKER_MV_READY"
        while [ ! -e "$FM_MARKER_MV_RELEASE" ]; do sleep 0.02; done
        ;;
      kill-before) kill -KILL "$PPID"; exit 1 ;;
      kill-after) "$REAL_MV" "$@" || exit; kill -KILL "$PPID"; exit 1 ;;
      fail) exit 1 ;;
    esac
    ;;
esac
exec "$REAL_MV" "$@"
SH
  chmod +x "$dir/fakebin/mv"
}

test_procevent_surface_serializes_with_drain() {
  local dir state out drain_out ready release pid drain_pid
  dir=$(make_case procevent-drain-race); state="$dir/state"; out="$dir/watch.out"
  drain_out="$dir/drain.out"; ready="$dir/marker-ready"; release="$dir/marker-release"
  append_wake "$state" check "procevent:drain-race:1" "check: procevent fixture drain-race 1"
  install_marker_mv_fault "$dir"
  FM_MARKER_MV_MODE=pause FM_MARKER_MV_READY="$ready" FM_MARKER_MV_RELEASE="$release" \
    procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_numeric_file "$ready" 100 || fail "the watcher never reached its marker commit boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" &
  drain_pid=$!
  wait_live "$drain_pid" 10 || fail "a concurrent drain split the surfacing transition"
  [ -s "$state/.wake-queue" ] || fail "the concurrent drain consumed the record before marker commit"
  touch "$release"
  wait "$pid" || fail "the paused watcher did not finish surfacing"
  wait "$drain_pid" || fail "the concurrent drain failed after surfacing committed"
  grep -F "procevent:drain-race:1" "$drain_out" >/dev/null \
    || fail "the serialized drain lost the process-event record"
  pass "queue revalidation, proactive output, and marker commit serialize with drain"
}

test_procevent_surface_crash_boundaries() {
  local dir state out fifo pid reader marker exit_status replay_err sequence generation
  dir=$(make_case procevent-output-fail); state="$dir/state"; out="$dir/watch.out"; fifo="$dir/output.fifo"
  append_wake "$state" check "procevent:output-fail:1" "check: procevent fixture output-fail 1"
  mkfifo "$fifo"
  sh -c ': < "$1"' _ "$fifo" & reader=$!
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$fifo" &
  pid=$!
  wait "$reader" || true
  wait_for_exit "$pid" 100
  exit_status=$?
  [ "$exit_status" -ne 124 ] || fail "the watcher survived a failed actionable output write"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -z "$marker" ] || fail "failed output committed a suppression marker"
  [ -s "$state/.wake-queue" ] || fail "failed output consumed the durable queue record"
  procevent_watch_bg "$dir" "$out"; pid=$!
  wait_for_exit "$pid" 100 || fail "the record was not replayable after output failure"
  grep -F "procevent:output-fail:1" "$out" >/dev/null || fail "output failure lost proactive replay"

  dir=$(make_case procevent-before-marker); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:before-marker:1" "check: procevent fixture before-marker 1"
  install_marker_mv_fault "$dir"
  FM_MARKER_MV_MODE=kill-before procevent_watch_bg "$dir" "$out"; pid=$!
  wait_for_exit "$pid" 100
  exit_status=$?
  [ "$exit_status" -ne 124 ] || fail "the watcher survived the injected pre-marker crash"
  grep -F "procevent:before-marker:1" "$out" >/dev/null || fail "the pre-marker crash happened before output"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -z "$marker" ] || fail "a pre-marker crash committed suppression"
  procevent_watch_bg "$dir" "$out.replay"; pid=$!
  wait_for_exit "$pid" 100 || fail "a pre-marker crash was not replayable"

  dir=$(make_case procevent-after-marker); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:after-marker:1" "check: procevent fixture after-marker 1"
  install_marker_mv_fault "$dir"
  FM_MARKER_MV_MODE=kill-after procevent_watch_bg "$dir" "$out"; pid=$!
  wait_for_exit "$pid" 100
  exit_status=$?
  [ "$exit_status" -ne 124 ] || fail "the watcher survived the injected post-marker crash"
  grep -F "procevent:after-marker:1" "$out" >/dev/null || fail "the post-marker crash lost actionable output"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -n "$marker" ] || fail "the post-marker crash did not reach marker commit"
  : > "$out.replay"
  procevent_watch_bg "$dir" "$out.replay"; pid=$!
  wait_for_exit "$pid" 100 \
    || fail "an unacknowledged delivered record was not re-surfaced on re-arm: $(cat "$out.replay")"
  grep -F 'check: rearm-resurface' "$out.replay" >/dev/null \
    || fail "the successor did not recover the delivered-but-unacknowledged record: $(cat "$out.replay")"
  replay_err="$out.replay.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out.replay.drain" 2> "$replay_err" \
    || fail "post-marker successor drain failed"
  grep "$(printf '\tcheck\t')" "$out.replay.drain" | grep -F 'procevent fixture after-marker 1' >/dev/null \
    || fail "post-marker successor did not re-drain the durable record"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$replay_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$replay_err")
  [ -n "$sequence" ] && [ -n "$generation" ] \
    || fail "post-marker replay omitted its post-handling acknowledgement boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "post-marker replay acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "post-marker acknowledgement left the durable record queued"
  pass "surfacing failures replay until post-handling acknowledgement"
}

test_procevent_marker_failure_exits_and_replays() {
  local dir state out pid marker output_count
  dir=$(make_case procevent-marker-failure); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:marker-failure:1" "check: procevent fixture marker-failure 1"
  install_marker_mv_fault "$dir"
  FM_MARKER_MV_MODE=fail procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "marker failure did not end the actionable watcher cycle successfully"
  output_count=$(grep -Fc "procevent:marker-failure:1" "$out" || true)
  [ "$output_count" = 1 ] || fail "marker failure printed the actionable reason $output_count times"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -z "$marker" ] || fail "marker failure committed suppression"
  [ ! -e "$state/.wake-queue.lock" ] && [ ! -L "$state/.wake-queue.lock" ] \
    || fail "marker failure left the queue lock held"
  procevent_watch_bg "$dir" "$out.replay"
  pid=$!
  wait_for_exit "$pid" 100 || fail "marker failure did not leave the durable record replayable"
  grep -F "procevent:marker-failure:1" "$out.replay" >/dev/null \
    || fail "marker failure lost the later proactive replay"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "marker-failure fixture drain failed"
  pass "marker failure exits through the shared wake owner, releases its lock, and replays later"
}

# --- heartbeat: no-change absorbed, backstop surfaces a missed status --------

test_heartbeat_no_change_absorbed() {
  local dir state fakebin out pid
  dir=$(make_case heartbeat-absorb); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  # A truly quiet fleet (no windows, no statuses) with a fast heartbeat cadence.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a no-change heartbeat (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "no-change heartbeat printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "no-change heartbeat enqueued a durable wake record"
  [ "$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] || fail "heartbeat backoff streak did not advance while absorbing"
  reap "$pid"
  pass "a heartbeat with no captain-relevant change is absorbed and backs off the cadence"
}

test_heartbeat_backstop_surfaces_unsurfaced_status() {
  local dir state fakebin out drain_out sig pid
  dir=$(make_case heartbeat-backstop); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  # A captain-relevant status whose .seen-* signature ALREADY matches (so the
  # per-poll signal scan stays quiet) but which was never surfaced (no
  # .hb-surfaced-* marker). This stands in for a per-wake-path miss; the heartbeat
  # fleet-scan backstop must catch it and wake firstmate.
  printf 'done: PR https://example.test/pr/5\n' > "$state/miss.status"
  sig=$(seen_sig "$state/miss.status"); printf '%s' "$sig" > "$state/.seen-miss_status"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "heartbeat backstop did not surface an unsurfaced captain-relevant status"
  grep -Fx "heartbeat" "$out" >/dev/null || fail "backstop did not exit with a heartbeat wake"
  [ "$(cat "$state/.hb-surfaced-miss" 2>/dev/null || true)" = "done: PR https://example.test/pr/5" ] \
    || fail "backstop did not record the status as surfaced (would re-fire next heartbeat)"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the backstop heartbeat failed"
  grep "$(printf '\theartbeat\t')" "$drain_out" >/dev/null || fail "backstop heartbeat was not queued"
  pass "heartbeat backstop fail-safe surfaces a captain-relevant status the per-wake path missed"
}

# --- beacon stays fresh while absorbing -------------------------------------

test_beacon_stays_fresh_while_absorbing() {
  local dir state fakebin out status_file pid m1 m2 now
  dir=$(make_case beacon-fresh); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: a\n' > "$status_file"
  # Provably working so the working: notes are absorbed (the path that must keep the
  # beacon fresh).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_live "$pid" 15 || { reap "$pid"; fail "watcher exited while absorbing the first benign signal"; }
  m1=$(file_mtime "$state/.last-watcher-beat")
  # A second benign signal keeps it absorbing; the beacon must keep advancing.
  printf 'working: b\n' >> "$status_file"
  wait_live "$pid" 20 || { reap "$pid"; fail "watcher exited while absorbing a second benign signal"; }
  m2=$(file_mtime "$state/.last-watcher-beat")
  now=$(date +%s)
  if [ -z "$m1" ] || [ -z "$m2" ]; then
    reap "$pid"
    fail "watcher beacon missing while absorbing"
  fi
  [ "$m2" -ge "$m1" ] || { reap "$pid"; fail "beacon mtime regressed while absorbing"; }
  [ "$(( now - m2 ))" -lt 10 ] || { reap "$pid"; fail "beacon went stale while absorbing (age $(( now - m2 ))s)"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "absorbing benign signals enqueued a wake"; }
  reap "$pid"
  pass "the liveness beacon stays fresh while the watcher absorbs benign wakes (fm-guard never false-alarms)"
}

# --- afk coherence: the daemon owns triage; the watcher does not double-triage ---

test_afk_present_reverts_watcher_to_one_shot() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case afk-coherence); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: routine note\n' > "$status_file"
  date '+%s' > "$state/.afk"   # away mode: the supervise-daemon owns triage
  # Set a PROVABLY-WORKING verdict: if afk failed to bypass the provably-working
  # check, this no-verb signal would be absorbed (not surfaced). The test asserting
  # a surface therefore also proves afk reverts to one-shot and skips the costly read.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 40 || fail "with .afk present the watcher did not exit one-shot for a benign signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "afk-mode watcher did not surface the signal for the daemon"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the afk-mode signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "afk-mode benign signal was not queued for the daemon to classify"
  pass "with .afk present the watcher reverts to one-shot so the daemon owns triage (no double-triage)"
}

# A paused pane can first appear as a changed hash. In AFK mode that initial path
# must still hand off the plain window identity to the daemon, rather than running
# the normal-mode pause re-surface and decorating the stale identity.
test_afk_paused_changed_pane_hands_off_plain_stale() {
  local dir state fakebin out drain_out capture_file statusf window key sig pid back
  dir=$(make_case afk-paused-changed-pane); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-afk-held"
  printf 'idle, awaiting upstream\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/afk-held.meta"
  statusf="$state/afk-held.status"
  printf 'paused: awaiting the upstream tool release\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-afk-held_status"
  date '+%s' > "$state/.afk"
  key=$(printf '%s' "$window" | tr '.:/' '___')

  # Deliberately do not seed .hash-*: this is the changed-pane path that used to
  # call handle_paused_stale before AFK's one-shot daemon handoff.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream tool release' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "AFK paused changed pane did not hand off a stale wake"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "AFK paused stale did not preserve its plain window identity: $(cat "$out")"
  grep -F "awaiting external" "$out" >/dev/null && fail "AFK watcher decorated a stale identity instead of handing it to the daemon"
  [ ! -e "$state/.paused-$key" ] || fail "AFK watcher recorded normal-mode pause tracking instead of handing off"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after AFK paused stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "stale: $window" >/dev/null \
    || fail "AFK paused stale was not queued with the plain window identity"
  pass "AFK changed paused panes hand off plain stale identities for daemon-owned pause triage"
}

# --- stale pane, task carries an OPEN captain decision: absorbed on the long
#     cadence, never wedge-escalated every STALE_ESCALATE_SECS ----------------
# The live 2026-08 case: a crew parked on a captain decision (needs-decision:)
# with a provably-working pane tripped a possible-wedge stale every four minutes,
# each costing a full firstmate turn only to re-conclude "still waiting for the
# same decision". The open decision (status_open_decisions) explains the
# inactivity, so the watcher absorbs it on the long PAUSE_RESURFACE_SECS cadence
# instead, exactly like a declared pause but kept distinct.
test_open_decision_stale_absorbed_on_long_cadence_not_wedged() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid back churn_hash i
  dir=$(make_case open-decision-held); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-held"
  printf 'idle, awaiting captain decision\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/held.meta"
  printf 'needs-decision [key=api-shape]: pick A or B\n' > "$state/held.status"
  sig=$(seen_sig "$state/held.status"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle, awaiting captain decision")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'

  # Phase A: first sight of an open-decision stale is absorbed - no wake, no
  # wedge timer, decision-held marker recorded, pause flag untouched.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for an open-decision stale (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "open-decision stale printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "open-decision stale enqueued a wake during absorb"
  [ -e "$state/.decision-held-$key" ] || fail "decision-held marker was not recorded on absorb"
  # The marker is the persisted record of WHICH pane hash this absorb was taken
  # on and WHICH status-file reading its fold ran against, so a later poll can
  # tell "still the absorbed hash" from a re-classified one, and "no new line
  # landed" from "a line landed, re-fold". Its append-detecting signature is the
  # same size:mtime token the signal scan dedupes on, not a bare mtime a
  # same-second closing append could slip through.
  [ "$(cat "$state/.decision-held-$key" 2>/dev/null || true)" \
    = "$(printf '%s\t%s' "$pane_hash" "$(seen_sig "$state/held.status")")" ] \
    || fail "decision-held marker did not record the absorbed hash and the folded status signature"
  [ ! -e "$state/.stale-since-$key" ] || fail "open-decision absorb started the wedge timer"
  [ ! -e "$state/.paused-$key" ] || fail "open-decision absorb touched the pause flag"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] \
    || fail "stale suppressor not advanced on decision-held absorb"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the decision-held phase-A stop"

  # Phase A2: the wedge threshold is now low (240s) - exactly the cadence that
  # wedge-escalated every four minutes today - while the re-surface threshold
  # stays high. The open decision must STILL absorb (no wedge, no wake), proving
  # the 4-min cycle is gone. Backdating .stale-since plants a long-crossed wedge
  # timer, so this also proves the later poll of an absorbed decision-held hash
  # takes the long cadence instead of wedge_timer_check - and that it does so
  # without re-folding, the status file being untouched since the phase-A absorb.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "open-decision stale wedge-escalated at 240s instead of absorbing: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "open-decision stale printed a wake at the 240s wedge threshold"
  [ ! -s "$state/.wake-queue" ] || fail "open-decision stale enqueued a wake at the 240s wedge threshold"
  grep -F "possible wedge" "$out" >/dev/null \
    && fail "open-decision stale was wedge-escalated instead of absorbed"
  [ ! -e "$state/.stale-since-$key" ] || fail "open-decision absorb left the wedge timer armed"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the decision-held phase-A2 stop"

  # Phase B: age the decision past the re-surface threshold by backdating its
  # status file, re-prime .seen-*, and confirm it re-surfaces as a decision-held
  # recheck - never a wedge.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$state/held.status"
  else touch -m -d "@$back" "$state/held.status"; fi
  sig=$(seen_sig "$state/held.status"); printf '%s' "$sig" > "$state/.seen-held_status"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not re-surface an open decision past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "re-surface did not print a stale wake"
  grep -F "awaiting captain" "$out" >/dev/null || fail "re-surface was not labeled a decision-held recheck"
  grep -F "possible wedge" "$out" >/dev/null && fail "an open decision was mislabeled a possible wedge"
  [ -e "$state/.decision-resurfaced-$key" ] || fail "decision re-surface throttle marker was not recorded"
  [ ! -e "$state/.stale-since-$key" ] || fail "decision re-surface used the wedge timer"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the decision re-surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "decision re-surface was not queued"
  ack_stopped_cycle "$state" || fail "could not acknowledge the decision-held phase-B re-surface"

  # Phase C: the pane content churns (a ticking clock, a token counter, a
  # scrolling log line) while the SAME decision stays open and the status file
  # stays untouched. A hash change resets the per-absorb bookkeeping and hands the
  # pane back to first-sight, so the only thing keeping this within one re-surface
  # per window is the throttle marker surviving that reset. It must: the decision
  # just re-surfaced, so the crew must now stay silent for a full window, not wake
  # firstmate again on every churn cycle - which would be more often than the
  # 4-minute wedge cadence this whole path replaces.
  printf 'idle, awaiting captain decision (17204 tokens)\n' > "$capture_file"
  churn_hash=$(hash_text "idle, awaiting captain decision (17204 tokens)")
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ]; do
    [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$churn_hash" ] && break
    is_live_non_zombie "$pid" || break
    sleep 0.1
    i=$((i + 1))
  done
  if ! is_live_non_zombie "$pid"; then
    reap "$pid"; fail "the churned pane re-surfaced within the window instead of staying absorbed: $(cat "$out")"
  fi
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$churn_hash" ] \
    || { reap "$pid"; fail "the churned pane was never re-absorbed on the long cadence"; }
  [ ! -s "$out" ] || { reap "$pid"; fail "the churned pane printed a wake inside the re-surface window"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "the churned pane enqueued a wake inside the re-surface window"; }
  [ -e "$state/.decision-resurfaced-$key" ] \
    || { reap "$pid"; fail "the re-surface throttle marker did not survive the hash change"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "the churned pane re-armed the wedge timer"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "an open captain decision is absorbed on the long cadence and re-surfaced as a recheck, never wedge-escalated"
}

# --- open decision but the crew is NOT provably working: surfaced immediately -
# The decision-held absorb is a trade of the WEDGE TIMER, which only a
# provably-working pane ever armed. A crew that stopped or died with a decision
# still open shows no working evidence, so the absorb-only-when-provably-working
# rule stands: it surfaces at once instead of being swallowed for a whole
# PAUSE_RESURFACE_SECS window (and, since a never-answered decision never closes,
# potentially forever). Covers both shapes of that pane: the open decision as the
# log's last line (terminal triage) and buried under a later append
# (non-terminal triage).
test_open_decision_not_working_surfaces_immediately() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case open-decision-not-working); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-frozen"
  printf 'bare shell, agent gone\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/frozen.meta"
  printf 'needs-decision [key=api-shape]: pick A or B\n' > "$state/frozen.status"
  sig=$(seen_sig "$state/frozen.status"); printf '%s' "$sig" > "$state/.seen-frozen_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "bare shell, agent gone")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The captain answered in the pane (no resolved: line was ever appended), the
  # crew resumed and then died to a bare shell. The decision fold is still open.
  export FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell'

  # Phase A: the open decision is the last status line, so the terminal triage
  # decides. Not provably working -> surface now, no decision-held absorb.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 \
    || fail "a stopped crew with an open decision was absorbed instead of surfaced: $(cat "$out")"
  grep -F "stale: $window" "$out" >/dev/null || fail "terminal open-decision stale did not surface for a stopped crew"
  grep -F "awaiting captain" "$out" >/dev/null \
    && fail "a stopped crew was absorbed on the decision-held long cadence"
  [ ! -e "$state/.decision-held-$key" ] || fail "a stopped crew was flagged decision-held"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the terminal surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null \
    || fail "the terminal open-decision surface was not queued"

  # Phase B: same still-open decision, now buried under a later non-captain
  # append, so the non-terminal triage decides. Still not provably working ->
  # still surfaced immediately. The suppressor is re-primed to a foreign hash for
  # a clean first-sight, and .seen-* re-primed so the status signal path stays quiet.
  printf 'needs-decision [key=api-shape]: pick A or B\nworking: picking the pieces back up\n' > "$state/frozen.status"
  sig=$(seen_sig "$state/frozen.status"); printf '%s' "$sig" > "$state/.seen-frozen_status"
  printf 'not-this-hash' > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 \
    || fail "a stopped crew with a buried open decision was absorbed instead of surfaced: $(cat "$out")"
  grep -F "stale: $window" "$out" >/dev/null || fail "non-terminal open-decision stale did not surface for a stopped crew"
  grep -F "awaiting captain" "$out" >/dev/null \
    && fail "a stopped crew with a buried decision was absorbed on the decision-held long cadence"
  [ ! -e "$state/.decision-held-$key" ] || fail "a stopped crew with a buried decision was flagged decision-held"
  unset FM_FAKE_CREW_STATE
  pass "an open captain decision never absorbs a crew that is not provably working"
}

# --- a decision-held absorb never outlives the hash it was taken on ---------
# The absorb marker is what the later polls of an absorbed hash route on, so it
# must mean exactly "the last first-sight absorbed THIS hash as decision-held".
# When it outlives its absorb, a pane that has since been re-classified is handed
# the one-hour cadence with its wedge timer disarmed - and because a decision the
# captain answered in the pane never closes in the fold, nothing ever takes it
# back. The reachable leak: a crew parked past BUSY_TURN_MAX_SECS goes busy again
# at a new hash, which routes through the wedge timer rather than the plain reset,
# then dies before finishing its turn. The frozen pane must keep surfacing as the
# stale it is, poll after poll.
test_decision_held_marker_does_not_outlive_its_absorb() {
  local dir state fakebin out capture_file window key h1 h2 sig pid back
  dir=$(make_case decision-held-residual); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-parked"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/parked.meta"
  # Answered in the pane, so no resolved line ever lands: the fold stays open for
  # good, which is what makes an escaped marker permanent rather than transient.
  printf 'needs-decision [key=api-shape]: pick A or B\n' > "$state/parked.status"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$state/parked.status"
  else touch -m -d "@$back" "$state/parked.status"; fi
  sig=$(seen_sig "$state/parked.status"); printf '%s' "$sig" > "$state/.seen-parked_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  h1=$(hash_text "waiting on the captain")
  h2=$(hash_text "resuming after the answer")

  # Phase A: parked and provably working -> absorbed as decision-held at h1.
  printf 'waiting on the captain\n' > "$capture_file"
  printf '%s' "$h1" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  record_pi_state "$state" parked idle
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "the parked crew was not absorbed as decision-held: $(cat "$out")"
  fi
  [ -e "$state/.decision-held-$key" ] || { reap "$pid"; fail "no decision-held absorb to test the residual against"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the residual-marker phase-A stop"

  # Phase B: the crew resumes - pane busy at a NEW hash, and parked longer than
  # BUSY_TURN_MAX_SECS, so the reset routes through the wedge timer instead of the
  # plain erase. That is the sub-branch the marker used to survive.
  printf 'resuming after the answer\n' > "$capture_file"
  record_pi_state "$state" parked busy
  touch -t 200001010000 "$state/parked.meta"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=240 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 40; then
    reap "$pid"; fail "the resumed busy pane surfaced before the wedge threshold: $(cat "$out")"
  fi
  [ "$(cat "$state/.hash-$key" 2>/dev/null || true)" = "$h2" ] \
    || { reap "$pid"; fail "the resumed pane's new hash was never recorded"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the residual-marker phase-B stop"

  # Phase C: the agent dies mid-turn. The backend reports idle again while the
  # frozen pane still renders h2, so first sight finds a crew that is NOT provably
  # working and must surface it at once - which it does, then and now.
  record_pi_state "$state" parked idle
  export FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell'
  sig=$(seen_sig "$state/parked.status"); printf '%s' "$sig" > "$state/.seen-parked_status"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=240 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 60 || fail "the dead crew's frozen pane was never surfaced: $(cat "$out")"
  grep -F "stale: $window" "$out" >/dev/null || fail "the dead crew's frozen pane did not surface as stale"
  ack_stopped_cycle "$state" || fail "could not acknowledge the dead-crew surface"

  # Phase D: the pane is unchanged, so this is a LATER poll of the hash first
  # sight just surfaced. A marker left over from phase A's absorb would route it
  # to the decision-held cadence here - swallowing a dead crew for a whole
  # PAUSE_RESURFACE_SECS window, on repeat, since the decision never closes.
  sig=$(seen_sig "$state/parked.status"); printf '%s' "$sig" > "$state/.seen-parked_status"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=240 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 40; then
    reap "$pid"
    fail "a residual decision-held marker re-absorbed a dead crew onto the long cadence: $(cat "$out")"
  fi
  grep -F "awaiting captain" "$out" >/dev/null \
    && { reap "$pid"; fail "a dead crew was rechecked as a held decision instead of staying surfaced"; }
  [ ! -e "$state/.decision-held-$key" ] \
    || { reap "$pid"; fail "the decision-held marker outlived the absorb it was written for"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a decision-held marker never outlives its absorb to swallow a re-classified pane"
}

# --- a busy blink behind a frozen screen must not undo the absorb -----------
# A crew parked on a decision is idle for hours, so it crosses BUSY_TURN_MAX_SECS
# by construction; one poll where the semantic busy contract reports busy while
# the pane renders exactly the same screen then routes through the wedge timer.
# The pane never leaves that hash, so there is no later first-sight to re-decide
# anything: whatever this poll leaves behind is permanent. Dropping the absorb
# marker here would hand the parked crew straight back to the 240s cycle this
# whole path exists to remove.
test_decision_held_absorb_survives_a_busy_blip_at_the_same_hash() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case decision-held-busy-blip); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window="test:fm-blip"
  printf 'waiting on the captain\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/blip.meta"
  printf 'needs-decision [key=api-shape]: pick A or B\n' > "$state/blip.status"
  sig=$(seen_sig "$state/blip.status"); printf '%s' "$sig" > "$state/.seen-blip_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "waiting on the captain")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  record_pi_state "$state" blip idle
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Phase A: absorbed as decision-held, wedge timer disarmed.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "the parked crew was not absorbed as decision-held: $(cat "$out")"
  fi
  [ -e "$state/.decision-held-$key" ] || { reap "$pid"; fail "no decision-held absorb to blip"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "the decision-held absorb left a wedge timer armed"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the busy-blip phase-A stop"

  # Phase B: the blink. Same screen, same hash - only the backend's verdict flips,
  # and the parked crew is long past its completed-turn bound, so this poll takes
  # the wedge-timer sub-branch of the same-hash reset and arms .stale-since-.
  record_pi_state "$state" blip busy
  touch -t 200001010000 "$state/blip.meta"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 40; then
    reap "$pid"; fail "the busy blink surfaced instead of resetting bookkeeping: $(cat "$out")"
  fi
  [ -s "$state/.stale-since-$key" ] \
    || { reap "$pid"; fail "the busy blink did not take the wedge-timer reset sub-branch under test"; }
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] \
    || { reap "$pid"; fail "the busy blink moved the stale suppressor off the absorbed hash"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the busy-blip phase-B stop"

  # Phase C: idle again on the same frozen screen, with the timer the blink armed
  # backdated well past a live 240s threshold. The parked crew must return to the
  # long cadence and disarm that timer - not escalate as a possible wedge.
  record_pi_state "$state" blip idle
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  sig=$(seen_sig "$state/blip.status"); printf '%s' "$sig" > "$state/.seen-blip_status"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 40; then
    reap "$pid"
    fail "a busy blink dropped the parked crew back onto the 240s wedge cycle: $(cat "$out")"
  fi
  grep -F "possible wedge" "$out" >/dev/null \
    && { reap "$pid"; fail "the parked crew wedge-escalated after a busy blink"; }
  [ -e "$state/.decision-held-$key" ] \
    || { reap "$pid"; fail "the busy blink dropped the absorb marker for a hash the pane never left"; }
  [ ! -e "$state/.stale-since-$key" ] \
    || { reap "$pid"; fail "the resumed absorb did not disarm the timer the blink armed"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a busy blink behind a frozen screen never drops a parked crew back onto the wedge cycle"
}

# --- the decision closes: normal wedge cadence resumes immediately ----------
# A crew that stays mute AFTER the captain's answer is a real wedge and must
# re-escalate. Once the decision fold closes (a resolved line lands),
# task_has_open_decision turns false, the decision-held tracking is cleared, and
# the next poll re-evaluates the pane from a clean first-sight under the normal
# terminal/non-terminal triage - so the wedge detector is restored at once.
test_open_decision_closure_resumes_normal_cadence() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case decision-closure); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-answered"
  printf 'idle, mute after the answer\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/answered.meta"
  # An open decision that the captain then resolves - the fold is now closed.
  printf 'needs-decision [key=api-shape]: pick A or B\nresolved [key=api-shape]: captain chose A\n' > "$state/answered.status"
  sig=$(seen_sig "$state/answered.status"); printf '%s' "$sig" > "$state/.seen-answered_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle, mute after the answer")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Pretend a prior decision-held absorb so the closure branch is the path under
  # test: the marker names THIS pane hash, so the later-poll triage routes to it,
  # but records a status signature that no longer matches (a resolved line has
  # since landed), which is exactly what forces the bounded re-validating fold.
  # The fold now reports closed, so the watcher must clear the tracking and
  # re-evaluate from a clean first-sight.
  printf '%s\t0:0' "$pane_hash" > "$state/.decision-held-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  # Crew is NOT provably working (it got its answer and went idle), so the
  # normal non-terminal triage surfaces immediately - the real-wedge re-escalate.
  export FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not re-escalate a mute crew after the decision closed"
  grep -F "stale: $window" "$out" >/dev/null || fail "closure did not re-surface the mute crew"
  grep -F "awaiting captain" "$out" >/dev/null \
    && fail "closure re-surfaced as a decision-held recheck instead of a normal stale"
  grep -F "possible wedge" "$out" >/dev/null && fail "an immediate not-provably-working re-surface was mislabeled a wedge"
  [ ! -e "$state/.decision-held-$key" ] || fail "closure did not clear the decision-held marker"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after closure re-escalate failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "closure re-escalate was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a closed decision resumes the normal cadence and a mute crew re-escalates immediately"
}

# --- no open decision: a needs-decision that was resolved wedge-escalates ---
# exactly like today (no regression on wedge detection). A crew whose decision
# has closed carries no open decision, so the decision-held absorb never applies
# and the existing provably-working wedge path is unchanged.
test_closed_decision_stale_wedge_escalates_like_today() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case closed-decision-wedge); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-resolved"
  printf 'idle building again\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/resolved.meta"
  # The needs-decision was resolved, so the fold is closed: no open decision.
  printf 'needs-decision [key=api-shape]: pick A or B\nresolved [key=api-shape]: captain chose A\nworking: resuming\n' > "$state/resolved.status"
  sig=$(seen_sig "$state/resolved.status"); printf '%s' "$sig" > "$state/.seen-resolved_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building again")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Phase A: high wedge threshold -> a non-terminal provably-working stale is
  # absorbed exactly as today (the decision is closed, so no decision-held path).
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_live "$pid" 30; then
    reap "$pid"; fail "watcher exited for a closed-decision provably-working stale (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "closed-decision stale printed a wake during absorb"
  [ ! -e "$state/.decision-held-$key" ] || fail "a closed decision was misrouted to the decision-held absorb"
  [ -s "$state/.stale-since-$key" ] || fail "the normal wedge timer was not started for a closed-decision stale"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the closed-decision phase-A stop"

  # Phase B: backdate the idle timer past the threshold; the run wedges and the
  # next poll escalates exactly like the non-terminal case - no decision-held
  # suppression.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 40 || fail "watcher did not escalate a closed-decision stale past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  grep -F "awaiting captain" "$out" >/dev/null && fail "a closed-decision wedge was mislabeled a decision-held recheck"
  unset FM_FAKE_CREW_STATE
  pass "a closed decision does not suppress the wedge: it escalates exactly like today"
}

test_signal_reason_is_actionable_classifier
test_stale_is_terminal_classifier
test_scan_captain_relevant_statuses_classifier
test_classifier_primitives
test_crew_is_provably_working_classifier
test_status_is_paused_classifier
test_crew_absorb_class_classifier
test_signal_crew_provably_working_classifier
test_secondmate_status_signal_never_absorbed_classifier
test_provably_working_signal_absorbed
test_turn_ended_provably_working_absorbed
test_turn_ended_not_working_surfaced
test_working_note_not_working_surfaced
test_secondmate_status_note_surfaced_despite_busy_agent
test_self_announced_close_does_not_rewake_but_next_note_does
test_actionable_signal_surfaced
test_terminal_stale_surfaced
test_stale_terminal_status_overridden_by_active_run
test_nonterminal_stale_provably_working_absorbed_then_escalated
test_wedge_escalation_marks_demand_deep_inspection_after_threshold
test_wedge_escalation_resets_when_pane_becomes_active
test_busy_pane_below_turn_age_bound_is_absorbed
test_busy_pane_stable_hash_escalates_past_turn_age_bound
test_busy_pane_changing_hash_escalates_past_turn_age_bound
test_busy_pane_turn_end_touch_resets_age
test_busy_pane_repeated_escalation_reaches_demand_deep_inspection
test_busy_pane_default_turn_age_bound_is_3600s
test_nonterminal_stale_not_working_surfaced
test_nonterminal_stale_paused_absorbed_then_resurfaced
test_exited_declared_pause_is_bounded_but_live_gate_surfaces
test_open_decision_stale_absorbed_on_long_cadence_not_wedged
test_open_decision_not_working_surfaces_immediately
test_decision_held_marker_does_not_outlive_its_absorb
test_decision_held_absorb_survives_a_busy_blip_at_the_same_hash
test_open_decision_closure_resumes_normal_cadence
test_closed_decision_stale_wedge_escalates_like_today
test_secondmate_paused_resurfaces_in_normal_mode
test_secondmate_nonpaused_stale_remains_suppressed
test_secondmate_unpause_clears_pause_tracking
test_nonterminal_stale_pause_transitions_reclassify_unchanged_hash
test_nonterminal_paused_rechecks_authoritative_state
test_paused_authoritative_working_preserves_wedge_timer
test_nonterminal_stale_repairs_missing_or_corrupt_timer
test_triage_log_size_cap_accepts_spaced_wc_counts
test_procevent_captured_result_surfaces_proactively
test_procevent_unacknowledged_result_redrains_until_handled
test_procevent_marker_keys_are_injective
test_procevent_surface_serializes_with_drain
test_procevent_surface_crash_boundaries
test_procevent_marker_failure_exits_and_replays
test_heartbeat_no_change_absorbed
test_heartbeat_backstop_surfaces_unsurfaced_status
test_beacon_stays_fresh_while_absorbing
test_afk_present_reverts_watcher_to_one_shot
test_afk_paused_changed_pane_hands_off_plain_stale
