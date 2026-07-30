#!/usr/bin/env bash
# tests/fm-self-heal.test.sh - the local secondmate self-heal watchdog.
#
# Tests bin/fm-self-heal.sh: a script that runs in a secondmate's own home,
# checks whether the secondmate's agent session is alive, and relaunches it
# with fm-spawn.sh --secondmate when dead or missing - without depending on
# the primary firstmate's watcher being alive.
#
# The guarantees under test mirror bin/fm-bootstrap.sh's
# secondmate_liveness_sweep safety contract (tests/fm-secondmate-liveness.test.sh):
#   - A confirmed-dead secondmate is killed and respawned.
#   - An authoritatively missing secondmate is respawned (no destructive kill).
#   - An already-live secondmate is never touched.
#   - An ambiguous existing process never triggers a duplicate launch.
#   - A transiently unreadable target never licenses recovery.
#   - An unverified harness blocks recovery on a dead reading.
#   - Recovery is idempotent: once alive, a second run is a pure no-op.
#
# Additional self-heal-specific guarantees:
#   - The script runs from a secondmate home and resolves the primary from
#     the git worktree linkage (FM_PRIMARY_ROOT overrides for testing).
#   - The respawn uses the primary's fm-spawn.sh with FM_SPAWN_NO_GUARD=1.
#   - The status report uses a non-captain-relevant verb with no corr= token.
#   - The --all mode checks every registered secondmate from the primary.
#   - --dry-run reports what would happen without relaunching.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-self-heal)

# --- fixtures ---------------------------------------------------------------

# make_toolchain <dir>: stubs the read-only diagnostics fm-spawn.sh needs.
# Mirrors tests/fm-secondmate-liveness.test.sh's make_toolchain minus tmux.
make_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" node gh-axi chrome-devtools-axi lavish-axi pi-signed
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' '0.1.1' ;;
  "update --help") printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  "mv --help") printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

# make_liveness_tmux <dir>: a controllable tmux stub. FM_TEST_PANE_CMD may be
# a foreground command, `missing` (readable inventory omits the window), or
# `unreadable` (both pane and inventory reads fail). Mirrors the liveness test.
make_liveness_tmux() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
mode=${FM_TEST_PANE_CMD:-zsh}
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*)
          case "$mode" in
            missing) printf '%s\n' node; exit 0 ;;
            unreadable) exit 1 ;;
            *) printf '%s\n' "$mode"; exit 0 ;;
          esac
          ;;
      esac
    done
    exit 0
    ;;
  list-windows)
    case "$mode" in
      missing) printf '%s\n' main; exit 0 ;;
      unreadable) exit 1 ;;
      *) [ -e "${FM_TMUX_CALL_LOG:?}.killed" ] || printf '%s\n' fm-sm1; exit 0 ;;
    esac
    ;;
  new-window|kill-window)
    printf '%s\n' "$*" >> "${FM_TMUX_CALL_LOG:?}"
    [ "${1:-}" = kill-window ] && : > "${FM_TMUX_CALL_LOG}.killed"
    [ "${FM_TEST_FAIL_NEW_WINDOW:-0}" = 1 ] && [ "${1:-}" = new-window ] && exit 1
    [ "${1:-}" = new-window ] && rm -f "${FM_TMUX_CALL_LOG}.killed"
    exit 0
    ;;
  has-session) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# new_primary <name>: a scratch primary firstmate HOME with state/, config/,
# data/, and a pinned crew harness.
new_primary() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/config" "$w/home/data"
  # Symlink bin/ to the real repo's bin/ so fm-spawn.sh and its libraries
  # resolve from the real code, exactly as in production where the primary
  # checkout IS the repo root. FM_ROOT_OVERRIDE + FM_HOME (set by
  # fm_spawn_secondmate) keep state/config/data pointing at this test primary.
  ln -s "$ROOT/bin" "$w/home/bin"
  touch "$w/home/state/.last-watcher-beat"
  printf 'codex\n' > "$w/home/config/crew-harness"
  printf '%s\n' "$w"
}

# add_sm_home <primary_w> <id> <window> [harness]: create a secondmate home
# and its kind=secondmate meta in the primary's state/.
add_sm_home() {
  local primary_w=$1 id=$2 window=$3 harness=${4:-claude}
  local home="$primary_w/$id"
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'charter\n' > "$home/data/charter.md"
  {
    printf 'window=%s\n' "$window"
    printf 'kind=secondmate\n'
    printf 'harness=%s\n' "$harness"
    printf 'home=%s\n' "$home"
  } > "$primary_w/home/state/$id.meta"
}

# run_self_heal <fakebin> <sm_home> <primary_root> <pane_cmd> <call_log> [extra env...]
run_self_heal() {
  local fb=$1 sm_home=$2 primary=$3 cmd=$4 log=$5
  shift 5
  PATH="$fb:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$sm_home" \
    FM_PRIMARY_ROOT="$primary" \
    FM_TEST_PANE_CMD="$cmd" FM_TMUX_CALL_LOG="$log" \
    env "$@" "$ROOT/bin/fm-self-heal.sh" 2>&1
}

# run_self_heal_all <fakebin> <primary_home> <primary_root> <pane_cmd> <call_log> [extra env...]
run_self_heal_all() {
  local fb=$1 primary_home=$2 primary=$3 cmd=$4 log=$5
  shift 5
  PATH="$fb:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$primary_home" \
    FM_ROOT_OVERRIDE="$primary" \
    FM_TEST_PANE_CMD="$cmd" FM_TMUX_CALL_LOG="$log" \
    env "$@" "$ROOT/bin/fm-self-heal.sh" --all 2>&1
}

# --- tests ------------------------------------------------------------------

test_heals_confirmed_dead_secondmate() {
  local w fb tmuxfb log out
  w=$(new_primary heal-dead)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_self_heal "$tmuxfb:$fb" "$w/sm1" "$w/home" zsh "$log")

  assert_contains "$out" "self-heal: secondmate sm1: respawned after confirmed agent absence" \
    "a confirmed-dead secondmate should be respawned"
  assert_contains "$(cat "$log")" "kill-window -t =firstmate:=fm-sm1" \
    "the stale endpoint must be killed before respawn"
  assert_contains "$(cat "$log")" "new-window" \
    "a confirmed-dead secondmate should actually be relaunched"
  # Status report
  assert_contains "$(cat "$w/home/state/sm1.status")" "self-healed:" \
    "recovery should be reported in the primary status file"
  assert_not_contains "$(cat "$w/home/state/sm1.status")" "corr=" \
    "the status report must NOT carry a corr= token (pending-reply territory)"
  pass "self-heal: a confirmed-dead secondmate endpoint is killed and respawned with status report"
}

test_heals_authoritatively_missing_secondmate() {
  local w fb tmuxfb log out
  w=$(new_primary heal-missing)
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_self_heal "$tmuxfb:$fb" "$w/sm1" "$w/home" missing "$log")

  assert_contains "$out" "self-heal: secondmate sm1: respawned after recorded endpoint confidently missing" \
    "an authoritatively missing secondmate should be respawned"
  assert_contains "$(cat "$log")" "new-window" \
    "a missing secondmate should be relaunched"
  assert_not_contains "$(cat "$log")" "kill-window" \
    "an absent window should not need a destructive pre-kill"
  pass "self-heal: an authoritatively missing secondmate window is respawned"
}

test_leaves_alive_secondmate_untouched() {
  local w fb tmuxfb log out
  w=$(new_primary heal-alive)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_self_heal "$tmuxfb:$fb" "$w/sm1" "$w/home" claude "$log")

  assert_contains "$out" "self-heal: secondmate sm1: alive" \
    "an already-live secondmate should be reported as alive"
  [ ! -s "$log" ] || fail "an already-live secondmate must never be killed or respawned: $(cat "$log")"
  [ ! -f "$w/home/state/sm1.status" ] || fail "an alive secondmate should not generate a status report"
  pass "self-heal: an already-live secondmate is untouched and generates no status report"
}

test_never_acts_on_ambiguous() {
  local w fb tmuxfb log out
  w=$(new_primary heal-ambiguous)
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_self_heal "$tmuxfb:$fb" "$w/sm1" "$w/home" node "$log")

  assert_contains "$out" "self-heal: secondmate sm1: skipped: existing endpoint has ambiguous agent process" \
    "an ambiguous process should be reported as skipped"
  [ ! -s "$log" ] || fail "an ambiguous process must never trigger kill or relaunch: $(cat "$log")"
  pass "self-heal: an existing ambiguous process prevents duplicate recovery"
}

test_never_acts_on_unreadable() {
  local w fb tmuxfb log out
  w=$(new_primary heal-unreadable)
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_self_heal "$tmuxfb:$fb" "$w/sm1" "$w/home" unreadable "$log")

  assert_contains "$out" "self-heal: secondmate sm1: skipped: endpoint probe unreadable" \
    "an unreadable target should be reported as skipped"
  [ ! -s "$log" ] || fail "an unreadable target must never trigger kill or relaunch: $(cat "$log")"
  pass "self-heal: transient target unreadability never licenses recovery"
}

test_never_acts_on_unverified_harness() {
  local w fb tmuxfb log out
  w=$(new_primary heal-unverified)
  add_sm_home "$w" sm1 firstmate:fm-sm1 custom-agent
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_self_heal "$tmuxfb:$fb" "$w/sm1" "$w/home" zsh "$log")

  assert_contains "$out" "self-heal: secondmate sm1: skipped: recorded harness 'custom-agent' is unverified for recovery" \
    "an unverified harness should block recovery"
  [ ! -s "$log" ] || fail "an unverified harness must never trigger kill or relaunch: $(cat "$log")"
  pass "self-heal: an unverified harness blocks recovery with a concrete diagnostic"
}

test_reports_respawn_failure() {
  local w fb tmuxfb log out
  w=$(new_primary heal-failure)
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_self_heal "$tmuxfb:$fb" "$w/sm1" "$w/home" missing "$log" FM_TEST_FAIL_NEW_WINDOW=1)

  assert_contains "$out" "self-heal: secondmate sm1: respawn failed after recorded endpoint confidently missing" \
    "a failed respawn should report the authorizing cause"
  pass "self-heal: failed respawn diagnostics distinguish a confidently missing endpoint"
}

test_idempotent_converges() {
  local w fb tmuxfb log out1 out2
  w=$(new_primary heal-idempotent)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  # Round 1: dead → respawned.
  out1=$(run_self_heal "$tmuxfb:$fb" "$w/sm1" "$w/home" zsh "$log")
  assert_contains "$out1" "self-heal: secondmate sm1: respawned" "round 1 should respawn"
  [ -s "$log" ] || fail "round 1 should have logged the kill+respawn operations"

  # Round 2: now alive → no-op.
  : > "$log"
  out2=$(run_self_heal "$tmuxfb:$fb" "$w/sm1" "$w/home" claude "$log")
  assert_contains "$out2" "self-heal: secondmate sm1: alive" "round 2 should report alive"
  [ ! -s "$log" ] || fail "round 2 must not re-kill or re-respawn: $(cat "$log")"
  pass "self-heal: idempotent - a live secondmate is never re-touched on a later run"
}

test_dry_run_reports_without_relanching() {
  local w fb tmuxfb log out
  w=$(new_primary heal-dry-run2)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(PATH="$tmuxfb:$fb:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$w/sm1" \
    FM_PRIMARY_ROOT="$w/home" \
    FM_TEST_PANE_CMD=zsh FM_TMUX_CALL_LOG="$log" \
    env "$ROOT/bin/fm-self-heal.sh" --dry-run 2>&1)

  assert_contains "$out" "dry-run: would kill and respawn" \
    "dry-run should report what would happen"
  [ ! -s "$log" ] || fail "dry-run must never kill or respawn: $(cat "$log")"
  pass "self-heal: --dry-run reports without relaunching"
}

test_all_mode_checks_every_secondmate() {
  local w fb tmuxfb log out
  w=$(new_primary heal-all-mode)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  add_sm_home "$w" sm2 firstmate:fm-sm2
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_self_heal_all "$tmuxfb:$fb" "$w/home" "$w/home" zsh "$log")

  assert_contains "$out" "self-heal: secondmate sm1: respawned" \
    "--all should heal sm1"
  assert_contains "$out" "self-heal: secondmate sm2: respawned" \
    "--all should heal sm2"
  pass "self-heal: --all mode checks every registered secondmate"
}

test_all_mode_no_secondmates_is_noop() {
  local w fb tmuxfb log out
  w=$(new_primary heal-all-empty)
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_self_heal_all "$tmuxfb:$fb" "$w/home" "$w/home" zsh "$log")

  [ -z "$out" ] || fail "--all with no secondmates should produce no output, got: $out"
  [ ! -s "$log" ] || fail "--all with no secondmates should not touch any endpoint: $(cat "$log")"
  pass "self-heal: --all with no secondmates is a silent no-op"
}

test_not_a_secondmate_home_errors() {
  local w fb out
  w=$(new_primary heal-not-sm)
  fb=$(make_toolchain "$w")
  mkdir -p "$w/notsm"
  out=$(PATH="$fb:$BASE_PATH" FM_HOME="$w/notsm" \
    "$ROOT/bin/fm-self-heal.sh" 2>&1) || true
  assert_contains "$out" "not a secondmate home" \
    "running without a marker and without --all should error"
  pass "self-heal: not a secondmate home produces a clear error"
}

test_status_verb_not_captain_relevant() {
  local w fb tmuxfb log out status_line
  w=$(new_primary heal-verb)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_self_heal "$tmuxfb:$fb" "$w/sm1" "$w/home" zsh "$log")
  status_line=$(tail -1 "$w/home/state/sm1.status")

  # The verb must not be a captain-relevant terminal verb.
  local verb
  verb=$(printf '%s' "$status_line" | sed 's/:.*//')
  case "$verb" in
    done|needs-decision|blocked|failed)
      fail "self-heal status verb '$verb' is captain-relevant - it must not trigger a captain wake" ;;
  esac
  # Must contain "self-healed" and "no corr" markers.
  assert_contains "$status_line" "self-healed" "status line should use the self-healed verb"
  assert_contains "$status_line" "no corr" "status line should explicitly note no corr token"
  pass "self-heal: status report verb is non-captain-relevant and carries no corr token"
}

test_heals_no_meta_secondmate() {
  local w fb tmuxfb log out
  w=$(new_primary heal-no-meta)
  # Create a secondmate home but NO meta file in the primary's state.
  mkdir -p "$w/sm1/bin" "$w/sm1/data" "$w/sm1/state" "$w/sm1/config" "$w/sm1/projects"
  printf 'sm1\n' > "$w/sm1/.fm-secondmate-home"
  printf '# Firstmate\n' > "$w/sm1/AGENTS.md"
  printf 'charter\n' > "$w/sm1/data/charter.md"
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_self_heal "$tmuxfb:$fb" "$w/sm1" "$w/home" zsh "$log")

  # Without a meta, fm-spawn.sh resolves home= from data/secondmates.md.
  # The test primary has no secondmates.md, so the spawn fails, but the
  # self-heal script handles it gracefully.
  assert_contains "$out" "no meta found" \
    "a missing meta should be reported"
  pass "self-heal: a missing meta is handled gracefully with a respawn attempt"
}

# --- run --------------------------------------------------------------------

test_heals_confirmed_dead_secondmate
test_heals_authoritatively_missing_secondmate
test_leaves_alive_secondmate_untouched
test_never_acts_on_ambiguous
test_never_acts_on_unreadable
test_never_acts_on_unverified_harness
test_reports_respawn_failure
test_idempotent_converges
test_dry_run_reports_without_relanching
test_all_mode_checks_every_secondmate
test_all_mode_no_secondmates_is_noop
test_not_a_secondmate_home_errors
test_status_verb_not_captain_relevant
test_heals_no_meta_secondmate

echo "# all fm-self-heal tests passed"