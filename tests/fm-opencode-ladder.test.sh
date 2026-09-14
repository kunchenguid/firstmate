#!/usr/bin/env bash
# Behavior tests for bin/fm-opencode-ladder-lib.sh - the free-then-Go ladder.
#
# The captain's rule: spend the FREE tier's own quota first each day, fall
# through to the paid Go tier only once free is proven exhausted, and climb
# back when free resets. Same model (muse spark 1.3), different provider
# prefix: opencode/muse-spark-1.3-contributor-free, then
# opencode-go/muse-spark-1.3-contributor.
#
# Where the agy ladder is predictive (it reads quota percentages before
# spending), this one is reactive: quota-axi reports nothing for opencode, so
# there is no reading to decide on. The only "free is exhausted" signal is the
# existing cap detection - bin/fm-opencode-retry.sh classifying the vendor's
# own retry-backoff horizon as quota-scale - and this ladder builds on it
# rather than re-deriving it.
#
# The load-bearing contracts:
#   1. A fresh home dispatches FREE by default, including a spawn that names
#      no model at all.
#   2. A free request with no proven cap stays on free, silently.
#   3. A free request with a proven quota-scale cap on the free tier falls
#      through to Go, and says so. The recorded vendor refusal below
#      ("Free usage exceeded, subscribe to Go [retrying in 21h 54m]") is the
#      text that case is built from: the test converts its horizon into the
#      vendor's own `next` timestamp through the real record helper, so the
#      state machine is exercised against the refusal without spending quota.
#   4. A seconds-long backoff (transient retry) never triggers the fall-through.
#   5. An expired cap climbs back to free on its own: the vendor's horizon is
#      the timer, via the record helper's own expiry.
#   6. A cap bound to the GO tier never moves a free request: the tiers are
#      separate quotas, so Go being capped says nothing about free.
#   7. An explicit Go request always stands, even while free is capped.
#   8. A model outside the governed pair launches unchanged, but reported.
#   9. FM_OPENCODE_LADDER_OVERRIDE holds a free request on free past a proven
#      cap, and SAYS SO. A silent override would be worse than no ladder.
#  10. A quota-scale cap with NO model binding still falls through: the
#      failure direction is deliberate (see the lib header), and the notice
#      says the evidence was unbound.
#  11. The gate sits on the ordinary dispatch path: a real bin/fm-spawn.sh
#      launch with a proven free cap carries the Go model id, and a real
#      launch with no model at all carries the free id - pinned through a
#      fake tmux pane, so no real harness ever starts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-opencode-ladder-lib.sh
. "$ROOT/bin/fm-opencode-ladder-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-opencode-ladder)
HELPER="$ROOT/bin/fm-opencode-retry.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"

FREE='opencode/muse-spark-1.3-contributor-free'
GO='opencode-go/muse-spark-1.3-contributor'

now_s() { date +%s; }
ms_from_now() {  # <offset-secs> -> epoch ms
  echo $(( ($(now_s) + $1) * 1000 ))
}

fresh_state() {  # <name> -> state dir with no retry evidence
  local dir="$TMP_ROOT/state-$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# record_cap <state-dir> <id> <offset-secs> [model]: one retry observation
# through the real record helper - the same executable the spawn-installed
# plugin names, so the fixture is evidence-shaped, never hand-written.
record_cap() {  # <state-dir> <id> <offset-secs> [model]
  local state=$1 id=$2 offset=$3 model=${4:-}
  if [ -n "$model" ]; then
    "$HELPER" record "$state" "$id" 3 "$(ms_from_now "$offset")" "$model" "ses_$id"
  else
    "$HELPER" record "$state" "$id" 3 "$(ms_from_now "$offset")"
  fi
}

# run_gate <state-dir> <model>: the gate the way a caller runs it - effective
# model on stdout, notice (if any) on stderr. Prints "<model><TAB><note>".
# The notice travels on stderr rather than a global because callers capture
# the model with $(...), which runs in a subshell where a global assignment
# would be lost. A caller that needs environment (e.g. the override) prefixes
# the run_gate call itself, which propagates into the capture subshell.
run_gate() {  # <state-dir> <model>
  local state=$1 model=$2 note got
  note=$(mktemp "$TMP_ROOT/note.XXXXXX")
  got=$(fm_opencode_ladder_model "$model" "$state" 2>"$note") || return 1
  printf '%s|%s\n' "$got" "$(cat "$note")"
}

GOT=''
NOTE=''
split_gate() {  # <run_gate-output>: sets GOT and NOTE
  GOT=${1%%|*}
  NOTE=${1#*|}
}

# --- pane-capture stub -------------------------------------------------------
# fm_opencode_ladder_pane_file captures through fm_backend_capture; the stub
# serves per-target fixture text so the idle shape is exercised without a
# real pane. Fixtures live under $FM_PANE_FIXTURES/<target>.txt; a target
# with no fixture is uncapturable (unknown, never open).
FM_PANE_FIXTURES="$TMP_ROOT/panes"
mkdir -p "$FM_PANE_FIXTURES"
fm_backend_capture() {  # <backend> <target> <lines> [label]
  local fixture="$FM_PANE_FIXTURES/${2:-}.txt"
  [ -f "$fixture" ] || return 1
  cat "$fixture"
}

# write_lane_meta <state-dir> <id> <model>: the durable record the way a
# spawn leaves it, with an endpoint the capture stub can serve.
write_lane_meta() {  # <state-dir> <id> <model>
  printf 'harness=opencode\nmodel=%s\nkind=scout\nbackend=tmux\nwindow=pane-%s\n' \
    "$3" "$2" > "$1/$2.meta"
}

# --- 1. free is the default ---------------------------------------------------

test_fresh_home_dispatches_free() {
  local state out
  state=$(fresh_state fresh)
  out=$(run_gate "$state" '') || fail "gate must never refuse a fresh home"
  split_gate "$out"
  [ "$GOT" = "$FREE" ] || fail "fresh home with no model must dispatch free, got '$GOT'"
  [ -z "$NOTE" ] || fail "clean free dispatch must stay silent, said: $NOTE"
  pass "a fresh home dispatches free by default"
}

test_explicit_free_stays_free_when_healthy() {
  local state out
  state=$(fresh_state healthy)
  out=$(run_gate "$state" "$FREE") || fail "gate must never refuse a healthy rung"
  split_gate "$out"
  [ "$GOT" = "$FREE" ] || fail "healthy free request must stay free, got '$GOT'"
  [ -z "$NOTE" ] || fail "clean free dispatch must stay silent, said: $NOTE"
  pass "a free request with no proven cap stays on free"
}

# --- 2/3. the recorded refusal falls through ----------------------------------

test_recorded_refusal_falls_through_to_go() {
  local state out
  state=$(fresh_state refusal)
  # Recorded vendor refusal, verbatim from the 2026-09-07 twelve-wide stall:
  #   Free usage exceeded, subscribe to Go [retrying in 21h 54m]
  # The bracketed horizon is the vendor's own backoff; 21h 54m is 78840s.
  # The test converts that horizon into the structural `next` timestamp the
  # detector owns, so the state machine is proven against the refusal text
  # without spending a unit of paid quota.
  record_cap "$state" lane1 78840 "$FREE" || fail "record refused the refusal-shaped observation"
  out=$(run_gate "$state" "$FREE") || fail "gate must never refuse, even past the cap"
  split_gate "$out"
  [ "$GOT" = "$GO" ] || fail "proven free cap must fall through to Go, got '$GOT'"
  case "$NOTE" in
    *'free'*|*'Free'*) : ;;
    *) fail "fall-through must name the exhausted free tier, said: ${NOTE:-<silent>}" ;;
  esac
  pass "the recorded free refusal falls through to Go with the reason stated"
}

test_transient_retry_stays_free() {
  local state out
  state=$(fresh_state transient)
  record_cap "$state" lane1 8 "$FREE" || fail "record refused a transient observation"
  out=$(run_gate "$state" "$FREE") || fail "gate must never refuse"
  split_gate "$out"
  [ "$GOT" = "$FREE" ] || fail "a seconds-long backoff must never trigger the fall-through, got '$GOT'"
  pass "a transient retry backoff stays on free"
}

# --- 5. climb-back on the vendor's own horizon ---------------------------------

test_expired_cap_climbs_back_to_free() {
  local state out
  state=$(fresh_state expired)
  # A 22-hour cap recorded 23 hours ago: the vendor's own scheduled retry time
  # plus grace has passed, so the file no longer describes the present and the
  # next spawn climbs back without any timer of this ladder's own.
  record_cap "$state" lane1 -82800 "$FREE" || fail "record refused an old observation"
  out=$(run_gate "$state" "$FREE") || fail "gate must never refuse"
  split_gate "$out"
  [ "$GOT" = "$FREE" ] || fail "an expired cap must climb back to free, got '$GOT'"
  pass "an expired cap climbs back to free on the vendor's own horizon"
}

# --- 6/7. the tiers are separate -----------------------------------------------

test_go_cap_does_not_move_free() {
  local state out
  state=$(fresh_state gocap)
  record_cap "$state" lane1 78840 "$GO" || fail "record refused a Go-bound cap"
  out=$(run_gate "$state" "$FREE") || fail "gate must never refuse"
  split_gate "$out"
  [ "$GOT" = "$FREE" ] || fail "a Go-tier cap must not move a free request, got '$GOT'"
  pass "a cap bound to the Go tier leaves free dispatch alone"
}

test_explicit_go_stands_despite_free_cap() {
  local state out
  state=$(fresh_state explicitgo)
  record_cap "$state" lane1 78840 "$FREE" || fail "record refused fixture"
  out=$(run_gate "$state" "$GO") || fail "gate must never refuse"
  split_gate "$out"
  [ "$GOT" = "$GO" ] || fail "an explicit Go request must stand, got '$GOT'"
  pass "an explicit Go request stands even while free is capped"
}

# --- 8/9/10. off-ladder, override, unbound -------------------------------------

test_off_ladder_model_allowed_with_notice() {
  local state out
  state=$(fresh_state off)
  record_cap "$state" lane1 78840 "$FREE" || fail "record refused fixture"
  out=$(run_gate "$state" 'opencode/glm-5.3') || fail "gate must never refuse"
  split_gate "$out"
  [ "$GOT" = 'opencode/glm-5.3' ] || fail "an off-ladder model must launch unchanged, got '$GOT'"
  [ -n "$NOTE" ] || fail "an off-ladder model must be reported, not silently passed"
  pass "a model outside the governed pair launches unchanged but reported"
}

test_override_holds_free_past_cap() {
  local state out
  state=$(fresh_state override)
  record_cap "$state" lane1 78840 "$FREE" || fail "record refused fixture"
  out=$(FM_OPENCODE_LADDER_OVERRIDE='captain asked for free' run_gate "$state" "$FREE") \
    || fail "gate must never refuse"
  split_gate "$out"
  [ "$GOT" = "$FREE" ] || fail "the override must hold free past the cap, got '$GOT'"
  case "$NOTE" in
    *'OVERRID'*|*' verrid'*) : ;;
    *) fail "an overridden fall-through must say so, said: ${NOTE:-<silent>}" ;;
  esac
  pass "FM_OPENCODE_LADDER_OVERRIDE holds free past a proven cap and says so"
}

test_unbound_cap_falls_through() {
  local state out
  state=$(fresh_state unbound)
  # Quota-scale, but the plugin recorded no model binding: the failure
  # direction is deliberate - a stalled fleet is worse than a small early
  # spend - so this still falls through, and the notice owns the ambiguity.
  record_cap "$state" lane1 78840 || fail "record refused an unbound observation"
  out=$(run_gate "$state" "$FREE") || fail "gate must never refuse"
  split_gate "$out"
  [ "$GOT" = "$GO" ] || fail "an unbound quota-scale cap must still fall through, got '$GOT'"
  case "$NOTE" in
    *'no model'*|*'unbound'*) : ;;
    *) fail "an unbound fall-through must own the ambiguity, said: ${NOTE:-<silent>}" ;;
  esac
  pass "an unbound quota-scale cap falls through with the ambiguity stated"
}

# --- 11. the dispatch path ------------------------------------------------------
#
# A real bin/fm-spawn.sh launch with a fake tmux pane, so the assertions pin
# the command firstmate would run without starting any real harness.

spawn_fakebin() {  # <dir> -> fakebin with tmux/treehouse/timeout stubs
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # Test-local pool-CLI stub, carried from the fork's tests/lib.sh with the
  # real-spawn case: this base's shared lib has no treehouse stub, and the
  # spawn here only needs `get` to print a leased path (upstream's spawn never
  # calls it; exit 0 suffices).
  fm_fake_treehouse() {
    local _treehouse_fakebin=$1
    cat > "$_treehouse_fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = get ]; then
  printf '%s\n' "${FM_FAKE_LEASE_PATH:-${FM_FAKE_PANE_PATH:-}}"
fi
exit 0
SH
    chmod +x "$_treehouse_fakebin/treehouse"
  }
  fm_fake_treehouse "$fakebin"
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  printf '%s\n' "$fakebin"
}

# spawn_opencode <dir> <id> [model]: a REAL bin/fm-spawn.sh opencode launch.
# Prints "<launch-log> <home>". Model empty means no --model flag at all.
spawn_opencode() {  # <dir> <id> [model]
  local dir=$1 id=$2 model=${3:-} home proj wt fakebin
  home="$dir/home"
  proj="$dir/proj"
  wt="$dir/wt"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  fakebin=$(spawn_fakebin "$dir/fake")
  fm_git_worktree "$proj" "$wt" "wt-$id"
  # This base kept upstream's brief scaffold (batch 2 was dropped), which
  # refuses a brief whose ## Captain's intent / ## Firstmate spec subsections
  # do not sit under a top-level # Task heading - so the fixture carries that
  # shape, where the fork's looser scaffold accepted one line.
  printf '# Task\n\n## Captain'"'"'s intent\n\nroute this test lane\n\n## Firstmate spec\n\nopencode ladder dispatch\n' > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  if [ -n "$model" ]; then
    env PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" FM_FAKE_LAUNCH_LOG="$dir/launch.log" TMUX="fake,1,0" \
      "$SPAWN" "$id" "$proj" \
      --harness opencode --model "$model" --mode no-mistakes --yolo off >/dev/null 2>&1
  else
    env PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" FM_FAKE_LAUNCH_LOG="$dir/launch.log" TMUX="fake,1,0" \
      "$SPAWN" "$id" "$proj" \
      --harness opencode --mode no-mistakes --yolo off >/dev/null 2>&1
  fi
  printf '%s %s\n' "$dir/launch.log" "$home"
}

test_spawn_falls_through_on_proven_cap() {
  local dir="$TMP_ROOT/spawn-go" log home launch log_home
  mkdir -p "$dir/home/state"
  "$HELPER" record "$dir/home/state" lane1 3 "$(ms_from_now 78840)" "$FREE" "ses_lane1" \
    || fail "record refused fixture"
  log_home=$(spawn_opencode "$dir" task-go "$FREE")
  log=${log_home%% *}; home=${log_home#* }
  [ -f "$log" ] || fail "spawn wrote no launch command"
  launch=$(cat "$log")
  assert_contains "$launch" "$GO" "a proven free cap routes the real launch to Go"
  assert_not_contains "$launch" "$FREE" "a proven free cap leaves no free model flag on the launch"
  assert_contains "$(cat "$home/state/task-go.meta")" "model=$GO" "the durable record names the Go model"
  pass "a proven free cap routes a real spawn to Go"
}

test_spawn_defaults_to_free() {
  local dir="$TMP_ROOT/spawn-free" log home launch log_home
  mkdir -p "$dir"
  log_home=$(spawn_opencode "$dir" task-free)
  log=${log_home%% *}; home=${log_home#* }
  [ -f "$log" ] || fail "spawn wrote no launch command"
  launch=$(cat "$log")
  assert_contains "$launch" "$FREE" "a modelless opencode spawn carries the free id"
  assert_contains "$(cat "$home/state/task-free.meta")" "model=$FREE" "the durable record names the free model"
  pass "a modelless opencode spawn dispatches free end to end"
}

test_idle_lane_falls_through_to_go() {
  local state out
  state=$(fresh_state idlecap)
  write_lane_meta "$state" lane1 "$FREE"
  # No sidecar: the lane took the provider error and ended its turn, so the
  # plugin cleared (or never wrote) the retry evidence. Its pane still shows
  # the cap verbatim - wrapped across rendered lines, as on 2026-09-14. This
  # is the entire bug: the gate used to answer OPEN for this lane and route
  # the next spawn onto the dead rung.
  printf '%s\n' \
    'working on the task...' \
    'Free usage exceeded, subscri' \
    'be to Go [retrying in 35s attempt #5]' \
    'opencode>' > "$FM_PANE_FIXTURES/pane-lane1.txt"
  out=$(run_gate "$state" "$FREE") || fail "gate must never refuse, even past the cap"
  split_gate "$out"
  [ "$GOT" = "$GO" ] || fail "an idle-after-cap lane must fall through to Go, got '$GOT'"
  case "$NOTE" in
    *'pane'*|*'horizon'*) : ;;
    *) fail "a text-evidence fall-through must own the missing horizon, said: ${NOTE:-<silent>}" ;;
  esac
  pass "an idle-after-cap lane falls through to Go"
}

test_idle_healthy_lane_stays_free() {
  local state out
  state=$(fresh_state idlehealthy)
  write_lane_meta "$state" lane1 "$FREE"
  # Idle turn, clean pane, no sidecar: no evidence of a cap anywhere. A gate
  # that read this as capped would spend the captain's money for nothing.
  printf '%s\n' \
    'working on the task...' \
    'done' \
    'opencode>' > "$FM_PANE_FIXTURES/pane-lane1.txt"
  out=$(run_gate "$state" "$FREE") || fail "gate must never refuse"
  split_gate "$out"
  [ "$GOT" = "$FREE" ] || fail "an idle lane with a clean pane must stay free, got '$GOT'"
  [ -z "$NOTE" ] || fail "a clean idle dispatch must stay silent, said: $NOTE"
  pass "an idle lane with a clean pane stays on free"
}

test_fresh_home_dispatches_free
test_explicit_free_stays_free_when_healthy
test_recorded_refusal_falls_through_to_go
test_transient_retry_stays_free
test_expired_cap_climbs_back_to_free
test_go_cap_does_not_move_free
test_explicit_go_stands_despite_free_cap
test_off_ladder_model_allowed_with_notice
test_override_holds_free_past_cap
test_unbound_cap_falls_through
test_idle_lane_falls_through_to_go
test_idle_healthy_lane_stays_free
test_spawn_falls_through_on_proven_cap
test_spawn_defaults_to_free
