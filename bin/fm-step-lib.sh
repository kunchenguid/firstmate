#!/usr/bin/env bash
# fm-step-lib.sh - sourced helpers for the worker step display.
#
# This file is the single owner of the step record format and the step-display
# switch. bin/fm-step.sh writes the record, bin/fm-fleet-snapshot.sh reads it
# into each task row, bin/fm-fleet-view.sh renders it, and bin/fm-brief.sh adds
# the worker's one-line plan instruction only while the display is on.
#
# Switch: config/step-display holds one word, `on` or `off`.
# An absent file, an empty file, or `on` means on.
# `off` means off: generated briefs and the fleet table match the setup that
# existed before the step display, and the step views report that the display is
# off. Any other value counts as off and prints one warning naming the file, so
# a mistyped fallback still falls back. Only exact `off` is silent.
#
# Record: state/<task-id>.step, one line per step start, appended in order:
#   <epoch> TAB <n> TAB <m> TAB <step name>
# <epoch> is the Unix time the worker started step <n> of a plan of <m> steps.
# The last valid line is the current step. Earlier lines name earlier steps.
# A line that does not match this shape is skipped by readers.
# The record is presentation data only. No watcher, wake, status, or
# current-state reader consumes it, so writing it never wakes the supervisor.
# Teardown removes it with the other per-task state.

# fm_step_display_mode <config-dir> - print `on` or `off`.
# A value other than on or off prints a warning to stderr and resolves to off.
fm_step_display_mode() {
  local file="$1/step-display" value
  [ -e "$file" ] || { printf 'on\n'; return 0; }
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    printf 'warning: %s is not a readable file; the step display is off\n' "$file" >&2
    printf 'off\n'
    return 0
  fi
  value=$(tr -d '[:space:]' < "$file")
  case "$value" in
    ''|on) printf 'on\n' ;;
    off) printf 'off\n' ;;
    *)
      printf 'warning: %s must hold on or off, not %s; the step display is off\n' "$file" "$value" >&2
      printf 'off\n'
      ;;
  esac
}

# fm_step_record_path <state-dir> <task-id> - print the task's step record path.
fm_step_record_path() {
  printf '%s/%s.step\n' "$1" "$2"
}

# fm_step_record_json <record-file> <now-epoch> - print the record as JSON.
# Prints `null` when the file is absent or holds no valid line. Otherwise prints
# {current:{n,m,name,started_at,age_seconds},history:[{n,m,name,started_at}...]}.
# current is the last valid line. history holds at most the last 50 valid lines
# in record order. age_seconds is null when started_at is later than <now-epoch>.
fm_step_record_json() {
  local file=$1 now=$2
  [ -f "$file" ] || { printf 'null\n'; return 0; }
  jq -R -s --argjson now "$now" '
    [ splits("\n")
      | capture("^(?<at>[0-9]+)\t(?<n>[0-9]+)\t(?<m>[0-9]+)\t(?<name>[^\t]+)$")?
      | {n:(.n | tonumber), m:(.m | tonumber), name, started_at:(.at | tonumber)}
      | select(.n >= 1 and .m >= 1 and .n <= .m) ] as $all
    | if ($all | length) == 0 then null
      else ($all[-1]) as $cur
        | {current:($cur + {age_seconds:(if $now >= $cur.started_at then $now - $cur.started_at else null end)}),
           history:($all | .[-50:])}
      end' < "$file"
}
