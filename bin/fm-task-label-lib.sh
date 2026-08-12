#!/usr/bin/env bash
# Deterministic Herdr display-label owner.
#
# Machine identity remains the full task id and response-derived Herdr ids.
# This library owns presentation only:
#   <kind> - <phrase> · <task-key>
#
# A caller must publish the returned journal before creating the Herdr tab and
# remove it only after complete task metadata has been atomically published.
FM_TASK_LABEL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_task_label_kind() {  # <ship|crew|scout|secondmate>
  case "$1" in
    ship|crew) printf 'Crew' ;;
    scout) printf 'Scout' ;;
    secondmate) printf '2nd' ;;
    *) return 1 ;;
  esac
}

fm_task_label_sha256() {  # <text>
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  fi
}

fm_task_label_base_key() {  # <task-id>
  local id=$1 tail
  tail=${id##*-}
  case "$tail" in
    *[!A-Za-z0-9]*|'') ;;
    *)
      if [ "${#tail}" -ge 4 ] && [ "${#tail}" -le 6 ] && \
         [[ "$tail" == *[A-Za-z]* ]] && [[ "$tail" == *[0-9]* ]]; then
        printf '%s' "$tail" | tr '[:upper:]' '[:lower:]'
        return 0
      fi
      ;;
  esac
  fm_task_label_sha256 "$id" | cut -c1-6
}

fm_task_label_has_unsafe_controls() {  # <text>
  local raw=$1 stripped
  stripped=$(printf '%s' "$raw" | LC_ALL=C tr -d '\001-\037\177')
  [ "$stripped" = "$raw" ] || return 0
  case "$raw" in
    *$'\342\200\252'*|*$'\342\200\253'*|*$'\342\200\254'*|\
    *$'\342\200\255'*|*$'\342\200\256'*|*$'\342\201\246'*|\
    *$'\342\201\247'*|*$'\342\201\250'*|*$'\342\201\251'*) return 0 ;;
  esac
  return 1
}

fm_task_label_trim_phrase() {  # <already ASCII-sanitized phrase>
  printf '%s' "$1" | sed \
    -e 's/[[:space:]][[:space:]]*/ /g' \
    -e 's/^[ .+_-]*//' \
    -e 's/[ .+_-]*$//'
}

fm_task_label_sanitize_phrase() {  # <raw phrase>
  local raw=$1 phrase prefix next
  fm_task_label_has_unsafe_controls "$raw" && {
    echo "error: display title contains control or bidi characters" >&2
    return 1
  }
  phrase=$(printf '%s' "$raw" | LC_ALL=C sed 's/[^A-Za-z0-9 .+_-]/ /g')
  phrase=$(fm_task_label_trim_phrase "$phrase")
  if [ "${#phrase}" -gt 28 ]; then
    prefix=${phrase:0:28}
    next=${phrase:28:1}
    if [[ "$next" =~ [A-Za-z0-9_] ]] && [[ "$prefix" == *" "* ]]; then
      prefix=${prefix% *}
    fi
    phrase=$(fm_task_label_trim_phrase "$prefix")
  fi
  printf '%s' "$phrase"
}

fm_task_label_character_count() {  # <safe display label>
  local ascii=${1//$'·'/x}
  printf '%s' "${#ascii}"
}

fm_task_label_phrase_is_valid() {  # <phrase>
  local phrase=$1 sanitized
  case "$phrase" in
    ''|*[!A-Za-z0-9\ .+_-]*) return 1 ;;
  esac
  [ "${#phrase}" -le 28 ] || return 1
  sanitized=$(fm_task_label_sanitize_phrase "$phrase") || return 1
  [ "$sanitized" = "$phrase" ]
}

fm_task_label_task_id_is_valid() {  # <task-id>
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

fm_task_label_validate_display_label() {  # <label>; echoes key
  local label=$1 key phrase
  fm_task_label_has_unsafe_controls "$label" && return 1
  [ "$(fm_task_label_character_count "$label")" -le 50 ] || return 1
  case "$label" in
    *" · "*) key=${label##*" · "} ;;
    *) return 1 ;;
  esac
  case "$key" in
    [a-z0-9][a-z0-9][a-z0-9][a-z0-9]|\
    [a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9]|\
    [a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9]|\
    [a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9]) ;;
    *) return 1 ;;
  esac
  case "$label" in
    Crew\ -\ *\ ·\ "$key") phrase=${label#Crew - }; phrase=${phrase%" · $key"} ;;
    Scout\ -\ *\ ·\ "$key") phrase=${label#Scout - }; phrase=${phrase%" · $key"} ;;
    2nd\ -\ *\ ·\ "$key") phrase=${label#2nd - }; phrase=${phrase%" · $key"} ;;
    *) return 1 ;;
  esac
  fm_task_label_phrase_is_valid "$phrase" || return 1
  printf '%s' "$key"
}

fm_task_label_semantic_phrase() {  # <task-id>
  local id=$1 tail lower_tail phrase word lower_word count=0 out='' first rest
  id=${id#fm-}
  id=${id##*/}
  tail=${id##*-}
  lower_tail=$(printf '%s' "$tail" | tr '[:upper:]' '[:lower:]')
  if [ "$(fm_task_label_base_key "$id")" = "$lower_tail" ]; then
    id=${id%-"$tail"}
  fi
  phrase=${id//-/ }
  for word in $phrase; do
    lower_word=$(printf '%s' "$word" | tr '[:upper:]' '[:lower:]')
    case "$lower_word" in
      fm|firstmate|crew|ship|scout|task|secondmate) continue ;;
    esac
    [[ "$word" == *[A-Za-z]* ]] || continue
    out="${out}${out:+ }$word"
    count=$((count + 1))
    [ "$count" -lt 4 ] || break
  done
  out=$(fm_task_label_sanitize_phrase "$out") || return 1
  if [ -n "$out" ]; then
    first=$(printf '%s' "$out" | cut -c1 | tr '[:lower:]' '[:upper:]')
    rest=${out:1}
    printf '%s%s' "$first" "$rest"
  fi
}

fm_task_label_backlog_title() {  # <backlog-path> <task-id>
  local backlog=$1 id=$2
  [ -f "$backlog" ] || return 0
  awk -v key="$id" '
    /^- \[[ xX]\] / {
      rest = $0
      sub(/^- \[[ xX]\] +/, "", rest)
      candidate = rest
      sub(/[[:space:]].*/, "", candidate)
      if (candidate == key) {
        sub(/^[^[:space:]]+[[:space:]]+/, "", rest)
        print rest
        exit
      }
    }
  ' "$backlog"
}

fm_task_label_read_record() {  # <record> <expected-id>; echoes label<TAB>key
  local record=$1 expected=$2 task_id label key label_key
  [ -f "$record" ] || return 1
  task_id=$(grep '^task_id=' "$record" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  label=$(grep '^display_label=' "$record" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  key=$(grep '^task_key=' "$record" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -z "$task_id" ] || [ "$task_id" = "$expected" ] || return 1
  label_key=$(fm_task_label_validate_display_label "$label") || return 1
  [ "$label_key" = "$key" ] || return 1
  printf '%s\t%s' "$label" "$key"
}

fm_task_label_collision() {  # <state> <current-id> <key> <candidate-label> <live-labels>
  local state=$1 current=$2 key=$3 candidate=$4 live=${5:-} record owner other_key other_label
  for record in "$state"/*.meta "$state"/*.herdr-label; do
    [ -f "$record" ] || continue
    owner=$(basename "$record")
    owner=${owner%.meta}
    owner=${owner%.herdr-label}
    [ "$owner" = "$current" ] && continue
    other_key=$(grep '^task_key=' "$record" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    other_label=$(grep '^display_label=' "$record" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    if [ -z "$other_key" ]; then
      case "$other_label" in *" · "*) other_key=${other_label##*" · "} ;; esac
    fi
    [ "$other_key" != "$key" ] && [ "$other_label" != "$candidate" ] || return 0
  done
  while IFS= read -r other_label; do
    [ -n "$other_label" ] || continue
    [ "$other_label" != "$candidate" ] || return 0
    case "$other_label" in *" · $key") return 0 ;; esac
  done <<EOF
$live
EOF
  return 1
}

fm_task_label_prepare() {  # <state> <id> <kind> <explicit-title> <live-labels> [backlog] [home] [session] [workspace]
  local state=$1 id=$2 kind=$3 explicit=${4:-} live=${5:-} backlog=${6:-}
  local herdr_home=${7:-} herdr_session=${8:-} herdr_workspace=${9:-}
  local journal meta existing kind_label key phrase candidate hash tmp
  local existing_home existing_session existing_workspace
  journal="$state/$id.herdr-label"
  meta="$state/$id.meta"
  if ! fm_task_label_task_id_is_valid "$id"; then
    echo "error: invalid task id for Herdr display label" >&2
    return 1
  fi
  mkdir -p "$state" || return 1

  if [ -e "$journal" ] || [ -L "$journal" ]; then
    if [ ! -f "$journal" ] || ! existing=$(fm_task_label_read_record "$journal" "$id"); then
      echo "error: malformed Herdr label journal for $id" >&2
      return 1
    fi
    if [ -f "$meta" ]; then
      candidate=$(fm_task_label_read_record "$meta" "$id" 2>/dev/null || true)
      [ -z "$candidate" ] || [ "$candidate" = "$existing" ] || {
        echo "error: Herdr label journal and metadata disagree for $id" >&2
        return 1
      }
    fi
    existing_home=$(grep '^herdr_home=' "$journal" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    existing_session=$(grep '^herdr_session=' "$journal" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    existing_workspace=$(grep '^herdr_workspace_id=' "$journal" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -z "$existing_home" ] || [ -z "$herdr_home" ] || [ "$existing_home" = "$herdr_home" ] || return 1
    [ -z "$existing_session" ] || [ -z "$herdr_session" ] || [ "$existing_session" = "$herdr_session" ] || return 1
    [ -z "$existing_workspace" ] || [ -z "$herdr_workspace" ] || [ "$existing_workspace" = "$herdr_workspace" ] || return 1
    if { [ -n "$herdr_home" ] && [ -z "$existing_home" ]; } ||
       { [ -n "$herdr_session" ] && [ -z "$existing_session" ]; } ||
       { [ -n "$herdr_workspace" ] && [ -z "$existing_workspace" ]; }; then
      candidate=${existing%%$'\t'*}
      key=${existing#*$'\t'}
      tmp=$(mktemp "$state/.$id.herdr-label.XXXXXX") || return 1
      chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
      {
        printf 'version=1\n'
        printf 'task_id=%s\n' "$id"
        printf 'display_label=%s\n' "$candidate"
        printf 'task_key=%s\n' "$key"
        printf 'herdr_home=%s\n' "${existing_home:-$herdr_home}"
        printf 'herdr_session=%s\n' "${existing_session:-$herdr_session}"
        printf 'herdr_workspace_id=%s\n' "${existing_workspace:-$herdr_workspace}"
      } > "$tmp" || { rm -f "$tmp"; return 1; }
      mv "$tmp" "$journal" || { rm -f "$tmp"; return 1; }
    fi
    printf '%s' "$existing"
    return 0
  fi
  if existing=$(fm_task_label_read_record "$meta" "$id" 2>/dev/null); then
    candidate=${existing%%$'\t'*}
    key=${existing#*$'\t'}
  else
    kind_label=$(fm_task_label_kind "$kind") || {
      echo "error: unsupported task kind for Herdr display label: $kind" >&2
      return 1
    }
    key=$(fm_task_label_base_key "$id") || return 1
    phrase=
    if [ -n "$explicit" ]; then
      phrase=$(fm_task_label_sanitize_phrase "$explicit") || return 1
    fi
    if [ -z "$phrase" ] && [ -n "$backlog" ]; then
      phrase=$(fm_task_label_backlog_title "$backlog" "$id")
      phrase=$(fm_task_label_sanitize_phrase "$phrase") || return 1
    fi
    if [ -z "$phrase" ]; then
      phrase=$(fm_task_label_semantic_phrase "$id") || return 1
    fi
    [ -n "$phrase" ] || phrase="Task $key"
    candidate="$kind_label - $phrase · $key"
    if fm_task_label_collision "$state" "$id" "$key" "$candidate" "$live"; then
      hash=$(fm_task_label_sha256 "$id") || return 1
      key=${hash:0:10}
      candidate="$kind_label - $phrase · $key"
      fm_task_label_collision "$state" "$id" "$key" "$candidate" "$live" && {
        echo "error: 10-character Herdr task-key collision for $id" >&2
        return 1
      }
    fi
  fi
  [ "$(fm_task_label_character_count "$candidate")" -le 50 ] || {
    echo "error: Herdr display label exceeds 50 characters" >&2
    return 1
  }

  tmp=$(mktemp "$state/.$id.herdr-label.XXXXXX") || return 1
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  {
    printf 'version=1\n'
    printf 'task_id=%s\n' "$id"
    printf 'display_label=%s\n' "$candidate"
    printf 'task_key=%s\n' "$key"
    [ -z "$herdr_home" ] || printf 'herdr_home=%s\n' "$herdr_home"
    [ -z "$herdr_session" ] || printf 'herdr_session=%s\n' "$herdr_session"
    [ -z "$herdr_workspace" ] || printf 'herdr_workspace_id=%s\n' "$herdr_workspace"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  if ! mv "$tmp" "$journal"; then
    rm -f "$tmp"
    return 1
  fi
  printf '%s\t%s' "$candidate" "$key"
}
