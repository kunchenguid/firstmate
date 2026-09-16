#!/usr/bin/env bash
# Shared task reference and human-name resolver.
#
# The private state file is a tab-separated registry. Live rows have five fields:
# task id, short reference, human name, last-seen epoch, and an empty retired epoch.
# Retired rows remain as tombstones so recycled references use oldest retirement
# order; the atomic replace and lock keep concurrent callers coherent.
# Usage: source this file, then call fm_callsign_resolve or fm_callsigns_sync.
set -u

FM_CALLSIGNS_STATE=${FM_CALLSIGNS_STATE:-${FM_STATE_OVERRIDE:-${FM_HOME:-.}/state}}
FM_CALLSIGNS_FILE=${FM_CALLSIGNS_FILE:-$FM_CALLSIGNS_STATE/task-callsigns.tsv}
FM_CALLSIGNS_LOCK=${FM_CALLSIGNS_LOCK:-$FM_CALLSIGNS_STATE/.task-callsigns.lock}

fm_callsign_valid_name() {
  [ -n "${1:-}" ] && printf '%s' "$1" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$'
}

fm_callsign_normalize_name() {  # <text>
  local value
  value=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-*//; s/-*$//' | cut -c1-40)
  value=${value%-}
  [ -n "$value" ] || value=task
  printf '%s' "$value"
}

fm_callsigns_inventory() {
  local backlog=${FM_CALLSIGNS_BACKLOG:-${FM_DATA_OVERRIDE:-${FM_HOME:-.}/data}/backlog.md}
  local meta id
  # Backlog titles are preferred for defaults, while metadata preserves tasks
  # during a short transition where the backlog row is not yet published.
  if [ -f "$backlog" ]; then
    awk '
      function title(line, value) {
        value=line
        sub(/^[-*][[:space:]]+\[[ xX]\][[:space:]]+/, "", value)
        sub(/^[-*][[:space:]]+/, "", value)
        sub(/^\*\*[^*]+\*\*[[:space:]]+-[[:space:]]*/, "", value)
        sub(/^[^[:space:]]+[[:space:]]+-[[:space:]]*/, "", value)
        sub(/[[:space:]]+\(repo:[[:space:]]*.*$/, "", value)
        sub(/[[:space:]]+blocked-by:.*/, "", value)
        sub(/[[:space:]]+https?:\/\/[^[:space:]]+/, "", value)
        gsub(/[^A-Za-z0-9]+/, "-", value)
        gsub(/^-+|-+$/, "", value)
        return tolower(value)
      }
      /^##[[:space:]]+(In flight|Queued|Done)[[:space:]]*$/ { section=1; next }
      /^##[[:space:]]+/ { section=0; next }
      section && /^[-*][[:space:]]+/ {
        line=$0; rest=line
        sub(/^[-*][[:space:]]+\[[ xX]\][[:space:]]+/, "", rest)
        sub(/^[-*][[:space:]]+/, "", rest)
        if (rest ~ /^\*\*[^*]+\*\*[[:space:]]+-/) {
          sub(/^\*\*/, "", rest); id=rest; sub(/\*\*.*/, "", id)
        } else { id=rest; sub(/[[:space:]]+.*/, "", id) }
        if (id != "") print id "\t" title(line)
      }
    ' "$backlog"
  fi
  for meta in "$FM_CALLSIGNS_STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    printf '%s\t%s\n' "$id" "$(fm_callsign_normalize_name "$id")"
  done
}

fm_callsigns_lock() {
  mkdir -p "$FM_CALLSIGNS_STATE"
  local n=0
  while ! mkdir "$FM_CALLSIGNS_LOCK" 2>/dev/null; do
    n=$((n + 1)); [ "$n" -lt 200 ] || return 1
    sleep 0.05
  done
  printf '%s\n' "$$" > "$FM_CALLSIGNS_LOCK/pid"
}

fm_callsigns_unlock() { rm -rf -- "$FM_CALLSIGNS_LOCK"; }

fm_callsigns_sync_locked() {
  local inventory=$1 now=$2 tmp live tomb id default ref name seen retired selected candidate n
  local selected_epoch selected_num selected_ref selected_name
  inventory="$inventory.unique"
  awk -F '\t' '!seen[$1]++ && $1 != "" {print}' "$1" > "$inventory"
  live=$(mktemp "${TMPDIR:-/tmp}/fm-callsigns-live.XXXXXX") || return 1
  tomb=$(mktemp "${TMPDIR:-/tmp}/fm-callsigns-tomb.XXXXXX") || { rm -f "$live"; return 1; }
  if [ -f "$FM_CALLSIGNS_FILE" ]; then
    while IFS=$'\t' read -r id ref name seen retired; do
      [ "$id" = version=1 ] && continue
      case "$ref" in t[1-9]|t[1-9][0-9]) ;; *) continue ;; esac
      [ -n "$id" ] || continue
      if [ -n "$retired" ]; then
        printf '%s\t%s\t%s\t%s\n' "$retired" "${ref#t}" "$ref" "$name" >> "$tomb"
      elif ! awk -F '\t' -v id="$id" '$1 == id {found=1} END {exit !found}' "$live" 2>/dev/null; then
        printf '%s\t%s\t%s\t%s\n' "$id" "$ref" "$name" "${seen:-$now}" >> "$live"
      fi
    done < "$FM_CALLSIGNS_FILE"
  fi
  # Any live row no longer present in backlog or metadata leaves its active period.
  while IFS=$'\t' read -r id ref name seen; do
    [ -n "$id" ] || continue
    if ! awk -F '\t' -v id="$id" '$1 == id {found=1} END {exit !found}' "$inventory"; then
      printf '%s\t%s\t%s\t%s\n' "$now" "${ref#t}" "$ref" "$name" >> "$tomb"
      awk -F '\t' -v id="$id" '$1 != id' "$live" > "$live.next" && mv -f "$live.next" "$live"
    fi
  done < "$live"
  # Allocate missing IDs. Existing retired references are chosen oldest first;
  # otherwise the shortest unused t1-t99 reference is selected.
  while IFS=$'\t' read -r id default; do
    [ -n "$id" ] || continue
    if awk -F '\t' -v id="$id" '$1 == id {found=1} END {exit !found}' "$live"; then continue; fi
    selected=
    if [ -s "$tomb" ]; then
      sort -t$'\t' -k1,1n -k2,2n "$tomb" > "$tomb.sorted"
      IFS=$'\t' read -r selected_epoch selected_num selected_ref selected_name < "$tomb.sorted"
      selected=$selected_ref
      awk -F '\t' -v e="$selected_epoch" -v r="$selected_ref" '!($1 == e && $3 == r)' "$tomb" > "$tomb.next" && mv -f "$tomb.next" "$tomb"
    else
      n=1
      while [ "$n" -le 99 ]; do
        candidate=t$n
        if ! awk -F '\t' -v r="$candidate" '$2 == r {found=1} END {exit !found}' "$live"; then selected=$candidate; break; fi
        n=$((n + 1))
      done
    fi
    [ -n "$selected" ] || { rm -f "$live" "$tomb" "$inventory" "$tomb.sorted"; return 1; }
    printf '%s\t%s\t%s\t%s\n' "$id" "$selected" "${default:-$(fm_callsign_normalize_name "$id")}" "$now" >> "$live"
  done < "$inventory"
  tmp="$FM_CALLSIGNS_FILE.tmp.$$"
  umask 077
  {
    printf 'version=1\n'
    sort -t$'\t' -k1,1 "$live" | while IFS=$'\t' read -r id ref name seen; do
      fm_callsign_valid_name "$name" || name=$(fm_callsign_normalize_name "$name")
      printf '%s\t%s\t%s\t%s\t\n' "$id" "$ref" "$name" "$seen"
    done
    sort -t$'\t' -k1,1n -k2,2n "$tomb" | while IFS=$'\t' read -r retired ref_num ref name; do
      printf '%s\t%s\t%s\t0\t%s\n' "__retired__${ref}" "$ref" "$name" "$retired"
    done
  } > "$tmp" || { rm -f "$tmp"; rm -f "$live" "$tomb" "$inventory"; return 1; }
  chmod 0600 "$tmp"
  mv -f "$tmp" "$FM_CALLSIGNS_FILE"
  rm -f "$live" "$tomb" "$inventory" "$tomb.sorted" "$tomb.next" "$live.next"
}

fm_callsigns_sync() {
  local now=${1:-$(date +%s)} inventory tmp rc=0
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-callsigns.XXXXXX") || return 1
  fm_callsigns_inventory > "$tmp" || rc=1
  if [ "$rc" -eq 0 ] && fm_callsigns_lock; then
    fm_callsigns_sync_locked "$tmp" "$now" || rc=1
    fm_callsigns_unlock
  else rc=1; fi
  rm -f "$tmp"
  return "$rc"
}

fm_callsigns_lookup_id() {  # <selector>, after sync
  local selector=$1 id ref name seen retired
  local matches=0 match=
  [ -f "$FM_CALLSIGNS_FILE" ] || return 1
  while IFS=$'\t' read -r id ref name seen retired; do
    [ -n "$id" ] && [ -z "$retired" ] || continue
    if [ "$selector" = "$id" ] || [ "$selector" = "$ref" ] || \
       [ "$selector" = "$name" ] || [ "$selector" = "fm-$id" ]; then
      matches=$((matches + 1)); match=$id
    fi
  done < "$FM_CALLSIGNS_FILE"
  if [ "$matches" -eq 1 ]; then printf '%s\n' "$match"; return 0; fi
  if [ "$matches" -gt 1 ]; then
    printf 'ambiguous task selector %s\n' "$selector" >&2
  else
    printf 'unknown task selector %s\n' "$selector" >&2
  fi
  return 1
}

fm_callsign_resolve() {
  fm_callsigns_sync || return 1
  fm_callsigns_lookup_id "$1"
}

fm_callsign_set_name() {  # <selector> <name>
  local selector=$1 name=$2 id tmp
  fm_callsign_valid_name "$name" || {
    echo "invalid task name '$name' (use lowercase hyphenated words)" >&2
    return 2
  }
  fm_callsigns_sync || return 1
  id=$(fm_callsigns_lookup_id "$selector") || return 1
  if awk -F '\t' -v id="$id" -v name="$name" '$5=="" && $3==name && $1!=id {found=1} END {exit !found}' "$FM_CALLSIGNS_FILE"; then
    echo "task name '$name' is already assigned to another active task" >&2
    return 1
  fi
  fm_callsigns_lock || return 1
  tmp="$FM_CALLSIGNS_FILE.tmp.$$"
  awk -F '\t' -v id="$id" -v name="$name" 'BEGIN{OFS="\t"} $1==id && $5=="" {$3=name} {print}' \
    "$FM_CALLSIGNS_FILE" > "$tmp" || { rm -f "$tmp"; fm_callsigns_unlock; return 1; }
  chmod 0600 "$tmp"
  mv -f "$tmp" "$FM_CALLSIGNS_FILE"
  fm_callsigns_unlock
  printf '%s\n' "$name"
}

fm_callsigns_json() {
  command -v jq >/dev/null 2>&1 || return 1
  fm_callsigns_sync || return 1
  jq -Rn '[inputs | select((startswith("version=") | not) and length > 0)
    | split("\t") | select(length >= 5 and .[4] == "")
    | {id:.[0],ref:.[1],name:.[2]}]' < "$FM_CALLSIGNS_FILE"
}
