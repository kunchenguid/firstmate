#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
set -u

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-herdr-lab.sh
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}

# herdr_real_shell_io_ready: read-only readiness probe for real-herdr e2e tests.
# Requires bin/backends/herdr.sh to be sourced by the caller and HERDR_SESSION
# to name the caller's throwaway session. Some desktop shells expose a real
# herdr CLI but do not let the headless test pane observe typed input or run
# submitted shell text reliably; those hosts cannot prove these e2e contracts.
herdr_real_shell_io_ready() {
  local container_raw container seeded_tab ids pane target marker cap state
  marker="herdr-selfcheck-$$"
  container_raw=$(fm_backend_herdr_container_ensure /tmp 2>/dev/null) || {
    echo "skip: real herdr shell self-check could not ensure a workspace"
    return 1
  }
  container=${container_raw%%$'\t'*}
  seeded_tab=${container_raw#*$'\t'}
  ids=$(fm_backend_herdr_create_task "$container" "fm-herdr-selfcheck-$$" /tmp "$seeded_tab" 2>/dev/null) || {
    echo "skip: real herdr shell self-check could not create a task pane"
    return 1
  }
  read -r _ pane <<EOF
$ids
EOF
  target="${HERDR_SESSION:-default}:$pane"

  if ! fm_backend_herdr_send_text_line "$target" "echo $marker" >/dev/null 2>&1; then
    fm_backend_herdr_kill "$target" 2>/dev/null || true
    echo "skip: real herdr shell self-check could not submit text"
    return 1
  fi
  sleep 0.5
  cap=$(fm_backend_herdr_capture "$target" 20 2>/dev/null || true)
  case "$cap" in
    *"$marker"*) : ;;
    *)
      fm_backend_herdr_kill "$target" 2>/dev/null || true
      echo "skip: real herdr shell self-check could not read submitted output"
      return 1
      ;;
  esac

  if ! fm_backend_herdr_send_literal "$target" "$marker-pending" >/dev/null 2>&1; then
    fm_backend_herdr_kill "$target" 2>/dev/null || true
    echo "skip: real herdr shell self-check could not type literal text"
    return 1
  fi
  sleep 0.5
  state=$(fm_backend_herdr_composer_state "$target" 2>/dev/null || true)
  fm_backend_herdr_send_key "$target" Enter >/dev/null 2>&1 || true
  fm_backend_herdr_kill "$target" 2>/dev/null || true
  if [ "$state" != pending ]; then
    echo "skip: real herdr shell self-check could not observe pending input"
    return 1
  fi
  return 0
}
