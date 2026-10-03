#!/usr/bin/env bash
# fm-task-id-rule-lib.sh - the bash loader for bin/fm-task-id-rule.conf.
#
# The rule and its contract live in that file's header; this file is generic
# load code only: parse the key=value artifact, validate it, fail closed, and
# expose the rule's three operations (structural reject, strip, candidate
# walk). The Python loader is load_task_id_rule in bin/fm-jev-decisions.py;
# neither side embeds a copy of the rule.
#
# Load contract: sourcing this file parses the artifact once, immediately.
# A missing, unreadable, or malformed artifact prints one diagnostic and exits
# the shell, so no caller can run with a guessed rule.
# Self-location follows bin/fm-backend.sh's own pattern so it resolves in
# sourced bash and zsh alike (zsh defines $0 as the sourced file, bash has
# BASH_SOURCE), and it stays pure-shell: PATH-stubbed tests must not need an
# external dirname to find the artifact that sits next to this file.
FM_TASK_ID_RULE_SCRIPT=${BASH_SOURCE[0]:-$0}
case "$FM_TASK_ID_RULE_SCRIPT" in
*/*) FM_TASK_ID_RULE_DIR="${FM_TASK_ID_RULE_SCRIPT%/*}" ;;
*) FM_TASK_ID_RULE_DIR="." ;;
esac
unset FM_TASK_ID_RULE_SCRIPT
FM_TASK_ID_RULE_DIR="$(cd "$FM_TASK_ID_RULE_DIR" 2>/dev/null && pwd)" || FM_TASK_ID_RULE_DIR="."
FM_TASK_ID_RULE_FILE="$FM_TASK_ID_RULE_DIR/fm-task-id-rule.conf"

fm_task_id_rule_load_error() { # <message>
  printf 'error: shared task-id rule %s: %s\n' "$FM_TASK_ID_RULE_FILE" "$1" >&2
  exit 1
}

fm_task_id_rule_load() {
  local line key value prefix='' candidates='' reject='' seen_prefix='' seen_candidates='' seen_reject='' rest tok

  [ -r "$FM_TASK_ID_RULE_FILE" ] || fm_task_id_rule_load_error "missing or unreadable"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    '' | '#'*) continue ;;
    esac
    case "$line" in
    *=*)
      key=${line%%=*}
      value=${line#*=}
      ;;
    *) fm_task_id_rule_load_error "malformed line: $line" ;;
    esac
    case "$key" in
    prefix)
      [ -z "$seen_prefix" ] || fm_task_id_rule_load_error "duplicate key: prefix"
      prefix=$value
      seen_prefix=1
      ;;
    candidates)
      [ -z "$seen_candidates" ] || fm_task_id_rule_load_error "duplicate key: candidates"
      candidates=$value
      seen_candidates=1
      ;;
    reject_contains)
      [ -z "$seen_reject" ] || fm_task_id_rule_load_error "duplicate key: reject_contains"
      reject=$value
      seen_reject=1
      ;;
    *) fm_task_id_rule_load_error "unknown key: $key" ;;
    esac
  done < "$FM_TASK_ID_RULE_FILE"

  [ -n "$seen_prefix" ] || fm_task_id_rule_load_error "missing key: prefix"
  [ -n "$seen_candidates" ] || fm_task_id_rule_load_error "missing key: candidates"
  [ -n "$seen_reject" ] || fm_task_id_rule_load_error "missing key: reject_contains"
  [ -n "$prefix" ] || fm_task_id_rule_load_error "empty value: prefix"
  [ -n "$candidates" ] || fm_task_id_rule_load_error "empty value: candidates"
  [ -n "$reject" ] || fm_task_id_rule_load_error "empty value: reject_contains"
  case "$candidates" in
  ,* | *, | *,,*)
    fm_task_id_rule_load_error "bad candidate list: $candidates"
    ;;
  esac
  rest=$candidates
  while [ -n "$rest" ]; do
    tok=${rest%%,*}
    case "$tok" in
    exact | stripped) ;;
    *) fm_task_id_rule_load_error "unknown candidate transform: $tok" ;;
    esac
    case "$rest" in
    *,*) rest=${rest#*,} ;;
    *) rest="" ;;
    esac
  done

  FM_TASK_ID_RULE_PREFIX=$prefix
  FM_TASK_ID_RULE_CANDIDATES=$candidates
  FM_TASK_ID_RULE_REJECT=$reject
}

fm_task_id_rule_is_prefixed() { # <string> -> 0 when the prefix is carried
  case "$1" in
  "$FM_TASK_ID_RULE_PREFIX"*) return 0 ;;
  esac
  return 1
}

fm_task_id_rule_rejected() { # <selector> -> 0 when structurally not a selector
  case "$1" in
  *"$FM_TASK_ID_RULE_REJECT"*) return 0 ;;
  esac
  return 1
}

fm_task_id_rule_strip() { # <string> -> one leading prefix removed
  local s=$1
  case "$s" in
  "$FM_TASK_ID_RULE_PREFIX"*) s=${s#"$FM_TASK_ID_RULE_PREFIX"} ;;
  esac
  printf '%s' "$s"
}

fm_task_id_rule_task_id() { # <selector> <state-dir> -> prints the task id, or fails
  local s=$1 state=$2 rest tok cand

  if fm_task_id_rule_rejected "$s"; then
    return 1
  fi
  rest=$FM_TASK_ID_RULE_CANDIDATES
  while [ -n "$rest" ]; do
    tok=${rest%%,*}
    case "$rest" in
    *,*) rest=${rest#*,} ;;
    *) rest="" ;;
    esac
    case "$tok" in
    exact) cand=$s ;;
    stripped)
      cand=$(fm_task_id_rule_strip "$s")
      if [ "$cand" = "$s" ]; then
        continue
      fi
      ;;
    *) return 1 ;;
    esac
    if [ -f "$state/$cand.meta" ]; then
      printf '%s' "$cand"
      return 0
    fi
  done
  return 1
}

fm_task_id_rule_load
