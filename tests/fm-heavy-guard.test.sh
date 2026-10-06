#!/usr/bin/env bash
# Behavior tests for bin/fm-heavy-guard.sh and its fm-test-run.sh integration.
#
# Heavy suites (acceptance, end-to-end, full-regression) are the ones that leak
# tens of gigabytes. These cover the decision itself, the posture and runner
# config, refusal text, and runner refusal through family and script selection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-heavy-guard.sh"
RUNNER="$ROOT/bin/fm-test-run.sh"

test_status_reports_local_by_default() {
  local root cfg out
  root=$(fm_test_tmproot fm-heavy-guard)
  cfg="$root/config"
  mkdir -p "$cfg"
  out=$(FM_CONFIG_OVERRIDE="$cfg" "$GUARD" status) || fail "status exited non-zero"
  case "$out" in *"posture=local"*) ;; *) fail "expected local default posture: $out" ;; esac
  pass "unconfigured posture is local"
}

test_local_posture_allows_heavy_work() {
  local root cfg out
  root=$(fm_test_tmproot fm-heavy-guard)
  cfg="$root/config"
  mkdir -p "$cfg"
  out=$(FM_CONFIG_OVERRIDE="$cfg" "$GUARD" check --selection all --family live-harness-optin --path foo-e2e.test.sh) \
    || fail "local posture must allow heavy work"
  case "$out" in *"allowed:"*) ;; *) fail "expected an allowed verdict: $out" ;; esac
  pass "local posture allows heavy selections"
}

test_remote_posture_refuses_and_names_the_runner() {
  local root cfg rc out
  root=$(fm_test_tmproot fm-heavy-guard)
  cfg="$root/config"
  mkdir -p "$cfg"
  printf 'remote-only\n' > "$cfg/heavy-suites"
  printf '/campaign/runner\n' > "$cfg/campaign-runner"
  for args in "--selection all" "--lane heavy" "--family real-herdr-gated" "--path acceptance.cjs" "--token acceptance" "--token e2e"; do
    rc=0
    # shellcheck disable=SC2086 # the argument string is a deliberate, fixed word list.
    out=$(FM_CONFIG_OVERRIDE="$cfg" "$GUARD" check $args 2>&1) || rc=$?
    [ "$rc" -eq 3 ] || fail "'$args' should refuse with exit 3, got $rc"
    case "$out" in *"/campaign/runner"*) ;; *) fail "'$args' refusal did not name the runner: $out" ;; esac
    case "$out" in *"GCP campaign VM"*) ;; *) fail "'$args' refusal did not name the VM: $out" ;; esac
  done
  # A light selection stays allowed under the same posture.
  FM_CONFIG_OVERRIDE="$cfg" "$GUARD" check --lane portable-serial --family pure-contract-unit \
    || fail "a light selection must stay allowed under remote-only"
  pass "remote posture refuses every heavy class and names the campaign VM"
}

test_unknown_posture_is_an_error() {
  local root cfg rc out
  root=$(fm_test_tmproot fm-heavy-guard)
  cfg="$root/config"
  mkdir -p "$cfg"
  printf 'sometimes\n' > "$cfg/heavy-suites"
  rc=0
  out=$(FM_CONFIG_OVERRIDE="$cfg" "$GUARD" status 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an unknown posture should be an error"
  case "$out" in *"unknown posture"*) ;; *) fail "unknown-posture error was not named: $out" ;; esac
  pass "an unknown posture refuses instead of guessing"
}

test_path_classification_is_delimited() {
  local root cfg out
  root=$(fm_test_tmproot fm-heavy-guard)
  cfg="$root/config"
  mkdir -p "$cfg"
  printf 'remote-only\n' > "$cfg/heavy-suites"
  printf '/campaign/runner\n' > "$cfg/campaign-runner"
  out=$(FM_CONFIG_OVERRIDE="$cfg" "$GUARD" check --path "path/to/acceptance.cjs" 2>&1) \
    && fail "acceptance.cjs should be refused" || true
  case "$out" in *"suite acceptance.cjs"*) ;; *) fail "suite name not reported: $out" ;; esac
  printf 'remote-only\n' > "$cfg/heavy-suites"
  FM_CONFIG_OVERRIDE="$cfg" "$GUARD" check --path "tests/fm-unit.test.sh" \
    || fail "an unrelated test path must not classify heavy"
  pass "path classification matches heavy suite names only"
}

test_runner_refuses_heavy_family_under_remote_posture() {
  local root cfg rc out
  root=$(fm_test_tmproot fm-heavy-guard)
  cfg="$root/config"
  mkdir -p "$cfg"
  printf 'remote-only\n' > "$cfg/heavy-suites"
  printf '/campaign/runner\n' > "$cfg/campaign-runner"
  rc=0
  out=$(cd "$ROOT" && FM_CONFIG_OVERRIDE="$cfg" timeout 30 "$RUNNER" --family live-harness-optin 2>&1) || rc=$?
  [ "$rc" -eq 3 ] || fail "runner should refuse the heavy family with exit 3, got $rc"
  case "$out" in *"/campaign/runner"*) ;; *) fail "runner refusal did not name the runner: $out" ;; esac
  pass "fm-test-run refuses a heavy family before executing it"
}

test_runner_refuses_direct_heavy_scripts() {
  local root cfg script rc out
  root=$(fm_test_tmproot fm-heavy-guard)
  cfg="$root/config"
  mkdir -p "$cfg"
  printf 'remote-only\n' > "$cfg/heavy-suites"
  for script in tests/fm-pi-codex-native.test.sh tests/fm-backend-herdr-smoke.test.sh; do
    rc=0
    out=$(FM_CONFIG_OVERRIDE="$cfg" timeout 30 "$RUNNER" "$script" 2>&1) || rc=$?
    [ "$rc" -eq 3 ] || fail "direct $script should refuse with exit 3, got $rc: $out"
  done
  pass "direct script selection honors every heavy family"
}

test_runner_executes_light_work_in_a_box() {
  local root cfg fakebin out rc
  root=$(fm_test_tmproot fm-heavy-guard)
  cfg="$root/config"
  mkdir -p "$cfg"
  fakebin=$(fm_fakebin "$root")
  printf 'remote-only\n' > "$cfg/heavy-suites"
  printf 'test=2G\n' > "$cfg/memory-box"
  printf 'printf "ok - fixture executed\\n"\n' > "$root/unit.test.sh"
  cat > "$fakebin/systemd-run" <<'SH'
#!/bin/sh
cap= swap=
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
  case "$1" in
    MemoryMax=*) cap=${1#*=} ;;
    MemorySwapMax=*) swap=${1#*=} ;;
  esac
  shift
done
shift
[ "$swap" = 0 ] || exit 1
if [ "$1" != true ]; then
  [ "$cap" = 2147483648 ] || exit 1
  printf '%s\n' boxed > "$BOX_LOG"
fi
exec "$@"
SH
  chmod +x "$fakebin/systemd-run"
  rc=0
  out=$(PATH="$fakebin:$PATH" BOX_LOG="$root/box.log" FM_CONFIG_OVERRIDE="$cfg" \
    "$RUNNER" --jobs 1 --per-script-timeout-secs 5 "$root/unit.test.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "light runner execution failed: $out"
  [ "$(cat "$root/box.log")" = boxed ] || fail "script did not reach the configured scope"
  case "$out" in *"ok - fixture executed"*) ;; *) fail "light script was not executed: $out" ;; esac
  pass "light scripts still execute through the configured memory box"
}

test_remote_alias_is_rejected() {
  local root cfg rc
  root=$(fm_test_tmproot fm-heavy-guard)
  cfg="$root/config"
  mkdir -p "$cfg"
  printf 'remote\n' > "$cfg/heavy-suites"
  rc=0
  FM_CONFIG_OVERRIDE="$cfg" "$GUARD" status >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "undocumented remote alias must be rejected"
  pass "only remote-only is accepted as the remote posture"
}

test_status_reports_local_by_default
test_local_posture_allows_heavy_work
test_remote_posture_refuses_and_names_the_runner
test_unknown_posture_is_an_error
test_path_classification_is_delimited
test_runner_refuses_heavy_family_under_remote_posture
test_runner_refuses_direct_heavy_scripts
test_remote_alias_is_rejected
test_runner_executes_light_work_in_a_box
