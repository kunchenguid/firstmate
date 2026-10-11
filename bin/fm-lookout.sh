#!/usr/bin/env bash
# fm-lookout.sh - a second mate's lookout on the flagship: another vessel
# watching the primary home's watcher while the captain is away.
#
# A second mate whose charter carries the lookout duty (bin/fm-brief.sh
# --lookout) stands it with `stand`, which registers `watch` as a custom check
# in its own home (bin/fm-check-register.sh), so the mate's ordinary watcher
# runs it on every check sweep (FM_CHECK_INTERVAL, 300 s by default). Each
# `watch` reads the flagship's watcher beacon (state/.last-watcher-beat) and
# away posture over SSH, and while the flagship is away it acts:
#
#   beacon fresh        nothing, beyond ending an earlier episode
#   beacon stale        record it on both vessels, then restart the flagship's
#                       watcher with `recover`, retrying with backoff; on a
#                       daemon home it checks the away daemon instead, and
#                       takes the con when a live daemon's beacon stays stale
#                       for daemon_stall_secs
#   flagship idle       its beacon is fresh but its oldest queued wake has gone
#                       unacknowledged for idle_secs: the primary session is
#                       making no progress, which a restart cannot fix
#   flagship silent     record it here, queued for the flagship's return brief
#
# `recover` reuses the arm the Claude Stop hook starts for its handling
# successor: bin/fm-watch-arm.sh, detached on the flagship and confirmed by its
# one status line. It restores the watcher and its durable wake queue; it
# cannot rewake an idle primary session. While state/.afk exists the away
# daemon owns supervision, so `recover` never arms a watcher there: a live
# daemon is left alone, even when slow, and a dead one counts as a failed
# recovery, because a lookout cannot revive it from outside. A live daemon
# whose beacon stays stale for daemon_stall_secs from the episode's start is
# still left alone, but the mate takes the con.
#
# TAKING THE CON. When the flagship cannot be recovered - recovery failed, it
# stayed silent for stale_secs after last reading away, or it is idle - the
# mate takes the con of the overnight review queue. From its copy of the
# flagship's ROUTE lines and review ledger, synced while the flagship answered,
# it claims every unclaimed review it can build itself (ROUTE lines naming
# self_name, ledger rows whose host-hint cell names self_hint) and records every
# ROUTE line to another desk as not delivered. The queue is opt-in: with no
# routes and no complete ledger configuration the con is recorded as taken
# with nothing to claim. It HANDS THE CON BACK when the flagship's beacon is
# fresh and its queue moving again, or the captain is back; claims stay with
# the mate until it releases each one.
#
# CLAIMS. A claim is a line in a home's state/.review-claims.log
# (<epoch> TAB <review> TAB claim|release TAB <holder> TAB <detail>); the last
# line for a review decides who holds it. The mate's claims are mirrored to the
# flagship, which honours them: a driver there runs `claimed <review>` before it
# drives a review, and the return brief lists every claim still held.
#
# REPORTING. The scripts report facts (docs/secondmate-parent-channel.md):
# every event goes to the mate's parent channel (bin/fm-parent-channel-lib.sh)
# and to the flagship's state/.lookout.log, which the flagship's return brief
# reads through `brief`. `watch` prints only what the mate itself must act on,
# taking or handing back the con, so the check wakes the mate for exactly
# those.
#
# Records, all append-only:
#   mate      state/lookout/<name>/events.log        this lookout's events
#             state/lookout/<name>/{pending,sending} records not yet delivered
#             state/lookout/<name>/{ledger.md,routes.txt,flagship-claims.log}
#                                                    copies synced while it answered
#   flagship  state/.lookout.log                     every lookout's events
#   both      state/.review-claims.log               claims
#
# It never kills a process on the flagship, deletes nothing (its lock is a pid
# file it empties on exit), and posts to no external channel. Every ssh call is
# bounded by fm_run_timed inside a pass budget (pass_budget_secs) that stays
# under the watcher's 30 s check bound, and state is saved before a restart is
# tried, so a pass cut short never loses an episode.
#
# Config (mate): config/lookout, one key=value per line.
#   flagship_host=<ssh destination>      required
#   flagship_home=<flagship FM_HOME>     required on a remote route; a local
#                                        route defaults to its parent home
#   flagship_root=<flagship code root>   default flagship_home
#   name=flagship                        label for this lookout's records
#   stale_secs=900  idle_secs=1800  daemon_stall_secs=<2 x stale_secs>
#   backoff_base_secs=300  backoff_max_secs=3600
#   connect_timeout_secs=5  ssh_timeout_secs=8  pass_budget_secs=25
#   login_shell=yes|no  take_the_con=on|off  self_name=<this mate's id>
#   The review queue, all unset by default:
#   routes=<status file with ROUTE lines, relative to flagship_home>
#   route_window_secs=86400
#   ledger=<markdown review table, relative to flagship_home>
#   ledger_columns=<url>,<needs>,<hint>  1-based table cells
#   ledger_skip=<regex>                  rows whose needs cell matches are done
#   self_hint=<word>                     host-hint word naming this mate
#
# Usage:
#   fm-lookout.sh stand                      mate: register the lookout check
#   fm-lookout.sh stand-down                 mate: retire the lookout check
#   fm-lookout.sh watch                      mate: one lookout pass (the check)
#   fm-lookout.sh probe [--ledger <rel>] [--routes <rel>]
#                                            flagship: beacon age, posture, and
#                                            the files to sync
#   fm-lookout.sh recover [--observer <name>]
#                                            flagship: append delivered records
#                                            from stdin, then start the arm;
#                                            exit 3 when a live away daemon
#                                            owns supervision
#   fm-lookout.sh record                     flagship: append delivered records
#   fm-lookout.sh claim <review> [--holder <name>] [--detail <text>]
#   fm-lookout.sh release <review> [--holder <name>]
#   fm-lookout.sh claimed <review>           exit 0 and name the holder, or
#                                            exit 1 when free
#   fm-lookout.sh brief [--since <epoch>]    flagship: return-brief lines
#
# Environment: FM_LOOKOUT_SSH replaces the ssh command. Test seam (only with
# FM_TEST_SEAM=1): FM_LOOKOUT_ARM replaces bin/fm-watch-arm.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CFG_FILE="$CONFIG/lookout"
CLAIMS="$STATE/.review-claims.log"
FLAGSHIP_LOG="$STATE/.lookout.log"
CHECK_ID=lookout
ARM_CONFIRM=6
TAB=$(printf '\t')

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

usage() {
  sed -n '/^# Usage:/,/^# Environment:/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

die() { printf 'fm-lookout: %s\n' "$*" >&2; exit 2; }
now() { date +%s; }
iso() { date -u -r "$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%MZ; }
clean() { printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-400; }
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

cfg() {  # <key> <default>
  local key=$1 v=$2 line
  if [ -f "$CFG_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      [ "${line%%=*}" = "$key" ] && v=${line#*=}
    done < "$CFG_FILE"
  fi
  printf '%s' "$v"
}

num_or() {  # <value> <default>
  case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}

review_id() {  # <url-or-id> -> CR-<n> when present, else the input
  local id
  id=$(printf '%s' "$1" | grep -o 'CR-[0-9][0-9]*' | head -n 1)
  printf '%s' "${id:-$1}"
}

# This home's name: config self_name, else its second-mate id, else its
# directory name.
self_name() {
  local id
  id=$(fm_parent_channel_home_id "$FM_HOME" 2>/dev/null) || id=$(basename "$FM_HOME")
  cfg self_name "$id"
}

# --- claims -------------------------------------------------------------------

# Every claims log this home can see: its own, plus the synced copy of each
# flagship it keeps a lookout on.
claim_logs() {
  local f
  [ ! -f "$CLAIMS" ] || printf '%s\n' "$CLAIMS"
  for f in "$STATE"/lookout/*/flagship-claims.log; do
    [ ! -f "$f" ] || printf '%s\n' "$f"
  done
}

# Print "<holder>\t<epoch>" for a review held now; nothing when free.
claim_holder() {  # <review>
  local review=$1 logs
  logs=$(claim_logs)
  [ -n "$logs" ] || return 0
  printf '%s\n' "$logs" | tr '\n' '\0' | xargs -0 cat 2>/dev/null \
    | awk -F '\t' -v r="$review" '$2 == r && $1 ~ /^[0-9]+$/ { print }' \
    | sort -t "$TAB" -k1,1n -s \
    | awk -F '\t' 'END { if ($3 == "claim") printf "%s\t%s\n", $4, $1 }'
}

# Queue a claim line for every flagship this home keeps a lookout on.
enqueue_claim() {  # <line>
  local dir
  for dir in "$STATE"/lookout/*/; do
    [ -d "$dir" ] || continue
    printf 'claim\t%s\n' "$1" >> "${dir}pending" || return 1
  done
}

claim_append() {  # <review> <claim|release> <holder> <detail>
  local line
  line=$(printf '%s\t%s\t%s\t%s\t%s' "$(now)" "$1" "$2" "$(clean "$3")" "$(clean "$4")")
  mkdir -p "$STATE" || return 1
  printf '%s\n' "$line" >> "$CLAIMS" || return 1
  enqueue_claim "$line"
}

cmd_claim() {  # <review> [--holder h] [--detail d]
  local review holder detail='' held who
  [ "$#" -ge 1 ] || die "claim needs a review"
  review=$(review_id "$1"); shift
  holder=$(self_name)
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --holder) [ "$#" -ge 2 ] || die "--holder needs a value"; holder=$2; shift 2 ;;
      --detail) [ "$#" -ge 2 ] || die "--detail needs a value"; detail=$2; shift 2 ;;
      *) die "unknown claim argument: $1" ;;
    esac
  done
  held=$(claim_holder "$review")
  who=${held%%"$TAB"*}
  if [ -n "$held" ] && [ "$who" != "$holder" ]; then
    printf '%s is held by %s since %s\n' "$review" "$who" "$(iso "${held#*"$TAB"}")"
    return 1
  fi
  [ -z "$held" ] || { printf '%s already held by %s\n' "$review" "$holder"; return 0; }
  claim_append "$review" claim "$holder" "$detail" || return 1
  printf '%s claimed by %s\n' "$review" "$holder"
}

cmd_release() {  # <review> [--holder h]
  local review holder held who
  [ "$#" -ge 1 ] || die "release needs a review"
  review=$(review_id "$1"); shift
  holder=$(self_name)
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --holder) [ "$#" -ge 2 ] || die "--holder needs a value"; holder=$2; shift 2 ;;
      *) die "unknown release argument: $1" ;;
    esac
  done
  held=$(claim_holder "$review")
  who=${held%%"$TAB"*}
  [ -n "$held" ] || { printf '%s is not claimed\n' "$review"; return 0; }
  if [ "$who" != "$holder" ]; then
    printf '%s is held by %s, not %s; only its holder releases it\n' "$review" "$who" "$holder"
    return 1
  fi
  claim_append "$review" release "$holder" "" || return 1
  printf '%s released by %s\n' "$review" "$holder"
}

cmd_claimed() {  # <review>
  local review held
  [ "$#" -eq 1 ] || die "claimed needs one review"
  review=$(review_id "$1")
  held=$(claim_holder "$review")
  if [ -n "$held" ]; then
    printf '%s is held by %s since %s\n' "$review" "${held%%"$TAB"*}" "$(iso "${held#*"$TAB"}")"
    return 0
  fi
  printf '%s is free\n' "$review"
  return 1
}

# --- flagship side ------------------------------------------------------------

cmd_probe() {
  local ledger='' routes='' m age away queue
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ledger) [ "$#" -ge 2 ] || die "--ledger needs a path"; ledger=$2; shift 2 ;;
      --routes) [ "$#" -ge 2 ] || die "--routes needs a path"; routes=$2; shift 2 ;;
      *) die "unknown probe argument: $1" ;;
    esac
  done
  [ -d "$STATE" ] || die "no state directory at $STATE"
  if [ "$(uname)" = Darwin ]; then
    m=$(/usr/bin/stat -f %m "$STATE/.last-watcher-beat" 2>/dev/null)
  else
    m=$(stat -c %Y "$STATE/.last-watcher-beat" 2>/dev/null)
  fi
  if [ -n "$m" ]; then age=$(( $(now) - m )); else age=never; fi
  away=no
  if [ -e "$STATE/.afk" ] || [ "$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" mode 2>/dev/null)" = away ]; then
    away=yes
  fi
  # Age of the oldest wake still waiting in the durable queue (rows start with
  # their epoch; bin/fm-wake-lib.sh owns the format): how long the primary
  # session has left queued work unacknowledged.
  queue=$(awk -F '\t' -v now="$(now)" '$1 ~ /^[0-9]+$/ && (min == "" || $1 < min) { min = $1 } END { if (min == "") print "none"; else print now - min }' "$STATE/.wake-queue" 2>/dev/null)
  printf 'beat_age=%s\naway=%s\nqueue_age=%s\n' "$age" "$away" "${queue:-none}"
  printf -- '--- ledger\n'
  [ -z "$ledger" ] || [ ! -f "$FM_HOME/$ledger" ] || cat "$FM_HOME/$ledger"
  printf -- '--- routes\n'
  [ -z "$routes" ] || [ ! -f "$FM_HOME/$routes" ] || grep 'ROUTE ' "$FM_HOME/$routes" | tail -n 300
  printf -- '--- claims\n'
  [ ! -f "$CLAIMS" ] || cat "$CLAIMS"
  printf -- '--- end\n'
}

# Append delivered records, skipping any line already present so a retried
# delivery never duplicates.
cmd_record() {
  local input events claims
  input=$(cat)
  mkdir -p "$STATE" || return 1
  events=$(printf '%s\n' "$input" | sed -n "s/^event$TAB//p")
  claims=$(printf '%s\n' "$input" | sed -n "s/^claim$TAB//p")
  append_new "$FLAGSHIP_LOG" "$events" && append_new "$CLAIMS" "$claims"
}

append_new() {  # <file> <lines>
  local new
  [ -n "$2" ] || return 0
  touch "$1" || return 1
  new=$(printf '%s\n' "$2" | awk -v f="$1" 'BEGIN { while ((getline l < f) > 0) seen[l] } $0 != "" && !($0 in seen) { print; seen[$0] }') || return 1
  [ -z "$new" ] || printf '%s\n' "$new" >> "$1"
}

# The away daemon's pid while it holds its lock; bin/fm-afk-start.sh owns the
# lock and its liveness test.
away_daemon_pid() {
  # shellcheck disable=SC2016 # $1 expands in the child shell
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" bash -c '. "$1" && set +e && daemon_lock_held_by_live_daemon && daemon_lock_pid' _ "$SCRIPT_DIR/fm-afk-start.sh"
}

# Record what the lookout sent, then start the watcher arm detached, the way
# the Claude Stop hook starts its handling successor, and report the arm's one
# status line. A daemon home gets no arm.
cmd_recover() {
  local observer=unknown arm out deadline budget line pid
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --observer) [ "$#" -ge 2 ] || die "--observer needs a name"; observer=$2; shift 2 ;;
      *) die "unknown recover argument: $1" ;;
    esac
  done
  [ -d "$STATE" ] || die "no state directory at $STATE"
  cmd_record || return 1
  if [ -e "$STATE/.afk" ]; then
    if pid=$(away_daemon_pid); then
      printf 'watcher: away daemon pid=%s is alive and owns supervision; left it alone (requested by %s)\n' "$pid" "$observer"
      return 3
    fi
    printf 'watcher: FAILED - the away daemon owns supervision here and is not running; a lookout cannot revive it from outside (requested by %s)\n' "$observer"
    return 1
  fi
  arm="$SCRIPT_DIR/fm-watch-arm.sh"
  [ "${FM_TEST_SEAM:-}" != 1 ] || [ -z "${FM_LOOKOUT_ARM:-}" ] || arm=$FM_LOOKOUT_ARM
  out="$STATE/.lookout-recover.out"
  : > "$out" || return 1
  budget=$(num_or "${FM_ARM_CONFIRM_TIMEOUT:-}" "$ARM_CONFIRM")
  set -m 2>/dev/null || true
  FM_HOME="$FM_HOME" FM_ARM_CONFIRM_TIMEOUT="$budget" nohup "$arm" >"$out" 2>&1 </dev/null &
  set +m 2>/dev/null || true
  deadline=$(( $(now) + budget + 1 ))
  while :; do
    line=$(grep -E '^watcher: (started|attached) pid=[0-9]+' "$out" 2>/dev/null | head -n 1)
    [ -z "$line" ] || { printf '%s\n' "$line"; return 0; }
    line=$(grep '^watcher: FAILED' "$out" 2>/dev/null | head -n 1)
    [ -z "$line" ] || { printf '%s\n' "$line"; return 1; }
    [ "$(now)" -lt "$deadline" ] || break
    sleep 0.2
  done
  printf 'watcher: no status line within %ss (requested by %s)\n' "$((budget + 1))" "$observer"
  return 1
}

cmd_brief() {
  local since=0 me
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --since) [ "$#" -ge 2 ] || die "--since needs an epoch"; since=$(num_or "$2" 0); shift 2 ;;
      *) die "unknown brief argument: $1" ;;
    esac
  done
  me=$(self_name)
  if [ -f "$FLAGSHIP_LOG" ]; then
    awk -F '\t' -v since="$since" '$1 ~ /^[0-9]+$/ && $1 >= since' "$FLAGSHIP_LOG" | sort -t "$TAB" -k1,1n -s \
      | awk -F '\t' '{ n++; if (n <= 20) printf "%s\t%s\t%s\n", $1, $2, $4 } END { if (n > 20) printf "-\t-\t%d more in state/.lookout.log\n", n - 20 }' \
      | while IFS="$TAB" read -r epoch observer detail; do
          if [ "$epoch" = - ]; then
            printf 'lookout: %s\n' "$detail"
          else
            printf 'lookout %s at %s: %s\n' "$observer" "$(iso "$epoch")" "$detail"
          fi
        done
  fi
  [ -f "$CLAIMS" ] || return 0
  sort -t "$TAB" -k1,1n -s "$CLAIMS" \
    | awk -F '\t' '$1 ~ /^[0-9]+$/ { state[$2] = $3; holder[$2] = $4; at[$2] = $1; if (!($2 in seen)) { seen[$2]; order[++n] = $2 } }
        END { for (i = 1; i <= n; i++) { r = order[i]; if (state[r] == "claim") printf "%s\t%s\t%s\n", r, holder[r], at[r] } }' \
    | while IFS="$TAB" read -r review holder epoch; do
        [ "$holder" != "$me" ] || continue
        printf 'lookout: %s is still claimed by %s (since %s); leave it to them until they release it\n' "$review" "$holder" "$(iso "$epoch")"
      done
}

# --- mate side ----------------------------------------------------------------

OBS=
NAME=
F_HOST=
F_HOME=
F_ROOT=

load_flagship() {
  F_HOST=$(cfg flagship_host '')
  F_HOME=$(cfg flagship_home '')
  if [ -z "$F_HOME" ] && fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent" 2>/dev/null \
    && [ "$FM_SECONDMATE_PARENT_ROUTE" = local ]; then
    F_HOME=$FM_SECONDMATE_PARENT_HOME
  fi
  [ -n "$F_HOST" ] && [ -n "$F_HOME" ] || die "set flagship_host and flagship_home in $CFG_FILE"
  F_ROOT=$(cfg flagship_root "$F_HOME")
  NAME=$(cfg name flagship)
  OBS="$STATE/lookout/$NAME"
}

# Publish one fact on this mate's parent channel; a main home has none.
report() {  # <line>
  fm_parent_channel_report "$FM_HOME" "$STATE" "$1" >/dev/null 2>&1 || true
}

# Record an event here and queue it for the flagship's return brief.
event() {  # <event> <detail>
  local line
  line=$(printf '%s\t%s\t%s\t%s' "$(now)" "$(self_name)" "$1" "$(clean "$2")")
  printf '%s\n' "$line" >> "$OBS/events.log"
  printf 'event\t%s\n' "$line" >> "$OBS/pending"
}

st_get() {  # <key> <default>
  local v=$2 line
  if [ -f "$OBS/state" ]; then
    while IFS= read -r line; do
      [ "${line%%=*}" = "$1" ] && v=${line#*=}
    done < "$OBS/state"
  fi
  printf '%s' "$v"
}

st_save() {  # key=value...
  local kv
  : > "$OBS/state.new" || return 1
  for kv in "$@"; do printf '%s\n' "$kv" >> "$OBS/state.new"; done
  mv "$OBS/state.new" "$OBS/state"
}

# fm_run_timed starts its command in the background, which gives it /dev/null
# for stdin, so remote input travels on fd 3: set REMOTE_INPUT to a file.
REMOTE_INPUT=/dev/null
remote() {  # <bound-seconds> <command...> -> runs on the flagship
  local bound=$1 cmd ssh timeout
  shift
  cmd="FM_HOME=$(sq "$F_HOME") $(sq "$F_ROOT/bin/fm-lookout.sh")"
  while [ "$#" -gt 0 ]; do cmd="$cmd $(sq "$1")"; shift; done
  [ "$(cfg login_shell yes)" = no ] || cmd="exec \"\${SHELL:-/bin/sh}\" -lc $(sq "$cmd")"
  ssh=${FM_LOOKOUT_SSH:-ssh}
  timeout=$(num_or "$(cfg connect_timeout_secs 5)" 5)
  # shellcheck disable=SC2016 # $@ expands in the child shell
  fm_run_timed "$bound" /bin/sh -c 'exec "$@" <&3' _ \
    "$ssh" -o BatchMode=yes -o ConnectTimeout="$timeout" -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -- "$F_HOST" "$cmd" 3< "$REMOTE_INPUT"
}

# Gather queued records into the batch being sent; pending is moved aside
# first, so a claim appended mid-send lands in a fresh pending file.
batch_pending() {
  if [ -s "$OBS/pending" ] && mv "$OBS/pending" "$OBS/pending.batch"; then
    cat "$OBS/pending.batch" >> "$OBS/sending" && : > "$OBS/pending.batch"
  fi
  touch "$OBS/sending"
}

flush_pending() {
  batch_pending
  [ -s "$OBS/sending" ] || return 0
  if REMOTE_INPUT="$OBS/sending" remote "$SSH_BOUND" record >/dev/null 2>&1; then
    : > "$OBS/sending"
  fi
}

# Write the probe's sections to the synced copies; returns 1 unless the output
# ends with the end marker.
sync_probe() {  # <probe-output>
  printf '%s\n' "$1" | grep -qx -- '--- end' || return 1
  printf '%s\n' "$1" | awk '/^--- ledger$/ { s = 1; next } /^--- /{ s = 0 } s' > "$OBS/ledger.md.new"
  printf '%s\n' "$1" | awk '/^--- routes$/ { s = 1; next } /^--- /{ s = 0 } s' > "$OBS/routes.txt.new"
  printf '%s\n' "$1" | awk '/^--- claims$/ { s = 1; next } /^--- /{ s = 0 } s' > "$OBS/flagship-claims.log.new"
  if [ -s "$OBS/ledger.md.new" ]; then mv "$OBS/ledger.md.new" "$OBS/ledger.md"; else : > "$OBS/ledger.md.new"; fi
  if [ -s "$OBS/routes.txt.new" ]; then mv "$OBS/routes.txt.new" "$OBS/routes.txt"; else : > "$OBS/routes.txt.new"; fi
  mv "$OBS/flagship-claims.log.new" "$OBS/flagship-claims.log"
}

# ROUTE lines inside the window: "<url>\t<dest>\t<reason>".
route_lines() {  # <cutoff-epoch>
  sed -n "s/^[a-z-]*[^:]*\\[at=\\([0-9]*\\)\\][^:]*: ROUTE \\([^ ]*\\) to \\([^:]*\\): \\(.*\\)\$/\\1$TAB\\2$TAB\\3$TAB\\4/p" "$OBS/routes.txt" \
    | awk -F '\t' -v cut="$1" '$1 >= cut { printf "%s\t%s\t%s\n", $2, $3, $4 }'
}

# The ledger is usable only when its columns and this mate's host hint are set.
ledger_ready() {
  [ -s "$OBS/ledger.md" ] && [ -n "$(cfg self_hint '')" ] \
    && printf '%s' "$(cfg ledger_columns '')" | grep -Eq '^[1-9][0-9]*,[1-9][0-9]*,[1-9][0-9]*$'
}

# Reviews this mate builds: "<review>\t<url>\t<why>" from ROUTE lines naming
# self_name and from ledger rows whose host-hint cell names self_hint.
self_reviews() {  # <route-cutoff-epoch>
  local self hint cols
  self=$(self_name)
  hint=$(cfg self_hint '' | tr '[:upper:]' '[:lower:]')
  cols=$(cfg ledger_columns '')
  {
    [ ! -s "$OBS/routes.txt" ] || route_lines "$1" | awk -F '\t' -v me="$self" '$2 == me { printf "%s\troute: %s\n", $1, $3 }'
    ! ledger_ready || awk -F '|' -v hint="$hint" -v cols="$cols" -v skip="$(cfg ledger_skip '')" '
      BEGIN { split(cols, c, ","); u = c[1] + 1; n = c[2] + 1; k = c[3] + 1 }
      NF > k && $u !~ /^ *(:?-+:? *)?$/ {
        url = $u; gsub(/^ +| +$/, "", url); needs = $n; gsub(/^ +| +$/, "", needs)
        if (url !~ /^https?:/) next
        h = " " tolower($k) " "; gsub(/[^a-z0-9-]/, " ", h)
        if (skip != "" && needs ~ skip) next
        if (index(h, " " hint " ") == 0) next
        printf "%s\tledger: %s\n", url, needs
      }' "$OBS/ledger.md"
  } | while IFS="$TAB" read -r url why; do
    printf '%s\t%s\t%s\n' "$(review_id "$url")" "$url" "$why"
  done | awk -F '\t' '!seen[$1]++'
}

# Sets CON to what this pass leaves standing: yes when the con was taken with
# a queue to drive, empty when there was none to take.
CON=no
take_the_con() {  # <reason>
  local cutoff list review url why held dest claimed=0 skipped=0 undelivered=0 took_names='' routes='' line
  if [ "$(cfg take_the_con on)" = off ]; then
    event con-off "take_the_con is off in config/lookout; did not take the con ($1)"
    CON=empty
    return 0
  fi
  if ! ledger_ready && [ ! -s "$OBS/routes.txt" ]; then
    event con-skipped "no review queue is configured or synced, so there is nothing to take the con of ($1)"
    report "note [key=lookout-con-$NAME-$since]: lookout: the flagship needs the con ($1), but no review queue is configured for this mate"
    CON=empty
    return 0
  fi
  cutoff=$(( $(now) - $(num_or "$(cfg route_window_secs 86400)" 86400) ))
  list=$(self_reviews "$cutoff")
  while IFS="$TAB" read -r review url why; do
    [ -n "$review" ] || continue
    held=$(claim_holder "$review")
    if [ -n "$held" ] && [ "${held%%"$TAB"*}" != "$(self_name)" ]; then
      skipped=$((skipped + 1))
      continue
    fi
    [ -n "$held" ] || claim_append "$review" claim "$(self_name)" "took the con: $why" || continue
    claimed=$((claimed + 1))
    took_names="$took_names $review"
  done <<EOF
$list
EOF
  if [ -f "$OBS/routes.txt" ]; then
    while IFS="$TAB" read -r url dest why; do
      [ -n "$url" ] && [ "$dest" != "$(self_name)" ] || continue
      undelivered=$((undelivered + 1))
      routes="$routes; $(review_id "$url") to $dest"
      event route-undelivered "ROUTE $url to $dest was not delivered: $why"
    done <<EOF
$(route_lines "$cutoff" | awk -F '\t' '!seen[$1 FS $2]++')
EOF
  fi
  line="took the con of $claimed review(s) this mate builds:${took_names:- none}; $skipped already held elsewhere; $undelivered ROUTE line(s) to other desks not delivered${routes} ($1)"
  event took-the-con "$line"
  report "working [key=lookout-con-$NAME-$since]: lookout: $line"
  CON=yes
  printf 'lookout: took the con from %s (%s). Drive these reviews to green under your lookout duty:%s. Release each with bin/fm-lookout.sh release <review> when it is done or handed back.\n' \
    "$NAME" "$1" "${took_names:- none}"
}

hand_back_the_con() {  # <standing-con> <reason>
  local held='' review state holder line
  while IFS="$TAB" read -r review state holder; do
    [ "$state" = claim ] && [ "$holder" = "$(self_name)" ] && held="$held $review"
  done <<EOF
$( [ ! -f "$CLAIMS" ] || sort -t "$TAB" -k1,1n -s "$CLAIMS" | awk -F '\t' '{ s[$2] = $3; h[$2] = $4 } END { for (r in s) printf "%s\t%s\t%s\n", r, s[r], h[r] }')
EOF
  line="handed the con back ($2); still claimed by $(self_name) until released:${held:- none}"
  event handed-back-the-con "$line"
  report "resolved [key=lookout-con-$NAME-$since]: lookout: $line"
  [ "$1" = yes ] || return 0
  printf 'lookout: handed the con back to %s (%s). Take no new reviews from the con; finish or hand back each one you still hold (%s) and release it with bin/fm-lookout.sh release <review>.\n' \
    "$NAME" "$2" "${held# }"
}

# The pass lock is a pid file, emptied on exit; a stored pid counts only while
# it is still a lookout pass, so a reused pid never wedges the lookout.
lock_take() {
  local pid
  pid=$(cat "$OBS/lock" 2>/dev/null)
  if [ -n "$pid" ] && [ "$pid" != "$$" ] && kill -0 "$pid" 2>/dev/null \
    && ps -p "$pid" -o command= 2>/dev/null | grep -q 'fm-lookout'; then
    return 1
  fi
  printf '%s\n' "$$" > "$OBS/lock"
  trap ': > "$OBS/lock"' EXIT
}

save() {
  st_save episode="$episode" since="$since" failures="$failures" next_attempt="$next_attempt" last_away="$last_away" daemon="$daemon" con="$CON"
}

cmd_watch() {
  local out rc beat away queue idle stale idle_secs stall base max t line left kind
  load_flagship
  mkdir -p "$OBS" || die "cannot create $OBS"
  lock_take || return 0
  SSH_BOUND=$(num_or "$(cfg ssh_timeout_secs 8)" 8)
  PASS_BUDGET=$(num_or "$(cfg pass_budget_secs 25)" 25)
  stale=$(num_or "$(cfg stale_secs 900)" 900)
  idle_secs=$(num_or "$(cfg idle_secs 1800)" 1800)
  stall=$(num_or "$(cfg daemon_stall_secs $((stale * 2)))" $((stale * 2)))
  base=$(num_or "$(cfg backoff_base_secs 300)" 300)
  max=$(num_or "$(cfg backoff_max_secs 3600)" 3600)
  episode=$(st_get episode ok)
  since=$(st_get since 0)
  failures=$(st_get failures 0)
  next_attempt=$(st_get next_attempt 0)
  last_away=$(st_get last_away no)
  daemon=$(st_get daemon no)
  CON=$(st_get con no)
  t=$(now)
  SECONDS=0

  out=$(remote "$SSH_BOUND" probe --ledger "$(cfg ledger '')" --routes "$(cfg routes '')" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ] || ! sync_probe "$out"; then
    line=$(printf '%s\n' "$out" | tail -n 1)
    if [ "$episode" != silent ]; then
      [ "$episode" != ok ] || since=$t
      episode=silent
      event silent "the flagship did not answer over SSH (exit $rc: $(clean "$line")); it last read away=$last_away"
      report "note [key=lookout-silent-$NAME-$since]: lookout: the flagship $F_HOST did not answer over SSH; it last read away=$last_away"
    fi
    if [ "$CON" = no ] && [ "$last_away" = yes ] && [ $((t - since)) -ge "$stale" ]; then
      take_the_con "the flagship has been silent for $((t - since))s"
    fi
    save
    return 0
  fi

  beat=$(printf '%s\n' "$out" | sed -n 's/^beat_age=//p' | head -n 1)
  case "$beat" in ''|*[!0-9]*) beat=never ;; esac
  away=$(printf '%s\n' "$out" | sed -n 's/^away=//p' | head -n 1)
  queue=$(printf '%s\n' "$out" | sed -n 's/^queue_age=//p' | head -n 1)
  idle=no
  case "$queue" in ''|*[!0-9]*) ;; *) [ "$queue" -lt "$idle_secs" ] || idle=yes ;; esac
  [ "$episode" != silent ] || event answers "the flagship answers again after $((t - since))s"
  last_away=$away

  if [ "$away" != yes ] || { [ "$beat" != never ] && [ "$beat" -lt "$stale" ] && [ "$idle" = no ]; }; then
    if [ "$episode" != ok ]; then
      if [ "$away" != yes ]; then
        event present "the flagship is no longer in away mode"
      elif [ "$episode" = idle ]; then
        event moving "the flagship's queue is moving again"
      else
        event fresh "the flagship's watcher beacon is fresh again (${beat}s old)"
      fi
    fi
    if [ "$CON" != no ]; then
      if [ "$away" = yes ]; then kind="the flagship's watcher is beating and its queue is moving"; else kind="the captain is back"; fi
      hand_back_the_con "$CON" "$kind"
    fi
    flush_pending
    episode=ok since=0 failures=0 next_attempt=0 daemon=no CON=no
    save
    return 0
  fi

  if [ "$beat" != never ] && [ "$beat" -lt "$stale" ]; then
    # The watcher beats but the primary leaves queued wakes unacknowledged: a
    # restart cannot help, so the mate keeps the queue moving instead.
    if [ "$episode" != idle ]; then
      [ "$episode" != ok ] || since=$t
      episode=idle
      event idle "the flagship's watcher beats but its oldest queued wake has waited ${queue}s unacknowledged during away mode (threshold ${idle_secs}s)"
      report "note [key=lookout-idle-$NAME-$since]: lookout: the flagship's primary session has left queued wakes unacknowledged for ${queue}s during away mode"
    fi
    [ "$CON" != no ] || take_the_con "the flagship's primary session has made no progress for ${queue}s"
    flush_pending
    save
    return 0
  fi

  if [ "$episode" != stale ]; then
    [ "$episode" != ok ] || since=$t
    episode=stale
    event stale "the flagship's watcher beacon is ${beat}s old during away mode (threshold ${stale}s)"
    report "note [key=lookout-stale-$NAME-$since]: lookout: the flagship's watcher beacon is ${beat}s old during away mode; restarting it"
  fi
  save
  left=$((PASS_BUDGET - SECONDS))
  if [ "$t" -ge "$next_attempt" ] && [ "$left" -ge $((ARM_CONFIRM + 4)) ]; then
    # One call carries the queued records and the restart, so the stale event
    # reaches the flagship before the restart is tried.
    batch_pending
    line=$(REMOTE_INPUT="$OBS/sending" remote "$left" recover --observer "$(self_name)" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
      : > "$OBS/sending"
      event recovered "restarted the flagship's watcher: $(clean "$(printf '%s\n' "$line" | tail -n 1)")"
      report "note: lookout: restarted the flagship's watcher"
      failures=0
      next_attempt=0
    elif [ "$rc" -eq 3 ]; then
      : > "$OBS/sending"
      [ "$daemon" = yes ] || event daemon-alive "left the flagship's supervision to its live away daemon: $(clean "$(printf '%s\n' "$line" | tail -n 1)")"
      daemon=yes
      next_attempt=$((t + base))
      if [ "$CON" = no ] && [ $((t - since)) -ge "$stall" ]; then
        event daemon-stalled "daemon alive but supervision stalled: the beacon has been stale for $((t - since))s (threshold ${stall}s)"
        save
        take_the_con "the flagship's away daemon is alive but supervision has stalled for $((t - since))s"
      fi
    else
      case "$line" in *'watcher: '*) : > "$OBS/sending" ;; esac
      failures=$((failures + 1))
      next_attempt=$(( base * (1 << (failures - 1)) ))
      [ "$next_attempt" -le "$max" ] || next_attempt=$max
      next_attempt=$((t + next_attempt))
      event recovery-failed "could not restart the flagship's watcher (attempt $failures, next try after $(iso "$next_attempt")): $(clean "$(printf '%s\n' "$line" | tail -n 1)")"
      [ "$failures" -ne 1 ] || report "note [key=lookout-recovery-failed-$NAME-$since]: lookout: could not restart the flagship's watcher; retrying with backoff"
      save
      [ "$CON" != no ] || take_the_con "the flagship's watcher could not be restarted"
    fi
  fi
  save
  return 0
}

cmd_stand() {
  local check
  load_flagship
  mkdir -p "$OBS" || return 1
  check="$STATE/$CHECK_ID.check.sh"
  umask 077
  printf '#!/usr/bin/env bash\n# The lookout on the flagship, stood by bin/fm-lookout.sh stand.\nexec env FM_HOME=%s %s watch\n' \
    "$(sq "$FM_HOME")" "$(sq "$FM_ROOT/bin/fm-lookout.sh")" > "$check.new" || return 1
  chmod 700 "$check.new" && mv "$check.new" "$check" || return 1
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null || return 1
  printf 'lookout stood on the flagship %s (%s); this home'"'"'s watcher keeps it on every check sweep\n' "$F_HOST" "$F_HOME"
}

cmd_stand_down() {
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null || return 1
  printf 'lookout stood down; claims this home holds stay until released\n'
}

cmd=${1:-}
[ -n "$cmd" ] || { usage >&2; exit 2; }
shift
case "$cmd" in
  stand) cmd_stand "$@" ;;
  stand-down) cmd_stand_down "$@" ;;
  watch) cmd_watch "$@" ;;
  probe) cmd_probe "$@" ;;
  recover) cmd_recover "$@" ;;
  record) cmd_record "$@" ;;
  claim) cmd_claim "$@" ;;
  release) cmd_release "$@" ;;
  claimed) cmd_claimed "$@" ;;
  brief) cmd_brief "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
