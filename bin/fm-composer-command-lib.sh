#!/usr/bin/env bash
# fm-composer-command-lib.sh - the ONE owner of composer command-invocation
# delivery: recognizing a captain note as an allowlisted slash command,
# resolving THIS home's own primary session with certainty, and typing the
# exact command into it through the existing tmux delivery primitives
# (bin/fm-tmux-lib.sh) rather than only queueing it as ordinary note text.
#
# Why keystrokes at all: a slash command such as `/compact` is intercepted
# locally by the CLI's own input loop, not sent to the model as text. The
# existing captain-note path (bin/fm-inbox.sh) delivers a note's BODY into
# firstmate's own context as conversation text, which never reaches that local
# interceptor - so a note that reads "/compact" is filed and read, never
# executed. The only way to make it execute is to type it into the same pty a
# human would, exactly the way bin/fm-tmux-lib.sh's submit primitives already
# do for the away-mode daemon and bin/fm-send.sh.
#
# Default-off: the whole feature is gated on the presence of the local,
# gitignored config/composer-commands file (fm_composer_command_enabled). An
# absent file means every note keeps behaving exactly as it does today -
# queued as text, never typed anywhere.
#
# Recognition rule (fm_composer_command_match): a note body is a command
# invocation ONLY when, after trimming leading/trailing whitespace, it is
# BYTE-IDENTICAL to one entry in FM_COMPOSER_COMMAND_ALLOWLIST. No prefix
# match, no argument parsing, no case-folding: one extra character, a leading
# word, or trailing prose makes it an ordinary note. This is deliberately the
# narrowest rule that still recognizes the captain's literal example, because
# a permissive rule here turns the composer into a remote shell.
#
# Allowlist (FM_COMPOSER_COMMAND_ALLOWLIST): see its own comment below for the
# one entry and why nothing else is on it.
#
# Session resolution: firstmate's own pane can only be identified with
# certainty from WITHIN firstmate's own live turn, where $TMUX_PANE is
# genuinely inherited (bin/fm-supervisor-target-lib.sh's discover_supervisor_*,
# the same primitives the away-mode daemon uses to find the captain's pane).
# A note's delivery, though, is triggered by bin/fm-inbox.sh running as a
# SEPARATE process with no such inheritance - the UI's backend invokes it, not
# firstmate's own shell. So resolution happens in two steps, split the same way
# bin/fm-trace-context-lib.sh splits capture from use:
#   fm_composer_command_session_start   captures discover_supervisor_target/
#                                        backend ONCE, from within firstmate's
#                                        own live session-start turn, and binds
#                                        the record to that session's lock pid
#                                        so a later restart into a different
#                                        pane cannot resolve a stale target.
#   fm_composer_command_session_effective  reads that durable record back, but
#                                        ONLY when its bound lock still matches
#                                        the CURRENT session lock. Any other
#                                        process (bin/fm-inbox.sh, a test) gets
#                                        a certain answer or none at all - it
#                                        never scans for panes by name and
#                                        never guesses.
#
# Busy handling (fm_composer_command_deliver): reuses fm-tmux-lib.sh's
# DELIVERY busy read (fm_pane_is_busy, fm_tmux_composer_state) verbatim - the
# same primitives bin/fm-supervise-daemon.sh's inject_msg already uses to
# decide whether it is safe to type into a live pane. This is deliberately NOT
# the semantic per-task busy-state contract in bin/fm-busy-lib.sh: firstmate's
# own primary session has no armed busy-state record the way a spawned
# crewmate task does, and the delivery guard's job is narrower anyway (is
# ANYONE mid-turn or mid-type right now), which is exactly what the rendered
# tail and composer classifier already answer.
#
# Decision: refuse-and-report when busy, never silently retry. Firstmate
# cannot safely poll for the pane going idle without either creating a second
# supervision cycle (forbidden - AGENTS.md section 8) or hooking the
# safety-critical turn-end/auto-arm chain (out of scope for this change, and
# too risky to alter without its own dedicated review). A busy pane therefore
# leaves the command UNMARKED as delivered and returns a distinct, reported
# exit code; the ordinary note this was queued alongside stays in the inbox
# exactly as it does today, so the captain and firstmate both see plainly that
# it was not auto-executed and can resend once idle. Nothing is ever silently
# dropped: every call prints exactly one line naming what happened and why.
#
# Idempotency (no double delivery, including across a restart): delivery is
# keyed by the caller-supplied <key> (bin/fm-inbox.sh passes the note's own
# durable id). A confirmed submit writes a durable, empty marker file under
# state/.composer-command-delivered/<key> BEFORE returning success; every call
# checks that marker FIRST and treats its presence as already-done, no-op
# success. The marker is written only after fm_tmux_submit_core reports the
# proof-carrying "empty" verdict (the composer actually cleared), never
# before, so a crash before that point leaves nothing marked and a safe retry
# is still possible. The write is then VERIFIED (the file's existence is
# checked, not either command's exit code) rather than assumed: a live
# failure at that point - a read-only or full state directory - is reported
# as a distinct, loud outcome (rc 10) rather than swallowed into an ordinary
# success, because the command has already run and cannot be undone, and
# silently claiming success would leave a later same-key call free to resubmit
# it. The one window this cannot close is a hard process kill between the
# confirmed submit and the marker write actually landing on disk - no
# in-process check can run after the process is gone. That window is a few
# milliseconds of one local file write, and /compact is idempotent to invoke
# twice, so it remains an accepted, documented tradeoff rather than a real
# hazard. A short-lived per-key mkdir claim
# (state/.composer-command-inflight/<key>) additionally rejects a second
# CONCURRENT attempt at the same key rather than racing it.
#
# Sourcing: set -u safe. Depends on bin/fm-supervisor-target-lib.sh (session
# discovery) and bin/fm-tmux-lib.sh (busy/composer read and submit) being
# sourced by the caller, or sources them itself when FM_COMPOSER_COMMAND_LIB_DIR
# points at this file's directory.

FM_COMPOSER_COMMAND_LIB_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$FM_COMPOSER_COMMAND_LIB_DIR/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_COMPOSER_COMMAND_LIB_DIR/fm-tmux-lib.sh"

# The allowlist. One entry today: /compact is a local, reversible
# conversation-management command with no filesystem, network, merge, or
# external-state side effect - it only affects this session's own context -
# which is why it is the captain's own named example and the only entry that
# clears the "never destructive, irreversible, or security-sensitive" bar.
# Add a new entry only with the same justification recorded here; this array
# is the single place that decides what this feature is ever allowed to type.
FM_COMPOSER_COMMAND_ALLOWLIST=(
  "/compact"
)

# Only tmux is verified for this feature (the CLI records a typed command as
# plain pty input on tmux, matching the evidence this feature was built on).
# A recorded herdr or other backend target is refused explicitly rather than
# assumed to behave the same way.
FM_COMPOSER_COMMAND_SUPPORTED_BACKENDS="tmux"

# fm_composer_command_trim: echo <text> with leading/trailing ASCII whitespace
# (space, tab, newline, carriage return) removed. Internal whitespace and
# every other byte is preserved verbatim.
fm_composer_command_trim() {  # <text>
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# fm_composer_command_match: print the exact allowlisted command matched, and
# succeed, ONLY when <text> - trimmed - is byte-identical to one allowlist
# entry. Fails silently (no output) for anything else: extra words, arguments,
# multiple lines, wrong case, or no match at all.
fm_composer_command_match() {  # <text>
  local text trimmed entry
  text=${1-}
  trimmed=$(fm_composer_command_trim "$text")
  [ -n "$trimmed" ] || return 1
  for entry in "${FM_COMPOSER_COMMAND_ALLOWLIST[@]}"; do
    if [ "$trimmed" = "$entry" ]; then
      printf '%s' "$entry"
      return 0
    fi
  done
  return 1
}

# fm_composer_command_enabled: 0 iff the local, gitignored presence flag
# config/composer-commands exists in <config-dir>. Absence is the default and
# means the whole feature is inert.
fm_composer_command_enabled() {  # <config-dir>
  [ -f "${1:-}/composer-commands" ]
}

# fm_composer_command_session_lock: mirrors fm_trace_context_session_lock's
# binding idiom (bin/fm-trace-context-lib.sh) - the lock pid a durable record
# is bound to, so a stale record from a superseded or crashed session is never
# read as current. Kept local to this file rather than shared because the two
# libraries record unrelated contracts; only the small binding idiom repeats.
fm_composer_command_session_lock() {  # <state-dir>
  local state_dir=$1 lock_pid
  { IFS= read -r lock_pid < "$state_dir/.lock"; } 2>/dev/null || return 1
  case "$lock_pid" in
    '' | *[!0-9]*) return 1 ;;
  esac
  [ "$lock_pid" -gt 1 ] || return 1
  printf '%s' "$lock_pid"
}

fm_composer_command_session_record_path() {  # <state-dir>
  printf '%s/.composer-session-target' "$1"
}

# fm_composer_command_session_start: capture THIS home's own primary session
# target/backend ONCE, with certainty, and persist it bound to the current
# session lock. Call this only from within firstmate's own live turn (session
# start), where $TMUX_PANE (or the herdr equivalent) is genuinely inherited -
# see discover_supervisor_target's own precedence (bin/fm-supervisor-target-lib.sh).
# A record is written ONLY when both the feature is enabled and the pane
# resolved with confidence (discover_supervisor_target/backend returning 0,
# never the bare legacy-default guess); every other case removes any existing
# record rather than leaving a stale or uncertain one behind. Always returns 0
# so a session-start caller never fails on this step.
fm_composer_command_session_start() {  # <config-dir> <state-dir>
  local config_dir=$1 state_dir=$2 record lock_pid tmp
  local target='' target_rc backend='' backend_rc
  record=$(fm_composer_command_session_record_path "$state_dir")
  lock_pid=$(fm_composer_command_session_lock "$state_dir") || {
    rm -f "$record" 2>/dev/null || true
    return 0
  }
  if ! fm_composer_command_enabled "$config_dir"; then
    rm -f "$record" 2>/dev/null || true
    return 0
  fi
  target=$(discover_supervisor_target); target_rc=$?
  backend=$(discover_supervisor_backend); backend_rc=$?
  if [ "$target_rc" -ne 0 ] || [ "$backend_rc" -ne 0 ] || [ -z "$target" ] || [ -z "$backend" ]; then
    rm -f "$record" 2>/dev/null || true
    return 0
  fi
  tmp=$(mktemp "$record.tmp.XXXXXX" 2>/dev/null) || {
    rm -f "$record" 2>/dev/null || true
    return 0
  }
  if ! printf '%s %s %s\n' "$lock_pid" "$backend" "$target" > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$record" 2>/dev/null; then
    rm -f "$tmp" "$record" 2>/dev/null || true
  fi
  return 0
}

# fm_composer_command_session_effective: print "<backend> <target>" ONLY when
# a durable record exists AND its bound lock pid equals the CURRENT session
# lock. Fails (no output) on every other case - absent record, foreign or
# stale lock, or a malformed line - so a caller never acts on a guess.
fm_composer_command_session_effective() {  # <state-dir>
  local state_dir=$1 record current_lock
  local recorded_lock='' backend='' target='' extra=''
  record=$(fm_composer_command_session_record_path "$state_dir")
  current_lock=$(fm_composer_command_session_lock "$state_dir") || return 1
  if [ -f "$record" ] && [ ! -L "$record" ]; then
    IFS=' ' read -r recorded_lock backend target extra < "$record" 2>/dev/null || true
  fi
  [ "$recorded_lock" = "$current_lock" ] || return 1
  [ -n "$backend" ] && [ -n "$target" ] && [ -z "$extra" ] || return 1
  # Trailing newline matters here: callers read this with `read`, which
  # reports failure on a final line with no newline even though it still
  # assigns the fields - printing one avoids that false negative.
  printf '%s %s\n' "$backend" "$target"
}

fm_composer_command_delivered_marker() {  # <state-dir> <key>
  printf '%s/.composer-command-delivered/%s' "$1" "$2"
}

fm_composer_command_inflight_claim() {  # <state-dir> <key>
  printf '%s/.composer-command-inflight/%s' "$1" "$2"
}

# fm_composer_command_claim: atomically claim <key> for one in-flight delivery
# attempt via mkdir (atomic on every POSIX filesystem). A claim older than 30s
# is treated as abandoned by a crashed attempt and reclaimed rather than
# blocking every future retry forever.
fm_composer_command_claim() {  # <state-dir> <key>
  local state_dir=$1 key=$2 claim mtime now
  claim=$(fm_composer_command_inflight_claim "$state_dir" "$key")
  mkdir -p "$(dirname "$claim")" 2>/dev/null || return 1
  if mkdir "$claim" 2>/dev/null; then
    return 0
  fi
  mtime=$(fm_file_mtime_epoch "$claim" 2>/dev/null) || mtime=0
  now=$(fm_epoch_now 2>/dev/null) || now=0
  if [ "$mtime" -gt 0 ] && [ "$now" -gt 0 ] && [ "$((now - mtime))" -ge 30 ]; then
    rmdir "$claim" 2>/dev/null || true
    mkdir "$claim" 2>/dev/null && return 0
  fi
  return 1
}

fm_composer_command_release() {  # <state-dir> <key>
  rmdir "$(fm_composer_command_inflight_claim "$1" "$2")" 2>/dev/null || true
}

fm_file_mtime_epoch() {  # <path>
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

fm_epoch_now() {
  date +%s 2>/dev/null
}

# fm_composer_command_deliver: the full, idempotent delivery pipeline. Prints
# exactly one line describing the outcome and returns a distinct code for
# every outcome, so a caller (or a test) never has to guess what happened:
#   0  delivered now, or already delivered previously (idempotent no-op)
#   2  feature not enabled (config/composer-commands absent)
#   3  <text> is not a recognized allowlisted command invocation
#   4  another delivery attempt for this exact key is already in flight
#   5  this home's own session cannot be resolved with certainty
#   6  the recorded backend is not one this feature can deliver into
#   7  the recorded session endpoint no longer exists
#   8  the session is busy (mid-turn) or its composer is not confirmed empty
#   9  the submit could not be confirmed delivered
#   10 the command WAS submitted but the durable marker could not be written -
#      see the comment at the marker write below for why this cannot report
#      success
fm_composer_command_deliver() {  # <text> <key> <config-dir> <state-dir>
  local text=$1 key=$2 config_dir=$3 state_dir=$4
  local marker cmd backend target harness verdict retries sleep_s settle

  if ! fm_composer_command_enabled "$config_dir"; then
    printf 'composer command delivery is not enabled (config/composer-commands absent)\n'
    return 2
  fi

  if ! cmd=$(fm_composer_command_match "$text"); then
    printf 'not a recognized composer command invocation: refusing to deliver\n'
    return 3
  fi

  marker=$(fm_composer_command_delivered_marker "$state_dir" "$key")
  if [ -e "$marker" ]; then
    printf 'already delivered: %s (key=%s)\n' "$cmd" "$key"
    return 0
  fi

  if ! fm_composer_command_claim "$state_dir" "$key"; then
    printf 'delivery already in progress for key=%s: refusing to race it\n' "$key"
    return 4
  fi

  if ! read -r backend target < <(fm_composer_command_session_effective "$state_dir" 2>/dev/null); then
    fm_composer_command_release "$state_dir" "$key"
    printf 'cannot resolve this home'"'"'s own session with certainty: delivering nothing\n'
    return 5
  fi

  case " $FM_COMPOSER_COMMAND_SUPPORTED_BACKENDS " in
    *" $backend "*) : ;;
    *)
      fm_composer_command_release "$state_dir" "$key"
      printf 'recorded backend '"'"'%s'"'"' is not supported for composer command delivery (supported: %s)\n' \
        "$backend" "$FM_COMPOSER_COMMAND_SUPPORTED_BACKENDS"
      return 6
      ;;
  esac

  if ! tmux display-message -p -t "$target" '#{pane_id}' >/dev/null 2>&1; then
    fm_composer_command_release "$state_dir" "$key"
    printf 'this home'"'"'s own session endpoint no longer exists: delivering nothing\n'
    return 7
  fi

  harness=$("$FM_COMPOSER_COMMAND_LIB_DIR/fm-harness.sh" 2>/dev/null || printf 'unknown')
  if fm_pane_is_busy "$target" "$harness" || [ "$(fm_tmux_composer_state "$target")" != empty ]; then
    fm_composer_command_release "$state_dir" "$key"
    printf 'deferred: this home'"'"'s own session is busy or its composer is not confirmed empty (command not delivered, not marked done)\n'
    return 8
  fi

  retries=${FM_COMPOSER_COMMAND_SUBMIT_RETRIES:-5}
  sleep_s=${FM_COMPOSER_COMMAND_SUBMIT_SLEEP:-0.2}
  settle=${FM_COMPOSER_COMMAND_SUBMIT_SETTLE:-0.2}
  verdict=$(fm_tmux_submit_core "$target" "$cmd" "$retries" "$sleep_s" "$settle")
  fm_composer_command_release "$state_dir" "$key"

  if [ "$verdict" != empty ]; then
    printf 'delivery could not be confirmed (verdict=%s): not marked delivered, safe to retry\n' "$verdict"
    return 9
  fi

  # The command has ALREADY run at this point (the submit above was
  # confirmed), so a failure here cannot be swallowed into an ordinary
  # success: doing that would leave no durable record, and a later same-key
  # call would find no marker, pass every guard again, and resubmit - a real
  # double delivery, exactly what this contract exists to prevent. Verify the
  # marker actually exists after the attempt rather than trusting either
  # command's own exit code, so a partial failure (mkdir ok, write not) is
  # still caught. There is no way to "undo" the already-run command, so the
  # only honest response is to report the failure loudly and distinctly
  # rather than pretend delivery completed cleanly.
  mkdir -p "$(dirname "$marker")" 2>/dev/null
  : > "$marker" 2>/dev/null
  if [ ! -e "$marker" ]; then
    printf '%s was delivered to this home'"'"'s own session (key=%s), but the durable delivered-marker could not be written: a later retry for this exact key may resubmit it\n' "$cmd" "$key"
    return 10
  fi
  printf 'delivered %s to this home'"'"'s own session (key=%s)\n' "$cmd" "$key"
  return 0
}
