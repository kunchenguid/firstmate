#!/usr/bin/env bash
# Behavior tests for bin/fm-mem-protection-install.sh.
#
# The installer owns the reproducible host policy, so these pin the generated
# artifacts (earlyoom args, the one-minute timer unit, the heavy-suite posture)
# through its `print` interface and exercise the config-only subcommands against
# a temporary home. `install` and `revert` themselves touch the real host and are
# not run here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$ROOT/bin/fm-mem-protection-install.sh"

test_print_contains_the_oom_policy() {
  local root home out
  root=$(fm_test_tmproot fm-mem-protection-install)
  home="$root/home"
  mkdir -p "$home"
  out=$("$INSTALLER" print --home "$home") || fail "print exited non-zero"
  case "$out" in *'-m 5'*) ;; *) fail "print omitted the 5 percent memory minimum" ;; esac
  case "$out" in *'-s 5'*) ;; *) fail "print omitted the 5 percent swap minimum" ;; esac
  case "$out" in *'--prefer'*) ;; *) fail "print omitted --prefer" ;; esac
  case "$out" in *'--avoid'*) ;; *) fail "print omitted --avoid" ;; esac
  local token
  for token in node MainThread pytest acceptance vitest; do
    case "$out" in *"$token"*) ;; *) fail "prefer list omitted $token" ;; esac
  done
  for token in omp sshd dockerd herdr clickhouse; do
    case "$out" in *"$token"*) ;; *) fail "avoid list omitted $token" ;; esac
  done
  pass "print carries the required prefer and avoid policy"
}

test_print_contains_the_timer_units() {
  local root home out
  root=$(fm_test_tmproot fm-mem-protection-install)
  home="$root/home"
  mkdir -p "$home"
  out=$("$INSTALLER" print --home "$home") || fail "print exited non-zero"
  case "$out" in *"OnUnitActiveSec=1min"*) ;; *) fail "timer is not one minute" ;; esac
  case "$out" in *"fm-mem-alert.timer"*) ;; *) fail "timer unit name missing" ;; esac
  case "$out" in *"Environment=FM_HOME=$home"*) ;; *) fail "service does not pin FM_HOME: $out" ;; esac
  case "$out" in *"fm-mem-alert.sh"*) ;; *) fail "service does not run the alert check" ;; esac
  case "$out" in *"check"*) ;; *) fail "service does not pass the check subcommand" ;; esac
  pass "print carries the one-minute alert units"
}

test_config_subcommands_round_trip() {
  local root home out
  root=$(fm_test_tmproot fm-mem-protection-install)
  home="$root/home"
  mkdir -p "$home"
  "$INSTALLER" install-config --home "$home" --runner /campaign/runner \
    || fail "install-config exited non-zero"
  [ "$(cat "$home/config/heavy-suites")" = remote-only ] || fail "heavy-suites not written"
  [ "$(cat "$home/config/campaign-runner")" = /campaign/runner ] || fail "campaign-runner not written"
  out=$("$INSTALLER" status --home "$home") || fail "status exited non-zero"
  case "$out" in *"config/heavy-suites: remote-only"*) ;; *) fail "status did not report the posture: $out" ;; esac
  "$INSTALLER" revert-config --home "$home" || fail "revert-config exited non-zero"
  [ ! -e "$home/config/heavy-suites" ] || fail "heavy-suites not removed"
  [ ! -e "$home/config/campaign-runner" ] || fail "campaign-runner not removed"
  pass "config subcommands write and remove the posture"
}

test_config_write_refuses_a_captain_edit() {
  local root home rc
  root=$(fm_test_tmproot fm-mem-protection-install)
  home="$root/home"
  mkdir -p "$home/config"
  printf 'keep-me\n' > "$home/config/heavy-suites"
  rc=0
  "$INSTALLER" install-config --home "$home" --runner /campaign/runner >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a differing existing value must not be replaced"
  [ "$(cat "$home/config/heavy-suites")" = keep-me ] || fail "the existing value was overwritten"
  pass "install-config never replaces a value it did not write"
}

test_status_runs_on_a_bare_home() {
  local root home out
  root=$(fm_test_tmproot fm-mem-protection-install)
  home="$root/home"
  mkdir -p "$home"
  out=$("$INSTALLER" status --home "$home") || fail "status exited non-zero"
  case "$out" in *"config/heavy-suites: absent"*) ;; *) fail "status did not report an absent posture: $out" ;; esac
  case "$out" in *"earlyoom"*) ;; *) fail "status did not report earlyoom: $out" ;; esac
  pass "status reports every part on a bare home"
}

test_print_contains_the_oom_policy
test_print_contains_the_timer_units
test_config_subcommands_round_trip
test_config_write_refuses_a_captain_edit
test_status_runs_on_a_bare_home
