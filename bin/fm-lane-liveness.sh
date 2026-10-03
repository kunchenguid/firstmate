#!/usr/bin/env bash
# fm-lane-liveness.sh - read-only liveness rail and routing-verification
# measurement for firstmate response lanes.
#
# Usage:
#   fm-lane-liveness.sh read        one reading line per lane, with its verdict
#   fm-lane-liveness.sh routes      routing-verification measurement
#   fm-lane-liveness.sh classes     the error-signature class vocabulary this rail emits
#   fm-lane-liveness.sh check       watcher poll: report a lane whose verdict changed
#   fm-lane-liveness.sh selfcheck   watcher poll: report rail silence
#   fm-lane-liveness.sh arm         write and register both check shims
#   fm-lane-liveness.sh disarm      retire both check shims and their records
#   fm-lane-liveness.sh --help      print this help
#
# READ-ONLY against every lane. It never writes, moves, deletes, or otherwise
# touches a lane's inbox, its messages, its status log, its metadata, or any
# other lane state. It writes only its own three records, all under this home's
# own state directory: the heartbeat, the per-lane error-class and drain
# journal, and the reported-verdict record that suppresses repeats. It contains
# no model call of any kind; every verdict is deterministic.
#
# It runs CENTRALLY, in the home that supervises the lanes, and never inside a
# monitored home, because a rail deployed inside a lane dies with the thing it
# was meant to watch.
#
# `check` and `selfcheck` are the two halves that keep the rail from failing
# silently. `check` writes the heartbeat only after a sweep completes, so a
# sweep the watcher kills on its per-check timeout deliberately leaves the beat
# stale, and `selfcheck` then reports that silence as its own finding. A rail
# that stops reporting reports that it stopped.
#
# Config: config/response-lanes.conf. docs/configuration.md "Response lanes"
# owns its schema, every default, and the reasoning behind each threshold. An
# absent config leaves the rail inert.
#
# Lane resolution uses this home's own state/<lane>.meta. A meta carrying
# remote_host= is a remote lane: its inbox is read over ssh at
# <home>/state/parent-route/<lane>.inbox on that host, because no local inbox
# directory exists for it. A local lane's inbox is state/<lane>.inbox. An inbox
# that cannot be read is reported `unknown` with every count as `-`, never as
# zero, because a zero reading for an inbox that is not there is exactly the
# false-health signal this rail exists to prevent.
#
# Error signature classes are matched from the lane's own pane, through
# bin/fm-peek.sh so local and remote panes use one reader, by fixed substring
# and never by inference, in this order so the more specific class wins:
#   budget_exceeded      "Account budget exceeded"
#   rate_limited         "429 Too Many Requests", "rate limit", "Rate limit"
#   stream_disconnected  "stream disconnected before completion"
#   transport_dead       "Connection refused", "connection refused", "ECONNREFUSED"
# A pane that cannot be read is `unknown`, which is deliberately not `none`.
#
# That class list is DATA THIS RAIL OWNS, and `classes` prints it so a consumer
# never carries its own copy to drift out of date. Each row says whether the
# class represents a provider error the rail actually matched (`matched=yes`) or
# the absence of one (`matched=no`), which is the only distinction a consumer
# needs to tell a provider fault from a clean or unread pane. What to DO about a
# matched class is the consumer's policy, not this rail's.
# Under FM_TEST_SEAM only, state/<lane>.pane substitutes for that capture so the
# suite can drive each class deterministically; without the seam the file is
# inert and the real pane is always the source.
#
# Routing verification implements the delivery-AND-processing contract over the
# same single probe the liveness reading uses. The auditable universe of routing
# claims is this home's durable inbox records: every send that reported
# confirmed delivery left one, and the transient send result is retained
# nowhere, so the record itself is the durable delivery evidence. Processing
# evidence is the record present under handled/, or a status line carrying the
# same corr= token firstmate embedded. Delivery evidence without processing
# evidence is recorded as routed_unverified, never as routed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/response-lanes.conf"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

BEAT="$STATE/.lane-liveness-beat"
JOURNAL="$STATE/.lane-liveness-lanes"
REPORTED="$STATE/.lane-liveness-reported"
CHECK_ID='lane-liveness'
SELF_CHECK_ID='lane-liveness-self'

# Fallbacks used when the config names no override; docs/configuration.md owns
# the reasoning for each.
W=900
D=1800
E=600
M=50
SELF=900
SSH_TIMEOUT=10
CAPTURE_TIMEOUT=8

LANES=
SKIP_PANE=

usage() {
  cat <<'USAGE'
fm-lane-liveness.sh - read-only liveness rail for firstmate response lanes.

  read        one reading line per lane, with its verdict
  routes      routing-verification measurement (routed vs routed_unverified)
  classes     the error-signature class vocabulary this rail emits
  check       watcher poll: report a lane whose verdict changed
  selfcheck   watcher poll: report rail silence
  arm         write and register both check shims
  disarm      retire both check shims and their records
  --help      print this help

Reads config/response-lanes.conf; docs/configuration.md "Response lanes" owns
its schema and thresholds. Every mode is read-only against every lane.
USAGE
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 2
}

case "$(uname -s 2>/dev/null)" in
  Darwin)
    file_mtime() { /usr/bin/stat -f %m "$1" 2>/dev/null; }
    file_owner() { /usr/bin/stat -f %Su "$1" 2>/dev/null; }
    ;;
  *)
    file_mtime() { stat -c %Y "$1" 2>/dev/null; }
    file_owner() { stat -c %U "$1" 2>/dev/null; }
    ;;
esac

NOW=

is_int() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
}

# gt <a> <b>: true only when both are whole numbers and a > b, so a `-` reading
# never fabricates a verdict.
gt() {
  is_int "$1" && is_int "$2" && [ "$1" -gt "$2" ]
}

age_of() {  # <file>; whole seconds since its mtime, or `-`
  local m
  m=$(file_mtime "$1")
  if is_int "$m"; then printf '%s' "$(( NOW - m ))"; else printf -- '-'; fi
}

config_load() {
  local line key value name inbox lineno=0
  [ -f "$CONFIG" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$(( lineno + 1 ))
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      'lane '*)
        # shellcheck disable=SC2086  # deliberate split of a whitespace record
        set -- $line
        name=${2:-}
        inbox=${3:-}
        fm_pr_task_id_valid "$name" \
          || die "response-lanes.conf line $lineno: invalid lane name"
        LANES="$LANES$name	$inbox
"
        ;;
      *=*)
        key=${line%%=*}
        value=${line#*=}
        # Keys of the recovery ladder, which shares this one config file and
        # validates them itself (bin/fm-lane-recover.sh). Skipped rather than
        # rejected here, so one subsystem keeps one config surface while an
        # actual typo in a rail key still refuses below.
        case "$key" in
          RECOVERY|ATTEMPT_CEILING|COOLDOWN|RELAUNCH_TIMEOUT|PERSIST_TIMEOUT|SWITCH_MODEL|SWITCH_HARNESS)
            continue
            ;;
        esac
        is_int "$value" \
          || die "response-lanes.conf line $lineno: $key needs a whole number"
        case "$key" in
          SSH_TIMEOUT|CAPTURE_TIMEOUT)
            [ "$value" -gt 0 ] \
              || die "response-lanes.conf line $lineno: $key must be a positive whole number, because a zero bound disables the bound instead of applying it"
            ;;
        esac
        case "$key" in
          W) W=$value ;; D) D=$value ;; E) E=$value ;; M) M=$value ;;
          SELF) SELF=$value ;; SSH_TIMEOUT) SSH_TIMEOUT=$value ;;
          CAPTURE_TIMEOUT) CAPTURE_TIMEOUT=$value ;;
          *) die "response-lanes.conf line $lineno: unknown setting $key" ;;
        esac
        ;;
      *) die "response-lanes.conf line $lineno: unrecognized record" ;;
    esac
  done < "$CONFIG"
  [ -n "$LANES" ]
}

# --- the rail's own journal --------------------------------------------------
#
# One record per lane: <lane> <error-class> <class-first-seen-epoch> <handled>.
# It carries the two signals a single-shot read cannot see for itself: how long
# an error class has been sustained, and whether handled_count moved.

journal_read() {  # <lane>
  [ -f "$JOURNAL" ] || return 0
  awk -v l="$1" '$1==l {print $2, $3, $4; exit}' "$JOURNAL" 2>/dev/null
}

record_replace() {  # <file> <key> <line>
  local tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 0
  umask 077
  tmp=$(mktemp "$STATE/.lane-liveness-rec.XXXXXX") || return 0
  if [ -f "$1" ]; then
    awk -v l="$2" '$1!=l' "$1" >> "$tmp" 2>/dev/null
  fi
  printf '%s\n' "$3" >> "$tmp"
  mv -f -- "$tmp" "$1" 2>/dev/null || rm -f -- "$tmp"
}

reported_read() {  # <lane>
  [ -f "$REPORTED" ] || return 0
  awk -v l="$1" '$1==l {print $2; exit}' "$REPORTED" 2>/dev/null
}

# --- per-lane probe and reading ---------------------------------------------

# LANE_* hold the reading for one lane. They are globals because bash 3.2 has
# no associative arrays and the reading is one flat row.
lane_reset() {
  LANE_SOURCE=- LANE_PENDING=- LANE_HANDLED=- LANE_DRAIN=- LANE_MISSED=-
  LANE_RESOLVED=- LANE_ERRCLASS=unknown LANE_BEAT=- LANE_AGENT=unverified
  LANE_ROUTE_EVIDENCE=- LANE_DRAINED_ON_ERROR=no LANE_MOVER=- LANE_VERDICT=unknown
  LANE_HANDLED_MOVED=no LANE_INBOX=-
  LANE_REASON=''
  LANE_RECORDS=''
}

# shell_quote <value>: the value as one shell word. ssh joins its command
# arguments with spaces and the remote login shell parses that joined string,
# so a multi-word program crosses intact only when it is quoted for that parse.
shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

remote_probe() {  # <host> <inbox> <home>
  local program remote
  program=$(cat <<'REMOTE'
d=$1; h=$2
m=$(stat -c %Y "$h/state/.last-watcher-beat" 2>/dev/null || /usr/bin/stat -f %m "$h/state/.last-watcher-beat" 2>/dev/null)
printf 'beat %s\n' "${m:--}"
[ -d "$d" ] || { printf 'inbox missing\n'; exit 0; }
printf 'inbox ok\n'
emit() {
  for f in "$1"/*.msg; do
    [ -f "$f" ] || continue
    m=$(stat -c %Y "$f" 2>/dev/null || /usr/bin/stat -f %m "$f" 2>/dev/null)
    c=$(LC_ALL=C grep -o 'corr=[A-Za-z0-9._-]*' "$f" 2>/dev/null | head -1)
    c=${c#corr=}
    printf 'rec %s %s %s %s\n' "$2" "$(basename "$f")" "${m:--}" "${c:--}"
  done
}
emit "$d" pending
emit "$d/handled" handled
REMOTE
)
  remote="sh -c $(shell_quote "$program") sh $(shell_quote "$2") $(shell_quote "$3")"
  # stdin closed: this call runs inside the per-lane config loop, and a real
  # ssh drains its stdin, which would consume the loop's remaining lane lines.
  fm_run_timed "$SSH_TIMEOUT" ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" \
    "$1" "$remote" < /dev/null
}

local_probe() {  # <inbox>
  local f m c kind
  [ -d "$1" ] || { printf 'inbox missing\n'; return 0; }
  printf 'inbox ok\n'
  for f in "$1"/*.msg "$1"/handled/*.msg; do
    [ -f "$f" ] || continue
    case "$f" in */handled/*) kind=handled ;; *) kind=pending ;; esac
    m=$(file_mtime "$f")
    c=$(LC_ALL=C grep -o 'corr=[A-Za-z0-9._-]*' "$f" 2>/dev/null | head -1)
    c=${c#corr=}
    printf 'rec %s %s %s %s\n' "$kind" "${f##*/}" "${m:--}" "${c:--}"
  done
}

error_class() {  # <pane-text>
  case "${1:-}" in
    '') printf 'unknown' ;;
    *'Account budget exceeded'*) printf 'budget_exceeded' ;;
    *'429 Too Many Requests'*|*'rate limit'*|*'Rate limit'*) printf 'rate_limited' ;;
    *'stream disconnected before completion'*) printf 'stream_disconnected' ;;
    *'Connection refused'*|*'connection refused'*|*ECONNREFUSED*) printf 'transport_dead' ;;
    *) printf 'none' ;;
  esac
}

# The vocabulary error_class can return, and whether each one means the rail
# matched a provider error string. Kept immediately beside error_class so the
# published list and the matcher cannot drift apart.
action_classes() {
  printf 'class %s matched=%s\n' \
    none no \
    unknown no \
    budget_exceeded yes \
    rate_limited yes \
    stream_disconnected yes \
    transport_dead yes
}

pending_reply_counts() {  # <status-file>; prints "<outstanding-missed> <resolved>"
  awk '
    function id(s) { if (match(s, /pending-reply-id=[A-Za-z0-9._-]+/)) return substr(s, RSTART+17, RLENGTH-17); return "" }
    /pending-reply-missed:/  { k=id($0); if (k != "") m[k]=1 }
    /pending-reply-resolved:/ { k=id($0); if (k != "") r[k]=1 }
    END { miss=0; res=0; for (k in m) if (!(k in r)) miss++; for (k in r) res++; print miss, res }
  ' "$1" 2>/dev/null
}

# route_classify <lane>: classifies this lane's probed records against the
# section 4 contract. Sets ROUTED and UNVERIFIED, and prints one `claim` line
# per unverified claim.
route_classify() {
  local lane=$1 kind name corr status_file
  ROUTED=0
  UNVERIFIED=0
  status_file="$STATE/$lane.status"
  while IFS='	' read -r kind name corr; do
    [ -n "$kind" ] || continue
    if [ "$kind" = handled ]; then
      ROUTED=$(( ROUTED + 1 ))
      continue
    fi
    if [ "$corr" != - ] && [ -f "$status_file" ] \
      && LC_ALL=C grep -qF "corr=$corr" "$status_file" 2>/dev/null; then
      ROUTED=$(( ROUTED + 1 ))
      continue
    fi
    UNVERIFIED=$(( UNVERIFIED + 1 ))
    if [ "$corr" = - ]; then
      printf 'claim lane=%s record=%s corr=- verdict=routed_unverified reason=delivered, never handled, and carries no corr token to correlate\n' \
        "$lane" "$name"
    else
      printf 'claim lane=%s record=%s corr=%s verdict=routed_unverified reason=delivered and never handled, and no status line carries its corr token\n' \
        "$lane" "$name" "$corr"
    fi
  done <<EOF
$(printf '%s' "$LANE_RECORDS" | LC_ALL=C sort)
EOF
}

lane_read() {  # <lane> <inbox-override>
  local lane=$1 override=$2 meta home host inbox probe oldest
  local tag kind name mtime corr beat_remote=- counts pane remote_agent
  local jclass jsince jhandled since sustained
  lane_reset
  meta="$STATE/$lane.meta"
  if [ ! -f "$meta" ]; then
    LANE_REASON='no lane record in this home'
    return 0
  fi
  home=$(fm_meta_get "$meta" home)
  host=$(fm_meta_get "$meta" remote_host)

  if [ -n "$host" ]; then
    LANE_SOURCE="remote:$host"
    inbox=${override:-$home/state/parent-route/$lane.inbox}
    LANE_INBOX=$inbox
    probe=$(remote_probe "$host" "$inbox" "$home" 2>/dev/null) || probe=
    if [ -z "$probe" ]; then
      LANE_REASON="host $host is unreachable, so this lane is unread rather than healthy"
      return 0
    fi
  else
    LANE_SOURCE=local
    inbox=${override:-$STATE/$lane.inbox}
    LANE_INBOX=$inbox
    probe=$(local_probe "$inbox")
    LANE_BEAT=$(age_of "$home/state/.last-watcher-beat")
  fi

  case "$probe" in
    *'inbox missing'*)
      LANE_REASON="the configured inbox $inbox is absent, so its depth is unread rather than zero"
      return 0
      ;;
  esac

  oldest=
  LANE_PENDING=0
  LANE_HANDLED=0
  while read -r tag kind name mtime corr; do
    case "$tag" in
      beat) beat_remote=$kind; continue ;;
      rec) ;;
      *) continue ;;
    esac
    LANE_RECORDS="$LANE_RECORDS$kind	$name	$corr
"
    if [ "$kind" = handled ]; then
      LANE_HANDLED=$(( LANE_HANDLED + 1 ))
    else
      LANE_PENDING=$(( LANE_PENDING + 1 ))
      if is_int "$mtime" && { [ -z "$oldest" ] || [ "$mtime" -lt "$oldest" ]; }; then
        oldest=$mtime
      fi
    fi
  done <<EOF
$probe
EOF

  [ -z "$oldest" ] || LANE_DRAIN=$(( NOW - oldest ))
  if [ -n "$host" ] && is_int "$beat_remote"; then
    LANE_BEAT=$(( NOW - beat_remote ))
  fi
  LANE_MOVER=$(handled_mover "$host" "$inbox")

  if [ -f "$STATE/$lane.status" ]; then
    counts=$(pending_reply_counts "$STATE/$lane.status")
    LANE_MISSED=${counts%% *}
    LANE_RESOLVED=${counts##* }
    is_int "$LANE_MISSED" || LANE_MISSED=-
    is_int "$LANE_RESOLVED" || LANE_RESOLVED=-
  fi

  route_classify "$lane" > /dev/null
  LANE_ROUTE_EVIDENCE=$ROUTED

  if [ -z "$SKIP_PANE" ]; then
    if [ -n "${FM_TEST_SEAM:-}" ] && [ -f "$STATE/$lane.pane" ]; then
      pane=$(LC_ALL=C tr -d '\000' < "$STATE/$lane.pane" 2>/dev/null) || pane=
    else
      pane=$(fm_run_timed "$CAPTURE_TIMEOUT" "$SCRIPT_DIR/fm-peek.sh" "$lane" 60 2>/dev/null) || pane=
    fi
    LANE_ERRCLASS=$(error_class "$pane")
  fi
  if [ -z "$host" ]; then
    LANE_AGENT=$(fm_backend_agent_state "$(fm_backend_of_meta "$meta")" \
      "$(fm_meta_get "$meta" window)" 2>/dev/null) || LANE_AGENT=unverified
    [ -n "$LANE_AGENT" ] || LANE_AGENT=unverified
  else
    # A remote lane's agent state comes from the remote control state verb the
    # supervision library polls, bounded like this sweep's other remote read.
    LANE_AGENT=unverified
    # shellcheck disable=SC2016  # the single-quoted program expands in the child shell
    remote_agent=$(fm_run_timed "$SSH_TIMEOUT" env FM_HOME="$FM_HOME" bash -c '
      . "$1/fm-secondmate-liveness-lib.sh" || exit 1
      fm_secondmate_liveness_probe "$2" "$3" poll || exit 1
      printf %s "$FM_SM_LIVE_STATE"
    ' _ "$SCRIPT_DIR" "$meta" "$lane" 2>/dev/null) || remote_agent=
    case "$remote_agent" in
      alive|dead|missing|ambiguous|unreadable|unverified) LANE_AGENT=$remote_agent ;;
    esac
  fi

  jclass=-
  jsince=''
  jhandled=''
  read -r jclass jsince jhandled <<EOF
$(journal_read "$lane")
EOF
  if [ "$jclass" = "$LANE_ERRCLASS" ] && is_int "$jsince"; then
    since=$jsince
  elif [ "$LANE_ERRCLASS" = unknown ] && is_int "$jsince"; then
    since=$jsince
  else
    since=$NOW
  fi
  LANE_HANDLED_MOVED=no
  gt "$LANE_HANDLED" "$jhandled" && LANE_HANDLED_MOVED=yes
  case "$LANE_ERRCLASS" in
    none) ;;
    *)
      [ "$LANE_HANDLED_MOVED" != yes ] || LANE_DRAINED_ON_ERROR=yes
      ;;
  esac
  if [ -z "$SKIP_PANE" ] && [ "$LANE_ERRCLASS" != unknown ]; then
    record_replace "$JOURNAL" "$lane" "$lane $LANE_ERRCLASS $since $LANE_HANDLED"
  elif is_int "$jsince"; then
    record_replace "$JOURNAL" "$lane" "$lane $jclass $jsince $LANE_HANDLED"
  fi

  sustained=$(( NOW - since ))
  lane_verdict "$sustained"
}

# handled_mover <host> <inbox>: the owner of the newest handled record, which is
# the only thing the filesystem can say about who moved it. Records are sent in
# order under a zero-padded name, so the lexically greatest handled name is the
# newest one, read without asking `ls` to sort. A remote lane reports `-`.
handled_mover() {  # <host> <inbox>
  local newest kind name corr owner
  [ -z "$1" ] || { printf -- '-'; return 0; }
  newest=''
  while IFS='	' read -r kind name corr; do
    [ "$kind" = handled ] || continue
    if [ -z "$newest" ] || [ "$name" \> "$newest" ]; then newest=$name; fi
  done <<EOF
$LANE_RECORDS
EOF
  [ -n "$newest" ] || { printf -- '-'; return 0; }
  owner=$(file_owner "$2/handled/$newest")
  printf '%s' "${owner:--}"
}

lane_verdict() {  # <error-class-sustained-seconds>
  local sustained=$1 missed_pct total half
  LANE_VERDICT=alive
  LANE_REASON=

  if ! is_int "$LANE_BEAT"; then
    LANE_VERDICT=dead
    LANE_REASON="the supervision beat is unestablished (watcher_beat_age_s=-), and an unknown reading is never a fresh beat"
    return 0
  fi
  if gt "$LANE_BEAT" "$W"; then
    LANE_VERDICT=dead
    LANE_REASON="supervision beat age ${LANE_BEAT}s over W=${W}s"
    return 0
  fi
  if gt "$LANE_PENDING" 0 && gt "$LANE_DRAIN" "$D" && [ "$LANE_HANDLED_MOVED" = no ]; then
    LANE_VERDICT=dead
    LANE_REASON="$LANE_PENDING pending with oldest ${LANE_DRAIN}s over D=${D}s and no movement to handled since the last sweep"
    return 0
  fi
  case "$LANE_AGENT" in
    dead|missing)
      if gt "$LANE_PENDING" 0 && gt "$LANE_DRAIN" "$D"; then
        LANE_VERDICT=dead
        LANE_REASON="agent_status=$LANE_AGENT with $LANE_PENDING pending and oldest ${LANE_DRAIN}s over D=${D}s, so nothing will move them to handled"
        return 0
      fi
      ;;
  esac
  case "$LANE_ERRCLASS" in
    transport_dead|budget_exceeded)
      if gt "$sustained" "$E"; then
        LANE_VERDICT=dead
        LANE_REASON="$LANE_ERRCLASS sustained ${sustained}s over E=${E}s"
        return 0
      fi
      ;;
  esac

  if [ "$LANE_DRAINED_ON_ERROR" = yes ]; then
    LANE_VERDICT=degraded
    LANE_REASON="handled count moved while $LANE_ERRCLASS was active, so the drain is not proof of work (mover=$LANE_MOVER)"
    return 0
  fi
  if [ "$LANE_AGENT" = alive ] && gt "$LANE_MISSED" 0 && is_int "$LANE_RESOLVED"; then
    total=$(( LANE_MISSED + LANE_RESOLVED ))
    missed_pct=$(( LANE_MISSED * 100 / total ))
    if gt "$missed_pct" "$M"; then
      LANE_VERDICT=degraded
      LANE_REASON="${missed_pct}% of tracked requests unanswered ($LANE_MISSED of $total), over M=${M}%"
      return 0
    fi
  fi
  half=$(( W / 2 ))
  if gt "$LANE_BEAT" "$half"; then
    LANE_VERDICT=degraded
    LANE_REASON="supervision beat age ${LANE_BEAT}s elevated, still under W=${W}s"
    return 0
  fi
}

lane_line() {  # <lane>
  printf 'lane=%s source=%s verdict=%s pending_count=%s handled_count=%s inbox_drain_age_s=%s pending_reply_missed=%s pending_reply_resolved=%s error_signature_class=%s watcher_beat_age_s=%s agent_status=%s route_evidence_count=%s drained_while_error_active=%s mover=%s inbox=%s' \
    "$1" "$LANE_SOURCE" "$LANE_VERDICT" "$LANE_PENDING" "$LANE_HANDLED" \
    "$LANE_DRAIN" "$LANE_MISSED" "$LANE_RESOLVED" "$LANE_ERRCLASS" \
    "$LANE_BEAT" "$LANE_AGENT" "$LANE_ROUTE_EVIDENCE" "$LANE_DRAINED_ON_ERROR" \
    "$LANE_MOVER" "$LANE_INBOX"
  [ -z "$LANE_REASON" ] || printf ' reason=%s' "$LANE_REASON"
  printf '\n'
}

# --- modes ------------------------------------------------------------------

action_read() {
  local lane override
  [ -f "$CONFIG" ] || { printf 'response lanes are not configured (%s is absent)\n' "$CONFIG"; return 0; }
  config_load || { printf 'response lanes are not configured (%s names no lane)\n' "$CONFIG"; return 0; }
  printf 'thresholds W=%ss D=%ss E=%ss M=%s%% SELF=%ss\n' "$W" "$D" "$E" "$M" "$SELF"
  while IFS='	' read -r lane override; do
    [ -n "$lane" ] || continue
    lane_read "$lane" "$override"
    lane_line "$lane"
  done <<EOF
$LANES
EOF
}

action_routes() {
  local lane override routed=0 unverified=0 total pct extra
  SKIP_PANE=1
  [ -f "$CONFIG" ] || { printf 'response lanes are not configured (%s is absent)\n' "$CONFIG"; return 0; }
  config_load || { printf 'response lanes are not configured (%s names no lane)\n' "$CONFIG"; return 0; }
  while IFS='	' read -r lane override; do
    [ -n "$lane" ] || continue
    lane_read "$lane" "$override"
    if [ "$LANE_VERDICT" = unknown ] && [ "$LANE_ROUTE_EVIDENCE" = - ]; then
      printf 'lane lane=%s claims=- reason=%s\n' "$lane" "$LANE_REASON"
      continue
    fi
    route_classify "$lane"
    extra=
    if [ "$LANE_DRAINED_ON_ERROR" = yes ]; then
      extra=" drained_while_error_active=$LANE_DRAINED_ON_ERROR mover=$LANE_MOVER"
    fi
    printf 'lane lane=%s claims=%s routed=%s routed_unverified=%s%s\n' \
      "$lane" "$(( ROUTED + UNVERIFIED ))" "$ROUTED" "$UNVERIFIED" "$extra"
    routed=$(( routed + ROUTED ))
    unverified=$(( unverified + UNVERIFIED ))
  done <<EOF
$LANES
EOF
  total=$(( routed + unverified ))
  if [ "$total" -eq 0 ]; then pct=0; else pct=$(( unverified * 100 / total )); fi
  printf 'routing-verification claims=%s routed=%s routed_unverified=%s unverified_rate=%s/%s (%s%%)\n' \
    "$total" "$routed" "$unverified" "$unverified" "$total" "$pct"
}

action_check() {
  local lane override prior
  config_load || return 0
  while IFS='	' read -r lane override; do
    [ -n "$lane" ] || continue
    lane_read "$lane" "$override"
    prior=$(reported_read "$lane")
    [ -n "$prior" ] || prior=alive
    if [ "$LANE_VERDICT" != "$prior" ]; then
      if [ "$LANE_VERDICT" = alive ]; then
        printf 'lane-liveness: %s recovered to alive\n' "$lane"
      else
        printf 'lane-liveness: %s\n' "$(lane_line "$lane")"
      fi
      record_replace "$REPORTED" "$lane" "$lane $LANE_VERDICT"
    fi
  done <<EOF
$LANES
EOF
  # The heartbeat is written only here, after the whole sweep completed.
  touch "$BEAT" 2>/dev/null || true
}

action_selfcheck() {
  local age self=$SELF configured
  if [ ! -f "$BEAT" ]; then
    [ ! -f "$CONFIG" ] \
      || printf 'lane-liveness-self: the response-lane rail has never completed a sweep\n'
    return 0
  fi
  age=$(age_of "$BEAT")
  if ! is_int "$age"; then
    printf 'lane-liveness-self: the response-lane rail heartbeat is unreadable\n'
    return 0
  fi
  # The configured SELF is the one enforced, but leniently: a config that will
  # not load leaves the default in place rather than silencing the check that
  # exists to report silence.
  configured=$(config_load 2>/dev/null; printf '%s' "$SELF")
  is_int "$configured" && self=$configured
  if [ "$age" -gt "$self" ]; then
    printf 'lane-liveness-self: no response-lane sweep completed for %ss, over SELF=%ss\n' \
      "$age" "$self"
  fi
}

shim_write() {  # <check-id> <mode>
  local shim="$STATE/$1.check.sh" tmp
  umask 077
  tmp=$(mktemp "$STATE/.lane-liveness-shim.XXXXXX") || return 1
  printf '%s\n%s\n%s\n%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-lane-liveness.sh - response-lane rail poll shim.' \
    "export FM_HOME=$(printf '%q' "$FM_HOME")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-lane-liveness.sh") $2" > "$tmp" || return 1
  chmod 0700 "$tmp" || return 1
  mv -f -- "$tmp" "$shim" || return 1
  "$SCRIPT_DIR/fm-check-register.sh" "$1" >/dev/null || { rm -f -- "$shim"; return 1; }
}

action_arm() {
  [ -f "$CONFIG" ] || die "$CONFIG is absent, so there is nothing to arm"
  config_load || die "$CONFIG names no lane"
  shim_write "$CHECK_ID" check || die 'could not arm the response-lane check'
  shim_write "$SELF_CHECK_ID" selfcheck || {
    if "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null 2>&1; then
      die 'could not arm the rail-silence check'
    fi
    die 'could not arm the rail-silence check, and the response-lane check could not be rolled back either, so it may still be armed'
  }
  printf 'armed: state/%s.check.sh state/%s.check.sh\n' "$CHECK_ID" "$SELF_CHECK_ID"
}

action_disarm() {
  local failed=''
  "$SCRIPT_DIR/fm-check-unregister.sh" "$SELF_CHECK_ID" >/dev/null 2>&1 || failed=$SELF_CHECK_ID
  "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null 2>&1 || failed="${failed:+$failed }$CHECK_ID"
  [ -z "$failed" ] \
    || die "could not unregister $failed, so the rail is not disarmed and its records were left in place"
  rm -f -- "$BEAT" "$JOURNAL" "$REPORTED"
  printf 'disarmed: %s %s\n' "$CHECK_ID" "$SELF_CHECK_ID"
}

NOW=$(date +%s)

case "${1:-read}" in
  read) action_read ;;
  routes) action_routes ;;
  classes) action_classes ;;
  check) action_check ;;
  selfcheck) action_selfcheck ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  --help|-h|help) usage ;;
  *) die "unknown mode ${1:-}" ;;
esac
