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
# Record: state/<task-id>.step, appended in order, with three line shapes:
#   <epoch> TAB <n> TAB <m> TAB <step name>          a step start
#   <epoch> TAB plan TAB <k> TAB <m> TAB <step name> one step of a full plan
#   <epoch> TAB scenario TAB <result> TAB <name>     one scenario result
# A step start says the worker started step <n> of a plan of <m> steps at Unix
# time <epoch>. The last valid step start is the current step.
# A full plan is <m> plan lines with <k> = 1..<m>, written in one append before
# step 1 starts, so a reader knows every step name before that step starts.
# The last complete plan wins, so a worker re-plans by recording a new plan.
# A scenario line records one checked scenario; <result> is pass, fail, or run
# (running now). The last line for a scenario name wins.
# Readers skip a line that matches none of these shapes, so a record written
# before plan and scenario lines existed still reads the same.
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
# {current, history, plan, plan_recorded_at, scenarios}:
#   current is the last valid step start {n,m,name,started_at,age_seconds}, or
#     null when only a plan or scenarios are recorded. age_seconds is null when
#     started_at is later than <now-epoch>.
#   history holds at most the last 50 step starts {n,m,name,started_at} in
#     record order.
#   plan is the last complete plan as [{n,name}...] in step order, or null.
#   plan_recorded_at is that plan's epoch, or null.
#   scenarios is [{name,result,at}...], one entry per scenario name in the
#     order first recorded, holding the last result recorded for that name.
fm_step_record_json() {
  local file=$1 now=$2
  [ -f "$file" ] || { printf 'null\n'; return 0; }
  jq -R -s --argjson now "$now" '
    [ splits("\n") ] as $lines
    | [ $lines[]
        | capture("^(?<at>[0-9]+)\t(?<n>[0-9]+)\t(?<m>[0-9]+)\t(?<name>[^\t]+)$")?
        | {n:(.n | tonumber), m:(.m | tonumber), name, started_at:(.at | tonumber)}
        | select(.n >= 1 and .m >= 1 and .n <= .m) ] as $all
    | [ $lines[]
        | capture("^(?<at>[0-9]+)\tplan\t(?<k>[0-9]+)\t(?<m>[0-9]+)\t(?<name>[^\t]+)$")?
        | {at:(.at | tonumber), k:(.k | tonumber), m:(.m | tonumber), name}
        | select(.k >= 1 and .m >= 1 and .k <= .m) ] as $plan_lines
    # Split the plan lines into runs that each start at k = 1, and keep the
    # last run that names every step 1..m of one plan size exactly once.
    | (reduce $plan_lines[] as $p ([];
        if $p.k == 1 or length == 0 then . + [[$p]] else .[-1] += [$p] end)
       | map(select(.[0].k == 1
           and (map(.m) | unique | length) == 1
           and (map(.k)) == [range(1; .[0].m + 1)]))
       | last) as $plan
    | [ $lines[]
        | capture("^(?<at>[0-9]+)\tscenario\t(?<result>pass|fail|run)\t(?<name>[^\t]+)$")?
        | {name, result, at:(.at | tonumber)} ] as $scen_lines
    | (reduce $scen_lines[] as $s ({order:[], last:{}};
        (if .last[$s.name] == null then .order += [$s.name] else . end)
        | .last[$s.name] = $s)
       | [.order[] as $n | .last[$n]] ) as $scenarios
    | if ($all | length) == 0 and $plan == null and ($scenarios | length) == 0 then null
      else
        {current:(if ($all | length) == 0 then null
                  else $all[-1] + {age_seconds:(if $now >= $all[-1].started_at then $now - $all[-1].started_at else null end)}
                  end),
         history:($all | .[-50:]),
         plan:(if $plan == null then null else [$plan[] | {n:.k, name}] end),
         plan_recorded_at:(if $plan == null then null else $plan[0].at end),
         scenarios:$scenarios}
      end' < "$file"
}
