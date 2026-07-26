#!/usr/bin/env bash
# fm-keepalive.sh - external revival of a PRIMARY firstmate session whose own
# turn died while fleet work was still in flight.
#
# WHY THIS EXISTS. When a crewmate dies the primary notices and relaunches it.
# When the PRIMARY's own turn dies - a fatal API overload after the harness's
# internal retries, or any other hard stop - nothing inside that session can
# start another turn, so in-flight work sits frozen until a human types
# something. This is a small external loop that watches durable evidence and, on
# proof that the session is idle-but-lapsed with work riding on it, injects one
# typed operational input to make the primary resume supervision.
#
# It classifies nothing about WHY the turn died and never touches the harness's
# own retry behavior; it only observes the aftermath.
#
# OFF BY DEFAULT. Nothing runs unless the home opts in with config/keepalive
# containing "on" (local, gitignored; docs/session-keepalive.md owns the contract
# and docs/configuration.md owns the config reference).
#
# AWAY MODE OWNS ITS OWN REVIVAL. While state/.afk exists the away-mode
# sub-supervisor (bin/fm-supervise-daemon.sh) owns injection into the primary
# pane, so every verdict here becomes "afk" and nothing is injected. Two
# injectors racing for one composer would corrupt a turn.
#
# DETECTION EVIDENCE (all durable reads; no conversation scraping):
#   1. state/*.meta          - work in flight; none means nothing to revive.
#   2. state/.afk            - away mode owns supervision.
#   3. state/.lock           - the session lock's harness pid. A live harness
#                              means a dead TURN is revivable; a dead holder
#                              means the whole session is gone and typing cannot
#                              revive it; no lock at all fails closed.
#   4. state/.last-watcher-beat - the watcher liveness beacon shared with
#                              bin/fm-supervision-lib.sh. A healthy primary
#                              re-arms supervision every turn, so a stale beacon
#                              with work in flight is the lapse signal.
#   5. the primary's busy footer - a long-thinking turn or a foreground tool call
#                              is busy and is never revived.
#   6. the primary's composer state - injection happens only into an
#                              affirmatively empty agent composer, so half-typed
#                              human input and a dead-shell prompt both defer.
#   7. state/.keepalive-suspect - the lapse must hold continuously across ticks
#                              for FM_KEEPALIVE_CONFIRM_SECS before the first
#                              revival, so a momentary between-turns window
#                              cannot trigger one.
#
# BACKOFF AND CAP. An overloaded API rejects an immediate retry too, so attempt
# N+1 waits FM_KEEPALIVE_BACKOFF_BASE * 2^(N-1) seconds, capped at
# FM_KEEPALIVE_BACKOFF_MAX. After FM_KEEPALIVE_MAX_ATTEMPTS the loop stops
# injecting and writes state/.keepalive-exhausted, which bin/fm-guard.sh surfaces
# on the next fleet action. Attempt state is durable, so restarting this loop
# does not reset the cap.
#
# AUTHORITY. A revived turn inherits exactly the standing authority it already
# had. Revival is never approval for a merge, an ask-user finding, or anything
# destructive, irreversible, or security-sensitive, and the injected body says so.
#
# Usage:
#   fm-keepalive.sh start      Capture the primary pane, then launch the loop in
#                              a fresh non-visible terminal for the detected
#                              supervisor backend and record its exact id.
#                              Idempotent: an already-running loop is left alone.
#   fm-keepalive.sh run        The foreground loop itself. Normally started by
#                              `start`, or directly inside a harness-native
#                              tracked background job. Never use shell `&`.
#   fm-keepalive.sh stop       Signal the loop, then close the recorded terminal
#                              by exact id.
#   fm-keepalive.sh status     Print loop liveness, the current read-only
#                              verdict, and attempt state. Always exits 0.
#   fm-keepalive.sh tick       Run exactly one evaluate-and-act pass and print
#                              its verdict line.
#   fm-keepalive.sh evaluate   Print the read-only verdict line only.
#   fm-keepalive.sh config-check
#                              Silent opt-in probe for callers that arm this loop:
#                              exit 0 when opted in, 1 when off, 2 when
#                              config/keepalive holds an unrecognized value.
#   fm-keepalive.sh --help
#
# Verdicts (printed as "<verdict>|<detail>"):
#   off no-session idle afk healthy agent-gone endpoint-gone busy unsafe
#   confirming backoff exhausted revived revive-failed
#
# Env knobs (defaults in docs/configuration.md):
#   FM_KEEPALIVE                on|off override for config/keepalive
#   FM_KEEPALIVE_POLL           seconds between ticks in `run` (default 30)
#   FM_KEEPALIVE_GRACE          stale-beacon threshold; defaults to FM_GUARD_GRACE
#   FM_KEEPALIVE_CONFIRM_SECS   continuous lapse required before revival (45)
#   FM_KEEPALIVE_BACKOFF_BASE   first backoff step in seconds (60)
#   FM_KEEPALIVE_BACKOFF_MAX    backoff ceiling in seconds (900)
#   FM_KEEPALIVE_MAX_ATTEMPTS   revival attempts before giving up loudly (5)
#   FM_KEEPALIVE_GONE_EXIT_SECS continuous endpoint absence before the loop exits
#                               instead of watching a closed window (600)
#   FM_KEEPALIVE_SUBMIT_RETRIES Enter-retry attempts after typing once (3)
#   FM_KEEPALIVE_SUBMIT_SLEEP   seconds between submit checks (0.5)
#   FM_KEEPALIVE_ENTRY          test seam: command run in the created terminal
#   FM_SUPERVISOR_TARGET / FM_SUPERVISOR_BACKEND  primary pane overrides, resolved
#                               by bin/fm-supervisor-target-lib.sh
#   FM_STATE_OVERRIDE / FM_CONFIG_OVERRIDE  alternate state/config dirs (tests)
#
# This file is sourceable: the BASH_SOURCE guard at the foot keeps the CLI from
# running so tests can drive the pure evaluators directly.
set -u

FM_KEEPALIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_KEEPALIVE_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# Shared primitives, each with exactly one owner elsewhere:
#   fm-tmux-lib.sh          harness busy signatures (fm_busy_lines_match)
#   fm-backend.sh           per-backend capture/busy/composer/submit dispatch
#   fm-operational-input.sh the typed operational-input envelope
#   fm-supervision-lib.sh   in-flight count and watcher-beacon freshness
#   fm-supervisor-target-lib.sh  primary-pane discovery
#   fm-session-lock-lib.sh  session-lock harness identity and holder liveness
# shellcheck source=bin/fm-tmux-lib.sh
. "$FM_KEEPALIVE_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$FM_KEEPALIVE_DIR/fm-backend.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$FM_KEEPALIVE_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$FM_KEEPALIVE_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$FM_KEEPALIVE_DIR/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$FM_KEEPALIVE_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_KEEPALIVE_DIR/fm-wake-lib.sh"
# Capability-removal half of the no-mistakes gate boundary: arming or driving this
# loop types into the captain's primary pane, the same hazard class as fm-send.sh.
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$FM_KEEPALIVE_DIR/fm-gate-refuse-lib.sh"

# Supervisor backends with verified composer/busy/submit primitives for primary
# injection. Same set as the away-mode daemon; anything else refuses at startup
# rather than running tmux primitives against a non-tmux pane.
FM_KEEPALIVE_SUPPORTED_BACKENDS="tmux herdr"
FM_KEEPALIVE_POLL_DEFAULT=30
FM_KEEPALIVE_CONFIRM_SECS_DEFAULT=45
FM_KEEPALIVE_BACKOFF_BASE_DEFAULT=60
FM_KEEPALIVE_BACKOFF_MAX_DEFAULT=900
FM_KEEPALIVE_MAX_ATTEMPTS_DEFAULT=5
FM_KEEPALIVE_GONE_EXIT_SECS_DEFAULT=600
FM_KEEPALIVE_SUBMIT_RETRIES_DEFAULT=3
FM_KEEPALIVE_SUBMIT_SLEEP_DEFAULT=0.5
FM_KEEPALIVE_LOG_MAX_BYTES_DEFAULT=262144
FM_KEEPALIVE_LOG_KEEP_LINES_DEFAULT=1000
FM_KEEPALIVE_WS_LABEL="firstmate-keepalive"

fm_keepalive_state() { printf '%s' "${FM_STATE_OVERRIDE:-$FM_HOME/state}"; }
fm_keepalive_config() { printf '%s' "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"; }

fm_keepalive_now() { date +%s; }

fm_keepalive_log() {  # <state> <message>
  local state=$1 log
  shift
  log="$state/.keepalive.log"
  mkdir -p "$state" 2>/dev/null || return 0
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$log" 2>/dev/null || true
}

fm_keepalive_trim_log() {  # <state>
  local state=$1 log size tmp
  log="$state/.keepalive.log"
  [ -f "$log" ] || return 0
  size=$(wc -c < "$log" 2>/dev/null) || return 0
  [ "$size" -ge "${FM_KEEPALIVE_LOG_MAX_BYTES:-$FM_KEEPALIVE_LOG_MAX_BYTES_DEFAULT}" ] || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-keepalive-log.XXXXXX") || return 0
  if tail -n "${FM_KEEPALIVE_LOG_KEEP_LINES:-$FM_KEEPALIVE_LOG_KEEP_LINES_DEFAULT}" "$log" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$log" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# fm_keepalive_positive_int: sanitize one numeric knob. A blank, non-numeric, or
# negative value uses the default so a typo can never disable a bound.
fm_keepalive_positive_int() {  # <value> <default>
  local value=${1-} fallback=$2
  case "$value" in
    ''|*[!0-9]*) printf '%s' "$fallback" ;;
    *) printf '%s' "$value" ;;
  esac
}

# fm_keepalive_config_value: the effective opt-in value. FM_KEEPALIVE wins;
# otherwise the first non-empty, non-comment line of config/keepalive; otherwise
# empty (absent file = off).
fm_keepalive_config_value() {  # [config-dir]
  local config=${1:-$(fm_keepalive_config)} file line
  if [ -n "${FM_KEEPALIVE:-}" ]; then
    printf '%s' "$FM_KEEPALIVE"
    return 0
  fi
  file="$config/keepalive"
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    printf '%s' "$line"
    return 0
  done < "$file"
  return 0
}

# fm_keepalive_enabled: 0 = opted in, 1 = off, 2 = present but unrecognized.
# An unrecognized value never enables the mechanism and never silently passes as
# off either: bootstrap reports it so the typo gets fixed.
fm_keepalive_enabled() {  # [config-dir]
  local value
  value=$(fm_keepalive_config_value "${1:-}")
  case "$value" in
    on) return 0 ;;
    ''|off) return 1 ;;
    *) return 2 ;;
  esac
}

# --- durable episode state --------------------------------------------------
# .keepalive-suspect     epoch the current continuous lapse was first observed
# .keepalive-attempts    "<count><TAB><last-attempt-epoch>"
# .keepalive-gone        epoch the primary endpoint was first observed absent
# .keepalive-exhausted   the loud give-up report after the attempt cap

FM_KEEPALIVE_TAB=$'\t'

fm_keepalive_attempt_count() {  # <state>
  local state=$1 record count
  record=$(cat "$state/.keepalive-attempts" 2>/dev/null || true)
  count=${record%%"$FM_KEEPALIVE_TAB"*}
  fm_keepalive_positive_int "$count" 0
}

fm_keepalive_attempt_epoch() {  # <state>
  local state=$1 record epoch
  record=$(cat "$state/.keepalive-attempts" 2>/dev/null || true)
  case "$record" in
    *"$FM_KEEPALIVE_TAB"*) epoch=${record##*"$FM_KEEPALIVE_TAB"} ;;
    *) epoch= ;;
  esac
  fm_keepalive_positive_int "$epoch" 0
}

# fm_keepalive_marker_age: seconds since the epoch recorded INSIDE an episode
# marker, not since its mtime, so the record survives a copy or a touch and reads
# the same way the marker is written. A missing or malformed marker reads as
# ancient, which only ever delays an escalation, never a revival.
fm_keepalive_marker_age() {  # <marker-path>
  local marker=$1 recorded now
  recorded=$(cat "$marker" 2>/dev/null || true)
  recorded=$(fm_keepalive_positive_int "$recorded" 0)
  if [ "$recorded" -le 0 ]; then
    printf '999999'
    return 0
  fi
  now=$(fm_keepalive_now)
  if [ "$now" -lt "$recorded" ]; then
    printf '0'
    return 0
  fi
  printf '%s' "$((now - recorded))"
}

fm_keepalive_record_attempt() {  # <state> <count> <epoch>
  local state=$1 count=$2 epoch=$3
  mkdir -p "$state" 2>/dev/null || return 1
  printf '%s\t%s\n' "$count" "$epoch" > "$state/.keepalive-attempts"
}

fm_keepalive_clear_episode() {  # <state>
  local state=$1
  rm -f "$state/.keepalive-suspect" "$state/.keepalive-attempts" \
    "$state/.keepalive-gone" 2>/dev/null || true
}

# fm_keepalive_backoff_delay: seconds required between attempt <count> and the
# next one. Zero for the very first attempt (the confirm window already gates
# it); then base * 2^(count-1), capped at the documented ceiling.
fm_keepalive_backoff_delay() {  # <attempt-count>
  local count base max delay
  count=$(fm_keepalive_positive_int "${1-}" 0)
  base=$(fm_keepalive_positive_int "${FM_KEEPALIVE_BACKOFF_BASE:-}" "$FM_KEEPALIVE_BACKOFF_BASE_DEFAULT")
  max=$(fm_keepalive_positive_int "${FM_KEEPALIVE_BACKOFF_MAX:-}" "$FM_KEEPALIVE_BACKOFF_MAX_DEFAULT")
  if [ "$count" -le 0 ]; then
    printf '0'
    return 0
  fi
  delay=$base
  while [ "$count" -gt 1 ] && [ "$delay" -lt "$max" ]; do
    delay=$((delay * 2))
    count=$((count - 1))
  done
  [ "$delay" -gt "$max" ] && delay=$max
  printf '%s' "$delay"
}

# --- primary-pane reads -----------------------------------------------------
# Both wrappers are call sites for the shared primitives, not a second copy of
# the decision: the native busy state is asked first and a captured tail is
# matched against the verified harness signatures only when the backend reports
# unknown, exactly as the watcher, fm-crew-state.sh, and the away-mode daemon do.

fm_keepalive_primary_busy() {  # <backend> <target>
  local backend=$1 target=$2 native tail40
  native=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null)
  case "$native" in
    busy) return 0 ;;
  esac
  tail40=$(fm_backend_capture "$backend" "$target" 40 2>/dev/null) || return 1
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -12 | fm_busy_lines_match
}

fm_keepalive_composer_state() {  # <backend> <target>
  local backend=$1 target=$2 verdict
  verdict=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)
  printf '%s' "${verdict:-unknown}"
}

# fm_keepalive_session_state: what the session lock says about the primary
# harness process. "live" (a dead turn is revivable), "dead" (the whole session
# is gone), or "none" (no lock to reason about - fail closed).
fm_keepalive_session_state() {  # <state>
  local state=$1 pid
  pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) printf 'none'; return 0 ;;
  esac
  if fm_harness_pid_alive "$pid"; then
    printf 'live'
  else
    printf 'dead'
  fi
}

# --- the read-only verdict --------------------------------------------------
# Prints exactly one "<verdict>|<detail>" line and writes nothing, so a test (or
# `status`) can ask what the loop would decide without changing state.
fm_keepalive_evaluate() {  # <state> <backend> <target> [config-dir]
  local state=$1 backend=$2 target=$3 config=${4:-}
  local grace in_flight beacon session composer attempts last delay now suspect age confirm max

  fm_keepalive_enabled "$config"
  case "$?" in
    1) printf 'off|config/keepalive is not on'; return 0 ;;
    2) printf 'off|config/keepalive value is unrecognized; treated as off'; return 0 ;;
  esac

  if [ -e "$state/.afk" ]; then
    printf 'afk|away mode owns supervision and injection'
    return 0
  fi

  grace=$(fm_keepalive_positive_int "${FM_KEEPALIVE_GRACE:-}" "${FM_GUARD_GRACE:-300}")
  fm_supervision_status "$state" "$grace"
  in_flight=$FM_SUP_IN_FLIGHT
  beacon=$FM_SUP_BEACON_DESC
  if [ "$in_flight" -eq 0 ]; then
    printf 'idle|no work in flight'
    return 0
  fi
  if [ "$FM_SUP_WATCHER_FRESH" = true ]; then
    printf 'healthy|supervision beacon %s within %ss with %s task(s) in flight' \
      "$beacon" "$grace" "$in_flight"
    return 0
  fi

  session=$(fm_keepalive_session_state "$state")
  case "$session" in
    none)
      printf 'no-session|no session lock records a primary harness process'
      return 0 ;;
    dead)
      printf 'agent-gone|the session lock holder is no longer a live harness; input cannot revive it'
      return 0 ;;
  esac

  if ! fm_backend_target_exists "$backend" "$target"; then
    printf 'endpoint-gone|%s target %s does not resolve' "$backend" "$target"
    return 0
  fi
  if fm_keepalive_primary_busy "$backend" "$target"; then
    printf 'busy|the primary is mid-turn'
    return 0
  fi
  composer=$(fm_keepalive_composer_state "$backend" "$target")
  if [ "$composer" != empty ]; then
    printf 'unsafe|composer is not confirmed-empty (state=%s)' "$composer"
    return 0
  fi

  attempts=$(fm_keepalive_attempt_count "$state")
  max=$(fm_keepalive_positive_int "${FM_KEEPALIVE_MAX_ATTEMPTS:-}" "$FM_KEEPALIVE_MAX_ATTEMPTS_DEFAULT")
  if [ "$attempts" -ge "$max" ]; then
    printf 'exhausted|%s revival attempt(s) did not restore supervision (beacon %s, %s task(s) in flight)' \
      "$attempts" "$beacon" "$in_flight"
    return 0
  fi

  now=$(fm_keepalive_now)
  confirm=$(fm_keepalive_positive_int "${FM_KEEPALIVE_CONFIRM_SECS:-}" "$FM_KEEPALIVE_CONFIRM_SECS_DEFAULT")
  suspect=$(cat "$state/.keepalive-suspect" 2>/dev/null || true)
  suspect=$(fm_keepalive_positive_int "$suspect" 0)
  if [ "$suspect" -eq 0 ]; then
    printf 'confirming|first observation of a lapse (beacon %s); confirming for %ss' "$beacon" "$confirm"
    return 0
  fi
  age=$(fm_keepalive_marker_age "$state/.keepalive-suspect")
  if [ "$age" -lt "$confirm" ]; then
    printf 'confirming|lapse held %ss of the %ss confirm window (beacon %s)' "$age" "$confirm" "$beacon"
    return 0
  fi

  last=$(fm_keepalive_attempt_epoch "$state")
  delay=$(fm_keepalive_backoff_delay "$attempts")
  if [ "$attempts" -gt 0 ] && [ "$last" -gt 0 ] && [ $((now - last)) -lt "$delay" ]; then
    printf 'backoff|attempt %s waits %ss between attempts, %ss elapsed' \
      "$((attempts + 1))" "$delay" "$((now - last))"
    return 0
  fi

  printf 'revive|supervision lapsed %s with %s task(s) in flight; attempt %s of %s' \
    "$beacon" "$in_flight" "$((attempts + 1))" "$max"
}

# --- revival ----------------------------------------------------------------
# The injected body must tell the primary what happened, what to do, and that
# nothing about its authority changed. Single line, because submission is
# send-text plus Enter and embedded newlines are ambiguous in a TUI composer.
fm_keepalive_revive_body() {  # <attempt> <max> <detail>
  local attempt=$1 max=$2 detail=$3
  printf '%s' "Automatic session revival ${attempt} of ${max}: the previous turn ended without handing supervision back (${detail}). Resume supervision now - drain queued wakes with bin/fm-wake-drain.sh, reconcile in-flight work from the durable records, and re-arm the supervision cycle for this harness. Do not start new work, and do not re-do work a durable record already shows as finished. This revival grants no authority: merges, ask-user decisions, and anything destructive, irreversible, or security-sensitive keep exactly the approval they had before."
}

# fm_keepalive_inject: type the revival input once and submit it. Returns 0 only
# when the backend confirms the submit; an unconfirmed submit leaves the text in
# the composer, which the next tick reads as a non-empty composer and defers on,
# so a swallowed Enter can never concatenate two revival inputs.
fm_keepalive_inject() {  # <backend> <target> <body>
  local backend=$1 target=$2 body=$3 encoded retries sleep_s verdict
  body=${body//$'\n'/ - }
  fm_operational_input_encode session-revive "$body" encoded || return 1
  retries=$(fm_keepalive_positive_int "${FM_KEEPALIVE_SUBMIT_RETRIES:-}" "$FM_KEEPALIVE_SUBMIT_RETRIES_DEFAULT")
  sleep_s=${FM_KEEPALIVE_SUBMIT_SLEEP:-$FM_KEEPALIVE_SUBMIT_SLEEP_DEFAULT}
  verdict=$(fm_backend_send_text_submit "$backend" "$target" "$encoded" "$retries" "$sleep_s" "$sleep_s")
  [ "$verdict" = empty ]
}

fm_keepalive_write_exhausted() {  # <state> <detail>
  local state=$1 detail=$2 marker
  marker="$state/.keepalive-exhausted"
  [ -e "$marker" ] && return 0
  {
    printf 'fm session revival EXHAUSTED as of %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf '%s\n' "$detail"
    printf 'The primary session did not resume supervision after the attempt cap.\n'
    printf 'Nothing was discarded: queued wakes, task records, and crew work all survive.\n'
  } > "$marker" 2>/dev/null || return 1
  fm_keepalive_log "$state" "ERROR: revival exhausted - $detail"
}

# fm_keepalive_tick: evaluate, then perform this verdict's durable bookkeeping
# and, for a "revive" verdict, the injection. Prints the acted-on verdict line,
# which is "revived" or "revive-failed" once an injection was attempted.
fm_keepalive_tick() {  # <state> <backend> <target> [config-dir]
  local state=$1 backend=$2 target=$3 config=${4:-}
  local line verdict detail attempts max body now confirm
  line=$(fm_keepalive_evaluate "$state" "$backend" "$target" "$config")
  verdict=${line%%|*}
  detail=${line#*|}
  case "$verdict" in
    healthy)
      if [ -e "$state/.keepalive-suspect" ] || [ -e "$state/.keepalive-attempts" ] \
        || [ -e "$state/.keepalive-exhausted" ]; then
        fm_keepalive_log "$state" "recovered: $detail"
        rm -f "$state/.keepalive-exhausted" 2>/dev/null || true
      fi
      fm_keepalive_clear_episode "$state"
      ;;
    off|no-session|idle|afk)
      fm_keepalive_clear_episode "$state"
      ;;
    agent-gone|endpoint-gone)
      # An absent session process or endpoint is confirmed the same way a lapse
      # is: one continuous confirm window, because a transient `ps` or backend
      # read failure must not produce a scary report or end the loop. Only a
      # confirmed absent session process is reported, since nothing can revive it.
      rm -f "$state/.keepalive-suspect" 2>/dev/null || true
      if [ -e "$state/.keepalive-gone" ]; then
        confirm=$(fm_keepalive_positive_int "${FM_KEEPALIVE_CONFIRM_SECS:-}" "$FM_KEEPALIVE_CONFIRM_SECS_DEFAULT")
        if [ "$verdict" = agent-gone ] && [ "$(fm_keepalive_marker_age "$state/.keepalive-gone")" -ge "$confirm" ]; then
          fm_keepalive_write_exhausted "$state" "$detail" || true
        fi
      else
        fm_keepalive_now > "$state/.keepalive-gone" 2>/dev/null || true
      fi
      ;;
    busy|unsafe)
      # The session is alive or its composer is not ours to type into: the
      # continuous-lapse window restarts, while durable attempt state stays so a
      # revived-then-re-died turn keeps growing its backoff.
      rm -f "$state/.keepalive-suspect" "$state/.keepalive-gone" 2>/dev/null || true
      ;;
    confirming)
      rm -f "$state/.keepalive-gone" 2>/dev/null || true
      [ -e "$state/.keepalive-suspect" ] || fm_keepalive_now > "$state/.keepalive-suspect" 2>/dev/null || true
      ;;
    exhausted)
      fm_keepalive_write_exhausted "$state" "$detail" || true
      ;;
    backoff)
      ;;
    revive)
      attempts=$(fm_keepalive_attempt_count "$state")
      max=$(fm_keepalive_positive_int "${FM_KEEPALIVE_MAX_ATTEMPTS:-}" "$FM_KEEPALIVE_MAX_ATTEMPTS_DEFAULT")
      attempts=$((attempts + 1))
      now=$(fm_keepalive_now)
      fm_keepalive_record_attempt "$state" "$attempts" "$now" || true
      rm -f "$state/.keepalive-suspect" 2>/dev/null || true
      body=$(fm_keepalive_revive_body "$attempts" "$max" "$detail")
      if fm_keepalive_inject "$backend" "$target" "$body"; then
        fm_keepalive_log "$state" "revived: attempt $attempts of $max - $detail"
        line="revived|attempt $attempts of $max submitted: $detail"
      else
        fm_keepalive_log "$state" "revival attempt $attempts of $max could not confirm a submit - $detail"
        line="revive-failed|attempt $attempts of $max could not confirm a submit: $detail"
      fi
      ;;
  esac
  printf '%s' "$line"
}

# --- loop lifecycle ---------------------------------------------------------

fm_keepalive_lock_path() { printf '%s' "$1/.keepalive.lock"; }

fm_keepalive_lock_pid() {  # <state>
  cat "$(fm_keepalive_lock_path "$1")/pid" 2>/dev/null || true
}

# fm_keepalive_live: 0 when the singleton lock is held by a live process whose
# recorded identity still matches, so a reused pid cannot look like a live loop.
fm_keepalive_live() {  # <state>
  local state=$1 lock pid expected actual
  lock=$(fm_keepalive_lock_path "$state")
  [ -d "$lock" ] || return 1
  pid=$(cat "$lock/pid" 2>/dev/null) || return 1
  fm_pid_alive "$pid" || return 1
  expected=$(cat "$lock/pid-identity" 2>/dev/null || true)
  [ -n "$expected" ] || return 0
  actual=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ "$actual" = "$expected" ]
}

fm_keepalive_resolve_endpoint() {  # sets FM_KEEPALIVE_BACKEND / FM_KEEPALIVE_TARGET
  FM_KEEPALIVE_BACKEND=$(discover_supervisor_backend) || true
  FM_KEEPALIVE_TARGET=$(discover_supervisor_target) || true
  if ! fm_backend_list_contains "$FM_KEEPALIVE_SUPPORTED_BACKENDS" "$FM_KEEPALIVE_BACKEND"; then
    printf 'fm-keepalive: supervisor backend %s has no verified primary-injection primitives (supported: %s)\n' \
      "$FM_KEEPALIVE_BACKEND" "$FM_KEEPALIVE_SUPPORTED_BACKENDS" >&2
    return 1
  fi
  [ -n "$FM_KEEPALIVE_TARGET" ] || {
    printf 'fm-keepalive: could not resolve the primary pane; set FM_SUPERVISOR_TARGET\n' >&2
    return 1
  }
}

fm_keepalive_run() {
  local state config backend target poll gone_exit line verdict gone_age
  state=$(fm_keepalive_state)
  config=$(fm_keepalive_config)
  mkdir -p "$state" 2>/dev/null || {
    printf 'fm-keepalive: cannot create state directory %s\n' "$state" >&2
    return 1
  }
  if ! fm_keepalive_enabled "$config"; then
    printf 'fm-keepalive: not opted in (config/keepalive is not on); nothing to run\n' >&2
    return 1
  fi
  fm_keepalive_resolve_endpoint || return 1
  backend=$FM_KEEPALIVE_BACKEND
  target=$FM_KEEPALIVE_TARGET
  if ! fm_backend_target_exists "$backend" "$target"; then
    printf 'fm-keepalive: primary target %s does not resolve to a %s pane\n' "$target" "$backend" >&2
    return 1
  fi
  local lock
  lock=$(fm_keepalive_lock_path "$state")
  if ! fm_lock_try_acquire "$lock"; then
    printf 'fm-keepalive: already running (lock %s held)\n' "$lock" >&2
    return 0
  fi
  fm_pid_identity "${BASHPID:-$$}" > "$lock/pid-identity" 2>/dev/null || true
  # shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
  fm_keepalive_cleanup() {
    trap - TERM INT
    fm_lock_release "$lock" 2>/dev/null || true
    fm_keepalive_log "$state" "loop stopping"
    exit 0
  }
  trap fm_keepalive_cleanup TERM INT

  poll=$(fm_keepalive_positive_int "${FM_KEEPALIVE_POLL:-}" "$FM_KEEPALIVE_POLL_DEFAULT")
  gone_exit=$(fm_keepalive_positive_int "${FM_KEEPALIVE_GONE_EXIT_SECS:-}" "$FM_KEEPALIVE_GONE_EXIT_SECS_DEFAULT")
  fm_keepalive_log "$state" "loop starting (pid $$); backend=$backend target=$target poll=${poll}s"
  while :; do
    if ! fm_keepalive_enabled "$config"; then
      fm_keepalive_log "$state" "standing down: config/keepalive is no longer on"
      fm_lock_release "$lock" 2>/dev/null || true
      return 0
    fi
    line=$(fm_keepalive_tick "$state" "$backend" "$target" "$config")
    verdict=${line%%|*}
    case "$verdict" in
      revive|revived|revive-failed|exhausted|agent-gone) fm_keepalive_log "$state" "tick: $line" ;;
    esac
    # Standing down is correct exactly when there is nothing left to revive: a
    # confirmed-absent session process can never accept input again, and an
    # endpoint absent this long is a closed window, not a dead turn. Both leave
    # their durable records behind for the next session.
    if [ "$verdict" = agent-gone ] && [ -e "$state/.keepalive-exhausted" ]; then
      fm_keepalive_log "$state" "standing down: the primary session process is gone"
      fm_lock_release "$lock" 2>/dev/null || true
      return 0
    fi
    if [ "$verdict" = endpoint-gone ] && [ -e "$state/.keepalive-gone" ]; then
      gone_age=$(fm_keepalive_marker_age "$state/.keepalive-gone")
      if [ "$gone_age" -ge "$gone_exit" ]; then
        fm_keepalive_log "$state" "standing down: primary endpoint absent for ${gone_age}s"
        fm_lock_release "$lock" 2>/dev/null || true
        return 0
      fi
    fi
    fm_keepalive_trim_log "$state"
    sleep "$poll"
  done
}

# --- non-visible terminal for the loop --------------------------------------
# Same shape as the away-mode daemon's launcher (bin/fm-afk-launch.sh, the owner
# of that rationale): create a terminal that never touches the captain's active
# tab, capture the PRIMARY pane BEFORE creating it, and pass that pane in so the
# loop injects into the primary instead of discovering its own new pane. Never
# shell `&`, which herdr and codex can reap.

fm_keepalive_record_path() { printf '%s' "$1/.keepalive-terminal"; }

fm_keepalive_record_write() {  # <state> <backend> <target> <extra>
  local state=$1 pending
  pending=$(mktemp "$state/.keepalive-terminal.pending.XXXXXX") || return 1
  printf '%s\t%s\t%s\n' "$2" "$3" "$4" > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$(fm_keepalive_record_path "$state")" || { rm -f "$pending"; return 1; }
}

# Exit 0 with the recorded backend/target, 1 when no record exists, 2 when the
# record is malformed. A malformed record is never guessed at: its caller refuses
# rather than closing or creating a terminal it cannot identify exactly.
fm_keepalive_record_read() {  # <state>; sets FM_KEEPALIVE_REC_BACKEND / _TARGET
  local record
  FM_KEEPALIVE_REC_BACKEND=""
  FM_KEEPALIVE_REC_TARGET=""
  record=$(fm_keepalive_record_path "$1")
  [ -f "$record" ] || return 1
  IFS=$'\t' read -r FM_KEEPALIVE_REC_BACKEND FM_KEEPALIVE_REC_TARGET _ < "$record" || return 2
  [ -n "$FM_KEEPALIVE_REC_BACKEND" ] && [ -n "$FM_KEEPALIVE_REC_TARGET" ] || return 2
  case "$FM_KEEPALIVE_REC_BACKEND" in
    tmux|herdr) return 0 ;;
    *) return 2 ;;
  esac
}

fm_keepalive_close_terminal() {  # <backend> <target>
  local backend=$1 target=$2 session pane
  case "$backend" in
    tmux) tmux kill-session -t "$target" 2>/dev/null ;;
    herdr)
      fm_backend_source herdr || return 1
      session=${target%%:*}
      pane=${target#*:}
      [ -n "$session" ] && [ -n "$pane" ] && [ "$pane" != "$target" ] || return 1
      fm_backend_herdr_cli "$session" pane close "$pane" >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

fm_keepalive_entry_cmd() {
  printf '%s' "${FM_KEEPALIVE_ENTRY:-$FM_ROOT/bin/fm-keepalive.sh run}"
}

fm_keepalive_launch_cmd() {  # <primary-target> <primary-backend>
  printf 'exec env FM_HOME=%q FM_SUPERVISOR_TARGET=%q FM_SUPERVISOR_BACKEND=%q %s' \
    "$FM_HOME" "$1" "$2" "$(fm_keepalive_entry_cmd)"
}

fm_keepalive_wait_ready() {  # <state>
  local state=$1 attempt=0
  [ -z "${FM_KEEPALIVE_ENTRY:-}" ] || return 0
  while [ "$attempt" -lt 100 ]; do
    fm_keepalive_live "$state" && return 0
    sleep 0.05
    attempt=$((attempt + 1))
  done
  return 1
}

fm_keepalive_create_tmux() {  # <state> <primary-target> <primary-backend>
  local state=$1 primary_target=$2 primary_backend=$3 session hash nonce
  hash=$(printf '%s' "$FM_HOME" | cksum | cut -d' ' -f1)
  nonce="$$-${RANDOM:-0}-$(fm_keepalive_now)"
  session="fm-keepalive-$hash-$nonce"
  fm_keepalive_record_write "$state" tmux "$session" "" || return 1
  if ! tmux new-session -d -s "$session" "$(fm_keepalive_launch_cmd "$primary_target" "$primary_backend")" 2>/dev/null; then
    rm -f "$(fm_keepalive_record_path "$state")" 2>/dev/null || true
    printf 'fm-keepalive: could not create the detached tmux session %s\n' "$session" >&2
    return 1
  fi
  if ! fm_keepalive_wait_ready "$state"; then
    printf 'fm-keepalive: the loop did not start; closing %s\n' "$session" >&2
    fm_keepalive_close_terminal tmux "$session"
    rm -f "$(fm_keepalive_record_path "$state")" 2>/dev/null || true
    return 1
  fi
  printf 'fm-keepalive: watching %s from detached tmux session %s\n' "$primary_target" "$session"
}

fm_keepalive_create_herdr() {  # <state> <primary-target> <primary-backend>
  local state=$1 primary_target=$2 primary_backend=$3 session out wsid pane label
  session=${primary_target%%:*}
  if [ -z "$session" ] || [ "$session" = "$primary_target" ]; then
    printf 'fm-keepalive: cannot derive a herdr session from primary target %s\n' "$primary_target" >&2
    return 1
  fi
  fm_backend_source herdr || return 1
  fm_backend_herdr_server_ensure "$session" || {
    printf 'fm-keepalive: herdr server is not ready for session %s\n' "$session" >&2
    return 1
  }
  label="$FM_KEEPALIVE_WS_LABEL-$$-${RANDOM:-0}-$(fm_keepalive_now)"
  out=$(fm_backend_herdr_cli "$session" workspace create --cwd "$FM_HOME" --label "$label" --no-focus 2>/dev/null)
  wsid=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$wsid" ] || [ -z "$pane" ]; then
    printf 'fm-keepalive: herdr did not return an exact workspace and pane id\n' >&2
    return 1
  fi
  fm_keepalive_record_write "$state" herdr "$session:$pane" "$wsid" || {
    fm_keepalive_close_terminal herdr "$session:$pane"
    return 1
  }
  if ! fm_backend_herdr_cli "$session" pane run "$pane" \
    "$(fm_keepalive_launch_cmd "$primary_target" "$primary_backend")" >/dev/null 2>&1; then
    printf 'fm-keepalive: could not run the loop in herdr pane %s:%s\n' "$session" "$pane" >&2
    fm_keepalive_close_terminal herdr "$session:$pane"
    rm -f "$(fm_keepalive_record_path "$state")" 2>/dev/null || true
    return 1
  fi
  if ! fm_keepalive_wait_ready "$state"; then
    printf 'fm-keepalive: the loop did not start; closing herdr pane %s:%s\n' "$session" "$pane" >&2
    fm_keepalive_close_terminal herdr "$session:$pane"
    rm -f "$(fm_keepalive_record_path "$state")" 2>/dev/null || true
    return 1
  fi
  printf 'fm-keepalive: watching %s from non-visible herdr workspace %s\n' "$primary_target" "$wsid"
}

fm_keepalive_start() {
  local state config backend target
  state=$(fm_keepalive_state)
  config=$(fm_keepalive_config)
  mkdir -p "$state" 2>/dev/null || return 1
  if ! fm_keepalive_enabled "$config"; then
    printf 'fm-keepalive: not opted in (config/keepalive is not on); nothing started\n' >&2
    return 1
  fi
  if fm_keepalive_live "$state"; then
    printf 'fm-keepalive: already running (pid %s)\n' "$(fm_keepalive_lock_pid "$state")"
    return 0
  fi
  # A recorded terminal with no live loop is a leak from a crash: close it by its
  # exact recorded id before creating another one.
  fm_keepalive_record_read "$state"
  case "$?" in
    0)
      fm_keepalive_close_terminal "$FM_KEEPALIVE_REC_BACKEND" "$FM_KEEPALIVE_REC_TARGET" || true
      rm -f "$(fm_keepalive_record_path "$state")" 2>/dev/null || true
      ;;
    2)
      printf 'fm-keepalive: the recorded terminal id is malformed; resolve %s before starting\n' \
        "$(fm_keepalive_record_path "$state")" >&2
      return 1
      ;;
  esac
  fm_keepalive_resolve_endpoint || return 1
  backend=$FM_KEEPALIVE_BACKEND
  target=$FM_KEEPALIVE_TARGET
  case "$backend" in
    tmux) fm_keepalive_create_tmux "$state" "$target" "$backend" ;;
    herdr) fm_keepalive_create_herdr "$state" "$target" "$backend" ;;
    *)
      printf 'fm-keepalive: no non-visible launch primitive for backend %s\n' "$backend" >&2
      return 1 ;;
  esac
}

fm_keepalive_stop() {
  local state pid result=0
  state=$(fm_keepalive_state)
  pid=""
  if fm_keepalive_live "$state"; then
    pid=$(fm_keepalive_lock_pid "$state")
    kill -TERM "$pid" 2>/dev/null || result=1
    local waited=0
    while [ "$waited" -lt 40 ]; do
      fm_pid_alive "$pid" || break
      sleep 0.25
      waited=$((waited + 1))
    done
  fi
  fm_keepalive_record_read "$state"
  case "$?" in
    0)
      fm_keepalive_close_terminal "$FM_KEEPALIVE_REC_BACKEND" "$FM_KEEPALIVE_REC_TARGET" || result=1
      rm -f "$(fm_keepalive_record_path "$state")" 2>/dev/null || result=1
      ;;
    2)
      printf 'fm-keepalive: the recorded terminal id is malformed; not guessing which terminal to close\n' >&2
      result=1
      ;;
  esac
  if [ "$result" -eq 0 ]; then
    printf 'fm-keepalive: stopped\n'
  else
    printf 'fm-keepalive: stop incomplete; the recorded terminal is preserved for retry\n' >&2
  fi
  return "$result"
}

fm_keepalive_status() {
  local state config backend target
  state=$(fm_keepalive_state)
  config=$(fm_keepalive_config)
  if fm_keepalive_live "$state"; then
    printf 'loop: running pid %s\n' "$(fm_keepalive_lock_pid "$state")"
  else
    printf 'loop: not running\n'
  fi
  if fm_keepalive_enabled "$config"; then
    printf 'config: on\n'
  else
    printf 'config: off (value=%s)\n' "$(fm_keepalive_config_value "$config")"
  fi
  printf 'attempts: %s (last %s)\n' \
    "$(fm_keepalive_attempt_count "$state")" "$(fm_keepalive_attempt_epoch "$state")"
  [ -e "$state/.keepalive-exhausted" ] && printf 'exhausted: %s\n' "$state/.keepalive-exhausted"
  if fm_keepalive_resolve_endpoint 2>/dev/null; then
    backend=$FM_KEEPALIVE_BACKEND
    target=$FM_KEEPALIVE_TARGET
    printf 'verdict: %s\n' "$(fm_keepalive_evaluate "$state" "$backend" "$target" "$config")"
  else
    printf 'verdict: unavailable (no resolvable primary pane)\n'
  fi
  return 0
}

fm_keepalive_usage() {
  sed -n '/^# Usage:/,/^# This file is sourceable/p' "${BASH_SOURCE[0]}" \
    | sed '$d' | sed 's/^# \{0,1\}//'
}

fm_keepalive_main() {
  local state config backend target
  # Read-only verbs stay available everywhere; anything that can arm, drive, or
  # retire the loop refuses from a no-mistakes gate context before acting.
  case "${1:-status}" in
    start|run|stop|tick) fm_refuse_if_gate_agent ;;
  esac
  case "${1:-status}" in
    -h|--help|help) fm_keepalive_usage ;;
    start) fm_keepalive_start ;;
    run) fm_keepalive_run ;;
    stop) fm_keepalive_stop ;;
    status) fm_keepalive_status ;;
    config-check)
      fm_keepalive_enabled "$(fm_keepalive_config)"
      return $?
      ;;
    tick|evaluate)
      state=$(fm_keepalive_state)
      config=$(fm_keepalive_config)
      fm_keepalive_resolve_endpoint || return 1
      backend=$FM_KEEPALIVE_BACKEND
      target=$FM_KEEPALIVE_TARGET
      if [ "$1" = tick ]; then
        fm_keepalive_tick "$state" "$backend" "$target" "$config"
      else
        fm_keepalive_evaluate "$state" "$backend" "$target" "$config"
      fi
      printf '\n'
      ;;
    *) fm_keepalive_usage >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_keepalive_main "$@"
  exit $?
fi
