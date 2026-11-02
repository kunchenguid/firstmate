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
windows="${FM_TMUX_CALL_LOG:?}.windows"
case "${1:-}" in
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      for arg in "$@"; do
        case "$arg" in
          ". '"*"'") staged=${arg#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || cat "$staged" >> "$FM_FAKE_LAUNCH_LOG" ;;
          *'encode launch-brief'*|*'Firstmate operational input waiting: read'*) printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
      done
    fi
    exit 0 ;;
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
      missing)
        printf '%s\n' main
        [ ! -s "$windows" ] || cat "$windows"
        exit 0 ;;
      unreadable) exit 1 ;;
      *)
        [ -e "${FM_TMUX_CALL_LOG:?}.killed" ] || printf '%s\n' fm-sm1
        [ ! -s "$windows" ] || cat "$windows"
        exit 0 ;;
    esac
    ;;
  new-window|kill-window)
    printf '%s\n' "$*" >> "${FM_TMUX_CALL_LOG:?}"
    [ "${FM_TEST_FAIL_KILL:-0}" = 1 ] && [ "${1:-}" = kill-window ] && exit 1
    if [ "${1:-}" = new-window ] && [ -n "${FM_TEST_NEW_WINDOW_PAUSE:-}" ]; then
      sleep "$FM_TEST_NEW_WINDOW_PAUSE"
    fi
    if [ "${1:-}" = new-window ]; then
      name=
      previous=
      for arg in "$@"; do
        [ "$previous" = -n ] && name=$arg
        previous=$arg
      done
      grep -Fqx -- "$name" "$windows" 2>/dev/null || printf '%s\n' "$name" >> "$windows"
    fi
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

test_sweep_respawns_on_the_recorded_backend() {
  local w fb tmuxfb log out
  w=$(new_world sweep-pinned-backend)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  # The home now selects hc for new spawns; the dead mate is recorded on tmux.
  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log" FM_BACKEND=hc)

  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1:" \
    "the respawn should succeed on the recorded backend: $out"
  assert_contains "$(cat "$log")" "new-window" \
    "the respawn must land on the backend the mate is recorded on, not the configured default"
  assert_no_grep 'backend=hc' "$w/home/state/sm1.meta" \
    "the respawned record must stay on its recorded backend"
  pass "sweep: a dead secondmate respawns on its recorded backend, not a changed default"
}

test_sweep_recovers_the_durable_secondmate_account() {
  local w fb tmuxfb log out
  w=$(new_world sweep-account)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  mkdir -p "$w/home/config/secondmate-accounts/sm1" "$w/mate-account" "$w/primary-account" "$w/user-home"
  printf 'claude\n' > "$w/home/config/secondmate-harness"
  printf '%s\n' "$w/primary-account" > "$w/home/config/claude-account"
  printf '%s\n' "$w/mate-account" > "$w/home/config/secondmate-accounts/sm1/claude-account"
  : > "$w/mate-account/.credentials.json"
  cat > "$fb/claude" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ] || exit 0
[ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" ]
SH
  chmod +x "$fb/claude"
  log="$w/calls.log"; : > "$log"
  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log" \
    HOME="$w/user-home" CLAUDE_CONFIG_DIR="$w/ambient-account" FM_FAKE_LAUNCH_LOG="$w/launch.log")
  assert_not_contains "$out" 'SECONDMATE_LIVENESS: secondmate sm1:' "account recovery should succeed: $out"
  assert_grep 'relaunched' "$w/home/state/.secondmate-relaunch-sm1" "recovery must finish"
  assert_grep "account=$w/mate-account" "$w/home/state/sm1.meta" "recovery must record the configured mate account"
  assert_grep "CLAUDE_CONFIG_DIR='$w/mate-account'" "$w/launch.log" "recovery must launch on the durable mate pin, not the ambient account"
  pass "sweep: secondmate recovery resolves its durable account despite a different ambient login"
}

test_sweep_serializes_distinct_secondmate_relaunches() {
  local w fb tmuxfb log out id
  w=$(new_world sweep-concurrent-relaunch)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  add_sm_home "$w" sm2 firstmate:fm-sm2
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  # Keep the first fresh spawn inside new-window with its task-set lock held.
  # A parallel sweep races the second spawn into that lock and loses it.
  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" missing "$log" FM_TEST_NEW_WINDOW_PAUSE=2)

  assert_not_contains "$out" 'SECONDMATE_LIVENESS: secondmate sm' \
    "both distinct mates should relaunch without task-set contention"
  for id in sm1 sm2; do
    assert_grep 'relaunched' "$w/home/state/.secondmate-relaunch-$id" \
      "$id did not complete its relaunch"
  done
  [ "$(grep -c '^new-window ' "$log")" -eq 2 ] \
    || fail "both mates should reach a fresh spawn: $(cat "$log")"
  pass "sweep: distinct secondmate relaunches serialize across the task-set lock"
}

# The T3-only close refusal (fm_secondmate_liveness_relaunch) must leave every
# other backend on its existing best-effort kill: a tmux close that fails is
# still followed by the guarded spawn, exactly as before.
test_sweep_keeps_tmux_best_effort_kill_when_close_fails() {
  local w fb tmuxfb log out
  w=$(new_world sweep-dead-close-fails)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log" FM_TEST_FAIL_KILL=1)

  assert_contains "$(cat "$log")" "kill-window -t =firstmate:=fm-sm1" "the close is attempted"
  assert_not_contains "$out" "could not prove the old" "a non-T3 close failure must not take the T3-only refusal path"
  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: respawn failed after confirmed agent absence on existing endpoint" \
    "the guarded spawn still runs after a failed tmux close, as before"
  pass "sweep: a tmux secondmate whose close fails keeps the existing best-effort kill and guarded spawn"
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

test_relaunch_waits_for_other_mates_relaunch_lock() {
  local w fb tmuxfb log out holder i=0 lock
  w=$(new_world sweep-relaunch-lock-held)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"
  lock="$w/home/state/.secondmate-relaunch.lock"

  ( STATE="$w/home/state" bash -c \
      '. "$1" && fm_lock_try_acquire "$2" && trap '\''fm_lock_release "$2"'\'' EXIT && sleep 5' \
      _ "$ROOT/bin/fm-wake-lib.sh" "$lock" ) &
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$lock" ] || fail "the fixture never acquired the per-home relaunch lock"

  out=$(PATH="$tmuxfb:$fb:$BASE_PATH" FM_HOME="$w/home" FM_BACKEND=tmux \
    FM_ROOT="$ROOT" FM_TEST_PANE_CMD=zsh FM_TMUX_CALL_LOG="$log" \
    STATE="$w/home/state" bash -c '
      . "$1/bin/fm-secondmate-liveness-lib.sh"
      fm_secondmate_liveness_probe "$2" sm1 poll
      rc=0
      fm_secondmate_liveness_relaunch "$2" sm1 1 || rc=$?
      printf "rc=%s status=%s reason=%s\n" "$rc" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_REASON"
    ' _ "$ROOT" "$w/home/state/sm1.meta")
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  assert_contains "$out" "rc=1 status=skipped" \
    "a relaunch blocked on another mate must return a skipped failure"
  assert_contains "$out" "another secondmate relaunch still owns the per-home relaunch lock after 1s" \
    "a liveness relaunch must bound its lock wait by the spawn timeout"
  [ ! -e "$w/home/state/.secondmate-relaunch-sm1" ] \
    || fail "a relaunch blocked on another mate was counted as an attempt"
  [ ! -s "$log" ] || fail "a blocked relaunch touched the endpoint: $(cat "$log")"
  pass "relaunch: the spawn timeout bounds the lock wait before touching the endpoint"
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
# FM_FAKE_REMOTE_REPLY on FM_FAKE_REMOTE_RC.
# --- sweep level: hc-backed mates (bin/backends/hc.sh) ----------------------

# make_liveness_hc <dir>: a stateful fake herdr-core. Terminals live as
# <FM_HC_FAKE_DIR>/<address>.json; `run` allocates the next address from the
# counter file and stores the labels and cwd it was given, `ls` lists live
# terminals filtered by --label exactly like the real core (finished ones only
# with --all), `get` answers not_found with exit 3, `kill` marks a terminal
# finished, and `rm` removes it. Every call is logged with its HC_SESSION.
make_liveness_hc() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/hc" <<'SH'
#!/usr/bin/env bash
set -u
D=${FM_HC_FAKE_DIR:?}
mkdir -p "$D"
{ printf 'HC_SESSION=%s' "${HC_SESSION:-}"; for a in "$@"; do printf '\x1f%s' "$a"; done; printf '\n'; } >> "$D/log"
cmd=${1:-}
last=''
for a in "$@"; do last=$a; done
case "$cmd" in
  --version) printf 'hc 0.1.14\n' ;;
  server) printf '{"pid":1}\n' ;;
  connect) IFS= read -r _ || true; printf '{"jsonrpc":"2.0","id":1,"result":{"generation":1}}\n' ;;
  ls)
    all=0; want=()
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --all) all=1 ;;
        --label) want+=("$2"); shift ;;
      esac
      shift
    done
    out='[]'
    for f in "$D"/t*.json; do
      [ -e "$f" ] || continue
      [ "$all" = 1 ] || [ "$(jq -r .state "$f")" = live ] || continue
      ok=1
      for kv in ${want[@]+"${want[@]}"}; do
        [ "$(jq -r --arg k "${kv%%=*}" '.labels[$k] // ""' "$f")" = "${kv#*=}" ] || ok=0
      done
      [ "$ok" = 1 ] || continue
      out=$(jq -c --slurpfile t "$f" '. + [$t[0] | {address, state}]' <<<"$out")
    done
    printf '{"terminals":%s}\n' "$out" ;;
  run)
    n=$(cat "$D/next" 2>/dev/null || printf 1)
    printf '%s\n' $((n + 1)) > "$D/next"
    addr="t$n"; cwd=/; labels='{}'
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        --cwd) cwd=$2; shift ;;
        --label) labels=$(jq -c --arg k "${2%%=*}" --arg v "${2#*=}" '.[$k]=$v' <<<"$labels"); shift ;;
      esac
      shift
    done
    jq -n --arg a "$addr" --arg c "$cwd" --argjson l "$labels" \
      '{address:$a, state:"live", name:null, labels:$l, cwd:$c, foreground:{name:"zsh", argv:["/bin/zsh"], cwd:$c, pid:1}}' > "$D/$addr.json"
    printf '{"address":"%s"}\n' "$addr" ;;
  get)
    [ -f "$D/$last.json" ] || { printf '{"error":{"kind":"not_found"}}\n' >&2; exit 3; }
    cat "$D/$last.json" ;;
  kill)
    [ -f "$D/$last.json" ] || { printf '{"error":{"kind":"not_found"}}\n' >&2; exit 3; }
    jq '.state="finished" | .foreground=null' "$D/$last.json" > "$D/$last.tmp" && mv "$D/$last.tmp" "$D/$last.json"
    printf '{}\n' ;;
  rm) rm -f "$D/$last.json"; printf '{}\n' ;;
  read) printf '❯\n' ;;
  send) printf '{"started":true,"wait":{"status":"working"}}\n' ;;
  *) printf '{}\n' ;;
esac
SH
  chmod +x "$fakebin/hc"
  printf '%s\n' "$fakebin"
}

# hc_seed_terminal <fake-dir> <address> <live|finished> <fg-name|-> <task-label> <hometag>:
# the mate's recorded terminal as the core would report it, carrying the
# PRIMARY's identity labels (its record owns the terminal) and the mate's tab.
hc_seed_terminal() {
  local d=$1 addr=$2 state=$3 fg=$4 task=$5 home=$6
  mkdir -p "$d"
  jq -n --arg a "$addr" --arg s "$state" --arg f "$fg" --arg t "$task" --arg h "$home" \
    '{address:$a, state:$s, name:null, labels:{"firstmate.task":$t, "firstmate.home":$h, "herdr.space":("fm-"+$h), "herdr.tab":($h+"-"+$t)}, cwd:"/", foreground:(if $f == "-" then null else {name:$f, argv:[$f], cwd:"/", pid:1} end)}' \
    > "$d/$addr.json"
  printf '%s\n' $(( ${addr#t} + 1 )) > "$d/next"
}

# add_hc_sm_home <w> <id> <address>: add_sm_home plus the hc endpoint fields.
add_hc_sm_home() {
  local w=$1 id=$2 addr=$3
  add_sm_home "$w" "$id" "fmtest:$addr"
  printf 'backend=hc\nhc_session=fmtest\nhc_terminal=%s\n' "$addr" >> "$w/home/state/$id.meta"
}

# The hometag the sweep's own process derives (FM_HOME is the world's home and
# FM_ROOT the checkout under test), and the tag the MATE home derives for itself
# (both resolve to that home inside its own session).
# shellcheck disable=SC2016 # the $0 root expands in the child shell.
primary_tag_of() {  # <w>
  env -u FM_ROOT_OVERRIDE FM_HOME="$1/home" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source hc >/dev/null 2>&1; fm_backend_hometag' "$ROOT"
}
# shellcheck disable=SC2016 # the $0 root expands in the child shell.
mate_tag_of() {  # <mate-home>
  FM_HOME="$1" FM_ROOT_OVERRIDE="$1" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source hc >/dev/null 2>&1; fm_backend_hometag' "$ROOT"
}

run_hc_bootstrap() {  # <w> <path> <hc-bin> <tmux-call-log> -> stdout
  local w=$1 path=$2 hcbin=$3 log=$4
  env -u HC_TERMINAL_ID -u HC_TERMINAL_SOCKET -u HC_SCOPE -u HC_SOCKET -u FM_HC_SOCKET -u FM_ROOT_OVERRIDE \
    PATH="$path:$BASE_PATH" TMUX='' FM_BACKEND=hc FM_HOME="$w/home" \
    FM_HC_BIN="$hcbin" FM_HC_FAKE_DIR="$w/hc" HC_SESSION=fmtest \
    FM_TEST_PANE_CMD=zsh FM_TMUX_CALL_LOG="$log" \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

hc_world() {  # <name> -> sets W_DIR, W_PATH, W_HCBIN, W_LOG, W_TAG, W_MATE_TAG for sm1
  W_DIR=$(new_world "$1")
  add_hc_sm_home "$W_DIR" sm1 t1
  local fb tmuxfb hcfb
  fb=$(make_toolchain "$W_DIR"); tmuxfb=$(make_liveness_tmux "$W_DIR"); hcfb=$(make_liveness_hc "$W_DIR/hc-tools")
  W_PATH="$hcfb:$tmuxfb:$fb"
  W_HCBIN="$hcfb/hc"
  W_LOG="$W_DIR/calls.log"; : > "$W_LOG"
  W_TAG=$(primary_tag_of "$W_DIR")
  W_MATE_TAG=$(mate_tag_of "$W_DIR/sm1")
  [ -n "$W_TAG" ] && [ -n "$W_MATE_TAG" ] || fail "could not resolve the home tags"
}

test_sweep_closes_and_respawns_a_dead_hc_secondmate() {
  local out hclog run_line
  hc_world sweep-hc-dead
  hc_seed_terminal "$W_DIR/hc" t1 live zsh fm-sm1 "$W_TAG"

  out=$(run_hc_bootstrap "$W_DIR" "$W_PATH" "$W_HCBIN" "$W_LOG")

  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1:" \
    "a dead hc mate must be recovered silently: $out"
  hclog=$(cat "$W_DIR/hc/log")
  assert_contains "$hclog" $'\x1fkill\x1f--json\x1ft1' "the dead terminal must be closed before the respawn"
  assert_contains "$hclog" $'\x1frm\x1f--json\x1ft1' "the closed terminal must be removed from the core"
  [ ! -e "$W_DIR/hc/t1.json" ] || fail "the dead terminal must be gone from the core"
  run_line=$(grep $'\x1frun\x1f' "$W_DIR/hc/log")
  assert_contains "$run_line" "herdr.space=fm-$W_MATE_TAG" "the respawned mate must land in its own space"
  assert_contains "$run_line" "firstmate.home=$W_TAG" "the respawned terminal must carry this home's identity"
  assert_contains "$run_line" "firstmate.task=fm-sm1" "the respawned terminal must carry the mate's task label"
  assert_grep 'hc_terminal=t2' "$W_DIR/home/state/sm1.meta" "the record must follow the replacement terminal"
  assert_grep 'window=fmtest:t2' "$W_DIR/home/state/sm1.meta" "the window must follow the replacement terminal"
  assert_grep 'backend=hc' "$W_DIR/home/state/sm1.meta" "the record must stay on hc"
  assert_not_contains "$hclog" HC_SESSION=default "recovery must never reach the default session"
  assert_grep 'relaunched' "$W_DIR/home/state/.secondmate-relaunch-sm1" \
    "the durable per-mate relaunch record must be written"
  pass "sweep: a dead hc secondmate terminal is closed, removed, and respawned in the mate's own space"
}

test_sweep_removes_a_finished_hc_husk_before_respawn() {
  local out hclog
  hc_world sweep-hc-finished
  # The agent's program ended: the core keeps a finished record carrying the
  # mate's labels and its Herdr.app tab until it is removed.
  hc_seed_terminal "$W_DIR/hc" t1 finished - fm-sm1 "$W_TAG"

  out=$(run_hc_bootstrap "$W_DIR" "$W_PATH" "$W_HCBIN" "$W_LOG")

  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1:" \
    "a finished hc mate must be recovered silently: $out"
  hclog=$(cat "$W_DIR/hc/log")
  assert_not_contains "$hclog" $'\x1fkill\x1f' "a finished terminal has nothing left to kill"
  assert_contains "$hclog" $'\x1frm\x1f--json\x1ft1' "the finished husk must be removed before the respawn"
  [ ! -e "$W_DIR/hc/t1.json" ] || fail "the husk must be gone from the core"
  assert_contains "$hclog" $'\x1frun\x1f' "the mate must be respawned"
  assert_grep 'hc_terminal=t2' "$W_DIR/home/state/sm1.meta" "the record must follow the replacement terminal"
  pass "sweep: a finished hc terminal is removed as a husk before the mate is respawned"
}

test_sweep_respawns_a_not_found_hc_secondmate() {
  local out hclog
  hc_world sweep-hc-gone
  # The recorded terminal is already gone from the core; the next address the
  # core hands out is unrelated to the record.
  mkdir -p "$W_DIR/hc"
  printf '5\n' > "$W_DIR/hc/next"

  out=$(run_hc_bootstrap "$W_DIR" "$W_PATH" "$W_HCBIN" "$W_LOG")

  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1:" \
    "a mate whose terminal is gone must be respawned silently: $out"
  hclog=$(cat "$W_DIR/hc/log")
  assert_not_contains "$hclog" $'\x1fkill\x1f' "nothing is killed for a terminal that is already gone"
  assert_contains "$hclog" $'\x1frun\x1f' "the mate must be respawned"
  assert_grep 'hc_terminal=t5' "$W_DIR/home/state/sm1.meta" "the record must bind the fresh terminal"
  pass "sweep: an hc secondmate whose terminal is gone is respawned without touching the core"
}

test_sweep_leaves_an_alive_hc_secondmate_untouched() {
  local out before
  hc_world sweep-hc-alive
  hc_seed_terminal "$W_DIR/hc" t1 live claude fm-sm1 "$W_TAG"
  before=$(cat "$W_DIR/home/state/sm1.meta")

  out=$(run_hc_bootstrap "$W_DIR" "$W_PATH" "$W_HCBIN" "$W_LOG")

  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1:" "an alive hc mate needs no report: $out"
  for verb in kill rm run; do
    assert_not_contains "$(cat "$W_DIR/hc/log")" $'\x1f'"$verb"$'\x1f' "an alive hc mate must not be touched ($verb)"
  done
  [ "$(cat "$W_DIR/home/state/sm1.meta")" = "$before" ] || fail "an alive hc mate's record must not change"
  [ ! -e "$W_DIR/home/state/.secondmate-relaunch-sm1" ] || fail "no relaunch attempt may be recorded for an alive mate"
  pass "sweep: an alive hc secondmate is left exactly as it is"
}

# --- bin/fm-secondmate-move.sh: moving a local mate onto another backend ------

# make_move_tmux <dir>: a file-driven fake tmux (FM_MOVE_FAKE_DIR) with the
# reads fm-control's exit needs and the window ops the move's close and the
# liveness probe need. The pane's command lives in <dir>/command and flips to
# zsh when the typed /exit lands; typed text is kept in <dir>/literal; an
# `unreadable` marker fails every read; a <dir>/pane file replaces the default
# empty composer screen.
make_move_tmux() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=${FM_MOVE_FAKE_DIR:?}
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s\n' "${1:-}" >> "$D/literal"
      case "${1:-}" in /exit|/quit) printf 'zsh' > "$D/command" ;; esac
    else
      printf '%s\n' "${1:-}" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    [ ! -e "$D/unreadable" ] || exit 1
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    [ ! -e "$D/unreadable" ] || exit 1
    if [ -f "$D/pane" ]; then cat "$D/pane"; else printf '╭────╮\n│    │\n╰────╯\n'; fi
    exit 0 ;;
  list-windows)
    [ ! -e "$D/unreadable" ] || exit 1
    [ ! -f "$D/windows" ] || cat "$D/windows"
    exit 0 ;;
  new-window|kill-window)
    printf '%s\n' "$*" >> "${FM_TMUX_CALL_LOG:?}"
    if [ "$1" = kill-window ]; then : > "$D/windows"; fi
    exit 0 ;;
  has-session) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# add_move_sm_home <w> <id>: a tmux-recorded mate with the full record shape a
# real launch publishes, so fm-control can validate its endpoint identity.
add_move_sm_home() {
  local w=$1 id=$2
  add_sm_home "$w" "$id" "firstmate:fm-$id"
  printf 'endpoint_task_id=%s\nworktree=%s\nproject=%s\nmode=secondmate\nyolo=off\nprojects=\n' \
    "$id" "$w/$id" "$w/$id" >> "$w/home/state/$id.meta"
}

move_world() {  # <name> <pane-command> -> sets W_DIR, W_PATH, W_HCBIN, W_LOG, W_TAG, W_MATE_TAG, W_MV
  W_DIR=$(new_world "$1")
  add_move_sm_home "$W_DIR" sm1
  local fb mvfb hcfb
  fb=$(make_toolchain "$W_DIR"); mvfb=$(make_move_tmux "$W_DIR/mv-tools"); hcfb=$(make_liveness_hc "$W_DIR/hc-tools")
  W_PATH="$mvfb:$hcfb:$fb"
  W_HCBIN="$hcfb/hc"
  W_LOG="$W_DIR/calls.log"; : > "$W_LOG"
  W_MV="$W_DIR/mv"
  mkdir -p "$W_MV" "$W_DIR/hc"
  printf '%s' "$2" > "$W_MV/command"
  printf '%s' "$W_DIR/sm1" > "$W_MV/cwd"
  printf 'fm-sm1\n' > "$W_MV/windows"
  : > "$W_MV/literal"
  W_TAG=$(primary_tag_of "$W_DIR")
  W_MATE_TAG=$(mate_tag_of "$W_DIR/sm1")
  [ -n "$W_TAG" ] && [ -n "$W_MATE_TAG" ] || fail "could not resolve the home tags"
}

run_move() {  # <args...> -> combined output; the move's exit status
  env -u HC_TERMINAL_ID -u HC_TERMINAL_SOCKET -u HC_SCOPE -u HC_SOCKET -u FM_HC_SOCKET -u FM_ROOT_OVERRIDE -u FM_BACKEND \
    PATH="$W_PATH:$BASE_PATH" TMUX='' FM_HOME="$W_DIR/home" \
    FM_HC_BIN="$W_HCBIN" FM_HC_FAKE_DIR="$W_DIR/hc" HC_SESSION=fmtest \
    FM_MOVE_FAKE_DIR="$W_MV" FM_TMUX_CALL_LOG="$W_LOG" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_SETTLE_WAIT=0.05 FM_CONTROL_EXIT_WAIT=0.5 \
    "$ROOT/bin/fm-secondmate-move.sh" "$@" 2>&1
}

assert_move_landed_on_hc() {  # <output>
  local run_line meta
  assert_contains "$1" "moved sm1 from=tmux to=hc" "the move must report the backends"
  assert_contains "$1" "spawned sm1 harness=codex kind=secondmate" "the move must relay the launch line"
  assert_contains "$(cat "$W_LOG")" "kill-window" "the old tmux endpoint must be closed"
  run_line=$(grep $'\x1frun\x1f' "$W_DIR/hc/log")
  assert_contains "$run_line" "herdr.space=fm-$W_MATE_TAG" "the moved mate must land in its own space"
  assert_contains "$run_line" "firstmate.home=$W_TAG" "the moved terminal must carry this home's identity"
  meta=$(cat "$W_DIR/home/state/sm1.meta")
  for line in backend=hc hc_session=fmtest hc_terminal=t1 window=fmtest:t1 kind=secondmate "home=$W_DIR/sm1"; do
    assert_contains "$meta" "$line" "the republished record must carry $line"
  done
  assert_grep 'attempt' "$W_DIR/home/state/.secondmate-relaunch-sm1" "the move must record its attempt"
  assert_grep 'relaunched' "$W_DIR/home/state/.secondmate-relaunch-sm1" "the move must record its outcome"
}

test_move_stops_a_live_tmux_secondmate_and_relaunches_it_on_hc() {
  local out rc=0
  move_world move-live claude
  out=$(run_move sm1 --backend hc) || rc=$?
  expect_code 0 "$rc" "moving a live tmux mate onto hc must succeed"$'\n'"$out"
  [ "$(cat "$W_MV/literal")" = /exit ] || fail "the live agent must be stopped through its exit command first, got: $(cat "$W_MV/literal")"
  [ "$(cat "$W_MV/command")" = zsh ] || fail "the stop must have been proven before the move went on"
  assert_move_landed_on_hc "$out"
  pass "move: a live tmux secondmate is stopped, its endpoint closed, and the mate relaunched on hc in its own space"
}

test_move_relaunches_an_already_stopped_tmux_secondmate_on_hc() {
  local out rc=0
  move_world move-stopped zsh
  out=$(run_move sm1 --backend hc) || rc=$?
  expect_code 0 "$rc" "moving a stopped tmux mate onto hc must succeed"$'\n'"$out"
  [ ! -s "$W_MV/literal" ] || fail "an already-stopped agent must not be sent an exit command: $(cat "$W_MV/literal")"
  assert_move_landed_on_hc "$out"
  pass "move: an already-stopped tmux secondmate is relaunched on hc without lifecycle input"
}

# add_move_remote_dead <w>: places sm1 on a remote host whose stubbed state
# probe reports the agent dead, so the move reaches the relaunch step.
add_move_remote_dead() {
  local w=$1 sshbin
  printf 'remote_host=lab-host\nremote_backend=herdr\nremote_herdr_session=fm-remote\nremote_target=fm-remote:w1:p1\n' >> "$w/home/state/sm1.meta"
  mkdir -p "$w/home/data"
  printf -- '- sm1 - Remote mate (host: lab-host; root: /remote/root; home: /remote/sm1-home; scope: remote work; projects: alpha; added 2026-01-01)\n' \
    > "$w/home/data/secondmates.md"
  sshbin=$(fm_fakebin "$w/ssh-tools")
  cat > "$sshbin/ssh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$w/ssh.log'
printf 'dead\n'
SH
  chmod +x "$sshbin/ssh"
  W_PATH="$sshbin:$W_PATH"
}

test_move_refuses_before_stopping_anything() {
  local scenario out rc before args
  for scenario in cmux unknown same-backend remote unreadable pending-composer; do
    move_world "move-refuse-$scenario" claude
    args=(sm1 --backend hc)
    case "$scenario" in
      cmux) args=(sm1 --backend cmux) ;;
      unknown) args=(sm1 --backend bogus) ;;
      same-backend) args=(sm1 --backend tmux) ;;
      remote) add_move_remote_dead "$W_DIR" ;;
      unreadable) : > "$W_MV/unreadable" ;;
      pending-composer) printf '❯ draft text\n' > "$W_MV/pane" ;;
    esac
    before=$(cat "$W_DIR/home/state/sm1.meta")
    rc=0
    out=$(run_move "${args[@]}") || rc=$?
    [ "$rc" -ne 0 ] || fail "$scenario must refuse the move: $out"
    [ ! -s "$W_MV/literal" ] || fail "$scenario must not stop the agent: $(cat "$W_MV/literal")"
    [ "$(cat "$W_MV/command")" = claude ] || fail "$scenario must leave the agent running"
    [ ! -s "$W_LOG" ] || fail "$scenario must not close the endpoint: $(cat "$W_LOG")"
    assert_not_contains "$(cat "$W_DIR/hc/log" 2>/dev/null || true)" $'\x1frun\x1f' "$scenario must not launch anything"
    [ "$(cat "$W_DIR/home/state/sm1.meta")" = "$before" ] || fail "$scenario must leave the record unchanged"
    [ ! -e "$W_DIR/home/state/.secondmate-relaunch-sm1" ] || fail "$scenario must not record a relaunch attempt"
    case "$scenario" in
      cmux) assert_contains "$out" "backend=cmux does not support --secondmate" "the cmux refusal names the limit" ;;
      unknown) assert_contains "$out" "unknown backend" "the unknown-backend refusal names it" ;;
      same-backend) assert_contains "$out" "already recorded on backend=tmux" "a same-backend move points at relaunch" ;;
      remote)
        assert_contains "$out" "a local move is refused" "a dead remote mate reaches the library's own refusal"
        assert_contains "$(cat "$W_DIR/ssh.log")" "-- lab-host " "the remote mate must have been probed on its host"
        ;;
      unreadable) assert_contains "$out" "cannot be classified" "an unreadable endpoint refuses before any stop" ;;
      pending-composer) assert_contains "$out" "could not be proven stopped" "a refused stop ends the move" ;;
    esac
  done
  pass "move: an unmovable target, a remote mate, an unclassifiable endpoint, and a refused stop all leave the mate untouched"
}

test_move_usage_prints_the_exit_status_contract() {
  local out rc=0 contract='Exit status: 0 moved; 1 refused or failed,'
  out=$("$ROOT/bin/fm-secondmate-move.sh" --help 2>/dev/null) || rc=$?
  expect_code 0 "$rc" "--help must succeed"$'\n'"$out"
  assert_contains "$out" "$contract" "--help must print the exit-status contract"
  assert_contains "$out" "with the message naming the state the mate was left in; 2 invalid use." "--help must print the whole contract"
  rc=0
  out=$("$ROOT/bin/fm-secondmate-move.sh" 2>&1 >/dev/null) || rc=$?
  expect_code 2 "$rc" "a move with no arguments is invalid use"$'\n'"$out"
  assert_contains "$out" "$contract" "invalid use must print the exit-status contract on stderr"
  assert_contains "$out" "with the message naming the state the mate was left in; 2 invalid use." "invalid use must print the whole contract on stderr"
  pass "move: --help and invalid use both print the header through its exit-status contract"
}

test_move_refuses_while_the_liveness_lock_is_held() {
  local out rc=0 holder i=0
  move_world move-lock-held zsh
  ( STATE="$W_DIR/home/state" bash -c \
      '. "$1" && fm_lock_acquire_wait "$2" && sleep 30' \
      _ "$ROOT/bin/fm-wake-lib.sh" "$W_DIR/home/state/.secondmate-liveness-sm1.lock" ) &
  holder=$!
  while [ ! -d "$W_DIR/home/state/.secondmate-liveness-sm1.lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -d "$W_DIR/home/state/.secondmate-liveness-sm1.lock" ] || fail "the fixture never acquired the liveness lock"
  out=$(run_move sm1 --backend hc) || rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail "a move must not run beside a liveness episode: $out"
  assert_contains "$out" "another liveness check or recovery is in progress" "the refusal names the lock"
  [ ! -s "$W_LOG" ] || fail "a locked mate must not be touched: $(cat "$W_LOG")"
  assert_not_contains "$(cat "$W_DIR/hc/log" 2>/dev/null || true)" $'\x1frun\x1f' "a locked mate must not be launched"
  pass "move: a mate mid-episode under the shared liveness lock is refused entirely"
}

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
[ -z "${FM_FAKE_REMOTE_REPLY:-}" ] || printf '%s\n' "$FM_FAKE_REMOTE_REPLY"
exit "${FM_FAKE_REMOTE_RC:-0}"
SH
  chmod +x "$fakebin/ssh"
  printf '%s\n' "$w"
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

  [ "$(wc -l < "$w/ssh.log" | tr -d ' ')" -eq 6 ] \
    || fail "each poll-mode probe should spend exactly one remote state call: $(cat "$w/ssh.log")"
  pass "poll probe: remote states map to the same contract as local, one call each"
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

# make_remote_probe_world_rex <name>: the same remote probe world on a rex
# route, whose fake ssh answers the doctor, the state verb, and the route verb
# separately so a full-mode probe exercises readiness plus the route re-check.
make_remote_probe_world_rex() {
  local name=$1 w fakebin
  w="$TMP_ROOT/$name"
  fakebin=$(fm_fakebin "$w")
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config"
  cat > "$w/home/state/rsm1.meta" <<EOF
window=remote:rsm1
kind=secondmate
harness=claude
remote_host=lab-host
remote_backend=rex
remote_rex_session_id=session:00000001-0000-7000-8000-000000000002
remote_rex_server=unix:///remote/rex.sock
remote_target=00000001-0000-7000-8000-000000000002:00000003-0000-7000-8000-000000000004
home=/remote/rsm1-home
EOF
  cat > "$w/home/data/secondmates.md" <<EOF
- rsm1 - Remote mate (host: lab-host; root: /remote/root; home: /remote/rsm1-home; scope: remote work; projects: alpha; added 2026-01-01)
EOF
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = lab-host ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
argv_b64=$4
command_fields=$(perl -MMIME::Base64=decode_base64 -e '
  my $data=decode_base64($ARGV[0]);
  my @args=split(/\0/, $data);
  print join("\t", map { defined $_ ? $_ : "" } @args[0..2]);
' "$argv_b64")
IFS=$'\t' read -r command_name _command_action command_rel <<EOF
$command_fields
EOF
printf '%s %s %s\n' "$command_name" "$_command_action" "$command_rel" >> "${FM_FAKE_SSH_LOG:?}"
case "$command_name:$_command_action" in
  fm-remote-doctor.sh:*)
    [ -z "${FM_FAKE_DOCTOR_OUT:-}" ] || printf '%s\n' "$FM_FAKE_DOCTOR_OUT"
    exit "${FM_FAKE_DOCTOR_RC:-0}"
    ;;
  fm-remote-secondmate-control.sh:route)
    [ "${FM_FAKE_REMOTE_RC:-0}" -eq 0 ] || exit "$FM_FAKE_REMOTE_RC"
    printf 'schema=fm-remote-secondmate-control.v1\n'
    printf 'backend=%s\n' "${FM_FAKE_ROUTE_BACKEND:-rex}"
    printf 'target=%s\n' "${FM_FAKE_ROUTE_TARGET:-00000001-0000-7000-8000-000000000002:00000003-0000-7000-8000-000000000004}"
    printf 'rex_session_id=session:00000001-0000-7000-8000-000000000002\n'
    printf 'rex_server=unix:///remote/rex.sock\n'
    printf 'harness=claude\n'
    exit 0
    ;;
  fm-remote-secondmate-control.sh:state)
    printf '%s\n' "${FM_FAKE_REMOTE_REPLY:-alive}"
    exit "${FM_FAKE_REMOTE_RC:-0}"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/ssh"
  printf '%s\n' "$w"
}

test_remote_full_probe_rex_route() {
  local w out
  w=$(make_remote_probe_world_rex probe-rex)

  # A green readiness gate, an alive rex endpoint, and a matching route keep
  # the recorded rex backend live.
  out=$(probe_remote "$w" full)
  [ "$out" = 'alive|alive|0|||' ] || fail "a live rex route should stay a quiet no-op, got: $out"
  grep -q -- '--backend rex' "$w/ssh.log" \
    || fail "the readiness gate did not ask the remote doctor about rex: $(cat "$w/ssh.log")"
  pass "full probe: a live rex route stays alive through the rex readiness gate"
}

test_remote_full_probe_rex_backend_drift() {
  local w out
  w=$(make_remote_probe_world_rex probe-rex-drift)

  # The remote reports a different backend than this home recorded: a skip,
  # never a silent migration.
  out=$(probe_remote "$w" full FM_FAKE_ROUTE_BACKEND=herdr)
  [ "$out" = "skipped|alive|0|||alive remote endpoint runs on backend 'herdr', but this home recorded 'rex'; migrate or retire it explicitly" ] \
    || fail "a herdr route under a rex record must be reported, got: $out"

  out=$(probe_remote "$w" full FM_FAKE_ROUTE_BACKEND=tmux)
  [ "$out" = "skipped|alive|0|||alive remote endpoint is recorded on backend 'tmux'; migrate or retire it explicitly" ] \
    || fail "an unsupported remote backend must be reported, got: $out"
  pass "full probe: remote backend drift is reported, never migrated"
}

test_remote_full_probe_rex_readiness_verdicts() {
  local w out
  w=$(make_remote_probe_world_rex probe-rex-readiness)

  out=$(probe_remote "$w" full FM_FAKE_DOCTOR_RC=1 \
    FM_FAKE_DOCTOR_OUT='check rex-server=fixable: no persistent rex server answers')
  case "$out" in
    'skipped|unknown|0|||remote readiness failed on lab-host: check rex-server=fixable:'*) : ;;
    *) fail "a rex readiness gap must be reported, got: $out" ;;
  esac

  out=$(probe_remote "$w" full FM_FAKE_DOCTOR_RC=255)
  [ "$out" = 'skipped|unknown|0|||remote host unavailable or endpoint state unknown; route preserved on lab-host' ] \
    || fail "an unreachable rex readiness probe must preserve the route, got: $out"
  pass "full probe: rex readiness gaps and unreachable hosts stay explicit"
}

test_remote_full_probe_legacy_record_defaults_herdr() {
  local w out
  w=$(make_remote_probe_world_rex probe-legacy)

  # A record written before rex existed carries no remote_backend; it is a
  # herdr route, so the gate asks the doctor about herdr and a herdr route
  # reply keeps it alive.
  sed -i.bak '/^remote_backend=/d;/^remote_rex_/d' "$w/home/state/rsm1.meta"
  rm -f "$w/home/state/rsm1.meta.bak"
  printf 'remote_herdr_session=fm-remote\nremote_target=fm-remote:w1:p1\n' >> "$w/home/state/rsm1.meta"
  out=$(probe_remote "$w" full FM_FAKE_ROUTE_BACKEND=herdr)
  [ "$out" = 'alive|alive|0|||' ] || fail "a legacy route should stay alive on herdr, got: $out"
  grep -q -- '--backend herdr' "$w/ssh.log" \
    || fail "a legacy record did not ask the remote doctor about herdr: $(cat "$w/ssh.log")"
  pass "full probe: a record without remote_backend stays a herdr route"
}

test_tmux_agent_state_classifies
test_tmux_agent_state_rejects_malformed_targets_before_probe
test_herdr_agent_state_preserves_husk_classifier
test_agent_state_dispatcher_and_compatibility
test_sweep_respawns_confirmed_dead_secondmate
test_sweep_respawns_on_the_recorded_backend
test_sweep_recovers_the_durable_secondmate_account
test_sweep_serializes_distinct_secondmate_relaunches
test_sweep_keeps_tmux_best_effort_kill_when_close_fails
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
test_relaunch_waits_for_other_mates_relaunch_lock
test_sweep_refuses_relaunch_on_ledger_errors
test_sweep_closes_and_respawns_a_dead_hc_secondmate
test_sweep_removes_a_finished_hc_husk_before_respawn
test_sweep_respawns_a_not_found_hc_secondmate
test_sweep_leaves_an_alive_hc_secondmate_untouched
test_move_stops_a_live_tmux_secondmate_and_relaunches_it_on_hc
test_move_relaunches_an_already_stopped_tmux_secondmate_on_hc
test_move_refuses_before_stopping_anything
test_move_usage_prints_the_exit_status_contract
test_move_refuses_while_the_liveness_lock_is_held
test_remote_poll_probe_maps_states
test_remote_poll_probe_unreachable_preserves_route
test_remote_full_probe_rex_route
test_remote_full_probe_rex_backend_drift
test_remote_full_probe_rex_readiness_verdicts
test_remote_full_probe_legacy_record_defaults_herdr

echo "# all fm-secondmate-liveness tests passed"
