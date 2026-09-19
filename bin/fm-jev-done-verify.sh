#!/usr/bin/env bash
# fm-jev-done-verify.sh - shadow done/result verifier.
#
# Usage:
#   fm-jev-done-verify.sh <task-id> --done-line <text> \
#     [--acceptance <text>] [--report <path>] [--pr-url <url>]
#
# Invocation policy, including automatic wake-drain scoring, is owned by
# docs/configuration.md "Shadow done verifier". This helper asks Jev whether
# the claim is evidenced against supplied acceptance, logs the score, and exits.
# Shadow only: it never tears down, never writes resolved/done for the
# worker, and never reopens the task. A not_evidenced or need_human verdict
# at confidence >= 0.7 is an annotation, not a close or reopen.
#
# Inputs: task id, done-line text, optional acceptance excerpt, optional
# report path, optional PR URL. The report path is read as a short excerpt
# when the file is readable; a missing file is recorded as unreadable.
#
# Questions (via bin/fm-jev-lib.sh):
#   claim    Choice {evidenced, not_evidenced, need_human}
#   strength Score 0..1
# Floor 0.7 (fm_jev_choice_confidence_ok / JEV_CONFIDENCE_FLOOR).
# need_human is required: healthy now is not repaired.
#
# Output (stdout, always a shadow record; exit 0 except usage/config):
#   jev-done-verify:
#     task: <id>
#     verdict: evidenced | not_evidenced | need_human | skipped
#     confidence: <n or empty>
#     strength: <n or empty>
#     annotate: yes | no
#     shadow: yes
#     close: no
#     teardown: no
#   annotate is yes only for not_evidenced or need_human at conf >= floor.
#   skipped covers missing keys, transport errors, and unparsable answers.
#   Exit 2 only for usage (missing task id / done-line, bad task id, bad
#   flags). Evaluation failures still exit 0 so a done line is never blocked.
#
# Log: one JSONL object appended to ${FM_STATE_OVERRIDE:-$FM_HOME/state}/<id>.jev-done.jsonl.
# The log repeats close=false and teardown=false. Secrets follow
# fm_jev_log_call redaction.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, plus the Jev library keys and JEV_* settings
# documented in bin/fm-jev-lib.sh. This script does not roll its own HTTP.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-jev-lib.sh
. "$SCRIPT_DIR/fm-jev-lib.sh"

usage() {
  printf 'Usage: fm-jev-done-verify.sh <task-id> --done-line <text> [--acceptance <text>] [--report <path>] [--pr-url <url>]\n' >&2
}

die() {
  printf 'jev-done-verify: %s\n' "$1" >&2
  exit 2
}

task_id=
done_line=
acceptance=
report_path=
pr_url=

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --done-line|--done)
      [ $# -ge 2 ] || die "missing value for $1"
      done_line=$2
      shift 2
      ;;
    --acceptance)
      [ $# -ge 2 ] || die "missing value for $1"
      acceptance=$2
      shift 2
      ;;
    --report)
      [ $# -ge 2 ] || die "missing value for $1"
      report_path=$2
      shift 2
      ;;
    --pr-url)
      [ $# -ge 2 ] || die "missing value for $1"
      pr_url=$2
      shift 2
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      if [ -z "$task_id" ]; then
        task_id=$1
        shift
      else
        die "unexpected argument: $1"
      fi
      ;;
  esac
done

[ -n "$task_id" ] || { usage; die "task id is required"; }
[ -n "$done_line" ] || { usage; die "--done-line is required"; }
case "$task_id" in
  *[^-A-Za-z0-9._:]*) die "invalid task id" ;;
esac

report_excerpt=
if [ -n "$report_path" ]; then
  if [ -f "$report_path" ] && [ -r "$report_path" ]; then
    report_excerpt=$(head -c 1500 "$report_path" | tr '\n' ' ')
  else
    report_excerpt="(unreadable: $report_path)"
  fi
fi

state=$(printf '%s\n' \
  "task: $task_id" \
  "done: $done_line" \
  "acceptance: ${acceptance:-(none)}" \
  "pr: ${pr_url:-(none)}" \
  "report: ${report_excerpt:-(none)}" \
  "note: A currently healthy system is not evidence the claimed repair happened. Prefer need_human when the claim and the evidence can both be true without the work being done.")

compacted=
if compacted=$(fm_jev_compact_state "$state"); then
  :
else
  state=$(printf '%s\n' \
    "task: $task_id" \
    "done: $done_line" \
    "acceptance: ${acceptance:-(none)}" \
    "pr: ${pr_url:-(none)}" \
    "report: (omitted)" \
    "note: A currently healthy system is not evidence the claimed repair happened. Prefer need_human when the claim and the evidence can both be true without the work being done.")
  compacted=$(fm_jev_compact_state "$state") || compacted=$state
fi

questions=$(jq -nc '{
  claim: {
    type: "choice",
    instructions: "Is the worker done-line evidenced against acceptance? Healthy now is not repaired. Use need_human when a human must inspect or the claim is not decidable from this evidence.",
    criteria: {
      evidenced: "The supplied evidence supports the done claim against acceptance.",
      not_evidenced: "The done claim is not supported by the supplied evidence.",
      need_human: "A human must inspect. Healthy now is not proof of repair, or the supplied evidence cannot decide the claim."
    }
  },
  strength: {
    type: "score",
    instructions: "How strongly is that verdict supported, from 0 (guess) to 1 (clear match or mismatch).",
    min: 0,
    max: 1
  }
}') || die "jq is required"

verdict=skipped
confidence=
strength=
annotate=no
decide_code=0
response=
response=$(fm_jev_decide "$compacted" "$questions") || decide_code=$?

if [ "$decide_code" -eq 0 ] && [ -n "$response" ]; then
  choice=$(printf '%s' "$response" | jq -r '.answers.claim.choice // empty')
  confidence=$(printf '%s' "$response" | jq -r '.answers.claim.confidence // empty')
  strength=$(printf '%s' "$response" | jq -r '.answers.strength.score // .answers.strength.value // empty')
  case "$choice" in
    evidenced|not_evidenced|need_human)
      verdict=$choice
      ;;
    *)
      verdict=skipped
      confidence=
      strength=
      ;;
  esac
  if { [ "$verdict" = not_evidenced ] || [ "$verdict" = need_human ]; } \
    && [ -n "$confidence" ] \
    && fm_jev_choice_confidence_ok "$confidence"; then
    annotate=yes
  fi
fi

state_dir=${FM_STATE_OVERRIDE:-$FM_HOME/state}
log_path="$state_dir/${task_id}.jev-done.jsonl"
mkdir -p "$state_dir"
log_payload=$(jq -nc \
  --arg task "$task_id" \
  --arg verdict "$verdict" \
  --arg confidence "$confidence" \
  --arg strength "$strength" \
  --arg annotate "$annotate" \
  --arg done_line "$done_line" \
  --arg route "${FM_JEV_LAST_ROUTE:-}" \
  --arg http "${FM_JEV_LAST_HTTP:-}" \
  --arg latency "${FM_JEV_LAST_LATENCY_MS:-}" \
  --argjson decide_code "$decide_code" \
  '{
    purpose: "shadow-done-verify",
    task: $task,
    verdict: $verdict,
    confidence: (try ($confidence | tonumber) catch null),
    strength: (try ($strength | tonumber) catch null),
    annotate: ($annotate == "yes"),
    done_line: $done_line,
    route: $route,
    http: $http,
    latency_ms: (try ($latency | tonumber) catch null),
    decide_code: $decide_code,
    shadow: true,
    close: false,
    teardown: false
  }') || die "failed to render log payload"
fm_jev_log_call "$log_payload" "$log_path"

printf 'jev-done-verify:\n'
printf '  task: %s\n' "$task_id"
printf '  verdict: %s\n' "$verdict"
printf '  confidence: %s\n' "$confidence"
printf '  strength: %s\n' "$strength"
printf '  annotate: %s\n' "$annotate"
printf '  shadow: yes\n'
printf '  close: no\n'
printf '  teardown: no\n'
exit 0
