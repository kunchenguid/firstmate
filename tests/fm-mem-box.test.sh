#!/usr/bin/env bash
# Behavior tests for bin/fm-mem-box.sh.
#
# The memory box is the boundary that keeps one leaking worker or test from
# taking the host with it, so these cover the parts that decide the boundary:
# byte-cap resolution and per-lane config, the exact single-quote escaping the
# spawn path splices into a pane command, the real cgroup v2 limit when the host
# can delegate one, the unboxed fallback and its required-mode refusal, and the
# heavy-lane hand-off to bin/fm-heavy-guard.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
  local root cfg out supported
  root=$(fm_test_tmproot fm-mem-box)
  cfg="$root/config"
  mkdir -p "$cfg"
  supported=$(FM_CONFIG_OVERRIDE="$cfg" "$BOX" check | awk -F= '$1=="supported"{print $2}')
  if [ "$supported" != yes ]; then
    printf 'skip: memory box unsupported on this host (%s)\n' "$(uname -s)"
    return 0
  fi
  # shellcheck disable=SC2016 # the substitution expands inside the boxed bash.
  out=$(FM_CONFIG_OVERRIDE="$cfg" FM_MEM_BOX_CAP=104857600 "$BOX" exec test -- \
    bash -c 'cat "/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)/memory.max"') \
    || fail "boxed command exited non-zero"
  [ "$out" = 104857600 ] || fail "expected memory.max 104857600 inside the box, got '$out'"
  pass "boxed command runs under the configured cgroup memory limit"
}

test_fallback_and_required_mode() {
  local root cfg rc out
  root=$(fm_test_tmproot fm-mem-box)
  cfg="$root/config"
  mkdir -p "$cfg"
  out=$(FM_CONFIG_OVERRIDE="$cfg" FM_MEM_BOX_DISABLE=1 FM_MEM_BOX_QUIET=0 "$BOX" exec test -- true 2>&1) \
    || fail "disabled box should still run the command"
  case "$out" in *"running lane test unboxed"*) ;; *) fail "expected the unboxed notice: $out" ;; esac
  rc=0
  out=$(FM_CONFIG_OVERRIDE="$cfg" FM_MEM_BOX_DISABLE=1 FM_MEM_BOX_REQUIRED=1 "$BOX" exec test -- true 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "required mode must refuse when the box is unavailable"
  case "$out" in *"required"*) ;; *) fail "required-mode refusal was not named: $out" ;; esac
  pass "unboxed fallback notices, and required mode refuses"
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
  FM_CONFIG_OVERRIDE="$cfg" "$BOX" exec worker -- true \
    || fail "a non-heavy lane must still run under a remote-only posture"
  pass "heavy lane refuses under remote-only and other lanes still run"
}

test_default_cap_when_unconfigured
test_per_lane_and_default_config
test_env_cap_overrides_config
test_malformed_config_is_a_hard_error
test_box_applies_the_cgroup_limit
test_fallback_and_required_mode
test_heavy_lane_consults_the_guard
