#!/usr/bin/env bash
# Record and apply firstmate-approved recurring CI check decisions.
# Usage:
#   fm-known-regression.sh mark <check-name> <answer> <tracking-id>
#   fm-known-regression.sh retire <check-name> <tracking-id>
#   fm-known-regression.sh apply <task-id>
# `mark` adds one exact, case-sensitive CI check name and its answer to
# data/known-regressions.tsv. Repeating the same record is safe; changing it
# requires retiring the prior tracking id first. `retire` removes only the
# matching check/tracking pair after its fix lands on main. `apply` resolves
# a keyed gate only when every ask-user finding in its snapshot matches an
# active record with the same answer. fm-watch calls it for newly signaled
# decision logs; mixed or unmatched gates use ordinary triage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "${FM_HOME:-}" ] || [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME must name this firstmate home" >&2
  exit 2
fi
FM_HOME="$(cd "$FM_HOME" && pwd -P)"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
RECORD="$DATA/known-regressions.tsv"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  sed -n '1,13p' "$0" | sed 's/^#\{0,1\} *//'
}

valid_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || { echo "error: $label must not be empty" >&2; return 1; }
  case "$value" in *$'\n'*|*$'\r'*|*$'\t'*) echo "error: $label must be one line without tabs" >&2; return 1 ;; esac
}

load_record() {  # <check-name> -> REG_ANSWER, REG_TRACKING_ID
  local check=$1 name answer tracking
  REG_ANSWER=
  REG_TRACKING_ID=
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 1
  while IFS=$'\t' read -r name answer tracking; do
    if [ "$name" = "$check" ]; then
      REG_ANSWER=$answer
      REG_TRACKING_ID=$tracking
      return 0
    fi
  done < "$RECORD"
  return 1
}

mark_record() {
  local check=$1 answer=$2 tracking=$3 tmp
  valid_line 'check name' "$check"
  valid_line answer "$answer"
  valid_line 'tracking id' "$tracking"
  mkdir -p "$DATA" "$STATE"
  fm_lock_acquire_wait "$STATE/.known-regressions.lock"
  if load_record "$check"; then
    fm_lock_release "$STATE/.known-regressions.lock"
    if [ "$REG_ANSWER" = "$answer" ] && [ "$REG_TRACKING_ID" = "$tracking" ]; then
      printf 'already marked: %s (%s)\n' "$check" "$tracking"
      return 0
    fi
    echo "error: '$check' is already marked for '$REG_TRACKING_ID'; retire that record before replacing it" >&2
    return 1
  fi
  tmp=$(mktemp "$DATA/.known-regressions.XXXXXX") || {
    fm_lock_release "$STATE/.known-regressions.lock"
    return 1
  }
  if [ -f "$RECORD" ]; then cat "$RECORD" > "$tmp" || { rm -f "$tmp"; fm_lock_release "$STATE/.known-regressions.lock"; return 1; }; fi
  if ! printf '%s\t%s\t%s\n' "$check" "$answer" "$tracking" >> "$tmp" \
    || ! chmod 0600 "$tmp" \
    || ! _fm_atomic_replace "$tmp" "$RECORD"; then
    rm -f "$tmp"
    fm_lock_release "$STATE/.known-regressions.lock"
    return 1
  fi
  fm_lock_release "$STATE/.known-regressions.lock"
  printf 'marked: %s (%s)\n' "$check" "$tracking"
}

retire_record() {
  local check=$1 tracking=$2 tmp name answer current removed=0
  valid_line 'check name' "$check"
  valid_line 'tracking id' "$tracking"
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || { echo "error: no known-regression records" >&2; return 1; }
  fm_lock_acquire_wait "$STATE/.known-regressions.lock"
  tmp=$(mktemp "$DATA/.known-regressions.XXXXXX") || { fm_lock_release "$STATE/.known-regressions.lock"; return 1; }
  while IFS=$'\t' read -r name answer current; do
    if [ "$name" = "$check" ]; then
      [ "$current" = "$tracking" ] || { rm -f "$tmp"; fm_lock_release "$STATE/.known-regressions.lock"; echo "error: tracking id does not match '$check'" >&2; return 1; }
      removed=1
      continue
    fi
    printf '%s\t%s\t%s\n' "$name" "$answer" "$current" >> "$tmp"
  done < "$RECORD"
  if [ "$removed" -ne 1 ]; then
    rm -f "$tmp"
    fm_lock_release "$STATE/.known-regressions.lock"
    echo "error: no known-regression record for '$check'" >&2
    return 1
  fi
  if [ -s "$tmp" ]; then
    if ! chmod 0600 "$tmp" || ! _fm_atomic_replace "$tmp" "$RECORD"; then
      rm -f "$tmp"
      fm_lock_release "$STATE/.known-regressions.lock"
      return 1
    fi
  else
    rm -f "$tmp" "$RECORD"
  fi
  fm_lock_release "$STATE/.known-regressions.lock"
  printf 'retired: %s (%s)\n' "$check" "$tracking"
}

apply_for_task() {
  local id=$1 status open key verb note snapshot ids out check answer tracking send_bin missing=0 tracks='' checks='' first_answer=
  case "$id" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid task id" >&2; return 2 ;; esac
  status="$STATE/$id.status"
  [ -f "$status" ] && [ ! -L "$status" ] || return 0
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 0
  open=$(status_open_decisions "$status") || return 0
  send_bin=${FM_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}
  while IFS=$'\t' read -r key verb note; do
    missing=0
    tracks=
    checks=
    first_answer=
    [ "$verb" = needs-decision ] || continue
    case "$key" in nm-*) ;; *) continue ;; esac
    case "$note" in *'ask-user findings='*' file='*) ;; *) continue ;; esac
    ids=${note#*ask-user findings=}; ids=${ids%% file=*}
    snapshot=${note##* file=}
    case "$snapshot" in "$DATA/$id/"nm-*-findings.txt) ;; *) continue ;; esac
    [ -d "$DATA/$id" ] && [ ! -L "$DATA/$id" ] || continue
    [ -f "$snapshot" ] && [ -r "$snapshot" ] && [ ! -L "$snapshot" ] || continue
    out=$(python3 - "$snapshot" "$ids" <<'PY'
import ast
import re
import sys

path, selected_csv = sys.argv[1:]
selected = selected_csv.split(",")
if not selected_csv or any(not re.fullmatch(r"[A-Za-z0-9._-]+", item) for item in selected):
    sys.exit(1)
block = {}
findings = {}
def emit():
    if block.get("id") not in selected:
        return
    description = block.get("description", "")
    match = re.match(r"^CI check failing: (.+) - provider reported failure - https?://\S+$", description)
    if match:
        findings[block["id"]] = match.group(1)

with open(path, encoding="utf-8") as source:
    for raw in source:
        line = raw.rstrip("\n")
        match = re.match(r"^(id|description)\s*([=:])\s*(.*)$", line)
        if not match:
            if not line.strip():
                emit()
                block = {}
            continue
        key, separator, value = match.groups()
        if key == "id":
            if block:
                emit()
                block = {}
            block[key] = value.strip().strip("'")
        elif separator == "=" and value.startswith('"'):
            try:
                block[key] = ast.literal_eval(value)
            except (SyntaxError, ValueError):
                block[key] = ""
        else:
            block[key] = value.strip().strip('"').strip("'")
emit()
if len(findings) != len(selected):
    sys.exit(1)
for finding_id in selected:
    print(findings[finding_id])
PY
) || continue
    [ -n "$out" ] || continue
    while IFS= read -r check; do
      [ -n "$check" ] || continue
      if ! load_record "$check"; then missing=1; break; fi
      if [ -z "$first_answer" ]; then first_answer=$REG_ANSWER
      elif [ "$first_answer" != "$REG_ANSWER" ]; then missing=1; break
      fi
      case " $checks " in *" $check "*) ;; *) checks="${checks}${checks:+,}$check" ;; esac
      case " $tracks " in *" $REG_TRACKING_ID "*) ;; *) tracks="${tracks}${tracks:+,}$REG_TRACKING_ID" ;; esac
    done <<EOF
$out
EOF
    [ "$missing" -eq 0 ] || continue
    if FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$send_bin" "$id" --resolve-key "$key" "$first_answer"; then
      printf 'auto-resolved %s [%s] by known CI checks %s (%s)\n' "$id" "$key" "$checks" "$tracks"
    fi
  done <<EOF
$open
EOF
}

case "${1:-}" in
  mark)
    [ "$#" -eq 4 ] || { usage >&2; exit 2; }
    mark_record "$2" "$3" "$4"
    ;;
  retire)
    [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    retire_record "$2" "$3"
    ;;
  apply)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    apply_for_task "$2"
    ;;
  *) usage >&2; exit 2 ;;
esac
