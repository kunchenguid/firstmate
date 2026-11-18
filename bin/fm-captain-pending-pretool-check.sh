#!/usr/bin/env bash
# PreToolUse guard that surfaces a captain-relevant fleet signal written while
# the primary's turn is running, so the primary can end the turn early instead
# of holding the wake behind minutes of inline work.
#
# Why: on the Claude primary the wake watcher runs BETWEEN turns (Stop
# auto-arm), so a status line written mid-turn - a captain board answer, a
# crewmate terminal verb - sits unread until the turn ends. Observed main turns
# run median 56 s, p90 243 s, max 770 s, and 38% of slow status lines landed
# mid-turn, so a pending wake waited on main's turn length. This guard reads the
# watcher's own seen markers (bin/fm-wake-lib.sh) at every Bash tool boundary:
# when a fleet status file grew past its watcher-classified offset with bytes
# that are not this home's owned bookkeeping, and the unread span holds a line
# bin/fm-classify-lib.sh's status_is_captain_relevant already classifies as
# captain-relevant, it prints one advisory additionalContext naming the signal.
# The queued wake itself stays owned by the turn-end wake queue and
# bin/fm-guard.sh's queued-wakes warning; this guard only adds the mid-turn
# surface and never blocks, denies, or deduplicates the wake.
#
# The pending check reuses the wake-scan predicates, so a line that already
# woke this turn stays silent: the watcher advanced its seen marker before the
# turn started, and own-appended bookkeeping (owned-append ledger) is not a
# signal. Each pending span (task plus end offset) is announced once per
# pending episode through state/.captain-pending-announced, rewritten per
# announcement to only still-pending spans, so a long turn is not re-nagged on
# every tool call.
#
# Registered for the Claude primary in .claude/settings.json (Bash matcher,
# GROK marker guard like every tracked entry). fm_primary_root_matches keeps it
# inert in crewmate worktrees; a foreign-host payload guard stands down where
# another harness's own registration already covers the event. The payload is
# Claude-shaped, so pi-code reads it as Claude does.
#
# Usage:  <PreToolUse JSON on stdin> | bin/fm-captain-pending-pretool-check.sh --claude
#         bin/fm-captain-pending-pretool-check.sh --check     (plain-text mode for adapters)
#
# Modes (FM_CAPTAIN_PENDING_GUARD): flag (default) advises, off allows
# everything silently. FAIL OPEN: malformed or empty stdin, a missing jq, a
# non-Bash tool, an unreadable primary, and any scan failure all allow.
set -u

MODE=${FM_CAPTAIN_PENDING_GUARD:-flag}
case "$MODE" in off) exit 0 ;; esac

HOOK_TRANSPORT=claude
case "${1:-}" in
  --claude) HOOK_TRANSPORT=claude ;;
  --check) HOOK_TRANSPORT=check ;;
  '') ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

if [ "$HOOK_TRANSPORT" = claude ]; then
  input=$(cat 2>/dev/null) || input=
  [ -n "$input" ] || exit 0
  # A foreign host whose own registration covers this event delivers the
  # payload; Claude never emits that key (bin/fm-hook-host-lib.sh owns why).
  if printf '%s' "$input" | jq -e 'type == "object" and has("cursor_version")' >/dev/null 2>&1; then
    exit 0
  fi
  tool=$(printf '%s' "$input" | jq -r '.tool_name // .toolName // empty' 2>/dev/null) || exit 0
  [ "$tool" = Bash ] || exit 0
fi

_SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd 2>/dev/null)" || _SCRIPT_DIR="."
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$_SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$_SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_root_matches "$ROOT" || exit 0

STATE="${FM_STATE_OVERRIDE:-${STATE:-${FM_HOME:-$ROOT}/state}}"
# shellcheck source=bin/fm-wake-lib.sh
. "$_SCRIPT_DIR/fm-wake-lib.sh"

announce_marker="$STATE/.captain-pending-announced"
lockdir="$STATE/.captain-pending-announced.lock"

# Sets _CAPTAIN_FAST_OFFSET from the raw bytes of a v1 or v2 seen marker's
# classified field. Returns 1 when the marker is missing, foreign, or not in a
# recognized shape; such files always fall through to the owner-verified slow
# path, never to silence.
_captain_fast_offset() {  # <marker-raw>
  local field=${1##*$'\t'}
  _CAPTAIN_FAST_OFFSET=
  case "$field" in
    *'@'*) field=${field%%@*} ;;
    *) return 1 ;;
  esac
  case "$field" in ''|*[!0-9]*) return 1 ;; esac
  _CAPTAIN_FAST_OFFSET=$field
  return 0
}

# Prints one "name<TAB>size" row per status file whose size is past the offset
# its watcher seen marker records. One stat call total; the marker itself is
# read with the shell builtin and parsed in place, so a steady-state tool call
# pays no per-file forks. Unparsable markers fall through rather than silence.
_captain_pending_candidates() {
  local name size marker raw sizes='' f
  for f in "$STATE"/*.status; do
    [ ! -L "$f" ] || continue
    [ -f "$f" ] || continue
    sizes=$sizes${f#"$STATE"/}$'\n'
  done
  [ -n "$sizes" ] || return 0
  sizes=${sizes%$'\n'}
  # One stat for every file; task ids cannot contain spaces, newlines, or tabs.
  # shellcheck disable=SC2086
  if [ "$_FM_UNAME" = Darwin ]; then
    sizes=$(cd "$STATE" && stat -f '%z %N' $sizes 2>/dev/null) || return 0
  else
    sizes=$(cd "$STATE" && stat -c '%s %n' -- $sizes 2>/dev/null) || return 0
  fi
  [ -n "$sizes" ] || return 0
  while IFS=' ' read -r size name; do
    case "$size" in ''|*[!0-9]*) continue ;; esac
    [ -n "$name" ] || continue
    marker=$(fm_wake_signal_seen_path "$STATE" "$STATE/$name")
    raw=''
    [ -f "$marker" ] && [ ! -L "$marker" ] && IFS= read -r raw < "$marker" 2>/dev/null
    if _captain_fast_offset "$raw"; then
      [ "$_CAPTAIN_FAST_OFFSET" -lt "$size" ] || continue
    fi
    printf '%s\t%s\n' "$name" "$size"
  done < <(printf '%s\n' "$sizes")
}

# Slow path, owner-verified: would the wake scan call this file a signal, and
# does the span the announcement has not yet covered hold a line the classifier
# calls captain-relevant? Called directly (never in a command substitution) so
# it can report through globals: _CAPTAIN_SIG holds "task:size<TAB>snippet"
# when the file's NEW content must be announced, else empty, and
# _CAPTAIN_CLEARED holds the end offset through which this file has now been
# checked (announced or cleared) so the marker holds the covered frontier; an
# empty _CAPTAIN_CLEARED means the file could not be read and its previous
# frontier must stand. Growth on top of an announced span with no new
# captain-relevant line stays silent, so a long turn is not re-nagged for the
# same content, while genuinely new captain content announces again.
_captain_pending_signal() {  # <name> <size> <announced-end-or-empty>
  local name=$1 size=$2 announced=$3 f="$STATE/$1" offset span line snippet='' found=0 start
  _CAPTAIN_SIG=
  _CAPTAIN_CLEARED=
  _fm_wake_require_classify || return 0
  [ -n "${_CAPTAIN_EXCLUDE:-}" ] && [ "$f" = "$_CAPTAIN_EXCLUDE" ] && return 0
  # Already reported, or growth this home itself owns as bookkeeping.
  if fm_wake_signal_seen_current "$STATE" "$f"; then
    _CAPTAIN_CLEARED=$size
    return 0
  fi
  offset=$(fm_wake_signal_seen_size "$STATE" "$f")
  case "$offset" in ''|*[!0-9]*) return 0 ;; esac
  [ "$offset" -lt "$size" ] || { _CAPTAIN_CLEARED=$size; return 0; }
  start=$offset
  case "$announced" in
    ''|*[!0-9]*) ;;
    *) [ "$announced" -gt "$offset" ] && [ "$announced" -le "$size" ] && start=$announced ;;
  esac
  _CAPTAIN_CLEARED=$size
  [ "$start" -lt "$size" ] || return 0
  span=$(_fm_status_read_span "$f" "$start" $((size - start))) || { _CAPTAIN_CLEARED=; return 0; }
  while IFS= read -r line; do
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    if status_is_captain_relevant "$line"; then
      [ -n "$snippet" ] || snippet=$line
      found=1
    fi
  done < <(printf '%s\n' "$span")
  [ "$found" -eq 1 ] || return 0
  _CAPTAIN_SIG=$(printf '%s:%s\t%s' "${name%.status}" "$size" "$snippet")
  return 0
}

# Fills _CAPTAIN_NEW (newline-separated "task:size<TAB>snippet" rows to
# announce now) and _CAPTAIN_KEYS (the covered frontier "task:end" for every
# still-pending candidate). Both stay empty when nothing is pending.
_captain_pending_scan() {
  local candidates='' row name size task announced='' announced_end
  _CAPTAIN_NEW=
  _CAPTAIN_KEYS=
  candidates=$(_captain_pending_candidates) || candidates=
  [ -n "$candidates" ] || return 0
  _fm_wake_require_classify || return 0
  _CAPTAIN_EXCLUDE=$(status_scan_parent_channel_exclude "$STATE")
  [ -f "$announce_marker" ] && [ ! -L "$announce_marker" ] && announced=$(cat "$announce_marker" 2>/dev/null)
  while IFS=$'\t' read -r name size; do
    [ -n "$name" ] || continue
    task=${name%.status}
    announced_end=''
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      case "$row" in
        "$task:"*[!0-9]*) ;;
        "$task:"*) announced_end=${row#"$task":}; break ;;
      esac
    done <<< "$announced"
    _captain_pending_signal "$name" "$size" "$announced_end"
    if [ -n "${_CAPTAIN_SIG:-}" ]; then
      _CAPTAIN_NEW=${_CAPTAIN_NEW:+$_CAPTAIN_NEW$'\n'}$_CAPTAIN_SIG
    fi
    if [ -n "${_CAPTAIN_CLEARED:-}" ]; then
      _CAPTAIN_KEYS=${_CAPTAIN_KEYS:+$_CAPTAIN_KEYS$'\n'}$task:$_CAPTAIN_CLEARED
    fi
  done < <(printf '%s\n' "$candidates")
  return 0
}

_captain_pending_message() {  # <sigs>; echoes the advisory text
  local key task snippet listing='' count=0 more=0
  while IFS=$'\t' read -r key snippet; do
    [ -n "$key" ] || continue
    task=${key%%:*}
    count=$((count + 1))
    if [ "$count" -le 2 ]; then
      [ ${#snippet} -gt 160 ] && snippet="${snippet:0,160}..."
      [ "$count" -eq 1 ] && listing="'$snippet' ($task)" && continue
      listing="$listing; '$snippet' ($task)"
    else
      more=1
    fi
  done < <(printf '%s\n' "$1")
  [ -n "$listing" ] || return 0
  [ "$more" -eq 0 ] || listing="$listing; and more"
  printf '[captain-pending] A captain-relevant fleet signal arrived during this turn and is queued behind it: %s. The queued wake is delivered only when this turn ends. Finish the current step and end this turn promptly instead of starting new work; delegate work that would run over about 60 s inline.' "$listing"
}

# Main.
_captain_pending_scan
[ -n "${_CAPTAIN_NEW:-}" ] || exit 0

msg=$(_captain_pending_message "$_CAPTAIN_NEW")
[ -n "$msg" ] || exit 0

# Record every still-pending span so the next announcement covers only new
# content. On lock contention announce anyway and skip the rewrite; the worst
# case is one duplicate advisory in a concurrent turn.
if fm_lock_try_acquire "$lockdir"; then
  : > "$announce_marker" 2>/dev/null
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    printf '%s\n' "$key" >> "$announce_marker" 2>/dev/null || true
  done < <(printf '%s\n' "${_CAPTAIN_KEYS:-}")
  fm_lock_release "$lockdir"
fi

if [ "$HOOK_TRANSPORT" = check ]; then
  printf '%s\n' "$msg"
else
  jq -cn --arg m "$msg" '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $m}}'
fi
exit 0
