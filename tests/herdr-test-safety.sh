#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
set -u

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-herdr-lab.sh
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

herdr_test_runner_lab() { # <session>
  { [ "${FM_TEST_HERDR_CAPABILITY:-}" = herdr-lab ] \
    || [ "${FM_TEST_HERDR_CAPABILITY:-}" = herdr-mixed ]; } \
    && [ -n "${FM_TEST_HERDR_LAB_SESSION:-}" ] \
    && [ "$1" = "$FM_TEST_HERDR_LAB_SESSION" ]
}

herdr_test_session() { # <label>
  if [ -n "${FM_TEST_HERDR_LAB_SESSION:-}" ]; then
    printf '%s\n' "$FM_TEST_HERDR_LAB_SESSION"
  else
    fm_herdr_lab_name "$1"
  fi
}

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

# Real-Herdr suites must never start or otherwise repair the captain's default
# session just to satisfy a test precondition. Treat a missing, unreadable, or
# stopped default as an unavailable external lab baseline and skip cleanly;
# the deterministic fm-herdr-lab unit suite owns refusal coverage.
herdr_test_lab_available() { # <session>
  if herdr_test_runner_lab "$1"; then
    return 0
  fi
  if fm_herdr_lab_require_default_running "$1" "isolated test setup"; then
    return 0
  fi
  echo "skip: default Herdr session is not running; isolated lab tests will not start or mutate it"
  return 1
}

herdr_test_prepare() { # <session>
  if herdr_test_runner_lab "$1"; then
    return 0
  fi
  fm_herdr_lab_prepare "$1"
}

herdr_test_stop() { # <session>
  if herdr_test_runner_lab "$1"; then
    FM_HERDR_LAB_STATE_DIR="${FM_HERDR_LAB_STATE_DIR:?}" \
      PATH="${FM_TEST_ORIGINAL_PATH:?}" \
      "${HERDR_LAB_HELPER:?}" stop "$1"
    return
  fi
  fm_herdr_lab_stop "$1"
}

herdr_test_provision() { # <session>
  if herdr_test_runner_lab "$1"; then
    FM_HERDR_LAB_STATE_DIR="${FM_HERDR_LAB_STATE_DIR:?}" \
      PATH="${FM_TEST_ORIGINAL_PATH:?}" \
      "${HERDR_LAB_HELPER:?}" provision "$1"
    return
  fi
  fm_herdr_lab_provision "$1"
}

herdr_safe_stop_and_delete() { # <session>
  if herdr_test_runner_lab "$1"; then
    return 0
  fi
  fm_herdr_lab_teardown "$1"
}
