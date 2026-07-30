# shellcheck shell=bash
# Shared tasks-axi backend selection and compatibility probe for bootstrap,
# teardown, and secondmate backlog handoff.
# Usage: . bin/fm-tasks-axi-lib.sh
# Compatible means tasks-axi --version reports 0.1.1 or newer,
# `tasks-axi update --help` exposes --archive-body for recoverable note rewrites,
# and `tasks-axi mv --help` exposes [<id>...] for atomic multi-ID moves required
# by secondmate handoffs (introduced in tasks-axi 0.2.2).
# `config/backlog-backend=manual` opts out of tasks-axi for routine firstmate
# backlog mutations, but validated secondmate handoffs always use `tasks-axi mv`.
# Absent or any other value keeps the default tasks-axi backend path, falling
# back to manual mutation when the tool is not compatible.
#
# Hidden backlog category (captain triage: do / defer / backlog / kill):
# A structured hold whose reason starts with "backlog:" is render-hidden from
# every routine status surface until revived (unhold) or listed explicitly.
# This lib owns the predicate and the human hint text; listing surfaces call it
# rather than re-stating the prefix. Explicit listing is bin/fm-backlog-list.sh
# --backlog (see that script's header). Deferred (hold-until / future) and
# parked (hold-kind parked without the backlog: reason prefix) stay visible.

FM_BACKLOG_HOLD_PREFIX='backlog:'
FM_BACKLOG_LIST_COMMAND='bin/fm-backlog-list.sh --backlog'

fm_tasks_axi_version_parts() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi --version 2>/dev/null) || return 1
  printf '%s\n' "$output" |
    sed -n 's/.*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2 \3/p' |
    head -1
}

fm_tasks_axi_compatible() {
  local parts major minor patch rest
  parts=$(fm_tasks_axi_version_parts) || return 1
  [ -n "$parts" ] || return 1
  major=${parts%% *}
  rest=${parts#* }
  minor=${rest%% *}
  patch=${rest##* }

  if [ "$major" -gt 0 ] ||
    { [ "$major" -eq 0 ] && [ "$minor" -gt 1 ]; } ||
    { [ "$major" -eq 0 ] && [ "$minor" -eq 1 ] && [ "$patch" -ge 1 ]; }; then
    fm_tasks_axi_update_has_archive_body && fm_tasks_axi_mv_has_multi_id
    return $?
  fi
  return 1
}

fm_tasks_axi_update_has_archive_body() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi update --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '--archive-body' >/dev/null
}

fm_tasks_axi_mv_has_multi_id() {
  local output
  command -v tasks-axi >/dev/null 2>&1 || return 1
  output=$(tasks-axi mv --help 2>&1) || return 1
  printf '%s\n' "$output" | grep -F -- '[<id>...]' >/dev/null
}

fm_backlog_backend_value() {
  local config_dir=$1 backend_file value
  backend_file="$config_dir/backlog-backend"
  if [ -f "$backend_file" ]; then
    value=$(tr -d '[:space:]' < "$backend_file" 2>/dev/null || true)
    [ -n "$value" ] || value=tasks-axi
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' tasks-axi
}

fm_backlog_backend_manual() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = manual ]
}

fm_tasks_axi_backend_available() {
  local config_dir=$1
  fm_backlog_backend_manual "$config_dir" && return 1
  fm_tasks_axi_compatible
}

# True when a hold reason is the hidden backlog triage category.
# Match is prefix-only and case-sensitive: "backlog: cold storage" matches;
# "Backlog: ..." or "deferred backlog later" do not.
fm_hold_reason_is_backlogged() {
  case "${1:-}" in
    "$FM_BACKLOG_HOLD_PREFIX"*) return 0 ;;
    *) return 1 ;;
  esac
}

# True when a markdown task title line carries (hold: backlog: ...).
fm_backlog_title_line_is_backlogged() {
  local line=${1:-} reason
  case "$line" in
    *"(hold:"*)
      reason=${line#*"(hold:"}
      reason=${reason#"${reason%%[![:space:]]*}"}
      case "$reason" in
        "$FM_BACKLOG_HOLD_PREFIX"*) return 0 ;;
      esac
      ;;
  esac
  return 1
}

# Print the one-line routine-surface hint, or nothing when count is zero.
# Callers pass the explicit list invocation operators should run (default is
# the firstmate backlog status view).
fm_backlog_hidden_hint() {
  local count=${1:-0}
  case "$count" in
    ''|*[!0-9]*) return 0 ;;
    0) return 0 ;;
  esac
  printf '%d backlogged hidden - use %s to list\n' "$count" "$FM_BACKLOG_LIST_COMMAND"
}

# List structured task ids in a backlog markdown file whose hold reason starts
# with "backlog:". One id per line, in file order. Free-form lines are ignored.
fm_backlogged_ids_from_file() {
  local path=$1
  [ -f "$path" ] || return 0
  awk -v prefix="$FM_BACKLOG_HOLD_PREFIX" '
    function is_task_title(line) {
      return line ~ /^[-*][[:space:]]+(\[[ xX]\][[:space:]]+)?[^[:space:]]+[[:space:]]+-[[:space:]]+/ \
        || line ~ /^[-*][[:space:]]+\*\*[^*]+\*\*[[:space:]]+-[[:space:]]+/
    }
    function task_id(line,   rest, id) {
      rest = line
      sub(/^[-*][[:space:]]+/, "", rest)
      if (rest ~ /^\[[ xX]\][[:space:]]+/) sub(/^\[[ xX]\][[:space:]]+/, "", rest)
      if (rest ~ /^\*\*[^*]+\*\*/) {
        sub(/^\*\*/, "", rest)
        sub(/\*\*.*/, "", rest)
        id = rest
      } else {
        id = rest
        sub(/[[:space:]].*/, "", id)
      }
      return id
    }
    function is_backlogged(line, reason) {
      reason = line
      sub(/^.*\(hold:[[:space:]]*/, "", reason)
      return index(reason, prefix) == 1
    }
    is_task_title($0) && is_backlogged($0) {
      id = task_id($0)
      if (id != "") print id
    }
  ' "$path"
}

# Count structured backlogged title lines in a backlog markdown file.
fm_backlogged_count_from_file() {
  local path=$1
  local n
  n=$(fm_backlogged_ids_from_file "$path" | awk 'END { print NR+0 }')
  printf '%s\n' "${n:-0}"
}

# Render backlog title lines for the explicit status view or session-start.
# This is the single owner of markdown classification, filtering, and hints.
fm_backlog_render_title_lines() {  # <path> <routine|backlog|include> <max> <status|session>
  local path=$1 mode=${2:-routine} max=${3:-0} style=${4:-status}
  awk \
    -v mode="$mode" \
    -v max="$max" \
    -v style="$style" \
    -v prefix="$FM_BACKLOG_HOLD_PREFIX" \
    -v list_command="$FM_BACKLOG_LIST_COMMAND" '
    function state_for_heading(line, heading) {
      heading = line
      sub(/^##[[:space:]]+/, "", heading)
      sub(/[[:space:]]+$/, "", heading)
      if (heading == "In flight") return "in_flight"
      if (heading == "Queued") return "queued"
      if (heading == "Done") return "done"
      return ""
    }
    function is_backlogged(line, reason) {
      reason = line
      sub(/^.*\(hold:[[:space:]]*/, "", reason)
      return index(reason, prefix) == 1
    }
    /^##[[:space:]]+/ {
      state = state_for_heading($0)
      if (state != "") {
        pending_heading = $0
        heading_pending = 1
      }
      next
    }
    state != "" && /^[-*][[:space:]]+/ {
      backlogged = is_backlogged($0)
      if (backlogged) hidden++
      keep = mode == "backlog" ? backlogged : (mode == "include" ? 1 : !backlogged)
      if (!keep) next
      total++
      if (max > 0 && shown >= max) next
      if (heading_pending) {
        print pending_heading
        heading_pending = 0
      }
      print $0
      shown++
      next
    }
    END {
      if (mode == "backlog") {
        if (hidden == 0) {
          print "(no backlogged items)"
        } else if (max > 0 && total > shown) {
          printf "(shown %d of %d backlogged item title line(s))\n", shown, total
        } else {
          printf "(shown %d backlogged item title line(s))\n", shown
        }
      } else if (mode == "include") {
        if (total == 0) {
          print "(no backlog item title lines found)"
        } else {
          printf "(shown %d of %d backlog item title line(s); includes backlogged)\n", shown, total
          if (max > 0 && total > shown) {
            printf "(truncated %d item(s); increase --limit for a larger listing)\n", total - shown
          }
        }
      } else {
        if (total == 0) {
          if (hidden > 0) {
            print "(no non-backlogged item title lines found)"
          } else {
            print "(no backlog item title lines found)"
          }
        } else if (style == "session") {
          printf "(shown %d of %d backlog item title line(s))\n", shown, total
          if (total > shown) {
            printf "(truncated %d item(s); increase FM_SESSION_START_BACKLOG_LIMIT for a larger startup listing)\n", total - shown
          }
        } else {
          printf "(shown %d of %d non-backlogged item title line(s))\n", shown, total
          if (max > 0 && total > shown) {
            printf "(truncated %d item(s); increase --limit for a larger listing)\n", total - shown
          }
        }
        if (hidden > 0) {
          printf "%d backlogged hidden - use %s to list\n", hidden, list_command
        }
      }
    }
  ' "$path"
}
