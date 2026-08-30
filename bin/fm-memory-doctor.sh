#!/usr/bin/env bash
# Read-only diagnostic for fleet memory and knowledge files.
# Usage:
#   fm-memory-doctor.sh
#   fm-memory-doctor.sh --home-local
#   fm-memory-doctor.sh --inherited-hashes
#
# Detects and reports memory problems for this home and every registered
# local or remote secondmate. It never edits memory, configuration, inherited
# files, tasks, or remote homes. Registered remote checks print UNKNOWN because
# Firstmate has no non-staging read-only remote inspection boundary.
#
# Checks, in stable order:
#   budget            reuse bin/fm-startup-memory-budget.sh report
#   pointers          concrete path tokens from memory files; globs, documented
#                     optional absent home-local files, and pointers declared
#                     primary-home-only in shared captain memory are valid only
#                     when checking a validated secondmate home
#   staleness         retired subjects, superseded pins, installed-version claims
#   contradictions    mechanically comparable rule.KEY=VALUE facts; configured
#                     crew-harness fallback vs dispatch default is not a gap
#   inherited-hash    declared inherited files vs each secondmate home
#   project-notes     *-notes.md older than 30 days with in-flight project work
#
# Invocation: bin/fm-bootstrap.sh runs `fm-memory-doctor.sh --home-local` as a
# fail-open advisory detect. A threatening GAP prints MEMORY_DOCTOR and does not
# change bootstrap's exit 0. This script never becomes a daemon, timer, or gate.
#
# Line protocol:
#   memory-doctor
#   check <name> <subject>=PASS|GAP|UNKNOWN evidence=<path-or-command> detail=<text>
#   summary pass=<n> gap=<n> unknown=<n> threatening=<n>
# Exit 1 only for a verified GAP that threatens memory reliability
# (budget, pointers, contradictions, inherited-hash). UNKNOWN and stow-class
# gaps (staleness, project-notes) report clearly and exit 0.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
NOTE_MAX_AGE_SECONDS=$((30 * 24 * 60 * 60))
DETAIL_MAX=180

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-crew-dispatch-lib.sh
. "$SCRIPT_DIR/fm-crew-dispatch-lib.sh"
# shellcheck source=bin/fm-home-layout-lib.sh
. "$SCRIPT_DIR/fm-home-layout-lib.sh"

usage() {
  sed -n '2,33{s/^# \{0,1\}//;p;}' "$0"
}

die_usage() {
  usage >&2
  exit 2
}

truncate_detail() {
  local text=$1
  text=${text//$'\n'/ }
  text=${text//$'\t'/ }
  if [ "${#text}" -gt "$DETAIL_MAX" ]; then
    printf '%s...' "${text:0:DETAIL_MAX}"
  else
    printf '%s' "$text"
  fi
}

safe_token() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*|-* ) return 1 ;;
  esac
  return 0
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

now_epoch() {
  date +%s
}

is_secretish_path() {
  local p
  p=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$p" in
    *.env|*token*|*password*|*secret*|*credential*|*transcript*) return 0 ;;
  esac
  return 1
}

# Findings: check<TAB>subject<TAB>verdict<TAB>evidence<TAB>detail
FINDINGS=$(mktemp "${TMPDIR:-/tmp}/fm-memory-doctor.XXXXXX")
trap 'rm -f "$FINDINGS"' EXIT

record() {
  local check=$1 subject=$2 verdict=$3 evidence=$4 detail=$5
  printf '%s\t%s\t%s\t%s\t%s\n' "$check" "$subject" "$verdict" "$evidence" "$(truncate_detail "$detail")" >> "$FINDINGS"
}

run_budget_report() {
  local home=$1 config=$2 data=$3 state=$4
  FM_HOME="$home" \
  FM_CONFIG_OVERRIDE="$config" \
  FM_DATA_OVERRIDE="$data" \
  FM_STATE_OVERRIDE="$state" \
    "$SCRIPT_DIR/fm-startup-memory-budget.sh" report
}

path_for_home_rel() {
  local home=$1 config=$2 data=$3 state=$4 rel=$5
  case "$rel" in
    config/*) printf '%s/%s' "$config" "${rel#config/}" ;;
    data/*) printf '%s/%s' "$data" "${rel#data/}" ;;
    state/*) printf '%s/%s' "$state" "${rel#state/}" ;;
    *) printf '%s/%s' "$home" "$rel" ;;
  esac
}

directory_is_searchable() {
  local dir=$1
  [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] || return 1
  (cd "$dir" && :) 2>/dev/null
}

path_parent_is_searchable() {
  local path=$1 probe parent
  probe=${path%/*}
  if [ "$probe" = "$path" ]; then
    probe=.
  elif [ -z "$probe" ]; then
    probe=/
  fi
  while [ ! -e "$probe" ] && [ ! -L "$probe" ]; do
    parent=${probe%/*}
    if [ "$parent" = "$probe" ]; then
      break
    elif [ -z "$parent" ]; then
      parent=/
    fi
    probe=$parent
  done
  directory_is_searchable "$probe"
}

emit_inherited_hashes() {
  local home=$1 config=$2 data=$3 rel path status hash
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    path=$(path_for_home_rel "$home" "$config" "$data" "$home/state" "$rel")
    status=absent
    hash=-
    if ! path_parent_is_searchable "$path"; then
      status=unreadable
    elif [ -e "$path" ] || [ -L "$path" ]; then
      if [ -L "$path" ] || [ ! -f "$path" ]; then
        status=unreadable
      elif hash=$(fm_inherit_sha256 "$path" 2>/dev/null) && [ -n "$hash" ]; then
        status=present
      else
        status=unreadable
        hash=-
      fi
    fi
    printf 'inherited %s status=%s hash=%s\n' "$rel" "$status" "$hash"
  done < <(fm_config_inherit_items)
}

extract_backtick_and_link_tokens() {
  local file=$1 line rest tok destination
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    rest=$line
    while [[ "$rest" == *'`'* ]]; do
      rest=${rest#*\`}
      [[ "$rest" == *'`'* ]] || break
      tok=${rest%%\`*}
      rest=${rest#*\`}
      printf 'backtick\t%s\t%s\n' "$tok" "$tok"
    done
    rest=$line
    while [[ "$rest" == *']('* ]]; do
      rest=${rest#*](}
      fm_home_markdown_link_payload "$rest" || break
      tok=$FM_HOME_MARKDOWN_LINK_PAYLOAD
      rest=$FM_HOME_MARKDOWN_LINK_REST
      destination=$(fm_home_markdown_link_destination "$tok") || continue
      printf 'link\t%s\t%s\n' "$tok" "$destination"
    done
  done < "$file"
}

is_glob_pointer_token() {
  case "$1" in
    *'*'*|*'?'*|*'['*) return 0 ;;
  esac
  return 1
}

absent_pointer_status() {
  local home_kind=$1 home=$2 config=$3 data=$4 state=$5 tok=$6
  case "$tok" in
    "$config"/*) tok="config/${tok#"$config"/}" ;;
    "$data"/*) tok="data/${tok#"$data"/}" ;;
    "$state"/*) tok="state/${tok#"$state"/}" ;;
    "$home"/*) tok=${tok#"$home"/} ;;
  esac
  fm_home_path_absence_status "$home_kind" "$home" "$tok" "$state" "$config" "$data"
}

classify_pointer_token() {
  local tok=$1
  case "$tok" in
    ''|*[[:space:]]*) return 1 ;;
    *'..'*|*'://'*) return 1 ;;
  esac
  is_glob_pointer_token "$tok" && return 1
  is_secretish_path "$tok" && return 1
  case "$tok" in
    /*|data/*|config/*|state/*|bin/*|docs/*|.agents/*|skills/*)
      printf 'path\n'
      return 0
      ;;
    */*)
      printf 'unclassified\n'
      return 0
      ;;
    *.md|*.json|*.sh|*.toml)
      printf 'unclassified\n'
      return 0
      ;;
  esac
  return 1
}

resolve_pointer_token() {
  local home=$1 config=$2 data=$3 state=$4 tok=$5
  case "$tok" in
    /*) printf '%s' "$tok" ;;
    config/*|data/*|state/*) path_for_home_rel "$home" "$config" "$data" "$state" "$tok" ;;
    bin/*|docs/*|.agents/*|skills/*) printf '%s/%s' "$FM_ROOT" "$tok" ;;
    *) return 1 ;;
  esac
}

classify_pointer_target() {
  local path=$1 depth=${2:-0} link target
  POINTER_TARGET_STATUS=UNKNOWN
  if [ "$depth" -ge 40 ]; then
    return 0
  fi
  if ! path_parent_is_searchable "$path"; then
    return 0
  fi
  if [ -L "$path" ]; then
    link=$(readlink "$path" 2>/dev/null) || return 0
    case "$link" in
      /*) target=$link ;;
      *) target="$(dirname "$path")/$link" ;;
    esac
    if [ ! -e "$path" ]; then
      classify_pointer_target "$target" $((depth + 1))
      if [ "$POINTER_TARGET_STATUS" = MISSING ] || [ "$POINTER_TARGET_STATUS" = DANGLING ]; then
        POINTER_TARGET_STATUS=DANGLING
      fi
      return 0
    fi
  fi
  if [ -f "$path" ]; then
    if [ -r "$path" ] && (: < "$path") 2>/dev/null; then
      POINTER_TARGET_STATUS=PASS
    fi
  elif [ -d "$path" ]; then
    if directory_is_searchable "$path"; then
      POINTER_TARGET_STATUS=PASS
    fi
  elif [ ! -e "$path" ] && [ ! -L "$path" ]; then
    POINTER_TARGET_STATUS=MISSING
  fi
}

enumerate_memory_files() {
  local data=$1 manifest=$2 errors=$3 candidates f
  : > "$manifest"
  : > "$errors"
  if ! directory_is_searchable "$data"; then
    printf 'directory\t%s\n' "$data" >> "$errors"
    return 0
  fi
  candidates=$(mktemp "${TMPDIR:-/tmp}/fm-memory-doctor-candidates.XXXXXX")
  for f in "$data/captain.md" "$data/captain-shared.md" \
    "$data/learnings.md" "$data/model-routing.md"; do
    if [ -e "$f" ] || [ -L "$f" ]; then
      if [ ! -f "$f" ] || [ -L "$f" ]; then
        printf 'unsafe\t%s\n' "$f" >> "$errors"
      else
        printf '%s\n' "$f" >> "$candidates"
      fi
    fi
  done
  for f in "$data/"*-notes.md "$data/"*pointer* "$data/"*pointers*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    if [ ! -f "$f" ] || [ -L "$f" ]; then
      printf 'unsafe\t%s\n' "$f" >> "$errors"
    else
      printf '%s\n' "$f" >> "$candidates"
    fi
  done
  LC_ALL=C sort -u "$candidates" | while IFS= read -r f; do
    if [ ! -r "$f" ] || ! (: < "$f") 2>/dev/null; then
      printf 'file\t%s\n' "$f" >> "$errors"
    else
      printf '%s\n' "$f" >> "$manifest"
    fi
  done
  rm -f "$candidates"
}

memory_files_error_detail() {
  local errors=$1 kind path files directories unsafe
  files=""
  directories=""
  unsafe=""
  while IFS=$'\t' read -r kind path; do
    [ -n "$path" ] || continue
    case "$kind" in
      directory) directories="$directories $path" ;;
      file) files="$files $path" ;;
      unsafe) unsafe="$unsafe $path" ;;
    esac
  done < "$errors"
  directories=${directories# }
  files=${files# }
  unsafe=${unsafe# }
  if [ -n "$directories" ]; then
    printf 'memory directory is unreadable: %s' "$directories"
  elif [ -n "$unsafe" ]; then
    printf 'memory input is unsafe: %s' "$unsafe"
  elif [ -n "$files" ]; then
    printf 'memory file is unreadable: %s' "$files"
  fi
}

extract_one_field() {
  local file=$1 prefix=$2
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  awk -v prefix="$prefix" '
    index($0, prefix) == 1 {
      rest = substr($0, length(prefix) + 1)
      if (rest ~ /^[A-Za-z0-9._-]+$/) print rest
    }
  ' "$file"
}

extract_two_fields() {
  local file=$1 prefix=$2
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  awk -v prefix="$prefix" '
    index($0, prefix) == 1 {
      rest = substr($0, length(prefix) + 1)
      if (rest ~ /^[A-Za-z0-9._-]+[[:space:]]+[A-Za-z0-9._+-]+$/) print rest
    }
  ' "$file"
}

extract_rule_facts() {
  local file=$1 source=$2
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  awk -v source="$source" '
    /^rule\.[A-Za-z0-9._-]+=[^[:space:]]+$/ {
      split($0, parts, "=")
      key = parts[1]
      val = substr($0, length(key) + 2)
      printf "%s\t%s\t%s\n", key, val, source
    }
  ' "$file"
}

configured_effective_default_harness() {
  local config=$1 dispatch static value
  dispatch="$config/crew-dispatch.json"
  static="$config/crew-harness"
  if ! path_parent_is_searchable "$dispatch"; then
    printf 'UNAVAILABLE\t-\tcrew dispatch parent is unreadable\n'
    return 0
  fi
  if [ -e "$dispatch" ] || [ -L "$dispatch" ]; then
    if [ ! -f "$dispatch" ] || [ -L "$dispatch" ] || [ ! -r "$dispatch" ] \
      || ! (: < "$dispatch") 2>/dev/null; then
      printf 'UNAVAILABLE\t-\tcrew dispatch is unreadable\n'
      return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
      printf 'UNAVAILABLE\t-\tjq is unavailable\n'
      return 0
    fi
    if ! fm_crew_dispatch_validate_file "$dispatch"; then
      printf 'UNAVAILABLE\t-\tcrew dispatch is invalid: %s\n' "$FM_CREW_DISPATCH_ERROR"
      return 0
    fi
    if ! fm_crew_dispatch_resolve_default_harness "$dispatch"; then
      printf 'UNAVAILABLE\t-\tdispatch default could not be resolved\n'
      return 0
    fi
    case "$FM_CREW_DISPATCH_DEFAULT_STATUS" in
      unresolved)
        printf 'UNAVAILABLE\t-\tdispatch default requires runtime selection\n'
        return 0
        ;;
      value)
        value=$FM_CREW_DISPATCH_DEFAULT_HARNESS
        printf 'VALUE\t%s\tconfigured dispatch default\n' "$value"
        return 0
        ;;
      static) ;;
      *)
        printf 'UNAVAILABLE\t-\tdispatch default could not be resolved\n'
        return 0
        ;;
    esac
  fi
  if ! path_parent_is_searchable "$static"; then
    printf 'UNAVAILABLE\t-\tstatic crew harness parent is unreadable\n'
  elif [ -e "$static" ] || [ -L "$static" ]; then
    if [ ! -f "$static" ] || [ -L "$static" ] || [ ! -r "$static" ] \
      || ! (: < "$static") 2>/dev/null; then
      printf 'UNAVAILABLE\t-\tstatic crew harness is unreadable\n'
      return 0
    fi
    value=$(tr -d '\r' < "$static")
    value=${value%$'\n'}
    if [ "$value" = default ]; then
      printf 'UNAVAILABLE\t-\tstatic crew harness defers to the current session\n'
    elif safe_token "$value"; then
      printf 'VALUE\t%s\tstatic crew harness\n' "$value"
    else
      printf 'UNAVAILABLE\t-\tstatic crew harness is invalid\n'
    fi
  else
    printf 'UNAVAILABLE\t-\tstatic crew harness defers to the current session\n'
  fi
}

check_budget_local() {
  local subject=$1 home=$2 config=$3 data=$4 state=$5 out rc status
  if [ ! -d "$home" ]; then
    record budget "$subject" UNKNOWN "$home" "home directory is not readable"
    return 0
  fi
  if ! directory_is_searchable "$data"; then
    record budget "$subject" UNKNOWN "$data" "memory directory is unreadable"
    return 0
  fi
  set +e
  out=$(run_budget_report "$home" "$config" "$data" "$state" 2>/dev/null)
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    record budget "$subject" UNKNOWN "bin/fm-startup-memory-budget.sh report" "report failed with exit $rc"
    return 0
  fi
  status=$(printf '%s\n' "$out" | awk -F= '$1=="budget_status" {print $2; exit}')
  case "$status" in
    within-budget)
      record budget "$subject" PASS "bin/fm-startup-memory-budget.sh report" "within-budget"
      ;;
    over-budget)
      record budget "$subject" GAP "bin/fm-startup-memory-budget.sh report" "over-budget"
      ;;
    *)
      record budget "$subject" UNKNOWN "bin/fm-startup-memory-budget.sh report" "report did not include budget_status"
      ;;
  esac
}

check_pointers_home() {
  local subject=$1 home_kind=$2 home=$3 config=$4 data=$5 state=$6 files=$7 errors=$8
  local file origin evidence tok path_tok class resolved broken unclassified unreadable unavailable absence_status
  broken=""
  unclassified=""
  unavailable=""
  if [ ! -d "$data" ]; then
    record pointers "$subject" UNKNOWN "$data" "memory directory is not readable"
    return 0
  fi
  unreadable=$(memory_files_error_detail "$errors" || true)
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    while IFS=$'\t' read -r origin evidence tok; do
      [ -n "$tok" ] || continue
      path_tok=$tok
      [ "$origin" != link ] || path_tok=${tok%%[\?#]*}
      class=$(classify_pointer_token "$path_tok" || true)
      case "$class" in
        unclassified)
          case " $unclassified " in *" $evidence "*) ;; *) unclassified="$unclassified $evidence" ;; esac
          ;;
        path)
          resolved=$(resolve_pointer_token "$home" "$config" "$data" "$state" "$path_tok") || continue
          classify_pointer_target "$resolved"
          case "$POINTER_TARGET_STATUS" in
            PASS) continue ;;
            MISSING)
              absence_status=$(absent_pointer_status "$home_kind" "$home" "$config" "$data" "$state" "$path_tok")
              case "$absence_status" in
                OPTIONAL) continue ;;
                UNKNOWN)
                  case " $unavailable " in *" $evidence "*) ;; *) unavailable="$unavailable $evidence" ;; esac
                  ;;
                REQUIRED)
                  case " $broken " in *" $evidence "*) ;; *) broken="$broken $evidence" ;; esac
                  ;;
                *)
                  case " $unavailable " in *" $evidence "*) ;; *) unavailable="$unavailable $evidence" ;; esac
                  ;;
              esac
              ;;
            DANGLING)
              case " $broken " in *" $evidence "*) ;; *) broken="$broken $evidence" ;; esac
              ;;
            UNKNOWN)
              case " $unavailable " in *" $evidence "*) ;; *) unavailable="$unavailable $evidence" ;; esac
              ;;
          esac
          ;;
      esac
    done < <(extract_backtick_and_link_tokens "$file")
  done < "$files"
  broken=${broken# }
  unclassified=${unclassified# }
  unavailable=${unavailable# }
  if [ -n "$broken" ]; then
    record pointers "$subject" GAP "$data" "missing $broken"
    return 0
  fi
  if [ -n "$unreadable" ]; then
    record pointers "$subject" UNKNOWN "$data" "$unreadable"
    return 0
  fi
  if [ -n "$unavailable" ]; then
    record pointers "$subject" UNKNOWN "$data" "pointer target or absence contract is unavailable: $unavailable"
    return 0
  fi
  if [ -n "$unclassified" ]; then
    record pointers "$subject" PASS "$data" "no broken pointers; unclassified $unclassified"
    return 0
  fi
  record pointers "$subject" PASS "$data" "no broken pointers"
}

check_staleness_home() {
  local subject=$1 data=$2 files=$3 errors=$4 file id tool ver prev resolved gaps unverified pinfile unreadable
  local registry registry_status registry_unknown
  gaps=""
  unverified=""
  registry="$DATA/secondmates.md"
  registry_status=absent
  registry_unknown=""
  pinfile=$(mktemp "${TMPDIR:-/tmp}/fm-memory-doctor-pins.XXXXXX")
  if [ ! -d "$data" ]; then
    rm -f "$pinfile"
    record staleness "$subject" UNKNOWN "$data" "memory directory is not readable"
    return 0
  fi
  unreadable=$(memory_files_error_detail "$errors" || true)
  if ! path_parent_is_searchable "$registry"; then
    registry_status=unreadable
  elif [ -e "$registry" ] || [ -L "$registry" ]; then
    if [ -f "$registry" ] && [ ! -L "$registry" ] && [ -r "$registry" ] \
      && (: < "$registry") 2>/dev/null; then
      registry_status=readable
    else
      registry_status=unreadable
    fi
  fi
  if [ "$registry_status" = readable ] \
    && ! secondmate_registry_validate_bindings "$registry" secondmate_registry_path_key; then
    registry_status=invalid
    registry_unknown=$SECONDMATE_REGISTRY_ERROR
  fi
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    while read -r id; do
      [ -n "$id" ] || continue
      safe_token "$id" || continue
      case "$registry_status" in
        unreadable) registry_unknown="$registry is unreadable" ;;
        invalid) ;;
        absent) gaps="$gaps retired-active:$id" ;;
        readable)
          secondmate_registry_line_for_id "$registry" "$id" 2>/dev/null \
            || gaps="$gaps retired-active:$id"
          ;;
      esac
    done < <(extract_one_field "$file" "active_secondmate: ")
    while read -r tool ver; do
      [ -n "$tool" ] || continue
      prev=$(awk -F '\t' -v tool="$tool" '$1==tool {print $2; exit}' "$pinfile")
      if [ -n "$prev" ] && [ "$prev" != "$ver" ]; then
        gaps="$gaps superseded-pin:$tool:$prev->$ver"
      fi
      printf '%s\t%s\n' "$tool" "$ver" >> "$pinfile"
    done < <(extract_two_fields "$file" "pin: ")
    while read -r tool ver; do
      [ -n "$tool" ] || continue
      safe_token "$tool" || continue
      resolved=$(type -P -- "$tool" 2>/dev/null || true)
      if [ -z "$resolved" ] || [ ! -f "$resolved" ]; then
        unverified="$unverified installed-unavailable:$tool"
      else
        unverified="$unverified installed-version-unverified:$tool:$ver"
      fi
    done < <(extract_two_fields "$file" "installed: ")
  done < "$files"
  rm -f "$pinfile"
  gaps=${gaps# }
  if [ -n "$gaps" ]; then
    record staleness "$subject" GAP "$data" "$gaps"
    return 0
  fi
  if [ -n "$unreadable" ]; then
    record staleness "$subject" UNKNOWN "$data" "$unreadable"
    return 0
  fi
  if [ -n "$registry_unknown" ]; then
    record staleness "$subject" UNKNOWN "$registry" "$registry_unknown"
    return 0
  fi
  unverified=${unverified# }
  if [ -n "$unverified" ]; then
    record staleness "$subject" UNKNOWN "$data" "$unverified"
    return 0
  fi
  record staleness "$subject" PASS "$data" "no staleness signals"
}

rule_lookup() {
  local store=$1 key=$2 field=$3
  awk -F '\t' -v key="$key" -v field="$field" '$1==key { print (field=="val" ? $2 : $3); exit }' "$store"
}

rule_store() {
  local store=$1 key=$2 val=$3 source=$4
  printf '%s\t%s\t%s\n' "$key" "$val" "$source" >> "$store"
}

absorb_rule() {
  local store=$1 key=$2 val=$3 source=$4 prev src
  [ -n "$key" ] && [ -n "$val" ] || return 0
  prev=$(rule_lookup "$store" "$key" val)
  src=$(rule_lookup "$store" "$key" src)
  if [ -n "$prev" ] && [ "$prev" != "$val" ]; then
    printf ' %s:%s=%s vs %s=%s' "$key" "$src" "$prev" "$source" "$val"
    return 0
  fi
  [ -n "$prev" ] || rule_store "$store" "$key" "$val" "$source"
  return 0
}

check_contradictions_home() {
  local subject=$1 home=$2 config=$3 data=$4 files=$5 errors=$6
  local file rel source key val gaps store unreadable configured status detail claim claim_source configured_unknown
  gaps=""
  store=$(mktemp "${TMPDIR:-/tmp}/fm-memory-doctor-rules.XXXXXX")
  if [ ! -d "$data" ] && [ ! -d "$config" ]; then
    rm -f "$store"
    record contradictions "$subject" UNKNOWN "$home" "home is not readable"
    return 0
  fi
  unreadable=$(memory_files_error_detail "$errors" || true)
  configured_unknown=""

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    rel="data/${file#"$data"/}"
    while IFS=$'\t' read -r key val source; do
      gaps="$gaps$(absorb_rule "$store" "$key" "$val" "$source")"
    done < <(extract_rule_facts "$file" "$rel")
  done < "$files"
  gaps=${gaps# }
  if [ -n "$gaps" ]; then
    rm -f "$store"
    record contradictions "$subject" GAP "$data" "$gaps"
    return 0
  fi
  claim=$(rule_lookup "$store" rule.default_harness val)
  claim_source=$(rule_lookup "$store" rule.default_harness src)
  rm -f "$store"
  if [ -n "$claim" ]; then
    IFS=$'\t' read -r status configured detail \
      <<< "$(configured_effective_default_harness "$config")"
    if [ "$status" != VALUE ]; then
      configured_unknown=$detail
    elif [ "$claim" != "$configured" ]; then
      record contradictions "$subject" GAP "$data" \
        "rule.default_harness:${claim_source}=${claim} vs configured-effective=${configured}"
      return 0
    fi
  fi
  if [ -n "$unreadable" ]; then
    record contradictions "$subject" UNKNOWN "$data" "$unreadable"
    return 0
  fi
  if [ -n "$configured_unknown" ]; then
    record contradictions "$subject" UNKNOWN "$config" "$configured_unknown"
    return 0
  fi
  record contradictions "$subject" PASS "$data" "no mechanical rule contradictions"
}

compare_inherited_hashes() {
  local subject=$1 primary_out=$2 other_out=$3 evidence=$4
  local rel p_status p_hash o_status o_hash mismatches unreadable
  mismatches=""
  unreadable=""
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in
      config/*)
        fm_config_inherit_item_session_scoped "${rel#config/}" && continue
        ;;
    esac
    p_status=$(printf '%s\n' "$primary_out" | awk -v rel="$rel" '$1=="inherited" && $2==rel {split($3,a,"="); print a[2]; exit}')
    p_hash=$(printf '%s\n' "$primary_out" | awk -v rel="$rel" '$1=="inherited" && $2==rel {split($4,a,"="); print a[2]; exit}')
    o_status=$(printf '%s\n' "$other_out" | awk -v rel="$rel" '$1=="inherited" && $2==rel {split($3,a,"="); print a[2]; exit}')
    o_hash=$(printf '%s\n' "$other_out" | awk -v rel="$rel" '$1=="inherited" && $2==rel {split($4,a,"="); print a[2]; exit}')
    if [ "$p_status" = unreadable ] || [ "$o_status" = unreadable ]; then
      [ -n "$unreadable" ] || unreadable=$rel
      continue
    fi
    if [ "$p_status" != "$o_status" ] || [ "$p_hash" != "$o_hash" ]; then
      mismatches="$mismatches $rel"
    fi
  done < <(fm_config_inherit_items)
  mismatches=${mismatches# }
  if [ -n "$mismatches" ]; then
    record inherited-hash "$subject" GAP "$evidence" "hash mismatch $mismatches"
    return 0
  fi
  if [ -n "$unreadable" ]; then
    record inherited-hash "$subject" UNKNOWN "$evidence" "$unreadable is unreadable"
    return 0
  fi
  record inherited-hash "$subject" PASS "$evidence" "inherited files match"
}

check_inherited_local() {
  local subject=$1 home=$2 primary_out other_out
  if [ ! -d "$home" ]; then
    record inherited-hash "$subject" UNKNOWN "$home" "home directory is not readable"
    return 0
  fi
  primary_out=$(emit_inherited_hashes "$FM_HOME" "$CONFIG" "$DATA")
  other_out=$(emit_inherited_hashes "$home" "$home/config" "$home/data")
  compare_inherited_hashes "$subject" "$primary_out" "$other_out" "$home"
}

project_in_flight() {
  local data=$1 state=$2 slug=$3 file
  for file in "$state"/*.meta; do
    [ -f "$file" ] && [ ! -L "$file" ] || continue
    grep -F -x -q -- "project=$slug" "$file" && return 0
  done
  if [ -f "$data/backlog.md" ] && [ ! -L "$data/backlog.md" ]; then
    awk -v slug="$slug" '
      $0 == "## In flight" { in_flight = 1; next }
      /^## / { in_flight = 0 }
      in_flight && index($0, "- [ ]") == 1 && index($0, "(repo: " slug ")") { found = 1; exit }
      END { exit(found ? 0 : 1) }
    ' "$data/backlog.md" && return 0
  fi
  return 1
}

project_notes_input_error() {
  local data=$1 state=$2 path
  for path in "$data/projects.md" "$data/backlog.md"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      if [ ! -f "$path" ] || [ -L "$path" ] || [ ! -r "$path" ] || ! (: < "$path") 2>/dev/null; then
        printf 'project activity input is unreadable: %s' "$path"
        return 0
      fi
    fi
  done
  if ! path_parent_is_searchable "$state"; then
    printf 'project activity directory parent is unreadable: %s' "$state"
    return 0
  elif [ -e "$state" ] || [ -L "$state" ]; then
    if ! directory_is_searchable "$state"; then
      printf 'project activity directory is unreadable: %s' "$state"
      return 0
    fi
    for path in "$state"/*.meta; do
      [ -e "$path" ] || [ -L "$path" ] || continue
      if [ ! -f "$path" ] || [ -L "$path" ] || [ ! -r "$path" ] || ! (: < "$path") 2>/dev/null; then
        printf 'project activity input is unreadable: %s' "$path"
        return 0
      fi
    done
  fi
}

check_project_notes_home() {
  local subject=$1 data=$2 state=$3 files=$4 errors=$5
  local file slug mtime now age stale unreadable
  stale=""
  unreadable=$(memory_files_error_detail "$errors" || true)
  if [ -z "$unreadable" ]; then
    unreadable=$(project_notes_input_error "$data" "$state" || true)
  fi
  now=$(now_epoch)
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    case "$file" in "$data/"*-notes.md) ;; *) continue ;; esac
    slug=$(basename "$file")
    slug=${slug%-notes.md}
    [ -n "$slug" ] || continue
    project_in_flight "$data" "$state" "$slug" || continue
    mtime=$(file_mtime "$file") || continue
    age=$((now - mtime))
    if [ "$age" -gt "$NOTE_MAX_AGE_SECONDS" ]; then
      stale="$stale data/${slug}-notes.md"
    fi
  done < "$files"
  stale=${stale# }
  if [ -n "$stale" ]; then
    record project-notes "$subject" GAP "$data" "stale active-project notes $stale"
    return 0
  fi
  if [ -n "$unreadable" ]; then
    record project-notes "$subject" UNKNOWN "$data" "$unreadable"
    return 0
  fi
  record project-notes "$subject" PASS "$data" "no stale active-project notes"
}

check_local_home() {
  local subject=$1 home_kind=$2 home=$3 config=$4 data=$5 state=$6 files errors
  files=$(mktemp "${TMPDIR:-/tmp}/fm-memory-doctor-files.XXXXXX")
  errors=$(mktemp "${TMPDIR:-/tmp}/fm-memory-doctor-errors.XXXXXX")
  enumerate_memory_files "$data" "$files" "$errors"
  check_budget_local "$subject" "$home" "$config" "$data" "$state"
  check_pointers_home "$subject" "$home_kind" "$home" "$config" "$data" "$state" "$files" "$errors"
  check_staleness_home "$subject" "$data" "$files" "$errors"
  check_contradictions_home "$subject" "$home" "$config" "$data" "$files" "$errors"
  check_project_notes_home "$subject" "$data" "$state" "$files" "$errors"
  rm -f "$files" "$errors"
}

check_remote_home() {
  local subject=$1 check
  for check in budget pointers staleness contradictions inherited-hash project-notes; do
    record "$check" "$subject" UNKNOWN data/secondmates.md \
      "remote inspection unavailable: no read-only non-staging boundary"
  done
}

CHECK_ORDER=$'budget\npointers\nstaleness\ncontradictions\ninherited-hash\nproject-notes'
THREATENING=' budget pointers contradictions inherited-hash '

is_threatening_check() {
  case "$THREATENING" in *" $1 "*) return 0 ;; esac
  return 1
}

print_report() {
  local pass=0 gap=0 unknown=0 threatening=0 check subject verdict evidence detail threat_names
  threat_names=""
  printf 'memory-doctor\n'
  while IFS= read -r check; do
    [ -n "$check" ] || continue
    LC_ALL=C sort -t$'\t' -k2,2 "$FINDINGS" | awk -F '\t' -v want="$check" '$1==want {print}' | while IFS=$'\t' read -r check subject verdict evidence detail; do
      printf 'check %s %s=%s evidence=%s detail=%s\n' "$check" "$subject" "$verdict" "$evidence" "$detail"
    done
  done <<< "$CHECK_ORDER"
  while IFS=$'\t' read -r check subject verdict evidence detail; do
    case "$verdict" in
      PASS) pass=$((pass + 1)) ;;
      GAP)
        gap=$((gap + 1))
        if is_threatening_check "$check"; then
          threatening=$((threatening + 1))
          case " $threat_names " in *" $check "*) ;; *) threat_names="$threat_names $check" ;; esac
        fi
        ;;
      UNKNOWN) unknown=$((unknown + 1)) ;;
    esac
  done < "$FINDINGS"
  threat_names=${threat_names# }
  printf 'summary pass=%s gap=%s unknown=%s threatening=%s\n' "$pass" "$gap" "$unknown" "$threatening"
  if [ "$threatening" -gt 0 ]; then
    printf 'gap: memory reliability threats:%s\n' "$threat_names"
    return 1
  fi
  if [ "$gap" -gt 0 ]; then
    printf 'ok: no memory reliability threats; stow-class gaps remain\n'
    return 0
  fi
  printf 'ok: memory reliability checks passed\n'
  return 0
}

MODE=report
HOME_LOCAL=0
case "${1:-}" in
  '' ) ;;
  --inherited-hashes)
    [ "$#" -eq 1 ] || die_usage
    MODE=hashes
    ;;
  --home-local)
    [ "$#" -eq 1 ] || die_usage
    HOME_LOCAL=1
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    die_usage
    ;;
esac

if [ "$MODE" = hashes ]; then
  emit_inherited_hashes "$FM_HOME" "$CONFIG" "$DATA"
  exit 0
fi

HOME_LOCAL_KIND=$(fm_home_layout_kind "$FM_HOME")
check_local_home primary "$HOME_LOCAL_KIND" "$FM_HOME" "$CONFIG" "$DATA" "$STATE"
if [ "$HOME_LOCAL" -eq 1 ]; then
  print_report
  exit
fi

have_secondmate=0
registry="$DATA/secondmates.md"
registry_status=absent
registry_id=""
registry_home=""
registry_remote=0
if ! directory_is_searchable "$DATA"; then
  registry_status=unreadable
elif [ -e "$registry" ] || [ -L "$registry" ]; then
  if [ -f "$registry" ] && [ ! -L "$registry" ] && [ -r "$registry" ] \
    && (: < "$registry") 2>/dev/null; then
    registry_status=readable
  else
    registry_status=unreadable
  fi
fi
registry_error=""
if [ "$registry_status" = readable ] \
  && ! secondmate_registry_validate_bindings "$registry" secondmate_registry_path_key; then
  registry_status=invalid
  registry_error=$SECONDMATE_REGISTRY_ERROR
fi
if [ "$registry_status" = readable ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || continue
    have_secondmate=1
    registry_id=$SECONDMATE_REGISTRY_ID
    registry_home=$SECONDMATE_REGISTRY_HOME
    registry_remote=$SECONDMATE_REGISTRY_REMOTE
    if [ "$registry_remote" -eq 1 ]; then
      check_remote_home "$registry_id"
    else
      check_local_home "$registry_id" secondmate "$registry_home" \
        "$registry_home/config" "$registry_home/data" "$registry_home/state"
      check_inherited_local "$registry_id" "$registry_home"
    fi
  done < "$registry"
fi
if [ "$registry_status" = unreadable ]; then
  record inherited-hash none UNKNOWN data/secondmates.md "secondmate registry is unreadable"
elif [ "$registry_status" = invalid ]; then
  record inherited-hash none UNKNOWN data/secondmates.md "$registry_error"
elif [ "$have_secondmate" -eq 0 ]; then
  record inherited-hash none PASS data/secondmates.md "no registered secondmates"
fi

print_report
