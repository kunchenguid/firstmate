#!/usr/bin/env bash
# fm-notify.sh - the single owner of firstmate's captain-audible producer tags.
#
# Three supervision events earn a distinct desktop notification, so a sound the
# captain hears always carries signal. Everything else - ordinary turn-ends,
# watcher polls, routine progress - stays silent by design.
#
#   pr-merged   a task's pull request landed
#   pr-ready    a task's pull request is open and ready for the captain's review
#   attention   a task finished, failed, needs a decision, or is blocked
#
# Usage:
#   fm-notify.sh [--once <key>] <event-class> <title> [body]
#   fm-notify.sh [--once <key>] --from-status <task-id> <status-line>
#   fm-notify.sh --help
#
# --once <key> makes the tag fire at most once for that key, so two owners of
# the same real-world fact (firstmate merging a PR, then the merge poll
# observing it merged) never double-beep. The durable marker lives in
# state/.notify-once-<key>; markers older than FM_NOTIFY_ONCE_TTL_DAYS (30) are
# pruned on each write, so the set stays bounded without a teardown hook.
#
# --from-status maps one captain-relevant status event onto a class, so the
# status vocabulary has exactly one notification owner:
#   done: with a PR/MR URL (or a "PR ..." note) -> pr-ready
#   done: / failed: / needs-decision: / blocked: -> attention
#   anything else -> silent
#
# Manual smoke - run each to hear its tag:
#   bin/fm-notify.sh pr-merged "firstmate: PR merged"           "smoke test"
#   bin/fm-notify.sh pr-ready  "firstmate: PR ready for review" "smoke test"
#   bin/fm-notify.sh attention "firstmate: decision needed"     "smoke test"
#
# Always exits 0. A notification is a courtesy on top of a supervision path
# that has already recorded the real event durably, so a missing binary, an
# unreadable config, a refused channel, or a timeout must never break, block,
# or fail the caller. Failures print one line to stderr and nothing more; the
# watcher discards that stream.
#
# Scope. The tag fires only from a genuine primary firstmate home whose state
# directory is that home's own state/. A task worktree, a secondmate home, and
# a redirected state directory all no-op, so a crewmate can never reach the
# captain's desktop and only the primary home's supervision paths ever beep.
#
# Config: config/notify (local, gitignored), one `key=value` per non-empty,
# non-comment line, last assignment wins. An absent file means the three
# classes above are ON with their default sounds.
#
#   enabled=off              global kill switch (on|off, default on)
#   channel=<channel>        default channel for every class (default auto)
#   pr-merged=<sound>[,<channel>]   per-class overrides; the bare value `off`
#   pr-ready=<sound>[,<channel>]    disables that one class. A leading comma
#   attention=<sound>[,<channel>]   (`,herdr`) keeps the default sound.
#
# Channels: auto (default), macos, herdr, both, none.
#   auto resolves to macos when osascript is available, else herdr when the
#   herdr CLI is available, else nothing. macOS Notification Center is
#   preferred even inside herdr because named system sounds are what make the
#   three classes audibly distinct; herdr offers only none|done|request. Set
#   `channel=both` for the herdr toast alongside the macOS sound, or
#   `channel=herdr` to keep every tag inside the herdr UI.
#
# Sounds. macOS sounds are named system sounds (Glass, Ping, Sosumi, Basso,
# Hero, Submarine, Funk, Tink, ...); an unrecognized name is refused and the
# class default is used. Herdr sounds are fixed per class because the CLI
# accepts only three values.
#
#   class      macOS default   herdr sound
#   pr-merged  Glass           done
#   pr-ready   Ping            done
#   attention  Sosumi          request
#
# Test seam: FM_NOTIFY_EXEC replaces every real channel. The special value
# `discard` fires nothing; any other value is run as
# `<cmd> <channel> <sound> <title> <body>`. Unset means production.
#
# See docs/configuration.md "Producer-tag notifications (config/notify)" for
# the captain-facing reference, and bin/fm-supervise-daemon.sh for the separate
# away-mode wedge alarm, which owns its own louder, rate-limited channel.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
NOTIFY_CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/notify"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

NOTIFY_ONCE_TTL_DAYS=${FM_NOTIFY_ONCE_TTL_DAYS:-30}
case "$NOTIFY_ONCE_TTL_DAYS" in ''|*[!0-9]*) NOTIFY_ONCE_TTL_DAYS=30 ;; esac
NOTIFY_TIMEOUT_SECS=${FM_NOTIFY_TIMEOUT_SECS:-10}
case "$NOTIFY_TIMEOUT_SECS" in ''|*[!0-9]*|0) NOTIFY_TIMEOUT_SECS=10 ;; esac

notify_log() {
  printf 'fm-notify: %s\n' "$1" >&2
}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

notify_trim() {  # <text>
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

notify_class_valid() {  # <class>
  case "$1" in
    pr-merged|pr-ready|attention) return 0 ;;
    *) return 1 ;;
  esac
}

notify_default_sound() {  # <class>
  case "$1" in
    pr-merged) printf 'Glass' ;;
    pr-ready) printf 'Ping' ;;
    attention) printf 'Sosumi' ;;
  esac
}

# Herdr's CLI accepts only none|done|request, so the class-to-sound map is fixed
# rather than configurable: there is nothing to tune between three values.
notify_herdr_sound() {  # <class>
  case "$1" in
    attention) printf 'request' ;;
    *) printf 'done' ;;
  esac
}

# Print the last value assigned to <key> in config/notify, or nothing when the
# key is unset, the file is absent, or the path is a symlink (a config file is
# captain-owned local material, never an indirection into somewhere else).
notify_config_lookup() {  # <key>
  local key=$1 line k v out=''
  [ -f "$NOTIFY_CONFIG" ] || return 0
  [ -L "$NOTIFY_CONFIG" ] && return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line=$(notify_trim "$line")
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; *=*) ;; *) continue ;; esac
    k=$(notify_trim "${line%%=*}")
    v=$(notify_trim "${line#*=}")
    [ "$k" = "$key" ] || continue
    out=$v
  done < "$NOTIFY_CONFIG"
  printf '%s' "$out"
}

notify_is_off() {  # <value>
  case "$1" in
    off|OFF|Off|false|no|0) return 0 ;;
    *) return 1 ;;
  esac
}

notify_enabled() {
  local v
  v=$(notify_config_lookup enabled)
  [ -n "$v" ] || return 0
  ! notify_is_off "$v"
}

# A macOS sound name is interpolated into the AppleScript source, unlike the
# title and body which travel as argv items. Accept only the shape a real
# system sound has, so a stray config line can never become script text.
notify_sound_valid() {  # <sound>
  case "$1" in
    ''|*[!A-Za-z0-9\ _-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Resolve <class> against the config into NOTIFY_SOUND and NOTIFY_CHANNEL.
# Returns 1 when the class is switched off.
NOTIFY_SOUND=
NOTIFY_CHANNEL=
notify_resolve_class() {  # <class>
  local class=$1 raw sound='' channel=''
  raw=$(notify_config_lookup "$class")
  if [ -n "$raw" ]; then
    notify_is_off "$raw" && return 1
    case "$raw" in
      *,*) sound=$(notify_trim "${raw%%,*}"); channel=$(notify_trim "${raw#*,}") ;;
      *) sound=$raw ;;
    esac
    # `off` in either position silences the class, so a captain who writes
    # `pr-ready=off,herdr` gets silence rather than a sound literally named off.
    { notify_is_off "$sound" || notify_is_off "$channel"; } && return 1
  fi
  if [ -n "$sound" ] && ! notify_sound_valid "$sound"; then
    notify_log "ignoring unusable sound name for $class; using the default"
    sound=
  fi
  [ -n "$sound" ] || sound=$(notify_default_sound "$class")
  [ -n "$channel" ] || channel=$(notify_config_lookup channel)
  [ -n "$channel" ] || channel=auto
  NOTIFY_SOUND=$sound
  NOTIFY_CHANNEL=$channel
  return 0
}

# Map a configured channel directive onto a concrete channel: macos, herdr,
# both, or none. `auto` prefers the macOS Notification Center because its named
# sounds are what make the three classes distinguishable.
notify_channel_resolve() {  # <directive>
  local directive=$1
  case "$directive" in
    auto|default|'')
      if [ "$(uname 2>/dev/null || true)" = Darwin ] && command -v osascript >/dev/null 2>&1; then
        printf 'macos'
      elif command -v herdr >/dev/null 2>&1; then
        printf 'herdr'
      else
        printf 'none'
      fi
      ;;
    macos|osascript) printf 'macos' ;;
    herdr) printf 'herdr' ;;
    both) printf 'both' ;;
    none|off) printf 'none' ;;
    *)
      notify_log "unrecognized channel directive; falling back to auto"
      notify_channel_resolve auto
      ;;
  esac
}

notify_run_bounded() {  # <cmd> <arg>...
  if command -v timeout >/dev/null 2>&1; then
    timeout "$NOTIFY_TIMEOUT_SECS" "$@" >/dev/null 2>&1
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$NOTIFY_TIMEOUT_SECS" "$@" >/dev/null 2>&1
  else
    "$@" >/dev/null 2>&1
  fi
}

# The one execution seam every channel passes through. Returns 2 when no
# override is configured, meaning the caller runs the real channel.
notify_exec_override() {  # <channel> <sound> <title> <body>
  local override=${FM_NOTIFY_EXEC:-}
  case "$override" in
    '') return 2 ;;
    discard) return 0 ;;
    *)
      notify_run_bounded "$override" "$@" && return 0
      notify_log "notifier override failed for channel '$1'"
      return 1
      ;;
  esac
}

notify_via_macos() {  # <sound> <title> <body>
  local sound=$1 title=$2 body=$3 rc
  notify_exec_override macos "$sound" "$title" "$body"
  rc=$?
  [ "$rc" -eq 2 ] || return "$rc"
  command -v osascript >/dev/null 2>&1 || {
    notify_log "osascript is unavailable; no macOS notification posted"
    return 1
  }
  notify_run_bounded osascript -e 'on run argv' \
    -e "display notification (item 2 of argv) with title (item 1 of argv) sound name \"$sound\"" \
    -e 'end run' "$title" "$body" && return 0
  notify_log "macOS notification failed"
  return 1
}

notify_via_herdr() {  # <sound> <title> <body>
  local sound=$1 title=$2 body=$3 rc
  notify_exec_override herdr "$sound" "$title" "$body"
  rc=$?
  [ "$rc" -eq 2 ] || return "$rc"
  command -v herdr >/dev/null 2>&1 || {
    notify_log "herdr is unavailable; no herdr notification posted"
    return 1
  }
  notify_run_bounded herdr notification show "$title" --body "$body" --sound "$sound" && return 0
  notify_log "herdr notification failed"
  return 1
}

notify_once_marker() {  # <key>
  printf '%s/.notify-once-%s' "$STATE" "$(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_')"
}

# 0 when this key has not fired yet, and the marker is claimed for it.
# The claim is written before the channel runs: a tag that is lost to a failing
# channel is far cheaper than one the captain hears twice.
notify_once_claim() {  # <key>
  local marker
  marker=$(notify_once_marker "$1")
  [ -e "$marker" ] && return 1
  find "$STATE" -maxdepth 1 -name '.notify-once-*' -type f \
    -mtime "+$NOTIFY_ONCE_TTL_DAYS" -delete 2>/dev/null || true
  : > "$marker" 2>/dev/null || return 0
  return 0
}

# The notifier acts only inside a genuine primary firstmate home. A secondmate
# home reports to firstmate rather than to the captain's desktop, a task
# worktree is a crewmate context, and a redirected state directory is not this
# home's own record.
notify_scope_ok() {
  fm_root_is_secondmate_home "$FM_HOME" && return 1
  [ "$STATE" = "$FM_HOME/state" ] || return 1
  fm_primary_scope_matches "$FM_HOME" "$STATE"
}

notify_emit() {  # <class> <title> <body>
  local class=$1 title=$2 body=$3 channel
  notify_class_valid "$class" || {
    notify_log "unknown event class '$class'"
    return 0
  }
  notify_enabled || return 0
  notify_resolve_class "$class" || return 0
  channel=$(notify_channel_resolve "$NOTIFY_CHANNEL")
  case "$channel" in
    macos) notify_via_macos "$NOTIFY_SOUND" "$title" "$body" || true ;;
    herdr) notify_via_herdr "$(notify_herdr_sound "$class")" "$title" "$body" || true ;;
    both)
      notify_via_macos "$NOTIFY_SOUND" "$title" "$body" || true
      notify_via_herdr "$(notify_herdr_sound "$class")" "$title" "$body" || true
      ;;
    none) notify_log "no notification channel available on this machine" ;;
  esac
  return 0
}

# 0 when a status note names a pull or merge request. Both a forge URL and the
# legacy bare "PR ..." note count, because a ship task reports its PR either way.
notify_note_is_pr() {  # <note>
  case "$1" in
    *://*/pull/*|*://*/pulls/*|*://*/pull-requests/*|*://*/merge_requests/*) return 0 ;;
    PR\ *|pr\ *) return 0 ;;
    *) return 1 ;;
  esac
}

notify_from_status() {  # <task-id> <status-line>
  local task=$1 line=$2 verb note class title
  verb=$(status_line_verb "$line")
  note=$(status_line_note "$line")
  case "$verb" in
    done)
      if notify_note_is_pr "$note"; then
        class=pr-ready
        title='firstmate: PR ready for review'
      else
        class=attention
        title='firstmate: task finished'
      fi
      ;;
    failed) class=attention; title='firstmate: task failed' ;;
    needs-decision) class=attention; title='firstmate: decision needed' ;;
    blocked) class=attention; title='firstmate: blocked' ;;
    *) return 0 ;;
  esac
  notify_emit "$class" "$title" "$task: $note"
}

ONCE_KEY=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --once)
      [ "$#" -ge 2 ] || { notify_log "--once needs a key"; exit 0; }
      ONCE_KEY=$2
      shift 2
      ;;
    *) break ;;
  esac
done

if [ "$#" -lt 2 ]; then
  usage >&2
  exit 0
fi

# Scope is checked before anything is claimed or posted, so a crewmate context
# leaves no marker behind either.
notify_scope_ok || {
  notify_log "not a primary firstmate home; no notification posted"
  exit 0
}

if [ "$1" = --from-status ]; then
  if [ "$#" -lt 3 ]; then
    notify_log "--from-status needs a task id and a status line"
    exit 0
  fi
  [ -z "$ONCE_KEY" ] || notify_once_claim "$ONCE_KEY" || exit 0
  notify_from_status "$2" "$3"
  exit 0
fi

[ -z "$ONCE_KEY" ] || notify_once_claim "$ONCE_KEY" || exit 0
notify_emit "$1" "$2" "${3:-}"
exit 0
