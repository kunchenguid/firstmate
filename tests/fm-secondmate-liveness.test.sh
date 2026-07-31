#!/usr/bin/env bash
# tests/fm-secondmate-liveness.test.sh - the session-start secondmate LIVENESS
# guarantee: bin/fm-backend.sh's fm_backend_agent_alive probe (dispatching to
# fm_backend_tmux_agent_alive / fm_backend_herdr_agent_alive) and
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
#   - fm_backend_tmux_agent_alive classifies a verified-harness foreground
#     process as alive, a bare shell as dead, and anything ambiguous
#     (including a bare interpreter name) as unknown - never dead.
#   - fm_backend_herdr_agent_alive is a thin wrapper over the already-verified
#     fm_backend_herdr_pane_agent_state husk classifier: dead/no-agent -> dead,
#     live -> alive, unknown -> unknown.
#   - fm_backend_agent_alive routes to the right per-backend classifier and
#     reports unknown for a backend with no verified classifier (never errors).
#   - bin/fm-bootstrap.sh's secondmate_liveness_sweep respawns a confidently
#     DEAD secondmate (killing the stale endpoint first, since the tmux
#     adapter refuses to create a same-named window over a live one), leaves
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
FM_TEST_REAL_NODE=$(command -v node)
export FM_TEST_REAL_NODE
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-secondmate-liveness)

# --- unit level: fm_backend_tmux_agent_alive --------------------------------

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
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_tmux_agent_alive_classifies() {
  local fb

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-claude" claude)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = alive ] \
    || fail "a live claude foreground process should classify as alive"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-codex" codex)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = alive ] \
    || fail "a live codex foreground process should classify as alive"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-opencode" opencode)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = alive ] \
    || fail "a live opencode foreground process should classify as alive"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-grok" grok)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = alive ] \
    || fail "a live grok foreground process should classify as alive"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-zsh" zsh)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = dead ] \
    || fail "a bare zsh foreground process should classify as dead"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-bash" bash)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = dead ] \
    || fail "a bare bash foreground process should classify as dead"

  # Defensive: this adapter strips a leading login-shell dash even though real
  # tmux 3.6a was observed to already normalize #{pane_current_command} itself
  # (docs/tmux-backend.md "Agent liveness probe").
  fb=$(make_probe_tmux "$TMP_ROOT/tmux-dashzsh" -zsh)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = dead ] \
    || fail "a defensively-stripped login-shell name should still classify as dead"

  # A bare interpreter name is ambiguous (pi's own launcher execs into a
  # generic "node" process - docs/tmux-backend.md "Known gap") - must be
  # unknown, never dead, so the sweep can never respawn on a false-dead read.
  fb=$(make_probe_tmux "$TMP_ROOT/tmux-node" node)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = unknown ] \
    || fail "an ambiguous bare-interpreter (node) foreground process should classify as unknown, never dead"

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-vim" vim)
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_agent_alive sess:win' "$ROOT")" = unknown ] \
    || fail "an unrecognized foreground process should classify as unknown"

  pass "fm_backend_tmux_agent_alive: alive/dead/unknown classification"
}

# --- unit level: fm_backend_herdr_agent_alive -------------------------------
# Reuses the already-verified fm_backend_herdr_pane_agent_state husk
# classifier (docs/herdr-backend.md "Respawn idempotency" /
# "Agent liveness probe reuses the husk classifier"); this wrapper's own
# mapping logic is tested in isolation by overriding that classifier, exactly
# as tests/fm-backend-herdr.test.sh already overrides `sleep` in a bash -c
# string for the same kind of isolated-unit assertion.

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

test_herdr_agent_alive_preserves_identity_state() {
  local out

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_identity_state() { printf "absent"; }; fm_backend_herdr_pane_agent_state() { printf "live"; }; fm_backend_herdr_agent_alive "sess:p1" "fm-secondmate"' "$ROOT")
  [ "$out" = dead ] || fail "a confirmed absent expected Herdr pane should classify as dead, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_identity_state() { printf "match"; }; fm_backend_herdr_pane_agent_state() { printf "live"; }; fm_backend_herdr_agent_alive "sess:p1" "fm-secondmate"' "$ROOT")
  [ "$out" = alive ] || fail "a matching Herdr pane should proceed to agent-state inspection, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_identity_state() { printf "mismatch"; }; fm_backend_herdr_pane_agent_state() { printf "live"; }; fm_backend_herdr_agent_alive "sess:p1" "fm-secondmate"' "$ROOT")
  [ "$out" = unknown ] || fail "a mismatched expected Herdr pane should classify as unknown, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_identity_state() { printf "unknown"; }; fm_backend_herdr_pane_agent_state() { printf "live"; }; fm_backend_herdr_agent_alive "sess:p1" "fm-secondmate"' "$ROOT")
  [ "$out" = unknown ] || fail "an inconclusive expected Herdr identity should classify as unknown, got '$out'"

  pass "fm_backend_herdr_agent_alive: preserves absent/match/mismatch/unknown identity states"
}

# --- unit level: the generic fm_backend_agent_alive dispatcher --------------

test_agent_alive_dispatcher_routes_and_falls_back() {
  local fb out

  fb=$(make_probe_tmux "$TMP_ROOT/dispatch-tmux" claude)
  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive tmux sess:win' "$ROOT")
  [ "$out" = alive ] || fail "dispatcher should route tmux to fm_backend_tmux_agent_alive, got '$out'"

  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_herdr_pane_agent_state() { printf "live"; }; fm_backend_agent_alive herdr sess:p1' "$ROOT")
  [ "$out" = alive ] || fail "dispatcher should route herdr to fm_backend_herdr_agent_alive, got '$out'"

  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive zellij sess:win' "$ROOT")
  [ "$out" = unknown ] || fail "dispatcher should report unknown for a backend with no verified classifier, got '$out'"

  pass "fm_backend_agent_alive: routes tmux/herdr correctly, unknown for an unverified backend"
}

# --- sweep level: bin/fm-bootstrap.sh's secondmate_liveness_sweep -----------

# make_toolchain <dir>: the fixed set of stubs bin/fm-bootstrap.sh's read-only
# diagnostics need to stay quiet (mirrors tests/fm-secondmate-sync.test.sh's
# make_fake_toolchain), MINUS tmux - callers add their own controllable tmux.
make_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" gh-axi chrome-devtools-axi lavish-axi
  cat > "$fakebin/node" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  */fm-contained-read.cjs)
    exec "${FM_TEST_REAL_NODE:?}" "$@"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/node"
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
  printf '%s\n' "$fakebin"
}

# make_liveness_tmux <dir>: a tmux stub whose #{pane_current_command} answer is
# read fresh from $FM_TEST_PANE_CMD on every query (so a test can flip it
# between bootstrap runs), and which logs every new-window/kill-window call
# (the only two operations a respawn performs) to $FM_TMUX_CALL_LOG.
make_liveness_tmux() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*)
          if [ -n "${FM_TEST_PANE_CMD_FILE:-}" ]; then
            pane_command=$(cat "$FM_TEST_PANE_CMD_FILE")
          else
            pane_command=${FM_TEST_PANE_CMD:-zsh}
          fi
          [ -z "${FM_TEST_PROBE_LOG:-}" ] || printf 'probe\n' >> "$FM_TEST_PROBE_LOG"
          printf '%s\n' "$pane_command"
          exit 0
          ;;
      esac
    done
    [ -f "${FM_TEST_ENDPOINT_FILE:?}" ]
    exit $? ;;
  kill-window)
    printf '%s\n' "$*" >> "${FM_TMUX_CALL_LOG:?}"
    rm -f "$FM_TEST_ENDPOINT_FILE"
    exit 0 ;;
  new-window)
    printf '%s\n' "$*" >> "${FM_TMUX_CALL_LOG:?}"
    touch "$FM_TEST_ENDPOINT_FILE"
    exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        case "$arg" in
          *account-native-launch*)
            native_path=$(printf '%s\n' "$arg" | sed -n "s#.*'\([^']*/account-native-launch\)'.*#\1#p")
            [ -z "$native_path" ] \
              || printf '%s\n' "${native_path%/account-native-launch}" > "${FM_MANAGED_NATIVE_DIR_FILE:?}"
            ;;
        esac
      fi
      prev=$arg
    done
    case "$*" in
      *' Enter')
        if [ -f "${FM_MANAGED_NATIVE_DIR_FILE:-/nonexistent}" ]; then
          native_dir=$(cat "$FM_MANAGED_NATIVE_DIR_FILE")
          touch "$native_dir/ready"
          (
            for _ in $(seq 1 200); do
              [ -f "$native_dir/go" ] && break
              sleep 0.05
            done
            [ ! -f "$native_dir/go" ] || touch "${FM_MANAGED_SESSION_REFRESHED:?}"
          ) </dev/null >/dev/null 2>&1 &
        fi
        ;;
    esac
    exit 0 ;;
  list-windows|has-session) exit 0 ;;
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
  {
    printf 'window=%s\n' "$window"
    printf 'kind=secondmate\n'
    printf 'harness=%s\n' "$harness"
    printf 'home=%s\n' "$home"
  } > "$w/home/state/$id.meta"
  touch "$w/home/state/.fake-endpoint"
}

run_bootstrap() {  # <fakebin> <home> <pane-cmd> <call-log> [extra env...] -> stdout
  local fb=$1 home=$2 cmd=$3 log=$4; shift 4
  PATH="$fb:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$home" \
    FM_ACCOUNT_ROUTING_TEST_LAB=firstmate-account-routing-test-lab-v1 \
    FM_TEST_PANE_CMD="$cmd" FM_TMUX_CALL_LOG="$log" \
    FM_TEST_ENDPOINT_FILE="$home/state/.fake-endpoint" \
    env "$@" "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

test_sweep_defers_confirmed_dead_unmanaged_secondmate() {
  local w fb tmuxfb log out
  w=$(new_world sweep-dead)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_contains "$out" "respawn deferred: unmanaged generation requires an explicit operator --no-account-routing decision" \
    "a bare-shell unmanaged secondmate did not fail closed"
  assert_contains "$(cat "$log")" "kill-window -t firstmate:fm-sm1" \
    "the stale endpoint must be killed before deferring recovery"
  assert_not_contains "$(cat "$log")" "new-window" \
    "a confirmed-dead unmanaged secondmate was automatically relaunched"
  pass "sweep: a confirmed-dead unmanaged secondmate requires operator routing authority"
}

test_sweep_rechecks_liveness_after_lifecycle_lock() {
  local w fb tmuxfb log out_file cmd_file probe_log lock_ready lock_release lock_pid bootstrap_pid out
  w=$(new_world sweep-lifecycle-recheck)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"
  out_file="$w/bootstrap.out"
  cmd_file="$w/pane-command"
  probe_log="$w/probes.log"
  lock_ready="$w/lock-ready"
  lock_release="$w/lock-release"
  printf 'zsh\n' > "$cmd_file"

  bash -c '
    . "$1"
    held=$(FM_ACCOUNT_LIFECYCLE_LOCK_WAIT_SECONDS=2 fm_account_lifecycle_lock_acquire "$2" sm1) || exit 1
    touch "$3"
    while [ ! -f "$4" ]; do sleep 0.05; done
    fm_account_lifecycle_lock_release "$held"
  ' _ "$ROOT/bin/fm-account-routing-lib.sh" "$w/home/state" "$lock_ready" "$lock_release" &
  lock_pid=$!
  for _ in $(seq 1 100); do [ -f "$lock_ready" ] && break; sleep 0.05; done
  [ -f "$lock_ready" ] || { kill "$lock_pid" 2>/dev/null || true; fail "lifecycle recheck test did not acquire its blocker lock"; }

  PATH="$tmuxfb:$fb:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$w/home" \
    FM_TEST_PANE_CMD_FILE="$cmd_file" FM_TEST_PROBE_LOG="$probe_log" \
    FM_TMUX_CALL_LOG="$log" FM_TEST_ENDPOINT_FILE="$w/home/state/.fake-endpoint" \
    FM_ACCOUNT_LIFECYCLE_LOCK_WAIT_SECONDS=5 "$ROOT/bin/fm-bootstrap.sh" > "$out_file" 2>&1 &
  bootstrap_pid=$!
  for _ in $(seq 1 100); do [ -s "$probe_log" ] && break; sleep 0.05; done
  [ -s "$probe_log" ] || {
    kill "$bootstrap_pid" "$lock_pid" 2>/dev/null || true
    fail "lifecycle recheck test never reached its initial dead probe"
  }
  printf 'claude\n' > "$cmd_file"
  touch "$lock_release"
  wait "$lock_pid" || fail "lifecycle recheck blocker failed"
  wait "$bootstrap_pid" || fail "lifecycle recheck bootstrap failed"
  out=$(cat "$out_file")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: already-live" \
    "secondmate recovery ignored the live under-lock recheck"
  [ ! -s "$log" ] || fail "stale pre-lock liveness killed or respawned the replacement endpoint: $(cat "$log")"
  [ "$(wc -l < "$probe_log" | tr -d ' ')" -ge 2 ] || fail "secondmate recovery did not probe again under the lifecycle lock"
  pass "sweep: lifecycle lock recheck prevents stale endpoint termination"
}

test_unmanaged_respawn_requires_explicit_operator_bypass() {
  local w fb tmuxfb log out
  w=$(new_world sweep-unmanaged-routing)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  mkdir -p "$w/home/config"
  printf 'enforce\n' > "$w/home/config/account-routing-mode"
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_contains "$out" "respawn deferred: unmanaged generation requires an explicit operator --no-account-routing decision" \
    "automatic recovery did not fail closed for an unmanaged secondmate"
  assert_not_contains "$(cat "$log")" "new-window" \
    "automatic recovery relaunched an unmanaged secondmate with the provider default identity"
  pass "unmanaged secondmate recovery requires an explicit operator bypass"
}

test_pending_rollback_recovery_bypasses_session_gate_and_retries() {
  local variant w fb tmuxfb log out fake_root meta
  for variant in profile profileless; do
    w=$(new_world "sweep-rollback-$variant")
    add_sm_home "$w" sm1 firstmate:fm-sm1
    meta="$w/home/state/sm1.meta"
    printf '%s\n' 'account_rollback_cleanup=pending' >> "$meta"
    if [ "$variant" = profile ]; then
      printf '%s\n' 'account_profile=claude-2' >> "$meta"
    fi
    fake_root="$w/fake-root"
    mkdir -p "$fake_root/bin"
    cat > "$fake_root/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    cat > "$fake_root/bin/fm-account-session-sync.sh" <<'SH'
#!/usr/bin/env bash
printf 'session-sync %s\n' "$*" >> "$FM_ROLLBACK_CALL_LOG"
exit 0
SH
    cat > "$fake_root/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'spawn %s\n' "$*" >> "$FM_ROLLBACK_CALL_LOG"
count=$(grep -c '^spawn ' "$FM_ROLLBACK_CALL_LOG")
meta="$FM_HOME/state/$1.meta"
if [ "$count" -eq 1 ]; then
  . "$FM_TEST_REAL_ROOT/bin/fm-account-routing-lib.sh"
  lock=${FM_ACCOUNT_LIFECYCLE_LOCK_HELD:?}
  start=$(fm_account_process_start_time "$$") || exit 1
  handoff=$(mktemp "$FM_HOME/state/.rollback-handoff.XXXXXX") || exit 1
  printf '%s\n%s\n' "$$" "$start" > "$handoff" || exit 1
  mv "$handoff" "$lock" || exit 1
  trap 'fm_account_lifecycle_lock_release "$lock" >/dev/null 2>&1 || true' EXIT
  tmp=$(mktemp "$FM_HOME/state/.rollback-test.XXXXXX") || exit 1
  grep -v '^account_rollback_cleanup=pending$' "$meta" > "$tmp" || exit 1
  mv "$tmp" "$meta" || exit 1
  exit 1
fi
[ -f "${FM_ACCOUNT_LIFECYCLE_LOCK_HELD:?}" ] || exit 9
printf 'fresh-lock %s\n' "$FM_ACCOUNT_LIFECYCLE_LOCK_HELD" >> "$FM_ROLLBACK_CALL_LOG"
exit 0
SH
    chmod +x "$fake_root/bin/"*.sh
    fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
    log="$w/calls.log"; : > "$log"

    out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log" \
      FM_ROOT_OVERRIDE="$fake_root" FM_ROLLBACK_CALL_LOG="$log" FM_TEST_REAL_ROOT="$ROOT")

    grep -q '^spawn sm1 --secondmate --resume-account$' "$log" \
      || fail "$variant rollback recovery did not enter rollback-first resume: $(cat "$log")"
    if [ "$variant" = profile ]; then
      assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: rollback reconciled and respawned" \
        "$variant rollback recovery did not converge in the liveness sweep"
      assert_contains "$(cat "$log")" "fresh-lock" \
        "$variant rollback recovery reused the child-released lifecycle lock instead of acquiring a fresh one"
      [ "$(grep -c '^spawn sm1 --secondmate --resume-account$' "$log")" -eq 2 ] \
        || fail "profile rollback recovery did not retry the restored managed generation"
      [ "$(grep -c '^session-sync ' "$log")" -eq 1 ] \
        || fail "profile rollback recovery did not redo session sync exactly once under its fresh lock"
    else
      assert_contains "$out" "rollback reconciled; respawn deferred: restored unmanaged generation requires an explicit operator --no-account-routing decision" \
        "profileless rollback recovery did not fail closed after restoring unmanaged metadata"
      assert_not_contains "$(cat "$log")" "session-sync" \
        "profileless rollback recovery unexpectedly ran managed session synchronization"
      assert_not_contains "$(cat "$log")" "spawn sm1 --secondmate --no-account-routing" \
        "profileless rollback recovery automatically used the provider default identity"
    fi
  done
  pass "pending rollback recovery resumes only restored managed generations"
}

test_sweep_parent_skips_release_after_spawn_handoff() {
  local w fb tmuxfb log out fake_root sleeper_pid lock
  w=$(new_world sweep-parent-skip-release)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  printf 'account_profile=claude-1\n' >> "$w/home/state/sm1.meta"
  fake_root="$w/fake-root"
  mkdir -p "$fake_root/bin"
  cat > "$fake_root/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fake_root/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
set -u
. "$FM_TEST_REAL_ROOT/bin/fm-account-routing-lib.sh"
lock=${FM_ACCOUNT_LIFECYCLE_LOCK_HELD:?}
sleep 30 </dev/null >/dev/null 2>&1 &
pid=$!
start=$(fm_account_process_start_time "$pid") || exit 1
handoff=$(mktemp "$FM_HOME/state/.parent-skip-handoff.XXXXXX") || exit 1
printf '%s\n%s\n' "$pid" "$start" > "$handoff" || exit 1
mv "$handoff" "$lock" || exit 1
printf '%s\n' "$pid" > "$FM_PARENT_SKIP_PID"
exit 0
SH
  cat > "$fake_root/bin/fm-account-session-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake_root/bin/"*.sh
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"
  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log" \
    FM_ROOT_OVERRIDE="$fake_root" FM_TEST_REAL_ROOT="$ROOT" FM_PARENT_SKIP_PID="$w/sleeper-pid")
  sleeper_pid=$(cat "$w/sleeper-pid" 2>/dev/null || true)
  lock="$w/home/state/.account-lifecycle-sm1.lock"
  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: respawned" \
    "parent treated a successfully handed-off lock as its own release failure"
  if [ -z "$sleeper_pid" ] || ! kill -0 "$sleeper_pid" 2>/dev/null; then
    fail "handoff simulation did not leave its child owner alive"
  fi
  [ "$(sed -n '1p' "$lock" 2>/dev/null)" = "$sleeper_pid" ] \
    || fail "parent released or replaced the child-owned lifecycle lock"
  kill "$sleeper_pid" 2>/dev/null || true
  wait "$sleeper_pid" 2>/dev/null || true
  rm -f "$lock"
  pass "sweep: parent skips release after lifecycle ownership handoff"
}

test_enforced_recovery_sweep_installs_meta_with_inherited_lock() {
  local w workspace primary_tip spawn_root fb tmuxfb fake_root fake_af log out meta account_task native_dir_file refreshed
  w=$(new_world sweep-enforced-inherited-lock)
  add_sm_home "$w" sm1 firstmate:fm-sm1 claude
  primary_tip=$(git -C "$ROOT" rev-parse HEAD)
  rm -rf "$w/sm1"
  git clone -q --no-checkout "$ROOT" "$w/sm1"
  git -C "$w/sm1" branch --force main "$primary_tip"
  git -C "$w/sm1" checkout -q --detach "$primary_tip"
  mkdir -p "$w/sm1/bin" "$w/sm1/data" "$w/sm1/state" "$w/sm1/config" "$w/sm1/projects"
  printf '%s\n' sm1 > "$w/sm1/.fm-secondmate-home"
  printf 'charter\n' > "$w/sm1/data/charter.md"
  workspace=$(cd "$w/sm1" && pwd -P)
  meta="$w/home/state/sm1.meta"
  account_task=fm-test-sm1-a1234
  mkdir -p "$w/home/data/sm1"
  printf -- '- sm1 - test secondmate (home: %s; scope: test; projects: ; added 2026-07-13)\n' \
    "$workspace" > "$w/home/data/secondmates.md"
  cat >> "$meta" <<EOF
worktree=$workspace
project=$workspace
mode=secondmate
yolo=off
tasktmp=/tmp/fm-sm1
account_pool=claude-crew
account_profile=claude-2
account_task=$account_task
account_attempt=a1234
provider_session_id=sess-$account_task
generation_id=account:$account_task:a1234
EOF
  printf 'enforce\n' > "$w/home/config/account-routing-mode"

  spawn_root="$w/spawn-root"
  git clone -q --no-checkout "$ROOT" "$spawn_root"
  git -C "$spawn_root" checkout -q -B main "$primary_tip"
  git -C "$spawn_root" remote set-url origin "file://$spawn_root"
  git -C "$w/sm1" remote set-url origin "file://$spawn_root"
  fake_root="$w/fake-root"
  mkdir -p "$fake_root/bin"
  cat > "$fake_root/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
FM_ROOT_OVERRIDE="$FM_TEST_SPAWN_ROOT" "$FM_TEST_SPAWN_ROOT/bin/fm-spawn.sh" "$@" > "$FM_MANAGED_SPAWN_OUT" 2>&1
status=$?
cat "$FM_MANAGED_SPAWN_OUT"
exit "$status"
SH
  cat > "$fake_root/bin/fm-account-session-sync.sh" <<'SH'
#!/usr/bin/env bash
FM_ROOT_OVERRIDE="$FM_TEST_REAL_ROOT" exec "$FM_TEST_REAL_ROOT/bin/fm-account-session-sync.sh" "$@"
SH
  cat > "$fake_root/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake_root/bin/"*.sh

  fake_af="$w/agent-fleet"
  cat > "$fake_af" <<'SH'
#!/usr/bin/env bash
set -u
task=
pool=claude-crew
profile=claude-2
workspace=${FM_MANAGED_WORKSPACE:-}
prev=
for arg in "$@"; do
  case "$prev" in --task) task=$arg ;; --pool) pool=$arg ;; --profile) profile=$arg ;; --workspace) workspace=$arg ;; esac
  prev=$arg
done
case "$*" in
  '--format json contract') printf '{"contract_version":2}\n' ;;
  *' lease recover '*)
    printf '{"schema":1,"task":"%s","pool":"%s","profile":"%s","provider":"claude","workspace":"%s","decision_reason":"fake","quota_fresh":true,"headroom_percent":5,"active_lease_count":0,"degraded":false}\n' "$task" "$pool" "$profile" "$workspace"
    ;;
  *' session status '*)
    updated=2026-07-13T00:00:00Z
    event_seq=1
    if [ -f "${FM_MANAGED_SESSION_REFRESHED:-/nonexistent}" ]; then
      updated=2026-07-13T00:00:01Z
      event_seq=2
    fi
    printf '{"schema":2,"task":"%s","profile":"%s","provider":"claude","pool":"%s","workspace":"%s","session_id":"sess-%s","session_event_seq":%s,"updated_at":"%s"}\n' "$task" "$profile" "$pool" "$workspace" "$task" "$event_seq" "$updated"
    ;;
  *' lease release '*) printf '{"ok":true}\n' ;;
  *) exit 64 ;;
esac
SH
  chmod +x "$fake_af"

  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"
  native_dir_file="$w/native-dir"
  refreshed="$w/session-refreshed"
  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log" \
    FM_ROOT_OVERRIDE="$fake_root" FM_TEST_REAL_ROOT="$ROOT" \
    FM_TEST_SPAWN_ROOT="$spawn_root" \
    FM_AGENT_FLEET_BIN="$fake_af" FM_ACCOUNT_SESSION_WAIT_SECONDS=2 \
    FM_MANAGED_WORKSPACE="$workspace" \
    FM_MANAGED_NATIVE_DIR_FILE="$native_dir_file" FM_MANAGED_SESSION_REFRESHED="$refreshed" \
    FM_MANAGED_SPAWN_OUT="$w/spawn.out")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: respawned" \
    "enforced secondmate recovery did not complete through the bootstrap sweep: $(cat "$w/spawn.out" 2>/dev/null)"
  assert_grep "account_task=$account_task" "$meta" \
    "enforced secondmate recovery did not install the inherited-lock generation"
  assert_no_grep '^account_rollback_cleanup=' "$meta" \
    "enforced secondmate recovery did not commit its metadata installation"
  assert_present "$refreshed" "enforced secondmate recovery never crossed its fresh SessionStart gate"
  pass "sweep: enforced secondmate recovery installs metadata under the inherited lifecycle lock"
}

test_sweep_leaves_alive_secondmate_untouched() {
  local w fb tmuxfb log out
  w=$(new_world sweep-alive)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: already-live" \
    "a live claude foreground process should be reported as already-live"
  [ ! -s "$log" ] || fail "an already-live secondmate must never be killed or respawned: $(cat "$log")"
  pass "sweep: an already-live secondmate is left untouched (no kill, no respawn)"
}

test_sweep_never_acts_on_inconclusive_reading() {
  local w fb tmuxfb log out
  w=$(new_world sweep-unknown)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  # "node" is the ambiguous bare-interpreter case (docs/tmux-backend.md
  # "Known gap") - ANY reading less than confident-dead must never respawn.
  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" node "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: liveness probe inconclusive" \
    "an inconclusive (unknown) probe reading should be reported as skipped"
  [ ! -s "$log" ] || fail "an inconclusive reading must NEVER trigger a kill or respawn (would risk a duplicate agent): $(cat "$log")"
  pass "sweep: a transient/unknown probe reading is reported but never acted on"
}

test_sweep_never_acts_on_unverified_harness_dead_reading() {
  local w fb tmuxfb log out
  w=$(new_world sweep-unverified-harness)
  add_sm_home "$w" sm1 firstmate:fm-sm1 custom-agent
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: liveness probe inconclusive" \
    "an unverified harness should not let a dead-looking endpoint become actionable"
  [ ! -s "$log" ] || fail "an unverified harness must NEVER trigger a kill or respawn: $(cat "$log")"
  pass "sweep: an unverified harness makes a dead-looking probe inconclusive"
}

test_sweep_converges_no_retouch_once_alive() {
  local w fb tmuxfb log out1 out2
  w=$(new_world sweep-idempotent)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  # Round 1: a dead unmanaged generation is killed and deferred.
  out1=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")
  assert_contains "$out1" "respawn deferred: unmanaged generation requires an explicit operator --no-account-routing decision" \
    "round 1 should defer the dead unmanaged secondmate"
  assert_not_contains "$(cat "$log")" "new-window" \
    "round 1 automatically relaunched the unmanaged generation"

  # Round 2: the (now-respawned) secondmate is genuinely alive - a second
  # sweep must converge to a pure no-op, not respawn again.
  : > "$log"
  out2=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log")
  assert_contains "$out2" "SECONDMATE_LIVENESS: secondmate sm1: already-live" "round 2 should see the now-live secondmate and stop touching it"
  [ ! -s "$log" ] || fail "round 2 must not re-kill or re-respawn an already-live secondmate: $(cat "$log")"
  pass "sweep: a later live secondmate is never re-touched after deferred recovery"
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

  assert_contains "$out" "CREW_HARNESS_OVERRIDE: codex" \
    "detect-only should still execute fm-bootstrap.sh's read-only diagnostics"
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

if [ "${FM_TEST_FOCUSED:-}" = review-round-10 ]; then
  test_sweep_defers_confirmed_dead_unmanaged_secondmate
  test_sweep_rechecks_liveness_after_lifecycle_lock
  test_unmanaged_respawn_requires_explicit_operator_bypass
  test_pending_rollback_recovery_bypasses_session_gate_and_retries
  test_enforced_recovery_sweep_installs_meta_with_inherited_lock
  exit 0
fi

if [ "${FM_TEST_FOCUSED:-}" = review-round-16 ]; then
  test_pending_rollback_recovery_bypasses_session_gate_and_retries
  test_sweep_parent_skips_release_after_spawn_handoff
  test_enforced_recovery_sweep_installs_meta_with_inherited_lock
  exit 0
fi

test_tmux_agent_alive_classifies
test_herdr_agent_alive_maps_pane_agent_state
test_herdr_agent_alive_preserves_identity_state
test_agent_alive_dispatcher_routes_and_falls_back
test_sweep_defers_confirmed_dead_unmanaged_secondmate
test_sweep_rechecks_liveness_after_lifecycle_lock
test_unmanaged_respawn_requires_explicit_operator_bypass
test_pending_rollback_recovery_bypasses_session_gate_and_retries
test_sweep_parent_skips_release_after_spawn_handoff
test_enforced_recovery_sweep_installs_meta_with_inherited_lock
test_sweep_leaves_alive_secondmate_untouched
test_sweep_never_acts_on_inconclusive_reading
test_sweep_never_acts_on_unverified_harness_dead_reading
test_sweep_converges_no_retouch_once_alive
test_sweep_skipped_under_detect_only
test_sweep_noop_with_no_secondmate_meta

echo "# all fm-secondmate-liveness tests passed"
