#!/usr/bin/env bash
# fm-tor-log-lib.sh - the ONE owner of the gate-log line (Tor-Log).
#
# Usage:
#   . bin/fm-tor-log-lib.sh
#   fm_tor_log <tor> <regel-id> <verdikt:gruen|rot|warn> <ausweg|-> <kontext...>
#
# Every gate (Tor) in this fleet writes one line per DECISION - green passages
# included, so the log answers "did the gate even look?" and not only "what did
# it refuse?". Without the green lines a silent gate and an unarmed gate are
# indistinguishable, and an armed gate that never fires reads as proof of a
# well-behaved fleet when it may simply be broken (L03: green without a proven
# red case proves nothing).
#
# File contract (this header is the single owner):
#   $FM_HOME/state/tor-log/<tor>.jsonl
#     append-only, one JSON object per line, newest last:
#       {"ts":"<UTC, date -u +%Y-%m-%dT%H:%M:%SZ>",
#        "tor":"<gate name, the file's own basename>",
#        "regel":"<rule id that decided: an order id, a reservation file, or - >",
#        "verdikt":"gruen|rot|warn",
#        "ausweg":"<the named exit the caller took, or - >",
#        "kontext":"<free text: the call context that was judged>"}
#     No reader ever rewrites or truncates this file; rotation is a separate,
#     not-yet-built concern.
#   $FM_HOME/state/tor-log/<tor>.jsonl.lock
#     flock guard so concurrent gates cannot interleave a partial line.
#
# Guarantees:
#   - NEVER fatal. The log is bookkeeping, never the work itself: any failure
#     (unwritable state dir, missing flock, bad arguments) prints one `warn:`
#     line to stderr and the function still returns 0, so a caller running under
#     `set -e` cannot be killed by its own logging.
#   - Loud on unknown values (L33), but never silent: a verdikt outside
#     gruen|rot|warn and a <tor> outside [a-z0-9-] both print a warn line naming
#     the offending value. The verdikt is then recorded VERBATIM (the log must
#     not launder what actually happened) while the file name uses the
#     sanitized <tor> (every other character becomes '-') because a file name is
#     not free text.
#   - Field values are JSON-escaped; tabs, newlines, and control characters are
#     folded so one decision is always exactly one line.
#
# FM_HOME resolution: $FM_HOME if set, else the repo this file lives in.

fm_tor_log_home() { # -> the home whose state/tor-log/ is written
  if [ -n "${FM_HOME:-}" ]; then
    printf '%s' "$FM_HOME"
  else
    (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  fi
}

fm_tor_log_json_string() { # <text...> -> a JSON string literal
  local s="$*"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  s="$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')"
  printf '"%s"' "$s"
}

fm_tor_log() { # <tor> <regel-id> <verdikt> <ausweg|-> <kontext...>
  if [ "$#" -lt 4 ]; then
    printf 'warn: fm_tor_log needs <tor> <regel-id> <verdikt:gruen|rot|warn> <ausweg|-> [kontext...]; nothing logged\n' >&2
    return 0
  fi
  local tor="$1" regel="$2" verdikt="$3" ausweg="$4"
  shift 4
  local kontext="$*"
  local safe_tor="${tor//[^a-z0-9-]/-}"
  if [ -z "$tor" ] || [ "$safe_tor" != "$tor" ]; then
    printf 'warn: fm_tor_log gate name %s is not [a-z0-9-]; logging under %s\n' \
      "'$tor'" "'${safe_tor:--}'" >&2
    [ -n "$safe_tor" ] || safe_tor="-"
  fi
  case "$verdikt" in
    gruen|rot|warn) ;;
    *) printf 'warn: fm_tor_log verdikt %s is not gruen|rot|warn; recorded verbatim\n' "'$verdikt'" >&2 ;;
  esac
  [ -n "$regel" ] || regel="-"
  [ -n "$ausweg" ] || ausweg="-"

  local dir file line
  dir="$(fm_tor_log_home)/state/tor-log"
  file="$dir/$safe_tor.jsonl"
  line="$(printf '{"ts":%s,"tor":%s,"regel":%s,"verdikt":%s,"ausweg":%s,"kontext":%s}' \
    "$(fm_tor_log_json_string "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" \
    "$(fm_tor_log_json_string "$safe_tor")" \
    "$(fm_tor_log_json_string "$regel")" \
    "$(fm_tor_log_json_string "$verdikt")" \
    "$(fm_tor_log_json_string "$ausweg")" \
    "$(fm_tor_log_json_string "$kontext")")"

  (
    set +e
    mkdir -p "$dir" 2>/dev/null || exit 1
    if command -v flock >/dev/null 2>&1; then
      exec 9>>"$file.lock" || exit 1
      flock 9 || exit 1
    fi
    printf '%s\n' "$line" >> "$file" || exit 1
    exit 0
  ) || printf 'warn: fm_tor_log could not append to %s (decision stands, only the log is missing)\n' "$file" >&2
  return 0
}
