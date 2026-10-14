#!/usr/bin/env bash
# fm-admin-guard.sh - Worker-side deterministic guard against permission-bypass merges.
#
# Hard Rule 2: "Never merge a PR without the captain's explicit word."
# Imperative shorthand in a firstmate steer (such as "land it", "merge it",
# "get it in", or "ship to main") crosses the supervisor/captain boundary and
# never confers merge authority.
#
# When a worker hits a merge refusal or permission error, it must NOT fall back
# to `gh pr merge --admin` or any other permission-bypass merge. This guard
# refuses any `gh pr merge` invocation using `--admin` unless the task brief's
# `## Captain's intent` carries an `admin-merge: authorized` line.
#
# Supported entry forms:
#   <PreToolUse JSON on stdin> | bin/fm-admin-guard.sh [--claude|--cursor]
#   bin/fm-admin-guard.sh --command '<cmd>' [--claude|--cursor]
#   bin/fm-admin-guard.sh [gh] pr merge ... (wrapper/shim mode)
#
# Exit/output contract:
#   ALLOW - exit 0 (executes real gh in wrapper mode).
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   DENY, --cursor - exit 0 and Cursor's own decision object on stdout.
set -u

CMD=""
CMD_SET=0
CLAUDE_MODE=0
CURSOR_MODE=0
IS_GH_WRAPPER=0

case "${0##*/}" in
  gh) IS_GH_WRAPPER=1 ;;
esac

case "${1:-}" in
  gh)
    IS_GH_WRAPPER=1
    shift
    ;;
esac

find_real_gh() {
  local self_path real_path
  self_path="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")"
  local IFS=:
  for d in $PATH; do
    [ -n "$d" ] || d="."
    if [ -x "$d/gh" ]; then
      real_path="$(cd "$d" 2>/dev/null && pwd)/gh"
      if [ "$real_path" != "$self_path" ] && [ "$real_path" != "$0" ]; then
        printf '%s\n' "$real_path"
        return 0
      fi
    fi
  done
  for fb in /usr/bin/gh /usr/local/bin/gh /opt/homebrew/bin/gh; do
    if [ -x "$fb" ] && [ "$fb" != "$self_path" ]; then
      printf '%s\n' "$fb"
      return 0
    fi
  done
  return 1
}

SELF=$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null)
FM_ROOT=$(CDPATH='' cd -- "${SELF%/*}/.." 2>/dev/null && pwd -P)
FM_HOME=${FM_HOME:-$FM_ROOT}

# shellcheck source=bin/fm-brief-heading-lib.sh
. "$FM_ROOT/bin/fm-brief-heading-lib.sh" 2>/dev/null

is_captain_authorized() {
  local brief=${FM_ADMIN_GUARD_BRIEF:-}
  if [ -z "$brief" ]; then
    [ -n "${FM_TASK_ID:-}" ] || return 1
    brief="$FM_HOME/data/$FM_TASK_ID/brief.md"
  fi
  fm_brief_task_heading_body "$brief" "## Captain's intent" 2>/dev/null \
    | grep -iqE -- '^[[:space:]]*admin-merge:[[:space:]]*authori[sz]ed[[:space:]]*$'
}

args_are_admin_merge() {
  [ "${1:-}" = pr ] && [ "${2:-}" = merge ] || return 1
  shift 2
  local arg
  for arg in "$@"; do
    case "$arg" in
      --admin|--admin=*) return 0 ;;
    esac
  done
  return 1
}

deny_refusal() {
  local reason="error: [hard-rule-2] worker cannot use --admin or bypass permissions; only captain explicit authorization confers merge authority."
  if [ "$IS_GH_WRAPPER" -eq 1 ]; then
    printf '%s\n' "$reason" >&2
    exit 2
  fi
  local escaped
  escaped=$(printf '%s' "$reason" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
  if [ "$CURSOR_MODE" -eq 1 ]; then
    printf '{"permission":"deny","user_message":"%s"}\n' "$escaped"
    exit 0
  fi
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  [ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$escaped"
  exit 2
}

if [ "$IS_GH_WRAPPER" -eq 1 ]; then
  if args_are_admin_merge "$@"; then
    is_captain_authorized || deny_refusal
  fi
  real_gh=$(find_real_gh) || {
    echo "error: gh executable not found on PATH" >&2
    exit 127
  }
  exec "$real_gh" "$@"
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    --cursor)
      CURSOR_MODE=1
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: fm-admin-guard.sh [--command <cmd>] [--claude|--cursor]
       fm-admin-guard.sh gh <gh-args...>

Refuses `gh pr merge --admin` unless the task brief's `## Captain's intent` has an `admin-merge: authorized` line.
Exits 0 to allow, 2 to deny (exit 0 with decision object for --cursor).
EOF
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
fi

[ -n "$CMD" ] || exit 0

case "$CMD" in
  *--admin*) ;;
  *) exit 0 ;;
esac

split_command_segments() {
  local s=$1 out="" q="" c i j line delim=""
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    if [ -n "$q" ]; then
      if [ "$q" = '"' ] && [ "$c" = "\\" ]; then
        out+=${s:i:2}
        i=$((i + 1))
        continue
      fi
      [ "$c" = "$q" ] && q=""
      [ "$c" = $'\n' ] && c=' '
      out+=$c
      continue
    fi
    case "$c" in
      "\\")
        out+=${s:i:2}
        i=$((i + 1))
        ;;
      "'"|'"') q=$c; out+=$c ;;
      '<')
        if { [ "$i" -eq 0 ] || [ "${s:i-1:1}" != '<' ]; } \
          && ! [[ $out =~ \(\([^\)]*$ ]] \
          && [[ ${s:i} =~ ^[\<][\<]-?[[:space:]]*[\"\']?([^\"\'[:space:]\;\&\|\<\>\(\)]+) ]]; then
          delim=${BASH_REMATCH[1]}
        fi
        out+=$c
        ;;
      $'\n')
        printf '%s\n' "$out"
        out=""
        if [ -n "$delim" ]; then
          j=$((i + 1))
          while [ "$j" -lt "${#s}" ]; do
            line=${s:j}
            line=${line%%$'\n'*}
            j=$((j + ${#line} + 1))
            line=${line#"${line%%[!$'\t']*}"}
            [ "$line" = "$delim" ] && break
          done
          i=$((j - 1))
          delim=""
        fi
        ;;
      ';'|'&'|'|') printf '%s\n' "$out"; out="" ;;
      *) out+=$c ;;
    esac
  done
  printf '%s\n' "$out"
}

is_admin_merge_command() {
  local cmd="$1" line inner
  local words=()
  while IFS= read -r line; do
    line=$(printf '%s' "$line" | sed -E -e 's/^[[:space:]]*//' -e 's/^([({`]|\$\()+[[:space:]]*//' -e 's/^(which|command -v|type -P)[[:space:]]+//')
    if [[ $line =~ ^(bash|sh|zsh)[[:space:]]+-[a-z]*c[a-z]*[[:space:]]+[\"\'](.*)[\"\'] ]]; then
      inner=${BASH_REMATCH[2]}
      is_admin_merge_command "$inner" && return 0
      continue
    fi
    read -r -a words <<< "${line//[\"\'\`()\}]/ }"
    while [ "${#words[@]}" -gt 0 ]; do
      case "${words[0]}" in
        *=*|sudo|env|exec|time|nohup|command) words=("${words[@]:1}") ;;
        *) break ;;
      esac
    done
    [ "${#words[@]}" -gt 0 ] || continue
    case "${words[0]##*/}" in
      gh|gh-axi) args_are_admin_merge "${words[@]:1}" && return 0 ;;
    esac
  done < <(split_command_segments "$cmd")
  return 1
}

if is_admin_merge_command "$CMD"; then
  is_captain_authorized || deny_refusal
fi

exit 0
