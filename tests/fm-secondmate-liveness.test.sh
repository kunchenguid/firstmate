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
  local dir=$1 comm=$2 window=${3:-win} fakebin process_comm
  process_comm=$comm
  fakebin=$(fm_fakebin "$dir")
  if [ "$comm" = omp ]; then
    process_comm="$fakebin/omp"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fakebin/omp"
    chmod +x "$fakebin/omp"
  fi
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
  case "\${1:-}" in
  send-keys)
    [ -z "\${FM_FAKE_SEND_LOG:-}" ] || printf '%s\n' "\$*" >> "\$FM_FAKE_SEND_LOG"
    exit 0
    ;;
  display-message)
    for a in "\$@"; do case "\$a" in *pane_current_command*) printf '%s\n' '$comm'; exit 0 ;; esac; done
    for a in "\$@"; do case "\$a" in *pane_pid*) printf '4242\n'; exit 0 ;; esac; done
    for a in "\$@"; do case "\$a" in *pane_tty*) printf '/dev/pts/42\n'; exit 0 ;; esac; done
    exit 0 ;;
  list-windows) printf '%s\n' '$window'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  "-axo pid=,ppid=") printf '1 0\\n4242 1\\n' ;;
  *"-o pid=,pgid=,tpgid=,comm="*) printf '4242 4242 4242 %s\\n' '$process_comm' ;;
  *"-o comm="*) printf '%s\\n' '$process_comm' ;;
  *"-o args="*) printf '%s\\n' '$process_comm' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

make_tree_probe_tmux() {
  local dir=$1 root_comm=$2 fakebin child_script child_executable
  fakebin=$(fm_fakebin "$dir")
  child_script="$fakebin/omp"
  child_executable="$fakebin/bun"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  display-message)
    for a in "\$@"; do case "\$a" in *pane_current_command*) printf '%s\\n' '$root_comm'; exit 0 ;; esac; done
    for a in "\$@"; do case "\$a" in *pane_pid*) printf '4242\\n'; exit 0 ;; esac; done
    for a in "\$@"; do case "\$a" in *pane_tty*) printf '/dev/pts/42\\n'; exit 0 ;; esac; done
    exit 0 ;;
  list-windows) printf '%s\\n' win ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
  case "\$*" in
  "-axo pid=,ppid=")
    if [ "\${FM_FAKE_PS_BAD:-0}" = 1 ]; then
      printf 'not-a-process-row\\n'
    elif [ "\${FM_FAKE_PS_REPARENTED:-0}" = 1 ]; then
      printf '1 0\\n4242 1\\n6161 1\\n'
    else
      printf '1 0\\n4242 1\\n5151 4242\\n6161 5151\\n'
    fi
    ;;
  *"-o pid=,pgid=,tpgid=,comm="*) printf '4242 4242 4242 %s\\n' '$root_comm' ;;
  *"-o comm="*)
    case "\$*" in *"-p 6161 "*|*"-p 6161"*) printf '%s\\n' '$child_executable' ;; *) printf '%s\\n' '$root_comm' ;; esac
    ;;
  *"-o args="*)
    case "\$*" in *"-p 6161 "*|*"-p 6161"*) printf '%s %s\\n' '$child_executable' '$child_script' ;; *) printf '%s\\n' '$root_comm' ;; esac
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fakebin/omp"
  chmod +x "$fakebin/omp"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fakebin/bun"
  chmod +x "$fakebin/bun"
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

test_tmux_canonical_omp_rejects_stale_endpoint() {
  local fb out
  fb=$(make_probe_tmux "$TMP_ROOT/tmux-canonical-omp-stale" claude)
  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win omp' "$ROOT")
  [ "$out" = ambiguous ] || fail "a canonical OMP endpoint relaunching as Claude must not remain alive, got '$out'"
  pass "tmux liveness: canonical OMP rejects a same-pane non-OMP relaunch"
}

test_tmux_canonical_omp_accepts_current_endpoint() {
  local fb out
  fb=$(make_probe_tmux "$TMP_ROOT/tmux-canonical-omp-live" omp)
  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win omp' "$ROOT")
  [ "$out" = alive ] || fail "a current canonical OMP endpoint must remain alive, got '$out'"
  pass "tmux liveness: current canonical OMP identity remains live"
}

test_tmux_canonical_non_omp_rejects_omp_input_and_busy() {
  local dir fb log state out status
  dir="$TMP_ROOT/tmux-canonical-non-omp-omp-relaunch"
  log="$dir/send.log"
  state="$dir/state"
  mkdir -p "$state"
  fb=$(make_probe_tmux "$dir" omp)
  PATH="$fb:$BASE_PATH" FM_FAKE_SEND_LOG="$log" \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_send_key tmux sess:win Escape label claude' "$ROOT" \
    >/dev/null 2>&1 || status=$?
  [ "${status:-0}" -ne 0 ] || fail "canonical Claude control must reject a same-pane OMP relaunch"
  [ ! -s "$log" ] || fail "canonical Claude control must not send a key to the OMP relaunch"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" task >/dev/null \
    || fail "could not seed canonical non-OMP busy state"
  out=$(PATH="$fb:$BASE_PATH" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$0/bin/fm-backend.sh"; . "$0/bin/fm-busy-lib.sh"; fm_busy_classify tmux sess:win claude task "$1"' \
    "$ROOT" "$state")
  [ "$out" = "unknown identity-mismatch" ] \
    || fail "canonical Claude busy state must reject a same-pane OMP relaunch, got '$out'"
  pass "tmux canonical non-OMP input and busy state reject an OMP relaunch"
}

test_tmux_key_rechecks_after_target_resolution() {
  local log out status
  log="$TMP_ROOT/tmux-key-toctou.log"
  out=$(FM_TEST_LOG="$log" bash -c '
    . "$0/bin/fm-backend.sh"
    fm_backend_endpoint_allows() { calls=$((calls + 1)); [ "$calls" -eq 1 ]; }
    tmux() {
      case "${1:-}" in
        display-message) return 0 ;;
        send-keys) printf "%s\n" "$*" >> "$FM_TEST_LOG" ;;
      esac
    }
    calls=0
    fm_backend_send_key tmux sess:win Escape label omp
  ' "$ROOT" 2>&1) || status=$?
  [ "${status:-0}" -ne 0 ] || fail "tmux key delivery must refuse endpoint drift after target resolution"
  [ ! -s "$log" ] || fail "tmux key delivery sent after the just-in-time identity check failed"
  pass "tmux key delivery reauthorizes immediately before transport"
}

test_tmux_canonical_omp_accepts_proven_clean_shell_exit() {
  local dir fb out state target id
  dir="$TMP_ROOT/tmux-canonical-omp-shell-exit"
  state="$dir/state"; id=canonical-omp-shell-exit; target="sess:fm-$id"
  mkdir -p "$state"
  printf '%s\n' g123 > "$state/$id.busy-gen"
  printf '%s\n' g123.test > "$state/$id.omp-session-run"
  printf '%s\n' g123.test > "$state/$id.omp-session-stop"
  fb=$(make_probe_tmux "$dir" zsh "fm-$id")
  out=$(PATH="$fb:$BASE_PATH" FM_STATE_OVERRIDE="$state" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux "$1" omp' "$ROOT" "$target")
  [ "$out" = dead ] || fail "a canonical OMP endpoint over a lone shell must classify as cleanly stopped, got '$out'"
  rm -f "$state/$id.omp-session-stop"
  out=$(PATH="$fb:$BASE_PATH" FM_STATE_OVERRIDE="$state" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux "$1" omp' "$ROOT" "$target")
  [ "$out" = ambiguous ] || fail "a lone shell without observed OMP terminal evidence must remain indeterminate, got '$out'"
  pass "tmux liveness: canonical OMP clean stop requires terminal evidence and a lone shell"
}

test_tmux_canonical_omp_rejects_symlinked_stop_evidence() {
  local dir fb out state target id file target_file
  dir="$TMP_ROOT/tmux-canonical-omp-symlink-evidence"
  state="$dir/state"; id=canonical-omp-symlink; target="sess:fm-$id"
  mkdir -p "$state"
  printf '%s\n' g123 > "$state/$id.busy-gen"
  printf '%s\n' g123.test > "$state/$id.omp-session-run"
  printf '%s\n' g123.test > "$state/$id.omp-session-stop"
  fb=$(make_probe_tmux "$dir" zsh "fm-$id")
  for file in busy-gen omp-session-run omp-session-stop; do
    target_file="$dir/$file-target"
    mv "$state/$id.$file" "$target_file"
    ln -s "$target_file" "$state/$id.$file"
    out=$(PATH="$fb:$BASE_PATH" FM_STATE_OVERRIDE="$state" \
      bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux "$1" omp' "$ROOT" "$target")
    [ "$out" = ambiguous ] || fail "a symlinked OMP $file marker must remain ambiguous, got '$out'"
    [ -L "$state/$id.$file" ] || fail "tmux replaced the symlinked OMP $file marker"
    rm -f "$state/$id.$file"
    mv "$target_file" "$state/$id.$file"
  done
  pass "tmux OMP stop evidence rejects symlinked generation, run, and stop markers"
}

test_tmux_raw_omp_is_not_verified() {
  local fb out
  fb=$(make_probe_tmux "$TMP_ROOT/tmux-raw-omp" omp)
  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win raw-omp 1' "$ROOT")
  [ "$out" = ambiguous ] || fail "a raw OMP launch must not classify as a verified live agent, got '$out'"
  pass "tmux liveness: raw OMP suppresses verified attribution while raw behavior stays conservative"
}

test_tmux_omp_endpoint_requires_target_inventory() {
  local fb out
  fb=$(make_failed_probe_tmux "$TMP_ROOT/tmux-omp-endpoint-unreadable" unreadable)
  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; if fm_backend_omp_endpoint_allows tmux sess:fm-omp omp; then printf allowed; else printf denied; fi' "$ROOT")
  [ "$out" = denied ] || fail "an unreadable tmux inventory must not authorize a canonical OMP endpoint"
  pass "tmux endpoint gate: exact target inventory precedes process identity"
}







test_tmux_control_rejects_stale_canonical_omp() {
  local fb status
  fb=$(make_tree_probe_tmux "$TMP_ROOT/tmux-control-canonical-omp-stale" claude "$TMP_ROOT/tmux-control-canonical-omp-stale/omp")
  PATH="$fb:$BASE_PATH" FM_FAKE_PS_OMP_PID=6161 \
    bash -c '. "$0/bin/fm-backend.sh"; fm_backend_send_key tmux sess:win Escape label omp' "$ROOT" >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "tmux control must reject a canonical OMP endpoint relaunching as Claude with a stale OMP child"
  pass "tmux control: foreground Claude plus a stale OMP child blocks lifecycle keys"
}

# --- unit level: fm_backend_herdr_agent_state -------------------------------

test_herdr_agent_state_preserves_husk_classifier() {
  local pane_state expected out

  for row in 'dead missing' 'no-agent dead' 'live alive' 'unknown unreadable'; do
    pane_state=${row%% *}
    expected=${row#* }
    out=$(FM_TEST_PANE_STATE="$pane_state" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "%s" "$FM_TEST_PANE_STATE"; }; fm_backend_herdr_agent_state "sess:p1"' "$ROOT")
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

  pass "fm_backend_agent_state: routes tmux/Herdr and preserves unsupported backends"
}

test_shared_input_dispatch_preserves_unproved_backends() {
  local backend out
  for backend in zellij orca cmux; do
    out=$(bash -c '
      . "$0/bin/fm-backend.sh"
      fm_backend_source() { return 0; }
      fm_backend_zellij_send_key() { printf zellij; }
      fm_backend_orca_send_key() { printf orca; }
      fm_backend_cmux_send_key() { printf cmux; }
      fm_backend_send_key "$1" sess:win Escape label claude
    ' "$ROOT" "$backend")
    [ "$out" = "$backend" ] || fail "unproved backend $backend should preserve its input path, got '$out'"
  done
  pass "shared input dispatch: non-tmux/Herdr backends preserve existing delivery"
}

test_tmux_submit_rechecks_endpoint_before_each_enter() {
  local log out
  log="$TMP_ROOT/tmux-submit-recheck.log"; : > "$log"
  out=$(FM_TEST_LOG="$log" bash -c '
    . "$0/bin/fm-backend.sh"
    . "$0/bin/fm-tmux-lib.sh"
    fm_backend_source() { return 0; }
    fm_backend_tmux_send_text_submit() { fm_tmux_submit_core "$@"; }
    fm_backend_omp_endpoint_allows() { calls=$((calls + 1)); [ "$calls" -lt 3 ]; }
    tmux() {
      case "${1:-}" in
        send-keys)
          case "$*" in
            *" -l "*) printf literal >> "$FM_TEST_LOG" ;;
            *) printf enter >> "$FM_TEST_LOG" ;;
          esac
          ;;
      esac
    }
    calls=0
    verdict=$(fm_tmux_submit_core sess:win hello 1 0 0 label omp)
    printf "%s\t%s" "$verdict" "$(cat "$FM_TEST_LOG")"
  ' "$ROOT")
  [ "$out" = $'unknown\tliteral' ] || fail "tmux must recheck before Enter and stop on endpoint drift, got '$out'"
  pass "tmux submit: endpoint identity is rechecked before every Enter"
}

test_tmux_submit_rechecks_endpoint_before_literal() {
  local log out
  log="$TMP_ROOT/tmux-submit-literal-recheck.log"; : > "$log"
  out=$(FM_TEST_LOG="$log" bash -c '
    . "$0/bin/fm-backend.sh"
    . "$0/bin/fm-tmux-lib.sh"
    calls=0
    fm_backend_omp_endpoint_allows() { calls=$((calls + 1)); [ "$calls" -eq 1 ]; }
    tmux() {
      case "${1:-}" in
        send-keys) printf "%s\n" "$*" >> "$FM_TEST_LOG" ;;
      esac
    }
    verdict=$(fm_tmux_submit_core sess:win hello 1 0 0 label omp)
    printf "%s\t%s" "$verdict" "$(cat "$FM_TEST_LOG")"
  ' "$ROOT")
  [ "$out" = $'unknown\t' ] || fail "tmux must reject literal input when canonical OMP identity is not authorized, got '$out'"
  pass "tmux submit: canonical OMP identity is rechecked immediately before literal text"
}


# --- sweep level: bin/fm-bootstrap.sh's secondmate_liveness_sweep -----------

# make_toolchain <dir>: the fixed set of stubs bin/fm-bootstrap.sh's read-only
# diagnostics need to stay quiet (mirrors tests/fm-secondmate-sync.test.sh's
# make_fake_toolchain), MINUS tmux - callers add their own controllable tmux.
make_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" node chrome-devtools-axi pi-signed
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
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
  printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' '0.2.4' ;;
  "update --help") printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  "mv --help") printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.25'
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
        *pane_pid*) printf '%s\n' 4242; exit 0 ;;
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
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  "-axo pid=,ppid=") printf '%s\n' '1 0' '4242 1' ;;
  *"-o comm="*) printf '%s\n' "${FM_TEST_PANE_CMD:-zsh}" ;;
  *"-o args="*) printf '%s\n' "${FM_TEST_PANE_CMD:-zsh}" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
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
}

run_bootstrap() {  # <fakebin> <home> <pane-cmd> <call-log> [extra env...] -> stdout
  local fb=$1 home=$2 cmd=$3 log=$4; shift 4
  PATH="$fb:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$home" \
    FM_TEST_PANE_CMD="$cmd" FM_TMUX_CALL_LOG="$log" \
    env "$@" "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

test_sweep_recovers_proven_dead_shell() {
  local w fb tmuxfb log out
  w=$(new_world sweep-dead)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log" FM_BOOTSTRAP_VERBOSE_FACTS=1)

  assert_contains "$out" "BOOTSTRAP_INFO: secondmate sm1 relaunched after confirmed agent absence on existing endpoint (backend=tmux)" \
    "a proven bare-shell endpoint was not reported as recovered"
  assert_contains "$(cat "$log")" "kill-window" \
    "the proven dead shell endpoint was not removed before respawn"
  assert_contains "$(cat "$log")" "new-window" \
    "the proven dead shell endpoint was not relaunched"
  pass "sweep: a proven bare-shell endpoint is recovered exactly once"
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

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" missing "$log")

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

  # Round 1: missing -> respawned silently (new-window logged).
  out1=$(run_bootstrap "$tmuxfb:$fb" "$w/home" missing "$log")
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

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" missing "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "with no kind=secondmate meta present, the sweep must print nothing"
  [ ! -s "$log" ] || fail "with no secondmate meta, no endpoint should ever be touched: $(cat "$log")"
  pass "sweep: a silent no-op with no kind=secondmate meta present (a secondmate home's own natural scoping)"
}

test_tmux_agent_state_classifies
test_tmux_agent_state_rejects_malformed_targets_before_probe
test_tmux_canonical_omp_rejects_stale_endpoint
test_tmux_canonical_omp_accepts_current_endpoint
test_tmux_canonical_non_omp_rejects_omp_input_and_busy
test_tmux_key_rechecks_after_target_resolution
test_tmux_canonical_omp_accepts_proven_clean_shell_exit
test_tmux_canonical_omp_rejects_symlinked_stop_evidence
test_tmux_raw_omp_is_not_verified
test_tmux_omp_endpoint_requires_target_inventory
test_tmux_control_rejects_stale_canonical_omp
test_herdr_agent_state_preserves_husk_classifier
test_agent_state_dispatcher_and_compatibility
test_shared_input_dispatch_preserves_unproved_backends
test_tmux_submit_rechecks_endpoint_before_each_enter
test_tmux_submit_rechecks_endpoint_before_literal
test_sweep_recovers_proven_dead_shell
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

echo "# all fm-secondmate-liveness tests passed"
