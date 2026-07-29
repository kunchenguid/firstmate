#!/usr/bin/env bash
# fm-quota-watch.sh - lightweight, agent-free Claude quota gate for this
# firstmate home.
#
# Runs from an OS-level scheduler (crontab or launchd), NOT from the `schedule`
# or `loop` skills - both of those dispatch a real model turn per firing, which
# is exactly the cost this script exists to avoid. It never launches an agent
# or a model turn itself: only `quota-axi --json` (a data-only CLI query), file
# reads/writes under this home's own `state/`, and `bin/fm-send.sh` key/text
# delivery to already-running crewmate panes.
#
# What it does, once per invocation:
#   1. Read current claude quota via `quota-axi --provider claude --json` and
#      take the MAX percentUsed across all reported windows (session/weekly/
#      credits): if any window is close to exhausted, further turns are
#      constrained, so the tightest window governs the pause decision.
#   2. No usable reading (tool missing, auth_required, malformed output, empty
#      windows) is treated as "nothing to do" - never a pause, never a crash.
#   3. pct >= pause threshold (default 80, see below): interrupt every LIVE
#      kind=ship/kind=scout crewmate of THIS home (never kind=secondmate, which
#      has its own lifecycle per AGENTS.md section 6, and never touches
#      projects/) with its harness's verified interrupt key
#      (.agents/skills/harness-adapters/SKILL.md), send it nothing further, and
#      record the pause both durably (state/.quota-paused) and on the crew's own
#      status log using the EXISTING `paused: <reason>` verb
#      (bin/fm-classify-lib.sh, AGENTS.md section 8) - this is what makes a live
#      firstmate/watcher treat the idle pane as an expected wait instead of a
#      stale wedge, with no separate supervision code needed: fm-crew-state.sh
#      already re-reads the live pane/run-step BEFORE trusting that status line,
#      so a crew that resumed and started working again is never stuck reading
#      as paused.
#   4. pct < resume threshold (default 65, hysteresis below the pause
#      threshold so a reading oscillating near 80 does not flap): send one
#      short note to every crewmate THIS script paused (recorded in
#      state/.quota-paused) and clear the flag. A crewmate this script did not
#      pause (e.g. a pre-existing declared external-wait `paused:`) is left
#      alone.
#   5. Otherwise (below pause threshold with no flag, or inside the hysteresis
#      band while already paused): no-op.
#
# Idempotent: rerunning while still above the pause threshold does not resend
# interrupts to already-recorded crew and does not duplicate the flag: it only
# picks up crew spawned since the last pause (still-live, not yet recorded).
# Rerunning below the resume threshold with no flag present is a silent no-op.
#
# Configuration (env wins, then local gitignored config/ file, then default):
#   FM_QUOTA_PAUSE_THRESHOLD / config/quota-pause-threshold   (default 80)
#   FM_QUOTA_RESUME_THRESHOLD / config/quota-resume-threshold (default 65)
# Both accept a bare integer 0-100; an invalid value, or a resume threshold not
# strictly below the pause threshold, falls back to the defaults with a
# stderr warning rather than misbehaving quietly.
#
# Test seams (mirrors FM_CREW_STATE_BIN elsewhere in this codebase):
#   FM_QUOTA_AXI_BIN   quota reader command, default `quota-axi` off PATH.
#   FM_QUOTA_SEND_BIN  crewmate sender, default the sibling fm-send.sh.
# Standard overrides also apply: FM_HOME, FM_ROOT_OVERRIDE, FM_STATE_OVERRIDE,
# FM_CONFIG_OVERRIDE.
#
# Usage:
#   fm-quota-watch.sh            run one check-and-act cycle
#   fm-quota-watch.sh --status   print resolved config and current reading;
#                                 take no action (for verifying cron setup)
#   fm-quota-watch.sh --help
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME
[ -n "${FM_ROOT_OVERRIDE:-}" ] && export FM_ROOT_OVERRIDE
[ -n "${FM_STATE_OVERRIDE:-}" ] && export FM_STATE_OVERRIDE
[ -n "${FM_CONFIG_OVERRIDE:-}" ] && export FM_CONFIG_OVERRIDE

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

FM_QUOTA_AXI_BIN="${FM_QUOTA_AXI_BIN:-quota-axi}"
FM_QUOTA_SEND_BIN="${FM_QUOTA_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}"
PAUSE_FLAG="$STATE/.quota-paused"

fm_quota_watch_usage() {
  sed -n '2,58{s/^# \{0,1\}//;p;}' "$SCRIPT_DIR/fm-quota-watch.sh"
}

STATUS_ONLY=0
case "${1:-}" in
  --help|-h) fm_quota_watch_usage; exit 0 ;;
  --status) STATUS_ONLY=1 ;;
  '') ;;
  *) echo "fm-quota-watch.sh: unknown argument '$1' (see --help)" >&2; exit 2 ;;
esac

if [ ! -d "$STATE" ]; then
  echo "fm-quota-watch.sh: state dir '$STATE' is missing; nothing to watch" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "fm-quota-watch.sh: jq is required and was not found on PATH" >&2
  exit 127
fi

# --- configuration -----------------------------------------------------------

# First non-empty, non-comment line of config/<name>, mirroring the
# config/backend / config/crew-harness reading convention (docs/configuration.md).
fm_quota_watch_config_value() {  # <filename>
  local f="$CONFIG/$1" line
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    printf '%s' "$line"
    return 0
  done < "$f"
}

# Clamp to a plain integer 0-100, else print the given default.
fm_quota_watch_validate_pct() {  # <value> <default>
  case "$1" in
    ''|*[!0-9]*) printf '%s' "$2"; return ;;
  esac
  if [ "$1" -gt 100 ]; then
    printf '%s' "$2"
  else
    printf '%s' "$1"
  fi
}

PAUSE_THRESHOLD=${FM_QUOTA_PAUSE_THRESHOLD:-$(fm_quota_watch_config_value quota-pause-threshold)}
[ -n "$PAUSE_THRESHOLD" ] || PAUSE_THRESHOLD=80
RESUME_THRESHOLD=${FM_QUOTA_RESUME_THRESHOLD:-$(fm_quota_watch_config_value quota-resume-threshold)}
[ -n "$RESUME_THRESHOLD" ] || RESUME_THRESHOLD=65
PAUSE_THRESHOLD=$(fm_quota_watch_validate_pct "$PAUSE_THRESHOLD" 80)
RESUME_THRESHOLD=$(fm_quota_watch_validate_pct "$RESUME_THRESHOLD" 65)
if [ "$RESUME_THRESHOLD" -ge "$PAUSE_THRESHOLD" ]; then
  echo "fm-quota-watch.sh: configured resume threshold ($RESUME_THRESHOLD) must be strictly below the pause threshold ($PAUSE_THRESHOLD); falling back to defaults 65/80" >&2
  PAUSE_THRESHOLD=80
  RESUME_THRESHOLD=65
fi

# --- quota reading ------------------------------------------------------------

if ! FM_QUOTA_AXI_RESOLVED=$(command -v "$FM_QUOTA_AXI_BIN" 2>/dev/null); then
  echo "fm-quota-watch.sh: '$FM_QUOTA_AXI_BIN' not found on PATH; no quota data available, nothing to do (cron/launchd PATH may need extending - see docs)" >&2
  exit 0
fi

QUOTA_JSON=$("$FM_QUOTA_AXI_RESOLVED" --provider claude --json 2>/dev/null)
# Max percentUsed across every reported claude window. Empty output means no
# usable window was reported (auth_required, error, or malformed JSON) - the
# jq filter itself never fails loudly, it just yields nothing to act on.
PCT=$(printf '%s' "$QUOTA_JSON" | jq -r '
  ([.providers[]? | select(.provider=="claude") | .windows[]?.percentUsed | numbers]
   | if length > 0 then (max | floor | tostring) else empty end)
' 2>/dev/null)

if [ "$STATUS_ONLY" -eq 1 ]; then
  echo "fm-quota-watch.sh: pause_threshold=$PAUSE_THRESHOLD resume_threshold=$RESUME_THRESHOLD"
  if [ -n "$PCT" ]; then
    echo "fm-quota-watch.sh: current claude usage pct=$PCT"
  else
    echo "fm-quota-watch.sh: no usable claude quota reading right now (auth_required, missing tool, or malformed output)"
  fi
  if [ -f "$PAUSE_FLAG" ]; then
    echo "fm-quota-watch.sh: fleet is currently quota-paused:"
    sed 's/^/  /' "$PAUSE_FLAG"
  else
    echo "fm-quota-watch.sh: fleet is not quota-paused"
  fi
  exit 0
fi

if [ -z "$PCT" ]; then
  echo "fm-quota-watch.sh: no usable claude quota reading (auth_required, missing tool, or malformed output); leaving fleet state unchanged" >&2
  exit 0
fi

# --- crew enumeration ---------------------------------------------------------

# task=<id> lines already recorded in the pause flag, one per line.
fm_quota_watch_flag_tasks() {
  [ -f "$PAUSE_FLAG" ] || return 0
  grep '^task=' "$PAUSE_FLAG" 2>/dev/null | cut -d= -f2-
}

fm_quota_watch_in_list() {  # <needle> <newline-separated-haystack>
  printf '%s\n' "$2" | grep -qxF "$1"
}

# Send this harness's verified single interrupt action (harness-adapters
# SKILL.md). Refuses rather than guessing for an unrecognized/empty harness.
fm_quota_watch_interrupt() {  # <task-id> <harness>
  local id=$1 harness=$2
  case "$harness" in
    claude|codex|pi|pi-signed|kimi)
      "$FM_QUOTA_SEND_BIN" "$id" --key Escape
      ;;
    opencode)
      "$FM_QUOTA_SEND_BIN" "$id" --key Escape && "$FM_QUOTA_SEND_BIN" "$id" --key Escape
      ;;
    grok)
      "$FM_QUOTA_SEND_BIN" "$id" --key C-c
      ;;
    *)
      echo "fm-quota-watch.sh: unrecognized harness '$harness' for $id; refusing to guess an interrupt key" >&2
      return 1
      ;;
  esac
}

fm_quota_watch_pause() {
  local pct=$1 now paused_at prior_paused_at existing_tasks tmp_flag meta id kind harness
  now=$(date +%s)
  paused_at=$now
  if [ -f "$PAUSE_FLAG" ]; then
    prior_paused_at=$(fm_meta_get "$PAUSE_FLAG" paused_at)
    [ -n "$prior_paused_at" ] && paused_at=$prior_paused_at
  fi
  existing_tasks=$(fm_quota_watch_flag_tasks)

  tmp_flag=$(mktemp "${TMPDIR:-/tmp}/fm-quota-paused.XXXXXX") || return 1
  {
    printf 'paused_at=%s\n' "$paused_at"
    printf 'pct=%s\n' "$pct"
  } > "$tmp_flag"

  local acted=0 kept=0
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    kind=$(fm_meta_get "$meta" kind)
    case "$kind" in ship|scout) ;; *) continue ;; esac
    id=$(basename "$meta" .meta)

    if fm_quota_watch_in_list "$id" "$existing_tasks"; then
      printf 'task=%s\n' "$id" >> "$tmp_flag"
      kept=$((kept + 1))
      continue
    fi

    harness=$(fm_meta_get "$meta" harness)
    if fm_quota_watch_interrupt "$id" "$harness"; then
      printf 'paused: quota at %s%%, auto-resume when it clears\n' "$pct" >> "$STATE/$id.status"
      printf 'task=%s\n' "$id" >> "$tmp_flag"
      acted=$((acted + 1))
    else
      echo "fm-quota-watch.sh: warning: could not interrupt $id (harness=${harness:-<unset>}); leaving it unmanaged" >&2
    fi
  done

  mv "$tmp_flag" "$PAUSE_FLAG"
  echo "fm-quota-watch.sh: pct=$pct >= pause threshold $PAUSE_THRESHOLD - paused $acted new crew, $kept already paused"
}

fm_quota_watch_resume() {
  local pct=$1 id meta acted=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    meta="$STATE/$id.meta"
    if [ ! -f "$meta" ]; then
      echo "fm-quota-watch.sh: $id has no metadata anymore (torn down while paused); skipping resume send" >&2
      continue
    fi
    if "$FM_QUOTA_SEND_BIN" "$id" "Quota recovered (now ${pct}% used, below the ${RESUME_THRESHOLD}% resume threshold). Continue where you left off."; then
      acted=$((acted + 1))
    else
      echo "fm-quota-watch.sh: warning: could not deliver the resume message to $id" >&2
    fi
  done < <(fm_quota_watch_flag_tasks)
  rm -f "$PAUSE_FLAG"
  echo "fm-quota-watch.sh: pct=$pct < resume threshold $RESUME_THRESHOLD - resumed $acted crew, cleared the pause"
}

# --- act -----------------------------------------------------------------

if [ "$PCT" -ge "$PAUSE_THRESHOLD" ]; then
  fm_quota_watch_pause "$PCT"
elif [ -f "$PAUSE_FLAG" ]; then
  if [ "$PCT" -lt "$RESUME_THRESHOLD" ]; then
    fm_quota_watch_resume "$PCT"
  else
    echo "fm-quota-watch.sh: pct=$PCT inside hysteresis band [$RESUME_THRESHOLD,$PAUSE_THRESHOLD) - still paused, waiting to drop below $RESUME_THRESHOLD"
  fi
else
  echo "fm-quota-watch.sh: pct=$PCT below pause threshold $PAUSE_THRESHOLD - nothing to do"
fi
