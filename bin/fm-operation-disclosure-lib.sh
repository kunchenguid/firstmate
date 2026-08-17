#!/usr/bin/env bash
# Shared stop-before-mutation receipt check.
#
# Every guarded public mutation calls this function after validating its closed
# argument grammar and before locks, durable records, Git, GitHub, or
# worker-runtime side effects.
# The Python owner implements the receipt contract documented in
# docs/prompt-runtime.md, then consumes each matching receipt atomically.

fm_operation_disclosure_issue() { # <operation> <task> [exact args...]
  local operation=$1 task=$2 output
  shift 2
  output=$(python3 "$SCRIPT_DIR/fm-operation-disclosure.py" disclose "$operation" "$task" -- "$@") || return
  printf '%s\n' "${output##*FM_DISCLOSURE_TOKEN=}"
}

fm_operation_disclosure_consume() { # <operation> <task> [exact original args...]
  local operation=$1 task=$2
  shift 2
  python3 "$SCRIPT_DIR/fm-operation-disclosure.py" consume "$operation" "$task" -- "$@"
}
