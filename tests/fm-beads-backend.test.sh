#!/usr/bin/env bash
# tests/fm-beads-backend.test.sh - beads as third backlog backend option.
# Tests backend selection and availability checks.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-tasks-axi-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-beads-backend)

# Test: fm_backlog_backend_value() returns beads when configured
test_beads_backend_value() {
  local config="$TMP_ROOT/config"
  mkdir -p "$config"

  # Test default (tasks-axi)
  value=$(fm_backlog_backend_value "$config")
  [ "$value" = "tasks-axi" ] || fail "default backend should be tasks-axi, got: $value"

  # Test explicit beads
  printf '%s' 'beads' > "$config/backlog-backend"
  value=$(fm_backlog_backend_value "$config")
  [ "$value" = "beads" ] || fail "beads backend when configured should return beads, got: $value"

  # Test manual
  printf '%s' 'manual' > "$config/backlog-backend"
  value=$(fm_backlog_backend_value "$config")
  [ "$value" = "manual" ] || fail "manual backend when configured should return manual, got: $value"
}

# Test: fm_beads_backend_available() checks config and task CLI
test_beads_backend_available() {
  local config="$TMP_ROOT/config-beads"
  mkdir -p "$config"

  # Test: beads not configured - should return false
  printf '%s' 'tasks-axi' > "$config/backlog-backend"
  if fm_beads_backend_available "$config"; then
    fail "fm_beads_backend_available should return false when beads not configured"
  fi

  # Test: beads configured but task CLI not found - should return false
  printf '%s' 'beads' > "$config/backlog-backend"
  if ! command -v task >/dev/null 2>&1; then
    if fm_beads_backend_available "$config"; then
      fail "fm_beads_backend_available should return false when task CLI not found"
    fi
    return 0
  fi

  # Test: beads configured and task CLI found - should return true if store is reachable
  if ! task list --limit 1 >/dev/null 2>&1; then
    # Store not reachable in test environment - that's OK
    return 0
  fi
  if ! fm_beads_backend_available "$config"; then
    fail "fm_beads_backend_available should return true when beads configured and task CLI works"
  fi
}

# Test: fm_tasks_axi_backend_available() returns false when beads is configured
test_tasks_axi_backend_false_for_beads() {
  local config="$TMP_ROOT/config-axi"
  mkdir -p "$config"

  printf '%s' 'beads' > "$config/backlog-backend"

  if fm_tasks_axi_backend_available "$config"; then
    fail "fm_tasks_axi_backend_available should return false when beads is configured"
  fi
}

# Test: backend value handles whitespace
test_backend_value_whitespace() {
  local config="$TMP_ROOT/config-ws"
  mkdir -p "$config"

  printf '%s' '  beads  ' > "$config/backlog-backend"
  value=$(fm_backlog_backend_value "$config")
  [ "$value" = "beads" ] || fail "backend value should strip whitespace, got: $value"
}

# Run all tests
test_beads_backend_value
test_beads_backend_available
test_tasks_axi_backend_false_for_beads
test_backend_value_whitespace

echo "ok - all beads backend tests passed"
