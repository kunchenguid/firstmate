#!/usr/bin/env bash
# fm-cost-summary-lib.sh - the close-out consumption summary written at
# teardown (data/cost-per-accepted-issue-scout/report.md section 3.2 B).
#
# fm_cost_summary_write <data-dir> <task-id> <meta-file> <kind> <pr-url> <landed>
# writes data/<task-id>/cost.json: a per-task artifact that SURVIVES teardown,
# exactly like a scout's own data/<id>/report.md (teardown's cleanup list
# never touches data/). It mirrors that existing survival mechanism rather
# than inventing a new one.
#
# Every field is copied from something a harness or firstmate already
# computed; this never starts a collector, a daemon, or a token proxy.
# Money is always list-price USD read verbatim from the harness's own cost
# accounting (Claude session cost-state, Pi session usage.cost.total), never
# cash and never MXN: a subscription's marginal cash cost is not recoverable
# from any record this fleet reads (report section 2.1). cash_mxn is always
# null. A field that cannot be read - jq missing, a sidecar unreadable or
# absent, no intake identity recorded (a pre-upgrade task) - is written as
# null with that meaning; nothing here estimates or converts.
#
# Consumption is scoped to session files under this task's frozen
# session_ptr (its worktree path) whose mtime is at/after intake_at, because
# a treehouse pool slot is reused across tasks (fm-teardown.sh's slot-reuse
# note) and an older session file left over from a prior occupant of the same
# worktree must never be folded into this task's total. This is a per-task
# aggregate across every session file that matches, not a per-incarnation
# breakdown: attributing each dollar to one specific harness/model
# incarnation would need session-to-incarnation correlation this fleet does
# not already compute, which is a new collector, not a copy of one.
#
# Best-effort throughout: nothing here ever fails or blocks teardown. A
# write that could produce nothing useful (no jq, no intake identity) still
# writes the file with the fields it has and nulls for the rest.

set -eu

_FM_COST_SUMMARY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_COST_SUMMARY_LIB_DIR="."
# shellcheck source=bin/fm-classify-lib.sh
. "$_FM_COST_SUMMARY_LIB_DIR/fm-classify-lib.sh"

fm_cost_claude_dir() {  # <worktree>
  printf '%s\n' "${HOME}/.claude/projects/$(printf '%s' "$1" | tr '/.' '--')"
}

fm_cost_pi_dir() {  # <worktree>
  printf '%s\n' "${HOME}/.pi/agent/sessions/--$(printf '%s' "${1#/}" | tr '/' '-')--"
}

_fm_cost_file_mtime_epoch() {  # <file>
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    LC_ALL=C /usr/bin/stat -f '%m' "$1" 2>/dev/null
  else
    LC_ALL=C stat -c '%Y' "$1" 2>/dev/null
  fi
}

# Sums one already-computed cost field per matching jsonl file (either the
# LAST value the file holds, for a cumulative field, or every value the file
# holds, for an incremental one), streamed rather than slurped so a large
# session file is never read whole into memory. Echoes a JSON number, or
# "null" when nothing was found or jq is unavailable.
fm_cost_sum_jq_field() {  # <dir> <mtime-lower-bound-iso8601> <jq-select-filter> <last-only: 0|1>
  local dir=$1 since=$2 filt=$3 last_only=$4 f v total found file_total file_found since_epoch file_epoch
  command -v jq >/dev/null 2>&1 || { printf 'null\n'; return 0; }
  [ -d "$dir" ] || { printf 'null\n'; return 0; }
  since_epoch=$(fm_utc_iso_to_epoch "$since") || since_epoch=0
  total=0
  found=0
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    file_epoch=$(_fm_cost_file_mtime_epoch "$f") || file_epoch=0
    [ -n "$file_epoch" ] || file_epoch=0
    [ "$file_epoch" -ge "$since_epoch" ] 2>/dev/null || continue
    file_total=0
    file_found=0
    while IFS= read -r v; do
      [ -n "$v" ] || continue
      case "$v" in null) continue ;; esac
      if [ "$last_only" = 1 ]; then
        file_total=$v
      else
        file_total=$(awk -v a="$file_total" -v b="$v" 'BEGIN { printf "%.10f", a + b }')
      fi
      file_found=1
    done < <(jq -c "$filt" "$f" 2>/dev/null)
    [ "$file_found" = 1 ] || continue
    found=1
    total=$(awk -v a="$total" -v b="$file_total" 'BEGIN { printf "%.10f", a + b }')
  done < <(find "$dir" -maxdepth 1 -type f -name '*.jsonl' 2>/dev/null)
  if [ "$found" -eq 1 ]; then
    printf '%s\n' "$total"
  else
    printf 'null\n'
  fi
}

# Claude's own cost-state event is a running total per session file, so only
# the LAST one per file counts; summing every cost-state line in one file
# would double-count that file's own history.
fm_cost_claude_usd_total() {  # <worktree> <since>
  local dir
  dir=$(fm_cost_claude_dir "$1")
  fm_cost_sum_jq_field "$dir" "$2" 'select(.type=="cost-state") | .totalCostUSD' 1
}

# Pi's usage.cost.total is incremental per turn (report section 1.5), so every
# matching value in a file is summed.
fm_cost_pi_usd_total() {  # <worktree> <since>
  local dir
  dir=$(fm_cost_pi_dir "$1")
  fm_cost_sum_jq_field "$dir" "$2" 'select(.message.usage.cost.total != null) | .message.usage.cost.total' 0
}

fm_cost_summary_json_str() {  # <value, possibly empty>
  [ -n "$1" ] && printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')" || printf 'null'
}

fm_cost_summary_write() {  # <data-dir> <task-id> <meta-file> <kind> <pr-url> <landed: true|false|null>
  local data_dir=$1 id=$2 meta=$3 kind=$4 pr=$5 landed=$6
  local wt intake_at intake_harness intake_model intake_effort intake_rule session_ptr
  local harness model effort spawn_gen since claude_usd pi_usd list_usd_total relaunched out_dir
  wt=$(fm_meta_get "$meta" worktree)
  intake_at=$(fm_meta_get "$meta" intake_at)
  intake_harness=$(fm_meta_get "$meta" intake_harness)
  intake_model=$(fm_meta_get "$meta" intake_model)
  intake_effort=$(fm_meta_get "$meta" intake_effort)
  intake_rule=$(fm_meta_get "$meta" intake_rule)
  session_ptr=$(fm_meta_get "$meta" session_ptr)
  harness=$(fm_meta_get "$meta" harness)
  model=$(fm_meta_get "$meta" model)
  effort=$(fm_meta_get "$meta" effort)
  spawn_gen=$(fm_meta_get "$meta" spawn_gen)
  if [ -z "$intake_harness" ]; then
    relaunched=null
  elif [ "$intake_harness" != "$harness" ] || [ "$intake_model" != "$model" ] || [ "$intake_effort" != "$effort" ]; then
    relaunched=true
  else
    relaunched=false
  fi
  claude_usd=null
  pi_usd=null
  if [ -n "$intake_at" ]; then
    since=$intake_at
    [ -z "$wt" ] || claude_usd=$(fm_cost_claude_usd_total "$wt" "$since")
    [ -z "$wt" ] || pi_usd=$(fm_cost_pi_usd_total "$wt" "$since")
  fi
  if [ "$claude_usd" = null ] && [ "$pi_usd" = null ]; then
    list_usd_total=null
  else
    list_usd_total=$(awk -v c="${claude_usd/null/0}" -v p="${pi_usd/null/0}" 'BEGIN { printf "%.10f", c + p }')
  fi
  out_dir="$data_dir/$id"
  mkdir -p "$out_dir" 2>/dev/null || return 0
  {
    printf '{\n'
    printf '  "task_id": %s,\n' "$(fm_cost_summary_json_str "$id")"
    printf '  "kind": %s,\n' "$(fm_cost_summary_json_str "$kind")"
    printf '  "generated_at": %s,\n' "$(fm_cost_summary_json_str "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
    printf '  "intake": {\n'
    printf '    "at": %s,\n' "$(fm_cost_summary_json_str "$intake_at")"
    printf '    "harness": %s,\n' "$(fm_cost_summary_json_str "$intake_harness")"
    printf '    "model": %s,\n' "$(fm_cost_summary_json_str "$intake_model")"
    printf '    "effort": %s,\n' "$(fm_cost_summary_json_str "$intake_effort")"
    printf '    "rule": %s,\n' "$(fm_cost_summary_json_str "$intake_rule")"
    printf '    "session_ptr": %s\n' "$(fm_cost_summary_json_str "$session_ptr")"
    printf '  },\n'
    printf '  "final": {\n'
    printf '    "harness": %s,\n' "$(fm_cost_summary_json_str "$harness")"
    printf '    "model": %s,\n' "$(fm_cost_summary_json_str "$model")"
    printf '    "effort": %s,\n' "$(fm_cost_summary_json_str "$effort")"
    printf '    "spawn_gen": %s\n' "$(fm_cost_summary_json_str "$spawn_gen")"
    printf '  },\n'
    printf '  "relaunched": %s,\n' "$relaunched"
    printf '  "consumption": {\n'
    printf '    "claude_list_usd_total": %s,\n' "$claude_usd"
    printf '    "pi_list_usd_total": %s,\n' "$pi_usd"
    printf '    "list_usd_total": %s,\n' "$list_usd_total"
    printf '    "note": "list-price USD from harness session cost accounting, summed across every session file under this task'"'"'s worktree modified at/after intake_at; a per-task aggregate, not a per-incarnation breakdown; never cash, never MXN"\n'
    printf '  },\n'
    printf '  "cash_mxn": null,\n'
    printf '  "accepted": {\n'
    printf '    "landed": %s,\n' "${landed:-null}"
    printf '    "pr": %s\n' "$(fm_cost_summary_json_str "$pr")"
    printf '  }\n'
    printf '}\n'
  } > "$out_dir/.cost.json.$$" 2>/dev/null && mv -f "$out_dir/.cost.json.$$" "$out_dir/cost.json" 2>/dev/null
  rm -f "$out_dir/.cost.json.$$" 2>/dev/null || true
  return 0
}
