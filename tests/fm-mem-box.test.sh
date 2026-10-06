#!/usr/bin/env bash
# Behavior tests for bin/fm-mem-box.sh.
#
# The memory box is the boundary that keeps one leaking worker or test from
# taking the host with it, so these cover the parts that decide the boundary:
# byte-cap resolution and per-lane config, the exact single-quote escaping the
# spawn path splices into a pane command, the real cgroup v2 limit when the host
# can delegate one, refusal when a box cannot be created, and the
# heavy-lane hand-off to bin/fm-heavy-guard.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

BOX="$ROOT/bin/fm-mem-box.sh"
DEFAULT_CAP=8589934592

test_default_cap_when_unconfigured() {
  local root cfg out
  root=$(fm_test_tmproot fm-mem-box)
  cfg="$root/config"
  mkdir -p "$cfg"
  out=$(FM_CONFIG_OVERRIDE="$cfg" "$BOX" cap test) || fail "cap exited non-zero with no config"
  [ "$out" = "$DEFAULT_CAP" ] || fail "expected builtin default $DEFAULT_CAP, got '$out'"
  pass "unconfigured lane resolves to the 8 GiB default"
}

test_per_lane_and_default_config() {
  local root cfg worker test_cap
  root=$(fm_test_tmproot fm-mem-box)
  cfg="$root/config"
  mkdir -p "$cfg"
  printf 'default=1G\nworker=2G\n' > "$cfg/memory-box"
  worker=$(FM_CONFIG_OVERRIDE="$cfg" "$BOX" cap worker) || fail "cap worker exited non-zero"
  test_cap=$(FM_CONFIG_OVERRIDE="$cfg" "$BOX" cap test) || fail "cap test exited non-zero"
  [ "$worker" = 2147483648 ] || fail "worker lane cap: expected 2147483648, got '$worker'"
  [ "$test_cap" = 1073741824 ] || fail "default cap: expected 1073741824, got '$test_cap'"
  pass "per-lane override and default are both honored"
}

test_env_cap_overrides_config() {
  local root cfg out
  root=$(fm_test_tmproot fm-mem-box)
  cfg="$root/config"
  mkdir -p "$cfg"
  printf 'default=1G\n' > "$cfg/memory-box"
  out=$(FM_CONFIG_OVERRIDE="$cfg" FM_MEM_BOX_CAP=4G "$BOX" cap test) \
    || fail "cap with FM_MEM_BOX_CAP exited non-zero"
  [ "$out" = 4294967296 ] || fail "expected 4294967296, got '$out'"
  pass "FM_MEM_BOX_CAP wins over configured caps"
}

test_malformed_config_is_a_hard_error() {
  local root cfg rc err
  root=$(fm_test_tmproot fm-mem-box)
  cfg="$root/config"
  mkdir -p "$cfg"
  printf 'default=bogus\n' > "$cfg/memory-box"
  rc=0
  err=$(FM_CONFIG_OVERRIDE="$cfg" "$BOX" cap test 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a malformed size should refuse"
  case "$err" in *"invalid size"*) ;; *) fail "malformed-size error was not named: $err" ;; esac
  printf 'not-a-pair\n' > "$cfg/memory-box"
  rc=0
  err=$(FM_CONFIG_OVERRIDE="$cfg" "$BOX" cap test 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a non key=value line should refuse"
  case "$err" in *"key=value"*) ;; *) fail "malformed-line error was not named: $err" ;; esac
  pass "malformed config refuses loudly instead of guessing a default"
}

test_box_applies_the_cgroup_limit() {
  local root cfg out supported unit
  root=$(fm_test_tmproot fm-mem-box)
  cfg="$root/config"
  mkdir -p "$cfg"
  supported=$(FM_CONFIG_OVERRIDE="$cfg" "$BOX" check | awk -F= '$1=="supported"{print $2}')
  if [ "$supported" != yes ]; then
    printf 'skip: memory box unsupported on this host (%s)\n' "$(uname -s)"
    return 0
  fi
  unit="fm-mem-box-test-$$.scope"
  # shellcheck disable=SC2016 # the substitution expands inside the boxed bash.
  out=$(FM_CONFIG_OVERRIDE="$cfg" FM_MEM_BOX_CAP=104857600 "$BOX" exec test --unit "$unit" -- \
    bash -c 'cat "/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)/memory.max"; systemctl --user show --property=ActiveState --value "$1"' _ "$unit") \
    || fail "boxed command exited non-zero"
  [ "$out" = "$(printf '104857600\nactive')" ] || fail "expected bounded named scope to be active, got '$out'"
  pass "boxed command runs under the configured cgroup memory limit"
}

test_unavailable_box_refuses_execution() {
  local root cfg rc out fakebin
  root=$(fm_test_tmproot fm-mem-box)
  cfg="$root/config"
  mkdir -p "$cfg"
  fakebin=$(fm_fakebin "$root")
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/systemd-run"
  chmod +x "$fakebin/systemd-run"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_CONFIG_OVERRIDE="$cfg" "$BOX" exec worker -- touch "$root/executed" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "unavailable box must refuse"
  [ ! -e "$root/executed" ] || fail "command ran outside a box"
  case "$out" in *"cgroup v2"*|*"systemd user manager"*) ;; *) fail "missing capability not named: $out" ;; esac
  pass "unavailable box refuses without executing the command"
}

test_portable_box_bounds_allocations_and_preserves_exit_status() {
  local root fakebin out rc
  root=$(fm_test_tmproot fm-mem-box-portable)
  fakebin=$(fm_fakebin "$root")
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/systemd-run"
  chmod +x "$fakebin/systemd-run"
  # The allocation exceeds a small real limit, without risking host memory.
  out=$(PATH="$fakebin:$PATH" FM_MEM_BOX_CAP=64M "$BOX" exec test -- python3 -c '
import resource
assert resource.getrlimit(resource.RLIMIT_AS) == (67108864, 67108864)
assert resource.getrlimit(resource.RLIMIT_NPROC) == (16384, 16384)
try:
    bytearray(128 * 1024 * 1024)
except MemoryError:
    print("allocation refused")
else:
    raise AssertionError("allocation escaped memory cap")
' 2>&1) || fail "portable allocation probe failed: $out"
  case "$out" in *"box=process-limits"*"allocation refused"*) ;; *) fail "portable box not observed: $out" ;; esac
  rc=0
  PATH="$fakebin:$PATH" FM_MEM_BOX_CAP=64M "$BOX" exec test -- bash -c 'exit 23' >/dev/null 2>&1 || rc=$?
  [ "$rc" = 23 ] || fail "portable box lost command exit status: $rc"
  pass "portable box applies real hard limits, denies excess allocation, and preserves exit status"
}

test_test_box_refuses_when_portable_limits_are_unavailable() {
  local root fakebin limit out rc
  root=$(fm_test_tmproot fm-mem-box-refusal)
  fakebin=$(fm_fakebin "$root")
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/systemd-run"
  chmod +x "$fakebin/systemd-run"
  for limit in v u; do
    # Model a shell lacking one limit capability, keeping the other real.
    cat > "$root/bash-env" <<'SH'
ulimit() {
  [ "$1" != "-$UNAVAILABLE_LIMIT" ] || return 1
  builtin ulimit "$@"
}
SH
    rc=0
    out=$(PATH="$fakebin:$PATH" BASH_ENV="$root/bash-env" UNAVAILABLE_LIMIT="$limit" \
      FM_MEM_BOX_CAP=64M "$BOX" exec test -- touch "$root/executed" 2>&1) || rc=$?
    [ "$rc" != 0 ] || fail "missing $limit limit accepted"
    [ ! -e "$root/executed" ] || fail "payload executed without both portable limits"
    case "$out" in *"portable address-space/process-count limits unavailable"*"refusing"*) ;; *) fail "refusal reason missing: $out" ;; esac
  done
  pass "test execution refuses if either portable limit cannot be applied"
}

test_spawn_carries_the_home_and_cap_into_the_pane() {
  local root home proj wt fakebin panelog command out
  root=$(fm_test_tmproot fm-mem-box)
  home="$root/home"
  proj="$root/project"
  wt="$root/wt"
  fm_test_spawn_home "$home" codex
  printf 'worker=2G\ntest=1G\n' > "$home/config/memory-box"
  fm_test_spawn_brief "$home" boxed-worker
  fm_git_worktree "$proj" "$wt" boxed-worker
  fakebin=$(fm_test_make_spawn_fakebin "$root/fake" codex)
  panelog="$root/pane.log"
  mv "$fakebin/systemctl" "$fakebin/systemctl-ok"
  cat > "$fakebin/systemctl" <<'SH'
#!/bin/sh
if [ ! -e "$SCOPE_PENDING" ]; then
  touch "$SCOPE_PENDING"
  printf 'inactive\n'
  exit 0
fi
exec "${0%/*}/systemctl-ok" "$@"
SH
  chmod +x "$fakebin/systemctl"
  SCOPE_PENDING="$root/scope.pending" FM_FAKE_PANE_LOG="$panelog" FM_FAKE_SCOPE_LOG="$root/observed-unit" fm_test_run_spawn "$home" "$wt" "$fakebin" boxed-worker "$proj" --mode no-mistakes --yolo off \
    || fail "spawn failed"
  command=$(grep '^exec env .*fm-mem-box.sh' "$panelog")
  [ -n "$command" ] || fail "pane received no box entry"
  cat > "$fakebin/pane-shell" <<'SH'
#!/bin/sh
printf '%s\n' "$FM_HOME" "$FM_CONFIG_OVERRIDE" "${FM_MEM_BOX_CAP-unset}"
exec "$BOX" exec test -- printf 'nested test ran\n'
SH
  mv "$fakebin/systemd-run" "$fakebin/systemd-run-ok"
  cat > "$fakebin/systemd-run" <<'SH'
#!/bin/sh
for arg do
  case "$arg" in --unit=*) printf '%s\n' "${arg#*=}" > "$UNIT_LOG" ;; esac
done
exec "${0%/*}/systemd-run-ok" "$@"
SH
  chmod +x "$fakebin/systemd-run" "$fakebin/pane-shell"
  out=$(FM_HOME="$root/stale" FM_CONFIG_OVERRIDE="$root/stale/config" FM_MEM_BOX_CAP=8G \
    BOX="$BOX" FM_FAKE_SYSTEMD_LOG="$root/scopes" UNIT_LOG="$root/started-unit" \
    SHELL="$fakebin/pane-shell" PATH="$fakebin:$PATH" bash -c "$command") || fail "pane entry failed"
  [ "$out" = "$(printf '%s\n' "$home" "$home/config" unset 'nested test ran')" ] || fail "pane used stale policy: $out"
  [ "$(cat "$root/scopes")" = "$(printf '%s\n' '2147483648 0' '1073741824 0')" ] || fail "nested test inherited worker cap"
  cmp "$root/started-unit" "$root/observed-unit" || fail "spawn observed a different scope from its pane"
  pass "spawned pane consumes worker cap and nested tests use their own lane cap"
}

test_heavy_lane_consults_the_guard() {
  local root cfg rc out
  root=$(fm_test_tmproot fm-mem-box)
  cfg="$root/config"
  mkdir -p "$cfg"
  printf 'remote-only\n' > "$cfg/heavy-suites"
  printf '/campaign/runner\n' > "$cfg/campaign-runner"
  rc=0
  out=$(FM_CONFIG_OVERRIDE="$cfg" "$BOX" exec heavy -- true 2>&1) || rc=$?
  [ "$rc" -eq 3 ] || fail "heavy lane should be refused with exit 3, got $rc"
  case "$out" in *"/campaign/runner"*) ;; *) fail "refusal did not name the campaign runner: $out" ;; esac
  rc=0
  FM_CONFIG_OVERRIDE="$cfg" "$BOX" exec worker -- true || rc=$?
  [ "$rc" -ne 3 ] || fail "worker lane was classified heavy"
  pass "heavy lane refuses under remote-only without classifying workers as heavy"
}

test_spawn_refuses_box_and_delivery_failures() {
  local root mode home proj wt fakebin out rc
  root=$(fm_test_tmproot fm-mem-box)
  for mode in unavailable scope export literal submit; do
    home="$root/$mode/home"
    proj="$root/$mode/project"
    wt="$root/$mode/wt"
    fm_test_spawn_home "$home" codex
    fm_test_spawn_brief "$home" failed-worker
    fm_git_worktree "$proj" "$wt" failed-worker
    fakebin=$(fm_test_make_spawn_fakebin "$root/$mode/fake" codex)
    mv "$fakebin/tmux" "$fakebin/tmux-ok"
    cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${FM_FAIL_DELIVERY:-}:$*" in
  export:*'export GOTMPDIR='*) exit 1 ;;
  literal:*'. '*launch.*.sh*) exit 1 ;;
esac
if [ "${FM_FAIL_DELIVERY:-}" = submit ] && [ "$#" -eq 4 ] &&
  [ "$1" = send-keys ] && [ "$4" = Enter ]; then
  exit 1
fi
exec "${0%/*}/tmux-ok" "$@"
SH
    chmod +x "$fakebin/tmux"
    rc=0
    if [ "$mode" = unavailable ]; then
      out=$(FM_FAKE_SYSTEMD_FAIL=1 fm_test_run_spawn "$home" "$wt" "$fakebin" failed-worker "$proj" --mode no-mistakes --yolo off) || rc=$?
      case "$out" in *"memory box unavailable"*) ;; *) fail "missing box not named: $out" ;; esac
    elif [ "$mode" = scope ]; then
      out=$(FM_FAKE_SCOPE_STATE=failed FM_FAKE_SCOPE_LOG="$root/scope.log" \
        FM_FAKE_PANE_LOG="$root/pane.log" FM_FAKE_LAUNCH_LOG="$root/launch.log" \
        fm_test_run_spawn "$home" "$wt" "$fakebin" failed-worker "$proj" --mode no-mistakes --yolo off) || rc=$?
      case "$out" in *"pane memory scope"*"did not start"*) ;; *) fail "scope failure not named: $out" ;; esac
      [ -s "$root/scope.log" ] || fail "scope state was not queried"
      [ ! -s "$root/launch.log" ] || fail "harness launch sent after scope failure"
      [ "$(awk '/^exec env .*fm-mem-box.sh/ { seen=1; next } seen { n++ } END { print n+0 }' "$root/pane.log")" = 0 ] || fail "launch environment sent after scope failure"
    else
      out=$(FM_FAIL_DELIVERY="$mode" fm_test_run_spawn "$home" "$wt" "$fakebin" failed-worker "$proj" --mode no-mistakes --yolo off) || rc=$?
      case "$out" in *"could not deliver"*|*"could not submit"*) ;; *) fail "delivery failure not named: $out" ;; esac
    fi
    [ "$rc" -ne 0 ] || fail "$mode failure reported successful spawn"
    case "$out" in *"spawned failed-worker"*) fail "$mode failure printed spawned" ;; esac
    [ ! -e "$home/state/failed-worker.meta" ] || fail "$mode failure retained a dispatched task record"
  done
  pass "unavailable boxes and failed launch delivery cannot publish spawn success"
}

test_default_cap_when_unconfigured
test_per_lane_and_default_config
test_env_cap_overrides_config
test_malformed_config_is_a_hard_error
test_box_applies_the_cgroup_limit
test_unavailable_box_refuses_execution
test_spawn_carries_the_home_and_cap_into_the_pane
test_heavy_lane_consults_the_guard
test_spawn_refuses_box_and_delivery_failures

test_portable_box_bounds_allocations_and_preserves_exit_status
test_test_box_refuses_when_portable_limits_are_unavailable
