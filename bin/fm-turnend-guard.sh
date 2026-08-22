#!/usr/bin/env bash
# Turn-end guard for any firstmate PRIMARY session: the main home OR a
# secondmate's own home. A secondmate runs its own primary firstmate session and
# is guarded exactly like the main primary; child writer worktrees and reader
# scout scratch directories are exempt (see the scoping block below and docs/turnend-guard.md).
#
# fm-guard.sh (bin/fm-guard.sh) is pull-based: it only warns when some other
# supervision script happens to run. A primary session that ends a turn without
# resuming its harness supervision protocol, and then never runs another
# fleet-touching command itself, can sit blind for hours.
# This script is push-based: verified harness turn-end hooks invoke it every time
# the primary is about to end a turn.
# Claude and codex can block directly by preserving exit status 2 and stderr.
# OpenCode and pi adapters use the same predicate and force one bounded
# follow-up because their turn-end events are passive. Grok delegates native
# blocking when its running Stop payload advertises that capability, with one
# bounded resume fallback for payloads from pre-native processes.
# The same hook family also measures the completed captain-facing reply against
# the fleet's configured line cap. It emits one non-blocking warning for one
# oversized reply and never manufactures another continuation. Extraction,
# configuration, measurement, identity, or warning-state failure emits one
# bounded diagnostic and steps aside. See docs/turnend-guard.md for the full
# warning boundary and per-harness delivery mechanics.
#
# Ships with TRACKED harness hook files at the repo root, so this file is
# checked out into every worktree of this repo: the primary checkout, every
# secondmate home (treehouse-leased or git-cloned), and any writer task worktree
# spawned to work on firstmate itself (the recursive "firstmate
# improving itself" case). A secondmate home runs its OWN primary firstmate
# session, so it must be guarded like the main primary; child writer worktrees
# and reader scout scratch directories are exempt. It must therefore scope itself at runtime to a real
# primary checkout - the main home or a genuinely marked secondmate home - and
# stay a silent, fast no-op inside child task environments.
#
# Loop-guard, codex/Grok (default) mode: never block twice in the same turn.
# Codex uses stop_hook_active and Grok uses stopHookActive; typed camel-case
# takes precedence when both spellings are present. A true value means the
# current stop attempt already follows a block, so this guard always allows it.
# Passive harness adapters provide their own one-follow-up guard before calling
# this script.
# That bounds those harnesses to at most one forced continuation per turn -
# never a wedged, un-endable session - while still nagging again on a later turn
# if the problem persists.
#
# Loop-guard, --claude mode (Stop-owned auto-arm cooperation): Claude Code
# marks EVERY stop after ANY stop-hook-driven continuation stop_hook_active=true,
# including turns started by the asyncRewake auto-arm, so the one-shot allow
# would re-open the exact blind window this guard exists to close
# (docs/turnend-guard.md records the 2026-07-21 incident). In --claude mode this
# guard ignores stop_hook_active and instead cooperates with the Stop-owned
# auto-arm (bin/fm-claude-stop-autoarm.sh), which fires on the same Stop event:
#   1. a live identity-matched watcher with a fresh beacon allows immediately;
#   2. otherwise wait briefly (FM_CLAUDE_AUTOARM_SYNC_WAIT_MS, default 800ms)
#      for the auto-arm to claim this home (state/.claude-autoarm.lock owner
#      alive) or to record a fresh actionable exit-2 outcome
#      (state/.claude-autoarm-epoch) for this event epoch - either proof allows
#      without consuming a continuation, so one event epoch yields exactly one recovery turn;
#      the first fresh exhausted-failure epoch preserves the bounded progression,
#      while later fresh failed epochs consume it instead of resetting it;
#   3. only when neither materializes is the auto-arm genuinely absent: re-block
#      with the repair banner, bounded to FM_CLAUDE_TURNEND_BLOCK_BUDGET
#      (default 3) consecutive blocks per session - safely below Claude Code's
#      hard 8-consecutive-block override - then allow one loud attended
#      fail-open only for an already verified failure episode.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"
CLAUDE_MODE=0
SYNC_WAIT_MS=${FM_CLAUDE_AUTOARM_SYNC_WAIT_MS:-800}
EPOCH_FRESH=${FM_CLAUDE_AUTOARM_EPOCH_FRESH:-15}
BLOCK_BUDGET=${FM_CLAUDE_TURNEND_BLOCK_BUDGET:-3}
case "$SYNC_WAIT_MS" in ''|*[!0-9]*) SYNC_WAIT_MS=800 ;; esac
case "$EPOCH_FRESH" in ''|*[!0-9]*|0) EPOCH_FRESH=15 ;; esac
case "$BLOCK_BUDGET" in ''|*[!0-9]*|0) BLOCK_BUDGET=3 ;; esac

for arg in "$@"; do
  case "$arg" in
    --claude) CLAUDE_MODE=1 ;;
    *) echo "usage: $(basename "$0") [--claude]" >&2; exit 2 ;;
  esac
done

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

# Read the whole turn-end hook payload once; never block on unreadable/absent
# stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# jq is the repo's established JSON dependency (bin/fm-x-poll.sh uses the same
# "missing jq -> silent no-op" degrade). Without it we cannot safely read the
# loop-guard field, so we must never block - fail open, not noisy.
command -v jq >/dev/null 2>&1 || exit 0

STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '
  if type != "object" then error("payload")
  elif has("stopHookActive") then
    if ((.stopHookActive | type) == "boolean") then .stopHookActive else error("stopHookActive") end
  elif has("stop_hook_active") then
    if ((.stop_hook_active | type) == "boolean") then .stop_hook_active else error("stop_hook_active") end
  else false
  end
' 2>/dev/null) || exit 0
if [ "$CLAUDE_MODE" -eq 0 ] && [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

# --- scope precisely to a PRIMARY checkout ----------------------------------
# A genuinely-marked secondmate home runs its OWN primary firstmate session, so
# force-INCLUDE it as a guarded primary whether treehouse leased it as a linked
# worktree (git-dir != git-common-dir) or it is a git-cloned plain checkout. This
# mirrors the cd-guard's intent that a secondmate's own session is a guarded
# primary. Only an UNMARKED checkout (or one with an invalid marker) falls
# through to the linked-worktree exemption: firstmate hands ship and writer
# scout tasks genuine linked `git worktree`s (bin/fm-spawn.sh aborts otherwise),
# whose git-dir lives under the parent repo's .git/worktrees/<name>
# and differs from the common (shared) git-dir, while a main, non-worktree
# checkout has the two equal. Child worktrees never carry the gitignored marker,
# so this exempts them while guarding every real secondmate home.
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- non-blocking captain-facing reply warning -------------------------------
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"

# The documented tail window this advisory check reads from a turn transcript.
CAPTAIN_COMMS_TRANSCRIPT_WINDOW=200

# A direct harness parses this hook's stdout as one JSON document, so the guard
# emits at most one envelope per invocation. Both advisory messages it can
# produce - the attended fail-open notice and the captain reply warning - are
# held here and joined into that single envelope at exit, notice first.
GUARD_STDOUT_NOTICE=
CAPTAIN_COMMS_WARNING_TEXT=
CAPTAIN_COMMS_WARNING_DIGEST=
CAPTAIN_COMMS_WARNING_SESSION_KEY=
CAPTAIN_COMMS_WARNING_TAKEN=0

# An adapter that reads none of this hook's stdout declares that here, so the
# guard neither emits an envelope into a sink nor spends the warning's one
# delivery on it. docs/turnend-guard.md lists the registrations that declare
# it and why each one has no established stdout reader.
GUARD_STDOUT_SINK=${FM_TURNEND_STDOUT_SINK:-reader}

# The supervision banner marks every line it owns with BANNER_MARK; a warning
# delivered alongside that banner uses ADVISORY_MARK. A passive adapter keeps
# only banner lines out of stderr, because it already received the warning on
# stdout; the legacy Grok resume, which has no stdout consumer, keeps both.
BANNER_MARK='●'
ADVISORY_MARK='○'

# The single warn-once boundary: the identity is recorded only when this
# invocation is about to put the warning on a channel its caller reads. Delivery
# that cannot happen leaves the reply eligible to warn at a later turn end.
captain_comms_warning_take() {
  [ -n "$CAPTAIN_COMMS_WARNING_TEXT" ] || return 1
  [ "$CAPTAIN_COMMS_WARNING_TAKEN" -eq 0 ] || return 0
  if ! captain_comms_warning_claim "$CAPTAIN_COMMS_WARNING_SESSION_KEY" "$CAPTAIN_COMMS_WARNING_DIGEST"; then
    CAPTAIN_COMMS_WARNING_TEXT=
    return 1
  fi
  CAPTAIN_COMMS_WARNING_TAKEN=1
  return 0
}

guard_stdout_emit() {  # <exit-status>
  local status=$1 message kind json
  [ "$GUARD_STDOUT_SINK" != none ] || return 0
  message=$GUARD_STDOUT_NOTICE
  kind=
  # A direct harness discards stdout on a blocked stop, and only block_stop has
  # a stderr channel for the warning there, so a block that printed no banner
  # must not spend the warning on a stream nobody will read.
  if { [ "$status" -eq 0 ] || [ "$CAPTAIN_COMMS_WARNING_TAKEN" -eq 1 ]; } \
    && captain_comms_warning_take; then
    if [ -n "$message" ]; then
      message=$(printf '%s\n\n%s' "$message" "$CAPTAIN_COMMS_WARNING_TEXT")
    else
      message=$CAPTAIN_COMMS_WARNING_TEXT
      kind=captain-comms-warning
    fi
  fi
  [ -n "$message" ] || return 0
  json=$(jq -cn --arg message "$message" --arg kind "$kind" \
    'if $kind == "" then {systemMessage:$message} else {systemMessage:$message, kind:$kind} end') || {
      captain_comms_stand_down 'cannot encode the turn-end advisory message'
      return 0
    }
  printf '%s\n' "$json"
}

guard_exit() {  # <status>
  guard_stdout_emit "$1"
  exit "$1"
}

captain_comms_stand_down() {
  printf 'fm-turnend-guard: captain-comms warning stood down: %s\n' "$1" >&2
}

captain_comms_run_bounded() {  # <seconds> <command...>
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$seconds" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$seconds" "$@"
  else
    return 127
  fi
}

captain_comms_transcript_summary() {  # <transcript-path> <result-var>
  local transcript=$1 result_var=$2 parsed_summary jq_program
  if [ ! -f "$transcript" ] || [ ! -r "$transcript" ]; then
    captain_comms_stand_down 'cannot read the turn transcript'
    return 1
  fi
  # shellcheck disable=SC2016 # jq expands $items; the outer shell must not.
  jq_program='
      def text_content:
        if type == "string" then .
        elif type == "array" then
          map(
            if type == "string" then .
            elif ((.type? == "text" or .type? == "input_text" or .type? == "output_text")
                  and ((.text? | type) == "string")) then .text
            else empty
            end
          ) | join("")
        else ""
        end;
      def conversation_item:
        if (.type? == "user" and .message?.role? == "user") then
          {role:"user", text:(.message.content | text_content), id:(.uuid? // .id? // "")}
        elif (.type? == "assistant" and .message?.role? == "assistant") then
          {role:"assistant", text:(.message.content | text_content), id:(.uuid? // .id? // "")}
        elif (.type? == "response_item" and .payload?.type? == "message"
              and (.payload.role? == "user" or .payload.role? == "assistant")) then
          {role:.payload.role, text:(.payload.content | text_content), id:(.payload.id? // .id? // "")}
        elif (.type? == "event_msg" and .payload?.type? == "user_message") then
          {role:"user", text:(.payload.message? // ""), id:(.payload.id? // .id? // "")}
        elif (.type? == "event_msg" and .payload?.type? == "agent_message") then
          {role:"assistant", text:(.payload.message? // ""), id:(.payload.id? // .id? // "")}
        else empty
        end;
      [split("\n")[] | fromjson? | conversation_item
       | select((.text | type) == "string" and (.text | length) > 0)] as $items
      | {
          trigger: ([$items[] | select(.role == "user")] | last // null),
          assistant: ([$items[] | select(.role == "assistant")] | last // null)
        }
    '
  # Read only the tail of the transcript so an hours-long session cannot make
  # this advisory check re-parse megabytes on every turn end. The window is a
  # documented fail-open bound: a turn whose triggering input has been pushed
  # out of it yields no trigger, and the warning steps aside. The file is the
  # live session's own transcript, still being appended while this hook runs, so
  # records are decoded one line at a time and an unreadable line is skipped
  # rather than discarding every valid record beside it.
  # shellcheck disable=SC2016 # The bounded child bash expands its positional parameters.
  parsed_summary=$(captain_comms_run_bounded 2 bash -c \
    'set -o pipefail; tail -n "$3" -- "$2" 2>/dev/null | jq -Rsc "$1" 2>/dev/null' \
    _ "$jq_program" "$transcript" "$CAPTAIN_COMMS_TRANSCRIPT_WINDOW") || {
      captain_comms_stand_down 'cannot parse the turn transcript within the measurement bound'
      return 1
    }
  printf -v "$result_var" '%s' "$parsed_summary"
}

# bin/fm-slack-lib.sh owns the captain-comms cap format, its built-in default,
# its dangling-symlink and unreadable-file rules, and the line measurement. This
# guard only calls that owner; it never restates any part of the contract.
captain_comms_owner_load() {
  [ -z "${FMS_CAPTAIN_COMMS_LINES_DEFAULT:-}" ] || return 0
  # shellcheck source=bin/fm-slack-lib.sh
  if ! . "$SCRIPT_DIR/fm-slack-lib.sh" 2>/dev/null; then
    captain_comms_stand_down 'cannot load the shared captain-comms configuration owner'
    return 1
  fi
}

captain_comms_line_cap_load() {
  local value
  captain_comms_owner_load || return 1
  value=$(fms_captain_comms_cap_read \
    "$CONFIG/slack-captain-comms-lines" "$FMS_CAPTAIN_COMMS_LINES_DEFAULT") || {
      captain_comms_stand_down 'cannot load the captain-comms line cap'
      return 1
    }
  CAPTAIN_COMMS_LINE_CAP=$value
}

captain_comms_line_count() {  # <reply> <result-var>
  local reply=$1 result_var=$2
  captain_comms_owner_load || return 1
  fms_captain_comms_line_count "$reply" || {
    captain_comms_stand_down 'cannot count reply lines'
    return 1
  }
  printf -v "$result_var" '%s' "$FMS_CAPTAIN_COMMS_LINE_COUNT"
}

captain_comms_digest() {  # stdin
  if command -v shasum >/dev/null 2>&1; then
    (set -o pipefail; shasum -a 256 2>/dev/null | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    (set -o pipefail; sha256sum 2>/dev/null | awk '{print $1}')
  else
    return 1
  fi
}

# The warned-identity record holds one line per session, most recently warned
# first, so concurrent sessions in one home cannot evict each other's identity
# and re-warn a reply that already warned. The bound matches the OpenCode
# adapter's own retained-session cap. A line that is not exactly a key and a
# digest is ignored, so malformed state degrades to "not yet warned" instead of
# suppressing every future warning.
CAPTAIN_COMMS_WARNING_SESSIONS_MAX=32

captain_comms_session_key() {  # <session-id> <result-var>
  local key=${1//[^A-Za-z0-9._-]/_}
  [ -n "$key" ] || key=unknown
  printf -v "$2" '%s' "${key:0:64}"
}

captain_comms_warning_claim() {  # <session-key> <reply-digest>
  local session_key=$1 digest=$2 claim_file lock tmp previous
  claim_file="$STATE/.turnend-captain-comms-warning"
  lock="$STATE/.turnend-captain-comms-warning.lock"
  if ! fm_lock_try_acquire "$lock"; then
    captain_comms_stand_down 'cannot acquire the warning identity claim without waiting'
    return 1
  fi
  previous=$(awk -v key="$session_key" \
    'NF == 2 && $1 == key { print $2; exit }' "$claim_file" 2>/dev/null || true)
  if [ "$previous" = "$digest" ]; then
    fm_lock_release "$lock"
    return 2
  fi
  tmp="$claim_file.tmp.${BASHPID:-$$}"
  if ! {
    printf '%s %s\n' "$session_key" "$digest"
    awk -v key="$session_key" 'NF == 2 && $1 != key { print }' "$claim_file" 2>/dev/null || true
  } | head -n "$CAPTAIN_COMMS_WARNING_SESSIONS_MAX" > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$claim_file" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    fm_lock_release "$lock"
    captain_comms_stand_down 'cannot record the warning identity'
    return 1
  fi
  fm_lock_release "$lock"
  return 0
}

captain_comms_warn_if_needed() {
  local normalized reply reply_id trigger transcript summary explicit_facing
  local assistant_id assistant_text trigger_text trigger_id need_summary summary_loaded
  # shellcheck disable=SC2034 # Output variable populated by fm_operational_input_classify.
  local session_id line_count='' identity digest operational_kind
  normalized=$(printf '%s' "$PAYLOAD" | jq -cer '
    def optional_string($name):
      if has($name) then
        if (.[$name] | type) == "string" then .[$name] else error($name) end
      else null
      end;
    def optional_boolean($name):
      if has($name) then
        if (.[$name] | type) == "boolean" then .[$name] else error($name) end
      else null
      end;
    {
      reply: (optional_string("fm_reply_text") // optional_string("last_assistant_message")
              // optional_string("lastAssistantMessage")),
      reply_id: (optional_string("fm_reply_id") // optional_string("turn_id")
                 // optional_string("turnId") // optional_string("prompt_id")
                 // optional_string("promptId")),
      trigger: optional_string("fm_trigger_text"),
      transcript: (optional_string("transcript_path") // optional_string("transcriptPath")),
      captain_facing: optional_boolean("fm_captain_facing"),
      session_id: (optional_string("session_id") // optional_string("sessionId") // "unknown")
    }
  ' 2>/dev/null) || {
    captain_comms_stand_down 'reply metadata is malformed'
    return 0
  }
  # One NUL-separated read keeps every multi-line field intact while spawning a
  # single jq on the turn-end hot path instead of one per field.
  reply='' reply_id='' trigger='' transcript='' explicit_facing='' session_id=''
  {
    IFS= read -r -d '' reply || true
    IFS= read -r -d '' reply_id || true
    IFS= read -r -d '' trigger || true
    IFS= read -r -d '' transcript || true
    IFS= read -r -d '' explicit_facing || true
    IFS= read -r -d '' session_id || true
  } < <(printf '%s' "$normalized" | jq -j '
      (.reply // ""), "\u0000",
      (.reply_id // ""), "\u0000",
      (.trigger // ""), "\u0000",
      (.transcript // ""), "\u0000",
      (if .captain_facing == null then "" else (.captain_facing | tostring) end), "\u0000",
      (.session_id // "unknown"), "\u0000"
    ' 2>/dev/null)
  [ -n "$session_id" ] || session_id=unknown

  [ "$explicit_facing" != false ] || return 0

  # A reply the payload already carries is measured before anything else: a
  # reply at or under the cap can never warn, so it must not pay for a
  # transcript parse or leave a stand-down diagnostic about one.
  if [ -n "$reply" ]; then
    captain_comms_line_cap_load || return 0
    captain_comms_line_count "$reply" line_count || return 0
    [ "$line_count" -gt "$CAPTAIN_COMMS_LINE_CAP" ] || return 0
  fi

  # The transcript is the direct harnesses' authoritative source for the
  # completed reply, its identity, and the triggering input. Parse it only when
  # the payload left one of those unresolved.
  need_summary=0
  summary_loaded=0
  [ -n "$reply" ] || need_summary=1
  [ -n "$reply_id" ] || need_summary=1
  if [ "$explicit_facing" != true ] && [ -z "$trigger" ]; then
    need_summary=1
  fi
  if [ "$need_summary" -eq 1 ] && [ -n "$transcript" ]; then
    captain_comms_transcript_summary "$transcript" summary || return 0
    assistant_text='' assistant_id='' trigger_text='' trigger_id=''
    {
      IFS= read -r -d '' assistant_text || true
      IFS= read -r -d '' assistant_id || true
      IFS= read -r -d '' trigger_text || true
      IFS= read -r -d '' trigger_id || true
    } < <(printf '%s' "$summary" | jq -j '
        (.assistant.text // ""), "\u0000",
        (.assistant.id // ""), "\u0000",
        (.trigger.text // ""), "\u0000",
        (.trigger.id // ""), "\u0000"
      ' 2>/dev/null)
    [ -n "$reply" ] || reply=$assistant_text
    [ -n "$reply_id" ] || reply_id=$assistant_id
    [ -n "$reply_id" ] || reply_id=$trigger_id
    [ -n "$trigger" ] || trigger=$trigger_text
    summary_loaded=1
  fi

  if [ -z "$reply" ]; then
    # A payload that carries no reply and no transcript has nothing to measure;
    # that is silence, not a failure. A transcript that yielded no completed
    # assistant text is a genuine extraction failure and leaves evidence.
    [ "$summary_loaded" -eq 0 ] || captain_comms_stand_down 'cannot extract the completed reply'
    return 0
  fi
  if [ "$explicit_facing" != true ]; then
    [ -n "$trigger" ] || {
      captain_comms_stand_down 'cannot identify the reply audience'
      return 0
    }
    if fm_operational_input_classify "$trigger" operational_kind; then
      return 0
    fi
  fi
  [ -n "$reply_id" ] || {
    captain_comms_stand_down 'cannot identify the completed reply'
    return 0
  }

  if [ -z "$line_count" ]; then
    captain_comms_line_cap_load || return 0
    captain_comms_line_count "$reply" line_count || return 0
    [ "$line_count" -gt "$CAPTAIN_COMMS_LINE_CAP" ] || return 0
  fi
  captain_comms_session_key "$session_id" CAPTAIN_COMMS_WARNING_SESSION_KEY
  identity=$(printf '%s\n%s\n%s' "$session_id" "$reply_id" "$reply")
  digest=$(printf '%s' "$identity" | captain_comms_digest) && [ -n "$digest" ] || {
    captain_comms_stand_down 'cannot hash the warning identity'
    return 0
  }
  CAPTAIN_COMMS_WARNING_DIGEST=$digest
  CAPTAIN_COMMS_WARNING_TEXT="FIRSTMATE CAPTAIN COMMS WARNING: the reply that just completed is $line_count lines, over the $CAPTAIN_COMMS_LINE_CAP-line captain comms cap. Nothing was truncated, retried, or blocked."
}

captain_comms_warn_if_needed

# --- the actual supervision predicate ----------------------------------------
BUDGET_FILE="$STATE/.turnend-claude-blocks"
BUDGET_LOCK="$STATE/.turnend-claude-blocks.lock"
OWNER_LOCK="$STATE/.claude-autoarm.lock"
FAILURE_NOTICE="$STATE/.claude-autoarm-failure-notified"
FAILURE_ALARM="$STATE/.claude-autoarm-failure-alarmed"
SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // "unknown"' 2>/dev/null || printf 'unknown')
budget_reset() {
  [ "$CLAUDE_MODE" -eq 1 ] || return 0
  fm_lock_try_acquire "$BUDGET_LOCK" || return 0
  rm -f "$BUDGET_FILE" 2>/dev/null || true
  fm_lock_release "$BUDGET_LOCK"
}

fm_supervision_status "$STATE" "$GRACE"
if [ "$FM_SUP_NEEDED" = false ]; then
  [ -e "$FAILURE_NOTICE" ] || budget_reset
  guard_exit 0
fi
if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
  [ "$CLAUDE_MODE" -eq 1 ] || guard_exit 0
  fm_failure_episode_reset "$STATE" && guard_exit 0
  guard_exit 2
fi

block_stop() {
  local afk x_mode reason rule reason_line
  afk=0
  [ -e "$STATE/.afk" ] && afk=1
  x_mode=0
  [ -f "$CONFIG/x-mode.env" ] && x_mode=1
  reason=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --afk "$afk" --x-mode "$x_mode" --repair-line 2>/dev/null \
    || printf '%s\n' 'tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn')
  rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '%s%s\n' "$BANNER_MARK" "$rule"
    printf '%s  TURN WOULD END BLIND - SUPERVISION IS OFF\n' "$BANNER_MARK"
    if [ "$FM_SUP_IN_FLIGHT" -gt 0 ]; then
      printf '%s  %s task(s) in flight, but no live watcher holds this home lock (last beat: %s).\n' "$BANNER_MARK" "$FM_SUP_IN_FLIGHT" "$FM_SUP_BEACON_DESC"
    elif [ "$FM_SUP_SOURCES" -gt 0 ]; then
      printf '%s  %s process-event source(s) registered, but no live watcher holds this home lock (last beat: %s).\n' "$BANNER_MARK" "$FM_SUP_SOURCES" "$FM_SUP_BEACON_DESC"
    else
      printf '%s  X-mode relay polling needs supervision, but no live watcher holds this home lock (last beat: %s).\n' "$BANNER_MARK" "$FM_SUP_BEACON_DESC"
    fi
    if [ "$CLAUDE_MODE" -eq 1 ]; then
      printf '%s  The Stop-owned auto-arm did not claim this home either, so recovery is NOT already under way.\n' "$BANNER_MARK"
    fi
    while IFS= read -r reason_line; do
      printf '%s  %s\n' "$BANNER_MARK" "$reason_line"
    done <<REASON
$reason
REASON
    printf '%s%s\n' "$BANNER_MARK" "$rule"
    ! captain_comms_warning_take \
      || printf '%s  %s\n' "$ADVISORY_MARK" "$CAPTAIN_COMMS_WARNING_TEXT"
  } >&2
  guard_exit 2
}

if [ "$CLAUDE_MODE" -eq 0 ]; then
  block_stop
fi

# --- --claude cooperative path -----------------------------------------------
# The Stop-owned auto-arm fires on the same Stop event. Give it a brief bounded
# window to prove it owns recovery for this event epoch before consuming one of
# Claude's bounded continuations.
budget_account_current_epoch() {
  local current_epoch outcome old_session old_count old_epoch tmp initialized
  fm_lock_try_acquire "$BUDGET_LOCK" || return 1
  current_epoch=$(sed -n 's/^epoch=\([0-9][0-9]*\) .*/\1/p' "$STATE/.claude-autoarm-epoch" 2>/dev/null || true)
  outcome=$(sed -n 's/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$STATE/.claude-autoarm-epoch" 2>/dev/null || true)
  initialized=0
  COUNT=0
  if [ -f "$BUDGET_FILE" ]; then
    old_session=$(sed -n '1s/^session=//p' "$BUDGET_FILE" 2>/dev/null || true)
    old_count=$(sed -n '2s/^count=//p' "$BUDGET_FILE" 2>/dev/null || true)
    old_epoch=$(sed -n '3s/^epoch=//p' "$BUDGET_FILE" 2>/dev/null || true)
    case "$old_count" in
      ''|*[!0-9]*) old_count=0 ;;
    esac
    if [ "$old_session" = "$SESSION_ID" ]; then
      COUNT=$old_count
      if [ -n "$current_epoch" ] && [ "$old_epoch" = "$current_epoch" ]; then
        :
      else
        COUNT=$((COUNT + 1))
      fi
    fi
  fi
  if [ ! -f "$BUDGET_FILE" ] || [ "${old_session:-}" != "$SESSION_ID" ]; then
    case "$outcome" in
      failed|failed-suppressed)
        if [ -e "$FAILURE_NOTICE" ]; then
          initialized=1
          COUNT=0
        else
          COUNT=1
        fi
        ;;
      *) COUNT=1 ;;
    esac
  fi
  tmp="$BUDGET_FILE.tmp.$$"
  if ! printf 'session=%s\ncount=%s\nepoch=%s\n' "$SESSION_ID" "$COUNT" "$current_epoch" > "$tmp" 2>/dev/null \
    || ! mv -f "$tmp" "$BUDGET_FILE" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    fm_lock_release "$BUDGET_LOCK"
    return 1
  fi
  rm -f "$tmp" 2>/dev/null || true
  BUDGET_INITIALIZED_FAILURE=$initialized
  fm_lock_release "$BUDGET_LOCK"
  return 0
}

autoarm_owns_recovery() {
  local pid role outcome age
  fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" && return 0
  pid=$(cat "$OWNER_LOCK/pid" 2>/dev/null || true)
  role=$(fm_lock_role "$OWNER_LOCK" 2>/dev/null || true)
  if fm_pid_alive "$pid" && [ "$role" = autoarm ]; then
    [ ! -e "$FAILURE_NOTICE" ] || budget_account_current_epoch || true
    return 0
  fi
  outcome=$(sed -n 's/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$STATE/.claude-autoarm-epoch" 2>/dev/null || true)
  case "$outcome" in
    rewake)
      age=$(fm_path_age "$STATE/.claude-autoarm-epoch")
      if [ "$age" -lt "$EPOCH_FRESH" ]; then
        [ ! -e "$FAILURE_NOTICE" ] || budget_account_current_epoch || true
        return 0
      fi
      ;;
    failed)
      age=$(fm_path_age "$STATE/.claude-autoarm-epoch")
      if [ "$age" -lt "$EPOCH_FRESH" ] && [ -e "$FAILURE_NOTICE" ] \
        && budget_account_current_epoch; then
        [ "$BUDGET_INITIALIZED_FAILURE" -eq 1 ] && return 0
      fi
      ;;
    failed-suppressed)
      age=$(fm_path_age "$STATE/.claude-autoarm-epoch")
      if [ "$age" -lt "$EPOCH_FRESH" ] && [ -e "$FAILURE_NOTICE" ] \
        && budget_account_current_epoch; then
        :
      fi
      ;;
  esac
  return 1
}

terminal_fail_open() {
  local pid role old_session old_count
  [ "$COUNT" -gt "$BLOCK_BUDGET" ] || return 1
  failure_episode_verified || return 1
  [ ! -e "$FAILURE_ALARM" ] || return 1
  if ! fm_lock_try_acquire "$OWNER_LOCK"; then
    pid=$(cat "$OWNER_LOCK/pid" 2>/dev/null || true)
    role=$(fm_lock_role "$OWNER_LOCK" 2>/dev/null || true)
    if fm_pid_alive "$pid" && [ "$role" = autoarm ]; then
      return 2
    fi
    return 1
  fi
  if ! fm_lock_set_role "$OWNER_LOCK" terminal-check; then
    fm_lock_release "$OWNER_LOCK"
    return 1
  fi
  if ! fm_lock_try_acquire "$BUDGET_LOCK"; then
    fm_lock_release "$OWNER_LOCK"
    return 1
  fi
  old_session=$(sed -n '1s/^session=//p' "$BUDGET_FILE" 2>/dev/null || true)
  old_count=$(sed -n '2s/^count=//p' "$BUDGET_FILE" 2>/dev/null || true)
  case "$old_count" in
    ''|*[!0-9]*) old_count=0 ;;
  esac
  role=$(fm_lock_role "$OWNER_LOCK" 2>/dev/null || true)
  if [ "$role" != terminal-check ] || [ "$old_session" != "$SESSION_ID" ] \
    || [ "$old_count" -le "$BLOCK_BUDGET" ] || ! failure_episode_verified \
    || [ -e "$FAILURE_ALARM" ]; then
    fm_lock_release "$BUDGET_LOCK"
    fm_lock_release "$OWNER_LOCK"
    return 1
  fi
  if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
    if ! fm_failure_episode_reset "$STATE" held; then
      fm_lock_release "$BUDGET_LOCK"
      fm_lock_release "$OWNER_LOCK"
      return 1
    fi
    fm_lock_release "$BUDGET_LOCK"
    fm_lock_release "$OWNER_LOCK"
    return 2
  fi
  if ! (set -C; : > "$FAILURE_ALARM") 2>/dev/null; then
    fm_lock_release "$BUDGET_LOCK"
    fm_lock_release "$OWNER_LOCK"
    return 1
  fi
  fm_lock_release "$BUDGET_LOCK"
  fm_lock_release "$OWNER_LOCK"
  return 0
}

failure_episode_verified() {
  local outcome
  [ ! -e "$STATE/.afk" ] || return 1
  [ -e "$FAILURE_NOTICE" ] || return 1
  outcome=$(sed -n 's/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$STATE/.claude-autoarm-epoch" 2>/dev/null || true)
  case "$outcome" in
    failed|failed-suppressed) return 0 ;;
    *) return 1 ;;
  esac
}

i=0
while [ "$i" -lt $((SYNC_WAIT_MS / 100)) ]; do
  if autoarm_owns_recovery; then
    if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
      fm_failure_episode_reset "$STATE" || guard_exit 2
    fi
    guard_exit 0
  fi
  sleep 0.1
  i=$((i + 1))
done
if autoarm_owns_recovery; then
  if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
    fm_failure_episode_reset "$STATE" || guard_exit 2
  fi
  guard_exit 0
fi

# The auto-arm genuinely failed to establish: consume the bounded re-block
# budget before considering the verified one-time attended fail-open.
budget_account_current_epoch || block_stop
terminal_fail_open
terminal_status=$?
if [ "$terminal_status" -eq 0 ]; then
  if [ "$FM_SUP_IN_FLIGHT" -gt 0 ]; then
    NEED_DESC="$FM_SUP_IN_FLIGHT task(s) in flight"
  elif [ "$FM_SUP_SOURCES" -gt 0 ]; then
    NEED_DESC="$FM_SUP_SOURCES process-event source(s) registered"
  else
    NEED_DESC="X-mode relay polling active"
  fi
  GUARD_STDOUT_NOTICE="FIRSTMATE SUPERVISION IS GENUINELY DOWN: $NEED_DESC, the Stop-owned auto-arm exhausted its bounded retries and one failure notice, no watcher or automatic continuation exists, and the block budget is exhausted. Keep this session attended and diagnose the automatic Stop-hook and watcher startup before relying on unattended supervision."
  guard_exit 0
fi
[ "$terminal_status" -eq 2 ] && guard_exit 0
block_stop
