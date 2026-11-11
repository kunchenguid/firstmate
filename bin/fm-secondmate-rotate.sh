#!/usr/bin/env bash
# fm-secondmate-rotate.sh - second-mate SESSION ROTATION: restart an idle
# second mate onto a fresh conversation once its session has grown past a
# configured context size, through the guarded persist-then-restart path.
#
# Usage: fm-secondmate-rotate.sh scan
#        fm-secondmate-rotate.sh tokens <secondmate-id>
#
# WHY. A second mate is a persistent agent, so nothing ends its conversation:
# it grows until the harness's own compaction fires, which on a 1M-token model
# is close to 1M tokens. Every step pays for the whole context, so a bloated
# mate answers its wakes several times slower than a fresh one while its lanes
# sit empty. Rotation spends the conversation only after the mate has written
# down its open work, which is exactly bin/fm-secondmate-restart.sh's persist
# gate.
#
# THE GATE (config/secondmate-rotation). Absent means off. A present file
# enables rotation; its optional lines are
#   threshold-tokens=<n>   context size at or above which a mate is due (250000)
#   window-seconds=<n>     minimum time between two rotations of one mate (21600)
# Blank lines and lines starting with # are ignored; an unusable value keeps
# its default. docs/configuration.md "Second-mate session rotation" owns the
# operator-facing description.
#
# `scan` (run by bin/fm-watch.sh on its check sweep when the gate exists)
# considers every local `kind=secondmate` record in this home. A mate is due
# when ALL of these hold:
#   - its context size is measured (see `tokens`) at or above the threshold;
#   - its busy verdict is `idle` (bin/fm-busy-lib.sh), so no turn is cut short
#     and the persist request is answered promptly;
#   - its last rotation, recorded in state/<id>.rotation, is at least
#     window-seconds old, so a mate is rotated at most once per window whatever
#     the outcome.
# For a due mate it records state/<id>.rotation first, then starts
# `bin/fm-secondmate-restart.sh --rotate <id>` detached in its own session
# (the watcher stops a check's whole process group when the check returns), with
# its report in state/<id>.rotation.log, and prints one line naming the mate,
# its measured size, and that log. The watcher turns that output into one
# `check: secondmate-rotation` wake. A remotely placed mate is skipped: its
# session lives on another host. Nothing here stops, clears, or discards
# anything itself; fm-secondmate-restart.sh and bin/fm-control.sh own the
# transaction and its refusals.
#
# `tokens` prints the mate's current context size in tokens, or `unmeasured`.
# The size is the last request's prompt plus output usage recorded in the mate's
# own session transcript:
#   - pi, pi-signed: the session file the mate's Herdr pane is bound to when
#     that reference is a readable path, otherwise the newest *.jsonl under
#     ${PI_CODING_AGENT_DIR:-~/.pi/agent}/sessions/--<home path>--, read for the
#     last assistant message's usage.totalTokens;
#   - claude: the newest *.jsonl under ${CLAUDE_CONFIG_DIR:-~/.claude}/projects/
#     <home path with every non-alphanumeric character as ->, read through
#     bin/fm-warm-compact-lib.sh's input + cache_read + cache_creation usage.
# Every other harness, and a transcript that cannot be found or read, is
# `unmeasured` and is never rotated.
#
# Test seam: FM_SECONDMATE_ROTATE_RESTART names the command started in place of
# bin/fm-secondmate-restart.sh; it receives the same `--rotate <id>` arguments.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  scan|tokens) ;;
  *) usage >&2; exit 2 ;;
esac

if [ -z "${FM_HOME:-}" ] || [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME is not set to a firstmate home; fm-secondmate-rotate refuses to guess one" >&2
  exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing" >&2; exit 1; }

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-warm-compact-lib.sh
. "$SCRIPT_DIR/fm-warm-compact-lib.sh"

ROTATE_THRESHOLD=250000
ROTATE_WINDOW=21600

# rotation_config: succeed and set ROTATE_THRESHOLD and ROTATE_WINDOW when the
# home opted in; fail when it did not.
rotation_config() {
  local file=$CONFIG/secondmate-rotation line key value
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}
    value=${line#*=}
    case "$value" in '' | 0* | *[!0-9]*) continue ;; esac
    case "$key" in
      threshold-tokens) ROTATE_THRESHOLD=$value ;;
      window-seconds) ROTATE_WINDOW=$value ;;
    esac
  done < "$file"
  return 0
}

newest_jsonl() {  # <dir>
  local dir=$1 f newest='' newest_m=0 m
  [ -d "$dir" ] || return 1
  for f in "$dir"/*.jsonl; do
    [ -f "$f" ] || continue
    m=$(fm_file_mtime "$f" 2>/dev/null || echo 0)
    if [ -z "$newest" ] || [ "$m" -gt "$newest_m" ]; then
      newest=$f
      newest_m=$m
    fi
  done
  [ -n "$newest" ] || return 1
  printf '%s' "$newest"
}

fm_file_mtime() {  # <path>
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# pi_bound_session: the session path the mate's Herdr pane is bound to.
pi_bound_session() {  # <meta>
  local meta=$1 target identity ref
  [ "$(fm_backend_of_meta "$meta")" = herdr ] || return 1
  target=$(fm_backend_target_of_meta "$meta")
  fm_backend_source herdr >/dev/null 2>&1 || return 1
  fm_backend_herdr_parse_target "$target" || return 1
  identity=$(fm_backend_herdr_pane_agent_session_ref "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" 2>/dev/null) || return 1
  [ "${identity%%$'\t'*}" = pi ] || return 1
  ref=${identity#*$'\t'}
  case "$ref" in /*) ;; *) return 1 ;; esac
  [ -r "$ref" ] || return 1
  printf '%s' "$ref"
}

pi_context_tokens() {  # <transcript>
  [ -r "$1" ] || return 1
  tail -n 400 "$1" 2>/dev/null | jq -R -r '
      fromjson? | select(.type == "message" and .message.role? == "assistant")
      | .message.usage // empty | select(type == "object")
      | (.totalTokens // ((.input // 0) + (.output // 0) + (.cacheRead // 0) + (.cacheWrite // 0)))
      | select(type == "number" and . > 0)
    ' 2>/dev/null | tail -n 1
}

# mate_context_tokens <id>: print the measured size, or fail.
mate_context_tokens() {  # <id>
  local id=$1 meta harness home transcript='' dir tokens
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || return 1
  harness=$(fm_meta_get "$meta" harness)
  home=$(fm_meta_get "$meta" home)
  [ -n "$home" ] || home=$(fm_meta_get "$meta" worktree)
  case "$home" in /*) ;; *) return 1 ;; esac
  case "$harness" in
    pi|pi-signed)
      transcript=$(pi_bound_session "$meta") || transcript=
      if [ -z "$transcript" ]; then
        dir="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/sessions/--$(printf '%s' "${home#/}" | tr '/\\:' '---')--"
        transcript=$(newest_jsonl "$dir") || return 1
      fi
      tokens=$(pi_context_tokens "$transcript")
      ;;
    claude)
      dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$home" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
      transcript=$(newest_jsonl "$dir") || return 1
      tokens=$(fm_warm_compact_context_tokens "$transcript")
      ;;
    *) return 1 ;;
  esac
  case "$tokens" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$tokens"
}

if [ "$1" = tokens ]; then
  id=${2:-}
  case "$id" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid second mate id: $id" >&2; exit 2 ;; esac
  [ "$(fm_meta_get "$STATE/$id.meta" kind 2>/dev/null)" = secondmate ] \
    || { echo "error: $id is not a second mate recorded in this home" >&2; exit 1; }
  mate_context_tokens "$id" || printf 'unmeasured'
  printf '\n'
  exit 0
fi

rotation_config || exit 0

last_rotation() {  # <id>
  local v
  v=$(sed -n 's/^epoch=//p' "$STATE/$1.rotation" 2>/dev/null | tail -n 1)
  case "$v" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$v" ;; esac
}

launch_rotation() {  # <id>
  local id=$1 cmd=${FM_SECONDMATE_ROTATE_RESTART:-$SCRIPT_DIR/fm-secondmate-restart.sh}
  # The watcher stops this check's whole process group as soon as the scan
  # returns, and the persist gate alone can take minutes, so the restart runs in
  # its own session. The parent returns only after the child's setsid, so the
  # group stop can never land between the fork and the new session.
  # shellcheck disable=SC2016  # Perl, not the shell, expands its variables.
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" nohup perl -e '
    use POSIX qw(setsid);
    pipe(my $r, my $w) or exit 1;
    my $pid = fork;
    exit 1 unless defined $pid;
    if (!$pid) { close $r; setsid(); close $w; exec @ARGV or POSIX::_exit(127) }
    close $w; my $ready = <$r>; exit 0' \
    "$cmd" --rotate "$id" > "$STATE/$id.rotation.log" 2>&1 < /dev/null
}

now=$(date +%s)
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  [ "$(fm_meta_get "$meta" kind)" = secondmate ] || continue
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || continue
  tokens=$(mate_context_tokens "$id") || continue
  [ "$tokens" -ge "$ROTATE_THRESHOLD" ] || continue
  [ $((now - $(last_rotation "$id"))) -ge "$ROTATE_WINDOW" ] || continue
  case "$(fm_busy_classify_meta "$meta" "$id" "$STATE")" in
    idle*) ;;
    *) continue ;;
  esac
  printf 'epoch=%s\ntokens=%s\nthreshold=%s\n' "$now" "$tokens" "$ROTATE_THRESHOLD" \
    > "$STATE/$id.rotation" || continue
  launch_rotation "$id"
  printf 'rotating %s: context %s tokens >= %s; persist-then-restart onto a fresh session started (report: state/%s.rotation.log)\n' \
    "$id" "$tokens" "$ROTATE_THRESHOLD" "$id"
done
exit 0
