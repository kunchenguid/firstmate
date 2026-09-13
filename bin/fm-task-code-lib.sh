#!/usr/bin/env bash
# Shared stored task-code rules.
#
# fm_task_code_visible prints the Herdr-safe visible form of one stored code.
# Stored codes use ASCII grammar; the one U+2026 display ellipsis occupies one
# terminal cell on supported Herdr surfaces.

_FM_TASK_CODE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$_FM_TASK_CODE_LIB_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$_FM_TASK_CODE_LIB_DIR/fm-wake-lib.sh"
unset _FM_TASK_CODE_LIB_DIR

fm_task_code_valid() {  # <body>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*|.*|*..*|*.) return 1 ;;
    *) return 0 ;;
  esac
}

fm_task_code_project_prefix() {  # <home> <project> <kind> <task-id>
  local home=$1 project=${2%/} kind=$3 id=$4 name prefix
  name=${project##*/}
  if [ "$kind" = secondmate ]; then
    case "$id" in
      artemis-*) printf 'A' ;;
      research) printf 'R' ;;
      *) printf 'FM' ;;
    esac
    return 0
  fi
  case "$name" in
    firstmate|firstmate-*) prefix=FM ;;
    artemis) prefix=A ;;
    artemis-spec-kit) prefix=AS ;;
    falling-blocks-js*) prefix=FB ;;
    financial-life) prefix=FL ;;
    portal-snake-*) prefix=G ;;
    *)
      prefix=$(printf '%s\n' "$name" | awk -F '[-_]' '{ for (i=1; i<=NF && i<=4; i++) printf toupper(substr($i,1,1)) }')
      ;;
  esac
  case "$prefix" in ''|*[!A-Z0-9]*) return 1 ;; esac
  printf '%s' "$prefix"
}

fm_task_code_role() {  # <kind> <task-id>
  case "$1:$2" in
    secondmate:*) printf '2' ;;
    scout:*) printf 'S' ;;
    ship:fm-crew-*|ship:fm-moiras-*|ship:fm-tachikoma-*|ship:fm-robin-*) printf 'H' ;;
    ship:*) printf 'C' ;;
    *) return 1 ;;
  esac
}

fm_task_code_parent_meta() {  # <home> <parent-task-id> [<state-dir>]
  local home=$1 parent=$2 state=${3:-$1/state} marker owner
  if [ -f "$state/$parent.meta" ] && [ ! -L "$state/$parent.meta" ]; then
    printf '%s' "$state/$parent.meta"
    return 0
  fi
  marker=$(awk 'NF { value=$0 } END { print value }' "$home/.fm-secondmate-home" 2>/dev/null || true)
  [ "$marker" = "$parent" ] || return 1
  fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" || return 1
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || return 1
  owner="$FM_SECONDMATE_PARENT_HOME/state/$parent.meta"
  [ -f "$owner" ] && [ ! -L "$owner" ] || return 1
  printf '%s' "$owner"
}

fm_task_code_child_seq_next() (  # <home> <parent-task-id> [<state-dir>]
  local home=$1 parent=$2 state=${3:-$1/state} meta lock day prior_day prior_seq next tmp
  local parent_code candidate candidate_code occupied
  case "$parent" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  meta=$(fm_task_code_parent_meta "$home" "$parent" "$state") || return 1
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  trap 'fm_lock_release "$lock"' EXIT
  day=${FM_TASK_CODE_TODAY:-$(date -u +%Y-%m-%d)}
  case "$day" in ????-??-??) ;; *) return 1 ;; esac
  prior_day=$(awk -F= '$1 == "parent_child_seq_day" { n++; value=$2 } END { if (n <= 1) print value; else exit 1 }' "$meta") \
    || return 1
  prior_seq=$(awk -F= '$1 == "parent_child_seq" { n++; value=$2 } END { if (n <= 1) print value; else exit 1 }' "$meta") \
    || return 1
  if [ "$prior_day" = "$day" ]; then
    case "$prior_seq" in ''|*[!0-9]*) return 1 ;; esac
    next=$((prior_seq + 1))
  else
    next=1
  fi
  parent_code=$(fm_task_code_of_meta "$meta") || return 1
  while :; do
    occupied=0
    for candidate in "$state"/*.meta; do
      [ -f "$candidate" ] && [ ! -L "$candidate" ] || continue
      candidate_code=$(fm_task_code_of_meta "$candidate" 2>/dev/null || true)
      [ "$candidate_code" != "$parent_code.$next" ] || occupied=1
    done
    [ "$occupied" -eq 1 ] || break
    next=$((next + 1))
  done
  tmp="${meta%/*}/.$parent.meta.task-code.${BASHPID:-$$}.${RANDOM:-0}"
  (umask 077
    awk -F= '$1 != "parent_child_seq_day" && $1 != "parent_child_seq"' "$meta" > "$tmp" \
      && printf 'parent_child_seq_day=%s\nparent_child_seq=%s\n' "$day" "$next" >> "$tmp") \
    || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$meta" || { rm -f -- "$tmp"; return 1; }
  fm_lock_release "$lock" || return 1
  trap - EXIT
  printf '%s' "$next"
)

fm_task_code_mint() {  # <home> <project> <kind> <task-id> <parent-task-id> <child-seq> [<state-dir>]
  local home=$1 project=$2 kind=$3 id=$4 parent=$5 child_seq=$6 state=${7:-$1/state}
  local prefix role slug code meta existing owner
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  if [ -n "$parent" ]; then
    case "$parent" in *[!A-Za-z0-9._-]*) return 1 ;; esac
    case "$child_seq" in ''|0|*[!0-9]*) return 1 ;; esac
    meta=$(fm_task_code_parent_meta "$home" "$parent" "$state") || return 1
    code=$(awk -F= '$1 == "code" { n++; value=substr($0,6) } END { if (n == 1 && value != "") print value; else exit 1 }' "$meta") \
      || return 1
    fm_task_code_valid "$code" || return 1
    code="$code.$child_seq"
  else
    [ -z "$child_seq" ] || return 1
    prefix=$(fm_task_code_project_prefix "$home" "$project" "$kind" "$id") || return 1
    role=$(fm_task_code_role "$kind" "$id") || return 1
    slug=$id
    case "$kind:$id" in
      secondmate:research) slug= ;;
      secondmate:"${project##*/}"-*) slug=${id#"${project##*/}"-} ;;
    esac
    case "${project##*/}:$slug" in
      artemis:art-*) slug=${slug#art-} ;;
      firstmate:fm-*) slug=${slug#fm-} ;;
    esac
    code=$prefix$role
    [ -z "$slug" ] || code="$code-$slug"
  fi
  fm_task_code_valid "$code" || return 1
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    owner=${meta##*/}; owner=${owner%.meta}
    [ "$owner" != "$id" ] || continue
    existing=$(awk -F= '$1 == "code" { n++; value=substr($0,6) } END { if (n == 1) print value }' "$meta")
    [ "$existing" != "$code" ] || return 1
  done
  printf '%s' "$code"
}

fm_task_code_of_meta() {  # <meta-file>
  local code
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  code=$(awk -F= '$1 == "code" { n++; value=substr($0,6) } END { if (n == 1 && value != "") print value; else exit 1 }' "$1") \
    || return 1
  fm_task_code_valid "$code" || return 1
  printf '%s' "$code"
}

fm_task_code_meta_for_selector() {  # <selector> <state-dir>
  local raw=$1 state=$2 selector meta code exact='' exact_count=0 prefix='' prefix_count=0
  case "$raw" in
    \[*\]) selector=${raw#\[}; selector=${selector%\]} ;;
    *'['*|*']'*|*…*) return 1 ;;
    *) selector=$raw ;;
  esac
  fm_task_code_valid "$selector" || return 1
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    code=$(awk -F= '$1 == "code" { n++; value=substr($0,6) } END { if (n == 1 && value != "") print value; else exit 1 }' "$meta") \
      || continue
    fm_task_code_valid "$code" || continue
    if [ "$code" = "$selector" ]; then
      exact=$meta
      exact_count=$((exact_count + 1))
    fi
    case "$code" in
      "$selector"*) prefix=$meta; prefix_count=$((prefix_count + 1)) ;;
    esac
  done
  if [ "$exact_count" -eq 1 ]; then
    printf '%s' "$exact"
  elif [ "$exact_count" -gt 1 ]; then
    return 1
  elif [ "$prefix_count" -eq 1 ]; then
    printf '%s' "$prefix"
  else
    return 1
  fi
}

fm_task_code_visible() {  # <body>
  local code=$1 counters tail
  fm_task_code_valid "$code" || return 1
  [ "${#code}" -gt 8 ] || { printf '%s' "$code"; return 0; }
  case "$code" in
    *.*)
      counters=.${code#*.}
      if [ "${#counters}" -le 5 ]; then
        printf '%s…%s' "${code:0:2}" "$counters"
      else
        tail=${code:$(( ${#code} - 5 )):5}
        printf '%s…%s' "${code:0:2}" "$tail"
      fi
      ;;
    *)
      tail=${code:$(( ${#code} - 5 )):5}
      printf '%s…%s' "${code:0:2}" "$tail"
      ;;
  esac
}
