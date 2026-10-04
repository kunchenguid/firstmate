#!/usr/bin/env bash
# Materialize one no-mistakes ask-user gate as a deterministic backlog hold.
# Usage: fm-ask-user-intake.sh ensure <origin-task> <decision-key> <snapshot-file>
#        fm-ask-user-intake.sh promote <origin-task> <decision-key> <authority-class> <reason>
#        fm-ask-user-intake.sh resolve <origin-task> <decision-key>
# `ensure` starts with a parked, Firstmate-owned hold: reviewer `ask-user` is
# not itself proof that the captain owns the decision. Firstmate applies
# ask-user-authority before `promote`, which accepts only captain classes.
# Repeated drains converge on the same row. `resolve` closes only a parked row;
# a captain-held row needs fm-captain-hold.sh's answer path instead.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
verb=${1:-}
origin=${2:-}
key=${3:-}
case "$verb" in ensure) [ "$#" -eq 4 ] ;; promote) [ "$#" -eq 5 ] ;; resolve) [ "$#" -eq 3 ] ;; *) exit 2 ;; esac || {
  printf 'Usage: fm-ask-user-intake.sh ensure <task> <key> <snapshot> | promote <task> <key> <class> <reason> | resolve <task> <key>\n' >&2
  exit 2
}
case "$origin:$key" in *[!a-zA-Z0-9._:-]*|:*|*:) printf 'fm-ask-user-intake: invalid task or key\n' >&2; exit 2 ;; esac
digest=$(printf '%s\t%s' "$origin" "$key" | shasum -a 256 | cut -c 1-20)
id="ask-user-$digest"
resolving="$STATE/.ask-user-resolving-$id"
task_axi() { FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-tasks-axi.sh" "$@"; }
if show=$(task_axi show "$id" --full 2>&1); then
  :
elif printf '%s\n' "$show" | grep -qx 'code: NOT_FOUND'; then
  show=''
else
  printf 'fm-ask-user-intake: could not inspect %s: %s\n' "$id" "${show%%$'\n'*}" >&2
  exit 2
fi
if [ -n "$show" ]; then
  printf '%s\n' "$show" | grep -F "Ask-user origin: $origin" >/dev/null \
    || { printf 'fm-ask-user-intake: identity collision or unrelated row at %s\n' "$id" >&2; exit 2; }
  printf '%s\n' "$show" | grep -F "Ask-user key: $key" >/dev/null \
    || { printf 'fm-ask-user-intake: key mismatch at %s\n' "$id" >&2; exit 2; }
fi
if [ "$verb" = ensure ]; then
  snapshot=$4
  data_real=$(cd "$DATA" && pwd -P) || exit 2
  [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || { printf 'fm-ask-user-intake: snapshot is not a regular file: %s\n' "$snapshot" >&2; exit 2; }
  snapshot_dir=$(cd "$(dirname "$snapshot")" && pwd -P) || exit 2
  [ "$snapshot_dir" = "$data_real/$origin" ] || { printf 'fm-ask-user-intake: snapshot is outside the task data directory\n' >&2; exit 2; }
  if [ -z "$show" ]; then
    origin_row=$(task_axi show "$origin" --full) || { printf 'fm-ask-user-intake: origin backlog task is unavailable\n' >&2; exit 2; }
    repo=$(printf '%s\n' "$origin_row" | sed -n 's/^  repo: *//p' | head -1)
    [ -n "$repo" ] && [ "$repo" != '"-"' ] || repo=firstmate
    body=$(printf 'Ask-user origin: %s\nAsk-user key: %s\nInitial decision owner: firstmate\nFinding snapshot: %s' "$origin" "$key" "$snapshot")
    task_axi add "$id" "Review ask-user finding for $origin" --kind task --repo "$repo" --body "$body" >/dev/null \
      || { printf 'fm-ask-user-intake: could not add hold row %s\n' "$id" >&2; exit 2; }
    show=$(task_axi show "$id" --full) || exit 2
  fi
  state=$(printf '%s\n' "$show" | sed -n 's/^  state: *//p' | head -1)
  kind=$(printf '%s\n' "$show" | sed -n 's/^  hold_kind: *//p' | head -1)
  if [ "$state" = 'done' ] || [ "$kind" = captain ]; then printf 'existing: %s\n' "$id"; exit 0; fi
  if [ "$kind" = parked ]; then printf 'existing: %s owner=firstmate\n' "$id"; exit 0; fi
  case "$kind" in '-'|'"-"'|'') ;; *) printf 'fm-ask-user-intake: %s has unrelated hold kind %s\n' "$id" "$kind" >&2; exit 2 ;; esac
  task_axi hold "$id" --reason "Firstmate review of ask-user gate $key" --kind parked >/dev/null \
    || { printf 'fm-ask-user-intake: could not park %s\n' "$id" >&2; exit 2; }
  printf 'held: %s owner=firstmate\n' "$id"
elif [ "$verb" = promote ]; then
  [ -n "$show" ] || { printf 'fm-ask-user-intake: no intake row to promote\n' >&2; exit 2; }
  "$SCRIPT_DIR/fm-captain-hold.sh" hold "$id" --reason "$5" --authority-class "$4" >/dev/null
  printf 'held: %s owner=captain\n' "$id"
else
  [ -n "$show" ] || { printf 'absent: %s\n' "$id"; exit 0; }
  state=$(printf '%s\n' "$show" | sed -n 's/^  state: *//p' | head -1)
  kind=$(printf '%s\n' "$show" | sed -n 's/^  hold_kind: *//p' | head -1)
  if [ "$state" = 'done' ]; then
    rm -f "$resolving"
    printf 'resolved: %s\n' "$id"
    exit 0
  fi
  if [ "$kind" = parked ]; then
    : > "$resolving"
    task_axi unhold "$id" >/dev/null
  elif { [ "$kind" != '-' ] && [ "$kind" != '"-"' ] && [ -n "$kind" ]; } || [ ! -f "$resolving" ]; then
    printf 'fm-ask-user-intake: %s is held by %s; use its authority owner\n' "$id" "$kind" >&2
    exit 2
  fi
  task_axi 'done' "$id" >/dev/null
  rm -f "$resolving"
  printf 'resolved: %s\n' "$id"
fi
