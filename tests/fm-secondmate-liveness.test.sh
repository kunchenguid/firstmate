#!/usr/bin/env bash
# tests/fm-secondmate-liveness.test.sh - the session-start secondmate LIVENESS
# guarantee: bin/fm-backend.sh's fm_backend_agent_alive probe (dispatching to
# the verified Herdr classifier) and
# bin/fm-bootstrap.sh's secondmate_liveness_sweep() that acts on it.
#
# The gap under test (AGENTS.md "Session start"; evidence 2026-07-07): a
# secondmate agent that has exited leaves its backend endpoint alive as a bare
# shell. fm_backend_target_exists only checks pane PRESENCE, so it reports
# that shell "alive"; recovery only respawns endpoints reported dead, and the
# watcher deliberately exempts secondmates from stale-pane detection (an idle
# secondmate pane is healthy by design). A dead-shell secondmate was therefore
# invisible to every existing check and sat dead indefinitely.
#
# The guarantees under test:
#   - fm_backend_herdr_agent_alive is a thin wrapper over the already-verified
#     fm_backend_herdr_pane_agent_state husk classifier: dead/no-agent -> dead,
#     live -> alive, unknown -> unknown.
#   - fm_backend_agent_alive routes to the right per-backend classifier and
#     reports unknown for a backend with no verified classifier (never errors).
#   - bin/fm-bootstrap.sh's secondmate_liveness_sweep respawns a confidently
#     DEAD secondmate (killing the stale endpoint before relaunch), leaves
#     an ALIVE one untouched, and never acts on an inconclusive (UNKNOWN)
#     reading.
#   - The sweep converges: once a secondmate reads alive, a later run never
#     re-touches it (idempotent by construction, not by remembering what it
#     already did).
#   - The sweep is skipped entirely under FM_BOOTSTRAP_DETECT_ONLY=1 (the
#     read-only session path), matching the other mutating sweeps.
#   - The sweep is naturally scoped to the primary: with no kind=secondmate
#     meta present (a secondmate's own state/ never holds one, since
#     secondmates never spawn secondmates), it is a silent no-op.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-secondmate-liveness)

# --- unit level: semantic Herdr agent liveness ---

test_herdr_agent_alive_maps_pane_agent_state() {
  local out

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "dead"; }; fm_backend_herdr_agent_alive "sess:p1"' "$ROOT")
  [ "$out" = dead ] || fail "herdr pane_agent_state=dead should map to dead, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "no-agent"; }; fm_backend_herdr_agent_alive "sess:p1"' "$ROOT")
  [ "$out" = dead ] || fail "herdr pane_agent_state=no-agent (restored bare shell) should map to dead, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "live"; }; fm_backend_herdr_agent_alive "sess:p1"' "$ROOT")
  [ "$out" = alive ] || fail "herdr pane_agent_state=live should map to alive, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "unknown"; }; fm_backend_herdr_agent_alive "sess:p1"' "$ROOT")
  [ "$out" = unknown ] || fail "herdr pane_agent_state=unknown should stay unknown, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_agent_alive "no-colon-target"' "$ROOT")
  [ "$out" = unknown ] || fail "an unparseable target should classify as unknown, got '$out'"

  pass "fm_backend_herdr_agent_alive: dead/no-agent->dead, live->alive, unknown->unknown"
}

# --- unit level: the generic fm_backend_agent_alive dispatcher --------------

test_agent_alive_dispatcher_routes_and_falls_back() {
  local out
  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_herdr_pane_agent_state() { printf "live"; }; fm_backend_agent_alive herdr sess:p1' "$ROOT")
  [ "$out" = alive ] || fail "dispatcher should route herdr to fm_backend_herdr_agent_alive, got '$out'"

  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive zellij sess:win' "$ROOT")
  [ "$out" = unknown ] || fail "dispatcher should report unknown for a backend with no verified classifier, got '$out'"

  pass "fm_backend_agent_alive: routes Herdr correctly and returns unknown for an unverified backend"
}

# --- sweep level: bin/fm-bootstrap.sh's secondmate_liveness_sweep -----------

make_toolchain() {  # <dir> -> fakebin
  local dir=$1 fakebin jq_bin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" node gh-axi chrome-devtools-axi lavish-axi quota-axi tasks-axi
  fm_test_write_basic_herdr "$fakebin/herdr"
  jq_bin=$(command -v jq)
  ln -s "$jq_bin" "$fakebin/jq"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
fi
exit 0
SH
  chmod +x "$fakebin/gh" "$fakebin/treehouse" "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

new_world() {  # <name>
  local world="$TMP_ROOT/$1"
  mkdir -p "$world/home/state" "$world/home/config"
  touch "$world/home/state/.last-watcher-beat"
  printf 'codex\n' > "$world/home/config/crew-harness"
  printf '%s\n' "$world"
}

add_secondmate_home() {  # <world> <id> [harness]
  local world=$1 id=$2 harness=${3:-codex} home="$1/$2"
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'charter\n' > "$home/data/charter.md"
  fm_write_meta "$world/home/state/$id.meta" \
    "window=default:w1:p1" \
    "kind=secondmate" \
    "harness=$harness" \
    "home=$home"
}

run_bootstrap() {  # <fakebin> <home> <agent-mode> <call-log> [extra env...]
  local fakebin=$1 home=$2 mode=$3 call_log=$4
  shift 4
  env PATH="$fakebin:$BASE_PATH" \
    FM_BACKEND=herdr FM_HOME="$home" \
    FM_FAKE_HERDR_AGENT_MODE="$mode" \
    FM_FAKE_HERDR_AGENT_STATUS="${FM_FAKE_HERDR_AGENT_STATUS:-working}" \
    FM_HERDR_CALL_LOG="$call_log" \
    "$@" "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

test_sweep_respawns_confirmed_dead_secondmate() {
  local world fakebin log out
  world=$(new_world sweep-dead)
  add_secondmate_home "$world" sm1
  fakebin=$(make_toolchain "$world")
  log="$world/herdr.calls"
  : > "$log"

  out=$(run_bootstrap "$fakebin" "$world/home" missing "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: respawned" \
    "a confirmed agent-less Herdr pane should be respawned"
  assert_grep "pane close w1:p1" "$log" "the stale Herdr pane was not closed before relaunch"
  assert_grep "tab create" "$log" "the confirmed-dead secondmate was not relaunched"
  pass "sweep: a confirmed-dead Herdr secondmate is closed and respawned"
}

test_sweep_leaves_alive_secondmate_untouched() {
  local world fakebin log out
  world=$(new_world sweep-alive)
  add_secondmate_home "$world" sm1
  fakebin=$(make_toolchain "$world")
  log="$world/herdr.calls"
  : > "$log"

  out=$(FM_FAKE_HERDR_AGENT_STATUS=idle run_bootstrap "$fakebin" "$world/home" live "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: already-live" \
    "a registered idle Herdr agent should remain live"
  assert_no_grep "pane close" "$log" "an already-live secondmate pane was closed"
  assert_no_grep "tab create" "$log" "an already-live secondmate was relaunched"
  pass "sweep: an already-live Herdr secondmate is untouched"
}

test_sweep_never_acts_on_inconclusive_reading() {
  local world fakebin log out
  world=$(new_world sweep-unknown)
  add_secondmate_home "$world" sm1
  fakebin=$(make_toolchain "$world")
  log="$world/herdr.calls"
  : > "$log"

  out=$(run_bootstrap "$fakebin" "$world/home" malformed "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: liveness probe inconclusive" \
    "an unparseable Herdr response should stay inconclusive"
  assert_no_grep "pane close" "$log" "an inconclusive read closed a pane"
  assert_no_grep "tab create" "$log" "an inconclusive read relaunched a secondmate"
  pass "sweep: an inconclusive Herdr reading is never acted on"
}

test_sweep_never_acts_on_unverified_harness() {
  local world fakebin log out
  world=$(new_world sweep-unverified)
  add_secondmate_home "$world" sm1 custom-agent
  fakebin=$(make_toolchain "$world")
  log="$world/herdr.calls"
  : > "$log"

  out=$(run_bootstrap "$fakebin" "$world/home" missing "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: liveness probe inconclusive" \
    "an unverified harness should make a dead-looking pane inconclusive"
  assert_no_grep "pane close" "$log" "an unverified harness allowed pane cleanup"
  assert_no_grep "tab create" "$log" "an unverified harness allowed relaunch"
  pass "sweep: an unverified harness cannot authorize respawn"
}

test_sweep_skipped_under_detect_only() {
  local world fakebin log out
  world=$(new_world sweep-detect-only)
  add_secondmate_home "$world" sm1
  fakebin=$(make_toolchain "$world")
  log="$world/herdr.calls"
  : > "$log"

  out=$(run_bootstrap "$fakebin" "$world/home" missing "$log" FM_BOOTSTRAP_DETECT_ONLY=1)

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "detect-only bootstrap ran the mutating liveness sweep"
  assert_no_grep "pane close" "$log" "detect-only bootstrap closed a pane"
  assert_no_grep "tab create" "$log" "detect-only bootstrap relaunched a secondmate"
  pass "sweep: detect-only bootstrap never runs secondmate liveness mutation"
}

test_sweep_noop_without_secondmates() {
  local world fakebin log out
  world=$(new_world sweep-empty)
  fakebin=$(make_toolchain "$world")
  log="$world/herdr.calls"
  : > "$log"

  out=$(run_bootstrap "$fakebin" "$world/home" missing "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "a home without secondmate metadata emitted a liveness verdict"
  assert_no_grep "pane close" "$log" "an empty home closed a pane"
  assert_no_grep "tab create" "$log" "an empty home spawned a secondmate"
  pass "sweep: a home without secondmates is a silent no-op"
}

test_herdr_agent_alive_maps_pane_agent_state
test_agent_alive_dispatcher_routes_and_falls_back
test_sweep_respawns_confirmed_dead_secondmate
test_sweep_leaves_alive_secondmate_untouched
test_sweep_never_acts_on_inconclusive_reading
test_sweep_never_acts_on_unverified_harness
test_sweep_skipped_under_detect_only
test_sweep_noop_without_secondmates

echo "# all fm-secondmate-liveness tests passed"
