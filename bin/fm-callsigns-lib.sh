#!/usr/bin/env bash
# Shared task reference and human-name resolver.
#
# The private state file is a tab-separated registry. Live rows have six fields:
# task id, short reference, human name, last-seen epoch, name origin
# (`generated` or `explicit`), and an empty retired epoch. Retired rows remain as tombstones
# so recycled references use oldest retirement order after a deterministic cooldown;
# until then they prevent an old reference from silently naming new work. Version 1 rows migrate by
# treating only the exact legacy title-derived default as generated; every other
# name is preserved as explicit. Atomic replacement and locking keep concurrent
# callers coherent.
# Usage: source this file, then call fm_callsign_resolve or fm_callsigns_sync.
set -u

FM_CALLSIGNS_STATE=${FM_CALLSIGNS_STATE:-${FM_STATE_OVERRIDE:-${FM_HOME:-.}/state}}
FM_CALLSIGNS_DATA=${FM_CALLSIGNS_DATA:-${FM_DATA_OVERRIDE:-${FM_HOME:-.}/data}}
FM_CALLSIGNS_FILE=${FM_CALLSIGNS_FILE:-$FM_CALLSIGNS_STATE/task-callsigns.tsv}
FM_CALLSIGNS_LOCK=${FM_CALLSIGNS_LOCK:-$FM_CALLSIGNS_STATE/.task-callsigns.lock}
FM_CALLSIGN_REUSE_COOLDOWN_SECS=${FM_CALLSIGN_REUSE_COOLDOWN_SECS:-86400}
case "$FM_CALLSIGN_REUSE_COOLDOWN_SECS" in
  ''|*[!0-9]*) FM_CALLSIGN_REUSE_COOLDOWN_SECS=86400 ;;
  *) [ "${#FM_CALLSIGN_REUSE_COOLDOWN_SECS}" -le 9 ] || FM_CALLSIGN_REUSE_COOLDOWN_SECS=86400 ;;
esac

fm_callsign_valid_name() {
  [ -n "${1:-}" ] && printf '%s' "$1" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$'
}

fm_callsign_valid_shorthand() {
  fm_callsign_valid_name "${1:-}" || return 1
  printf '%s\n' "$1" | awk -F- 'NF >= 2 && NF <= 4 {ok=1} END {exit !ok}'
}

fm_callsign_legacy_name() {  # <text>
  local value
  value=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-*//; s/-*$//' | cut -c1-40)
  value=${value%-}
  [ -n "$value" ] || value=task
  printf '%s' "$value"
}

fm_callsign_skip_token() {  # <token> <current-count>
  case "$1" in
    a|an|and|as|at|by|for|from|in|into|of|on|only|or|the|to|with) return 0 ;;
    add|build|change|correct|create|ensure|fix|implement|improve|make|migrate|normalize|preserve|refactor|remove|render|update)
      [ "$2" -eq 0 ] && return 0
      ;;
  esac
  return 1
}

fm_callsign_shorthand_name() {  # <title> <task-id>
  local title=${1:-} fallback=${2:-} normalized token result='' count=0
  normalized=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-*//; s/-*$//')
  for token in $(printf '%s' "$normalized" | tr '-' ' '); do
    fm_callsign_skip_token "$token" "$count" && continue
    if [ -z "$result" ]; then result=$token; else result=$result-$token; fi
    count=$((count + 1))
    [ "$count" -lt 3 ] || break
  done
  if [ "$count" -lt 2 ]; then
    normalized=$(printf '%s' "$fallback" | tr '[:upper:]' '[:lower:]' \
      | sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-*//; s/-*$//')
    for token in $(printf '%s' "$normalized" | tr '-' ' '); do
      fm_callsign_skip_token "$token" "$count" && continue
      case "-$result-" in *"-$token-"*) continue ;; esac
      if [ -z "$result" ]; then result=$token; else result=$result-$token; fi
      count=$((count + 1))
      [ "$count" -ge 2 ] && break
    done
  fi
  if [ "$count" -eq 0 ]; then result=task-work
  elif [ "$count" -eq 1 ]; then result=$result-task
  fi
  printf '%s' "$result"
}

fm_callsigns_inventory() {
  local backlog=${FM_CALLSIGNS_BACKLOG:-$FM_CALLSIGNS_DATA/backlog.md}
  local meta lifecycle id legacy
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
    ' "$backlog" | while IFS=$'\t' read -r id legacy; do
      printf '%s\t%s\t%s\n' "$id" "$(fm_callsign_shorthand_name "$legacy" "$id")" "$legacy"
    done
  fi
  for meta in "$FM_CALLSIGNS_STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    legacy=$(fm_callsign_legacy_name "$id")
    printf '%s\t%s\t%s\n' "$id" "$(fm_callsign_shorthand_name "$id" "$id")" "$legacy"
  done
  # A reviewed task remains current across runtime cleanup until guarded closure,
  # even when bounded backlog Done retention has already archived its row.
  for lifecycle in "$FM_CALLSIGNS_DATA"/task-lifecycle/*.json; do
    [ -f "$lifecycle" ] && [ ! -L "$lifecycle" ] || continue
    id=${lifecycle##*/}; id=${id%.json}
    case "$id" in ''|.*|*/*|*[!A-Za-z0-9._-]*) continue ;; esac
    legacy=$(fm_callsign_legacy_name "$id")
    printf '%s\t%s\t%s\n' "$id" "$(fm_callsign_shorthand_name "$id" "$id")" "$legacy"
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

fm_callsign_unique_generated() {  # <base> <live-file>
  local base=$1 live=$2 candidate stem n=2
  if ! awk -F '\t' -v name="$base" '$3 == name {found=1} END {exit !found}' "$live"; then
    printf '%s' "$base"
    return 0
  fi
  stem=$base
  if [ "$(printf '%s\n' "$base" | awk -F- '{print NF}')" -ge 4 ]; then stem=${base%-*}; fi
  while [ "$n" -le 999 ]; do
    candidate=$stem-$n
    if ! awk -F '\t' -v name="$candidate" '$3 == name {found=1} END {exit !found}' "$live"; then
      printf '%s' "$candidate"
      return 0
    fi
    n=$((n + 1))
  done
  return 1
}

fm_callsigns_sync_locked() {
  local inventory=$1 now=$2 tmp live tomb raw id default legacy ref name seen retired origin line field5 field6
  local selected candidate n schema=1 generated_name rc=0 eligible_before
  local selected_epoch selected_ref
  inventory="$inventory.unique"
  awk -F '\t' '!seen[$1]++ && $1 != "" {print}' "$1" > "$inventory"
  live=$(mktemp "${TMPDIR:-/tmp}/fm-callsigns-live.XXXXXX") || return 1
  tomb=$(mktemp "${TMPDIR:-/tmp}/fm-callsigns-tomb.XXXXXX") || { rm -f "$live"; return 1; }
  raw=$(mktemp "${TMPDIR:-/tmp}/fm-callsigns-raw.XXXXXX") || { rm -f "$live" "$tomb"; return 1; }
  if [ -f "$FM_CALLSIGNS_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in version=*) schema=${line#version=}; continue ;; esac
      IFS=$'\t' read -r id ref name seen field5 field6 <<< "$line"
      if [ "$schema" = 2 ]; then origin=$field5; retired=$field6
      else origin=; retired=$field5
      fi
      case "$ref" in t[1-9]|t[1-9][0-9]) ;; *) continue ;; esac
      [ -n "$id" ] || continue
      if [ -n "$retired" ]; then
        printf '%s\t%s\t%s\t%s\n' "$retired" "${ref#t}" "$ref" "$name" >> "$tomb"
        continue
      fi
      if ! awk -F '\t' -v id="$id" '$1 == id {found=1} END {exit !found}' "$inventory"; then
        printf '%s\t%s\t%s\t%s\n' "$now" "${ref#t}" "$ref" "$name" >> "$tomb"
        continue
      fi
      if [ "$schema" != 2 ]; then
        legacy=$(awk -F '\t' -v id="$id" '$1 == id {print $3; exit}' "$inventory")
        if [ -n "$legacy" ] && [ "$name" = "$legacy" ]; then origin=migrate; else origin=explicit; fi
      elif [ "$origin" != generated ] && [ "$origin" != explicit ]; then
        origin=explicit
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$ref" "$name" "${seen:-$now}" "$origin" >> "$raw"
    done < "$FM_CALLSIGNS_FILE"
  fi
  # Explicit names reserve their exact spelling before generated names are
  # migrated, so a generated collision can never rename a human choice.
  awk -F '\t' '$5 == "explicit" && !seen[$1]++ {print}' "$raw" > "$live"
  while IFS=$'\t' read -r id ref name seen origin; do
    [ "$origin" = generated ] || [ "$origin" = migrate ] || continue
    awk -F '\t' -v id="$id" '$1 == id {found=1} END {exit !found}' "$live" && continue
    if [ "$origin" = generated ] \
      && ! awk -F '\t' -v name="$name" '$3 == name {found=1} END {exit !found}' "$live"; then
      generated_name=$name
    else
      default=$(awk -F '\t' -v id="$id" '$1 == id {print $2; exit}' "$inventory")
      [ -n "$default" ] || default=$(fm_callsign_shorthand_name "$name" "$id")
      if ! generated_name=$(fm_callsign_unique_generated "$default" "$live"); then
        rc=1
        break
      fi
    fi
    printf '%s\t%s\t%s\t%s\tgenerated\n' "$id" "$ref" "$generated_name" "$seen" >> "$live"
  done < "$raw"
  if [ "$rc" -ne 0 ]; then
    rm -f "$live" "$tomb" "$raw" "$inventory"
    return 1
  fi
  # Allocate missing IDs. Existing retired references are chosen oldest first
  # only after the cooldown; cooling tombstones remain reserved, so an immediate
  # old reference can never identify unrelated new work.
  eligible_before=$((now - FM_CALLSIGN_REUSE_COOLDOWN_SECS))
  while IFS=$'\t' read -r id default legacy; do
    [ -n "$id" ] || continue
    if awk -F '\t' -v id="$id" '$1 == id {found=1} END {exit !found}' "$live"; then continue; fi
    selected=
    if [ -s "$tomb" ]; then
      awk -F '\t' -v cutoff="$eligible_before" '$1 <= cutoff' "$tomb" \
        | sort -t$'\t' -k1,1n -k2,2n > "$tomb.sorted"
      if [ -s "$tomb.sorted" ]; then
        IFS=$'\t' read -r selected_epoch _ selected_ref name < "$tomb.sorted"
        selected=$selected_ref
        awk -F '\t' -v e="$selected_epoch" -v r="$selected_ref" '!($1 == e && $3 == r)' "$tomb" > "$tomb.next" && mv -f "$tomb.next" "$tomb"
      fi
    fi
    if [ -z "$selected" ]; then
      n=1
      while [ "$n" -le 99 ]; do
        candidate=t$n
        if ! awk -F '\t' -v r="$candidate" '$2 == r {found=1} END {exit !found}' "$live" \
           && ! awk -F '\t' -v r="$candidate" '$3 == r {found=1} END {exit !found}' "$tomb"; then
          selected=$candidate
          break
        fi
        n=$((n + 1))
      done
    fi
    if [ -z "$selected" ]; then
      rc=1
      break
    fi
    if ! generated_name=$(fm_callsign_unique_generated "$default" "$live"); then
      rc=1
      break
    fi
    printf '%s\t%s\t%s\t%s\tgenerated\n' "$id" "$selected" "$generated_name" "$now" >> "$live"
  done < "$inventory"
  if [ "$rc" -ne 0 ]; then
    rm -f "$live" "$tomb" "$raw" "$inventory" "$tomb.sorted"
    return 1
  fi
  tmp="$FM_CALLSIGNS_FILE.tmp.$$"
  umask 077
  {
    printf 'version=2\n'
    sort -t$'\t' -k1,1 "$live" | while IFS=$'\t' read -r id ref name seen origin; do
      printf '%s\t%s\t%s\t%s\t%s\t\n' "$id" "$ref" "$name" "$seen" "$origin"
    done
    sort -t$'\t' -k1,1n -k2,2n "$tomb" | while IFS=$'\t' read -r retired _ ref name; do
      printf '%s\t%s\t%s\t0\tretired\t%s\n' "__retired__${ref}" "$ref" "$name" "$retired"
    done
  } > "$tmp" || { rm -f "$tmp" "$live" "$tomb" "$raw" "$inventory"; return 1; }
  chmod 0600 "$tmp"
  mv -f "$tmp" "$FM_CALLSIGNS_FILE"
  rm -f "$live" "$tomb" "$raw" "$inventory" "$tomb.sorted" "$tomb.next"
}

fm_callsigns_sync() {
  local now=${1:-$(date +%s)} tmp rc=0
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#now}" -le 18 ] || return 1
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
  local selector=$1 id ref name seen origin retired
  local matches=0 match=
  [ -f "$FM_CALLSIGNS_FILE" ] || return 1
  while IFS=$'\t' read -r id ref name seen origin retired; do
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
  fm_callsign_valid_shorthand "$name" || {
    echo "invalid task name '$name' (use two to four lowercase hyphenated tokens)" >&2
    return 2
  }
  fm_callsigns_sync || return 1
  id=$(fm_callsigns_lookup_id "$selector") || return 1
  if awk -F '\t' -v id="$id" -v name="$name" '$6=="" && $3==name && $1!=id {found=1} END {exit !found}' "$FM_CALLSIGNS_FILE"; then
    echo "task name '$name' is already assigned to another active task" >&2
    return 1
  fi
  fm_callsigns_lock || return 1
  tmp="$FM_CALLSIGNS_FILE.tmp.$$"
  awk -F '\t' -v id="$id" -v name="$name" 'BEGIN{OFS="\t"} $1==id && $6=="" {$3=name;$5="explicit"} {print}' \
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
    | split("\t") | select(length >= 6 and .[5] == "")
    | {id:.[0],ref:.[1],name:.[2]}]' < "$FM_CALLSIGNS_FILE"
}
