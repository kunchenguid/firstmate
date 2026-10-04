#!/usr/bin/env bash
# Behavior tests for bin/fm-heavy-guard.sh and its fm-test-run.sh integration.
#
# Heavy suites (acceptance, end-to-end, full-regression) are the ones that leak
# tens of gigabytes. These cover the decision itself, the posture and runner
# config, the refusal text, and the two-sided runner integration: a remote-only
# posture refuses before execution, while a local posture still reaches
# execution (with live prompts forced off so the run spends nothing).
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

test_classify_names_heavy_tokens() {
  local root cfg out
  root=$(fm_test_tmproot fm-heavy-guard)
  cfg="$root/config"
  mkdir -p "$cfg"
  out=$(FM_CONFIG_OVERRIDE="$cfg" "$GUARD" classify acceptance e2e unit foo) \
    || fail "classify exited non-zero"
  printf '%s\n' "$out" | grep -qx 'heavy acceptance' || fail "acceptance should classify heavy"
  printf '%s\n' "$out" | grep -qx 'heavy e2e' || fail "e2e should classify heavy"
  printf '%s\n' "$out" | grep -qx 'light unit' || fail "unit should classify light"
  printf '%s\n' "$out" | grep -qx 'light foo' || fail "foo should classify light"
  pass "classify separates heavy from light tokens"
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
  for args in "--selection all" "--lane heavy" "--family real-herdr-gated" "--path acceptance.cjs"; do
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

test_runner_reaches_execution_under_local_posture() {
  local root cfg out rc
  root=$(fm_test_tmproot fm-heavy-guard)
  cfg="$root/config"
  mkdir -p "$cfg"
  # FM_LIVE=0 keeps the live guards from submitting prompts, so this proves the
  # local path reaches execution without spending anything.
  rc=0
  out=$(cd "$ROOT" && FM_CONFIG_OVERRIDE="$cfg" FM_LIVE=0 timeout 120 "$RUNNER" --family live-harness-optin 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "local posture should reach execution cleanly, got $rc"
  case "$out" in *"FM_TEST_SUMMARY"*) ;; *) fail "runner produced no summary: $out" ;; esac
  pass "fm-test-run reaches execution under the local posture"
}

test_status_reports_local_by_default
test_classify_names_heavy_tokens
test_local_posture_allows_heavy_work
test_remote_posture_refuses_and_names_the_runner
test_unknown_posture_is_an_error
test_path_classification_is_delimited
test_runner_refuses_heavy_family_under_remote_posture
test_runner_reaches_execution_under_local_posture
