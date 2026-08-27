# shellcheck shell=bash
# fm-tasks-show-lib.sh - the single owner of reading a task out of the backlog.
# Usage: . bin/fm-tasks-show-lib.sh
#
# Sourced, never executed. Every caller that needs a task's title, state, hold
# kind, hold reason, or body reads it through these helpers, so the two encoding
# facts behind `tasks-axi show` live in exactly one place:
#   - a scalar field prints JSON-quoted whenever its text carries punctuation
#     that would otherwise be ambiguous, and
#   - "-" is the empty marker, not a one-character value.
# A second hand-rolled parser would drift from those the first time either
# changes, which is why this file exists rather than a copied sed line.
#
# Every read runs in the active FM_HOME, so a main home and a secondmate home
# each see their own backlog rather than whichever one the caller happened to
# be standing in.

# The backlog CLI, always against this home and optionally bounded by an absolute
# deadline supplied by callers that cannot block on a backlog read.
fm_tasks_axi() {
  local now remaining
  if [ -n "${FM_TASKS_AXI_DEADLINE:-}" ]; then
    case "$FM_TASKS_AXI_DEADLINE" in ''|*[!0-9]*) return 1 ;; esac
    now=$(date +%s) || return 1
    case "$now" in ''|*[!0-9]*) return 1 ;; esac
    remaining=$((FM_TASKS_AXI_DEADLINE - now))
    [ "$remaining" -gt 0 ] || return 124
    declare -F fm_run_timed >/dev/null 2>&1 || return 1
    (cd "${FM_HOME:-.}" && fm_run_timed "$remaining" tasks-axi "$@")
    return
  fi
  (cd "${FM_HOME:-.}" && tasks-axi "$@")
}

# One task's full record, or nonzero when no such task exists here.
fm_task_show() {  # <task-id>
  fm_tasks_axi show "$1" --full 2>/dev/null
}

fm_show_field() {  # <show-output> <field>
  printf '%s\n' "$1" | sed -n "s/^  $2: //p" | head -1
}

fm_decode_shown_value() {  # <shown-field>
  local value=$1
  case "$value" in
    \"*\")
      printf '%s' "$value" | perl -MJSON::PP -e '
        local $/;
        my $value = decode_json(<STDIN>);
        binmode STDOUT, ":raw";
        utf8::encode($value) if utf8::is_utf8($value);
        print $value;
      '
      ;;
    *) printf '%s' "$value" ;;
  esac
}

# Decode show-encoded scalar fields and normalize the empty marker.
fm_show_field_value() {  # <show-output> <field>
  local value
  value=$(fm_decode_shown_value "$(fm_show_field "$1" "$2")")
  [ "$value" != '-' ] || value=''
  printf '%s' "$value"
}

# Every still-open task id in this home's backlog, one per line. Extra arguments
# are passed straight to `tasks-axi list` as filters. The count and every returned
# row must agree before any ids are emitted, so a failed or malformed listing can
# never masquerade as an empty backlog.
fm_open_task_ids() {  # [<tasks-axi list flags>...]
  local output rc
  output=$(fm_tasks_axi list "$@" 2>/dev/null) || { rc=$?; return "$rc"; }
  printf '%s\n' "$output" | awk -F, '
    /^count: [0-9]+($| of [0-9]+ total$| \(showing first [0-9]+\)$)/ {
      value = $0
      sub(/^count: /, "", value)
      sub(/ .*/, "", value)
      count = value + 0
      seen_count++
      next
    }
    /^  [A-Za-z0-9._-]+,/ {
      id = $1
      sub(/^ +/, "", id)
      rows++
      if ($2 != "done") ids = ids (ids == "" ? "" : "\n") id
    }
    END {
      if (seen_count != 1 || rows != count) exit 65
      if (ids != "") print ids
    }
  '
}
