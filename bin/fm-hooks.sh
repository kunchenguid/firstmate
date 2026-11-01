#!/usr/bin/env bash
# fm-hooks.sh - run the lifecycle hooks installed for one event.
#
# Usage: fm-hooks.sh run <event> [args...]    JSON payload on stdin
#        fm-hooks.sh list <event>
#
# Lifecycle scripts call this through fm_hooks_emit (bin/fm-hooks-lib.sh), which
# never starts it when no hook folder exists. bin/fm-hooks-lib.sh owns where
# hook folders live; docs/configuration.md "Lifecycle hooks" owns the event
# list, the payloads, where each event is called from, and which merged keys
# Firstmate reads.
#
# `run` executes every regular executable file in each hook folder, folder by
# folder, in byte-wise lexical order of file name (LC_ALL=C), skipping names
# that start with a dot or end in "~". Each hook gets the payload on stdin, the
# event name in FM_HOOK_EVENT, FM_HOME, and the extra args. With no hook files
# it prints nothing, reads nothing from stdin (unless it mirrors a dialog event,
# below), and exits 0. An empty or
# terminal stdin is the payload {}. The runner keeps no state of its own.
#
# Every hook runs under FM_HOOK_TIMEOUT seconds (a positive integer, default
# 10) through bin/fm-timeout-lib.sh, which stops the hook's whole process
# group at the bound. A hook that exits 124 or 137 is indistinguishable from
# one that hit the bound (fm_timed_out) and is reported as timed out.
#
# Blocking events: pre-spawn, turn-end, pre-merge. The first hook that exits
# non-zero or times out stops the run; its stderr (or "<name> exited <n>", or
# "<name> timed out after <n>s") is printed on stderr as the reason, later
# hooks do not run, and the runner exits 3.
# Every other event is non-blocking: a failure or timeout is reported on stderr
# as one "fm-hooks: <event>: <name> ..." line (and appended with a UTC stamp to
# FM_HOOK_LOG when that names a writable file), the remaining hooks still run,
# and the runner exits 0.
#
# Output:
#   session-start  each hook's stdout is passed through in run order, whatever
#                  its exit status, unless it timed out.
#   pre-spawn,     each hook's stdout is read as a sequence of JSON objects
#   intake         (from pre-spawn hooks that succeeded, from intake hooks that
#                  did not time out) and merged in run and print order, key by
#                  key and recursively. A new key is taken, an equal value is
#                  fine, and any other clash is a conflict where the value set
#                  first, by the earlier hook, is kept; each conflict is
#                  reported like a failure as "conflict on <key.path>: kept
#                  <hook>, ignored <hook>", never naming a value. With
#                  FM_HOOK_MERGE_CONFLICT=refuse a pre-spawn conflict refuses
#                  (exit 3) with those lines as the reason. Output that is not
#                  a sequence of JSON objects is ignored and reported. The
#                  merged object is printed as one line; nothing is printed when
#                  no hook contributed an object. Merging uses jq (FM_HOOKS_JQ
#                  names another binary); without it the first hook's raw output
#                  passes through and any later output is reported as ignored.
#   others         stdout is discarded.
#
# FM_HOOK_MIRROR, when set, names a JSONL file that gets one line per run that
# ran a hook: at, runner, event, payload_sha256, payload_bytes, hooks (hook,
# exit, timed_out, ms), refused, output_sha256. Only digests are written, never
# the payload or the output.
# The dialog events prompt-submit and stop are mirrored on every run, even with
# no hook files (they then read the payload), and their line adds "dialog":
# role (captain for prompt-submit, main for stop), session_id, id (prompt_id or
# generation_id), and text_sha256 and text_chars of the said text (prompt, or
# last_assistant_message, else text), each null when the payload lacks it.
# With FM_HOOK_MIRROR_TEXT=1 it also carries dialog.text, capped at 4000
# characters (the first 2000 and the last 1950 around one
# "[... N characters cut ...]" line). Reading the dialog needs jq; without it
# the dialog carries only its role.
#
# Exit status: 0 done (or nothing installed), 2 usage or unknown event,
# 3 a blocking event was refused, 75 the runner could not create its scratch
# directory (a blocking caller treats any status other than 0 as a refusal).
# Bash 3.2 compatible.
set -u

FM_HOOKS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOOKS_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_HOOKS_SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_HOOKS_ROOT}}"
export FM_HOME
FM_HOOKS_EVENTS=" session-start intake pre-spawn post-spawn watch-tick turn-end pre-merge post-merge teardown heartbeat prompt-submit stop "

# shellcheck source=bin/fm-hooks-lib.sh
. "$FM_HOOKS_SCRIPT_DIR/fm-hooks-lib.sh"

fm_hooks_usage() {
  echo "usage: fm-hooks.sh run|list <event> [args...]" >&2
  exit 2
}

fm_hooks_list() {  # <event>: print hook paths, one per line, in run order
  local dir f
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    (
      LC_ALL=C
      for f in "$dir"/*; do
        case ${f##*/} in .* | *~) continue ;; esac
        [ -f "$f" ] && [ -x "$f" ] && printf '%s\n' "$f"
      done
    )
  done <<EOF_DIRS
$(fm_hooks_dirs "$1")
EOF_DIRS
}

fm_hooks_log() {  # <message>
  printf 'fm-hooks: %s\n' "$1" >&2
  if [ -n "${FM_HOOK_LOG:-}" ]; then
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"$FM_HOOK_LOG" 2>/dev/null || true
  fi
}

fm_hooks_has_text() {  # <file>: 0 when it holds a non-whitespace byte
  [ -s "$1" ] && grep -q '[^[:space:]]' "$1" 2>/dev/null
}

fm_hooks_now_ms() {  # milliseconds since the epoch, or nothing when the shell cannot tell
  [ -n "${EPOCHREALTIME:-}" ] || return 0
  local t=${EPOCHREALTIME//[!0-9]/}
  printf '%s' "$((t / 1000))"
}

fm_hooks_sha() {  # <file>: sha256 hex digest, or nothing when no digest tool exists
  local sum
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(sha256sum <"$1")
  elif command -v shasum >/dev/null 2>&1; then
    sum=$(shasum -a 256 <"$1")
  else
    return 0
  fi
  printf '%s' "${sum%% *}"
}

# The dialog fields of a mirror line: the slurped payload in, the said text
# out with --arg mode text, the dialog object otherwise.
# shellcheck disable=SC2016 # A jq program: $names are jq variables.
FM_HOOKS_DIALOG_JQ='
(if length == 1 and (.[0] | type) == "object" then .[0] else {} end) as $d
| ([$fields[] as $f | $d[$f] | strings] | first) as $t
| def ident($ks): [$ks[] as $k | $d[$k] | select(type == "string" or (type == "number" and . == floor))]
    | first | if . == null then null else tostring end;
  if $mode == "text" then ($t // empty)
  else {role: $role, session_id: ident(["session_id"]), id: ident(["prompt_id", "generation_id"]),
        text_sha256: (if $t == null then null else $sha end),
        text_chars: (if $t == null then null else ($t | length) end)}
    + (if $with then {text: (if $t == null or ($t | length) <= 4000 then $t
                             else $t[0:2000] + "\n[... \(($t | length) - 3950) characters cut ...]\n" + $t[-1950:] end)}
       else {} end)
  end
'

fm_hooks_dialog() {  # <tmp> <event>: print the dialog object of a prompt-submit or stop mirror line
  local tmp=$1 role fields jq=${FM_HOOKS_JQ:-jq} with=false sha=''
  case $2 in
    prompt-submit) role=captain fields='["prompt", "text"]' ;;
    *) role=main fields='["last_assistant_message", "text"]' ;;
  esac
  [ "${FM_HOOK_MIRROR_TEXT:-}" != 1 ] || with=true
  if command -v "$jq" >/dev/null 2>&1 &&
    "$jq" -s -j --arg mode text --arg role "$role" --arg sha '' --argjson with false --argjson fields "$fields" \
      "$FM_HOOKS_DIALOG_JQ" <"$tmp/payload" >"$tmp/dialog.text" 2>/dev/null; then
    sha=$(fm_hooks_sha "$tmp/dialog.text")
    "$jq" -s -c --arg mode line --arg role "$role" --arg sha "$sha" --argjson with "$with" \
      --argjson fields "$fields" "$FM_HOOKS_DIALOG_JQ" <"$tmp/payload" 2>/dev/null && return 0
  fi
  printf '{"role": "%s", "session_id": null, "id": null, "text_sha256": null, "text_chars": null%s}\n' \
    "$role" "$([ "$with" = true ] && printf ', "text": null')"
}

fm_hooks_mirror() {  # <tmp> <event> <refused 0|1>: append one JSONL line to FM_HOOK_MIRROR
  [ -n "${FM_HOOK_MIRROR:-}" ] || return 0
  local tmp=$1 event=$2 refused=false psha osha=null bytes dialog=''
  [ "$3" = 1 ] && refused=true
  case $event in prompt-submit | stop) dialog=", \"dialog\": $(fm_hooks_dialog "$tmp" "$event")" ;; esac
  psha=$(fm_hooks_sha "$tmp/payload")
  psha=${psha:+\"$psha\"}
  psha=${psha:-null}
  bytes=$(wc -c <"$tmp/payload")
  bytes=${bytes//[!0-9]/}
  if [ -s "$tmp/printed" ]; then
    osha=$(fm_hooks_sha "$tmp/printed")
    osha=${osha:+\"$osha\"}
    osha=${osha:-null}
  fi
  mkdir -p "$(dirname "$FM_HOOK_MIRROR")" 2>/dev/null
  printf '{"at": "%s", "runner": "fm-hooks.sh", "event": %s, "payload_sha256": %s, "payload_bytes": %s, "hooks": [%s], "refused": %s, "output_sha256": %s%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" "$(fm_hooks_json_string "$event")" \
    "$psha" "${bytes:-0}" "$FM_HOOKS_MIRROR_HOOKS" "$refused" "$osha" "$dialog" \
    >>"$FM_HOOK_MIRROR" 2>/dev/null || true
}

# The output merge rule: each input is
# {n: hook name, v: that hook's stdout slurped as an array, or null}.
# shellcheck disable=SC2016 # A jq program: $names are jq variables.
FM_HOOKS_MERGE_JQ='
def merge($o; $p; $src):
  reduce ($o | to_entries[]) as $e (.;
    ($p + [$e.key]) as $q
    | if (.acc | getpath($p) | has($e.key)) | not then
        .acc |= setpath($q; $e.value) | .own += [[$q, $src]]
      else (.acc | getpath($q)) as $cur
        | if ($cur | type) == "object" and ($e.value | type) == "object" then merge($e.value; $q; $src)
          elif $cur == $e.value then .
          else .conf += [{key: ($q | join(".")),
                          kept: ([.own[] | select(.[0] as $x | $q[0:($x | length)] == $x) | .[1]] | last),
                          ignored: $src}]
          end
      end);
reduce inputs as $h ({acc: {}, own: [], conf: [], ign: [], seen: false};
  if ($h.v | type) == "array" and all($h.v[]; type == "object") then
    reduce $h.v[] as $o (.; .seen = true | merge($o; []; $h.n))
  else .ign += [$h.n] end)
| (if .seen then "OUT " + (.acc | tojson) else empty end),
  (.conf[] | "CONFLICT conflict on \(.key): kept \(.kept), ignored \(.ignored)"),
  (.ign[] | "IGNORED \(.) printed output that is not a JSON object (ignored)")
'

fm_hooks_merge() {  # <tmp> <event> <blocking>: merge the outputs listed in $tmp/merge.list
  # Prints the merged object; returns 3 (reason on stderr) when a pre-spawn conflict must refuse.
  local tmp=$1 event=$2 blocking=$3 jq=${FM_HOOKS_JQ:-jq} idx name file line refuse=0 reasons='' first=''
  [ -s "$tmp/merge.list" ] || return 0
  if ! command -v "$jq" >/dev/null 2>&1; then
    while read -r idx name; do
      file="$tmp/m.$idx"
      fm_hooks_has_text "$file" || continue
      if [ -z "$first" ]; then
        first=$name
        tee -a "$tmp/printed" <"$file"
      else
        fm_hooks_log "$event: jq not found, kept the output of $first, ignored $name"
      fi
    done <"$tmp/merge.list"
    return 0
  fi
  : >"$tmp/merge.in"
  # shellcheck disable=SC2016 # jq programs: $n is a jq variable.
  while read -r idx name; do
    "$jq" -c -s --arg n "$name" '{n: $n, v: .}' "$tmp/m.$idx" >>"$tmp/merge.in" 2>/dev/null ||
      "$jq" -n -c --arg n "$name" '{n: $n, v: null}' >>"$tmp/merge.in"
  done <"$tmp/merge.list"
  "$jq" -n -r "$FM_HOOKS_MERGE_JQ" <"$tmp/merge.in" >"$tmp/merge.out" || return 0
  case ${FM_HOOK_MERGE_CONFLICT:-first} in refuse) [ "$blocking" = 1 ] && refuse=1 ;; esac
  while IFS= read -r line; do
    case $line in
      "CONFLICT "*)
        if [ "$refuse" = 1 ]; then
          reasons="${reasons:+$reasons; }$event: ${line#CONFLICT }"
        else
          fm_hooks_log "$event: ${line#CONFLICT }"
        fi
        ;;
      "IGNORED "*) fm_hooks_log "$event: ${line#IGNORED }" ;;
    esac
  done <"$tmp/merge.out"
  if [ -n "$reasons" ]; then
    printf '%s\n' "$reasons" >&2
    return 3
  fi
  while IFS= read -r line; do
    case $line in "OUT "*) printf '%s\n' "${line#OUT }" | tee -a "$tmp/printed" ;; esac
  done <"$tmp/merge.out"
  return 0
}

fm_hooks_run() {  # <event> [args...]
  local event=$1 hooks hook name limit blocking=0 collect=0 merge=0 dialog=0 tmp reason rc mirror_rc
  local timed_out n=0 start ms
  shift
  case $event in pre-spawn | turn-end | pre-merge) blocking=1 ;; esac
  case $event in session-start) collect=1 ;; esac
  case $event in pre-spawn | intake) merge=1 ;; esac
  case $event in prompt-submit | stop) [ -z "${FM_HOOK_MIRROR:-}" ] || dialog=1 ;; esac
  hooks=$(fm_hooks_list "$event")
  [ -n "$hooks" ] || [ "$dialog" = 1 ] || return 0
  limit=${FM_HOOK_TIMEOUT:-10}
  case $limit in '' | *[!0-9]* | 0) limit=10 ;; esac
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$FM_HOOKS_SCRIPT_DIR/fm-timeout-lib.sh"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-hooks.XXXXXX") || return 75
  if [ -t 0 ]; then printf '{}' >"$tmp/payload"; else cat >"$tmp/payload"; fi
  [ -s "$tmp/payload" ] || printf '{}' >"$tmp/payload"
  : >"$tmp/merge.list"
  : >"$tmp/printed"
  FM_HOOKS_MIRROR_HOOKS=
  while IFS= read -r hook; do
    [ -n "$hook" ] || continue
    name=${hook##*/}
    n=$((n + 1))
    rc=0
    start=$(fm_hooks_now_ms)
    fm_run_timed "$limit" env FM_HOOK_EVENT="$event" "$hook" "$@" \
      <"$tmp/payload" >"$tmp/out" 2>"$tmp/err" || rc=$?
    ms=null
    [ -z "$start" ] || ms=$(($(fm_hooks_now_ms) - start))
    timed_out=0
    ! fm_timed_out "$rc" || timed_out=1
    mirror_rc=$rc
    [ "$timed_out" = 0 ] || mirror_rc=null
    FM_HOOKS_MIRROR_HOOKS="${FM_HOOKS_MIRROR_HOOKS:+$FM_HOOKS_MIRROR_HOOKS, }{\"hook\": $(fm_hooks_json_string "$name"), \"exit\": $mirror_rc, \"timed_out\": $([ "$timed_out" = 1 ] && echo true || echo false), \"ms\": $ms}"
    if [ "$collect" = 1 ] && [ "$timed_out" = 0 ]; then
      tee -a "$tmp/printed" <"$tmp/out"
    fi
    if [ "$merge" = 1 ] && [ "$timed_out" = 0 ] && { [ "$blocking" = 0 ] || [ "$rc" = 0 ]; }; then
      cp "$tmp/out" "$tmp/m.$n"
      printf '%s %s\n' "$n" "$name" >>"$tmp/merge.list"
    fi
    if [ "$timed_out" = 0 ] && [ "$rc" = 0 ]; then
      continue
    fi
    if [ "$blocking" = 1 ]; then
      if [ "$timed_out" = 1 ]; then
        reason="$name timed out after ${limit}s"
        ! fm_hooks_has_text "$tmp/err" || reason="$reason: $(cat "$tmp/err")"
      elif fm_hooks_has_text "$tmp/err"; then
        reason=$(cat "$tmp/err")
      else
        reason="$name exited $rc"
      fi
      printf '%s\n' "$reason" >&2
      fm_hooks_mirror "$tmp" "$event" 1
      rm -rf "$tmp"
      return 3
    fi
    if [ "$timed_out" = 1 ]; then
      fm_hooks_log "$event: $name timed out after ${limit}s (ignored)"
    elif fm_hooks_has_text "$tmp/err"; then
      fm_hooks_log "$event: $name exited $rc (ignored): $(head -n 1 "$tmp/err")"
    else
      fm_hooks_log "$event: $name exited $rc (ignored)"
    fi
  done <<EOF_HOOKS
$hooks
EOF_HOOKS
  rc=0
  if [ "$merge" = 1 ]; then
    fm_hooks_merge "$tmp" "$event" "$blocking" || rc=$?
  fi
  fm_hooks_mirror "$tmp" "$event" "$([ "$rc" = 3 ] && echo 1 || echo 0)"
  rm -rf "$tmp"
  return "$rc"
}

case ${1:-} in -h | --help)
  sed -n '2,/^set -u$/p' "$FM_HOOKS_SCRIPT_DIR/fm-hooks.sh" | sed 's/^# \{0,1\}//; $d'
  exit 0
  ;;
esac
[ $# -ge 2 ] || fm_hooks_usage
case $FM_HOOKS_EVENTS in *" $2 "*) ;; *) echo "fm-hooks: unknown event $2" >&2; exit 2 ;; esac
case $1 in
  run) shift; fm_hooks_run "$@"; exit $? ;;
  list) fm_hooks_list "$2" ;;
  *) fm_hooks_usage ;;
esac
