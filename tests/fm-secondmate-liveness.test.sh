#!/usr/bin/env bash
# tests/fm-secondmate-liveness.test.sh - the session-start secondmate liveness
# guarantee owned by bin/fm-backend.sh's detailed fm_backend_agent_state and
# bin/fm-bootstrap.sh's secondmate_liveness_sweep that acts on it.
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
#   - fm_backend_agent_state is the detailed owner that distinguishes alive,
#     dead, missing, ambiguous, unreadable, and unverified.
#   - The tmux classifier returns missing only after a readable session
#     inventory omits the exact window, regardless of display-message fallback.
#   - The Herdr classifier preserves the proven husk mapping while separating a
#     missing pane from an existing agent-less pane.
#   - fm_backend_agent_alive preserves the older three-state compatibility view.
#   - bin/fm-bootstrap.sh's secondmate_liveness_sweep recovers only dead or
#     missing endpoints, keeps successful recovery and already-live results
#     silent by default, and reports ambiguous and unreadable targets distinctly.
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
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-secondmate-liveness)

# --- unit level: fm_backend_tmux_agent_state --------------------------------

# make_probe_tmux <dir> <pane_current_command>: a fake tmux whose
# #{pane_current_command} display-message query answers with the fixed value;
# every other subcommand is a silent no-op success.
make_probe_tmux() {
  local dir=$1 comm=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  display-message)
    for a in "\$@"; do case "\$a" in *pane_current_command*) printf '%s\n' '$comm'; exit 0 ;; esac; done
    exit 0 ;;
  list-windows) printf '%s\n' win; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# make_failed_probe_tmux <dir> <inventory>: missing and present fail the pane
# read, while unreadable returns a misleading fallback node process but fails
# the inventory that must be authoritative.
make_failed_probe_tmux() {
  local dir=$1 inventory=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  display-message)
    [ '$inventory' = unreadable ] && { printf '%s\n' node; exit 0; }
    exit 1
    ;;
  list-windows)
    case '$inventory' in
      missing) printf '%s\n' main ; exit 0 ;;
      missing-session) printf '%s\n' "can't find session: sess" >&2; exit 1 ;;
      missing-server) printf '%s\n' "no server running on /tmp/tmux-test/default" >&2; exit 1 ;;
      missing-socket) printf '%s\n' "error connecting to /tmp/tmux-test/default (No such file or directory)" >&2; exit 1 ;;
      present) printf '%s\n' fm-sm1 ; exit 0 ;;
      *) printf '%s\n' "permission denied" >&2; exit 1 ;;
    esac
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_tmux_agent_state_classifies() {
  local fb out

  for harness in claude codex opencode grok kimi pi pi-signed pi-launcher Pi; do
    fb=$(make_probe_tmux "$TMP_ROOT/tmux-$harness" "$harness")
    out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win' "$ROOT")
    [ "$out" = alive ] || fail "a live $harness foreground process should classify as alive, got '$out'"
  done

  for shell in zsh bash -zsh; do
    fb=$(make_probe_tmux "$TMP_ROOT/tmux-${shell#-}" "$shell")
    out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win' "$ROOT")
    [ "$out" = dead ] || fail "a bare $shell foreground process should classify as dead, got '$out'"
  done

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-node" node)
  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win' "$ROOT")
  [ "$out" = ambiguous ] || fail "an existing node process should classify as ambiguous, got '$out'"
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive tmux sess:win' "$ROOT")" = unknown ] \
    || fail "the compatibility view must keep an existing node process unknown"

  fb=$(make_failed_probe_tmux "$TMP_ROOT/tmux-missing" missing)
  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:fm-sm1' "$ROOT")
  [ "$out" = missing ] || fail "a readable inventory omitting the target should classify as missing, got '$out'"
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive tmux sess:fm-sm1' "$ROOT")" = dead ] \
    || fail "the compatibility view should treat an authoritatively missing target as dead"

  for inventory in present unreadable; do
    fb=$(make_failed_probe_tmux "$TMP_ROOT/tmux-$inventory" "$inventory")
    out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:fm-sm1' "$ROOT")
    [ "$out" = unreadable ] || fail "a $inventory inventory case should stay unreadable, got '$out'"
  done

  for inventory in missing-session missing-server missing-socket; do
    fb=$(make_failed_probe_tmux "$TMP_ROOT/tmux-$inventory" "$inventory")
    out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:fm-sm1' "$ROOT")
    [ "$out" = missing ] || fail "a confirmed $inventory inventory failure should classify as missing, got '$out'"
  done

  pass "fm_backend_tmux_agent_state: separates live, dead, missing, ambiguous, and unreadable"
}

test_tmux_agent_state_rejects_malformed_targets_before_probe() {
  local fakebin marker target out
  fakebin=$(fm_fakebin "$TMP_ROOT/tmux-malformed")
  marker="$TMP_ROOT/tmux-malformed-called"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'called\n' > "$FM_TEST_TMUX_MARKER"
printf 'bash\n'
SH
  chmod +x "$fakebin/tmux"

  for target in sess sess: :win sess:win:extra; do
    out=$(PATH="$fakebin:$BASE_PATH" FM_TEST_TMUX_MARKER="$marker" \
      bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux "$1"' "$ROOT" "$target")
    [ "$out" = unreadable ] || fail "malformed tmux target '$target' should classify as unreadable, got '$out'"
    [ ! -e "$marker" ] || fail "malformed tmux target '$target' invoked tmux"
  done

  pass "fm_backend_tmux_agent_state: rejects malformed targets before probing tmux"
}

# --- unit level: fm_backend_herdr_agent_state -------------------------------

test_herdr_agent_state_preserves_husk_classifier() {
  local pane_state expected out

  # Pin the session server as running so an installed herdr on the host
  # cannot turn the unknown row into a stopped-server `missing`.
  for row in 'dead missing' 'no-agent dead' 'live alive' 'unknown unreadable'; do
    pane_state=${row%% *}
    expected=${row#* }
    out=$(FM_TEST_PANE_STATE="$pane_state" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "%s" "$FM_TEST_PANE_STATE"; }; fm_backend_herdr_server_running_state() { printf running; }; fm_backend_herdr_agent_state "sess:p1"' "$ROOT")
    [ "$out" = "$expected" ] || fail "Herdr pane state $pane_state should map to $expected, got '$out'"
  done

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_agent_state "no-colon-target"' "$ROOT")
  [ "$out" = unreadable ] || fail "an unparseable Herdr target should classify as unreadable, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "no-agent"; }; fm_backend_herdr_agent_alive "sess:p1"' "$ROOT")
  [ "$out" = dead ] || fail "the Herdr compatibility view should keep a no-agent husk dead, got '$out'"

  pass "fm_backend_herdr_agent_state: preserves missing/no-agent/live/unknown husk behavior"
}

# --- unit level: the generic dispatchers ------------------------------------

test_agent_state_dispatcher_and_compatibility() {
  local fb out

  fb=$(make_probe_tmux "$TMP_ROOT/dispatch-tmux" claude)
  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win' "$ROOT")
  [ "$out" = alive ] || fail "detailed dispatcher should route tmux, got '$out'"

  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_herdr_pane_agent_state() { printf "live"; }; fm_backend_agent_state herdr sess:p1' "$ROOT")
  [ "$out" = alive ] || fail "detailed dispatcher should route Herdr, got '$out'"

  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state zellij sess:7' "$ROOT")
  [ "$out" = unverified ] || fail "Zellij should remain unverified, got '$out'"
  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive zellij sess:7' "$ROOT")
  [ "$out" = unknown ] || fail "the compatibility dispatcher should map unverified to unknown, got '$out'"

  pass "fm_backend_agent_state: routes tmux/Herdr and keeps Zellij unverified"
}

# --- sweep level: bin/fm-bootstrap.sh's secondmate_liveness_sweep -----------

# make_toolchain <dir>: the fixed set of stubs bin/fm-bootstrap.sh's read-only
# diagnostics need to stay quiet (mirrors tests/fm-secondmate-sync.test.sh's
# make_fake_toolchain), MINUS tmux - callers add their own controllable tmux.
make_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" node chrome-devtools-axi pi-signed
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.80
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.29'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh-axi"
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
  printf '%s\n' 'no-mistakes version v1.46.0 (fake)'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' '0.2.6' ;;
  "update --help") printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  "mv --help") printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.51'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

# make_liveness_tmux <dir>: a controllable tmux stub. FM_TEST_PANE_CMD may be
# a foreground command, `missing` (readable inventory omits the window), or
# `unreadable` (both pane and inventory reads fail).
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

# new_world <name>: a scratch firstmate HOME (state/, watcher beacon, pinned
# harness) with no kind=secondmate meta yet. FM_ROOT is left to resolve
# naturally to the real checkout under test ($ROOT), exactly as production
# always has it - this sweep's own fm-spawn.sh invocation resolves the
# secondmate harness through $FM_ROOT/bin/fm-harness.sh, which only exists in
# the real tree. The harness is pinned because ambient own-harness detection is
# environment-dependent: interactive harness sessions expose markers or parent
# process names, while a plain pipeline shell can fall through to "unknown",
# which has no fm-spawn.sh launch template.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/config"
  touch "$w/home/state/.last-watcher-beat"
  printf 'codex\n' > "$w/home/config/crew-harness"
  printf '%s\n' "$w"
}

# add_sm_home <w> <id> <window>: a plain (non-git) secondmate home - the
# probe/respawn machinery under test never requires the home to be a real
# worktree; a non-git home just makes the unrelated fast-forward sweep log a
# harmless "not a git repo" skip.
add_sm_home() {
  local w=$1 id=$2 window=$3 harness=${4:-claude}
  local home="$w/$id"
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'charter\n' > "$home/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$home/.gitignore"
  git -C "$home" init -q -b main
  {
    printf 'window=%s\n' "$window"
    printf 'kind=secondmate\n'
    printf 'harness=%s\n' "$harness"
    printf 'home=%s\n' "$home"
  } > "$w/home/state/$id.meta"
}

run_bootstrap() {  # <fakebin> <home> <pane-cmd> <call-log> [extra env...] -> stdout
  local fb=$1 home=$2 cmd=$3 log=$4; shift 4
  PATH="$fb:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$home" \
    FM_TEST_PANE_CMD="$cmd" FM_TMUX_CALL_LOG="$log" \
    env "$@" "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

test_sweep_respawns_confirmed_dead_secondmate() {
  local w fb tmuxfb log out
  w=$(new_world sweep-dead)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: respawned" \
    "a successfully respawned secondmate should be handled silently"
  assert_contains "$(cat "$log")" "kill-window -t =firstmate:=fm-sm1" \
    "the stale endpoint must be killed before respawn (tmux refuses a same-named window over a live one)"
  assert_contains "$(cat "$log")" "new-window" \
    "a confirmed-dead secondmate should actually be relaunched"
  assert_grep 'relaunched' "$w/home/state/.secondmate-relaunch-sm1" \
    "the shared library did not leave the durable per-mate relaunch record"
  pass "sweep: a confirmed-dead secondmate endpoint is killed and respawned"
}

test_sweep_skips_mate_whose_liveness_lock_is_held() {
  local w fb tmuxfb log out holder i=0
  w=$(new_world sweep-lock-held)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  # A concurrent liveness episode (the watcher's tick) owns the per-mate lock;
  # the sweep must skip rather than probe or relaunch a moving target.
  ( STATE="$w/home/state" bash -c \
      '. "$1" && fm_lock_acquire_wait "$2" && sleep 30' \
      _ "$ROOT/bin/fm-wake-lib.sh" "$w/home/state/.secondmate-liveness-sm1.lock" ) &
  holder=$!
  while [ ! -d "$w/home/state/.secondmate-liveness-sm1.lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -d "$w/home/state/.secondmate-liveness-sm1.lock" ] || fail "the fixture never acquired the liveness lock"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: another liveness check is already in progress" \
    "a mate under an active liveness lock should be skipped, not probed"
  [ ! -s "$log" ] || fail "a locked mate must never be killed or respawned: $(cat "$log")"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "sweep: a mate mid-episode under the shared liveness lock is skipped entirely"
}

test_sweep_refuses_relaunch_on_ledger_errors() {
  local w fb tmuxfb log out mode ledger word
  if [ "$(id -u)" -eq 0 ]; then
    pass "sweep: ledger permission errors skipped (root ignores file modes)"
    return 0
  fi
  for mode in 200 444; do
    case "$mode" in 200) word=unreadable ;; *) word=unwritable ;; esac
    w=$(new_world "sweep-ledger-$mode")
    add_sm_home "$w" sm1 firstmate:fm-sm1
    fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
    log="$w/calls.log"; : > "$log"
    ledger="$w/home/state/.secondmate-relaunch-sm1"
    : > "$ledger"
    chmod "$mode" "$ledger"

    out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")
    chmod 644 "$ledger"

    assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: relaunch ledger $ledger is $word" \
      "a mode-$mode relaunch ledger should skip the relaunch with its reason"
    [ ! -s "$log" ] || fail "a mode-$mode relaunch ledger still killed or spawned: $(cat "$log")"
    [ ! -s "$ledger" ] || fail "a mode-$mode ledger gained rows: $(cat "$ledger")"
  done
  pass "sweep: an unreadable or unwritable relaunch ledger refuses to kill or spawn"
}

test_sweep_leaves_alive_secondmate_untouched() {
  local w fb tmuxfb log out
  w=$(new_world sweep-alive)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: already-live" \
    "an already-live secondmate should be handled silently"
  [ ! -s "$log" ] || fail "an already-live secondmate must never be killed or respawned: $(cat "$log")"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log" FM_BOOTSTRAP_VERBOSE_FACTS=1)
  assert_contains "$out" "BOOTSTRAP_INFO: secondmate sm1 already live (backend=tmux)" \
    "verbose diagnostics should identify the already-live outcome"
  [ ! -s "$log" ] || fail "verbose reporting must not touch an already-live secondmate: $(cat "$log")"
  pass "sweep: an already-live secondmate is untouched and distinguishable in verbose diagnostics"
}

test_sweep_respawns_authoritatively_missing_pi_secondmate() {
  local w fb tmuxfb log out
  w=$(new_world sweep-missing-pi)
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" missing "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" "a successful missing-window recovery should stay silent by default"
  assert_contains "$(cat "$log")" "new-window" "an authoritatively missing Pi secondmate should be relaunched"
  assert_not_contains "$(cat "$log")" "kill-window" "an absent window should not need a destructive pre-kill"
  pass "sweep: an authoritatively missing Pi secondmate window is relaunched"
}

test_sweep_respawns_authoritatively_missing_pi_signed_secondmate() {
  local w fb tmuxfb log out
  w=$(new_world sweep-missing-pi-signed)
  printf '%s\n' pi-signed > "$w/home/config/secondmate-harness"
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi-signed
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" missing "$log")

  assert_not_contains "$out" "unverified for recovery" \
    "a recorded pi-signed secondmate should be verified for recovery"
  assert_contains "$(cat "$log")" "new-window" \
    "an authoritatively missing pi-signed secondmate should be relaunched"
  assert_not_contains "$(cat "$log")" "kill-window" \
    "an absent pi-signed window should not need a destructive pre-kill"
  pass "sweep: an authoritatively missing pi-signed secondmate window is relaunched"
}

test_sweep_never_acts_on_ambiguous_existing_process() {
  local w fb tmuxfb log out
  w=$(new_world sweep-ambiguous)
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" node "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: existing endpoint has ambiguous agent process" \
    "an existing Pi-shaped node process should be reported as ambiguous"
  [ ! -s "$log" ] || fail "an ambiguous existing process must never trigger kill or relaunch: $(cat "$log")"
  pass "sweep: an existing ambiguous Pi process prevents duplicate recovery"
}

test_sweep_never_acts_on_transient_unreadability() {
  local w fb tmuxfb log out
  w=$(new_world sweep-unreadable)
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" unreadable "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: endpoint probe unreadable" \
    "a transiently unreadable target should be distinguished from an absent one"
  [ ! -s "$log" ] || fail "an unreadable target must never trigger kill or relaunch: $(cat "$log")"
  pass "sweep: transient target unreadability never licenses recovery"
}

test_sweep_reports_missing_endpoint_relaunch_failure() {
  local w fb tmuxfb log out
  w=$(new_world sweep-missing-failure)
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" missing "$log" FM_TEST_FAIL_NEW_WINDOW=1)

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: respawn failed after recorded endpoint confidently missing" \
    "a failed missing-endpoint relaunch should retain its authorizing cause"
  pass "sweep: failed relaunch diagnostics distinguish a confidently missing endpoint"
}

test_sweep_never_acts_on_unverified_harness_dead_reading() {
  local w fb tmuxfb log out
  w=$(new_world sweep-unverified-harness)
  add_sm_home "$w" sm1 firstmate:fm-sm1 custom-agent
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: recorded harness 'custom-agent' is unverified for recovery" \
    "an unverified harness should not let a dead endpoint become actionable"
  [ ! -s "$log" ] || fail "an unverified harness must never trigger kill or relaunch: $(cat "$log")"
  pass "sweep: an unverified harness blocks recovery with a concrete diagnostic"
}

test_sweep_converges_no_retouch_once_alive() {
  local w fb tmuxfb log out1 out2
  w=$(new_world sweep-idempotent)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  # Round 1: dead -> respawned silently (kill + new-window logged).
  out1=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")
  assert_not_contains "$out1" "SECONDMATE_LIVENESS: secondmate sm1: respawned" "round 1 should handle the successful respawn silently"
  [ -s "$log" ] || fail "round 1 should have logged the kill+respawn window operations"

  # Round 2: the (now-respawned) secondmate is genuinely alive - a second
  # sweep must converge to a pure no-op, not respawn again.
  : > "$log"
  out2=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log")
  assert_not_contains "$out2" "SECONDMATE_LIVENESS: secondmate sm1: already-live" "round 2 should handle the already-live secondmate silently"
  [ ! -s "$log" ] || fail "round 2 must not re-kill or re-respawn an already-live secondmate: $(cat "$log")"
  pass "sweep: idempotent by construction - a live secondmate is never re-touched on a later run"
}

test_sweep_skipped_under_detect_only() {
  local w fb tmuxfb log out
  w=$(new_world sweep-detect-only)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  mkdir -p "$w/home/config"
  printf 'codex\n' > "$w/home/config/crew-harness"
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log" FM_BOOTSTRAP_DETECT_ONLY=1)

  assert_not_contains "$out" "CREW_HARNESS_OVERRIDE:" \
    "detect-only should keep routine harness facts silent"
  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "the read-only detect-only path must never run the mutating liveness sweep"
  [ ! -s "$log" ] || fail "detect-only must never touch any endpoint: $(cat "$log")"
  pass "sweep: skipped entirely under FM_BOOTSTRAP_DETECT_ONLY=1, exactly like the other mutating sweeps"
}

test_sweep_noop_with_no_secondmate_meta() {
  local w fb tmuxfb log out
  w=$(new_world sweep-no-secondmates)
  # No add_sm_home call: this state/ dir looks exactly like what a
  # secondmate's OWN home always has (secondmates never spawn secondmates),
  # proving the sweep's primary-only scoping falls out naturally.
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "with no kind=secondmate meta present, the sweep must print nothing"
  [ ! -s "$log" ] || fail "with no secondmate meta, no endpoint should ever be touched: $(cat "$log")"
  pass "sweep: a silent no-op with no kind=secondmate meta present (a secondmate home's own natural scoping)"
}

# --- library level: the watcher's poll-mode remote probe ---------------------
# bin/fm-secondmate-liveness-lib.sh's `poll` mode is the read-only probe the
# watcher tick runs per cadence: exactly one remote `state` call, `dead` and
# `missing` alone authorize relaunch, and transport failure (ssh exit 255) is
# never evidence of death. Full-mode remote readiness repair and route
# revalidation remain the startup sweep's own behavior, covered by the sweep
# tests above and tests/fm-remote-secondmate-lifecycle-e2e.test.sh.

# make_remote_probe_world <name>: a parent home carrying one remote-route
# secondmate meta plus a fake ssh that logs every call and answers with
# FM_FAKE_REMOTE_REPLY on FM_FAKE_REMOTE_RC. A `wedge-state` or `wedge-recover`
# call answers with FM_FAKE_WEDGE_REPLY (backslash escapes expanded) on
# FM_FAKE_WEDGE_RC instead, when either is set, so one probe can read `alive`
# from `state` and a separate verdict from the wedge verb.
make_remote_probe_world() {
  local name=$1 w fakebin
  w="$TMP_ROOT/$name"
  fakebin=$(fm_fakebin "$w")
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config"
  cat > "$w/home/state/rsm1.meta" <<EOF
window=remote:rsm1
kind=secondmate
harness=claude
remote_host=lab-host
remote_backend=herdr
remote_herdr_session=fm-remote
remote_target=fm-remote:w1:p1
home=/remote/rsm1-home
EOF
  cat > "$w/home/data/secondmates.md" <<EOF
- rsm1 - Remote mate (host: lab-host; root: /remote/root; home: /remote/rsm1-home; scope: remote work; projects: alpha; added 2026-01-01)
EOF
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_SSH_LOG:?}"
verb=$(printf '%s' "${!#}" | base64 -d 2>/dev/null | tr '\0' '\n' | sed -n '2p')
case "$verb" in
  wedge-state|wedge-recover)
    if [ -n "${FM_FAKE_WEDGE_REPLY:-}${FM_FAKE_WEDGE_RC:-}" ]; then
      [ -z "${FM_FAKE_WEDGE_REPLY:-}" ] || printf '%b\n' "$FM_FAKE_WEDGE_REPLY"
      exit "${FM_FAKE_WEDGE_RC:-0}"
    fi
    ;;
esac
[ -z "${FM_FAKE_REMOTE_REPLY:-}" ] || printf '%s\n' "$FM_FAKE_REMOTE_REPLY"
exit "${FM_FAKE_REMOTE_RC:-0}"
SH
  chmod +x "$fakebin/ssh"
  printf '%s\n' "$w"
}

# remote_verbs <ssh-log>: the control verb each logged remote call asked for.
# bin/fm-on.sh base64-encodes the NUL-separated remote argv, so the verb is the
# second field of the decoded last wire argument.
remote_verbs() {  # <ssh-log>
  local blob
  while read -r blob; do
    [ -n "$blob" ] || continue
    printf '%s' "$blob" | base64 -d 2>/dev/null | tr '\0' '\n' | sed -n '2p'
  done < <(awk 'NF { print $NF }' "$1")
}

# probe_remote <w> <mode> [env...] -> "<status>|<state>|<kill>|<cause>|<where>|<reason>"
probe_remote() {
  local w=$1 mode=$2; shift 2
  # shellcheck disable=SC2016 # positional params expand in the child shell.
  env STATE="$w/home/state" FM_HOME="$w/home" FM_DATA_OVERRIDE="$w/home/data" \
    FM_SSH_BIN="$w/fakebin/ssh" FM_FAKE_SSH_LOG="$w/ssh.log" "$@" \
    bash -c '
      . "$0/bin/fm-secondmate-liveness-lib.sh"
      fm_secondmate_liveness_probe "$1" rsm1 "$2"
      printf "%s|%s|%s|%s|%s|%s\n" \
        "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_STATE" "$FM_SM_LIVE_KILL" \
        "$FM_SM_LIVE_CAUSE" "$FM_SM_LIVE_WHERE" "$FM_SM_LIVE_REASON"
    ' "$ROOT" "$w/home/state/rsm1.meta" "$mode"
}

test_remote_poll_probe_maps_states() {
  local w out
  w=$(make_remote_probe_world probe-states)

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_REPLY=dead)
  [ "$out" = 'relaunchable|dead|0|remote endpoint dead on its configured host|host=lab-host|' ] \
    || fail "a dead remote reply should authorize relaunch on its own host, got: $out"

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_REPLY=missing)
  [ "$out" = 'relaunchable|missing|0|remote endpoint missing on its configured host|host=lab-host|' ] \
    || fail "a missing remote reply should authorize relaunch on its own host, got: $out"

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_REPLY=alive)
  [ "$out" = 'alive|alive|0|||' ] || fail "an alive remote reply should be a quiet no-op, got: $out"

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_REPLY=ambiguous)
  [ "$out" = 'skipped|ambiguous|0|||remote endpoint state is ambiguous on lab-host' ] \
    || fail "an ambiguous remote reply must preserve the endpoint, got: $out"

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_REPLY=unverified)
  [ "$out" = 'skipped|unverified|0|||remote endpoint state is unverified on lab-host' ] \
    || fail "an unverified remote reply must preserve the endpoint, got: $out"

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_REPLY=bogus)
  [ "$out" = 'skipped|bogus|0|||remote endpoint returned an invalid state' ] \
    || fail "an invalid remote reply must preserve the endpoint, got: $out"

  # Six probes, seven calls: every verdict costs exactly one remote state call,
  # and the `alive` one spends a second to ask the mate's own host whether that
  # liveness is real (the wedge probe). An inconclusive or dead reading never
  # pays for the extra read.
  [ "$(wc -l < "$w/ssh.log" | tr -d ' ')" -eq 7 ] \
    || fail "each poll-mode probe should spend one remote state call, plus one wedge probe on the alive reading: $(cat "$w/ssh.log")"
  # The transport base64-encodes the remote argv, so the verb is read back by
  # decoding it rather than by matching the wire line.
  [ "$(remote_verbs "$w/ssh.log" | grep -c '^wedge-state$')" -eq 1 ] \
    || fail "only the alive reading should spend a wedge probe: $(remote_verbs "$w/ssh.log")"
  [ "$(remote_verbs "$w/ssh.log" | grep -c '^state$')" -eq 6 ] \
    || fail "every probe should still spend exactly one state call: $(remote_verbs "$w/ssh.log")"
  pass "poll probe: remote states map to the same contract as local, one call each plus the alive wedge probe"
}

test_remote_poll_probe_unreachable_preserves_route() {
  local w out
  w=$(make_remote_probe_world probe-unreachable)

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_RC=255)
  [ "$out" = 'skipped|unknown|0|||remote host unavailable or endpoint state unknown; route preserved on lab-host' ] \
    || fail "ssh exit 255 must never read as a dead endpoint, got: $out"

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_RC=1)
  [ "$out" = 'skipped|unknown|0|||remote endpoint probe unreadable on lab-host' ] \
    || fail "a non-transport remote probe failure must stay inconclusive, got: $out"
  pass "poll probe: unreachable or inconclusive remote reads preserve the route"
}

# remote_wedge_tripwire <w>: stubs for every local tool a pid could be derived
# or signalled with. Each logs to <w>/local-tools.log, so an empty log proves
# the parent never read a pane, a process table, or sent a signal on its own
# host: the remote mate's verdict and kill are its own host's business.
remote_wedge_tripwire() {  # <w>
  local w=$1 tool
  for tool in herdr ps pgrep pkill kill lsof sample; do
    cat > "$w/fakebin/$tool" <<SH
#!/usr/bin/env bash
printf '%s %s\\n' "$tool" "\$*" >> "$w/local-tools.log"
exit 1
SH
    chmod +x "$w/fakebin/$tool"
  done
}

test_remote_poll_probe_reports_a_wedged_mate_relaunchable() {
  local w out
  w=$(make_remote_probe_world probe-wedged)
  remote_wedge_tripwire "$w"

  out=$(probe_remote "$w" poll PATH="$w/fakebin:$PATH" FM_FAKE_REMOTE_REPLY=alive FM_FAKE_WEDGE_REPLY=wedged)
  [ "$out" = 'relaunchable|wedged|wedged|remote agent wedged: running but no progress for at least 900s|host=lab-host|' ] \
    || fail "a remote wedged verdict should make the mate relaunchable as wedged, got: $out"
  [ "$(remote_verbs "$w/ssh.log" | tr '\n' ' ')" = 'state wedge-state ' ] \
    || fail "the wedged probe should spend exactly one state and one wedge-state call: $(remote_verbs "$w/ssh.log")"

  # An unreachable wedge probe is never a verdict: the alive mate stays alive.
  : > "$w/ssh.log"
  out=$(probe_remote "$w" poll PATH="$w/fakebin:$PATH" FM_FAKE_REMOTE_REPLY=alive FM_FAKE_WEDGE_RC=255)
  [ "$out" = 'alive|alive|0|||' ] \
    || fail "an unreachable wedge probe must leave the alive mate alone, got: $out"
  [ ! -s "$w/local-tools.log" ] \
    || fail "the parent touched a local process tool for a remote mate: $(cat "$w/local-tools.log")"
  pass "poll probe: a remote wedged verdict is relaunchable as wedged, and an unreachable wedge probe is not"
}

# recover_remote <w> [env...] -> "<rc>|<capture>|<killed>|<reason>"
recover_remote() {
  local w=$1; shift
  # shellcheck disable=SC2016 # positional params expand in the child shell.
  env STATE="$w/home/state" FM_HOME="$w/home" FM_DATA_OVERRIDE="$w/home/data" \
    FM_SSH_BIN="$w/fakebin/ssh" FM_FAKE_SSH_LOG="$w/ssh.log" PATH="$w/fakebin:$PATH" "$@" \
    bash -c '
      . "$0/bin/fm-secondmate-liveness-lib.sh"
      rc=0
      fm_secondmate_liveness_wedge_recover "$1" rsm1 || rc=$?
      printf "%s|%s|%s|%s\n" "$rc" "${FM_SM_LIVE_WEDGE_CAPTURE:-}" \
        "${FM_SM_LIVE_WEDGE_KILLED:-}" "${FM_SM_LIVE_REASON:-}"
    ' "$ROOT" "$w/home/state/rsm1.meta"
}

test_remote_wedge_recover_runs_only_on_the_mates_own_host() {
  local w out ledger
  w=$(make_remote_probe_world recover-remote)
  remote_wedge_tripwire "$w"
  ledger="$w/home/state/.secondmate-relaunch-rsm1"

  out=$(recover_remote "$w" FM_FAKE_WEDGE_REPLY='capture=/remote/rsm1-home/state/.wedge-sample-rsm1-1\nkilled=4242')
  [ "$out" = '0|/remote/rsm1-home/state/.wedge-sample-rsm1-1|4242|' ] \
    || fail "remote recovery should parse the remote capture path and killed pids, got: $out"
  [ "$(awk -F '\t' '$2 == "wedge-capture" { print $3 }' "$ledger")" = /remote/rsm1-home/state/.wedge-sample-rsm1-1 ] \
    || fail "remote recovery should record the remote capture path in the relaunch ledger: $(cat "$ledger" 2>/dev/null)"
  [ "$(remote_verbs "$w/ssh.log" | tr '\n' ' ')" = 'wedge-recover ' ] \
    || fail "remote recovery must be exactly one wedge-recover control call: $(remote_verbs "$w/ssh.log")"

  : > "$w/ssh.log"
  out=$(recover_remote "$w" FM_FAKE_WEDGE_REPLY='no attributable agent process' FM_FAKE_WEDGE_RC=1)
  [ "$out" = '1|||wedged remote agent could not be recovered on lab-host: no attributable agent process; endpoint left running' ] \
    || fail "a failing remote recovery must refuse and preserve the endpoint, got: $out"

  out=$(recover_remote "$w" FM_FAKE_WEDGE_RC=255)
  case "$out" in
    '1|||wedged remote agent could not be recovered on lab-host: '*'; endpoint left running') ;;
    *) fail "an unreachable host must refuse the recovery and preserve the endpoint, got: $out" ;;
  esac
  [ "$(awk -F '\t' '$2 == "wedge-capture"' "$ledger" | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "a refused remote recovery must not record a capture: $(cat "$ledger")"
  [ ! -s "$w/local-tools.log" ] \
    || fail "the parent derived a pid or signalled locally for a remote mate: $(cat "$w/local-tools.log")"
  pass "wedge recover: a remote mate is captured and killed only by its own host's control verb, and a failed call preserves it"
}

test_tmux_agent_state_classifies
test_tmux_agent_state_rejects_malformed_targets_before_probe
test_herdr_agent_state_preserves_husk_classifier
test_agent_state_dispatcher_and_compatibility
test_sweep_respawns_confirmed_dead_secondmate
test_sweep_leaves_alive_secondmate_untouched
test_sweep_respawns_authoritatively_missing_pi_secondmate
test_sweep_respawns_authoritatively_missing_pi_signed_secondmate
test_sweep_never_acts_on_ambiguous_existing_process
test_sweep_never_acts_on_transient_unreadability
test_sweep_reports_missing_endpoint_relaunch_failure
test_sweep_never_acts_on_unverified_harness_dead_reading
test_sweep_converges_no_retouch_once_alive
test_sweep_skipped_under_detect_only
test_sweep_noop_with_no_secondmate_meta
test_sweep_skips_mate_whose_liveness_lock_is_held
test_sweep_refuses_relaunch_on_ledger_errors
test_remote_poll_probe_maps_states
test_remote_poll_probe_unreachable_preserves_route
test_remote_poll_probe_reports_a_wedged_mate_relaunchable
test_remote_wedge_recover_runs_only_on_the_mates_own_host

# --- wedged secondmate: detection, capture, kill scope, and bound ------------
# bin/fm-herdr-wedge-lib.sh adds the one liveness state the backend classifier
# cannot express: a Herdr-backed agent whose process is running and registered
# but which has stopped making progress.
#
# A wedged verdict needs three independent signals to agree, because each one
# alone has a legitimate quiet case: both Herdr progress counters unchanged
# (a long model response produces no new scrollback either), consumed CPU time
# unchanged (a frozen process burns none, a working one keeps accumulating it),
# and no live non-MCP child process (a long Bash command or subagent is a live
# child; the frozen process in the incident had none at all).
#
# The guarantees under test:
#   - a working pane that advances ANY of those signals stays alive;
#   - a working pane that advances none becomes wedged once the window has
#     actually elapsed as observed time, and not before;
#   - a gap between samples larger than the detector could have watched - a
#     suspended machine, a jumped clock - restarts the window instead of being
#     judged, so waking up does not kill live work;
#   - an idle, done, or blocked agent is never a wedge candidate;
#   - any unreadable signal yields `unreadable`, never `wedged`, so a vendor
#     shape change or an unreadable process table can only disable recovery;
#   - the session-start sweep only re-bases the window; the watcher's continuous
#     poll is the sole producer of a wedged verdict;
#   - the configured window has a floor and an `off` switch;
#   - evidence is captured BEFORE the kill and recorded in the relaunch ledger;
#   - the kill reaches only the pane's own agent process - never the pane shell,
#     never an agent-named process outside the pane's subtree;
#   - a wedged relaunch feeds the SAME attempt ledger the watcher's existing
#     relaunch bound counts, so a mis-detecting probe cannot kill-loop a mate.

# Fixture processes are real and long-lived, so they are tracked and reaped on
# exit rather than relying on each case's own teardown: a case that fails early
# would otherwise leave a `sleep 300` (or a busy loop) behind for the rest of
# the suite. tests/lib.sh owns the directory cleanup, so this trap chains to it.
WEDGE_PID_FILE="$TMP_ROOT/.wedge-pids"
: > "$WEDGE_PID_FILE"

wedge_track_pid() {  # <pid>
  printf '%s\n' "$1" >> "$WEDGE_PID_FILE"
}

wedge_reap_pids() {
  local p
  [ -f "$WEDGE_PID_FILE" ] || return 0
  while read -r p; do
    [ -n "$p" ] || continue
    pkill -P "$p" 2>/dev/null || true
    kill -KILL "$p" 2>/dev/null || true
  done < "$WEDGE_PID_FILE"
  : > "$WEDGE_PID_FILE"
}

trap 'wedge_reap_pids; fm_test_cleanup' EXIT

# The agent-named stand-in every process-level wedge case runs under a harness
# name. Empty when no stand-in survives a foreign name on this host, in which
# case those cases skip with a reason rather than fail.
WEDGE_STANDIN=$(fm_agent_standin "$TMP_ROOT/wedge-standin") || WEDGE_STANDIN=''

# make_wedge_herdr <dir>: a fake `herdr` answering the read-only calls the wedge
# path makes. Unlike the ordered-response fakes elsewhere, this one is keyed by
# subcommand and re-read on every call, because the classifier is deliberately
# called repeatedly across simulated watcher ticks.
#
# Files under <dir>: `status`, `seq`, `offset` drive `agent get` and
# `pane list`; `procinfo.json` is the `pane process-info` body; `fail-agent`
# and `fail-panes` make those reads fail; `drop-seq` and `drop-offset` omit one
# counter, which is how a vendor rename is simulated.
make_wedge_herdr() {
  local dir=$1 fakebin
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  printf 'working\n' > "$dir/status"
  printf '100\n' > "$dir/seq"
  printf '500\n' > "$dir/offset"
  printf '{}\n' > "$dir/procinfo.json"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
d=${FM_FAKE_WEDGE_DIR:?}
printf '%s\n' "$*" >> "$d/calls.log"
case "${1:-} ${2:-}" in
  "agent get")
    [ ! -e "$d/fail-agent" ] || exit 1
    if [ -e "$d/drop-seq" ]; then
      printf '{"result":{"agent":{"agent":"claude","agent_status":"%s"}}}\n' "$(cat "$d/status")"
    else
      printf '{"result":{"agent":{"agent":"claude","agent_status":"%s","state_change_seq":%s}}}\n' \
        "$(cat "$d/status")" "$(cat "$d/seq")"
    fi
    ;;
  "pane list")
    [ ! -e "$d/fail-panes" ] || exit 1
    # A sibling pane is listed first and carries its own scroll counter, so a
    # read that matched by position instead of pane_id would see the wrong one.
    if [ -e "$d/drop-offset" ]; then
      printf '{"result":{"panes":[{"pane_id":"w9:p9","scroll":{"max_offset_from_bottom":7}},{"pane_id":"w1:p2"}]}}\n'
    else
      printf '{"result":{"panes":[{"pane_id":"w9:p9","scroll":{"max_offset_from_bottom":7}},{"pane_id":"w1:p2","scroll":{"max_offset_from_bottom":%s}}]}}\n' \
        "$(cat "$d/offset")"
    fi
    ;;
  "pane get")
    # The pane structurally exists, so the ordinary backend classifier reaches
    # `live`/`alive` and the wedge probe is the thing under test.
    printf '{"result":{"pane":{"pane_id":"w1:p2"}}}\n'
    ;;
  "pane process-info") cat "$d/procinfo.json" ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$fakebin"
}

# make_wedge_ps <dir>: a `ps` shim that passes everything through to the real
# `ps` unless told to fail one specific read, or to answer the CPU-time column
# with FM_FAKE_PS_CPUTIME verbatim. That lets a fixture blind exactly one signal,
# or speak another platform's cputime format, and leave the others intact.
make_wedge_ps() {
  local dir=$1
  mkdir -p "$dir/psbin"
  cat > "$dir/psbin/ps" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" cputime= "*|*"cputime="*)
    [ -z "\${FM_FAKE_PS_FAIL_CPUTIME:-}" ] || exit 1
    [ -z "\${FM_FAKE_PS_CPUTIME:-}" ] || { printf '%s\\n' "\$FM_FAKE_PS_CPUTIME"; exit 0; }
    ;;
esac
case " \$* " in
  *"-axo"*) [ -z "\${FM_FAKE_PS_FAIL_TABLE:-}" ] || exit 1 ;;
esac
exec $(command -v ps) "\$@"
SH
  chmod +x "$dir/psbin/ps"
  printf '%s\n' "$dir/psbin/ps"
}

# attach_wedge_agent <dir> <frozen|tool-child|mcp-child|cpu-burn>: a REAL
# process shape for the pane, and the matching `pane process-info` body.
#
# The agent is a symlink to a real long-running binary so the kernel records
# `claude` as the executable identity, which is what fm-agent-process-lib.sh
# classifies on; copying a platform binary would fail code signing on macOS.
# Every sleeping stand-in is WEDGE_STANDIN, never the host `sleep`, because a
# multicall `sleep` exits at once under a foreign name.
# The pane shell runs a second command after the agent so it outlives it, which
# is what makes "the shell survived" a real assertion about the kill's scope.
#
#   frozen      the incident's shape: an agent burning no CPU with no children
#   tool-child  a healthy agent running a long, quiet tool command
#   mcp-child   an agent whose only child is one of its own MCP servers
#   cpu-burn    a healthy agent consuming CPU with nothing on screen
#
# Echoes "<shell-pid> <agent-pid>".
attach_wedge_agent() {  # <dir> <kind>
  local dir=$1 kind=$2 sleep_bin bash_bin lab shell_pid agent_pid i=0 comm body
  [ -n "$WEDGE_STANDIN" ] || fail "attach_wedge_agent needs an agent stand-in"
  sleep_bin=$(command -v sleep) || fail "sleep not found"
  bash_bin=$(command -v bash) || fail "bash not found"
  lab="$dir/agentbin"; mkdir -p "$lab"
  ln -sf "$WEDGE_STANDIN" "$lab/toolcmd"
  ln -sf "$WEDGE_STANDIN" "$lab/mcp-server-fs"
  case "$kind" in
    frozen) ln -sf "$WEDGE_STANDIN" "$lab/claude"; body="'$lab/claude' 300" ;;
    tool-child)
      ln -sf "$bash_bin" "$lab/claude"
      # The trailing `:` stops bash exec-optimizing the single command away, so
      # the agent really has a child.
      body="'$lab/claude' -c \"'$lab/toolcmd' 300; :\""
      ;;
    mcp-child)
      ln -sf "$bash_bin" "$lab/claude"
      body="'$lab/claude' -c \"'$lab/mcp-server-fs' 300; :\""
      ;;
    cpu-burn)
      ln -sf "$bash_bin" "$lab/claude"
      body="'$lab/claude' -c 'while :; do :; done'"
      ;;
    *) fail "unknown wedge agent kind: $kind" ;;
  esac
  sh -c "$body; '$sleep_bin' 300" >/dev/null 2>&1 &
  shell_pid=$!
  disown "$shell_pid" 2>/dev/null || true
  wedge_track_pid "$shell_pid"
  while [ "$i" -lt 200 ]; do
    for agent_pid in $(pgrep -P "$shell_pid" 2>/dev/null); do
      comm=$(LC_ALL=C ps -p "$agent_pid" -o comm= 2>/dev/null)
      case "${comm##*/}" in claude) break 2 ;; esac
    done
    agent_pid=''
    sleep 0.05
    i=$((i + 1))
  done
  [ -n "${agent_pid:-}" ] || fail "the $kind fixture never started its agent child"
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"claude","argv0":"claude","argv":["claude"],"cmdline":"claude"}]}}}\n' \
    "$shell_pid" "$agent_pid" "$agent_pid" > "$dir/procinfo.json"
  printf '%s %s\n' "$shell_pid" "$agent_pid"
}

# wedge_classify <dir> <state-dir> <window> <mode> [env...]: one classifier
# sample, run through the real adapter CLI wrapper exactly as production does.
wedge_classify() {
  local dir=$1 state=$2 window=$3 mode=$4 fakebin="$1/fakebin"
  shift 4
  # shellcheck disable=SC2016 # positional params expand in the child shell.
  env PATH="$fakebin:$BASE_PATH" FM_FAKE_WEDGE_DIR="$dir" FM_HOME="$state/.." "$@" \
    bash -c '
      . "$0/bin/fm-backend.sh"
      . "$0/bin/fm-herdr-wedge-lib.sh"
      fm_herdr_wedge_classify "$1" sm1 fmtest:w1:p2 "$2" "$3"
    ' "$ROOT" "$state" "$window" "$mode"
}

# wedge_age_window <state-dir> <secs>: push the recorded window start back by
# <secs> while leaving the last-sample epoch where it is, which is exactly the
# steady state a continuously sampling watcher produces. Ageing both fields
# would instead simulate the unobserved gap the suspend case covers.
wedge_age_window() {  # <state-dir> <secs>
  local record="$1/.secondmate-wedge-sm1"
  awk -F '\t' -v OFS='\t' -v back="$2" '{ $6 = $6 - back; print }' "$record" > "$record.aged" \
    && mv "$record.aged" "$record"
}

test_wedge_progress_on_any_signal_keeps_the_mate_alive() {
  local dir state out
  dir="$TMP_ROOT/wedge-progressing"; state="$dir/state"
  make_wedge_herdr "$dir" >/dev/null; mkdir -p "$state"
  attach_wedge_agent "$dir" frozen >/dev/null

  out=$(wedge_classify "$dir" "$state" 600 judge)
  [ "$out" = progressing ] || fail "the first sample should start the window, got '$out'"

  # state_change_seq advanced; the scroll counter did not. Either one moving is
  # progress, and this is the case a false positive would kill real work in: a
  # long model response produces no new scrollback.
  printf '101\n' > "$dir/seq"
  wedge_age_window "$state" 601
  out=$(wedge_classify "$dir" "$state" 600 judge)
  [ "$out" = progressing ] || fail "an advancing state_change_seq must read progressing, got '$out'"

  # The mirror case: scrollback grew while the status sequence did not.
  printf '501\n' > "$dir/offset"
  wedge_age_window "$state" 601
  out=$(wedge_classify "$dir" "$state" 600 judge)
  [ "$out" = progressing ] || fail "an advancing scroll counter must read progressing, got '$out'"

  # And the divergence that proves the window is really being measured: with
  # every signal frozen the very same fixture goes wedged.
  wedge_age_window "$state" 601
  out=$(wedge_classify "$dir" "$state" 600 judge)
  [ "$out" = wedged ] || fail "the control case must wedge once no signal moves, got '$out'"
  pass "wedge: a working pane advancing either progress counter is never wedged"
}

test_wedge_cpu_time_growth_keeps_the_mate_alive() {
  local dir state out
  dir="$TMP_ROOT/wedge-cpu"; state="$dir/state"
  make_wedge_herdr "$dir" >/dev/null; mkdir -p "$state"
  # A healthy agent that is thinking rather than printing: no new scrollback and
  # no status change, but it is consuming CPU the whole time.
  attach_wedge_agent "$dir" cpu-burn >/dev/null

  out=$(wedge_classify "$dir" "$state" 600 judge)
  [ "$out" = progressing ] || fail "the first sample should start the window, got '$out'"
  # Let the busy loop accumulate at least one more whole second of CPU time.
  sleep 2
  wedge_age_window "$state" 601
  out=$(wedge_classify "$dir" "$state" 600 judge)
  [ "$out" = progressing ] \
    || fail "rising CPU time must keep a quiet agent alive even past the window, got '$out'"
  pass "wedge: a working pane whose CPU time rises is never wedged, however quiet its output"
}

test_wedge_live_tool_child_keeps_the_mate_alive() {
  local dir state out
  dir="$TMP_ROOT/wedge-toolchild"; state="$dir/state"
  make_wedge_herdr "$dir" >/dev/null; mkdir -p "$state"
  # A healthy agent blocked waiting on one long, quiet tool command: its own
  # counters are frozen and it burns no CPU while it waits, so the live child is
  # the only thing that tells it apart from the incident's frozen process.
  attach_wedge_agent "$dir" tool-child >/dev/null

  wedge_classify "$dir" "$state" 600 judge >/dev/null
  wedge_age_window "$state" 601
  out=$(wedge_classify "$dir" "$state" 600 judge)
  [ "$out" = progressing ] \
    || fail "a live non-MCP child must keep a quiet agent alive past the window, got '$out'"
  pass "wedge: a working pane running a long quiet tool command is never wedged"
}

test_wedge_mcp_server_child_alone_still_wedges() {
  local dir state out
  dir="$TMP_ROOT/wedge-mcpchild"; state="$dir/state"
  make_wedge_herdr "$dir" >/dev/null; mkdir -p "$state"
  # The divergence that keeps the previous case honest: the SAME shape, with the
  # child being one of the agent's own MCP servers rather than tool work. An MCP
  # server lives for the whole session, so it is not evidence of progress.
  attach_wedge_agent "$dir" mcp-child >/dev/null

  wedge_classify "$dir" "$state" 600 judge >/dev/null
  wedge_age_window "$state" 601
  out=$(wedge_classify "$dir" "$state" 600 judge)
  [ "$out" = wedged ] \
    || fail "a frozen agent whose only child is its own MCP server must still wedge, got '$out'"
  pass "wedge: an MCP server child is not mistaken for live work, so the frozen shape still wedges"
}

test_wedge_unobserved_gap_restarts_the_window() {
  local dir state out record
  dir="$TMP_ROOT/wedge-suspend"; state="$dir/state"
  make_wedge_herdr "$dir" >/dev/null; mkdir -p "$state"
  attach_wedge_agent "$dir" frozen >/dev/null
  record="$state/.secondmate-wedge-sm1"

  wedge_classify "$dir" "$state" 600 judge >/dev/null
  # The suspend shape: the machine slept, so BOTH the window start and the last
  # sample this detector actually took are far in the past. The agent's counters
  # cannot have moved while it was frozen by the OS either, so wall-clock age
  # would read as wedged - and SIGKILL live work.
  awk -F '\t' -v OFS='\t' '{ $6 = $6 - 1800; $7 = $7 - 1800; print }' "$record" > "$record.aged" \
    && mv "$record.aged" "$record"
  out=$(wedge_classify "$dir" "$state" 600 judge)
  [ "$out" = progressing ] \
    || fail "a gap larger than the detector could have watched must restart the window, got '$out'"

  # Not vacuous: the identical fixture, with the window aged but the sampling
  # continuous, does wedge.
  wedge_age_window "$state" 601
  out=$(wedge_classify "$dir" "$state" 600 judge)
  [ "$out" = wedged ] \
    || fail "continuously observed frozen time must still wedge, got '$out'"
  pass "wedge: an unobserved gap (suspend or clock jump) restarts the window instead of killing live work"
}

test_wedge_sample_gap_follows_a_slow_watcher_cadence() {
  local dir state out record
  dir="$TMP_ROOT/wedge-slow-cadence"; state="$dir/state"
  make_wedge_herdr "$dir" >/dev/null; mkdir -p "$state"
  attach_wedge_agent "$dir" frozen >/dev/null
  record="$state/.secondmate-wedge-sm1"

  # A home ticking every 600 seconds samples 600 seconds apart by design. With
  # the fixed 300-second limit every one of those gaps would restart the window,
  # so a frozen mate could never be recovered there.
  wedge_classify "$dir" "$state" 600 judge FM_SECONDMATE_LIVENESS_SECS=600 >/dev/null
  awk -F '\t' -v OFS='\t' '{ $6 = $6 - 700; $7 = $7 - 650; print }' "$record" > "$record.aged" \
    && mv "$record.aged" "$record"
  out=$(wedge_classify "$dir" "$state" 600 judge FM_SECONDMATE_LIVENESS_SECS=600)
  [ "$out" = wedged ] \
    || fail "one ordinary tick of a slow cadence must count as observed time, got '$out'"

  # The control: the same gap at the default cadence is not observed time.
  wedge_classify "$dir" "$state" 600 baseline >/dev/null
  awk -F '\t' -v OFS='\t' '{ $6 = $6 - 700; $7 = $7 - 650; print }' "$record" > "$record.aged" \
    && mv "$record.aged" "$record"
  out=$(wedge_classify "$dir" "$state" 600 judge)
  [ "$out" = progressing ] \
    || fail "a 650s gap at the default cadence must restart the window, got '$out'"
  pass "wedge: the observed-sample gap widens with a slow watcher cadence instead of disabling recovery"
}

test_wedge_cpu_time_parses_both_platform_formats() {
  local dir psbin raw want out
  dir="$TMP_ROOT/wedge-cputime-formats"
  psbin=$(make_wedge_ps "$dir")
  # The real shapes `ps -o cputime=` prints: BSD/macOS `[HH:]MM:SS.CC` and Linux
  # procps `[DD-]HH:MM:SS`, each in centiseconds.
  while read -r raw want; do
    # shellcheck disable=SC2016 # positional params expand in the child shell.
    out=$(env FM_HERDR_PS_BIN="$psbin" FM_FAKE_PS_CPUTIME="$raw" bash -c '
        . "$0/bin/fm-herdr-wedge-lib.sh"; fm_herdr_wedge_cpu_centiseconds "$1"' "$ROOT" "$$") \
      || fail "cputime '$raw' should parse"
    [ "$out" = "$want" ] || fail "cputime '$raw' should be $want centiseconds, got '$out'"
  done <<'EOF'
0:12.34 1234
125:03.45 750345
1:02:03.45 372345
00:00:00 0
1-02:03:04 9378400
EOF
  for raw in garbage 12 0:12.3 1:2:3:4 12.34 ':' '-1:00'; do
    # shellcheck disable=SC2016 # positional params expand in the child shell.
    if out=$(env FM_HERDR_PS_BIN="$psbin" FM_FAKE_PS_CPUTIME="$raw" bash -c '
        . "$0/bin/fm-herdr-wedge-lib.sh"; fm_herdr_wedge_cpu_centiseconds "$1"' "$ROOT" "$$"); then
      fail "cputime '$raw' must not parse, got '$out'"
    fi
  done
  pass "wedge: CPU time parses both the macOS and the Linux cputime format, and refuses anything else"
}

test_wedge_macos_cpu_time_drives_the_verdict() {
  local dir state out psbin
  dir="$TMP_ROOT/wedge-cputime-bsd"; state="$dir/state"
  make_wedge_herdr "$dir" >/dev/null; mkdir -p "$state"
  attach_wedge_agent "$dir" frozen >/dev/null
  psbin=$(make_wedge_ps "$dir")

  out=$(wedge_classify "$dir" "$state" 600 judge FM_HERDR_PS_BIN="$psbin" FM_FAKE_PS_CPUTIME=0:12.34)
  [ "$out" = progressing ] || fail "the first macOS-format sample should start the window, got '$out'"
  # One centisecond of CPU: a whole-second reading would miss it entirely.
  wedge_age_window "$state" 601
  out=$(wedge_classify "$dir" "$state" 600 judge FM_HERDR_PS_BIN="$psbin" FM_FAKE_PS_CPUTIME=0:12.35)
  [ "$out" = progressing ] \
    || fail "a growing macOS-format CPU time must keep a frozen-countered mate alive, got '$out'"
  wedge_age_window "$state" 601
  out=$(wedge_classify "$dir" "$state" 600 judge FM_HERDR_PS_BIN="$psbin" FM_FAKE_PS_CPUTIME=0:12.35)
  [ "$out" = wedged ] || fail "an unchanged macOS-format CPU time must still wedge, got '$out'"
  wedge_age_window "$state" 601
  out=$(wedge_classify "$dir" "$state" 600 judge FM_HERDR_PS_BIN="$psbin" FM_FAKE_PS_CPUTIME=garbage)
  [ "$out" = unreadable ] || fail "an unparseable CPU time must yield no verdict, got '$out'"
  pass "wedge: a macOS-format CPU time reading drives the verdict instead of reading unreadable"
}

test_wedge_legacy_cpu_record_restarts_the_window() {
  local dir state out record
  dir="$TMP_ROOT/wedge-legacy-record"; state="$dir/state"
  make_wedge_herdr "$dir" >/dev/null; mkdir -p "$state"
  attach_wedge_agent "$dir" frozen >/dev/null
  record="$state/.secondmate-wedge-sm1"

  wedge_classify "$dir" "$state" 600 judge >/dev/null
  # A record from before the CPU field carried its unit: the bare number must
  # never compare equal to a fresh reading, even when the digits match.
  awk -F '\t' -v OFS='\t' '{ sub(/cs$/, "", $5); print }' "$record" > "$record.old" \
    && mv "$record.old" "$record"
  wedge_age_window "$state" 601
  out=$(wedge_classify "$dir" "$state" 600 judge)
  [ "$out" = progressing ] \
    || fail "a CPU field in an older unit must restart the window, got '$out'"
  wedge_age_window "$state" 601
  out=$(wedge_classify "$dir" "$state" 600 judge)
  [ "$out" = wedged ] || fail "the rewritten record should wedge on the next window, got '$out'"
  pass "wedge: a recorded CPU sample in an older unit restarts the window rather than reading unchanged"
}

test_wedge_requires_the_whole_window_to_elapse() {
  local dir state out
  dir="$TMP_ROOT/wedge-window"; state="$dir/state"
  make_wedge_herdr "$dir" >/dev/null; mkdir -p "$state"
  attach_wedge_agent "$dir" frozen >/dev/null

  out=$(wedge_classify "$dir" "$state" 3600 judge)
  [ "$out" = progressing ] || fail "baseline sample should read progressing, got '$out'"
  # Frozen on every signal, but nowhere near a generous window: still alive.
  wedge_age_window "$state" 120
  out=$(wedge_classify "$dir" "$state" 3600 judge)
  [ "$out" = progressing ] \
    || fail "a frozen agent inside a generous window must stay progressing, got '$out'"

  wedge_age_window "$state" 3600
  out=$(wedge_classify "$dir" "$state" 3600 judge)
  [ "$out" = wedged ] || fail "a frozen agent past the window must read wedged, got '$out'"
  pass "wedge: a wedged verdict needs the configured no-progress window to elapse in full"
}

test_wedge_never_fires_for_an_idle_done_or_blocked_agent() {
  local dir state out status
  dir="$TMP_ROOT/wedge-not-working"; state="$dir/state"
  make_wedge_herdr "$dir" >/dev/null; mkdir -p "$state"
  attach_wedge_agent "$dir" frozen >/dev/null

  for status in idle 'done' blocked; do
    printf 'working\n' > "$dir/status"
    wedge_classify "$dir" "$state" 600 judge >/dev/null
    wedge_age_window "$state" 601
    printf '%s\n' "$status" > "$dir/status"
    out=$(wedge_classify "$dir" "$state" 600 judge)
    [ "$out" = not-working ] \
      || fail "a '$status' agent must never be a wedge candidate, got '$out'"
    [ ! -e "$state/.secondmate-wedge-sm1" ] \
      || fail "a '$status' agent should drop its recorded sample so the next working stretch starts clean"
  done
  pass "wedge: an idle, done, or blocked agent is never treated as wedged"
}

test_wedge_unreadable_signals_never_authorize_a_kill() {
  local dir state out marker psbin
  dir="$TMP_ROOT/wedge-unreadable"; state="$dir/state"
  make_wedge_herdr "$dir" >/dev/null; mkdir -p "$state"
  attach_wedge_agent "$dir" frozen >/dev/null
  psbin=$(make_wedge_ps "$dir")

  # Establish a frozen window first, so every case below WOULD read wedged if
  # its signal were readable - that is what makes these assertions meaningful
  # rather than vacuous.
  wedge_classify "$dir" "$state" 600 judge >/dev/null
  wedge_age_window "$state" 601
  [ "$(wedge_classify "$dir" "$state" 600 judge)" = wedged ] \
    || fail "the fixture did not reach a wedged verdict, so the unreadable cases prove nothing"

  # A renamed or unreadable herdr counter.
  for marker in fail-agent fail-panes drop-seq drop-offset; do
    : > "$dir/$marker"
    wedge_age_window "$state" 601
    out=$(wedge_classify "$dir" "$state" 600 judge)
    [ "$out" = unreadable ] \
      || fail "with '$marker' the verdict must be unreadable, never a kill authorization, got '$out'"
    rm -f "$dir/$marker"
  done

  # An unreadable CPU-time column, which is the signal that separates a frozen
  # process from a thinking one.
  wedge_age_window "$state" 601
  out=$(wedge_classify "$dir" "$state" 600 judge \
    FM_HERDR_PS_BIN="$psbin" FM_FAKE_PS_FAIL_CPUTIME=1)
  [ "$out" = unreadable ] \
    || fail "an unreadable CPU time must never wedge, got '$out'"

  # An unreadable process table, which is where the live-child signal comes from.
  wedge_age_window "$state" 601
  out=$(wedge_classify "$dir" "$state" 600 judge \
    FM_HERDR_PS_BIN="$psbin" FM_FAKE_PS_FAIL_TABLE=1)
  [ "$out" = unreadable ] \
    || fail "an unreadable process table must never wedge, got '$out'"

  wedge_age_window "$state" 601
  out=$(wedge_classify "$dir" "$state" 600 judge)
  [ "$out" = wedged ] || fail "the readable fixture should wedge again after the unreadable cases, got '$out'"
  pass "wedge: an unreadable counter, CPU time, or process table disables recovery instead of authorizing a kill"
}

test_wedge_session_start_mode_only_rebases_the_window() {
  local dir state out
  dir="$TMP_ROOT/wedge-baseline"; state="$dir/state"
  make_wedge_herdr "$dir" >/dev/null; mkdir -p "$state"
  attach_wedge_agent "$dir" frozen >/dev/null

  wedge_classify "$dir" "$state" 600 judge >/dev/null
  wedge_age_window "$state" 601
  out=$(wedge_classify "$dir" "$state" 600 baseline)
  [ "$out" = baseline ] || fail "the session-start sweep must only re-base, got '$out'"
  # The re-base really moved the window: an immediate judging sample is clean.
  out=$(wedge_classify "$dir" "$state" 600 judge)
  [ "$out" = progressing ] \
    || fail "a re-based window must restart the clock rather than wedging at once, got '$out'"
  pass "wedge: the session-start sweep re-bases the window and never produces a verdict"
}

test_wedge_window_config_has_a_floor_and_an_off_switch() {
  local cfg out
  cfg="$TMP_ROOT/wedge-config"; mkdir -p "$cfg"

  out=$(bash -c '. "$0/bin/fm-herdr-wedge-lib.sh"; fm_herdr_wedge_window "$1"' "$ROOT" "$cfg")
  [ "$out" = 900 ] || fail "an unconfigured home should use the 900s default window, got '$out'"

  printf 'off\n' > "$cfg/secondmate-wedge-window"
  out=$(bash -c '. "$0/bin/fm-herdr-wedge-lib.sh"; fm_herdr_wedge_window "$1"' "$ROOT" "$cfg")
  [ "$out" = off ] || fail "an off window should disable wedge detection, got '$out'"

  printf '1800\n' > "$cfg/secondmate-wedge-window"
  out=$(bash -c '. "$0/bin/fm-herdr-wedge-lib.sh"; fm_herdr_wedge_window "$1"' "$ROOT" "$cfg")
  [ "$out" = 1800 ] || fail "a configured window at or above the floor should be honored, got '$out'"

  # Below the floor a hair-trigger kill is refused rather than honored.
  printf '30\n' > "$cfg/secondmate-wedge-window"
  out=$(bash -c '. "$0/bin/fm-herdr-wedge-lib.sh"; fm_herdr_wedge_window "$1" 2>/dev/null' "$ROOT" "$cfg")
  [ "$out" = 900 ] || fail "a sub-floor window must fall back to the default, got '$out'"
  assert_contains \
    "$(bash -c '. "$0/bin/fm-herdr-wedge-lib.sh"; fm_herdr_wedge_window "$1" 2>&1 >/dev/null' "$ROOT" "$cfg")" \
    "below the 600s floor" "a sub-floor window must say so rather than fall back silently"

  printf 'soon\n' > "$cfg/secondmate-wedge-window"
  out=$(bash -c '. "$0/bin/fm-herdr-wedge-lib.sh"; fm_herdr_wedge_window "$1" 2>/dev/null' "$ROOT" "$cfg")
  [ "$out" = 900 ] || fail "an unparseable window must fall back to the default, got '$out'"
  pass "wedge: the configured no-progress window honors a floor, an off switch, and warns on a typo"
}

# make_wedge_subtree <dir>: a real process shape to attribute a kill against -
# a shell whose child is an agent-named process (the pane), plus an identical
# agent-named process OUTSIDE that subtree (a sibling pane's agent, or the
# session server). Echoes "<shell-pid> <agent-pid> <outsider-pid>".
make_wedge_subtree() {
  local dir=$1 lab shell_pid agent_pid outsider_pid
  read -r shell_pid agent_pid <<< "$(attach_wedge_agent "$dir" frozen)"
  lab="$dir/agentbin"
  "$lab/claude" 300 >/dev/null 2>&1 &
  outsider_pid=$!
  wedge_track_pid "$outsider_pid"
  printf '%s %s %s\n' "$shell_pid" "$agent_pid" "$outsider_pid"
}

test_wedge_kill_reaches_only_the_panes_own_agent_process() {
  local dir out shell_pid agent_pid outsider_pid killed
  dir="$TMP_ROOT/wedge-kill-scope"
  make_wedge_herdr "$dir" >/dev/null
  read -r shell_pid agent_pid outsider_pid <<< "$(make_wedge_subtree "$dir")"

  # Attribution first: only the in-pane agent is ever a candidate.
  # shellcheck disable=SC2016 # positional params expand in the child shell.
  out=$(env PATH="$dir/fakebin:$BASE_PATH" FM_FAKE_WEDGE_DIR="$dir" bash -c '
      . "$0/bin/fm-backend.sh"; . "$0/bin/fm-herdr-wedge-lib.sh"
      fm_herdr_wedge_agent_pids fmtest w1:p2' "$ROOT")
  [ "$out" = "$agent_pid" ] \
    || fail "the kill candidates should be exactly the in-pane agent ($agent_pid), got '$out'"

  # shellcheck disable=SC2016 # positional params expand in the child shell.
  killed=$(env PATH="$dir/fakebin:$BASE_PATH" FM_FAKE_WEDGE_DIR="$dir" bash -c '
      . "$0/bin/fm-backend.sh"; . "$0/bin/fm-herdr-wedge-lib.sh"
      fm_herdr_wedge_kill_agent fmtest w1:p2 "$1" "$2" "$3"' \
    "$ROOT" "$agent_pid" "$shell_pid" "$outsider_pid")
  [ "$killed" = "$agent_pid" ] || fail "only the in-pane agent should be killed, got '$killed'"
  sleep 0.5
  kill -0 "$agent_pid" 2>/dev/null && fail "the wedged in-pane agent survived the kill"
  kill -0 "$shell_pid" 2>/dev/null \
    || fail "the pane's own shell was killed; that closes the pane instead of recovering the agent"
  kill -0 "$outsider_pid" 2>/dev/null \
    || fail "an agent-named process OUTSIDE the pane subtree was killed - a sibling pane or the session server would be lost"
  pass "wedge: SIGKILL reaches only the pane's own agent pid, never its shell or a process outside the subtree"
}

test_wedge_recovery_captures_evidence_before_killing_and_ledgers_it() {
  local dir state out shell_pid agent_pid outsider_pid capture ledger rc
  dir="$TMP_ROOT/wedge-capture"; state="$dir/state"
  make_wedge_herdr "$dir" >/dev/null; mkdir -p "$state" "$dir/home/config"
  read -r shell_pid agent_pid outsider_pid <<< "$(make_wedge_subtree "$dir")"
  printf 'window=fmtest:w1:p2\nkind=secondmate\nharness=claude\nbackend=herdr\nherdr_session=fmtest\nhome=%s\n' \
    "$dir/mate" > "$state/sm1.meta"

  rc=0
  # shellcheck disable=SC2016 # positional params expand in the child shell.
  out=$(env PATH="$dir/fakebin:$BASE_PATH" FM_FAKE_WEDGE_DIR="$dir" STATE="$state" \
    FM_HOME="$dir/home" bash -c '
      . "$0/bin/fm-secondmate-liveness-lib.sh"
      fm_secondmate_liveness_wedge_recover "$1" sm1 || exit 1
      printf "%s\n" "$FM_SM_LIVE_WEDGE_CAPTURE"
    ' "$ROOT" "$state/sm1.meta") || rc=$?
  [ "$rc" -eq 0 ] || fail "wedge recovery failed on a well-formed fixture: $out"
  capture=$out
  [ -s "$capture" ] || fail "no evidence file was written at '$capture'"
  assert_grep "$agent_pid" "$capture" "the evidence does not name the wedged agent pid"
  # The ordering proof: every evidence source here can only answer for a LIVE
  # process. A capture taken after the SIGKILL would have recorded the failure
  # marker instead - `(unreadable)` on Linux, a non-zero `sample` exit on macOS.
  assert_no_grep '(unreadable)' "$capture" \
    "the evidence was gathered after the kill: the live-process read failed"
  assert_no_grep 'sample exited' "$capture" \
    "the evidence was gathered after the kill: sample could not attach"
  grep -Eq 'State:|Analysis of sampling|Call graph' "$capture" \
    || fail "the evidence holds no live-process reading, so capture-before-kill is unproven: $(head -40 "$capture")"

  ledger="$state/.secondmate-relaunch-sm1"
  assert_grep "wedge-capture" "$ledger" "the relaunch ledger does not record the capture"
  assert_grep "$capture" "$ledger" "the relaunch ledger does not point at the evidence path"

  sleep 0.5
  kill -0 "$agent_pid" 2>/dev/null && fail "the wedged agent survived recovery"
  # The recovery primitive itself must still leave the pane shell alive; closing
  # the now agent-free pane belongs to the relaunch path, not here.
  kill -0 "$shell_pid" 2>/dev/null || fail "recovery killed the pane shell"
  kill -0 "$outsider_pid" 2>/dev/null || fail "recovery killed a process outside the pane subtree"
  [ ! -e "$state/.secondmate-wedge-sm1" ] \
    || fail "the recovered mate kept the frozen agent's progress sample instead of starting clean"
  pass "wedge: recovery captures live-process evidence before the kill and records its path in the ledger"
}

test_wedge_recovery_refuses_when_no_agent_pid_can_be_attributed() {
  local dir state out rc
  dir="$TMP_ROOT/wedge-no-pid"; state="$dir/state"
  make_wedge_herdr "$dir" >/dev/null; mkdir -p "$state" "$dir/home/config"
  # process-info describes a different pane: nothing here may be killed.
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w8:p8","shell_pid":1,"foreground_processes":[]}}}\n' \
    > "$dir/procinfo.json"
  printf 'window=fmtest:w1:p2\nkind=secondmate\nharness=claude\nbackend=herdr\nherdr_session=fmtest\nhome=%s\n' \
    "$dir/mate" > "$state/sm1.meta"

  rc=0
  # shellcheck disable=SC2016 # positional params expand in the child shell.
  out=$(env PATH="$dir/fakebin:$BASE_PATH" FM_FAKE_WEDGE_DIR="$dir" STATE="$state" \
    FM_HOME="$dir/home" bash -c '
      . "$0/bin/fm-secondmate-liveness-lib.sh"
      fm_secondmate_liveness_wedge_recover "$1" sm1 && exit 0
      printf "%s\n" "$FM_SM_LIVE_REASON"
      exit 1
    ' "$ROOT" "$state/sm1.meta") || rc=$?
  [ "$rc" -eq 1 ] || fail "recovery must refuse when no agent pid can be attributed"
  assert_contains "$out" "no attributable agent process to kill" \
    "the refusal should name why nothing was killed"
  assert_contains "$out" "endpoint left running" \
    "the refusal should state that the endpoint was preserved"
  pass "wedge: an unattributable agent process refuses the kill and preserves the endpoint"
}

test_wedge_probe_reports_relaunchable_only_on_the_watcher_tick() {
  local dir state out shell_pid agent_pid outsider_pid
  dir="$TMP_ROOT/wedge-probe"; state="$dir/state"
  make_wedge_herdr "$dir" >/dev/null; mkdir -p "$state" "$dir/home/config"
  read -r shell_pid agent_pid outsider_pid <<< "$(make_wedge_subtree "$dir")"
  printf 'window=fmtest:w1:p2\nkind=secondmate\nharness=claude\nbackend=herdr\nherdr_session=fmtest\nhome=%s\n' \
    "$dir/mate" > "$state/sm1.meta"
  printf '600\n' > "$dir/home/config/secondmate-wedge-window"

  probe() {  # <mode>
    # shellcheck disable=SC2016 # positional params expand in the child shell.
    env PATH="$dir/fakebin:$BASE_PATH" FM_FAKE_WEDGE_DIR="$dir" STATE="$state" \
      FM_HOME="$dir/home" FM_CONFIG_OVERRIDE="$dir/home/config" bash -c '
        . "$0/bin/fm-secondmate-liveness-lib.sh"
        fm_secondmate_liveness_probe "$1" sm1 "$2"
        printf "%s|%s|%s|%s\n" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_STATE" \
          "$FM_SM_LIVE_KILL" "$FM_SM_LIVE_WEDGE"
      ' "$ROOT" "$state/sm1.meta" "$1"
  }

  out=$(probe poll)
  [ "$out" = 'alive|alive|0|progressing' ] \
    || fail "the first poll should only start the window and leave the mate alive, got '$out'"

  wedge_age_window "$state" 601
  out=$(probe poll)
  [ "$out" = 'relaunchable|wedged|wedged|wedged' ] \
    || fail "a frozen working pane past the window should be relaunchable as wedged, got '$out'"

  # The same aged record under the session-start sweep is only re-based, never
  # acted on - a sweep sample cannot tell a frozen agent from an unobserved one.
  wedge_age_window "$state" 601
  out=$(probe full)
  [ "$out" = 'alive|alive|0|baseline' ] \
    || fail "the session-start sweep must leave a frozen mate alive and re-based, got '$out'"

  # An `off` window opts the home out entirely: no counter is even read.
  printf 'off\n' > "$dir/home/config/secondmate-wedge-window"
  out=$(probe poll)
  [ "$out" = 'alive|alive|0|' ] \
    || fail "an off wedge window must disable wedge detection, got '$out'"
  pass "probe: a wedged herdr secondmate is relaunchable on the watcher tick only, and an off window disables it"
}

test_wedge_relaunch_is_bounded_by_the_existing_attempt_ledger() {
  local dir state ledger attempts now
  dir="$TMP_ROOT/wedge-bound"; state="$dir/state"
  mkdir -p "$state"
  ledger="$state/.secondmate-relaunch-sm1"
  now=$(date +%s)

  # A wedged recovery records its attempt in the SAME ledger bin/fm-watch.sh's
  # relaunch bound counts, so a mis-detecting probe is capped exactly like a
  # mate that keeps dying. Seed the bound's own default budget
  # (FM_SECONDMATE_LIVENESS_MAX_ATTEMPTS=3 inside
  # FM_SECONDMATE_LIVENESS_WINDOW_SECS=3600) and confirm the counter the watcher
  # parks on has been reached.
  {
    printf '%s\tattempt\n' "$((now - 10))"
    printf '%s\twedge-capture\t%s/.wedge-sample-sm1-1\n' "$((now - 10))" "$state"
    printf '%s\tattempt\n' "$((now - 8))"
    printf '%s\tattempt\n' "$((now - 6))"
  } > "$ledger"

  attempts=$(STATE="$state" bash -c \
    '. "$0/bin/fm-secondmate-liveness-lib.sh"; fm_secondmate_liveness_recent_attempts sm1 3600' "$ROOT")
  [ "$attempts" -eq 3 ] \
    || fail "wedged attempts must count toward the shared relaunch bound at the watcher's parking threshold, got '$attempts'"

  # The capture rows are records, not attempts: they must never inflate the
  # budget and park a mate early.
  [ "$(awk -F '\t' '$2 == "wedge-capture"' "$ledger" | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "the capture row was not preserved in the ledger"

  # A live rearm restores the full budget for a wedged mate too, since the bound
  # counts only attempts after the last `rearmed` row.
  printf '%s\trearmed\n' "$now" >> "$ledger"
  attempts=$(STATE="$state" bash -c \
    '. "$0/bin/fm-secondmate-liveness-lib.sh"; fm_secondmate_liveness_recent_attempts sm1 3600' "$ROOT")
  [ "$attempts" -eq 0 ] || fail "a rearm should restore the wedged mate's full budget, got '$attempts'"
  pass "wedge: wedged relaunches consume the existing bounded attempt budget, so a misdetection cannot kill-loop"
}

test_wedge_cpu_time_parses_both_platform_formats
test_wedge_window_config_has_a_floor_and_an_off_switch
test_wedge_recovery_refuses_when_no_agent_pid_can_be_attributed
test_wedge_relaunch_is_bounded_by_the_existing_attempt_ledger
if [ -n "$WEDGE_STANDIN" ]; then
  test_wedge_progress_on_any_signal_keeps_the_mate_alive
  test_wedge_cpu_time_growth_keeps_the_mate_alive
  test_wedge_live_tool_child_keeps_the_mate_alive
  test_wedge_mcp_server_child_alone_still_wedges
  test_wedge_unobserved_gap_restarts_the_window
  test_wedge_sample_gap_follows_a_slow_watcher_cadence
  test_wedge_macos_cpu_time_drives_the_verdict
  test_wedge_legacy_cpu_record_restarts_the_window
  test_wedge_requires_the_whole_window_to_elapse
  test_wedge_never_fires_for_an_idle_done_or_blocked_agent
  test_wedge_unreadable_signals_never_authorize_a_kill
  test_wedge_session_start_mode_only_rebases_the_window
  test_wedge_kill_reaches_only_the_panes_own_agent_process
  test_wedge_recovery_captures_evidence_before_killing_and_ledgers_it
  test_wedge_probe_reports_relaunchable_only_on_the_watcher_tick
else
  echo "skip: no agent stand-in survives a foreign name on this host (process-level wedge cases)"
fi

echo "# all fm-secondmate-liveness tests passed"
