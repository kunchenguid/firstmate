#!/usr/bin/env bash
# fm-mail.sh - general-purpose mail plane for reading and sending mail.
#
# Reads inbound mail over IMAP and sends mail over SMTP on demand. This is an
# ordinary mail client surface, not an escalation of authority: every surfaced
# message is a notification firstmate reads before deciding, and firstmate still
# applies its own judgment exactly as it would for a TUI message (including
# return/away and other rules).
#
# Subcommands:
#   read                 List unseen INBOX mail as a compact digest (From /
#                        Date / Subject / first line).
#   send <to> <subject> <body | ->
#                        Send one message. A "-" body reads plain text from
#                        stdin.
#   poll                 Surface NEW unseen mail as a `check` wake so firstmate
#                        answers it concisely. Only UNSEEN mail newer than the
#                        last poll is surfaced; already-read mail never wakes a
#                        poll, no message is ever marked read (BODY.PEEK), and
#                        every surfaced message is keyed by its immutable IMAP
#                        UID so expunge renumbering never re-wakes or loses
#                        mail. The cursor also records the mailbox generation
#                        (UIDVALIDITY) so a recreated mailbox cannot reuse a
#                        numeric uid and suppress a new wake, and overlapping
#                        polls are serialized so the same mail is never
#                        double-surfaced. poll itself has no scheduler: run it
#                        manually, from `at`/cron, or via the standing check
#                        armed by bin/fm-mail-check.sh (docs/configuration.md
#                        "Mail plane").
#   status               Print configuration and the last poll cursor. No
#                        network, no wake.
#
# Volume: poll surfaces at most FM_MAIL_POLL_MAX_WAKES messages per run
# (default 20, valid 1..200); a larger flood is left unseen so the next poll
# surfaces the next batch, keeping the durable wake queue bounded no matter how
# much inbound mail arrives. A header fetch that fails is still surfaced once
# (degraded placeholders) and retried on later polls until the real metadata
# lands; a persistently unfetchable uid is never skipped and never re-wakes.
#
# Deployment - credentials and endpoints live ONLY in the gitignored
# $FM_HOME/.env (same convention as the Relay/FMX token). Add these four
# required values, plus the optional ports and timeout:
#   FM_MAIL_USER=<imap/smtp account>
#   FM_MAIL_PASS=<password>
#   FM_IMAP_HOST=<imap host>
#   FM_IMAP_PORT=<imap port>     (default 993, implicit TLS)
#   FM_SMTP_HOST=<smtp host>
#   FM_SMTP_PORT=<smtp port>     (default 465, implicit TLS)
#   FM_MAIL_TIMEOUT=<seconds>    (default 20; IMAP/SMTP socket timeout)
# FM_HOME falls back to the repo root when unset. This script carries no secret
# and no default endpoint that could resolve against a wrong home; the four
# FM_MAIL_* credential and endpoint values are always required, and
# FM_MAIL_PASS is never logged. The wake library is sourced from next to this
# script, not from $FM_HOME/bin; cursor, journal, retry set, and queue stay
# under $FM_HOME/state.
#
# IMAP/SMTP work is delegated to bin/fm-mail.py (imaplib/smtplib, implicit TLS
# on 993/465). STARTTLS and port 587 are not supported. BODY.PEEK is used on
# read/poll so mail is never marked seen before firstmate actually answers it.

set -euo pipefail

# --- resolve home, env, and endpoints -------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-}"
if [ -z "$FM_HOME" ]; then
  FM_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
ENV_FILE="$FM_HOME/.env"
# Load the home .env for keys not already set, so a direct invocation's
# environment overrides .env exactly like the Relay/FMX contract (fmx_env_get:
# "env wins over .env"). Tolerates a leading "export ", surrounding whitespace,
# one layer of matching quotes, comments, and blank lines.
if [ -f "$ENV_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      ''|\#*) continue ;;
      export\ *) line="${line#export }" ;;
    esac
    case "$line" in
      *=*) ;;
      *) continue ;;
    esac
    key="${line%%=*}"
    key="${key#"${key%%[![:space:]]*}"}"
    val="${line#*=}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    case "$val" in
      \"*\") val=${val#\"}; val=${val%\"} ;;
      \'*\') val=${val#\'}; val=${val%\'} ;;
    esac
    if [ -n "$key" ] && [ -z "${!key:-}" ]; then
      export "$key=$val"
    fi
  done < "$ENV_FILE"
fi

for r in FM_MAIL_USER FM_MAIL_PASS FM_IMAP_HOST FM_SMTP_HOST; do
  if [ -z "${!r:-}" ]; then
    echo "fm-mail: missing required \$FM_HOME/.env value: $r" >&2
    echo "fm-mail: add $r (and the other three FM_MAIL_* values) to $ENV_FILE" >&2
    exit 1
  fi
done
IMAP_HOST="$FM_IMAP_HOST"
IMAP_PORT="${FM_IMAP_PORT:-993}"
SMTP_HOST="$FM_SMTP_HOST"
SMTP_PORT="${FM_SMTP_PORT:-465}"
case "$IMAP_PORT" in
  ''|*[!0-9]*|0)
    echo "fm-mail: FM_IMAP_PORT must be a positive integer, got: ${FM_IMAP_PORT:-}" >&2
    exit 1
    ;;
esac
case "$SMTP_PORT" in
  ''|*[!0-9]*|0)
    echo "fm-mail: FM_SMTP_PORT must be a positive integer, got: ${FM_SMTP_PORT:-}" >&2
    exit 1
    ;;
esac
MAIL_MAX_WAKES="${FM_MAIL_POLL_MAX_WAKES:-20}"
case "$MAIL_MAX_WAKES" in
  ''|*[!0-9]*|0) MAIL_MAX_WAKES=20 ;;
esac
if [ "$MAIL_MAX_WAKES" -gt 200 ]; then
  MAIL_MAX_WAKES=200
fi

PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then
  echo "fm-mail: python3 required" >&2
  exit 1
fi
PY_BIN="$SCRIPT_DIR/fm-mail.py"
if [ ! -f "$PY_BIN" ]; then
  echo "fm-mail: $PY_BIN missing" >&2
  exit 1
fi

STATE_DIR="$FM_HOME/state"
mkdir -p "$STATE_DIR"
CURSOR="$STATE_DIR/.mail-seen"
# Durable emission journal: every successfully published poll wake records its
# uid here under the queue lock, immediately after the wake row is appended and
# before the cursor records it. A journal entry therefore always proves a wake
# was published, so a mail is never silently suppressed. The fleet wake drain
# acknowledges and removes consumed wake rows from its own queue, so the queue
# alone cannot prove that a wake was ever emitted after an ack; this journal is
# fm-mail's own record of emission and survives any drain ack, which makes
# recovery exactly-once instead of racing the drain.
WOKEN="$STATE_DIR/.mail-woken"
# Generation-scoped retry set: a uid whose header fetch failed is recorded
# here after its degraded wake so a later poll can fetch the real metadata.
# Cleared with the cursor and journal on a UIDVALIDITY change. The retry-scan
# position (.mail-retry-pos) is a durable cursor over this set so the bounded
# per-poll retry window marches through every uid; it is cleared with the set.
RETRY="$STATE_DIR/.mail-retry"
RETRY_POS="$STATE_DIR/.mail-retry-pos"
# Alternating-turn flag for a single contended wake slot (new surfacing vs
# retry recovery) at cap 1; cleared with the retry machinery on a generation
# change so a new mailbox starts with new mail first.
TURN="$STATE_DIR/.mail-turn"

# Invoke the python engine with the resolved endpoints, cursor, and cap in the
# environment so credentials never reach argv.
run_py() {
  FM_MAIL_USER="$FM_MAIL_USER" FM_MAIL_PASS="$FM_MAIL_PASS" \
  FM_IMAP_HOST="$IMAP_HOST" FM_IMAP_PORT="$IMAP_PORT" \
  FM_SMTP_HOST="$SMTP_HOST" FM_SMTP_PORT="$SMTP_PORT" \
  FM_MAIL_CURSOR="$CURSOR" FM_MAIL_RETRY="$RETRY" \
  FM_MAIL_RETRY_POS="$RETRY_POS" FM_MAIL_TURN="$TURN" \
  FM_MAIL_POLL_MAX_WAKES="$MAIL_MAX_WAKES" \
    "$PY" "$PY_BIN" "$@"
}

usage() {
  cat <<'EOF'
fm-mail.sh read
fm-mail.sh send <to> <subject> <body | ->
fm-mail.sh poll
fm-mail.sh status
EOF
}

mail_seen() {
  # $1 = uid; returns 0 when the cursor already records the uid as surfaced.
  grep -Fqx "$1" "$CURSOR"
}

mail_retry_add() {
  # $1 = uid; record that a degraded surfacing should be retried.
  local id=$1
  [ -n "$id" ] || return 1
  if [ -f "$RETRY" ] && grep -Fqx "$id" "$RETRY"; then
    return 0
  fi
  printf '%s\n' "$id" >> "$RETRY" || return 1
  return 0
}

mail_retry_remove() {
  # $1 = uid; drop a recovered uid from the retry set.
  local id=$1 rc=0
  [ -n "$id" ] || return 0
  [ -f "$RETRY" ] || return 0
  grep -vx -e "$id" "$RETRY" > "$RETRY.tmp.$$" 2>/dev/null || rc=$?
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
    chmod 0600 "$RETRY.tmp.$$" 2>/dev/null || true
    mv -f -- "$RETRY.tmp.$$" "$RETRY" || {
      rm -f -- "$RETRY.tmp.$$"
      return 1
    }
    return 0
  fi
  rm -f -- "$RETRY.tmp.$$"
  return 1
}

mail_record_evidence() {
  # Write the journal and cursor records; return 0 when at least one landed.
  # At least one must survive with a queued wake row, or the drain could
  # acknowledge the wake with no durable record of its uid.
  local generation=$1 id=$2 journal_ok=0 cursor_ok=0
  if printf '%s\t%s\n' "$generation" "$id" >> "$WOKEN"; then
    journal_ok=1
  fi
  if printf '%s\n' "$id" >> "$CURSOR"; then
    cursor_ok=1
  fi
  if [ "$journal_ok" -eq 1 ] || [ "$cursor_ok" -eq 1 ]; then
    return 0
  fi
  return 1
}

mail_rollback_wake_locked() {
  # Remove a just-appended wake row plus any partial journal/cursor evidence.
  # Runs under the held FM_WAKE_QUEUE_LOCK, so the rewrite cannot race an
  # acknowledgement. The journal entry is removed FIRST and required: deleting
  # the wake row while a journal entry survives would let the next heal mark
  # the uid surfaced without a wake. If the journal cannot be verified and
  # cleaned, fail the rollback so the row stays queued and is delivered -
  # never suppressed.
  local wake_key=$1 generation=$2 id=$3 clean_key tmp jtmp
  clean_key=$(printf '%s' "$wake_key" | fm_wake_clean_field)
  # Journal evidence: only when this uid has an entry must it be removed now.
  # When the journal is unwritable (the usual reason both records failed) no
  # entry exists and there is nothing to clean.
  if awk -F '\t' -v g="$generation" -v i="$id" \
      '$1 == g && $2 == i { found=1 } END { exit found ? 0 : 1 }' \
      "$WOKEN" 2>/dev/null; then
    jtmp=$(mktemp "$WOKEN.rm.XXXXXX") || return 1
    if ! awk -F '\t' -v g="$generation" -v i="$id" \
        '!($1 == g && $2 == i)' "$WOKEN" > "$jtmp" 2>/dev/null; then
      rm -f -- "$jtmp"
      return 1
    fi
    if ! mv -f -- "$jtmp" "$WOKEN" 2>/dev/null; then
      rm -f -- "$jtmp"
      return 1
    fi
  fi
  # Queue row: remove it (required) so nothing ackable survives without a
  # durable record.
  tmp=$(mktemp "$FM_WAKE_QUEUE.rollback.XXXXXX") || return 1
  if ! awk -F '\t' -v key="$clean_key" '
    NF >= 5 && $3 == "check" && $4 == key { next }
    { print }
  ' "$FM_WAKE_QUEUE" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" 2>/dev/null || true
  if ! mv -f -- "$tmp" "$FM_WAKE_QUEUE"; then
    rm -f -- "$tmp"
    return 1
  fi
  # Cursor record: best-effort; a surviving cursor line only means already
  # surfaced, which the heal tolerates.
  if grep -vx -e "$id" "$CURSOR" > "$CURSOR.tmp.$$" 2>/dev/null; then
    if mv -f -- "$CURSOR.tmp.$$" "$CURSOR" 2>/dev/null; then
      :
    fi
  fi
  rm -f -- "$CURSOR.tmp.$$"
  return 0
}

wake_for() {
  # Publish one `check` wake and its durable records under a single held
  # FM_WAKE_QUEUE_LOCK. The key is generation-aware when the mailbox reports a
  # UIDVALIDITY, so a restored mailbox's reused uid can never collide with a
  # stale wake key. The wake row is appended first, then the evidence records;
  # the drain acknowledges and deletes consumed rows only under the same lock,
  # so it can never remove our wake between the surface and the uid record.
  # A journal entry therefore always means the wake was published - a mail is
  # never silently suppressed. If no durable record can be written the row is
  # rolled back for a clean retry, and only when the journal, the cursor, and
  # the queue rewrite all fail does the poll fail closed, accepting a possible
  # duplicate over a lost mail.
  #
  # The one irreducible residual is a kill in the microseconds between the
  # queue append and the journal write, followed by the drain acknowledging the
  # row before the next poll heals it: neither the journal nor the cursor then
  # holds the uid, and the next poll wakes the mail again. A possible duplicate
  # (never a missed mail) is the deliberate, bounded tradeoff for keeping the
  # durable record write on the same held lock as the publish.
  #
  # Returns:
  #   0 - the wake row was appended and a durable uid record landed.
  #   1 - the wake row was appended and rolled back; nothing was delivered.
  #   2 - the wake row survived with no durable record (fail-closed); the drain
  #       delivers it and the next poll's heal records the uid.
  #   3 - the wake row was never appended; nothing was delivered.
  #   4 - the wake was delivered but the optional retry-id cleanup failed.
  local generation=$1 id=$2 summary=$3 retry_id=${4:-} lib="$SCRIPT_DIR/fm-wake-lib.sh" status=0
  local wake_key="mail:$id"
  if [ -n "$generation" ]; then
    wake_key="mail:$generation/$id"
  fi
  if [ ! -f "$lib" ]; then
    echo "fm-mail: $lib missing; cannot wake" >&2
    return 1
  fi
  # shellcheck source=bin/fm-wake-lib.sh
  # shellcheck disable=SC1091
  . "$lib"
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  if fm_wake_append_locked check "$wake_key" "check: mail $id - $summary"; then
    if mail_record_evidence "$generation" "$id"; then
      :
    elif mail_rollback_wake_locked "$wake_key" "$generation" "$id"; then
      echo "fm-mail: wake for $id rolled back (journal and cursor writes failed); retried on next poll" >&2
      status=1
    elif mail_record_evidence "$generation" "$id"; then
      echo "fm-mail: wake for $id durably recorded after the queue rewrite failed" >&2
    else
      echo "fm-mail: wake for $id could not be rolled back or durably recorded; the wake stays queued and the next poll heals it - a possible duplicate, never a lost mail" >&2
      status=2
    fi
  else
    echo "fm-mail: wake append failed for $id; retried on next poll" >&2
    status=3
  fi
  # A recovered uid must stay retry-eligible until the wake is durably
  # published, so the retry record is cleared only after a successful append.
  # This removes the kill-window between "retry removed" and "wake published"
  # that could strand recovered metadata: the uid would be cursor-recorded from
  # the earlier degraded wake but no longer in the retry set, so later polls
  # would never re-fetch it.
  if { [ "$status" -eq 0 ] || [ "$status" -eq 2 ]; } && [ -n "$retry_id" ]; then
    if ! mail_retry_remove "$retry_id"; then
      echo "fm-mail: could not clear retry for recovered $retry_id after publish; retried on next poll" >&2
      status=4
    fi
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

mail_stored_generation() {
  # Print the mailbox generation the local cursor was last reset to, or "".
  [ -f "$CURSOR" ] || : > "$CURSOR"
  grep -m1 '^uidvalidity=' "$CURSOR" | cut -d= -f2 || true
}

mail_heal() {
  # Reconcile a poll interrupted between its operations. Emission is a
  # three-phase commit: the wake append publishes the surfacing, the journal
  # write then proves THIS home emitted it, and the cursor record finally
  # declares the uid surfaced. Each phase is healed from durable evidence:
  #
  # 1. Journal heal - a journal entry is proof a wake was published, written
  #    immediately after a successful wake append under the same lock. It
  #    survives the fleet drain's ack (which physically removes consumed wake
  #    rows from the queue), so a poll killed after appending its wake but
  #    before recording the uid is recovered even when the drain already
  #    acknowledged that wake: the uid is recorded without re-waking, never
  #    duplicate.
  # 2. Queue heal - a queued wake whose uid is absent from the cursor (kill in
  #    the tiny gap between wake append and journal write) is likewise recorded
  #    without re-waking.
  # Both are generation-scoped: only evidence matching the CURRENT mailbox
  # generation is healed, so a legacy key or a stale prior-generation wake can
  # never mark a reused numeric uid as surfaced in the new mailbox.
  local generation=$1 jgen juid keyrest keygen keyuid heal_ok=0
  if [ -s "$WOKEN" ]; then
    while IFS=$'\t' read -r jgen juid; do
      [ -n "$juid" ] || continue
      [ "$jgen" != "$generation" ] && continue
      if ! mail_seen "$juid"; then
        if printf '%s\n' "$juid" >> "$CURSOR"; then
          :
        else
          heal_ok=1
        fi
      fi
    done < "$WOKEN"
    # Clear the journal only when every uid it names was durably recorded; if
    # any cursor write failed, keep the evidence so the next poll can retry it
    # (and an acknowledged wake can never be surfaced twice for lack of it).
    [ "$heal_ok" -eq 0 ] && : > "$WOKEN"
  fi
  while IFS= read -r k; do
    keyrest="${k#mail:}"
    [ "$keyrest" = "$k" ] && continue
    keygen=""
    keyuid=""
    case "$keyrest" in
      */*) keygen="${keyrest%%/*}"; keyuid="${keyrest#*/}" ;;
      *) keyuid="$keyrest" ;;
    esac
    [ -z "$keyuid" ] && continue
    [ "$keygen" != "$generation" ] && continue
    if ! mail_seen "$keyuid"; then
      if printf '%s\n' "$keyuid" >> "$CURSOR"; then
        :
      else
        heal_ok=1
      fi
    fi
  done < <(fm_wake_queued_keys check 2>/dev/null || true)
  return "$heal_ok"
}

mail_poll() {
  # List unseen mail (uid,date,from,subj,status) plus the mailbox generation
  # guard, then diff against already-surfaced uids to find NEW messages and
  # surface one wake each. status is ok, retry, or degraded; an empty status
  # is treated as ok so a legacy four-field row still wakes. Never marks
  # anything read. Overlapping polls are serialized on the mail-seen lock;
  # each poll first heals a run interrupted between its phases (mail_heal), so
  # an overlapping poll or an interrupted run can never lose a mail or
  # double-surface it.
  local list generation uid fr subj status woke=0 need_wake line wake_rc=0
  if [ ! -f "$SCRIPT_DIR/fm-wake-lib.sh" ]; then
    echo "fm-mail: $SCRIPT_DIR/fm-wake-lib.sh missing; cannot poll" >&2
    return 1
  fi
  # shellcheck source=bin/fm-wake-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_acquire_wait "$STATE_DIR/.mail-seen.lock"
  if ! list="$(run_py poll_list)"; then
    # The poll engine already printed its cause on stderr; just release the
    # lock and fail instead of letting set -e abort the whole script with the
    # lock still held.
    fm_lock_release "$STATE_DIR/.mail-seen.lock"
    return 1
  fi
  generation="$(printf '%s\n' "$list" | head -n1 | cut -f2)"
  list="$(printf '%s\n' "$list" | tail -n +2)"

  # A recreated/restored mailbox has a new UIDVALIDITY; a numeric uid can be
  # reused, so a stale cursor must not suppress its wake. Journal entries from
  # the old mailbox are equally stale: they describe wakes from before the
  # mailbox identity changed, so clear them rather than risk healing a reused
  # uid into the new generation. The retry set is equally stale.
  if [ -n "$generation" ] && [ "$(mail_stored_generation)" != "$generation" ]; then
    printf 'uidvalidity=%s\n' "$generation" > "$CURSOR"
    : > "$WOKEN"
    : > "$RETRY"
    : > "$RETRY_POS"
    : > "$TURN"
  fi

  if ! mail_heal "$generation"; then
    echo "fm-mail: heal could not record a uid; journal kept; retried on next poll" >&2
    fm_lock_release "$STATE_DIR/.mail-seen.lock"
    return 1
  fi

  # cut -f keeps empty TSV fields; IFS-tab read would collapse the empty
  # Date on a degraded row and shift status off the end.
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    uid=$(printf '%s\n' "$line" | cut -f1)
    fr=$(printf '%s\n' "$line" | cut -f3)
    subj=$(printf '%s\n' "$line" | cut -f4)
    status=$(printf '%s\n' "$line" | cut -f5)
    [ -z "$uid" ] && continue
    [ -z "$status" ] && status=ok
    need_wake=0
    case "$status" in
      retry)
        # Already cursor-recorded from the degraded wake; surface the recovered
        # metadata without gating on mail_seen.
        need_wake=1
        ;;
      *)
        if ! mail_seen "$uid"; then
          need_wake=1
        fi
        ;;
    esac
    if [ "$need_wake" -eq 1 ]; then
      # Wake first, then record, then clear retry eligibility: the wake append,
      # journal, cursor commit, and retry-record removal all happen together
      # under the wake-queue lock inside wake_for (so no drain ack can split
      # them), and a failure stops the poll so the next run retries. A kill
      # before the append leaves nothing and the next poll retries; a kill
      # after the append is healed above without re-waking.
      # Reaching the per-poll wake cap stops the loop: the remaining unseen
      # mail stays out of the cursor and surfaces on the next poll, so a flood
      # bounds the durable wake queue instead of flooding firstmate.
      if [ "$woke" -ge "$MAIL_MAX_WAKES" ]; then
        echo "fm-mail: per-poll wake cap ($MAIL_MAX_WAKES) reached; remaining mail surfaces on the next poll" >&2
        break
      fi
      if [ "$status" = degraded ]; then
        # Record the retry BEFORE the wake so a failed retry write can never
        # leave the uid cursor-recorded but unrecoverable: the mail stays
        # unseen and is retried next poll instead.
        if ! mail_retry_add "$uid"; then
          echo "fm-mail: could not record retry for $uid; retried on next poll" >&2
          fm_lock_release "$STATE_DIR/.mail-seen.lock"
          return 1
        fi
      fi
      wake_rc=0
      # Clear the retry record as part of the wake publish transaction. For a
      # recovered uid this removes the dangerous gap where the retry was cleared
      # but the wake had not yet published; a kill in that gap would leave the
      # uid cursor-recorded from the degraded wake but no longer retry-eligible,
      # so its recovered metadata could never surface. For normal (ok) mail it
      # also clears any stale retry entry left by a rolled-back earlier wake.
      # Degraded mail keeps its retry entry so the next poll retries the fetch.
      retry_arg=""
      if [ "$status" = retry ] || [ "$status" = ok ]; then
        retry_arg="$uid"
      fi
      wake_for "$generation" "$uid" "mail from $fr - ${subj:-no subject}" "$retry_arg" || wake_rc=$?
      if [ "$wake_rc" -eq 0 ]; then
        echo "fm-mail: woke for $uid"
        woke=$((woke + 1))
      else
        echo "fm-mail: wake failed for $uid; retried on next poll" >&2
        fm_lock_release "$STATE_DIR/.mail-seen.lock"
        return 1
      fi
    fi
  done <<< "$list"
  fm_lock_release "$STATE_DIR/.mail-seen.lock"
  if [ "$woke" -eq 0 ]; then
    echo "fm-mail: no new mail"
  fi
  return 0
}

case "${1:-}" in
  read)
    run_py read
    ;;
  send)
    to="${2:-}"
    subj="${3:-}"
    body="${4:--}"
    if [ -z "$to" ] || [ -z "$subj" ]; then
      usage
      exit 1
    fi
    if [ "$body" = "-" ]; then
      body="$(cat)"
    fi
    printf '%s' "$body" | run_py send "$to" "$subj" "-"
    ;;
  status)
    echo "mail account: $FM_MAIL_USER"
    echo "imap: $IMAP_HOST:$IMAP_PORT smtp: $SMTP_HOST:$SMTP_PORT"
    run_py seen "$CURSOR" || true
    ;;
  poll)
    mail_poll
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac