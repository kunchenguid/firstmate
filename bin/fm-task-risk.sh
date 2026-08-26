#!/usr/bin/env bash
# fm-task-risk.sh - record Firstmate's explicit task-risk assessment.
#
# Usage:
#   fm-task-risk.sh set <task-id> --level low|medium|high --rationale <one line>
#
# This script owns the task-body record consumed by fm-fleet-snapshot.sh.
# It replaces any prior record from this script, preserves every other body
# line, archives the superseded body through tasks-axi, and never infers risk
# from priority, title, repository, or prose.
#
# Assessment rubric:
#   low     Narrow, reversible work with no meaningful security, privacy, data,
#           payment, production, or external-user impact.
#   medium  A contained change with a meaningful blast radius or rollback cost.
#   high    Irreversible or broad impact, or material security, privacy, data,
#           payment, production, compliance, or external-user consequences.
# Uncertainty raises the assessment when its consequence could be material.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"

RISK_STAGED=''
RISK_BODY_FILE=''

cleanup() {
  [ -z "$RISK_STAGED" ] || rm -f -- "$RISK_STAGED"
  [ -z "$RISK_BODY_FILE" ] || rm -f -- "$RISK_BODY_FILE"
}

trap cleanup EXIT

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

fail() {
  printf 'fm-task-risk: %s\n' "$*" >&2
  exit 1
}

validate_slug() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) fail "task id must be slug-shaped" ;;
  esac
}

validate_rationale() {
  [ -n "${1//[[:space:]]/}" ] || fail "rationale must not be empty"
  case "$1" in
    *$'\n'*|*$'\r'*) fail "rationale must be one line" ;;
  esac
  [ "${#1}" -le 240 ] || fail "rationale must be at most 240 characters"
}

shown_field() {  # <show-output> <field>
  printf '%s\n' "$1" | sed -n "s/^  $2: //p" | head -1
}

decode_body() {
  python3 -c '
import json
import sys

value = sys.stdin.read()
if value == "-":
    value = ""
elif value.startswith("\""):
    value = json.loads(value)
sys.stdout.write(value)
'
}

command_set() {
  local id=${1:-} level='' rationale='' shown encoded_body body staged body_file
  [ "$#" -ge 1 ] || { usage; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --level)
        shift
        level=${1:-}
        ;;
      --rationale)
        shift
        rationale=${1:-}
        ;;
      *)
        usage
        exit 2
        ;;
    esac
    shift
  done

  validate_slug "$id"
  case "$level" in low|medium|high) ;; *) fail "level must be low, medium, or high" ;; esac
  validate_rationale "$rationale"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required"
  if fm_backlog_backend_manual "$FM_HOME/config"; then
    fail "the manual backlog backend is selected; preserve this script header's record contract in the manual task-body edit"
  fi
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"

  shown=$(cd "$FM_HOME" && tasks-axi show "$id" --full 2>/dev/null) \
    || fail "task $id is absent from $FM_HOME/data/backlog.md"
  encoded_body=$(shown_field "$shown" body)
  body=$(printf '%s' "$encoded_body" | decode_body) \
    || fail "could not decode the existing body for $id"

  staged=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-task-risk.XXXXXX") \
    || fail "could not stage the risk assessment"
  body_file=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-task-risk-body.XXXXXX") \
    || fail "could not stage the existing task body"
  RISK_STAGED=$staged
  RISK_BODY_FILE=$body_file
  # Keep the task content in a file so it never shares a shell interpolation
  # boundary with the Python program that rewrites the owned block.
  printf '%s' "$body" > "$body_file"
  RISK_LEVEL="$level" RISK_RATIONALE="$rationale" \
    python3 - "$staged" "$body_file" <<'PY'
import os
import pathlib
import sys

marker = "Risk assessment recorded by fm-task-risk."
lines = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").splitlines()
kept = []
index = 0
while index < len(lines):
    if lines[index] == marker:
        index += 1
        if index < len(lines) and lines[index].startswith("Risk level: "):
            index += 1
        if index < len(lines) and lines[index].startswith("Risk rationale: "):
            index += 1
        while index < len(lines) and lines[index] == "":
            index += 1
        continue
    kept.append(lines[index])
    index += 1
while kept and kept[0] == "":
    kept.pop(0)
while kept and kept[-1] == "":
    kept.pop()
record = [
    marker,
    f"Risk level: {os.environ['RISK_LEVEL']}",
    f"Risk rationale: {os.environ['RISK_RATIONALE']}",
]
result = record + ([""] + kept if kept else [])
pathlib.Path(sys.argv[1]).write_text("\n".join(result) + "\n", encoding="utf-8")
PY
  rm -f -- "$body_file"
  RISK_BODY_FILE=''
  body_file=''
  if ! (cd "$FM_HOME" && tasks-axi update "$id" --body-file "$staged" --archive-body >/dev/null); then
    fail "could not record the risk assessment for $id"
  fi
  rm -f -- "$staged"
  RISK_STAGED=''
  printf 'risk: %s %s\n' "$id" "$level"
}

case "${1:-}" in
  set)
    shift
    command_set "$@"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
