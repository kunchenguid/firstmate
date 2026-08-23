#!/usr/bin/env bash
# tests/fm-auto-quota-drain.test.sh - automatic quota threshold transitions and one graceful secondmate-seat drain.
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"
# shellcheck source=tests/treehouse-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/treehouse-helpers.sh"

DRAIN="$ROOT/bin/fm-auto-quota-drain.sh"
NODE_BIN=$(command -v node) || fail "test needs node"
JQ_BIN=$(command -v jq) || fail "test needs jq"
NODE_BIN_DIR=$(dirname "$NODE_BIN")
JQ_BIN_DIR=$(dirname "$JQ_BIN")
BASE_PATH=${FM_TEST_BASE_PATH:-$NODE_BIN_DIR:$JQ_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-auto-quota-drain)
fm_git_identity fmtest fmtest@example.com

make_world() {
  local name=$1 root home seat fakebin
  root="$TMP_ROOT/$name"
  home="$root/main"
  seat="$root/seat-home"
  fakebin="$root/fakebin"
  mkdir -p "$home/config" "$home/data" "$home/state" "$seat/data" "$seat/state" "$seat/config" "$fakebin"
  printf '%s\n' '# Backlog' '## Queued' '- [ ] routed-work - Preserve me.' > "$home/data/backlog.md"
  printf '%s\n' '# Routed backlog' '- [ ] child-work - Preserve this too.' > "$seat/data/backlog.md"
  printf '%s\n' 'cursor-agent cursor-grok-4.6-xhigh xhigh' > "$home/config/secondmate-harness"
  printf '%s\n' '{"schemaVersion":1,"tuples":[{"harness":"cursor-agent","model":"cursor-grok-4.6-xhigh","provider":"cursor","modelFamily":"cursor-grok-4.6"},{"harness":"claude","model":"opus","provider":"claude","modelFamily":"claude-opus"}]}' > "$home/config/model-catalog.json"
  printf '%s\n' \
    'window=firstmate:fm-seat-a' \
    'endpoint_task_id=seat-a' \
    "worktree=$seat" \
    "project=$seat" \
    'harness=claude' \
    'model=opus' \
    'effort=high' \
    'kind=secondmate' \
    "home=$seat" > "$home/state/seat-a.meta"
  cat > "$home/config/auto-quota-drain.json" <<'JSON'
{
  "schemaVersion": 1,
  "warningPercentRemaining": 7,
  "actionPercentRemaining": 5,
  "maxSnapshotAgeSeconds": 300,
  "positions": [
    {
      "position": "primary-seat",
      "seat": "seat-a",
      "provider": "claude",
      "postDrainProvider": "cursor",
      "postDrainModelFamily": "cursor-grok-4.6",
      "requiredReasoningClass": "frontier",
      "postDrainReasoningClass": "frontier"
    }
  ]
}
JSON
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${1:-}" = --json ] || exit 64
printf 'quota-call\n' >> "$FM_FAKE_QUOTA_CALLS"
cat "$FM_FAKE_QUOTA_SNAPSHOT"
SH
  chmod +x "$fakebin/quota-axi"
  cat > "$fakebin/lifecycle" <<'SH'
#!/usr/bin/env bash
set -eu
cmd=$1
shift
printf '%s' "$cmd" >> "$FM_FAKE_LIFECYCLE_TRACE"
for arg in "$@"; do printf '\t%s' "$arg" >> "$FM_FAKE_LIFECYCLE_TRACE"; done
printf '\n' >> "$FM_FAKE_LIFECYCLE_TRACE"
case "$cmd:${FM_FAKE_LIFECYCLE_FAIL:-}" in
  checkpoint:checkpoint) printf '%s\n' 'checkpoint seal missing' >&2; exit 23 ;;
  park:unlanded) printf '%s\n' 'REFUSED: unlanded work remains' >&2; exit 24 ;;
  relaunch:relaunch) printf '%s\n' 'temporary relaunch failure' >&2; exit 25 ;;
esac
if [ "$cmd" = relaunch ]; then printf 'launched\n'; fi
SH
  chmod +x "$fakebin/lifecycle"
  printf '%s\n' "$home|$seat|$fakebin"
}

write_snapshot() {
  local file=$1 claude=$2 cursor=$3 generated=${4:-2030-01-01T00:00:00Z} claude_state=${5:-fresh}
  cat > "$file" <<JSON
{"schemaVersion":3,"generatedAt":"$generated","providers":[{"provider":"claude","state":{"status":"$claude_state","stale":$([ "$claude_state" = fresh ] && printf false || printf true)},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":$claude,"boundedBy":["weekly"],"limitingWindowIds":["weekly"],"runway":{"status":"through_reset","usableRunwaySeconds":7200,"limitingWindowId":"weekly"}}]}},{"provider":"cursor","state":{"status":"fresh","stale":false},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":$cursor,"boundedBy":["monthly"],"limitingWindowIds":["monthly"],"runway":{"status":"through_reset","usableRunwaySeconds":7200,"limitingWindowId":"monthly"}}]}}]}
JSON
}

world_fields() {
  local rest
  TEST_HOME=${1%%|*}
  rest=${1#*|}
  TEST_SEAT=${rest%%|*}
  TEST_FAKEBIN=${rest#*|}
  TEST_SNAPSHOT="$TEST_HOME/snapshot.json"
  TEST_TRACE="$TEST_HOME/lifecycle.trace"
  TEST_CALLS="$TEST_HOME/quota.calls"
}

run_drain() {
  local home=$1 fakebin=$2 snapshot=$3 trace=$4 calls=$5
  shift 5
  PATH="$fakebin:$BASE_PATH" \
    FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_AUTO_QUOTA_NOW=2030-01-01T00:01:00Z \
    FM_AUTO_QUOTA_LIFECYCLE_ADAPTER="$fakebin/lifecycle" \
    FM_FAKE_QUOTA_SNAPSHOT="$snapshot" \
    FM_FAKE_QUOTA_CALLS="$calls" \
    FM_FAKE_LIFECYCLE_TRACE="$trace" \
    "$@" \
    "$DRAIN"
}

assert_one_quota_call() {
  local calls=$1
  [ "$(wc -l < "$calls" | tr -d ' ')" -eq 1 ] || fail "ordinary cycle did not consume exactly one quota snapshot"
}

run_adapter_action_cycle() {
  run_drain "$TEST_HOME" "$TEST_FAKEBIN" "$TEST_SNAPSHOT" "$TEST_TRACE" "$TEST_CALLS" "$@"
}

set_seat_meta() {
  local home=$1 seat=$2 harness=$3 model=$4 effort=$5 window=$6 seat_home=$7
  printf '%s\n' \
    "window=$window" \
    "endpoint_task_id=$seat" \
    "worktree=$seat_home" \
    "project=$seat_home" \
    "harness=$harness" \
    "model=$model" \
    "effort=$effort" \
    'kind=secondmate' \
    "home=$seat_home" > "$home/state/$seat.meta"
}

seed_action_journal() {
  local home=$1 seat_home=$2 phase=$3 candidate candidate_b64 journal
  candidate=$(jq -cn '{harness:"cursor-agent",provider:"cursor",modelFamily:"cursor-grok-4.6",model:"cursor-grok-4.6-xhigh",effort:"xhigh",reasoningClass:"frontier",headroom:"sufficient",runway:"sufficient"}')
  candidate_b64=$(printf '%s' "$candidate" | base64 | tr -d '\n')
  mkdir -p "$home/state/auto-quota-drain"
  journal="$home/state/auto-quota-drain/action-primary-seat"
  printf '%s\n' \
    'schema=fm-auto-quota-action.v4' \
    "phase=$phase" \
    'position=primary-seat' \
    'seat=seat-a' \
    "home=$seat_home" \
    'required_reasoning_class=frontier' \
    'trigger_provider=claude' \
    'percent=5' \
    "candidate_b64=$candidate_b64" \
    'old_backend=tmux' \
    'old_target=firstmate:fm-seat-a' \
    'old_harness=claude' \
    'old_model=opus' \
    'old_effort=high' \
    'corr_id=0123456789abcdef' > "$journal"
}

assert_no_quota_calls() {
  local calls=$1
  [ ! -e "$calls" ] || [ ! -s "$calls" ] || fail "journal recovery consulted current quota before resuming"
}

test_healthy_is_silent() {
  world_fields "$(make_world healthy)"
  write_snapshot "$TEST_SNAPSHOT" 80 90
  out=$(run_adapter_action_cycle) || fail "healthy quota check failed: $out"
  [ -z "$out" ] || fail "healthy quota check was not silent: $out"
  assert_one_quota_call "$TEST_CALLS"
  [ ! -e "$TEST_TRACE" ] || fail "healthy quota invoked a lifecycle adapter"
  pass "auto quota drain: healthy effective pools are silent and use one snapshot"
}

test_watcher_surfaces_the_bounded_warning() {
  local out
  world_fields "$(make_world watcher-warning)"
  write_snapshot "$TEST_SNAPSHOT" 8 90
  run_adapter_action_cycle >/dev/null || fail "watcher warning baseline failed"
  : > "$TEST_CALLS"
  write_snapshot "$TEST_SNAPSHOT" 7 90
  out=$(PATH="$TEST_FAKEBIN:$BASE_PATH" FM_HOME="$TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    FM_AUTO_QUOTA_NOW=2030-01-01T00:01:00Z FM_AUTO_QUOTA_LIFECYCLE_ADAPTER="$TEST_FAKEBIN/lifecycle" \
    FM_FAKE_QUOTA_SNAPSHOT="$TEST_SNAPSHOT" FM_FAKE_QUOTA_CALLS="$TEST_CALLS" FM_FAKE_LIFECYCLE_TRACE="$TEST_TRACE" \
    bash -c '. "$1/bin/fm-watch.sh"; fm_wake_append() { printf "queued:%s:%s:%s\\n" "$1" "$2" "$3"; }; wake() { printf "wake:%s\\n" "$1"; }; auto_quota_drain_surface' _ "$ROOT") \
    || fail "watcher did not surface the bounded quota warning: $out"
  assert_contains "$out" "queued:check:auto-quota-drain:check: auto-quota-drain: warning: quota pool claude crossed to 7% remaining (warning threshold 7%)" "watcher did not queue the quota warning through its existing event path"
  assert_contains "$out" "wake:check: auto-quota-drain: warning: quota pool claude crossed to 7% remaining (warning threshold 7%)" "watcher did not wake on the queued quota warning"
  assert_one_quota_call "$TEST_CALLS"
  pass "auto quota drain: an ordinary watcher cycle publishes one bounded threshold warning"
}

test_warning_transition_and_dedupe() {
  world_fields "$(make_world warning)"
  node -e 'const fs=require("fs");const p=process.argv[1];const j=JSON.parse(fs.readFileSync(p));delete j.warningPercentRemaining;delete j.actionPercentRemaining;fs.writeFileSync(p,JSON.stringify(j));' "$TEST_HOME/config/auto-quota-drain.json"
  write_snapshot "$TEST_SNAPSHOT" 8 90
  run_adapter_action_cycle >/dev/null || fail "warning baseline failed"
  : > "$TEST_CALLS"
  write_snapshot "$TEST_SNAPSHOT" 7 90
  out=$(run_adapter_action_cycle) || fail "seven-percent crossing failed: $out"
  assert_contains "$out" "warning: quota pool claude crossed to 7% remaining (warning threshold 7%)" "warning crossing event was not exact"
  : > "$TEST_CALLS"
  write_snapshot "$TEST_SNAPSHOT" 6 90
  out=$(run_adapter_action_cycle) || fail "warning episode dedupe failed: $out"
  [ -z "$out" ] || fail "warning repeated inside one threshold episode: $out"
  [ ! -e "$TEST_TRACE" ] || fail "warning-only episode invoked lifecycle"
  pass "auto quota drain: seven-percent crossing warns once and dedupes its episode"
}

test_config_has_no_second_launch_ladder() {
  local out
  world_fields "$(make_world no-second-ladder)"
  cat > "$TEST_HOME/config/auto-quota-drain.json" <<'JSON'
{"schemaVersion":1,"positions":[{"position":"primary-seat","seat":"seat-a","provider":"claude","requiredReasoningClass":"frontier","fallbackLadder":[{"harness":"cursor-agent","provider":"cursor","modelFamily":"cursor-grok-4.6","model":"cursor-grok-4.6-xhigh","effort":"xhigh","reasoningClass":"frontier","accepted":true}]}]}
JSON
  write_snapshot "$TEST_SNAPSHOT" 6 90
  out=$(run_adapter_action_cycle) || fail "duplicate ladder refusal should remain nonblocking: $out"
  assert_contains "$out" "diagnostic: auto-quota-drain configuration is malformed; no lifecycle action taken" "auto quota config still accepted a second harness/model ladder"
  [ ! -e "$TEST_TRACE" ] || fail "malformed duplicate ladder reached lifecycle code"
  pass "auto quota drain: launch tuple belongs only to durable secondmate-harness config"
}

test_durable_tuple_must_match_catalog_post_drain_facts() {
  local out before_meta before_parent before_child
  world_fields "$(make_world tuple-catalog-mismatch)"
  printf '%s\n' 'claude opus high' > "$TEST_HOME/config/secondmate-harness"
  write_snapshot "$TEST_SNAPSHOT" 6 90
  run_adapter_action_cycle >/dev/null || fail "tuple mismatch baseline failed"
  write_snapshot "$TEST_SNAPSHOT" 5 90
  before_meta=$(sha256sum "$TEST_HOME/state/seat-a.meta" | awk '{print $1}')
  before_parent=$(sha256sum "$TEST_HOME/data/backlog.md" | awk '{print $1}')
  before_child=$(sha256sum "$TEST_SEAT/data/backlog.md" | awk '{print $1}')
  out=$(run_adapter_action_cycle 2>&1) || fail "tuple mismatch refusal should remain nonblocking: $out"
  assert_contains "$out" "durable secondmate tuple catalog facts do not match the configured post-drain provider/model family" "Claude tuple with Cursor facts was not refused at the catalog boundary"
  [ ! -e "$TEST_HOME/state/auto-quota-drain/action-primary-seat" ] || fail "tuple mismatch published an action journal"
  [ ! -e "$TEST_TRACE" ] || fail "tuple mismatch sent a checkpoint or reached another lifecycle action"
  [ "$before_meta" = "$(sha256sum "$TEST_HOME/state/seat-a.meta" | awk '{print $1}')" ] || fail "tuple mismatch mutated seat metadata"
  [ "$before_parent" = "$(sha256sum "$TEST_HOME/data/backlog.md" | awk '{print $1}')" ] || fail "tuple mismatch mutated the parent backlog"
  [ "$before_child" = "$(sha256sum "$TEST_SEAT/data/backlog.md" | awk '{print $1}')" ] || fail "tuple mismatch mutated the seat backlog"
  pass "auto quota drain: Claude launch tuple cannot act on Cursor quota/catalog facts"
}

test_nonterminal_journals_resume_before_current_inputs() {
  local phase mode name out journal expected before_meta before_parent before_child
  for phase in parking parked; do
    for mode in reset absent malformed; do
      name="resume-$phase-$mode"
      world_fields "$(make_world "$name")"
      write_snapshot "$TEST_SNAPSHOT" 90 90
      seed_action_journal "$TEST_HOME" "$TEST_SEAT" "$phase"
      journal="$TEST_HOME/state/auto-quota-drain/action-primary-seat"
      case "$mode" in
        reset) : ;;
        absent) rm -f "$TEST_HOME/config/auto-quota-drain.json" ;;
        malformed) printf '%s\n' '{malformed' > "$TEST_HOME/config/auto-quota-drain.json" ;;
      esac
      before_meta=$(sha256sum "$TEST_HOME/state/seat-a.meta" | awk '{print $1}')
      before_parent=$(sha256sum "$TEST_HOME/data/backlog.md" | awk '{print $1}')
      before_child=$(sha256sum "$TEST_SEAT/data/backlog.md" | awk '{print $1}')
      : > "$TEST_TRACE"
      out=$(run_adapter_action_cycle 2>&1) || fail "$phase journal did not resume with $mode current input: $out"
      assert_no_quota_calls "$TEST_CALLS"
      case "$phase" in
        parking)
          expected=park-status
          assert_grep 'phase=parked' "$journal" "$mode current input abandoned the parking journal"
          [ -z "$out" ] || fail "$phase/$mode recovery should remain silent: $out"
          ;;
        parked)
          expected=relaunch
          assert_grep 'phase=complete' "$journal" "$mode current input abandoned the parked journal"
          assert_contains "$out" "action: quota pool claude crossed to 5% remaining" "$phase/$mode recovery did not complete"
          ;;
      esac
      [ "$(cut -f1 "$TEST_TRACE" | paste -sd, -)" = "$expected" ] || fail "$phase/$mode recovery ran the wrong lifecycle mutation: $(cat "$TEST_TRACE")"
      [ "$before_meta" = "$(sha256sum "$TEST_HOME/state/seat-a.meta" | awk '{print $1}')" ] || fail "$phase/$mode recovery mutated seat metadata through the adapter seam"
      [ "$before_parent" = "$(sha256sum "$TEST_HOME/data/backlog.md" | awk '{print $1}')" ] || fail "$phase/$mode recovery mutated the parent backlog"
      [ "$before_child" = "$(sha256sum "$TEST_SEAT/data/backlog.md" | awk '{print $1}')" ] || fail "$phase/$mode recovery mutated the seat backlog"
    done
  done
  pass "auto quota drain: parking and parked journals resume before reset, absent, or malformed current inputs"
}

test_journal_identity_drift_refuses_every_mutating_phase() {
  local phase drift name out journal before_journal before_parent before_child other_home
  for phase in planned checkpoint_pending checkpointed parking parked; do
    for drift in seat home; do
      name="identity-$phase-$drift"
      world_fields "$(make_world "$name")"
      write_snapshot "$TEST_SNAPSHOT" 5 90
      seed_action_journal "$TEST_HOME" "$TEST_SEAT" "$phase"
      journal="$TEST_HOME/state/auto-quota-drain/action-primary-seat"
      case "$drift" in
        seat)
          node -e 'const fs=require("fs"),p=process.argv[1],j=JSON.parse(fs.readFileSync(p));j.positions[0].seat="seat-b";fs.writeFileSync(p,JSON.stringify(j));' "$TEST_HOME/config/auto-quota-drain.json"
          ;;
        home)
          other_home="$TEST_HOME/other-seat-home"
          mkdir -p "$other_home"
          set_seat_meta "$TEST_HOME" seat-a claude opus high firstmate:fm-seat-a "$other_home"
          ;;
      esac
      before_journal=$(sha256sum "$journal" | awk '{print $1}')
      before_parent=$(sha256sum "$TEST_HOME/data/backlog.md" | awk '{print $1}')
      before_child=$(sha256sum "$TEST_SEAT/data/backlog.md" | awk '{print $1}')
      : > "$TEST_TRACE"
      out=$(run_adapter_action_cycle 2>&1) || fail "$phase/$drift drift refusal should remain nonblocking: $out"
      assert_contains "$out" "diagnostic: auto-quota-drain seat seat-a journal-bound" "$phase/$drift drift did not identify the bound journal identity"
      [ ! -s "$TEST_TRACE" ] || fail "$phase/$drift drift reached lifecycle mutation: $(cat "$TEST_TRACE")"
      assert_no_quota_calls "$TEST_CALLS"
      [ "$before_journal" = "$(sha256sum "$journal" | awk '{print $1}')" ] || fail "$phase/$drift drift rewrote or abandoned the journal"
      [ "$before_parent" = "$(sha256sum "$TEST_HOME/data/backlog.md" | awk '{print $1}')" ] || fail "$phase/$drift drift mutated the parent backlog"
      [ "$before_child" = "$(sha256sum "$TEST_SEAT/data/backlog.md" | awk '{print $1}')" ] || fail "$phase/$drift drift mutated the originally bound seat backlog"
    done
  done
  pass "auto quota drain: seat and home drift refuse every mutating nonterminal phase without retargeting"
}

test_adapter_progresses_one_phase_per_cycle() {
  local out phases before_parent after_parent before_child after_child
  world_fields "$(make_world adapter-action)"
  write_snapshot "$TEST_SNAPSHOT" 6 90
  run_adapter_action_cycle >/dev/null || fail "adapter action baseline failed"
  write_snapshot "$TEST_SNAPSHOT" 5 90
  before_parent=$(sha256sum "$TEST_HOME/data/backlog.md" | awk '{print $1}')
  before_child=$(sha256sum "$TEST_SEAT/data/backlog.md" | awk '{print $1}')

  : > "$TEST_CALLS"
  out=$(run_adapter_action_cycle) || fail "checkpoint cycle failed: $out"
  [ -z "$out" ] || fail "checkpoint-pending cycle should remain silent: $out"
  phases=$(cut -f1 "$TEST_TRACE" | paste -sd, -)
  [ "$phases" = checkpoint ] || fail "first action cycle did not stop after checkpoint: $phases"

  out=$(run_adapter_action_cycle) || fail "park cycle failed: $out"
  [ -z "$out" ] || fail "parking cycle should remain silent: $out"
  phases=$(cut -f1 "$TEST_TRACE" | paste -sd, -)
  [ "$phases" = checkpoint,park ] || fail "second action cycle did not stop after park: $phases"

  out=$(run_adapter_action_cycle) || fail "relaunch cycle failed: $out"
  assert_contains "$out" "action: quota pool claude crossed to 5% remaining; secondmate seat-a checkpointed, parked, and relaunched from durable config on cursor-agent/cursor-grok-4.6-xhigh (xhigh)" "completed action event changed"
  phases=$(cut -f1 "$TEST_TRACE" | paste -sd, -)
  [ "$phases" = checkpoint,park,relaunch ] || fail "lifecycle phase order changed: $phases"

  after_parent=$(sha256sum "$TEST_HOME/data/backlog.md" | awk '{print $1}')
  after_child=$(sha256sum "$TEST_SEAT/data/backlog.md" | awk '{print $1}')
  [ "$before_parent" = "$after_parent" ] || fail "main routed backlog changed during seat drain"
  [ "$before_child" = "$after_child" ] || fail "secondmate routed backlog changed during seat drain"
  pass "auto quota drain: adapter unit advances checkpoint, park, and relaunch on separate cycles"
}

test_reasoning_floor_and_target_pool_are_bounded() {
  local out
  world_fields "$(make_world reasoning-floor)"
  node -e 'const fs=require("fs");const p=process.argv[1];const j=JSON.parse(fs.readFileSync(p));j.positions[0].postDrainReasoningClass="standard";fs.writeFileSync(p,JSON.stringify(j));' "$TEST_HOME/config/auto-quota-drain.json"
  write_snapshot "$TEST_SNAPSHOT" 6 90
  out=$(run_adapter_action_cycle) || fail "reasoning-floor diagnostic failed: $out"
  assert_contains "$out" "diagnostic: auto-quota-drain configuration would downgrade the required reasoning class; no lifecycle action taken" "reasoning-class downgrade was not refused"

  world_fields "$(make_world target-tight)"
  write_snapshot "$TEST_SNAPSHOT" 6 5
  run_adapter_action_cycle >/dev/null || fail "target-pool baseline failed"
  write_snapshot "$TEST_SNAPSHOT" 5 5
  out=$(run_adapter_action_cycle) || fail "target-pool refusal failed: $out"
  assert_contains "$out" "diagnostic: auto-quota-drain seat seat-a post-drain pool is not above the action threshold; no lifecycle action taken" "drained target pool was selected"
  [ ! -e "$TEST_TRACE" ] || fail "unavailable target pool reached lifecycle code"
  pass "auto quota drain: target pool and reasoning-class floor remain bounded"
}

make_production_tmux() {
  local root=$1 fakebin
  fakebin="$root/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_TMUX_LOG:?}
state=${FM_FAKE_TMUX_STATE:?}
pane=${FM_FAKE_TMUX_CAPTURE:?}
cmd=$(cat "$state" 2>/dev/null || printf missing)
case "${1:-}" in
  has-session|new-session)
    printf '%s\n' "$*" >> "$log"
    exit 0
    ;;
  new-window)
    printf '%s\n' "$*" >> "$log"
    printf 'bash\n' > "$state"
    exit 0
    ;;
  kill-window)
    printf '%s\n' "$*" >> "$log"
    printf 'missing\n' > "$state"
    exit 0
    ;;
  list-windows)
    [ "$cmd" = missing ] || printf 'fm-seat-a\n'
    exit 0
    ;;
  display-message)
    case "$*" in
      *pane_current_command*) [ "$cmd" = missing ] && exit 1; printf '%s\n' "$cmd" ;;
      *pane_tty*) printf '\n' ;;
      *cursor_y*) printf '0\n' ;;
      *session_name*) printf 'firstmate\n' ;;
      *pane_current_path*) printf '%s\n' "${FM_FAKE_SEAT_HOME:?}" ;;
      *) printf 'firstmate\n' ;;
    esac
    exit 0
    ;;
  capture-pane)
    cat "$pane"
    exit 0
    ;;
  send-keys)
    printf '%s\n' "$*" >> "$log"
    [ "${FM_FAKE_TMUX_SEND_FAIL:-}" != 1 ] || exit 1
    case "$*" in
      *'/exit'*|*' C-d') printf 'bash\n' > "$state" ;;
      *cursor-agent*) printf 'cursor-agent\n' > "$state" ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

make_production_toolchain() {
  local root=$1 fakebin
  fakebin=$(make_production_tmux "$root")
  printf '#!/usr/bin/env bash\nexec '"'"'%s'"'"' "$@"\n' "$NODE_BIN" > "$fakebin/node"
  printf '#!/usr/bin/env bash\nexec '"'"'%s'"'"' "$@"\n' "$JQ_BIN" > "$fakebin/jq"
  chmod +x "$fakebin/node" "$fakebin/jq"
  fm_fake_exit0 "$fakebin" chrome-devtools-axi pi-signed cursor-agent
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.45
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || printf '%s\n' '0.1.29'
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  fm_test_write_active_treehouse_fake "$fakebin"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
exit 0
SH
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  '--version ') printf '%s\n' '0.2.4' ;;
  'update --help') printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  'mv --help') printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf '%s\n' '0.1.17'; exit 0; fi
[ "${1:-}" = --json ] || exit 64
printf 'quota-call\n' >> "$FM_FAKE_QUOTA_CALLS"
cat "$FM_FAKE_QUOTA_SNAPSHOT"
SH
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
dest=${!#}
case "${FM_FAKE_PENDING_COMMIT_FAIL:-}:$dest" in
  1:*/pending-replies/[a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9])
    corr=${dest##*/}
    marker=${dest%/*}/.delivery-confirmed-$corr
    if [ "$(cat "$marker" 2>/dev/null || true)" != "" ] && grep -q '^confirmed=' "$marker" 2>/dev/null; then
      exit 1
    fi
    ;;
esac
exec /bin/mv "$@"
SH
  chmod +x "$fakebin"/*
  printf '%s\n' "$fakebin"
}

test_uncertain_checkpoint_delivery_recovers_without_abandoning_action() {
  local root="$TMP_ROOT/uncertain-checkpoint" fields home seat fakebin snapshot calls journal corr out
  fields=$(make_production_world "$root")
  home=${fields%%|*}; fields=${fields#*|}; seat=${fields%%|*}; fakebin=${fields#*|}
  snapshot="$home/snapshot.json"; calls="$home/quota.calls"
  write_snapshot "$snapshot" 6 90
  run_production_drain "$home" "$seat" "$fakebin" "$snapshot" "$calls" "$root" >/dev/null \
    || fail "uncertain checkpoint baseline failed"
  write_snapshot "$snapshot" 5 90

  out=$(FM_FAKE_PENDING_COMMIT_FAIL=1 run_production_drain "$home" "$seat" "$fakebin" "$snapshot" "$calls" "$root" 2>&1) \
    || fail "uncertain checkpoint cycle abandoned the action: $out"
  journal="$home/state/auto-quota-drain/action-primary-seat"
  assert_grep 'phase=checkpoint_pending' "$journal" "uncertain checkpoint delivery was permanently refused"
  assert_no_grep 'phase=refused' "$journal" "uncertain checkpoint delivery abandoned its journal"
  corr=$(grep '^corr_id=' "$journal" | cut -d= -f2-)
  [ -f "$home/state/pending-replies/.delivery-confirmed-$corr" ] \
    || fail "uncertain checkpoint lost its durable recovery marker"

  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    FM_FAKE_TMUX_LOG="$root/tmux.log" FM_FAKE_TMUX_STATE="$root/tmux.state" \
    FM_FAKE_TMUX_CAPTURE="$root/pane.txt" FM_FAKE_SEAT_HOME="$seat" \
    bash -c '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_tick "$2/state"' _ "$ROOT" "$home" \
    || fail "pending-reply owner did not reconcile uncertain checkpoint delivery"
  printf 'done: auto quota drain checkpoint sealed corr=%s\n' "$corr" >> "$home/state/seat-a.status"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    FM_FAKE_TMUX_LOG="$root/tmux.log" FM_FAKE_TMUX_STATE="$root/tmux.state" \
    FM_FAKE_TMUX_CAPTURE="$root/pane.txt" FM_FAKE_SEAT_HOME="$seat" \
    bash -c '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_tick "$2/state"' _ "$ROOT" "$home" \
    || fail "pending-reply owner did not resolve recovered checkpoint"
  run_production_drain "$home" "$seat" "$fakebin" "$snapshot" "$calls" "$root" >/dev/null \
    || fail "recovered checkpoint did not resume"
  assert_grep 'phase=checkpointed' "$journal" "recovered checkpoint did not advance the action journal"
  pass "auto quota drain: uncertain checkpoint delivery remains recoverable"
}

test_definitive_checkpoint_failure_refuses_without_later_mutation() {
  local root="$TMP_ROOT/failed-checkpoint" fields home seat fakebin snapshot calls journal out before_journal before_log before_state
  fields=$(make_production_world "$root")
  home=${fields%%|*}; fields=${fields#*|}; seat=${fields%%|*}; fakebin=${fields#*|}
  snapshot="$home/snapshot.json"; calls="$home/quota.calls"
  write_snapshot "$snapshot" 6 90
  run_production_drain "$home" "$seat" "$fakebin" "$snapshot" "$calls" "$root" >/dev/null \
    || fail "failed checkpoint baseline failed"
  write_snapshot "$snapshot" 5 90

  out=$(FM_FAKE_TMUX_SEND_FAIL=1 run_production_drain "$home" "$seat" "$fakebin" "$snapshot" "$calls" "$root" 2>&1) \
    || fail "definitive checkpoint refusal must remain nonblocking: $out"
  journal="$home/state/auto-quota-drain/action-primary-seat"
  assert_grep 'phase=refused' "$journal" "definitive checkpoint failure did not refuse the action"
  assert_no_grep 'phase=checkpoint_pending' "$journal" "definitive checkpoint failure entered a pending wait"
  [ -z "$(find "$home/state/pending-replies" -maxdepth 1 -type f -print -quit 2>/dev/null)" ] \
    || fail "definitive checkpoint failure retained an undelivered expectation"
  before_journal=$(sha256sum "$journal" | awk '{print $1}')
  before_log=$(sha256sum "$root/tmux.log" | awk '{print $1}')
  before_state=$(cat "$root/tmux.state")

  out=$(run_production_drain "$home" "$seat" "$fakebin" "$snapshot" "$calls" "$root" 2>&1) \
    || fail "refused checkpoint follow-up failed: $out"
  [ -z "$out" ] || fail "refused checkpoint follow-up emitted a lifecycle event: $out"
  [ "$before_journal" = "$(sha256sum "$journal" | awk '{print $1}')" ] \
    || fail "refused checkpoint follow-up rewrote the action journal"
  [ "$before_log" = "$(sha256sum "$root/tmux.log" | awk '{print $1}')" ] \
    || fail "refused checkpoint follow-up invoked the endpoint lifecycle"
  [ "$before_state" = "$(cat "$root/tmux.state")" ] \
    || fail "refused checkpoint follow-up mutated the endpoint"
  pass "auto quota drain: definitive checkpoint failure refuses without later mutation"
}

make_production_world() {
  local root=$1 home seat fakebin clean_revision
  home="$root/main"
  seat="$root/seat-home"
  mkdir -p "$home/config" "$home/data" "$home/state"
  git clone -q --no-hardlinks "$ROOT" "$seat" || fail "could not clone production secondmate fixture"
  if git -C "$ROOT" show-ref --verify --quiet refs/heads/main; then
    clean_revision=$(git -C "$ROOT" rev-parse refs/heads/main)
  else
    clean_revision=$(git -C "$ROOT" rev-parse HEAD)
  fi
  git -C "$seat" checkout -q "$clean_revision" \
    || fail "could not place production secondmate fixture on a clean revision"
  mkdir -p "$seat/config" "$seat/data" "$seat/state" "$seat/projects"
  printf '%s\n' 'seat-a' > "$seat/.fm-secondmate-home"
  printf '%s\n' 'schema=fm-secondmate-parent.v1' 'route=local' "parent_home=$home" > "$seat/.fm-secondmate-parent"
  printf '%s\n' '# Charter' 'Stay idle.' > "$seat/data/charter.md"
  printf '%s\n' "- seat-a - quota seat (home: $seat; scope: quota work; projects: ; added 2030-01-01)" > "$home/data/secondmates.md"
  printf '%s\n' 'cursor-agent cursor-grok-4.6-xhigh xhigh' > "$home/config/secondmate-harness"
  printf '%s\n' '{"schemaVersion":1,"tuples":[{"harness":"cursor-agent","model":"cursor-grok-4.6-xhigh","provider":"cursor","modelFamily":"cursor-grok-4.6"},{"harness":"claude","model":"opus","provider":"claude","modelFamily":"claude-opus"}]}' > "$home/config/model-catalog.json"
  cat > "$home/config/auto-quota-drain.json" <<'JSON'
{"schemaVersion":1,"warningPercentRemaining":7,"actionPercentRemaining":5,"maxSnapshotAgeSeconds":300,"positions":[{"position":"primary-seat","seat":"seat-a","provider":"claude","postDrainProvider":"cursor","postDrainModelFamily":"cursor-grok-4.6","requiredReasoningClass":"frontier","postDrainReasoningClass":"frontier"}]}
JSON
  printf '%s\n' \
    'window=firstmate:fm-seat-a' \
    'endpoint_task_id=seat-a' \
    "worktree=$seat" \
    "project=$seat" \
    'harness=claude' \
    'model=opus' \
    'effort=high' \
    'kind=secondmate' \
    "home=$seat" > "$home/state/seat-a.meta"
  : > "$home/state/seat-a.status"
  fakebin=$(make_production_toolchain "$root")
  : > "$root/tmux.log"
  : > "$root/pane.txt"
  printf 'claude\n' > "$root/tmux.state"
  printf '%s\n' "$home|$seat|$fakebin"
}

run_production_drain() {
  local home=$1 seat=$2 fakebin=$3 snapshot=$4 calls=$5 root=$6
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux \
    FM_AUTO_QUOTA_NOW=2030-01-01T00:01:00Z FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    FM_SKIP_SECONDMATE_INHERIT=1 FM_FAKE_QUOTA_SNAPSHOT="$snapshot" \
    FM_FAKE_QUOTA_CALLS="$calls" FM_FAKE_TMUX_LOG="$root/tmux.log" \
    FM_FAKE_TMUX_STATE="$root/tmux.state" FM_FAKE_TMUX_CAPTURE="$root/pane.txt" \
    FM_FAKE_SEAT_HOME="$seat" "$DRAIN"
}

run_production_bootstrap() {
  local home=$1 seat=$2 fakebin=$3 snapshot=$4 calls=$5 root=$6
  PATH="$fakebin:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_SKIP_SECONDMATE_INHERIT=1 FM_FAKE_TMUX_LOG="$root/tmux.log" FM_FAKE_TMUX_STATE="$root/tmux.state" \
    FM_FAKE_TMUX_CAPTURE="$root/pane.txt" FM_FAKE_SEAT_HOME="$seat" \
    FM_FAKE_QUOTA_SNAPSHOT="$snapshot" FM_FAKE_QUOTA_CALLS="$calls" \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

test_production_lifecycle_is_nonblocking_and_restart_safe() {
  local root="$TMP_ROOT/production" fields home seat fakebin snapshot calls out journal corr start elapsed phases
  local before_beat after_beat watcher_pid live_state
  fields=$(make_production_world "$root")
  home=${fields%%|*}; fields=${fields#*|}; seat=${fields%%|*}; fakebin=${fields#*|}
  snapshot="$home/snapshot.json"; calls="$home/quota.calls"
  write_snapshot "$snapshot" 6 90
  run_production_drain "$home" "$seat" "$fakebin" "$snapshot" "$calls" "$root" >/dev/null || fail "production baseline failed"
  write_snapshot "$snapshot" 5 90

  # Begin on the real old tuple: the seat is live on claude/opus/high.
  [ "$(cat "$root/tmux.state")" = claude ] || fail "production fixture did not begin on the real old tuple"
  assert_grep 'harness=claude' "$home/state/seat-a.meta" "production fixture did not begin on the drained harness"
  assert_grep 'model=opus' "$home/state/seat-a.meta" "production fixture did not begin on the drained model"
  assert_grep 'effort=high' "$home/state/seat-a.meta" "production fixture did not begin on the drained effort"

  start=$(date +%s)
  out=$(run_production_drain "$home" "$seat" "$fakebin" "$snapshot" "$calls" "$root") || fail "production checkpoint start failed: $out"
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 5 ] || fail "checkpoint cycle blocked for ${elapsed}s"
  [ -z "$out" ] || fail "pending checkpoint cycle should be silent: $out"
  journal="$home/state/auto-quota-drain/action-primary-seat"
  corr=$(grep '^corr_id=' "$journal" | cut -d= -f2-)
  printf '%s' "$corr" | grep -Eq '^[a-f0-9]{16}$' || fail "action journal did not persist its checkpoint correlation id"
  assert_grep 'phase=checkpoint_pending' "$journal" "checkpoint phase was not left pending for a later watcher cycle"
  assert_grep "home=$seat" "$journal" "action journal did not bind the exact secondmate home"
  assert_grep 'required_reasoning_class=frontier' "$journal" "action journal did not bind the required reasoning class"
  assert_grep 'old_target=firstmate:fm-seat-a' "$journal" "action journal did not bind the exact old endpoint identity"
  assert_grep 'old_harness=claude' "$journal" "action journal did not bind the old harness identity"
  assert_grep 'old_model=opus' "$journal" "action journal did not bind the old model identity"
  assert_grep 'old_effort=high' "$journal" "action journal did not bind the old effort identity"
  [ "$(cat "$root/tmux.state")" = claude ] || fail "checkpoint-pending cycle parked the seat early"
  assert_no_grep 'phase=complete' "$journal" "checkpoint-pending cycle wrote a premature completion"
  assert_no_grep 'phase=parking' "$journal" "checkpoint-pending cycle wrote a premature park"
  assert_no_grep 'phase=parked' "$journal" "checkpoint-pending cycle wrote a premature parked"

  touch -t 200001010000 "$home/state/.last-watcher-beat"
  before_beat=$(stat -c %Y "$home/state/.last-watcher-beat" 2>/dev/null || stat -f %m "$home/state/.last-watcher-beat")
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux FM_POLL=1 \
    FM_CHECK_INTERVAL=999 FM_SLACK_CHECK_INTERVAL=999 FM_HEARTBEAT=999 FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    FM_SKIP_SECONDMATE_INHERIT=1 FM_AUTO_QUOTA_NOW=2030-01-01T00:01:00Z \
    FM_FAKE_QUOTA_SNAPSHOT="$snapshot" FM_FAKE_QUOTA_CALLS="$calls" \
    FM_FAKE_TMUX_LOG="$root/tmux.log" FM_FAKE_TMUX_STATE="$root/tmux.state" \
    FM_FAKE_TMUX_CAPTURE="$root/pane.txt" FM_FAKE_SEAT_HOME="$seat" \
    "$ROOT/bin/fm-watch.sh" > "$root/watcher.log" 2>&1 &
  watcher_pid=$!
  sleep 3
  kill -0 "$watcher_pid" 2>/dev/null || fail "fixture watcher stopped while checkpoint receipt was pending: $(cat "$root/watcher.log")"
  kill -TERM "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  after_beat=$(stat -c %Y "$home/state/.last-watcher-beat" 2>/dev/null || stat -f %m "$home/state/.last-watcher-beat")
  [ "$after_beat" -gt "$before_beat" ] || fail "later watcher cycles did not advance the heartbeat while checkpoint receipt was pending"
  assert_grep 'phase=checkpoint_pending' "$journal" "later watcher cycle advanced without the correlated receipt"
  # The old tuple stays live across a later quota episode: no early completion, park, or relaunch.
  [ "$(cat "$root/tmux.state")" = claude ] || fail "later quota episode parked the still-live old endpoint"
  assert_no_grep 'phase=complete' "$journal" "later quota episode wrote a premature completion"
  assert_no_grep 'phase=parking' "$journal" "later quota episode wrote a premature park"
  assert_no_grep 'phase=parked' "$journal" "later quota episode wrote a premature parked"

  printf 'done: auto quota drain checkpoint sealed corr=%s\n' "$corr" >> "$home/state/seat-a.status"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    FM_FAKE_TMUX_LOG="$root/tmux.log" FM_FAKE_TMUX_STATE="$root/tmux.state" \
    FM_FAKE_TMUX_CAPTURE="$root/pane.txt" FM_FAKE_SEAT_HOME="$seat" \
    bash -c '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_tick "$2/state"' _ "$ROOT" "$home" \
    || fail "pending-reply owner did not resolve the checkpoint receipt"

  out=$(run_production_drain "$home" "$seat" "$fakebin" "$snapshot" "$calls" "$root") || fail "production checkpoint receipt failed: $out"
  [ -z "$out" ] || fail "checkpoint receipt cycle should be silent: $out"
  assert_grep 'phase=checkpointed' "$journal" "resolved receipt did not leave park for a later cycle"

  out=$(run_production_drain "$home" "$seat" "$fakebin" "$snapshot" "$calls" "$root") || fail "production park request failed: $out"
  [ -z "$out" ] || fail "parking cycle should be silent: $out"
  assert_grep 'phase=parking' "$journal" "graceful exit request did not leave a later-cycle parking phase"
  [ "$(cat "$root/tmux.state")" = bash ] || fail "graceful exit request was not delivered"

  out=$(run_production_drain "$home" "$seat" "$fakebin" "$snapshot" "$calls" "$root") || fail "production park confirmation failed: $out"
  [ -z "$out" ] || fail "park confirmation cycle should be silent: $out"
  assert_grep 'phase=parked' "$journal" "dead endpoint was not parked for later relaunch"
  [ "$(cat "$root/tmux.state")" = missing ] || fail "dead endpoint was not removed"

  out=$(run_production_bootstrap "$home" "$seat" "$fakebin" "$snapshot" "$calls" "$root") || fail "restart recovery before relaunch failed: $out"
  assert_grep 'harness=cursor-agent' "$home/state/seat-a.meta" "restart recovery before relaunch bypassed durable secondmate-harness"
  assert_grep 'routing_source=secondmate-config' "$home/state/seat-a.meta" "restart recovery before relaunch lost durable provenance"
  assert_grep 'model=cursor-grok-4.6-xhigh' "$home/state/seat-a.meta" "restart recovery before relaunch lost the durable model"
  assert_grep 'effort=xhigh' "$home/state/seat-a.meta" "restart recovery before relaunch lost the durable effort"
  [ "$(cat "$root/tmux.state")" = cursor-agent ] \
    || fail "restart recovery did not launch the durable cursor endpoint: $out; log=$(cat "$root/tmux.log")"
  assert_grep 'window=firstmate:fm-seat-a' "$home/state/seat-a.meta" "restart recovery recorded an unusable endpoint"
  live_state=$(PATH="$fakebin:$BASE_PATH" FM_FAKE_TMUX_LOG="$root/tmux.log" FM_FAKE_TMUX_STATE="$root/tmux.state" \
    FM_FAKE_TMUX_CAPTURE="$root/pane.txt" FM_FAKE_SEAT_HOME="$seat" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_state tmux firstmate:fm-seat-a' _ "$ROOT")
  [ "$live_state" = alive ] || fail "restart recovery endpoint did not classify alive: $live_state"

  out=$(run_production_drain "$home" "$seat" "$fakebin" "$snapshot" "$calls" "$root" 2>&1) || fail "production restart reconciliation failed: $out"
  assert_contains "$out" "action: quota pool claude crossed to 5% remaining" "production lifecycle did not complete after restart recovery"
  # Bootstrap liveness recovery already relaunched the durable endpoint between cycles, so the
  # drain's relaunch step reconciled an already-live endpoint rather than calling the launch owner.
  # The terminal attestation must say "reconciled" and must not falsely claim "relaunched".
  assert_contains "$out" "checkpointed, parked, and reconciled to a durable-config endpoint on cursor-agent/cursor-grok-4.6-xhigh (xhigh)" "production restart reconciliation did not attest the reconcile it actually performed"
  assert_not_contains "$out" "relaunched from durable config" "production restart reconciliation falsely claimed a relaunch the drain did not perform"
  assert_grep 'harness=cursor-agent' "$home/state/seat-a.meta" "production relaunch bypassed durable secondmate-harness"
  assert_grep 'model=cursor-grok-4.6-xhigh' "$home/state/seat-a.meta" "production relaunch lost the durable model pin"
  assert_grep 'effort=xhigh' "$home/state/seat-a.meta" "production relaunch lost the durable effort pin"
  assert_grep 'routing_source=secondmate-config' "$home/state/seat-a.meta" "production relaunch provenance was not truthful"
  assert_no_grep 'matched_rule=' "$home/state/seat-a.meta" "secondmate config relaunch claimed a crew-dispatch rule"
  assert_no_grep 'dispatch=resolved' "$home/state/seat-a.meta" "secondmate config relaunch claimed crew profile resolution"

  printf 'bash\n' > "$root/tmux.state"
  out=$(run_production_bootstrap "$home" "$seat" "$fakebin" "$snapshot" "$calls" "$root") || fail "post-drain bootstrap recovery failed: $out"
  assert_grep 'harness=cursor-agent' "$home/state/seat-a.meta" "post-drain death recovery reverted to the drained harness"
  assert_grep 'model=cursor-grok-4.6-xhigh' "$home/state/seat-a.meta" "post-drain death recovery reverted the durable model"
  assert_grep 'effort=xhigh' "$home/state/seat-a.meta" "post-drain death recovery reverted the durable effort"
  assert_grep 'routing_source=secondmate-config' "$home/state/seat-a.meta" "bootstrap recovery lost durable routing provenance"
  phases=$(grep '^phase=' "$journal" | cut -d= -f2-)
  [ "$phases" = complete ] || fail "completed action journal changed during later recovery"
  pass "auto quota drain: real pending reply, park, relaunch, restart, and post-drain recovery reuse durable tuple"
}

test_adapter_refusals_and_parked_retry() {
  local out phases
  world_fields "$(make_world refusals)"
  write_snapshot "$TEST_SNAPSHOT" 6 90
  run_adapter_action_cycle >/dev/null || fail "refusal baseline failed"
  write_snapshot "$TEST_SNAPSHOT" 5 90
  out=$(run_adapter_action_cycle env FM_FAKE_LIFECYCLE_FAIL=checkpoint 2>&1) || fail "checkpoint refusal must remain nonblocking: $out"
  assert_contains "$out" "diagnostic: auto-quota-drain seat-a checkpoint refused: checkpoint seal missing; no later lifecycle step ran" "checkpoint refusal diagnostic changed"
  [ "$(cut -f1 "$TEST_TRACE")" = checkpoint ] || fail "checkpoint refusal reached a later phase"

  world_fields "$(make_world parked-retry)"
  write_snapshot "$TEST_SNAPSHOT" 6 90
  run_adapter_action_cycle >/dev/null || fail "parked retry baseline failed"
  write_snapshot "$TEST_SNAPSHOT" 5 90
  run_adapter_action_cycle >/dev/null || fail "parked retry checkpoint failed"
  run_adapter_action_cycle >/dev/null || fail "parked retry park failed"
  out=$(run_adapter_action_cycle env FM_FAKE_LIFECYCLE_FAIL=relaunch 2>&1) || fail "relaunch refusal should remain nonblocking: $out"
  assert_contains "$out" "diagnostic: auto-quota-drain seat-a relaunch refused after a sealed checkpoint and park: temporary relaunch failure" "relaunch refusal diagnostic changed"
  out=$(run_adapter_action_cycle 2>&1) || fail "parked relaunch retry failed: $out"
  assert_contains "$out" "action: quota pool claude crossed to 5% remaining" "parked retry did not complete"
  phases=$(cut -f1 "$TEST_TRACE" | paste -sd, -)
  [ "$phases" = checkpoint,park,relaunch,relaunch ] || fail "parked retry repeated an earlier phase: $phases"
  pass "auto quota drain: refusals stop safely and parked relaunch retries only relaunch"
}

test_bad_quota_and_error_recovery_backstop() {
  local out
  world_fields "$(make_world bad-quota)"
  write_snapshot "$TEST_SNAPSHOT" 4 90 2029-12-31T23:00:00Z
  out=$(run_adapter_action_cycle) || fail "stale quota diagnostic failed: $out"
  assert_contains "$out" "diagnostic: auto-quota-drain quota snapshot is stale; no lifecycle action taken" "stale quota diagnostic changed"
  out=$(run_adapter_action_cycle) || fail "stale quota dedupe failed: $out"
  [ -z "$out" ] || fail "stale quota diagnostic repeated unchanged: $out"
  printf '%s\n' '{bad json' > "$TEST_SNAPSHOT"
  out=$(run_adapter_action_cycle) || fail "malformed quota diagnostic failed: $out"
  assert_contains "$out" "diagnostic: auto-quota-drain quota snapshot is malformed; no lifecycle action taken" "malformed quota diagnostic changed"
  [ ! -e "$TEST_TRACE" ] || fail "bad quota triggered lifecycle"

  world_fields "$(make_world recovery-backstop)"
  printf '%s\n' 'error-triggered-relaunch=pending' > "$TEST_HOME/state/seat-a.escalation"
  write_snapshot "$TEST_SNAPSHOT" 90 90
  run_adapter_action_cycle >/dev/null || fail "healthy backstop coexistence check failed"
  [ "$(cat "$TEST_HOME/state/seat-a.escalation")" = 'error-triggered-relaunch=pending' ] || fail "threshold path replaced or consumed error recovery"
  [ ! -e "$TEST_TRACE" ] || fail "healthy threshold path invoked lifecycle while error recovery remained pending"
  pass "auto quota drain: invalid quota fails open and error-triggered recovery remains untouched"
}

# make_drift_tmux: a fake tmux that tracks per-window state under $1/windows/<name>.
# Each window's state file holds the foreground command (claude/cursor-agent/bash/missing).
make_drift_tmux() {
  local root=$1 fakebin wndir
  fakebin="$root/fakebin"
  wndir="$root/windows"
  mkdir -p "$fakebin" "$wndir"
  printf 'claude\n' > "$wndir/fm-seat-a"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_TMUX_LOG:?}
wndir=${FM_FAKE_TMUX_WNDIR:?}
pane=${FM_FAKE_TMUX_CAPTURE:?}
# Resolve the -t target from the args (tmux uses -t <target>).
target=
i=2
while [ "$i" -le $# ]; do
  a=${!i}
  if [ "$a" = -t ] || [ "$a" = -s ]; then
    n=$((i+1))
    target=${!n:-}
    break
  fi
  i=$((i+1))
done
case "${1:-}" in
  has-session) printf '%s\n' "$*" >> "$log"; exit 0 ;;
  new-window)
    printf '%s\n' "$*" >> "$log"
    printf 'bash\n' > "$wndir/fm-seat-a"
    exit 0
    ;;
  kill-window)
    printf '%s\n' "$*" >> "$log"
    printf 'missing\n' > "$wndir/fm-seat-a"
    exit 0
    ;;
  list-windows)
    [ -f "$wndir/fm-seat-a" ] && [ "$(cat "$wndir/fm-seat-a")" != missing ] && printf 'fm-seat-a\n'
    exit 0
    ;;
  display-message)
    case "$*" in
      *pane_current_command*)
        w=${target#*:}
        [ -f "$wndir/$w" ] || exit 1
        st=$(cat "$wndir/$w")
        [ "$st" != missing ] || exit 1
        printf '%s\n' "$st"
        ;;
      *pane_tty*) printf '\n' ;;
      *cursor_y*) printf '0\n' ;;
      *session_name*) printf 'firstmate\n' ;;
      *pane_current_path*) printf '%s\n' "${FM_FAKE_SEAT_HOME:?}" ;;
      *) printf 'firstmate\n' ;;
    esac
    exit 0
    ;;
  capture-pane) cat "$pane"; exit 0 ;;
  send-keys)
    printf '%s\n' "$*" >> "$log"
    case "$*" in
      *'/exit'*|*' C-d') printf 'bash\n' > "$wndir/fm-seat-a" ;;
      *cursor-agent*) printf 'cursor-agent\n' > "$wndir/fm-seat-a" ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_parking_binds_journal_old_identity_through_meta_drift() {
  local root="$TMP_ROOT/drift" fields home seat fakebin snapshot calls out journal
  fields=$(make_production_world "$root")
  home=${fields%%|*}; fields=${fields#*|}; seat=${fields%%|*}; fakebin=${fields#*|}
  # Replace the single-state fake tmux with a per-window fake tmux.
  fakebin=$(make_drift_tmux "$root")
  printf '#!/usr/bin/env bash\nexec '"'"'%s'"'"' "$@"\n' "$NODE_BIN" > "$fakebin/node"
  printf '#!/usr/bin/env bash\nexec '"'"'%s'"'"' "$@"\n' "$JQ_BIN" > "$fakebin/jq"
  chmod +x "$fakebin/node" "$fakebin/jq"
  fm_fake_exit0 "$fakebin" chrome-devtools-axi pi-signed cursor-agent
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.45
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || printf '%s\n' '0.1.29'
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  fm_test_write_active_treehouse_fake "$fakebin"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
exit 0
SH
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  '--version ') printf '%s\n' '0.2.4' ;;
  'update --help') printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  'mv --help') printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf '%s\n' '0.1.17'; exit 0; fi
[ "${1:-}" = --json ] || exit 64
printf 'quota-call\n' >> "$FM_FAKE_QUOTA_CALLS"
cat "$FM_FAKE_QUOTA_SNAPSHOT"
SH
  chmod +x "$fakebin"/*
  snapshot="$home/snapshot.json"; calls="$home/quota.calls"
  : > "$root/tmux.log"; : > "$root/pane.txt"
  journal="$home/state/auto-quota-drain/action-primary-seat"

  run_drift_drain() {
    PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_BACKEND=tmux \
      FM_AUTO_QUOTA_NOW=2030-01-01T00:01:00Z FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
      FM_SKIP_SECONDMATE_INHERIT=1 FM_FAKE_QUOTA_SNAPSHOT="$snapshot" \
      FM_FAKE_QUOTA_CALLS="$calls" FM_FAKE_TMUX_LOG="$root/tmux.log" \
      FM_FAKE_TMUX_WNDIR="$root/windows" FM_FAKE_TMUX_CAPTURE="$root/pane.txt" \
      FM_FAKE_SEAT_HOME="$seat" "$DRAIN"
  }

  write_snapshot "$snapshot" 6 90
  run_drift_drain >/dev/null || fail "drift baseline failed"
  write_snapshot "$snapshot" 5 90
  run_drift_drain >/dev/null || fail "drift checkpoint failed"
  assert_grep 'phase=checkpoint_pending' "$journal" "drift fixture did not reach checkpoint_pending"
  printf 'done: auto quota drain checkpoint sealed corr=%s\n' "$(grep '^corr_id=' "$journal" | cut -d= -f2-)" >> "$home/state/seat-a.status"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    FM_FAKE_TMUX_LOG="$root/tmux.log" FM_FAKE_TMUX_WNDIR="$root/windows" \
    FM_FAKE_TMUX_CAPTURE="$root/pane.txt" FM_FAKE_SEAT_HOME="$seat" \
    bash -c '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_tick "$2/state"' _ "$ROOT" "$home" \
    || fail "drift pending-reply owner did not resolve the receipt"
  run_drift_drain >/dev/null || fail "drift receipt failed"
  assert_grep 'phase=checkpointed' "$journal" "drift receipt did not reach checkpointed"
  run_drift_drain >/dev/null || fail "drift park request failed"
  assert_grep 'phase=parking' "$journal" "drift park request did not reach parking"
  [ "$(cat "$root/windows/fm-seat-a")" = bash ] || fail "drift graceful exit was not delivered"

  # Drift the seat metadata to a brand-new live cursor endpoint on a different window,
  # simulating bootstrap liveness recovery creating a fresh endpoint while the old
  # journal-bound endpoint is still shutting down. Parking must still observe the
  # journal-bound old endpoint die, not the drifted live metadata.
  printf 'cursor-agent\n' > "$root/windows/fm-seat-b"
  set_seat_meta "$home" seat-a cursor-agent cursor-grok-4.6-xhigh xhigh firstmate:fm-seat-b "$seat"

  out=$(run_drift_drain 2>&1) || fail "drift park confirmation failed: $out"
  [ -z "$out" ] || fail "drift park confirmation should be silent: $out"
  assert_grep 'phase=parked' "$journal" "parking did not advance through the journal-bound old endpoint when metadata drifted to a live new endpoint"
  [ "$(cat "$root/windows/fm-seat-a")" = missing ] || fail "journal-bound old endpoint was not parked"
  [ "$(cat "$root/windows/fm-seat-b")" = cursor-agent ] || fail "drifted live new endpoint was disturbed"
  pass "auto quota drain: parking observes the journal-bound old endpoint through metadata drift"
}

test_parking_never_shortcuts_on_durable_tuple_live() {
  local root="$TMP_ROOT/shortcut" fields home seat fakebin snapshot calls out journal
  fields=$(make_production_world "$root")
  home=${fields%%|*}; fields=${fields#*|}; seat=${fields%%|*}; fakebin=${fields#*|}
  snapshot="$home/snapshot.json"; calls="$home/quota.calls"
  : > "$root/tmux.log"; : > "$root/pane.txt"
  journal="$home/state/auto-quota-drain/action-primary-seat"

  write_snapshot "$snapshot" 6 90
  run_production_drain "$home" "$seat" "$fakebin" "$snapshot" "$calls" "$root" >/dev/null || fail "shortcut baseline failed"
  write_snapshot "$snapshot" 5 90
  run_production_drain "$home" "$seat" "$fakebin" "$snapshot" "$calls" "$root" >/dev/null || fail "shortcut checkpoint failed"
  printf 'done: auto quota drain checkpoint sealed corr=%s\n' "$(grep '^corr_id=' "$journal" | cut -d= -f2-)" >> "$home/state/seat-a.status"
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    FM_FAKE_TMUX_LOG="$root/tmux.log" FM_FAKE_TMUX_STATE="$root/tmux.state" \
    FM_FAKE_TMUX_CAPTURE="$root/pane.txt" FM_FAKE_SEAT_HOME="$seat" \
    bash -c '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_tick "$2/state"' _ "$ROOT" "$home" \
    || fail "shortcut pending-reply owner did not resolve the receipt"
  run_production_drain "$home" "$seat" "$fakebin" "$snapshot" "$calls" "$root" >/dev/null || fail "shortcut receipt failed"
  run_production_drain "$home" "$seat" "$fakebin" "$snapshot" "$calls" "$root" >/dev/null || fail "shortcut park request failed"
  assert_grep 'phase=parking' "$journal" "shortcut park request did not reach parking"
  [ "$(cat "$root/tmux.state")" = bash ] || fail "shortcut graceful exit was not delivered"

  # Subvert the seat metadata to claim the durable tuple is already live, the exact
  # shape the removed candidate-live parking shortcut would have treated as a
  # recovered candidate. Parking must still observe the journal-bound old endpoint
  # die and must not declare complete or skip park/relaunch.
  printf 'cursor-agent\n' > "$root/tmux.state"
  set_seat_meta "$home" seat-a cursor-agent cursor-grok-4.6-xhigh xhigh firstmate:fm-seat-a "$seat"

  out=$(run_production_drain "$home" "$seat" "$fakebin" "$snapshot" "$calls" "$root" 2>&1) || fail "shortcut park confirmation failed: $out"
  [ -z "$out" ] || fail "shortcut park confirmation should be silent: $out"
  assert_grep 'phase=parking' "$journal" "parking advanced instead of observing the still-live old endpoint die"
  assert_no_grep 'phase=parked' "$journal" "parking used a candidate-live shortcut to skip the old endpoint death"
  assert_no_grep 'phase=complete' "$journal" "parking declared a premature completion from mutable metadata"
  pass "auto quota drain: parking never shortcuts on a still-live durable-tuple process"
}

test_resolve_candidate_separates_stderr_from_stdout() {
  local out
  world_fields "$(make_world stderr-split)"
  : > "$TEST_CALLS"
  run_split() {
    PATH="$TEST_FAKEBIN:$BASE_PATH" \
      FM_HOME="$TEST_HOME" FM_ROOT_OVERRIDE="$ROOT" \
      FM_AUTO_QUOTA_NOW=2030-01-01T00:01:00Z \
      FM_AUTO_QUOTA_LIFECYCLE_ADAPTER="$TEST_FAKEBIN/lifecycle" \
      FM_FAKE_QUOTA_SNAPSHOT="$TEST_SNAPSHOT" FM_FAKE_QUOTA_CALLS="$TEST_CALLS" \
      FM_FAKE_LIFECYCLE_TRACE="$TEST_TRACE" \
      LC_ALL=invalid_locale.UTF-8 \
      "$DRAIN" 2>"$TEST_HOME/stderr.log"
  }
  # A baseline cycle above the action threshold seeds the previous-percent record
  # so a later crossing triggers the action; a bash locale warning lands on
  # fm-harness.sh's stderr while the tuple rides stdout.
  write_snapshot "$TEST_SNAPSHOT" 6 90
  run_split >/dev/null || fail "stderr-split baseline cycle failed"
  write_snapshot "$TEST_SNAPSHOT" 5 90
  run_split >/dev/null || fail "stderr-split checkpoint cycle failed"
  run_split >/dev/null || fail "stderr-split park cycle failed"
  out=$(run_split) || fail "stderr-split relaunch cycle failed: $out"
  assert_contains "$out" "action: quota pool claude crossed to 5% remaining; secondmate seat-a checkpointed, parked, and relaunched from durable config on cursor-agent/cursor-grok-4.6-xhigh (xhigh)" "stderr-split action did not resolve the durable tuple through a bash locale warning"
  assert_not_contains "$out" "setlocale" "a bash locale warning parsed as the harness name"
  pass "auto quota drain: resolve_candidate separates fm-harness.sh stderr from the tuple stdout"
}

test_healthy_is_silent
test_watcher_surfaces_the_bounded_warning
test_warning_transition_and_dedupe
test_config_has_no_second_launch_ladder
test_durable_tuple_must_match_catalog_post_drain_facts
test_nonterminal_journals_resume_before_current_inputs
test_journal_identity_drift_refuses_every_mutating_phase
test_adapter_progresses_one_phase_per_cycle
test_reasoning_floor_and_target_pool_are_bounded
test_uncertain_checkpoint_delivery_recovers_without_abandoning_action
test_definitive_checkpoint_failure_refuses_without_later_mutation
test_production_lifecycle_is_nonblocking_and_restart_safe
test_parking_binds_journal_old_identity_through_meta_drift
test_parking_never_shortcuts_on_durable_tuple_live
test_resolve_candidate_separates_stderr_from_stdout
test_adapter_refusals_and_parked_retry
test_bad_quota_and_error_recovery_backstop

printf '%s\n' "All auto-quota-drain tests passed."
